import Foundation

enum PlannerCoreTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            guard condition else { throw AppFailure.message("FAIL planner: \(label)") }
        }
        func rejects(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        let origin = PlannerPlace(id: "origin", name: "家", address: "青岛市南区", longitude: 120.38, latitude: 36.06, cityCode: "0532")
        let destination = PlannerPlace(id: "destination", name: "餐馆", address: "青岛市南区测试路", longitude: 120.4, latitude: 36.07, cityCode: "0532")
        let arrival = TripPlanning.date(dateString: "2026-10-02", timeString: "00:10")!
        let fetched = TripPlanning.date(dateString: "2026-10-01", timeString: "18:00")!
        let route = PlannerRoute(id: "route-1", mode: .transit, durationSeconds: 1_800, distanceMeters: 8_000,
                                 summary: "地铁换乘公交", costDescription: "票价约 4 元", fetchedAt: fetched)
        let trip = PlannedTrip(title: "晚餐", origin: origin, destination: destination, route: route,
                               arrival: arrival, durationMinutes: 90, bufferMinutes: 20, createdAt: fetched)
        let preferences = PlannerPreferences()
        try expect(preferences.city == "青岛" && preferences.origin.isEmpty && preferences.mode == .transit
                   && preferences.bufferMinutes == 15 && preferences.durationMinutes == 90, "usable preferences retain missing origin")
        try expect(arrival == ISO8601DateFormatter().date(from: "2026-10-01T16:10:00Z"), "Chinese local date is fixed UTC+8")
        let badDays = ["2026-02-29", "2026-02-30", "2026-13-01", "2026-10-00", "2026-1-02", "2026-10-02\n", "1999-12-31", "2101-01-01"]
        try expect(badDays.allSatisfy { TripPlanning.date(dateString: $0, timeString: "18:30") == nil }
                   && TripPlanning.date(dateString: "2028-02-29", timeString: "18:30") != nil, "invalid dates never normalize or roll over")
        try expect(["24:00", "18:60", "8:30", "18:30:00", " 18:30", "18:30\n"].allSatisfy {
            TripPlanning.date(dateString: "2026-10-02", timeString: $0) == nil
        }, "only exact HH:mm accepted")
        let missing = PlannerIntent(title: "吃饭", destination: "餐馆")
        try TripPlanning.validate(missing)
        try expect(missing.origin == nil && missing.date == nil && missing.time == nil && missing.mode == nil
                   && missing.missingFields == ["出发地点", "日期", "到达时间"], "model omissions stay explicit for user confirmation")
        let unknownMode = Data(#"{"title":"晚餐","destination":"餐馆","mode":"teleport"}"#.utf8)
        let invalidDateType = Data(#"{"title":"晚餐","destination":"餐馆","date":20261002}"#.utf8)
        try expect(rejects { _ = try JSONDecoder().decode(PlannerIntent.self, from: unknownMode) }
                   && rejects { _ = try JSONDecoder().decode(PlannerIntent.self, from: invalidDateType) }, "structured invalid mode or date type not guessed")
        try expect(rejects { try TripPlanning.validate(PlannerIntent(date: "2026-02-30")) }
                   && rejects { try TripPlanning.validate(PlannerIntent(time: "25:00")) }
                   && rejects { try TripPlanning.validate(PlannerIntent(durationMinutes: 4)) }, "invalid structured field contents fail validation")
        try TripPlanning.validate(trip)
        let schedule = TripPlanning.schedule(trip)
        try expect(schedule.count == 2 && schedule[0].end == schedule[1].start && schedule[0].tripID == trip.id,
                   "valid trip creates connected travel and activity events")
        try expect(schedule[0].start == TripPlanning.date(dateString: "2026-10-01", timeString: "23:20"), "midnight departure crosses preceding day with buffer")
        try expect(schedule[1].end == TripPlanning.date(dateString: "2026-10-02", timeString: "01:40")
                   && schedule[0].notes.contains("高德") && schedule[0].notes.contains("20 分钟缓冲")
                   && schedule[0].notes.contains("重新规划"), "activity duration and estimate disclosure retained")
        let decodedTrip = try JSONDecoder().decode(PlannedTrip.self, from: JSONEncoder().encode(trip))
        try expect(TripPlanning.schedule(trip).map(\.id) == trip.eventIDs && TripPlanning.schedule(decodedTrip).map(\.id) == trip.eventIDs,
                   "event IDs stable across rescheduling and persistence")
        let oldEventData = Data(#"{"id":"F4F4A102-56A1-498D-BA0C-41B8439ACB28","title":"旧日程","start":810273600,"end":810277200,"notes":"保留"}"#.utf8)
        let oldEvent = try JSONDecoder().decode(PlanEvent.self, from: oldEventData)
        try expect(oldEvent.title == "旧日程" && oldEvent.location == nil && oldEvent.navigationURL == nil && oldEvent.tripID == nil,
                   "legacy event without planner metadata decodes")
        let legacySnapshotData = Data(#"{"version":3,"transactions":[],"tasks":[],"events":[{"id":"F4F4A102-56A1-498D-BA0C-41B8439ACB28","title":"旧日程","start":810273600,"end":810277200,"notes":"保留"}],"weights":[],"workouts":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(Snapshot.self, from: legacySnapshotData)
        try expect(legacy.plannedTrips.isEmpty && legacy.plannerPreferences == PlannerPreferences() && legacy.events.count == 1,
                   "version three snapshot keeps real events and defaults preferences")
        var noBuffer = trip; noBuffer.bufferMinutes = 0
        var maxBuffer = trip; maxBuffer.bufferMinutes = 120
        try expect(TripPlanning.schedule(noBuffer).first?.start == arrival.addingTimeInterval(-1_800)
                   && TripPlanning.schedule(maxBuffer).first?.start == arrival.addingTimeInterval(-9_000), "zero and maximum buffer exact")
        var negativeBuffer = trip; negativeBuffer.bufferMinutes = -1
        var excessiveBuffer = trip; excessiveBuffer.bufferMinutes = 121
        var zeroRoute = trip; zeroRoute.route.durationSeconds = 0
        var excessiveRoute = trip; excessiveRoute.route.durationSeconds = 86_401
        var negativeDistance = trip; negativeDistance.route.distanceMeters = -1
        var excessiveDistance = trip; excessiveDistance.route.distanceMeters = 2_000_001
        try expect([negativeBuffer, excessiveBuffer, zeroRoute, excessiveRoute, negativeDistance, excessiveDistance].allSatisfy { invalid in
            rejects { try TripPlanning.validate(invalid) } && TripPlanning.schedule(invalid).isEmpty
        }, "unusable route or buffer rejected without creating events")
        var shortActivity = trip; shortActivity.durationMinutes = 4
        var longActivity = trip; longActivity.durationMinutes = 1_441
        var missingID = trip; missingID.eventIDs = [UUID()]
        var duplicateID = trip; duplicateID.eventIDs = [trip.eventIDs[0], trip.eventIDs[0]]
        try expect([shortActivity, longActivity, missingID, duplicateID].allSatisfy { invalid in rejects { try TripPlanning.validate(invalid) } },
                   "invalid activity duration and unstable IDs fail validation")
        var invalidLatitude = origin; invalidLatitude.latitude = 90.1
        var invalidLongitude = origin; invalidLongitude.longitude = -180.1
        var nanPlace = origin; nanPlace.latitude = .nan
        var infinitePlace = origin; infinitePlace.longitude = .infinity
        try expect([invalidLatitude, invalidLongitude, nanPlace, infinitePlace].allSatisfy { invalid in
            rejects { try TripPlanning.validate(invalid) } && TripPlanning.navigationURL(origin: invalid, destination: destination, mode: .walking) == nil
        }, "coordinates validated before navigation")
        var nonFiniteTrip = trip; nonFiniteTrip.arrival = Date(timeIntervalSince1970: .nan)
        var nonFiniteRoute = trip; nonFiniteRoute.route.fetchedAt = Date(timeIntervalSince1970: .infinity)
        var outOfRangeTrip = trip; outOfRangeTrip.arrival = Date(timeIntervalSince1970: 1e20)
        try expect([nonFiniteTrip, nonFiniteRoute, outOfRangeTrip].allSatisfy { invalid in rejects { try TripPlanning.validate(invalid) } }, "invalid timestamps cannot overflow scheduling")
        var longTitle = trip; longTitle.title = String(repeating: "字", count: 201)
        var longSummary = trip; longSummary.route.summary = String(repeating: "字", count: 1_001)
        var longCost = trip; longCost.route.costDescription = String(repeating: "字", count: 301)
        var emptyName = trip; emptyName.destination.name = " \n "
        try expect([longTitle, longSummary, longCost, emptyName].allSatisfy { invalid in rejects { try TripPlanning.validate(invalid) } }, "unbounded or empty text rejected")
        var namedDestination = destination; namedDestination.name = "餐馆,A&B + 海景?#"
        let url = TripPlanning.navigationURL(origin: origin, destination: namedDestination, mode: .transit)!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try expect(components.scheme == "https" && components.host == "uri.amap.com" && components.path == "/navigation"
                   && query["to"] == "120.400000,36.070000,餐馆，A&B + 海景?#" && query["src"] == "Daylight"
                   && query["callnative"] == "1" && components.queryItems?.count == 6, "navigation encodes names without query injection or comma ambiguity")
        let modes: [TravelMode: String] = [.driving: "car", .transit: "bus", .walking: "walk", .cycling: "ride"]
        try expect(modes.allSatisfy { mode, expected in
            guard let link = TripPlanning.navigationURL(origin: origin, destination: destination, mode: mode) else { return false }
            return URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "mode" })?.value == expected
        }, "all travel modes map to official navigation modes")
        let before = PlanEvent(title: "之前", start: schedule[0].start.addingTimeInterval(-1_800), end: schedule[0].start)
        let after = PlanEvent(title: "之后", start: schedule[1].end, end: schedule[1].end.addingTimeInterval(1_800))
        try expect(TripPlanning.conflicts(events: [before, after], proposed: schedule).isEmpty, "touching event boundaries do not conflict")
        let overlap = PlanEvent(title: "冲突", start: schedule[0].start.addingTimeInterval(60), end: schedule[1].end.addingTimeInterval(-60))
        let invalidEvent = PlanEvent(title: "无效", start: arrival, end: arrival)
        try expect(TripPlanning.conflicts(events: [overlap, overlap, invalidEvent], proposed: schedule).map(\.id) == [overlap.id],
                   "one overlap across two proposed events returned once and invalid events ignored")
        var sameTripOtherID = overlap; sameTripOtherID.tripID = trip.id
        try expect(TripPlanning.conflicts(events: schedule + [sameTripOtherID], proposed: schedule).isEmpty, "refresh excludes trip's own calendar events")
        var snapshot = Snapshot()
        snapshot.plannedTrips = [trip]
        snapshot.events = schedule
        snapshot.plannerPreferences.origin = "家"
        let restored = try BackupCodec.decode(BackupCodec.export(snapshot))
        try expect(restored.plannedTrips.count == 1 && restored.plannedTrips[0].eventIDs == trip.eventIDs
                   && restored.plannerPreferences.origin == "家" && restored.events[0].navigationURL == schedule[0].navigationURL,
                   "full backup preserves trip linkage navigation and preferences")
        try expect(decodedTrip.advice == nil, "older trip without model advice remains readable")
        var longRoute = route; longRoute.id = "route-long"; longRoute.durationSeconds = 3600
        let earlyConflict = PlanEvent(title: "不得上传的私人日程", start: schedule[0].start.addingTimeInterval(-1200), end: schedule[0].start)
        let options = try TripPlanning.analysisOptions(title: trip.title, origin: origin, destination: destination,
            routes: [route, longRoute], arrival: arrival, durationMinutes: 90, bufferMinutes: 20, events: [earlyConflict, earlyConflict], now: fetched)
        try expect(options[0].isAvailable && options[0].conflictCount == 0 && options[1].conflictCount == 1 && !options[1].isAvailable,
                   "route-specific conflict counts distinguish alternatives and deduplicate events")
        try expect(options[0].departure == schedule[0].start && options[1].departure == schedule[0].start.addingTimeInterval(-1800)
                   && options.allSatisfy({ $0.arrival == arrival && $0.finish == schedule[1].end }),
                   "analysis candidate times come from the same authoritative schedule calculation")
        let lateOptions = try TripPlanning.analysisOptions(title: trip.title, origin: origin, destination: destination,
            routes: [route, longRoute], arrival: arrival, durationMinutes: 90, bufferMinutes: 20, events: [],
            now: schedule[0].start.addingTimeInterval(-60))
        try expect(lateOptions[0].departureIsFuture && !lateOptions[1].departureIsFuture && !lateOptions[1].isAvailable,
                   "elapsed departure is unavailable even without calendar conflicts")
        let analysis = PlannerRouteAnalysis(recommendedRouteID: route.id, summary: "短程方案省时，符合偏好。",
            assessments: [PlannerRouteAssessment(routeID: route.id, benefits: "耗时更短。", tradeoffs: "完整费用未知。"),
                          PlannerRouteAssessment(routeID: longRoute.id, benefits: "另一条实际路线。", tradeoffs: "需要更早出发。")],
            cautions: ["出发前刷新路线。"], generatedAt: fetched, model: "fixture-model")
        try TripPlanning.validate(analysis, options: options)
        var unknown = analysis; unknown.recommendedRouteID = "fabricated-route"
        var unavailable = analysis; unavailable.recommendedRouteID = longRoute.id
        var repeatedAssessment = analysis; repeatedAssessment.assessments = [analysis.assessments[0], analysis.assessments[0]]
        var incomplete = analysis; incomplete.assessments.removeLast()
        try expect([unknown, unavailable, repeatedAssessment, incomplete].allSatisfy { value in
            rejects { try TripPlanning.validate(value, options: options) }
        }, "unknown, conflicting, duplicated and incomplete recommendations rejected")
        var allBlocked = options; allBlocked[0].conflictCount = 1
        try TripPlanning.validate(unavailable, options: allBlocked)
        try expect(TripPlanning.savedAdvice(analysis, selectedRouteID: "unknown") == nil
                   && TripPlanning.savedAdvice(analysis, selectedRouteID: longRoute.id)?.wasRecommended == false,
                   "only the actual selected route gets its own assessment even when overriding recommendation")
        var analyzedTrip = trip
        analyzedTrip.advice = TripPlanning.savedAdvice(analysis, selectedRouteID: route.id)
        var analyzedSnapshot = snapshot; analyzedSnapshot.plannedTrips = [analyzedTrip]; analyzedSnapshot.events = TripPlanning.schedule(analyzedTrip)
        let analyzedRestore = try BackupCodec.decode(BackupCodec.export(analyzedSnapshot))
        try expect(analyzedRestore.plannedTrips[0].advice?.summary == analysis.summary
                   && analyzedRestore.plannedTrips[0].advice?.wasRecommended == true
                   && analyzedRestore.plannedTrips[0].advice?.generatedAt == fetched
                   && analyzedRestore.events[0].notes.contains("模型分析参考")
                   && analyzedRestore.events.map(\.id) == trip.eventIDs, "advice survives backup without altering calendar times or IDs")
        var badAdvice = analyzedTrip; badAdvice.advice!.summary = String(repeating: "字", count: 801)
        var badCaution = analyzedTrip; badCaution.advice!.cautions = Array(repeating: "提醒", count: 6)
        var badAdviceDate = analyzedTrip; badAdviceDate.advice!.generatedAt = Date(timeIntervalSince1970: .infinity)
        try expect([badAdvice, badCaution, badAdviceDate].allSatisfy { value in rejects { try TripPlanning.validate(value) } },
                   "invalid stored advice fails validation rather than corrupting records")
        try expect(rejects { _ = try TripPlanning.analysisOptions(title: trip.title, origin: origin, destination: destination,
            routes: [route, route], arrival: arrival, durationMinutes: 90, bufferMinutes: 20, events: [], now: fetched) },
                   "duplicate routes cannot be submitted for comparison")
        try TripPlanning.requireFutureDeparture(trip, now: schedule[0].start.addingTimeInterval(-1))
        try expect(rejects { try TripPlanning.requireFutureDeparture(trip, now: schedule[0].start) }
                   && rejects { try TripPlanning.requireFutureDeparture(trip, now: schedule[0].start.addingTimeInterval(60)) },
                   "departure that elapses after preview is rejected at final confirmation")
        var approvedRemote = overlap; approvedRemote.eventID = "stable-calendar-conflict"
        var refreshedRemote = approvedRemote; refreshedRemote.id = UUID()
        try expect(!TripPlanning.needsConflictReview(current: [refreshedRemote], approved: [approvedRemote]),
                   "same approved calendar occurrence remains approved after a fresh fetch changes local UUID")
        var changedRemote = refreshedRemote; changedRemote.start = changedRemote.start.addingTimeInterval(60)
        try expect(TripPlanning.needsConflictReview(current: [changedRemote], approved: [approvedRemote])
                   && TripPlanning.needsConflictReview(current: [approvedRemote, before], approved: [approvedRemote])
                   && TripPlanning.needsConflictReview(current: [approvedRemote], approved: [])
                   && !TripPlanning.needsConflictReview(current: [], approved: [approvedRemote]),
                   "new or rescheduled conflicts require confirmation, while disappeared conflicts do not")
        return checks
    }
}
