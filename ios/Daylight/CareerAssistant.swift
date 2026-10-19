import Foundation
import Combine

// A bounded JSON document keeps older clients compatible with added server fields.
enum CareerAssistantJSON: Codable, Identifiable, Equatable, Sendable {
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

