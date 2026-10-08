import Foundation

enum SMSInboxPolicy {
    static func resolvedRequestID(_ input: String?) -> String {
        let value = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? UUID().uuidString : value
    }
    static func accept(body: String, sender: String, requestID input: String?, receivedAt: Date = Date(), into current: Snapshot) throws -> (snapshot: Snapshot, result: String) {
        let requestID = resolvedRequestID(input)
        guard let parsed = try BankSMS.parse(body: body, sender: sender, requestID: requestID, receivedAt: receivedAt) else { return (current, "已跳过非记账消息") }
        return try accept(message: parsed, into: current)
    }
    static func accept(message: BankMessage, into current: Snapshot) throws -> (snapshot: Snapshot, result: String) {
        var parsed = message
        let requestID = parsed.requestID
        if let existing = current.smsInbox.first(where: { $0.requestID == requestID }) {
            guard existing.fingerprint == parsed.fingerprint else {
                throw AppFailure.message("接收编号与已有记录重复，但正文不同。请将快捷指令中的编号留空，由日常生成编号，然后补录这笔交易。")
            }
            return (current, existing.status == .recorded ? "这条短信已记录" : "这条短信已接收")
        }
        var next = current
        if let tail = parsed.draft?.bankAccountTail {
            let knownTails = Set(next.transactions.filter { BankBalanceMath.direction(for: $0) != .excluded }.compactMap(\.bankAccountTail))
            if !knownTails.isEmpty && knownTails != Set([tail]) {
                parsed.warnings.append("此银行卡尾号与当前余额账本不同，请确认并取消计入工行卡余额")
                parsed.reason = parsed.warnings.joined(separator: "；")
            }
        }
        if let existing = next.smsInbox.first(where: { $0.fingerprint == parsed.fingerprint }) {
            if parsed.origin == .icbcNotification || existing.origin == .icbcNotification {
                return (current, existing.status == .recorded ? "这条短信已记录" : existing.status == .ignored ? "已跳过非记账消息" : "这条短信已接收")
            }
            parsed.possibleDuplicate = true; parsed.reason = "正文与已有银行消息相同，请确认是否为另一笔交易"
        }
        if !parsed.possibleDuplicate {
            let match = BankScreenshotCore.duplicate(for: parsed, in: next)
            let involvesNotification = parsed.origin == .icbcNotification
                || next.smsInbox.contains { $0.id == match.existingID && $0.origin == .icbcNotification }
                || next.transactions.contains { $0.id == match.existingID && $0.externalID?.hasPrefix("notification:") == true }
            if match.level == .exact && involvesNotification {
                let recorded = next.transactions.contains { $0.id == match.existingID }
                return (current, recorded ? "这条短信已记录" : "这条短信已接收")
            }
            if match.level != .none {
                parsed.possibleDuplicate = true
                parsed.reason = "可能与已接收的银行账单重复，请核对后确认"
            }
        }
        if next.autoRecordSMS, let record = parsed.draft, [.expense, .transfer].contains(record.kind), parsed.warnings.isEmpty, !parsed.possibleDuplicate {
            parsed.status = .recorded; next.transactions.append(record)
        }
        next.smsInbox.append(parsed)
        try SnapshotChecks.validate(next)
        return (next, parsed.status == .recorded ? "已保存这笔\(parsed.draft?.kind.label ?? "交易")" : "已接收，请在日常中确认")
    }
}
