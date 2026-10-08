import Foundation

enum BankNotificationTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            guard condition else { throw AppFailure.message("FAIL: \(label)") }
        }
        let at = ISO8601DateFormatter().date(from: "2026-10-04T02:47:20Z")!
        let body = "尾号9999卡10月4日10:47支出(消费财付通-测试商店)5元。请点击查看详情。"
        func parse(_ value: String, title: String = "动账通知") throws -> BankMessage? {
            try BankNotification.parse(title: title, body: value, requestID: UUID().uuidString, receivedAt: at)
        }
        let message = try parse(body)!
        try expect(message.origin == .icbcNotification && message.draft?.cents == 500, "five-yuan notification without SMS footer is parsed")
        try expect(message.draft?.bankAccountTail == "9999" && message.draft?.title == "消费财付通-测试商店", "notification account and merchant are preserved")
        try expect(message.bankBalanceAfterCents == nil && message.draft?.bankBalanceAfterCents == nil, "notification without balance never invents one")
        try expect(message.draft?.date == at.addingTimeInterval(-20) && message.draft?.bankDirection == .debit, "notification date and debit direction are exact")
        try expect(message.draft?.externalID?.hasPrefix("notification:") == true && !message.body.contains("9999"), "notification origin and redaction persist")
        for amount in ["0.01", "8.00", "10", "34.50", "1,234.56"] {
            let parsed = try parse(body.replacingOccurrences(of: "5元", with: "\(amount)元"))
            let expected = try MoneyMath.parse(amount.replacingOccurrences(of: ",", with: ""))
            try expect(parsed?.draft?.cents == expected, "notification amount \(amount) has no minimum ten-yuan threshold")
        }
        let balancedBody = body.replacingOccurrences(of: "5元。", with: "5元，余额95.00元。")
        let balanced = try parse(balancedBody)!
        try expect(balanced.bankBalanceAfterCents == 9500 && balanced.draft?.cents == 500, "balance is separate from transaction amount")
        try expect(try parse(body.replacingOccurrences(of: "尾号9999卡", with: "尾号 9999 卡"))?.draft?.bankAccountTail == "9999", "spaced tail keeps the account")
        for title in ["支付好礼，欢度国庆假期", "【礼遇】欢享假日", "动账通知优惠", "", "工商银行"] {
            try expect(try parse(body, title: title) == nil, "unrelated title is rejected even with transaction-like body")
        }
        for value in [
            "绑卡支付享优惠，平台消费立减5元。",
            "【节节候新】瓜分超200万份假日礼，有机会赢百元话费！",
            body + "优惠券5元", body + body,
            body.replacingOccurrences(of: "5元", with: ""),
            body.replacingOccurrences(of: "尾号9999卡", with: "尾号卡"),
            body.replacingOccurrences(of: "10月4日10:47", with: ""),
            body.replacingOccurrences(of: "支出", with: "支出失败"),
            body.replacingOccurrences(of: "测试商店", with: "验证码")
        ] {
            try expect(try parse(value) == nil, "promotion incomplete failed or combined body is rejected")
        }
        for amount in ["0", "1.234", "1,23.45", "99999999999999"] {
            let parsed = try parse(body.replacingOccurrences(of: "5元", with: "\(amount)元"))
            try expect(parsed?.draft == nil, "invalid amount cannot become a saved expense")
        }
        let invalidDate = try parse(body.replacingOccurrences(of: "10月4日", with: "2月30日"))
        try expect(invalidDate?.draft == nil, "invalid notification date never rolls forward")
        for value in ["", String(repeating: "字", count: 4001)] {
            var rejected = false
            do { _ = try parse(value) } catch { rejected = true }
            try expect(rejected, "missing or oversized input fails visibly")
        }
        var enabled = Snapshot(); enabled.autoRecordSMS = true
        enabled.bankBalanceBaseline = BankBalanceBaseline(cents: 10000, date: at.addingTimeInterval(-120))
        let skipped = try BankNotification.accept(title: "支付好礼", body: body, requestID: nil, receivedAt: at, into: enabled)
        try expect(skipped.snapshot.transactions.isEmpty && skipped.snapshot.smsInbox.isEmpty && BankBalanceMath.reading(skipped.snapshot)?.cents == 10000, "non-transaction title cannot change inbox or balance")
        let saved = try BankNotification.accept(title: "动账通知", body: body, requestID: "notification-test-0001", receivedAt: at, into: enabled)
        try expect(saved.snapshot.transactions.count == 1 && saved.snapshot.smsInbox.first?.status == .recorded, "complete safe notification automatically records")
        try expect(BankBalanceMath.reading(saved.snapshot)?.cents == 9500 && BankBalanceMath.reading(saved.snapshot)?.estimated == true, "no-balance notification subtracts from manual baseline as estimate")
        let smsBody = body.replacingOccurrences(of: "。请点击查看详情。", with: "，余额95.00元。【工商银行】")
        let smsAfter = try SMSInboxPolicy.accept(body: smsBody, sender: "95588", requestID: nil, receivedAt: at, into: saved.snapshot)
        try expect(smsAfter.snapshot.transactions.count == 1 && smsAfter.snapshot.smsInbox.count == 1, "SMS after notification silently deduplicates without new pending receipt")
        let smsFirst = try SMSInboxPolicy.accept(body: smsBody, sender: "95588", requestID: nil, receivedAt: at, into: enabled)
        let notificationAfter = try BankNotification.accept(title: "动账通知", body: body, requestID: nil, receivedAt: at, into: smsFirst.snapshot)
        try expect(notificationAfter.snapshot.transactions.count == 1 && notificationAfter.snapshot.smsInbox.count == 1, "notification after SMS silently deduplicates without new pending receipt")
        let repeatedID = try BankNotification.accept(title: "动账通知", body: body, requestID: "notification-test-0001", receivedAt: at, into: saved.snapshot)
        try expect(repeatedID.snapshot.smsInbox.count == 1 && repeatedID.snapshot.transactions.count == 1, "retry with stable ID is idempotent")
        var collisionRejected = false
        do { _ = try BankNotification.accept(title: "动账通知", body: balancedBody, requestID: "notification-test-0001", receivedAt: at, into: saved.snapshot) } catch { collisionRejected = true }
        try expect(collisionRejected, "conflicting notification ID cannot overwrite a receipt")
        let otherCard = try BankNotification.accept(title: "动账通知", body: body.replacingOccurrences(of: "9999", with: "8888"), requestID: nil, receivedAt: at, into: saved.snapshot)
        try expect(otherCard.snapshot.transactions.count == 1 && otherCard.snapshot.smsInbox.last?.warnings.isEmpty == false, "another bank account requires review")
        let separate = try BankNotification.accept(title: "动账通知", body: body.replacingOccurrences(of: "5元", with: "8元"), requestID: nil, receivedAt: at, into: saved.snapshot)
        try expect(separate.snapshot.transactions.count == 2 && BankBalanceMath.reading(separate.snapshot)?.cents == 8700, "distinct small payment is recorded and balance subtracts exactly once")
        for verb in ["收入", "退款"] {
            let pending = try BankNotification.accept(title: "动账通知", body: body.replacingOccurrences(of: "支出", with: verb), requestID: nil, receivedAt: at, into: enabled)
            try expect(pending.snapshot.transactions.isEmpty && pending.snapshot.smsInbox.first?.draft?.bankDirection == .credit, "income refund direction parsed but review required")
        }
        let restored = try BackupCodec.decode(BackupCodec.export(saved.snapshot))
        try expect(restored.smsInbox.first?.origin == .icbcNotification && restored.transactions.first?.externalID?.hasPrefix("notification:") == true, "notification survives full backup restore")
        let suite = "Daylight-notification-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempt = SMSReceptionDiagnostics.begin(bodyLength: body.utf16.count, defaults: defaults, origin: .icbcNotification)
        SMSReceptionDiagnostics.succeed(&attempt, result: saved.result, defaults: defaults)
        try expect(SMSReceptionDiagnostics.latest(defaults: defaults)?.origin == .icbcNotification && attempt.outcome == .recorded, "diagnostic retains origin and success")
        let encoded = String(data: defaults.data(forKey: SMSReceptionDiagnostics.storageKey)!, encoding: .utf8)!
        try expect(!encoded.contains("9999") && !encoded.contains("测试商店") && !encoded.contains("支出"), "notification diagnostics never retain bank text")
        var legacy = attempt; legacy.origin = nil
        let legacyBytes = try JSONEncoder().encode(legacy)
        try expect(SMSReceptionDiagnostics.decode(legacyBytes)?.origin == nil, "older SMS diagnostic without origin still loads")
        return checks
    }
}
