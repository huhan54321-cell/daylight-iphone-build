import SwiftUI
import UniformTypeIdentifiers

struct CareerAssistantJobView: View {
    @ObservedObject var client: CareerAssistantClient
    let jobID: String
    let profileID: String
    @State private var materialID = ""
    @State private var action = "submit"
    @State private var fields = "{}"
    @State private var analysis: CareerAssistantJSON?
    @State private var analyzing = false
    private var job: CareerAssistantJSON { client.snapshot["jobs"].array.first { $0.id == jobID } ?? .null }
    private var match: CareerAssistantJSON { job["matches"].array.first { $0["profileID"].string == profileID } ?? .null }
    var body: some View {
        Form {
            Section { Text(job["title"].string).font(.headline); Text("\(job["company"].display) · \(job["city"].display)"); Text("来源：\(job["sourceName"].display)；最近检查：\(job["checkedAt"].display)").font(.caption); if let url = URL(string: job["url"].string) { Link("查看原始岗位", destination: url) } }
            Section("匹配理由") { ForEach(match["reasons"].strings, id: \.self) { Text($0) } }
            Section("缺口与待确认条件") { ForEach(match["gaps"].strings + match["unknown"].strings, id: \.self) { Text($0).foregroundStyle(.secondary) } }
            Section("岗位正文") { Text(job["description"].display).textSelection(.enabled); ForEach(job["requirements"].strings, id: \.self) { Text($0) } }
            Section("准备申请") {
                Button(job["followUp"]["saved"].bool ? "取消收藏" : "收藏岗位") { Task { _ = await client.send("jobs/\(jobID)/followup", body: ["saved": !job["followUp"]["saved"].bool]) } }.disabled(!client.online)
                Picker("使用材料", selection: $materialID) { Text("选择材料").tag(""); ForEach(client.snapshot["materials"].array) { Text("\($0["title"].string) · v\($0["version"].int)").tag($0.id) } }
                Picker("操作", selection: $action) { Text("打招呼").tag("greeting"); Text("发送简历").tag("send_resume"); Text("正式提交").tag("submit") }
                Text("填写准备提交的字段（JSON 文本）；未验证的站点仍需到原页核对和填写。").font(.caption)
                TextEditor(text: $fields).frame(minHeight: 90).font(.system(.caption, design: .monospaced))
                Button("生成审核单") {
                    Task {
                        guard let data = fields.data(using: .utf8), let form = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { client.message = "字段须为 JSON 对象，字段值为文本。"; return }
                        _ = await client.send("applications", body: ["jobID": jobID, "materialID": materialID, "action": action, "fields": form])
                    }
                }.disabled(!client.online || materialID.isEmpty)
                ForEach(client.snapshot["applications"].array.filter { $0["jobID"].string == jobID }) { app in NavigationLink("查看审核与申请记录") { CareerApplicationView(client: client, applicationID: app.id) } }
            }
            Section("Codex 辅助分析") {
                Button(analyzing ? "分析中…" : "分析匹配与材料修改建议") {
                    analyzing = true
                    Task { var body: [String: Any] = ["jobID": jobID, "profileID": profileID]; if !materialID.isEmpty { body["materialID"] = materialID }; analysis = await client.send("ai", body: body); analyzing = false }
                }.disabled(!client.online || analyzing)
                if let analysis { Text(analysis["summary"].string); ForEach(analysis["suggestions"].strings, id: \.self) { Text($0) }; Text("建议需要本人核实，不会自动改写简历或提交。").font(.caption).foregroundStyle(.secondary) }
            }
            if let message = client.message { Text(message).foregroundStyle(.orange) }
        }.navigationTitle("岗位详情")
    }
}

