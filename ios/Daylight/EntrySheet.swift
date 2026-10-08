import SwiftUI

struct EntrySheet: View {
    var request: EntryRequest
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()
    @State private var end = Date().addingTimeInterval(3_600)
    @State private var allDay = false
    @State private var amount = ""
    @State private var category = "餐饮"
    @State private var source = "微信"
    @State private var notes = ""
    @State private var transactionKind: TransactionKind = .expense
    @State private var exerciseType = "力量训练"
    @State private var error: String?
    @State private var loaded = false
    @State private var deleting = false
    @State private var affectsBankBalance = false
    @State private var transferToBank = false
    private var kind: EntryKind { request.kind }
    private var editing: Bool { request.money != nil || request.task != nil || request.event != nil || request.weight != nil || request.exercise != nil }
    private var fromHealth: Bool { request.weight?.healthID != nil || request.exercise?.healthID != nil }
    private var categories: [String] { Array(Set(["待分类", "餐饮", "交通", "购物", "居住", "运动", "娱乐", "工资", "账户转移", "其他", category])).sorted() }
    private var sheetTitle: String {
        if request.sms != nil { return "确认账单" }; if editing { return "编辑记录" }
        switch kind { case .task: return "添加待办"; case .event: return "安排日程"; case .money: return "记一笔"; case .weight: return "记录体重"; case .exercise: return "记录运动" }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let sms = request.sms { Section(sms.originLabel) { Text(sms.body).font(.footnote); Text(sms.reason).font(.caption).foregroundStyle(.secondary) } }
                Section {
                    if [.task, .event, .money].contains(kind) { TextField("名称", text: $title).accessibilityIdentifier("entry-title") }
                    if kind == .money { moneyFields }
                    if kind == .weight { TextField("体重（kg）", text: $amount).keyboardType(.decimalPad).disabled(fromHealth).accessibilityIdentifier("entry-amount") }
                    if kind == .exercise { exerciseFields }
                    if kind == .event {
                        Toggle("全天事项", isOn: $allDay)
                        DatePicker("开始", selection: $date, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                        if !allDay { DatePicker("结束", selection: $end) }
                        else { Text("没有具体时刻时，记录在所选日期的全天日程中。").font(.caption).foregroundStyle(.secondary) }
                    }
                    else { DatePicker("日期", selection: $date, displayedComponents: kind == .money ? [.date, .hourAndMinute] : [.date]).disabled(fromHealth) }
                    if [.task, .event, .exercise].contains(kind) { TextField(kind == .exercise ? "健身动作、组数、重量（可选）" : "备注（可选）", text: $notes, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("entry-notes") }
                    if fromHealth { Text(kind == .exercise ? "运动来自苹果健康，可在这里补充动作备注。其他内容请在健康 App 中修改。" : "体重来自苹果健康，请在健康 App 中修改。").font(.caption).foregroundStyle(.secondary) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("entry-error") } }
                if request.sms != nil { Section { Button("忽略这条账单", role: .destructive) { ignoreSMS() } } }
                else if editing && !fromHealth { Section { Button("删除记录", role: .destructive) { deleting = true }.accessibilityIdentifier("entry-delete") } }
            }.navigationTitle(sheetTitle).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("entry-cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button(request.sms == nil ? "保存" : "确认保存") { save() }.disabled(kind == .weight && fromHealth).accessibilityIdentifier("entry-save") }
                }
                .alert("删除这条记录？", isPresented: $deleting) { Button("删除", role: .destructive) { remove() }; Button("取消", role: .cancel) {} } message: { Text(deletionDetail) }
        }.presentationDragIndicator(.visible).onAppear { load() }
    }
    private var moneyFields: some View {
        Group {
            Picker("类型", selection: $transactionKind) { ForEach(TransactionKind.allCases) { Text($0.label).tag($0) } }
            TextField("金额（元）", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("entry-amount")
            Picker("分类", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
            Picker("渠道", selection: Binding(get: { source }, set: { source = $0; affectsBankBalance = ["银行卡", "工行储蓄卡"].contains($0) })) { ForEach(Array(Set(["微信", "支付宝", "银行卡", "工行储蓄卡", "现金", "其他", source])).sorted(), id: \.self) { Text($0).tag($0) } }
            Toggle("计入工行卡余额", isOn: $affectsBankBalance).accessibilityIdentifier("entry-affects-bank")
            if affectsBankBalance && transactionKind == .transfer {
                Picker("转移方向", selection: $transferToBank) { Text("从银行卡转出").tag(false); Text("转入银行卡").tag(true) }
            }
            if let balance = request.sms?.bankBalanceAfterCents ?? request.money?.bankBalanceAfterCents {
                LabeledContent("银行报告的交易后余额", value: "¥ \(MoneyMath.display(balance))")
            }
        }
    }
    private var exerciseFields: some View {
        Group {
            Picker("运动", selection: $exerciseType) { ForEach(Array(Set(["力量训练", "跑步", "步行", "骑行", "游泳", "瑜伽", "其他运动", exerciseType])).sorted(), id: \.self) { Text($0).tag($0) } }.disabled(fromHealth)
            TextField("运动时长（分钟）", text: $amount).keyboardType(.decimalPad).disabled(fromHealth).accessibilityIdentifier("entry-amount")
        }
    }
    private var deletionDetail: String {
        if request.task?.reminderID != nil { return "这也会删除苹果提醒事项中对应的待办。" }
        if request.event?.eventID != nil { return "这也会删除苹果日历中的这次日程。" }
        return "如需恢复，可重新录入或导入先前保存的备份。"
    }
    private func load() {
        guard !loaded else { return }; loaded = true; date = request.initialDate; end = date.addingTimeInterval(3_600)
        if let value = request.money ?? request.sms?.draft { title = value.title; date = value.date; amount = String(format: "%.2f", Double(value.cents) / 100); category = value.category; source = value.source; transactionKind = value.kind; affectsBankBalance = BankBalanceMath.direction(for: value) != .excluded; transferToBank = BankBalanceMath.direction(for: value) == .credit }
        else if let sms = request.sms { date = sms.receivedAt; category = "待分类"; source = "工行储蓄卡"; affectsBankBalance = true }
        if let value = request.task { title = value.title; date = value.date; notes = value.notes }
        if let value = request.event { title = value.title; date = value.start; end = value.end; notes = value.notes; allDay = value.isAllDay }
        if let value = request.weight { date = value.date; amount = String(format: "%.2f", value.kilograms) }
        if let value = request.exercise { date = value.date; amount = String(format: "%.1f", value.minutes); exerciseType = value.title; notes = value.actions }
    }
    private func save() {
        do {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if [.task, .event, .money].contains(kind), name.isEmpty { throw AppFailure.message("请输入名称") }
            switch kind {
            case .money:
                var value = request.money ?? request.sms?.draft ?? MoneyRecord(date: date, kind: transactionKind, cents: 1, title: name, category: category, source: source)
                value.date = date; value.kind = transactionKind; value.cents = try MoneyMath.parse(amount); value.title = name; value.category = category; value.source = source
                value.bankDirection = !affectsBankBalance ? .excluded : ([.income, .refund].contains(transactionKind) || (transactionKind == .transfer && transferToBank) ? .credit : .debit)
                if let sms = request.sms { try store.reviewSMS(sms, record: value) } else if request.money != nil { try store.updateMoney(value) } else { try store.addMoney(value) }
            case .task:
                var value = request.task ?? PlanTask(title: name, date: date); value.title = name; value.date = date; value.notes = notes
                if request.task != nil { try store.updateTask(value) } else { try store.addTask(value) }
            case .event:
                if allDay { date = Calendar.current.startOfDay(for: date); end = Calendar.current.date(byAdding: .day, value: 1, to: date)! }
                guard end > date else { throw AppFailure.message("结束时间应晚于开始时间") }
                var value = request.event ?? PlanEvent(title: name, start: date, end: end); value.title = name; value.start = date; value.end = end; value.notes = notes; value.allDay = allDay
                if request.event != nil { try store.updateEvent(value) } else { try store.addEvent(value) }
            case .weight:
                guard let kg = Double(amount), kg.isFinite, (1...500).contains(kg) else { throw AppFailure.message("请输入 1–500 kg 范围内的体重") }
                var value = request.weight ?? WeightRecord(date: date, kilograms: kg, source: "手动"); value.date = date; value.kilograms = kg
                if request.weight != nil { try store.updateWeight(value) } else { try store.addWeight(value) }
            case .exercise:
                guard let minutes = Double(amount), minutes.isFinite, minutes > 0, minutes <= (fromHealth ? 525_600 : 1_440) else { throw AppFailure.message("运动时长应大于 0；手动记录最多 1440 分钟") }
                var value = request.exercise ?? ExerciseRecord(date: date, title: exerciseType, minutes: minutes, source: "手动"); value.date = date; value.title = exerciseType; value.minutes = minutes; value.actions = notes
                if request.exercise != nil { try store.updateExercise(value) } else { try store.addExercise(value) }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func ignoreSMS() { do { if let sms = request.sms { try store.reviewSMS(sms, record: nil) }; dismiss() } catch { self.error = error.localizedDescription } }
    private func remove() {
        do {
            if let value = request.money { try store.deleteMoney(value) }; if let value = request.task { try store.deleteTask(value) }; if let value = request.event { try store.deleteEvent(value) }; if let value = request.weight { try store.deleteWeight(value) }; if let value = request.exercise { try store.deleteExercise(value) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
