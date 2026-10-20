import SwiftUI

struct CareerAssistantJobView: View {
    @ObservedObject var client: CareerAssistantClient
    let jobID: String
    let profileID: String
    private var job: CareerAssistantJSON { client.snapshot["jobs"].array.first { $0.id == jobID } ?? .null }
    private var match: CareerAssistantJSON { job["matches"].array.first { $0["profileID"].string == profileID } ?? .null }
    var body: some View {
        List {
            Section {
                Text(job["title"].string).font(.title3.weight(.semibold))
                Text(job["company"].display)
                Text(job["location"].string.isEmpty ? job["city"].display : job["location"].string).font(.subheadline)
                CareerSourceActions(url: job["url"].string, sourceID: job["sourceID"].string, title: job["title"].string)
                HStack {
                    Button { Task { await client.update(id: jobID, patch: ["saved": !job["followUp"]["saved"].bool]) } } label: { Label(job["followUp"]["saved"].bool ? "已收藏" : "收藏", systemImage: job["followUp"]["saved"].bool ? "bookmark.fill" : "bookmark") }.buttonStyle(.bordered).disabled(client.saving).accessibilityIdentifier("career-save-job")
                    NavigationLink { CareerTrackingEditor(client: client, jobID: jobID) } label: { Label("记录跟进", systemImage: "checklist") }.buttonStyle(.bordered).accessibilityIdentifier("career-track-job")
                }
                if job["pendingSync"].bool { Text("修改已保存在手机，等待同步。").font(.caption).foregroundStyle(.secondary) }
                if !job["followUp"]["stage"].string.isEmpty { LabeledContent("阶段", value: job["followUp"]["stage"].string) }
                if !job["followUp"]["nextAction"].string.isEmpty { LabeledContent("下一步", value: job["followUp"]["nextAction"].string) }
            }
            Section("匹配与待确认") {
                ForEach(match["reasons"].strings, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.subheadline) }
                ForEach(match["gaps"].strings + match["unknown"].strings, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
                if match == .null { Text("这份岗位尚未按电脑端目标分析，请核对原始条件。").foregroundStyle(.secondary) }
            }
            Section("来源") {
                LabeledContent("来源", value: job["sourceName"].display)
                LabeledContent("最近检查", value: CareerDates.label(job["checkedAt"].string))
                LabeledContent("地点", value: job["location"].display)
                LabeledContent("薪资", value: job["salary"].display)
                if ["closed", "historical"].contains(job["status"].string) { Text("这是一份历史或已结束岗位，请先确认招聘有效性。").foregroundStyle(.orange) }
            }
            Section { DisclosureGroup("已保存的岗位内容") { Text(job["description"].display).textSelection(.enabled); ForEach(job["requirements"].strings, id: \.self) { Text($0) } } }
            if !client.snapshot["applications"].array.filter({ $0["jobID"].string == jobID }).isEmpty { Section("材料与申请") {
                ForEach(client.snapshot["applications"].array.filter { $0["jobID"].string == jobID }) { app in NavigationLink("\(CareerApplicationView.stateName(app["state"].string)) · \(app["materialTitle"].display)") { CareerApplicationView(client: client, applicationID: app.id) } }
                Text("在电脑工作台准备材料和填写申请；准备好后可在手机审核。收藏不会触发投递。").font(.caption).foregroundStyle(.secondary)
            } }
        }.navigationTitle("岗位详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct CareerTrackingEditor: View {
    static let stages = ["未投递", "准备材料", "已打招呼", "已发送简历", "已投递", "面试", "Offer", "未通过", "已结束"]
    @ObservedObject var client: CareerAssistantClient
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var stage = "未投递"
    @State private var notes = ""
    @State private var nextAction = ""
    @State private var remind = false
    @State private var reminder = Date().addingTimeInterval(86400)
    @State private var hasInterview = false
    @State private var start = Date().addingTimeInterval(86400)
    @State private var end = Date().addingTimeInterval(90000)
    @State private var location = ""
    @State private var interviewNotes = ""
    @State private var submitting = false
    @State private var editingBase: CareerAssistantJSON?
    @State private var initialValues: CareerAssistantJSON = .null
    @FocusState private var focusedField: String?
    private var job: CareerAssistantJSON { client.snapshot["jobs"].array.first { $0.id == jobID } ?? .null }
    private func values() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let interview: Any = hasInterview ? ["start": formatter.string(from: start), "end": formatter.string(from: end), "location": location, "notes": interviewNotes] : NSNull()
        return ["stage": stage, "notes": notes, "nextAction": nextAction, "reminderAt": remind ? formatter.string(from: reminder) as Any : NSNull(), "interview": interview]
    }
    var body: some View {
        Form {
            Section { Text(job["company"].display + " · " + job["title"].display); Picker("跟进阶段", selection: $stage) { ForEach(Self.stages, id: \.self) { Text($0) } }.accessibilityIdentifier("career-stage") }
            Section("下一步") {
                TextField("例如：等回复、准备一面", text: $nextAction).focused($focusedField, equals: "nextAction").submitLabel(.done).accessibilityIdentifier("career-next-action")
                TextField("跟进笔记", text: $notes, axis: .vertical).focused($focusedField, equals: "notes").lineLimit(3...8)
                Toggle("设置跟进提醒", isOn: $remind)
                if remind { DatePicker("提醒时间", selection: $reminder) }
            }
            Section("面试日程") {
                Toggle("安排面试，并加入计划", isOn: $hasInterview).accessibilityIdentifier("career-interview-toggle")
                if hasInterview {
                    DatePicker("开始", selection: $start).accessibilityIdentifier("career-interview-start")
                    DatePicker("结束", selection: $end)
                    TextField("地点或会议链接", text: $location).focused($focusedField, equals: "location").submitLabel(.done)
                    TextField("面试备注", text: $interviewNotes, axis: .vertical).focused($focusedField, equals: "interviewNotes")
                    Text("改期会更新同一条计划；关闭此开关会取消对应日程。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(submitting ? "正在保存…" : "保存跟进") {
                    submitting = true
                    Task {
                        let currentValues = values()
                        let encoded = (try? CareerAssistantJSON.from(currentValues)) ?? .null
                        let patch = currentValues.filter { encoded[$0.key] != initialValues[$0.key] }
                        let ok: Bool
                        if patch.isEmpty { ok = true }
                        else { ok = await client.update(id: jobID, patch: patch, editingBase: editingBase) }
                        submitting = false; if ok { dismiss() }
                    }
                }.disabled(submitting || client.saving || (hasInterview && (end <= start || end.timeIntervalSince(start) > 86400)) || notes.count > 4000 || nextAction.count > 200).accessibilityIdentifier("career-save-tracking")
                Text("先保存到手机，电脑连接后同步。材料审批需要在线完成。").font(.caption).foregroundStyle(.secondary)
                if let message = client.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }.navigationTitle("跟进与面试").scrollDismissesKeyboard(.interactively)
            .onSubmit { focusedField = nil }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if focusedField != nil { Button("完成输入") { focusedField = nil }.accessibilityIdentifier("career-dismiss-tracking-keyboard") }
                }
            }
            .onAppear {
            guard editingBase == nil else { return }
            let f = job["followUp"]
            stage = Self.stages.contains(f["stage"].string) ? f["stage"].string : "未投递"; notes = f["notes"].string; nextAction = f["nextAction"].string
            if let date = CareerDates.date(f["reminderAt"].string) { reminder = date; remind = true }
            if let date = CareerDates.date(f["interview"]["start"].string) { start = date; end = CareerDates.date(f["interview"]["end"].string) ?? date.addingTimeInterval(3600); hasInterview = true }
            location = f["interview"]["location"].string; interviewNotes = f["interview"]["notes"].string
            editingBase = f; initialValues = (try? CareerAssistantJSON.from(values())) ?? .null
        }
    }
}
