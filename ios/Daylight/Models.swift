import Foundation

enum TransactionKind: String, Codable, CaseIterable, Identifiable {
    case expense, income, refund, transfer
    var id: String { rawValue }
    var label: String {
        switch self { case .expense: return "支出"; case .income: return "收入"; case .refund: return "退款"; case .transfer: return "账户转移" }
    }
}

struct MoneyRecord: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var kind: TransactionKind
    var cents: Int
    var title: String
    var category: String
    var source: String
    var externalID: String? = nil
    var bankDirection: BankBalanceDirection? = nil
    var bankBalanceAfterCents: Int? = nil
    var bankBalanceReportedAt: Date? = nil
    var bankTimeIsMinuteOnly: Bool? = nil
    var bankAccountTail: String? = nil
}

enum MerchantCategories {
    static func category(title: String, kind: TransactionKind) -> String {
        if kind == .transfer { return "账户转移" }
        if kind == .income { return title.range(of: "工资|薪资|薪酬", options: .regularExpression) != nil ? "工资" : "待分类" }
        let rules: [(String, String)] = [
            ("炸串|烧烤|餐饮|餐馆|饭店|餐厅|小吃|茶饮|奶茶|大杯茶|咖啡|面馆|饺子|火锅|汉堡|肯德基|麦当劳|蜜雪|瑞幸|星巴克|喜茶|古茗|霸王茶姬", "餐饮"),
            ("地铁|公交|出租车|打车|滴滴|高铁|火车|铁路|停车|加油|轮渡|客运|交通", "交通"),
            ("体育|健身|运动|球馆|游泳|瑜伽|羽毛球|篮球|网球|攀岩", "运动"),
            ("房租|物业|水费|电费|燃气|酒店|宾馆|住宿", "居住"),
            ("电影|影院|剧院|演出|游戏|乐园|景区", "娱乐"),
            ("超市|商场|百货|便利店|购物|淘宝|京东|拼多多", "购物")
        ]
        return rules.first { title.range(of: $0.0, options: .regularExpression) != nil }?.1 ?? "待分类"
    }
    static func fill(_ record: MoneyRecord) -> MoneyRecord {
        guard ["", "待分类", "未分类"].contains(record.category.trimmingCharacters(in: .whitespacesAndNewlines)) else { return record }
        var value = record; value.category = category(title: value.title, kind: value.kind); return value
    }
}

enum BankBalanceDirection: String, Codable { case excluded, debit, credit }
struct BankBalanceBaseline: Codable { var cents: Int; var date: Date }
struct BankBalanceReading { var cents: Int; var date: Date; var fromSMS: Bool; var estimated: Bool }
enum BankBalanceMath {
    static func transactionDate(_ record: MoneyRecord) -> Date {
        guard record.bankTimeIsMinuteOnly == true, let received = record.bankBalanceReportedAt else { return record.date }
        // Place a minute-only bank timestamp within its own minute; a delayed SMS stays in that minute.
        return min(max(received, record.date), record.date.addingTimeInterval(59.999))
    }
    static func direction(for record: MoneyRecord) -> BankBalanceDirection {
        if let explicit = record.bankDirection { return explicit }
        guard ["工行储蓄卡", "银行卡"].contains(record.source) else { return .excluded }
        return [.income, .refund].contains(record.kind) ? .credit : .debit
    }
    static func delta(_ record: MoneyRecord) -> Int {
        switch direction(for: record) { case .excluded: return 0; case .debit: return -record.cents; case .credit: return record.cents }
    }
    private static func screenshotOrderMinutes(_ snapshot: Snapshot) -> Set<Double> {
        let groups = Dictionary(grouping: snapshot.transactions.filter { direction(for: $0) != .excluded }) { floor($0.date.timeIntervalSince1970 / 60) }
        return Set(groups.compactMap { minute, records in
            records.count >= 2 && records.contains(where: { $0.bankTimeIsMinuteOnly == true && $0.externalID?.hasPrefix("wechat:") == true }) ? minute : nil
        })
    }
    static func hasUnresolvedScreenshotOrder(_ snapshot: Snapshot) -> Bool {
        guard let latestMinute = screenshotOrderMinutes(snapshot).max() else { return false }
        guard let basis = reading(snapshot) else { return true }
        return latestMinute * 60 > basis.date.timeIntervalSince1970
    }
    static func reading(_ snapshot: Snapshot) -> BankBalanceReading? {
        let uncertainMinutes = screenshotOrderMinutes(snapshot)
        // Screenshot import time and UUID cannot order separate bank payments within
        // one minute. Keep reported balances as evidence, but use none as that minute's endpoint.
        let checkpoints = snapshot.transactions.filter { direction(for: $0) != .excluded && $0.bankBalanceAfterCents != nil && !uncertainMinutes.contains(floor($0.date.timeIntervalSince1970 / 60)) }.sorted {
            let leftDate = transactionDate($0), rightDate = transactionDate($1)
            if leftDate != rightDate { return leftDate > rightDate }
            let left = $0.bankBalanceReportedAt ?? $0.date, right = $1.bankBalanceReportedAt ?? $1.date
            if left != right { return left > right }
            return $0.id.uuidString > $1.id.uuidString
        }
        let checkpoint = checkpoints.first
        let baseline = snapshot.bankBalanceBaseline.flatMap { uncertainMinutes.contains(floor($0.date.timeIntervalSince1970 / 60)) ? nil : $0 }
        let useSMS = checkpoint != nil && (baseline == nil || transactionDate(checkpoint!) > baseline!.date)
        guard useSMS || baseline != nil else { return nil }
        let date = useSMS ? transactionDate(checkpoint!) : baseline!.date
        let base = useSMS ? checkpoint!.bankBalanceAfterCents! : baseline!.cents
        // A reported balance already includes its transaction and earlier transactions.
        let later = snapshot.transactions.filter { transactionDate($0) > date && direction(for: $0) != .excluded }
        let uncertainLater = uncertainMinutes.contains { $0 * 60 > date.timeIntervalSince1970 }
        return BankBalanceReading(cents: base + later.reduce(0) { $0 + delta($1) }, date: date, fromSMS: useSMS, estimated: !later.isEmpty || uncertainLater)
    }
}

