import Foundation
import Combine

@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()
    @Published private(set) var data = Snapshot()
    @Published var message: String? = nil
    @Published var busy = false
    let apple = AppleServices()
    private var loadFailed = false
    private let fileURL: URL
    private var repository: RecordRepository { RecordRepository(url: fileURL) }

    init() {
        fileURL = UITestSupport.recordURL(applicationSupport:
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        do {
            data = try repository.load()
        } catch {
            loadFailed = true
            message = "已有记录无法读取，原文件已保留。为防止覆盖，暂时不能保存新记录。\(error.localizedDescription)"
        }
    }

    private func commit(_ next: Snapshot) throws {
        guard !loadFailed else { throw AppFailure.message("请先恢复已有记录，当前不会覆盖原文件") }
        try repository.save(next)
        data = next
    }

    func reloadLocal() {
        do { data = try repository.load(); loadFailed = false }
        catch { loadFailed = true; message = "记录暂时无法读取，原文件已保留。请解锁手机后重试：\(error.localizedDescription)" }
    }
    func exportBackup() throws -> Data {
        guard !loadFailed else { throw AppFailure.message("已有记录无法读取，请先解锁或恢复备份") }
        let profile = try CareerProfileDocument.loadSaved() ?? CareerProfileDocument.load()
        return try BackupCodec.export(data, careerProfile: profile)
    }
    func importBackup(_ bytes: Data) throws {
        let before = data.transactions.count + data.tasks.count + data.events.count + data.weights.count + data.workouts.count + data.smsInbox.count + data.plannedTrips.count
        let bundle = try BackupCodec.decodeBundle(bytes)
        let next = try BackupCodec.merge(bundle.records, into: data)
        let existingProfile = try CareerProfileDocument.loadSaved()
        if loadFailed {
            // Preserve an unreadable original before accepting a user-selected valid backup.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.copyItem(at: fileURL, to: fileURL.deletingLastPathComponent().appendingPathComponent("records-recovery-\(UUID().uuidString).json"))
            }
            do { try repository.save(next); data = next; loadFailed = false }
            catch { throw error }
        } else { try commit(next) }
        var profileRestored = false
        var profileSaveError: Error?
        if existingProfile == nil, let importedProfile = bundle.careerProfile {
            do { try importedProfile.saveLocally(); profileRestored = true }
            catch { profileSaveError = error }
        }
        let after = next.transactions.count + next.tasks.count + next.events.count + next.weights.count + next.workouts.count + next.smsInbox.count + next.plannedTrips.count
        message = "已合并 \(after - before) 条记录；已有记录与自动保存设置保留。" +
            (profileRestored ? " 求职画像已恢复。" : "") +
            (profileSaveError == nil ? "" : " 求职画像保存失败，请单独导入画像文件：\(profileSaveError!.localizedDescription)")
    }
    func receiveSMS(body: String, sender: String, requestID: String?, diagnostic initialAttempt: SMSReceptionAttempt? = nil) throws -> String {
        try receiveBankMessage(body: body, requestID: requestID, diagnostic: initialAttempt) { current in
            try SMSInboxPolicy.accept(body: body, sender: sender, requestID: requestID, into: current)
        }
    }
    func receiveBankNotification(title: String, body: String, requestID: String?, diagnostic initialAttempt: SMSReceptionAttempt? = nil) throws -> String {
        let result = try receiveBankMessage(body: body, requestID: requestID, origin: .icbcNotification, diagnostic: initialAttempt) { current in
            try BankNotification.accept(title: title, body: body, requestID: requestID, into: current)
        }
        return result.replacingOccurrences(of: "短信", with: "通知")
    }
    private func receiveBankMessage(body: String, requestID: String?, origin: BankMessageOrigin? = nil, diagnostic initialAttempt: SMSReceptionAttempt?, accept: (Snapshot) throws -> (snapshot: Snapshot, result: String)) throws -> String {
        var attempt = initialAttempt ?? SMSReceptionDiagnostics.begin(bodyLength: body.utf16.count, origin: origin)
        SMSReceptionDiagnostics.advance(&attempt, to: .load)
        do {
            // Read the latest saved snapshot before appending. This synchronous MainActor
            // path cannot interleave with another in-process commit, and also retries a
            // previous protected-data read failure after the phone has been unlocked.
            data = try repository.load()
            loadFailed = false
        } catch {
            loadFailed = true
            SMSReceptionDiagnostics.fail(&attempt, at: .load, error: error)
            throw AppFailure.message("本地记录无法读取，原文件已保留。请解锁并打开日常后重试；仍失败时检查记录或恢复备份。诊断代码：\(SMSReceptionDiagnostics.failureCode(error))")
        }
        SMSReceptionDiagnostics.advance(&attempt, to: .accept)
        let receipt: (snapshot: Snapshot, result: String)
        do {
            receipt = try accept(data)
        } catch {
            let problem = SMSReceptionDiagnostics.inputProblem(body: body, requestID: requestID)
            SMSReceptionDiagnostics.fail(&attempt, at: problem == nil ? .accept : .input, error: error, problem: problem)
            if let failure = error as? AppFailure { throw failure }
            throw AppFailure.message("银行消息接收未完成。诊断代码：\(SMSReceptionDiagnostics.failureCode(error))。请在设置的银行记账中查看最近接收状态。")
        }
        if receipt.snapshot.smsInbox.count != data.smsInbox.count {
            SMSReceptionDiagnostics.advance(&attempt, to: .save)
            do { try commit(receipt.snapshot) }
            catch {
                SMSReceptionDiagnostics.fail(&attempt, at: .save, error: error)
                throw AppFailure.message("本地记录保存失败，未确认接收成功。请解锁并打开日常后重试。诊断代码：\(SMSReceptionDiagnostics.failureCode(error))")
            }
        }
        SMSReceptionDiagnostics.succeed(&attempt, result: receipt.result)
        return receipt.result
    }
    func setAutomaticSMS(_ enabled: Bool) {
        do { var next = data; next.autoRecordSMS = enabled; try commit(next) }
        catch { message = error.localizedDescription }
    }
    func confirmBankReceipts(_ messages: [BankMessage], allowingDuplicates: Set<UUID> = []) throws -> BankScreenshotConfirmation {
        let result = try BankScreenshotCore.confirm(messages: messages, into: data, allowPossibleDuplicate: allowingDuplicates)
        if result.count > 0 { try commit(result.snapshot) }
        return result
    }
    func setBankBalance(cents: Int, date: Date) throws {
        var next = data; next.bankBalanceBaseline = BankBalanceBaseline(cents: cents, date: date); try commit(next)
    }
    func reviewSMS(_ original: BankMessage, record: MoneyRecord?) throws {
        var next = data
        guard let index = next.smsInbox.firstIndex(where: { $0.id == original.id }) else { throw AppFailure.message("短信记录已不存在") }
        next.transactions.removeAll { $0.id == original.id }
        if var record {
            if BankBalanceMath.direction(for: record) != .excluded, let tail = record.bankAccountTail {
                let tails = Set(next.transactions.filter { BankBalanceMath.direction(for: $0) != .excluded }.compactMap(\.bankAccountTail))
                guard tails.isEmpty || tails == Set([tail]) else { throw AppFailure.message("此记录属于另一张银行卡，请取消计入工行卡余额后保存") }
            }
            record.id = original.id; record.externalID = "\((original.origin ?? .sms).externalPrefix):\(original.id.uuidString)"
            record.bankBalanceAfterCents = original.bankBalanceAfterCents
            record.bankBalanceReportedAt = original.receivedAt
            next.transactions.append(record); next.smsInbox[index].draft = record; next.smsInbox[index].status = .recorded
        } else { next.smsInbox[index].status = .ignored }
        try commit(next)
    }
    func updateMoney(_ value: MoneyRecord) throws {
        var next = data
        guard let index = next.transactions.firstIndex(where: { $0.id == value.id }) else { throw AppFailure.message("该记录已不存在") }
        if BankBalanceMath.direction(for: value) != .excluded, let tail = value.bankAccountTail {
            let tails = Set(next.transactions.filter { $0.id != value.id && BankBalanceMath.direction(for: $0) != .excluded }.compactMap(\.bankAccountTail))
            guard tails.isEmpty || tails == Set([tail]) else { throw AppFailure.message("此记录属于另一张银行卡，请取消计入工行卡余额后保存") }
        }
        next.transactions[index] = value
        if let sms = next.smsInbox.firstIndex(where: { $0.id == value.id }) { next.smsInbox[sms].draft = value }
        try commit(next)
    }
    func deleteMoney(_ value: MoneyRecord) throws {
        var next = data; next.transactions.removeAll { $0.id == value.id }
        if let index = next.smsInbox.firstIndex(where: { $0.id == value.id }) { next.smsInbox[index].status = .ignored }
        try commit(next)
    }
    func updateWeight(_ value: WeightRecord) throws {
        var next = data
        guard let index = next.weights.firstIndex(where: { $0.id == value.id }) else { throw AppFailure.message("该记录已不存在") }
        guard value.healthID == nil else { throw AppFailure.message("苹果健康记录请在健康 App 中修改") }
        next.weights[index] = value; try commit(next)
    }
    func deleteWeight(_ value: WeightRecord) throws {
        guard value.healthID == nil else { throw AppFailure.message("苹果健康记录请在健康 App 中删除") }
        var next = data; next.weights.removeAll { $0.id == value.id }; try commit(next)
    }
    func updateExercise(_ value: ExerciseRecord) throws {
        var next = data
        guard let index = next.workouts.firstIndex(where: { $0.id == value.id }) else { throw AppFailure.message("该记录已不存在") }
        // Allow notes for HealthKit workouts without changing the source's duration/date.
        if let original = next.workouts.first(where: { $0.id == value.id }), original.healthID != nil {
            next.workouts[index].actions = value.actions
        } else { next.workouts[index] = value }
        try commit(next)
    }
    func deleteExercise(_ value: ExerciseRecord) throws {
        guard value.healthID == nil else { throw AppFailure.message("苹果健康记录请在健康 App 中删除") }
        var next = data; next.workouts.removeAll { $0.id == value.id }; try commit(next)
    }
    func updateTask(_ value: PlanTask) throws {
        var updated = value
        if value.reminderID != nil { try apple.updateReminder(value) }
        var next = data
        guard let index = next.tasks.firstIndex(where: { $0.id == value.id }) else { throw AppFailure.message("待办已不存在，请刷新") }
        if value.reminderID == nil, apple.remindersAvailable { updated.reminderID = try apple.createReminder(value) }
        next.tasks[index] = updated; try commit(next)
    }
    func deleteTask(_ value: PlanTask) throws {
        if value.reminderID != nil { try apple.deleteReminder(value) }
        var next = data; next.tasks.removeAll { $0.id == value.id }; try commit(next)
    }
    func updateEvent(_ value: PlanEvent) throws {
        var updated = value
        guard let original = data.events.first(where: { $0.id == value.id }) else { throw AppFailure.message("日程已不存在，请刷新") }
        if value.eventID != nil { updated.eventID = try apple.updateEvent(value, original: original) }
        else if apple.calendarAvailable { updated.eventID = try apple.createEvent(value) }
        var next = data
        guard let index = next.events.firstIndex(where: { $0.id == value.id }) else { return }
        next.events[index] = updated; try commit(next)
    }
    func deleteEvent(_ value: PlanEvent) throws {
        if value.eventID != nil { try apple.deleteEvent(value) }
        var next = data; next.events.removeAll { $0.id == value.id }; try commit(next)
    }

    func addMoney(_ value: MoneyRecord) throws { var next = data; next.transactions.append(value); try commit(next) }
    func addWeight(_ value: WeightRecord) throws { var next = data; next.weights.append(value); try commit(next) }
    func addExercise(_ value: ExerciseRecord) throws { var next = data; next.workouts.append(value); try commit(next) }

    func addTask(_ value: PlanTask) throws {
        // Save locally first. A failed remote operation never discards the task.
        var next = data; next.tasks.append(value); try commit(next)
        if apple.remindersAvailable {
            do {
                var synced = value
                synced.reminderID = try apple.createReminder(value)
                next = data
                if let index = next.tasks.firstIndex(where: { $0.id == value.id }) { next.tasks[index] = synced }
                try commit(next)
            } catch { message = "待办已本地保存，提醒事项同步失败：\(error.localizedDescription)" }
        }
    }

    func addEvent(_ value: PlanEvent) throws {
        var next = data; next.events.append(value); try commit(next)
        if apple.calendarAvailable {
            do {
                var synced = value; synced.eventID = try apple.createEvent(value)
                next = data
                if let index = next.events.firstIndex(where: { $0.id == value.id }) { next.events[index] = synced }
                do { try commit(next) }
                catch {
                    try? apple.deleteEvent(synced)
                    throw error
                }
            } catch { message = "日程已本地保存，日历同步失败：\(error.localizedDescription)" }
        }
    }

    func addSpokenSchedule(_ events: [PlanEvent], syncCalendar: Bool) async throws -> ScheduleReceptionResult {
        guard !busy else { throw AppFailure.message("正在更新记录，请稍后再同步") }
        busy = true; defer { busy = false }
        let merged = try ScheduleIntake.merge(events, into: data)
        if merged.added > 0 { try commit(merged.snapshot) }
        if syncCalendar && !apple.calendarAvailable {
            // A denied permission never discards an already saved local schedule.
            try? await apple.requestCalendar()
        }
        if syncCalendar && apple.calendarAvailable {
            for id in merged.ids {
                guard let original = data.events.first(where: { $0.id == id && $0.eventID == nil }) else { continue }
                do {
                    let existing = apple.fetchEvents(in: DateInterval(start: original.start.addingTimeInterval(-1), end: original.end.addingTimeInterval(1)))
                        .first { ScheduleIntake.sameEvent($0, original) }
                    var linked = original
                    let existingID = existing?.eventID
                    linked.eventID = try existingID ?? apple.createEvent(original)
                    var latest = data
                    if let index = latest.events.firstIndex(where: { $0.id == id }) { latest.events[index] = linked }
                    do { try commit(latest) }
                    catch {
                        if existingID == nil { try? apple.deleteEvent(linked) }
                        throw error
                    }
                } catch { /* Keep unsynced local records available for retry. */ }
            }
        }
        let saved = data.events.filter { merged.ids.contains($0.id) }.sorted { $0.start < $1.start }
        let synced = saved.filter { $0.eventID != nil }.count
        return ScheduleReceptionResult(addedCount: merged.added, syncedCount: synced, pendingSyncCount: saved.count - synced, events: saved)
    }

    func savePlannerPreferences(_ value: PlannerPreferences) throws {
        try TripPlanning.validate(value)
        var next = data; next.plannerPreferences = value; try commit(next)
    }

    func plannerConflictEvents(on date: Date) async throws -> [PlanEvent] {
        let day = Calendar.current.startOfDay(for: date)
        let window = DateInterval(start: day.addingTimeInterval(-86_400), end: day.addingTimeInterval(172_800))
        var values = data.events.filter { $0.start < window.end && $0.end > window.start }
        if apple.calendarAvailable {
            let remote = apple.fetchEvents(in: window)
            // An authorized live calendar takes precedence over cached linked records.
            values.removeAll { $0.eventID != nil }
            values += remote
        }
        return values
    }

    func addPlannedTrip(_ trip: PlannedTrip) async throws {
        try TripPlanning.validate(trip)
        guard !busy else { throw AppFailure.message("正在更新记录，请稍后再保存行程") }
        busy = true; defer { busy = false }
        var next = data
        // Stable trip and event IDs make a second tap or retry safe.
        if !next.plannedTrips.contains(where: { $0.id == trip.id }) {
            let scheduled = TripPlanning.schedule(trip)
            guard !scheduled.contains(where: { item in next.events.contains(where: { $0.id == item.id }) }) else { throw AppFailure.message("行程标识已存在，请重新预览") }
            next.plannedTrips.append(trip); next.events.append(contentsOf: scheduled)
            try commit(next)
        }
        guard apple.calendarAvailable else {
            message = "行程已保存在本地。连接苹果日历后可同步这两段安排。"
            return
        }
        var failures = 0
        for eventID in trip.eventIDs {
            guard let original = data.events.first(where: { $0.id == eventID && $0.eventID == nil }) else { continue }
            do {
                var synced = original; synced.eventID = try apple.createEvent(original)
                var latest = data
                if let index = latest.events.firstIndex(where: { $0.id == eventID }) { latest.events[index] = synced }
                do { try commit(latest) }
                catch {
                    // Avoid leaving an unlinked calendar event that would be duplicated on retry.
                    try? apple.deleteEvent(synced)
                    throw error
                }
            } catch { failures += 1 }
        }
        message = failures == 0 ? "行程已保存，并同步到苹果日历；出发和活动开始前 10 分钟提醒。" : "行程已本地保存，部分日历同步未完成。可在计划页重试同步，已同步的安排不会重复创建。"
    }

    func toggleTask(_ value: PlanTask) {
        do {
            var next = data
            guard let index = next.tasks.firstIndex(where: { $0.id == value.id }) else { return }
            let completed = !value.completed
            if let id = value.reminderID { try apple.setReminder(id, completed: completed) }
            next.tasks[index].completed = completed
            try commit(next)
        } catch { message = "未能更新完成状态：\(error.localizedDescription)" }
    }

    func connectCalendar() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await apple.requestCalendar(); try await reloadPlans(); message = "已读取日历。可从计划页面添加新日程。" }
        catch { message = error.localizedDescription }
    }
    func connectReminders() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await apple.requestReminders(); try await reloadPlans(); message = "已读取提醒事项。新增待办和完成状态会写回。" }
        catch { message = error.localizedDescription }
    }
    func refreshPlans(center: Date = Date()) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        apple.calendarFocus = center
        do { try await reloadPlans() } catch { message = "计划刷新失败：\(error.localizedDescription)" }
    }

    private func reloadPlans() async throws {
        // Fetch first; SMS intents may save new financial records while we await EventKit.
        // Merge into the latest snapshot only after all asynchronous reads finish.
        let reminders: [PlanTask]?
        if apple.remindersAvailable { reminders = try await apple.fetchReminders() } else { reminders = nil }
        let window = apple.calendarWindow
        let events = apple.calendarAvailable ? apple.fetchEvents() : nil
        var next = data
        if let reminders {
            let old = next.tasks
            next.tasks = old.filter { $0.reminderID == nil } + reminders.map { remote in
                var value = remote
                if let local = old.first(where: { $0.reminderID == remote.reminderID }) { value.id = local.id }
                return value
            }
        }
        if let events {
            // Only replace records inside the queried window. Events outside it remain intact.
            let old = next.events
            let refreshed = events.map { remote in
                var value = remote
                if let local = old.first(where: { $0.eventID == remote.eventID && (abs($0.start.timeIntervalSince(remote.start)) < 1 || $0.tripID != nil) }) {
                    value.id = local.id; value.tripID = local.tripID
                    if value.navigationURL == nil { value.navigationURL = local.navigationURL }
                }
                return value
            }
            let refreshedIDs = Set(refreshed.map(\.id))
            next.events = old.filter { !refreshedIDs.contains($0.id) && ($0.eventID == nil || $0.end < window.start || $0.start >= window.end) } + refreshed
        }
        try commit(next)
    }

    func syncLocalPlans() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            // Persist each successful link immediately so retry does not recreate earlier items.
            if apple.remindersAvailable {
                for value in data.tasks.filter({ $0.reminderID == nil }) {
                    let id = try apple.createReminder(value)
                    var next = data
                    if let i = next.tasks.firstIndex(where: { $0.id == value.id }) { next.tasks[i].reminderID = id }
                    try commit(next)
                }
            }
            if apple.calendarAvailable {
                for value in data.events.filter({ $0.eventID == nil }) {
                    let id = try apple.createEvent(value)
                    var next = data
                    if let i = next.events.firstIndex(where: { $0.id == value.id }) { next.events[i].eventID = id }
                    do { try commit(next) }
                    catch {
                        var linked = value; linked.eventID = id
                        try? apple.deleteEvent(linked)
                        throw error
                    }
                }
            }
            guard apple.remindersAvailable || apple.calendarAvailable else { throw AppFailure.message("请先连接日历或提醒事项") }
            try await reloadPlans(); message = "本地计划已写入获授权的苹果应用"
        } catch { message = "同步未全部完成，未同步记录仍保留在本地：\(error.localizedDescription)" }
    }

    func readHealth() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await apple.requestHealth()
            let result = try await apple.fetchHealth()
            var next = data
            let ids = Set(next.workouts.compactMap(\.healthID))
            next.workouts.append(contentsOf: result.workouts.filter { !ids.contains($0.healthID ?? "") })
            let weightIDs = Set(next.weights.compactMap(\.healthID))
            next.weights.append(contentsOf: result.weights.filter { !weightIDs.contains($0.healthID ?? "") })
            try commit(next)
            message = result.workouts.isEmpty && result.weights.isEmpty ? "暂无可读取记录。可能没有记录，或读取范围／权限受限。" : "已读取获准访问的最近 90 天运动与体重，不会自动识别具体健身动作。"
        } catch { message = "健康读取未完成：\(error.localizedDescription)" }
    }
}
