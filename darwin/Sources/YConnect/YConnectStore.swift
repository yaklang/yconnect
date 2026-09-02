import AppKit
import Foundation

enum AuthenticationPhase: Equatable {
    case signedOut
    case restoring
    case account
    case apiKey

    var isAuthenticated: Bool { self == .account || self == .apiKey }
}

@MainActor
final class YConnectStore: ObservableObject {
    @Published private(set) var phase: AuthenticationPhase = .signedOut
    @Published var preferredAuthenticationMode: AuthenticationMode = .account
    @Published private(set) var dashboard: DashboardResponse?
    @Published private(set) var account: UserAccountResponse?
    @Published private(set) var accountKeys: [APIKeyRecord] = []
    @Published private(set) var accountModels: [ModelRecord] = []
    @Published private(set) var businessKeyInfo: BusinessKeyInfoResponse?
    @Published private(set) var businessKeyModels: [BusinessKeyModel] = []
    @Published var selectedAccountKeyID: Int64? {
        didSet { if !isPreview { YConnectPreferences.selectedAccountKeyID = selectedAccountKeyID } }
    }
    @Published var selectedModelID: String? {
        didSet { if !isPreview { YConnectPreferences.selectedModelID = selectedModelID } }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var operationMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var serviceChecks: [ServiceCheck] = []
    @Published private(set) var openCodeMessage = "尚未写入 OpenCode 配置"
    @Published private(set) var lastRefreshAt: Date?

    let environment: AppEnvironment
    private let api: YakCoolAPI
    private let credentials: CredentialRepository
    private let openCode: OpenCodeConfigurator
    private let isPreview: Bool
    private var webCookies: [StoredWebCookie] = []
    private var standaloneAPIKey: String?

    init(
        environment: AppEnvironment = .current(),
        api: YakCoolAPI = YakCoolAPI(),
        credentialVault: CredentialVault? = nil,
        openCodeConfigurator: OpenCodeConfigurator? = nil,
        preview: Bool = false
    ) {
        self.environment = environment
        self.api = api
        let vault = credentialVault ?? KeychainVault(service: environment.keychainService)
        credentials = CredentialRepository(vault: vault)
        openCode = openCodeConfigurator ?? OpenCodeConfigurator(
            configurationURL: environment.openCodeConfigurationURL,
            applicationSupportDirectory: environment.applicationSupportDirectory
        )
        isPreview = preview
        selectedAccountKeyID = preview ? nil : YConnectPreferences.selectedAccountKeyID
        selectedModelID = preview ? nil : YConnectPreferences.selectedModelID
    }

    var isAuthenticated: Bool { phase.isAuthenticated }
    var isAccountMode: Bool { phase == .account }

    var userDisplayName: String {
        dashboard?.user.displayName ?? account?.displayName ?? businessKeyInfo?.key.label ?? "未登录"
    }

    var statusSummary: String {
        switch phase {
        case .signedOut: return "连接你的 YakCool 账户"
        case .restoring: return "正在恢复安全会话…"
        case .account:
            guard let credit = dashboard?.aiServiceCredit else { return "账户已连接" }
            if credit.status != "ok" && credit.status != "synced" { return "额度状态：\(credit.status)" }
            return credit.remainingRMB.map { "余额约 ¥\($0)" } ?? "账户已连接"
        case .apiKey:
            return businessKeyInfo?.quota.display ?? "API Key 已连接"
        }
    }

    var selectedAccountKey: APIKeyRecord? {
        guard let selectedAccountKeyID else { return accountKeys.first(where: \.active) ?? accountKeys.first }
        return accountKeys.first(where: { $0.id == selectedAccountKeyID })
    }

    var selectedModelName: String {
        if let selectedModelID,
           let model = accountModels.first(where: { $0.modelID == selectedModelID }) {
            return model.displayName
        }
        if let selectedModelID,
           let model = businessKeyModels.first(where: { $0.id == selectedModelID }) {
            return model.name
        }
        return selectedModelID ?? "尚未选择"
    }

    func restoreSession() async {
        guard !isPreview else { return }
        phase = .restoring
        clearVisibleData()
        do {
            let cookies = try credentials.loadWebCookies()
            if !cookies.isEmpty {
                _ = try await api.verifyWebCookies(cookies)
                webCookies = cookies
                phase = .account
                preferredAuthenticationMode = .account
                try await refreshAccount()
                return
            }
            if let key = try credentials.loadAPIKey() {
                try await loadBusinessKey(key, persist: false)
                return
            }
            phase = .signedOut
        } catch {
            try? credentials.deleteWebCookies()
            try? credentials.deleteAPIKey()
            webCookies = []
            standaloneAPIKey = nil
            phase = .signedOut
            errorMessage = "已保存的登录信息失效，请重新登录。\n\(error.localizedDescription)"
        }
    }

    func completeAccountLogin(cookies: [StoredWebCookie]) async throws {
        guard !cookies.isEmpty else { throw YConnectError.invalidCredential("没有读取到 YakCool 用户会话") }
        isBusy = true
        defer { isBusy = false }
        _ = try await api.verifyWebCookies(cookies)
        try credentials.saveWebCookies(cookies)
        try? credentials.deleteAPIKey()
        webCookies = cookies
        standaloneAPIKey = nil
        phase = .account
        preferredAuthenticationMode = .account
        try await refreshAccount()
        operationMessage = "YakCool 账户已安全连接"
    }

    func signIn(apiKey rawValue: String) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let key = try YakCoolAPI.normalizedAPIKey(rawValue)
            try await loadBusinessKey(key, persist: true)
            operationMessage = "API Key 验证成功"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            switch phase {
            case .account: try await refreshAccount()
            case .apiKey:
                guard let standaloneAPIKey else { throw YConnectError.invalidCredential("API Key 不存在") }
                try await loadBusinessKey(standaloneAPIKey, persist: false)
            case .signedOut, .restoring: return
            }
            operationMessage = "信息已刷新"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        if phase == .account, !webCookies.isEmpty { _ = try? await api.logout(cookies: webCookies) }
        try? credentials.deleteWebCookies()
        try? credentials.deleteAPIKey()
        webCookies = []
        standaloneAPIKey = nil
        clearVisibleData()
        phase = .signedOut
        operationMessage = "已退出；OpenCode 配置不会被自动改动"
    }