struct PlanTask: Identifiable, Codable {
    var id = UUID()
    var title: String
    var date: Date
    var completed = false
    var notes = ""
    var reminderID: String? = nil
}

struct PlanEvent: Identifiable, Codable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var notes = ""
    var eventID: String? = nil
    var location: String? = nil
    var navigationURL: String? = nil
    var tripID: UUID? = nil
    var allDay: Bool? = nil
    var isAllDay: Bool { allDay == true }
}

struct WeightRecord: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var kilograms: Double
    var source: String
    var healthID: String? = nil
}

struct ExerciseRecord: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var title: String
    var minutes: Double
    var actions = ""
    var source: String
    var healthID: String? = nil
}

struct Snapshot: Codable {
    var version = 4
    var transactions: [MoneyRecord] = []
    var tasks: [PlanTask] = []
    var events: [PlanEvent] = []
    var weights: [WeightRecord] = []
    var workouts: [ExerciseRecord] = []
    var importedAt: Date? = nil
    var smsInbox: [BankMessage] = []
    var autoRecordSMS = false
    var bankBalanceBaseline: BankBalanceBaseline? = nil
    var plannerPreferences = PlannerPreferences()
    var plannedTrips: [PlannedTrip] = []
    init() {}
    private enum CodingKeys: String, CodingKey { case version, transactions, tasks, events, weights, workouts, importedAt, smsInbox, autoRecordSMS, bankBalanceBaseline, plannerPreferences, plannedTrips }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let oldVersion = try values.decode(Int.self, forKey: .version)
        guard (1...4).contains(oldVersion) else { throw AppFailure.message("备份版本不受支持，已有记录已保留") }
        transactions = try values.decode([MoneyRecord].self, forKey: .transactions)
        tasks = try values.decode([PlanTask].self, forKey: .tasks)
        events = try values.decode([PlanEvent].self, forKey: .events)
        weights = try values.decode([WeightRecord].self, forKey: .weights)
        workouts = try values.decode([ExerciseRecord].self, forKey: .workouts)
        importedAt = try values.decodeIfPresent(Date.self, forKey: .importedAt)
        smsInbox = try values.decodeIfPresent([BankMessage].self, forKey: .smsInbox) ?? []
        autoRecordSMS = try values.decodeIfPresent(Bool.self, forKey: .autoRecordSMS) ?? false
        bankBalanceBaseline = try values.decodeIfPresent(BankBalanceBaseline.self, forKey: .bankBalanceBaseline)
        plannerPreferences = try values.decodeIfPresent(PlannerPreferences.self, forKey: .plannerPreferences) ?? PlannerPreferences()
        plannedTrips = try values.decodeIfPresent([PlannedTrip].self, forKey: .plannedTrips) ?? []
        transactions = transactions.map(MerchantCategories.fill)
        for index in smsInbox.indices { smsInbox[index].draft = smsInbox[index].draft.map(MerchantCategories.fill) }
    }
}

enum BankMessageStatus: String, Codable { case pending, recorded, ignored }
enum BankMessageOrigin: String, Codable {
    case sms, wechatScreenshot, icbcNotification
    var externalPrefix: String { switch self { case .sms: return "sms"; case .wechatScreenshot: return "wechat"; case .icbcNotification: return "notification" } }
    var label: String { switch self { case .sms: return "银行卡短信"; case .wechatScreenshot: return "微信动账截图"; case .icbcNotification: return "工行动账通知" } }
}
struct BankMessage: Codable, Identifiable {
    var id = UUID()
    var requestID: String
    var fingerprint: String
    var receivedAt: Date
    var body: String
    var draft: MoneyRecord?
    var warnings: [String] = []
    var status: BankMessageStatus = .pending
    var reason: String
    var possibleDuplicate = false
    var bankBalanceAfterCents: Int? = nil
    var origin: BankMessageOrigin? = nil
    var originLabel: String { (origin ?? .sms).label }
}

enum AppFailure: LocalizedError, CustomNSError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    static var errorDomain: String { "Daylight.AppFailure" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "操作未完成"] }
}

enum MoneyMath {
    static func parseBalance(_ text: String) throws -> Int {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: #"^-?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), abs(value) <= Decimal(1_000_000_000) else { throw AppFailure.message("余额最多两位小数，绝对值不超过十亿元") }
        return NSDecimalNumber(decimal: value * 100).intValue
    }
    static func parse(_ text: String) throws -> Int {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")),
              value > 0, value <= Decimal(1_000_000_000) else {
            throw AppFailure.message("金额应大于零、最多两位小数，且不超过十亿元")
        }
        return NSDecimalNumber(decimal: value * 100).intValue
    }
    static func display(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.number.precision(.fractionLength(2)))
    }
    static func sum(_ records: [MoneyRecord], kind: TransactionKind) -> Int {
        records.filter { $0.kind == kind }.reduce(0) { $0 + $1.cents }
    }
    static func netExpense(_ records: [MoneyRecord]) -> Int { sum(records, kind: .expense) - sum(records, kind: .refund) }
}
