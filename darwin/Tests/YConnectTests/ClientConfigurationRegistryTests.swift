import Foundation
import XCTest
@testable import YConnect

final class ClientConfigurationRegistryTests: XCTestCase {
    func testCCSwitchCoverageCatalogContainsNineIndependentClientTypesExactlyOnce() {
        let scope = ClientSupportCatalog.ccSwitchScope

        XCTAssertEqual(scope.count, 9)
        XCTAssertEqual(Set(scope.map(\.id)).count, 9)
        XCTAssertEqual(
            scope.map(\.id),
            [
                .claudeCode, .claudeDesktop, .codex, .geminiCLI, .grokBuild,
                .openCode, .openClaw, .hermes, .pi,
            ]
        )
        XCTAssertEqual(
            Set(scope.filter { $0.availability == .ready }.map(\.id)),
            [
                .claudeCode, .claudeDesktop, .codex, .grokBuild,
                .openCode, .openClaw, .hermes, .pi,
            ]
        )
        XCTAssertEqual(
            scope.first(where: { $0.id == .geminiCLI })?.availability,
            .requiresBridge
        )
    }

    func testRegistryPreservesOrderAndFiltersModelsByClientProtocol() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientRegistryTests-\(UUID().uuidString)", isDirectory: true)
        let openCode = StubClient(
            id: .openCode,
            protocols: [.chatCompletions],
            target: root.appendingPathComponent("opencode.json")
        )
        let claude = StubClient(
            id: .claudeCode,
            protocols: [.anthropicMessages],
            target: root.appendingPathComponent("claude.json")
        )

        let registry = try ClientConfigurationRegistry([openCode, claude])
        XCTAssertEqual(registry.descriptors.map(\.id), [.openCode, .claudeCode])
        XCTAssertTrue(registry[.openCode] === openCode)
        XCTAssertTrue(registry[.claudeCode] === claude)

