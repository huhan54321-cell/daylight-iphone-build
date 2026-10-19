import SwiftUI

struct CareerConnectionView: View {
    @ObservedObject var client: CareerAssistantClient
    @AppStorage("career-reminders-enabled") private var reminders = false
    @State private var address = ""
    @State private var token = ""
    @State private var saving = false
    var body: some View {
        Form {
            Section("连接你的电脑") {
                TextField("HTTPS 服务地址", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("career-service-url")
                SecureField("访问令牌", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("career-service-token")
                Button(saving ? "正在连接…" : "保存并连接") { saving = true; Task { await client.saveConnection(CareerAPIConfiguration(baseURL: address, token: token)); saving = false } }.disabled(saving).accessibilityIdentifier("career-service-save")
                Text("手机和电脑的 Tailscale 需保持连接。电脑离线时，已缓存的岗位和报告仍可阅读，收藏、跟进及面试先保存在手机。").font(.caption).foregroundStyle(.secondary)
                if let message = client.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            Section("提醒与同步") {
                Toggle("跟进与面试提醒", isOn: Binding(get: { reminders }, set: { enabled in Task { do { try await CareerNotifications.configure(enabled: enabled, snapshot: client.snapshot); reminders = enabled } catch { client.message = error.localizedDescription } } }))
                Text("面试前 30 分钟提醒；跟进使用你指定的时间。近期提醒会保存在手机，电脑离线也能触发。").font(.caption).foregroundStyle(.secondary)
                NavigationLink("待同步修改 · \(client.pending.count)") { CareerSyncView(client: client) }
                NavigationLink("来源状态与搜索范围") { CareerSourceView(client: client) }
            }
            Section("求职目标") { ForEach(client.snapshot["profiles"].array) { p in NavigationLink(p["name"].string) { CareerProfileEditor(client: client, original: p) } } }
            Section("电脑工作台") {
                Text("在电脑浏览器打开服务地址后的 /career。材料版本、附件、申请准备与投递执行集中在工作台。")
                Text("每天北京时间 09:00 刷新，电脑稍后启动时补做当日任务。手机的同步按钮只读取已有结果。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("求职设置").onAppear { address = client.connection.baseURL; token = client.connection.token }
    }
}

struct CareerSyncView: View {
    @ObservedObject var client: CareerAssistantClient
    var body: some View {
        List {
            if client.pending.isEmpty { ContentUnavailableView("全部修改已同步", systemImage: "checkmark.icloud") }
            ForEach(client.pending) { op in
                Section {
                    Text(client.snapshot[op.kind == "followups" ? "jobs" : "leads"].array.first { $0.id == op.targetID }?["title"].string ?? "求职记录")
                    if let conflict = op.conflict {
                        Text(conflict["message"].display).foregroundStyle(.orange)
                        ForEach(op.patch.dictionary.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading) { Text(["saved": "收藏", "stage": "阶段", "notes": "笔记", "nextAction": "下一步", "reminderAt": "提醒", "interview": "面试", "read": "已读", "ignored": "忽略"][key] ?? key).font(.headline); Text("手机：" + describe(op.patch[key])); Text("电脑：" + describe(conflict["current"][key])) }.font(.caption)
                        }
                        if conflict["state"].string == "conflict" {
                            Button("保留手机修改并同步") { Task { await client.resolve(op, usePhone: true) } }.disabled(!client.online)
                            Button("使用电脑内容", role: .destructive) { Task { await client.resolve(op, usePhone: false) } }.disabled(!client.online)
                        } else { Text("原修改保存在本机，请在电脑核查这条记录后重试。").font(.caption) }
                    } else { Text("已在手机保存，连接电脑后同步。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("待同步修改").toolbar { Button("重试同步") { Task { await client.retrySync() } }.disabled(client.busy) }
    }
    private func describe(_ value: CareerAssistantJSON) -> String {
        if value == .null { return "未设置" }
        if value.dictionary.isEmpty { return value.display }
        return "\(CareerDates.label(value["start"].string)) — \(CareerDates.label(value["end"].string)) \(value["location"].string) \(value["notes"].string)"
    }
}

struct CareerSourceView: View {
    @ObservedObject var client: CareerAssistantClient
    var body: some View {
        List {
            Section { Text("以下状态表示最近一次检查结果。未完成或需要验证时，不能据此判断没有招聘岗位。").font(.subheadline) }
            ForEach(client.snapshot["sources"].array) { source in
                Section(source["name"].string) {
                    Text(["ok": "检查完成", "partial": "部分完成", "login_required": "需在电脑登录", "blocked": "需在电脑完成验证", "error": "本轮未完成", "not_configured": "尚未配置", "not_checked": "尚未检查"][source["state"].string] ?? source["state"].display).font(.headline)
                    Text(source["message"].string).font(.subheadline)
                    Text("最近成功：\(CareerDates.label(source["lastSuccessAt"].string))").font(.caption).foregroundStyle(.secondary)
                    if !source["coverage"]["keywords"].strings.isEmpty { Text("检索词：" + source["coverage"]["keywords"].strings.joined(separator: "、")).font(.caption) }
                    Text(source["capabilities"]["submit"].bool ? "已验证辅助提交能力" : "自动投递尚不可用").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("最近任务") { ForEach(client.snapshot["tasks"].array.prefix(5)) { task in Text(task["message"].string).font(.caption) } }
        }.navigationTitle("来源状态")
    }
}
