import Foundation

struct CareerJob: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var sourceID: String
    var sourceName: String
    var company: String
    var title: String
    var city: String
    var jobType: String
    var salary: String
    var location: String
    var url: String
    var description: String
    var requirements: [String]
    var tags: [String]
    var publishedAt: String?
    var checkedAt: String
    var status: String
    var minDays: Int?
    var minMonths: Int?
    var graduateYears: [Int]
    var relatedURLs: [String]
    var verification: String? = nil
    var refreshedAt: String? = nil
    var deadline: String? = nil
    var sourceJobID: String? = nil
    var contentHash: String? = nil
    var companyIntro: String? = nil
    var sourceNote: String? = nil
    var requiredDegree: String? = nil

    var stableID: String {
        let originalID = sourceJobID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "url:" + CareerMatching.canonicalURL(url) + "|" + CareerMatching.companyIdentity(company) + "|" + CareerMatching.normalized(title) + "|" + CareerMatching.cityIdentity(city)
        let anchor = originalID?.isEmpty == false ? "id:" + originalID! : fallback
        return CareerMatching.identityKey("\(sourceID.lowercased())|\(anchor)", prefix: "job-")
    }
    var sourceURLs: [String] { Array(Set([url] + relatedURLs)).filter { CareerFeed.validLink($0) }.sorted() }
    var statusLabel: String {
        if status != "historical", status != "closed", verification == "listing_only" { return "列表线索 · 详情待核查" }
        switch status { case "verified": return verification == "full_jd" ? "网页可投，名额需确认" : "来源已核查，详情待确认"; case "historical": return "历史资料"; case "closed": return "已关闭"; default: return verification == "listing_only" ? "列表线索 · 详情待核查" : "招聘状态待核对" }
    }
}

struct CareerSource: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var state: String
    var lastAttemptAt: String?
    var lastSuccessAt: String?
    var count: Int
    var message: String
    var coverage: CareerSourceCoverage? = nil
    var nextAttemptAt: String? = nil
    var failureCount: Int? = nil
    var stateLabel: String {
        switch state {
        case "ok": return "采集成功"
        case "login_required": return "需要电脑登录"
        case "blocked": return "来源限制访问"
        case "not_configured": return "尚未配置"
        default: return "采集失败"
        }
    }
}

struct CareerSourceCoverage: Codable, Sendable, Equatable {
    var cities: [String]
    var keywords: [String]
    var companies: [String]
    var totalQueries: Int
    var queriesRun: Int
    var pagesRun: Int
    var detailsRun: Int
    var requests: Int
    var partial: Bool
    var mode: String? = nil
    var plannedKeywords: [String]? = nil
}

struct CareerFeedScheduler: Codable, Sendable, Equatable {
    var enabled: Bool
    var intervalHours: Int
    var nextRunAt: String
    var lastRunAt: String?
    var lastFinishedAt: String?
    var budgetDay: String
    var budgetUsed: Int
    var budgetLimit: Int
    var hostRequired: Bool
    var running: Bool? = nil
}

struct CareerFeedArticle: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var date: String
    var category: String
    var summary: String
    var relevance: String
    var url: String
}

