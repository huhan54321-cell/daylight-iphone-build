import Foundation
import Combine

@MainActor
final class CareerAssistantClient: ObservableObject {
    @Published private(set) var snapshot: CareerAssistantJSON = .object([:])
    @Published private(set) var online = false
    @Published private(set) var busy = false
    @Published private(set) var saving = false
    @Published private(set) var startingDiscovery = false
    @Published private(set) var pending: [CareerMobileOperation] = []
    @Published var message: String?
    private var configuration: CareerAPIConfiguration
    private var archive = CareerMobileArchive()
    private let disk: CareerArchiveDisk
    private var bootstrapTask: Task<Void, Never>?
    private var storageFailed = false
    private var mutation: Task<Bool, Never>?
    var configured: Bool { !configuration.baseURL.isEmpty && !configuration.token.isEmpty }
    var discoveryRunning: Bool { snapshot["tasks"].array.contains { $0["state"].string == "running" } }
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return UITestSupport.recordURL(applicationSupport: support).deletingLastPathComponent().appendingPathComponent("Career") }
        #endif
        return support.appendingPathComponent("DaylightCareer")
    }
    init(configuration: CareerAPIConfiguration = (try? CareerCredentials.load()) ?? CareerAPIConfiguration()) {
        self.configuration = configuration
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-career-failure") { self.configuration = CareerAPIConfiguration(baseURL: "http://127.0.0.1:9", token: "isolated-simulator-fixture") }
        #endif
        disk = CareerArchiveDisk(url: Self.directory.appendingPathComponent("mobile-v3.json"))
    }
    private func publish() { snapshot = archive.visible; pending = archive.pending }
    @discardableResult private func mutate(_ change: @escaping (inout CareerMobileArchive) -> Void) async -> Bool {
        let previous = mutation
        let task = Task { @MainActor in
            _ = await previous?.value
            guard !self.storageFailed else { return false }
            self.saving = true; defer { self.saving = false }
            var next = self.archive; change(&next)
            do { try await self.disk.save(next); self.archive = next; self.publish(); return true }
            catch { self.message = "修改未能保存：" + error.localizedDescription; return false }
        }
        mutation = task; return await task.value
    }
    func bootstrap() async {
        if let task = bootstrapTask { await task.value; return }
        let task = Task { @MainActor in await self.loadArchive() }; bootstrapTask = task; await task.value
    }
    private func loadArchive() async {
        do {
            if let cached = try await disk.load() { archive = cached; publish() }
            else {
                let legacyURL = Self.directory.appendingPathComponent("assistant-v2.json")
                if let data = try? Data(contentsOf: legacyURL), data.count <= 16_777_216, let cached = try? JSONDecoder().decode(CareerAssistantJSON.self, from: data), cached["schemaVersion"].int == 2 { archive.snapshot = cached }
            }
            if !archive.migratedLegacy {
                let legacy = CareerStore()
                var doc = archive.snapshot.dictionary, jobs = archive.snapshot["jobs"].array
                if let bytes = try? JSONEncoder().encode(legacy.feed?.articles ?? []), let articles = try? JSONDecoder().decode(CareerAssistantJSON.self, from: bytes) { doc["articles"] = articles }
                let oldJobs = CareerMatching.merge(jobs: legacy.jobs + legacy.savedJobs)
                for job in oldJobs {
                    guard let data = try? JSONEncoder().encode(job), let raw = try? JSONDecoder().decode(CareerAssistantJSON.self, from: data) else { continue }
                    let match = jobs.firstIndex { row in row.id == job.id || job.sourceURLs.contains(row["url"].string) }
                    let id = match.map { jobs[$0].id } ?? job.id
                    if match == nil {
                        var row = raw.dictionary
                        row["followUp"] = .object(["id": .string(id), "saved": .bool(false), "stage": .string("未投递"), "notes": .string(""), "nextAction": .string("")]); jobs.append(.object(row))
                    }
                    doc["jobs"] = .array(jobs); doc["schemaVersion"] = .number(2); archive.snapshot = .object(doc)
                    let old = legacy.followUp(for: job)
                    let current = archive.visible["jobs"].array.first { $0.id == id }?["followUp"] ?? .null
                    var patch: [String: CareerAssistantJSON] = [:]
                    if old.saved && !current["saved"].bool { patch["saved"] = .bool(true) }
                    if old.stage != "未投递", current["stage"].string == "未投递" {
                        let mapped = ["准备投递": "准备材料", "面试中": "面试", "已联系": "已打招呼", "已申请": "已投递", "已拒绝": "未通过"][old.stage] ?? old.stage
                        patch["stage"] = .string(CareerTrackingEditor.stages.contains(mapped) ? mapped : "准备材料")
                    }
                    if !patch.isEmpty { archive.enqueue(kind: "followups", targetID: id, patch: .object(patch)) }
                }
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--ui-test-career-mobile") { archive.snapshot = try CareerMobileFixtures.make(archive.snapshot) }
                #endif
                archive.migratedLegacy = true
                try await disk.save(archive); publish()
            }
        } catch { storageFailed = true; message = "本机求职资料暂时无法读取，已保留原文件：" + error.localizedDescription }
    }
    func request(_ route: String, body: [String: Any]? = nil) async throws -> CareerAssistantJSON {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let bytes = try await CareerNetworking(configuration: configuration).assistantRequest(route: route, body: data)
        return try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(CareerAssistantJSON.self, from: bytes) }.value
    }
    func reload() async {
        await bootstrap(); guard !busy, !storageFailed else { return }
        guard configured else { online = false; return }
        busy = true; defer { busy = false }
        do {
            let value = try await request("snapshot")
            guard value["schemaVersion"].int == 2 else { throw AppFailure.message("请更新电脑端求职服务。") }
            guard !Task.isCancelled else { return }
            let cached = await mutate { state in
                var incoming = value.dictionary
                if value["articles"].array.isEmpty { incoming["articles"] = state.snapshot["articles"] }
                // Keep historical favourites and unsynced phone records until the server acknowledges them.
                let ids = Set(value["jobs"].array.map(\.id))
                let extra = state.visible["jobs"].array.filter { !ids.contains($0.id) && ($0["followUp"]["saved"].bool || $0["followUp"]["stage"].string != "未投递" || $0["pendingSync"].bool) }
                incoming["jobs"] = .array(value["jobs"].array + extra); state.snapshot = .object(incoming)
                for report in value["reports"].array where report.dictionary["leads"] != nil { state.reports[report.id] = report }
                let keep = Set(value["reports"].array.prefix(60).map(\.id)); state.reports = state.reports.filter { keep.contains($0.key) }
            }
            guard cached else { online = false; return }
            online = true; message = nil; await flush()
        } catch is CancellationError { online = false }
        catch { online = false; message = "电脑暂时无法连接。已显示本机内容，收藏和跟进会留待同步。" }
    }
    @discardableResult func update(kind: String = "followups", id: String, patch: [String: Any], editingBase: CareerAssistantJSON? = nil) async -> Bool {
        await bootstrap()
        do {
            let value = try CareerAssistantJSON.from(patch)
            let saved = await mutate { $0.enqueue(kind: kind, targetID: id, patch: value, editingBase: editingBase) }
            if saved, online, !busy {
                busy = true
                Task { @MainActor in await self.flush(); self.busy = false }
            }
            return saved
        } catch { message = error.localizedDescription; return false }
    }
    private func flush() async {
        var rounds = 0
        while !Task.isCancelled, rounds < 20 {
            rounds += 1
            var seen = Set<String>()
            let batch = archive.pending.filter { op in
                let key = op.kind + ":" + op.targetID
                guard seen.insert(key).inserted else { return false }
                return op.conflict == nil
            }.prefix(30)
            if batch.isEmpty { return }
            do {
                let bytes = try JSONEncoder().encode(Array(batch))
                let operations = try JSONSerialization.jsonObject(with: bytes)
                let response = try await request("sync", body: ["operations": operations])
                guard response["results"].array.count == batch.count else { throw AppFailure.message("电脑返回的同步结果不完整") }
                let saved = await mutate { state in for result in response["results"].array { state.accept(result) } }
                guard saved else { return }
            } catch { online = false; message = "修改已保存在手机，电脑恢复连接后继续同步。"; return }
        }
    }
    func retrySync() async {
        _ = await mutate { state in for i in state.pending.indices where state.pending[i].conflict?["state"].string == "error" { state.pending[i].conflict = nil } }; await reload()
    }
    func discover() async {
        guard configured, !startingDiscovery, !discoveryRunning, !busy else { return }
        startingDiscovery = true; defer { startingDiscovery = false }
        do { _ = try await request("refresh", body: [:]); await reload() }
        catch { message = "未能发起新检索：" + error.localizedDescription }
    }
    func resolve(_ operation: CareerMobileOperation, usePhone: Bool) async {
        _ = await mutate { $0.resolve(operation.id, usePhone: usePhone) }; await reload()
    }
    func saveConnection(_ value: CareerAPIConfiguration) async {
        do { try CareerCredentials.save(value); configuration = value; online = false; await reload() }
        catch { message = error.localizedDescription }
    }
    var connection: CareerAPIConfiguration { configuration }
    @discardableResult func send(_ route: String, body: [String: Any] = [:]) async -> CareerAssistantJSON? {
        guard online else { message = "审核需要在线核对最新材料，请先连接电脑。"; return nil }
        do { let result = try await request(route, body: body); await reload(); return result }
        catch { message = error.localizedDescription; return nil }
    }
    func report(_ id: String) -> CareerAssistantJSON? { archive.reports[id] }
    func loadReport(_ id: String) async -> CareerAssistantJSON? {
        if let cached = archive.reports[id] { return cached }
        guard online else { return nil }
        do { let value = try await request("reports/" + id); _ = await mutate { $0.reports[id] = value }; return value }
        catch { message = "这份历史报告尚未缓存，请连接电脑后读取。"; return nil }
    }
    func monitor() async {
        await reload()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(online ? (discoveryRunning ? 3 : 45) : 60)) } catch { return }
            await reload()
        }
    }
}
