import Foundation
import CoreGraphics
import ImageIO
import Vision

struct BankScreenshotOCRResult: Sendable {
    let text: String
    let warnings: [String]
}

enum BankScreenshotOCRError: Error, LocalizedError, Sendable {
    case emptyImage
    case fileTooLarge
    case unreadableImage
    case imageTooLarge
    case noText
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .emptyImage: return "没有读取到图片，请重新选择截图"
        case .fileTooLarge: return "图片超过 20 MB，请裁剪或分成几张截图再试"
        case .unreadableImage: return "无法读取这张图片，请选择清晰的 PNG、JPEG 或 HEIC 截图"
        case .imageTooLarge: return "图片尺寸过大，请分成几张截图再识别"
        case .noText: return "这张图片没有识别到文字，请选择清晰、完整的动账提醒截图"
        case .recognitionFailed: return "这张图片的文字识别失败，请重新截图再试"
        }
    }
}

/// Images stay in memory. Only the recognized text leaves the local Vision operation.
enum BankScreenshotOCR {
    static func recognize(_ data: Data) async throws -> BankScreenshotOCRResult {
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool { try recognizeSynchronously(data) }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func recognizeSynchronously(_ data: Data) throws -> BankScreenshotOCRResult {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw BankScreenshotOCRError.emptyImage }
        guard data.count <= 20 * 1_024 * 1_024 else { throw BankScreenshotOCRError.fileTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw BankScreenshotOCRError.unreadableImage }
        // Check metadata before decoding so compressed, oversized files cannot allocate a huge bitmap.
        guard width <= 20_000, height <= 20_000,
              width <= 24_000_000 / height else { throw BankScreenshotOCRError.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw BankScreenshotOCRError.unreadableImage
        }
        let orientationValue = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            try Task.checkCancellation()
            throw BankScreenshotOCRError.recognitionFailed
        }
        try Task.checkCancellation()
        let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(text: text, bounds: observation.boundingBox, confidence: candidate.confidence)
        }
        guard !lines.isEmpty else { throw BankScreenshotOCRError.noText }
        var warnings: [String] = []
        if lines.contains(where: { $0.confidence < 0.8 }) {
            warnings.append("部分文字识别置信度较低，请对照截图确认金额、时间和余额")
        }
        if CGImageSourceGetCount(source) > 1 {
            warnings.append("这张图片有多个画面，仅识别了第一张")
        }
        return BankScreenshotOCRResult(text: readingOrder(lines), warnings: warnings)
    }

    private struct RecognizedLine {
        let text: String
        let bounds: CGRect
        let confidence: Float
    }

    private struct ReadingRow {
        var lines: [RecognizedLine]
        let centerY: CGFloat
        let height: CGFloat
    }

    private static func readingOrder(_ lines: [RecognizedLine]) -> String {
        let sorted = lines.sorted {
            if $0.bounds.midY != $1.bounds.midY { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
        var rows: [ReadingRow] = []
        for line in sorted {
            if let index = rows.indices.last,
               abs(rows[index].centerY - line.bounds.midY) <= min(rows[index].height, line.bounds.height) * 0.45 {
                rows[index].lines.append(line)
            } else {
                rows.append(ReadingRow(lines: [line], centerY: line.bounds.midY, height: line.bounds.height))
            }
        }
        // A label and value often arrive as separate Vision observations on the same line.
        // Joining each row first preserves the relationship without interleaving adjacent cards.
        return rows.map { row in
            row.lines.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }
}