struct CareerFeed: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var generatedAt: String
    var jobs: [CareerJob]
    var sources: [CareerSource]
    var articles: [CareerFeedArticle]
    var scheduler: CareerFeedScheduler? = nil

    static func decode(_ data: Data) throws -> CareerFeed {
        guard data.count <= 4_194_304 else { throw CareerFeedError.tooLarge }
        let value = try JSONDecoder().decode(CareerFeed.self, from: data)
        guard value.schemaVersion == 1, value.jobs.count <= 2000, value.sources.count <= 50,
              value.articles.count <= 100, value.generatedAt.count <= 80 else { throw CareerFeedError.invalidFeed }
        for job in value.jobs {
            guard !job.id.isEmpty, !job.company.isEmpty, !job.title.isEmpty, job.id.count <= 300,
                  job.company.count <= 500, job.title.count <= 500, job.description.count <= 30_000,
                  (job.companyIntro?.count ?? 0) <= 5000, (job.sourceNote?.count ?? 0) <= 5000,
                  job.requiredDegree.map({ ["bachelor", "master", "phd"].contains($0) }) ?? true,
                  job.requirements.count <= 100, job.requirements.allSatisfy({ $0.count <= 5000 }),
                  job.tags.count <= 100, job.tags.allSatisfy({ $0.count <= 200 }),
                  ["unconfirmed", "historical", "verified", "closed"].contains(job.status),
                  validLink(job.url), job.relatedURLs.count <= 100,
                  job.relatedURLs.allSatisfy(validLink),
                  job.minDays.map({ (1...7).contains($0) }) ?? true,
                  job.minMonths.map({ (1...36).contains($0) }) ?? true,
                  job.graduateYears.count <= 30 else { throw CareerFeedError.invalidFeed }
        }
        for source in value.sources {
            guard !source.id.isEmpty, source.count >= 0, source.count <= 100_000,
                  ["ok", "login_required", "blocked", "not_configured", "error"].contains(source.state),
                  source.message.count <= 3000 else { throw CareerFeedError.invalidFeed }
        }
        for article in value.articles {
            guard !article.id.isEmpty, article.title.count <= 500, article.summary.count <= 5000,
                  validLink(article.url) else { throw CareerFeedError.invalidFeed }
        }
        return value
    }

    static func validLink(_ text: String) -> Bool {
        guard text.count <= 4096, let url = URLComponents(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return true
    }
}

enum CareerFeedError: Error, LocalizedError, Sendable {
    case invalidFeed, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidFeed: return "岗位服务返回的数据格式不正确，保留上次内容。"
        case .tooLarge: return "岗位服务返回的数据过大，保留上次内容。"
        }
    }
}

struct CareerPreferences: Sendable, Equatable {
    var focus: String
    var cityScope: String
    var attendanceDays: Int?
    var durationMonths: Int?
    var start: String
    var expectedGraduationYear: Int? = nil
    var currentEducation: String = ""
    var capabilities: [CareerCapability] = []
}

struct CareerMatch: Identifiable, Sendable {
    let job: CareerJob
    let score: Int
    let reasons: [String]
    let gaps: [String]
    let conditions: [String]
    var id: String { job.stableID }
    var label: String {
        if job.verification == "listing_only" { return "相关列表线索" }
        if job.verification == "unreadable" { return "待核查线索" }
        return score >= 65 ? "优先查看" : score >= 40 ? "方向相关" : "相邻机会"
    }
}

enum CareerMatching {
    static func rank(jobs: [CareerJob], preferences: CareerPreferences, now: Date = Date()) -> [CareerMatch] {
        merge(jobs: jobs).filter { job in
            guard !["historical", "closed"].contains(job.status), preferences.cityScope != "只看杭州" || isHangzhou(job.city) else { return false }
            let intern = contains(job.jobType + job.title, ["实习", "intern"])
            guard intern else { return false }
            if let year = preferences.expectedGraduationYear, !job.graduateYears.isEmpty && !job.graduateYears.contains(year) { return false }
            if let required = job.requiredDegree, let own = degreeLevel(preferences.currentEducation),
               let needed = ["bachelor": 1, "master": 2, "phd": 3][required], own < needed { return false }
            if isExpired(job.deadline, now: now) { return false }
            if let required = job.minDays, let available = preferences.attendanceDays, available < required { return false }
            if let required = job.minMonths, let available = preferences.durationMonths, available < required { return false }
            let text = jobText(job)
            let irrelevantTitles = ["销售", "商务", "行政", "财务", "人事", "招聘专员", "市场运营", "法务"]
            return !irrelevantTitles.contains(where: { job.title.contains($0) }) &&
                contains(text, ["具身", "机器人", "机械臂", "仿真", "mujoco", "robot", "manipulation", "模仿学习", "运动控制", "灵巧手"])
        }.map { match($0, preferences: preferences) }.sorted {
            if preferences.cityScope == "杭州优先", isHangzhou($0.job.city) != isHangzhou($1.job.city) { return isHangzhou($0.job.city) }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.job.checkedAt != $1.job.checkedAt { return $0.job.checkedAt > $1.job.checkedAt }
            return $0.id < $1.id
        }
    }

