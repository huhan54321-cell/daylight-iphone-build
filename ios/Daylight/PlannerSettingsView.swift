import SwiftUI

@MainActor struct PlannerSettingsView: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = PlannerAPIConfiguration()
    @State private var city = "青岛"
    @State private var origin = ""
    @State private var mode = TravelMode.transit
    @State private var bufferMinutes = 15
    @State private var durationMinutes = 90
    @State private var error: String?
    @State private var loaded = false
    @State private var saving = false
    @State private var testing = false
    @State private var connectionResult: String?
    @State private var availableModels: [String] = []

    var body: some View {
        Form {
            if let error {
                Section(loaded ? "保存未完成" : "配置暂时无法读取") {
                    Text(error).foregroundStyle(.red).font(.subheadline)
                    if !loaded {
                        Text("请解锁手机后重新打开此页。读取成功前暂不保存，以免覆盖已有配置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("地图查询需要高德 Web 服务 Key。模型服务用于理解需求、比较真实路线并解释推荐；未配置模型时仍可手动填写并选择路线。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("模型会收到本次安排、必要偏好、路线估算和日程冲突数量；高德会收到地点查询和路线坐标。已有日程标题、账本、短信和健康记录不会随这些请求上传。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("地图服务") {
                SecureField("高德 Web 服务 Key", text: $configuration.amapKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("模型理解与路线分析 · 可选") {
                Button("使用 DeepSeek 官方配置") {
                    configuration.modelBaseURL = "https://api.deepseek.com"
                    configuration.model = "deepseek-flash"
                }.disabled(saving || testing)
                Text("DeepSeek 官方接口地址为 api.deepseek.com，当前模型示例 deepseek-flash；保留你填写的密钥。第三方渠道请填写该渠道地址和模型 ID。").font(.caption).foregroundStyle(.secondary)
                TextField("HTTPS 服务地址，如 …/v1", text: $configuration.modelBaseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型名称", text: $configuration.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("获取可用模型") { fetchModels() }.disabled(testing || saving || !loaded)
                if !availableModels.isEmpty {
                    Picker("选择可用模型", selection: $configuration.model) {
                        if !availableModels.contains(configuration.model) { Text(configuration.model.isEmpty ? "请选择" : configuration.model).tag(configuration.model) }
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                SecureField("模型 API Key", text: $configuration.modelKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("接口调用可能按你的服务账号收费。密钥保存在此设备的钥匙串中，不随账本备份导出。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("platform.deepseek.com/usage 是账号管理页，不是 API 地址。获取模型列表不生成内容；选择后请保存配置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("连接检查") {
                Text("支持 Chat Completions 兼容接口。服务地址填写 API 地址，例如 https://api.deepseek.com/v1；模型名称必须是服务商提供的模型 ID。").font(.caption).foregroundStyle(.secondary)
                Button("测试模型连接") { testConnection(model: true) }.disabled(testing || saving || !loaded)
                Button("测试高德连接") { testConnection(model: false) }.disabled(testing || saving || !loaded)
                if testing { ProgressView("正在检查连接…") }
                if let connectionResult { Text(connectionResult).font(.subheadline).textSelection(.enabled) }
                Text("使用当前填写的配置测试，不会保存配置或发送账本、已有日程；模型测试可能产生少量接口费用。").font(.caption).foregroundStyle(.secondary)
            }
            Section("常用安排") {
                TextField("常用城市", text: $city)
                TextField("默认出发地点，例如小区或地铁站", text: $origin)
                Picker("交通偏好", selection: $mode) {
                    ForEach(TravelMode.allCases) { value in Text(value.label).tag(value) }
                }
                Stepper("提前缓冲 \(bufferMinutes) 分钟", value: $bufferMinutes, in: 0...120, step: 5)
                Stepper("活动时长 \(durationMinutes) 分钟", value: $durationMinutes, in: 5...1440, step: 5)
                Text("默认地点和交通偏好保存在本地，并随完整备份保留。出发前仍需确认具体地点。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("计划助手设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { save() }.disabled(!loaded || saving)
            }
        }
        .task { load() }
    }

    private func load() {
        guard !loaded else { return }
        let preferences = store.data.plannerPreferences
        city = preferences.city; origin = preferences.origin; mode = preferences.mode
        bufferMinutes = preferences.bufferMinutes; durationMinutes = preferences.durationMinutes
        do { configuration = try PlannerCredentials.load(); loaded = true }
        catch { self.error = error.localizedDescription }
    }

    private func save() {
        saving = true; error = nil
        do {
            let cleanCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanCity.isEmpty else { throw AppFailure.message("请填写常用城市，以便区分同名地点") }
            let preferences = PlannerPreferences(city: cleanCity, origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode, bufferMinutes: bufferMinutes, durationMinutes: durationMinutes)
            try TripPlanning.validate(preferences)
            try PlannerCredentials.save(configuration)
            try store.savePlannerPreferences(preferences)
            dismiss()
        } catch { self.error = error.localizedDescription }
        saving = false
    }

    private func testConnection(model: Bool) {
        testing = true; connectionResult = nil
        let client = PlannerNetworking(configuration: configuration)
        let region = city
        Task {
            defer { testing = false }
            do {
                if model { connectionResult = try await client.testModel() }
                else { connectionResult = try await client.testAMap(city: region) }
            }
            catch { connectionResult = "\(model ? "模型" : "高德")：\(error.localizedDescription)" }
        }
    }

    private func fetchModels() {
        testing = true; connectionResult = nil
        let client = PlannerNetworking(configuration: configuration)
        Task {
            defer { testing = false }
            do {
                availableModels = try await client.listModels()
                if !availableModels.contains(configuration.model), let first = availableModels.first { configuration.model = first }
                connectionResult = "已获取 \(availableModels.count) 个可用模型，请选择、测试并保存。"
            } catch { connectionResult = error.localizedDescription }
        }
    }
}
