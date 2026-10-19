import SwiftUI
import PDFKit

struct CareerApplicationView: View {
    @ObservedObject var client: CareerAssistantClient
    let applicationID: String
    @State private var review: CareerAssistantJSON?
    @State private var confirmed = false
    @State private var submitting = false
    @State private var note = ""
    @State private var loadError: String?
    private var current: CareerAssistantJSON { client.snapshot["applications"].array.first { $0.id == applicationID } ?? .null }
    private var value: CareerAssistantJSON { review ?? current }
    static func stateName(_ state: String) -> String { ["draft": "待审核", "approved": "已审核，等待电脑处理", "executing": "执行中", "unknown": "结果不明，需核查", "submitted": "已正式提交", "greeting_sent": "已打招呼", "resume_sent": "已发送简历", "interview": "面试", "offer": "已获得 Offer", "rejected": "未通过", "cancelled": "已取消"][state] ?? state }
    var body: some View {
        List {
            Section("本次申请") {
                Text(value["company"].display + " · " + value["jobTitle"].display).font(.headline)
                Text(Self.stateName(current["state"].string))
                Text("将执行：\(["greeting": "打招呼", "send_resume": "发送简历", "submit": "正式提交"][value["action"].string] ?? "待确认")")
                if let url = URL(string: value["url"].string) { Link("查看原始岗位", destination: url) }
                Text(current["message"].string).font(.caption).foregroundStyle(.secondary)
            }
            Section("电脑准备的材料 · v\(value["materialVersion"].int)") {
                Text(value["materialTitle"].display)
                DisclosureGroup("查看材料全文") { Text(value["materialContent"].string).textSelection(.enabled) }
                if !value["attachment"]["name"].string.isEmpty {
                    Text("附件：" + value["attachment"]["name"].string)
                    if let data = Data(base64Encoded: value["material"]["attachment"]["base64"].string), !data.isEmpty {
                        NavigationLink("预览本次 PDF 附件") { CareerPDFPreview(data: data).navigationTitle(value["attachment"]["name"].string) }
                    } else { Text("连接电脑后可读取对应版本的 PDF 预览。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("将填写的内容") { ForEach(value["fields"].dictionary.keys.sorted(), id: \.self) { key in LabeledContent(key, value: value["fields"][key].display) }; if value["fields"].dictionary.isEmpty { Text("本次没有附加字段") } }
            if ["draft", "approved"].contains(current["state"].string) {
                Section("审核") {
                    if let loadError { Text(loadError).foregroundStyle(.orange) }
                    if review != nil && !value["valid"].bool { Text("岗位或材料已变化，请在电脑重新准备审核单。").foregroundStyle(.orange) }
                    Toggle("已核对岗位、材料、附件和填写内容", isOn: $confirmed).disabled(!client.online || review == nil || !value["valid"].bool)
                    Button(submitting ? "正在确认…" : "批准这份材料与操作") {
                        submitting = true
                        Task { _ = await client.send("applications/\(applicationID)/approve", body: ["confirmed": true, "reviewHash": value["reviewHash"].string]); confirmed = false; submitting = false }
                    }.disabled(!client.online || !confirmed || !value["valid"].bool || submitting).accessibilityIdentifier("career-approve")
                    TextField("需要修改的地方", text: $note, axis: .vertical)
                    Button("退回电脑修改") {
                        submitting = true
                        Task { _ = await client.send("applications/\(applicationID)/request-changes", body: ["reviewHash": value["reviewHash"].string, "note": note]); confirmed = false; submitting = false }
                    }.disabled(!client.online || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting || review == nil)
                    Text("批准绑定当前材料和表单版本。执行由电脑完成；来源未通过验证时需本人到原站操作。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("申请结果") {
                if !current["receipt"].string.isEmpty { Text(current["receipt"].string) }
                NavigationLink("记录跟进与面试") { CareerTrackingEditor(client: client, jobID: current["jobID"].string) }
                if let message = client.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }.navigationTitle("材料审核").navigationBarTitleDisplayMode(.inline)
            .task(id: current["reviewHash"].string) {
                confirmed = false; review = nil
                guard client.online else { loadError = "当前为缓存，连接电脑核对版本后才能批准。"; return }
                do { review = try await client.request("applications/\(applicationID)/review"); loadError = nil } catch { loadError = "本次审核内容未能在线核对，请稍后重试。" }
            }
            .onChange(of: client.online) { _, _ in confirmed = false }
    }
}

struct CareerPDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view }
    func updateUIView(_ view: PDFView, context: Context) {}
}
