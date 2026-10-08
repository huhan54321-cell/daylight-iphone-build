import Foundation
import Security

// Intentionally not Codable: credentials are never part of an app backup.
struct PlannerAPIConfiguration: Sendable {
    var modelBaseURL = "https://api.deepseek.com/v1"
    var model = ""
    var modelKey = ""
    var amapKey = ""

    func validated() throws -> PlannerAPIConfiguration {
        var copy = self
        copy.modelBaseURL = modelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.modelKey = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.amapKey = amapKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !copy.modelBaseURL.isEmpty { _ = try Self.modelEndpoint(copy.modelBaseURL) }
        guard copy.model.count <= 160, copy.modelKey.count <= 4096, copy.amapKey.count <= 256,
              [copy.model, copy.modelKey, copy.amapKey].allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw PlannerServiceError.invalidConfiguration
        }
        return copy
    }

    static func modelEndpoint(_ text: String) throws -> URL {
        guard var components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              host.contains("."), !host.hasSuffix("."),
              !["localhost", "local", "internal", "invalid", "test"].contains(host.split(separator: ".").last.map(String.init) ?? ""),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !host.contains("%"), (components.port == nil || (1...65535).contains(components.port!)),
              text.count <= 1024, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PlannerServiceError.invalidEndpoint
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "platform.deepseek.com" { throw AppFailure.message("这是 DeepSeek 账号管理页面。调用地址请填写 https://api.deepseek.com，保留该平台生成的 API Key。") }
        components.path = path.hasSuffix("chat/completions") ? "/" + path : "/" + (path.isEmpty ? "chat/completions" : path + "/chat/completions")
        guard let endpoint = components.url else { throw PlannerServiceError.invalidEndpoint }
        return endpoint
    }
}

enum PlannerServiceError: Error, LocalizedError, Sendable {
    case missingModel, missingAMap, invalidEndpoint, invalidConfiguration, invalidInput, searchTooLong
    case invalidResponse, responseTooLarge, noCityCode, timeout, offline, cancelled, transport
    case http(Int), rejectedModel(Int), mapDenied, mapCode(String), keychain

    var errorDescription: String? {
        switch self {
        case .missingModel: return "请先在智能计划设置中填写模型名称、模型 API Key 和 HTTPS 接口地址。"
        case .missingAMap: return "请先在智能计划设置中填写高德 Web 服务 API Key。"
        case .invalidEndpoint: return "模型接口需使用公网 HTTPS 地址，不能包含账号、查询参数或本地地址。"
        case .invalidConfiguration: return "接口配置格式不正确，请检查模型名称和密钥。"
        case .invalidInput: return "输入内容不完整或过长，请填写具体地点和城市后重试。"
        case .searchTooLong: return "地点搜索词过长，请缩短到 80 个字以内再查询。"
        case .invalidResponse: return "服务返回的数据不完整或格式不正确，请重试或手动完善计划。"
        case .responseTooLarge: return "服务返回内容过长，已停止处理。"
        case .noCityCode: return "地点缺少城市编码，暂时不能查询公交路线；请重新选择高德地点。"
        case .timeout: return "查询超时，请检查网络后重试。"
        case .offline: return "当前无法连接网络，请联网后重试。"
        case .cancelled: return "查询已取消。"
        case .transport: return "暂时无法连接服务，请检查网络和接口设置后重试。"
        case .rejectedModel(let code): return "模型名称未被服务接受（HTTP \(code)）。请点击“获取可用模型”选择账号可用的模型，再测试连接。"
        case .http(let code):
            if code == 400 || code == 422 { return "请求参数未被服务接受（HTTP \(code)）。请检查模型名称、接口格式；当前支持 Chat Completions 兼容接口。" }
            if code == 404 { return "接口或模型不存在（HTTP 404）。请核对服务地址和模型名称，不能填写服务商网页地址。" }
            if code == 402 { return "模型服务余额不足（HTTP 402），请检查 API 账户余额。" }
            if code == 401 || code == 403 { return "服务拒绝访问（HTTP \(code)），请检查 API Key 和接口权限。" }
            if code == 429 { return "请求过于频繁或额度不足（HTTP 429），请检查服务额度。" }
            if (300...399).contains(code) { return "接口要求跳转（HTTP \(code)）。请填写服务商的实际 API 地址；密钥不会转发到跳转地址。" }
            return "服务返回 HTTP \(code)，请稍后重试或检查服务商状态。"
        case .mapDenied: return "高德查询未成功，请检查 Web 服务 Key、接口权限和调用额度。"
        case .mapCode(let code):
            switch code {
            case "10001": return "高德 Key 无效（10001），请使用 Web 服务 Key。"
            case "10003", "10019", "10020", "10021": return "高德额度或调用频率受限（\(code)），请检查账号额度。"
            case "10004": return "高德 IP 白名单不允许此次请求（10004），请检查 Key 的限制设置。"
            case "10009": return "高德 Key 平台类型不匹配（10009），本功能需要 Web 服务 Key。"
            default: return "高德查询失败（\(code)），请检查 Web 服务 Key 和接口权限。"
            }
        case .keychain: return "无法读取或保存接口密钥，请解锁手机后重试。"
        }
    }
}

enum PlannerCredentials {
    private static let service = "com.personalassistant.Daylight.planner"
    private static let account = "personal-api-configuration"

    static func load() throws -> PlannerAPIConfiguration {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return PlannerAPIConfiguration() }
        guard status == errSecSuccess, let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { throw PlannerServiceError.keychain }
        let stored = PlannerAPIConfiguration(modelBaseURL: object["modelBaseURL"] ?? "https://api.deepseek.com/v1",
            model: object["model"] ?? "", modelKey: object["modelKey"] ?? "", amapKey: object["amapKey"] ?? "")
        // An old invalid address must remain editable. All network operations and
        // writes validate it again before using the stored credentials.
        var fields = stored; fields.modelBaseURL = "https://api.deepseek.com"
        _ = try fields.validated()
        guard stored.modelBaseURL.count <= 1024 else { throw PlannerServiceError.invalidConfiguration }
        return stored
    }

    static func save(_ configuration: PlannerAPIConfiguration) throws {
        let value = try configuration.validated()
        let object = ["modelBaseURL": value.modelBaseURL, "model": value.model, "modelKey": value.modelKey, "amapKey": value.amapKey]
        let data = try JSONSerialization.data(withJSONObject: object)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PlannerServiceError.keychain }
        var insertion = identity
        attributes.forEach { insertion[$0.key] = $0.value }
        guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw PlannerServiceError.keychain }
    }

    static func clear() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PlannerServiceError.keychain }
    }

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}
