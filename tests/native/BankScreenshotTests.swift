import Foundation

enum BankScreenshotTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            guard condition else { throw AppFailure.message("FAIL: \(label)") }
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try expect(rejected, label)
        }
        let instant = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!
        func card(amount: String = "8.00", balance: String = "501.23", tail: String = "1234", stamp: String = "2026年10月3日18:11", direction: String = "出账", detail: String = "缴费财付通-示例交通") -> String {
            """
            中国工商银行客户服务
            动账交易提醒
            账号类型： 尾号 \(tail) 的借记卡
            交易时间： \(stamp)
            交易类型： \(detail)
            交易金额： \(direction) \(amount) 人民币元
            账户余额： \(balance) 人民币元。点此查明细详情
            查看详情
            """
        }
        let first = try BankScreenshotCore.parse(text: card(), receivedAt: instant)
        try expect(first.messages.count == 1 && first.incompleteCardCount == 0, "complete labelled ICBC card parses")
        let message = first.messages[0], draft = message.draft!
        try expect(draft.cents == 800 && draft.bankBalanceAfterCents == 50_123, "small debit amount and balance remain separate")
        try expect(draft.date == ISO8601DateFormatter().date(from: "2026-10-03T10:11:00Z"), "explicit OCR timestamp uses UTC+8")
        try expect(message.origin == .wechatScreenshot && draft.externalID?.hasPrefix("wechat:") == true, "screenshot origin is preserved")
        try expect(draft.bankAccountTail == "1234" && !message.body.contains("1234") && !message.body.contains("501.23"), "saved body redacts card and balance")
        try expect(draft.bankDirection == .debit && draft.kind == .expense && message.warnings.isEmpty, "complete debit is review-ready")
        let cent = try BankScreenshotCore.parse(text: card(amount: "0.01"), receivedAt: instant)
        try expect(cent.messages.first?.draft?.cents == 1, "one-cent screenshot has no ten-yuan minimum")
        let ordinaryDebit = try BankSMS.parse(body: "尾号1234卡10月3日14:08支出(消费财付通-示例运动公司)34.50元，余额456.78元。【工商银行】", sender: "95588", requestID: UUID().uuidString, receivedAt: instant)
        try expect(ordinaryDebit?.draft?.cents == 3_450 && ordinaryDebit?.draft?.bankBalanceAfterCents == 45_678, "34.50-yuan ICBC debit shape is recognized without confusing balance")
        let spaced = card().replacingOccurrences(of: "8.00", with: "8").replacingOccurrences(of: "2026年10月3日", with: "2026年10月03日")
        let same = try BankScreenshotCore.parse(text: spaced, receivedAt: instant).messages[0]
        try expect(same.fingerprint == message.fingerprint, "canonical receipt key ignores spacing and equivalent date-money formatting")
        let secondText = card(amount: "6.00", balance: "495.23", stamp: "2026年10月3日18:14", detail: "消费财付通-示例餐饮")
        let batch = try BankScreenshotCore.parse(text: "服务号通知\n" + card() + "\n" + secondText, receivedAt: instant)
        try expect(batch.messages.count == 2 && batch.messages[1].draft?.cents == 600 && batch.messages[1].draft?.bankBalanceAfterCents == 49_523, "several cards parse independently")
        let cropped = card().components(separatedBy: "账户余额").first!
        let partial = try BankScreenshotCore.parse(text: card() + cropped, receivedAt: instant)
        try expect(partial.messages.count == 1 && partial.incompleteCardCount == 1 && !partial.notices.isEmpty, "partial card cannot borrow previous balance")
        for malformed in ["8.OO", "8,00", "8.001", "-8.00", "0", "1000000000.01"] {
            let result = try BankScreenshotCore.parse(text: card(amount: malformed), receivedAt: instant)
            try expect(result.messages.isEmpty && result.incompleteCardCount == 1, "ambiguous screenshot amount \(malformed) is rejected")
        }
        for malformed in ["5O1.23", "50,1.23", "501.234", "1000000000.01"] {
            let result = try BankScreenshotCore.parse(text: card(balance: malformed), receivedAt: instant)
            try expect(result.messages.isEmpty, "ambiguous screenshot balance \(malformed) is rejected")
        }
        let grouped = try BankScreenshotCore.parse(text: card(amount: "1,234.56", balance: "-9,876.54"), receivedAt: instant)
        try expect(grouped.messages.first?.draft?.cents == 123_456 && grouped.messages.first?.draft?.bankBalanceAfterCents == -987_654, "strict thousands grouping and negative balance accepted")
        let fullWidth = card().replacingOccurrences(of: "8.00", with: "８．００")
        try expect(try BankScreenshotCore.parse(text: fullWidth, receivedAt: instant).messages.first?.draft?.cents == 800, "compatibility-width digits normalize without OCR guessing")
        let invalidDate = try BankScreenshotCore.parse(text: card(stamp: "2026年2月30日18:11"), receivedAt: instant)
        try expect(invalidDate.messages.isEmpty, "invalid screenshot calendar date is rejected")
        let noYear = try BankScreenshotCore.parse(text: card(stamp: "10月3日18:11"), receivedAt: instant)
        try expect(noYear.messages.isEmpty, "screenshot time requires explicit year")
        let duplicateField = try BankScreenshotCore.parse(text: card() + "交易金额：出账1.00人民币元", receivedAt: instant)
        try expect(duplicateField.messages.isEmpty, "duplicate amount field is ambiguous")
        let noHeader = try BankScreenshotCore.parse(text: card().replacingOccurrences(of: "中国工商银行客户服务", with: "其他银行客户服务"), receivedAt: instant)
        try expect(noHeader.messages.isEmpty && !noHeader.notices.isEmpty, "bank header is required")
        let masked = try BankScreenshotCore.parse(text: card(tail: "XXXX"), receivedAt: instant).messages[0]
        try expect(masked.draft?.bankAccountTail == nil && !masked.warnings.isEmpty, "masked card requires review")
        let refund = try BankScreenshotCore.parse(text: card(direction: "入账", detail: "消费退款-示例商户"), receivedAt: instant).messages[0]
        try expect(refund.draft?.kind == .refund && refund.draft?.bankDirection == .credit, "credit refund classification")
        let recharge = try BankScreenshotCore.parse(text: card(detail: "充值财付通-微信零钱充值账户"), receivedAt: instant).messages[0]
        try expect(recharge.draft?.kind == .transfer && recharge.draft?.bankDirection == .debit, "wallet recharge remains a transfer")
        let income = try BankScreenshotCore.parse(text: card(direction: "入账", detail: "汇款-示例转入"), receivedAt: instant).messages[0]
        try expect(income.draft?.kind == .income && !income.warnings.isEmpty, "ambiguous incoming funds require classification review")
        try rejects("OCR text cap") { _ = try BankScreenshotCore.parse(text: String(repeating: "字", count: 50_001), receivedAt: instant) }
        try rejects("OCR card cap") { _ = try BankScreenshotCore.parse(text: String(repeating: card(), count: 101), receivedAt: instant) }

        let saved = try BankScreenshotCore.confirm(messages: batch.messages, into: Snapshot())
        try expect(saved.count == 2 && saved.snapshot.transactions.count == 2 && saved.snapshot.smsInbox.allSatisfy { $0.status == .recorded }, "batch confirmation saves reviewed receipts together")
        let retry = try BankScreenshotCore.confirm(messages: batch.messages, into: saved.snapshot)
        try expect(retry.count == 0 && retry.skippedCount == 2 && retry.snapshot.transactions.count == 2, "repeated screenshots are idempotent")
        let repeatedInBatch = try BankScreenshotCore.confirm(messages: [message, same], into: Snapshot())
        try expect(repeatedInBatch.count == 1 && repeatedInBatch.skippedCount == 1, "overlapping images deduplicate within one confirmation")
        var oldSMS = Snapshot()
        let smsBody = "尾号1234卡2026年10月3日18:11支出(缴费财付通-示例交通)8元，余额501.23元。【工商银行】"
        var sms = try BankSMS.parse(body: smsBody, sender: "95588", requestID: UUID().uuidString, receivedAt: instant)!
        sms.status = .recorded
        oldSMS.smsInbox = [sms]; oldSMS.transactions = [sms.draft!]
        try expect(BankScreenshotCore.duplicate(for: message, in: oldSMS).level == .exact, "complete SMS and WeChat evidence identifies same payment")
        try expect(BankScreenshotCore.duplicate(for: sms, in: saved.snapshot).level == .exact, "cross-source matching works when screenshot arrives first")
        let manuallySavedSMS = try BankScreenshotCore.confirm(messages: [sms], into: Snapshot())
        try expect(manuallySavedSMS.count == 1 && manuallySavedSMS.snapshot.transactions[0].externalID?.hasPrefix("sms:") == true, "manual SMS confirmation preserves its receipt origin")
        let encoded = try JSONEncoder().encode(saved.snapshot)
        let restored = try JSONDecoder().decode(Snapshot.self, from: encoded)
        try expect(restored.smsInbox[0].origin == .wechatScreenshot && restored.transactions[0].bankAccountTail == "1234", "backup retains screenshot origin and account tail")
        oldSMS.transactions[0].bankAccountTail = nil; oldSMS.smsInbox[0].draft?.bankAccountTail = nil
        try expect(BankScreenshotCore.duplicate(for: message, in: oldSMS).level == .possible, "legacy SMS without tail is only a possible duplicate")
        try rejects("possible duplicate requires explicit approval") { _ = try BankScreenshotCore.confirm(messages: [message], into: oldSMS) }
        let allowed = try BankScreenshotCore.confirm(messages: [message], into: oldSMS, allowPossibleDuplicate: [message.id])
        try expect(allowed.count == 1 && allowed.snapshot.transactions.count == 2, "user may explicitly confirm a separate same-minute payment")
        let differentBalance = try BankScreenshotCore.parse(text: card(balance: "493.23"), receivedAt: instant).messages[0]
        try expect(BankScreenshotCore.duplicate(for: differentBalance, in: saved.snapshot).level == .none, "same-minute same-amount payments with different balances are distinct")
        let differentTail = try BankScreenshotCore.parse(text: card(tail: "5678"), receivedAt: instant).messages[0]
        try expect(BankScreenshotCore.duplicate(for: differentTail, in: saved.snapshot).level == .none, "different known card tails are not duplicates")
        try rejects("mixed cards cannot share balance") { _ = try BankScreenshotCore.confirm(messages: [message, differentTail], into: Snapshot()) }
        try rejects("other card cannot affect existing card balance") { _ = try BankScreenshotCore.confirm(messages: [differentTail], into: saved.snapshot) }
        var excluded = differentTail; excluded.draft?.bankDirection = .excluded
        try expect(try BankScreenshotCore.confirm(messages: [excluded], into: saved.snapshot).count == 1, "excluded other-card record does not change single-card balance")
        var ignored = message; ignored.status = .ignored
        var ignoredSnapshot = Snapshot(); ignoredSnapshot.smsInbox = [ignored]
        try expect(BankScreenshotCore.duplicate(for: same, in: ignoredSnapshot).level == .possible, "ignored receipt can be reconsidered with explicit approval")
        var pendingSnapshot = Snapshot(); pendingSnapshot.smsInbox = [message]
        try expect(BankScreenshotCore.duplicate(for: same, in: pendingSnapshot).reason.contains("待确认"), "exact pending receipt is described as awaiting review")
        var invalid = message; invalid.draft?.cents = 0
        try rejects("confirmation validates all financial records before persistence") { _ = try BankScreenshotCore.confirm(messages: [invalid], into: Snapshot()) }
        return checks
    }
}
