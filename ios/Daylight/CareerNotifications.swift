import Foundation
import UserNotifications

enum CareerNotifications {
    static func configure(enabled: Bool, snapshot: CareerAssistantJSON) async throws {
        let center = UNUserNotificationCenter.current()
        if enabled {
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { throw AppFailure.message("提醒权限未开启。仍可在求职的进度页查看待办，也可以到系统设置开启通知。") }
        }
        UserDefaults.standard.set(enabled, forKey: "career-reminders-enabled")
        await sync(snapshot)
    }
    static func sync(_ snapshot: CareerAssistantJSON) async {
        let center = UNUserNotificationCenter.current()
        let all = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: all.filter { $0.identifier.hasPrefix("career-") }.map(\.identifier))
        guard UserDefaults.standard.bool(forKey: "career-reminders-enabled") else { return }
        let allowance = max(0, min(40, 60 - all.filter { !$0.identifier.hasPrefix("career-") }.count))
        var reminders: [(String, Date, String, String)] = []
        for job in snapshot["jobs"].array {
            let follow = job["followUp"], company = job["company"].string
            if let date = CareerDates.date(follow["reminderAt"].string), date > Date() {
                reminders.append(("career-follow-" + job.id, date, "求职跟进 · " + company, follow["nextAction"].string.isEmpty ? job["title"].string : follow["nextAction"].string))
            }
            if let start = CareerDates.date(follow["interview"]["start"].string), start.addingTimeInterval(-1800) > Date() {
                reminders.append(("career-interview-" + job.id, start.addingTimeInterval(-1800), "30 分钟后面试 · " + company, job["title"].string))
            }
        }
        for (id, date, title, body) in reminders.sorted(by: { $0.1 < $1.1 }).prefix(allowance) {
            let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
