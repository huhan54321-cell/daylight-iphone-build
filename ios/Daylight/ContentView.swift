import SwiftUI
import EventKit

private enum AppPage: String, CaseIterable { case today = "今天", finance = "账本", plan = "计划", health = "运动", settings = "设置" }
struct ContentView: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @State private var page: AppPage = ContentView.initialPage
    @State private var entry: EntryRequest?
    private static var initialPage: AppPage {
        #if DEBUG && targetEnvironment(simulator)
        // Launch directly into a read-only page for CI screenshots, avoiding URL confirmation dialogs.
        let arguments = ProcessInfo.processInfo.arguments
        let pages: [String: AppPage] = ["today": .today, "finance": .finance, "plan": .plan, "health": .health, "settings": .settings]
        if let index = arguments.firstIndex(of: "--capture-tab"), arguments.indices.contains(index + 1), let selected = pages[arguments[index + 1]] { return selected }
        #endif
        return .today
    }
    var body: some View {
        TabView(selection: $page) {
            screen(.today).tabItem { Label("今天", systemImage: "sun.max") }.tag(AppPage.today)
            screen(.finance).tabItem { Label("账本", systemImage: "wallet.pass") }.tag(AppPage.finance)
            screen(.plan).tabItem { Label("计划", systemImage: "calendar") }.tag(AppPage.plan)
            screen(.health).tabItem { Label("运动", systemImage: "waveform.path.ecg") }.tag(AppPage.health)
            screen(.settings).tabItem { Label("设置", systemImage: "gearshape") }.tag(AppPage.settings)
        }.tint(.blue).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .sheet(item: $entry) { EntrySheet(request: $0) }
            .alert("日常", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("知道了") { store.message = nil } } message: { Text(store.message ?? "") }
            .task { await store.refreshPlans() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { store.reloadLocal(); Task { await store.refreshPlans() } } }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await store.refreshPlans(center: store.apple.calendarFocus) } }
            .onOpenURL { url in
                guard url.scheme == "daylight", url.host == "tab" else { return }
                let pages: [String: AppPage] = ["today": .today, "finance": .finance, "plan": .plan, "health": .health, "settings": .settings]
                if let selected = pages[url.lastPathComponent] { page = selected }
            }
    }
    private func screen(_ selected: AppPage) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selected {
                    case .today: TodayModule(entry: $entry)
                    case .finance: FinanceModule(entry: $entry)
                    case .plan: PlanModule(entry: $entry)
                    case .health: HealthModule(entry: $entry)
                    case .settings: SettingsModule()
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).background(Color(uiColor: .systemGroupedBackground)).navigationTitle(selected.rawValue)
                .toolbar {
                    if selected != .settings {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("记一笔", systemImage: "wallet.pass") { entry = EntryRequest(kind: .money) }.accessibilityIdentifier("menu-action-money")
                                Button("添加待办", systemImage: "checklist") { entry = EntryRequest(kind: .task) }.accessibilityIdentifier("menu-action-task")
                                Button("安排日程", systemImage: "calendar.badge.plus") { entry = EntryRequest(kind: .event) }.accessibilityIdentifier("menu-action-event")
                                Button("记录体重", systemImage: "scalemass") { entry = EntryRequest(kind: .weight) }.accessibilityIdentifier("menu-action-weight")
                                Button("记录运动", systemImage: "figure.strengthtraining.traditional") { entry = EntryRequest(kind: .exercise) }.accessibilityIdentifier("menu-action-exercise")
                            } label: { Image(systemName: "plus").font(.title3).padding(7) }.accessibilityLabel("新增记录").accessibilityIdentifier("add-record")
                        }
                    }
                }
        }
    }
}
struct TodayModule: View {
    @EnvironmentObject private var store: AssistantStore
    @Binding var entry: EntryRequest?
    @State private var showCareer = false
    private var records: [MoneyRecord] { store.data.transactions.filter { Calendar.current.isDateInToday($0.date) } }
    private var tasks: [PlanTask] { store.data.tasks.filter { Calendar.current.isDateInToday($0.date) }.sorted { !$0.completed && $1.completed } }
    private var pendingCount: Int { store.data.smsInbox.filter { $0.status == .pending }.count }
    var body: some View {
        Text(Date().formatted(.dateTime.month(.wide).day().weekday(.wide))).font(.subheadline).foregroundStyle(.secondary)
        Button { showCareer = true } label: {
            SoftCard {
                HStack {
                    Image(systemName: "sparkle.magnifyingglass").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) { Text("求职与具身").font(.headline); Text("精选岗位 · 公司介绍 · 具身观察").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("open-career")
            .navigationDestination(isPresented: $showCareer) { CareerModule() }
            .task {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--capture-career") }) { showCareer = true }
                #endif
            }
        ModuleSection(title: "收支概览") {
            SoftCard {
                Text("今天已记录净支出").font(.subheadline).foregroundStyle(.secondary)
                Text("¥ \(MoneyMath.display(MoneyMath.netExpense(records)))").font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit().accessibilityIdentifier("today-net-expense")
                Divider()
                HStack { SmallMetric(title: "收入", value: "¥ \(MoneyMath.display(MoneyMath.sum(records, kind: .income)))"); Spacer(); SmallMetric(title: "记录", value: "\(records.count) 笔", valueIdentifier: "today-record-count") }
                if pendingCount > 0 { Label("\(pendingCount) 条账单待确认", systemImage: "tray").font(.caption).foregroundStyle(.orange) }
                Text("显示已记录收支 · 账户转移不计消费").font(.caption).foregroundStyle(.secondary)
            }
        }
        ModuleSection(title: "今天的计划") {
            SoftCard {
                if tasks.isEmpty && store.data.events.on(Date()).isEmpty { EmptyRecords(title: "今天，想做点什么？", icon: "checklist") }
                ForEach(tasks) { value in PlanTaskRow(value: value) { entry = EntryRequest(kind: .task, task: value) } }
                ForEach(store.data.events.on(Date())) { value in PlanEventRow(value: value) { entry = EntryRequest(kind: .event, event: value) } }
                Button("添加待办", systemImage: "plus") { entry = EntryRequest(kind: .task) }.font(.subheadline)
            }
        }
        ModuleSection(title: "照顾自己") {
            HStack(alignment: .top, spacing: 12) {
                SoftCard { SmallMetric(title: "最近体重", value: store.data.weights.max(by: { $0.date < $1.date }).map { String(format: "%.1f kg", $0.kilograms) } ?? "— kg", valueIdentifier: "today-latest-weight") }.frame(maxWidth: .infinity)
                SoftCard { SmallMetric(title: "今日运动", value: "\(Int(store.data.workouts.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.minutes })) 分钟", valueIdentifier: "today-workout-minutes") }.frame(maxWidth: .infinity)
            }
        }
    }
}
