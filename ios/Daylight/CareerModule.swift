import SwiftUI
import UniformTypeIdentifiers

struct CareerModule: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile = CareerProfileDocument.load()
    @State private var profileDraft = CareerProfileDocument.load()
    @State private var importingProfile = false
    @State private var exportingProfile = false
    @State private var profileDocument: JSONBackupDocument?
    @State private var profileNotice: String?
    @State private var profileStorageError = false
    @StateObject private var store = CareerStore()
    @State private var section = "岗位"
    @State private var report = "周报"
    @State private var showPreferences = false
    @State private var showServiceSettings = false
    @State private var selectedJob: CareerJob?
    @State private var company: CareerCompany?
    @State private var companyQuery = ""
    @State private var companyCategory = "全部"
    @State private var jobQuery = ""
    @State private var expandedGroups = Set<String>()
    @FocusState private var companySearchFocused: Bool
    @FocusState private var jobSearchFocused: Bool
    private var focus: String { profile.focus }
    private var cityScope: String { profile.cityScope }
    private var attendance: String { profile.attendanceDays.map { "\($0) 天" } ?? "未定" }
    private var duration: String { profile.durationMonths.map { "\($0) 个月" } ?? "未定" }
    private var start: String { profile.start }

    private var preferencesValue: CareerPreferences {
        CareerPreferences(focus: focus, cityScope: cityScope, attendanceDays: profile.attendanceDays, durationMonths: profile.durationMonths,
            start: start, expectedGraduationYear: profile.expectedGraduationYear, currentEducation: profile.currentEducation,
            capabilities: profile.capabilities)
    }
    private var matches: [CareerMatch] {
        store.rankedMatches(preferences: preferencesValue).filter { jobQuery.isEmpty ||
            "\($0.job.company) \($0.job.title) \($0.job.city) \($0.job.description)".localizedCaseInsensitiveContains(jobQuery) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Picker("内容", selection: $section) { Text("岗位").tag("岗位"); Text("公司").tag("公司"); Text("具身观察").tag("具身观察") }
                    .pickerStyle(.segmented).accessibilityIdentifier("career-section")
                if section == "岗位" { jobs }
                else if section == "公司" { directory }
                else { observation }
                Text("资讯每日自动更新，岗位每三天更新；画像、收藏和匹配结果留在本机。")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("career-preview-notice")
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("求职与具身").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPreferences) { preferences }
            .sheet(isPresented: $showServiceSettings) { CareerServiceSettings(store: store) }
            .sheet(item: $selectedJob) { jobDetail($0) }
            .sheet(item: $company) { companyDetail($0) }
            .onChange(of: section) { _, _ in companySearchFocused = false; jobSearchFocused = false }
            .onChange(of: scenePhase) { _, value in
                if value == .active {
                    reloadProfile()
                    Task { await store.refreshIfNeeded() }
                }
            }
            .onAppear { reloadProfile() }
            .task {
                #if DEBUG && targetEnvironment(simulator)
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--capture-career-companies") { section = "公司" }
                if args.contains("--capture-career-observation") { section = "具身观察" }
                #endif
                await store.refreshIfNeeded()
            }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(focus) · 实习").font(.subheadline).foregroundStyle(.secondary)
                Text("下一站").font(.largeTitle.bold())
            }
            Spacer()
            Button {
                companySearchFocused = false; jobSearchFocused = false
                Task { await store.connect(refresh: store.usePrivateService && store.feed?.scheduler?.running != true) }
            } label: {
                if store.busy { ProgressView().padding(12) }
                else { Image(systemName: "arrow.clockwise").padding(12).background(Color.blue.opacity(0.08), in: Circle()) }
            }.disabled(store.busy).accessibilityLabel("采集并刷新岗位").accessibilityIdentifier("career-refresh")
            Button { profileDraft = profile; if !profileStorageError { profileNotice = nil }; showPreferences = true } label: { Image(systemName: "slider.horizontal.3").padding(12).background(Color.blue.opacity(0.08), in: Circle()) }
                .accessibilityLabel("求职偏好").accessibilityIdentifier("career-preferences")
        }
    }

    private var serviceStatus: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(store.origin, systemImage: store.origin == "采集服务" ? "network" : "tray").font(.caption)
                Spacer()
                Button("更新设置") { showServiceSettings = true }.font(.caption).accessibilityIdentifier("career-service-settings")
            }
            if let last = store.lastSuccess { Text("上次成功读取：\(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            else { Text("打开后自动读取公开更新；岗位状态以原页为准。").font(.caption).foregroundStyle(.secondary) }
            if store.busy { Label("正在读取最新岗位与资讯", systemImage: "hourglass").font(.caption) }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("career-service-error") }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("career-service-notice") }
            if let sources = store.feed?.sources, !sources.isEmpty {
                DisclosureGroup("\(sources.count) 个来源 · 查看采集状态") {
                    ForEach(sources) { source in sourceStatus(source) }
                }.font(.caption).accessibilityIdentifier("career-source-status")
            }
            if let schedule = store.feed?.scheduler {
                Text(schedule.enabled ? "岗位更新：\(intervalLabel(schedule.intervalHours)) · 下次 \(displayTime(schedule.nextRunAt))" : "定期更新已暂停")
                    .font(.caption).foregroundStyle(.secondary)
                Text("今日采集请求预算剩余 \(max(0, schedule.budgetLimit - schedule.budgetUsed))／\(schedule.budgetLimit)；采集由公开更新任务执行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sourceStatus(_ source: CareerSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(source.name).fontWeight(.medium); Spacer(); Text(source.stateLabel).foregroundStyle(source.state == "ok" ? Color.blue : Color.orange) }
            Text("\(source.count) 条 · \(source.message)").foregroundStyle(.secondary)
            if let date = source.lastSuccessAt { Text("来源上次成功：\(date)").foregroundStyle(.secondary) }
            if let attempt = source.lastAttemptAt { Text("本次尝试：\(attempt)").foregroundStyle(.secondary) }
            if let coverage = source.coverage {
                Text(coverage.mode == "fixed_pages" ? "固定来源读取：列表页 \(coverage.pagesRun)，详情 \(coverage.detailsRun)，请求 \(coverage.requests)。" : "实际查询 \(coverage.queriesRun)／\(coverage.totalQueries)，列表页 \(coverage.pagesRun)，详情 \(coverage.detailsRun)，请求 \(coverage.requests)。")
                if !coverage.keywords.isEmpty { Text("实际查询词：\(coverage.keywords.joined(separator: "、"))。") }
                else if let planned = coverage.plannedKeywords, !planned.isEmpty { Text("查询计划尚未执行：\(planned.prefix(3).joined(separator: "、"))。") }
                if !coverage.companies.isEmpty { Text("本次来源公司：\(coverage.companies.prefix(8).joined(separator: "、"))。公司目录数量不代表已逐家扫描。") }
                if coverage.partial { Text(coverage.mode == "fixed_pages" ? "本次只读取指定来源页面，不代表已搜索全站。" : "本轮为部分覆盖，未扫描的词和公司会在后续轮转。") }
            }
            if let next = source.nextAttemptAt { Text("下次尝试：\(displayTime(next))").foregroundStyle(.secondary) }
        }.font(.caption).padding(.vertical, 6).accessibilityIdentifier("career-source-\(source.id)")
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 18) {
            serviceStatus
            HStack {
                TextField("搜索岗位、公司或技能", text: $jobQuery).focused($jobSearchFocused)
                    .autocorrectionDisabled().submitLabel(.done).onSubmit { jobSearchFocused = false }.accessibilityIdentifier("career-job-search")
                if jobSearchFocused { Button("完成") { jobSearchFocused = false }.accessibilityIdentifier("career-job-search-done") }
            }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            Text("优先展示杭州实习。职责与要求来自岗位来源；未取得完整 JD 时明确标注。")
                .font(.caption).foregroundStyle(.secondary)
            if matches.isEmpty {
                EmptyRecords(title: jobQuery.isEmpty ? "当前没有匹配的有效岗位资料" : "没有符合搜索的岗位", icon: "briefcase")
                Text("可调整本地筛选条件；来源刷新失败时保留上次成功内容。").font(.caption).foregroundStyle(.secondary)
            } else if cityScope == "全国" {
                matchGroup("相关岗位", values: matches, key: "all")
            } else {
                matchGroup("杭州", values: matches.filter { CareerMatching.isHangzhou($0.job.city) }, key: "hangzhou")
                if cityScope != "只看杭州" { matchGroup("其他城市", values: matches.filter { !CareerMatching.isHangzhou($0.job.city) }, key: "other") }
            }
            otherJobRecords
        }
    }

    private func matchGroup(_ title: String, values: [CareerMatch], key: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.title2.bold()); Spacer(); Text("\(values.count) 个岗位").font(.caption).foregroundStyle(.secondary) }
            if values.isEmpty { Text("目前没有匹配项，来源成功采集后继续补充。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(expandedGroups.contains(key) ? values : Array(values.prefix(6))) { item in jobCard(item) }
            if values.count > 6 {
                Button(expandedGroups.contains(key) ? "收起" : "查看全部 \(values.count) 个岗位") {
                    if expandedGroups.contains(key) { expandedGroups.remove(key) } else { expandedGroups.insert(key) }
                }.accessibilityIdentifier("career-jobs-expand-\(key)")
            }
        }
    }

    private func jobCard(_ item: CareerMatch) -> some View {
        Button { jobSearchFocused = false; selectedJob = item.job } label: {
            SoftCard {
                HStack { Text(item.job.sourceName).font(.caption.bold()).foregroundStyle(.blue).lineLimit(1); Spacer(); Text(item.job.jobType.isEmpty ? "类型待核对" : item.job.jobType).font(.caption).foregroundStyle(.secondary) }
                Text(item.job.title).font(.headline)
                Text("\(item.job.company) · \(item.job.city) · \(item.job.salary.isEmpty ? "薪酬未说明" : item.job.salary)").font(.subheadline).foregroundStyle(.secondary)
                Text(jdSummary(item.job)).font(.subheadline).lineLimit(3)
                HStack {
                    Text(item.job.statusLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.followUp(for: item.job).saved { Image(systemName: "bookmark.fill").foregroundStyle(.blue) }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("career-job-\(item.id)")
            .accessibilityValue(store.followUp(for: item.job).saved ? "已收藏" : "未收藏")
    }

    private var otherJobRecords: some View {
        let preferred = Set(store.rankedMatches(preferences: CareerPreferences(focus: focus, cityScope: "全国", attendanceDays: profile.attendanceDays,
            durationMonths: profile.durationMonths, start: start, expectedGraduationYear: profile.expectedGraduationYear, currentEducation: profile.currentEducation,
            capabilities: profile.capabilities)).map(\.id))
        let records = CareerMatching.merge(jobs: store.jobs).filter { !preferred.contains($0.stableID) }
        return Group {
            if !records.isEmpty {
                DisclosureGroup("历史及条件不符资料 · \(records.count) 条") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("历史、关闭、工作类型未明确为实习或硬条件不符的条目不参与当前推荐。模型低相关只降排序，不删除岗位；关闭模型开关可恢复规则排序。").font(.caption).foregroundStyle(.secondary)
                        ForEach(records, id: \.stableID) { job in
                            Button { selectedJob = job } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.title).font(.subheadline.bold())
                                    Text("\(job.company) · \(job.city) · \(job.jobType) · \(job.statusLabel)").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }.buttonStyle(.plain).accessibilityIdentifier(job.company.contains("群核") ? "career-job-detail" : "career-history-\(job.stableID)")
                        }
                    }
                }.accessibilityIdentifier("career-history")
            }
        }
    }

    private func jobDetail(_ job: CareerJob) -> some View {
        let match = CareerMatching.rank(jobs: [job], preferences: preferencesValue).first
        let intro = CareerDirectory.companies.first { CareerMatching.companyIdentity($0.name) == CareerMatching.companyIdentity(job.company) || job.company.contains($0.name) || $0.name.contains(job.company) }
        return NavigationStack {
            Form {
                Section {
                    Text(job.title).font(.title3.bold())
                    Text("\(job.company) · \(job.city) · \(job.jobType) · \(job.salary)").foregroundStyle(.secondary)
                    Text(job.statusLabel).font(.caption).foregroundStyle(job.status == "verified" ? Color.blue : Color.orange)
                    if job.requiredDegree == "phd" { Text("来源学历要求：博士。").font(.caption).foregroundStyle(.orange) }
                    if !job.location.isEmpty { Text(job.location).font(.caption) }
                }
                Section("岗位职责") {
                    if !job.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(job.description).textSelection(.enabled) }
                    else { Text("岗位职责尚未获取，请打开原始来源查看完整 JD。").foregroundStyle(.secondary) }
                }
                Section("任职要求") {
                    if !job.requirements.isEmpty { ForEach(Array(job.requirements.enumerated()), id: \.offset) { _, text in Text(text).textSelection(.enabled) } }
                    else { Text("尚未取得来源的完整任职要求，请打开原始岗位核对。").foregroundStyle(.secondary) }
                }
                Section("公司介绍") {
                    if let intro { Text(intro.intro); Text("\(intro.location) · \(intro.status)").font(.caption).foregroundStyle(.secondary) }
                    else if let text = job.companyIntro, !text.isEmpty { Text(text) }
                    else { Text("公司介绍尚待补充。团队资源、导师和实习政策请向招聘方核对。").foregroundStyle(.secondary) }
                }
                Section("来源与跟进") {
                    Text(job.sourceName).font(.caption).foregroundStyle(.secondary)
                    if let published = job.publishedAt { Text("原页发布时间：\(published)").font(.caption).foregroundStyle(.secondary) }
                    else { Text("原页发布时间未知").font(.caption).foregroundStyle(.secondary) }
                    if let refreshed = job.refreshedAt { Text("原页刷新时间：\(refreshed)").font(.caption).foregroundStyle(.secondary) }
                    if let deadline = job.deadline { Text("原页截止：\(deadline)").font(.caption).foregroundStyle(.secondary) }
                    Text("来源核查时间：\(job.checkedAt)").font(.caption).foregroundStyle(.secondary)
                    if let note = job.sourceNote, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                    if let url = URL(string: job.url) { Link("查看原始岗位来源", destination: url) }
                    ForEach(job.relatedURLs.filter { $0 != job.url }, id: \.self) { text in if let url = URL(string: text) { Link("查看其他来源 · \(url.host ?? "网页")", destination: url) } }
                    Toggle("收藏这个岗位", isOn: Binding(get: { store.followUp(for: job).saved }, set: { value in var state = store.followUp(for: job); state.saved = value; store.setFollowUp(state, for: job) }))
                        .accessibilityIdentifier("career-save-job")
                    Picker("投递状态", selection: Binding(get: { store.followUp(for: job).stage }, set: { value in var state = store.followUp(for: job); state.stage = value; store.setFollowUp(state, for: job) })) {
                        ForEach(["未投递", "准备投递", "已投递", "面试中", "已结束"], id: \.self) { Text($0) }
                    }.accessibilityIdentifier("career-job-stage")
                }
                secondaryJobDetails(job, match: match)
                if store.followUp(for: job).saved { Label("已收藏 · \(store.followUp(for: job).stage)", systemImage: "bookmark.fill").accessibilityIdentifier("career-saved-status") }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }.navigationTitle("岗位与公司").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selectedJob = nil }.accessibilityIdentifier("career-detail-done") } }
        }
    }

    private func secondaryJobDetails(_ job: CareerJob, match: CareerMatch?) -> some View {
        Section("补充信息") {
            DisclosureGroup("实习条件与资料限制") {
                if let match {
                    ForEach(match.conditions, id: \.self) { Text($0) }
                    ForEach(match.gaps, id: \.self) { Text($0) }
                } else { Text("此条可能已关闭、过期或有明确条件不符，请在原页核对。") }
            }
            if store.modelEnabled, let cached = store.modelAnalysis(for: job, preferences: preferencesValue) {
                DisclosureGroup("模型分析 · 参考") {
                    Text(cached.analysis.safeSummary)
                    ForEach(cached.analysis.assessments, id: \.skillID) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(item.label) · \(item.levelLabel)").font(.subheadline.bold())
                            Text("JD 摘录：\(item.quote)").font(.caption).foregroundStyle(.secondary)
                            Text(item.safeReason).font(.subheadline)
                        }
                    }
                    Text("\(cached.model) · \(cached.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(cached.actualTokens.map { String($0) + " Token" } ?? "用量未返回")。模型分析可能出错，JD 以原始来源为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func jdSummary(_ job: CareerJob) -> String {
        let text = job.description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "岗位详情尚未获取，打开原始来源查看完整 JD。" }
        return String(text.prefix(180)) + (text.count > 180 ? "…" : "")
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("杭州公司关注目录").font(.title2.bold())
            Text("24 个关注项 · 16 个有杭州公开来源，8 个仍需核查。公司目录不等于招聘岗位库；岗位页单独展示实际职责与来源。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("搜索公司或方向", text: $companyQuery).focused($companySearchFocused).submitLabel(.done).onSubmit { companySearchFocused = false }.autocorrectionDisabled().accessibilityIdentifier("career-company-search")
                if companySearchFocused { Button("完成") { companySearchFocused = false } }
            }
            Picker("方向", selection: $companyCategory) { ForEach(["全部", "仿真与操作", "本体与控制", "灵巧手", "服务机器人", "相邻方向", "待核查"], id: \.self) { Text($0) } }.pickerStyle(.menu)
            let values = CareerDirectory.companies.filter { (companyCategory == "全部" || $0.category == companyCategory) && (companyQuery.isEmpty || "\($0.name) \($0.category) \($0.intro)".localizedCaseInsensitiveContains(companyQuery)) }
            if values.isEmpty { EmptyRecords(title: "没有符合条件的公司", icon: "building.2") }
            ForEach(values) { value in
                Button { companySearchFocused = false; company = value } label: {
                    SoftCard {
                        HStack { Text(value.name).font(.headline); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                        Text("\(value.category) · \(value.location)").font(.caption).foregroundStyle(.secondary)
                        Text(value.intro).font(.subheadline)
                        Text(value.status).font(.caption).foregroundStyle(value.category == "待核查" ? Color.orange : Color.blue)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("career-company-\(value.id)")
            }
        }
    }

    private func companyDetail(_ value: CareerCompany) -> some View {
        NavigationStack {
            Form {
                Section(value.name) { Text(value.intro); Text("\(value.location) · \(value.status)").font(.caption).foregroundStyle(.secondary) }
                Section("与你的方向") { Text(value.fit) }
                Section("核查状态") { Text("2026-10-05 核查公司资料；公司入库不代表存在合适实习。招聘情况以原始岗位为准。"); if let url = URL(string: value.url) { Link("查看来源", destination: url) } }
            }.navigationTitle("公司介绍").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { company = nil } } }
        }
    }

    private var observation: some View {
        let all = store.feed?.articles ?? []
        let current = CareerReportPeriod.articles(all, days: report == "日报" ? 1 : 7)
        let categories = ["行业动态", "技术进展", "操作与学习", "仿真与评测", "开源工具", "硬件与落地", "论文"]
        let themes = Array(Set(current.flatMap { $0.topics ?? [] })).sorted()
        let archive = all.filter { row in !current.contains(where: { $0.id == row.id }) }
        return VStack(alignment: .leading, spacing: 18) {
            Picker("报告周期", selection: $report) { Text("日报").tag("日报"); Text("周报").tag("周报") }.pickerStyle(.segmented).accessibilityIdentifier("career-report-period")
            Text(report == "日报" ? "今天的具身观察" : "最近七天的具身观察").font(.title2.bold())
            Text("按北京时间和原始发布日期筛选。论文以首次提交日期为准；预印本尚不代表经过同行评审。没有确定日期的内容放入资料库。")
                .font(.caption).foregroundStyle(.secondary)
            if let generated = store.feed?.generatedAt { Text("内容更新：\(displayTime(generated))").font(.caption).foregroundStyle(.secondary) }
            if !current.isEmpty {
                SoftCard {
                    Text("\(current.count) 条观察 · \(current.filter { $0.category == "论文" }.count) 篇论文").font(.headline)
                    if !themes.isEmpty { Text("技术线索：" + themes.joined(separator: "、")).font(.subheadline) }
                    Text("覆盖产业、策略学习、仿真评测、开源工具与硬件落地；摘要与技术关键词来自来源内容，不额外调用模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                EmptyRecords(title: report == "日报" ? "今日暂无已核实日期的新内容" : "本周暂无已核实日期的新内容", icon: "newspaper")
                Text("可以查看下方资料库，或点击顶部刷新读取最新发布内容。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(categories, id: \.self) { category in
                let values = current.filter { $0.category == category }
                if !values.isEmpty {
                    Text("\(category) · \(values.count)").font(.title3.bold())
                    ForEach(values) { article in articleCard(article) }
                }
            }
            if !archive.isEmpty {
                DisclosureGroup("资料库 · \(archive.count) 条历史或日期待核查内容") {
                    ForEach(archive) { article in articleCard(article) }
                }.accessibilityIdentifier("career-article-archive")
            }
        }
    }

    private func articleCard(_ article: CareerFeedArticle) -> some View {
        SoftCard {
            HStack {
                Text(article.category).foregroundStyle(.blue)
                Spacer()
                Text(article.date.isEmpty ? "发布日期待核查" : String(article.date.prefix(10))).foregroundStyle(.secondary)
            }.font(.caption)
            Text(article.title).font(.headline)
            if let source = article.sourceName { Text(source).font(.caption).foregroundStyle(.secondary) }
            if let authors = article.authors, !authors.isEmpty { Text(authors.prefix(4).joined(separator: "、") + (authors.count > 4 ? " 等" : "")).font(.caption).foregroundStyle(.secondary) }
            Text(article.summary).font(.subheadline).textSelection(.enabled)
            if let topics = article.topics, !topics.isEmpty { Text("技术方向：" + topics.joined(separator: " · ")).font(.caption).foregroundStyle(.blue) }
            if let points = article.highlights, !points.isEmpty {
                DisclosureGroup("查看来源中的技术要点") {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in Text(point).font(.subheadline).padding(.vertical, 3) }
                }.font(.caption)
            }
            if let updated = article.updatedAt, updated != article.date { Text("版本更新：\(String(updated.prefix(10)))").font(.caption).foregroundStyle(.secondary) }
            if let url = URL(string: article.url) { Link(article.category == "论文" ? "阅读论文与摘要" : "阅读来源原文", destination: url) }
        }.accessibilityIdentifier("career-article-\(article.id)")
    }

    private var preferences: some View {
        NavigationStack {
            Form {
                Section("求职方向") {
                    Picker("岗位方向", selection: $profileDraft.focus) { ForEach(["具身操作算法", "机器人仿真算法", "机器人系统开发"], id: \.self) { Text($0) } }
                    Picker("城市范围", selection: $profileDraft.cityScope) { ForEach(["杭州优先", "只看杭州", "全国"], id: \.self) { Text($0) } }
                    Text("画像和求职偏好保存在这台 iPhone；点保存后影响岗位排序。").font(.caption).foregroundStyle(.secondary)
                }
                Section("实习条件") {
                    Picker("到岗时间", selection: $profileDraft.start) { ForEach(["未定", "立即", "两周内", "一个月内", "寒假", "暑假"], id: \.self) { Text($0) } }
                    Picker("每周出勤", selection: Binding(get: { profileDraft.attendanceDays.map { "\($0) 天" } ?? "未定" }, set: { profileDraft.attendanceDays = leadingNumber($0) })) { ForEach(["未定", "1 天", "2 天", "3 天", "4 天", "5 天", "6 天", "7 天"], id: \.self) { Text($0) } }
                    Picker("实习时长", selection: Binding(get: { profileDraft.durationMonths.map { "\($0) 个月" } ?? "未定" }, set: { profileDraft.durationMonths = leadingNumber($0) })) { ForEach(["未定", "1 个月", "2 个月", "3 个月", "4 个月", "5 个月", "6 个月", "12 个月"], id: \.self) { Text($0) } }
                    Text("未定条件不会当作满足，也不会因此删掉岗位。已选条件和原页要求逐项核对，未知信息保留待核对。").font(.caption).foregroundStyle(.secondary)
                }
                Section("个人画像（保存在本机）") {
                    TextField("当前学历阶段，例如在读或已毕业", text: $profileDraft.currentEducation).accessibilityIdentifier("career-profile-education")
                    TextField("预计毕业年份", text: Binding(get: { profileDraft.expectedGraduationYear.map { String($0) } ?? "" }, set: { profileDraft.expectedGraduationYear = Int($0.filter(\.isNumber).prefix(4)) }))
                        .keyboardType(.numberPad)
                    ForEach($profileDraft.capabilities) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("技能或方向", text: $item.label).font(.subheadline.weight(.medium))
                            TextField("项目事实或经验说明", text: $item.fact, axis: .vertical).lineLimit(2...5).font(.caption)
                            Picker("掌握状态", selection: $item.status) {
                                Text("已确认").tag("confirmed"); Text("部分经验").tag("partial")
                                Text("计划学习").tag("planned"); Text("待确认").tag("unknown")
                            }.font(.caption)
                            Button("移除此项", role: .destructive) { profileDraft.capabilities.removeAll { $0.id == item.id } }.font(.caption)
                        }.padding(.vertical, 4)
                    }
                    Button("添加技能或项目", systemImage: "plus") {
                        guard profileDraft.capabilities.count < 30 else { profileNotice = "最多保留 30 项。"; return }
                        profileDraft.capabilities.append(CareerCapability(id: "skill-" + UUID().uuidString.lowercased(), label: "新技能或项目", fact: "", status: "unknown"))
                    }
                    Button("从文件导入画像", systemImage: "square.and.arrow.down") { importingProfile = true }
                    Button("导出本机画像", systemImage: "square.and.arrow.up") {
                        do { profileDocument = JSONBackupDocument(bytes: try profileDraft.encoded()); exportingProfile = true }
                        catch { profileNotice = error.localizedDescription }
                    }
                    if let profileNotice { Text(profileNotice).font(.caption).foregroundStyle(.secondary) }
                    Text("填写实际做过的项目和结果，不要写姓名、电话或邮箱。导入后先检查内容，再点保存；取消会保留原画像。画像 JSON 请放在私人位置。").font(.caption).foregroundStyle(.secondary)
                }
                Section("数据与运行") {
                    Text("岗位内容与收藏／投递状态保存在本机独立文件。规则匹配不消耗模型 Token。默认自动读取公开更新，无需电脑地址或访问令牌。")
                    Text("BOSS 需要电脑会话，实际读取可能受网站限制；实习僧官方接口需要平台授权。各来源是否接通以采集状态为准。云端定时采集尚未启用。").font(.subheadline).foregroundStyle(.secondary)
                }
                modelPreferences
            }.navigationTitle("求职偏好").navigationBarTitleDisplayMode(.inline)
                .fileImporter(isPresented: $importingProfile, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    do {
                        guard let url = try result.get().first else { return }
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        profileDraft = try CareerProfileDocument.decode(Data(contentsOf: url)); profileStorageError = false; profileNotice = "画像已读取，请核对后点保存。"
                    } catch { profileNotice = "导入失败，原画像未更改：\(error.localizedDescription)" }
                }
                .fileExporter(isPresented: $exportingProfile, document: profileDocument, contentType: .json, defaultFilename: "求职个人画像") { result in
                    switch result { case .success: profileNotice = "画像已导出。"; case .failure(let error): profileNotice = "导出失败：\(error.localizedDescription)" }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showPreferences = false }.accessibilityIdentifier("career-profile-cancel") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do { try profileDraft.saveLocally(); profile = profileDraft; profileStorageError = false; showPreferences = false }
                            catch { profileNotice = error.localizedDescription }
                        }.disabled(profileStorageError).accessibilityIdentifier("career-preferences-done")
                    }
                }
        }
    }
    private func reloadProfile() {
        do { profile = try CareerProfileDocument.loadSaved() ?? CareerProfileDocument.load(); profileStorageError = false }
        catch {
            profileStorageError = true
            profileNotice = "本机画像无法读取，原数据未覆盖。请从私人画像文件导入并核对后保存。"
        }
    }
    private func leadingNumber(_ value: String) -> Int? { Int(value.prefix { $0.isNumber }) }
    private func intervalLabel(_ hours: Int) -> String { hours >= 24 && hours % 24 == 0 ? "每 \(hours / 24) 天" : "每 \(hours) 小时" }
    private func displayTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let first = formatter.date(from: value); formatter.formatOptions = [.withInternetDateTime]
        return (first ?? formatter.date(from: value)).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? value
    }
    private var modelPreferences: some View {
        Section("模型语义匹配 · 可选") {
            Toggle("使用模型辅助理解岗位", isOn: $store.modelEnabled).accessibilityIdentifier("career-model-enabled")
            Text("默认关闭。开启后手动分析新／变化岗位，会把最多 6 项相关能力事实、求职偏好和公开 JD 摘录发送给已配置的模型服务；模型 Key 不发送给采集服务。列表线索不调用模型。")
                .font(.caption).foregroundStyle(.secondary)
            Button(store.modelBusy ? "正在分析…" : "分析新增岗位") { Task { await store.analyzeNewJobs(preferences: preferencesValue) } }
                .disabled(!store.modelEnabled || store.modelBusy).accessibilityIdentifier("career-model-analyze")
            Text("每批最多 3 岗，JD 最多 1200 字，输出上限 800 Token。每日保守预算 6000 Token，含失败预留；相同输入复用缓存，修改画像或 JD 才重新分析。")
                .font(.caption).foregroundStyle(.secondary)
            Text("今日已返回实际用量 \(store.modelActualTokensToday) Token；保守预算剩余 \(store.modelRemainingTokens) Token。预留值通常高于实际，失败项当天不反复调用。")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("career-model-usage")
            if let notice = store.modelNotice { Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("career-model-notice") }
            Text("语义分析用于排序和解释，可能出错；不是录用概率，也不能改动招聘事实和实习硬约束。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CareerServiceSettings: View {
    @ObservedObject var store: CareerStore
    @Environment(\.dismiss) private var dismiss
    private enum ConfigurationField: Hashable { case address, token }
    @FocusState private var focusedField: ConfigurationField?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("自动更新") {
                    Text("默认直接读取公开岗位和具身资讯。无需启动电脑脚本、填写 IP 地址或复制访问令牌。")
                    Text("资讯每日更新，岗位每三天更新；顶部刷新读取最近发布的版本，不会立即触发全部网站重新采集。").font(.caption).foregroundStyle(.secondary)
                    Button("读取最新公开内容") { store.usePrivateService = false; focusedField = nil; Task { await store.connect(refresh: false) } }.disabled(store.busy)
                    Toggle("使用个人采集服务（高级）", isOn: $store.usePrivateService)
                }
                if store.usePrivateService {
                Section("个人采集服务") {
                    TextField("例如 http://192.168.1.10:4176", text: $store.configuration.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).focused($focusedField, equals: .address).accessibilityIdentifier("career-service-url")
                    SecureField("采集服务访问令牌", text: $store.configuration.token).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focusedField, equals: .token).accessibilityIdentifier("career-service-token")
                    Text("地址和访问令牌由电脑采集服务提供，与 DeepSeek API Key 分开。保存在本机钥匙串，不随账本备份导出。").font(.caption).foregroundStyle(.secondary)
                    Button("保存连接配置") { focusedField = nil; do { try store.saveConfiguration(); message = nil } catch { message = error.localizedDescription } }.accessibilityIdentifier("career-service-save")
                    Button(store.busy ? "正在连接…" : "测试连接并读取岗位") { focusedField = nil; message = nil; Task { await store.connect(refresh: false) } }.disabled(store.busy).accessibilityIdentifier("career-service-test")
                    Button("采集并刷新") { focusedField = nil; message = nil; Task { await store.connect(refresh: true) } }.disabled(store.busy).accessibilityIdentifier("career-service-refresh")
                    if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("career-service-error") }
                    if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                }
                Section("数据与来源") {
                    Text("公开内容来源包括企业官网、公开招聘页、研究机构、arXiv 和开源项目。来源受限时保留缓存并显示状态，不保证全站覆盖。")
                    Text("你的画像、收藏和投递记录保存在手机；公开更新任务不接收这些数据，也不接收账本、健康或日历内容。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.scrollDismissesKeyboard(.interactively).navigationTitle("内容更新").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { focusedField = nil; dismiss() }.accessibilityIdentifier("career-service-done") }
                }
        }
    }
}
