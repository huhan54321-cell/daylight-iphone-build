import Foundation
import EventKit
import HealthKit

@MainActor
final class AppleServices {
    private let events = EKEventStore()
    private let health = HKHealthStore()
    var calendarFocus = Date()
    var calendarAvailable: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var remindersAvailable: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    var calendarWindow: DateInterval {
        let start = Calendar.current.startOfDay(for: calendarFocus)
        return DateInterval(start: Calendar.current.date(byAdding: .day, value: -32, to: start)!, end: Calendar.current.date(byAdding: .day, value: 62, to: start)!)
    }

    func requestCalendar() async throws {
        let granted = try await events.requestFullAccessToEvents()
        guard granted else { throw AppFailure.message("尚未允许日历访问。本地计划仍可使用，可在系统设置中调整权限。") }
    }
    func requestReminders() async throws {
        let granted = try await events.requestFullAccessToReminders()
        guard granted else { throw AppFailure.message("尚未允许提醒事项访问。本地待办仍可使用，可在系统设置中调整权限。") }
    }
    func createReminder(_ value: PlanTask) throws -> String {
        guard remindersAvailable, let calendar = events.defaultCalendarForNewReminders(), calendar.allowsContentModifications else {
            throw AppFailure.message("提醒事项权限或可写入的默认列表不可用")
        }
        let reminder = EKReminder(eventStore: events)
        reminder.calendar = calendar; reminder.title = value.title; reminder.notes = value.notes
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: value.date)
        reminder.isCompleted = value.completed
        try events.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
    func setReminder(_ id: String, completed: Bool) throws {
        guard remindersAvailable, let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AppFailure.message("提醒事项访问不可用或原待办已删除，请刷新计划")
        }
        guard reminder.calendar.allowsContentModifications else { throw AppFailure.message("该提醒事项列表为只读") }
        reminder.isCompleted = completed; try events.save(reminder, commit: true)
    }
    func updateReminder(_ value: PlanTask) throws {
        guard remindersAvailable, let id = value.reminderID, let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else { throw AppFailure.message("提醒事项不可用或已删除，请刷新") }
        guard reminder.calendar.allowsContentModifications else { throw AppFailure.message("提醒事项列表为只读") }
        reminder.title = value.title; reminder.notes = value.notes; reminder.isCompleted = value.completed
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: value.date)
        try events.save(reminder, commit: true)
    }
    func deleteReminder(_ value: PlanTask) throws {
        guard remindersAvailable, let id = value.reminderID, let reminder = events.calendarItem(withIdentifier: id) as? EKReminder else { throw AppFailure.message("提醒事项不可用或已删除，请刷新") }
        guard reminder.calendar.allowsContentModifications else { throw AppFailure.message("提醒事项列表为只读") }
        try events.remove(reminder, commit: true)
    }
    func fetchReminders() async throws -> [PlanTask] {
        guard remindersAvailable else { return [] }
        let predicate = events.predicateForReminders(in: nil)
        let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            events.fetchReminders(matching: predicate) { values in
                if let values { continuation.resume(returning: values) }
                else { continuation.resume(throwing: AppFailure.message("提醒事项读取未完成，请重试；本地记录仍保留")) }
            }
        }
        return reminders.map { reminder in
            let date = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Calendar.current.startOfDay(for: Date())
            return PlanTask(title: reminder.title ?? "未命名待办", date: date, completed: reminder.isCompleted, notes: reminder.notes ?? "", reminderID: reminder.calendarItemIdentifier)
        }
    }
    func createEvent(_ value: PlanEvent) throws -> String {
        guard calendarAvailable, let calendar = events.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
            throw AppFailure.message("日历权限或可写入的默认日历不可用")
        }
        let event = EKEvent(eventStore: events)
        event.calendar = calendar; event.title = value.title; event.startDate = value.start; event.endDate = value.end; event.notes = value.notes
        event.location = value.location
        event.isAllDay = value.isAllDay
        event.url = value.navigationURL.flatMap(URL.init(string:))
        if value.tripID != nil { event.addAlarm(EKAlarm(relativeOffset: -600)) }
        try events.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw AppFailure.message("已创建日程，但未获得标识，请刷新日历确认") }
        return id
    }
    func fetchEvents() -> [PlanEvent] {
        fetchEvents(in: calendarWindow)
    }
    func fetchEvents(in window: DateInterval) -> [PlanEvent] {
        guard calendarAvailable else { return [] }
        return events.events(matching: events.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)).map {
            let link = $0.url.flatMap { url in url.scheme == "https" && url.host == "uri.amap.com" ? url.absoluteString : nil }
            return PlanEvent(title: $0.title ?? "未命名日程", start: $0.startDate, end: $0.endDate, notes: $0.notes ?? "", eventID: $0.eventIdentifier, location: $0.location, navigationURL: link, allDay: $0.isAllDay)
        }
    }
    private func occurrence(_ value: PlanEvent) throws -> EKEvent {
        guard calendarAvailable, let id = value.eventID else { throw AppFailure.message("日历访问不可用") }
        let predicate = events.predicateForEvents(withStart: value.start.addingTimeInterval(-1), end: value.end.addingTimeInterval(1), calendars: nil)
        guard let event = events.events(matching: predicate).first(where: { $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(value.start)) < 1 }) else { throw AppFailure.message("日程已变化或已删除，请先刷新") }
        guard event.calendar.allowsContentModifications else { throw AppFailure.message("日历为只读") }
        return event
    }
    func updateEvent(_ value: PlanEvent, original: PlanEvent) throws -> String {
        let event = try occurrence(original)
        event.title = value.title; event.notes = value.notes; event.startDate = value.start; event.endDate = value.end
        event.location = value.location
        event.isAllDay = value.isAllDay
        if let link = value.navigationURL { event.url = URL(string: link) }
        try events.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw AppFailure.message("日历已更新，请刷新以获取日程标识") }
        return id
    }
    func deleteEvent(_ value: PlanEvent) throws { try events.remove(occurrence(value), span: .thisEvent, commit: true) }
    func requestHealth() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppFailure.message("此设备无法访问苹果健康") }
        let weight = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        // Read only. Request completion does not prove that all read permissions were granted.
        try await health.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), weight])
    }
    private func samples(_ type: HKSampleType) async throws -> [HKSample] {
        let start = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result ?? []) }
            }
            health.execute(query)
        }
    }
    func fetchHealth() async throws -> (workouts: [ExerciseRecord], weights: [WeightRecord]) {
        let workoutSamples = try await samples(HKObjectType.workoutType())
        let workouts = workoutSamples.compactMap { sample -> ExerciseRecord? in
            guard let workout = sample as? HKWorkout else { return nil }
            let title: String
            switch workout.workoutActivityType {
            case .running: title = "跑步"
            case .walking: title = "步行"
            case .cycling: title = "骑行"
            case .traditionalStrengthTraining, .functionalStrengthTraining: title = "力量训练"
            case .swimming: title = "游泳"
            case .yoga: title = "瑜伽"
            default: title = "运动"
            }
            return ExerciseRecord(date: workout.startDate, title: title, minutes: workout.duration / 60, source: workout.sourceRevision.source.name, healthID: workout.uuid.uuidString)
        }
        let weightSamples = try await samples(HKObjectType.quantityType(forIdentifier: .bodyMass)!)
        let weights = weightSamples.compactMap { sample -> WeightRecord? in
            guard let weight = sample as? HKQuantitySample else { return nil }
            return WeightRecord(date: weight.startDate, kilograms: weight.quantity.doubleValue(for: .gramUnit(with: .kilo)), source: weight.sourceRevision.source.name, healthID: weight.uuid.uuidString)
        }
        return (workouts, weights)
    }
}
