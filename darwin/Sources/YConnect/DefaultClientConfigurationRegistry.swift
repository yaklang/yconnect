import Foundation

/// The single composition root for client adapters shipped by YConnect.
///
/// A user's existing dotfile layout must not prevent the application from
/// launching. Each throwing adapter initializer is therefore isolated: a
/// failed adapter keeps its descriptor and declared targets, while operations
/// on that adapter surface the initialization error. The other clients remain
/// usable.
enum DefaultClientConfigurationRegistry {
    static let clientOrder: [ClientID] = [
        .openCode, .pi, .claudeCode, .claudeDesktop, .codex, .grokBuild,
        .openClaw, .hermes,
    ]

    static func make(
        environment: AppEnvironment,
        openCodeConfigurator: OpenCodeConfigurator? = nil,
        fileManager: FileManager = .default
    ) throws -> ClientConfigurationRegistry {
        let openCode = openCodeConfigurator ?? OpenCodeConfigurator(
            configurationURL: environment.openCodeConfigurationURL,
            applicationSupportDirectory: environment.applicationSupportDirectory,
            fileManager: fileManager
        )

        let configurators: [any ClientConfiguring] = [
            OpenCodeClientConfigurator(configurator: openCode),
            isolated(
                descriptor: piDescriptor,
                targets: targets(for: .pi, environment: environment),
                factory: { try PiClientConfigurator(environment: environment, fileManager: fileManager) }
            ),
            isolated(
                descriptor: claudeCodeDescriptor,
                targets: targets(for: .claudeCode, environment: environment),
                factory: { try ClaudeCodeClientConfigurator(environment: environment, fileManager: fileManager) }
            ),
            isolated(
                descriptor: ClaudeDesktopClientConfigurator.descriptor,
                targets: targets(for: .claudeDesktop, environment: environment),
                factory: {
                    try ClaudeDesktopClientConfigurator(environment: environment, fileManager: fileManager)
                }
            ),
            isolated(
                descriptor: codexDescriptor,
                targets: targets(for: .codex, environment: environment),
                factory: { try CodexClientConfigurator(environment: environment, fileManager: fileManager) }
            ),
            isolated(
                descriptor: grokBuildDescriptor,
                targets: targets(for: .grokBuild, environment: environment),
                factory: { try GrokBuildClientConfigurator(environment: environment, fileManager: fileManager) }
            ),
            isolated(
                descriptor: OpenClawClientConfigurator.descriptor,
                targets: targets(for: .openClaw, environment: environment),
                factory: { try OpenClawClientConfigurator(environment: environment, fileManager: fileManager) }
            ),
            isolated(
                descriptor: HermesClientConfigurator.descriptor,
                targets: targets(for: .hermes, environment: environment),
                factory: { try HermesClientConfigurator(environment: environment, fileManager: fileManager) }
            ),
        ]
        return try ClientConfigurationRegistry(
            isolatingTargetCollisions(configurators, fileManager: fileManager)
        )
    }

    private static func isolated(
        descriptor: ClientDescriptor,
        targets: [ClientConfigurationTarget],
        factory: () throws -> any ClientConfiguring
    ) -> any ClientConfiguring {
        do {
            return try factory()
        } catch {
            return UnavailableClientConfigurator(
                descriptor: descriptor,
                targets: targets,
                initializationError: error
            )
        }
    }

    private static func targets(
        for clientID: ClientID,
        environment: AppEnvironment
    ) -> [ClientConfigurationTarget] {
        var targets = [ClientConfigurationTarget(
            url: environment.managedSecretURL(for: clientID),
            role: .credential
        )] + environment.configurationURLs(for: clientID).map {
            ClientConfigurationTarget(url: $0, role: .configuration)
        }
        if clientID == .claudeDesktop || clientID == .hermes {
            targets.insert(
                ClientConfigurationTarget(
                    url: environment.managedHelperURL(for: clientID),
                    role: .helper
                ),
                at: 1
            )
        }
        return targets
    }

