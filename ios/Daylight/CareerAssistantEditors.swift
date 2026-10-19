import SwiftUI

struct CareerProfileEditor: View {
    @ObservedObject var client: CareerAssistantClient
    let original: CareerAssistantJSON
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directions = ""
    @State private var cities = ""
    @State private var skills = ""
    @State private var year = ""
    @State private var days = ""
    @State private var months = ""
    @State private var start = ""
    @State private var enabled = true
    private func split(_ value: String) -> [String] { value.components(separatedBy: CharacterSet(charactersIn: "，,、\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var body: some View {
        Form {
            Section("求职方向") { TextField("档案名称", text: $name); TextField("方向，以逗号分隔", text: $directions); TextField("优先城市", text: $cities); TextField("真实技能", text: $skills); Toggle("纳入每日发现", isOn: $enabled) }
            Section("实习条件（可留空）") { TextField("毕业年份", text: $year).keyboardType(.numberPad); TextField("每周可到岗天数", text: $days).keyboardType(.numberPad); TextField("可实习月数", text: $months).keyboardType(.numberPad); TextField("到岗日期 YYYY-MM-DD", text: $start) }
            Button("保存目标") { Task { let body: [String: Any] = ["id": original.id.isEmpty ? UUID().uuidString.lowercased() : original.id, "name": name, "directions": split(directions), "cities": split(cities), "skills": split(skills), "graduationYear": year, "days": days, "months": months, "startDate": start, "enabled": enabled]; if await client.send("profiles", body: body) != nil { dismiss() } } }.disabled(!client.online || name.isEmpty || directions.isEmpty)
            if let message = client.message { Text(message).foregroundStyle(.orange) }
        }.navigationTitle("目标档案").onAppear {
            name = original["name"].string; directions = original["directions"].strings.joined(separator: "、"); cities = original["cities"].strings.joined(separator: "、"); skills = original["skills"].strings.joined(separator: "、")
            year = original["graduationYear"].int == 0 ? "" : String(original["graduationYear"].int); days = original["days"].int == 0 ? "" : String(original["days"].int); months = original["months"].int == 0 ? "" : String(original["months"].int); start = original["startDate"].string; enabled = original.id.isEmpty || original["enabled"].bool
        }
    }
}

