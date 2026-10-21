import SwiftUI

struct CareerAssistantView: View {
    @ObservedObject var client: CareerAssistantClient
    @State private var section = "机会"
    @State private var filter = "全部"
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var city = "全部城市"
    @State private var profileID = ""
    @State private var includeClosed = false
    @State private var sortOrder = "综合推荐"
    init(client: CareerAssistantClient) { self.client = client }
    init(configuration: CareerAPIConfiguration) { self.client = CareerAssistantClient(configuration: configuration) }
    private var profiles: [CareerAssistantJSON] { client.snapshot["profiles"].array }
    private var selectedProfile: String { profileID.isEmpty ? profiles.first?.id ?? "" : profileID }
    private func matching(_ job: CareerAssistantJSON) -> CareerAssistantJSON { job["matches"].array.first { $0["profileID"].string == selectedProfile } ?? .null }
    private var jobs: [CareerAssistantJSON] {
        client.snapshot["jobs"].array.filter { job in
            (includeClosed || filter == "收藏" || !["closed", "historical"].contains(job["status"].string)) &&
            (filter != "收藏" || job["followUp"]["saved"].bool) && (city == "全部城市" || job["city"].string == city) &&
            (query.isEmpty || "\(job["title"].string) \(job["company"].string) \(job["location"].string) \(job["description"].string)".localizedCaseInsensitiveContains(query))
        }.sorted {
            let left = matching($0), right = matching($1)
            let leftDate = left["freshnessAt"].string.isEmpty ? $0["checkedAt"].string : left["freshnessAt"].string
            let rightDate = right["freshnessAt"].string.isEmpty ? $1["checkedAt"].string : right["freshnessAt"].string
            if sortOrder == "综合推荐", left["score"].int != right["score"].int { return left["score"].int > right["score"].int }
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id < $1.id
        }
    }
    private var approvals: [CareerAssistantJSON] { client.snapshot["applications"].array.filter { $0["state"].string == "draft" } }
    private var following: [CareerAssistantJSON] { client.snapshot["jobs"].array.filter { let f = $0["followUp"]; return !["", "未投递", "已结束"].contains(f["stage"].string) || !f["nextAction"].string.isEmpty || f["interview"] != .null } }
    var body: some View {
        List {
            Section {
                connectionSummary
                DisclosureGroup("同步与检索详情") {
                    if let task = client.snapshot["tasks"].array.first {
                        Text(task["message"].string).font(.caption)
                        Text("最近检索：\(CareerDates.label(task["startedAt"].string))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("同步读取已有结果；查找新机会会让电脑启动检索。BOSS 仍需在电脑浏览后导入。").font(.caption).foregroundStyle(.secondary)
                    if let message = client.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("career-message") }
                    if !approvals.isEmpty { Button("\(approvals.count) 份材料待你审核") { section = "进度" } }
                }.font(.subheadline)
                Picker("求职内容", selection: $section) { ForEach(["机会", "进度", "报告"], id: \.self) { Text($0) } }.pickerStyle(.segmented).accessibilityIdentifier("career-sections")
            }
            if section == "机会" { opportunities }
            else if section == "进度" { progress }
            else { reports }
        }.navigationTitle("求职").listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
            .onDisappear { searchFocused = false }
            .onChange(of: section) { _, _ in searchFocused = false }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { NavigationLink { CareerConnectionView(client: client) } label: { Image(systemName: "gearshape") }.accessibilityLabel("求职设置").accessibilityIdentifier("career-settings") }
                ToolbarItem(placement: .topBarTrailing) { Button { Task { await client.reload() } } label: { Image(systemName: "arrow.clockwise") }.disabled(client.busy).accessibilityLabel("同步求职内容").accessibilityIdentifier("career-reload") }
            }
            .refreshable { await client.reload() }
            .task {
                #if DEBUG && targetEnvironment(simulator)
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--capture-career-companies") { filter = "公司" }
                if arguments.contains("--capture-career-saved") { filter = "收藏" }
                if arguments.contains("--capture-career-observation") { section = "报告" }
                #endif
                await client.monitor()
            }
    }
    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(client.online ? "电脑已连接" : client.configured ? "本机内容" : "尚未连接电脑", systemImage: client.online ? "checkmark.icloud" : "iphone")
                Spacer()
                if client.busy { ProgressView().accessibilityLabel("正在后台同步") }
                Button { Task { await client.discover() } } label: {
                    Text(client.discoveryRunning ? "检索中…" : "查找新机会")
                }.buttonStyle(.borderless).disabled(!client.configured || client.busy || client.startingDiscovery || client.discoveryRunning).accessibilityIdentifier("career-discover")
            }.font(.subheadline)
            Text(client.snapshot["generatedAt"].string.isEmpty ? "收藏、跟进和面试会先保存在手机。" : "上次同步 \(CareerDates.label(client.snapshot["generatedAt"].string))").font(.caption).foregroundStyle(.secondary)
            if let task = client.snapshot["tasks"].array.first {
                Text(task["message"].string).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            let incomplete = client.snapshot["sources"].array.filter { ["blocked", "error", "login_required", "partial"].contains($0["state"].string) }.count
            if incomplete > 0 { NavigationLink("\(incomplete) 个来源尚未全部检查成功") { CareerSourceView(client: client) }.font(.caption) }
            if !client.pending.isEmpty { NavigationLink("\(client.pending.count) 项本机修改待同步") { CareerSyncView(client: client) }.font(.caption).accessibilityIdentifier("career-pending") }
        }.padding(.vertical, 3)
    }
    private var opportunities: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("查看范围", selection: $filter) { Text("全部").tag("全部"); Text("收藏").tag("收藏"); Text("公司").tag("公司") }.pickerStyle(.segmented).accessibilityIdentifier("career-filter")
                    HStack {
                        TextField("搜索公司、岗位、方向或商圈", text: $query)
                            .focused($searchFocused).submitLabel(.search).autocorrectionDisabled()
                            .onSubmit { searchFocused = false }.accessibilityIdentifier("career-search")
                        if searchFocused { Button("完成") { searchFocused = false }.buttonStyle(.borderless).accessibilityIdentifier("career-dismiss-search-keyboard") }
                    }
                    if filter != "公司" {
                        Picker("排序", selection: $sortOrder) { Text("综合推荐").tag("综合推荐"); Text("最新发现／变化").tag("最新发现") }.pickerStyle(.segmented)
                    }
                }.padding(.vertical, 3)
                if filter != "公司" {
                    DisclosureGroup(city == "全部城市" ? "城市与更多筛选" : "\(city) · 更多筛选") {
                        Picker("城市", selection: $city) { Text("全部城市").tag("全部城市"); ForEach(Set(client.snapshot["jobs"].array.map { $0["city"].string }).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) } }
                        if profiles.count > 1 { Picker("目标", selection: $profileID) { Text("默认目标").tag(""); ForEach(profiles) { Text($0["name"].string).tag($0.id) } } }
                        Toggle("包含已结束与历史岗位", isOn: $includeClosed).font(.caption)
                    }.font(.subheadline)
                }
            }
            if filter == "公司" { companyRows }
            else {
                if sortOrder == "最新发现" { Section("按新增或内容变化排序") { ForEach(jobs) { jobLink($0) } } }
                else { ForEach(["precise", "explore"], id: \.self) { lane in
                    let rows = jobs.filter { (matching($0)["lane"].string == "precise" ? "precise" : "explore") == lane }
                    if !rows.isEmpty { Section(lane == "precise" ? "优先查看" : "拓展与待核查") { ForEach(rows) { row in jobLink(row) } } }
                } }
                if jobs.isEmpty { Section { ContentUnavailableView(filter == "收藏" ? "还没有收藏" : "没有符合筛选的岗位", systemImage: "bookmark", description: Text(filter == "收藏" ? "在岗位详情收藏，之后可离线查看。" : "可以调整筛选；来源未检查成功时，已有内容仍然保留。")) } }
            }
            Section { NavigationLink { CareerSourceView(client: client) } label: { Label("来源状态与搜索范围", systemImage: "antenna.radiowaves.left.and.right") } }
        }
    }
    private func jobLink(_ job: CareerAssistantJSON) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink { CareerAssistantJobView(client: client, jobID: job.id, profileID: selectedProfile) } label: { CareerJobRow(job: job, reason: matching(job)["reasons"].strings.first) }
                .accessibilityIdentifier("career-job-" + job.id)
            CareerSourceActions(url: job["url"].string, sourceID: job["sourceID"].string, title: job["title"].string, compact: true)
        }
    }
    private var companyRows: some View {
        let names = Set(CareerDirectory.companies.map(\.name) + client.snapshot["jobs"].array.map { $0["company"].string })
        return Section("公司与对应岗位") {
            ForEach(names.filter { !$0.isEmpty && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }.sorted(), id: \.self) { name in
                NavigationLink { CareerCompanyView(client: client, name: name, profileID: selectedProfile) } label: {
                    VStack(alignment: .leading, spacing: 4) { Text(name); Text(CareerDirectory.companies.first { $0.name == name }?.category ?? "来自岗位库").font(.caption).foregroundStyle(.secondary) }
                }.accessibilityIdentifier("career-company-" + (CareerDirectory.companies.first { $0.name == name }?.id ?? name))
            }
        }
    }
    private var progress: some View {
        Group {
            Section("待你审核 · \(approvals.count)") {
                ForEach(approvals) { application in applicationLink(application) }
                if approvals.isEmpty { Text("电脑准备好材料后，审核单会出现在这里。").foregroundStyle(.secondary) }
            }
            Section("近期面试与提醒") {
                ForEach(following.filter { !$0["followUp"]["reminderAt"].string.isEmpty || $0["followUp"]["interview"] != .null }.sorted { ($0["followUp"]["interview"]["start"].string + $0["followUp"]["reminderAt"].string) < ($1["followUp"]["interview"]["start"].string + $1["followUp"]["reminderAt"].string) }) { job in
                    NavigationLink { CareerTrackingEditor(client: client, jobID: job.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job["company"].string + " · " + job["title"].string)
                            if job["followUp"]["interview"] != .null { Label("面试 \(CareerDates.label(job["followUp"]["interview"]["start"].string))", systemImage: "calendar").font(.caption) }
                            if !job["followUp"]["reminderAt"].string.isEmpty { Text("跟进 \(CareerDates.label(job["followUp"]["reminderAt"].string)) · \(job["followUp"]["nextAction"].string)").font(.caption) }
                        }
                    }
                }
                Text("面试会同步到「计划」；开启提醒后，面试前 30 分钟在本机通知。").font(.caption).foregroundStyle(.secondary)
            }
            Section("正在跟进") { ForEach(following) { jobLink($0) }; if following.isEmpty { Text("在岗位详情记录阶段、下一步或面试安排。") } }
            Section("已审核与投递记录") { ForEach(client.snapshot["applications"].array.filter { $0["state"].string != "draft" }) { applicationLink($0) } }
        }
    }
    private func applicationLink(_ application: CareerAssistantJSON) -> some View {
        NavigationLink { CareerApplicationView(client: client, applicationID: application.id) } label: { VStack(alignment: .leading, spacing: 5) { Text(application["company"].string + " · " + application["jobTitle"].string); Text(CareerApplicationView.stateName(application["state"].string)).font(.caption).foregroundStyle(.secondary) } }.accessibilityIdentifier("career-application-" + application.id)
    }
    private var reports: some View {
        Group {
            Section("小红书招聘线索") {
                ForEach(client.snapshot["reports"].array) { report in NavigationLink { CareerAssistantReportView(client: client, report: report) } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(report["title"].string); Text(report["message"].string).font(.caption).foregroundStyle(.secondary); if report["partial"].bool { Text("部分完成，详见搜索范围").font(.caption).foregroundStyle(.orange) } }
                }.accessibilityIdentifier("career-report-" + report.id) }
                if client.snapshot["reports"].array.isEmpty { Text("还没有报告。电脑完成检索后，这里会显示新增及变化的招聘线索。").foregroundStyle(.secondary) }
            }
            Section("已收藏与未读线索") {
                ForEach(client.snapshot["leads"].array.filter { !$0["ignored"].bool && !["excluded", "closed"].contains($0["category"].string) && ($0["saved"].bool || !$0["read"].bool) }) { lead in NavigationLink { CareerAssistantLeadView(client: client, lead: lead) } label: { Text(lead["title"].string) } }
            }
            Section("待核查机会") { ForEach(client.snapshot["opportunities"].array) { row in NavigationLink(row["title"].string) { CareerOpportunityView(client: client, opportunity: row) } } }
            Section("具身观察 · 已保存资料") {
                ForEach(client.snapshot["articles"].array) { row in
                    if let url = URL(string: row["url"].string), url.scheme == "https" {
                        Link(destination: url) {
                            VStack(alignment: .leading) {
                                Text(row["title"].string)
                                Text(row["summary"].string).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("career-article-" + row.id)
                    }
                }
            }
        }
    }
}

