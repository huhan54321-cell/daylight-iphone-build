import Foundation

enum PlannerIntegrationTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            guard condition else { throw AppFailure.message("FAIL planner integration: \(label)") }
        }
        func rejects(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        let smsID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let legacy = Data("""
        {"version":3,"transactions":[{"id":"\(smsID.uuidString)","date":810273600,"kind":"expense","cents":1234,"title":"原消费","category":"购物","source":"工行储蓄卡","externalID":"sms:\(smsID.uuidString)","bankDirection":"debit","bankBalanceAfterCents":11111,"bankBalanceReportedAt":810273620,"bankTimeIsMinuteOnly":true}],"tasks":[],"events":[],"weights":[],"workouts":[],"smsInbox":[{"id":"\(smsID.uuidString)","requestID":"20261002141800001","fingerprint":"legacy-fixture","receivedAt":810273620,"body":"尾号XXXX卡支出12.34元，余额已隐藏。【工商银行】","draft":{"id":"\(smsID.uuidString)","date":810273600,"kind":"expense","cents":1234,"title":"原消费","category":"购物","source":"工行储蓄卡","bankDirection":"debit","bankBalanceAfterCents":11111,"bankBalanceReportedAt":810273620,"bankTimeIsMinuteOnly":true},"warnings":[],"status":"recorded","reason":"已记录","possibleDuplicate":false,"bankBalanceAfterCents":11111}],"autoRecordSMS":true,"bankBalanceBaseline":{"cents":20000,"date":810270000}}
        """.utf8)
        let migrated = try JSONDecoder().decode(Snapshot.self, from: legacy)
        try SnapshotChecks.validate(migrated)
        try expect(migrated.version == 4 && migrated.plannedTrips.isEmpty && migrated.plannerPreferences == PlannerPreferences(),
                   "schema three migrates to four without inserting demonstration trips")
        try expect(migrated.autoRecordSMS && migrated.smsInbox[0].id == smsID && migrated.smsInbox[0].status == .recorded
                   && migrated.smsInbox[0].bankBalanceAfterCents == 11111 && migrated.transactions[0].bankTimeIsMinuteOnly == true
                   && migrated.bankBalanceBaseline?.cents == 20000 && BankBalanceMath.reading(migrated)?.cents == 11111,
                   "migration preserves SMS links automatic setting and bank balance")

        let instant = TripPlanning.date(dateString: "2026-10-02", timeString: "12:00")!
        let origin = PlannerPlace(id: "integration-origin", name: "家", address: "青岛市南区起点", longitude: 120.38, latitude: 36.06, cityCode: "0532")
        let destination = PlannerPlace(id: "integration-destination", name: "餐馆", address: "青岛市南区终点", longitude: 120.40, latitude: 36.07, cityCode: "0532")
        let route = PlannerRoute(id: "integration-route", mode: .transit, durationSeconds: 1800, distanceMeters: 8000,
                                 summary: "地铁换乘公交", fetchedAt: instant)
        let trip = PlannedTrip(title: "和朋友吃晚餐", origin: origin, destination: destination, route: route,
                               arrival: instant.addingTimeInterval(6 * 3600), durationMinutes: 90, bufferMinutes: 15, createdAt: instant)
        var source = migrated
        source.plannedTrips = [trip]
        source.plannerPreferences = PlannerPreferences(city: "青岛", origin: "常用出发地址", mode: .walking, bufferMinutes: 20, durationMinutes: 120)
        source.events = TripPlanning.schedule(trip)
        source.events[0].eventID = "calendar-event-travel"
        source.events[1].eventID = "calendar-event-dinner"
        let backup = try BackupCodec.export(source)
        let decoded = try BackupCodec.decode(backup)
        let restored = try BackupCodec.merge(decoded, into: Snapshot())
        try expect(restored.plannedTrips.count == 1 && restored.plannedTrips[0].id == trip.id
                   && restored.plannedTrips[0].eventIDs == trip.eventIDs && restored.events.map(\.id) == source.events.map(\.id)
                   && restored.plannerPreferences == source.plannerPreferences && restored.transactions.count == 1,
                   "complete backup merges trip preferences and existing finances into empty installation")
        let repeated = try BackupCodec.merge(decoded, into: restored)
        try expect(repeated.plannedTrips.count == 1 && repeated.events.count == 2 && repeated.transactions.count == 1
                   && repeated.plannedTrips[0].eventIDs == restored.plannedTrips[0].eventIDs,
                   "repeated trip backup import does not multiply trips or events")
        var customized = Snapshot()
        customized.plannerPreferences = PlannerPreferences(city: "北京", origin: "办公地点", mode: .cycling, bufferMinutes: 30, durationMinutes: 45)
        let mergedCustom = try BackupCodec.merge(decoded, into: customized)
        try expect(mergedCustom.plannerPreferences == customized.plannerPreferences && mergedCustom.plannedTrips.count == 1,
                   "current customized preferences take precedence over imported defaults")

        // A fresh installation may read Apple Calendar before restoring an older app backup.
        // Those events have newly generated local UUIDs but matching EventKit occurrence IDs.
        var fresh = Snapshot()
        let remoteTravelID = UUID(), remoteDinnerID = UUID()
        let travel = source.events[0], dinner = source.events[1]
        fresh.events = [
            PlanEvent(id: remoteTravelID, title: "苹果里修改过的出发标题", start: travel.start, end: travel.end,
                      notes: "当前日历备注", eventID: travel.eventID, location: "当前日历地点"),
            PlanEvent(id: remoteDinnerID, title: dinner.title, start: dinner.start, end: dinner.end,
                      notes: dinner.notes, eventID: dinner.eventID)
        ]
        let mergedRemote = try BackupCodec.merge(decoded, into: fresh)
        try expect(mergedRemote.events.count == 2 && mergedRemote.plannedTrips.count == 1
                   && mergedRemote.plannedTrips[0].eventIDs == [remoteTravelID, remoteDinnerID],
                   "restore remaps backed-up trip UUIDs onto already-read calendar events")
        let linkedTravel = mergedRemote.events.first(where: { $0.id == remoteTravelID })!
        let linkedDinner = mergedRemote.events.first(where: { $0.id == remoteDinnerID })!
        try expect(linkedTravel.tripID == trip.id && linkedDinner.tripID == trip.id
                   && linkedTravel.navigationURL == travel.navigationURL && linkedDinner.navigationURL == dinner.navigationURL,
                   "calendar deduplication restores trip and navigation metadata")
        try expect(linkedTravel.title == fresh.events[0].title && linkedTravel.notes == fresh.events[0].notes
                   && linkedTravel.location == fresh.events[0].location && linkedTravel.start == fresh.events[0].start,
                   "restoring linkage preserves user-edited current calendar content")
        let remoteTwice = try BackupCodec.merge(decoded, into: mergedRemote)
        try expect(remoteTwice.events.count == 2 && remoteTwice.plannedTrips.count == 1
                   && remoteTwice.plannedTrips[0].eventIDs == [remoteTravelID, remoteDinnerID]
                   && remoteTwice.events.first(where: { $0.id == remoteTravelID })?.tripID == trip.id,
                   "second restore keeps remapped UUIDs and does not drop linkage")

        var rescheduled = fresh
        for index in rescheduled.events.indices {
            rescheduled.events[index].start = rescheduled.events[index].start.addingTimeInterval(3600)
            rescheduled.events[index].end = rescheduled.events[index].end.addingTimeInterval(3600)
        }
        let movedMerged = try BackupCodec.merge(decoded, into: rescheduled)
        try expect(movedMerged.events.count == 2 && movedMerged.plannedTrips[0].eventIDs == [remoteTravelID, remoteDinnerID]
                   && movedMerged.events.first(where: { $0.id == remoteTravelID })?.start == travel.start.addingTimeInterval(3600)
                   && movedMerged.events.first(where: { $0.id == remoteDinnerID })?.end == dinner.end.addingTimeInterval(3600)
                   && movedMerged.events.allSatisfy({ $0.tripID == trip.id && $0.navigationURL != nil }),
                   "restore reconnects individually rescheduled Apple events without restoring obsolete times")
        let movedTwice = try BackupCodec.merge(decoded, into: movedMerged)
        try expect(movedTwice.events.count == 2 && movedTwice.plannedTrips[0].eventIDs == [remoteTravelID, remoteDinnerID]
                   && movedTwice.events.first(where: { $0.id == remoteDinnerID })?.start == dinner.start.addingTimeInterval(3600),
                   "rescheduled trip linkage stays stable through repeated backup merge")

        var ordinaryBackup = Snapshot(), ordinaryCurrent = Snapshot()
        let ordinary = PlanEvent(title: "周期日程第一天", start: instant, end: instant.addingTimeInterval(3600), eventID: "recurring-calendar-id")
        ordinaryBackup.events = [ordinary]
        let otherOccurrence = PlanEvent(title: "周期日程第二天", start: instant.addingTimeInterval(86400), end: instant.addingTimeInterval(90000), eventID: "recurring-calendar-id")
        ordinaryCurrent.events = [otherOccurrence]
        let separateOccurrences = try BackupCodec.merge(ordinaryBackup, into: ordinaryCurrent)
        try expect(separateOccurrences.events.count == 2 && Set(separateOccurrences.events.map(\.id)) == Set([ordinary.id, otherOccurrence.id]),
                   "ordinary events sharing a recurring identifier keep distinct occurrence times")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Daylight-planner-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = RecordRepository(url: directory.appendingPathComponent("records.json"))
        try repository.save(source)
        let originalBytes = try Data(contentsOf: repository.url)
        var duplicateTrip = source; duplicateTrip.plannedTrips.append(trip)
        var duplicateEventIDs = source
        var otherTrip = trip; otherTrip.id = UUID()
        duplicateEventIDs.plannedTrips.append(otherTrip)
        var invalidTrip = source; invalidTrip.plannedTrips[0].route.durationSeconds = 0
        try expect([duplicateTrip, duplicateEventIDs, invalidTrip].allSatisfy { invalid in rejects { try repository.save(invalid) } }
                   && (try Data(contentsOf: repository.url)) == originalBytes,
                   "invalid trip and duplicate identifiers fail before overwriting saved data")
        var invalidPreferences = source; invalidPreferences.plannerPreferences.bufferMinutes = 121
        try expect(rejects { try repository.save(invalidPreferences) } && (try Data(contentsOf: repository.url)) == originalBytes,
                   "invalid preferences leave original file unchanged")
        let loaded = try repository.load()
        try expect(loaded.plannedTrips[0].eventIDs == trip.eventIDs && loaded.transactions[0].id == smsID
                   && loaded.plannerPreferences == source.plannerPreferences,
                   "valid repository remains readable after rejected updates")
        return checks
    }
}
