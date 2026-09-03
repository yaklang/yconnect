import Foundation
import XCTest
@testable import YConnect

final class YConnectStoreTests: XCTestCase {
    private let origin = URL(string: "https://store-tests.yakcool.com")!

    func testAccountBalanceDisplaysOneFractionDigit() {
        let credit = CreditSummary(
            status: "ok",
            uid: "fixture-account",
            tokenLimit: nil,
            tokenUsed: nil,
            tokenRemaining: 3_962_332_000,
            tokenLimitEnabled: true,
            tokenLimitRMB: nil,
            tokenUsedRMB: nil,
            weightedTokensPerRMB: 10_000_000,
            error: nil
        )

        XCTAssertEqual(credit.remainingRMB, "396.2")
    }

    func testOnlyAuthenticationFailuresInvalidateStoredCredentials() {
        XCTAssertTrue(YConnectError.invalidCredential("invalid").invalidatesStoredCredential)
        XCTAssertTrue(
            YConnectError.server(status: 401, code: "invalid_api_key", message: "invalid")
                .invalidatesStoredCredential
        )
        XCTAssertFalse(
            YConnectError.server(status: 500, code: "upstream_unavailable", message: "temporary")
                .invalidatesStoredCredential
        )
        XCTAssertFalse(YConnectError.transport("offline").invalidatesStoredCredential)
        XCTAssertFalse(YConnectError.file("keychain unavailable").invalidatesStoredCredential)
        XCTAssertFalse(YConnectError.invalidResponse.invalidatesStoredCredential)
    }

    func testBusinessQuotaPresentationDistinguishesIndependentAndSharedBalance() {
        let independent = BusinessQuota(
            mode: "key_limit",
            followsAccount: false,
            approximate: false,
            stepPercent: nil,
            usedPercentApprox: nil,
            remainingPercentApprox: nil,
            currency: "CNY",
            limitRMB: "100.0000",
            usedRMB: "14.3610",
            remainingRMB: "85.6390",
            exhausted: false,
            display: "RMB 85.6390 remaining"
        )
        XCTAssertEqual(independent.statusDisplay, "Key 独立额度，剩余 ¥85.6")
        XCTAssertEqual(independent.metricTitle, "可用余额")
        XCTAssertEqual(independent.metricValue, "¥85.6")
        XCTAssertEqual(independent.modeDisplay, "独立限额")
        XCTAssertEqual(independent.connectionModeDisplay, "独立余额 API Key")
        XCTAssertEqual(independent.trayStatusText, "¥85.6")
        XCTAssertFalse(independent.trayStatusIsLow)

        let shared = BusinessQuota(
            mode: "shared_account",
            followsAccount: true,
            approximate: true,
            stepPercent: 10,
            usedPercentApprox: 20,
            remainingPercentApprox: 80,
            currency: nil,
            limitRMB: nil,
            usedRMB: nil,
            remainingRMB: nil,
            exhausted: false,
            display: "80% remaining"
        )
        XCTAssertEqual(shared.statusDisplay, "跟随主余额，剩余约 80%")
        XCTAssertEqual(shared.metricTitle, "剩余比例")
        XCTAssertEqual(shared.metricValue, "约 80%")
        XCTAssertEqual(shared.modeDisplay, "跟随主余额")
        XCTAssertEqual(shared.connectionModeDisplay, "跟随主余额 API Key")
        XCTAssertEqual(shared.trayStatusText, "80%")
        XCTAssertFalse(shared.trayStatusIsLow)

        let lowShared = BusinessQuota(
            mode: "shared_account",
            followsAccount: true,
            approximate: true,
            stepPercent: 5,
            usedPercentApprox: 71,
            remainingPercentApprox: 29,
            currency: nil,
            limitRMB: nil,
            usedRMB: nil,
            remainingRMB: nil,
            exhausted: false,
            display: "29% remaining"
        )
        XCTAssertEqual(lowShared.trayStatusText, "29%")
        XCTAssertTrue(lowShared.trayStatusIsLow)
    }

