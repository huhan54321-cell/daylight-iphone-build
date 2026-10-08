import SwiftUI

@MainActor struct PlannerOverview: View {
    @EnvironmentObject private var store: AssistantStore
    var initialDate: Date = Date()
    @State private var showEditor = false
    @State private var showSettings = false
    @State private var selectedTrip: PlannedTrip?
    #if DEBUG
    @State private var showCapturePreview = false
    @State private var showCaptureAnalysis = false
    #endif
    private var recentTrips: [PlannedTrip] { Array(store.data.plannedTrips.sorted { $0.createdAt > $1.createdAt }.prefix(6)) }

    var body: some View {
        SoftCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("计划助手", systemImage: "sparkles").font(.headline)
                    Text("一句话安排出行，确认后加入行程表").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").padding(6) }
                    .accessibilityLabel("计划助手设置")
            }
            Button { showEditor = true } label: {
                Label("帮我安排", systemImage: "plus.bubble.fill").frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            if !recentTrips.isEmpty {
                Divider()
                ForEach(recentTrips) { trip in
                    Button { selectedTrip = trip } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "map").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trip.title).foregroundStyle(.primary)
                                Text("\(trip.destination.name) · \(trip.route.mode.label)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(currentTimeDescription(trip)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showEditor) { PlannerEditor(initialDate: initialDate) }
        .sheet(isPresented: $showSettings) { NavigationStack { PlannerSettingsView() } }
        .sheet(item: $selectedTrip) { PlannerTripDetail(trip: $0) }
        #if DEBUG
        .sheet(isPresented: $showCapturePreview) { PlannerPreviewCapture() }
        .sheet(isPresented: $showCaptureAnalysis) { PlannerAnalysisCapture() }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--capture-planner-analysis") { showCaptureAnalysis = true }
            else if arguments.contains("--capture-planner-preview") { showCapturePreview = true }
            else if arguments.contains("--capture-planner-settings") { showSettings = true }
            else if arguments.contains("--capture-planner") { showEditor = true }
        }
        #endif
    }

    private func currentTimeDescription(_ trip: PlannedTrip) -> String {
        let events = store.data.events.filter { trip.eventIDs.contains($0.id) }.sorted { $0.start < $1.start }
        if let activity = events.first(where: { $0.id == trip.eventIDs.last }) {
            return "日程：\(activity.start.formatted(date: .abbreviated, time: .shortened))"
        }
        if let first = events.first { return "日程：\(first.start.formatted(date: .abbreviated, time: .shortened))" }
        return "路线参考 · 日程已移除"
    }
}