    func createAPIKey(label: String) async -> Bool {
        guard phase == .account else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await api.createAPIKey(label: label, cookies: webCookies)
            try await refreshAccount()
            selectedAccountKeyID = response.key.id
            operationMessage = "API Key 已创建；完整密钥仅在本机内存中展示"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAPIKey(_ key: APIKeyRecord) async -> Bool {
        guard phase == .account else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await api.deleteAPIKey(id: key.id, cookies: webCookies)
            if selectedAccountKeyID == key.id { selectedAccountKeyID = nil }
            try await refreshAccount()
            operationMessage = "“\(key.label)”已删除"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func redeem(code: String) async -> Bool {
        guard phase == .account else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try await api.redeem(code: code, cookies: webCookies)
            try await refreshAccount()
            switch result.status {
            case "applied":
                operationMessage = result.amountCents.map { "兑换成功，到账 ¥\(String(format: "%.2f", Double($0) / 100))" } ?? "兑换成功"
            case "pending":
                operationMessage = result.message ?? "兑换正在处理，请稍后使用同一兑换码重试"
            default:
                operationMessage = result.message ?? "兑换状态：\(result.status)"
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func copyCurrentAPIKey() -> Bool {
        guard let value = currentAPIKeyValue else {
            errorMessage = "当前没有可复制的 API Key"
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        operationMessage = "API Key 已复制到剪贴板"
        return true
    }

    func applyOpenCodeConfiguration() async {
        guard let key = currentAPIKeyValue else {
            errorMessage = "请先选择可用的 API Key"
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await api.keyModels(apiKey: key)
            let compatible = response.data.filter { $0.protocols.contains("chat_completions") }
            guard !compatible.isEmpty else {
                throw YConnectError.unsupported("当前 API Key 没有兼容 OpenCode 的 Chat Completions 模型")
            }
            businessKeyModels = response.data
            let modelID = selectedModelID.flatMap { selected in
                compatible.contains(where: { $0.id == selected }) ? selected : nil
            } ?? compatible[0].id
            selectedModelID = modelID
            let result = try openCode.apply(
                apiKey: key,
                models: compatible.map { OpenCodeModelOption(id: $0.id, name: $0.name) },
                selectedModelID: modelID
            )
            openCodeMessage = result.message
            operationMessage = result.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreOpenCodeConfiguration() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try openCode.restoreLatest()
            openCodeMessage = result.message
            operationMessage = result.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runServiceChecks(includeLiveCompletion: Bool) async {
        guard let key = currentAPIKeyValue else {
            errorMessage = "请先登录并选择 API Key"
            return
        }
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        serviceChecks = [
            ServiceCheck(id: "health", title: "YakCool 服务", state: .pending),
            ServiceCheck(id: "auth", title: "API Key 权限", state: .pending),
            ServiceCheck(id: "models", title: "可用模型", state: .pending),
        ]
        if includeLiveCompletion {
            serviceChecks.append(ServiceCheck(id: "completion", title: "最小模型调用", state: .pending))
        }
        defer { isBusy = false }

        await runCheck(id: "health") {
            let health = try await self.api.health()
            return health.status
        }

        await runCheck(id: "auth") {
            let info = try await self.api.keyInfo(apiKey: key)
            return "\(info.key.label) · \(info.key.status)"
        }

        var compatibleModels: [BusinessKeyModel] = []
        await runCheck(id: "models") {
            let result = try await self.api.keyModels(apiKey: key)
            compatibleModels = result.data.filter { $0.protocols.contains("chat_completions") }
            guard !result.data.isEmpty else { throw YConnectError.unsupported("当前 Key 没有可用模型") }
            return "\(result.data.count) 个模型，\(compatibleModels.count) 个支持 Chat Completions"
        }

        if includeLiveCompletion {
            await runCheck(id: "completion") {
                guard let model = compatibleModels.first(where: { $0.id == self.selectedModelID }) ?? compatibleModels.first else {
                    throw YConnectError.unsupported("没有可用于最小调用的 Chat Completions 模型")
                }
                let reply = try await self.api.completionProbe(
                    gateway: YakCoolAPI.productionGateway,
                    apiKey: key,
                    model: model.id
                )
                return reply.isEmpty ? "调用成功（空文本响应）" : "调用成功：\(String(reply.prefix(40)))"
            }
        }
        operationMessage = serviceChecks.contains(where: {
            if case .failed = $0.state { return true }
            return false
        }) ? "部分检查未通过" : "全部检查通过"
    }

    private func refreshAccount() async throws {
        guard !webCookies.isEmpty else { throw YConnectError.invalidCredential("账户会话不存在") }
        async let dashboardRequest = api.dashboard(cookies: webCookies)
        async let accountRequest = api.account(cookies: webCookies)
        async let keysRequest = api.apiKeys(cookies: webCookies)
        async let modelsRequest = api.models(cookies: webCookies)
        let (newDashboard, newAccount, keyResponse, modelResponse) = try await (
            dashboardRequest, accountRequest, keysRequest, modelsRequest
        )
        dashboard = newDashboard
        account = newAccount
        accountKeys = keyResponse.keys
        accountModels = modelResponse.models
        if selectedAccountKey == nil { selectedAccountKeyID = keyResponse.keys.first(where: \.active)?.id ?? keyResponse.keys.first?.id }
        if selectedModelID == nil || !modelResponse.models.contains(where: { $0.modelID == selectedModelID }) {
            selectedModelID = modelResponse.models.first?.modelID
        }
        lastRefreshAt = Date()
    }

    private func loadBusinessKey(_ key: String, persist: Bool) async throws {
        async let infoRequest = api.keyInfo(apiKey: key)
        async let modelsRequest = api.keyModels(apiKey: key)
        let (info, models) = try await (infoRequest, modelsRequest)
        if persist {
            try credentials.saveAPIKey(key)
            try? credentials.deleteWebCookies()
        }
        webCookies = []
        standaloneAPIKey = key
        dashboard = nil
        account = nil
        accountKeys = []
        accountModels = []
        businessKeyInfo = info
        businessKeyModels = models.data
        phase = .apiKey
        preferredAuthenticationMode = .apiKey
        if selectedModelID == nil || !models.data.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = models.data.first(where: { $0.protocols.contains("chat_completions") })?.id ?? models.data.first?.id
        }
        lastRefreshAt = Date()
    }

    private var currentAPIKeyValue: String? {
        switch phase {
        case .account: return selectedAccountKey?.apiKey.nilIfEmpty
        case .apiKey: return standaloneAPIKey
        case .signedOut, .restoring: return nil
        }
    }

    private func runCheck(id: String, operation: () async throws -> String) async {
        updateCheck(id: id, state: .running)
        do { updateCheck(id: id, state: .passed(try await operation())) }
        catch { updateCheck(id: id, state: .failed(error.localizedDescription)) }
    }

    private func updateCheck(id: String, state: ServiceCheck.State) {
        guard let index = serviceChecks.firstIndex(where: { $0.id == id }) else { return }
        serviceChecks[index].state = state
    }

    private func clearVisibleData() {
        dashboard = nil
        account = nil
        accountKeys = []
        accountModels = []
        businessKeyInfo = nil
        businessKeyModels = []
        serviceChecks = []
        lastRefreshAt = nil
    }

    static func preview(environment: AppEnvironment) -> YConnectStore {
        let store = YConnectStore(
            environment: environment,
            credentialVault: MemoryCredentialVault(),
            preview: true
        )
        store.phase = .account
        store.dashboard = DashboardResponse(
            user: YakCoolUser(
                id: 1001,
                publicUUID: "preview-user",
                displayName: "YakCool 用户",
                avatarURL: "",
                isEnterprise: false,
                enterpriseName: nil
            ),
            aiServiceCredit: CreditSummary(
                status: "ok", uid: "preview", tokenLimit: 800_000_000,
                tokenUsed: 243_000_000, tokenRemaining: 557_000_000,
                tokenLimitEnabled: true, tokenLimitRMB: "80.0000",
                tokenUsedRMB: "24.3000", weightedTokensPerRMB: 10_000_000, error: nil
            ),
            apiKeyCount: 2,
            apiKeyLimit: 20,
            gatewayURL: "https://aibalance.yaklang.com",
            accessMethods: [],
            accountSummary: AccountSummary(
                keyCount: 2, activeKeyCount: 2, inactiveKeyCount: 0, modelCount: 8,
                usageCount: 381, successCount: 374, failureCount: 7, successRate: 98.16,
                webSearchCount: 23, activeDays: 12, lastUsedTime: "刚刚", createdAt: "2026-08-01"
            )
        )
        store.accountKeys = [
            APIKeyRecord(
                id: 11, label: "OpenCode", apiKey: "preview-key-never-persisted", last4: "8A2F",
                allowedModels: [], tokenUsed: 0, tokenLimit: 0, tokenLimitEnabled: false,
                usageCount: 212, successCount: 210, failureCount: 2, active: true,
                status: "enabled", createdAt: "2026-08-10", lastUsedTime: "刚刚"
            ),
            APIKeyRecord(
                id: 12, label: "MacBook", apiKey: "preview-key-two", last4: "77C1",
                allowedModels: [], tokenUsed: 0, tokenLimit: 0, tokenLimitEnabled: false,
                usageCount: 169, successCount: 164, failureCount: 5, active: true,
                status: "enabled", createdAt: "2026-08-12", lastUsedTime: "2 小时前"
            ),
        ]
        store.accountModels = [
            ModelRecord(id: 1, modelID: "gpt-5", displayName: "GPT-5", provider: "OpenAI", summary: "", capabilityTags: [], contextWindow: 200_000, recommendedScenarios: ""),
            ModelRecord(id: 2, modelID: "claude-sonnet-4", displayName: "Claude Sonnet 4", provider: "Anthropic", summary: "", capabilityTags: [], contextWindow: 200_000, recommendedScenarios: ""),
        ]
        store.businessKeyModels = [
            BusinessKeyModel(id: "gpt-5", name: "GPT-5", protocols: ["chat_completions", "responses"]),
            BusinessKeyModel(id: "claude-sonnet-4", name: "Claude Sonnet 4", protocols: ["anthropic_messages"]),
        ]
        store.selectedAccountKeyID = 11
        store.selectedModelID = "gpt-5"
        store.lastRefreshAt = Date()
        store.openCodeMessage = environment.isDevelopment
            ? "开发预览使用隔离配置目录，不会修改真实 OpenCode 配置"
            : "将安全写入 \(environment.openCodeConfigurationURL.path)"
        return store
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
