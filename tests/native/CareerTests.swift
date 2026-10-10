import Foundation

private final class CareerFixtureProtocol: URLProtocol {
    static var reply: (Int, Data) = (200, Data())
    static var captured: URLRequest?
    static var failPublicPrimary = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        let code = Self.failPublicPrimary && request.url?.host == "raw.githubusercontent.com" ? 503 : Self.reply.0
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum CareerTests {
    static func run() async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ label: String) throws { checks += 1; if !value { throw AppFailure.message("FAIL: career \(label)") } }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var failed = false; do { try action() } catch { failed = true }; try expect(failed, label)
        }
        let now = ISO8601DateFormatter().date(from: "2026-10-06T04:00:00Z")!
        let job = CareerJob(id: "synthetic-job", sourceID: "boss", sourceName: "BOSS", company: "群核科技", title: "机械臂仿真算法实习生", city: "杭州", jobType: "实习", salary: "面议", location: "杭州", url: "https://www.zhipin.com/job_detail/fixture.html", description: "MuJoCo Python PyTorch 模仿学习、机械臂抓取闭环评测", requirements: [], tags: [], publishedAt: nil, checkedAt: "2026-10-06T04:00:00Z", status: "unconfirmed", minDays: 4, minMonths: 3, graduateYears: [], relatedURLs: [], verification: "listing_only")
        let preferences = CareerPreferences(focus: "具身操作算法", cityScope: "杭州优先", attendanceDays: nil, durationMonths: nil, start: "未定",
            expectedGraduationYear: 2030, currentEducation: "硕士在读")
        let ranked = CareerMatching.rank(jobs: [job], preferences: preferences, now: now)
        try expect(ranked.count == 1, "unknown internship conditions preserve a relevant lead")
        try expect(ranked[0].conditions.contains { $0.contains("未定") }, "unknown condition explicitly awaits confirmation")
        try expect(job.statusLabel.contains("线索"), "listing is not labelled available for application")
        var closed = job; closed.status = "closed"
        var historical = job; historical.status = "historical"
        try expect(CareerMatching.rank(jobs: [closed, historical], preferences: preferences, now: now).isEmpty, "closed and historical excluded")
        var expired = job; expired.deadline = "2026-10-05T23:59:59+08:00"
        try expect(CareerMatching.rank(jobs: [expired], preferences: preferences, now: now).isEmpty, "cached expired job excluded without refresh")
        var sdk = job; sdk.graduateYears = [2027]
        try expect(CareerMatching.rank(jobs: [sdk], preferences: preferences, now: now).isEmpty, "graduation mismatch is filtered using profile input")
        let genericPreferences = CareerPreferences(focus: "具身操作算法", cityScope: "全国", attendanceDays: nil, durationMonths: nil, start: "未定")
        try expect(CareerMatching.rank(jobs: [sdk], preferences: genericPreferences, now: now).count == 1, "graduation year is not assumed without a local profile")
        var doctoral = job; doctoral.requiredDegree = "phd"
        try expect(CareerMatching.rank(jobs: [doctoral], preferences: preferences, now: now).isEmpty, "explicit doctorate-only role incompatible with current master's enrollment")
        try expect(CareerMatching.rank(jobs: [doctoral], preferences: genericPreferences, now: now).count == 1, "degree is not assumed without a local profile")
        var fulltime = job; fulltime.title = "机器人算法工程师"; fulltime.jobType = "全职"
        try expect(CareerMatching.rank(jobs: [fulltime], preferences: preferences, now: now).isEmpty, "fulltime job is not an internship recommendation")
        var other = job; other.id = "other"; other.city = "上海"
        try expect(CareerMatching.rank(jobs: [other, job], preferences: preferences, now: now).first?.job.city == "杭州", "Hangzhou comes first")
        var only = preferences; only.cityScope = "只看杭州"
        try expect(CareerMatching.rank(jobs: [other, job], preferences: only, now: now).count == 1, "Hangzhou only respects location")
        var duplicate = job; duplicate.id = "other-source-id"; duplicate.company = "杭州群核信息技术有限公司"; duplicate.sourceID = "zju"; duplicate.sourceName = "高校"; duplicate.url = "https://www.career.zju.edu.cn/job"
        let merged = CareerMatching.merge(jobs: [job, duplicate])
        try expect(merged.count == 1 && merged[0].sourceURLs.count == 2, "cross-source duplicates merge and retain evidence links")
        var secondTeam = job; secondTeam.id = "different-team"; secondTeam.url = "https://www.zhipin.com/job_detail/different-team.html"; secondTeam.description = "另一研发团队负责 ROS 驱动与控制"
        try expect(CareerMatching.merge(jobs: [job, secondTeam]).count == 2, "same company and title with distinct source URLs remain separate jobs")
        var insufficient = duplicate; insufficient.description = "详情暂不可读"; insufficient.requirements = []; insufficient.minDays = nil; insufficient.minMonths = nil
        try expect(CareerMatching.merge(jobs: [job, insufficient]).count == 2, "cross-source title-only similarity is insufficient for merging")
        var limited = preferences; limited.attendanceDays = 3
        try expect(CareerMatching.rank(jobs: [job], preferences: limited, now: now).isEmpty, "known attendance shortfall excluded")
        limited = preferences; limited.durationMonths = 2
        try expect(CareerMatching.rank(jobs: [job], preferences: limited, now: now).isEmpty, "known duration shortfall excluded")
        var vla = job; vla.description += " VLA LoRA ACT 强化学习 PPO ROS2"
        let vlaMatch = CareerMatching.rank(jobs: [vla], preferences: preferences, now: now)[0]
        try expect(vlaMatch.gaps.contains { $0.contains("VLA") } && vlaMatch.gaps.contains { $0.contains("强化学习") }, "planned VLA and absent RL become gaps")
        var ros = job; ros.description = "机器人操作系统 ROS 驱动"; ros.title = "机器人软件实习生"
        let rosMatch = CareerMatching.rank(jobs: [ros], preferences: preferences, now: now)[0]
        try expect(!rosMatch.reasons.contains { $0.contains("本机画像") }, "robot operating system is not manipulation experience")
        let feed = CareerFeed(schemaVersion: 1, generatedAt: "2026-10-06T04:00:00Z", jobs: [job], sources: [], articles: [])
        let bytes = try JSONEncoder().encode(feed)
        try expect(try CareerFeed.decode(bytes).jobs.count == 1, "feed decodes valid research cache")
        var unsafe = feed; unsafe.jobs[0].url = "javascript:alert(1)"
        try rejects("unsafe source link rejected") { _ = try CareerFeed.decode(JSONEncoder().encode(unsafe)) }
        unsafe = feed; unsafe.schemaVersion = 8
        try rejects("unsupported schema rejected") { _ = try CareerFeed.decode(JSONEncoder().encode(unsafe)) }
        let config = CareerAPIConfiguration(baseURL: "http://127.0.0.1:4176", token: "synthetic-career-token")
        try expect(try config.endpoint(refresh: false).path == "/v1/career/feed", "read endpoint configured")
        try expect(try config.endpoint(refresh: true).path == "/v1/career/refresh", "refresh endpoint configured")
        try rejects("numeric prefix does not allow public plaintext token") { _ = try CareerAPIConfiguration(baseURL: "http://192.168.1.10.example.com", token: "synthetic").endpoint(refresh: false) }
        try rejects("header newline rejected") { _ = try CareerAPIConfiguration(baseURL: "https://jobs.example.com", token: "x\ny").endpoint(refresh: false) }
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [CareerFixtureProtocol.self]
        let session = URLSession(configuration: settings); defer { session.invalidateAndCancel() }
        let client = CareerNetworking(configuration: config, session: session)
        CareerFixtureProtocol.reply = (200, bytes)
        let received = try await client.fetch(refresh: false)
        try expect(received.jobs.count == 1 && CareerFixtureProtocol.captured?.httpMethod == "GET", "client reads actual feed protocol")
        try expect(CareerFixtureProtocol.captured?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-career-token", "client sends own collector credential")
        _ = try await client.fetch(refresh: true)
        try expect(CareerFixtureProtocol.captured?.httpMethod == "POST", "client requests bounded server refresh")
        CareerFixtureProtocol.reply = (202, bytes)
        try expect(try await client.fetch(refresh: true).jobs.count == 1, "asynchronous collection returns usable cached feed without blocking app")
        CareerFixtureProtocol.reply = (401, Data("{}".utf8))
        var rejected = false; do { _ = try await client.fetch(refresh: false) } catch CareerServiceError.http(401) { rejected = true }
        try expect(rejected, "auth failure remains specific")
        CareerFixtureProtocol.reply = (200, Data("invalid".utf8))
        rejected = false; do { _ = try await client.fetch(refresh: false) } catch { rejected = true }
        try expect(rejected, "malformed response is not successful empty jobs")
        try expect(CareerPublicContent.cleaned(feed).jobs.isEmpty, "removed providers are excluded from public and private display")
        let publicURL = URL(string: "https://raw.githubusercontent.com/example/example/main/public/career-feed.json")!
        try expect(CareerPublicEndpoint.validated(publicURL.absoluteString) != nil, "public HTTPS endpoint accepted")
        try expect(CareerPublicEndpoint.validated("http://raw.githubusercontent.com/example/example/main/public/career-feed.json") == nil, "public plaintext rejected")
        CareerFixtureProtocol.reply = (200, bytes)
        let publicClient = CareerPublicNetworking(session: session)
        _ = try await publicClient.fetch(url: publicURL)
        try expect(CareerFixtureProtocol.captured?.httpMethod == "GET" && CareerFixtureProtocol.captured?.value(forHTTPHeaderField: "Authorization") == nil && CareerFixtureProtocol.captured?.httpBody == nil, "public read sends no profile or secret")
        CareerFixtureProtocol.failPublicPrimary = true
        defer { CareerFixtureProtocol.failPublicPrimary = false }
        _ = try await publicClient.fetch(url: publicURL)
        try expect(CareerFixtureProtocol.captured?.url?.host == "api.github.com" && CareerFixtureProtocol.captured?.value(forHTTPHeaderField: "Authorization") == nil, "public CDN outage falls back to credential-free contents API")
        let today = CareerFeedArticle(id: "today", title: "Robot policy", date: "2026-10-06T00:00:00+08:00", category: "论文", summary: "Source abstract", relevance: "", url: "https://arxiv.org/abs/2610.00001")
        var old = today; old.id = "old"; old.date = "2026-10-01T00:00:00+08:00"
        var unknown = today; unknown.id = "unknown"; unknown.date = ""; unknown.dateVerified = false
        var future = today; future.id = "future"; future.date = "2026-10-07T00:00:00+08:00"
        let articles = [old, today, unknown, future]
        try expect(CareerReportPeriod.date("2026-10-06T00:00:00.000Z") != nil, "real API fractional dates are supported")
        try expect(CareerReportPeriod.articles(articles, days: 1, now: now).map(\.id) == ["today"], "daily report contains only today's confirmed publications")
        try expect(Set(CareerReportPeriod.articles(articles, days: 7, now: now).map(\.id)) == Set(["today", "old"]), "weekly report excludes unknown dates and future papers")
        return checks
    }
}