    @MainActor
    func testAuthenticationInfoContainsKeyOnceAndEverySupportedEndpoint() {
        let key = "fixture-secret-key"
        let value = YConnectStore.authenticationInfo(apiKey: key)

        XCTAssertEqual(value.components(separatedBy: key).count - 1, 1)
        XCTAssertTrue(value.contains("YConnect · YakCool 接入信息"))
        XCTAssertTrue(value.contains("由 YConnect 生成并复制"))
        XCTAssertTrue(value.contains("选择下面任一兼容协议接入"))
        XCTAssertTrue(value.contains("请只分享给可信的人"))
        for endpoint in YConnectStore.accessEndpoints {
            XCTAssertTrue(value.contains("\(endpoint.name): \(endpoint.url)"))
        }
        XCTAssertTrue(value.contains("Authorization: Bearer"))
        XCTAssertTrue(value.contains("x-api-key"))
    }

    @MainActor
    func testAuthenticationInfoIncludesSelectedModelWhenSharingFromWidget() {
        let value = YConnectStore.authenticationInfo(
            apiKey: "fixture-secret-key",
            modelID: "gpt-5-codex"
        )

        XCTAssertTrue(value.contains("所选模型\ngpt-5-codex"))
        XCTAssertEqual(value.components(separatedBy: "gpt-5-codex").count - 1, 1)
    }

    @MainActor
    func testBusinessKeySignInPersistsOnlyAfterBothEndpointsSucceed() async throws {
        let context = try makeContext()
        defer { context.remove() }
        let transport = StoreFlowTransport()
        let vault = MemoryCredentialVault()
        let store = makeStore(context: context, transport: transport, vault: vault)

        await store.signIn(apiKey: "  fake-business-key-for-store-tests  ")

        XCTAssertEqual(store.phase, .apiKey)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.businessKeyInfo?.key.label, "Fixture Business Key")
        XCTAssertEqual(store.userDisplayName, "Fixture Business Key")
        XCTAssertEqual(store.businessKeyModels.map(\.id), ["anthropic-only", "chat-primary", "chat-secondary"])
        XCTAssertEqual(store.selectedModelID, "chat-primary")
        XCTAssertEqual(store.statusSummary, "跟随主余额，剩余约 80%")
        XCTAssertEqual(
            try CredentialRepository(vault: vault).loadAPIKey(),
            "fake-business-key-for-store-tests"
        )
        XCTAssertEqual(try CredentialRepository(vault: vault).loadWebCookies(), [])

