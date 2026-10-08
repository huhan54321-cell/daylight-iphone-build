import Foundation
import UserNotifications

enum SummaryNotifications {
    private static let identifiers = ["daylight.weekly-summary", "daylight.monthly-summary"]
    static func configure(enabled: Bool) async throws {
        let center = UNUserNotificationCenter.current()
        if !enabled { center.removePendingNotificationRequests(withIdentifiers: identifiers); return }
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw AppFailure.message("通知权限未开启，App 内仍可查看周报和月报") }
        let weekly = UNMutableNotificationContent(); weekly.title = "看看这一周"; weekly.body = "打开日常，查看已记录的收支、计划和运动。"; weekly.sound = .default
        let monthly = UNMutableNotificationContent(); monthly.title = "新的一个月"; monthly.body = "上个月的记录都收好了，打开账本查看月度汇总。"; monthly.sound = .default
        var week = DateComponents(); week.weekday = 2; week.hour = 20; week.minute = 0
        var month = DateComponents(); month.day = 1; month.hour = 20; month.minute = 0
        try await center.add(UNNotificationRequest(identifier: identifiers[0], content: weekly, trigger: UNCalendarNotificationTrigger(dateMatching: week, repeats: true)))
        do { try await center.add(UNNotificationRequest(identifier: identifiers[1], content: monthly, trigger: UNCalendarNotificationTrigger(dateMatching: month, repeats: true))) }
        catch { center.removePendingNotificationRequests(withIdentifiers: identifiers); throw error }
    }
}
