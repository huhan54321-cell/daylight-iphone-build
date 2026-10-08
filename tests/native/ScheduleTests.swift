import Foundation

enum ScheduleTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ label: String) throws { checks += 1; if !value { throw AppFailure.message("FAIL: \(label)") } }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var failed = false; do { try action() } catch { failed = true }; try expect(failed, label)
        }
        let now = ISO8601DateFormatter().date(from: "2026-10-04T01:00:00Z")!
        let events = try ScheduleIntake.local("今天上午9点到10点开会；下午2点到3点健身", now: now)
        try expect(events.count == 2 && events[0].title == "开会" && events[1].title == "健身", "spoken numeric time ranges produce two activities")
        try expect(events[0].start == now && events[0].end == now.addingTimeInterval(3600), "today resolves in Shanghai time")
        try expect(events[1].start == now.addingTimeInterval(5 * 3600), "afternoon period is converted exactly")
        try expect(try ScheduleIntake.local("今天9:00到10:00开会，今天14:00到15:00健身", now: now).count == 2, "dictation comma separates complete appointments")
        let half = try ScheduleIntake.local("明天上午9点半到10点半测试", now: now)
        try expect(half[0].start == now.addingTimeInterval(86400 + 1800), "tomorrow and half-hour speech are exact")
        let explicit = try ScheduleIntake.local("2026-10-05 09:00-10:00开会", now: now)
        try expect(explicit[0].start == now.addingTimeInterval(86400), "explicit date and colon range are exact")
        for input in ["9:00到10:00开会", "今天开会", "今天9:00开会", "今天25:00到26:00开会", "今天9:99到10:00开会", "今天10:00到9:00开会", "今天晚上12点到1点测试", "2026-02-30 09:00-10:00测试", "今天9:00到10:00开会；含糊安排"] {
            try rejects("incomplete ambiguous invalid or partially understood schedule is rejected") { _ = try ScheduleIntake.local(input, now: now) }
        }
        let merged = try ScheduleIntake.merge(events, into: Snapshot())
        try expect(merged.added == 2 && merged.snapshot.events.count == 2, "batch records all valid activities")
        let repeated = try ScheduleIntake.merge(try ScheduleIntake.local("今天上午9点到10点开会；下午2点到3点健身", now: now), into: merged.snapshot)
        try expect(repeated.added == 0 && repeated.snapshot.events.count == 2 && Set(repeated.ids) == Set(events.map(\.id)), "repeated utterance uses existing IDs for calendar retry")
        var different = events[0]; different.id = UUID(); different.start = different.start.addingTimeInterval(60); different.end = different.end.addingTimeInterval(60)
        try expect(try ScheduleIntake.merge([different], into: merged.snapshot).added == 1, "different start time is a separate appointment")
        let row: [String: Any] = ["title": "会议", "date": "2026-10-04", "startTime": "09:00", "endDate": "2026-10-04", "endTime": "10:00", "location": "示例会议室"]
        let decoded = try ScheduleIntake.decode(["events": [row], "clarification": ""])
        try expect(decoded[0].start == now && decoded[0].location == "示例会议室", "model output validates exact event dates and location")
        var missing = row; missing.removeValue(forKey: "endTime")
        try rejects("missing model time rejects the entire batch") { _ = try ScheduleIntake.decode(["events": [row, missing]]) }
        try rejects("model clarification never auto-saves partial plan") { _ = try ScheduleIntake.decode(["events": [row], "clarification": "缺少时间"]) }
        try rejects("model tool instructions are not calendar data") { _ = try ScheduleIntake.decode(["events": [row], "tool": "delete"]) }
        try rejects("empty schedule rejected") { _ = try ScheduleIntake.validate([]) }
        try rejects("schedule batch limit") { _ = try ScheduleIntake.validate(Array(repeating: events[0], count: 21)) }
        let backup = try BackupCodec.decode(BackupCodec.export(merged.snapshot))
        try expect(backup.events.count == 2 && backup.events[0].id == events[0].id, "voice schedule survives backup without any new schema")
        let relaxed = try ScheduleIntake.flexibleLocal("明天下午三点健身；去买菜", durationMinutes: 45, now: now)
        try expect(relaxed.count == 2 && relaxed[0].start == now.addingTimeInterval(86400 + 6 * 3600), "Chinese clock and relative date resolve locally")
        try expect(relaxed[0].end.timeIntervalSince(relaxed[0].start) == 2700 && !relaxed[0].isAllDay, "single start uses selected adjustable duration")
        try expect(relaxed[1].isAllDay && relaxed[1].end.timeIntervalSince(relaxed[1].start) == 86400 && relaxed[1].title == "去买菜", "missing clock stays all day and inherits date")
        let localDay = Calendar.current.date(from: DateComponents(year:2026, month:10, day:4))!
        try expect(try ScheduleIntake.flexibleLocal("开会", now: now)[0].start == localDay, "missing date defaults today civil day in device calendar")
        try expect(try ScheduleIntake.flexibleLocal("今天下午两点到三点开会", now: now)[0].end.timeIntervalSince(now) == 6 * 3600, "Chinese full range is preserved")
        for invalid in ["今天25点测试", "今天9:99开会", "今天10点到9点开会", "2026-02-30买菜", "下周找时间开会", "10月6日去买菜", "周末健身", "昨天去买菜", "今天9点开会两小时", "今天晚上十二点睡觉"] {
            try rejects("invalid or ambiguous relaxed schedule never silently becomes all day") { _ = try ScheduleIntake.flexibleLocal(invalid, now: now) }
        }
        let looseRow: [String: Any] = ["title":"买菜", "date":"2026-10-04", "startTime":NSNull(), "endDate":NSNull(), "endTime":NSNull(), "location":NSNull()]
        let modelAllDay = try ScheduleIntake.decodeFlexible(["events":[looseRow]])
        try expect(modelAllDay[0].isAllDay, "model missing clock becomes an explicit all day item")
        var single = looseRow; single["startTime"] = "09:00"
        try expect(try ScheduleIntake.decodeFlexible(["events":[single]], durationMinutes:45)[0].end == now.addingTimeInterval(2700), "model start only uses selected duration")
        var invalid = single; invalid["endDate"] = "2026-10-08"
        try rejects("missing end time cannot hide contradictory end date") { _ = try ScheduleIntake.decodeFlexible(["events":[invalid]]) }
        var ledger = Snapshot(); ledger.events = relaxed
        let preserved = try BackupCodec.decode(BackupCodec.export(ledger))
        try expect(preserved.events[1].isAllDay && preserved.events[0].id == relaxed[0].id, "all day metadata and record identity survive backup")
        for (merchant, category) in [("消费财付通-青岛地铁","交通"),("消费财付通-青岛体育有限公司","运动"),("地铁口炸串","餐饮"),("大杯茶","餐饮"),("炸串","餐饮")] {
            try expect(MerchantCategories.category(title: merchant, kind: .expense) == category, "merchant classified locally")
        }
        var record = MoneyRecord(date:now, kind:.expense, cents:500, title:"青岛地铁", category:"待分类", source:"工行储蓄卡")
        let recordID = record.id; ledger.transactions = [record]
        let migrated = try BackupCodec.decode(BackupCodec.export(ledger))
        try expect(migrated.transactions[0].category == "交通" && migrated.transactions[0].id == recordID && migrated.transactions[0].cents == 500, "pending historical category migration preserves money and identity")
        record.category = "手动分类"
        try expect(MerchantCategories.fill(record).category == "手动分类", "explicit personal categories preserved")
        try expect(MerchantCategories.category(title:"健身充值", kind:.transfer) == "账户转移", "merchant transfer never classified as expense")
        return checks
    }
}