        let models = [
            ClientModelOption(id: "chat", name: "Chat", protocols: [.chatCompletions]),
            ClientModelOption(id: "messages", name: "Messages", protocols: [.anthropicMessages]),
            ClientModelOption(id: "both", name: "Both", protocols: [.chatCompletions, .anthropicMessages]),
            ClientModelOption(id: "unknown", name: "Unknown", protocols: [AIProtocol(rawValue: "future")]),
        ]
        XCTAssertEqual(openCode.compatibleModels(from: models).map(\.id), ["chat", "both"])
        XCTAssertEqual(claude.compatibleModels(from: models).map(\.id), ["messages", "both"])
    }

    func testRegistryRejectsDuplicateClientAndCrossClientTargetCollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientRegistryCollisions-\(UUID().uuidString)", isDirectory: true)
        let shared = root.appendingPathComponent("shared.json")
        let first = StubClient(id: .openCode, protocols: [.chatCompletions], target: shared)
        let duplicate = StubClient(
            id: .openCode,
            protocols: [.responses],
            target: root.appendingPathComponent("other.json")
        )
        XCTAssertThrowsError(try ClientConfigurationRegistry([first, duplicate])) { error in
            guard case ClientConfigurationError.duplicateClient = error else {
                return XCTFail("expected duplicate-client error, got \(error)")
            }
        }

        let collision = StubClient(id: .codex, protocols: [.responses], target: shared)
        XCTAssertThrowsError(try ClientConfigurationRegistry([first, collision])) { error in
            guard case ClientConfigurationError.collidingTarget(let path) = error else {
                return XCTFail("expected target-collision error, got \(error)")
            }
            XCTAssertEqual(path, ConfigurationPathCanonicalizer.canonicalizedURL(shared).path)
        }

        let internallyDuplicated = StubClient(
            id: .pi,
            protocols: [.responses],
            targets: [shared, shared]
        )
        XCTAssertThrowsError(try ClientConfigurationRegistry([internallyDuplicated])) { error in
            guard case ClientConfigurationError.collidingTarget(let path) = error else {
                return XCTFail("expected same-adapter target-collision error, got \(error)")
            }
            XCTAssertEqual(path, ConfigurationPathCanonicalizer.canonicalizedURL(shared).path)
        }
    }

    func testRegistryDetectsPhysicalCollisionThroughSymlinkedParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientRegistryAliases-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let first = StubClient(
            id: .openCode,
            protocols: [.chatCompletions],
            target: real.appendingPathComponent("config.json")
        )
        let second = StubClient(
            id: .codex,
            protocols: [.responses],
            target: alias.appendingPathComponent("config.json")
        )

        XCTAssertThrowsError(try ClientConfigurationRegistry([first, second])) { error in
            guard case ClientConfigurationError.collidingTarget(let path) = error else {
                return XCTFail("expected canonical target-collision error, got \(error)")
            }
            XCTAssertEqual(path, real.appendingPathComponent("config.json").standardizedFileURL.path)
        }
    }

    func testOpenCodeFacadePreviewRedactsUnrelatedProviderCredentials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeFacadePreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("home/.config/opencode/opencode.json")
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingSecret = "unrelated-provider-secret-marker-a83f"
        let existing = """
        {
          "theme": "keep-me",
          "provider": {
            "other": {
              "options": {
                "apiKey": "\(existingSecret)",
                "headers": { "Authorization": "Bearer hidden-header-marker" }
              }
            }
          }
        }
        """
        try Data(existing.utf8).write(to: configurationURL)

        let facade = OpenCodeClientConfigurator(configurator: OpenCodeConfigurator(
            configurationURL: configurationURL,
            applicationSupportDirectory: supportURL
        ))
        let newCredential = "new-preview-credential-marker-c91e"
        let preview = try facade.preview(ClientApplyRequest(
            apiKey: newCredential,
            models: [ClientModelOption(
                id: "chat-model",
                name: "Chat Model",
                protocols: [.chatCompletions]
            )],
            selectedModelID: "chat-model"
        ))
        let description = String(describing: preview)

        XCTAssertFalse(description.contains(existingSecret))
        XCTAssertFalse(description.contains("hidden-header-marker"))
        XCTAssertFalse(description.contains(newCredential))
        XCTAssertTrue(description.contains("<redacted>"))
        XCTAssertTrue(description.contains("keep-me"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: facade.targets.first(where: { $0.role == .credential })?.url.path ?? ""
        ))
    }
}

private final class StubClient: ClientConfiguring {
    let descriptor: ClientDescriptor
    let targets: [ClientConfigurationTarget]

    init(id: ClientID, protocols: [AIProtocol], target: URL) {
        self.descriptor = ClientDescriptor(
            id: id,
            name: id.rawValue,
            shortName: id.rawValue,
            symbol: "terminal",
            summary: "fixture",
            supportedProtocols: protocols,
            configurationPath: target.path,
            restartNote: "",
            availability: .ready
        )
        self.targets = [ClientConfigurationTarget(url: target, role: .configuration)]
    }

    init(id: ClientID, protocols: [AIProtocol], targets: [URL]) {
        descriptor = ClientDescriptor(
            id: id,
            name: id.rawValue,
            shortName: id.rawValue,
            symbol: "terminal",
            summary: "fixture",
            supportedProtocols: protocols,
            configurationPath: targets.first?.path ?? "",
            restartNote: "",
            availability: .ready
        )
        self.targets = targets.map { ClientConfigurationTarget(url: $0, role: .configuration) }
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        ClientConfigurationPreview(clientID: descriptor.id, selectedModelID: request.selectedModelID, changes: [])
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        ClientConfigurationResult(
            action: .unchanged,
            clientID: descriptor.id,
            changedTargets: [],
            backupURL: nil,
            modelID: request.selectedModelID,
            message: "fixture"
        )
    }

    func inspect() throws -> ClientConfigurationStatus {
        ClientConfigurationStatus(
            clientID: descriptor.id,
            state: .notConfigured,
            selectedModelID: nil,
            configuredModelIDs: [],
            credentialProtection: .missing,
            latestBackupURL: nil,
            issues: []
        )
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        throw ClientConfigurationError.noBackup(descriptor.name)
    }
}
