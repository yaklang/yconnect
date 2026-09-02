import Foundation

private enum CoreClientInputValidation {
    static let maximumConfiguredModelCount = 100

    static func validateAPIKey(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }) else {
            throw ClientConfigurationError.invalidConfiguration("API Key 格式无效")
        }
    }

    static func validateModel(_ model: ClientModelOption) throws {
        guard !model.id.isEmpty,
              model.id.utf8.count <= 200,
              model.id == model.id.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.id.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }) else {
            throw ClientConfigurationError.invalidSelection("模型 ID 格式无效")
        }
        guard !model.name.isEmpty,
              model.name.utf8.count <= 256,
              model.name == model.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.name.unicodeScalars.contains(where: {
                  CharacterSet.newlines.union(.controlCharacters).contains($0)
              }) else {
            throw ClientConfigurationError.invalidSelection("模型名称格式无效")
        }
    }

    static func validateOutputModels(_ models: [ClientModelOption]) throws {
        guard !models.isEmpty, models.count <= maximumConfiguredModelCount else {
            throw ClientConfigurationError.invalidSelection(
                "单个客户端最多可配置 \(maximumConfiguredModelCount) 个模型"
            )
        }
        var identifiers: Set<String> = []
        for model in models {
            try validateModel(model)
            guard identifiers.insert(model.id).inserted else {
                throw ClientConfigurationError.invalidSelection("模型 ID 重复：\(model.id)")
            }
        }
    }
}

final class PiClientConfigurator: ClientConfiguring {
    static let providerID = "yakcool"
    static let gatewayV1 = "https://aibalance.yaklang.com/v1"
    static let gatewayHost = "https://aibalance.yaklang.com"