struct CareerMaterialEditor: View {
    @ObservedObject var client: CareerAssistantClient
    let original: CareerAssistantJSON
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var confirmed = false
    @State private var importing = false
    @State private var attachment: [String: Any]?
    @State private var versions: [CareerAssistantJSON] = []
    private var changes: [String] {
        let before = Set(original["content"].string.components(separatedBy: .newlines).filter { !$0.isEmpty })
        let after = Set(content.components(separatedBy: .newlines).filter { !$0.isEmpty })
        return before.subtracting(after).sorted().map { "− " + $0 } + after.subtracting(before).sorted().map { "+ " + $0 }
    }
    var body: some View {
        Form {
            Section("材料内容") { TextField("名称，例如机器人实习简历", text: $title); TextEditor(text: $content).frame(minHeight: 260); Toggle("内容仅包含我的真实经历与能力", isOn: $confirmed) }
            Section("简历附件") { Text(attachment?["name"] as? String ?? original["attachment"]["name"].display); Button("选择 PDF（最大 2 MB）") { importing = true } }
            if !original.id.isEmpty { Section("相对当前版本的变化") { ForEach(Array(changes.enumerated()), id: \.offset) { Text($0.element).font(.caption) }; if changes.isEmpty { Text("正文没有变化") } } }
            Section { Button("保存新版本") { Task { var body: [String: Any] = ["title": title, "content": content, "confirmedFacts": confirmed]; if !original.id.isEmpty { body["id"] = original.id }; if let attachment { body["attachment"] = attachment }; if await client.send("materials", body: body) != nil { dismiss() } } }.disabled(!client.online || !confirmed || title.isEmpty || content.isEmpty); if let message = client.message { Text(message).foregroundStyle(.orange) } }
            if !versions.isEmpty { Section("历史版本") { ForEach(versions) { version in DisclosureGroup("v\(version["version"].int) · \(version["updatedAt"].display)") { Text(version["content"].string).textSelection(.enabled) } } } }
        }.navigationTitle(original.id.isEmpty ? "新增材料" : "编辑材料")
            .onAppear { title = original["title"].string; content = original["content"].string }
            .task { if !original.id.isEmpty, client.online { versions = (try? await client.request("materialVersions/" + original.id))?.array ?? [] } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let bytes = try Data(contentsOf: url); guard bytes.count <= 2_097_152 else { throw AppFailure.message("PDF 不能超过 2 MB") }; attachment = ["name": url.lastPathComponent, "base64": bytes.base64EncodedString()] }
                catch { client.message = error.localizedDescription }
            }
    }
}

