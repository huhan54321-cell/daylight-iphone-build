import Foundation

enum BankBalanceOrderTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            guard condition else { throw AppFailure.message("FAIL: \(label)") }
        }
        let minute = ISO8601DateFormatter().date(from: "2026-10-03T10:11:00Z")!
        let imported = minute.addingTimeInterval(3_600)
        func record(cents: Int, balance: Int?, date: Date = minute, screenshot: Bool = true, minuteOnly: Bool = true, credit: Bool = false) -> MoneyRecord {
            MoneyRecord(date: date, kind: credit ? .income : .expense, cents: cents, title: "示例交易", category: "待分类", source: "工行储蓄卡", externalID: "\(screenshot ? "wechat" : "sms"):\(UUID().uuidString)", bankDirection: credit ? .credit : .debit, bankBalanceAfterCents: balance, bankBalanceReportedAt: imported, bankTimeIsMinuteOnly: minuteOnly, bankAccountTail: "1234")
        }
        let debitA = record(cents: 800, balance: 99_200)
        let debitB = record(cents: 600, balance: 98_600)
        var snapshot = Snapshot()
        snapshot.transactions = [debitA, debitB]
        snapshot.bankBalanceBaseline = BankBalanceBaseline(cents: 100_000, date: minute.addingTimeInterval(-60))
        let estimate = BankBalanceMath.reading(snapshot)
        try expect(estimate?.cents == 98_600 && estimate?.estimated == true && estimate?.fromSMS == false, "ambiguous screenshot minute uses earlier baseline and both debits")
        try expect(BankBalanceMath.hasUnresolvedScreenshotOrder(snapshot), "ambiguous latest minute is exposed for balance calibration UI")
        var reversed = snapshot; reversed.transactions.reverse()
        try expect(BankBalanceMath.reading(reversed)?.cents == estimate?.cents, "screenshot array order cannot choose the balance endpoint")
        var changedImport = snapshot
        changedImport.transactions[0].bankBalanceReportedAt = imported.addingTimeInterval(500)
        changedImport.transactions[1].bankBalanceReportedAt = imported.addingTimeInterval(-500)
        try expect(BankBalanceMath.reading(changedImport)?.cents == 98_600, "different screenshot import times cannot choose transaction order")
        try expect(snapshot.transactions[0].bankBalanceAfterCents == 99_200 && snapshot.transactions[1].bankBalanceAfterCents == 98_600, "reported balances remain intact for receipt matching and review")
        var noBasis = snapshot; noBasis.bankBalanceBaseline = nil
        try expect(BankBalanceMath.reading(noBasis) == nil && BankBalanceMath.hasUnresolvedScreenshotOrder(noBasis), "ambiguous minute without a reliable basis requires manual calibration")
        var priorCheckpoint = noBasis
        priorCheckpoint.transactions.append(record(cents: 2_000, balance: 100_000, date: minute.addingTimeInterval(-120), screenshot: false))
        try expect(BankBalanceMath.reading(priorCheckpoint)?.cents == 98_600 && BankBalanceMath.reading(priorCheckpoint)?.estimated == true, "an older unambiguous bank balance supports estimation")
        var laterCheckpoint = snapshot
        laterCheckpoint.transactions.append(record(cents: 800, balance: 97_800, date: minute.addingTimeInterval(60), screenshot: false))
        try expect(BankBalanceMath.reading(laterCheckpoint)?.cents == 97_800 && BankBalanceMath.reading(laterCheckpoint)?.estimated == false && !BankBalanceMath.hasUnresolvedScreenshotOrder(laterCheckpoint), "a later clear balance supersedes ambiguous transaction order")
        var laterBaseline = snapshot
        laterBaseline.bankBalanceBaseline = BankBalanceBaseline(cents: 98_599, date: minute.addingTimeInterval(120))
        try expect(BankBalanceMath.reading(laterBaseline)?.cents == 98_599 && !BankBalanceMath.hasUnresolvedScreenshotOrder(laterBaseline), "a later manual calibration resolves the ambiguity")
        var insideBaseline = noBasis
        insideBaseline.bankBalanceBaseline = BankBalanceBaseline(cents: 99_000, date: minute.addingTimeInterval(30))
        try expect(BankBalanceMath.reading(insideBaseline) == nil && BankBalanceMath.hasUnresolvedScreenshotOrder(insideBaseline), "a baseline inside the unknown-order minute is not a reliable starting point")
        var insideWithOlderCheckpoint = priorCheckpoint
        insideWithOlderCheckpoint.bankBalanceBaseline = insideBaseline.bankBalanceBaseline
        try expect(BankBalanceMath.reading(insideWithOlderCheckpoint)?.cents == 98_600, "inside-minute calibration cannot replace an earlier reliable checkpoint")
        var sameBalance = snapshot
        sameBalance.transactions = [record(cents: 800, balance: 99_200), record(cents: 800, balance: 100_000, credit: true)]
        try expect(BankBalanceMath.reading(sameBalance)?.cents == 100_000 && BankBalanceMath.reading(sameBalance)?.estimated == true, "opposite directions are estimated without guessing the last payment")
        var missingBalance = snapshot
        missingBalance.transactions[1].bankBalanceAfterCents = nil
        try expect(BankBalanceMath.reading(missingBalance)?.cents == 98_600 && BankBalanceMath.hasUnresolvedScreenshotOrder(missingBalance), "another same-minute transaction without a balance still makes endpoint uncertain")
        var mixedSMS = snapshot
        mixedSMS.transactions[1].externalID = "sms:\(mixedSMS.transactions[1].id.uuidString)"
        try expect(BankBalanceMath.reading(mixedSMS)?.cents == 98_600 && BankBalanceMath.hasUnresolvedScreenshotOrder(mixedSMS), "SMS and screenshot records share the same bank-minute ambiguity")
        var excluded = snapshot
        excluded.transactions[1].bankDirection = .excluded
        try expect(BankBalanceMath.reading(excluded)?.cents == 99_200 && !BankBalanceMath.hasUnresolvedScreenshotOrder(excluded), "excluded records do not create bank balance ambiguity")
        var exactTimes = snapshot
        exactTimes.transactions[0].bankTimeIsMinuteOnly = false
        exactTimes.transactions[1].bankTimeIsMinuteOnly = false
        exactTimes.transactions[0].date = minute.addingTimeInterval(10)
        exactTimes.transactions[1].date = minute.addingTimeInterval(20)
        try expect(BankBalanceMath.reading(exactTimes)?.cents == 98_600 && !BankBalanceMath.hasUnresolvedScreenshotOrder(exactTimes), "explicit transaction seconds retain their actual ordering")
        var unchangedSMS = snapshot
        unchangedSMS.transactions[0].externalID = "sms:first"
        unchangedSMS.transactions[1].externalID = "sms:second"
        try expect(!BankBalanceMath.hasUnresolvedScreenshotOrder(unchangedSMS), "existing SMS-only ordering is unchanged by the screenshot feature")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        try expect(decoded.transactions.map(\.bankBalanceAfterCents) == [99_200, 98_600] && BankBalanceMath.reading(decoded)?.cents == 98_600, "backup preserves balance evidence and recalculates safe estimation")
        return checks
    }
}
