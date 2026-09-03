import AppKit
import Foundation

enum AuthenticationPhase: Equatable {
    case signedOut
    case restoring
    case account
    case apiKey

    var isAuthenticated: Bool { self == .account || self == .apiKey }
}

struct YakCoolAccessEndpoint: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: String
}

@MainActor
final class YConnectStore: ObservableObject {
    static let accessEndpoints: [YakCoolAccessEndpoint] = [
        YakCoolAccessEndpoint(
            id: "openai-base",
            name: "OpenAI 兼容基址",
            url: "https://aibalance.yaklang.com/v1"
        ),
        YakCoolAccessEndpoint(
            id: "chat-completions",
            name: "Chat Completions",
            url: "https://aibalance.yaklang.com/v1/chat/completions"
        ),
        YakCoolAccessEndpoint(
            id: "responses",
            name: "Responses API",
            url: "https://aibalance.yaklang.com/v1/responses"
        ),
        YakCoolAccessEndpoint(
            id: "anthropic-base",
            name: "Anthropic 基址",
            url: "https://aibalance.yaklang.com"
        ),
        YakCoolAccessEndpoint(
            id: "anthropic-messages",
            name: "Anthropic Messages",
            url: "https://aibalance.yaklang.com/v1/messages"
        ),
    ]

