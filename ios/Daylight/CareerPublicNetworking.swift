import Foundation

enum CareerPublicEndpoint {
    static var url: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CareerPublicFeedURL") as? String else { return nil }
        return validated(value)
    }
    static func validated(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              parts.host == "raw.githubusercontent.com", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasSuffix("/public/career-feed.json") else { return nil }
        return parts.url
    }
}

actor CareerPublicNetworking {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 25; settings.timeoutIntervalForResource = 40
            settings.urlCache = nil; settings.httpCookieStorage = nil
            self.session = URLSession(configuration: settings)
        }
    }
    func fetch(url: URL) async throws -> CareerFeed {
        guard CareerPublicEndpoint.validated(url.absoluteString) != nil else { throw CareerServiceError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Public feed GET contains no credentials, profile, search text or device data.
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CareerPublicError.unavailable }
            guard response.url?.host == url.host, response.expectedContentLength <= 4_194_304 else { throw CareerFeedError.invalidFeed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4_194_304 else { throw CareerFeedError.tooLarge }
                data.append(byte)
            }
            let feed = try CareerFeed.decode(data)
            // Reject content from providers removed from this product's collection scope.
            return CareerPublicContent.cleaned(feed)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw CareerPublicError.unavailable
        }
    }
}

enum CareerPublicError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "公开更新暂时无法读取，上次内容仍可查看。稍后点击刷新重试。" }
}

enum CareerPublicContent {
    static func excluded(_ job: CareerJob) -> Bool {
        let host = URL(string: job.url)?.host?.lowercased() ?? ""
        return ["boss", "shixiseng", "shixiseng-public"].contains(job.sourceID) ||
            host == "zhipin.com" || host.hasSuffix(".zhipin.com") ||
            host == "shixiseng.com" || host.hasSuffix(".shixiseng.com")
    }
    static func cleaned(_ original: CareerFeed) -> CareerFeed {
        var value = original
        value.jobs.removeAll(where: excluded)
        value.sources.removeAll { ["boss", "shixiseng", "shixiseng-public"].contains($0.id) }
        return value
    }
}

enum CareerReportPeriod {
    static func date(_ value: String) -> Date? {
        if let result = ISO8601DateFormatter().date(from: value) { return result }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = fractional.date(from: value) { return result }
        guard value.count == 10 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)
    }
    static func articles(_ values: [CareerFeedArticle], days: Int, now: Date = Date()) -> [CareerFeedArticle] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        return values.filter { article in
            guard article.dateVerified != false, let published = date(article.date) else { return false }
            return published >= start && published < end && published <= now
        }.sorted { $0.date > $1.date }
    }
}
