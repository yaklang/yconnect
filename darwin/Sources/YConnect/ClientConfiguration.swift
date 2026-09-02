import Foundation

/// Protocol identifiers returned by YakCool's `/api/key/models` endpoint.
///
/// This is intentionally a value type rather than a closed enum. The gateway
/// may add protocols without requiring a YConnect update just to decode them.
struct AIProtocol: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static let chatCompletions = AIProtocol(rawValue: "chat_completions")
    static let responses = AIProtocol(rawValue: "responses")
    static let anthropicMessages = AIProtocol(rawValue: "anthropic_messages")

    var title: String {
        switch self {
        case .chatCompletions: return "Chat Completions"
        case .responses: return "Responses"
        case .anthropicMessages: return "Anthropic Messages"
        default: return rawValue
        }
    }
}

struct ClientID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }

    static let openCode = ClientID(rawValue: "opencode")
    static let pi = ClientID(rawValue: "pi")
    static let claudeCode = ClientID(rawValue: "claude-code")
    static let codex = ClientID(rawValue: "codex")
    static let grokBuild = ClientID(rawValue: "grok-build")
    static let claudeDesktop = ClientID(rawValue: "claude-desktop")
    static let geminiCLI = ClientID(rawValue: "gemini-cli")
    static let openClaw = ClientID(rawValue: "openclaw")
    static let hermes = ClientID(rawValue: "hermes")
}

struct ClientDescriptor: Identifiable, Hashable, Sendable {
    enum Availability: String, Hashable, Sendable {
        case ready
        case requiresBridge
        case planned
    }

    let id: ClientID
    let name: String
    let shortName: String
    let symbol: String
    let summary: String
    let supportedProtocols: [AIProtocol]
    let configurationPath: String
    let restartNote: String
    let availability: Availability

    var protocolSummary: String {
        supportedProtocols.map(\.title).joined(separator: " · ")
    }
}

/// The independent client types exposed by the current CC-Switch AppType
/// surface, tracked here so the UI can distinguish shipped adapters from
/// protocol work that still needs a bridge. This is product coverage metadata,
/// not a list of writable configurators.
struct ClientCoverage: Identifiable, Hashable, Sendable {
    let id: ClientID
    let name: String
    let availability: ClientDescriptor.Availability
    let note: String

    var statusTitle: String {
        switch availability {
        case .ready: return "已适配"
        case .requiresBridge: return "需协议桥"
        case .planned: return "待接入"
        }
    }

    var statusSymbol: String {
        switch availability {
        case .ready: return "checkmark.circle.fill"
        case .requiresBridge: return "point.3.connected.trianglepath.dotted"
        case .planned: return "clock"
        }
    }
}

enum ClientSupportCatalog {
    /// Kept in CC-Switch's AppType order. The list is deliberately explicit:
    /// auth modes and OpenCode variants are not counted as separate clients.
    static let ccSwitchScope: [ClientCoverage] = [
        ClientCoverage(id: .claudeCode, name: "Claude Code", availability: .ready, note: "Anthropic Messages"),
        ClientCoverage(id: .claudeDesktop, name: "Claude Desktop", availability: .ready, note: "Anthropic Messages（Claude 模型）"),
        ClientCoverage(id: .codex, name: "Codex", availability: .ready, note: "Responses"),
        ClientCoverage(id: .geminiCLI, name: "Gemini CLI", availability: .requiresBridge, note: "Gemini generateContent 非 YakCool 原生协议"),
        ClientCoverage(id: .grokBuild, name: "Grok Build", availability: .ready, note: "Responses / Messages / Chat"),
        ClientCoverage(id: .openCode, name: "OpenCode", availability: .ready, note: "Chat Completions"),
        ClientCoverage(id: .openClaw, name: "OpenClaw", availability: .ready, note: "Responses / Messages / Chat"),
        ClientCoverage(id: .hermes, name: "Hermes", availability: .ready, note: "Responses / Messages / Chat"),
        ClientCoverage(id: .pi, name: "Pi", availability: .ready, note: "Responses / Messages / Chat"),
    ]
}

struct ClientModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let protocols: Set<AIProtocol>

    init(id: String, name: String, protocols: [String]) {
        self.id = id
        self.name = name
        self.protocols = Set(protocols.map { AIProtocol(rawValue: $0) })
    }

    init(id: String, name: String, protocols: Set<AIProtocol>) {
        self.id = id
        self.name = name
        self.protocols = protocols
    }
}

struct ClientApplyRequest {
    let apiKey: String
    let models: [ClientModelOption]
    let selectedModelID: String
}

struct ClientConfigurationTarget: Hashable, Sendable {
    enum Role: String, Hashable, Sendable {
        case configuration
        case credential
        case helper
    }

