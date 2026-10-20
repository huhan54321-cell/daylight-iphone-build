import SwiftUI

struct CareerAssistantReportView: View {
    @ObservedObject var client: CareerAssistantClient
    let report: CareerAssistantJSON
    @State private var full: CareerAssistantJSON?
    private var value: CareerAssistantJSON { full ?? client.report(report.id) ?? report }
    var body: some View {
        List {
            Section { Text(value["message"].string); Text("范围：\(value["startDate"].display) — \(value["endDate"].display)"); Text("实际读取 \(value["inspected"].int) 篇；关键词：\(value["keywords"].strings.joined(separator: "、"))").font(.caption); Text(value["scopeNote"].string).font(.caption).foregroundStyle(.secondary) }
            Section(value.dictionary["leads"] == nil ? "优先线索（摘要缓存）" : "本轮全部相关线索") {
                ForEach(value.dictionary["leads"] == nil ? value["priority"].array : value["leads"].array) { lead in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink(lead["title"].string) { CareerAssistantLeadView(client: client, lead: lead) }
                        Text(lead["reason"].string).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        CareerSourceActions(url: lead["url"].string, sourceID: "xiaohongshu", noteID: lead.id, title: lead["title"].string, compact: true)
                    }
                }
            }
            if !value["closedIDs"].array.isEmpty { Section("本轮关闭") { ForEach(value["closedIDs"].strings, id: \.self) { Text($0) } } }
        }.navigationTitle("招聘线索报告").task { full = await client.loadReport(report.id) }
    }
}

struct CareerAssistantLeadView: View {
    @ObservedObject var client: CareerAssistantClient
    let lead: CareerAssistantJSON
    private var current: CareerAssistantJSON { client.snapshot["leads"].array.first { $0.id == lead.id } ?? lead }
    var body: some View {
        List {
            Section {
                Text(current["title"].string).font(.headline)
                CareerSourceActions(url: current["url"].string, sourceID: "xiaohongshu", noteID: current.id, title: current["title"].string)
                Text(current["reason"].string); Text("发布日期：\(current["publishedDate"].display)")
            }
            Section("原帖明确提及") {
                LabeledContent("公司／团队", value: current["company"].display)
                LabeledContent("地点", value: current["cities"].strings.isEmpty ? "未提及" : current["cities"].strings.joined(separator: "、"))
                LabeledContent("方向", value: current["directions"].strings.joined(separator: "、"))
                ForEach(current["conditions"].strings, id: \.self) { Text($0) }
            }
            Section {
                Button(current["saved"].bool ? "取消收藏" : "收藏") { Task { await client.update(kind: "leads", id: lead.id, patch: ["saved": !current["saved"].bool]) } }
                Button("标为已读") { Task { await client.update(kind: "leads", id: lead.id, patch: ["read": true]) } }
                Button("忽略这条线索") { Task { await client.update(kind: "leads", id: lead.id, patch: ["ignored": true]) } }
                Button("转为待核查机会") { Task { _ = await client.send("leads/\(lead.id)/opportunity") } }.disabled(!client.online || !current["opportunityID"].string.isEmpty)
            }
            Section { Text("首次发现：\(current["firstSeenAt"].display)"); Text("最近检查：\(current["checkedAt"].display)") }.font(.caption)
        }.navigationTitle("招聘线索")
    }
}

struct CareerOpportunityView: View {
    @ObservedObject var client: CareerAssistantClient
    let opportunity: CareerAssistantJSON
    @State private var jobID = ""
    var body: some View { Form { Text(opportunity["title"].string); Picker("关联正式岗位", selection: $jobID) { Text("请选择").tag(""); ForEach(client.snapshot["jobs"].array) { Text("\($0["company"].string) · \($0["title"].string)").tag($0.id) } }; Button("确认关联") { Task { _ = await client.send("opportunities/\(opportunity.id)/link", body: ["jobID": jobID]) } }.disabled(!client.online || jobID.isEmpty); Text("关联只整理信息，不触发投递。").font(.caption) }.navigationTitle("待核查机会") }
}
