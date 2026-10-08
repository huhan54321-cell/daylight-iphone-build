import SwiftUI

struct SMSReceptionDiagnosticsView: View {
    @AppStorage(SMSReceptionDiagnostics.storageKey) private var diagnosticData = Data()
    @State private var expanded = SMSReceptionDiagnosticsView.captureExpanded
    private var latest: SMSReceptionAttempt? { SMSReceptionDiagnostics.decode(diagnosticData) }
    private static var captureExpanded: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--capture-sms-diagnostics")
        #else
        return false
        #endif
    }

    var body: some View {
        DisclosureGroup("最近银行接收", isExpanded: $expanded) {
            if let attempt = latest {
                LabeledContent("调用时间", value: attempt.attemptedAt.formatted(.dateTime.year().month().day().hour().minute().second()))
                LabeledContent("来源", value: (attempt.origin ?? .sms).label)
                LabeledContent("结果", value: attempt.outcome.label.replacingOccurrences(of: "短信", with: attempt.origin == .icbcNotification ? "通知" : "短信"))
                LabeledContent("阶段", value: attempt.stage.label)
                if let problem = attempt.problem { Text(problem.summary.replacingOccurrences(of: "短信", with: attempt.origin == .icbcNotification ? "通知" : "短信")).font(.subheadline) }
                Text("版本 \(attempt.appVersion) (\(attempt.appBuild)) · 正文长度 \(attempt.bodyLength > 4000 ? "超过 4000" : String(attempt.bodyLength))")
                    .font(.caption).foregroundStyle(.secondary)
                if let category = attempt.errorCategory, let code = attempt.errorCode {
                    Text("诊断代码：\(category.label) \(code)").font(.caption).textSelection(.enabled)
                }
            } else {
                Text("尚无接收记录。调用「接收工行动账通知」或「接收工行短信」后，这里会显示接收结果。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("只在手机保留最近一次调用的诊断信息，不含消息正文。快捷指令未调用此操作或运行中断时，状态可能不会更新。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
