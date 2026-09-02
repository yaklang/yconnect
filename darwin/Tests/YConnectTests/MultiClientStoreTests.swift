import Foundation
import XCTest
@testable import YConnect

final class MultiClientStoreTests: XCTestCase {
    private let origin = URL(string: "https://multi-client-store-tests.yakcool.com")!

    @MainActor
    func testPreviewFactoryRejectsNetworkAndIgnoresSuppliedClientPaths() async throws {
        let root = try makeTemporaryRoot(named: "OfflinePreview")
        defer { try? FileManager.default.removeItem(at: root) }
        let suppliedConfigurationURL = root
            .appendingPathComponent("ProductionLikeHome/.config/opencode/opencode.json")
        try FileManager.default.createDirectory(
            at: suppliedConfigurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sentinel = Data("{\"fixture\":\"must-remain-unchanged\"}".utf8)
        try sentinel.write(to: suppliedConfigurationURL)
        let suppliedEnvironment = AppEnvironment(
            displayName: "Production-like fixture",
            keychainService: "tests.must-not-be-used",
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            openCodeConfigurationURL: suppliedConfigurationURL,
            clientHomeDirectory: root.appendingPathComponent("ProductionLikeHome"),
            isDevelopment: false
        )

        let store = YConnectStore.preview(environment: suppliedEnvironment)
        XCTAssertEqual(
            store.environment.applicationSupportDirectory.standardizedFileURL,
            suppliedEnvironment.applicationSupportDirectory
                .appendingPathComponent("RenderPreview", isDirectory: true)
                .standardizedFileURL
        )

        await store.applySelectedClientConfiguration()

        XCTAssertTrue(store.errorMessage?.contains("预览模式不执行网络请求") == true)
        XCTAssertEqual(try Data(contentsOf: suppliedConfigurationURL), sentinel)
    }

    @MainActor
    func testPreviewKeepsIndependentPiSelectionAcrossClientSwitches() throws {
        let root = try makeTemporaryRoot(named: "PreviewSelection")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YConnectStore.preview(environment: .preview(at: root))

        XCTAssertEqual(store.selectedClientID, .openCode)
        XCTAssertEqual(store.selectedModelID, "gpt-5")
        store.selectedClientID = .pi
        store.selectedModelID = "claude-sonnet-4"

        store.selectedClientID = .openCode
        XCTAssertEqual(store.selectedModelID, "gpt-5")
        store.selectedClientID = .pi

        XCTAssertEqual(store.selectedModelID, "claude-sonnet-4")
    }

    @MainActor
    func testDuplicateModelIDsMergeProtocolsAndAppearOnceForEachCompatibleClient() async throws {
        let root = try makeTemporaryRoot(named: "DuplicateModels")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try ControlledKeyModelsTransport(models: [
            BusinessKeyModel(
                id: "shared-model",
                name: "Shared Model",
                protocols: ["chat_completions"]
            ),
            BusinessKeyModel(
                id: "shared-model",
                name: "Duplicate Name Must Not Create Another Row",
                protocols: ["anthropic_messages", "responses"]
            ),
        ])
        let store = YConnectStore(
            environment: .preview(at: root),
            api: YakCoolAPI(origin: origin, transport: transport),
            credentialVault: MemoryCredentialVault(),
            preview: true
        )

        await store.signIn(apiKey: "duplicate-model-fixture-key")

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.businessKeyModels.map(\.id), ["shared-model"])
        XCTAssertEqual(
            Set(store.businessKeyModels[0].protocols.map { AIProtocol(rawValue: $0) }),
            [.chatCompletions, .anthropicMessages, .responses]
        )

        for clientID in [ClientID.openCode, .pi, .claudeCode, .codex, .grokBuild] {
            store.selectedClientID = clientID
            XCTAssertEqual(
                store.selectedClientCompatibleModels.map(\.id),
                ["shared-model"],
                "The picker should contain one merged row for \(clientID.rawValue)"
            )
        }
    }

