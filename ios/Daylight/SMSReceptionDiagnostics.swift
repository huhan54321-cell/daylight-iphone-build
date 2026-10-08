import Foundation

enum SMSReceptionStage: String, Codable, Equatable {
    case input, load, accept, save
    var label: String {
        switch self {
        case .input: return "检查输入"
        case .load: return "读取本地记录"
        case .accept: return "解析与接收"
        case .save: return "保存本地记录"
        }
    }
}

enum SMSReceptionOutcome: String, Codable, Equatable {
    case started, recorded, pending, alreadyRecorded, alreadyReceived, skipped, failed
    var label: String {
        switch self {
        case .started: return "接收操作已开始，尚无完成结果"
        case .recorded: return "已保存交易"
        case .pending: return "已接收，等待确认"
        case .alreadyRecorded: return "这条短信已记录"
        case .alreadyReceived: return "这条短信已接收"
        case .skipped: return "已跳过非记账消息"
        case .failed: return "接收失败"
        }
    }
}

enum SMSReceptionProblem: String, Codable, Equatable {
    case emptyBody, bodyTooLong, invalidRequestID, recordsUnreadable, receptionFailed, saveFailed
    var summary: String {
        switch self {
        case .emptyBody: return "没有收到短信正文。请将正文设为获取文本的输出变量；在自动化编辑页手动运行时，可能没有消息输入。"
        case .bodyTooLong: return "短信正文超过 4000 字，请检查输入变量。"
        case .invalidRequestID: return "短信编号格式无效。可留空由 App 生成；保留编号时需为 16–100 位字母、数字、下划线或短横线。"
        case .recordsUnreadable: return "本地记录无法读取，原文件已保留。请解锁并打开日常后重试；仍失败时检查记录或恢复备份。"
        case .receptionFailed: return "短信接收检查未通过，请查看快捷指令显示的完整错误。"
        case .saveFailed: return "本地记录保存失败，尚未确认接收成功。请解锁并打开日常后重试。"
        }
    }
}

enum SMSReceptionErrorCategory: String, Codable, Equatable {
    case app, cocoa, posix, decoding, other
    var label: String {
        switch self {
        case .app: return "Daylight.AppFailure"
        case .cocoa: return "NSCocoaErrorDomain"
        case .posix: return "NSPOSIXErrorDomain"
        case .decoding: return "记录解码"
        case .other: return "其他错误"
        }
    }
}

struct SMSReceptionAttempt: Codable, Equatable {
    var attemptedAt: Date
    var finishedAt: Date?
    var appVersion: String
    var appBuild: String
    var bodyLength: Int
    var stage: SMSReceptionStage = .input
    var outcome: SMSReceptionOutcome = .started
    var problem: SMSReceptionProblem?
    var errorCategory: SMSReceptionErrorCategory?
    var errorCode: Int?
    var origin: BankMessageOrigin? = nil
}

// One bounded, local diagnostic outside Snapshot and backups. Never retain input strings
// or arbitrary error descriptions: either can contain SMS content or local file paths.
enum SMSReceptionDiagnostics {
    static let storageKey = "daylight.smsReception.lastAttempt.v1"
    private static let maximumBytes = 4096

    static func begin(bodyLength: Int, at: Date = Date(), bundle: Bundle = .main, defaults: UserDefaults = .standard, origin: BankMessageOrigin? = nil) -> SMSReceptionAttempt {
        let attempt = SMSReceptionAttempt(
            attemptedAt: at,
            appVersion: metadata(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            appBuild: metadata(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            bodyLength: min(max(bodyLength, 0), 4001), origin: origin
        )
        persist(attempt, defaults: defaults)
        return attempt
    }

    static func advance(_ attempt: inout SMSReceptionAttempt, to stage: SMSReceptionStage, defaults: UserDefaults = .standard) {
        attempt.stage = stage
        persist(attempt, defaults: defaults)
    }

    static func succeed(_ attempt: inout SMSReceptionAttempt, result: String, at: Date = Date(), defaults: UserDefaults = .standard) {
        attempt.finishedAt = at
        switch result {
        case "这条短信已记录": attempt.outcome = .alreadyRecorded
        case "这条短信已接收": attempt.outcome = .alreadyReceived
        case "已跳过非记账消息": attempt.outcome = .skipped
        default: attempt.outcome = result.hasPrefix("已保存这笔") ? .recorded : .pending
        }
        persist(attempt, defaults: defaults)
    }

    static func fail(_ attempt: inout SMSReceptionAttempt, at stage: SMSReceptionStage, error: Error, problem: SMSReceptionProblem? = nil, time: Date = Date(), defaults: UserDefaults = .standard) {
        attempt.stage = stage
        attempt.outcome = .failed
        attempt.finishedAt = time
        attempt.errorCategory = errorCategory(error)
        attempt.errorCode = (error as NSError).code
        switch stage {
        case .input, .accept: attempt.problem = problem ?? .receptionFailed
        case .load: attempt.problem = .recordsUnreadable
        case .save: attempt.problem = .saveFailed
        }
        persist(attempt, defaults: defaults)
    }

    static func inputProblem(body: String, requestID: String?) -> SMSReceptionProblem? {
        let text = body.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .emptyBody }
        if text.utf16.count > 4000 { return .bodyTooLong }
        let identifier = requestID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !identifier.isEmpty, identifier.range(of: #"^[A-Za-z0-9_-]{16,100}$"#, options: .regularExpression) == nil { return .invalidRequestID }
        return nil
    }

    static func errorCategory(_ error: Error) -> SMSReceptionErrorCategory {
        if error is DecodingError { return .decoding }
        let domain = (error as NSError).domain
        switch domain {
        case AppFailure.errorDomain: return .app
        case NSCocoaErrorDomain: return .cocoa
        case NSPOSIXErrorDomain: return .posix
        default: return .other
        }
    }

    static func failureCode(_ error: Error) -> String {
        "\(errorCategory(error).label) \((error as NSError).code)"
    }

    static func latest(defaults: UserDefaults = .standard) -> SMSReceptionAttempt? {
        decode(defaults.data(forKey: storageKey))
    }

    static func decode(_ bytes: Data?) -> SMSReceptionAttempt? {
        guard let bytes, bytes.count <= maximumBytes,
              let attempt = try? JSONDecoder().decode(SMSReceptionAttempt.self, from: bytes),
              attempt.attemptedAt.timeIntervalSince1970.isFinite,
              attempt.finishedAt?.timeIntervalSince1970.isFinite ?? true,
              (0...4001).contains(attempt.bodyLength),
              metadata(attempt.appVersion) == attempt.appVersion,
              metadata(attempt.appBuild) == attempt.appBuild else { return nil }
        return attempt
    }

    private static func metadata(_ value: String?) -> String {
        guard let value, !value.isEmpty,
              value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return "unknown" }
        return String(value.prefix(32))
    }

    private static func persist(_ attempt: SMSReceptionAttempt, defaults: UserDefaults) {
        guard let bytes = try? JSONEncoder().encode(attempt), bytes.count <= maximumBytes else { return }
        defaults.set(bytes, forKey: storageKey)
    }
}
