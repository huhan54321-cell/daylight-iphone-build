import AppIntents
import Foundation

struct ReceiveBankSMSIntent: AppIntent {
    static var title: LocalizedStringResource = "接收工行短信"
    static var description = IntentDescription("接收信息自动化传入的工行交易正文，直接保存在手机本地。无需电脑、网络或支付账号。")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "短信正文") var body: String
    @Parameter(title: "发件人", default: "95588") var sender: String
    @Parameter(title: "短信编号") var requestID: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let attempt = SMSReceptionDiagnostics.begin(bodyLength: body.utf16.count)
        let result = try AssistantStore.shared.receiveSMS(body: body, sender: sender, requestID: requestID, diagnostic: attempt)
        return .result(value: result)
    }
}

struct ReceiveBankNotificationIntent: AppIntent {
    static var title: LocalizedStringResource = "接收工行动账通知"
    static var description = IntentDescription("接收工商银行 App 通知自动化传入的标题和正文。仅识别动账通知中的完整交易，跳过活动通知，直接在手机保存。")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "通知标题") var notificationTitle: String
    @Parameter(title: "通知正文") var body: String
    @Parameter(title: "通知编号") var requestID: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let attempt = SMSReceptionDiagnostics.begin(bodyLength: body.utf16.count, origin: .icbcNotification)
        let result = try AssistantStore.shared.receiveBankNotification(title: notificationTitle, body: body, requestID: requestID, diagnostic: attempt)
        return .result(value: result)
    }
}

struct DaylightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReceiveBankNotificationIntent(), phrases: ["用\(.applicationName)接收工行动账通知"], shortTitle: "接收工行动账通知", systemImageName: "bell.badge")
        AppShortcut(intent: ReceiveBankSMSIntent(), phrases: ["用\(.applicationName)接收工行短信"], shortTitle: "接收工行短信", systemImageName: "wallet.pass")
    }
}