    @MainActor
    func testApplyKeepsClientSelectionAndMessageIsolatedWhenClientChangesDuringKeyModelsAwait() async throws {
        let root = try makeTemporaryRoot(named: "ApplyRace")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview(at: root)
        let openCode = RecordingStoreClient(
            id: .openCode,
            protocols: [.chatCompletions],
            target: root.appendingPathComponent("StubTargets/opencode.json"),
            applyMessage: "OpenCode stub applied"
        )
        let claude = RecordingStoreClient(
            id: .claudeCode,
            protocols: [.anthropicMessages],
            target: root.appendingPathComponent("StubTargets/claude.json"),
            applyMessage: "Claude stub applied"
        )
        let registry = try ClientConfigurationRegistry([openCode, claude])
        let transport = try ControlledKeyModelsTransport(
            models: [
                BusinessKeyModel(
                    id: "open-model",
                    name: "Open Model",
                    protocols: ["chat_completions"]
                ),
                BusinessKeyModel(
                    id: "claude-model",
                    name: "Claude Model",
                    protocols: ["anthropic_messages"]
                ),
            ],
            suspendedKeyModelsRequestNumber: 2
        )
        let store = YConnectStore(
            environment: environment,
            api: YakCoolAPI(origin: origin, transport: transport),
            credentialVault: MemoryCredentialVault(),
            clientRegistry: registry,
            preview: true
        )
        await store.signIn(apiKey: "apply-race-fixture-key")
        XCTAssertEqual(store.selectedClientID, .openCode)
        XCTAssertEqual(store.selectedModelID, "open-model")

        store.selectedClientID = .claudeCode
        store.selectedModelID = "claude-model"
        store.selectedClientID = .openCode
        store.selectedModelID = "open-model"

        let applyTask = Task { @MainActor in
            await store.applySelectedClientConfiguration()
        }
        await transport.waitUntilKeyModelsRequestIsSuspended()

        store.selectedClientID = .claudeCode
        let claudeSelectionBeforeResume = store.selectedModelID
        let claudeMessageBeforeResume = store.selectedClientMessage
        XCTAssertEqual(claudeSelectionBeforeResume, "claude-model")

        await transport.resumeSuspendedKeyModelsRequest()
        await applyTask.value

        XCTAssertEqual(openCode.appliedRequests.map(\.selectedModelID), ["open-model"])
        XCTAssertTrue(claude.appliedRequests.isEmpty)
        XCTAssertEqual(store.selectedClientID, .claudeCode)
        XCTAssertEqual(store.selectedModelID, claudeSelectionBeforeResume)
        XCTAssertEqual(store.clientMessages[.claudeCode], claudeMessageBeforeResume)
        XCTAssertEqual(store.selectedClientMessage, claudeMessageBeforeResume)
        XCTAssertEqual(store.clientMessages[.openCode], "OpenCode stub applied")
        let keyModelsRequestCount = await transport.keyModelsRequestCount()
        XCTAssertEqual(keyModelsRequestCount, 2)
    }

    @MainActor
    func testSecondApplyAndRestoreAreRejectedWhileFirstApplyIsInFlight() async throws {
        let root = try makeTemporaryRoot(named: "ApplyBusyGate")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RecordingStoreClient(
            id: .openCode,
            protocols: [.chatCompletions],
            target: root.appendingPathComponent("StubTargets/opencode.json"),
            applyMessage: "OpenCode stub applied"
        )
        let registry = try ClientConfigurationRegistry([client])
        let transport = try ControlledKeyModelsTransport(
            models: [BusinessKeyModel(
                id: "open-model",
                name: "Open Model",
                protocols: ["chat_completions"]
            )],
            suspendedKeyModelsRequestNumber: 2
        )
        let store = YConnectStore(
            environment: .preview(at: root),
            api: YakCoolAPI(origin: origin, transport: transport),
            credentialVault: MemoryCredentialVault(),
            clientRegistry: registry,
            preview: true
        )
        await store.signIn(apiKey: "busy-gate-fixture-key")

        let firstApply = Task { @MainActor in
            await store.applySelectedClientConfiguration()
        }
        await transport.waitUntilKeyModelsRequestIsSuspended()
        XCTAssertTrue(store.isBusy)

        await store.applySelectedClientConfiguration()
        store.restoreSelectedClientConfiguration()

        let keyModelsRequestCount = await transport.keyModelsRequestCount()
        XCTAssertEqual(keyModelsRequestCount, 2)
        XCTAssertTrue(client.appliedRequests.isEmpty)
        XCTAssertEqual(client.restoreInvocationCount, 0)
        XCTAssertTrue(store.isBusy)

        await transport.resumeSuspendedKeyModelsRequest()
        await firstApply.value

        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(client.appliedRequests.map(\.selectedModelID), ["open-model"])
        XCTAssertEqual(client.restoreInvocationCount, 0)
    }