struct CareerJobRow: View {
    let job: CareerAssistantJSON
    var reason: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) { Text(job["title"].string).font(.headline); Spacer(); if job["followUp"]["saved"].bool { Image(systemName: "bookmark.fill").foregroundStyle(.blue) } }
            Text(job["company"].display).font(.subheadline)
            Text(job["location"].string.isEmpty ? job["city"].display : job["location"].string).font(.caption).foregroundStyle(.secondary)
            if let reason, !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack { Text(job["sourceName"].display); if !["", "未投递"].contains(job["followUp"]["stage"].string) { Text(job["followUp"]["stage"].string) }; if job["pendingSync"].bool { Text("待同步") }; if ["closed", "historical"].contains(job["status"].string) { Text("历史／已结束") } }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct CareerCompanyView: View {
    @ObservedObject var client: CareerAssistantClient
    let name: String
    let profileID: String
    private var company: CareerCompany? { CareerDirectory.companies.first { $0.name == name } }
    var body: some View {
        List {
            if let company { Section("公司资料") { Text(company.intro); Text(company.location); Text(company.status).font(.caption).foregroundStyle(.secondary); Text(company.fit).font(.caption); if let url = URL(string: company.url) { Link("查看公司来源", destination: url) } } }
            Section("岗位库中的机会") {
                ForEach(client.snapshot["jobs"].array.filter { CareerMatching.companyIdentity($0["company"].string) == CareerMatching.companyIdentity(name) }) { job in NavigationLink { CareerAssistantJobView(client: client, jobID: job.id, profileID: profileID) } label: { CareerJobRow(job: job) } }
                Text("公司资料来自历史核查，是否招聘实习生请以具体岗位和原站为准。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(name)
    }
}