    static func merge(jobs: [CareerJob]) -> [CareerJob] {
        var result: [CareerJob] = []
        for rows in Dictionary(grouping: jobs, by: semanticIdentity).values {
            var clusters: [[CareerJob]] = []
            for job in rows.sorted(by: { $0.stableID < $1.stableID }) {
                let index = clusters.firstIndex { group in
                    !group.contains(where: { separateSourceRecords($0, job) }) &&
                    group.contains(where: { canMerge($0, job, siblings: rows) })
                }
                if let index { clusters[index].append(job) } else { clusters.append([job]) }
            }
            result.append(contentsOf: clusters.map(mergedCluster))
        }
        return result.sorted { $0.stableID < $1.stableID }
    }

    static func canonicalURL(_ text: String) -> String {
        guard var parts = URLComponents(string: text) else { return text }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.host == "m.zhipin.com" { parts.host = "www.zhipin.com" }
        if parts.fragment?.hasPrefix("/") != true { parts.fragment = nil }
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        var tracking = Set(["spm", "trackingid"])
        if parts.host?.hasSuffix("zhipin.com") == true && parts.path.hasPrefix("/job_detail/") { tracking.insert("securityid") }
        let query = (parts.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") && !tracking.contains($0.name.lowercased()) }
            .sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
        parts.queryItems = query.isEmpty ? nil : query
        return parts.string ?? text
    }
    static func identityKey(_ text: String, prefix: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return prefix + String(hash, radix: 16)
    }
    private static func semanticIdentity(_ job: CareerJob) -> String {
        [companyIdentity(job.company), normalized(job.title), cityIdentity(job.city), normalized(job.jobType)].joined(separator: "|")
    }
    private static func sameEvidence(_ lhs: CareerJob, _ rhs: CareerJob) -> Bool {
        if let a = lhs.requiredDegree, let b = rhs.requiredDegree, a != b { return false }
        if let a = lhs.minDays, let b = rhs.minDays, a != b { return false }
        if let a = lhs.minMonths, let b = rhs.minMonths, a != b { return false }
        if !lhs.graduateYears.isEmpty && !rhs.graduateYears.isEmpty && Set(lhs.graduateYears) != Set(rhs.graduateYears) { return false }
        let first = normalized(([lhs.description] + lhs.requirements.sorted()).joined(separator: " "))
        let second = normalized(([rhs.description] + rhs.requirements.sorted()).joined(separator: " "))
        return first.count >= 24 && first == second
    }
    private static func canMerge(_ lhs: CareerJob, _ rhs: CareerJob, siblings: [CareerJob]) -> Bool {
        let leftURL = canonicalURL(lhs.url), rightURL = canonicalURL(rhs.url)
        if lhs.sourceID == rhs.sourceID {
            if let leftID = lhs.sourceJobID, let rightID = rhs.sourceJobID, !leftID.isEmpty, !rightID.isEmpty { return leftID == rightID }
            return leftURL == rightURL
        }
        let direct = leftURL == rightURL || lhs.relatedURLs.map(canonicalURL).contains(rightURL) || rhs.relatedURLs.map(canonicalURL).contains(leftURL)
        if direct { return true }
        guard sameEvidence(lhs, rhs) else { return false }
        // Identical boilerplate across separate teams is not enough to collapse them.
        for side in [lhs, rhs] {
            let other = side.sourceID == lhs.sourceID ? rhs : lhs
            let candidates = siblings.filter { $0.sourceID == side.sourceID && sameEvidence($0, other) }
            if Set(candidates.map { canonicalURL($0.url) }).count > 1 { return false }
        }
        return true
    }
    private static func mergedCluster(_ rows: [CareerJob]) -> CareerJob {
        // Keep the deterministic original source anchor while retaining stronger JD evidence.
        var winner = rows.sorted { $0.stableID < $1.stableID }[0]
        let ordered = rows.sorted { $0.checkedAt == $1.checkedAt ? statusPriority($0.status) > statusPriority($1.status) : $0.checkedAt > $1.checkedAt }
        let evidence = ordered.first(where: { $0.verification == "full_jd" }) ?? ordered[0]
        winner.description = evidence.description; winner.requirements = evidence.requirements
        winner.verification = evidence.verification; winner.minDays = evidence.minDays; winner.minMonths = evidence.minMonths
        winner.graduateYears = evidence.graduateYears; winner.deadline = evidence.deadline
        winner.requiredDegree = evidence.requiredDegree
        winner.publishedAt = evidence.publishedAt; winner.refreshedAt = evidence.refreshedAt; winner.checkedAt = evidence.checkedAt
        winner.salary = evidence.salary; winner.location = evidence.location; winner.status = evidence.status
        winner.companyIntro = evidence.companyIntro ?? winner.companyIntro; winner.sourceNote = evidence.sourceNote ?? winner.sourceNote
        if ordered[0].status == "closed" { winner.status = "closed" }
        winner.relatedURLs = Array(Set(rows.flatMap { [$0.url] + $0.relatedURLs })).filter { $0 != winner.url }.sorted()
        winner.sourceName = Array(Set(rows.map(\.sourceName))).sorted().joined(separator: " / ")
        winner.tags = Array(Set(rows.flatMap(\.tags))).sorted()
        return winner
    }
    private static func separateSourceRecords(_ lhs: CareerJob, _ rhs: CareerJob) -> Bool {
        guard lhs.sourceID == rhs.sourceID else { return false }
        if let left = lhs.sourceJobID, let right = rhs.sourceJobID, !left.isEmpty, !right.isEmpty { return left != right }
        return canonicalURL(lhs.url) != canonicalURL(rhs.url)
    }

    static func isHangzhou(_ city: String) -> Bool { city.localizedCaseInsensitiveContains("杭州") || city.localizedCaseInsensitiveContains("hangzhou") }
    private static func degreeLevel(_ text: String) -> Int? {
        if contains(text, ["博士", "phd", "ph.d", "doctorate"]) { return 3 }
        if contains(text, ["硕士", "研究生", "master"]) { return 2 }
        if contains(text, ["本科", "学士", "bachelor"]) { return 1 }
        return nil
    }
    static func isExpired(_ deadline: String?, now: Date = Date()) -> Bool {
        guard let deadline, !deadline.isEmpty else { return false }
        if deadline.count == 10 {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd"
            guard formatter.date(from: deadline) != nil else { return false }
            return deadline < formatter.string(from: now)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: deadline)
        formatter.formatOptions = [.withInternetDateTime]
        return (fractional ?? formatter.date(from: deadline)).map { $0 < now } ?? false
    }
    static func cityIdentity(_ text: String) -> String { isHangzhou(text) ? "杭州" : normalized(text) }
    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func companyIdentity(_ text: String) -> String {
        var value = normalized(text)
        for suffix in ["有限责任公司", "股份有限公司", "有限公司"] { value = value.replacingOccurrences(of: suffix, with: "") }
        if contains(value, ["群核", "manycore"]) { return "群核科技" }
        if contains(value, ["宇树", "unitree"]) { return "宇树科技" }
        if contains(value, ["云深处", "deeprobotics"]) { return "云深处科技" }
        for brand in ["西湖机器人", "灵西机器人", "微分智飞", "千寻智能", "原力无限", "联汇科技", "光轮智能", "蓝芯机器人", "灵步", "智无际", "中控信息", "有鹿机器人", "宇泛智能"] {
            if value.contains(brand) { return brand }
        }
        return value
    }

    private static func match(_ job: CareerJob, preferences: CareerPreferences) -> CareerMatch {
        let text = jobText(job)
        var score = 10
        var reasons: [String] = []
        var gaps: [String] = []
        var conditions: [String] = []
        let isIntern = contains(job.jobType + job.title, ["实习", "intern"])
        if isIntern { score += 16; reasons.append("岗位类型为实习。") }
        else { score -= 12; conditions.append("岗位未明确为实习，任职经历与用工类型需核对。") }
        let manipulationText = text.replacingOccurrences(of: "机器人操作系统", with: "ros").replacingOccurrences(of: "robot operating system", with: "ros")
        let learningManipulation = contains(manipulationText, ["模仿学习", "imitation", "操作学习", "具身操作", "manipulation", "抓取策略", "操作策略", "灵巧操作策略"])
        if learningManipulation {
            score += preferences.focus == "具身操作算法" ? 26 : 14
            reasons.append("岗位涉及操作或模仿学习，可优先核对具体算法、数据和闭环评测要求。")
        } else if contains(manipulationText, ["机械臂", "抓取", "操作算法"]) {
            score += 6
            reasons.append("岗位涉及机械臂或抓取，需核对具体运动学、控制和操作策略要求。")
        }
        if contains(text, ["仿真", "mujoco", "simulation"]) {
            score += preferences.focus == "机器人仿真算法" ? 26 : 17
            reasons.append("岗位涉及仿真或实验评测，可核对仿真平台和评测任务要求。")
        }
        if contains(text, ["pytorch", "python"]) {
            score += 10 + evidenceBonus(preferences.capabilities, id: "python_pytorch", terms: ["python", "pytorch"])
            reasons.append("岗位涉及 Python／PyTorch 技术栈。")
        }
        if contains(text, ["仿真", "mujoco", "模仿学习", "imitation"]) {
            score += evidenceBonus(preferences.capabilities, id: "mujoco_bc", terms: ["仿真", "mujoco", "模仿学习", "行为克隆", "bc"])
        }
        if contains(text, ["c++", "运动学", "kinematic", "控制", "ros", "系统集成"]) {
            score += preferences.focus == "机器人系统开发" ? 24 : 12
            score += evidenceBonus(preferences.capabilities, id: "cpp_kinematics", terms: ["c++", "运动学", "kinematic"])
            reasons.append("岗位涉及 C++、运动学或机器人系统开发。")
        }
        if contains(text, ["vla", "openvla", "π", "pi0", "大模型", "lora"]) {
            gaps.append(profileCapabilityNote("vla_plan", preferences: preferences, fallback: "岗位涉及 VLA／大模型操作方向，请核对画像中的相关经验状态。"))
        }
        if technicalTerm(text, "act") || technicalTerm(text, "lerobot") {
            gaps.append(profileCapabilityNote("act_testing", preferences: preferences, fallback: "岗位涉及 ACT／LeRobot，请核对画像中的相关经验状态和评测结果。"))
        }
        if contains(text, ["强化学习", "reinforcement", "ppo", "sac"]) {
            gaps.append(profileCapabilityNote("reinforcement_learning", preferences: preferences, fallback: "岗位涉及强化学习，请核对画像中的相关项目经验。"))
        }
        let required = (job.requirements + job.description.components(separatedBy: CharacterSet(charactersIn: "。；;\n")))
            .filter { contains($0, ["要求", "须", "熟悉", "熟练", "掌握", "经验", "必备"]) && !contains($0, ["优先", "加分", "可选"]) }.joined(separator: " ")
        if contains(required, ["vla", "openvla", "大模型", "lora"]) {
            score += confirmedEvidence(preferences.capabilities, topicID: "vla_plan", terms: ["vla", "openvla", "大模型", "lora"]) ? 4 : -8
        }
        if contains(required, ["强化学习", "reinforcement", "ppo", "sac"]) {
            score += confirmedEvidence(preferences.capabilities, topicID: "reinforcement_learning", terms: ["强化学习", "reinforcement", "ppo", "sac"]) ? 4 : -8
        }
        if contains(text, ["ros2", "moveit"]) { gaps.append(profileCapabilityNote("ros_basics", preferences: preferences, fallback: "岗位涉及 ROS2／MoveIt，请核对画像中的相关经验状态。")) }
        if contains(text, ["博士", "phd"]) { conditions.append("原页提及博士，需核对是学历硬要求、优先条件还是包含多个在读层次。") }
        if let year = preferences.expectedGraduationYear, !job.graduateYears.isEmpty && !job.graduateYears.contains(year) {
            score -= 20; conditions.append("岗位毕业年份要求与已填写的毕业年份不一致。")
        }
        if let days = job.minDays {
            if let own = preferences.attendanceDays { conditions.append(own >= days ? "已选每周 \(own) 天，符合来源写明的至少 \(days) 天。" : "已选每周 \(own) 天，低于来源写明的至少 \(days) 天。"); if own < days { score -= 20 } }
            else { conditions.append("来源要求每周至少 \(days) 天；你的出勤未定，待核对。") }
        } else { conditions.append("来源未写明每周出勤要求，待核对。") }
        if let months = job.minMonths {
            if let own = preferences.durationMonths { conditions.append(own >= months ? "已选 \(own) 个月，符合来源写明的至少 \(months) 个月。" : "已选 \(own) 个月，短于来源写明的至少 \(months) 个月。"); if own < months { score -= 20 } }
            else { conditions.append("来源要求至少 \(months) 个月；你的时长未定，待核对。") }
        } else { conditions.append("来源未写明实习时长要求，待核对。") }
        conditions.append(preferences.start == "未定" ? "到岗时间未定，需与招聘方确认。" : "已选到岗：\(preferences.start)，具体日期需与招聘方确认。")
        if job.city.contains("/") || job.city.contains("、") || job.city.contains("或") { conditions.append("原页列出多个城市，实际团队工作地点需向招聘方确认。") }
        if job.verification == "listing_only" { gaps.insert("当前只读取到招聘列表，职责和要求尚未核查；匹配仅基于列表标题与标签。", at: 0) }
        if job.verification == "unreadable" { gaps.insert("来源详情当前不可读取，需打开原页核对完整职责。", at: 0) }
        if reasons.isEmpty { reasons.append("机器人相关方向线索，需进一步核对岗位职责。") }
        return CareerMatch(job: job, score: max(0, min(100, score)), reasons: reasons, gaps: gaps, conditions: conditions)
    }
    private static func jobText(_ job: CareerJob) -> String { ([job.title, job.description] + job.requirements + job.tags).joined(separator: " ").lowercased() }
    private static func confirmedEvidence(_ capabilities: [CareerCapability], topicID: String, terms: [String]) -> Bool {
        capabilities.contains { ($0.id == topicID || contains($0.label, terms)) && $0.status == "confirmed" &&
            !$0.fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && contains($0.fact, terms) }
    }
    private static func evidenceBonus(_ capabilities: [CareerCapability], id: String, terms: [String]) -> Int {
        guard let item = capabilities.first(where: { $0.id == id }), contains(item.fact, terms) else { return 0 }
        return item.status == "confirmed" ? 3 : item.status == "partial" ? 1 : 0
    }
    private static func profileCapabilityNote(_ id: String, preferences: CareerPreferences, fallback: String) -> String {
        guard let capability = preferences.capabilities.first(where: { $0.id == id }) else { return fallback }
        let state: String
        switch capability.status {
        case "confirmed": state = "已确认"
        case "partial": state = "部分经验"
        case "planned": state = "计划学习"
        default: state = "待确认"
        }
        return "岗位涉及\(capability.label)，本机画像状态：\(state)。具体要求仍需核对。"
    }
    private static func contains(_ text: String, _ values: [String]) -> Bool { values.contains { text.localizedCaseInsensitiveContains($0) } }
    private static func technicalTerm(_ text: String, _ term: String) -> Bool { text.range(of: "(?i)(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Za-z0-9])", options: .regularExpression) != nil }
    private static func statusPriority(_ value: String) -> Int { ["closed": 5, "verified": 4, "unconfirmed": 3, "historical": 1][value] ?? 0 }
}