    let url: URL
    let role: Role
}

enum ClientConfigurationState: String, Equatable, Sendable {
    case notConfigured
    case configured
    case drifted
    case invalid
}

enum CredentialProtection: String, Equatable, Sendable {
    case missing
    case managedFileSecure
    case safeReference
    case insecure
    case unexpectedInline
}

struct ClientConfigurationStatus: Equatable, Sendable {
    let clientID: ClientID
    let state: ClientConfigurationState
    let selectedModelID: String?
    let configuredModelIDs: [String]
    let credentialProtection: CredentialProtection
    let latestBackupURL: URL?
    let issues: [String]
}

struct ClientFileChangePreview: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        case create
        case update
        case unchanged
        case remove
    }

    let url: URL
    let role: ClientConfigurationTarget.Role
    let action: Action
    /// Configuration-only, already-redacted text. Credential/helper payloads
    /// must always leave this nil.
    let renderedText: String?
}

struct ClientConfigurationPreview: Equatable, Sendable {
    let clientID: ClientID
    let selectedModelID: String
    let changes: [ClientFileChangePreview]
}

struct ClientConfigurationResult: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        case applied
        case unchanged
        case restored
    }

    let action: Action
    let clientID: ClientID
    let changedTargets: [URL]
    let backupURL: URL?
    let modelID: String?
    let message: String

    var changed: Bool { action != .unchanged }
}

enum ClientConfigurationError: LocalizedError, Equatable {
    case duplicateClient(String)
    case collidingTarget(String)
    case unsupportedClient(String)
    case noCompatibleModel(String)
    case invalidSelection(String)
    case invalidConfiguration(String)
    case noBackup(String)

    var errorDescription: String? {
        switch self {
        case .duplicateClient(let name): return "客户端适配器重复：\(name)"
        case .collidingTarget(let path): return "多个客户端适配器不能共用可写目标：\(path)"
        case .unsupportedClient(let name): return "尚未安装或启用 \(name) 适配器"
        case .noCompatibleModel(let message),
             .invalidSelection(let message),
             .invalidConfiguration(let message): return message
        case .noBackup(let name): return "没有可恢复的 \(name) 配置备份"
        }
    }
}

protocol ClientConfiguring: AnyObject {
    var descriptor: ClientDescriptor { get }
    var targets: [ClientConfigurationTarget] { get }

    func compatibleModels(from models: [ClientModelOption]) -> [ClientModelOption]
    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview
    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult
    func inspect() throws -> ClientConfigurationStatus
    func restoreLatest() throws -> ClientConfigurationResult
}

extension ClientConfiguring {
    func compatibleModels(from models: [ClientModelOption]) -> [ClientModelOption] {
        let supported = Set(descriptor.supportedProtocols)
        return models.filter { !$0.protocols.isDisjoint(with: supported) }
    }
}

final class ClientConfigurationRegistry {
    let descriptors: [ClientDescriptor]
    private let clients: [ClientID: any ClientConfiguring]

    init(_ configurators: [any ClientConfiguring]) throws {
        var mapped: [ClientID: any ClientConfiguring] = [:]
        var ownedTargets: [URL: ClientID] = [:]

        for configurator in configurators {
            let id = configurator.descriptor.id
            guard mapped[id] == nil else {
                throw ClientConfigurationError.duplicateClient(configurator.descriptor.name)
            }
            for target in configurator.targets {
                let normalized = ConfigurationPathCanonicalizer.canonicalizedURL(target.url)
                if ownedTargets[normalized] != nil {
                    throw ClientConfigurationError.collidingTarget(normalized.path)
                }
                ownedTargets[normalized] = id
            }
            mapped[id] = configurator
        }

        clients = mapped
        descriptors = configurators.map(\.descriptor)
    }

    subscript(id: ClientID) -> (any ClientConfiguring)? { clients[id] }
}

/// Compatibility facade around the heavily tested OpenCode implementation.
/// Keeping the original transaction path intact lets the Store and UI migrate
/// to a client registry without weakening OpenCode's existing guarantees.
final class OpenCodeClientConfigurator: ClientConfiguring {
    let descriptor = ClientDescriptor(
        id: .openCode,
        name: "OpenCode",
        shortName: "OpenCode",
        symbol: "terminal",
        summary: "OpenAI-compatible coding agent",
        supportedProtocols: [.chatCompletions],
        configurationPath: "~/.config/opencode/opencode.json",
        restartNote: "OpenCode 会在下次请求时读取新配置",
        availability: .ready
    )

    private let configurator: OpenCodeConfigurator

    init(configurator: OpenCodeConfigurator) {
        self.configurator = configurator
    }

