import Foundation
import CryptoKit

enum BankSMS {
    static func redact(_ value: String) -> String {
        value.replacingOccurrences(of: #"尾号\s*[^\s卡]{1,12}\s*卡"#, with: "尾号XXXX卡", options: .regularExpression)
            .replacingOccurrences(of: #"余额\s*(?:人民币)?\s*-?[\d,.]+\s*元"#, with: "余额已隐藏", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{12,19}\b"#, with: "[账户号码已隐藏]", options: .regularExpression)
            .replacingOccurrences(of: #"\b1[3-9]\d{9}\b"#, with: "[手机号已隐藏]", options: .regularExpression)
    }

    static func parse(body: String, sender: String, requestID: String, receivedAt: Date = Date()) throws -> BankMessage? {
        if let problem = SMSReceptionDiagnostics.inputProblem(body: body, requestID: requestID) { throw AppFailure.message(problem.summary) }
        guard sender.trimmingCharacters(in: .whitespacesAndNewlines) == "95588", body.precomposedStringWithCompatibilityMapping.contains("【工商银行】") else { return nil }
        return try parseTransaction(body: body, requestID: requestID, receivedAt: receivedAt)
    }

    // Callers validate their own source contract first. Notification bodies do not
    // have the SMS footer; never add a forged footer to make them pass SMS checks.
    static func parseTransaction(body: String, requestID: String, receivedAt: Date) throws -> BankMessage? {
        let text = body.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppFailure.message("没有收到短信正文。请将短信正文设为获取文本的输出变量；在自动化编辑页手动运行时，可能没有收到消息输入。") }
        guard text.utf16.count <= 4_000 else { throw AppFailure.message("短信正文超过 4000 字，请检查输入变量") }
        guard requestID.range(of: #"^[A-Za-z0-9_-]{16,100}$"#, options: .regularExpression) != nil else {
            throw AppFailure.message("短信编号应为 16–100 位字母、数字、下划线或短横线")
        }
        guard text.range(of: "验证码|动态密码|一次性密码|登录|失败|未成功|待处理|冻结|解冻|预授权|额度|营销|优惠券", options: .regularExpression) == nil else { return nil }
        let bytes = Data(("95588\n" + text).utf8)
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var result = BankMessage(requestID: requestID, fingerprint: fingerprint, receivedAt: receivedAt, body: redact(text), draft: nil, reason: "未找到唯一交易金额，请补充确认；余额不会替代金额")
        let balanceRegex = try NSRegularExpression(pattern: #"余额\s*(?:人民币)?\s*(-?[\d,]+(?:\.\d{1,2})?)\s*元"#)
        let balances = balanceRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if balances.count == 1 {
            let amount = (text as NSString).substring(with: balances[0].range(at: 1))
            if amount.range(of: #"^-?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,2})?$"#, options: .regularExpression) != nil {
                result.bankBalanceAfterCents = try? MoneyMath.parseBalance(amount.replacingOccurrences(of: ",", with: ""))
            }
        }
        let regex = try NSRegularExpression(pattern: #"(支出|收入|退款|退货|退回)\s*(?:\(([^()]*)\))?\s*(?:人民币|RMB|CNY)?\s*([\d,]+(?:\.\d{1,2})?)\s*元"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let match = matches.first else { return result }
        let string = text as NSString
        let verb = string.substring(with: match.range(at: 1))
        let detail = match.range(at: 2).location == NSNotFound ? "" : string.substring(with: match.range(at: 2))
        let amount = string.substring(with: match.range(at: 3))
        guard amount.range(of: #"^(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let cents = try? MoneyMath.parse(amount.replacingOccurrences(of: ",", with: "")) else {
            result.reason = "交易金额格式或范围异常，请补充确认"; return result
        }
        var kind: TransactionKind = verb == "支出" ? .expense : verb == "收入" ? .income : .refund
        if detail.range(of: "退款|退货|消费撤销", options: .regularExpression) != nil, verb != "支出" { kind = .refund }
        if detail.range(of: "充值财付通|微信零钱充值|充值支付宝|支付宝.*充值|本人账户|同名账户", options: .regularExpression) != nil { kind = .transfer }
        if kind == .income { result.warnings.append("请确认是否为本人账户转入；本人资金转移不计收入") }
        if kind != .transfer, detail.range(of: "转账|转帐|汇款|提现|取款|取现|还款|转存|理财|基金", options: .regularExpression) != nil {
            result.warnings.append("资金用途待确认，请区分消费、收入和本人账户转移")
        }
        let dateRegex = try NSRegularExpression(pattern: #"(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#)
        var date = receivedAt
        var minuteOnly = false
        if let stamp = dateRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            minuteOnly = stamp.range(at: 6).location == NSNotFound
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
            func number(_ index: Int) -> Int? { stamp.range(at: index).location == NSNotFound ? nil : Int(string.substring(with: stamp.range(at: index))) }
            let year = calendar.component(.year, from: receivedAt)
            let years = number(1).map { [$0] } ?? [year - 1, year, year + 1]
            let month = number(2)!, day = number(3)!, hour = number(4)!, minute = number(5)!, second = number(6) ?? 0
            let candidates = years.compactMap { value -> Date? in
                let components = DateComponents(year: value, month: month, day: day, hour: hour, minute: minute, second: second)
                guard let instant = calendar.date(from: components) else { return nil }
                let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
                guard check.year == value, check.month == month, check.day == day, check.hour == hour, check.minute == minute, check.second == second else { return nil }
                return instant
            }.sorted { abs($0.timeIntervalSince(receivedAt)) < abs($1.timeIntervalSince(receivedAt)) }
            guard let instant = candidates.first else { result.reason = "短信日期无效，请补充确认"; return result }
            date = instant
            if abs(date.timeIntervalSince(receivedAt)) > 3 * 86_400 { result.warnings.append("交易与接收时间相差超过三天，请确认日期") }
        } else { result.warnings.append("未识别交易时间，暂使用接收时间，请确认") }
        result.draft = MoneyRecord(id: result.id, date: date, kind: kind, cents: cents, title: detail.isEmpty ? "银行卡\(verb)" : detail, category: MerchantCategories.category(title: detail, kind: kind), source: "工行储蓄卡", externalID: "sms:\(result.id.uuidString)")
        result.draft?.bankDirection = verb == "支出" ? .debit : .credit
        result.draft?.bankBalanceAfterCents = result.bankBalanceAfterCents
        result.draft?.bankBalanceReportedAt = receivedAt
        result.draft?.bankTimeIsMinuteOnly = minuteOnly
        if let tail = text.range(of: #"(?<=尾号)[0-9]{4}(?=卡)"#, options: .regularExpression) {
            result.draft?.bankAccountTail = String(text[tail])
        }
        result.reason = result.warnings.isEmpty ? "金额已识别，等待确认" : result.warnings.joined(separator: "；")
        return result
    }
}
