import SwiftUI
import PhotosUI

private struct BankImportRow: Identifiable {
    var message: BankMessage
    var selected: Bool
    var id: UUID { message.id }
}

struct BankScreenshotImportSheet: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    var manualSMS = false
    var manualNotification = false
    @State private var notificationTitle = "动账通知"
    @State private var photos: [PhotosPickerItem] = []
    @State private var rows: [BankImportRow] = []
    @State private var notices: [String] = []
    @State private var input = ""
    @State private var error: String?
    @State private var busy = false
    @State private var progress = ""
    @State private var editing: BankMessage?
    @State private var confirmDuplicates = false
    @State private var processingTask: Task<Void, Never>?
    @FocusState private var smsInputFocused: Bool
    private var selected: [BankMessage] { rows.filter(\.selected).map(\.message) }
    private var possibleDuplicates: Set<UUID> {
        Set(selected.filter { duplicateForReview($0).level == .possible }.map(\.id))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if manualSMS || manualNotification {
                        Text(manualNotification ? "粘贴工行 App 的完整动账通知正文。仅识别标题为动账通知的交易，活动和优惠通知不会入账。" : "粘贴漏记的完整工行交易短信。先识别并核对，再保存。").font(.subheadline)
                        if manualNotification {
                            TextField("通知标题", text: $notificationTitle).accessibilityIdentifier("bank-notification-title")
                            Text("没有余额的通知会按收支更新已设置的起始余额，显示为估算余额。").font(.caption).foregroundStyle(.secondary)
                        }
                        TextEditor(text: $input).frame(minHeight: 130).textInputAutocapitalization(.never).autocorrectionDisabled().focused($smsInputFocused).accessibilityIdentifier(manualNotification ? "bank-notification-input" : "bank-sms-input")
                        Button("清空正文", systemImage: "xmark.circle") {
                            smsInputFocused = false; input = ""; rows = []; notices = []; error = nil
                        }.disabled(busy || input.isEmpty).accessibilityIdentifier("bank-input-clear")
                    } else {
                        Text("选择微信工行「动账交易提醒」截图。每张可以包含多笔；需完整显示卡尾号、交易时间、类型、金额和余额。").font(.subheadline)
                        PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) {
                            Label("选择截图（最多 20 张）", systemImage: "photo.on.rectangle.angled")
                        }.disabled(busy)
                        Text("在手机本地识别，不上传图片。只能补录所选截图中完整可见的交易。").font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { HStack { ProgressView(); Text(progress).font(.subheadline) } }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("bank-import-error") } }
                if !notices.isEmpty {
                    Section("识别提示") { ForEach(Array(notices.enumerated()), id: \.offset) { _, text in Text(text).font(.footnote).foregroundStyle(.secondary) } }
                }
                if !rows.isEmpty {
                    Section("逐笔核对 · 已选择 \(selected.count) 笔") {
                        ForEach($rows) { $row in
                            let duplicate = duplicateForReview(row.message)
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $row.selected) {
                                    if let record = row.message.draft {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(record.title).lineLimit(3)
                                                Text("\(record.date.formatted(.dateTime.month().day().hour().minute())) · \(record.kind.label)").font(.caption).foregroundStyle(.secondary)
                                                if let tail = record.bankAccountTail { Text("工行卡尾号 \(tail)").font(.caption).foregroundStyle(.secondary) }
                                            }
                                            Spacer()
                                            Text("¥ \(MoneyMath.display(record.cents))").monospacedDigit()
                                        }
                                    }
                                }.disabled(duplicate.level == .exact || busy).accessibilityIdentifier("bank-row-select-\(rows.firstIndex(where: { $0.id == row.id }) ?? -1)")
                                if let balance = row.message.bankBalanceAfterCents { Text("交易后余额 ¥ \(MoneyMath.display(balance))").font(.caption).foregroundStyle(.secondary) }
                                if duplicate.level != .none { Text(duplicate.reason).font(.caption).foregroundStyle(.orange) }
                                if duplicate.level == .possible { Text("仅在确认是另一笔交易时选中。").font(.caption).foregroundStyle(.orange) }
                                ForEach(row.message.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                                Button("修改金额、日期或分类") { editing = row.message }.font(.subheadline).disabled(busy || duplicate.level == .exact).accessibilityIdentifier("bank-row-edit-\(rows.firstIndex(where: { $0.id == row.id }) ?? -1)")
                            }.padding(.vertical, 5)
                        }
                    }
                    Section {
                        Button("确认保存 \(selected.count) 笔") {
                            if possibleDuplicates.isEmpty { save() } else { confirmDuplicates = true }
                        }.disabled(busy || selected.isEmpty).accessibilityIdentifier("bank-import-confirm")
                        Text("请核对原文。识别可能有误，未选择的记录不会保存；手动补录必须确认后保存。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle(manualNotification ? "补录动账通知" : manualSMS ? "补录银行短信" : "识别动账截图").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.accessibilityIdentifier("bank-import-close") }
                    if manualSMS || manualNotification {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("识别") { parseSMS() }
                                .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityLabel(manualNotification ? "识别通知" : "识别短信")
                                .accessibilityIdentifier(manualNotification ? "bank-notification-parse" : "bank-sms-parse")
                        }
                    }
                }
                .sheet(item: $editing) { message in
                    BankScreenshotRecordEditor(message: message) { changed in
                        if let index = rows.firstIndex(where: { $0.id == changed.id }) { rows[index].message = changed }
                    }
                }
                .alert("确认疑似重复的交易？", isPresented: $confirmDuplicates) {
                    Button("确认是另一笔并保存") { save(allowDuplicates: true) }
                    Button("返回核对", role: .cancel) {}
                } message: { Text("有 \(possibleDuplicates.count) 笔与已有记录的时间和金额相近。继续会增加新记录并影响收支与余额。") }
                .onChange(of: photos) { _, values in
                    guard !values.isEmpty else { return }
                    processingTask = Task { await recognize(values) }
                }
                .onDisappear { processingTask?.cancel() }
                .task { loadCapturePreview() }
        }.presentationDragIndicator(.visible)
    }
    @MainActor private func recognize(_ items: [PhotosPickerItem]) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        for (index, item) in items.enumerated() {
            guard !Task.isCancelled else { return }
            progress = "正在识别第 \(index + 1) / \(items.count) 张"
            do {
                guard let bytes = try await item.loadTransferable(type: Data.self) else { throw AppFailure.message("无法读取所选图片") }
                let result = try await BankScreenshotOCR.recognize(bytes)
                guard !Task.isCancelled else { return }
                let parsed = try BankScreenshotCore.parse(text: result.text, receivedAt: Date())
                notices += result.warnings.map { "第 \(index + 1) 张：\($0)" }
                notices += parsed.notices.map { "第 \(index + 1) 张：\($0)" }
                append(parsed.messages)
            } catch {
                guard !Task.isCancelled else { return }
                notices.append("第 \(index + 1) 张未识别：\(error.localizedDescription)")
            }
        }
        photos = []
        if rows.isEmpty { error = "没有识别到完整交易。请截取清晰、完整的工行动账提醒后重试。" }
    }
    private func append(_ messages: [BankMessage]) {
        for message in messages {
            guard rows.count < 100 else {
                if !notices.contains("本批最多核对 100 笔，请保存后再选择剩余截图。") { notices.append("本批最多核对 100 笔，请保存后再选择剩余截图。") }
                break
            }
            guard !rows.contains(where: { $0.message.fingerprint == message.fingerprint }) else { continue }
            let duplicate = duplicateForReview(message)
            rows.append(BankImportRow(message: message, selected: duplicate.level == .none))
        }
    }
    private func duplicateForReview(_ message: BankMessage) -> BankScreenshotDuplicate {
        var prospective = store.data
        for earlier in rows {
            if earlier.id == message.id { break }
            guard earlier.selected else { continue }
            guard BankScreenshotCore.duplicate(for: earlier.message, in: prospective).level != .exact else { continue }
            prospective.smsInbox.append(earlier.message)
        }
        return BankScreenshotCore.duplicate(for: message, in: prospective)
    }
    private func parseSMS() {
        smsInputFocused = false
        error = nil
        do {
            let parsed = manualNotification
                ? try BankNotification.parse(title: notificationTitle, body: input, requestID: UUID().uuidString)
                : try BankSMS.parse(body: input, sender: "95588", requestID: UUID().uuidString)
            guard let message = parsed else { throw AppFailure.message(manualNotification ? "未识别为完整动账通知。请核对标题、尾号、时间和金额；活动、验证码及截断内容不会保存。" : "请粘贴包含【工商银行】的交易短信，不要粘贴验证码。") }
            guard message.draft != nil else { throw AppFailure.message(message.reason) }
            append([message]); input = ""
        } catch { self.error = error.localizedDescription }
    }
    private func save(allowDuplicates: Bool = false) {
        do {
            let result = try store.confirmBankReceipts(selected, allowingDuplicates: allowDuplicates ? possibleDuplicates : [])
            store.message = "已保存 \(result.count) 笔。" + (result.skippedCount > 0 ? "跳过 \(result.skippedCount) 笔已存在的记录。" : "")
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func loadCapturePreview() {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--capture-bank-review") || (args.contains("--ui-testing") && args.contains("--ui-test-bank-fixture")), rows.isEmpty else { return }
        let fixture = """
        中国工商银行客户服务
        动账交易提醒
        账号类型：尾号9999的借记卡
        交易时间：2026年8月12日18:11
        交易类型：缴费财付通-示例地铁
        交易金额：出账8.00人民币元
        账户余额：361.93人民币元
        中国工商银行客户服务
        动账交易提醒
        账号类型：尾号9999的借记卡
        交易时间：2026年8月12日18:14
        交易类型：消费财付通-示例商店
        交易金额：出账10.00人民币元
        账户余额：351.93人民币元
        """
        do {
            append(try BankScreenshotCore.parse(text: fixture, receivedAt: Date()).messages)
            notices = ["界面测试示例，未读取相册、未调用 OCR、不会自动保存。"]
        } catch { self.error = error.localizedDescription }
        #endif
    }
}

private struct BankScreenshotRecordEditor: View {
    var message: BankMessage
    var onSave: (BankMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amount = ""
    @State private var balance = ""
    @State private var date = Date()
    @State private var kind: TransactionKind = .expense
    @State private var category = "待分类"
    @State private var affectsBalance = true
    @State private var credit = false
    @State private var error: String?
    private let categories = ["待分类", "餐饮", "交通", "购物", "居住", "运动", "娱乐", "工资", "账户转移", "其他"]
    var body: some View {
        NavigationStack {
            Form {
                Section("核对记录") {
                    TextField("商户或名称", text: $title).accessibilityIdentifier("bank-edit-title")
                    TextField("交易金额（元）", text: $amount).keyboardType(.decimalPad).accessibilityIdentifier("bank-edit-amount")
                    DatePicker("交易时间", selection: $date)
                    Picker("类型", selection: $kind) { ForEach(TransactionKind.allCases) { Text($0.label).tag($0) } }
                    Picker("分类", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                    Toggle("计入工行卡余额", isOn: $affectsBalance)
                    if affectsBalance {
                        TextField("交易后余额（元，可留空）", text: $balance).keyboardType(.numbersAndPunctuation)
                        if kind == .transfer { Toggle("转入银行卡", isOn: $credit) }
                    }
                    if let tail = message.draft?.bankAccountTail { Text("卡尾号 \(tail)").font(.caption).foregroundStyle(.secondary) }
                }
                Section("识别内容") { Text(message.body).font(.footnote) }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }.navigationTitle("核对账单").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { save() }.accessibilityIdentifier("bank-edit-save") }
                }.onAppear {
                    guard let record = message.draft else { return }
                    title = record.title; amount = String(format: "%.2f", Double(record.cents) / 100)
                    balance = message.bankBalanceAfterCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
                    date = record.date; kind = record.kind; category = record.category
                    affectsBalance = BankBalanceMath.direction(for: record) != .excluded
                    credit = BankBalanceMath.direction(for: record) == .credit
                }
        }
    }
    private func save() {
        do {
            guard var record = message.draft else { return }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw AppFailure.message("请输入名称") }
            record.title = name; record.cents = try MoneyMath.parse(amount); record.date = date; record.kind = kind; record.category = category
            record.bankDirection = !affectsBalance ? .excluded : ([.income, .refund].contains(kind) || (kind == .transfer && credit) ? .credit : .debit)
            let cleanBalance = balance.trimmingCharacters(in: .whitespacesAndNewlines)
            record.bankBalanceAfterCents = affectsBalance && !cleanBalance.isEmpty ? try MoneyMath.parseBalance(cleanBalance) : nil
            var changed = message; changed.draft = record; changed.bankBalanceAfterCents = record.bankBalanceAfterCents
            onSave(changed); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
