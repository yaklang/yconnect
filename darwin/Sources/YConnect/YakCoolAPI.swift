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

struct ModelProbeResult: Equatable {
    let wireProtocol: AIProtocol
    let text: String

    var protocolName: String { wireProtocol.title }
}

final class YakCoolAPI {
    static let productionOrigin = URL(string: "https://yakcool.com")!
    static let productionGateway = URL(string: "https://aibalance.yaklang.com")!
    static let userAgent = "YConnect/0.2.0"

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
        try await modelProbe(
            gateway: gateway,
            apiKey: apiKey,
            model: model,
            wireProtocol: .chatCompletions
        ).text
    }

    func modelProbe(
        gateway: URL,
        apiKey: String,
        model: String,
        wireProtocol: AIProtocol
    ) async throws -> ModelProbeResult {
        let key = try Self.normalizedAPIKey(apiKey)
        let modelID = try Self.normalizedModelID(model)
        let endpoint = try Self.gatewayEndpoint(gateway, for: wireProtocol)
        var request = URLRequest(url: endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        switch wireProtocol {
        case .chatCompletions:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try encoder.encode(ChatCompletionsProbeRequest(model: modelID))
        case .responses:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try encoder.encode(ResponsesProbeRequest(model: modelID))
        case .anthropicMessages:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try encoder.encode(AnthropicMessagesProbeRequest(model: modelID))
        default:
            throw YConnectError.unsupported("YConnect 暂不支持通过 \(wireProtocol.title) 执行最小模型调用")
        }

        let data = try await checkedData(for: request)
        let text: String
        switch wireProtocol {
        case .chatCompletions:
            let response: ChatCompletionsProbeResponse = try decodeResponse(data)
            text = response.choices.first?.message?.content ?? response.choices.first?.text ?? ""
        case .responses:
            let response: ResponsesProbeResponse = try decodeResponse(data)
            if let outputText = response.outputText {
                text = outputText
            } else {
                var extractedText = ""
                for item in response.output {
                    guard let content = item.content,
                          let block = content.first(where: {
                              $0.type == nil || $0.type == "output_text"
                          }) else { continue }
                    extractedText = block.text ?? ""
                    break
                }
                text = extractedText
            }
        case .anthropicMessages:
            let response: AnthropicMessagesProbeResponse = try decodeResponse(data)
            text = response.content.first(where: { $0.type == nil || $0.type == "text" })?.text ?? ""
        default:
            // Unsupported values are rejected before a request is sent.
            throw YConnectError.unsupported("YConnect 暂不支持通过 \(wireProtocol.title) 执行最小模型调用")
        }
        return ModelProbeResult(
            wireProtocol: wireProtocol,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static let probeText = "Reply exactly with OK."

    private struct ChatCompletionsProbeRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages = [Message(role: "user", content: YakCoolAPI.probeText)]
        let maxTokens = 8
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct ResponsesProbeRequest: Encodable {
        let model: String
        let input = YakCoolAPI.probeText
        let maxOutputTokens = 8
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model, input, stream
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct AnthropicMessagesProbeRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let maxTokens = 8
        let messages = [Message(role: "user", content: YakCoolAPI.probeText)]
        let stream = false

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatCompletionsProbeResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let text: String?
        }
        let choices: [Choice]
    }

    private struct ResponsesProbeResponse: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String?
                let text: String?
            }
            let content: [Content]?
        }
        let output: [Output]
        let outputText: String?

        enum CodingKeys: String, CodingKey {
            case output
            case outputText = "output_text"
        }
    }

    private struct AnthropicMessagesProbeResponse: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
        }
        let content: [Content]
    }

    private static func normalizedModelID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 200,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw YConnectError.invalidCredential("请选择有效的模型")
        }
        return value
    }

    private static func gatewayEndpoint(_ gateway: URL, for wireProtocol: AIProtocol) throws -> URL {
        guard let components = URLComponents(url: gateway, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == productionGateway.host || host.hasSuffix(".yaklang.com"),
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw YConnectError.unsupported("服务地址不是受信任的 Yaklang HTTPS 网关")
        }

        let path: String
        switch wireProtocol {
        case .chatCompletions: path = "/v1/chat/completions"
        case .responses: path = "/v1/responses"
        case .anthropicMessages: path = "/v1/messages"
        default:
            throw YConnectError.unsupported("YConnect 暂不支持通过 \(wireProtocol.title) 执行最小模型调用")
        }
        var endpoint = components
        endpoint.path = path
        guard let url = endpoint.url else {
            throw YConnectError.unsupported("服务地址不是受信任的 Yaklang HTTPS 网关")
        }
        return url
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
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
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
