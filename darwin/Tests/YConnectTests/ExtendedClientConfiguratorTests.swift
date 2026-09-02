import Foundation
import XCTest
@testable import YConnect

final class ExtendedClientConfiguratorTests: XCTestCase {
    private var temporaryRoot: URL!
    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtendedClientConfiguratorTests-\(UUID().uuidString)", isDirectory: true)
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

    func testDescriptorsAndClaudeDesktopSelectionBoundary() throws {
        XCTAssertEqual(ClaudeDesktopClientConfigurator.descriptor.id, .claudeDesktop)
        XCTAssertEqual(OpenClawClientConfigurator.descriptor.id, .openClaw)
        XCTAssertEqual(HermesClientConfigurator.descriptor.id, .hermes)

        let claude = try ClaudeDesktopClientConfigurator(environment: environment)
        let models = [
            model("claude-sonnet", [.anthropicMessages]),
            model("anthropic/claude-opus", [.anthropicMessages, .responses]),
            model("claude-", [.anthropicMessages]),
            model("anthropic/claude-", [.anthropicMessages]),
            model("gpt-messages", [.anthropicMessages]),
            model("claude-chat-only", [.chatCompletions]),
        ]
        XCTAssertEqual(
            claude.compatibleModels(from: models).map(\.id),
            ["claude-sonnet", "anthropic/claude-opus"]
        )

        for invalidID in [
            "claude-", "anthropic/claude-", "gpt-messages", "claude-chat-only",
        ] {
            let request = ClientApplyRequest(
                apiKey: "selection-boundary-key",
                models: models,
                selectedModelID: invalidID
            )
            XCTAssertThrowsError(try claude.preview(request)) { error in
                guard case ClientConfigurationError.invalidSelection = error else {
                    return XCTFail("expected invalidSelection, got \(error)")
                }
            }
            XCTAssertThrowsError(try claude.apply(request))
        }

        let oversizedKey = String(repeating: "k", count: 513)
        let oversizedModelID = "claude-" + String(repeating: "m", count: 194)
        XCTAssertEqual(oversizedModelID.utf8.count, 201)
        XCTAssertThrowsError(try claude.preview(request(
            apiKey: oversizedKey,
            selectedModelID: "claude-sonnet",
            protocols: [.anthropicMessages]
        )))
        XCTAssertThrowsError(try claude.preview(request(
            apiKey: "bounded-key",
            selectedModelID: oversizedModelID,
            protocols: [.anthropicMessages]
        )))
        for url in claude.targets.map(\.url) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .claudeDesktop).path
        ))
    }

    func testEveryRenderedModelIsBoundedAndValidatedBeforeReadingConfiguration() throws {
        let openClaw = try OpenClawClientConfigurator(environment: environment)
        let invalidName = ClientModelOption(
            id: "bad-name-model",
            name: String(repeating: "n", count: 257),
            protocols: [.responses]
        )
        let badNameRequest = ClientApplyRequest(
            apiKey: "model-validation-key",
            models: [model("selected", [.responses]), invalidName],
            selectedModelID: "selected"
        )
        XCTAssertThrowsError(try openClaw.preview(badNameRequest))

        let invalidID = String(repeating: "i", count: 201)
        let badIDRequest = ClientApplyRequest(
            apiKey: "model-validation-key",
            models: [model("selected", [.responses]), model(invalidID, [.responses])],
            selectedModelID: "selected"
        )
        XCTAssertThrowsError(try openClaw.preview(badIDRequest))

        let tooManyModels = (0...100).map { model("model-\($0)", [.responses]) }
        XCTAssertThrowsError(try openClaw.preview(ClientApplyRequest(
            apiKey: "model-validation-key",
            models: tooManyModels,
            selectedModelID: "model-0"
        )))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openClaw.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openClaw.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .openClaw).path
        ))
    }

    func testPreviewRejectsOversizedMutationPlanBeforeRenderingOrWriting() throws {
        let maximumByteCount = 64
        let apiKey = "oversized-preview-secret-marker"
        let openClaw = try OpenClawClientConfigurator(
            environment: environment,
            maximumConfigurationByteCount: maximumByteCount
        )

        XCTAssertThrowsError(try openClaw.preview(request(
            apiKey: apiKey,
            selectedModelID: "bounded-plan-model",
            protocols: [.responses]
        ))) { error in
            guard case ConfigurationTransactionError.fileTooLarge(let path, let maximum) = error else {
                return XCTFail("expected planned output size rejection, got \(error)")
            }
            XCTAssertEqual(path, openClaw.configurationURL.path)
            XCTAssertEqual(maximum, maximumByteCount)
            XCTAssertFalse(String(describing: error).contains(apiKey))
            XCTAssertFalse(error.localizedDescription.contains(apiKey))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: openClaw.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openClaw.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .openClaw).path
        ))
    }

    func testClaudeDesktopPreviewApplyInspectIdempotenceAndRestoreAreSafe() throws {
        let claude = try ClaudeDesktopClientConfigurator(environment: environment)
        let oldInlineKey = "old-desktop-inline-key-marker"
        let unrelatedSecret = "unrelated-desktop-api-key-marker"
        let metadataSecret = "unrelated-metadata-token-marker"
        let originalProfile = Data("""
        {
          "theme": "keep-profile",
          "inferenceGatewayApiKey": "\(oldInlineKey)",
          "unrelatedProvider": {
            "api_key": "\(unrelatedSecret)",
            "headers": { "Authorization": "Bearer unrelated-desktop-header-marker" }
          }
        }
        """.utf8)
        let originalMetadata = Data("""
        {
          "version": 17,
          "appliedId": "old-profile",
          "entries": [
            {"id": "other-profile", "name": "Other", "token": "\(metadataSecret)"},
            {
              "id": "\(ClaudeDesktopClientConfigurator.profileID)",
              "name": "Old YakCool",
              "keepEntryField": {"enabled": true}
            }
          ]
        }
        """.utf8)
        let oldSecret = Data("previous-desktop-managed-secret".utf8)
        try write(originalProfile, to: claude.profileURL, permissions: 0o640)
        try write(originalMetadata, to: claude.metadataURL, permissions: 0o644)
        try write(oldSecret, to: claude.secretURL, permissions: 0o600)

        let apiKey = "desktop-new-secret-786351"
        let applyRequest = ClientApplyRequest(
            apiKey: apiKey,
            models: [
                model("claude-sonnet-4", [.anthropicMessages]),
                model("gpt-should-not-appear", [.anthropicMessages]),
                model("anthropic/claude-opus-4", [.anthropicMessages]),
            ],
            selectedModelID: "claude-sonnet-4"
        )
        let preview = try claude.preview(applyRequest)
        XCTAssertEqual(try Data(contentsOf: claude.profileURL), originalProfile)
        XCTAssertEqual(try Data(contentsOf: claude.metadataURL), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: claude.secretURL), oldSecret)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.helperURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .claudeDesktop).path
        ))
        for forbidden in [
            apiKey, oldInlineKey, unrelatedSecret, metadataSecret,
            "Bearer unrelated-desktop-header-marker",
        ] {
            assertCredentialAbsent(forbidden, from: preview)
        }
        XCTAssertNil(preview.changes.first(where: { $0.url == claude.secretURL })?.renderedText)
        XCTAssertNil(preview.changes.first(where: { $0.url == claude.helperURL })?.renderedText)

        let result = try claude.apply(applyRequest)
        XCTAssertEqual(result.action, .applied)
        XCTAssertEqual(
            result.changedTargets,
            [claude.secretURL, claude.helperURL, claude.profileURL, claude.metadataURL]
        )
        XCTAssertEqual(try Data(contentsOf: claude.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: claude.secretURL), 0o600)
        XCTAssertEqual(try permissions(of: claude.helperURL), 0o700)
        XCTAssertEqual(try permissions(of: claude.profileURL), 0o600)
        XCTAssertEqual(try permissions(of: claude.metadataURL), 0o600)

        let helperText = try text(at: claude.helperURL)
        XCTAssertTrue(helperText.hasPrefix("#!/bin/sh\nexec /bin/cat "))
        XCTAssertTrue(helperText.contains(shellQuote(claude.secretURL.path)))
        XCTAssertFalse(helperText.contains(apiKey))
        let profile = try jsonObject(at: claude.profileURL)
        XCTAssertEqual(profile["theme"] as? String, "keep-profile")
        XCTAssertNil(profile["inferenceGatewayApiKey"])
        XCTAssertEqual(profile["inferenceProvider"] as? String, "gateway")
        XCTAssertEqual(
            profile["inferenceGatewayBaseUrl"] as? String,
            "https://aibalance.yaklang.com"
        )
        XCTAssertEqual(profile["inferenceGatewayAuthScheme"] as? String, "bearer")
        XCTAssertEqual(profile["inferenceCredentialKind"] as? String, "helper-script")
        XCTAssertEqual(profile["inferenceCredentialHelper"] as? String, claude.helperURL.path)
        XCTAssertEqual(profile["inferenceCredentialHelperTtlSec"] as? Int, 300)
        XCTAssertEqual(profile["inferenceCredentialHelperTimeoutSec"] as? Int, 5)
        XCTAssertEqual(profile["inferenceCredentialHelperSilentRefreshEnabled"] as? Bool, true)
        let installedModels = try XCTUnwrap(profile["inferenceModels"] as? [[String: Any]])
        XCTAssertEqual(
            installedModels.compactMap { $0["name"] as? String },
            ["claude-sonnet-4", "anthropic/claude-opus-4"]
        )
        let metadata = try jsonObject(at: claude.metadataURL)
        XCTAssertEqual(metadata["version"] as? Int, 17)
        XCTAssertEqual(metadata["appliedId"] as? String, ClaudeDesktopClientConfigurator.profileID)
        let entries = try XCTUnwrap(metadata["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.filter {
            $0["id"] as? String == ClaudeDesktopClientConfigurator.profileID
        }.count, 1)
        let managedEntry = try XCTUnwrap(entries.first {
            $0["id"] as? String == ClaudeDesktopClientConfigurator.profileID
        })
        XCTAssertEqual(managedEntry["name"] as? String, ClaudeDesktopClientConfigurator.profileName)
        XCTAssertEqual((managedEntry["keepEntryField"] as? [String: Any])?["enabled"] as? Bool, true)

        for data in [try Data(contentsOf: claude.profileURL), try Data(contentsOf: claude.metadataURL)] {
            XCTAssertFalse(data.range(of: Data(apiKey.utf8)) != nil)
        }
        let status = try claude.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.selectedModelID, "claude-sonnet-4")
        XCTAssertEqual(
            status.configuredModelIDs,
            ["claude-sonnet-4", "anthropic/claude-opus-4"]
        )
        XCTAssertEqual(status.credentialProtection, .safeReference)
        XCTAssertTrue(status.issues.isEmpty)

        let manifest = try manifestText(for: result)
        for forbidden in [apiKey, oldInlineKey, unrelatedSecret, metadataSecret] {
            XCTAssertFalse(manifest.contains(forbidden))
        }
        let second = try claude.apply(applyRequest)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleBackups(for: .claudeDesktop).count, 1)

        let restored = try claude.restoreLatest()
        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(restored.backupURL, result.backupURL)
        XCTAssertEqual(try Data(contentsOf: claude.profileURL), originalProfile)
        XCTAssertEqual(try Data(contentsOf: claude.metadataURL), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: claude.secretURL), oldSecret)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.helperURL.path))
        XCTAssertEqual(try permissions(of: claude.profileURL), 0o640)
        XCTAssertEqual(try permissions(of: claude.metadataURL), 0o644)
    }

    func testOpenClawChoosesResponsesThenMessagesThenChatWithoutWriting() throws {
        let openClaw = try OpenClawClientConfigurator(environment: environment)
        let cases: [(Set<AIProtocol>, String, String)] = [
            ([.responses, .anthropicMessages, .chatCompletions], "openai-responses", "https://aibalance.yaklang.com/v1"),
            ([.anthropicMessages, .chatCompletions], "anthropic-messages", "https://aibalance.yaklang.com"),
            ([.chatCompletions], "openai-completions", "https://aibalance.yaklang.com/v1"),
        ]
        for (index, item) in cases.enumerated() {
            let modelID = "openclaw-model-\(index)"
            let preview = try openClaw.preview(request(
                apiKey: "openclaw-protocol-key",
                selectedModelID: modelID,
                protocols: item.0
            ))
            let rendered = try XCTUnwrap(configurationText(in: preview, url: openClaw.configurationURL))
            let root = try jsonObject(data: Data(rendered.utf8))
            let provider = try XCTUnwrap(
                ((root["models"] as? [String: Any])?["providers"] as? [String: Any])?["yakcool"]
                    as? [String: Any]
            )
            XCTAssertEqual(provider["api"] as? String, item.1)
            XCTAssertEqual(provider["baseUrl"] as? String, item.2)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: openClaw.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openClaw.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .openClaw).path
        ))
    }

    func testOpenClawJSON5ApplyInspectIdempotenceAndRestoreAreSafe() throws {
        let openClaw = try OpenClawClientConfigurator(environment: environment)
        let oldProviderSecret = "old-openclaw-provider-token-marker"
        let oldHeaderSecret = "old-openclaw-authorization-header-marker"
        let oldExtraHeaderSecret = "old-openclaw-extra-header-marker"
        let oldRequestSecret = "old-openclaw-request-auth-marker"
        let unrelatedSecret = "unrelated-openclaw-api-key-marker"
        let originalConfiguration = Data(#"""
        {
          // JSON5 comments and unquoted keys are accepted
          theme: 'keep-root',
          models: {
            mode: 'replace',
            providers: {
              other: { apiKey: 'unrelated-openclaw-api-key-marker', custom: 9 },
              yakcool: {
                api: 'openai-completions',
                baseUrl: 'https://old.invalid/v1',
                token: 'old-openclaw-provider-token-marker',
                headers: { Authorization: 'Bearer old-openclaw-authorization-header-marker' },
                extraHeaders: { 'X-API-Key': 'old-openclaw-extra-header-marker' },
                request: {
                  headers: { Authorization: 'Bearer old-openclaw-request-header-marker' },
                  auth: 'old-openclaw-request-auth-marker',
                },
                keepProviderField: { nested: true },
                models: [{ id: 'claw-model', name: 'Old', contextWindow: 131072 }],
              },
            },
          },
          secrets: {
            providers: {
              other: { source: 'env', allowlist: ['OTHER_KEY'] },
              yconnect: { source: 'env', value: 'old-openclaw-secret-value', keep: true },
            },
          },
          agents: { defaults: { model: { primary: 'other/model', fallbacks: ['keep/fallback'] } } },
        }
        """#.utf8)
        let originalSecret = Data("previous-openclaw-managed-secret".utf8)
        try write(originalConfiguration, to: openClaw.configurationURL, permissions: 0o640)
        try write(originalSecret, to: openClaw.secretURL, permissions: 0o600)

        let apiKey = "openclaw-new-secret-21e35f"
        let applyRequest = ClientApplyRequest(
            apiKey: apiKey,
            models: [
                model("claw-model", [.responses]),
                model("other-response", [.responses]),
                model("chat-only", [.chatCompletions]),
            ],
            selectedModelID: "claw-model"
        )
        let preview = try openClaw.preview(applyRequest)
        XCTAssertEqual(try Data(contentsOf: openClaw.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: openClaw.secretURL), originalSecret)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .openClaw).path
        ))
        for forbidden in [
            apiKey, oldProviderSecret, oldHeaderSecret, oldExtraHeaderSecret,
            oldRequestSecret, "Bearer old-openclaw-request-header-marker",
            unrelatedSecret, "old-openclaw-secret-value",
        ] {
            assertCredentialAbsent(forbidden, from: preview)
        }

        let result = try openClaw.apply(applyRequest)
        XCTAssertEqual(result.action, .applied)
        XCTAssertEqual(result.changedTargets, [openClaw.secretURL, openClaw.configurationURL])
        XCTAssertEqual(try Data(contentsOf: openClaw.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: openClaw.secretURL), 0o600)
        XCTAssertEqual(try permissions(of: openClaw.configurationURL), 0o600)
        let root = try jsonObject(at: openClaw.configurationURL)
        XCTAssertEqual(root["theme"] as? String, "keep-root")
        let models = try XCTUnwrap(root["models"] as? [String: Any])
        XCTAssertEqual(models["mode"] as? String, "merge")
        let providers = try XCTUnwrap(models["providers"] as? [String: Any])
        XCTAssertEqual((providers["other"] as? [String: Any])?["custom"] as? Int, 9)
        let provider = try XCTUnwrap(providers["yakcool"] as? [String: Any])
        XCTAssertEqual(provider["api"] as? String, "openai-responses")
        XCTAssertEqual(provider["baseUrl"] as? String, "https://aibalance.yaklang.com/v1")
        XCTAssertNil(provider["token"])
        XCTAssertNil(provider["headers"])
        XCTAssertNil(provider["extraHeaders"])
        XCTAssertNil(provider["request"])
        XCTAssertEqual((provider["keepProviderField"] as? [String: Any])?["nested"] as? Bool, true)
        let reference = try XCTUnwrap(provider["apiKey"] as? [String: Any])
        XCTAssertEqual(reference["source"] as? String, "file")
        XCTAssertEqual(reference["provider"] as? String, "yconnect")
        XCTAssertEqual(reference["id"] as? String, "value")
        let providerModels = try XCTUnwrap(provider["models"] as? [[String: Any]])
        XCTAssertEqual(providerModels.compactMap { $0["id"] as? String }, ["claw-model", "other-response"])
        XCTAssertEqual(providerModels[0]["contextWindow"] as? Int, 131072)
        let secretProvider = try XCTUnwrap(
            ((root["secrets"] as? [String: Any])?["providers"] as? [String: Any])?["yconnect"]
                as? [String: Any]
        )
        XCTAssertEqual(secretProvider["source"] as? String, "file")
        XCTAssertEqual(secretProvider["path"] as? String, openClaw.secretURL.path)
        XCTAssertEqual(secretProvider["mode"] as? String, "singleValue")
        XCTAssertEqual(secretProvider["timeoutMs"] as? Int, 5_000)
        XCTAssertEqual(secretProvider["keep"] as? Bool, true)
        XCTAssertNil(secretProvider["value"])
        let modelSelection = try XCTUnwrap(
            (((root["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"])
                as? [String: Any]
        )
        XCTAssertEqual(modelSelection["primary"] as? String, "yakcool/claw-model")
        XCTAssertEqual(modelSelection["fallbacks"] as? [String], ["keep/fallback"])
        XCTAssertFalse(try text(at: openClaw.configurationURL).contains(apiKey))

        let status = try openClaw.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.selectedModelID, "claw-model")
        XCTAssertEqual(status.configuredModelIDs, ["claw-model", "other-response"])
        XCTAssertEqual(status.credentialProtection, .safeReference)
        XCTAssertTrue(status.issues.isEmpty)
        let manifest = try manifestText(for: result)
        for forbidden in [
            apiKey, oldProviderSecret, oldHeaderSecret, oldExtraHeaderSecret,
            oldRequestSecret, unrelatedSecret, "previous-openclaw-managed-secret",
        ] {
            XCTAssertFalse(manifest.contains(forbidden))
        }

        let second = try openClaw.apply(applyRequest)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleBackups(for: .openClaw).count, 1)
        let restored = try openClaw.restoreLatest()
        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(try Data(contentsOf: openClaw.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: openClaw.secretURL), originalSecret)
        XCTAssertEqual(try permissions(of: openClaw.configurationURL), 0o640)
    }

    func testOpenClawReportsInlineCredentialAndRejectsUnsafePath() throws {
        let openClaw = try OpenClawClientConfigurator(environment: environment)
        let unsafe = Data("""
        {
          "models": {
            "mode": "merge",
            "providers": {
              "yakcool": {
                "baseUrl": "https://aibalance.yaklang.com/v1",
                "api": "openai-responses",
                "apiKey": {"source": "file", "provider": "yconnect", "id": "value"},
                "request": {
                  "headers": {"Authorization": "Bearer stale-secret"},
                  "auth": "stale-request-auth"
                },
                "models": [{"id": "model", "name": "Model"}]
              }
            }
          },
          "secrets": {
            "providers": {
              "yconnect": {
                "source": "file",
                "path": "\(openClaw.secretURL.path)",
                "mode": "singleValue",
                "timeoutMs": 5000
              }
            }
          },
          "agents": {"defaults": {"model": {"primary": "yakcool/model"}}}
        }
        """.utf8)
        try write(unsafe, to: openClaw.configurationURL, permissions: 0o600)
        try write(Data("safe-managed-secret".utf8), to: openClaw.secretURL, permissions: 0o600)
        let status = try openClaw.inspect()
        XCTAssertEqual(status.state, .drifted)
        XCTAssertEqual(status.credentialProtection, .unexpectedInline)

        try FileManager.default.removeItem(at: openClaw.configurationURL)
        let destination = temporaryRoot.appendingPathComponent("outside-openclaw.json")
        try Data("{}".utf8).write(to: destination)
        try FileManager.default.createDirectory(
            at: openClaw.configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: openClaw.configurationURL,
            withDestinationURL: destination
        )
        XCTAssertThrowsError(try OpenClawClientConfigurator(environment: environment))
    }

    func testHermesChoosesResponsesThenMessagesThenChatWithoutWriting() throws {
        let hermes = try HermesClientConfigurator(environment: environment)
        let cases: [(Set<AIProtocol>, String, String)] = [
            ([.responses, .anthropicMessages, .chatCompletions], "codex_responses", HermesClientConfigurator.gatewayV1),
            ([.anthropicMessages, .chatCompletions], "anthropic_messages", HermesClientConfigurator.gatewayHost),
            ([.chatCompletions], "chat_completions", HermesClientConfigurator.gatewayV1),
        ]
        for (index, item) in cases.enumerated() {
            let preview = try hermes.preview(request(
                apiKey: "hermes-protocol-key",
                selectedModelID: "hermes-model-\(index)",
                protocols: item.0
            ))
            let rendered = try XCTUnwrap(configurationText(in: preview, url: hermes.configurationURL))
            XCTAssertTrue(rendered.contains("api: \"\(item.2)\""))
            XCTAssertTrue(rendered.contains("transport: \"\(item.1)\""))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.helperURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .hermes).path
        ))
    }

    func testHermesYAMLApplyInspectIdempotenceAndRestoreAreSafe() throws {
        let hermes = try HermesClientConfigurator(environment: environment)
        let oldInline = "old-hermes-inline-key-marker"
        let unrelated = "unrelated-hermes-api-key-marker"
        let oldExtraHeader = "old-hermes-extra-header-marker"
        let originalConfiguration = Data("""
        # preserve Hermes comment\r
        telemetry:\r
          enabled: false\r
        providers:\r
          other:\r
            api: "https://other.invalid/v1"\r
            api_key: "\(unrelated)"\r
          yakcool:\r
            api: "https://old.invalid/v1"\r
            api_key: "\(oldInline)"\r
            key_env: "OLD_HERMES_KEY"\r
            extra_headers:\r
              Authorization: "Bearer \(oldExtraHeader)"\r
            keep_provider_field: "keep # quoted hash"\r
            models:\r
              "hermes-model":\r
                context_window: 131072\r
        model:\r
          default: "old-model"\r
          provider: "custom:old"\r
          temperature: 0.2\r
        """.utf8)
        let originalSecret = Data("previous-hermes-managed-secret".utf8)
        let originalHelper = helperData(secretURL: hermes.secretURL)
        try write(originalConfiguration, to: hermes.configurationURL, permissions: 0o640)
        try write(originalSecret, to: hermes.secretURL, permissions: 0o600)
        try write(originalHelper, to: hermes.helperURL, permissions: 0o700)

        let apiKey = "hermes-new-secret-8d8bc5"
        let applyRequest = ClientApplyRequest(
            apiKey: apiKey,
            models: [
                model("hermes-model", [.anthropicMessages]),
                model("second-hermes", [.anthropicMessages]),
                model("response-only", [.responses]),
            ],
            selectedModelID: "hermes-model"
        )
        let preview = try hermes.preview(applyRequest)
        XCTAssertEqual(try Data(contentsOf: hermes.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: hermes.secretURL), originalSecret)
        XCTAssertEqual(try Data(contentsOf: hermes.helperURL), originalHelper)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .hermes).path
        ))
        for forbidden in [apiKey, oldInline, unrelated, oldExtraHeader, "OLD_HERMES_KEY"] {
            assertCredentialAbsent(forbidden, from: preview)
        }
        XCTAssertNil(preview.changes.first(where: { $0.url == hermes.secretURL })?.renderedText)
        XCTAssertNil(preview.changes.first(where: { $0.url == hermes.helperURL })?.renderedText)

        let result = try hermes.apply(applyRequest)
        XCTAssertEqual(result.action, .applied)
        XCTAssertEqual(
            result.changedTargets,
            [hermes.secretURL, hermes.helperURL, hermes.configurationURL]
        )
        XCTAssertEqual(try Data(contentsOf: hermes.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: hermes.secretURL), 0o600)
        XCTAssertEqual(try permissions(of: hermes.helperURL), 0o700)
        XCTAssertEqual(try permissions(of: hermes.configurationURL), 0o600)
        let helperText = try text(at: hermes.helperURL)
        XCTAssertTrue(helperText.contains("exec /bin/cat \(shellQuote(hermes.secretURL.path))"))
        XCTAssertFalse(helperText.contains(apiKey))

        let installed = try text(at: hermes.configurationURL)
        XCTAssertTrue(installed.contains("# preserve Hermes comment\r\n"))
        XCTAssertTrue(installed.contains("enabled: false\r\n"))
        XCTAssertTrue(installed.contains("api_key: \"\(unrelated)\"\r\n"))
        XCTAssertTrue(installed.contains("keep_provider_field: \"keep # quoted hash\"\r\n"))
        XCTAssertTrue(installed.contains("temperature: 0.2\r\n"))
        XCTAssertTrue(installed.contains("context_window: 131072\r\n"))
        XCTAssertTrue(installed.contains("api: \"\(HermesClientConfigurator.gatewayHost)\"\r\n"))
        XCTAssertTrue(installed.contains("transport: \"anthropic_messages\"\r\n"))
        XCTAssertTrue(installed.contains("default_model: \"hermes-model\"\r\n"))
        XCTAssertTrue(installed.contains("key_cmd: \""))
        XCTAssertTrue(installed.contains(shellQuote(hermes.helperURL.path)))
        XCTAssertTrue(installed.contains("\"second-hermes\": {}\r\n"))
        XCTAssertTrue(installed.contains("default: \"hermes-model\"\r\n"))
        XCTAssertTrue(installed.contains("provider: \"custom:yakcool\"\r\n"))
        XCTAssertFalse(installed.contains(oldInline))
        XCTAssertFalse(installed.contains("extra_headers"))
        XCTAssertFalse(installed.contains(oldExtraHeader))
        XCTAssertFalse(installed.contains("OLD_HERMES_KEY"))
        XCTAssertFalse(installed.contains(apiKey))
        XCTAssertFalse(installed.replacingOccurrences(of: "\r\n", with: "").contains("\n"))

        let status = try hermes.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.selectedModelID, "hermes-model")
        XCTAssertEqual(status.configuredModelIDs, ["hermes-model", "second-hermes"])
        XCTAssertEqual(status.credentialProtection, .safeReference)
        XCTAssertTrue(status.issues.isEmpty)
        let manifest = try manifestText(for: result)
        for forbidden in [
            apiKey, oldInline, unrelated, oldExtraHeader, "previous-hermes-managed-secret",
        ] {
            XCTAssertFalse(manifest.contains(forbidden))
        }

        let second = try hermes.apply(applyRequest)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleBackups(for: .hermes).count, 1)
        let restored = try hermes.restoreLatest()
        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(try Data(contentsOf: hermes.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: hermes.secretURL), originalSecret)
        XCTAssertEqual(try Data(contentsOf: hermes.helperURL), originalHelper)
        XCTAssertEqual(try permissions(of: hermes.configurationURL), 0o640)
        XCTAssertEqual(try permissions(of: hermes.helperURL), 0o700)
    }

    func testHermesSwitchingProtocolRemovesStaleCatalogModels() throws {
        let hermes = try HermesClientConfigurator(environment: environment)
        let models = [
            model("responses-only", [.responses]),
            model("messages-only", [.anthropicMessages]),
            model("chat-only", [.chatCompletions]),
        ]
        _ = try hermes.apply(ClientApplyRequest(
            apiKey: "hermes-switch-key",
            models: models,
            selectedModelID: "responses-only"
        ))
        XCTAssertEqual(try hermes.inspect().configuredModelIDs, ["responses-only"])

        _ = try hermes.apply(ClientApplyRequest(
            apiKey: "hermes-switch-key",
            models: models,
            selectedModelID: "messages-only"
        ))
        let status = try hermes.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.configuredModelIDs, ["messages-only"])
        let installed = try text(at: hermes.configurationURL)
        XCTAssertFalse(installed.contains("\"responses-only\":"))
        XCTAssertFalse(installed.contains("\"chat-only\":"))
        XCTAssertTrue(installed.contains("\"messages-only\": {}"))
        XCTAssertTrue(installed.contains("transport: \"anthropic_messages\""))
    }

    func testHermesPreservesAdjacentCommentsAndMissingTrailingNewline() throws {
        let hermes = try HermesClientConfigurator(environment: environment)
        let original = Data("""
        # leading comment
        providers:
          yakcool:
            api_key: "remove-me"
            # adjacent comment must survive
            keep_provider_field: true
        model:
          temperature: 0.2
        # final comment without newline
        """.utf8)
        XCTAssertFalse(original.last == 0x0A)
        try write(original, to: hermes.configurationURL, permissions: 0o600)

        let applyRequest = request(
            apiKey: "hermes-comment-key",
            selectedModelID: "comment-model",
            protocols: [.responses]
        )
        let preview = try hermes.preview(applyRequest)
        let rendered = try XCTUnwrap(configurationText(in: preview, url: hermes.configurationURL))
        XCTAssertTrue(rendered.contains("# adjacent comment must survive"))
        XCTAssertTrue(rendered.contains("# final comment without newline"))
        XCTAssertFalse(rendered.hasSuffix("\n"))

        _ = try hermes.apply(applyRequest)
        let installed = try text(at: hermes.configurationURL)
        XCTAssertTrue(installed.contains("# leading comment"))
        XCTAssertTrue(installed.contains("# adjacent comment must survive"))
        XCTAssertTrue(installed.contains("# final comment without newline"))
        XCTAssertTrue(installed.contains("keep_provider_field: true"))
        XCTAssertFalse(installed.hasSuffix("\n"))
        XCTAssertEqual(try hermes.inspect().state, .configured)
    }

    func testHermesRejectsAmbiguousOwnedYAMLShapesWithoutWriting() throws {
        let hermes = try HermesClientConfigurator(environment: environment)
        let invalidDocuments = [
            "---\nproviders:\n  yakcool: {}\n",
            "providers:\n  - yakcool: {}\n",
            "providers: { yakcool: {} }\n",
            "providers: &shared\n  yakcool: {}\n",
            "providers: !custom\n  yakcool: {}\n",
            "providers:\n  yakcool:\n    models:\n      - model-one\n",
            "model: [one, two]\n",
            "providers:\n  <<: *provider_defaults\n",
        ]
        for source in invalidDocuments {
            let original = Data(source.utf8)
            try write(original, to: hermes.configurationURL, permissions: 0o600)
            XCTAssertThrowsError(try hermes.preview(request(
                apiKey: "hermes-shape-key",
                selectedModelID: "shape-model",
                protocols: [.responses]
            )), "must reject: \(source)")
            XCTAssertEqual(try Data(contentsOf: hermes.configurationURL), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.secretURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.helperURL.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: environment.backupsDirectory(for: .hermes).path
            ))
        }
    }

    func testHermesInspectRejectsExtraHeadersAndApplyRemovesThem() throws {
        let hermes = try HermesClientConfigurator(environment: environment)
        let applyRequest = request(
            apiKey: "hermes-extra-header-key",
            selectedModelID: "header-model",
            protocols: [.responses]
        )
        _ = try hermes.apply(applyRequest)
        var installed = try text(at: hermes.configurationURL)
        installed = installed.replacingOccurrences(
            of: "  yakcool:\n",
            with: "  yakcool:\n    extra_headers: {Authorization: \"Bearer injected-secret\"}\n"
        )
        try write(Data(installed.utf8), to: hermes.configurationURL, permissions: 0o600)
        let unsafeStatus = try hermes.inspect()
        XCTAssertEqual(unsafeStatus.state, .drifted)
        XCTAssertEqual(unsafeStatus.credentialProtection, .unexpectedInline)
        XCTAssertTrue(unsafeStatus.issues.contains(where: { $0.contains("extra_headers") }))

        let preview = try hermes.preview(applyRequest)
        assertCredentialAbsent("injected-secret", from: preview)
        _ = try hermes.apply(applyRequest)
        XCTAssertFalse(try text(at: hermes.configurationURL).contains("extra_headers"))
        XCTAssertEqual(try hermes.inspect().state, .configured)
    }

    func testHelperRestoreRejectsWrongContentOrExecutablePermissions() throws {
        for index in 0...1 {
            let isolatedEnvironment = AppEnvironment.preview(
                at: temporaryRoot.appendingPathComponent("UnsafeRestore-\(index)", isDirectory: true)
            )
            let hermes = try HermesClientConfigurator(environment: isolatedEnvironment)
            let originalHelper = index == 0
                ? Data("#!/bin/sh\nexit 9\n".utf8)
                : helperData(secretURL: hermes.secretURL)
            try write(originalHelper, to: hermes.helperURL, permissions: index == 0 ? 0o700 : 0o755)
            let applyRequest = request(
                apiKey: "restore-validation-key-\(index)",
                selectedModelID: "restore-model",
                protocols: [.responses]
            )
            _ = try hermes.apply(applyRequest)
            if index == 0 {
                XCTAssertThrowsError(try hermes.restoreLatest())
                XCTAssertEqual(
                    try Data(contentsOf: hermes.helperURL),
                    helperData(secretURL: hermes.secretURL)
                )
                XCTAssertEqual(try hermes.inspect().state, .configured)
            } else {
                XCTAssertEqual(try hermes.restoreLatest().action, .restored)
                XCTAssertEqual(try Data(contentsOf: hermes.helperURL), originalHelper)
                XCTAssertEqual(try hermes.inspect().state, .notConfigured)
            }
            XCTAssertEqual(try permissions(of: hermes.helperURL), 0o700)
        }
    }

    func testHermesRejectsDuplicateManagedYAMLAndDoesNotLeakCredentialInError() throws {
        let hermes = try HermesClientConfigurator(environment: environment)
        let existingSecret = "duplicate-yaml-secret-marker"
        let invalid = Data("""
        providers:
          yakcool:
            api_key: "\(existingSecret)"
        providers:
          other: {}
        """.utf8)
        try write(invalid, to: hermes.configurationURL, permissions: 0o600)
        let newSecret = "new-error-secret-marker"
        XCTAssertThrowsError(try hermes.preview(request(
            apiKey: newSecret,
            selectedModelID: "hermes-model",
            protocols: [.responses]
        ))) { error in
            let rendered = String(describing: error)
            XCTAssertFalse(rendered.contains(newSecret))
            XCTAssertFalse(rendered.contains(existingSecret))
        }
        XCTAssertEqual(try Data(contentsOf: hermes.configurationURL), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.helperURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.backupsDirectory(for: .hermes).path
        ))
    }

    private func model(_ id: String, _ protocols: Set<AIProtocol>) -> ClientModelOption {
        ClientModelOption(id: id, name: "Display \(id)", protocols: protocols)
    }

    private func request(
        apiKey: String,
        selectedModelID: String,
        protocols: Set<AIProtocol>
    ) -> ClientApplyRequest {
        ClientApplyRequest(
            apiKey: apiKey,
            models: [model(selectedModelID, protocols)],
            selectedModelID: selectedModelID
        )
    }

    private func write(_ data: Data, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func text(at url: URL) throws -> String {
        try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try jsonObject(data: Data(contentsOf: url))
    }

    private func jsonObject(data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        )
    }

    private func configurationText(
        in preview: ClientConfigurationPreview,
        url: URL
    ) -> String? {
        preview.changes.first(where: { $0.url == url })?.renderedText
    }

    private func manifestText(for result: ClientConfigurationResult) throws -> String {
        let backup = try XCTUnwrap(result.backupURL)
        return try XCTUnwrap(String(
            data: Data(contentsOf: backup.appendingPathComponent("manifest.json")),
            encoding: .utf8
        ))
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
            if change.role == .credential || change.role == .helper {
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

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func helperData(secretURL: URL) -> Data {
        Data("#!/bin/sh\nexec /bin/cat \(shellQuote(secretURL.path))\n".utf8)
    }
}
