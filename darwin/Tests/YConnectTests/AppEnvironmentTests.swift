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
