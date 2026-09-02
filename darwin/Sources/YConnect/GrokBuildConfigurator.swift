import Foundation

/// Configures xAI's Grok Build CLI with one YakCool catalog entry. A model's
/// advertised protocols determine the exact wire backend, with the more capable
/// Responses API preferred over Messages and Chat Completions.
final class GrokBuildClientConfigurator: ClientConfiguring {
    static let modelAlias = "yakcool"
    static let authProviderID = "yconnect"
    static let gatewayV1 = "https://aibalance.yaklang.com/v1"
    static let authTokenTTLSeconds = 300
    static let authTimeoutSeconds = 5

    private static let configurationTargetID = "configuration"
    private static let credentialTargetID = "credential"

    let descriptor = ClientDescriptor(
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

    let configurationURL: URL
    let secretURL: URL

    private let coordinator: ConfigurationTransactionCoordinator

    init(
        environment: AppEnvironment,
        fileManager: FileManager = .default,
        hooks: ConfigurationTransactionHooks = .none
    ) throws {
        guard let configurationURL = environment.configurationURLs(for: .grokBuild).first else {
            throw ClientConfigurationError.invalidConfiguration("Grok Build 配置路径不存在")
        }
        self.configurationURL = configurationURL
        self.secretURL = environment.managedSecretURL(for: .grokBuild)
        self.coordinator = try ConfigurationTransactionCoordinator(
            identifier: ClientID.grokBuild.rawValue,
            targets: [
                ConfigurationTransactionTarget(
                    id: Self.credentialTargetID,
                    url: self.secretURL,
                    sensitivity: .secret
                ),
                ConfigurationTransactionTarget(
                    id: Self.configurationTargetID,
                    url: self.configurationURL
                ),
            ],
            backupsDirectory: environment.backupsDirectory(for: .grokBuild),
            fileManager: fileManager,
            hooks: hooks
        )
    }

    var targets: [ClientConfigurationTarget] {
        [
            ClientConfigurationTarget(url: secretURL, role: .credential),
            ClientConfigurationTarget(url: configurationURL, role: .configuration),
        ]
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        let selected = try validatedSelection(request)
        let backend = try preferredBackend(for: selected)
        let credential = Data(request.apiKey.utf8)
        return try coordinator.withValidatedPlan(plan: { state in
            let configuration = try self.desiredConfiguration(
                existing: state.data(for: Self.configurationTargetID),
                selected: selected,
                backend: backend
            )
            return [
                .write(targetID: Self.credentialTargetID, data: credential),
                .write(targetID: Self.configurationTargetID, data: configuration),
            ]
        }) { state, mutations in
            let desiredCredential = try TOMLClientConfiguratorSupport.writtenData(
                for: Self.credentialTargetID,
                in: mutations
            )
            let configuration = try TOMLClientConfiguratorSupport.writtenData(
                for: Self.configurationTargetID,
                in: mutations
            )
            return ClientConfigurationPreview(
                clientID: descriptor.id,
                selectedModelID: selected.id,
                changes: [
                    ClientFileChangePreview(
                        url: secretURL,
                        role: .credential,
                        action: TOMLClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.credentialTargetID,
                            desiredData: desiredCredential
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: configurationURL,
                        role: .configuration,
                        action: TOMLClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.configurationTargetID,
                            desiredData: configuration
                        ),
                        renderedText: try TOMLClientConfiguratorSupport.redactedPreviewText(
                            configuration
                        )
                    ),
                ]
            )
        }
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        let selected = try validatedSelection(request)
        let backend = try preferredBackend(for: selected)
        let expectedCredential = Data(request.apiKey.utf8)
        let result = try coordinator.apply(plan: { state in
            let configuration = try self.desiredConfiguration(
                existing: state.data(for: Self.configurationTargetID),
                selected: selected,
                backend: backend
            )
            return [
                .write(targetID: Self.credentialTargetID, data: expectedCredential),
                .write(targetID: Self.configurationTargetID, data: configuration),
            ]
        }, validate: { state in
            try self.validateInstalled(
                state,
                expectedModelID: selected.id,
                expectedName: selected.name,
                expectedBackend: backend,
                expectedCredential: expectedCredential
            )
        })
        return mappedResult(result, modelID: selected.id, restored: false)
    }

