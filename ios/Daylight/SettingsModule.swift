import SwiftUI
import UniformTypeIdentifiers

struct SettingsModule: View {
    @EnvironmentObject private var store: AssistantStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("summaryNotifications") private var notifications = false
    @State private var exporting = false
    @State private var importing = false
    @State private var document: JSONBackupDocument?
    @State private var notificationBusy = false
    @State private var plannerSettings = false
    @State private var diagnosticCapture = false
    private var backupName: String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return "日常备份-\(formatter.string(from: Date()))" }
    var body: some View {
        SoftCard { Text("日常").font(.largeTitle.weight(.semibold)); Text("把生活，轻轻收好。").foregroundStyle(.secondary); Text("0.3.9 · iPhone 个人版").font(.caption).foregroundStyle(.secondary) }
        ModuleSection(title: "计划助手") {
            SoftCard {
                Button("配置智能规划", systemImage: "sparkles") { plannerSettings = true }
                Text("设置模型接口、高德 Key、常用出发地和出行偏好。密钥保存在手机钥匙串，备份只包含计划与偏好。").font(.caption).foregroundStyle(.secondary)
            }
        }
        ModuleSection(title: "外观与提醒") {
            SoftCard {
                Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                Toggle("周报与月报提醒", isOn: Binding(get: { notifications }, set: { enabled in Task { await configureNotifications(enabled) } })).disabled(notificationBusy)
                Text("每周一和每月 1 日晚 20:00 提醒查看汇总。").font(.caption).foregroundStyle(.secondary)
            }
        }
        ModuleSection(title: "银行记账") {
            SoftCard {
                Toggle("自动保存明确消费与充值转移", isOn: Binding(get: { store.data.autoRecordSMS }, set: { store.setAutomaticSMS($0) }))
                Text("收入、退款、用途不明的转账及疑似重复仍需确认。充值微信零钱或支付宝余额属于账户转移。").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("设置动账通知自动接收（首选）") {
                    Text("需要系统快捷指令支持「收到 App 通知」自动化（iOS 27）。选择工商银行 App，标题包含「动账通知」，选择立即运行。添加日常的「接收工行动账通知」操作，通知标题传入 Title，通知正文传入 Body；通知编号留空。").font(.subheadline)
                    Text("必须传入实际通知标题，不能固定填动账通知。App 会再次核对标题与完整交易字段，跳过活动通知；不能读取通知历史。配置成功后停用旧短信自动化，避免同一笔在两个入口接收。").font(.caption).foregroundStyle(.secondary)
                    Text("当前 iOS 18.2.1 没有此触发器。升级后的工行真实推送、锁屏与 Apple Watch 通知路由仍需手机验证。请先设置工行卡起始余额；通知没有余额时按收支估算。").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("设置短信自动接收") {
                    Text("打开快捷指令 → 自动化 → 信息，发件人 95588、包含工商银行，选择立即运行。添加日常的「接收工行短信」操作，把短信正文传给它，发件人填 95588；编号可使用已有格式化日期变量，也可留空由 App 生成。").font(.subheadline)
                    Text("已配置电脑接收版时，用此操作替换「获取 URL 内容」。第一次安装后先打开一次 App。之后在手机本地保存，无需配对码或电脑。").font(.caption).foregroundStyle(.secondary)
                }
                Text("接收只覆盖实际传入的新消息。漏记交易可补录动账通知、短信或微信动账截图。").font(.caption).foregroundStyle(.secondary)
                SMSReceptionDiagnosticsView()
            }
        }
        ModuleSection(title: "备份与恢复") {
            SoftCard {
                Button("导出完整备份", systemImage: "square.and.arrow.up") {
                    do { document = JSONBackupDocument(bytes: try store.exportBackup()); exporting = true } catch { store.message = error.localizedDescription }
                }
                Button("导入与合并备份", systemImage: "square.and.arrow.down") { importing = true }
                Text("备份含账本、计划、运动和求职画像，请保存在自己的私人位置。导入会合并记录；若手机已有画像，会保留手机上的版本。也支持电脑短信账本导出的 JSON。").font(.caption).foregroundStyle(.secondary)
            }
        }
        SoftCard { Label("记录保存在手机本地", systemImage: "iphone"); Text("苹果日历、提醒事项和健康由你主动授权。使用智能规划时，需求文本会发送给你配置的模型服务，地点和路线请求发送给高德。").font(.caption).foregroundStyle(.secondary) }
            .sheet(isPresented: $plannerSettings) { NavigationStack { PlannerSettingsView().environmentObject(store) } }
            .sheet(isPresented: $diagnosticCapture) {
                NavigationStack { List { SMSReceptionDiagnosticsView() }.navigationTitle("银行接收诊断") }
            }
            .task {
                #if DEBUG && targetEnvironment(simulator)
                diagnosticCapture = ProcessInfo.processInfo.arguments.contains("--capture-sms-diagnostics")
                #endif
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: backupName) { result in
                switch result { case .success: store.message = "备份已导出"; case .failure(let error): store.message = "备份导出未完成：\(error.localizedDescription)" }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try store.importBackup(Data(contentsOf: url))
                } catch { store.message = "导入未完成，已有记录保留：\(error.localizedDescription)" }
            }
    }
    private func configureNotifications(_ enabled: Bool) async {
        guard !notificationBusy else { return }; notificationBusy = true; defer { notificationBusy = false }
        do { try await SummaryNotifications.configure(enabled: enabled); notifications = enabled }
        catch { store.message = error.localizedDescription }
    }
}
