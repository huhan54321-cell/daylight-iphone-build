import Foundation

enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case driving, transit, walking, cycling
    var id: String { rawValue }
    var label: String {
        switch self {
        case .driving: return "驾车"
        case .transit: return "公交·地铁"
        case .walking: return "步行"
        case .cycling: return "骑行"
        }
    }
    fileprivate var navigationMode: String {
        switch self { case .driving: return "car"; case .transit: return "bus"; case .walking: return "walk"; case .cycling: return "ride" }
    }
}

struct PlannerPreferences: Codable, Equatable {
    var city = "青岛"
    var origin = ""
    var mode: TravelMode = .transit
    var bufferMinutes = 15
    var durationMinutes = 90
}

struct PlannerIntent: Codable {
    var title: String = ""
    var destination: String = ""
    var origin: String? = nil
    var date: String? = nil
    var time: String? = nil
    var mode: TravelMode? = nil
    var durationMinutes: Int? = nil

    // An incomplete model response is a draft for the user to complete, never a guessed appointment.
    var missingFields: [String] {
        var result: [String] = []
        if destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("目的地") }
        if origin?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { result.append("出发地点") }
        if date == nil { result.append("日期") }
        if time == nil { result.append("到达时间") }
        return result
    }
}

struct PlannerPlace: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var address: String
    var longitude: Double
    var latitude: Double
    var cityCode: String? = nil
}

struct PlannerRoute: Identifiable, Codable, Hashable {
    var id: String
    var mode: TravelMode
    var durationSeconds: Int
    var distanceMeters: Int
    var summary: String
    var costDescription: String? = nil
    var fetchedAt: Date
    var walkingDistanceMeters: Int? = nil
    var transferCount: Int? = nil
}

struct PlannerRouteOption {
    var route: PlannerRoute
    var departure: Date
    var arrival: Date
    var finish: Date
    var conflictCount: Int
    var departureIsFuture: Bool
    var isAvailable: Bool { departureIsFuture && conflictCount == 0 }
}

struct PlannerRouteAssessment: Codable {
    var routeID: String
    var benefits: String
    var tradeoffs: String
}

struct PlannerRouteAnalysis {
    var recommendedRouteID: String
    var summary: String
    var assessments: [PlannerRouteAssessment]
    var cautions: [String]
    var generatedAt: Date
    var model: String

    func assessment(for routeID: String) -> PlannerRouteAssessment? {
        assessments.first { $0.routeID == routeID }
    }
}

// Only the explanation for the confirmed route is saved; credentials and calendar contents are not.
struct PlannerSavedAdvice: Codable {
    var summary: String
    var benefits: String
    var tradeoffs: String
    var cautions: [String]
    var wasRecommended: Bool
    var generatedAt: Date
    var model: String
}

struct PlannedTrip: Identifiable, Codable {
    var id = UUID()
    var title: String
    var origin: PlannerPlace
    var destination: PlannerPlace
    var route: PlannerRoute
    var arrival: Date
    var durationMinutes: Int
    var bufferMinutes: Int
    // Persist these IDs so saving or refreshing a trip does not insert duplicate calendar events.
    var eventIDs: [UUID] = [UUID(), UUID()]
    var createdAt = Date()
    var advice: PlannerSavedAdvice? = nil
}