    @Published private(set) var phase: AuthenticationPhase = .signedOut
    @Published var preferredAuthenticationMode: AuthenticationMode = .account
    @Published private(set) var dashboard: DashboardResponse?
    @Published private(set) var account: UserAccountResponse?
    @Published private(set) var accountKeys: [APIKeyRecord] = []
    @Published private(set) var accountModels: [ModelRecord] = []
    @Published private(set) var businessKeyInfo: BusinessKeyInfoResponse?
    @Published private(set) var businessKeyModels: [BusinessKeyModel] = []
    @Published var selectedAccountKeyID: Int64? {
        didSet {
            if !isPreview { YConnectPreferences.selectedAccountKeyID = selectedAccountKeyID }
            if oldValue != selectedAccountKeyID, phase == .account { businessKeyModels = [] }
        }
    }
    @Published var selectedClientID: ClientID {
        didSet {
            guard oldValue != selectedClientID else { return }
            if !isPreview { YConnectPreferences.selectedClientID = selectedClientID }
            selectedModelID = rememberedModelID(for: selectedClientID)
            selectCompatibleModelIfNeeded()
        }
    }
    @Published var selectedModelID: String? {
        didSet {
            rememberModelID(selectedModelID, for: selectedClientID)
        }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var operationMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var serviceChecks: [ServiceCheck] = []
    @Published private(set) var clientMessages: [ClientID: String] = [:]
    @Published private(set) var clientStatuses: [ClientID: ClientConfigurationStatus] = [:]
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var installedClientIDs: Set<ClientID>
    @Published private(set) var recentClientIDs: [ClientID]

    let environment: AppEnvironment
    private let api: YakCoolAPI
    private let credentials: CredentialRepository
    private let clients: ClientConfigurationRegistry
    private let installationDetector: ClientInstallationDetecting
    private let isPreview: Bool
    private var selectedModelIDsByClient: [ClientID: String] = [:]
    private var webCookies: [StoredWebCookie] = []
    private var standaloneAPIKey: String?

    init(
        environment: AppEnvironment = .current(),
        api: YakCoolAPI = YakCoolAPI(),
        credentialVault: CredentialVault? = nil,
        openCodeConfigurator: OpenCodeConfigurator? = nil,
        clientRegistry: ClientConfigurationRegistry? = nil,
        installationDetector: ClientInstallationDetecting? = nil,
        preview: Bool = false
    ) {
        self.environment = environment
        self.api = api
        let vault = credentialVault ?? KeychainVault(service: environment.keychainService)
        credentials = CredentialRepository(vault: vault)
        isPreview = preview
        clients = clientRegistry ?? (try! DefaultClientConfigurationRegistry.make(
            environment: environment,
            openCodeConfigurator: openCodeConfigurator
        ))
        self.installationDetector = installationDetector
            ?? (preview ? StaticClientInstallationDetector() : DefaultClientInstallationDetector())
        let detectedClientIDs = self.installationDetector.installedClientIDs(from: clients.descriptors)
        installedClientIDs = detectedClientIDs
        recentClientIDs = preview ? [] : YConnectPreferences.recentClientIDs

        // Migrate the v0.1 OpenCode-only preference once, regardless of which
        // client happens to be selected when this Store starts.
        if !preview,
           YConnectPreferences.selectedModelID(for: .openCode) == nil,
           let legacyOpenCodeModel = YConnectPreferences.selectedModelID {
            YConnectPreferences.setSelectedModelID(legacyOpenCodeModel, for: .openCode)
        }
        let preferredClient = preview ? ClientID.openCode : YConnectPreferences.selectedClientID
        let firstInstalled = clients.descriptors.first(where: { detectedClientIDs.contains($0.id) })?.id
        selectedClientID = clients[preferredClient] != nil && detectedClientIDs.contains(preferredClient)
            ? preferredClient
            : (firstInstalled ?? clients.descriptors.first?.id ?? .openCode)
        selectedAccountKeyID = preview ? nil : YConnectPreferences.selectedAccountKeyID
        selectedModelID = preview
            ? nil
            : YConnectPreferences.selectedModelID(for: selectedClientID)
        if let selectedModelID {
            selectedModelIDsByClient[selectedClientID] = selectedModelID
        }
        for descriptor in clients.descriptors {
            clientMessages[descriptor.id] = environment.isDevelopment
                ? "开发预览使用隔离目录，不会修改真实 \(descriptor.name) 配置"
                : "尚未写入 \(descriptor.name) 配置"
        }
    }

    var isAuthenticated: Bool { phase.isAuthenticated }
    var isAccountMode: Bool { phase == .account }
    var hasTransientOperationMessage: Bool {
        guard let operationMessage else { return false }
        return operationMessage != "YakCool 账户已安全连接"
            && operationMessage != "API Key 验证成功"
    }
    var clientDescriptors: [ClientDescriptor] { clients.descriptors }
    var installedClientDescriptors: [ClientDescriptor] {
        let order = Dictionary(
            recentClientIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { min($0, $1) }
        )
        return clients.descriptors
            .filter { installedClientIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let left = order[lhs.id] ?? Int.max
                let right = order[rhs.id] ?? Int.max
                return left == right
                    ? descriptorIndex(lhs.id) < descriptorIndex(rhs.id)
                    : left < right
            }
    }
    var selectedClientDescriptor: ClientDescriptor {
        clients[selectedClientID]?.descriptor
            ?? ClientDescriptor(
                id: selectedClientID,
                name: selectedClientID.rawValue,
                shortName: selectedClientID.rawValue,
                symbol: "terminal",
                summary: "",
                supportedProtocols: [],
                configurationPath: "",
                restartNote: "",
                availability: .planned
            )
    }
    var selectedClientMessage: String {
        clientMessages[selectedClientID] ?? "尚未写入 \(selectedClientDescriptor.name) 配置"
    }
    var openCodeMessage: String { clientMessages[.openCode] ?? "尚未写入 OpenCode 配置" }

    func refreshInstalledClients() {
        installedClientIDs = installationDetector.installedClientIDs(from: clients.descriptors)
        recentClientIDs = recentClientIDs.filter(installedClientIDs.contains)
        if !isPreview { YConnectPreferences.recentClientIDs = recentClientIDs }
        if !installedClientIDs.contains(selectedClientID), let first = installedClientDescriptors.first {
            selectedClientID = first.id
        }
    }

    func selectClientForManagement(_ clientID: ClientID) {
        guard installedClientIDs.contains(clientID), clients[clientID] != nil else { return }
        selectedClientID = clientID
        markClientUsed(clientID)
    }

    var selectedClientCompatibleModels: [BusinessKeyModel] {
        guard let client = clients[selectedClientID] else { return [] }
        var seen: Set<String> = []
        return businessKeyModels.filter { model in
            guard !client.compatibleModels(from: [Self.clientModelOption(model)]).isEmpty else {
                return false
            }
            return seen.insert(model.id).inserted
        }
    }

    var userDisplayName: String {
        switch phase {
        case .account:
            return dashboard?.user.displayName ?? account?.displayName ?? "YakCool 用户"
        case .apiKey:
            // API Key sessions must only show the privacy-filtered identity
            // returned for that Key, never account data from another mode.
            return businessKeyInfo?.key.label ?? "API Key"
        case .signedOut, .restoring:
            return "未登录"
        }
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
            return businessKeyInfo?.quota.statusDisplay ?? "API Key 已连接"
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
            let invalidatesCredential = (error as? YConnectError)?.invalidatesStoredCredential ?? false
            if invalidatesCredential {
                try? credentials.deleteWebCookies()
                try? credentials.deleteAPIKey()
            }
            webCookies = []
            standaloneAPIKey = nil
            phase = .signedOut
            errorMessage = invalidatesCredential
                ? "已保存的登录信息失效，请重新登录。\n\(error.localizedDescription)"
                : "暂时无法恢复登录，已保留本地凭证。\n\(error.localizedDescription)"
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
        operationMessage = "已退出；本地客户端配置不会被自动改动"
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

    @discardableResult
    func copyAuthenticationInfo() -> Bool {
        guard let value = currentAPIKeyValue else {
            errorMessage = "当前没有可复制的接入信息"
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.authenticationInfo(apiKey: value), forType: .string)
        operationMessage = "接入信息已复制，可按需选择协议"
        return true
    }

    static func authenticationInfo(apiKey: String) -> String {
        let endpoints = accessEndpoints
            .map { "\($0.name): \($0.url)" }
            .joined(separator: "\n")
        return """
        YConnect · YakCool 接入信息
        由 YConnect 生成并复制。你可以根据自己的客户端和使用习惯，选择下面任一兼容协议接入。

        API Key
        \(apiKey)

        协议接入地址
        \(endpoints)

        请求头
        OpenAI 兼容协议 / Responses API: Authorization: Bearer
        Anthropic Messages: x-api-key

        安全提醒：API Key 可访问你的 YakCool 额度，请只分享给可信的人。
        """
    }

    func refreshConfigurationModels() async {
        guard !isPreview else {
            selectCompatibleModelIfNeeded()
            return
        }
        guard let key = currentAPIKeyValue, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let models = try await api.keyModels(apiKey: key).data
            guard currentAPIKeyValue == key else { return }
            businessKeyModels = Self.deduplicatedBusinessKeyModels(models)
            // The model catalog belongs to the credential, while compatibility
            // belongs to the client that is current when the response arrives.
            selectCompatibleModelIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applySelectedClientConfiguration() async {
        guard !isBusy else { return }
        guard let key = currentAPIKeyValue else {
            errorMessage = "请先选择可用的 API Key"
            return
        }
        let operationClientID = selectedClientID
        guard installedClientIDs.contains(operationClientID) else {
            errorMessage = "未检测到 \(selectedClientDescriptor.name)，无法应用配置"
            return
        }
        guard let client = clients[operationClientID] else {
            errorMessage = ClientConfigurationError.unsupportedClient(selectedClientDescriptor.name).localizedDescription
            return
        }
        let requestedModelID = rememberedModelID(for: operationClientID)
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await api.keyModels(apiKey: key)
            try Task.checkCancellation()
            guard currentAPIKeyValue == key else {
                throw YConnectError.invalidCredential("操作期间 API Key 已切换，请重试")
            }
            let normalizedModels = Self.deduplicatedBusinessKeyModels(response.data)
            let allOptions = normalizedModels.map(Self.clientModelOption)
            let compatible = client.compatibleModels(from: allOptions)
            guard !compatible.isEmpty else {
                let protocols = client.descriptor.supportedProtocols.map(\.title).joined(separator: " / ")
                throw ClientConfigurationError.noCompatibleModel(
                    "当前 API Key 没有兼容 \(client.descriptor.name) 的模型（需要 \(protocols)）"
                )
            }
            if selectedClientID == operationClientID {
                businessKeyModels = normalizedModels
            }
            let modelID = requestedModelID.flatMap { selected in
                compatible.contains(where: { $0.id == selected }) ? selected : nil
            } ?? compatible[0].id
            updateModelID(modelID, for: operationClientID)
            let result = try client.apply(ClientApplyRequest(
                apiKey: key,
                models: allOptions,
                selectedModelID: modelID
            ))
            clientMessages[operationClientID] = result.message
            operationMessage = result.message
            clientStatuses[operationClientID] = try? client.inspect()
            markClientUsed(operationClientID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreSelectedClientConfiguration() {
        guard !isBusy else { return }
        guard let client = clients[selectedClientID] else {
            errorMessage = ClientConfigurationError.unsupportedClient(selectedClientDescriptor.name).localizedDescription
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try client.restoreLatest()
            clientMessages[selectedClientID] = result.message
            operationMessage = result.message
            clientStatuses[selectedClientID] = try? client.inspect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Source-compatible entry points for scripts/tests from the first preview.
    func applyOpenCodeConfiguration() async {
        selectedClientID = .openCode
        await applySelectedClientConfiguration()
    }

    func restoreOpenCodeConfiguration() {
        selectedClientID = .openCode
        restoreSelectedClientConfiguration()
    }

    func runServiceChecks(includeLiveCompletion: Bool) async {
        guard let key = currentAPIKeyValue else {
            errorMessage = "请先登录并选择 API Key"
            return
        }
        guard !isBusy else { return }
        let operationClientID = selectedClientID
        guard let client = clients[operationClientID] else {
            errorMessage = ClientConfigurationError.unsupportedClient(selectedClientDescriptor.name).localizedDescription
            return
        }
        let descriptor = client.descriptor
        let requestedModelID = rememberedModelID(for: operationClientID)
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
            let models = Self.deduplicatedBusinessKeyModels(result.data)
            guard !models.isEmpty else { throw YConnectError.unsupported("当前 Key 没有可用模型") }
            let compatibleIDs = Set(client.compatibleModels(
                from: models.map(Self.clientModelOption)
            ).map(\.id))
            compatibleModels = models.filter { compatibleIDs.contains($0.id) }
            guard !compatibleModels.isEmpty else {
                let protocols = descriptor.supportedProtocols.map(\.title).joined(separator: " / ")
                throw YConnectError.unsupported(
                    "当前 Key 没有兼容 \(descriptor.name) 的模型（需要 \(protocols)）"
                )
            }
            return "\(models.count) 个模型，\(compatibleModels.count) 个兼容 \(descriptor.name)"
        }

        if includeLiveCompletion {
            await runCheck(id: "completion") {
                guard let model = compatibleModels.first(where: { $0.id == requestedModelID })
                    ?? compatibleModels.first else {
                    throw YConnectError.unsupported("没有可用于 \(descriptor.name) 最小调用的兼容模型")
                }
                let advertisedProtocols = Set(model.protocols.map { AIProtocol(rawValue: $0) })
                guard let wireProtocol = descriptor.supportedProtocols.first(where: {
                    advertisedProtocols.contains($0)
                }) else {
                    throw YConnectError.unsupported("模型与 \(descriptor.name) 没有兼容的调用协议")
                }
                let result = try await self.api.modelProbe(
                    gateway: YakCoolAPI.productionGateway,
                    apiKey: key,
                    model: model.id,
                    wireProtocol: wireProtocol
                )
                return result.text.isEmpty
                    ? "\(result.protocolName) · 调用成功（空文本响应）"
                    : "\(result.protocolName) · 调用成功：\(String(result.text.prefix(40)))"
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
        // The account catalog does not include wire-protocol capability data.
        // It must never overwrite a client-specific configuration selection;
        // `/api/key/models` is the authority for that decision.
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
        businessKeyModels = Self.deduplicatedBusinessKeyModels(models.data)
        phase = .apiKey
        preferredAuthenticationMode = .apiKey
        selectCompatibleModelIfNeeded()
        lastRefreshAt = Date()
    }

    private var currentAPIKeyValue: String? {
        switch phase {
        case .account: return selectedAccountKey?.apiKey.nilIfEmpty
        case .apiKey: return standaloneAPIKey
        case .signedOut, .restoring: return nil
        }
    }

    private func rememberedModelID(for clientID: ClientID) -> String? {
        if let remembered = selectedModelIDsByClient[clientID] { return remembered }
        guard !isPreview else { return nil }
        return YConnectPreferences.selectedModelID(for: clientID)
    }

    private func rememberModelID(_ modelID: String?, for clientID: ClientID) {
        if let modelID {
            selectedModelIDsByClient[clientID] = modelID
        } else {
            selectedModelIDsByClient.removeValue(forKey: clientID)
        }
        guard !isPreview else { return }
        YConnectPreferences.setSelectedModelID(modelID, for: clientID)
        // Keep the v0.1 OpenCode preference as a one-way compatibility aid.
        if clientID == .openCode { YConnectPreferences.selectedModelID = modelID }
    }

    private func updateModelID(_ modelID: String?, for clientID: ClientID) {
        if selectedClientID == clientID {
            // The property observer owns persistence for the active client.
            selectedModelID = modelID
        } else {
            rememberModelID(modelID, for: clientID)
        }
    }

    private func descriptorIndex(_ clientID: ClientID) -> Int {
        clients.descriptors.firstIndex(where: { $0.id == clientID }) ?? Int.max
    }

    private func markClientUsed(_ clientID: ClientID) {
        recentClientIDs.removeAll(where: { $0 == clientID })
        recentClientIDs.insert(clientID, at: 0)
        if !isPreview { YConnectPreferences.recentClientIDs = recentClientIDs }
    }

    private func selectCompatibleModelIfNeeded() {
        guard let client = clients[selectedClientID], !businessKeyModels.isEmpty else { return }
        let compatible = client.compatibleModels(from: businessKeyModels.map(Self.clientModelOption))
        guard !compatible.isEmpty else {
            selectedModelID = nil
            return
        }
        let remembered = rememberedModelID(for: selectedClientID)
        if let remembered, compatible.contains(where: { $0.id == remembered }) {
            selectedModelID = remembered
        } else if selectedModelID == nil || !compatible.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = compatible[0].id
        }
    }

    /// The API contract identifies models by ID. Merge a malformed or
    /// transitional duplicate response into one picker entry and retain the
    /// union of advertised wire protocols, in first-seen order.
    private static func deduplicatedBusinessKeyModels(
        _ models: [BusinessKeyModel]
    ) -> [BusinessKeyModel] {
        var result: [BusinessKeyModel] = []
        var indexByID: [String: Int] = [:]

        for model in models {
            guard let index = indexByID[model.id] else {
                indexByID[model.id] = result.count
                result.append(model)
                continue
            }
            let existing = result[index]
            var protocols = existing.protocols
            var seen = Set(protocols.map { AIProtocol(rawValue: $0) })
            for value in model.protocols {
                if seen.insert(AIProtocol(rawValue: value)).inserted {
                    protocols.append(value)
                }
            }
            result[index] = BusinessKeyModel(
                id: existing.id,
                name: existing.name.isEmpty ? model.name : existing.name,
                protocols: protocols
            )
        }
        return result
    }

    private static func clientModelOption(_ model: BusinessKeyModel) -> ClientModelOption {
        ClientModelOption(id: model.id, name: model.name, protocols: model.protocols)
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

    static func preview(
        environment: AppEnvironment,
        authenticated: Bool = true,
        installedClientIDs: Set<ClientID>? = nil,
        operationMessage: String? = nil
    ) -> YConnectStore {
        // Re-root even an accidentally supplied production environment. This
        // factory is used by render previews and must never share client files,
        // credentials, or backups with the running application.
        let sandboxEnvironment = AppEnvironment.preview(
            at: environment.applicationSupportDirectory
                .appendingPathComponent("RenderPreview", isDirectory: true)
        )
        let store = YConnectStore(
            environment: sandboxEnvironment,
            api: YakCoolAPI(
                origin: URL(string: "https://preview.invalid")!,
                transport: PreviewOfflineHTTPTransport()
            ),
            credentialVault: MemoryCredentialVault(),
            installationDetector: StaticClientInstallationDetector(installedClientIDs),
            preview: true
        )
        guard authenticated else { return store }
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
        store.operationMessage = operationMessage
        store.clientMessages[.openCode] = sandboxEnvironment.isDevelopment
            ? "开发预览使用隔离配置目录，不会修改真实 OpenCode 配置"
            : "将安全写入 \(sandboxEnvironment.openCodeConfigurationURL.path)"
        return store
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Render previews contain realistic-looking credentials. They must never be
/// allowed to escape through a real HTTP transport.
private struct PreviewOfflineHTTPTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _ = request
        throw YConnectError.unsupported("界面预览模式不执行网络请求")
    }
}
