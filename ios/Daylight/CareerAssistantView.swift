import SwiftUI
import UniformTypeIdentifiers

struct CareerAssistantView: View {
    @StateObject private var client: CareerAssistantClient
    @State private var section = "岗位库"
    @State private var query = ""
    @State private var profileID = ""
    @State private var migration: CareerAssistantJSON?
    @State private var backup: JSONBackupDocument?
    @State private var exporting = false
    @State private var restoring = false
    @State private var restoreDocument: CareerAssistantJSON?
    init(configuration: CareerAPIConfiguration) { _client = StateObject(wrappedValue: CareerAssistantClient(configuration: configuration)) }
    private var profiles: [CareerAssistantJSON] { client.snapshot["profiles"].array }
    private var selectedProfile: String { profileID.isEmpty ? profiles.first?.id ?? "" : profileID }
    var body: some View {
        List {
            Section {
                HStack { Label(client.online ? "电脑已连接" : "离线缓存", systemImage: client.online ? "network" : "tray"); Spacer(); if client.busy { ProgressView() } }
                if let message = client.message { Text(message).font(.caption).foregroundStyle(.orange) }
                Text("上次读取：\(client.snapshot["generatedAt"].display)").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(["岗位库", "招聘线索", "材料", "申请跟踪", "设置"], id: \.self) { name in
                        Button(name) { section = name }.buttonStyle(.bordered).tint(section == name ? .blue : .gray)
                    } }
                }
            }
            if section == "岗位库" { jobs }
            else if section == "招聘线索" { leads }
            else if section == "材料" { materials }
            else if section == "申请跟踪" { applications }
            else { settings }
        }.navigationTitle("个人求职助手").navigationBarTitleDisplayMode(.inline)
            .refreshable { await client.reload() }
            .task { await client.monitor() }
            .toolbar { Button { Task { await client.reload() } } label: { Image(systemName: "arrow.clockwise") }.disabled(client.busy) }
            .fileExporter(isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "求职助手备份") { if case .failure(let error) = $0 { client.message = error.localizedDescription } }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url); guard data.count <= 16_000_000 else { throw AppFailure.message("备份不能超过 16 MB") }
                    let value = try JSONDecoder().decode(CareerAssistantJSON.self, from: data)
                    guard value["schemaVersion"].int == 2 else { throw AppFailure.message("请选择求职助手 v2 备份") }; restoreDocument = value
                } catch { client.message = error.localizedDescription }
            }
    }
    private func matching(_ job: CareerAssistantJSON) -> CareerAssistantJSON { job["matches"].array.first { $0["profileID"].string == selectedProfile } ?? .null }
    private var visibleJobs: [CareerAssistantJSON] {
        client.snapshot["jobs"].array.filter { job in !["closed", "historical"].contains(job["status"].string) && (query.isEmpty || "\(job["title"].string) \(job["company"].string) \(job["description"].string)".localizedCaseInsensitiveContains(query)) }
            .sorted { matching($0)["score"].int > matching($1)["score"].int }
    }
    private var jobs: some View {
        Group {
            Section {
                Picker("求职目标", selection: $profileID) {
                    Text("默认目标").tag(""); ForEach(profiles) { Text($0["name"].string).tag($0.id) }
                }
                TextField("搜索公司、方向或岗位", text: $query)
                Button("发现新岗位与线索") { Task { _ = await client.send("refresh") } }.disabled(!client.online)
            }
            ForEach(["precise", "explore"], id: \.self) { lane in
                Section(lane == "precise" ? "精准推荐" : "拓展机会") {
                    ForEach(visibleJobs.filter { matching($0)["lane"].string == lane }) { job in
                        NavigationLink { CareerAssistantJobView(client: client, jobID: job.id, profileID: selectedProfile) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(job["title"].string).font(.headline)
                                Text("\(job["company"].display) · \(job["city"].display)").font(.subheadline)
                                Text(matching(job)["reasons"].strings.joined(separator: "；")).font(.caption).foregroundStyle(.secondary)
                                if job["followUp"]["saved"].bool { Label("已收藏", systemImage: "bookmark.fill").font(.caption) }
                            }
                        }
                    }
                }
            }
            if visibleJobs.isEmpty { Text("暂无岗位资料。可先在设置预览并迁移旧资料，再执行发现；来源状态可查看哪些网站尚未检查成功。").foregroundStyle(.secondary) }
        }
    }
    private var leads: some View {
        Group {
            Section("招聘线索报告") {
                ForEach(client.snapshot["reports"].array) { report in
                    NavigationLink { CareerAssistantReportView(client: client, report: report) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(report["title"].string)
                            Text(report["message"].string).font(.caption).foregroundStyle(.secondary)
                            if report["partial"].bool { Text("本轮部分完成／历史资料整理").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                if client.snapshot["reports"].array.isEmpty { Text("运行发现任务后，这里显示本轮新增和变化的招聘线索。") }
            }
            Section("收藏与未读线索") {
                ForEach(client.snapshot["leads"].array.filter { !$0["ignored"].bool && !["excluded", "closed"].contains($0["category"].string) && ($0["saved"].bool || !$0["read"].bool) }) { lead in
                    NavigationLink { CareerAssistantLeadView(client: client, lead: lead) } label: {
                        VStack(alignment: .leading) { Text(lead["title"].string); Text(lead["publishedDate"].string.isEmpty ? "发布日期未确认" : lead["publishedDate"].string).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("待核查机会") {
                ForEach(client.snapshot["opportunities"].array) { opportunity in
                    NavigationLink { CareerOpportunityView(client: client, opportunity: opportunity) } label: { Text(opportunity["title"].string) }
                }
            }
        }
    }
    private var materials: some View {
        Section("真实经历与简历版本") {
            NavigationLink("新增材料") { CareerMaterialEditor(client: client, original: .null) }.disabled(!client.online)
            ForEach(client.snapshot["materials"].array) { material in
                NavigationLink { CareerMaterialEditor(client: client, original: material) } label: { Text("\(material["title"].string) · v\(material["version"].int)") }
            }
        }
    }
    private var applications: some View {
        Section("申请记录与待办") {
            ForEach(client.snapshot["applications"].array) { application in
                NavigationLink { CareerApplicationView(client: client, applicationID: application.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(application["company"].string) · \(application["jobTitle"].string)")
                        Text(CareerApplicationView.stateName(application["state"].string)).font(.caption)
                        if !application["interviewAt"].string.isEmpty { Text("面试：\(application["interviewAt"].string)").font(.caption) }
                    }
                }
            }
            if client.snapshot["applications"].array.isEmpty { Text("从岗位详情选择材料，准备并审核本次申请。") }
        }
    }
    private var settings: some View {
        Group {
            Section("目标档案") {
                ForEach(profiles) { p in NavigationLink(p["name"].string) { CareerProfileEditor(client: client, original: p) } }
                NavigationLink("新增求职方向") { CareerProfileEditor(client: client, original: .null) }.disabled(!client.online)
            }
            Section("数据迁移与备份") {
                Button("预览旧岗位和小红书资料") { Task { do { migration = try await client.request("migration") } catch { client.message = error.localizedDescription } } }.disabled(!client.online)
                if let migration {
                    Text("可迁移 \(migration["jobs"].int) 个岗位、\(migration["notes"].int) 篇帖子；迁移前自动备份。")
                    if !migration["historyError"].string.isEmpty { Text(migration["historyError"].string).foregroundStyle(.orange) }
                    Button("确认迁移这份资料") { Task { _ = await client.send("migration", body: ["previewID": migration.id]); self.migration = nil } }.disabled(!client.online || migration["alreadyImported"].bool)
                }
                Button("导出电脑端完整求职备份") { Task { do { let value = try await client.request("export"); backup = JSONBackupDocument(bytes: try JSONEncoder().encode(value)); exporting = true } catch { client.message = error.localizedDescription } } }.disabled(!client.online)
                Button("选择求职备份恢复") { restoring = true }.disabled(!client.online)
                if let restoreDocument {
                    Text("将合并 \(restoreDocument["records"].array.count) 条记录；同 ID 内容会更新，恢复前备份当前数据库，历史批准失效。")
                    Button("确认恢复") { Task { if let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(restoreDocument)) as? [String: Any] { _ = await client.send("restore", body: object) }; self.restoreDocument = nil } }.disabled(!client.online)
                    Button("取消恢复") { self.restoreDocument = nil }
                }
            }
            Section("来源状态") {
                ForEach(client.snapshot["sources"].array) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source["name"].string).font(.headline)
                        Text(source["message"].string).font(.caption)
                        Text("上次成功：\(source["lastSuccessAt"].display)").font(.caption).foregroundStyle(.secondary)
                        if ["blocked", "login_required"].contains(source["state"].string) {
                            Button("电脑已处理验证，恢复来源") { Task { _ = await client.send("refresh", body: ["sourceID": source.id == "xiaohongshu" ? "xiaohongshu" : "jobs", "resumeSources": true]) } }.disabled(!client.online)
                        }
                    }
                }
            }
            Section("运行状态") {
                Text("每日北京时间 09:00 发现新机会；电脑上线后当日补做一次。")
                Text(client.snapshot["ai"]["message"].string).font(.caption)
                ForEach(client.snapshot["tasks"].array.prefix(5)) { Text($0["message"].string).font(.caption) }
                Text("远程连接使用电脑 Tailscale 的 HTTPS 地址和个人服务令牌。在上一级‘更新设置’填写。电脑离线时只能读缓存。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CareerAssistantReportView: View {
    @ObservedObject var client: CareerAssistantClient
    let report: CareerAssistantJSON
    @State private var full: CareerAssistantJSON?
    private var value: CareerAssistantJSON { full ?? report }
    var body: some View {
        List {
            Section { Text(value["message"].string); Text("范围：\(value["startDate"].display) — \(value["endDate"].display)"); Text("实际读取 \(value["inspected"].int) 篇；关键词：\(value["keywords"].strings.joined(separator: "、"))").font(.caption); Text(value["scopeNote"].string).font(.caption).foregroundStyle(.secondary) }
            Section(full == nil ? "优先线索（缓存）" : "本轮全部相关线索") {
                ForEach(full == nil ? value["priority"].array : value["leads"].array) { lead in NavigationLink(lead["title"].string) { CareerAssistantLeadView(client: client, lead: lead) } }
            }
            if !value["closedIDs"].array.isEmpty { Section("本轮关闭") { ForEach(value["closedIDs"].strings, id: \.self) { Text($0) } } }
        }.navigationTitle("招聘线索报告").task { if client.online { full = try? await client.request("reports/" + report.id) } }
    }
}

struct CareerAssistantLeadView: View {
    @ObservedObject var client: CareerAssistantClient
    let lead: CareerAssistantJSON
    private var current: CareerAssistantJSON { client.snapshot["leads"].array.first { $0.id == lead.id } ?? lead }
    var body: some View {
        List {
            Section { Text(current["title"].string).font(.headline); Text(current["reason"].string); Text("发布日期：\(current["publishedDate"].display)"); Text("页面日期原文：\(current["dateText"].display)").font(.caption) }
            Section("原帖明确提及") {
                LabeledContent("公司／团队", value: current["company"].display)
                LabeledContent("地点", value: current["cities"].strings.isEmpty ? "未提及" : current["cities"].strings.joined(separator: "、"))
                LabeledContent("方向", value: current["directions"].strings.joined(separator: "、"))
                ForEach(current["conditions"].strings, id: \.self) { Text($0) }
            }
            Section {
                if let url = URL(string: current["url"].string), url.scheme == "https" { Link("打开小红书原帖", destination: url) }
                if let url = URL(string: current["canonicalURL"].string) { Link("原链接失效时尝试标准链接", destination: url) }
                Text("链接仍失效时，可在小红书搜索帖子标题。正文细节和联系方式请以原帖为准。").font(.caption).foregroundStyle(.secondary)
                Button(current["saved"].bool ? "取消收藏" : "收藏") { Task { _ = await client.send("leads/\(lead.id)", body: ["saved": !current["saved"].bool]) } }.disabled(!client.online)
                Button("标为已读") { Task { _ = await client.send("leads/\(lead.id)", body: ["read": true]) } }.disabled(!client.online)
                Button("忽略这条线索") { Task { _ = await client.send("leads/\(lead.id)", body: ["ignored": true]) } }.disabled(!client.online)
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