enum TripPlanning {
    private static let earliest = Date(timeIntervalSince1970: 946_656_000) // 2000-01-01 in UTC+8
    private static let latest = Date(timeIntervalSince1970: 4_133_952_000) // 2101-01-01 in UTC+8

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date >= earliest && date < latest
    }
    private static func validText(_ text: String, maximum: Int, required: Bool = true) -> Bool {
        text.count <= maximum && (!required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0.value != 10 && $0.value != 13 && $0.value != 9 }
    }

    static func validate(_ preferences: PlannerPreferences) throws {
        guard validText(preferences.city, maximum: 100), validText(preferences.origin, maximum: 300, required: false),
              (0...120).contains(preferences.bufferMinutes), (5...1_440).contains(preferences.durationMinutes) else {
            throw AppFailure.message("城市或出发地点格式错误；缓冲时间应为 0–120 分钟，活动时长应为 5–1440 分钟")
        }
    }

    static func validate(_ intent: PlannerIntent) throws {
        guard validText(intent.title, maximum: 200, required: false), validText(intent.destination, maximum: 200, required: false),
              intent.origin.map({ validText($0, maximum: 300, required: false) }) ?? true,
              intent.durationMinutes.map({ (5...1_440).contains($0) }) ?? true else {
            throw AppFailure.message("计划草稿中的地点、标题或活动时长格式错误，请调整后继续")
        }
        if let day = intent.date, date(dateString: day, timeString: intent.time ?? "12:00") == nil {
            throw AppFailure.message("计划日期应为有效的 yyyy-MM-dd，时间应为 HH:mm")
        }
        if let time = intent.time, date(dateString: intent.date ?? "2026-01-01", timeString: time) == nil {
            throw AppFailure.message("到达时间应为有效的 HH:mm")
        }
    }

    static func validate(_ place: PlannerPlace) throws {
        guard validText(place.id, maximum: 200), validText(place.name, maximum: 200), validText(place.address, maximum: 500, required: false),
              place.longitude.isFinite, place.latitude.isFinite,
              (-180...180).contains(place.longitude), (-90...90).contains(place.latitude),
              place.cityCode.map({ $0.range(of: #"^[0-9]{2,6}$"#, options: .regularExpression) != nil }) ?? true else {
            throw AppFailure.message("地图地点信息无效，请重新选择地点")
        }
    }

    static func validate(_ route: PlannerRoute) throws {
        guard validText(route.id, maximum: 200), validText(route.summary, maximum: 1_000),
              route.costDescription.map({ validText($0, maximum: 300, required: false) }) ?? true,
              route.walkingDistanceMeters.map({ (0...2_000_000).contains($0) }) ?? true,
              route.transferCount.map({ (0...50).contains($0) }) ?? true,
              (1...86_400).contains(route.durationSeconds), (0...2_000_000).contains(route.distanceMeters), validDate(route.fetchedAt) else {
            throw AppFailure.message("路线数据无效或耗时超过一天，请重新查询")
        }
    }

    static func validate(_ trip: PlannedTrip) throws {
        try validate(trip.origin)
        try validate(trip.destination)
        try validate(trip.route)
        if let advice = trip.advice { try validate(advice) }
        guard validText(trip.title, maximum: 200), (5...1_440).contains(trip.durationMinutes),
              (0...120).contains(trip.bufferMinutes), validDate(trip.arrival), validDate(trip.createdAt),
              trip.eventIDs.count == 2, Set(trip.eventIDs).count == 2 else {
            throw AppFailure.message("行程信息无效，请检查标题、时间、时长和缓冲时间")
        }
        let departure = trip.arrival.addingTimeInterval(-Double(trip.route.durationSeconds) - Double(trip.bufferMinutes) * 60)
        let finish = trip.arrival.addingTimeInterval(Double(trip.durationMinutes) * 60)
        guard validDate(departure), validDate(finish), departure < trip.arrival, finish > trip.arrival else {
            throw AppFailure.message("行程日期超出可用范围，请重新设置")
        }
    }

    static func validate(_ advice: PlannerSavedAdvice) throws {
        guard validText(advice.summary, maximum: 800), validText(advice.benefits, maximum: 500),
              validText(advice.tradeoffs, maximum: 500), advice.cautions.count <= 5,
              advice.cautions.allSatisfy({ validText($0, maximum: 300) }),
              validText(advice.model, maximum: 160), validDate(advice.generatedAt) else {
            throw AppFailure.message("路线分析内容无效，请重新分析或手动选择路线")
        }
    }

    static func analysisOptions(title: String, origin: PlannerPlace, destination: PlannerPlace,
                                routes: [PlannerRoute], arrival: Date, durationMinutes: Int,
                                bufferMinutes: Int, events: [PlanEvent], now: Date) throws -> [PlannerRouteOption] {
        guard (1...3).contains(routes.count), Set(routes.map(\.id)).count == routes.count,
              Set(routes.map(\.mode)).count == 1, validDate(now) else {
            throw AppFailure.message("请重新查询一到三条有效路线后分析")
        }
        return try routes.map { route in
            let trip = PlannedTrip(title: title, origin: origin, destination: destination, route: route,
                                   arrival: arrival, durationMinutes: durationMinutes, bufferMinutes: bufferMinutes, createdAt: now)
            try validate(trip)
            let eventsToAdd = schedule(trip)
            let departure = eventsToAdd[0].start
            return PlannerRouteOption(route: route, departure: departure, arrival: arrival, finish: eventsToAdd[1].end,
                                      conflictCount: conflicts(events: events, proposed: eventsToAdd).count,
                                      departureIsFuture: departure > now)
        }
    }

    static func validate(_ analysis: PlannerRouteAnalysis, options: [PlannerRouteOption]) throws {
        let ids = Set(options.map { $0.route.id })
        guard (1...3).contains(options.count), ids.count == options.count,
              ids.contains(analysis.recommendedRouteID), analysis.assessments.count == options.count,
              Set(analysis.assessments.map(\.routeID)) == ids else {
            throw AppFailure.message("模型未完整比较实际路线，请重试或自行选择")
        }
        // Prefer a route that can still be taken and has no known conflict whenever one exists.
        let available = options.filter(\.isAvailable)
        guard available.isEmpty || available.contains(where: { $0.route.id == analysis.recommendedRouteID }) else {
            throw AppFailure.message("模型推荐与当前时间或日程冲突，请重试或自行选择")
        }
        for item in analysis.assessments {
            try validate(PlannerSavedAdvice(summary: analysis.summary, benefits: item.benefits, tradeoffs: item.tradeoffs,
                cautions: analysis.cautions, wasRecommended: item.routeID == analysis.recommendedRouteID,
                generatedAt: analysis.generatedAt, model: analysis.model))
        }
    }

    static func savedAdvice(_ analysis: PlannerRouteAnalysis?, selectedRouteID: String) -> PlannerSavedAdvice? {
        guard let analysis, let item = analysis.assessment(for: selectedRouteID) else { return nil }
        return PlannerSavedAdvice(summary: analysis.summary, benefits: item.benefits, tradeoffs: item.tradeoffs,
            cautions: analysis.cautions, wasRecommended: selectedRouteID == analysis.recommendedRouteID,
            generatedAt: analysis.generatedAt, model: analysis.model)
    }

    static func schedule(_ trip: PlannedTrip) -> [PlanEvent] {
        guard (try? validate(trip)) != nil else { return [] }
        let departure = trip.arrival.addingTimeInterval(-Double(trip.route.durationSeconds) - Double(trip.bufferMinutes) * 60)
        let finish = trip.arrival.addingTimeInterval(Double(trip.durationMinutes) * 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let minutes = Int(ceil(Double(trip.route.durationSeconds) / 60))
        let distance = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(trip.route.distanceMeters) / 1_000)
        var details = "高德地图路线估算：\(trip.route.mode.label)，约 \(minutes) 分钟，\(distance) 公里。\n\(trip.route.summary)"
        if let cost = trip.route.costDescription, !cost.isEmpty { details += "\n\(cost)" }
        if let walking = trip.route.walkingDistanceMeters { details += "\n步行参考：\(walking) 米" }
        if let transfers = trip.route.transferCount { details += "\n公交／轨道换乘参考：\(transfers) 次" }
        details += "\n查询时间：\(formatter.string(from: trip.route.fetchedAt))（中国标准时间）。\n已预留 \(trip.bufferMinutes) 分钟缓冲。交通和营业情况可能变化，请在出发前刷新路线。\n打开导航时高德会重新规划路线，不保证与此处选中的路线相同。"
        if let advice = trip.advice {
            details += "\n\n模型分析参考（\(formatter.string(from: advice.generatedAt))）：\(advice.summary)"
            details += advice.wasRecommended ? "\n本次选择了模型推荐路线。" : "\n本次自行选择了其他路线。"
            details += "\n所选路线优点：\(advice.benefits)\n取舍：\(advice.tradeoffs)"
            if !advice.cautions.isEmpty { details += "\n注意：" + advice.cautions.joined(separator: "；") }
            details += "\n模型分析不替代地图数据；变更日程后应重新规划。"
        }
        let link = navigationURL(origin: trip.origin, destination: trip.destination, mode: trip.route.mode)?.absoluteString
        return [
            PlanEvent(id: trip.eventIDs[0], title: "\(trip.route.mode.label)前往\(trip.destination.name)", start: departure, end: trip.arrival,
                      notes: "从 \(trip.origin.name) 出发。\n\(details)", location: trip.destination.address, navigationURL: link, tripID: trip.id),
            PlanEvent(id: trip.eventIDs[1], title: trip.title, start: trip.arrival, end: finish,
                      notes: "地点：\(trip.destination.name)\n\(trip.destination.address)\n\(details)", location: trip.destination.address, navigationURL: link, tripID: trip.id)
        ]
    }

    static func conflicts(events: [PlanEvent], proposed: [PlanEvent]) -> [PlanEvent] {
        let validProposals = proposed.filter { validDate($0.start) && validDate($0.end) && $0.start < $0.end }
        let ownIDs = Set(proposed.map(\.id))
        let ownTrips = Set(proposed.compactMap(\.tripID))
        var seen = Set<UUID>()
        return events.filter { existing in
            guard !ownIDs.contains(existing.id), !(existing.tripID.map({ ownTrips.contains($0) }) ?? false),
                  validDate(existing.start), validDate(existing.end), existing.start < existing.end,
                  validProposals.contains(where: { existing.start < $0.end && $0.start < existing.end }) else { return false }
            return seen.insert(existing.id).inserted
        }.sorted { left, right in
            left.start == right.start ? left.id.uuidString < right.id.uuidString : left.start < right.start
        }
    }

    static func requireFutureDeparture(_ trip: PlannedTrip, now: Date) throws {
        try validate(trip)
        guard validDate(now), let departure = schedule(trip).first?.start, departure > now else {
            throw AppFailure.message("按当前路线已来不及出发，请调整到达时间并重新预览")
        }
    }

    static func needsConflictReview(current: [PlanEvent], approved: [PlanEvent]) -> Bool {
        func identity(_ event: PlanEvent) -> String {
            // EventKit fetches produce new local UUIDs; approval belongs to the calendar occurrence and its times.
            let id = event.eventID ?? event.id.uuidString
            return "\(id)|\(event.start.timeIntervalSince1970)|\(event.end.timeIntervalSince1970)"
        }
        return !Set(current.map(identity)).isSubset(of: Set(approved.map(identity)))
    }

    static func navigationURL(origin: PlannerPlace, destination: PlannerPlace, mode: TravelMode) -> URL? {
        guard (try? validate(origin)) != nil, (try? validate(destination)) != nil else { return nil }
        func point(_ place: PlannerPlace) -> String {
            let longitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), place.longitude)
            let latitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), place.latitude)
            // Commas delimit coordinates in the URI; labels may not introduce a fourth component.
            let name = place.name.replacingOccurrences(of: ",", with: "，").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            return "\(longitude),\(latitude),\(name)"
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "uri.amap.com"
        components.path = "/navigation"
        components.queryItems = [URLQueryItem(name: "from", value: point(origin)), URLQueryItem(name: "to", value: point(destination)),
                                 URLQueryItem(name: "mode", value: mode.navigationMode), URLQueryItem(name: "policy", value: "0"),
                                 URLQueryItem(name: "src", value: "Daylight"), URLQueryItem(name: "callnative", value: "1")]
        return components.url
    }

    static func date(dateString: String, timeString: String) -> Date? {
        guard dateString.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              timeString.range(of: #"^[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        let text = "\(dateString) \(timeString)"
        guard let result = formatter.date(from: text), validDate(result), formatter.string(from: result) == text else { return nil }
        return result
    }
}
