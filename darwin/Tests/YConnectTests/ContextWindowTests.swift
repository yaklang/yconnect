import Foundation
import XCTest
@testable import YConnect

final class ContextWindowTests: XCTestCase {
    func testValidatesBoundsAndRejectsMalformedOrOverflowingInput() throws {
        XCTAssertEqual(try ContextWindowSetting.parse(" 500000 "), 500_000)
        XCTAssertNil(try ContextWindowSetting.parse("  "))
        for text in ["0", "-500000", "500K", "500,000", "5e5", "500000;echo", "10000001", "99999999999999999999999"] {
            XCTAssertThrowsError(try ContextWindowSetting.parse(text), text)
        }
    }

    @MainActor
    func testContextPreferencesFollowModelAndClientWithoutLeakingToAnotherModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YConnectStore.preview(environment: .preview(at: root), installedClientIDs: [.grokBuild, .openCode])
        store.selectedClientID = .grokBuild
        store.selectedModelID = "gpt-5"
        store.contextWindowInput = "500000"
        store.selectedModelID = "claude-sonnet-4"
        XCTAssertEqual(store.contextWindowInput, "")
        store.contextWindowInput = "200000"
        store.selectedModelID = "gpt-5"
        XCTAssertEqual(store.contextWindowInput, "500000")
        store.selectedClientID = .openCode
        XCTAssertEqual(store.contextWindowInput, "")
        store.selectedClientID = .grokBuild
        XCTAssertEqual(store.contextWindowInput, "500000")
        store.contextWindowInput = "bad"
        XCTAssertNotNil(store.contextWindowValidationMessage)
    }

    func testGrokWritesValidatesRestoresAndRemovesContextOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let grok = try GrokBuildClientConfigurator(environment: .preview(at: root))
        func request(_ context: Int?) -> ClientApplyRequest {
            ClientApplyRequest(apiKey: "fake-context-test", models: [ClientModelOption(id: "qwen-test", name: "Qwen", protocols: [.chatCompletions])], selectedModelID: "qwen-test", contextWindow: context)
        }
        _ = try grok.apply(request(nil))
        let original = try Data(contentsOf: grok.configurationURL)
        _ = try grok.apply(request(500_000))
        var document = try TOMLClientConfigurationDocument(data: Data(contentsOf: grok.configurationURL), label: "test")
        XCTAssertEqual(document.integer(table: "model.yakcool", key: "context_window"), 500_000)
        XCTAssertEqual(try grok.inspect().state, .configured)
        XCTAssertEqual(try grok.apply(request(500_000)).action, .unchanged)
        XCTAssertThrowsError(try grok.apply(request(-1)))
        _ = try grok.restoreLatest()
        XCTAssertEqual(try Data(contentsOf: grok.configurationURL), original)
        _ = try grok.apply(request(1_000_000))
        _ = try grok.apply(request(nil))
        document = try TOMLClientConfigurationDocument(data: Data(contentsOf: grok.configurationURL), label: "test")
        XCTAssertFalse(document.hasAssignment(table: "model.yakcool", key: "context_window"))
    }

    func testIsolatedGrokLaunchReceivesContextOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try ClientLauncher.prepare(environment: .preview(at: root), clientID: .grokBuild,
            model: ClientModelOption(id: "qwen-test", name: "Qwen", protocols: [.chatCompletions]),
            apiKey: "fake-launch-context-test", directory: root.path, autoStart: true,
            executable: URL(fileURLWithPath: "/bin/echo"), runner: URL(fileURLWithPath: "/bin/echo"), contextWindow: 500_000)
        let grokHome = try XCTUnwrap(plan.manifest.variables["GROK_HOME"])
        let data = try Data(contentsOf: URL(fileURLWithPath: grokHome).appendingPathComponent("config.toml"))
        let document = try TOMLClientConfigurationDocument(data: data, label: "launch")
        XCTAssertEqual(document.integer(table: "model.yakcool", key: "context_window"), 500_000)
        XCTAssertEqual(plan.manifest.arguments, ["--model", "yakcool"])
    }
}
