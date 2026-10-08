import Foundation

enum BankNotification {
    // The system automation must select the ICBC app. These fields validate a
    // receipt's shape, not the authenticity of arbitrary text supplied by a caller.
    static func parse(title: String, body: String, requestID: String, receivedAt: Date = Date()) throws -> BankMessage? {
        let text = body.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppFailure.message("没有收到通知正文。请传入通知的正文 Body，不能只传标题或通知对象。") }
        guard text.utf16.count <= 4000 else { throw AppFailure.message("通知正文超过 4000 字，请检查输入变量") }
        guard requestID.range(of: #"^[A-Za-z0-9_-]{16,100}$"#, options: .regularExpression) != nil else { throw AppFailure.message("通知编号格式无效，可留空由 App 生成") }
        guard title.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines) == "动账通知" else { return nil }
        // Anchor the entire body: promotions mentioning payments or an amount,
        // truncated receipts and combined notifications cannot become expenses.
        let shape = #"\A尾号\s*[0-9]{4}\s*卡\s*(?:[0-9]{4}年)?[0-9]{1,2}月[0-9]{1,2}日\s*[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?\s*(?:支出|收入|退款|退货|退回)\s*(?:\([^()\r\n]{1,200}\))?\s*(?:人民币|RMB|CNY)?\s*[0-9,.]+\s*元\s*(?:[，,]\s*余额\s*(?:人民币)?\s*-?[0-9,.]+\s*元)?\s*[。.]?\s*(?:【工商银行】\s*)?(?:请点击查看详情[。.]?\s*)?\z"#
        guard text.range(of: shape, options: .regularExpression) != nil else { return nil }
        guard var message = try BankSMS.parseTransaction(body: text, requestID: requestID, receivedAt: receivedAt) else { return nil }
        message.origin = .icbcNotification
        message.draft?.externalID = "notification:\(message.id.uuidString)"
        // Spaced notification tails still identify the balance account.
        if let range = text.range(of: #"(?<=尾号)\s*[0-9]{4}(?=\s*卡)"#, options: .regularExpression) {
            message.draft?.bankAccountTail = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message
    }

    static func accept(title: String, body: String, requestID: String?, receivedAt: Date = Date(), into current: Snapshot) throws -> (snapshot: Snapshot, result: String) {
        guard let message = try parse(title: title, body: body, requestID: SMSInboxPolicy.resolvedRequestID(requestID), receivedAt: receivedAt) else { return (current, "已跳过非记账消息") }
        return try SMSInboxPolicy.accept(message: message, into: current)
    }
}
