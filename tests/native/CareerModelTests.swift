import Foundation

private final class CareerModelFixtureProtocol: URLProtocol {
    static var reply: (Int, Data) = (200, Data())
    static var captured: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.captured = captured
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.1); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum CareerModelTests {
    static func run() async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ message: String) throws { checks += 1; if !value { throw AppFailure.message("FAIL: career model \(message)") } }
        func rejects(_ text: String, input: CareerModelInput, _ message: String) throws {
            var didReject = false; do { _ = try CareerModelAnalysis.decode(text, input: input) } catch { didReject = true }
            try expect(didReject, message)
        }
        let defaults = UserDefaults.standard
        let profileKeys = [CareerProfileDocument.storageKey, "career-focus", "career-city-scope", "career-attendance", "career-duration", "career-start"]
        let oldProfileValues = Dictionary(uniqueKeysWithValues: profileKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        defer {
            for key in profileKeys { if let value = oldProfileValues[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        }
        var testProfile = CareerProfileDocument()
        testProfile.currentEducation = "Test graduate"
        testProfile.expectedGraduationYear = 2030
        testProfile.capabilities = testProfile.capabilities.map { item in
            let confirmed = ["python_pytorch", "mujoco_bc", "cpp_kinematics", "robot_integration", "ros_basics"].contains(item.id)
            let status = item.id == "act_testing" ? "partial" : item.id == "vla_plan" ? "planned" : confirmed ? "confirmed" : "unknown"
            return CareerCapability(id: item.id, label: item.label, fact: "Synthetic test evidence for \(item.id).", status: status)
        }
        try testProfile.saveLocally()
        try expect(CareerProfileDocument.decode(try testProfile.encoded()) == testProfile, "local profile JSON round-trips")
        try expect(CareerModelProfile.publicDefaults.allSatisfy { $0.fact.isEmpty && $0.status == "unknown" }, "public build defaults contain no personal profile facts")
        let profileBackup = try BackupCodec.decodeBundle(BackupCodec.export(Snapshot(), careerProfile: testProfile))
        try expect(profileBackup.careerProfile == testProfile, "complete backup includes the local career profile")
        try expect(try BackupCodec.decodeBundle(BackupCodec.export(Snapshot())).careerProfile == nil, "older backups without a career profile still import")
        var unsupportedClaim = testProfile
        unsupportedClaim.capabilities[0].fact = ""
        try expect(!unsupportedClaim.isValid, "confirmed skills require a concrete fact")
        let now = ISO8601DateFormatter().date(from: "2026-10-06T04:00:00Z")!
        let prefs = CareerPreferences(focus: "具身操作算法", cityScope: "杭州优先", attendanceDays: nil, durationMonths: nil, start: "未定",
            expectedGraduationYear: 2030, currentEducation: "Test graduate", capabilities: testProfile.capabilities)
        let job = CareerJob(id: "synthetic-semantic", sourceID: "fixture", sourceName: "测试来源", company: "测试机器人公司", title: "具身操作算法实习生", city: "杭州", jobType: "实习", salary: "面议", location: "杭州", url: "https://jobs.example.com/robotics-intern", description: "使用 Python、PyTorch 开发 MuJoCo 仿真任务、模仿学习策略和闭环评测。关注 ACT、VLA 操作策略。", requirements: [], tags: [], publishedAt: nil, checkedAt: "2026-10-06T04:00:00Z", status: "unconfirmed", minDays: nil, minMonths: nil, graduateYears: [], relatedURLs: [], verification: "full_jd")
        guard let input = CareerModelInput(job: job, preferences: prefs) else { throw AppFailure.message("FAIL: model input") }
        try expect(input.excerpt.count <= 1200 && input.reservedTokens <= 6000, "bounded excerpt fits conservative daily budget")
        try expect(!input.userJSON.contains("姓名") && !input.userJSON.contains("modelKey"), "model input excludes contact and API credential fields")
        var listing = job; listing.verification = "listing_only"
        try expect(CareerModelInput(job: listing, preferences: prefs) == nil, "unread listing never spends model tokens")
        var historical = job; historical.status = "historical"
        try expect(CareerModelInput(job: historical, preferences: prefs) == nil, "historical listing skipped")
        let object: [String: Any] = ["jobID": input.jobID, "direction": "manipulation", "assessments": [
            ["skillID": "python_pytorch", "level": "met", "quote": "Python、PyTorch", "reason": "测试画像提供了相关框架使用证据。"],
            ["skillID": "act_testing", "level": "partial", "quote": "ACT", "reason": "目前仍在测试。"]], "summary": "操作与仿真方向相关，ACT 结果仍需补充。"]
        func json(_ value: [String: Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
        let text = try json(object)
        let result = try CareerModelAnalysis.decode(text, input: input)
        try expect(result.direction == "manipulation" && result.assessments.count == 2, "valid cited capability analysis accepted")
        var invalid = object; invalid["jobID"] = "another-job"
        try rejects(try json(invalid), input: input, "another job ID rejected")
        invalid = object; invalid["salary"] = "改变薪资"
        try rejects(try json(invalid), input: input, "extra recruitment facts cannot be mutated")
        invalid = object; invalid["assessments"] = [["skillID": "vla_plan", "level": "met", "quote": "VLA", "reason": "计划不能等于掌握。"]]
        try rejects(try json(invalid), input: input, "planned VLA never satisfies requirement")
        invalid = object; invalid["assessments"] = [["skillID": "act_testing", "level": "met", "quote": "ACT", "reason": "测试不能等于完成。"]]
        try rejects(try json(invalid), input: input, "unfinished ACT never marked met")
        invalid = object; invalid["assessments"] = [["skillID": "nonexistent", "level": "met", "quote": "ACT", "reason": "虚构技能。"]]
        try rejects(try json(invalid), input: input, "invented capability rejected")
        invalid = object; invalid["assessments"] = [["skillID": "python_pytorch", "level": "met", "quote": "不存在的职位要求", "reason": "虚构引用。"]]
        try rejects(try json(invalid), input: input, "fabricated JD quote rejected")
        var budget = CareerModelDailyBudget(day: CareerModelDailyBudget.dayKey(now))
        try expect(budget.reserve(input, now: now), "first request reserved before networking")
        try expect(!budget.reserve(input, now: now), "same input including failed attempt not retried today")
        try expect(budget.reserve(input, now: now.addingTimeInterval(86_400)), "next day explicitly requested retry can reserve")
        var changed = prefs; changed.durationMonths = 3
        try expect(CareerModelInput(job: job, preferences: changed)?.signature != input.signature, "changed preference invalidates semantic cache")
        let baseline = CareerMatching.rank(jobs: [job], preferences: prefs, now: now)
        let unrelated = CareerModelAnalysis(jobID: input.jobID, direction: "unrelated", assessments: result.assessments, summary: "仅语义分类参考。")
        let lowRelated = CareerSemanticRanking.apply(baseline, analyses: [input.jobID: unrelated], focus: prefs.focus)
        try expect(lowRelated.count == 1 && lowRelated[0].score == 0 && lowRelated[0].job == job && lowRelated[0].reasons.first!.contains("仍可查看"), "low semantic relevance lowers ranking but keeps original job reviewable")
        let ranked = CareerSemanticRanking.apply(baseline, analyses: [input.jobID: result], focus: prefs.focus)
        try expect(ranked[0].job == baseline[0].job, "semantic sorting never changes recruitment facts")
        var independent = job; independent.id = "different-team"; independent.url = "https://jobs.example.com/second-team"; independent.description = "第二个独立团队负责机器人系统集成，要求 C++ 开发。"
        try expect(CareerMatching.merge(jobs: [job, independent]).count == 2, "different same-source URLs and teams preserved")
        var originalA = job; originalA.sourceJobID = "original-team-A"
        var originalB = job; originalB.sourceJobID = "original-team-B"
        try expect(CareerMatching.merge(jobs: [originalA, originalB]).count == 2 && originalA.stableID != originalB.stableID, "explicit different original IDs retain distinct teams even at same URL")
        let unsupported: [(String, String, String)] = [
            ("ros_basics", "ROS2 与 MoveIt2", "岗位要求熟练 ROS2 与 MoveIt2，有丰富机器人真实场景工程经验，并承担控制软件联调。"),
            ("cpp_kinematics", "逆运动学 IK", "需要精通机械臂逆运动学 IK 与运动规划，使用 C++ 完成相关算法开发和优化。"),
            ("mujoco_bc", "强化学习 PPO", "要求熟悉强化学习 PPO 和 SAC，使用 MuJoCo 训练运动控制策略，并完成效果评测。"),
            ("python_pytorch", "PyTorch 分布式训练", "要求掌握 PyTorch 分布式训练与大模型部署，负责多机多卡模型训练和持续评测。")
        ]
        for (skill, quote, description) in unsupported {
            var advanced = job; advanced.description = description
            guard let advancedInput = CareerModelInput(job: advanced, preferences: prefs) else { throw AppFailure.message("FAIL: advanced input") }
            let exaggerated: [String: Any] = ["jobID": advancedInput.jobID, "direction": "systems", "assessments": [["skillID": skill, "level": "met", "quote": quote, "reason": "错误地把基础经验算作高级能力。"]], "summary": "错误的高级满足判断。"]
            try rejects(try json(exaggerated), input: advancedInput, "confirmed capability cannot overstate \(skill)")
        }
        var freeClaim = object; freeClaim["summary"] = "用户精通 ROS2 与分布式大模型部署，必能录用。"
        let bounded = try CareerModelAnalysis.decode(try json(freeClaim), input: input)
        try expect(!bounded.safeSummary.contains("精通") && !bounded.safeSummary.contains("录用"), "UI summary is derived from validated enums rather than free claims")
        var control = job; control.id = "control"; control.url = "https://jobs.example.com/control"; control.title = "机械臂运控实习生"; control.description = "使用 C++ 实现机械臂正运动学 FK 和机器人操作系统 ROS 驱动。"
        let focused = CareerMatching.rank(jobs: [job, control], preferences: prefs, now: now)
        try expect(focused.first?.job.url == job.url && !focused.first(where: { $0.job.url == control.url })!.reasons.contains { $0.contains("本机画像") }, "BC manipulation outranks FK control without false profile reason")
        var simulationPrefs = prefs; simulationPrefs.focus = "机器人仿真算法"
        try expect(CareerMatching.rank(jobs: [job, control], preferences: simulationPrefs, now: now).first?.job.url == job.url, "simulation focus favors MuJoCo over FK control")
        var companyOnly = control; companyOnly.companyIntro = "公司研发 MuJoCo 模仿学习与具身操作。"; companyOnly.sourceNote = "候选人规划 VLA。"
        try expect(CareerMatching.rank(jobs: [companyOnly], preferences: prefs, now: now).first?.score == CareerMatching.rank(jobs: [control], preferences: prefs, now: now).first?.score,
            "company introduction and source note never count as job responsibilities")
        var demanding = job; demanding.url = "https://jobs.example.com/advanced-policy"; demanding.requirements = ["要求掌握 VLA/LoRA 与强化学习 PPO 项目经验。"]
        try expect(CareerMatching.rank(jobs: [demanding], preferences: prefs, now: now).first!.score < CareerMatching.rank(jobs: [job], preferences: prefs, now: now).first!.score,
            "explicit unconfirmed VLA and RL requirements reduce rule ranking")
        var learned = prefs
        learned.capabilities = prefs.capabilities.map { item in
            if item.id == "vla_plan" { return CareerCapability(id: item.id, label: item.label, fact: "完成 VLA LoRA 操作项目和评测。", status: "confirmed") }
            if item.id == "reinforcement_learning" { return CareerCapability(id: item.id, label: item.label, fact: "完成强化学习 PPO 项目和评测。", status: "confirmed") }
            return item
        }
        try expect(CareerMatching.rank(jobs: [demanding], preferences: learned, now: now).first!.score > CareerMatching.rank(jobs: [demanding], preferences: prefs, now: now).first!.score,
            "new confirmed evidence changes rule ranking without changing collected jobs")
        try expect(CareerModelInput(job: demanding, preferences: learned)?.signature != CareerModelInput(job: demanding, preferences: prefs)?.signature,
            "model cache follows the profile snapshot passed to the request")
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [CareerModelFixtureProtocol.self]
        let session = URLSession(configuration: settings); defer { session.invalidateAndCancel() }
        let config = PlannerAPIConfiguration(modelBaseURL: "https://api.deepseek.com", model: "synthetic-model", modelKey: "synthetic-model-key", amapKey: "")
        let client = CareerModelNetworking(configuration: config, session: session)
        CareerModelFixtureProtocol.reply = (200, try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": text]]], "usage": ["total_tokens": 321]]))
        let received = try await client.analyze(input)
        try expect(received.analysis == result && received.actualTokens == 321, "client parses model result and real usage protocol")
        try expect(CareerModelFixtureProtocol.captured?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-model-key", "model key goes only to model endpoint")
        guard let requestBytes = CareerModelFixtureProtocol.captured?.httpBody,
              let payload = try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any] else { throw AppFailure.message("FAIL: model request body") }
        try expect(payload["max_tokens"] as? Int == 800 && payload["stream"] as? Bool == false, "output limit enforced in request")
        CareerModelFixtureProtocol.reply = (200, try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": "truncated"]]], "usage": ["total_tokens": 77]]))
        do { _ = try await client.analyze(input); throw AppFailure.message("FAIL: truncated model output accepted") } catch CareerModelError.invalidResponse { }
        let consumed = await client.lastActualTokens
        try expect(consumed == 77, "actual usage retained even for truncated rejected output")
        CareerModelFixtureProtocol.reply = (401, Data("{}".utf8))
        var rejected = false; do { _ = try await client.analyze(input) } catch PlannerServiceError.http(401) { rejected = true }
        try expect(rejected, "auth error does not trigger retry or fabricated match")
        return checks
    }
}
