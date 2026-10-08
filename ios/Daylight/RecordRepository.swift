import Foundation

enum SnapshotChecks {
    static func validate(_ snapshot: Snapshot) throws {
        func unique<T: Identifiable>(_ values: [T]) -> Bool where T.ID: Hashable { Set(values.map(\.id)).count == values.count }
        guard unique(snapshot.transactions), unique(snapshot.tasks), unique(snapshot.events), unique(snapshot.weights), unique(snapshot.workouts), unique(snapshot.smsInbox), unique(snapshot.plannedTrips), Set(snapshot.smsInbox.map(\.requestID)).count == snapshot.smsInbox.count else {
            throw AppFailure.message("记录包含重复标识，原文件未修改")
        }
        let preferences = snapshot.plannerPreferences
        guard !preferences.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, preferences.city.count <= 100, preferences.origin.count <= 300,
              (0...120).contains(preferences.bufferMinutes), (5...1440).contains(preferences.durationMinutes) else {
            throw AppFailure.message("计划偏好的城市或时间设置无效")
        }
        for trip in snapshot.plannedTrips { try TripPlanning.validate(trip) }
        let tripEventIDs = snapshot.plannedTrips.flatMap(\.eventIDs)
        guard Set(tripEventIDs).count == tripEventIDs.count else { throw AppFailure.message("行程中包含重复日程标识") }
        let money = snapshot.transactions + snapshot.smsInbox.compactMap(\.draft)
        guard money.allSatisfy({ $0.bankAccountTail.map { $0.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil } ?? true }) else {
            throw AppFailure.message("银行卡尾号格式无效，已有记录已保留")
        }
        guard money.allSatisfy({ $0.cents > 0 && $0.cents <= 100_000_000_000 && $0.date.timeIntervalSince1970.isFinite && ($0.bankBalanceAfterCents.map { (-100_000_000_000...100_000_000_000).contains($0) } ?? true) && ($0.bankBalanceReportedAt?.timeIntervalSince1970.isFinite ?? true) }),
              snapshot.events.allSatisfy({ $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start }),
              snapshot.tasks.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.date.timeIntervalSince1970.isFinite }),
              snapshot.weights.allSatisfy({ $0.kilograms.isFinite && (1...500).contains($0.kilograms) && $0.date.timeIntervalSince1970.isFinite }),
              snapshot.workouts.allSatisfy({ $0.minutes.isFinite && $0.minutes > 0 && $0.minutes <= ($0.healthID == nil ? 1_440 : 525_600) && $0.date.timeIntervalSince1970.isFinite }),
              snapshot.smsInbox.allSatisfy({ $0.receivedAt.timeIntervalSince1970.isFinite && $0.requestID.range(of: #"^[A-Za-z0-9_-]{16,100}$"#, options: .regularExpression) != nil && ($0.bankBalanceAfterCents.map { (-100_000_000_000...100_000_000_000).contains($0) } ?? true) }),
              snapshot.bankBalanceBaseline.map({ (-100_000_000_000...100_000_000_000).contains($0.cents) && $0.date.timeIntervalSince1970.isFinite }) ?? true else {
            throw AppFailure.message("记录中存在无效金额、日期或运动数值，原文件未修改")
        }
    }
}

struct RecordRepository {
    let url: URL
    func load() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        try SnapshotChecks.validate(snapshot)
        return snapshot
    }
    func save(_ snapshot: Snapshot) throws {
        try SnapshotChecks.validate(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(snapshot)
        #if os(iOS)
        // Allow local SMS saves after the first unlock, including subsequent screen locks.
        try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try encoded.write(to: url, options: .atomic)
        #endif
    }
}

enum BackupCodec {
    struct Envelope: Codable {
        var format = "daylight-backup"
        var exportedAt = Date()
        var records: Snapshot
        var careerProfile: CareerProfileDocument? = nil
    }
    static func export(_ snapshot: Snapshot, careerProfile: CareerProfileDocument? = nil) throws -> Data {
        try SnapshotChecks.validate(snapshot)
        if let careerProfile, !careerProfile.isValid { throw CareerProfileError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(records: snapshot, careerProfile: careerProfile))
    }
    static func decode(_ data: Data) throws -> Snapshot {
        try decodeBundle(data).records
    }
    static func decodeBundle(_ data: Data) throws -> (records: Snapshot, careerProfile: CareerProfileDocument?) {
        guard data.count <= 20_000_000 else { throw AppFailure.message("备份文件不能超过 20 MB") }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["format"] as? String == "daylight-backup" {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            try SnapshotChecks.validate(envelope.records)
            if let profile = envelope.careerProfile, !profile.isValid { throw CareerProfileError.invalid }
            return (envelope.records, envelope.careerProfile)
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            guard envelope.format == "daylight-backup" else { throw AppFailure.message("这不是日常的备份文件") }
            try SnapshotChecks.validate(envelope.records); return (envelope.records, envelope.careerProfile)
        }
        if let bank = try? JSONDecoder().decode(BankArchive.self, from: data) {
            let snapshot = try bank.snapshot(); try SnapshotChecks.validate(snapshot); return (snapshot, nil)
        }
        throw AppFailure.message("无法读取该备份，请选择日常备份或电脑短信账本导出的 JSON 文件")
    }
    static func merge(_ imported: Snapshot, into current: Snapshot) throws -> Snapshot {
        try SnapshotChecks.validate(imported)
        var next = current
        if next.plannerPreferences == PlannerPreferences() { next.plannerPreferences = imported.plannerPreferences }
        if next.bankBalanceBaseline == nil { next.bankBalanceBaseline = imported.bankBalanceBaseline }
        for record in imported.transactions where !next.transactions.contains(where: { $0.id == record.id || (record.externalID != nil && $0.externalID == record.externalID) }) { next.transactions.append(record) }
        for task in imported.tasks where !next.tasks.contains(where: { $0.id == task.id || (task.reminderID != nil && $0.reminderID == task.reminderID) }) { next.tasks.append(task) }
        var eventMapping: [UUID: UUID] = [:]
        for event in imported.events {
            let exact = next.events.firstIndex(where: { $0.id == event.id || (event.eventID != nil && $0.eventID == event.eventID && abs($0.start.timeIntervalSince(event.start)) < 1) })
            let sameCalendar = event.eventID.map { identifier in next.events.indices.filter { next.events[$0].eventID == identifier } } ?? []
            // A saved trip creates individual events. Reconnect one moved occurrence while preserving
            // its live calendar time; ordinary recurring events still require the original start.
            // Multiple occurrences are ambiguous, so do not attach a trip to an arbitrary one.
            let movedTrip = event.tripID != nil && sameCalendar.count == 1 ? sameCalendar.first : nil
            if let index = exact ?? movedTrip {
                eventMapping[event.id] = next.events[index].id
                if next.events[index].navigationURL == nil { next.events[index].navigationURL = event.navigationURL }
                if next.events[index].location == nil { next.events[index].location = event.location }
                if next.events[index].tripID == nil { next.events[index].tripID = event.tripID }
            } else { next.events.append(event); eventMapping[event.id] = event.id }
        }
        for weight in imported.weights where !next.weights.contains(where: { $0.id == weight.id || (weight.healthID != nil && $0.healthID == weight.healthID) }) { next.weights.append(weight) }
        for workout in imported.workouts where !next.workouts.contains(where: { $0.id == workout.id || (workout.healthID != nil && $0.healthID == workout.healthID) }) { next.workouts.append(workout) }
        for message in imported.smsInbox where !next.smsInbox.contains(where: { $0.id == message.id || $0.requestID == message.requestID }) { next.smsInbox.append(message) }
        for original in imported.plannedTrips {
            var trip = original
            trip.eventIDs = trip.eventIDs.map { eventMapping[$0] ?? $0 }
            if !next.plannedTrips.contains(where: { $0.id == trip.id || !Set($0.eventIDs).isDisjoint(with: trip.eventIDs) }) { next.plannedTrips.append(trip) }
        }
        next.importedAt = Date()
        try SnapshotChecks.validate(next)
        return next
    }

    private struct BankArchive: Decodable {
        var version: Int
        var inbox: [BankEntry]
        var transactions: [BankTransaction]
        func snapshot() throws -> Snapshot {
            guard version == 1 else { throw AppFailure.message("电脑短信备份版本不受支持") }
            var value = Snapshot()
            value.transactions = try transactions.map { try $0.record() }
            value.smsInbox = try inbox.map { entry in
                guard let uuid = UUID(uuidString: entry.id) else { throw AppFailure.message("备份记录标识无效") }
                var draft = try entry.draft?.record(id: uuid)
                draft?.externalID = "sms:\(uuid.uuidString)"
                return BankMessage(id: uuid, requestID: entry.requestId, fingerprint: entry.fingerprint, receivedAt: try BackupCodec.bankDate(entry.receivedAt), body: BankSMS.redact(entry.body), draft: draft, warnings: entry.warnings ?? [], status: entry.status, reason: entry.reason ?? "已导入电脑记录", possibleDuplicate: entry.possibleDuplicate ?? false)
            }
            return value
        }
    }
    private struct BankEntry: Decodable {
        var id: String; var requestId: String; var fingerprint: String; var receivedAt: String
        var body: String; var draft: BankTransaction?; var warnings: [String]?; var status: BankMessageStatus
        var reason: String?; var possibleDuplicate: Bool?
    }
    private struct BankTransaction: Decodable {
        var id: String?; var date: String; var kind: TransactionKind; var cents: Int
        var title: String; var category: String; var source: String
        func record(id supplied: UUID? = nil) throws -> MoneyRecord {
            guard let uuid = supplied ?? id.flatMap({ UUID(uuidString: $0) }) else { throw AppFailure.message("备份记录标识无效") }
            return MoneyRecord(id: uuid, date: try BackupCodec.bankDate(date), kind: kind, cents: cents, title: title, category: category, source: source, externalID: "sms:\(uuid.uuidString)")
        }
    }
    private static func bankDate(_ text: String) throws -> Date {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 28_800)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { throw AppFailure.message("备份交易日期无效") }
        return date
    }
}
