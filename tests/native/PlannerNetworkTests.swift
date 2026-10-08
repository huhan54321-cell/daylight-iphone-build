import Foundation

private final class PlannerFixtureProtocol: URLProtocol {
    struct Reply { var status: Int = 200; var data: Data; var error: URLError? = nil }
    private static let lock = NSLock()
    private static var current: ((URLRequest) throws -> Reply)?
    static func install(_ handler: @escaping (URLRequest) throws -> Reply) {
        lock.lock(); current = handler; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.current; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unknown) }
            let reply = try handler(request)
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

enum PlannerNetworkTests {
    static func run() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            if !condition { throw AppFailure.message("FAIL: planner network \(label)") }
        }
        func rejects(_ label: String, _ action: () async throws -> Void) async throws {
            var rejected = false
            do { try await action() } catch { rejected = true }
            try expect(rejected, label)
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [PlannerFixtureProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let config = PlannerAPIConfiguration(modelBaseURL: "https://api.example.com/v1", model: "fixture-model", modelKey: "fixture-personal-key", amapKey: "fixture-map-key")
        let networking = PlannerNetworking(configuration: config, session: session)
        let preferences = PlannerPreferences(city: "青岛", origin: "青岛站", mode: .transit, bufferMinutes: 15, durationMinutes: 90)
        let now = ISO8601DateFormatter().date(from: "2026-10-02T06:00:00Z")!
        let origin = PlannerPlace(id: "origin-poi", name: "青岛站", address: "山东路", longitude: 120.315, latitude: 36.06, cityCode: "0532")
        let destination = PlannerPlace(id: "destination-poi", name: "餐馆", address: "市南区", longitude: 120.36, latitude: 36.065, cityCode: "0532")
        func install(_ object: [String: Any], status: Int = 200) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            PlannerFixtureProtocol.install { _ in .init(status: status, data: data) }
        }
        func model(_ text: String) throws {
            try install(["choices": [["message": ["content": text]]]])
        }
        func body(_ request: URLRequest) -> Data {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            return result
        }
        try expect(try PlannerAPIConfiguration.modelEndpoint("https://api.example.com/v1").path == "/v1/chat/completions", "base endpoint appends compatible path")
        try expect(try PlannerAPIConfiguration.modelEndpoint("https://api.example.com/v1/chat/completions").path == "/v1/chat/completions", "full endpoint does not append twice")
        for invalid in ["http://api.example.com/v1", "https://localhost/v1", "https://127.0.0.1/v1", "https://192.168.1.2/v1", "https://api.local/v1", "https://user:password@api.example.com/v1", "https://api.example.com/v1?key=hidden", "https://api.example.com/v1#hidden"] {
            try await rejects("invalid model endpoint") { _ = try PlannerAPIConfiguration.modelEndpoint(invalid) }
        }
        try await rejects("header injection is rejected") { _ = try PlannerAPIConfiguration(modelKey: "key\r\nInjected: value").validated() }
        let noKeys = PlannerNetworking(configuration: PlannerAPIConfiguration(), session: session)
        try await rejects("missing model configuration") { _ = try await noKeys.understand("明天去餐馆", preferences: preferences, now: now) }
        try await rejects("missing map configuration") { _ = try await noKeys.searchPlaces("青岛站", city: "青岛") }
        let intentText = #"{"title":"晚餐","destination":"餐馆","origin":"青岛站","date":"2026-10-03","time":"18:30","mode":"transit","durationMinutes":90}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": intentText]]]])
        var inspectedModelRequest = false
        PlannerFixtureProtocol.install { request in
            let payload = try JSONSerialization.jsonObject(with: body(request)) as? [String: Any]
            let messages = payload?["messages"] as? [[String: String]]
            let user = messages?.last?["content"] ?? ""
            let system = messages?.first?["content"] ?? ""
            inspectedModelRequest = request.httpMethod == "POST" && request.url?.host == "api.example.com"
                && request.url?.path == "/v1/chat/completions" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-personal-key"
                && system.contains("2026-10-02") && system.contains("Asia/Shanghai")
                && user.contains("青岛站") && !user.contains("fixture-map-key") && !user.contains("fixture-personal-key")
                && payload?["stream"] as? Bool == false
            return .init(data: envelope)
        }
        let intent = try await networking.understand("明天18:30去餐馆", preferences: preferences, now: now)
        try expect(inspectedModelRequest, "intent request has minimal preferences, known endpoint and authorization")
        try expect(intent.destination == "餐馆" && intent.date == "2026-10-03" && intent.mode == .transit && intent.durationMinutes == 90, "strict model object decoded")
        try model("```json\n" + intentText + "\n```")
        try expect(try await networking.understand("晚餐", preferences: preferences).time == "18:30", "well-formed JSON fence accepted")
        try model(#"{"title":"去餐馆","destination":"","origin":null,"date":null,"time":null,"mode":null,"durationMinutes":null}"#)
        let missing = try await networking.understand("去某个餐馆", preferences: preferences)
        try expect(missing.destination.isEmpty && missing.time == nil && missing.date == nil && missing.missingFields.contains("到达时间"), "missing facts stay missing")
        for invalid in [intentText.replacingOccurrences(of: "2026-10-03", with: "2026-02-30"),
            intentText.replacingOccurrences(of: "18:30", with: "25:61"),
            intentText.replacingOccurrences(of: "\"transit\"", with: "\"teleport\""),
            intentText.replacingOccurrences(of: "\"durationMinutes\":90", with: "\"durationMinutes\":true"),
            intentText.replacingOccurrences(of: "\"durationMinutes\":90", with: "\"durationMinutes\":\"90\""),
            intentText.replacingOccurrences(of: "\"durationMinutes\":90", with: "\"durationMinutes\":90.5"),
            String(intentText.dropLast()) + ",\"url\":\"https://evil.example.com\"}", "说明：" + intentText, "```json\n" + intentText] {
            try model(String(invalid))
            try await rejects("malformed or unsupported intent rejected") { _ = try await networking.understand("晚餐", preferences: preferences) }
        }
        let places: [String: Any] = ["status": "1", "infocode": "10000", "pois": [
            ["id": "poi-one", "name": "餐馆甲", "location": "120.36,36.065", "address": "某路1号", "cityname": "青岛市", "adname": "市南区", "citycode": "0532"],
            ["id": "poi-one", "name": "重复", "location": "120.36,36.065"],
            ["id": "bad", "name": "无效坐标", "location": "NaN,200"],
            ["id": "poi-two", "name": "餐馆乙", "location": "120.37,36.066", "address": []]]]
        let placesData = try JSONSerialization.data(withJSONObject: places)
        var inspectedPlaceRequest = false
        PlannerFixtureProtocol.install { request in
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            inspectedPlaceRequest = request.url?.host == "restapi.amap.com" && request.url?.path == "/v5/place/text"
                && query["keywords"] == "餐馆" && query["region"] == "青岛" && query["city_limit"] == "true"
                && query["key"] == "fixture-map-key" && request.value(forHTTPHeaderField: "Authorization") == nil
            return .init(data: placesData)
        }
        let candidates = try await networking.searchPlaces("餐馆", city: "青岛")
        try expect(inspectedPlaceRequest, "map search uses real v5 endpoint, city restriction and separate key")
        try expect(candidates.count == 2 && candidates[0].cityCode == "0532" && candidates[1].address.isEmpty, "POIs deduplicate, ignore invalid coordinates and tolerate empty address arrays")
        try install(["status": "1", "infocode": "10000", "pois": [
            ["id": "poi-recovered", "name": "坐标缺失的旧结果", "location": "NaN,200"],
            ["id": "poi-recovered", "name": "有效门店", "location": "120.36,36.065", "citycode": "0532"]]])
        let recovered = try await networking.searchPlaces("餐馆", city: "青岛")
        try expect(recovered.count == 1 && recovered[0].id == "poi-recovered" && recovered[0].name == "有效门店"
            && recovered[0].longitude == 120.36, "invalid first POI does not hide a valid later result with the same ID")
        func routeObject(_ paths: [[String: Any]], transit: Bool = false) -> [String: Any] {
            ["status": "1", "infocode": "10000", "route": [transit ? "transits" : "paths": paths, "taxi_cost": "99"]]
        }
        let path: [String: Any] = ["distance": "5000", "duration": "99999", "cost": ["duration": "1200", "tolls": "5.50"], "steps": [["road_name": "香港路"]]]
        try install(routeObject([path, path, ["distance": "6000", "cost": ["duration": "1400", "tolls": "0"], "steps": [["road_name": "东海路"]]]]))
        let driving = try await networking.routes(origin: origin, destination: destination, mode: .driving)
        try expect(driving.count == 2 && driving[0].durationSeconds == 1200 && driving[0].distanceMeters == 5000, "v5 cost.duration and unique route alternatives")
        try expect(driving[0].costDescription == "过路费约 ¥5.5" && !driving[0].costDescription!.contains("99"), "driving tolls never become taxi fare")
        let transit: [String: Any] = ["distance": "6500", "cost": ["duration": "1800", "taxi_fee": "20"], "segments": [["walking": ["distance": "250"], "bus": ["buslines": [["name": "地铁3号线"]]]]]]
        let transitData = try JSONSerialization.data(withJSONObject: routeObject([transit], transit: true))
        var inspectedTransitRequest = false
        PlannerFixtureProtocol.install { request in
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            inspectedTransitRequest = request.url?.path == "/v5/direction/transit/integrated" && query["city1"] == "0532"
                && query["city2"] == "0532" && query["show_fields"] == "cost" && query["origin"] == "120.315000,36.060000"
            return .init(data: transitData)
        }
        let buses = try await networking.routes(origin: origin, destination: destination, mode: .transit)
        try expect(inspectedTransitRequest && buses[0].durationSeconds == 1800 && buses[0].summary.contains("地铁3号线"), "transit requires city codes and whole-plan cost.duration")
        try expect(buses[0].costDescription == nil, "transit does not mislabel taxi cost as ticket fare")
        try expect(buses[0].walkingDistanceMeters == 250 && buses[0].transferCount == 0,
            "transit walking and transfer references come from returned segments")
        var extraTransit = transit
        extraTransit["segments"] = [["walking": ["distance": "250"], "bus": ["buslines": [["name": "地铁3号线"]]]],
            ["walking": ["distance": "150"], "bus": ["buslines": [["name": "公交1路"]]]]]
        try install(routeObject([extraTransit], transit: true))
        let twoLegs = try await networking.routes(origin: origin, destination: destination, mode: .transit)
        try expect(twoLegs[0].walkingDistanceMeters == 400 && twoLegs[0].transferCount == 1, "walking distances sum across actual transit segments")
        extraTransit["segments"] = [["walking": ["steps": []], "bus": ["buslines": [["name": "地铁3号线"]]]]]
        try install(routeObject([extraTransit], transit: true))
        let unknownWalking = try await networking.routes(origin: origin, destination: destination, mode: .transit)
        try expect(unknownWalking[0].walkingDistanceMeters == nil, "missing transit walking distance is not misrepresented as zero")
        var noCity = origin; noCity.cityCode = nil
        try await rejects("transit missing city code") { _ = try await networking.routes(origin: noCity, destination: destination, mode: .transit) }
        for mode in [TravelMode.walking, .cycling] {
            var inspected = false
            let routeData = try JSONSerialization.data(withJSONObject: routeObject([path]))
            PlannerFixtureProtocol.install { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                inspected = request.url?.path == (mode == .walking ? "/v5/direction/walking" : "/v5/direction/bicycling")
                    && query.contains { $0.name == "alternative_route" && $0.value == "3" }
                return .init(data: routeData)
            }
            let routes = try await networking.routes(origin: origin, destination: destination, mode: mode)
            try expect(inspected && routes.count == 1 && routes[0].costDescription == nil, "walking/cycling use v5 and no driving fees")
        }
        try install(routeObject([]))
        try expect(try await networking.routes(origin: origin, destination: destination, mode: .driving).isEmpty, "empty route response stays empty")
        try install(routeObject([["distance": "5000", "duration": "1000"]]))
        try await rejects("v3 duration cannot silently substitute for missing v5 cost") { _ = try await networking.routes(origin: origin, destination: destination, mode: .driving) }
        try install(["status": "0", "infocode": "10001", "info": "fixture-map-key should never appear in an error"])
        do { _ = try await networking.searchPlaces("餐馆", city: "青岛"); throw AppFailure.message("FAIL: map error accepted") }
        catch { try expect(!error.localizedDescription.contains("fixture-map-key") && error.localizedDescription.contains("高德"), "provider error is sanitized") }
        try install(["error": ["message": "fixture-personal-key is invalid"]], status: 401)
        do { _ = try await networking.understand("餐馆", preferences: preferences); throw AppFailure.message("FAIL: auth error accepted") }
        catch { try expect(!error.localizedDescription.contains("fixture-personal-key") && error.localizedDescription.contains("API Key"), "HTTP authentication error is sanitized") }
        PlannerFixtureProtocol.install { _ in .init(data: Data(), error: URLError(.timedOut)) }
        do { _ = try await networking.searchPlaces("餐馆", city: "青岛"); throw AppFailure.message("FAIL: timeout accepted") }
        catch { try expect(error.localizedDescription.contains("超时"), "timeout has actionable reason") }
        PlannerFixtureProtocol.install { _ in .init(data: Data(repeating: 32, count: 1_048_577)) }
        try await rejects("large service response") { _ = try await networking.searchPlaces("餐馆", city: "青岛") }
        PlannerFixtureProtocol.install { _ in .init(data: Data("not-json".utf8)) }
        try await rejects("malformed service JSON") { _ = try await networking.searchPlaces("餐馆", city: "青岛") }

        let firstRoute = PlannerRoute(id: "real-route-one", mode: .driving, durationSeconds: 1200, distanceMeters: 5000,
            summary: "香港路", costDescription: "过路费约 ¥5.5", fetchedAt: now)
        let secondRoute = PlannerRoute(id: "real-route-two", mode: .driving, durationSeconds: 2400, distanceMeters: 4500,
            summary: "东海路", fetchedAt: now)
        let analysisArrival = now.addingTimeInterval(6 * 3600)
        let privateEvent = PlanEvent(title: "私人日历标题不得发给模型", start: analysisArrival.addingTimeInterval(-3000),
            end: analysisArrival.addingTimeInterval(-2200), notes: "私人日历备注不得发给模型")
        let options = try TripPlanning.analysisOptions(title: "晚餐", origin: origin, destination: destination,
            routes: [firstRoute, secondRoute], arrival: analysisArrival, durationMinutes: 90, bufferMinutes: 15, events: [privateEvent], now: now)
        func analyze(_ input: [PlannerRouteOption]? = nil, client: PlannerNetworking? = nil) async throws -> PlannerRouteAnalysis {
            try await (client ?? networking).analyzeRoutes(request: "尽量省时", origin: origin, destination: destination,
                options: input ?? options, durationMinutes: 90, bufferMinutes: 15, appleCalendarChecked: true, now: now)
        }
        let validAnalysis: [String: Any] = ["recommendedRouteID": firstRoute.id, "summary": "方案一耗时较短且没有已知冲突，符合省时偏好。",
            "assessments": [
                ["routeID": firstRoute.id, "benefits": "预计耗时较短。", "tradeoffs": "路程略长，过路费不等于完整费用。"],
                ["routeID": secondRoute.id, "benefits": "距离稍短。", "tradeoffs": "耗时较长且有已知日程冲突。"]],
            "cautions": ["未来交通可能变化，出发前重新查询。"]]
        func analysisModel(_ object: [String: Any]) throws {
            let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            try model(text)
        }
        let analysisText = String(data: try JSONSerialization.data(withJSONObject: validAnalysis), encoding: .utf8)!
        let analysisEnvelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": analysisText]]]])
        var inspectedAnalysis = false
        PlannerFixtureProtocol.install { request in
            let payload = try JSONSerialization.jsonObject(with: body(request)) as? [String: Any]
            let messages = payload?["messages"] as? [[String: String]]
            let user = messages?.last?["content"] ?? ""
            let data = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any]
            let submitted = data?["routes"] as? [[String: Any]] ?? []
            inspectedAnalysis = request.url?.path == "/v1/chat/completions"
                && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-personal-key"
                && submitted.count == 2 && submitted[0]["routeID"] as? String == firstRoute.id
                && submitted[0]["durationSeconds"] as? Int == 1200
                && submitted[0]["conflictCount"] as? Int == 0 && submitted[1]["conflictCount"] as? Int == 1
                && submitted[1]["reportedCost"] is NSNull
                && data?["calendarScope"] as? String == "app_and_readable_apple_calendar"
                && data?["timeZone"] as? String == "Asia/Shanghai" && user.contains("尽量省时")
                && !user.contains(privateEvent.title) && !user.contains(privateEvent.notes)
                && !user.contains("fixture-personal-key") && !user.contains("fixture-map-key")
                && !user.contains("longitude") && !user.contains("transactions")
            return .init(data: analysisEnvelope)
        }
        let analysis = try await analyze()
        try expect(inspectedAnalysis, "comparison sends real route facts, calculated time and conflict counts without private calendar or keys")
        try expect(analysis.recommendedRouteID == firstRoute.id && analysis.assessments.count == 2
            && analysis.assessment(for: secondRoute.id)?.tradeoffs.contains("冲突") == true && analysis.model == config.model,
            "valid qualitative analysis is linked to known routes")
        try model("```json\n" + analysisText + "\n```")
        try expect(try await analyze().recommendedRouteID == firstRoute.id, "comparison accepts complete JSON fence")
        var invalidAnalyses: [[String: Any]] = []
        var unknownAnalysis = validAnalysis; unknownAnalysis["recommendedRouteID"] = "invented-route"; invalidAnalyses.append(unknownAnalysis)
        var blockedAnalysis = validAnalysis; blockedAnalysis["recommendedRouteID"] = secondRoute.id; invalidAnalyses.append(blockedAnalysis)
        var duplicateAnalysis = validAnalysis
        let assessmentRows = validAnalysis["assessments"] as! [[String: Any]]
        duplicateAnalysis["assessments"] = [assessmentRows[0], assessmentRows[0]]; invalidAnalyses.append(duplicateAnalysis)
        var missingAnalysis = validAnalysis; missingAnalysis["assessments"] = [assessmentRows[0]]; invalidAnalyses.append(missingAnalysis)
        var extraAnalysis = validAnalysis; extraAnalysis["departure"] = "2026-10-02 20:00"; invalidAnalyses.append(extraAnalysis)
        var extraRow = assessmentRows[0]; extraRow["price"] = 4
        var extraRowAnalysis = validAnalysis; extraRowAnalysis["assessments"] = [extraRow, assessmentRows[1]]; invalidAnalyses.append(extraRowAnalysis)
        var longAnalysis = validAnalysis; longAnalysis["summary"] = String(repeating: "字", count: 801); invalidAnalyses.append(longAnalysis)
        var noSummary = validAnalysis; noSummary["summary"] = " \n "; invalidAnalyses.append(noSummary)
        var tooManyCautions = validAnalysis; tooManyCautions["cautions"] = Array(repeating: "提醒", count: 6); invalidAnalyses.append(tooManyCautions)
        var wrongType = validAnalysis; wrongType["cautions"] = [true]; invalidAnalyses.append(wrongType)
        var unknownRow = assessmentRows[1]; unknownRow["routeID"] = "unknown-route"
        var unknownAssessment = validAnalysis; unknownAssessment["assessments"] = [assessmentRows[0], unknownRow]; invalidAnalyses.append(unknownAssessment)
        for invalid in invalidAnalyses {
            try analysisModel(invalid)
            try await rejects("unsupported or unsafe comparison rejected") { _ = try await analyze() }
        }
        try install(["choices": [["finish_reason": "length", "message": ["content": analysisText]]]])
        try await rejects("truncated model generation cannot become a recommendation") { _ = try await analyze() }
        try await rejects("comparison requires configured model") { _ = try await analyze(client: noKeys) }
        var invalidOptions = options; invalidOptions[0].departure = invalidOptions[0].departure.addingTimeInterval(60)
        try await rejects("comparison cannot substitute model-calculated departure times") { _ = try await analyze(invalidOptions) }
        try await rejects("comparison rejects duplicate candidate IDs") { _ = try await analyze([options[0], options[0]]) }
        try await rejects("empty map results cannot trigger invented comparison") { _ = try await analyze([]) }
        let single = [options[0]]
        var singleAnalysis = validAnalysis; singleAnalysis["assessments"] = [assessmentRows[0]]
        singleAnalysis["summary"] = "只有这一条实际路线可分析。"
        try analysisModel(singleAnalysis)
        try expect(try await analyze(single).assessments.count == 1, "single genuine route does not require invented alternatives")
        try install(["error": ["message": "fixture-personal-key refused"]], status: 429)
        do { _ = try await analyze(); throw AppFailure.message("FAIL: analysis quota error accepted") }
        catch { try expect(!error.localizedDescription.contains("fixture-personal-key") && error.localizedDescription.contains("额度"),
            "comparison quota error preserves privacy and permits manual fallback") }
        var compatibilityCalls = 0
        PlannerFixtureProtocol.install { request in
            compatibilityCalls += 1
            let payload = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
            if payload["response_format"] != nil { return .init(status: 400, data: Data("{}".utf8)) }
            guard payload["temperature"] == nil else { throw AppFailure.message("FAIL: optional parameter was not removed") }
            return .init(data: envelope)
        }
        _ = try await networking.understand("明天安排", preferences: preferences, now: now)
        try expect(compatibilityCalls == 2, "parameter rejection makes exactly one compatible retry")
        var badEndpointCalls = 0
        PlannerFixtureProtocol.install { _ in badEndpointCalls += 1; return .init(status: 404, data: Data("{\"error\":\"fixture-personal-key\"}".utf8)) }
        do { _ = try await networking.understand("明天安排", preferences: preferences); throw AppFailure.message("FAIL: bad endpoint accepted") }
        catch { try expect(badEndpointCalls == 1 && error.localizedDescription.contains("404") && !error.localizedDescription.contains("fixture-personal-key"), "404 is actionable without retry or server secret") }
        let deepseek = PlannerNetworking(configuration: PlannerAPIConfiguration(modelBaseURL: "https://api.deepseek.com", model: "deepseek-flash", modelKey: "fixture-personal-key"), session: session)
        var nonThinking = false
        PlannerFixtureProtocol.install { request in
            let payload = try JSONSerialization.jsonObject(with: body(request)) as! [String: Any]
            nonThinking = (payload["thinking"] as? [String: String])?["type"] == "disabled" && request.url?.path == "/chat/completions"
            return .init(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"ok\":true}"]]]]))
        }
        try expect(try await deepseek.testModel().contains("成功") && nonThinking, "official DeepSeek connection test disables thinking for short JSON budget")
        let scheduleText = #"{"events":[{"title":"会议","date":"2026-10-02","startTime":"15:00","endDate":"2026-10-02","endTime":"16:00","location":null},{"title":"健身","date":"2026-10-02","startTime":"17:00","endDate":"2026-10-02","endTime":"18:00","location":"健身房"}],"clarification":""}"#
        try model(scheduleText)
        let planned = try await networking.understandSchedule("今天15点到16点开会，17点到18点健身", now: now)
        try expect(planned.count == 2 && planned[0].title == "会议" && planned[1].location == "健身房", "model schedule supports multiple validated appointments")
        try model(#"{"events":[],"clarification":"结束时间不明确"}"#)
        try await rejects("incomplete spoken schedule never writes partial appointments") { _ = try await networking.understandSchedule("今天开会", now: now) }
        let modelListData = try JSONSerialization.data(withJSONObject: ["data":[["id":"fixture-model"],["id":"fixture-model"],["id":"other-model"],["id":"invalid\nmodel"]]])
        var inspectedList = false
        PlannerFixtureProtocol.install { request in
            inspectedList = request.httpMethod == "GET" && request.url?.path == "/v1/models" && request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-personal-key" && body(request).isEmpty
            return .init(data:modelListData)
        }
        try expect(try await networking.listModels() == ["fixture-model","other-model"] && inspectedList, "model list is authenticated non-generation request with validated IDs")
        try await rejects("account management page cannot receive API requests") { _ = try PlannerAPIConfiguration.modelEndpoint("https://platform.deepseek.com/usage") }
        let rejection = try JSONSerialization.data(withJSONObject:["error":["param":"model","message":"Invalid model fixture-personal-key"]])
        var rejectedRequests = 0
        PlannerFixtureProtocol.install { _ in rejectedRequests += 1; return .init(status:400, data:rejection) }
        do { _ = try await networking.testModel(); try expect(false, "model rejection must fail") }
        catch let failure as PlannerServiceError {
            try expect(failure.localizedDescription.contains("获取可用模型") && !failure.localizedDescription.contains("fixture-personal-key") && rejectedRequests == 1, "model-specific diagnostic is safe and avoids futile generation retry")
        }
        let relaxedContent = #"{"events":[{"title":"买菜","date":"2026-10-02","startTime":null,"endDate":null,"endTime":null,"location":null}],"clarification":""}"#
        let relaxedData = try JSONSerialization.data(withJSONObject:["choices":[["message":["content":relaxedContent]]],"usage":["total_tokens":245]])
        var bounded = false
        PlannerFixtureProtocol.install { request in
            let payload = try JSONSerialization.jsonObject(with:body(request)) as? [String:Any]
            bounded = payload?["max_tokens"] as? Int == 1400
            return .init(data:relaxedData)
        }
        try expect(try await networking.understandSchedule("今天去买菜", now:now)[0].isAllDay && bounded, "flexible model schedule limits output and preserves missing time")
        try expect(await networking.lastModelTokens == 245, "model usage is read from provider rather than estimated")
        try await rejects("spoken model input limit enforced") { _ = try await networking.understandSchedule(String(repeating:"安排",count:601)) }
        return checks
    }
}
