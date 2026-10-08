import SwiftUI
import UniformTypeIdentifiers

enum EntryKind: String, Identifiable { case task, event, money, weight, exercise; var id: String { rawValue } }
struct EntryRequest: Identifiable {
    var id = UUID()
    var kind: EntryKind
    var initialDate = Date()
    var money: MoneyRecord? = nil
    var task: PlanTask? = nil
    var event: PlanEvent? = nil
    var weight: WeightRecord? = nil
    var exercise: ExerciseRecord? = nil
    var sms: BankMessage? = nil
}
struct SoftCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 14) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
}
struct ModuleSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.title3.weight(.semibold)); content } }
}
struct EmptyRecords: View {
    var title: String; var icon: String
    var body: some View { VStack(spacing: 10) { Image(systemName: icon).font(.title2).foregroundStyle(.blue); Text(title).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 16) }
}
struct SmallMetric: View {
    var title: String; var value: String; var valueIdentifier = ""
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline).monospacedDigit().accessibilityIdentifier(valueIdentifier) } }
}
struct PlanTaskRow: View {
    @EnvironmentObject private var store: AssistantStore
    var value: PlanTask; var edit: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button { store.toggleTask(value) } label: { Image(systemName: value.completed ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(value.completed ? Color.blue : Color.secondary) }.buttonStyle(.plain).accessibilityLabel(value.completed ? "取消完成" : "完成").accessibilityIdentifier("task-complete-\(value.title)").accessibilityValue(value.completed ? "completed" : "pending")
            Button(action: edit) { VStack(alignment: .leading, spacing: 4) { Text(value.title).strikethrough(value.completed).foregroundStyle(value.completed ? Color.secondary : Color.primary); if !value.notes.isEmpty { Text(value.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).accessibilityIdentifier("task-edit-\(value.title)")
        }.padding(.vertical, 5)
    }
}
struct PlanEventRow: View {
    var value: PlanEvent; var edit: () -> Void
    var body: some View {
        Button(action: edit) {
            HStack(alignment: .top, spacing: 12) {
                Text(value.isAllDay ? "全天" : value.start.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.medium)).foregroundStyle(.blue).frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) { Text(value.title).foregroundStyle(.primary); Text(value.isAllDay ? "时间待安排" : "至 \(value.end.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary); if !value.notes.isEmpty { Text(value.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(.subheadline).padding(.vertical, 5)
        }.buttonStyle(.plain).accessibilityIdentifier("plan-event-\(value.title)")
    }
}
struct JSONBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws { bytes = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
enum PeriodScope: String, CaseIterable, Identifiable {
    case day = "日", week = "周", month = "月"
    var id: String { rawValue }
    var component: Calendar.Component { switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month } }
    func interval(for date: Date) -> DateInterval { var calendar = Calendar.current; calendar.firstWeekday = 2; return calendar.dateInterval(of: component, for: date)! }
}
extension Array where Element == PlanEvent {
    func on(_ day: Date) -> [PlanEvent] { let start = Calendar.current.startOfDay(for: day); let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!; return filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start } }
}