struct CareerProfileEditor: View {
    @ObservedObject var client: CareerAssistantClient
    let original: CareerAssistantJSON
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directions = ""
    @State private var cities = ""
    @State private var skills = ""
    @State private var year = ""
    @State private var days = ""
    @State private var months = ""
    @State private var start = ""
    @State private var enabled = true
    private func split(_ value: String) -> [String] { value.components(separatedBy: CharacterSet(charactersIn: "，,、\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var body: some View {
        Form {
            Section("求职方向") { TextField("档案名称", text: $name); TextField("方向，以逗号分隔", text: $directions); TextField("优先城市", text: $cities); TextField("真实技能", text: $skills); Toggle("纳入每日发现", isOn: $enabled) }
            Section("实习条件（可留空）") { TextField("毕业年份", text: $year).keyboardType(.numberPad); TextField("每周可到岗天数", text: $days).keyboardType(.numberPad); TextField("可实习月数", text: $months).keyboardType(.numberPad); TextField("到岗日期 YYYY-MM-DD", text: $start) }
            Button("保存目标") { Task { let body: [String: Any] = ["id": original.id.isEmpty ? UUID().uuidString.lowercased() : original.id, "name": name, "directions": split(directions), "cities": split(cities), "skills": split(skills), "graduationYear": year, "days": days, "months": months, "startDate": start, "enabled": enabled]; if await client.send("profiles", body: body) != nil { dismiss() } } }.disabled(!client.online || name.isEmpty || directions.isEmpty)
            if let message = client.message { Text(message).foregroundStyle(.orange) }
        }.navigationTitle("目标档案").onAppear {
            name = original["name"].string; directions = original["directions"].strings.joined(separator: "、"); cities = original["cities"].strings.joined(separator: "、"); skills = original["skills"].strings.joined(separator: "、")
            year = original["graduationYear"].int == 0 ? "" : String(original["graduationYear"].int); days = original["days"].int == 0 ? "" : String(original["days"].int); months = original["months"].int == 0 ? "" : String(original["months"].int); start = original["startDate"].string; enabled = original.id.isEmpty || original["enabled"].bool
        }
    }
}

struct CareerApplicationView: View {
    @ObservedObject var client: CareerAssistantClient
    let applicationID: String
    @State private var confirmed = false
    @State private var status = "submitted"
    @State private var receipt = ""
    @State private var interview = Date()
    @State private var newFields = "{}"
    @State private var sending = false
    private var application: CareerAssistantJSON { client.snapshot["applications"].array.first { $0.id == applicationID } ?? .null }
    static func stateName(_ state: String) -> String { ["draft": "待审核", "approved": "已审核", "executing": "执行中", "unknown": "结果不明，需核查", "submitted": "已正式提交", "greeting_sent": "已打招呼", "resume_sent": "已发送简历", "interview": "面试", "offer": "已获得 Offer", "rejected": "未通过", "cancelled": "已取消"][state] ?? state }
    var body: some View {
        Form {
            Section("本次审核内容") {
                Text("\(application["company"].display) · \(application["jobTitle"].display)")
                Text("操作：\(["greeting": "打招呼", "send_resume": "发送简历", "submit": "正式提交"][application["action"].string] ?? "待确认")")
                Text("材料：\(application["materialTitle"].display) · v\(application["materialVersion"].int)")
                Text("附件：\(application["attachment"]["name"].display)")
                DisclosureGroup("查看本次材料全文") { Text(application["materialContent"].string).textSelection(.enabled) }
                ForEach(application["fields"].dictionary.keys.sorted(), id: \.self) { key in LabeledContent(key, value: application["fields"][key].display) }
                Text(Self.stateName(application["state"].string)).font(.headline)
                Text(application["message"].string).font(.caption).foregroundStyle(.secondary)
            }
            if ["draft", "approved"].contains(application["state"].string) {
                Section("更新待提交内容") {
                    Text("材料或岗位更新后，请重新生成审核单。字段须为 JSON 文本对象。").font(.caption)
                    TextEditor(text: $newFields).frame(minHeight: 80)
                    Button("使用最新材料重新生成审核单") {
                        Task { guard let data = newFields.data(using: .utf8), let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { client.message = "字段格式无效"; return }; confirmed = false; _ = await client.send("applications", body: ["id": applicationID, "jobID": application["jobID"].string, "materialID": application["materialID"].string, "fields": fields, "action": application["action"].string]) }
                    }.disabled(!client.online)
                }
                Section {
                    Toggle("已核对岗位、材料、附件和字段", isOn: $confirmed)
                    Button("确认本次审核内容") { Task { _ = await client.send("applications/\(applicationID)/approve", body: ["confirmed": true, "reviewHash": application["reviewHash"].string]); confirmed = false } }.disabled(!client.online || !confirmed)
                    if application["capability"]["submit"].bool {
                        Button(sending ? "执行中…" : "执行已批准操作") { sending = true; Task { _ = await client.send("applications/\(applicationID)/execute"); sending = false } }.disabled(!client.online || application["state"].string != "approved" || sending)
                    }
                }
            }
            Section("原页处理与跟踪") {
                if let url = URL(string: application["url"].string) { Link("打开原始岗位", destination: url) }
                Picker("本人核实的状态", selection: $status) { ForEach(["greeting_sent", "resume_sent", "submitted", "unknown", "interview", "offer", "rejected", "cancelled"], id: \.self) { Text(Self.stateName($0)).tag($0) } }
                TextField("回执或核查说明", text: $receipt, axis: .vertical)
                if status == "interview" { DatePicker("面试时间", selection: $interview) }
                Button("保存本人核实的结果") { Task { var body: [String: Any] = ["state": status, "receipt": receipt]; if status == "interview" { body["interviewAt"] = ISO8601DateFormatter().string(from: interview) }; _ = await client.send("applications/\(applicationID)/status", body: body) } }.disabled(!client.online || application["state"].string == "executing")
                Text(application["receipt"].string).font(.caption)
            }
            if let message = client.message { Text(message).foregroundStyle(.orange) }
        }.navigationTitle("审核与申请跟踪").onAppear {
            receipt = application["receipt"].string
            if let data = try? JSONEncoder().encode(application["fields"]), let text = String(data: data, encoding: .utf8) { newFields = text }
        }.onChange(of: application["reviewHash"].string) { _, _ in confirmed = false }
    }
}