    @MainActor
    func testServiceChecksFilterForSelectedClientAndUseDescriptorProtocolPriority() async throws {
        let root = try makeTemporaryRoot(named: "ProtocolAwareChecks")
        defer { try? FileManager.default.removeItem(at: root) }
        let openCode = RecordingStoreClient(
            id: .openCode,
            protocols: [.chatCompletions],
            target: root.appendingPathComponent("StubTargets/opencode.json"),
            applyMessage: "OpenCode stub applied"
        )
        let pi = RecordingStoreClient(
            id: .pi,
            protocols: [.responses, .anthropicMessages, .chatCompletions],
            target: root.appendingPathComponent("StubTargets/pi.json"),
            applyMessage: "Pi stub applied"
        )
        let registry = try ClientConfigurationRegistry([openCode, pi])
        let transport = try ProtocolAwareServiceTransport(models: [
            BusinessKeyModel(
                id: "messages-only",
                name: "Messages Only",
                protocols: ["anthropic_messages"]
            ),
            BusinessKeyModel(
                id: "multi-protocol",
                name: "Multi Protocol",
                protocols: ["chat_completions", "responses"]
            ),
        ])
        let store = YConnectStore(
            environment: .preview(at: root),
            api: YakCoolAPI(origin: origin, transport: transport),
            credentialVault: MemoryCredentialVault(),
            clientRegistry: registry,
            preview: true
        )
        await store.signIn(apiKey: "protocol-aware-fixture-key")
        XCTAssertNil(store.errorMessage)

        // A stale/incompatible model selection must not make OpenCode send an
        // Anthropic request; the selected client's capability filters it out.
        store.selectedClientID = .openCode
        store.selectedModelID = "messages-only"
        await store.runServiceChecks(includeLiveCompletion: true)

        var probes = await transport.probeRequests()
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(probes[0].url?.path, "/v1/chat/completions")
        XCTAssertEqual(try modelID(in: probes[0]), "multi-protocol")
        assertPassedCheck(store, id: "completion", contains: "Chat Completions")

        // The model advertises both Chat and Responses. Pi lists Responses
        // first, so descriptor order—not server protocol order—wins.
        store.selectedClientID = .pi
        store.selectedModelID = "multi-protocol"
        await store.runServiceChecks(includeLiveCompletion: true)

        probes = await transport.probeRequests()
        XCTAssertEqual(probes.count, 2)
        XCTAssertEqual(probes[1].url?.path, "/v1/responses")
        XCTAssertEqual(try modelID(in: probes[1]), "multi-protocol")
        assertPassedCheck(store, id: "completion", contains: "Responses")
    }

