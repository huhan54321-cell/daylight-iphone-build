import Foundation
import CryptoKit

struct BankScreenshotParseResult {
    var messages: [BankMessage]
    var notices: [String]
    var incompleteCardCount: Int
}

enum BankScreenshotDuplicateLevel: Equatable { case none, possible, exact }
struct BankScreenshotDuplicate {
    var level: BankScreenshotDuplicateLevel
    var reason: String
    var existingID: UUID? = nil
}
struct BankScreenshotConfirmation {
    var snapshot: Snapshot
    var count: Int
    var skippedCount: Int
    var notices: [String]
}

/// Parses only complete, explicitly labelled ICBC reminder cards. Images and OCR text
/// never enter the saved snapshot; saved bodies use the existing bank redaction.
enum BankScreenshotCore {
    static func parse(text: String, receivedAt: Date = Date()) throws -> BankScreenshotParseResult {
        guard text.utf16.count <= 50_000 else { throw AppFailure.message("截图文字过多，请分批选择") }
        let compact = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard compact.contains("中国工商银行客户服务"), compact.contains("动账交易提醒") else {
            return BankScreenshotParseResult(messages: [], notices: ["没有识别到完整的工行客户服务动账提醒，请保留服务号名称和交易卡片"], incompleteCardCount: 0)
        }
        let sections = compact.components(separatedBy: "中国工商银行客户服务").dropFirst()
        let cards = sections.flatMap { section -> [String] in
            let pieces = section.components(separatedBy: "动账交易提醒")
            return Array(pieces.dropFirst())
        }
        guard cards.count <= 100 else { throw AppFailure.message("一批最多识别 100 条提醒，请分批选择") }
        var messages: [BankMessage] = [], notices: [String] = [], incomplete = 0
        for (index, card) in cards.enumerated() {
            guard let message = try parseCard(card, receivedAt: receivedAt) else {
                incomplete += 1
                notices.append("第 \(index + 1) 条提醒字段不完整或识别有歧义，未生成账单；请保留尾号、时间、类型、金额和余额")
                continue
            }
            messages.append(message)
        }
        let tails = Set(messages.compactMap { $0.draft?.bankAccountTail })
        if tails.count > 1 { notices.append("截图包含多张银行卡，请只选择当前账本使用的银行卡，避免混用余额") }
        return BankScreenshotParseResult(messages: messages, notices: notices, incompleteCardCount: incomplete)
    }

