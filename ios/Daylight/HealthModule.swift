import SwiftUI
import Charts

struct HealthModule: View {
    @EnvironmentObject private var store: AssistantStore
    @Binding var entry: EntryRequest?
    @State private var days = 90
    private var start: Date { Calendar.current.date(byAdding: .day, value: -days, to: Date())! }
    private var weights: [WeightRecord] { store.data.weights.filter { $0.date >= start }.sorted { $0.date < $1.date } }
    private var workouts: [ExerciseRecord] { store.data.workouts.filter { $0.date >= start }.sorted { $0.date > $1.date } }
    private var latest: WeightRecord? { store.data.weights.max { $0.date < $1.date } }
    var body: some View {
        Picker("查看范围", selection: $days) { Text("近 7 天").tag(7); Text("近 30 天").tag(30); Text("近 90 天").tag(90); Text("全部").tag(36_500) }.pickerStyle(.segmented)
        ModuleSection(title: "体重") {
            SoftCard {
                HStack { VStack(alignment: .leading, spacing: 4) { Text(latest.map { String(format: "%.1f kg", $0.kilograms) } ?? "— kg").font(.system(size: 36, weight: .semibold, design: .rounded)); if let latest { Text("\(latest.date.formatted(date: .abbreviated, time: .omitted)) · \(latest.source)").font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button("记录") { entry = EntryRequest(kind: .weight) } }
                if weights.count > 1 { Chart(weights) { point in LineMark(x: .value("日期", point.date), y: .value("kg", point.kilograms)).foregroundStyle(.blue); PointMark(x: .value("日期", point.date), y: .value("kg", point.kilograms)).foregroundStyle(.blue) }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 150).accessibilityLabel("体重趋势，单位千克") }
                else { Text("记录两次后，查看体重变化。").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("体重记录 · \(weights.count)") {
                    ForEach(weights.reversed()) { value in Button { entry = EntryRequest(kind: .weight, weight: value) } label: { HStack { VStack(alignment: .leading, spacing: 3) { Text(value.date.formatted(date: .abbreviated, time: .omitted)); Text(value.source).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(String(format: "%.1f kg", value.kilograms)).monospacedDigit() }.font(.subheadline).padding(.vertical, 5) }.buttonStyle(.plain) }
                }.font(.subheadline)
            }
        }
        ModuleSection(title: "运动") {
            SoftCard { HStack { SmallMetric(title: "运动次数", value: "\(workouts.count) 次"); Spacer(); SmallMetric(title: "运动时长", value: "\(Int(workouts.reduce(0) { $0 + $1.minutes })) 分钟") }; Button("记录运动与健身动作", systemImage: "plus") { entry = EntryRequest(kind: .exercise) } }
            SoftCard {
                if workouts.isEmpty { EmptyRecords(title: "慢慢来，每一次运动都算数", icon: "figure.walk") }
                ForEach(workouts) { value in
                    Button { entry = EntryRequest(kind: .exercise, exercise: value) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) { Text(value.title).foregroundStyle(.primary); Text("\(value.date.formatted(date: .abbreviated, time: .omitted)) · \(value.source)").font(.caption).foregroundStyle(.secondary); if !value.actions.isEmpty { Text(value.actions).font(.caption).foregroundStyle(.secondary) } }
                            Spacer(); Text("\(Int(value.minutes)) 分钟").font(.subheadline).foregroundStyle(.primary).monospacedDigit()
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }
        }
        SoftCard {
            Button("读取苹果健康", systemImage: "heart") { Task { await store.readHealth() } }.disabled(store.busy)
            Text("按需读取最近 90 天的运动与体重，包括 Apple Watch 已写入健康的运动。点已有运动可补充健身动作；手动体重暂不写回健康。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
