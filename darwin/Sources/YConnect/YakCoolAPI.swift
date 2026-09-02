import Foundation

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

enum RequestCredential: Equatable {
    case none
    case webCookies([StoredWebCookie])
    case apiKey(String)
}

struct PublicMeResponse: Decodable {
    let user: YakCoolUser
    let staffSession: Bool?

    enum CodingKeys: String, CodingKey {
        case user
        case staffSession = "staff_session"
    }
}

struct HealthResponse: Decodable {
    let status: String
}

struct APIErrorPayload: Decodable {
    let error: String?
    let message: String?
}

struct CompletionProbeResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let text: String?
    }
    let choices: [Choice]?
}

final class YakCoolAPI {
    static let productionOrigin = URL(string: "https://yakcool.com")!
    static let productionGateway = URL(string: "https://aibalance.yaklang.com")!

    let origin: URL
    private let transport: HTTPTransport
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(origin: URL = productionOrigin, transport: HTTPTransport? = nil) {
        self.origin = origin
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.transport = URLSession(
                configuration: configuration,
                delegate: NoRedirectSessionDelegate.shared,
                delegateQueue: nil
            )
        }
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    static func normalizedAPIKey(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw YConnectError.invalidCredential("请输入有效的 YakCool API Key")
        }
        return value
    }

    func health() async throws -> HealthResponse {
        try await get("/api/health", credential: .none)
    }

    func verifyWebCookies(_ cookies: [StoredWebCookie]) async throws -> PublicMeResponse {
        guard !cookies.filter({ !$0.isExpired }).isEmpty else {
            throw YConnectError.invalidCredential("登录会话不存在或已经过期")
        }
        return try await get("/api/auth/me", credential: .webCookies(cookies))
    }

    func dashboard(cookies: [StoredWebCookie]) async throws -> DashboardResponse {
        try await get("/api/user/dashboard", credential: .webCookies(cookies))
    }

    func account(cookies: [StoredWebCookie]) async throws -> UserAccountResponse {
        try await get("/api/user/account", credential: .webCookies(cookies))
    }

    func apiKeys(cookies: [StoredWebCookie]) async throws -> APIKeysResponse {
        try await get("/api/user/api-keys", credential: .webCookies(cookies))
    }

    func models(cookies: [StoredWebCookie]) async throws -> ModelsResponse {
        try await get("/api/user/models", credential: .webCookies(cookies))
    }

    func createAPIKey(label: String, cookies: [StoredWebCookie]) async throws -> CreateKeyResponse {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "_.-"))
        guard !value.isEmpty, value.count <= 40,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw YConnectError.invalidCredential("名称仅支持 1–40 个字母、数字、空格、下划线、点或连字符")
        }
        return try await send(
            "/api/user/api-keys",
            method: "POST",
            credential: .webCookies(cookies),
            body: ["label": value]
        )
    }

    func deleteAPIKey(id: Int64, cookies: [StoredWebCookie]) async throws -> StatusResponse {
        guard id > 0 else { throw YConnectError.invalidCredential("API Key ID 无效") }
        return try await send(
            "/api/user/api-keys/\(id)",
            method: "DELETE",
            credential: .webCookies(cookies),
            body: Optional<[String: String]>.none
        )
    }

    func redeem(code: String, cookies: [StoredWebCookie]) async throws -> StatusResponse {
        let value = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard (12...64).contains(value.count) else {
            throw YConnectError.invalidCredential("兑换码长度应为 12 至 64 个字符")
        }
        return try await send(
            "/api/user/redeem",
            method: "POST",
            credential: .webCookies(cookies),
            body: ["code": value]
        )
    }

    func logout(cookies: [StoredWebCookie]) async throws -> StatusResponse {
        try await send(
            "/api/auth/logout",
            method: "POST",
            credential: .webCookies(cookies),
            body: Optional<[String: String]>.none
        )
    }

    func keyInfo(apiKey: String) async throws -> BusinessKeyInfoResponse {
        let key = try Self.normalizedAPIKey(apiKey)
        return try await get("/api/key/info", credential: .apiKey(key))
    }

    func keyModels(apiKey: String) async throws -> BusinessKeyModelsResponse {
        let key = try Self.normalizedAPIKey(apiKey)
        return try await get("/api/key/models", credential: .apiKey(key))
    }

    func completionProbe(gateway: URL, apiKey: String, model: String) async throws -> String {
        let key = try Self.normalizedAPIKey(apiKey)
        guard let host = gateway.host?.lowercased(),
              gateway.scheme?.lowercased() == "https",
              host == "aibalance.yaklang.com" || host.hasSuffix(".yaklang.com") else {
            throw YConnectError.unsupported("服务地址不是受信任的 Yaklang HTTPS 网关")
        }
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, modelID.count <= 200 else {
            throw YConnectError.invalidCredential("请选择有效的模型")
        }
        let endpoint = gateway
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("completions")
        var request = URLRequest(url: endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("YConnect/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try encoder.encode(CompletionProbeRequest(model: modelID))
        let data = try await checkedData(for: request)
        let response: CompletionProbeResponse = try decodeResponse(data)
        let text = response.choices?.first?.message?.content ?? response.choices?.first?.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct CompletionProbeRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages = [Message(role: "user", content: "Reply exactly with OK.")]
        let maxTokens = 8
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    private func get<T: Decodable>(_ path: String, credential: RequestCredential) async throws -> T {
        var request = try makeRequest(path: path, method: "GET", credential: credential)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try decodeResponse(await checkedData(for: request))
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        credential: RequestCredential,
        body: Body?
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method, credential: credential)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return try decodeResponse(await checkedData(for: request))
    }

    private func makeRequest(path: String, method: String, credential: RequestCredential) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains("?"),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.host?.lowercased() == origin.host?.lowercased() else {
            throw YConnectError.unsupported("请求路径不安全")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("YConnect/0.1", forHTTPHeaderField: "User-Agent")
        switch credential {
        case .none:
            break
        case .apiKey(let key):
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .webCookies(let cookies):
            let valid = cookies.filter(\.isSafeForRequest)
            guard !valid.isEmpty else {
                throw YConnectError.invalidCredential("登录会话不存在或已经过期")
            }
            let header = valid.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func checkedData(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw YConnectError.invalidResponse }
            guard data.count <= 5 * 1_024 * 1_024 else {
                throw YConnectError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let payload = try? decoder.decode(APIErrorPayload.self, from: data)
                let fallback = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                throw YConnectError.server(
                    status: http.statusCode,
                    code: payload?.error ?? "http_\(http.statusCode)",
                    message: payload?.message ?? payload?.error ?? fallback
                )
            }
            return data
        } catch let error as YConnectError {
            throw error
        } catch {
            throw YConnectError.transport("网络请求失败：\(error.localizedDescription)")
        }
    }

    private func decodeResponse<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw YConnectError.invalidResponse
        }
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectSessionDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
