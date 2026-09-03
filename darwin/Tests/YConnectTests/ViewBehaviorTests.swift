import Foundation
import XCTest
@testable import YConnect

final class ViewBehaviorTests: XCTestCase {
    func testAuthenticationModeUsesExplicitYakCoolLabels() {
        XCTAssertEqual(AuthenticationMode.account.title, "YAKCOOL 账户")
        XCTAssertEqual(AuthenticationMode.apiKey.title, "YAKCOOL APIKEY")
    }

    @MainActor
    func testSignedOutWidgetHeightTracksAuthenticationModeAndViewport() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectSignedOutMetricsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YConnectStore.preview(environment: .preview(at: root), authenticated: false)
        let presentation = WidgetPresentationState()

        store.preferredAuthenticationMode = .account
        XCTAssertEqual(WidgetMetrics.height(for: store, presentation: presentation), 380)

        store.preferredAuthenticationMode = .apiKey
        XCTAssertEqual(WidgetMetrics.height(for: store, presentation: presentation), 420)

        presentation.maximumHeight = 360
        XCTAssertEqual(WidgetMetrics.height(for: store, presentation: presentation), 360)
        XCTAssertTrue(WidgetMetrics.requiresVerticalScrolling(for: store, presentation: presentation))
    }

    func testNextYConnectLabelStartsAfterExistingKeyCountAndAvoidsCollisions() {
        XCTAssertEqual(APIKeyLabelSuggestion.next(existingLabels: []), "YConnect-1")
        XCTAssertEqual(
            APIKeyLabelSuggestion.next(existingLabels: ["Primary", "Work"]),
            "YConnect-3"
        )
        XCTAssertEqual(
            APIKeyLabelSuggestion.next(existingLabels: [" YConnect-1 ", "YConnect-3"]),
            "YConnect-4"
        )
    }

    @MainActor
    func testAPIKeyCreationRequestSelectsKeysPageAndAdvancesRequest() {
        let navigation = ManagerNavigation()

        navigation.requestAPIKeyCreation()

        XCTAssertEqual(navigation.selection, .apiKeys)
        XCTAssertEqual(navigation.apiKeyCreationRequestID, 1)
    }

    @MainActor
    func testCollapsedWidgetKeepsBreathingRoomWithOperationBanner() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectWidgetMetricsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YConnectStore.preview(
            environment: .preview(at: root),
            installedClientIDs: [.claudeCode, .codex, .openCode],
            operationMessage: "“YConnect-4”已删除"
        )
        let presentation = WidgetPresentationState()

        XCTAssertEqual(WidgetMetrics.height(for: store, presentation: presentation), 600)

        presentation.showsConnectionURLs = true
        XCTAssertEqual(WidgetMetrics.height(for: store, presentation: presentation), 752)

        presentation.showsConnectionURLs = false
        presentation.showsModels = true
        XCTAssertEqual(WidgetMetrics.height(for: store, presentation: presentation), 634)
    }

    @MainActor
    func testRecentAccessModelsAreDeduplicatedAndOrderedByMostRecentUse() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectRecentModelsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YConnectStore.preview(environment: .preview(at: root))

        store.recordAccessModelUse("claude-sonnet-4")
        store.recordAccessModelUse("gpt-5")
        store.recordAccessModelUse("claude-sonnet-4")
        store.recordAccessModelUse("not-available")

        XCTAssertEqual(store.recentAccessModelIDs, ["claude-sonnet-4", "gpt-5"])
    }
}