    var targets: [ClientConfigurationTarget] {
        [
            ClientConfigurationTarget(url: configurator.secretURL, role: .credential),
            ClientConfigurationTarget(url: configurator.configurationURL, role: .configuration),
        ]
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        let models = try validatedModels(request)
        let result = try configurator.preview(
            models: models.map { OpenCodeModelOption(id: $0.id, name: $0.name) },
            selectedModelID: request.selectedModelID
        )
        let redactedConfiguration = try ConfigurationPreviewRedactor.redactedJSONText(
            result.configuration,
            label: "OpenCode 配置"
        )
        return ClientConfigurationPreview(
            clientID: descriptor.id,
            selectedModelID: result.selectedModelID,
            changes: [
                ClientFileChangePreview(
                    url: result.secretURL,
                    role: .credential,
                    action: FileManager.default.fileExists(atPath: result.secretURL.path) ? .update : .create,
                    renderedText: nil
                ),
                ClientFileChangePreview(
                    url: result.configURL,
                    role: .configuration,
                    action: .update,
                    renderedText: redactedConfiguration
                ),
            ]
        )
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        let models = try validatedModels(request)
        let result = try configurator.apply(
            apiKey: request.apiKey,
            models: models.map { OpenCodeModelOption(id: $0.id, name: $0.name) },
            selectedModelID: request.selectedModelID
        )
        return ClientConfigurationResult(
            action: Self.action(result.action),
            clientID: descriptor.id,
            changedTargets: result.changed ? [result.secretURL, result.configURL] : [],
            backupURL: result.backupURL,
            modelID: result.modelID,
            message: result.message
        )
    }

    func inspect() throws -> ClientConfigurationStatus {
        let status = try configurator.inspect()
        let state: ClientConfigurationState
        if !status.configExists || !status.providerConfigured { state = .notConfigured }
        else if !status.secretReferenceIsSafe { state = .drifted }
        else if status.secretExists && status.secretPermissionsAreSecure { state = .configured }
        else { state = .invalid }

        var issues: [String] = []
        if status.providerConfigured && !status.secretReferenceIsSafe { issues.append("API Key 引用不是 YConnect 管理的安全文件") }
        if status.secretExists && !status.secretPermissionsAreSecure { issues.append("密钥文件权限不是 0600") }
        return ClientConfigurationStatus(
            clientID: descriptor.id,
            state: state,
            selectedModelID: status.selectedModelID,
            configuredModelIDs: status.configuredModelIDs,
            credentialProtection: status.secretReferenceIsSafe
                ? (status.secretExists && status.secretPermissionsAreSecure ? .safeReference : .missing)
                : .unexpectedInline,
            latestBackupURL: status.latestBackupURL,
            issues: issues
        )
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result = try configurator.restoreLatest()
        return ClientConfigurationResult(
            action: Self.action(result.action),
            clientID: descriptor.id,
            changedTargets: result.changed ? [result.secretURL, result.configURL] : [],
            backupURL: result.backupURL,
            modelID: result.modelID,
            message: result.message
        )
    }

    private func validatedModels(_ request: ClientApplyRequest) throws -> [ClientModelOption] {
        let models = compatibleModels(from: request.models)
        guard !models.isEmpty else {
            throw ClientConfigurationError.noCompatibleModel("当前 API Key 没有兼容 OpenCode 的 Chat Completions 模型")
        }
        guard models.contains(where: { $0.id == request.selectedModelID }) else {
            throw ClientConfigurationError.invalidSelection("所选模型不兼容 OpenCode")
        }
        return models
    }

    private static func action(_ action: OpenCodeConfigurationResult.Action) -> ClientConfigurationResult.Action {
        switch action {
        case .applied: return .applied
        case .unchanged: return .unchanged
        case .restored: return .restored
        }
    }
}

enum ConfigurationPreviewRedactor {
    private static let replacement = "<redacted>"
    private static let sensitiveNames: Set<String> = [
        "apikey", "authorization", "cookie", "credential", "headers",
        "password", "secret", "token",
    ]

    static func redactedJSONText(_ text: String, label: String) throws -> String {
        let root = try JSONConfigurationEditor.rootObject(from: Data(text.utf8), label: label)
        guard let redacted = redact(root) as? [String: Any] else {
            throw ClientConfigurationError.invalidConfiguration("无法生成 \(label)的脱敏预览")
        }
        return String(decoding: try JSONConfigurationEditor.serialized(redacted, label: label), as: UTF8.self)
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveNames.contains(where: { normalized == $0 || normalized.hasSuffix($0) })
    }

    private static func redact(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, element in
                result[element.key] = isSensitiveKey(element.key)
                    ? replacement
                    : redact(element.value)
            }
        }
        if let array = value as? [Any] { return array.map(redact) }
        return value
    }
}
