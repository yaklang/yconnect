import Foundation
import XCTest
@testable import YConnect

final class PiClaudeConfiguratorTests: XCTestCase {
    private var temporaryRoot: URL!
    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiClaudeConfiguratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        environment = .preview(at: temporaryRoot)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        environment = nil
        temporaryRoot = nil
    }

    func testPiFiltersModelsToSelectedWireProtocolAndMapsEverySupportedProtocol() throws {
        let pi = try PiClientConfigurator(environment: environment)
        let models = protocolFixtureModels()
        XCTAssertEqual(pi.compatibleModels(from: models).map(\.id), ["response-only", "anthropic-only", "chat-only", "all-wires"])

        let cases: [(selected: String, api: String, baseURL: String, modelIDs: [String])] = [
            ("response-only", "openai-responses", PiClientConfigurator.gatewayV1, ["response-only", "all-wires"]),
            ("anthropic-only", "anthropic-messages", PiClientConfigurator.gatewayHost, ["anthropic-only", "all-wires"]),
            ("chat-only", "openai-completions", PiClientConfigurator.gatewayV1, ["chat-only", "all-wires"]),
            // Pi has one wire protocol per provider node. For a multi-wire model,
            // the descriptor's explicit priority selects Responses first.
            ("all-wires", "openai-responses", PiClientConfigurator.gatewayV1, ["response-only", "all-wires"]),
        ]

        for item in cases {
            let request = ClientApplyRequest(
                apiKey: "pi-protocol-test-key",
                models: models,
                selectedModelID: item.selected
            )
            _ = try pi.apply(request)
            let modelsRoot = try jsonObject(at: pi.modelsURL)
            let providers = try XCTUnwrap(modelsRoot["providers"] as? [String: Any])
            let provider = try XCTUnwrap(providers[PiClientConfigurator.providerID] as? [String: Any])
            XCTAssertEqual(provider["api"] as? String, item.api)
            XCTAssertEqual(provider["baseUrl"] as? String, item.baseURL)
            let installedModels = try XCTUnwrap(provider["models"] as? [[String: Any]])
            XCTAssertEqual(installedModels.compactMap { $0["id"] as? String }, item.modelIDs)

            let settings = try jsonObject(at: pi.settingsURL)
            XCTAssertEqual(settings["defaultProvider"] as? String, PiClientConfigurator.providerID)
            XCTAssertEqual(settings["defaultModel"] as? String, item.selected)
        }
    }

    func testPiPreservesUnknownFieldsAndNeverRendersOrPersistsCredentialInline() throws {
        let pi = try PiClientConfigurator(environment: environment)
        let initialModels = Data(#"""
        {
          "theme": "keep-root",
          "providers": {
            "other": {
              "baseUrl": "https://other.invalid",
              "custom": 7,
              "apiKey": "unrelated-provider-secret-marker",
              "headers": { "Authorization": "Bearer unrelated-header-secret-marker" }
            },
            "yakcool": {
              "baseUrl": "https://old.invalid",
              "api": "openai-completions",
              "apiKey": "$OLD_KEY",
              "models": [{
                "id": "pi-model",
                "name": "Old display name",
                "contextWindow": 123456,
                "maxTokens": 7890,
                "compat": { "supportsDeveloperRole": true }
              }],
              "keepProviderField": { "nested": true }
            }
          }
        }
        """#.utf8)
        let initialSettings = Data(#"""
        {
          "theme": "keep-settings",
          "defaultProvider": "old-provider",
          "defaultModel": "old-model",
          "customSettings": { "number": 42 }
        }
        """#.utf8)
        try write(initialModels, to: pi.modelsURL, permissions: 0o640)
        try write(initialSettings, to: pi.settingsURL, permissions: 0o640)

        let apiKey = "pi-new-secret-marker-9736f5"
        let request = request(
            apiKey: apiKey,
            selectedModelID: "pi-model",
            protocols: [.responses]
        )
        let preview = try pi.preview(request)
        XCTAssertEqual(try Data(contentsOf: pi.modelsURL), initialModels, "preview must not write")
        XCTAssertEqual(try Data(contentsOf: pi.settingsURL), initialSettings, "preview must not write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pi.secretURL.path))
        assertCredentialAbsent(apiKey, from: preview)
        XCTAssertFalse(String(describing: preview).contains("unrelated-provider-secret-marker"))
        XCTAssertFalse(String(describing: preview).contains("unrelated-header-secret-marker"))
        XCTAssertFalse(String(describing: preview).contains("$OLD_KEY"))

        let result = try pi.apply(request)
        XCTAssertEqual(result.action, .applied)
        XCTAssertEqual(result.changedTargets, [pi.secretURL, pi.modelsURL, pi.settingsURL])
        XCTAssertEqual(try Data(contentsOf: pi.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: pi.secretURL), 0o600)
        XCTAssertEqual(try permissions(of: pi.modelsURL), 0o600)
        XCTAssertEqual(try permissions(of: pi.settingsURL), 0o600)

        let modelsText = try text(at: pi.modelsURL)
        let settingsText = try text(at: pi.settingsURL)
        XCTAssertFalse(modelsText.contains(apiKey))
        XCTAssertFalse(settingsText.contains(apiKey))
        let modelsRoot = try jsonObject(at: pi.modelsURL)
        XCTAssertEqual(modelsRoot["theme"] as? String, "keep-root")
        let providers = try XCTUnwrap(modelsRoot["providers"] as? [String: Any])
        XCTAssertEqual((providers["other"] as? [String: Any])?["custom"] as? Int, 7)
        let yakcool = try XCTUnwrap(providers[PiClientConfigurator.providerID] as? [String: Any])
        XCTAssertEqual(
            (yakcool["keepProviderField"] as? [String: Any])?["nested"] as? Bool,
            true,
            "unowned fields inside the managed provider must survive"
        )
        XCTAssertEqual(yakcool["apiKey"] as? String, ClientCredentialCommand.shellReadCommand(for: pi.secretURL))
        let installedModels = try XCTUnwrap(yakcool["models"] as? [[String: Any]])
        let installedModel = try XCTUnwrap(installedModels.first(where: { $0["id"] as? String == "pi-model" }))
        XCTAssertEqual(installedModel["name"] as? String, "pi-model")
        XCTAssertEqual(installedModel["contextWindow"] as? Int, 123456)
        XCTAssertEqual(installedModel["maxTokens"] as? Int, 7890)
        XCTAssertEqual((installedModel["compat"] as? [String: Any])?["supportsDeveloperRole"] as? Bool, true)
        let settingsRoot = try jsonObject(at: pi.settingsURL)
        XCTAssertEqual(settingsRoot["theme"] as? String, "keep-settings")
        XCTAssertEqual((settingsRoot["customSettings"] as? [String: Any])?["number"] as? Int, 42)

        let manifest = try manifestText(for: result)
        for forbidden in [apiKey, "$OLD_KEY", "https://old.invalid"] {
            XCTAssertFalse(manifest.contains(forbidden), "manifest must contain metadata only")
        }
        XCTAssertEqual(try permissions(of: try XCTUnwrap(result.backupURL)), 0o700)

        let status = try pi.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.selectedModelID, "pi-model")
        XCTAssertEqual(status.configuredModelIDs, ["pi-model"])
        XCTAssertEqual(status.credentialProtection, .safeReference)
    }

    func testPiThreeFileApplyIsIdempotentAndRestoreIsByteExact() throws {
        let pi = try PiClientConfigurator(environment: environment)
        let originalModels = Data(#"{"providers":{"old":{"custom":true}},"format":"original"}"#.utf8)
        let originalSettings = Data(#"{"defaultProvider":"old","defaultModel":"old/model","keep":1}"#.utf8)
        let originalSecret = Data("previous-pi-secret".utf8)
        try write(originalModels, to: pi.modelsURL, permissions: 0o640)
        try write(originalSettings, to: pi.settingsURL, permissions: 0o640)
        try write(originalSecret, to: pi.secretURL, permissions: 0o600)

        let request = request(
            apiKey: "replacement-pi-secret",
            selectedModelID: "pi-selected",
            protocols: [.anthropicMessages]
        )
        let first = try pi.apply(request)
        XCTAssertEqual(first.action, .applied)
        XCTAssertEqual(try visibleBackups(for: .pi).count, 1)

        let second = try pi.apply(request)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertTrue(second.changedTargets.isEmpty)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleBackups(for: .pi).count, 1)

        let restored = try pi.restoreLatest()
        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(restored.backupURL, first.backupURL)
        XCTAssertEqual(try Data(contentsOf: pi.modelsURL), originalModels)
        XCTAssertEqual(try Data(contentsOf: pi.settingsURL), originalSettings)
        XCTAssertEqual(try Data(contentsOf: pi.secretURL), originalSecret)
        XCTAssertEqual(try permissions(of: pi.modelsURL), 0o640)
        XCTAssertEqual(try permissions(of: pi.settingsURL), 0o640)
        XCTAssertEqual(try permissions(of: pi.secretURL), 0o600)
    }

    func testClaudeRemovesInlineEnvUsesHelperPreservesUnknownFieldsAndRestores() throws {
        let claude = try ClaudeCodeClientConfigurator(environment: environment)
        let inlineAPIKey = "old-inline-api-key-marker"
        let inlineToken = "old-inline-auth-token-marker"
        let originalSettings = Data("""
        {
          "theme": "keep-root",
          "permissions": { "allow": ["Read"] },
          "env": {
            "KEEP_ENV": "keep-env",
            "UNRELATED_SERVICE_TOKEN": "unrelated-claude-env-secret-marker",
            "ANTHROPIC_API_KEY": "\(inlineAPIKey)",
            "ANTHROPIC_AUTH_TOKEN": "\(inlineToken)",
            "ANTHROPIC_BASE_URL": "https://old.invalid",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": true,
            "CLAUDE_CODE_USE_FOUNDRY": "yes"
          }
        }
        """.utf8)
        try write(originalSettings, to: claude.settingsURL, permissions: 0o640)

        let apiKey = "claude-new-secret-marker-b071d2"
        let request = self.request(
            apiKey: apiKey,
            selectedModelID: "claude-selected",
            protocols: [.anthropicMessages]
        )
        let preview = try claude.preview(request)
        XCTAssertEqual(try Data(contentsOf: claude.settingsURL), originalSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.secretURL.path))
        assertCredentialAbsent(apiKey, from: preview)
        let previewSettings = try XCTUnwrap(preview.changes.first(where: { $0.url == claude.settingsURL })?.renderedText)
        XCTAssertFalse(previewSettings.contains(inlineAPIKey))
        XCTAssertFalse(previewSettings.contains(inlineToken))
        XCTAssertFalse(previewSettings.contains("unrelated-claude-env-secret-marker"))
        XCTAssertFalse(previewSettings.contains("CLAUDE_CODE_USE_BEDROCK"))
        XCTAssertFalse(previewSettings.contains("CLAUDE_CODE_USE_VERTEX"))
        XCTAssertFalse(previewSettings.contains("CLAUDE_CODE_USE_FOUNDRY"))
        XCTAssertTrue(previewSettings.contains("apiKeyHelper"))

        let first = try claude.apply(request)
        XCTAssertEqual(first.action, .applied)
        XCTAssertEqual(try Data(contentsOf: claude.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: claude.secretURL), 0o600)
        XCTAssertEqual(try permissions(of: claude.settingsURL), 0o600)

        let root = try jsonObject(at: claude.settingsURL)
        XCTAssertEqual(root["theme"] as? String, "keep-root")
        XCTAssertEqual((root["permissions"] as? [String: Any])?["allow"] as? [String], ["Read"])
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["KEEP_ENV"] as? String, "keep-env")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertNil(env["CLAUDE_CODE_USE_VERTEX"])
        XCTAssertNil(env["CLAUDE_CODE_USE_FOUNDRY"])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, ClaudeCodeClientConfigurator.gatewayHost)
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "claude-selected")
        XCTAssertEqual(root["model"] as? String, "claude-selected")
        XCTAssertEqual(
            root["apiKeyHelper"] as? String,
            ClientCredentialCommand.shellReadCommandWithoutSentinel(for: claude.secretURL)
        )
        let installedText = try text(at: claude.settingsURL)
        XCTAssertFalse(installedText.contains(apiKey))
        XCTAssertFalse(try manifestText(for: first).contains(apiKey))

        let status = try claude.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.selectedModelID, "claude-selected")
        XCTAssertEqual(status.credentialProtection, .safeReference)

        let second = try claude.apply(request)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleBackups(for: .claudeCode).count, 1)

        let restored = try claude.restoreLatest()
        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(restored.backupURL, first.backupURL)
        XCTAssertEqual(try Data(contentsOf: claude.settingsURL), originalSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.secretURL.path))
        XCTAssertEqual(try permissions(of: claude.settingsURL), 0o640)
    }

    func testInspectDetectsPiAndClaudeEndpointModelAndCredentialDrift() throws {
        let pi = try PiClientConfigurator(environment: environment)
        let claude = try ClaudeCodeClientConfigurator(environment: environment)
        _ = try pi.apply(request(
            apiKey: "pi-drift-key",
            selectedModelID: "pi-model",
            protocols: [.responses]
        ))
        _ = try claude.apply(request(
            apiKey: "claude-drift-key",
            selectedModelID: "claude-model",
            protocols: [.anthropicMessages]
        ))
        XCTAssertEqual(try pi.inspect().state, .configured)
        XCTAssertEqual(try claude.inspect().state, .configured)

        let installedPiModels = try Data(contentsOf: pi.modelsURL)
        let installedPiSettings = try Data(contentsOf: pi.settingsURL)
        var piModels = try jsonObject(at: pi.modelsURL)
        var piProviders = try XCTUnwrap(piModels["providers"] as? [String: Any])
        var piProvider = try XCTUnwrap(piProviders[PiClientConfigurator.providerID] as? [String: Any])
        piProvider["baseUrl"] = "https://external.invalid/v1"
        piProviders[PiClientConfigurator.providerID] = piProvider
        piModels["providers"] = piProviders
        try writeJSONObject(piModels, to: pi.modelsURL)
        XCTAssertEqual(try pi.inspect().state, .drifted)

        try write(installedPiModels, to: pi.modelsURL, permissions: 0o600)
        var piSettings = try jsonObject(at: pi.settingsURL)
        piSettings["defaultModel"] = "not-in-provider"
        try writeJSONObject(piSettings, to: pi.settingsURL)
        XCTAssertEqual(try pi.inspect().state, .drifted)
        try write(installedPiSettings, to: pi.settingsURL, permissions: 0o600)

        let installedClaudeSettings = try Data(contentsOf: claude.settingsURL)
        var claudeRoot = try jsonObject(at: claude.settingsURL)
        var claudeEnvironment = try XCTUnwrap(claudeRoot["env"] as? [String: Any])
        claudeEnvironment["ANTHROPIC_AUTH_TOKEN"] = "externally-added-token"
        claudeRoot["env"] = claudeEnvironment
        try writeJSONObject(claudeRoot, to: claude.settingsURL)
        let inlineStatus = try claude.inspect()
        XCTAssertEqual(inlineStatus.state, .drifted)
        XCTAssertEqual(inlineStatus.credentialProtection, .unexpectedInline)

        try write(installedClaudeSettings, to: claude.settingsURL, permissions: 0o600)
        claudeRoot = try jsonObject(at: claude.settingsURL)
        claudeEnvironment = try XCTUnwrap(claudeRoot["env"] as? [String: Any])
        claudeEnvironment["CLAUDE_CODE_USE_VERTEX"] = "true"
        claudeRoot["env"] = claudeEnvironment
        try writeJSONObject(claudeRoot, to: claude.settingsURL)
        let cloudStatus = try claude.inspect()
        XCTAssertEqual(cloudStatus.state, .drifted)
        XCTAssertEqual(cloudStatus.credentialProtection, .insecure)

        try write(installedClaudeSettings, to: claude.settingsURL, permissions: 0o600)
        claudeRoot = try jsonObject(at: claude.settingsURL)
        claudeRoot["model"] = "different-model"
        try writeJSONObject(claudeRoot, to: claude.settingsURL)
        XCTAssertEqual(try claude.inspect().state, .drifted)
    }

    func testClaudeFiltersToAnthropicMessagesAndRejectsChatOnlySelectionWithoutWriting() throws {
        let claude = try ClaudeCodeClientConfigurator(environment: environment)
        let models = protocolFixtureModels()
        XCTAssertEqual(claude.compatibleModels(from: models).map(\.id), ["anthropic-only", "all-wires"])

        let request = ClientApplyRequest(
            apiKey: "claude-key",
            models: models,
            selectedModelID: "chat-only"
        )
        XCTAssertThrowsError(try claude.preview(request)) { error in
            guard case ClientConfigurationError.invalidSelection = error else {
                return XCTFail("expected invalid selection, got \(error)")
            }
        }
        XCTAssertThrowsError(try claude.apply(request))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.settingsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.backupsDirectory(for: .claudeCode).path))
    }

    func testPiAndClaudeTargetsAndWritesStayIsolated() throws {
        let pi = try PiClientConfigurator(environment: environment)
        let claude = try ClaudeCodeClientConfigurator(environment: environment)
        XCTAssertNoThrow(try ClientConfigurationRegistry([pi, claude]))
        XCTAssertTrue(Set(pi.targets.map(\.url)).isDisjoint(with: Set(claude.targets.map(\.url))))
        XCTAssertNotEqual(environment.backupsDirectory(for: .pi), environment.backupsDirectory(for: .claudeCode))

        let piRequest = request(apiKey: "pi-isolation-key", selectedModelID: "pi-model", protocols: [.responses])
        _ = try pi.apply(piRequest)
        let piModelsAfterApply = try Data(contentsOf: pi.modelsURL)
        let piSettingsAfterApply = try Data(contentsOf: pi.settingsURL)
        let piSecretAfterApply = try Data(contentsOf: pi.secretURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.settingsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.secretURL.path))

        let claudeRequest = request(
            apiKey: "claude-isolation-key",
            selectedModelID: "claude-model",
            protocols: [.anthropicMessages]
        )
        _ = try claude.apply(claudeRequest)
        XCTAssertEqual(try Data(contentsOf: pi.modelsURL), piModelsAfterApply)
        XCTAssertEqual(try Data(contentsOf: pi.settingsURL), piSettingsAfterApply)
        XCTAssertEqual(try Data(contentsOf: pi.secretURL), piSecretAfterApply)
        XCTAssertEqual(try visibleBackups(for: .pi).count, 1)
        XCTAssertEqual(try visibleBackups(for: .claudeCode).count, 1)
    }

    func testMalformedPiJSONDoesNotWriteAnyOfItsThreeTargets() throws {
        let pi = try PiClientConfigurator(environment: environment)
        let malformedModels = Data(#"{"providers":{"existing":true}"#.utf8)
        let originalSettings = Data(#"{"defaultProvider":"keep","defaultModel":"keep"}"#.utf8)
        try write(malformedModels, to: pi.modelsURL, permissions: 0o640)
        try write(originalSettings, to: pi.settingsURL, permissions: 0o640)
        let request = self.request(apiKey: "must-not-be-written", selectedModelID: "model", protocols: [.responses])

        XCTAssertThrowsError(try pi.preview(request))
        XCTAssertThrowsError(try pi.apply(request))
        XCTAssertEqual(try Data(contentsOf: pi.modelsURL), malformedModels)
        XCTAssertEqual(try Data(contentsOf: pi.settingsURL), originalSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pi.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.backupsDirectory(for: .pi).path))
    }

    func testMalformedClaudeJSONDoesNotWriteSettingsCredentialOrBackup() throws {
        let claude = try ClaudeCodeClientConfigurator(environment: environment)
        let malformedSettings = Data(#"{"env":{"KEEP":"yes"}"#.utf8)
        try write(malformedSettings, to: claude.settingsURL, permissions: 0o640)
        let request = self.request(
            apiKey: "must-not-be-written",
            selectedModelID: "model",
            protocols: [.anthropicMessages]
        )

        XCTAssertThrowsError(try claude.preview(request))
        XCTAssertThrowsError(try claude.apply(request))
        XCTAssertEqual(try Data(contentsOf: claude.settingsURL), malformedSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.backupsDirectory(for: .claudeCode).path))
    }

    func testPiRejectsOversizedOrUnsafeInputBeforeWriting() throws {
        let pi = try PiClientConfigurator(environment: environment)
        let tooManyModels = (0...100).map {
            ClientModelOption(id: "model-\($0)", name: "Model \($0)", protocols: [.responses])
        }
        let invalidRequests = [
            ClientApplyRequest(
                apiKey: "pi-key",
                models: tooManyModels,
                selectedModelID: "model-0"
            ),
            ClientApplyRequest(
                apiKey: "pi-key",
                models: [
                    ClientModelOption(id: "duplicate", name: "First", protocols: [.responses]),
                    ClientModelOption(id: "duplicate", name: "Second", protocols: [.responses]),
                ],
                selectedModelID: "duplicate"
            ),
            ClientApplyRequest(
                apiKey: " pi-key",
                models: [ClientModelOption(id: "model", name: "Model", protocols: [.responses])],
                selectedModelID: "model"
            ),
        ]

        for request in invalidRequests {
            XCTAssertThrowsError(try pi.preview(request))
            XCTAssertThrowsError(try pi.apply(request))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pi.modelsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pi.settingsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pi.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.backupsDirectory(for: .pi).path))
    }

    func testClaudeRejectsUnsafeModelAndCredentialInputBeforeWriting() throws {
        let claude = try ClaudeCodeClientConfigurator(environment: environment)
        let invalidRequests = [
            request(apiKey: " claude-key", selectedModelID: "model", protocols: [.anthropicMessages]),
            ClientApplyRequest(
                apiKey: "claude-key",
                models: [ClientModelOption(id: "model with space", name: "Model", protocols: [.anthropicMessages])],
                selectedModelID: "model with space"
            ),
            ClientApplyRequest(
                apiKey: "claude-key",
                models: [ClientModelOption(id: "model", name: "Bad\nName", protocols: [.anthropicMessages])],
                selectedModelID: "model"
            ),
        ]

        for request in invalidRequests {
            XCTAssertThrowsError(try claude.preview(request))
            XCTAssertThrowsError(try claude.apply(request))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.settingsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.backupsDirectory(for: .claudeCode).path))
    }

    private func protocolFixtureModels() -> [ClientModelOption] {
        [
            ClientModelOption(id: "response-only", name: "Response", protocols: [.responses]),
            ClientModelOption(id: "anthropic-only", name: "Anthropic", protocols: [.anthropicMessages]),
            ClientModelOption(id: "chat-only", name: "Chat", protocols: [.chatCompletions]),
            ClientModelOption(
                id: "all-wires",
                name: "All",
                protocols: [.responses, .anthropicMessages, .chatCompletions]
            ),
            ClientModelOption(id: "unsupported", name: "Unsupported", protocols: [AIProtocol(rawValue: "gemini_native")]),
        ]
    }

    private func request(
        apiKey: String,
        selectedModelID: String,
        protocols: Set<AIProtocol>
    ) -> ClientApplyRequest {
        ClientApplyRequest(
            apiKey: apiKey,
            models: [ClientModelOption(id: selectedModelID, name: selectedModelID, protocols: protocols)],
            selectedModelID: selectedModelID
        )
    }

    private func write(_ data: Data, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try write(data, to: url, permissions: 0o600)
    }

    private func text(at url: URL) throws -> String {
        try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func manifestText(for result: ClientConfigurationResult) throws -> String {
        try text(at: XCTUnwrap(result.backupURL).appendingPathComponent("manifest.json"))
    }

    private func assertCredentialAbsent(
        _ credential: String,
        from preview: ClientConfigurationPreview,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(String(describing: preview).contains(credential), file: file, line: line)
        for change in preview.changes {
            XCTAssertFalse(change.renderedText?.contains(credential) == true, file: file, line: line)
            if change.role == .credential {
                XCTAssertNil(change.renderedText, file: file, line: line)
            }
        }
    }

    private func visibleBackups(for clientID: ClientID) throws -> [URL] {
        let directory = environment.backupsDirectory(for: clientID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
