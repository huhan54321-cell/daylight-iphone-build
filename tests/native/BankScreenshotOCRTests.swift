import Foundation
import CoreGraphics
import CoreText
import ImageIO

enum BankScreenshotOCRTests {
    static func run() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            guard condition else { throw AppFailure.message("FAIL screenshot OCR: \(label)") }
        }
        func rejects(_ input: Data, expected: BankScreenshotOCRError) async -> Bool {
            do {
                _ = try await BankScreenshotOCR.recognize(input)
                return false
            } catch let error as BankScreenshotOCRError {
                return error.localizedDescription == expected.localizedDescription
            } catch { return false }
        }
        try expect(await rejects(Data(), expected: .emptyImage), "empty image has a readable error")
        try expect(await rejects(Data("not an image".utf8), expected: .unreadableImage), "unsupported input is rejected")
        try expect(await rejects(Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1), expected: .fileTooLarge), "large compressed input is bounded before decoding")

        let image = try fixture()
        let encoded = try encode(image)
        let result = try await BankScreenshotOCR.recognize(encoded)
        let text = compact(result.text)
        try expect(text.components(separatedBy: "动账交易提醒").count == 3, "Vision recognizes both neutral transaction cards")
        try expect(text.components(separatedBy: "交易金额").count == 3
                   && text.components(separatedBy: "账户余额").count == 3,
                   "transaction amounts and balances keep distinct labels")
        try expect(text.contains("1.23") && text.contains("7.89")
                   && text.contains("100.00") && text.contains("92.11"),
                   "small transaction amounts and larger balances are retained")
        let firstTime = text.range(of: "09:01")
        let firstAmount = text.range(of: "1.23")
        let firstBalance = text.range(of: "100.00")
        let secondTime = text.range(of: "09:04")
        let secondAmount = text.range(of: "7.89")
        try expect(firstTime != nil && firstAmount != nil && firstBalance != nil && secondTime != nil && secondAmount != nil,
                   "both cards retain their transaction times and amounts")
        if let firstTime, let firstAmount, let firstBalance, let secondTime, let secondAmount {
            try expect(firstTime.lowerBound < firstAmount.lowerBound && firstAmount.lowerBound < firstBalance.lowerBound
                       && firstBalance.lowerBound < secondTime.lowerBound && secondTime.lowerBound < secondAmount.lowerBound,
                       "reading order groups each card before the next card")
        }
        let receivedAt = ISO8601DateFormatter().date(from: "2026-10-05T02:00:00Z")!
        let parsed = try BankScreenshotCore.parse(text: result.text, receivedAt: receivedAt)
        try expect(parsed.messages.count == 2 && parsed.incompleteCardCount == 0,
                   "real Vision output yields two complete structured cards; synthetic output: \(result.text)")
        try expect(parsed.messages.compactMap(\.draft).map(\.cents) == [123, 789],
                   "end-to-end OCR parser retains both small transaction amounts")
        try expect(parsed.messages.compactMap(\.draft).map(\.bankBalanceAfterCents) == [10_000, 9_211],
                   "end-to-end OCR parser assigns the correct balance to each card")
        try expect(parsed.messages.compactMap(\.draft).map(\.date) == [
            ISO8601DateFormatter().date(from: "2026-10-05T01:01:00Z")!,
            ISO8601DateFormatter().date(from: "2026-10-05T01:04:00Z")!
        ], "end-to-end OCR parser preserves Chinese local transaction times")
        try expect(parsed.messages.allSatisfy { $0.origin == .wechatScreenshot && $0.status == .pending },
                   "recognized screenshots stay pending for review with their actual source")

        let rotated = try rotateCounterclockwise(image)
        let rotatedData = try encode(rotated, type: "public.jpeg", orientation: 6)
        let rotatedResult = try await BankScreenshotOCR.recognize(rotatedData)
        let rotatedText = compact(rotatedResult.text)
        try expect(rotatedText.contains("1.23") && rotatedText.contains("7.89")
                   && rotatedText.components(separatedBy: "交易金额").count == 3,
                   "encoded orientation restores rotated financial rows")
        let rotatedParsed = try BankScreenshotCore.parse(text: rotatedResult.text, receivedAt: receivedAt)
        try expect(rotatedParsed.messages.compactMap(\.draft).map(\.cents) == [123, 789],
                   "orientation-aware OCR still produces two usable transaction drafts")
        let blank = try blankImage()
        try expect(await rejects(try encode(blank), expected: .noText), "blank screenshot asks for a clearer image")
        return checks
    }

    private static func compact(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    }

    // Neutral synthetic data only: no account digits, names, or transactions from user screenshots.
    private static func fixture() throws -> CGImage {
        let context = try canvas(width: 1_400, height: 1_800)
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 44, nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        func card(top: CGFloat, time: String, kind: String, amount: String, balance: String) {
            draw("中国工商银行客户服务", x: 80, y: top)
            draw("动账交易提醒", x: 80, y: top - 90)
            let rows = [
                ("账号类型：", "尾号 XXXX 的借记卡"),
                ("交易时间：", "2026年10月5日\(time)"),
                ("交易类型：", kind),
                ("交易金额：", "出账 \(amount) 人民币元"),
                ("账户余额：", "\(balance) 人民币元")
            ]
            for (index, row) in rows.enumerated() {
                let y = top - 190 - CGFloat(index) * 80
                draw(row.0, x: 80, y: y)
                draw(row.1, x: 380, y: y)
            }
        }
        card(top: 1_680, time: "09:01", kind: "缴费财付通-示例公交", amount: "1.23", balance: "100.00")
        card(top: 840, time: "09:04", kind: "消费财付通-示例小店", amount: "7.89", balance: "92.11")
        guard let image = context.makeImage() else { throw AppFailure.message("OCR fixture bitmap failed") }
        return image
    }

    private static func canvas(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppFailure.message("OCR fixture context failed")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.textMatrix = .identity
        return context
    }

    private static func blankImage() throws -> CGImage {
        guard let image = try canvas(width: 800, height: 600).makeImage() else {
            throw AppFailure.message("OCR blank fixture failed")
        }
        return image
    }

    private static func rotateCounterclockwise(_ image: CGImage) throws -> CGImage {
        let context = try canvas(width: image.height, height: image.width)
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let rotated = context.makeImage() else { throw AppFailure.message("OCR rotated fixture failed") }
        return rotated
    }

    private static func encode(_ image: CGImage, type: String = "public.png", orientation: Int = 1) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw AppFailure.message("OCR fixture encoder failed")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure.message("OCR fixture encoding failed") }
        return data as Data
    }
}