    @MainActor
    func testServiceChecksFailWithoutClientModelProtocolIntersectionAndSendNoProbe() async throws {
        let root = try makeTemporaryRoot(named: "NoProtocolIntersection")
        defer { try? FileManager.default.removeItem(at: root) }
        let openCode = RecordingStoreClient(
            id: .openCode,
            protocols: [.chatCompletions],
            target: root.appendingPathComponent("StubTargets/opencode.json"),
            applyMessage: "OpenCode stub applied"
        )
        let registry = try ClientConfigurationRegistry([openCode])
        let transport = try ProtocolAwareServiceTransport(models: [
            BusinessKeyModel(
                id: "responses-only",
                name: "Responses Only",
                protocols: ["responses"]
            ),
        ])
        let store = YConnectStore(
            environment: .preview(at: root),
            api: YakCoolAPI(origin: origin, transport: transport),
            credentialVault: MemoryCredentialVault(),
            clientRegistry: registry,
            preview: true
        )
        await store.signIn(apiKey: "no-intersection-fixture-key")

        await store.runServiceChecks(includeLiveCompletion: true)

        let probes = await transport.probeRequests()
        XCTAssertTrue(probes.isEmpty)
        assertFailedCheck(store, id: "models", contains: "没有兼容 opencode 的模型")
        assertFailedCheck(store, id: "completion", contains: "opencode 最小调用")
        XCTAssertEqual(store.operationMessage, "部分检查未通过")
    }

    private func makeTemporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MultiClientStoreTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func modelID(in request: URLRequest) throws -> String {
        let data = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(payload["model"] as? String)
    }

    @MainActor
    private func assertPassedCheck(
        _ store: YConnectStore,
        id: String,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .passed(let message) = store.serviceChecks.first(where: { $0.id == id })?.state else {
            return XCTFail("Expected \(id) to pass", file: file, line: line)
        }
        XCTAssertTrue(message.contains(expected), "Unexpected check message: \(message)", file: file, line: line)
    }

    @MainActor
    private func assertFailedCheck(
        _ store: YConnectStore,
        id: String,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let message) = store.serviceChecks.first(where: { $0.id == id })?.state else {
            return XCTFail("Expected \(id) to fail", file: file, line: line)
        }
        XCTAssertTrue(message.contains(expected), "Unexpected check message: \(message)", file: file, line: line)
    }
}