        let keyRequests = transport.requestSnapshot.filter {
            $0.path == "/api/key/info" || $0.path == "/api/key/models"
        }
        XCTAssertEqual(keyRequests.count, 2)
        XCTAssertTrue(keyRequests.allSatisfy {
            $0.authorization == "Bearer fake-business-key-for-store-tests"
                && $0.cookie == nil
        })
    }

    @MainActor
    func testRejectedBusinessKeyDoesNotPersistOrAuthenticate() async throws {
        let context = try makeContext()
        defer { context.remove() }
        let transport = StoreFlowTransport(rejectBusinessKey: true)
        let vault = MemoryCredentialVault()
        let store = makeStore(context: context, transport: transport, vault: vault)

        await store.signIn(apiKey: "fake-rejected-business-key")

        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.errorMessage, "The fixture API Key was rejected")
        XCTAssertNil(try CredentialRepository(vault: vault).loadAPIKey())
        XCTAssertEqual(try CredentialRepository(vault: vault).loadWebCookies(), [])
    }

    @MainActor
    func testPublicAccountLoginRefreshCreateDeleteAndRedeemFlow() async throws {
        let context = try makeContext()
        defer { context.remove() }
        let transport = StoreFlowTransport()
        let vault = MemoryCredentialVault()
        let store = makeStore(context: context, transport: transport, vault: vault)
        let cookie = try TestFixture.cookie(value: "fake-public-session-for-store-tests")

        try await store.completeAccountLogin(cookies: [cookie])

        XCTAssertEqual(store.phase, .account)
        XCTAssertEqual(store.dashboard?.user.displayName, "Fixture Account")
        XCTAssertEqual(store.account?.publicUUID, "fixture-public-user")
        XCTAssertEqual(store.accountKeys.map(\.id), [101])
        XCTAssertEqual(store.accountModels.map(\.modelID), ["catalog-model"])
        XCTAssertEqual(store.selectedAccountKey?.id, 101)
        XCTAssertEqual(store.businessKeyModels.map(\.id), ["anthropic-only", "chat-primary", "chat-secondary"])
        XCTAssertEqual(store.modelDiscoveryModels.map(\.id), ["anthropic-only", "chat-primary", "chat-secondary"])
        XCTAssertEqual(store.selectedModelID, "chat-primary")
        XCTAssertEqual(try CredentialRepository(vault: vault).loadWebCookies(), [cookie])
        XCTAssertNil(try CredentialRepository(vault: vault).loadAPIKey())

        let firstRefreshAt = try XCTUnwrap(store.lastRefreshAt)
        await store.refresh()
        XCTAssertEqual(store.operationMessage, "信息已刷新")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.lastRefreshAt), firstRefreshAt)
        XCTAssertEqual(
            transport.requestSnapshot.filter { $0.path == "/api/user/dashboard" }.count,
            2
        )

        let didCreate = await store.createAPIKey(label: "OpenCode Test")
        XCTAssertTrue(didCreate)
        XCTAssertEqual(store.accountKeys.map(\.id), [101, 202])
        XCTAssertEqual(store.selectedAccountKeyID, 202)
        XCTAssertEqual(store.selectedAccountKey?.apiKey, "fake-account-key-created")

        let created = try XCTUnwrap(store.accountKeys.first(where: { $0.id == 202 }))
        let didDelete = await store.deleteAPIKey(created)
        XCTAssertTrue(didDelete)
        XCTAssertEqual(store.accountKeys.map(\.id), [101])
        XCTAssertEqual(store.selectedAccountKey?.id, 101)

        let didRedeem = await store.redeem(code: " fake-code-1234 ")
        XCTAssertTrue(didRedeem)
        XCTAssertEqual(store.operationMessage, "兑换成功，到账 ¥12.50")
        XCTAssertEqual(transport.createdLabels, ["OpenCode Test"])
        XCTAssertEqual(transport.deletedKeyIDs, [202])
        XCTAssertEqual(transport.redemptionCodes, ["FAKE-CODE-1234"])

        let accountRequests = transport.requestSnapshot.filter {
            $0.path.hasPrefix("/api/auth/") || $0.path.hasPrefix("/api/user/")
        }
        XCTAssertFalse(accountRequests.isEmpty)
        XCTAssertTrue(accountRequests.allSatisfy {
            $0.cookie == "yakcool_user_session=fake-public-session-for-store-tests"
                && $0.authorization == nil
        })
    }

    @MainActor
    func testAccountModelDiscoveryFallsBackToPublishedCatalogWhenKeyQueryIsEmpty() async throws {
        let context = try makeContext()
        defer { context.remove() }
        let transport = StoreFlowTransport(emptyBusinessModels: true)
        let store = makeStore(context: context, transport: transport, vault: MemoryCredentialVault())
        let cookie = try TestFixture.cookie(value: "fake-public-session-for-model-fallback")

        try await store.completeAccountLogin(cookies: [cookie])

        XCTAssertTrue(store.businessKeyModels.isEmpty)
        XCTAssertEqual(store.modelDiscoveryModels.map(\.id), ["catalog-model"])
        XCTAssertEqual(store.modelDiscoveryModels.first?.name, "Catalog Model")
        store.recordAccessModelUse("catalog-model")
        XCTAssertEqual(store.recentAccessModelIDs.first, "catalog-model")
    }

    @MainActor
    func testApplyOpenCodeFallsBackToFirstCompatibleModelAndWritesOnlyTemporaryFiles() async throws {
        let context = try makeContext()
        defer { context.remove() }
        let transport = StoreFlowTransport()
        let vault = MemoryCredentialVault()
        let store = makeStore(context: context, transport: transport, vault: vault)

        await store.signIn(apiKey: "fake-opencode-business-key")
        XCTAssertEqual(store.phase, .apiKey)
        store.selectedModelID = "anthropic-only"

        await store.applyOpenCodeConfiguration()

        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.selectedModelID, "chat-primary")
        XCTAssertEqual(store.operationMessage, "已将 OpenCode 切换到 YakCool / chat-primary")

        let configData = try Data(contentsOf: context.configurationURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configData) as? [String: Any]
        )
        XCTAssertEqual(root["model"] as? String, "yakcool/chat-primary")
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        let provider = try XCTUnwrap(providers["yakcool"] as? [String: Any])
        let models = try XCTUnwrap(provider["models"] as? [String: Any])
        XCTAssertEqual(Set(models.keys), ["chat-primary", "chat-secondary"])
        XCTAssertNil(models["anthropic-only"])

        let options = try XCTUnwrap(provider["options"] as? [String: Any])
        let secretReference = try XCTUnwrap(options["apiKey"] as? String)
        XCTAssertTrue(secretReference.hasPrefix("{file:"))
        XCTAssertFalse(String(data: configData, encoding: .utf8)?.contains("fake-opencode-business-key") == true)

        let configurator = context.configurator
        XCTAssertEqual(
            try Data(contentsOf: configurator.secretURL),
            Data("fake-opencode-business-key".utf8)
        )
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: configurator.secretURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    @MainActor
    private func makeStore(
        context: TemporaryStoreContext,
        transport: StoreFlowTransport,
        vault: MemoryCredentialVault
    ) -> YConnectStore {
        YConnectStore(
            environment: context.environment,
            api: YakCoolAPI(origin: origin, transport: transport),
            credentialVault: vault,
            openCodeConfigurator: context.configurator,
            preview: true
        )
    }

    private func makeContext() throws -> TemporaryStoreContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectStoreTests-\(UUID().uuidString)", isDirectory: true)
        let configurationURL = root
            .appendingPathComponent("home/.config/opencode/opencode.json", isDirectory: false)
        let supportURL = root
            .appendingPathComponent("home/Library/Application Support/YConnect", isDirectory: true)
        let environment = AppEnvironment(
            displayName: "YConnect Store Tests",
            keychainService: "io.yaklang.yconnect.store-tests",
            applicationSupportDirectory: supportURL,
            openCodeConfigurationURL: configurationURL,
            isDevelopment: true
        )
        return TemporaryStoreContext(
            root: root,
            environment: environment,
            configurationURL: configurationURL,
            configurator: OpenCodeConfigurator(
                configurationURL: configurationURL,
                applicationSupportDirectory: supportURL
            )
        )
    }
}

