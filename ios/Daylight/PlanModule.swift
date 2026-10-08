import SwiftUI

struct PlanModule: View {
    @EnvironmentObject private var store: AssistantStore
    @Binding var entry: EntryRequest?
    @State private var date = Date()
    @State private var showCompleted = true
    @State private var showSpokenSchedule = false
    private var tasks: [PlanTask] { store.data.tasks.filter { Calendar.current.isDate($0.date, inSameDayAs: date) && (showCompleted || !$0.completed) }.sorted { !$0.completed && $1.completed } }
    private var month: Date { Calendar.current.dateInterval(of: .month, for: date)!.start }
    private var days: [Date] {
        let offset = (Calendar.current.component(.weekday, from: month) + 5) % 7
        let start = Calendar.current.date(byAdding: .day, value: -offset, to: month)!
        return (0..<42).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! }
    }
    var body: some View {
        PlannerOverview(initialDate: date)
        SoftCard {
            Button("口述日程", systemImage: "mic.fill") { showSpokenSchedule = true }.accessibilityIdentifier("plan-spoken-schedule")
            Text("说出今天或明天的安排，识别时间后记录，并同步苹果日历。").font(.caption).foregroundStyle(.secondary)
        }
        SoftCard {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").padding(7) }.accessibilityLabel("上个月")
                Spacer(); Text(date.formatted(.dateTime.year().month(.wide))).font(.headline); Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right").padding(7) }.accessibilityLabel("下个月")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 8) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(days, id: \.self) { value in dayCell(value) }
            }
            HStack { Label("待办", systemImage: "circle.fill").foregroundStyle(.blue); Label("日程", systemImage: "circle.fill").foregroundStyle(.green); Spacer(); Button("今天") { date = Date() } }.font(.caption)
        }
        ModuleSection(title: date.formatted(.dateTime.month().day().weekday(.wide))) {
            SoftCard {
                Toggle("显示已完成", isOn: $showCompleted).font(.subheadline)
                if tasks.isEmpty { EmptyRecords(title: "这一天，还没有待办", icon: "checklist") }
                ForEach(tasks) { value in PlanTaskRow(value: value) { entry = EntryRequest(kind: .task, task: value) } }
                Button("添加待办", systemImage: "plus") { entry = EntryRequest(kind: .task, initialDate: date) }
            }
        }
        ModuleSection(title: "日程安排") {
            SoftCard {
                if store.data.events.on(date).isEmpty { EmptyRecords(title: "留一点时间，给想做的事", icon: "calendar") }
                ForEach(store.data.events.on(date)) { value in PlanEventRow(value: value) { entry = EntryRequest(kind: .event, event: value) } }
                Button("安排日程", systemImage: "plus") { entry = EntryRequest(kind: .event, initialDate: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date)!) }
            }
        }
        SoftCard {
            Button(store.apple.calendarAvailable ? "刷新苹果日历" : "连接苹果日历", systemImage: "calendar") { Task { if store.apple.calendarAvailable { await store.refreshPlans(center: date) } else { await store.connectCalendar() } } }
            Button(store.apple.remindersAvailable ? "刷新提醒事项" : "连接提醒事项", systemImage: "checklist") { Task { if store.apple.remindersAvailable { await store.refreshPlans(center: date) } else { await store.connectReminders() } } }
            Button("同步此前本地保存的计划", systemImage: "arrow.up.circle") { Task { await store.syncLocalPlans() } }.font(.subheadline)
            Text("连接后读取已有安排，新增、编辑和完成状态会写回对应应用。删除同步记录也会删除对应的苹果安排；重复日程只操作这一次。").font(.caption).foregroundStyle(.secondary)
        }.disabled(store.busy)
        .onChange(of: month) { _, _ in Task { await store.refreshPlans(center: date) } }
        .sheet(isPresented: $showSpokenSchedule) { ScheduleAssistantSheet { savedDate in date = savedDate } }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--capture-schedule") { showSpokenSchedule = true }
            #endif
        }
    }
    private func dayCell(_ value: Date) -> some View {
        let selected = Calendar.current.isDate(value, inSameDayAs: date)
        let inMonth = Calendar.current.isDate(value, equalTo: date, toGranularity: .month)
        let hasTasks = store.data.tasks.contains { Calendar.current.isDate($0.date, inSameDayAs: value) && !$0.completed }
        let hasEvents = !store.data.events.on(value).isEmpty
        return Button { date = value } label: {
            VStack(spacing: 4) {
                Text("\(Calendar.current.component(.day, from: value))").font(.subheadline.weight(selected ? .semibold : .regular)).foregroundStyle(selected ? Color.white : inMonth ? Color.primary : Color.secondary)
                HStack(spacing: 3) { Circle().fill(hasTasks ? (selected ? Color.white : Color.blue) : Color.clear).frame(width: 4, height: 4); Circle().fill(hasEvents ? (selected ? Color.white : Color.green) : Color.clear).frame(width: 4, height: 4) }
            }.frame(maxWidth: .infinity).frame(minHeight: 38).background(selected ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { if Calendar.current.isDateInToday(value) && !selected { RoundedRectangle(cornerRadius: 12).stroke(.blue.opacity(0.4), lineWidth: 1) } }
        }.buttonStyle(.plain).accessibilityLabel("\(value.formatted(date: .complete, time: .omitted))，\(hasTasks ? "有待办" : "")\(hasEvents ? "有日程" : "")")
    }
    private func changeMonth(_ direction: Int) { date = Calendar.current.date(byAdding: .month, value: direction, to: month)! }
}