    func inspect() throws -> ClientConfigurationStatus {
        let latestBackup = try coordinator.latestBackupURL()
        return try coordinator.withSnapshot { state in
            let credentialSecure = state.file(Self.credentialTargetID)?.exists == true
                && state.file(Self.credentialTargetID)?.permissions == 0o600

            let document: TOMLClientConfigurationDocument
            do {
                document = try TOMLClientConfigurationDocument(
                    data: state.data(for: Self.configurationTargetID),
                    label: "Grok Build config.toml"
                )
            } catch {
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: .invalid,
                    selectedModelID: nil,
                    configuredModelIDs: [],
                    credentialProtection: credentialSecure ? .managedFileSecure : .missing,
                    latestBackupURL: latestBackup,
                    issues: [error.localizedDescription]
                )
            }

            let modelsTable = "models"
            let modelTable = "model.\(Self.modelAlias)"
            let authTable = "auth_provider.\(Self.authProviderID)"
            let selectedAlias = document.string(table: modelsTable, key: "default")
            let selectedModel = document.string(table: modelTable, key: "model")
            let backend = document.string(table: modelTable, key: "api_backend")
            let allowedModelAssignments: [String: Set<String>] = [
                modelTable: ["model", "base_url", "name", "api_backend", "auth_provider"],
            ]
            let allowedAuthAssignments: [String: Set<String>] = [
                authTable: ["command", "args", "token_ttl_secs", "timeout_secs"],
            ]
            let hasManagedShapeConflict = document.hasConflictingManagedShape(
                modelTable,
                allowedAssignments: allowedModelAssignments
            ) || document.hasConflictingManagedShape(
                authTable,
                allowedAssignments: allowedAuthAssignments
            )
            let hasAncestorConflict = document.hasConflictingAncestorAssignment(modelTable)
                || document.hasConflictingAncestorAssignment(authTable)
            let hasManagedMarker = selectedAlias == Self.modelAlias
                || document.containsManagedNamespace(modelTable)
                || document.containsManagedNamespace(authTable)
            let safeReference = document.string(table: modelTable, key: "auth_provider") == Self.authProviderID
                && document.string(table: authTable, key: "command") == "/bin/cat"
                && document.stringArray(table: authTable, key: "args") == [secretURL.path]
                && document.integer(table: authTable, key: "token_ttl_secs") == Self.authTokenTTLSeconds
                && document.integer(table: authTable, key: "timeout_secs") == Self.authTimeoutSeconds
            let hasInlineCredential = ["api_key", "env_key", "token"].contains {
                document.hasAssignment(table: modelTable, key: $0)
            }
            let backendIsSupported = ["responses", "messages", "chat_completions"].contains(backend)
            let modelIsCorrect = selectedAlias == Self.modelAlias
                && selectedModel?.isEmpty == false
                && document.string(table: modelTable, key: "base_url") == Self.gatewayV1
                && document.string(table: modelTable, key: "name")?.isEmpty == false
                && backendIsSupported
                && document.string(table: modelTable, key: "auth_provider") == Self.authProviderID
            let configured = hasManagedMarker
                && modelIsCorrect
                && safeReference
                && !hasInlineCredential
                && !hasManagedShapeConflict
                && credentialSecure

            var issues: [String] = []
            if hasManagedMarker && !modelIsCorrect {
                issues.append("Grok Build 的 YakCool 模型配置不完整或协议无效")
            }
            if hasManagedMarker && hasInlineCredential {
                issues.append("Grok Build 的 YakCool 模型含有内联认证字段")
            }
            if hasManagedMarker && hasManagedShapeConflict {
                issues.append("Grok Build 的 YakCool 配置含有额外或冲突的子表、数组表或 dotted 配置")
            }
            if hasManagedMarker && !safeReference {
                issues.append("Grok Build 未使用 YConnect 管理的命名认证提供方")
            }
            if safeReference && !credentialSecure {
                issues.append("Grok Build 密钥文件缺失或权限不是 0600")
            }

            let protection: CredentialProtection
            if hasInlineCredential || hasManagedShapeConflict {
                protection = .unexpectedInline
            } else if safeReference {
                protection = credentialSecure ? .safeReference : .missing
            } else {
                protection = credentialSecure ? .managedFileSecure : .missing
            }

            return ClientConfigurationStatus(
                clientID: descriptor.id,
                state: configured
                    ? .configured
                    : (hasAncestorConflict ? .invalid : (hasManagedMarker ? .drifted : .notConfigured)),
                selectedModelID: selectedModel,
                configuredModelIDs: selectedModel.map { [$0] } ?? [],
                credentialProtection: protection,
                latestBackupURL: latestBackup,
                issues: issues
            )
        }
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result: ConfigurationTransactionResult
        do {
            result = try coordinator.restoreLatest { state in
                if let data = state.data(for: Self.configurationTargetID) {
                    _ = try TOMLConfigurationEditor(data: data)
                }
                if state.file(Self.credentialTargetID)?.exists == true,
                   state.file(Self.credentialTargetID)?.permissions != 0o600 {
                    throw ClientConfigurationError.invalidConfiguration("Grok Build 密钥恢复后的权限不是 0600")
                }
            }
        } catch ConfigurationTransactionError.noBackup {
            throw ClientConfigurationError.noBackup(descriptor.name)
        }
        return mappedResult(result, modelID: nil, restored: true)
    }

    private func validatedSelection(_ request: ClientApplyRequest) throws -> ClientModelOption {
        try TOMLClientConfiguratorSupport.validateAPIKey(request.apiKey)
        guard let selected = compatibleModels(from: request.models).first(where: {
            $0.id == request.selectedModelID
        }) else {
            throw ClientConfigurationError.invalidSelection(
                "所选模型不支持 Grok Build 可用的 Responses、Messages 或 Chat Completions 协议"
            )
        }
        return selected
    }

    private func preferredBackend(for model: ClientModelOption) throws -> String {
        if model.protocols.contains(.responses) { return "responses" }
        if model.protocols.contains(.anthropicMessages) { return "messages" }
        if model.protocols.contains(.chatCompletions) { return "chat_completions" }
        throw ClientConfigurationError.noCompatibleModel("所选模型没有 Grok Build 支持的协议")
    }

    private func desiredConfiguration(
        existing: Data?,
        selected: ClientModelOption,
        backend: String
    ) throws -> Data {
        var editor = try existing.map(TOMLConfigurationEditor.init(data:)) ?? TOMLConfigurationEditor()
        try editor.upsert(key: "default", value: .string(Self.modelAlias), inTable: "models")
        try editor.removeManagedSubtree(named: "model.\(Self.modelAlias)")
        try editor.removeManagedSubtree(named: "auth_provider.\(Self.authProviderID)")
        try editor.replaceManagedTable(named: "model.\(Self.modelAlias)", entries: [
            TOMLConfigurationEntry("model", .string(selected.id)),
            TOMLConfigurationEntry("base_url", .string(Self.gatewayV1)),
            TOMLConfigurationEntry("name", .string("YakCool · \(selected.name)")),
            TOMLConfigurationEntry("api_backend", .string(backend)),
            TOMLConfigurationEntry("auth_provider", .string(Self.authProviderID)),
        ])
        try editor.replaceManagedTable(named: "auth_provider.\(Self.authProviderID)", entries: [
            TOMLConfigurationEntry("command", .string("/bin/cat")),
            TOMLConfigurationEntry("args", .stringArray([secretURL.path])),
            TOMLConfigurationEntry("token_ttl_secs", .integer(Self.authTokenTTLSeconds)),
            TOMLConfigurationEntry("timeout_secs", .integer(Self.authTimeoutSeconds)),
        ])
        return editor.renderedData()
    }

    private func validateInstalled(
        _ state: ConfigurationTransactionState,
        expectedModelID: String,
        expectedName: String,
        expectedBackend: String,
        expectedCredential: Data
    ) throws {
        guard let configuration = state.data(for: Self.configurationTargetID),
              state.file(Self.configurationTargetID)?.exists == true,
              state.file(Self.configurationTargetID)?.permissions == 0o600,
              state.data(for: Self.credentialTargetID) == expectedCredential,
              state.file(Self.credentialTargetID)?.exists == true,
              state.file(Self.credentialTargetID)?.permissions == 0o600 else {
            throw ClientConfigurationError.invalidConfiguration("Grok Build 写后文件校验失败")
        }

        let document = try TOMLClientConfigurationDocument(
            data: configuration,
            label: "Grok Build config.toml"
        )
        let modelTable = "model.\(Self.modelAlias)"
        let authTable = "auth_provider.\(Self.authProviderID)"
        let allowedModelAssignments: [String: Set<String>] = [
            modelTable: ["model", "base_url", "name", "api_backend", "auth_provider"],
        ]
        let allowedAuthAssignments: [String: Set<String>] = [
            authTable: ["command", "args", "token_ttl_secs", "timeout_secs"],
        ]
        guard document.string(table: "models", key: "default") == Self.modelAlias,
              document.string(table: modelTable, key: "model") == expectedModelID,
              document.string(table: modelTable, key: "base_url") == Self.gatewayV1,
              document.string(table: modelTable, key: "name") == "YakCool · \(expectedName)",
              document.string(table: modelTable, key: "api_backend") == expectedBackend,
              document.string(table: modelTable, key: "auth_provider") == Self.authProviderID,
              document.string(table: authTable, key: "command") == "/bin/cat",
              document.stringArray(table: authTable, key: "args") == [secretURL.path],
              document.integer(table: authTable, key: "token_ttl_secs") == Self.authTokenTTLSeconds,
              document.integer(table: authTable, key: "timeout_secs") == Self.authTimeoutSeconds,
              !document.hasConflictingManagedShape(
                modelTable,
                allowedAssignments: allowedModelAssignments
              ),
              !document.hasConflictingManagedShape(
                authTable,
                allowedAssignments: allowedAuthAssignments
              ),
              !document.hasAssignment(table: modelTable, key: "api_key"),
              !document.hasAssignment(table: modelTable, key: "env_key"),
              !document.hasAssignment(table: modelTable, key: "token") else {
            throw ClientConfigurationError.invalidConfiguration("Grok Build 写后 TOML 校验失败")
        }
    }

    private func mappedResult(
        _ result: ConfigurationTransactionResult,
        modelID: String?,
        restored: Bool
    ) -> ClientConfigurationResult {
        let action = TOMLClientConfiguratorSupport.clientAction(result.action)
        let changedTargets = result.changedTargetIDs.compactMap { id -> URL? in
            switch id {
            case Self.credentialTargetID: return secretURL
            case Self.configurationTargetID: return configurationURL
            default: return nil
            }
        }
        let message: String
        if restored {
            message = action == .unchanged
                ? "Grok Build 配置已是最近备份状态"
                : "已恢复最近一次 Grok Build 配置备份"
        } else {
            message = action == .unchanged
                ? "Grok Build 已在使用所选 YakCool 模型"
                : "已将 Grok Build 切换到 YakCool / \(modelID ?? "")"
        }
        return ClientConfigurationResult(
            action: action,
            clientID: descriptor.id,
            changedTargets: changedTargets,
            backupURL: result.backupURL,
            modelID: modelID,
            message: message
        )
    }
}