private actor ProtocolAwareServiceTransport: HTTPTransport {
    private let keyInfoData: Data
    private let keyModelsData: Data
    private var capturedProbes: [URLRequest] = []

    init(models: [BusinessKeyModel]) throws {
        keyInfoData = try JSONEncoder().encode(BusinessKeyInfoResponse(
            schemaVersion: 1,
            key: BusinessKeySummary(label: "Fixture Key", last4: "TEST", status: "active"),
            quota: BusinessQuota(
                mode: "account",
                followsAccount: true,
                approximate: true,
                stepPercent: nil,
                usedPercentApprox: nil,
                remainingPercentApprox: 100,
                currency: nil,
                limitRMB: nil,
                usedRMB: nil,
                remainingRMB: nil,
                exhausted: false,
                display: "fixture quota"
            ),
            queriedAt: "2026-09-03T00:00:00Z"
        ))
        keyModelsData = try JSONEncoder().encode(BusinessKeyModelsResponse(
            schemaVersion: 1,
            object: "list",
            data: models,
            queriedAt: "2026-09-03T00:00:00Z"
        ))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let data: Data
        switch request.url?.path {
        case "/api/health":
            data = Data(#"{"status":"ok"}"#.utf8)
        case "/api/key/info":
            data = keyInfoData
        case "/api/key/models":
            data = keyModelsData
        case "/v1/chat/completions":
            capturedProbes.append(request)
            data = Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        case "/v1/responses":
            capturedProbes.append(request)
            data = Data(#"{"output":[{"content":[{"type":"output_text","text":"OK"}]}]}"#.utf8)
        case "/v1/messages":
            capturedProbes.append(request)
            data = Data(#"{"content":[{"type":"text","text":"OK"}]}"#.utf8)
        default:
            data = try JSONSerialization.data(withJSONObject: [
                "error": "fixture_not_found",
                "message": "No fixture route for \(request.url?.path ?? "")",
            ])
            return (data, TestFixture.httpResponse(for: request, status: 404))
        }
        return (data, TestFixture.httpResponse(for: request, status: 200))
    }

    func probeRequests() -> [URLRequest] {
        capturedProbes
    }
}

private actor ControlledKeyModelsTransport: HTTPTransport {
    private let keyInfoData: Data
    private let keyModelsData: Data
    private let suspendedKeyModelsRequestNumber: Int?
    private var currentKeyModelsRequestCount = 0
    private var requestIsSuspended = false
    private var suspendedRequestContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        models: [BusinessKeyModel],
        suspendedKeyModelsRequestNumber: Int? = nil
    ) throws {
        self.suspendedKeyModelsRequestNumber = suspendedKeyModelsRequestNumber
        keyInfoData = try JSONEncoder().encode(BusinessKeyInfoResponse(
            schemaVersion: 1,
            key: BusinessKeySummary(label: "Fixture Key", last4: "TEST", status: "active"),
            quota: BusinessQuota(
                mode: "account",
                followsAccount: true,
                approximate: true,
                stepPercent: nil,
                usedPercentApprox: nil,
                remainingPercentApprox: 100,
                currency: nil,
                limitRMB: nil,
                usedRMB: nil,
                remainingRMB: nil,
                exhausted: false,
                display: "fixture quota"
            ),
            queriedAt: "2026-09-03T00:00:00Z"
        ))
        keyModelsData = try JSONEncoder().encode(BusinessKeyModelsResponse(
            schemaVersion: 1,
            object: "list",
            data: models,
            queriedAt: "2026-09-03T00:00:00Z"
        ))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        switch request.url?.path {
        case "/api/key/info":
            return (keyInfoData, TestFixture.httpResponse(for: request, status: 200))
        case "/api/key/models":
            currentKeyModelsRequestCount += 1
            if currentKeyModelsRequestCount == suspendedKeyModelsRequestNumber {
                requestIsSuspended = true
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { continuation in
                    suspendedRequestContinuation = continuation
                }
                requestIsSuspended = false
            }
            return (keyModelsData, TestFixture.httpResponse(for: request, status: 200))
        default:
            let data = try JSONSerialization.data(withJSONObject: [
                "error": "fixture_not_found",
                "message": "No fixture route for \(request.url?.path ?? "")",
            ])
            return (data, TestFixture.httpResponse(for: request, status: 404))
        }
    }

    func waitUntilKeyModelsRequestIsSuspended() async {
        if requestIsSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumeSuspendedKeyModelsRequest() {
        let continuation = suspendedRequestContinuation
        suspendedRequestContinuation = nil
        continuation?.resume()
    }

    func keyModelsRequestCount() -> Int {
        currentKeyModelsRequestCount
    }
}

private final class RecordingStoreClient: ClientConfiguring {
    let descriptor: ClientDescriptor
    let targets: [ClientConfigurationTarget]
    let applyMessage: String
    private(set) var appliedRequests: [ClientApplyRequest] = []
    private(set) var restoreInvocationCount = 0

    init(
        id: ClientID,
        protocols: [AIProtocol],
        target: URL,
        applyMessage: String
    ) {
        descriptor = ClientDescriptor(
            id: id,
            name: id.rawValue,
            shortName: id.rawValue,
            symbol: "terminal",
            summary: "multi-client store fixture",
            supportedProtocols: protocols,
            configurationPath: target.path,
            restartNote: "",
            availability: .ready
        )
        targets = [ClientConfigurationTarget(url: target, role: .configuration)]
        self.applyMessage = applyMessage
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        ClientConfigurationPreview(
            clientID: descriptor.id,
            selectedModelID: request.selectedModelID,
            changes: []
        )
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        appliedRequests.append(request)
        return ClientConfigurationResult(
            action: .applied,
            clientID: descriptor.id,
            changedTargets: targets.map(\.url),
            backupURL: nil,
            modelID: request.selectedModelID,
            message: applyMessage
        )
    }

    func inspect() throws -> ClientConfigurationStatus {
        ClientConfigurationStatus(
            clientID: descriptor.id,
            state: appliedRequests.isEmpty ? .notConfigured : .configured,
            selectedModelID: appliedRequests.last?.selectedModelID,
            configuredModelIDs: appliedRequests.map(\.selectedModelID),
            credentialProtection: .safeReference,
            latestBackupURL: nil,
            issues: []
        )
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        restoreInvocationCount += 1
        throw ClientConfigurationError.noBackup(descriptor.name)
    }
}
