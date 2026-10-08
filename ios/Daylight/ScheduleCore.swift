import Foundation

struct ScheduleReceptionResult {
    var addedCount: Int
    var syncedCount: Int
    var pendingSyncCount: Int
    var events: [PlanEvent]
}

enum ScheduleIntake {
    static func validate(_ events: [PlanEvent]) throws {
        guard (1...20).contains(events.count) else { throw AppFailure.message("每次可识别 1–20 项安排，请分批输入") }
        for event in events {
            guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, event.title.count <= 160,
                  (event.location?.count ?? 0) <= 300, event.notes.count <= 2000,
                  event.start.timeIntervalSince1970.isFinite, event.end.timeIntervalSince1970.isFinite,
                  event.start >= Date(timeIntervalSince1970: 946684800), event.end < Date(timeIntervalSince1970: 4133980800),
                  event.end > event.start, event.end.timeIntervalSince(event.start) <= 172800 else {
                throw AppFailure.message("安排缺少有效名称或起止时间，请补充后再记录，不会保存部分识别结果")
            }
        }
    }

    static func sameEvent(_ lhs: PlanEvent, _ rhs: PlanEvent) -> Bool {
        func key(_ text: String?) -> String { (text ?? "").precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines) }
        return key(lhs.title) == key(rhs.title) && lhs.start == rhs.start && lhs.end == rhs.end && lhs.isAllDay == rhs.isAllDay && key(lhs.location) == key(rhs.location)
    }

    static func merge(_ events: [PlanEvent], into current: Snapshot) throws -> (snapshot: Snapshot, added: Int, ids: [UUID]) {
        try validate(events)
        var next = current, ids: [UUID] = []
        for event in events {
            if let existing = next.events.first(where: { sameEvent($0, event) }) { ids.append(existing.id) }
            else { next.events.append(event); ids.append(event.id) }
        }
        try SnapshotChecks.validate(next)
        return (next, next.events.count - current.events.count, Array(Set(ids)))
    }

    static func decode(_ object: [String: Any]) throws -> [PlanEvent] {
        guard Set(object.keys).isSubset(of: ["events", "clarification"]), let rows = object["events"] as? [[String: Any]], rows.count <= 20 else { throw PlannerServiceError.invalidResponse }
        if let value = object["clarification"], !(value is String) { throw PlannerServiceError.invalidResponse }
        if let clarification = object["clarification"] as? String, !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppFailure.message("请补充明确的日期、开始时间和结束时间，再识别并同步。")
        }
        let events = try rows.map { row -> PlanEvent in
            guard Set(row.keys).isSubset(of: ["title", "date", "startTime", "endDate", "endTime", "location"]),
                  let title = row["title"] as? String, let day = row["date"] as? String,
                  let startTime = row["startTime"] as? String, let endDay = row["endDate"] as? String,
                  let endTime = row["endTime"] as? String,
                  let start = TripPlanning.date(dateString: day, timeString: startTime),
                  let end = TripPlanning.date(dateString: endDay, timeString: endTime) else { throw PlannerServiceError.invalidResponse }
            let location: String?
            if let value = row["location"], !(value is NSNull) {
                guard let text = value as? String else { throw PlannerServiceError.invalidResponse }; location = text
            } else { location = nil }
            return PlanEvent(title: title.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end, location: location)
        }
        try validate(events)
        return events
    }

    static func flexibleLocal(_ input: String, durationMinutes: Int = 60, now: Date = Date()) throws -> [PlanEvent] {
        guard !input.isEmpty, input.count <= 1200, (15...180).contains(durationMinutes) else { throw PlannerServiceError.invalidInput }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let pieces = input.precomposedStringWithCompatibilityMapping.components(separatedBy: CharacterSet(charactersIn: "；;\n，,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...20).contains(pieces.count) else { throw PlannerServiceError.invalidInput }
        var day = formatter.string(from: now), events: [PlanEvent] = []
        for original in pieces {
            var text = original
            let datePattern = #"^(今天|明天|后天|[0-9]{4}-[0-9]{2}-[0-9]{2})\s*"#
            if let range = text.range(of: datePattern, options: .regularExpression) {
                let word = String(text[range]).trimmingCharacters(in: .whitespaces)
                if let offset = ["今天": 0, "明天": 1, "后天": 2][word] { day = formatter.string(from: calendar.date(byAdding: .day, value: offset, to: now)!) }
                else { day = word }
                text.removeSubrange(range)
            }
            if let exact = try? local(day + " " + text, now: now) { events += exact; continue }
            guard text.range(of: #"昨天|前天|昨晚|下周|下星期|下个月|周末|周[一二三四五六日天]|星期|[0-9一二三四五六七八九十]+月|[0-9一二三四五六七八九十]+日"#, options: .regularExpression) == nil else {
                throw AppFailure.message("这段日期表达需要模型理解，请配置模型，或使用今天、明天、后天或 yyyy-MM-dd 日期。")
            }
            // Convert spoken Chinese clock numbers, keeping titles intact.
            let clockWords = try NSRegularExpression(pattern: #"([零一二两三四五六七八九十]{1,3})(?=点)"#)
            for match in clockWords.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let word = (text as NSString).substring(with: match.range)
                let digits: [Character: Int] = ["零":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
                let parts = word.split(separator: "十", omittingEmptySubsequences: false)
                let value: Int?
                if parts.count == 2 { value = (parts[0].isEmpty ? 1 : digits[parts[0].first!] ?? -100) * 10 + (parts[1].isEmpty ? 0 : digits[parts[1].first!] ?? -100) }
                else { value = word.count == 1 ? digits[word.first!] : nil }
                guard let value, value >= 0, let range = Range(match.range, in: text) else { throw PlannerServiceError.invalidInput }
                text.replaceSubrange(range, with: String(value))
            }
            if let exact = try? local(day + " " + text, now: now) { events += exact; continue }
            let regex = try NSRegularExpression(pattern: #"^\s*(上午|早上|下午|晚上|中午)?\s*([0-9]{1,2})(?::([0-9]{2})|点([0-9]{1,2})?分?(半)?)\s*(.{1,160})$"#)
            if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                func group(_ n: Int) -> String? { match.range(at: n).location == NSNotFound ? nil : (text as NSString).substring(with: match.range(at: n)) }
                var hour = Int(group(2)!)!; let minute = group(5) == nil ? Int(group(3) ?? group(4) ?? "0")! : 30
                guard !(hour == 12 && ["上午", "早上", "晚上"].contains(group(1) ?? "")) else { throw AppFailure.message("十二点有歧义，请使用 00:00 或 12:00，或通过模型识别。") }
                if ["下午", "晚上", "中午"].contains(group(1) ?? ""), hour < 12 { hour += 12 }
                let title = group(6)!.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (0...23).contains(hour), (0...59).contains(minute), !title.hasPrefix("到"), !title.hasPrefix("至"), !title.hasPrefix("-"),
                      title.range(of: "小时|分钟|持续", options: .regularExpression) == nil,
                      let start = TripPlanning.date(dateString: day, timeString: String(format: "%02d:%02d", hour, minute)) else { throw PlannerServiceError.invalidInput }
                events.append(PlanEvent(title: title, start: start, end: start.addingTimeInterval(Double(durationMinutes * 60)), notes: "未指定结束时间，按默认 \(durationMinutes) 分钟记录，可编辑。"))
            } else {
                guard !text.isEmpty, text.count <= 160,
                      text.range(of: #"[0-9]+[:点]|下周|下个月|周[一二三四五六日天]|星期|持续|小时|分钟|到|至"#, options: .regularExpression) == nil else {
                    throw AppFailure.message("这段表达需要模型理解，请配置模型，或补充明确日期和开始时间。")
                }
                events.append(try untimed(title: text, day: day, location: nil))
            }
        }
        try validate(events); return events
    }

    private static func untimed(title: String, day: String, location: String?) throws -> PlanEvent {
        guard let parsed = TripPlanning.date(dateString: day, timeString: "00:00") else { throw PlannerServiceError.invalidResponse }
        var reference = Calendar(identifier: .gregorian); reference.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // All-day events are civil dates in the device calendar, not an instant
        // at Shanghai midnight that can land on yesterday in another time zone.
        let calendar = Calendar.current
        let components = reference.dateComponents([.year, .month, .day], from: parsed)
        guard let start = calendar.date(from: components), let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw PlannerServiceError.invalidResponse }
        return PlanEvent(title: title, start: start, end: end, notes: "未指定具体时刻，按全天事项记录，可编辑。", location: location, allDay: true)
    }

    static func decodeFlexible(_ object: [String: Any], durationMinutes: Int = 60) throws -> [PlanEvent] {
        guard Set(object.keys).isSubset(of: ["events", "clarification"]), let rows = object["events"] as? [[String: Any]], (1...8).contains(rows.count),
              (15...180).contains(durationMinutes) else { throw PlannerServiceError.invalidResponse }
        if let value = object["clarification"], !(value is String) { throw PlannerServiceError.invalidResponse }
        if let clarification = object["clarification"] as? String, !clarification.isEmpty { throw AppFailure.message("日期或事项不明确，请补充后再记录。") }
        let events = try rows.map { row -> PlanEvent in
            guard Set(row.keys).isSubset(of: ["title", "date", "startTime", "endDate", "endTime", "location"]), let title = row["title"] as? String,
                  let day = row["date"] as? String else { throw PlannerServiceError.invalidResponse }
            func optional(_ key: String) throws -> String? {
                guard let value = row[key], !(value is NSNull) else { return nil }
                guard let text = value as? String else { throw PlannerServiceError.invalidResponse }; return text.isEmpty ? nil : text
            }
            let location = try optional("location"), startTime = try optional("startTime"), endTime = try optional("endTime"), endDay = try optional("endDate")
            guard let startTime else {
                guard endTime == nil, endDay == nil || endDay == day else { throw PlannerServiceError.invalidResponse }
                return try untimed(title: title.trimmingCharacters(in: .whitespacesAndNewlines), day: day, location: location)
            }
            guard let start = TripPlanning.date(dateString: day, timeString: startTime) else { throw PlannerServiceError.invalidResponse }
            let end: Date
            if let endTime { guard let parsed = TripPlanning.date(dateString: endDay ?? day, timeString: endTime) else { throw PlannerServiceError.invalidResponse }; end = parsed }
            else { guard endDay == nil || endDay == day else { throw PlannerServiceError.invalidResponse }; end = start.addingTimeInterval(Double(durationMinutes * 60)) }
            return PlanEvent(title: title.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end,
                notes: endTime == nil ? "未指定结束时间，按默认 \(durationMinutes) 分钟记录，可编辑。" : "", location: location)
        }
        try validate(events); return events
    }

    // Offline fallback accepts explicit numeric time ranges. Free-form speech is
    // handled by the configured model; no default appointment time is invented.
    static func local(_ input: String, now: Date = Date()) throws -> [PlanEvent] {
        guard input.count <= 2000 else { throw PlannerServiceError.invalidInput }
        let text = input.precomposedStringWithCompatibilityMapping
        let pieces = text.components(separatedBy: CharacterSet(charactersIn: "；;\n，,")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...20).contains(pieces.count) else { throw PlannerServiceError.invalidInput }
        let pattern = #"\A\s*(今天|明天|后天|[0-9]{4}-[0-9]{2}-[0-9]{2})?\s*(上午|早上|下午|晚上|中午)?\s*([0-9]{1,2})(?::([0-9]{2})|点([0-9]{1,2})?分?(半)?)\s*(?:到|至|-)\s*(上午|早上|下午|晚上|中午)?\s*([0-9]{1,2})(?::([0-9]{2})|点([0-9]{1,2})?分?(半)?)\s*(.{1,160})\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        var previousDay: String?, events: [PlanEvent] = []
        for piece in pieces {
            guard let match = regex.firstMatch(in: piece, range: NSRange(piece.startIndex..., in: piece)) else { throw AppFailure.message("请配置模型以识别自由口述，或按“今天9:00到10:00开会；今天14:00到15:00健身”输入完整时间段。") }
            func group(_ index: Int) -> String? { match.range(at: index).location == NSNotFound ? nil : (piece as NSString).substring(with: match.range(at: index)) }
            let day: String
            if let explicit = group(1) {
                if let offset = ["今天": 0, "明天": 1, "后天": 2][explicit] { day = formatter.string(from: calendar.date(byAdding: .day, value: offset, to: now)!) }
                else { day = explicit }
                previousDay = day
            } else if let previousDay { day = previousDay }
            else { throw AppFailure.message("请说明今天、明天或具体日期，不会自动猜测日期") }
            func clock(hour: Int, minute: Int, period: String?) throws -> String {
                var h = hour
                if hour == 12, ["上午", "早上", "晚上"].contains(period ?? "") { throw AppFailure.message("十二点的日期或上午下午有歧义，请使用明确的 00:00 或 12:00") }
                if ["下午", "晚上", "中午"].contains(period ?? ""), h < 12 { h += 12 }
                guard (0...23).contains(h), (0...59).contains(minute) else { throw PlannerServiceError.invalidInput }
                return String(format: "%02d:%02d", h, minute)
            }
            let startClock = try clock(hour: Int(group(3)!)!, minute: group(6) == nil ? Int(group(4) ?? group(5) ?? "0")! : 30, period: group(2))
            let endClock = try clock(hour: Int(group(8)!)!, minute: group(11) == nil ? Int(group(9) ?? group(10) ?? "0")! : 30, period: group(7) ?? group(2))
            guard let start = TripPlanning.date(dateString: day, timeString: startClock), let end = TripPlanning.date(dateString: day, timeString: endClock) else { throw PlannerServiceError.invalidInput }
            events.append(PlanEvent(title: group(12)!.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end))
        }
        try validate(events)
        return events
    }
}
