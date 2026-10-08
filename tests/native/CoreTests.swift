import Foundation

@main
struct CoreTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) throws {
        checks += 1
        guard condition else { throw AppFailure.message("FAIL: \(label)") }
    }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try expect(rejected, label)
    }
    static func main() async throws {
        let instant = ISO8601DateFormatter().date(from: "2026-10-01T15:00:00Z")!
        let sample = "尾号1234卡10月1日22:45支出(充值财付通-微信零钱充值账户)200元，余额111.11元。【工商银行】"
        for identifier in [nil, "", " \n "] as [String?] {
            let receipt = try SMSInboxPolicy.accept(body: sample, sender: "95588", requestID: identifier, receivedAt: instant, into: Snapshot())
            try expect(receipt.snapshot.smsInbox.count == 1 && UUID(uuidString: receipt.snapshot.smsInbox[0].requestID) != nil, "blank shortcut identifier generates UUID")
        }
        let spaced = try SMSInboxPolicy.accept(body: sample, sender: "95588", requestID: "  20261001230000099\n", receivedAt: instant, into: Snapshot()).snapshot
        let spacedRetry = try SMSInboxPolicy.accept(body: sample, sender: "95588", requestID: "20261001230000099", receivedAt: instant, into: spaced).snapshot
        try expect(spacedRetry.smsInbox.count == 1, "trimmed shortcut identifier preserves retry deduplication")
        try rejects("reused shortcut identifier cannot silently discard a different payment") {
            _ = try SMSInboxPolicy.accept(body: sample.replacingOccurrences(of: "200元", with: "201元"), sender: "95588", requestID: "20261001230000099", receivedAt: instant, into: spaced)
        }
        try rejects("short identifier still rejected at shortcut boundary") { _ = try SMSInboxPolicy.accept(body: sample, sender: "95588", requestID: "123", receivedAt: instant, into: Snapshot()) }
        let failure = AppFailure.message("短信编号格式错误") as NSError
        try expect(failure.localizedDescription == "短信编号格式错误", "bridged errors preserve readable reason")
        do {
            _ = try SMSInboxPolicy.accept(body: " \n ", sender: "95588", requestID: nil, into: Snapshot())
            throw AppFailure.message("FAIL: empty shortcut body was accepted")
        } catch {
            try expect((error as NSError).localizedDescription.contains("没有收到短信正文"), "empty shortcut input reports actionable reason")
        }
        let parsed = try BankSMS.parse(body: sample, sender: "95588", requestID: "20261001230000001", receivedAt: instant)!
        try expect(parsed.draft?.cents == 20_000, "use transaction amount, never balance")
        try expect(parsed.draft?.kind == .transfer, "wallet recharge is transfer")
        try expect(parsed.warnings.isEmpty, "valid transaction within three days")
        try expect(!parsed.body.contains("1234") && !parsed.body.contains("111.11"), "redact card and balance")
        try expect(parsed.draft?.date == ISO8601DateFormatter().date(from: "2026-10-01T14:45:00Z"), "bank timestamp uses UTC+8")
        try expect(parsed.draft?.id == parsed.id, "SMS and transaction use same ID")
        try expect(try MoneyMath.parse("0.01") == 1, "exact cents")
        try expect(try MoneyMath.parse("1000000000.00") == 100_000_000_000, "maximum amount")
        for amount in ["0", "-1", "12.345", "1e3", "1,000", "1000000000.01", "nan", ""] {
            try rejects("invalid amount \(amount)") { _ = try MoneyMath.parse(amount) }
        }
        let expense = "尾号1234卡10月1日22:45支出(超市消费)12.34元，余额999.99元。【工商银行】"
        let exp = try BankSMS.parse(body: expense, sender: "95588", requestID: "20261001230000002", receivedAt: instant)!
        try expect(exp.draft?.kind == .expense && exp.draft?.cents == 1_234, "direct card expense")
        for malformed in ["12.345", "-12.34", "0", "1,23", "999999999999999"] {
            let value = try BankSMS.parse(body: expense.replacingOccurrences(of: "12.34元", with: malformed + "元"), sender: "95588", requestID: "20261001230000003", receivedAt: instant)!
            try expect(value.draft == nil, "malformed SMS money \(malformed)")
        }
        let two = try BankSMS.parse(body: expense + "支出2元", sender: "95588", requestID: "20261001230000004", receivedAt: instant)!
        try expect(two.draft == nil, "multiple transaction amounts wait for review")
        try expect(try BankSMS.parse(body: expense, sender: "10086", requestID: "20261001230000005", receivedAt: instant) == nil, "wrong sender ignored")
        try expect(try BankSMS.parse(body: expense + "验证码123456", sender: "95588", requestID: "20261001230000006", receivedAt: instant) == nil, "OTP ignored without storage")
        try rejects("invalid request ID") { _ = try BankSMS.parse(body: expense, sender: "95588", requestID: "123") }
        let income = try BankSMS.parse(body: expense.replacingOccurrences(of: "支出(超市消费)", with: "收入(汇款)"), sender: "95588", requestID: "20261001230000007", receivedAt: instant)!
        try expect(income.draft?.kind == .income && !income.warnings.isEmpty, "ambiguous income needs review")
        let refund = try BankSMS.parse(body: expense.replacingOccurrences(of: "支出", with: "退款"), sender: "95588", requestID: "20261001230000008", receivedAt: instant)!
        try expect(refund.draft?.kind == .refund, "refund classified separately")
        let invalidDate = try BankSMS.parse(body: expense.replacingOccurrences(of: "10月1日", with: "2月30日"), sender: "95588", requestID: "20261001230000009", receivedAt: instant)!
        try expect(invalidDate.draft == nil, "calendar invalid date rejected")
        let missingDate = try BankSMS.parse(body: "支出12.34元【工商银行】", sender: "95588", requestID: "20261001230000010", receivedAt: instant)!
        try expect(missingDate.draft?.date == instant && !missingDate.warnings.isEmpty, "missing date uses receipt with warning")
        let newYear = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
        let rollover = try BankSMS.parse(body: expense.replacingOccurrences(of: "10月1日", with: "12月31日"), sender: "95588", requestID: "20261001230000011", receivedAt: newYear)!
        try expect(rollover.draft?.date == ISO8601DateFormatter().date(from: "2026-12-31T14:45:00Z"), "closest year on New Year")

        var empty = Snapshot()
        let pending = try SMSInboxPolicy.accept(body: sample, sender: "95588", requestID: "20261001230000012", receivedAt: instant, into: empty).snapshot
        try expect(pending.smsInbox.count == 1 && pending.transactions.isEmpty, "default review only")
        empty.autoRecordSMS = true
        let saved = try SMSInboxPolicy.accept(body: expense, sender: "95588", requestID: "20261001230000013", receivedAt: instant, into: empty).snapshot
        try expect(saved.transactions.count == 1 && saved.smsInbox[0].status == .recorded, "clear expense auto saves")
        let otherCard = try SMSInboxPolicy.accept(body: expense.replacingOccurrences(of: "尾号1234卡", with: "尾号5678卡"), sender: "95588", requestID: nil, receivedAt: instant, into: saved).snapshot
        try expect(otherCard.transactions.count == 1 && otherCard.smsInbox.last?.status == .pending && otherCard.smsInbox.last?.warnings.isEmpty == false, "a different known bank card cannot auto-change the common balance")
        let retried = try SMSInboxPolicy.accept(body: expense, sender: "95588", requestID: "20261001230000013", receivedAt: instant, into: saved).snapshot
        try expect(retried.smsInbox.count == 1 && retried.transactions.count == 1, "same request retry idempotent")
        let duplicate = try SMSInboxPolicy.accept(body: expense, sender: "95588", requestID: "20261001230000014", receivedAt: instant, into: saved).snapshot
        try expect(duplicate.transactions.count == 1 && duplicate.smsInbox.last?.possibleDuplicate == true && duplicate.smsInbox.last?.status == .pending, "same body new ID needs review")
        for text in [income.body, refund.body, missingDate.body] {
            let value = try SMSInboxPolicy.accept(body: text, sender: "95588", requestID: UUID().uuidString, receivedAt: instant, into: empty).snapshot
            try expect(value.transactions.isEmpty && value.smsInbox.count == 1, "uncertain transaction never auto saves")
        }
        let autoTransfer = try SMSInboxPolicy.accept(body: sample, sender: "95588", requestID: "20261001230000015", receivedAt: instant, into: empty).snapshot
        try expect(autoTransfer.transactions.first?.kind == .transfer, "clear recharge auto saves as transfer")
        try expect(MoneyMath.netExpense(autoTransfer.transactions) == 0, "recharge does not increase expense")
        try expect(MoneyMath.netExpense([exp.draft!, refund.draft!]) == 0, "refund offsets expense")

        let v1 = Data(#"{"version":1,"transactions":[],"tasks":[],"events":[],"weights":[],"workouts":[]}"#.utf8)
        let migrated = try JSONDecoder().decode(Snapshot.self, from: v1)
        try expect(migrated.version == 4 && migrated.smsInbox.isEmpty && !migrated.autoRecordSMS && migrated.bankBalanceBaseline == nil && migrated.plannedTrips.isEmpty, "v1 migration")
        try rejects("corrupt record file not treated as empty") { _ = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"version":1}"#.utf8)) }
        let backup = try BackupCodec.export(saved)
        let recovered = try BackupCodec.decode(backup)
        let merged = try BackupCodec.merge(recovered, into: saved)
        try expect(merged.transactions.count == 1 && merged.smsInbox.count == 1, "backup merge idempotent")
        let firstMerge = try BackupCodec.merge(recovered, into: Snapshot())
        try expect(!firstMerge.autoRecordSMS && firstMerge.transactions.count == 1, "import preserves current auto-record preference")
        let uuid = "6C55EA96-F066-464D-A677-A20EB1C63FAA"
        let archive = Data("""
        {"version":1,"autoRecord":false,"transactions":[{"id":"\(uuid)","date":"2026-10-01T22:45:00","kind":"transfer","cents":20000,"title":"充值","category":"账户转移","source":"工行储蓄卡"}],"inbox":[{"id":"\(uuid)","requestId":"20261001230000016","fingerprint":"example","receivedAt":"2026-10-01T15:00:00.000Z","body":"尾号1234卡余额111.11元","draft":null,"status":"recorded"}]}
        """.utf8)
        let bank = try BackupCodec.decode(archive)
        try expect(bank.transactions.first?.date == parsed.draft?.date, "computer archive local date timezone")
        try expect(bank.transactions.first?.id == bank.smsInbox.first?.id && bank.transactions.first?.externalID == "sms:\(uuid)", "computer archive retains links")
        try expect(bank.smsInbox.first?.body.contains("111.11") == false, "import also redacts")
        var invalid = saved; invalid.transactions[0].cents = -1
        try rejects("backup invalid cents rejected") { _ = try BackupCodec.export(invalid) }
        var duplicateIDs = saved; duplicateIDs.transactions.append(saved.transactions[0])
        try rejects("duplicate IDs rejected") { try SnapshotChecks.validate(duplicateIDs) }
        var invalidDraft = pending; invalidDraft.smsInbox[0].draft?.cents = -1
        try rejects("invalid draft rejected") { try SnapshotChecks.validate(invalidDraft) }
        var endurance = Snapshot()
        endurance.workouts = [ExerciseRecord(date: instant, title: "超长运动", minutes: 1_560, source: "苹果健康", healthID: UUID().uuidString)]
        try SnapshotChecks.validate(endurance)
        try expect(endurance.workouts.count == 1, "HealthKit workouts can exceed one day")
        endurance.workouts[0].healthID = nil
        try rejects("manual exercise keeps one-day input limit") { try SnapshotChecks.validate(endurance) }

        try expect(try MoneyMath.parseBalance("0.00") == 0, "zero balance allowed")
        try expect(try MoneyMath.parseBalance("-0.01") == -1, "negative balance exact cents")
        try rejects("invalid balance precision") { _ = try MoneyMath.parseBalance("1.234") }
        try expect(parsed.bankBalanceAfterCents == 11_111 && parsed.draft?.bankBalanceAfterCents == 11_111, "bank balance parsed separately from transaction")
        try expect(parsed.draft?.bankDirection == .debit, "wallet recharge debits bank")
        let inbound = try BankSMS.parse(body: sample.replacingOccurrences(of: "支出", with: "收入"), sender: "95588", requestID: UUID().uuidString, receivedAt: instant)!
        try expect(inbound.draft?.kind == .transfer && inbound.draft?.bankDirection == .credit, "inbound account transfer credits bank")
        let zeroSMS = try BankSMS.parse(body: sample.replacingOccurrences(of: "111.11元", with: "0.00元"), sender: "95588", requestID: UUID().uuidString, receivedAt: instant)!
        try expect(zeroSMS.bankBalanceAfterCents == 0, "zero SMS balance is retained")
        for invalidBalance in ["1,23", "12.345", "1000000000.01"] {
            let invalidSMS = try BankSMS.parse(body: sample.replacingOccurrences(of: "111.11元", with: invalidBalance + "元"), sender: "95588", requestID: UUID().uuidString, receivedAt: instant)!
            try expect(invalidSMS.bankBalanceAfterCents == nil && invalidSMS.draft?.cents == 20_000, "bad balance does not replace transaction \(invalidBalance)")
        }
        try expect(BankBalanceMath.reading(Snapshot()) == nil, "no invented starting balance")
        try expect(BankBalanceMath.reading(pending) == nil, "pending SMS does not affect balance")
        try expect(BankBalanceMath.reading(autoTransfer)?.cents == 11_111, "reported balance not debited twice")
        var ledger = Snapshot(); ledger.bankBalanceBaseline = BankBalanceBaseline(cents: 100_000, date: instant)
        let debit = MoneyRecord(date: instant.addingTimeInterval(60), kind: .expense, cents: 1_234, title: "消费", category: "餐饮", source: "工行储蓄卡")
        let credit = MoneyRecord(date: instant.addingTimeInterval(120), kind: .income, cents: 2_000, title: "收入", category: "工资", source: "工行储蓄卡")
        let returned = MoneyRecord(date: instant.addingTimeInterval(180), kind: .refund, cents: 234, title: "退款", category: "餐饮", source: "工行储蓄卡")
        let outgoing = MoneyRecord(date: instant.addingTimeInterval(240), kind: .transfer, cents: 1_000, title: "充值", category: "账户转移", source: "工行储蓄卡")
        let wallet = MoneyRecord(date: instant.addingTimeInterval(300), kind: .expense, cents: 999, title: "零钱支付", category: "其他", source: "微信")
        ledger.transactions = [debit, credit, returned, outgoing, wallet]
        try expect(BankBalanceMath.reading(ledger)?.cents == 100_000, "bank inflow outflow refund transfer and other wallet accounting")
        var directWeChat = wallet; directWeChat.bankDirection = .debit; ledger.transactions.append(directWeChat)
        // Use a distinct ID for the additional direct-card payment.
        ledger.transactions[ledger.transactions.count - 1].id = UUID()
        try expect(BankBalanceMath.reading(ledger)?.cents == 99_001, "explicit direct card payment via WeChat counts")
        ledger.transactions.removeLast()
        ledger.transactions.removeAll { $0.id == debit.id }
        try expect(BankBalanceMath.reading(ledger)?.cents == 101_234, "deleting expense recalculates balance")
        var point = debit; point.bankBalanceAfterCents = 88_000; point.bankBalanceReportedAt = instant.addingTimeInterval(61)
        ledger.transactions = [point, credit]
        try expect(BankBalanceMath.reading(ledger)?.cents == 90_000, "new checkpoint corrects baseline and later income applies once")
        var older = outgoing; older.id = UUID(); older.date = instant.addingTimeInterval(-60); older.bankBalanceAfterCents = 500_000; older.bankBalanceReportedAt = instant.addingTimeInterval(900)
        ledger.transactions.append(older)
        try expect(BankBalanceMath.reading(ledger)?.cents == 90_000, "late old SMS cannot override newer balance")
        var sameMinute = point; sameMinute.id = UUID(); sameMinute.bankBalanceAfterCents = 87_000; sameMinute.bankBalanceReportedAt = instant.addingTimeInterval(62)
        ledger.transactions.append(sameMinute)
        try expect(BankBalanceMath.reading(ledger)?.cents == 89_000, "same-minute checkpoints ordered by receipt time")
        ledger.bankBalanceBaseline = BankBalanceBaseline(cents: 123_456, date: instant.addingTimeInterval(180))
        try expect(BankBalanceMath.reading(ledger)?.cents == 123_456, "new manual balance includes older transactions")
        let balanceBackup = try BackupCodec.decode(BackupCodec.export(ledger))
        try expect(BankBalanceMath.reading(balanceBackup)?.cents == 123_456 && balanceBackup.transactions[0].bankBalanceAfterCents == 88_000, "balance metadata backup round trip")
        let emptyRestore = try BackupCodec.merge(balanceBackup, into: Snapshot())
        try expect(emptyRestore.bankBalanceBaseline?.cents == 123_456, "restore balance into new ledger")
        var currentBalance = Snapshot(); currentBalance.bankBalanceBaseline = BankBalanceBaseline(cents: 777, date: instant.addingTimeInterval(999))
        try expect(try BackupCodec.merge(balanceBackup, into: currentBalance).bankBalanceBaseline?.cents == 777, "import does not overwrite current manually set balance")
        var badBalance = ledger; badBalance.bankBalanceBaseline?.cents = Int.max
        try rejects("invalid baseline rejected") { try SnapshotChecks.validate(badBalance) }
        badBalance = ledger; badBalance.transactions[0].bankBalanceAfterCents = Int.min
        try rejects("invalid SMS balance rejected without overflow") { try SnapshotChecks.validate(badBalance) }
        let oldRecord = try JSONDecoder().decode(MoneyRecord.self, from: Data(#"{"id":"6C55EA96-F066-464D-A677-A20EB1C63FAA","date":0,"kind":"expense","cents":100,"title":"旧记录","category":"其他","source":"工行储蓄卡"}"#.utf8))
        try expect(oldRecord.bankDirection == nil && BankBalanceMath.delta(oldRecord) == -100, "old records migrate without losing bank outflow")

        var minuteLedger = Snapshot(); minuteLedger.bankBalanceBaseline = BankBalanceBaseline(cents: 100_000, date: instant.addingTimeInterval(30))
        var minuteSMS = debit; minuteSMS.date = instant; minuteSMS.bankBalanceAfterCents = 90_000; minuteSMS.bankBalanceReportedAt = instant.addingTimeInterval(40); minuteSMS.bankTimeIsMinuteOnly = true
        minuteLedger.transactions = [minuteSMS]
        try expect(BankBalanceMath.reading(minuteLedger)?.cents == 90_000, "new SMS within baseline minute updates balance")
        minuteLedger.transactions[0].bankBalanceReportedAt = instant.addingTimeInterval(20)
        try expect(BankBalanceMath.reading(minuteLedger)?.cents == 100_000, "manual correction after same-minute SMS remains authoritative")
        minuteLedger.transactions[0].date = instant.addingTimeInterval(-60); minuteLedger.transactions[0].bankBalanceReportedAt = instant.addingTimeInterval(500)
        try expect(BankBalanceMath.reading(minuteLedger)?.cents == 100_000, "delayed minute-only SMS never moves into later minute")
        minuteLedger.bankBalanceBaseline = nil; minuteLedger.transactions = [minuteSMS]
        var afterSMS = debit; afterSMS.date = instant.addingTimeInterval(50); minuteLedger.transactions.append(afterSMS)
        try expect(BankBalanceMath.reading(minuteLedger)?.cents == 88_766, "manual debit after same-minute checkpoint is counted")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Daylight-core-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = RecordRepository(url: directory.appendingPathComponent("records.json"))
        try expect(try repository.load().transactions.isEmpty, "first launch empty")
        try repository.save(saved)
        let before = try Data(contentsOf: repository.url)
        try rejects("failed validation preserves stored data") { try repository.save(invalid) }
        try expect(try Data(contentsOf: repository.url) == before, "failed save did not replace file")
        try expect(try repository.load().transactions.count == 1, "saved records reload")
        let corrupt = Data("broken-json".utf8); try corrupt.write(to: repository.url)
        try rejects("corrupt file load fails") { _ = try repository.load() }
        try expect(try Data(contentsOf: repository.url) == corrupt, "corrupt original preserved")
        checks += try SMSDiagnosticsTests.run()
        checks += try BankNotificationTests.run()
        checks += try ScheduleTests.run()
        checks += try BankScreenshotTests.run()
        checks += try BankBalanceOrderTests.run()
        checks += try await BankScreenshotOCRTests.run()
        checks += try PlannerCoreTests.run()
        checks += try PlannerIntegrationTests.run()
        checks += try await PlannerNetworkTests.run()
        checks += try await CareerTests.run()
        checks += try await CareerModelTests.run()
        print("PASS: \(checks) native core checks")
    }
}