@MainActor private struct PlannerEditor: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    var initialDate: Date
    @State private var configuration = PlannerAPIConfiguration()
    @State private var previousPreferences = PlannerPreferences()
    @State private var prompt = ""
    @State private var routePreference = ""
    @State private var title = "出行安排"
    @State private var city = "青岛"
    @State private var originQuery = ""
    @State private var destinationQuery = ""
    @State private var origin: PlannerPlace?
    @State private var destination: PlannerPlace?
    @State private var originCandidates: [PlannerPlace] = []
    @State private var destinationCandidates: [PlannerPlace] = []
    @State private var originSearched = false
    @State private var destinationSearched = false
    @State private var mode = TravelMode.transit
    @State private var arrival = Date()
    @State private var durationMinutes = 90
    @State private var bufferMinutes = 15
    @State private var routes: [PlannerRoute] = []
    @State private var selectedRoute: PlannerRoute?
    @State private var analysis: PlannerRouteAnalysis?
    @State private var analysisOptions: [PlannerRouteOption] = []
    @State private var preview: PlannedTrip?
    @State private var conflicts: [PlanEvent] = []
    @State private var busyStage: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var showSettings = false
    @State private var confirmConflict = false
    @State private var confirmManualPlan = false
    @State private var manualSaved = false
    @State private var loaded = false
    @State private var requestToken = UUID()
    @State private var work: Task<Void, Never>?
    private var busy: Bool { busyStage != nil }
    private var hasModel: Bool { !configuration.modelKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !configuration.model.isEmpty }
    private var hasAMap: Bool { !configuration.amapKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var manualEnd: Date { arrival.addingTimeInterval(Double(durationMinutes) * 60) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                requestSection
                if let busyStage { Section { HStack { ProgressView(); Text(busyStage).font(.subheadline) } } }
                if let error { Section { Text(error).foregroundStyle(.red).font(.subheadline) } }
                if let notice { Section { Text(notice).foregroundStyle(.secondary).font(.subheadline) } }
                if hasAMap { routesSection.id("planner-route-results") }
                if let preview { previewSection(preview) }
                detailsSection
                if hasAMap {
                    placesSection
                } else {
                    manualPlanSection
                }
            }
            .onChange(of: routes) { _, values in
                if !values.isEmpty { withAnimation { scroll.scrollTo("planner-route-results", anchor: .top) } }
            }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("帮我安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { work?.cancel(); dismiss() }.disabled(busyStage?.hasPrefix("正在保存") == true) }
                ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("计划助手设置").disabled(busy) }
            }
            .task { load() }
            .onDisappear { work?.cancel() }
            .sheet(isPresented: $showSettings, onDismiss: reloadSettings) { NavigationStack { PlannerSettingsView() } }
            .confirmationDialog("与已有日程重叠，仍要加入吗？", isPresented: $confirmConflict, titleVisibility: .visible) {
                Button("仍然加入行程表") { savePreview(approvedConflicts: conflicts) }
                Button("返回调整", role: .cancel) {}
            }
            .confirmationDialog("保存这项普通日程？", isPresented: $confirmManualPlan, titleVisibility: .visible) {
                Button("确认保存") { saveManualPlan() }
                Button("返回调整", role: .cancel) {}
            } message: {
                Text("\(title)\n\(arrival.formatted(date: .abbreviated, time: .shortened)) — \(manualEnd.formatted(date: .abbreviated, time: .shortened))\n只保存活动，不生成交通路线或出发时间。")
            }
            .onChange(of: city) { _, _ in clearPlaces() }
            .onChange(of: originQuery) { _, _ in origin = nil; originCandidates = []; originSearched = false; invalidateRoutes() }
            .onChange(of: destinationQuery) { _, _ in destination = nil; destinationCandidates = []; destinationSearched = false; invalidateRoutes() }
            .onChange(of: mode) { _, _ in invalidateRoutes() }
            .onChange(of: prompt) { _, _ in invalidateAnalysis() }
            .onChange(of: routePreference) { _, _ in invalidateAnalysis() }
            .onChange(of: title) { _, _ in invalidateAnalysis() }
            .onChange(of: arrival) { _, _ in invalidateAnalysis() }
            .onChange(of: durationMinutes) { _, _ in invalidateAnalysis() }
            .onChange(of: bufferMinutes) { _, _ in invalidateAnalysis() }
        }
    }

    private var requestSection: some View {
        Section {
            TextEditor(text: $prompt).frame(minHeight: 90).accessibilityLabel("用一句话描述安排").disabled(busy)
            Text("例如：明天晚上六点半，从家去青岛市南区某家餐馆，坐地铁，用餐两小时。请写明餐馆名称；“家”使用设置里的默认地点。")
                .font(.caption).foregroundStyle(.secondary)
            if hasModel {
                Button("理解我的安排", systemImage: "sparkles") { understand() }.disabled(busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text("尚未配置模型服务。可以直接填写下方表单，或先打开设置。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("配置模型与地图服务", systemImage: "gearshape") { showSettings = true }.disabled(busy)
            }
            Text("查询结果会先生成草稿；只有最后确认才会写入日程。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("想怎么安排") }
    }

    private var detailsSection: some View {
        Section("确认地点和时间") {
            TextField("活动名称", text: $title)
            TextField("查询城市", text: $city)
            TextField("出发地点", text: $originQuery)
            TextField("目的地或餐馆名称", text: $destinationQuery)
            DatePicker(hasAMap ? "到达时间" : "活动开始", selection: $arrival, displayedComponents: [.date, .hourAndMinute])
            Picker("交通方式", selection: $mode) { ForEach(TravelMode.allCases) { value in Text(value.label).tag(value) } }
            Stepper("活动时长 \(durationMinutes) 分钟", value: $durationMinutes, in: 5...1440, step: 5)
            Stepper("提前缓冲 \(bufferMinutes) 分钟", value: $bufferMinutes, in: 0...120, step: 5)
            TextField("路线偏好，如尽量省时、少走路", text: $routePreference, axis: .vertical)
            Text(hasAMap ? "路线耗时是查询时的估算，不代表未来实时路况。缓冲时间用于提前出发。" : "手动普通日程按活动开始时间保存；交通方式和缓冲时间不会用于推算出发时间。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy)
    }

    private var manualPlanSection: some View {
        Section("尚未配置高德 · 可以先保存活动") {
            Text("地点查询和路线规划需要高德 Web 服务 Key。现在可以使用上方填写的名称、地点、开始时间和时长，保存一项普通日程。")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("活动结束：\(manualEnd.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
            Button("手动保存普通日程", systemImage: "calendar.badge.plus") { confirmManualPlan = true }
                .disabled(busy || store.busy || manualSaved || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("保存会使用现有日历同步设置；未连接苹果日历时先保存在本 App。这里不创建交通日程，也不需要模型或地图账号。")
                .font(.caption).foregroundStyle(.secondary)
            Button("配置高德后查询路线", systemImage: "gearshape") { showSettings = true }.disabled(busy)
        }
    }

    private var placesSection: some View {
        Group {
            Section("选择出发地") {
                Button("查询出发地点", systemImage: "magnifyingglass") { search(isOrigin: true) }.disabled(busy || originQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                placeResults(originCandidates, selected: origin, searched: originSearched, isOrigin: true)
            }
            Section("选择目的地") {
                Button("查询目的地", systemImage: "magnifyingglass") { search(isOrigin: false) }.disabled(busy || destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                placeResults(destinationCandidates, selected: destination, searched: destinationSearched, isOrigin: false)
                Text("请分别点选具体地点，避免同名门店或小区导致路线错误。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func placeResults(_ values: [PlannerPlace], selected: PlannerPlace?, searched: Bool, isOrigin: Bool) -> some View {
        if searched && values.isEmpty { Text("没有找到地点，请补充名称或地址后重试。只能使用高德返回的真实地点。") .font(.subheadline).foregroundStyle(.secondary) }
        ForEach(values) { place in
            Button {
                if isOrigin { origin = place } else { destination = place }
                invalidateRoutes()
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name).foregroundStyle(.primary)
                        Text(place.address.isEmpty ? "高德地点 · 请确认名称" : place.address).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: selected?.id == place.id ? "checkmark.circle.fill" : "circle").foregroundStyle(.blue)
                }
            }.buttonStyle(.plain).disabled(busy)
        }
    }

    private var routesSection: some View {
        Section("选择路线") {
            Button("查询推荐路线", systemImage: "arrow.triangle.turn.up.right.diamond") { queryRoutes() }.disabled(busy || origin == nil || destination == nil)
            if let analysis {
                PlannerAnalysisContent(analysis: analysis)
                Button("采用模型推荐") {
                    selectedRoute = routes.first { $0.id == analysis.recommendedRouteID }
                    invalidatePreview()
                }.disabled(busy)
            }
            ForEach(routes) { route in
                Button { selectedRoute = route; invalidatePreview() } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("方案 \((routes.firstIndex(where: { $0.id == route.id }) ?? 0) + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if analysis?.recommendedRouteID == route.id { Label("模型推荐", systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.blue) }
                        }
                        PlannerRouteRow(route: route, selected: selectedRoute?.id == route.id)
                        if let option = analysisOptions.first(where: { $0.route.id == route.id }) {
                            PlannerOptionStatus(option: option)
                        }
                        if let assessment = analysis?.assessment(for: route.id) {
                            PlannerAssessmentContent(assessment: assessment)
                        }
                    }
                }.buttonStyle(.plain).disabled(busy)
            }
            if !routes.isEmpty {
                Text("高德实际返回 \(routes.count) 条方案。未提供费用时不会推算；公交换乘和步行详情可在高德查看。")
                    .font(.caption).foregroundStyle(.secondary)
                if hasModel {
                    Button(analysis == nil ? "分析路线与推荐" : "重新分析路线", systemImage: "sparkles") { analyzeRoutes() }.disabled(busy)
                    Text("模型会接收本次需求、起终点名称、路线估算和冲突数量，不发送已有日程的标题或内容。分析仅供参考，选择路线后仍需确认保存。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("配置模型后可比较这些真实路线并获得推荐理由；现在可直接选择路线。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("预览时间安排", systemImage: "calendar.badge.clock") { buildPreview() }.disabled(busy || selectedRoute == nil)
            }
        }
    }

    @ViewBuilder private func previewSection(_ trip: PlannedTrip) -> some View {
        Section("预览行程 · 尚未保存") {
            ForEach(TripPlanning.schedule(trip)) { event in
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.headline)
                    Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) — \(event.end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if conflicts.isEmpty {
                Label("已检查可读取的日程，未发现重叠", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.green)
            } else {
                Label("与 \(conflicts.count) 项已有日程重叠", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                ForEach(conflicts) { value in
                    Text("\(value.title) · \(value.start.formatted(date: .abbreviated, time: .shortened)) — \(value.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.apple.calendarAvailable {
                Text("尚未连接苹果日历，目前只检查了本 App 内的日程。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("确认后保存出发和活动两段日程。连接苹果日历后会同步；未连接时先保存在本 App。")
                .font(.caption).foregroundStyle(.secondary)
            Button { savePreview() } label: {
                Label("确认并加入行程表", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 4)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(busy)
        }
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        let preferences = store.data.plannerPreferences
        previousPreferences = preferences
        city = preferences.city; originQuery = preferences.origin; mode = preferences.mode
        bufferMinutes = preferences.bufferMinutes; durationMinutes = preferences.durationMinutes
        arrival = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: initialDate) ?? initialDate
        if arrival <= Date() { arrival = Calendar.current.date(byAdding: .day, value: 1, to: arrival) ?? initialDate }
        reloadConfiguration()
    }

    private func reloadConfiguration() {
        do { configuration = try PlannerCredentials.load() }
        catch { self.error = error.localizedDescription }
    }

    private func reloadSettings() {
        reloadConfiguration()
        invalidateAnalysis()
        let current = store.data.plannerPreferences
        if city == previousPreferences.city { city = current.city }
        if originQuery == previousPreferences.origin { originQuery = current.origin }
        if mode == previousPreferences.mode { mode = current.mode }
        if bufferMinutes == previousPreferences.bufferMinutes { bufferMinutes = current.bufferMinutes }
        if durationMinutes == previousPreferences.durationMinutes { durationMinutes = current.durationMinutes }
        previousPreferences = current
    }

    private func begin(_ stage: String) -> UUID {
        work?.cancel(); requestToken = UUID(); busyStage = stage; error = nil; notice = nil
        return requestToken
    }
    private func finish(_ token: UUID, error: Error? = nil) {
        guard requestToken == token else { return }; busyStage = nil
        if let error, !(error is CancellationError) { self.error = error.localizedDescription }
    }
    private func invalidatePreview() { preview = nil; conflicts = [] }
    private func invalidateAnalysis() { analysis = nil; analysisOptions = []; invalidatePreview() }
    private func invalidateRoutes() { routes = []; selectedRoute = nil; invalidateAnalysis() }
    private func clearPlaces() { origin = nil; destination = nil; originCandidates = []; destinationCandidates = []; originSearched = false; destinationSearched = false; invalidateRoutes() }

    private func understand() {
        let token = begin("正在理解安排…")
        let client = PlannerNetworking(configuration: configuration)
        let text = prompt
        let preferences = PlannerPreferences(city: city, origin: originQuery, mode: mode, bufferMinutes: bufferMinutes, durationMinutes: durationMinutes)
        work = Task {
            do {
                let intent = try await client.understand(text, preferences: preferences)
                guard !Task.isCancelled, requestToken == token else { return }
                clearPlaces()
                title = intent.title.isEmpty ? "出行安排" : intent.title
                destinationQuery = intent.destination
                originQuery = intent.origin ?? preferences.origin
                mode = intent.mode ?? preferences.mode
                durationMinutes = intent.durationMinutes ?? preferences.durationMinutes
                if let date = intent.date {
                    if let value = TripPlanning.date(dateString: date, timeString: intent.time ?? PlannerDisplay.timeString(arrival)) { arrival = value }
                } else if let time = intent.time, let value = TripPlanning.date(dateString: PlannerDisplay.dateString(arrival), timeString: time) { arrival = value }
                finish(token)
                notice = intent.missingFields.isEmpty ? "已生成可编辑草稿。请确认时间，并分别选择具体地点。" : "已生成可编辑草稿。尚未明确：\(intent.missingFields.joined(separator: "、"))。请核对下方字段，未说明的时间沿用当前默认值。"
            } catch { finish(token, error: AppFailure.message("模型理解：\(error.localizedDescription)")); notice = "可以继续手动填写下方表单，地图查询不依赖模型理解。" }
        }
    }

    private func search(isOrigin: Bool) {
        let query = isOrigin ? originQuery : destinationQuery
        let searchCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchCity.isEmpty else { error = "请先填写查询城市"; return }
        let token = begin(isOrigin ? "正在查询出发地点…" : "正在查询目的地…")
        let client = PlannerNetworking(configuration: configuration)
        work = Task {
            do {
                let values = try await client.searchPlaces(query, city: searchCity)
                guard !Task.isCancelled, requestToken == token else { return }
                if isOrigin { originCandidates = values; origin = nil; originSearched = true }
                else { destinationCandidates = values; destination = nil; destinationSearched = true }
                invalidateRoutes(); finish(token)
            } catch { finish(token, error: AppFailure.message("高德地点查询：\(error.localizedDescription)")) }
        }
    }

    private func queryRoutes() {
        guard let origin, let destination else { return }
        let token = begin("正在查询高德路线…")
        let client = PlannerNetworking(configuration: configuration)
        let travelMode = mode
        invalidateRoutes()
        work = Task {
            do {
                let values = try await client.routes(origin: origin, destination: destination, mode: travelMode)
                guard !Task.isCancelled, requestToken == token else { return }
                routes = Array(values.prefix(3))
                if routes.isEmpty { finish(token); notice = "高德没有返回可用路线。请调整地点或交通方式后重试。" }
                else if hasModel {
                    do { try await performRouteAnalysis(token: token, client: client); finish(token) }
                    catch { finish(token, error: error); notice = "真实路线已保留。可以重试分析，或直接选择路线并预览时间。" }
                } else { finish(token) }
            } catch { finish(token, error: error) }
        }
    }

    private func analyzeRoutes() {
        guard !busy, !routes.isEmpty, origin != nil, destination != nil else { return }
        invalidateAnalysis()
        let token = begin("正在分析路线与推荐…")
        let client = PlannerNetworking(configuration: configuration)
        work = Task {
            do { try await performRouteAnalysis(token: token, client: client); finish(token) }
            catch { finish(token, error: error); notice = "分析未完成。可以重试，或自行选择高德路线并预览时间。" }
        }
    }

    private func performRouteAnalysis(token: UUID, client: PlannerNetworking) async throws {
        guard let origin, let destination, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= 2000, routePreference.count <= 300 else {
            throw AppFailure.message("请填写活动名称；需求最多 2000 字，路线偏好最多 300 字")
        }
        busyStage = "正在检查候选路线的日程冲突…"
        let initialOptions = try TripPlanning.analysisOptions(title: title, origin: origin, destination: destination,
            routes: routes, arrival: arrival, durationMinutes: durationMinutes, bufferMinutes: bufferMinutes, events: [], now: Date())
        let start = initialOptions.map(\.departure).min()!
        let end = initialOptions.map(\.finish).max()!
        let events = try await conflictEvents(start: start, end: end)
        try Task.checkCancellation()
        guard requestToken == token else { throw CancellationError() }
        let analysisTime = Date()
        let options = try TripPlanning.analysisOptions(title: title, origin: origin, destination: destination,
            routes: routes, arrival: arrival, durationMinutes: durationMinutes, bufferMinutes: bufferMinutes, events: events, now: analysisTime)
        busyStage = "正在比较路线并生成推荐理由…"
        let request = "\(prompt)\n活动：\(title)\n路线偏好：\(routePreference)"
        let result = try await client.analyzeRoutes(request: request, origin: origin, destination: destination,
            options: options, durationMinutes: durationMinutes, bufferMinutes: bufferMinutes,
            appleCalendarChecked: store.apple.calendarAvailable, now: analysisTime)
        try Task.checkCancellation()
        guard requestToken == token else { throw CancellationError() }
        analysisOptions = options; analysis = result
        notice = "路线分析已完成。请查看推荐和取舍，再选择路线；尚未保存任何日程。"
    }

    private func conflictEvents(start: Date, end: Date) async throws -> [PlanEvent] {
        var events: [PlanEvent] = []
        var day = Calendar.current.startOfDay(for: start)
        let lastDay = Calendar.current.startOfDay(for: end)
        while day <= lastDay {
            try Task.checkCancellation()
            events += try await store.plannerConflictEvents(on: day)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Array(Dictionary(events.map { event in
            let identity = event.eventID.map { "calendar:\($0):\(event.start.timeIntervalSince1970)" } ?? event.id.uuidString
            return (identity, event)
        }, uniquingKeysWith: { first, _ in first }).values)
    }

    private func buildPreview() {
        guard let origin, let destination, let selectedRoute else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { error = "请填写活动名称"; return }
        let trip = PlannedTrip(title: cleanTitle, origin: origin, destination: destination, route: selectedRoute, arrival: arrival,
            durationMinutes: durationMinutes, bufferMinutes: bufferMinutes,
            advice: TripPlanning.savedAdvice(analysis, selectedRouteID: selectedRoute.id))
        do { try TripPlanning.validate(trip) }
        catch { self.error = error.localizedDescription; return }
        let proposed = TripPlanning.schedule(trip)
        do { try TripPlanning.requireFutureDeparture(trip, now: Date()) }
        catch { self.error = error.localizedDescription; return }
        guard let start = proposed.first?.start else { return }
        let token = begin("正在检查日程冲突…")
        work = Task {
            do {
                let events = try await conflictEvents(start: start, end: proposed.last?.end ?? trip.arrival)
                guard !Task.isCancelled, requestToken == token else { return }
                conflicts = TripPlanning.conflicts(events: events, proposed: proposed)
                preview = trip; finish(token)
            } catch { finish(token, error: error) }
        }
    }

    private func savePreview(approvedConflicts: [PlanEvent] = []) {
        guard let trip = preview, !busy else { return }
        let token = begin("正在确认最新日程…")
        work = Task {
            do {
                try TripPlanning.requireFutureDeparture(trip, now: Date())
                let proposed = TripPlanning.schedule(trip)
                let values = try await conflictEvents(start: proposed[0].start, end: proposed[1].end)
                try Task.checkCancellation()
                guard requestToken == token else { return }
                let latestConflicts = TripPlanning.conflicts(events: values, proposed: proposed)
                conflicts = latestConflicts
                if TripPlanning.needsConflictReview(current: latestConflicts, approved: approvedConflicts) {
                    finish(token)
                    notice = "已重新检查最新日程。请查看当前重叠安排，再决定是否保存。"
                    confirmConflict = true
                    return
                }
                // A calendar query may itself outlast the remaining time before departure.
                try TripPlanning.requireFutureDeparture(trip, now: Date())
                busyStage = "正在保存行程…"
                try await store.addPlannedTrip(trip)
                guard requestToken == token else { return }
                finish(token); dismiss()
            } catch { finish(token, error: error) }
        }
    }

    private func saveManualPlan() {
        guard !busy, !store.busy, !manualSaved else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let departureNote = originQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, (5...1440).contains(durationMinutes), arrival.timeIntervalSince1970.isFinite, manualEnd > arrival else {
            error = "请检查活动名称、开始时间和活动时长"; return
        }
        var notes = "手动安排，未查询地图或生成交通路线。"
        if !departureNote.isEmpty { notes += "\n出发地点（备注）：\(departureNote)" }
        let event = PlanEvent(title: cleanTitle, start: arrival, end: manualEnd, notes: notes, location: place.isEmpty ? nil : place)
        busyStage = "正在保存日程…"; error = nil; store.message = nil
        defer { busyStage = nil }
        do {
            try store.addEvent(event)
            manualSaved = true
            if store.message == nil {
                let synced = store.data.events.first(where: { $0.id == event.id })?.eventID != nil
                store.message = synced ? "普通日程已保存，并同步到苹果日历。" : "普通日程已本地保存，连接苹果日历后可同步。"
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor private struct PlannerRouteRow: View {
    var route: PlannerRoute
    var selected: Bool = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(route.mode.label) · 约 \(PlannerDisplay.duration(route.durationSeconds)) · \(PlannerDisplay.distance(route.distanceMeters))")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(route.summary).font(.subheadline).foregroundStyle(.secondary)
                if let cost = route.costDescription, !cost.isEmpty { Text(cost).font(.caption).foregroundStyle(.secondary) }
                if let walking = route.walkingDistanceMeters { Text("步行参考 \(PlannerDisplay.distance(walking))").font(.caption).foregroundStyle(.secondary) }
                if let transfers = route.transferCount { Text("公交／轨道换乘参考 \(transfers) 次").font(.caption).foregroundStyle(.secondary) }
                Text("查询于 \(route.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
        }.padding(.vertical, 3)
    }
}

@MainActor private struct PlannerAnalysisContent: View {
    var analysis: PlannerRouteAnalysis
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("模型分析参考", systemImage: "sparkles").font(.headline).foregroundStyle(.blue)
            Text(analysis.summary).font(.subheadline).foregroundStyle(.primary)
            ForEach(Array(analysis.cautions.enumerated()), id: \.offset) { _, text in
                Text("• \(text)").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(analysis.model) · \(analysis.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
            Text("路线数据以高德查询结果为准；模型分析可能有误，时间或需求变化后请重新分析。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

@MainActor private struct PlannerAssessmentContent: View {
    var assessment: PlannerRouteAssessment
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("优点：\(assessment.benefits)")
            Text("取舍：\(assessment.tradeoffs)")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

@MainActor private struct PlannerOptionStatus: View {
    var option: PlannerRouteOption
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("预计出发：\(option.departure.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
            if !option.departureIsFuture { Text("按当前时间已来不及出发，请调整到达时间").foregroundStyle(.red) }
            if option.conflictCount > 0 { Text("与 \(option.conflictCount) 项可读取日程重叠").foregroundStyle(.orange) }
            else { Text("本次可读取的日程未发现重叠").foregroundStyle(.secondary) }
        }.font(.caption)
    }
}

@MainActor private struct PlannerTripDetail: View {
    @EnvironmentObject private var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var trip: PlannedTrip
    @State private var refreshedRoutes: [PlannerRoute] = []
    @State private var error: String?
    @State private var querying = false
    @State private var work: Task<Void, Never>?
    private var events: [PlanEvent] { store.data.events.filter { trip.eventIDs.contains($0.id) }.sorted { $0.start < $1.start } }

    var body: some View {
        NavigationStack {
            Form {
                Section("地点") {
                    LabeledContent("出发地", value: trip.origin.name)
                    LabeledContent("目的地", value: trip.destination.name)
                    Text(trip.destination.address).font(.caption).foregroundStyle(.secondary)
                }
                Section("已保存的日程") {
                    if events.isEmpty { Text("相关日程已移除。以下路线仅作为原规划参考。") .font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title)
                            Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) — \(event.end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("这里显示计划中的现有时间。可返回日程表编辑；路线仍保留生成时的参考信息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("原规划路线") {
                    PlannerRouteRow(route: trip.route)
                    Button("打开高德导航", systemImage: "location.fill") {
                        if let url = TripPlanning.navigationURL(origin: trip.origin, destination: trip.destination, mode: trip.route.mode) { openURL(url) }
                    }
                    Button("刷新路线参考", systemImage: "arrow.clockwise") { refresh() }.disabled(querying)
                    Text("出发前可重新查询耗时。刷新只展示当前路线，不会修改或重复创建已保存的日程。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("打开导航时高德会重新规划路线，可能与之前选中的方案不同。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let advice = trip.advice {
                    Section("保存时的模型分析") {
                        Text(advice.summary).font(.subheadline)
                        Label(advice.wasRecommended ? "当时选择了模型推荐" : "当时选择了其他路线", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.blue)
                        PlannerAssessmentContent(assessment: PlannerRouteAssessment(routeID: trip.route.id, benefits: advice.benefits, tradeoffs: advice.tradeoffs))
                        ForEach(Array(advice.cautions.enumerated()), id: \.offset) { _, text in
                            Text("• \(text)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(advice.model) · \(advice.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("这是保存时的分析参考。日程或交通变化后不会自动更新，需重新规划。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if querying { Section { HStack { ProgressView(); Text("正在查询当前路线…") } } }
                if !refreshedRoutes.isEmpty {
                    Section("当前路线参考") {
                        ForEach(refreshedRoutes) { route in PlannerRouteRow(route: route) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.subheadline) } }
            }
            .navigationTitle(trip.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onDisappear { work?.cancel() }
        }
    }

    private func refresh() {
        querying = true; error = nil; refreshedRoutes = []
        work = Task {
            do {
                let configuration = try PlannerCredentials.load()
                let values = try await PlannerNetworking(configuration: configuration).routes(origin: trip.origin, destination: trip.destination, mode: trip.route.mode)
                guard !Task.isCancelled else { return }
                refreshedRoutes = Array(values.prefix(3))
                if values.isEmpty { error = "高德没有返回可用路线，请在高德中查看或稍后重试" }
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            querying = false
        }
    }
}

private enum PlannerDisplay {
    static func duration(_ seconds: Int) -> String {
        let minutes = Int(ceil(Double(seconds) / 60))
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }
    static func distance(_ meters: Int) -> String { meters >= 1000 ? String(format: "%.1f 公里", Double(meters) / 1000) : "\(meters) 米" }
    static func dateString(_ date: Date) -> String { format(date, pattern: "yyyy-MM-dd") }
    static func timeString(_ date: Date) -> String { format(date, pattern: "HH:mm") }
    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

#if DEBUG
@MainActor private struct PlannerAnalysisCapture: View {
    private let routes = [
        PlannerRoute(id: "capture-analysis-one", mode: .driving, durationSeconds: 1200, distanceMeters: 5000,
            summary: "测试道路甲", fetchedAt: Date()),
        PlannerRoute(id: "capture-analysis-two", mode: .driving, durationSeconds: 2100, distanceMeters: 4500,
            summary: "测试道路乙", fetchedAt: Date())
    ]
    private var analysis: PlannerRouteAnalysis {
        PlannerRouteAnalysis(recommendedRouteID: routes[0].id, summary: "截图示例：推荐方案 1，路程稍长，但预计耗时更短，符合尽量省时的偏好。",
            assessments: [
                PlannerRouteAssessment(routeID: routes[0].id, benefits: "预计耗时更短。", tradeoffs: "距离稍长，完整出行费用未知。"),
                PlannerRouteAssessment(routeID: routes[1].id, benefits: "距离较短。", tradeoffs: "预计耗时较长，需更早出发。")
            ], cautions: ["这是测试分析；正式使用时由配置的模型生成。"], generatedAt: Date(), model: "截图演示")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Label("截图测试数据 · 未调用服务，未保存", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                Section("路线分析") { PlannerAnalysisContent(analysis: analysis) }
                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                    Section("方案 \(index + 1)\(index == 0 ? " · 模型推荐" : "")") {
                        PlannerRouteRow(route: route, selected: index == 0)
                        if let item = analysis.assessment(for: route.id) { PlannerAssessmentContent(assessment: item) }
                    }
                }
                Section { Button("采用推荐并预览时间") {}.disabled(true) }
            }.navigationTitle("路线推荐").navigationBarTitleDisplayMode(.inline)
        }
    }
}

// This fixture is available only with an explicit simulator capture argument. It never calls a service or writes records.
@MainActor private struct PlannerPreviewCapture: View {
    private let trip: PlannedTrip = {
        let day = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let arrival = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: day) ?? day
        let origin = PlannerPlace(id: "capture-origin", name: "测试出发地", address: "截图演示地址", longitude: 120.38, latitude: 36.07, cityCode: "0532")
        let destination = PlannerPlace(id: "capture-destination", name: "测试餐馆", address: "截图演示地址", longitude: 120.39, latitude: 36.06, cityCode: "0532")
        let route = PlannerRoute(id: "capture-route", mode: .transit, durationSeconds: 2400, distanceMeters: 6500, summary: "测试线路 · 步行约 8 分钟 · 换乘 1 次", costDescription: "截图测试费用示例：¥4", fetchedAt: Date())
        return PlannedTrip(title: "晚餐安排（截图测试）", origin: origin, destination: destination, route: route, arrival: arrival, durationMinutes: 90, bufferMinutes: 15)
    }()
    var body: some View {
        NavigationStack {
            Form {
                Section { Label("截图测试数据 · 未查询地图，未保存日程", systemImage: "info.circle").font(.subheadline).foregroundStyle(.orange) }
                Section("选中的路线") { PlannerRouteRow(route: trip.route, selected: true) }
                Section("预览行程 · 尚未保存") {
                    ForEach(TripPlanning.schedule(trip)) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.title).font(.headline)
                            Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) — \(event.end.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Label("截图示例：与已有日程重叠", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    Text("请调整时间，或在正式预览中确认仍然加入。截图模式不会保存任何记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {} label: { Label("确认并加入行程表", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(true)
                }
            }.navigationTitle("预览行程").navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