private struct TemporaryStoreContext {
    let root: URL
    let environment: AppEnvironment
    let configurationURL: URL
    let configurator: OpenCodeConfigurator

    func remove() {
        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class StoreFlowTransport: HTTPTransport {
    struct CapturedRequest: Equatable {
        let method: String
        let path: String
        let authorization: String?
        let cookie: String?
        let body: Data?
    }

    private let lock = NSLock()
    private let rejectBusinessKey: Bool
    private let emptyBusinessModels: Bool
    private var requests: [CapturedRequest] = []
    private var keyIDs: [Int64] = [101]
    private var mutableCreatedLabels: [String] = []
    private var mutableDeletedKeyIDs: [Int64] = []
    private var mutableRedemptionCodes: [String] = []

    init(rejectBusinessKey: Bool = false, emptyBusinessModels: Bool = false) {
        self.rejectBusinessKey = rejectBusinessKey
        self.emptyBusinessModels = emptyBusinessModels
    }

    var requestSnapshot: [CapturedRequest] { locked { requests } }
    var createdLabels: [String] { locked { mutableCreatedLabels } }
    var deletedKeyIDs: [Int64] { locked { mutableDeletedKeyIDs } }
    var redemptionCodes: [String] { locked { mutableRedemptionCodes } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try locked {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            requests.append(CapturedRequest(
                method: method,
                path: path,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                cookie: request.value(forHTTPHeaderField: "Cookie"),
                body: request.httpBody
            ))

            if path == "/api/key/info" {
                if rejectBusinessKey {
                    return response(
                        request,
                        status: 401,
                        object: [
                            "error": "fixture_unauthorized",
                            "message": "The fixture API Key was rejected",
                        ]
                    )
                }
                return response(request, object: businessKeyInfo)
            }
            if path == "/api/key/models" {
                return response(request, object: businessModels)
            }
            if path == "/api/auth/me" {
                return response(request, object: [
                    "user": user,
                    "staff_session": false,
                ])
            }
            if path == "/api/user/dashboard" {
                return response(request, object: dashboard)
            }
            if path == "/api/user/account" {
                return response(request, object: account)
            }
            if path == "/api/user/models" {
                return response(request, object: ["models": accountModels])
            }
            if path == "/api/user/api-keys", method == "GET" {
                return response(request, object: [
                    "keys": keyIDs.map(keyRecord),
                    "sync_status": "synced",
                    "api_key_limit": 20,
                ])
            }
            if path == "/api/user/api-keys", method == "POST" {
                let body = try bodyObject(request)
                let label = body["label"] as? String ?? ""
                mutableCreatedLabels.append(label)
                if !keyIDs.contains(202) { keyIDs.append(202) }
                return response(request, object: ["key": keyRecord(202)])
            }
            if path.hasPrefix("/api/user/api-keys/"), method == "DELETE" {
                let id = Int64(path.split(separator: "/").last ?? "") ?? 0
                mutableDeletedKeyIDs.append(id)
                keyIDs.removeAll(where: { $0 == id })
                return response(request, object: [
                    "status": "deleted",
                    "message": "deleted",
                ])
            }
            if path == "/api/user/redeem", method == "POST" {
                let body = try bodyObject(request)
                mutableRedemptionCodes.append(body["code"] as? String ?? "")
                return response(request, object: [
                    "status": "applied",
                    "message": "applied",
                    "amount_cents": 1250,
                ])
            }

            return response(
                request,
                status: 404,
                object: ["error": "fixture_not_found", "message": "No fixture route for \(method) \(path)"]
            )
        }
    }

    private var user: [String: Any] {
        [
            "id": 7,
            "public_uuid": "fixture-public-user",
            "display_name": "Fixture Account",
            "avatar_url": "",
            "is_enterprise": false,
            "enterprise_name": NSNull(),
        ]
    }

    private var dashboard: [String: Any] {
        [
            "user": user,
            "ai_service_credit": [
                "status": "synced",
                "token_limit": 1_000_000,
                "token_used": 250_000,
                "token_remaining": 750_000,
                "token_limit_enable": true,
                "weighted_tokens_per_rmb": 10_000,
            ],
            "api_key_count": keyIDs.count,
            "api_key_limit": 20,
            "gateway_url": "https://aibalance.yaklang.com",
            "access_methods": [],
            "account_summary": NSNull(),
        ]
    }

    private var account: [String: Any] {
        [
            "id": 7,
            "public_uuid": "fixture-public-user",
            "display_name": "Fixture Account",
            "avatar_url": "",
            "login_method": "wechat",
            "wechat_bound": true,
            "created_at": 1_700_000_000,
            "last_login_at": 1_700_000_100,
        ]
    }

    private var accountModels: [[String: Any]] {
        [[
            "id": 1,
            "model_id": "catalog-model",
            "display_name": "Catalog Model",
            "provider": "Fixture",
            "summary": "fixture only",
            "capability_tags": ["chat"],
            "context_window": 32_000,
            "recommended_scenarios": "tests",
        ]]
    }

    private var businessKeyInfo: [String: Any] {
        [
            "schema_version": 1,
            "key": [
                "label": "Fixture Business Key",
                "last4": "TEST",
                "status": "active",
            ],
            "quota": [
                "mode": "account",
                "follows_account": true,
                "approximate": true,
                "remaining_percent_approx": 80,
                "display": "80% remaining",
            ],
            "queried_at": "2026-09-03T00:00:00Z",
        ]
    }

    private var businessModels: [String: Any] {
        [
            "schema_version": 1,
            "object": "list",
            "data": emptyBusinessModels ? [] : [
                ["id": "anthropic-only", "name": "Anthropic Only", "protocols": ["anthropic_messages"]],
                ["id": "chat-primary", "name": "Chat Primary", "protocols": ["chat_completions", "responses"]],
                ["id": "chat-secondary", "name": "Chat Secondary", "protocols": ["chat_completions"]],
            ],
            "queried_at": "2026-09-03T00:00:00Z",
        ]
    }

    private func keyRecord(_ id: Int64) -> [String: Any] {
        let created = id == 202
        return [
            "id": id,
            "label": created ? "OpenCode Test" : "Primary Test Key",
            "api_key": created ? "fake-account-key-created" : "fake-account-key-alpha",
            "last4": created ? "MAKE" : "TEST",
            "allowed_models": [],
            "token_used": 0,
            "token_limit": 0,
            "token_limit_enable": false,
            "usage_count": 0,
            "success_count": 0,
            "failure_count": 0,
            "active": true,
            "status": "enabled",
            "created_at": "2026-09-03T00:00:00Z",
            "last_used_time": "",
        ]
    }

    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw YConnectError.invalidResponse
        }
        return object
    }

    private func response(
        _ request: URLRequest,
        status: Int = 200,
        object: Any
    ) -> (Data, URLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (data, TestFixture.httpResponse(for: request, status: status))
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