    private static func parseCard(_ card: String, receivedAt: Date) throws -> BankMessage? {
        // Exact field counts prevent mixing an amount from one card with another balance.
        for labels in [["账号类型:", "帐号类型:"], ["交易时间:"], ["交易类型:"], ["交易金额:"], ["账户余额:", "帐号余额:", "账号余额:"]] {
            guard labels.reduce(0, { $0 + card.components(separatedBy: $1).count - 1 }) == 1 else { return nil }
        }
        func unique(_ pattern: String, group: Int = 1) throws -> String? {
            let regex = try NSRegularExpression(pattern: pattern)
            let matches = regex.matches(in: card, range: NSRange(card.startIndex..., in: card))
            guard matches.count == 1, let match = matches.first, match.range(at: group).location != NSNotFound else { return nil }
            return (card as NSString).substring(with: match.range(at: group))
        }
        guard let tailText = try unique(#"(?:账号|帐号)类型:尾号([0-9]{4}|[Xx]{4})的借记卡交易时间:"#),
              let stamp = try unique(#"交易时间:([0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)交易类型:"#),
              let detail = try unique(#"交易类型:([^:]{1,100})交易金额:"#),
              let verb = try unique(#"交易金额:(出账|入账)(?:人民币)?-?[0-9,.]+(?:人民币)?元(?:账户|帐号|账号)余额:"#),
              let amount = try unique(#"交易金额:(?:出账|入账)(?:人民币)?(-?[0-9,.]+)(?:人民币)?元(?:账户|帐号|账号)余额:"#),
              let balance = try unique(#"(?:账户|帐号|账号)余额:(?:人民币)?(-?[0-9,.]+)(?:人民币)?元(?:。|查看详情|$)"#),
              amount.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              balance.range(of: #"^-?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let cents = try? MoneyMath.parse(amount.replacingOccurrences(of: ",", with: "")),
              let balanceCents = try? MoneyMath.parseBalance(balance.replacingOccurrences(of: ",", with: "")) else { return nil }
        let sanitizedDetail = detail.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
        let exactAmount = "\(cents / 100).\(String(format: "%02d", cents % 100))"
        let body = "尾号\(tailText)卡\(stamp)\(verb == "出账" ? "支出" : "收入")(\(sanitizedDetail))\(exactAmount)元，余额\(balance.replacingOccurrences(of: ",", with: ""))元。【工商银行】"
        guard var message = try BankSMS.parse(body: body, sender: "95588", requestID: UUID().uuidString, receivedAt: receivedAt),
              var draft = message.draft else { return nil }
        // A canonical receipt key survives repeated screenshots, OCR spacing, and
        // equivalent integer/decimal formatting, without using the original image.
        let tail = tailText.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil ? tailText : nil
        let key = ["icbc-wechat-v1", tail ?? "unknown", String(Int64(draft.date.timeIntervalSince1970)), verb, String(cents), String(balanceCents), detail].joined(separator: "\n")
        message.fingerprint = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        message.origin = .wechatScreenshot
        message.bankBalanceAfterCents = balanceCents
        draft.title = detail
        draft.externalID = "wechat:\(message.id.uuidString)"
        draft.bankAccountTail = tail
        draft.bankBalanceAfterCents = balanceCents
        message.draft = draft
        if tail == nil { message.warnings.append("未识别银行卡尾号，请确认属于当前账本的银行卡") }
        message.reason = message.warnings.isEmpty ? "截图金额已识别，等待核对" : message.warnings.joined(separator: "；")
        return message
    }

    /// Shared with SMS reception: an old SMS may have no tail, so matching it is
    /// deliberately possible rather than exact. Different known balances or tails
    /// distinguish separate payments even when their minute and amount are equal.
    static func duplicate(for message: BankMessage, in snapshot: Snapshot) -> BankScreenshotDuplicate {
        if let existing = snapshot.smsInbox.first(where: { $0.fingerprint == message.fingerprint }) {
            let level: BankScreenshotDuplicateLevel = existing.status == .ignored ? .possible : .exact
            let reason = existing.status == .ignored ? "相同提醒曾被忽略，请确认是否重新记录" : existing.status == .pending ? "相同提醒已在待确认列表中" : "相同提醒已在账本中"
            return BankScreenshotDuplicate(level: level, reason: reason, existingID: existing.id)
        }
        guard let draft = message.draft else { return BankScreenshotDuplicate(level: .none, reason: "") }
        var candidates = snapshot.transactions
        candidates += snapshot.smsInbox.filter { $0.status == .pending }.compactMap(\.draft)
        var possible: UUID? = nil
        for existing in candidates {
            guard existing.id != draft.id, sameMinute(existing.date, draft.date), existing.cents == draft.cents,
                  BankBalanceMath.direction(for: existing) == BankBalanceMath.direction(for: draft),
                  BankBalanceMath.direction(for: draft) != .excluded else { continue }
            if let left = existing.bankAccountTail, let right = draft.bankAccountTail, left != right { continue }
            if let left = existing.bankBalanceAfterCents, let right = draft.bankBalanceAfterCents, left != right { continue }
            let knownSameTail = existing.bankAccountTail != nil && existing.bankAccountTail == draft.bankAccountTail
            let knownSameBalance = existing.bankBalanceAfterCents != nil && existing.bankBalanceAfterCents == draft.bankBalanceAfterCents
            let sameMerchant = merchantKey(existing.title) == merchantKey(draft.title)
            let involvesNotification = message.origin == .icbcNotification || existing.externalID?.hasPrefix("notification:") == true
            if knownSameTail && sameMerchant && (knownSameBalance || involvesNotification) {
                return BankScreenshotDuplicate(level: .exact, reason: "时间、金额、尾号和交易内容与已有账单相同，已自动去重", existingID: existing.id)
            }
            possible = possible ?? existing.id
        }
        if let existingID = possible { return BankScreenshotDuplicate(level: .possible, reason: "已有相同分钟、方向和金额的账单，请核对是否为同一笔交易", existingID: existingID) }
        return BankScreenshotDuplicate(level: .none, reason: "")
    }

    static func confirm(messages: [BankMessage], into current: Snapshot, allowPossibleDuplicate: Set<UUID> = []) throws -> BankScreenshotConfirmation {
        guard messages.count <= 100 else { throw AppFailure.message("一批最多确认 100 条提醒") }
        let knownTails = Set(current.transactions.filter { BankBalanceMath.direction(for: $0) != .excluded }.compactMap(\.bankAccountTail))
        let selectedTails = Set(messages.compactMap { message -> String? in
            guard let record = message.draft, BankBalanceMath.direction(for: record) != .excluded else { return nil }
            return record.bankAccountTail
        })
        guard selectedTails.count <= 1, knownTails.union(selectedTails).count <= 1 else { throw AppFailure.message("当前余额账本仅支持一张银行卡，请勿混入其他银行卡的提醒") }
        var next = current, count = 0, skipped = 0, notices: [String] = []
        for var message in messages {
            guard var record = message.draft else { throw AppFailure.message("账单字段不完整，请重新识别") }
            let match = duplicate(for: message, in: next)
            if match.level == .exact {
                skipped += 1; notices.append("一条已存在的提醒已跳过")
                continue
            }
            guard match.level != .possible || allowPossibleDuplicate.contains(message.id) else { throw AppFailure.message("有可能重复的账单，请核对后明确选择仍要记录") }
            record.id = message.id
            record.externalID = "\((message.origin ?? .sms).externalPrefix):\(message.id.uuidString)"
            message.draft = record
            message.bankBalanceAfterCents = record.bankBalanceAfterCents
            message.status = .recorded
            message.possibleDuplicate = match.level == .possible
            message.reason = message.origin == .wechatScreenshot ? "已核对并记录微信动账截图" : "已核对并记录银行卡短信"
            next.smsInbox.append(message)
            next.transactions.append(record)
            count += 1
        }
        try SnapshotChecks.validate(next)
        return BankScreenshotConfirmation(snapshot: next, count: count, skippedCount: skipped, notices: notices)
    }

    private static func sameMinute(_ lhs: Date, _ rhs: Date) -> Bool {
        floor(lhs.timeIntervalSince1970 / 60) == floor(rhs.timeIntervalSince1970 / 60)
    }
    private static func merchantKey(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:消费|缴费)(?:财付通|支付宝)?[-:]?"#, with: "", options: .regularExpression)
    }
}
