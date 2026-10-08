import Foundation
import Combine

struct CareerFollowUp: Codable, Sendable {
    var saved = false
    var stage = "未投递"
}

@MainActor
final class CareerStore: ObservableObject {
    @Published private(set) var feed: CareerFeed?
    @Published private(set) var origin = "内置研究资料"
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var followUps: [String: CareerFollowUp] = [:]
    @Published var configuration = CareerAPIConfiguration()
    @Published var modelEnabled = UserDefaults.standard.bool(forKey: "career-model-enabled") {
        didSet { UserDefaults.standard.set(modelEnabled, forKey: "career-model-enabled") }
    }
    @Published private(set) var modelBusy = false
    @Published private(set) var modelNotice: String?
    @Published private(set) var modelAnalyses: [String: CareerModelCachedAnalysis] = [:]
    @Published private(set) var modelBudget = CareerModelDailyBudget(day: CareerModelDailyBudget.dayKey(Date()))
    private let directory: URL?

    var configured: Bool { !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var jobs: [CareerJob] {
        var values = feed?.jobs ?? []
        if let legacy = legacySavedJob(), !values.contains(where: { $0.stableID == legacy.stableID }) { values.append(legacy) }
        return values
    }

    init(directory: URL? = nil, seedData: Data? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-career-failure") {
            configuration = CareerAPIConfiguration(baseURL: "http://127.0.0.1:4180", token: "ui-fixture-token")
        } else {
            do { configuration = try CareerCredentials.load() } catch { self.error = error.localizedDescription }
        }
        #else
        do { configuration = try CareerCredentials.load() } catch { self.error = error.localizedDescription }
        #endif
        if let cache = self.directory?.appendingPathComponent("career-feed-v1.json"), let data = try? Data(contentsOf: cache), let value = try? CareerFeed.decode(data) {
            feed = value; origin = "上次成功内容"
            if let stored = UserDefaults.standard.object(forKey: "career-last-success") as? Date { lastSuccess = stored }
        } else {
            let bytes = seedData ?? Bundle.main.url(forResource: "CareerSeed", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
            if let bytes, let value = try? CareerFeed.decode(bytes) { feed = value }
            else { self.error = CareerServiceError.missingSeed.localizedDescription }
        }
        if let file = self.directory?.appendingPathComponent("career-follow-up-v1.json"), let data = try? Data(contentsOf: file),
           let values = try? JSONDecoder().decode([String: CareerFollowUp].self, from: data) { followUps = values }
        if let file = self.directory?.appendingPathComponent("career-model-analysis-v1.json"), let data = try? Data(contentsOf: file), data.count <= 8_388_608,
           let values = try? JSONDecoder().decode([String: CareerModelCachedAnalysis].self, from: data) { modelAnalyses = values }
        if let file = self.directory?.appendingPathComponent("career-model-budget-v1.json"), let data = try? Data(contentsOf: file),
           let value = try? JSONDecoder().decode(CareerModelDailyBudget.self, from: data), value.day == CareerModelDailyBudget.dayKey(Date()) { modelBudget = value }
        migrateLegacyFollowUp()
    }

    func saveConfiguration() throws {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-career-failure") {
            _ = try configuration.endpoint(refresh: false)
            error = nil; notice = "界面测试连接配置已检查，未写入钥匙串。"
            return
        }
        #endif
        try CareerCredentials.save(configuration)
        error = nil; notice = "连接配置已保存在本机钥匙串。"
    }

