import SwiftUI

@MainActor struct ScheduleAssistantSheet: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    var onSaved: (Date) -> Void
    @State private var input = ""
    @State private var syncCalendar = true
    @State private var configuration = PlannerAPIConfiguration()
    @State private var busy = false
    @State private var error: String?
    @State private var result: ScheduleReceptionResult?
    @State private var work: Task<Void, Never>?
    @AppStorage("schedule-default-minutes") private var durationMinutes = 60
    @State private var cachedInput = ""
    @State private var cachedEvents: [PlanEvent] = []
    @State private var provenance = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("说说今天的安排") {
                    Text("点输入框，用键盘麦克风口述，也可直接输入。未说日期默认今天；未说具体时刻记为全天事项。").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $input).frame(minHeight: 150).focused($focused).disabled(busy).accessibilityIdentifier("schedule-input")
                    Text("例如：明天下午三点健身；去买菜。简单表达本地识别，复杂表达再调用模型，每次最多 1200 字，模型识别最多 8 项。").font(.caption).foregroundStyle(.secondary)
                    Stepper("未说结束时间：默认 \(durationMinutes) 分钟", value: $durationMinutes, in: 15...180, step: 15).disabled(busy)
                    Toggle("同步苹果日历", isOn: $syncCalendar).disabled(busy).accessibilityIdentifier("schedule-sync-calendar")
                    Text("时间可在计划中修改。相同安排自动去重；再次点击记录可重试日历同步，无需重复调用模型。").font(.caption).foregroundStyle(.secondary)
                }
                if busy { Section { ProgressView("正在识别并保存安排…") } }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("schedule-error") } }
                if let result {
                    Section("记录结果") {
                        Text(provenance).font(.caption).foregroundStyle(.secondary)
                        Text("新增 \(result.addedCount) 项安排").accessibilityIdentifier("schedule-added-count")
                        Text("已同步苹果日历 \(result.syncedCount) 项").font(.subheadline)
                        if syncCalendar && result.pendingSyncCount > 0 {
                            Text("\(result.pendingSyncCount) 项已本地保存，日历同步未完成。请检查日历授权与默认日历；可以再次点击记录重试，也可在计划页同步本地计划。").font(.caption).foregroundStyle(.orange)
                        }
                        if result.addedCount == 0 { Text("相同安排已存在，已自动跳过重复记录。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(result.events) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.title).font(.headline)
                                Text(event.isAllDay ? "\(event.start.formatted(date: .abbreviated, time: .omitted)) · 全天" : "\(event.start.formatted(date: .abbreviated, time: .shortened)) — \(event.end.formatted(date: .abbreviated, time: .shortened))").font(.subheadline).foregroundStyle(.secondary)
                                if !event.notes.isEmpty { Text(event.notes).font(.caption).foregroundStyle(.secondary) }
                                if let location = event.location, !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("口述日程").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy).accessibilityIdentifier("schedule-close") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("记录") { record() }
                            .disabled(busy || store.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("识别并记录安排").accessibilityIdentifier("schedule-record")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成输入") { focused = false }
                    }
                }
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
                    #endif
                    do { configuration = try PlannerCredentials.load() }
                    catch { self.error = error.localizedDescription }
                }
                .onDisappear { work?.cancel() }
        }
    }

    private func record() {
        focused = false; busy = true; error = nil; result = nil
        let text = input, shouldSync = syncCalendar
        let config = configuration
        let duration = min(180, max(15, durationMinutes))
        let cacheKey = "\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)|\(duration)|\(text)"
        work = Task {
            defer { busy = false }
            do {
                let events: [PlanEvent]
                guard text.count <= 1200 else { throw AppFailure.message("每次最多输入 1200 字，请分批记录。") }
                if cachedInput == cacheKey, !cachedEvents.isEmpty { events = cachedEvents; provenance = "复用上次识别 · 本次未调用模型" }
                else if let local = try? ScheduleIntake.flexibleLocal(text, durationMinutes: duration) {
                    events = local; provenance = "本地识别 · 未调用模型"
                } else if !config.modelKey.isEmpty && !config.model.isEmpty {
                    let client = PlannerNetworking(configuration: config)
                    events = try await client.understandSchedule(text, durationMinutes: duration)
                    if let tokens = await client.lastModelTokens { provenance = "模型识别 · 本次 \(tokens) tokens" }
                    else { provenance = "模型识别 · 服务未返回用量" }
                } else { events = try ScheduleIntake.flexibleLocal(text, durationMinutes: duration) }
                cachedInput = cacheKey; cachedEvents = events
                try Task.checkCancellation()
                let saved = try await store.addSpokenSchedule(events, syncCalendar: shouldSync)
                result = saved
                if let first = saved.events.first { onSaved(first.start) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