    let descriptor = ClientDescriptor(
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

    let modelsURL: URL
    let settingsURL: URL
    let secretURL: URL
    private let coordinator: ConfigurationTransactionCoordinator

    init(environment: AppEnvironment, fileManager: FileManager = .default) throws {
        let urls = environment.configurationURLs(for: .pi)
        guard urls.count == 2 else {
            throw ClientConfigurationError.invalidConfiguration("Pi 配置路径不完整")
        }
        modelsURL = urls[0]
        settingsURL = urls[1]
        secretURL = environment.managedSecretURL(for: .pi)
        coordinator = try ConfigurationTransactionCoordinator(
            identifier: ClientID.pi.rawValue,
            targets: [
                ConfigurationTransactionTarget(id: "credential", url: secretURL, sensitivity: .secret),
                ConfigurationTransactionTarget(id: "models", url: modelsURL),
                ConfigurationTransactionTarget(id: "settings", url: settingsURL),
            ],
            backupsDirectory: environment.backupsDirectory(for: .pi),
            fileManager: fileManager
        )
    }

    var targets: [ClientConfigurationTarget] {
        [
            ClientConfigurationTarget(url: secretURL, role: .credential),
            ClientConfigurationTarget(url: modelsURL, role: .configuration),
            ClientConfigurationTarget(url: settingsURL, role: .configuration),
        ]
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        try validateAPIKey(request.apiKey)
        return try coordinator.withValidatedPlan(plan: { state in
            let desired = try desiredDocuments(
                request,
                modelsData: state.data(for: "models"),
                settingsData: state.data(for: "settings")
            )
            return [
                .write(targetID: "credential", data: Data(request.apiKey.utf8)),
                .write(targetID: "models", data: desired.models),
                .write(targetID: "settings", data: desired.settings),
            ]
        }) { state, mutations in
            func desiredData(for targetID: String) throws -> Data {
                guard let mutation = mutations.first(where: { $0.targetID == targetID }),
                      case .write(_, let data) = mutation else {
                    throw ClientConfigurationError.invalidConfiguration(
                        "Pi 配置预览缺少目标：\(targetID)"
                    )
                }
                return data
            }
            let credential = try desiredData(for: "credential")
            let models = try desiredData(for: "models")
            let settings = try desiredData(for: "settings")
            return ClientConfigurationPreview(
                clientID: descriptor.id,
                selectedModelID: request.selectedModelID,
                changes: [
                    ClientFileChangePreview(
                        url: secretURL,
                        role: .credential,
                        action: previewAction(
                            state,
                            targetID: "credential",
                            desiredData: credential
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: modelsURL,
                        role: .configuration,
                        action: previewAction(state, targetID: "models", desiredData: models),
                        renderedText: try JSONConfigurationPreviewRedactor.renderedText(
                            from: models,
                            label: "Pi models.json"
                        )
                    ),
                    ClientFileChangePreview(
                        url: settingsURL,
                        role: .configuration,
                        action: previewAction(state, targetID: "settings", desiredData: settings),
                        renderedText: try JSONConfigurationPreviewRedactor.renderedText(
                            from: settings,
                            label: "Pi settings.json"
                        )
                    ),
                ]
            )
        }
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        try validateAPIKey(request.apiKey)
        let desiredModel = request.selectedModelID
        let result = try coordinator.apply(plan: { state in
            let desired = try self.desiredDocuments(
                request,
                modelsData: state.data(for: "models"),
                settingsData: state.data(for: "settings")
            )
            return [
                .write(targetID: "credential", data: Data(request.apiKey.utf8)),
                .write(targetID: "models", data: desired.models),
                .write(targetID: "settings", data: desired.settings),
            ]
        }, validate: { state in
            try self.validateInstalled(state, expectedModelID: desiredModel)
        })
        return mappedResult(result, modelID: desiredModel, restored: false)
    }

    func inspect() throws -> ClientConfigurationStatus {
        let latestBackup = try coordinator.latestBackupURL()
        return try coordinator.withSnapshot { state in
            let models = try JSONConfigurationEditor.rootObject(
                from: state.data(for: "models"),
                label: "Pi models.json"
            )
            let settings = try JSONConfigurationEditor.rootObject(
                from: state.data(for: "settings"),
                label: "Pi settings.json"
            )
            let provider = (models["providers"] as? [String: Any])?[Self.providerID] as? [String: Any]
            let active = provider != nil && settings["defaultProvider"] as? String == Self.providerID
            let commandIsSafe = provider?["apiKey"] as? String == ClientCredentialCommand.shellReadCommand(for: secretURL)
            let secretSecure = state.file("credential")?.exists == true
                && state.file("credential")?.permissions == 0o600
            let configuredModels = (provider?["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            let selectedModel = settings["defaultModel"] as? String
            let api = provider?["api"] as? String
            let expectedBaseURL: String?
            switch api {
            case "openai-responses", "openai-completions": expectedBaseURL = Self.gatewayV1
            case "anthropic-messages": expectedBaseURL = Self.gatewayHost
            default: expectedBaseURL = nil
            }
            let providerIsValid = expectedBaseURL != nil
                && provider?["baseUrl"] as? String == expectedBaseURL
                && !configuredModels.isEmpty
                && selectedModel.map(configuredModels.contains) == true
            var issues: [String] = []
            if provider != nil && !commandIsSafe { issues.append("Pi 的 YakCool credential 不是 YConnect 管理的命令引用") }
            if commandIsSafe && !secretSecure { issues.append("Pi 密钥文件缺失或权限不是 0600") }
            if active && !providerIsValid { issues.append("Pi 的 YakCool endpoint、协议或默认模型已发生变化") }
            return ClientConfigurationStatus(
                clientID: descriptor.id,
                state: active
                    ? (providerIsValid && commandIsSafe && secretSecure ? .configured : .drifted)
                    : .notConfigured,
                selectedModelID: selectedModel,
                configuredModelIDs: configuredModels,
                credentialProtection: commandIsSafe ? (secretSecure ? .safeReference : .missing) : .unexpectedInline,
                latestBackupURL: latestBackup,
                issues: issues
            )
        }
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result: ConfigurationTransactionResult
        do {
            result = try coordinator.restoreLatest { state in
                _ = try JSONConfigurationEditor.rootObject(from: state.data(for: "models"), label: "Pi models.json")
                _ = try JSONConfigurationEditor.rootObject(from: state.data(for: "settings"), label: "Pi settings.json")
            }
        } catch ConfigurationTransactionError.noBackup {
            throw ClientConfigurationError.noBackup(descriptor.name)
        }
        return mappedResult(result, modelID: nil, restored: true)
    }

    private struct DesiredDocuments {
        let models: Data
        let settings: Data
    }

    private func desiredDocuments(
        _ request: ClientApplyRequest,
        modelsData: Data?,
        settingsData: Data?
    ) throws -> DesiredDocuments {
        let compatible = compatibleModels(from: request.models)
        guard let selected = compatible.first(where: { $0.id == request.selectedModelID }) else {
            throw ClientConfigurationError.invalidSelection("所选模型不兼容 Pi")
        }
        let wireProtocol = try preferredProtocol(for: selected)
        let sameWireModels = compatible.filter { $0.protocols.contains(wireProtocol) }
        try CoreClientInputValidation.validateOutputModels(sameWireModels)

        var modelsRoot = try JSONConfigurationEditor.rootObject(from: modelsData, label: "Pi models.json")
        var providers: [String: Any]
        if let existing = modelsRoot["providers"] {
            guard let object = existing as? [String: Any] else {
                throw ClientConfigurationError.invalidConfiguration("Pi models.json 的 providers 必须是对象")
            }
            providers = object
        } else { providers = [:] }
        var provider: [String: Any]
        if let existing = providers[Self.providerID] {
            guard let object = existing as? [String: Any] else {
                throw ClientConfigurationError.invalidConfiguration(
                    "Pi models.json 的 providers.\(Self.providerID) 必须是对象"
                )
            }
            provider = object
        } else {
            provider = [:]
        }
        // The adapter owns only these four keys. Preserve Pi extensions and
        // future fields in the managed provider node just as we preserve other
        // providers and root-level settings.
        provider["baseUrl"] = wireProtocol == .anthropicMessages ? Self.gatewayHost : Self.gatewayV1
        provider["api"] = piAPIName(wireProtocol)
        provider["apiKey"] = ClientCredentialCommand.shellReadCommand(for: secretURL)
        let existingModels: [[String: Any]]
        if let value = provider["models"] {
            guard let array = value as? [[String: Any]] else {
                throw ClientConfigurationError.invalidConfiguration(
                    "Pi models.json 的 providers.\(Self.providerID).models 必须是对象数组"
                )
            }
            existingModels = array
        } else {
            existingModels = []
        }
        let existingModelsByID = Dictionary(
            existingModels.compactMap { model -> (String, [String: Any])? in
                guard let id = model["id"] as? String, !id.isEmpty else { return nil }
                return (id, model)
            },
            uniquingKeysWith: { first, _ in first }
        )
        provider["models"] = sameWireModels.map { model -> [String: Any] in
            var document = existingModelsByID[model.id] ?? [:]
            document["id"] = model.id
            document["name"] = model.name
            return document
        }
        providers[Self.providerID] = provider
        modelsRoot["providers"] = providers

        var settingsRoot = try JSONConfigurationEditor.rootObject(from: settingsData, label: "Pi settings.json")
        settingsRoot["defaultProvider"] = Self.providerID
        settingsRoot["defaultModel"] = request.selectedModelID
        return DesiredDocuments(
            models: try JSONConfigurationEditor.serialized(modelsRoot, label: "Pi models.json"),
            settings: try JSONConfigurationEditor.serialized(settingsRoot, label: "Pi settings.json")
        )
    }

    private func preferredProtocol(for model: ClientModelOption) throws -> AIProtocol {
        for candidate in descriptor.supportedProtocols where model.protocols.contains(candidate) { return candidate }
        throw ClientConfigurationError.noCompatibleModel("所选模型没有 Pi 支持的协议")
    }

    private func piAPIName(_ value: AIProtocol) -> String {
        switch value {
        case .responses: return "openai-responses"
        case .anthropicMessages: return "anthropic-messages"
        default: return "openai-completions"
        }
    }

    private func validateInstalled(_ state: ConfigurationTransactionState, expectedModelID: String) throws {
        let models = try JSONConfigurationEditor.rootObject(from: state.data(for: "models"), label: "Pi models.json")
        let settings = try JSONConfigurationEditor.rootObject(from: state.data(for: "settings"), label: "Pi settings.json")
        guard let provider = (models["providers"] as? [String: Any])?[Self.providerID] as? [String: Any],
              provider["apiKey"] as? String == ClientCredentialCommand.shellReadCommand(for: secretURL),
              (provider["models"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == expectedModelID }) == true,
              settings["defaultProvider"] as? String == Self.providerID,
              settings["defaultModel"] as? String == expectedModelID,
              state.file("credential")?.permissions == 0o600,
              state.file("credential")?.exists == true else {
            throw ClientConfigurationError.invalidConfiguration("Pi 写后校验失败")
        }
    }

    private func mappedResult(
        _ result: ConfigurationTransactionResult,
        modelID: String?,
        restored: Bool
    ) -> ClientConfigurationResult {
        let action = Self.action(result.action)
        let changed = result.changedTargetIDs.compactMap { id -> URL? in
            switch id {
            case "credential": return secretURL
            case "models": return modelsURL
            case "settings": return settingsURL
            default: return nil
            }
        }
        let message: String
        if restored { message = action == .unchanged ? "Pi 配置已是最近备份状态" : "已恢复最近一次 Pi 配置备份" }
        else { message = action == .unchanged ? "Pi 已在使用所选 YakCool 模型" : "已将 Pi 切换到 YakCool / \(modelID ?? "")" }
        return ClientConfigurationResult(
            action: action,
            clientID: descriptor.id,
            changedTargets: changed,
            backupURL: result.backupURL,
            modelID: modelID,
            message: message
        )
    }

    private static func action(_ action: ConfigurationTransactionResult.Action) -> ClientConfigurationResult.Action {
        switch action { case .applied: return .applied; case .unchanged: return .unchanged; case .restored: return .restored }
    }

    private func validateAPIKey(_ key: String) throws {
        try CoreClientInputValidation.validateAPIKey(key)
    }

    private func previewAction(
        _ state: ConfigurationTransactionState,
        targetID: String,
        desiredData: Data
    ) -> ClientFileChangePreview.Action {
        let file = state.file(targetID)
        guard file?.exists == true else { return .create }
        return file?.permissions == 0o600 && state.data(for: targetID) == desiredData ? .unchanged : .update
    }
}

final class ClaudeCodeClientConfigurator: ClientConfiguring {
    static let gatewayHost = "https://aibalance.yaklang.com"
    private static let conflictingCloudFlags = [
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
    ]

    let descriptor = ClientDescriptor(
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

    let settingsURL: URL
    let secretURL: URL
    private let coordinator: ConfigurationTransactionCoordinator

    init(environment: AppEnvironment, fileManager: FileManager = .default) throws {
        guard let settingsURL = environment.configurationURLs(for: .claudeCode).first else {
            throw ClientConfigurationError.invalidConfiguration("Claude Code 配置路径不存在")
        }
        self.settingsURL = settingsURL
        secretURL = environment.managedSecretURL(for: .claudeCode)
        coordinator = try ConfigurationTransactionCoordinator(
            identifier: ClientID.claudeCode.rawValue,
            targets: [
                ConfigurationTransactionTarget(id: "credential", url: secretURL, sensitivity: .secret),
                ConfigurationTransactionTarget(id: "settings", url: settingsURL),
            ],
            backupsDirectory: environment.backupsDirectory(for: .claudeCode),
            fileManager: fileManager
        )
    }

    var targets: [ClientConfigurationTarget] {
        [
            ClientConfigurationTarget(url: secretURL, role: .credential),
            ClientConfigurationTarget(url: settingsURL, role: .configuration),
        ]
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        try validateRequest(request)
        return try coordinator.withValidatedPlan(plan: { state in
            let settings = try desiredSettings(request, existing: state.data(for: "settings"))
            return [
                .write(targetID: "credential", data: Data(request.apiKey.utf8)),
                .write(targetID: "settings", data: settings),
            ]
        }) { state, mutations in
            func desiredData(for targetID: String) throws -> Data {
                guard let mutation = mutations.first(where: { $0.targetID == targetID }),
                      case .write(_, let data) = mutation else {
                    throw ClientConfigurationError.invalidConfiguration(
                        "Claude Code 配置预览缺少目标：\(targetID)"
                    )
                }
                return data
            }
            let credential = try desiredData(for: "credential")
            let settings = try desiredData(for: "settings")
            return ClientConfigurationPreview(
                clientID: descriptor.id,
                selectedModelID: request.selectedModelID,
                changes: [
                    ClientFileChangePreview(
                        url: secretURL,
                        role: .credential,
                        action: previewAction(
                            state,
                            targetID: "credential",
                            desiredData: credential
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: settingsURL,
                        role: .configuration,
                        action: previewAction(state, targetID: "settings", desiredData: settings),
                        renderedText: try JSONConfigurationPreviewRedactor.renderedText(
                            from: settings,
                            label: "Claude Code settings.json"
                        )
                    ),
                ]
            )
        }
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        try validateRequest(request)
        let selected = request.selectedModelID
        let result = try coordinator.apply(plan: { state in
            let settings = try self.desiredSettings(request, existing: state.data(for: "settings"))
            return [
                .write(targetID: "credential", data: Data(request.apiKey.utf8)),
                .write(targetID: "settings", data: settings),
            ]
        }, validate: { state in
            try self.validateInstalled(state, expectedModelID: selected)
        })
        return mappedResult(result, modelID: selected, restored: false)
    }

    func inspect() throws -> ClientConfigurationStatus {
        let latestBackup = try coordinator.latestBackupURL()
        return try coordinator.withSnapshot { state in
            let root = try JSONConfigurationEditor.rootObject(
                from: state.data(for: "settings"),
                label: "Claude Code settings.json"
            )
            let env = root["env"] as? [String: Any]
            let helper = root["apiKeyHelper"] as? String
            let expectedHelper = ClientCredentialCommand.shellReadCommandWithoutSentinel(for: secretURL)
            let endpointConfigured = env?["ANTHROPIC_BASE_URL"] as? String == Self.gatewayHost
            let helperConfigured = helper == expectedHelper
            let secretSecure = state.file("credential")?.exists == true
                && state.file("credential")?.permissions == 0o600
            let inlineCredentialConflict = env?["ANTHROPIC_API_KEY"] != nil
                || env?["ANTHROPIC_AUTH_TOKEN"] != nil
            let cloudConflicts = Self.conflictingCloudFlags.filter { Self.flagIsEnabled(env?[$0]) }
            let rootModel = root["model"] as? String
            let environmentModel = env?["ANTHROPIC_MODEL"] as? String
            let modelIsConsistent = rootModel?.isEmpty == false && rootModel == environmentModel
            let configurationIsValid = endpointConfigured
                && modelIsConsistent
                && !inlineCredentialConflict
                && cloudConflicts.isEmpty
            let safe = helperConfigured
                && secretSecure
                && !inlineCredentialConflict
                && cloudConflicts.isEmpty
            var issues: [String] = []
            if endpointConfigured && !helperConfigured { issues.append("Claude Code apiKeyHelper 不是 YConnect 管理的安全引用") }
            if helperConfigured && !secretSecure { issues.append("Claude Code 密钥文件缺失或权限不是 0600") }
            if inlineCredentialConflict { issues.append("Claude Code 存在会覆盖 apiKeyHelper 的内联 Anthropic credential") }
            if !cloudConflicts.isEmpty { issues.append("Claude Code 启用了会绕过 YakCool 的云端 provider：\(cloudConflicts.joined(separator: ", "))") }
            if endpointConfigured && !modelIsConsistent { issues.append("Claude Code 的默认模型配置不一致") }
            let credentialProtection: CredentialProtection
            if inlineCredentialConflict {
                credentialProtection = .unexpectedInline
            } else if !cloudConflicts.isEmpty {
                credentialProtection = .insecure
            } else if helperConfigured {
                credentialProtection = secretSecure ? .safeReference : .missing
            } else {
                credentialProtection = .unexpectedInline
            }
            return ClientConfigurationStatus(
                clientID: descriptor.id,
                state: (endpointConfigured || helperConfigured)
                    ? (configurationIsValid && safe ? .configured : .drifted)
                    : .notConfigured,
                selectedModelID: rootModel ?? environmentModel,
                configuredModelIDs: [],
                credentialProtection: credentialProtection,
                latestBackupURL: latestBackup,
                issues: issues
            )
        }
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result: ConfigurationTransactionResult
        do {
            result = try coordinator.restoreLatest { state in
                _ = try JSONConfigurationEditor.rootObject(from: state.data(for: "settings"), label: "Claude Code settings.json")
            }
        } catch ConfigurationTransactionError.noBackup {
            throw ClientConfigurationError.noBackup(descriptor.name)
        }
        return mappedResult(result, modelID: nil, restored: true)
    }

    private func desiredSettings(_ request: ClientApplyRequest, existing: Data?) throws -> Data {
        try validateRequest(request)
        var root = try JSONConfigurationEditor.rootObject(from: existing, label: "Claude Code settings.json")
        var env: [String: Any]
        if let value = root["env"] {
            guard let object = value as? [String: Any] else {
                throw ClientConfigurationError.invalidConfiguration("Claude Code settings.json 的 env 必须是对象")
            }
            env = object
        } else { env = [:] }
        env["ANTHROPIC_BASE_URL"] = Self.gatewayHost
        env["ANTHROPIC_MODEL"] = request.selectedModelID
        // These would override apiKeyHelper and may point to a stale provider.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        for key in Self.conflictingCloudFlags { env.removeValue(forKey: key) }
        root["env"] = env
        root["model"] = request.selectedModelID
        root["apiKeyHelper"] = ClientCredentialCommand.shellReadCommandWithoutSentinel(for: secretURL)
        return try JSONConfigurationEditor.serialized(root, label: "Claude Code settings.json")
    }

    private func validateRequest(_ request: ClientApplyRequest) throws {
        guard let selected = compatibleModels(from: request.models).first(where: {
            $0.id == request.selectedModelID
        }) else {
            throw ClientConfigurationError.invalidSelection("所选模型不支持 Claude Code 所需的 Anthropic Messages 协议")
        }
        try CoreClientInputValidation.validateModel(selected)
        try CoreClientInputValidation.validateAPIKey(request.apiKey)
    }

    private func validateInstalled(_ state: ConfigurationTransactionState, expectedModelID: String) throws {
        let root = try JSONConfigurationEditor.rootObject(from: state.data(for: "settings"), label: "Claude Code settings.json")
        let env = root["env"] as? [String: Any]
        guard env?["ANTHROPIC_BASE_URL"] as? String == Self.gatewayHost,
              env?["ANTHROPIC_MODEL"] as? String == expectedModelID,
              root["model"] as? String == expectedModelID,
              root["apiKeyHelper"] as? String == ClientCredentialCommand.shellReadCommandWithoutSentinel(for: secretURL),
              env?["ANTHROPIC_API_KEY"] == nil,
              env?["ANTHROPIC_AUTH_TOKEN"] == nil,
              Self.conflictingCloudFlags.allSatisfy({ !Self.flagIsEnabled(env?[$0]) }),
              state.file("credential")?.permissions == 0o600,
              state.file("credential")?.exists == true else {
            throw ClientConfigurationError.invalidConfiguration("Claude Code 写后校验失败")
        }
    }

    private func mappedResult(
        _ result: ConfigurationTransactionResult,
        modelID: String?,
        restored: Bool
    ) -> ClientConfigurationResult {
        let action: ClientConfigurationResult.Action
        switch result.action { case .applied: action = .applied; case .unchanged: action = .unchanged; case .restored: action = .restored }
        let changed = result.changedTargetIDs.compactMap { $0 == "credential" ? secretURL : ($0 == "settings" ? settingsURL : nil) }
        let message: String
        if restored { message = action == .unchanged ? "Claude Code 配置已是最近备份状态" : "已恢复最近一次 Claude Code 配置备份" }
        else { message = action == .unchanged ? "Claude Code 已在使用所选 YakCool 模型" : "已将 Claude Code 切换到 YakCool / \(modelID ?? "")" }
        return ClientConfigurationResult(action: action, clientID: descriptor.id, changedTargets: changed, backupURL: result.backupURL, modelID: modelID, message: message)
    }

    private func previewAction(
        _ state: ConfigurationTransactionState,
        targetID: String,
        desiredData: Data
    ) -> ClientFileChangePreview.Action {
        let file = state.file(targetID)
        guard file?.exists == true else { return .create }
        return file?.permissions == 0o600 && state.data(for: targetID) == desiredData ? .unchanged : .update
    }

    private static func flagIsEnabled(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return ["1", "true", "yes", "on"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
        return false
    }
}

/// Preview text is user-visible and may include fields YConnect deliberately
/// preserves but does not own. Recursively redact common credential-bearing
/// keys so another provider's inline secret cannot leak through our preview.
private enum JSONConfigurationPreviewRedactor {
    private static let redactedValue = "<redacted>"

    static func renderedText(from data: Data, label: String) throws -> String {
        let root = try JSONConfigurationEditor.rootObject(from: data, label: label)
        guard let redacted = redact(root) as? [String: Any] else {
            throw ClientConfigurationError.invalidConfiguration("无法生成安全的 \(label) 预览")
        }
        let rendered = try JSONConfigurationEditor.serialized(redacted, label: "\(label) 预览")
        return String(decoding: rendered, as: UTF8.self)
    }

    private static func redact(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { nested in nested }.reduce(into: [String: Any]()) { result, element in
                if isSensitiveKey(element.key) {
                    result[element.key] = redactedValue
                } else {
                    result[element.key] = redact(element.value)
                }
            }
        }
        if let array = value as? [Any] { return array.map(redact) }
        return value
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        if normalized == "apikeyhelper" { return false }
        if normalized == "headers" { return true }
        return ["apikey", "token", "secret", "password", "authorization", "credential", "cookie"]
            .contains(where: normalized.contains)
    }
}