    func connect(refresh: Bool) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-career-failure") {
            // A deterministic UI failure fixture exercises cache retention only.
            // Real request/response behaviour is verified separately by API tests.
            error = CareerServiceError.offline.localizedDescription
            return
        }
        #endif
        do {
            try saveConfiguration()
            notice = nil
            let result = try await CareerNetworking(configuration: configuration).fetch(refresh: refresh)
            let receivedAt = Date()
            try persist(result, filename: "career-feed-v1.json")
            feed = result; origin = "采集服务"; lastSuccess = receivedAt
            UserDefaults.standard.set(receivedAt, forKey: "career-last-success")
            migrateLegacyFollowUp()
            notice = result.scheduler?.running == true ? "电脑正在后台采集，已有岗位仍可查看。下次打开本页会读取最新结果。" : refresh ? "已读取采集结果。各来源登录与采集状态见下方。" : "服务连接成功，已读取当前岗位内容。"
        } catch is CancellationError {
            notice = "请求已取消，上次内容仍然可用。"
        } catch { self.error = error.localizedDescription }
    }

    func followUp(for job: CareerJob) -> CareerFollowUp {
        if let current = followUps[job.stableID] { return current }
        for url in job.sourceURLs {
            guard let key = aliasKey(url) else { continue }
            if let value = followUps[key] { return value }
        }
        return CareerFollowUp()
    }

    var modelRemainingTokens: Int {
        if modelBudget.day != CareerModelDailyBudget.dayKey(Date()) { return CareerModelDailyBudget.limit }
        return max(0, CareerModelDailyBudget.limit - max(modelBudget.reservedTokens, modelBudget.actualTokens))
    }
    var modelActualTokensToday: Int { modelBudget.day == CareerModelDailyBudget.dayKey(Date()) ? modelBudget.actualTokens : 0 }

    func modelAnalysis(for job: CareerJob, preferences: CareerPreferences) -> CareerModelCachedAnalysis? {
        guard let input = CareerModelInput(job: job, preferences: preferences), let cached = modelAnalyses[input.cacheKey],
              cached.signature == input.signature, let data = try? JSONEncoder().encode(cached.analysis),
              let json = String(data: data, encoding: .utf8), (try? CareerModelAnalysis.decode(json, input: input)) != nil else { return nil }
        return cached
    }

    func rankedMatches(preferences: CareerPreferences) -> [CareerMatch] {
        let baseline = CareerMatching.rank(jobs: jobs, preferences: preferences)
        guard modelEnabled else { return baseline }
        var current: [String: CareerModelAnalysis] = [:]
        for item in baseline { if let value = modelAnalysis(for: item.job, preferences: preferences) { current[item.id] = value.analysis } }
        let ranked = CareerSemanticRanking.apply(baseline, analyses: current, focus: preferences.focus)
        if preferences.cityScope == "全国" { return ranked.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score } }
        return ranked
    }

    func analyzeNewJobs(preferences: CareerPreferences) async {
        guard modelEnabled, !modelBusy else { return }
        modelBusy = true; modelNotice = nil
        defer { modelBusy = false }
        do {
            let config = try PlannerCredentials.load().validated()
            guard !config.model.isEmpty, !config.modelKey.isEmpty else { throw CareerModelError.missingConfiguration }
            _ = try PlannerAPIConfiguration.modelEndpoint(config.modelBaseURL)
            let client = CareerModelNetworking(configuration: config)
            let candidates = CareerMatching.rank(jobs: jobs, preferences: preferences)
                .filter { modelAnalysis(for: $0.job, preferences: preferences) == nil }
                .compactMap { CareerModelInput(job: $0.job, preferences: preferences) }
            if candidates.isEmpty { modelNotice = "完整 JD 没有新增变化；列表线索不调用模型，已有分析复用缓存。"; return }
            var completed = 0, attempted = 0
            for input in candidates {
                guard attempted < 3 else { break }
                var reservation = modelBudget
                guard reservation.reserve(input) else { continue }
                // Persist the reservation before requesting, including failures or app termination.
                try persist(reservation, filename: "career-model-budget-v1.json"); modelBudget = reservation
                attempted += 1
                do {
                    let result = try await client.analyze(input)
                    var updated = modelAnalyses
                    updated[input.cacheKey] = CareerModelCachedAnalysis(signature: input.signature, analysis: result.analysis,
                        generatedAt: Date(), model: config.model, actualTokens: result.actualTokens, reservedTokens: input.reservedTokens)
                    let recentKeys = Set(updated.sorted { $0.value.generatedAt > $1.value.generatedAt }.prefix(150).map(\.key))
                    updated = updated.filter { recentKeys.contains($0.key) }
                    try persist(updated, filename: "career-model-analysis-v1.json"); modelAnalyses = updated
                    completed += 1
                } catch {
                    modelNotice = error.localizedDescription
                }
                if let actual = await client.lastActualTokens {
                    var budget = modelBudget; budget.actualTokens += actual
                    try persist(budget, filename: "career-model-budget-v1.json"); modelBudget = budget
                }
            }
            let resultMessage = "已分析 \(completed) 个岗位；今日剩余保守预算 \(modelRemainingTokens) Token。失败项当天不重复调用。"
            modelNotice = modelNotice.map { $0 + "\n" + resultMessage } ?? (attempted == 0 ? "今日预算不足或该输入已经尝试过；保留规则排序，明日可继续。" : resultMessage)
        } catch { modelNotice = error.localizedDescription }
    }

    func setFollowUp(_ value: CareerFollowUp, for job: CareerJob) {
        var updated = followUps
        updated[job.stableID] = value
        for url in job.sourceURLs { if let key = aliasKey(url) { updated[key] = value } }
        do { try persist(updated, filename: "career-follow-up-v1.json"); followUps = updated }
        catch { self.error = "无法保存岗位跟进状态，请重试。" }
    }

    private func persist<Value: Encodable>(_ value: Value, filename: String) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
    private func aliasKey(_ url: String) -> String? {
        let canonical = CareerMatching.canonicalURL(url)
        let related = CareerMatching.merge(jobs: jobs).filter { $0.sourceURLs.contains(where: { CareerMatching.canonicalURL($0) == canonical }) }
        guard Set(related.map(\.stableID)).count <= 1 else { return nil }
        return CareerMatching.identityKey(canonical, prefix: "url-")
    }

    private static func defaultDirectory() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("DaylightCareer", isDirectory: true)
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-testing"), let index = args.firstIndex(of: "--ui-test-run"), index + 1 < args.count,
           let run = UUID(uuidString: args[index + 1]) { return base?.appendingPathComponent("ui-" + run.uuidString, isDirectory: true) }
        #endif
        return base
    }

    private func migrateLegacyFollowUp() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "career-saved-qunhe") || (defaults.string(forKey: "career-stage-qunhe") ?? "未投递") != "未投递",
              let job = jobs.first(where: { CareerMatching.companyIdentity($0.company) == "群核科技" && $0.title.contains("具身") }),
              followUps[job.stableID] == nil else { return }
        let value = CareerFollowUp(saved: defaults.bool(forKey: "career-saved-qunhe"), stage: defaults.string(forKey: "career-stage-qunhe") ?? "未投递")
        setFollowUp(value, for: job)
    }

    private func legacySavedJob() -> CareerJob? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "career-saved-qunhe") || (defaults.string(forKey: "career-stage-qunhe") ?? "未投递") != "未投递" else { return nil }
        return CareerJob(id: "legacy-qunhe-embodied", sourceID: "zju", sourceName: "浙江大学招聘页",
            company: "群核科技", title: "科研算法实习生（具身智能方向）", city: "杭州拱墅", jobType: "实习", salary: "面议", location: "杭州拱墅",
            url: "https://www.career.zju.edu.cn/jyxt/sczp/zphgl/ckZphdwXq.zf?dwxxid=761C0E152EE024AFE055000000000001&zphbh=4A1E5434BDBC2BCEE0653A68DD0E9B18&zphsqbh=c580d07223d2c9238242b3455027755f",
            description: "从旧版本保留的已跟进岗位。招聘页曾列出具身仿真、模仿学习与评测相关方向；当前招聘状态未确认。",
            requirements: [], tags: ["具身仿真", "模仿学习"], publishedAt: "2026-03-02", checkedAt: "2026-10-05", status: "historical",
            minDays: nil, minMonths: nil, graduateYears: [], relatedURLs: [], verification: "full_jd")
    }
}
