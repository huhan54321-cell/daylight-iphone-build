import Foundation

struct CareerMobileOperation: Codable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var kind: String
    var targetID: String
    var base: CareerAssistantJSON
    var patch: CareerAssistantJSON
    var job: CareerAssistantJSON?
    var conflict: CareerAssistantJSON?
}

struct CareerMobileArchive: Codable, Sendable {
    var version = 1
    var snapshot: CareerAssistantJSON = .object([:])
    var pending: [CareerMobileOperation] = []
    var migratedLegacy = false
    var reports: [String: CareerAssistantJSON] = [:]
    var visible: CareerAssistantJSON {
        var result = snapshot.dictionary
        var jobs = snapshot["jobs"].array
        var leads = snapshot["leads"].array
        for op in pending {
            if op.kind == "followups" {
                if !jobs.contains(where: { $0.id == op.targetID }), let job = op.job { jobs.append(job) }
                if let i = jobs.firstIndex(where: { $0.id == op.targetID }) {
                    var job = jobs[i].dictionary
                    var follow = jobs[i]["followUp"].dictionary
                    op.patch.dictionary.forEach { follow[$0.key] = $0.value }
                    job["followUp"] = .object(follow); job["pendingSync"] = .bool(true); jobs[i] = .object(job)
                }
            } else if let i = leads.firstIndex(where: { $0.id == op.targetID }) {
                var row = leads[i].dictionary; op.patch.dictionary.forEach { row[$0.key] = $0.value }; row["pendingSync"] = .bool(true); leads[i] = .object(row)
            }
        }
        result["jobs"] = .array(jobs); result["leads"] = .array(leads)
        return .object(result)
    }
    mutating func enqueue(kind: String, targetID: String, patch: CareerAssistantJSON) {
        let collection = kind == "followups" ? "jobs" : "leads"
        let row = visible[collection].array.first { $0.id == targetID } ?? .null
        let before = kind == "followups" ? row["followUp"] : row
        let base = Dictionary(uniqueKeysWithValues: patch.dictionary.keys.map { ($0, before[$0]) })
        pending.append(CareerMobileOperation(kind: kind, targetID: targetID, base: .object(base), patch: patch, job: kind == "followups" ? row : nil))
    }
    mutating func accept(_ result: CareerAssistantJSON) {
        guard let index = pending.firstIndex(where: { $0.id == result.id }) else { return }
        if result["state"].string != "applied" { pending[index].conflict = result; return }
        let op = pending.remove(at: index), target = result["targetID"].string
        let key = op.kind == "followups" ? "jobs" : "leads"
        var rows = snapshot[key].array
        if op.kind == "followups" {
            let oldIndex = rows.firstIndex { $0.id == op.targetID || $0.id == target }
            var row = (oldIndex.map { rows[$0] } ?? op.job ?? .null).dictionary
            row["id"] = .string(target); row["followUp"] = result["current"]
            if let oldIndex { rows[oldIndex] = .object(row) } else { rows.append(.object(row)) }
        } else if let i = rows.firstIndex(where: { $0.id == target }) { rows[i] = result["current"] }
        var document = snapshot.dictionary; document[key] = .array(rows); snapshot = .object(document)
        for i in pending.indices where pending[i].targetID == op.targetID && pending[i].kind == op.kind { pending[i].targetID = target }
    }
    mutating func resolve(_ id: String, usePhone: Bool) {
        guard let i = pending.firstIndex(where: { $0.id == id }), let conflict = pending[i].conflict else { return }
        let old = pending[i]
        // Dependent edits to this record remain visible; the explicit resolution covers their final values.
        let row = visible[old.kind == "followups" ? "jobs" : "leads"].array.first { $0.id == old.targetID } ?? .null
        let final = old.kind == "followups" ? row["followUp"] : row
        let keys = Set(pending.filter { $0.kind == old.kind && $0.targetID == old.targetID }.flatMap { $0.patch.dictionary.keys })
        pending.removeAll { $0.kind == old.kind && $0.targetID == old.targetID }
        if usePhone {
            let base = Dictionary(uniqueKeysWithValues: keys.map { ($0, conflict["current"][$0]) })
            let patch = Dictionary(uniqueKeysWithValues: keys.map { ($0, final[$0]) })
            pending.append(CareerMobileOperation(kind: old.kind, targetID: conflict["targetID"].string.isEmpty ? old.targetID : conflict["targetID"].string, base: .object(base), patch: .object(patch), job: old.job))
        }
    }
}

actor CareerArchiveDisk {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> CareerMobileArchive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 32_000_000 else { throw AppFailure.message("求职缓存过大，原文件已保留。") }
        let value = try JSONDecoder().decode(CareerMobileArchive.self, from: data)
        guard value.version == 1 else { throw AppFailure.message("求职缓存版本较新，请升级 App。") }
        return value
    }
    func save(_ archive: CareerMobileArchive) throws {
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 32_000_000 else { throw AppFailure.message("求职缓存已满，请先同步待处理修改。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
