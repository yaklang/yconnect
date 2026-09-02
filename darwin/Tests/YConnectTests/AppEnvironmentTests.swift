import Foundation
import XCTest
@testable import YConnect

final class AppEnvironmentTests: XCTestCase {
    func testPreviewEnvironmentUsesOnlyDedicatedPathsAndIdentity() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectPreviewTests-\(UUID().uuidString)", isDirectory: true)

        let environment = AppEnvironment.preview(at: root)

        XCTAssertEqual(environment.displayName, "YConnect Preview")
        XCTAssertEqual(environment.keychainService, "io.yaklang.yconnect.preview")
        XCTAssertEqual(environment.applicationSupportDirectory, root)
        XCTAssertEqual(environment.openCodeConfigurationURL, root.appendingPathComponent("opencode.json"))
        XCTAssertTrue(environment.isDevelopment)
        XCTAssertNotEqual(environment.keychainService, "io.yaklang.yconnect")
        XCTAssertNotEqual(environment.keychainService, "io.yaklang.yconnect.dev")
        XCTAssertTrue(environment.openCodeConfigurationURL.path.hasPrefix(root.path + "/"))
        XCTAssertFalse(environment.openCodeConfigurationURL.path.contains("/.config/opencode/"))

        let expectedPaths: [ClientID: [String]] = [
            .openCode: ["opencode.json"],
            .pi: ["ClientSandbox/Home/.pi/agent/models.json", "ClientSandbox/Home/.pi/agent/settings.json"],
            .claudeCode: ["ClientSandbox/Home/.claude/settings.json"],
            .codex: ["ClientSandbox/Home/.codex/config.toml"],
            .grokBuild: ["ClientSandbox/Home/.grok/config.toml"],
            .claudeDesktop: [
                "ClientSandbox/Home/Library/Application Support/Claude-3p/configLibrary/9d254f75-6d3a-4b8c-a0e8-4d3a4f4d42f7.json",
                "ClientSandbox/Home/Library/Application Support/Claude-3p/configLibrary/_meta.json",
            ],
            .geminiCLI: ["ClientSandbox/Home/.gemini/.env", "ClientSandbox/Home/.gemini/settings.json"],
            .openClaw: ["ClientSandbox/Home/.openclaw/openclaw.json"],
            .hermes: ["ClientSandbox/Home/.hermes/config.yaml"],
        ]
        for (clientID, suffixes) in expectedPaths {
            let urls = environment.configurationURLs(for: clientID)
            XCTAssertEqual(urls.count, suffixes.count, "\(clientID.rawValue) path count")
            for (url, suffix) in zip(urls, suffixes) {
                XCTAssertTrue(url.path.hasPrefix(root.path + "/"), "\(clientID.rawValue) escaped preview root")
                XCTAssertTrue(url.path.hasSuffix("/" + suffix), "\(clientID.rawValue) unexpected path: \(url.path)")
            }
            let secret = environment.managedSecretURL(for: clientID)
            let helper = environment.managedHelperURL(for: clientID)
            let backup = environment.backupsDirectory(for: clientID)
            XCTAssertTrue(secret.path.hasPrefix(root.path + "/"))
            XCTAssertTrue(helper.path.hasPrefix(root.path + "/"))
            XCTAssertTrue(backup.path.hasPrefix(root.path + "/"))
        }
    }

    @MainActor
    func testPreviewStoreDoesNotReadOrWritePersistentSelections() async {
        let previousKeyID = YConnectPreferences.selectedAccountKeyID
        let previousModelID = YConnectPreferences.selectedModelID
        defer {
            YConnectPreferences.selectedAccountKeyID = previousKeyID
            YConnectPreferences.selectedModelID = previousModelID
        }

        let persistentKeyID: Int64 = 9_876_543
        let persistentModelID = "persistent-model-fixture"
        YConnectPreferences.selectedAccountKeyID = persistentKeyID
        YConnectPreferences.selectedModelID = persistentModelID
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectPreviewStoreTests-\(UUID().uuidString)", isDirectory: true)

        let store = YConnectStore.preview(environment: .preview(at: root))

        XCTAssertEqual(store.selectedAccountKeyID, 11)
        XCTAssertEqual(store.selectedModelID, "gpt-5")
        XCTAssertEqual(YConnectPreferences.selectedAccountKeyID, persistentKeyID)
        XCTAssertEqual(YConnectPreferences.selectedModelID, persistentModelID)

        store.selectedAccountKeyID = 12
        store.selectedModelID = "claude-sonnet-4"
        await store.restoreSession()

        XCTAssertEqual(store.phase, .account)
        XCTAssertEqual(YConnectPreferences.selectedAccountKeyID, persistentKeyID)
        XCTAssertEqual(YConnectPreferences.selectedModelID, persistentModelID)
    }
}
