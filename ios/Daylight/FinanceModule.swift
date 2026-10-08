import SwiftUI
import Charts

private struct FinancePoint: Identifiable { var date: Date; var cents: Int; var id: Date { date } }
private struct CategoryPoint: Identifiable { var name: String; var cents: Int; var id: String { name } }
private enum BankImportMode: String, Identifiable { case screenshots, sms, notification; var id: String { rawValue } }

struct FinanceModule: View {
    @EnvironmentObject private var store: AssistantStore
    @Binding var entry: EntryRequest?
    @State private var scope: PeriodScope = .day
    @State private var showAllRecords = false
    @State private var date = Date()
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var kind = "all"
    @State private var showBalanceSettings = false
    @State private var bankImport: BankImportMode?
    private var interval: DateInterval { scope.interval(for: date) }
    private var records: [MoneyRecord] { store.data.transactions.filter { $0.date >= interval.start && $0.date < interval.end } }
    private var filtered: [MoneyRecord] { records.filter { (kind == "all" || $0.kind.rawValue == kind) && (query.isEmpty || "\($0.title) \($0.source) \($0.category)".localizedCaseInsensitiveContains(query)) }.sorted { $0.date > $1.date } }
    private var pending: [BankMessage] { store.data.smsInbox.filter { $0.status == .pending }.sorted { $0.receivedAt > $1.receivedAt } }
    private var visibleRecords: [MoneyRecord] { showAllRecords ? filtered : Array(filtered.prefix(5)) }
    private var periodTitle: String {
        switch scope {
        case .day: return date.formatted(.dateTime.month().day())
        case .week: return "\(interval.start.formatted(.dateTime.month().day())) — \(interval.end.addingTimeInterval(-1).formatted(.dateTime.month().day()))"
        case .month: return date.formatted(.dateTime.year().month(.wide))
        }
    }
    var body: some View {
        balanceCard
        Picker("汇总周期", selection: $scope) { ForEach(PeriodScope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("finance-period")
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").padding(8) }.accessibilityLabel("上一周期")
            Spacer(); Text(periodTitle).font(.headline); Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").padding(8) }.accessibilityLabel("下一周期")
        }
        DatePicker("选择日期", selection: $date, displayedComponents: .date).font(.subheadline)
        summary
        if !pending.isEmpty { pendingSection }
        detailsSection
        if scope != .day { trendSection }
        ModuleSection(title: "分类汇总") {
            SoftCard {
                if categoryPoints.isEmpty { EmptyRecords(title: "还没有分类记录", icon: "list.bullet") }
                ForEach(categoryPoints) { point in HStack { Text(point.name); Spacer(); Text("¥ \(MoneyMath.display(point.cents))").monospacedDigit() }.font(.subheadline) }
            }
        }
        importSection
            .sheet(isPresented: $showBalanceSettings) { BankBalanceSheet() }
            .sheet(item: $bankImport) { mode in BankScreenshotImportSheet(manualSMS: mode == .sms, manualNotification: mode == .notification) }
            .onChange(of: scope) { _, _ in showAllRecords = false }
            .onChange(of: date) { _, _ in showAllRecords = false }
            .onChange(of: query) { _, _ in showAllRecords = false }
            .onChange(of: kind) { _, _ in showAllRecords = false }
            .onDisappear { searchFocused = false }
            .task {
                #if DEBUG && targetEnvironment(simulator)
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--capture-bank-import") || args.contains("--capture-bank-review") { bankImport = .screenshots }
                if args.contains("--capture-bank-notification") { bankImport = .notification }
                #endif
            }
    }
    private var importSection: some View {
        ModuleSection(title: "补录与识别") { SoftCard {
            Button("补录动账通知", systemImage: "bell.badge") { bankImport = .notification }.accessibilityIdentifier("finance-import-notification")
            Text("工行 App 小额动账通知也能记账；自动接收配置见设置。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("识别微信动账截图", systemImage: "photo.on.rectangle.angled") { bankImport = .screenshots }.accessibilityIdentifier("finance-import-screenshots")
            Text("补录未发送短信的小额交易，多张截图一起核对。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("补录银行短信", systemImage: "text.bubble") { bankImport = .sms }.accessibilityIdentifier("finance-import-sms")
        } }
    }
    private var trendSection: some View {
        ModuleSection(title: "净支出趋势") {
            SoftCard {
                if records.isEmpty { EmptyRecords(title: "记录之后，变化会出现在这里", icon: "chart.xyaxis.line") }
                else { Chart(dayPoints) { point in LineMark(x: .value("日期", point.date), y: .value("元", Double(point.cents) / 100)).foregroundStyle(.blue); PointMark(x: .value("日期", point.date), y: .value("元", Double(point.cents) / 100)).foregroundStyle(.blue) }.frame(height: 160).accessibilityLabel("已记录净支出趋势，单位为元") }
            }
        }
    }
    private var detailsSection: some View {
        ModuleSection(title: "收支明细") {
            SoftCard {
                HStack {
                    TextField("搜索名称、分类或渠道", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searchFocused).submitLabel(.done)
                        .onSubmit { searchFocused = false }.accessibilityIdentifier("finance-search")
                    if searchFocused {
                        Button("完成") { searchFocused = false }.accessibilityIdentifier("finance-dismiss-keyboard")
                    }
                }
                Picker("记录类型", selection: $kind) { Text("全部").tag("all"); ForEach(TransactionKind.allCases) { Text($0.label).tag($0.rawValue) } }.pickerStyle(.menu)
                if filtered.isEmpty { EmptyRecords(title: "没有符合条件的记录", icon: "wallet.pass") }
                ForEach(visibleRecords) { value in
                    Button { searchFocused = false; entry = EntryRequest(kind: .money, money: value) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text(value.title).foregroundStyle(.primary); Text("\(value.date.formatted(.dateTime.month().day())) · \(value.category) · \(value.kind.label)").font(.caption).foregroundStyle(.secondary); Text(value.source).font(.caption2).foregroundStyle(.secondary) }
                            Spacer(); Text("¥ \(MoneyMath.display(value.cents))").monospacedDigit().foregroundStyle(value.kind == .income || value.kind == .refund ? Color.green : Color.primary)
                        }.font(.subheadline).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("finance-record-\(value.title)")
                }
                if filtered.count > 5 {
                    Divider()
                    Button(showAllRecords ? "收起明细" : "查看全部 \(filtered.count) 笔") { showAllRecords.toggle() }
                        .accessibilityIdentifier("finance-toggle-details")
                }
            }
            Text("统计仅包含已保存记录。账户转移不计消费；退款抵减支出，不计收入。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var balanceCard: some View {
        SoftCard {
            HStack { Text("工行卡余额").font(.subheadline).foregroundStyle(.secondary); Spacer(); Button("设置余额") { showBalanceSettings = true }.font(.subheadline).accessibilityIdentifier("finance-set-balance") }
            if let reading = BankBalanceMath.reading(store.data) {
                Text("¥ \(MoneyMath.display(reading.cents))").font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit().accessibilityIdentifier("finance-balance-value")
                Text("\(reading.fromSMS ? "依据已确认的银行余额" : "依据手动设置") · \(reading.date.formatted(.dateTime.month().day().hour().minute()))").font(.caption).foregroundStyle(.secondary)
                if reading.estimated { Text("估算余额 · 已按此后保存的收支更新").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(BankBalanceMath.hasUnresolvedScreenshotOrder(store.data) ? "需要校准" : "未设置").font(.title2.weight(.semibold))
                Text("设置起始余额，或确认包含余额的银行通知、短信和动账截图。").font(.caption).foregroundStyle(.secondary)
            }
            if BankBalanceMath.hasUnresolvedScreenshotOrder(store.data) {
                Text("同一分钟多笔交易的先后不明确，暂不采用该分钟的交易后余额。请核对银行当前余额并校准。").font(.caption).foregroundStyle(.orange)
            }
            if !pending.isEmpty { Text("\(pending.count) 条待确认，暂未更新余额").font(.caption).foregroundStyle(.orange) }
        }
    }
    private var summary: some View {
        SoftCard {
            Text(scope == .day ? "当天已记录净支出" : "本周期已记录净支出").font(.subheadline).foregroundStyle(.secondary)
            Text("¥ \(MoneyMath.display(MoneyMath.netExpense(records)))").font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
            HStack { SmallMetric(title: "收入", value: "¥ \(MoneyMath.display(MoneyMath.sum(records, kind: .income)))"); Spacer(); SmallMetric(title: "支出", value: "¥ \(MoneyMath.display(MoneyMath.sum(records, kind: .expense)))"); Spacer(); SmallMetric(title: "退款", value: "¥ \(MoneyMath.display(MoneyMath.sum(records, kind: .refund)))") }
            Divider()
            HStack { SmallMetric(title: "转移", value: "¥ \(MoneyMath.display(MoneyMath.sum(records, kind: .transfer)))"); Spacer(); SmallMetric(title: "已保存", value: "\(records.count) 笔", valueIdentifier: "finance-record-count") }
            if !previousRecords.isEmpty {
                let difference = MoneyMath.netExpense(records) - MoneyMath.netExpense(previousRecords)
                Text("比上一周期\(difference >= 0 ? "增加" : "减少") ¥ \(MoneyMath.display(abs(difference)))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var pendingSection: some View {
        ModuleSection(title: "待确认 · \(pending.count)") {
            SoftCard {
                ForEach(pending) { value in
                    Button { entry = EntryRequest(kind: .money, sms: value) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text(value.draft?.title ?? "金额待补充").foregroundStyle(.primary).lineLimit(2); Text(value.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Spacer(); Text(value.draft.map { "¥ \(MoneyMath.display($0.cents))" } ?? "确认").foregroundStyle(.orange).monospacedDigit()
                        }.font(.subheadline).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var previousRecords: [MoneyRecord] {
        let previous = scope.interval(for: Calendar.current.date(byAdding: scope.component, value: -1, to: date)!)
        return store.data.transactions.filter { $0.date >= previous.start && $0.date < previous.end }
    }
    private var categoryPoints: [CategoryPoint] { Dictionary(grouping: records.filter { $0.kind == .expense || $0.kind == .refund }, by: \.category).map { CategoryPoint(name: $0.key, cents: MoneyMath.netExpense($0.value)) }.sorted { $0.cents > $1.cents } }
    private var dayPoints: [FinancePoint] {
        let grouped = Dictionary(grouping: records, by: { Calendar.current.startOfDay(for: $0.date) })
        var points: [FinancePoint] = []; var day = interval.start
        while day < interval.end { points.append(FinancePoint(date: day, cents: MoneyMath.netExpense(grouped[day] ?? []))); day = Calendar.current.date(byAdding: .day, value: 1, to: day)! }
        return points
    }
    private func shift(_ direction: Int) { date = Calendar.current.date(byAdding: scope.component, value: direction, to: date)! }
}

struct BankBalanceSheet: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var date = Date()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("工行储蓄卡") {
                    TextField("余额（元，可为 0）", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("balance-amount")
                    DatePicker("余额对应时间", selection: $date, in: ...Date())
                    Text("填写该时间点的实际余额。余额已包含此前交易，之后保存的银行卡收支继续加减。").font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }.navigationTitle("设置银行卡余额").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("balance-cancel") }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try store.setBankBalance(cents: MoneyMath.parseBalance(amount), date: date); dismiss() } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("balance-save") }
            }
        }.presentationDragIndicator(.visible)
        .onAppear { if let reading = BankBalanceMath.reading(store.data) { amount = String(format: "%.2f", Double(reading.cents) / 100) } }
    }
}
