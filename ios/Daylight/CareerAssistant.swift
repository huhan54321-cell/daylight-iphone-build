import Foundation
import Combine

// A bounded JSON document keeps older clients compatible with added server fields.
enum CareerAssistantJSON: Codable, Identifiable, Equatable {
    case object([String: CareerAssistantJSON]), array([CareerAssistantJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    subscript(_ key: String) -> Self { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var strings: [String] { array.map(\.string).filter { !$0.isEmpty } }
    var array: [Self] { if case .array(let v) = self { return v }; return [] }
    var dictionary: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var int: Int { if case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }; return 0 }
    var id: String { self["id"].string }
    var display: String { switch self { case .string(let v): return v.isEmpty ? "未提及" : v; case .number: return String(int); case .bool(let v): return v ? "是" : "否"; default: return "未提及" } }
    static func from(_ value: Any) throws -> Self { try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value)) }
}

@MainActor
final class CareerAssistantClient: ObservableObject {
    @Published private(set) var snapshot: CareerAssistantJSON = .object([:])
    @Published private(set) var online = false
    @Published private(set) var busy = false
    @Published var message: String?
    private let configuration: CareerAPIConfiguration
    static var cacheURL: URL? { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("DaylightCareer/assistant-v2.json") }
    init(configuration: CareerAPIConfiguration) {
        self.configuration = configuration
        if let url = Self.cacheURL, let bytes = try? Data(contentsOf: url), bytes.count <= 16_777_216,
           let value = try? JSONDecoder().decode(CareerAssistantJSON.self, from: bytes), value["schemaVersion"].int == 2 { snapshot = value }
    }
    func request(_ route: String, body: [String: Any]? = nil) async throws -> CareerAssistantJSON {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let result = try await CareerNetworking(configuration: configuration).assistantRequest(route: route, body: data)
        return try JSONDecoder().decode(CareerAssistantJSON.self, from: result)
    }
    func reload() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let value = try await request("snapshot")
            guard value["schemaVersion"].int == 2 else { throw AppFailure.message("电脑服务版本不兼容，请更新服务。") }
            if let url = Self.cacheURL {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            snapshot = value; online = true; message = nil
        } catch { online = false; message = error.localizedDescription }
    }
    @discardableResult func send(_ route: String, body: [String: Any] = [:]) async -> CareerAssistantJSON? {
        guard online else { message = "电脑服务离线。可以查看缓存，联网后再提交操作。"; return nil }
        do { let value = try await request(route, body: body); await reload(); return value }
        catch { message = error.localizedDescription; return nil }
    }
    func monitor() async {
        await reload()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(snapshot["tasks"].array.contains { $0["state"].string == "running" } ? 5 : 30)) }
            catch { return }
            await reload()
        }
    }
}
