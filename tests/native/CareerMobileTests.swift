import Foundation

enum CareerMobileTests {
    static func run() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ reason: String) throws { checks += 1; if !condition { throw AppFailure.message("Career mobile: " + reason) } }
        let noteID = String(repeating: "a", count: 24)
        let noteURL = "https://www.xiaohongshu.com/explore/\(noteID)?xsec_token=fixture%2Bvalue&xsec_source=pc_search"
        let noteLink = CareerSourceLink(urlString: noteURL, sourceID: "xiaohongshu", noteID: noteID)
        try expect(noteLink?.appURL?.absoluteString == "xhsdiscover://item/\(noteID)", "note route opens specific ID, never home")
        try expect(noteLink?.webURL.absoluteString == noteURL, "web fallback retains original note access parameters")
        try expect(CareerSourceLink(urlString: noteURL, sourceID: "xiaohongshu", noteID: String(repeating: "b", count: 24)) == nil, "mismatched note ID rejected")
        try expect(CareerSourceLink(urlString: "https://evil.test/explore/\(noteID)", sourceID: "xiaohongshu") == nil, "external host cannot become trusted note route")
        try expect(CareerSourceLink(urlString: "https://www.xiaohongshu.com/explore/not-an-id", sourceID: "xiaohongshu") == nil, "invalid note identifier rejected")
        let bossLink = CareerSourceLink(urlString: "https://www.zhipin.com/job_detail/example123.html", sourceID: "boss")
        try expect(bossLink?.universalOnly == true && bossLink?.appURL == bossLink?.webURL, "BOSS opens exact source URL through platform association")
        try expect(CareerSourceLink(urlString: "javascript:alert(1)", sourceID: "official") == nil, "non-HTTPS cannot open in source browser")
        let job = try CareerAssistantJSON.from(["id": "job-test", "title": "机器人实习", "company": "测试团队", "url": "https://example.com/jobs/test", "followUp": ["saved": false, "stage": "未投递", "notes": ""]])
        var archive = CareerMobileArchive(); archive.snapshot = .object(["jobs": .array([job]), "schemaVersion": .number(2)])
        archive.enqueue(kind: "followups", targetID: job.id, patch: .object(["saved": .bool(true)]))
        archive.enqueue(kind: "followups", targetID: job.id, patch: .object(["stage": .string("已投递")]))
        try expect(archive.visible["jobs"].array[0]["followUp"]["saved"].bool, "offline bookmark visible immediately")
        try expect(archive.visible["jobs"].array[0]["followUp"]["stage"].string == "已投递", "ordered offline edits retain earlier changes")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("career-mobile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = CareerArchiveDisk(url: directory.appendingPathComponent("mobile-v3.json"))
        try await disk.save(archive)
        let restored = try await disk.load()!
        try expect(restored.pending.count == 2 && restored.pending[0].id == archive.pending[0].id, "restart preserves operation identity for safe retry")
        archive.accept(try .from(["id": archive.pending[0].id, "state": "applied", "targetID": "server-job", "current": ["saved": true, "stage": "未投递"]]))
        try expect(archive.pending.count == 1 && archive.pending[0].targetID == "server-job", "server alias rewrites dependent offline operations")
        try expect(CareerPlanLink.reference(archive.visible["jobs"].array[0]) == job.id, "server identity migration keeps the original interview plan reference")
        try expect(archive.visible["jobs"].array[0]["followUp"]["stage"].string == "已投递", "acknowledgment preserves later pending edit")
        archive.accept(try .from(["id": archive.pending[0].id, "state": "conflict", "targetID": "server-job", "fields": ["stage"], "current": ["saved": true, "stage": "面试"]]))
        let conflictedID = archive.pending[0].id
        archive.resolve(conflictedID, usePhone: true)
        try expect(archive.pending[0].id != conflictedID && archive.pending[0].base["stage"].string == "面试", "explicit resolution uses new identity and current server base")
        let rejectedID = archive.pending[0].id
        archive.accept(try .from(["id": rejectedID, "state": "error", "message": "服务器暂不接受这项修改"]))
        archive.enqueue(kind: "followups", targetID: "server-job", patch: .object(["stage": .string("准备材料"), "notes": .string("已修正")]))
        try expect(archive.pending.count == 1 && archive.pending[0].id != rejectedID && archive.pending[0].conflict == nil && archive.pending[0].patch["notes"].string == "已修正", "corrected rejected edit can sync without a permanently blocked predecessor")
        var editing = CareerMobileArchive(); editing.snapshot = .object(["jobs": .array([job])])
        editing.enqueue(kind: "followups", targetID: job.id, patch: .object(["notes": .string("phone edit")]), editingBase: .object(["notes": .string("text when editor opened")]))
        try expect(editing.pending[0].base["notes"].string == "text when editor opened", "editor retains its original base even when a snapshot refreshes while typing")
        let interview = try CareerAssistantJSON.from(["start":"2026-10-20T02:00:00Z","end":"2026-10-20T03:00:00Z","location":"在线","notes":"算法面试"])
        var row = job.dictionary; row["followUp"] = .object(["interview": interview]); let interviewJob = CareerAssistantJSON.object(row)
        let first = CareerPlanLink.event(job: interviewJob, existing: nil)!
        let second = CareerPlanLink.event(job: interviewJob, existing: first)!
        try expect(first.id == second.id && first.careerReference == job.id, "repeated sync updates the same interview plan")
        var changed = interview.dictionary; changed["start"] = .string("2026-10-21T02:00:00Z"); changed["end"] = .string("2026-10-21T03:00:00Z")
        row["followUp"] = .object(["interview": .object(changed)])
        let moved = CareerPlanLink.event(job: .object(row), existing: first)!
        try expect(moved.id == first.id && moved.start != first.start, "rescheduling does not duplicate plans")
        var records = Snapshot(); records.events = [moved]
        let roundtrip = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(records))
        try expect(roundtrip.events[0].careerReference == job.id, "backup preserves interview link")
        let corrupt = Data("broken archive".utf8); try corrupt.write(to: directory.appendingPathComponent("mobile-v3.json"))
        var rejected = false
        do { _ = try await disk.load() } catch { rejected = true }
        try expect(rejected && (try Data(contentsOf: directory.appendingPathComponent("mobile-v3.json"))) == corrupt, "unreadable local edits remain intact")
        let request = URLRequest(url: URL(string: "https://career-fixture.test/stall")!)
        let began = Date()
        var timedOut = false
        do { _ = try await CareerAssistantTransport.perform(request, timeout: 0.15, protocols: [CareerMobileSilentProtocol.self]) } catch { timedOut = true }
        try expect(timedOut && Date().timeIntervalSince(began) < 2, "stalled service has a bounded deadline")
        let task = Task { try await CareerAssistantTransport.perform(request, timeout: 5, protocols: [CareerMobileSilentProtocol.self]) }
        try await Task.sleep(for: .milliseconds(50)); let cancelledAt = Date(); task.cancel()
        var interrupted = false
        do { _ = try await task.value } catch { interrupted = true }
        try expect(interrupted && Date().timeIntervalSince(cancelledAt) < 1, "leaving a view cancels network promptly")
        return checks
    }
}

private final class CareerMobileSilentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "career-fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* Deliberately never sends headers or finishes. */ }
    override func stopLoading() {}
}