    /// A collision is a per-client availability problem, not an application
    /// startup failure. Disable every participant and leave unrelated adapters
    /// registered. Empty targets also prevent the generic registry from
    /// rejecting the otherwise useful descriptor entries.
    private static func isolatingTargetCollisions(
        _ configurators: [any ClientConfiguring],
        fileManager: FileManager
    ) -> [any ClientConfiguring] {
        var ownerByURL: [URL: Int] = [:]
        var conflictPathsByIndex: [Int: Set<String>] = [:]

        for (index, configurator) in configurators.enumerated() {
            for target in configurator.targets {
                let canonical = ConfigurationPathCanonicalizer.canonicalizedURL(
                    target.url,
                    fileManager: fileManager
                )
                if let owner = ownerByURL[canonical] {
                    conflictPathsByIndex[owner, default: []].insert(canonical.path)
                    conflictPathsByIndex[index, default: []].insert(canonical.path)
                } else {
                    ownerByURL[canonical] = index
                }
            }
        }

        return configurators.enumerated().map { index, configurator in
            guard let paths = conflictPathsByIndex[index], !paths.isEmpty else {
                return configurator
            }
            let pathList = paths.sorted().joined(separator: ", ")
            return UnavailableClientConfigurator(
                descriptor: configurator.descriptor,
                targets: [],
                initializationError: ClientConfigurationError.collidingTarget(pathList)
            )
        }
    }

    private static let piDescriptor = ClientDescriptor(
        id: .pi,
        name: "Pi Agent",
        shortName: "Pi",
        symbol: "pi",
        summary: "Pi Coding Agent / Agent Harness",
        supportedProtocols: [.responses, .anthropicMessages, .chatCompletions],
        configurationPath: "~/.pi/agent/models.json + settings.json",
        restartNote: "重新打开 /model 即可载入，无需重启 Pi",
        availability: .ready
    )

    private static let claudeCodeDescriptor = ClientDescriptor(
        id: .claudeCode,
        name: "Claude Code",
        shortName: "Claude Code",
        symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Anthropic Claude Code",
        supportedProtocols: [.anthropicMessages],
        configurationPath: "~/.claude/settings.json",
        restartNote: "请重新启动 Claude Code 终端会话",
        availability: .ready
    )

    private static let codexDescriptor = ClientDescriptor(
        id: .codex,
        name: "OpenAI Codex",
        shortName: "Codex",
        symbol: "terminal",
        summary: "OpenAI Codex CLI",
        supportedProtocols: [.responses],
        configurationPath: "~/.codex/config.toml",
        restartNote: "Codex 会在新会话中读取配置",
        availability: .ready
    )

    private static let grokBuildDescriptor = ClientDescriptor(
        id: .grokBuild,
        name: "Grok Build",
        shortName: "Grok Build",
        symbol: "bolt.horizontal",
        summary: "xAI Grok Build CLI",
        supportedProtocols: [.responses, .anthropicMessages, .chatCompletions],
        configurationPath: "~/.grok/config.toml",
        restartNote: "Grok Build 会在新会话中读取配置",
        availability: .ready
    )
}

private final class UnavailableClientConfigurator: ClientConfiguring {
    let descriptor: ClientDescriptor
    let targets: [ClientConfigurationTarget]
    private let initializationError: Error

    init(
        descriptor: ClientDescriptor,
        targets: [ClientConfigurationTarget],
        initializationError: Error
    ) {
        self.descriptor = descriptor
        self.targets = targets
        self.initializationError = initializationError
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        _ = request
        throw unavailableError
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        _ = request
        throw unavailableError
    }

    func inspect() throws -> ClientConfigurationStatus {
        throw unavailableError
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        throw unavailableError
    }

    private var unavailableError: ClientConfigurationError {
        .invalidConfiguration(
            "\(descriptor.name) 适配器暂不可用：\(initializationError.localizedDescription)"
        )
    }
}
