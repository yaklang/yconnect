import Foundation
import XCTest
@testable import YConnect

final class DefaultClientConfigurationRegistryTests: XCTestCase {
    private let expectedClientIDs: [ClientID] = [
        .openCode,
        .pi,
        .claudeCode,
        .claudeDesktop,
        .codex,
        .grokBuild,
        .openClaw,
        .hermes,
    ]

    @MainActor
    func testPreviewDefaultCompositionMatchesReadyCatalogInStableOrder() throws {
        let root = try makeTemporaryRoot(named: "Catalog")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview(at: root)

        let registry = try DefaultClientConfigurationRegistry.make(environment: environment)
        let registeredIDs = registry.descriptors.map(\.id)
        let readyIDs = Set(
            ClientSupportCatalog.ccSwitchScope
                .filter { $0.availability == .ready }
                .map(\.id)
        )

        XCTAssertEqual(registeredIDs, expectedClientIDs)
        XCTAssertEqual(Set(registeredIDs), readyIDs)
        XCTAssertTrue(registry.descriptors.allSatisfy { $0.availability == .ready })

        let store = YConnectStore.preview(environment: environment)
        XCTAssertEqual(store.clientDescriptors.map(\.id), expectedClientIDs)
    }

    func testPreviewDefaultCompositionTargetsAreUniqueAndContainedBySandbox() throws {
        let root = try makeTemporaryRoot(named: "Targets")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview(at: root)
        let registry = try DefaultClientConfigurationRegistry.make(environment: environment)

        let targets = expectedClientIDs.flatMap { clientID -> [ClientConfigurationTarget] in
            guard let client = registry[clientID] else {
                XCTFail("Missing default adapter for \(clientID.rawValue)")
                return []
            }
            return client.targets
        }
        XCTAssertEqual(targets.count, 20)

        let canonicalRoot = ConfigurationPathCanonicalizer.canonicalizedURL(root)
        let canonicalTargetPaths = targets.map {
            ConfigurationPathCanonicalizer.canonicalizedURL($0.url).path
        }
        XCTAssertEqual(
            Set(canonicalTargetPaths).count,
            canonicalTargetPaths.count,
            "Every default adapter target must have exclusive ownership"
        )
        for path in canonicalTargetPaths {
            XCTAssertTrue(
                isDescendant(path: path, of: canonicalRoot.path),
                "Default adapter target escaped the preview root: \(path)"
            )
        }
    }

    @MainActor
    func testSymlinkedCodexFinalPathDoesNotCollapseDefaultComposition() throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryRoot(named: "SymlinkIsolation")
        defer { try? fileManager.removeItem(at: root) }
        let environment = AppEnvironment.preview(at: root)
        let codexConfigurationURL = try XCTUnwrap(environment.configurationURLs(for: .codex).first)
        try fileManager.createDirectory(
            at: codexConfigurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let realConfigurationURL = root
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("real-codex-config.toml", isDirectory: false)
        try fileManager.createDirectory(
            at: realConfigurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalConfiguration = Data("fixture = \"must-remain-unchanged\"\n".utf8)
        try originalConfiguration.write(to: realConfigurationURL)
        try fileManager.createSymbolicLink(
            at: codexConfigurationURL,
            withDestinationURL: realConfigurationURL
        )

        let registry = try DefaultClientConfigurationRegistry.make(
            environment: environment,
            fileManager: fileManager
        )
        XCTAssertEqual(registry.descriptors.map(\.id), expectedClientIDs)

        let store = YConnectStore(
            environment: environment,
            credentialVault: MemoryCredentialVault(),
            preview: true
        )
        XCTAssertEqual(store.clientDescriptors.map(\.id), expectedClientIDs)

        let request = ClientApplyRequest(
            apiKey: "sk-default-composition-fixture",
            models: [ClientModelOption(
                id: "claude-fixture-model",
                name: "Fixture Model",
                protocols: [.chatCompletions, .responses, .anthropicMessages]
            )],
            selectedModelID: "claude-fixture-model"
        )
        let codex = try XCTUnwrap(registry[.codex])
        XCTAssertThrowsError(try codex.apply(request)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("符号链接"),
                "Expected the retained initialization error, got: \(error)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: realConfigurationURL), originalConfiguration)
        XCTAssertFalse(fileManager.fileExists(
            atPath: environment.managedSecretURL(for: .codex).path
        ))

        for clientID in expectedClientIDs where clientID != .codex {
            let client = try XCTUnwrap(registry[clientID])
            XCTAssertNoThrow(
                try client.preview(request),
                "A failed Codex initializer must not disable \(clientID.rawValue)"
            )
        }
    }

    private func makeTemporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DefaultClientConfigurationRegistryTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func isDescendant(path: String, of root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
