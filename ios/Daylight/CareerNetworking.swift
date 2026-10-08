import Foundation
import Security

struct CareerAPIConfiguration: Sendable {
    var baseURL = ""
    var token = ""

    func endpoint(refresh: Bool) throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 1024, var parts = URLComponents(string: value),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !host.contains("%"),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CareerServiceError.configuration }
        if parts.scheme?.lowercased() == "http", !Self.isLocal(host) { throw CareerServiceError.insecure }
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, credential.count <= 4096,
              !credential.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CareerServiceError.token }
        let base = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = (base.isEmpty ? "" : "/" + base) + "/v1/career/" + (refresh ? "refresh" : "feed")
        guard let endpoint = parts.url else { throw CareerServiceError.configuration }
        return endpoint
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let components = parts.compactMap { Int($0) }
        guard components.count == 4, components.allSatisfy({ (0...255).contains($0) }) else { return false }
        return components[0] == 10 || components[0] == 127 ||
            (components[0] == 192 && components[1] == 168) ||
            (components[0] == 172 && (16...31).contains(components[1])) ||
            (components[0] == 169 && components[1] == 254)
    }
}

enum CareerServiceError: Error, LocalizedError, Sendable {
    case configuration, insecure, token, keychain, timeout, offline, transport, http(Int), missingSeed
    var errorDescription: String? {
        switch self {
        case .configuration: return "请填写采集服务的完整地址，例如 http://192.168.1.10:4176。不能填写招聘网站或模型接口地址。"
        case .insecure: return "公网采集服务必须使用 HTTPS；HTTP 仅允许本机或局域网地址。"
        case .token: return "请填写采集服务的访问令牌，和 DeepSeek API Key 分开配置。"
        case .keychain: return "无法保存采集服务密钥，请解锁手机后重试。"
        case .timeout: return "岗位采集超时。电脑服务需保持运行；上次内容仍然可用。"
        case .offline: return "无法连接采集服务，请检查 Wi-Fi、电脑地址和服务是否运行。上次内容仍然可用。"
        case .transport: return "连接采集服务失败，请检查地址、电脑服务和网络权限。上次内容仍然可用。"
        case .http(let code):
            if code == 401 || code == 403 { return "采集服务拒绝访问（HTTP \(code)），请核对访问令牌。" }
            if code == 404 { return "服务没有岗位接口（HTTP 404），请检查地址和采集服务版本。" }
            if code == 409 { return "服务正在采集，请稍后读取结果；上次内容仍然可用。" }
            if code == 429 { return "请求过于频繁，请稍后重试；上次内容仍然可用。" }
            if (300...399).contains(code) { return "服务要求跳转（HTTP \(code)），请填写实际地址；令牌不会随跳转转发。" }
            return "采集服务返回 HTTP \(code)，上次内容仍然可用。"
        case .missingSeed: return "内置岗位资料未能读取，请连接采集服务获取岗位。"
        }
    }
}

enum CareerCredentials {
    private static let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.personalassistant.Daylight.career",
        kSecAttrAccount as String: "collector-configuration", kSecAttrSynchronizable as String: false]

    static func load() throws -> CareerAPIConfiguration {
        var query = identity
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return CareerAPIConfiguration() }
        guard status == errSecSuccess, let data = result as? Data,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { throw CareerServiceError.keychain }
        return CareerAPIConfiguration(baseURL: fields["baseURL"] ?? "", token: fields["token"] ?? "")
    }

    static func save(_ configuration: CareerAPIConfiguration) throws {
        var value = configuration
        value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.token = value.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.baseURL.isEmpty || !value.token.isEmpty { _ = try value.endpoint(refresh: false) }
        let data = try JSONSerialization.data(withJSONObject: ["baseURL": value.baseURL, "token": value.token])
        let changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw CareerServiceError.keychain }
        var query = identity; changes.forEach { query[$0.key] = $0.value }
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CareerServiceError.keychain }
    }
}

private final class CareerRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor CareerNetworking {
    private let configuration: CareerAPIConfiguration
    private let session: URLSession
    private let redirectPolicy = CareerRedirectPolicy()

    init(configuration: CareerAPIConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 90
            settings.timeoutIntervalForResource = 150
            settings.urlCache = nil; settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false
            self.session = URLSession(configuration: settings)
        }
    }

    func fetch(refresh: Bool) async throws -> CareerFeed {
        var request = URLRequest(url: try configuration.endpoint(refresh: refresh))
        request.httpMethod = refresh ? "POST" : "GET"
        request.setValue("Bearer " + configuration.token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if refresh { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = Data("{}".utf8) }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectPolicy)
            guard let http = response as? HTTPURLResponse else { throw CareerFeedError.invalidFeed }
            guard http.statusCode == 200 || (refresh && http.statusCode == 202) else { throw CareerServiceError.http(http.statusCode) }
            guard response.expectedContentLength <= 4_194_304 else { throw CareerFeedError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4_194_304 else { throw CareerFeedError.tooLarge }
                data.append(byte)
            }
            return try CareerFeed.decode(data)
        } catch let error as URLError {
            if error.code == .timedOut { throw CareerServiceError.timeout }
            if [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) { throw CareerServiceError.offline }
            if error.code == .cancelled { throw CancellationError() }
            throw CareerServiceError.transport
        } catch let error as DecodingError {
            _ = error
            throw CareerFeedError.invalidFeed
        }
    }
}
