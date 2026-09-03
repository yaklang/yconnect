import AppKit
import SwiftUI

extension Brand {
    // Muted terracotta keeps the YakCool warmth without reusing YTray's vivid orange.
    static let accent = Color(red: 0.780, green: 0.416, blue: 0.333)
    static let accentNS = NSColor(red: 0.780, green: 0.416, blue: 0.333, alpha: 1)
    // The darker fill preserves readable white labels on primary controls.
    static let primaryFill = Color(red: 0.706, green: 0.365, blue: 0.294)
    static let primaryFillNS = NSColor(red: 0.706, green: 0.365, blue: 0.294, alpha: 1)
    static let primaryFillPressed = Color(red: 0.663, green: 0.310, blue: 0.247)
    static let green = Color(red: 0.19, green: 0.65, blue: 0.40)
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum WidgetMetrics {
    static let width: CGFloat = 390
    static let cornerRadius: CGFloat = 18
    static let collapsedBreathingRoom: CGFloat = 28
    static let signedOutAccountHeight: CGFloat = 380
    static let signedOutAPIKeyHeight: CGFloat = 420

    @MainActor
    static func idealHeight(for store: YConnectStore, presentation: WidgetPresentationState? = nil) -> CGFloat {
        if store.phase == .restoring { return 250 }
        if !store.isAuthenticated {
            return store.preferredAuthenticationMode == .account
                ? signedOutAccountHeight
                : signedOutAPIKeyHeight
        }
        let clientSlots = min(store.installedClientDescriptors.count, 4)
        let rows = max(1, Int(ceil(Double(clientSlots) / 2)))
        let base: CGFloat = 330
        let expandedURLs: CGFloat = presentation?.showsConnectionURLs == true ? 180 : 0
        let expandedModels: CGFloat = presentation?.showsModels == true ? 190 : 0
        let quickModels: CGFloat
        if presentation?.showsModels == true {
            quickModels = 0
        } else if store.modelDiscoveryModels.isEmpty {
            quickModels = 36
        } else {
            quickModels = 20 + CGFloat(min(3, store.modelDiscoveryModels.count) * 36)
        }
        let hasExpandedSection = expandedURLs > 0 || expandedModels > 0
        let breathingRoom = hasExpandedSection ? 0 : collapsedBreathingRoom
        return base + CGFloat(rows * 38) + (store.hasTransientOperationMessage ? 38 : 0)
            + expandedURLs + expandedModels + quickModels + breathingRoom
    }

    @MainActor
    static func height(for store: YConnectStore, presentation: WidgetPresentationState? = nil) -> CGFloat {
        let idealHeight = idealHeight(for: store, presentation: presentation)
        guard let maximumHeight = presentation?.maximumHeight else { return idealHeight }
        return min(idealHeight, maximumHeight)
    }

    @MainActor
    static func requiresVerticalScrolling(
        for store: YConnectStore,
        presentation: WidgetPresentationState
    ) -> Bool {
        idealHeight(for: store, presentation: presentation)
            > height(for: store, presentation: presentation)
    }
}

@MainActor
final class WidgetPresentationState: ObservableObject {
    @Published var isPinned = false
    @Published var showsConnectionURLs = false
    @Published var showsModels = false
    @Published var maximumHeight: CGFloat?
}

enum ManagerSection: String, CaseIterable, Identifiable {
    case overview
    case apiKeys
    case clients
    case diagnostics
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "账户概览"
        case .apiKeys: return "API Keys"
        case .clients: return "客户端适配"
        case .diagnostics: return "连接测试"
        case .settings: return "设置"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .apiKeys: return "key.horizontal"
        case .clients: return "arrow.triangle.2.circlepath.circle"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class ManagerNavigation: ObservableObject {
    @Published var selection: ManagerSection? = .overview
    @Published private(set) var apiKeyCreationRequestID = 0

    var selectedSection: ManagerSection { selection ?? .overview }

    func requestAPIKeyCreation() {
        selection = .apiKeys
        apiKeyCreationRequestID &+= 1
    }
}

enum APIKeyLabelSuggestion {
    private static let prefix = "YConnect-"

    static func next(existingLabels: [String]) -> String {
        let usedNumbers = Set(existingLabels.compactMap { label -> Int? in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(prefix) else { return nil }
            let suffix = trimmed.dropFirst(prefix.count)
            guard let value = Int(suffix), value > 0 else { return nil }
            return value
        })
        var candidate = existingLabels.count + 1
        while usedNumbers.contains(candidate) { candidate += 1 }
        return "\(prefix)\(candidate)"
    }
}

struct SmallPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(configuration.isPressed ? Brand.primaryFillPressed : Brand.primaryFill)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct SmallSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.primary.opacity(configuration.isPressed ? 0.11 : 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.09)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct PlainHoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.06 : 0))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.08 : 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct StatusBadge: View {
    let title: String
    let good: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(good ? Brand.green : Color.secondary).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(good ? Brand.green : .secondary)
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background((good ? Brand.green : Color.secondary).opacity(0.10))
        .clipShape(Capsule())
    }
}

struct WidgetView: View {
    @ObservedObject var store: YConnectStore
    @ObservedObject var presentation: WidgetPresentationState
    let beginAccountLogin: () -> Void
    let openManager: (ManagerSection) -> Void
    let openAPIKeyCreation: () -> Void
    let closeWidget: () -> Void
    @State private var apiKey = ""
    @State private var copiedEndpointID: String?
    @State private var selectedAccessModelID: String?
    @State private var copiedModelID: String?
    @State private var modelSearchQuery = ""

    var body: some View {
        ZStack {
            VisualEffect()
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
            if WidgetMetrics.requiresVerticalScrolling(for: store, presentation: presentation) {
                ScrollView(.vertical, showsIndicators: true) {
                    widgetContent
                }
            } else {
                widgetContent
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: WidgetMetrics.width, height: WidgetMetrics.height(for: store, presentation: presentation))
        .clipShape(RoundedRectangle(cornerRadius: WidgetMetrics.cornerRadius, style: .continuous))
        .tint(Brand.accent)
        .alert("YConnect", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("知道了") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var widgetContent: some View {
        VStack(spacing: 9) {
            header
            switch store.phase {
            case .restoring: restoring
            case .signedOut: login
            case .account, .apiKey: authenticated
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Brand.accent.gradient)
                Image(systemName: "link").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("YConnect").font(.system(size: 18, weight: .bold))
                Text(headerIdentitySummary)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isAuthenticated {
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
                .disabled(store.isBusy)
                .help("刷新账户状态")
            }
            Button { presentation.isPinned.toggle() } label: {
                Image(systemName: presentation.isPinned || store.isBusy ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
            .foregroundStyle(presentation.isPinned || store.isBusy ? Brand.accent : .secondary)
            .disabled(store.isBusy)
            .help(store.isBusy ? "操作期间已临时固定" : "固定小组件")
            Button(action: closeWidget) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
            .foregroundStyle(.secondary)
        }
    }

    private var restoring: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("正在从 macOS 钥匙串恢复登录信息")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var login: some View {
        VStack(spacing: 10) {
            authenticationModePicker

            if store.preferredAuthenticationMode == .account {
                loginCard(
                    symbol: "qrcode.viewfinder",
                    title: "微信扫码登录",
                    detail: "在 YConnect 原生登录窗口内展示 YakCool 官方扫码页；登录成功后，会话加密保存在 macOS 钥匙串。"
                ) {
                    Button(action: beginAccountLogin) {
                        Label("在 YConnect 内扫码", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SmallPrimaryButtonStyle())
                }
            } else {
                loginCard(
                    symbol: "key.horizontal",
                    title: "使用 API Key",
                    detail: "仅查询这把 Key 的状态、近似额度和可用模型；不会获得账户管理权限。"
                ) {
                    HStack(spacing: 7) {
                        SecureField("粘贴 YakCool API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(height: 30)
                            .onSubmit { connectAPIKey() }
                        Button("粘贴") { pasteAPIKey(into: &apiKey) }
                            .buttonStyle(SmallSecondaryButtonStyle())
                    }
                    Button(action: connectAPIKey) {
                        if store.isBusy { ProgressView().controlSize(.small) }
                        else { Label("验证并连接", systemImage: "checkmark.shield") }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(SmallPrimaryButtonStyle())
                    .disabled(store.isBusy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("凭证不写入偏好、日志或客户端配置明文")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)

            Button { openManager(.overview) } label: {
                HStack {
                    Image(systemName: "rectangle.on.rectangle")
                    Text("打开完整客户端")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
            }
            .buttonStyle(PlainHoverButtonStyle(cornerRadius: 8))
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        }
    }

    private var authenticationModePicker: some View {
        HStack(spacing: 4) {
            authenticationModeButton(.account, symbol: "person.crop.circle")
            authenticationModeButton(.apiKey, symbol: "key.horizontal")
        }
        .padding(4)
        .frame(height: 40)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("登录方式")
    }

    private func authenticationModeButton(_ mode: AuthenticationMode, symbol: String) -> some View {
        let selected = store.preferredAuthenticationMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                store.preferredAuthenticationMode = mode
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.15)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Brand.accent : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? Brand.accent.opacity(0.24) : Color.clear)
            )
            .shadow(color: selected ? Color.black.opacity(0.07) : .clear, radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var authenticated: some View {
        VStack(spacing: 9) {
            connectionStatusBanner
            keySelectionCard

            quickClientActions

            if store.hasTransientOperationMessage, let message = store.operationMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                    Text(message).lineLimit(2)
                    Spacer()
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 30)
                .background(Brand.green.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Button { openManager(.overview) } label: {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                        Text("全部配置管理").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                }
                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 8))
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))

                Button { Task { await store.signOut() } } label: {
                    Label("登出", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                }
                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 8))
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { store.refreshInstalledClients() }
        .task(id: store.selectedAccountKeyID) {
            guard store.isAccountMode else { return }
            await store.refreshConfigurationModels()
        }
        .onChange(of: store.businessKeyModels.map(\.id)) { _, availableIDs in
            if let selectedAccessModelID, !availableIDs.contains(selectedAccessModelID) {
                self.selectedAccessModelID = nil
            }
        }
    }

    private var connectionStatusBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Brand.green)
            Text(store.isAccountMode ? "YakCool 账户已安全连接" : "API Key 已验证并安全连接")
            Spacer()
            if let quotaBadgeText {
                Text(quotaBadgeText)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(quotaBadgeIsLow ? Color.red : Brand.green)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background((quotaBadgeIsLow ? Color.red : Brand.green).opacity(0.10))
                    .clipShape(Capsule())
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Brand.green.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.green.opacity(0.16)))
    }

    private var headerIdentitySummary: String {
        guard store.isAuthenticated else { return store.statusSummary }
        if store.isAccountMode {
            return "\(store.userDisplayName) · YakCool 账户"
        }
        let mode = store.businessKeyInfo?.quota.modeDisplay ?? "API Key"
        return "\(store.userDisplayName) · \(mode)"
    }

    private var quotaBadgeText: String? {
        if store.isAccountMode {
            return store.dashboard?.aiServiceCredit.remainingRMB.map { "¥\($0)" }
        }
        return store.businessKeyInfo?.quota.metricValue
    }

    private var quotaBadgeIsLow: Bool {
        store.businessKeyInfo?.quota.trayStatusIsLow == true
    }

    private var quickClientActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("已安装客户端").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("按最近使用排序").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            if store.installedClientDescriptors.isEmpty {
                Button { openManager(.clients) } label: {
                    HStack {
                        Label("未检测到可配置客户端", systemImage: "magnifyingglass")
                        Spacer()
                        Text("打开操作台").foregroundStyle(Brand.accent)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                }
                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 8))
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(store.installedClientDescriptors.prefix(store.installedClientDescriptors.count > 4 ? 3 : 4))) { client in
                        Button {
                            store.selectClientForManagement(client.id)
                            openManager(.clients)
                        } label: {
                            Label("应用到 \(client.shortName)", systemImage: client.symbol)
                                .frame(maxWidth: .infinity)
                                .lineLimit(1)
                        }
                        .buttonStyle(SmallSecondaryButtonStyle())
                        .help("打开 \(client.name) 配置页")
                    }
                    if store.installedClientDescriptors.count > 4 {
                        Button { openManager(.clients) } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SmallSecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private var keySelectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("当前连接", systemImage: "key.horizontal.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if store.isAccountMode {
                    Button(action: openAPIKeyCreation) {
                        Label("新增 API Key", systemImage: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                    }
                    .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
                    .foregroundStyle(Brand.accent)
                    .help("前往 API Keys 管理页创建新 Key")
                }
                Button {
                    store.copyAuthenticationInfo(modelID: selectedAccessModel?.id)
                } label: {
                    Label("复制/分享接入信息", systemImage: "square.and.arrow.up")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                }
                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
                .foregroundStyle(.white.opacity(store.hasUsableAPIKey ? 1 : 0.72))
                .background(Brand.primaryFill.opacity(store.hasUsableAPIKey ? 1 : 0.38))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help("复制 API Key、协议地址和当前选择的模型，便于安全分享")
                .disabled(!store.hasUsableAPIKey)
            }
            if store.isAccountMode, !store.accountKeys.isEmpty {
                HStack(spacing: 7) {
                    Picker("API Key", selection: $store.selectedAccountKeyID) {
                        ForEach(store.accountKeys) { key in
                            Text("\(key.label) · ••••\(key.last4)").tag(Optional(key.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    copyKeyButton
                }
            } else if store.isAccountMode {
                HStack(spacing: 7) {
                    Label("尚未创建 API Key", systemImage: "key.slash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: openAPIKeyCreation) {
                        Text("创建一个")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(height: 24)
                    }
                    .buttonStyle(PlainHoverButtonStyle(cornerRadius: 5))
                    .foregroundStyle(Brand.accent)
                }
                .frame(height: 30)
            } else {
                HStack(spacing: 7) {
                    Text("•••• •••• •••• \(store.businessKeyInfo?.key.last4 ?? "----")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    copyKeyButton
                }
                .frame(height: 30)
            }

            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    presentation.showsConnectionURLs.toggle()
                    if presentation.showsConnectionURLs { presentation.showsModels = false }
                }
            } label: {
                HStack(spacing: 6) {
                    Label("协议接入地址", systemImage: "point.3.connected.trianglepath.dotted")
                    Spacer()
                    Text(presentation.showsConnectionURLs ? "收起" : "展开")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(presentation.showsConnectionURLs ? 90 : 0))
                }
                .font(.system(size: 10.5, weight: .medium))
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))

            if presentation.showsConnectionURLs {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(YConnectStore.accessEndpoints) { endpoint in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(endpoint.name)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    copyAccessEndpoint(endpoint)
                                } label: {
                                    Label(
                                        copiedEndpointID == endpoint.id ? "已复制" : "复制",
                                        systemImage: copiedEndpointID == endpoint.id ? "checkmark" : "doc.on.doc"
                                    )
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                }
                                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 5))
                                .foregroundStyle(copiedEndpointID == endpoint.id ? Brand.green : Brand.accent)
                                .help("复制 \(endpoint.name) URL")
                            }
                            Text(endpoint.url)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.84))
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                        .help(endpoint.url)
                    }
                }
            }

            Divider()
            modelSelectionSection
        }
        .cardStyle()
    }

    @ViewBuilder private var modelSelectionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("模型", systemImage: "cube")
                    .font(.system(size: 10.5, weight: .medium))
                Text("\(availableAccessModels.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(Color.primary.opacity(0.055))
                    .clipShape(Capsule())
                Spacer(minLength: 5)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        presentation.showsModels.toggle()
                        if presentation.showsModels { presentation.showsConnectionURLs = false }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(presentation.showsModels ? "收起" : "查看全部")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(presentation.showsModels ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
                .disabled(availableAccessModels.isEmpty)
            }

            if availableAccessModels.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "cube.transparent")
                    Text(modelEmptyStateText)
                    Spacer()
                    if store.isAccountMode, store.selectedAccountKey == nil {
                        Button(action: openAPIKeyCreation) {
                            Text("创建 API Key")
                                .font(.system(size: 9.5, weight: .semibold))
                                .frame(height: 22)
                        }
                        .buttonStyle(PlainHoverButtonStyle(cornerRadius: 5))
                        .foregroundStyle(Brand.accent)
                    } else {
                        Button { Task { await store.refreshConfigurationModels() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(PlainHoverButtonStyle(cornerRadius: 5))
                        .help("重新读取模型")
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minHeight: 29)
            } else if presentation.showsModels {
                if availableAccessModels.count > 6 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField("搜索名称、模型 ID 或协议", text: $modelSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10.5))
                        if !modelSearchQuery.isEmpty {
                            Button { modelSearchQuery = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.07)))
                }

                if filteredAccessModels.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("没有匹配的模型")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(filteredAccessModels) { model in
                                modelSelectionRow(model)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(height: min(CGFloat(filteredAccessModels.count) * 42, 142))
                    .background(Color.primary.opacity(0.025))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.06)))
                }

            } else {
                HStack {
                    Text(hasRecentQuickModels ? "最近选择 / 热门推荐" : "热门推荐")
                    Spacer()
                    Text("无需展开，直接复制 ID")
                }
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
                VStack(spacing: 3) {
                    ForEach(quickAccessModels) { model in
                        quickModelCopyRow(model)
                    }
                }
            }
        }
    }

    private func modelSelectionRow(_ model: BusinessKeyModel) -> some View {
        let isSelected = selectedAccessModel?.id == model.id
        return HStack(spacing: 5) {
            Button {
                selectAccessModel(model)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Brand.accent : Color.secondary.opacity(0.45))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name.isEmpty ? model.id : model.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if !model.name.isEmpty && model.name != model.id {
                                Text(model.id)
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .lineLimit(1)
                            }
                            Text(protocolSummary(for: model))
                                .font(.system(size: 8.5))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 3)
                }
                .padding(.leading, 7)
                .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
                .background(isSelected ? Brand.accent.opacity(0.08) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
            .help("选择 \(model.id)")
            modelCopyButton(model, compact: true)
        }
        .padding(.trailing, 4)
        .frame(height: 39)
    }

    private func quickModelCopyRow(_ model: BusinessKeyModel) -> some View {
        HStack(spacing: 6) {
            Button {
                selectAccessModel(model)
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name.isEmpty ? model.id : model.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(model.id)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 5)
                    Text(protocolSummary(for: model))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 7)
            .frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .buttonStyle(PlainHoverButtonStyle(cornerRadius: 6))
            modelCopyButton(model, compact: true)
        }
        .padding(.leading, 1)
        .frame(height: 33)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.05)))
    }

    private func modelCopyButton(_ model: BusinessKeyModel, compact: Bool) -> some View {
        Button { copyModelID(model) } label: {
            Label(
                copiedModelID == model.id ? "已复制" : "复制 ID",
                systemImage: copiedModelID == model.id ? "checkmark" : "doc.on.doc"
            )
            .font(.system(size: compact ? 9 : 10, weight: .semibold))
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: compact ? 24 : 28)
        }
        .buttonStyle(PlainHoverButtonStyle(cornerRadius: 5))
        .foregroundStyle(copiedModelID == model.id ? Brand.green : Brand.accent)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help("复制模型 ID：\(model.id)")
    }

    private var availableAccessModels: [BusinessKeyModel] {
        store.modelDiscoveryModels
    }

    private var modelEmptyStateText: String {
        if store.isAccountMode, store.selectedAccountKey == nil {
            return "请先选择或创建一个 API Key"
        }
        return store.isBusy ? "正在读取此 Key 的模型…" : "此 Key 暂无可用模型，请刷新后重试"
    }

    private var filteredAccessModels: [BusinessKeyModel] {
        let query = modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableAccessModels }
        return availableAccessModels.filter { model in
            model.id.localizedCaseInsensitiveContains(query)
                || model.name.localizedCaseInsensitiveContains(query)
                || model.protocols.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || model.protocols.contains(where: { AIProtocol(rawValue: $0).title.localizedCaseInsensitiveContains(query) })
        }
    }

    private var quickAccessModels: [BusinessKeyModel] {
        var result: [BusinessKeyModel] = []
        var seen: Set<String> = []
        for modelID in store.recentAccessModelIDs {
            guard let model = availableAccessModels.first(where: { $0.id == modelID }),
                  seen.insert(model.id).inserted else { continue }
            result.append(model)
            if result.count == 3 { return result }
        }
        // YakCool returns catalogued models in heat order; fill any missing
        // recent slots from that server-ranked popularity order.
        for model in availableAccessModels where seen.insert(model.id).inserted {
            result.append(model)
            if result.count == 3 { break }
        }
        return result
    }

    private var hasRecentQuickModels: Bool {
        store.recentAccessModelIDs.contains { modelID in
            availableAccessModels.contains(where: { $0.id == modelID })
        }
    }

    private var selectedAccessModel: BusinessKeyModel? {
        if let selectedAccessModelID,
           let model = availableAccessModels.first(where: { $0.id == selectedAccessModelID }) {
            return model
        }
        if let selectedModelID = store.selectedModelID,
           let model = availableAccessModels.first(where: { $0.id == selectedModelID }) {
            return model
        }
        return availableAccessModels.first
    }

    private func protocolSummary(for _: BusinessKeyModel) -> String {
        // AIBalance translates every public compatibility entrypoint. The
        // protocol metadata describes the upstream's native wire format, not
        // a restriction users must follow, so exposing it here is misleading.
        return "全协议接入"
    }

    private func selectAccessModel(_ model: BusinessKeyModel) {
        selectedAccessModelID = model.id
        copiedModelID = nil
        store.recordAccessModelUse(model.id)
    }

    private func copyModelID(_ model: BusinessKeyModel) {
        selectedAccessModelID = model.id
        store.recordAccessModelUse(model.id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.id, forType: .string)
        copiedModelID = model.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedModelID == model.id { copiedModelID = nil }
        }
    }

    private var copyKeyButton: some View {
        Button { store.copyCurrentAPIKey() } label: {
            Label("复制 Key", systemImage: "doc.on.doc")
        }
        .buttonStyle(SmallSecondaryButtonStyle())
        .help("复制完整 API Key")
        .disabled(!store.hasUsableAPIKey)
    }

    private func loginCard<Content: View>(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Brand.accent)
                .frame(height: 40)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.accent.opacity(0.22)))
    }

    private func connectAPIKey() {
        let value = apiKey
        apiKey = ""
        Task { await store.signIn(apiKey: value) }
    }

    private func pasteAPIKey(into value: inout String) {
        value = NSPasteboard.general.string(forType: .string) ?? ""
    }

    private func copyAccessEndpoint(_ endpoint: YakCoolAccessEndpoint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint.url, forType: .string)
        copiedEndpointID = endpoint.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedEndpointID == endpoint.id {
                copiedEndpointID = nil
            }
        }
    }
}

struct ManagerView: View {
    @ObservedObject var store: YConnectStore
    @ObservedObject var navigation: ManagerNavigation
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    let beginAccountLogin: () -> Void
    let setEdgeDockEnabled: (Bool) -> Void
    @State private var standaloneKey = ""
    @State private var newKeyLabel = ""
    @State private var handledAPIKeyCreationRequestID = 0
    @State private var redeemCode = ""
    @State private var pendingDelete: APIKeyRecord?
    @State private var confirmLiveTest = false
    @FocusState private var newKeyLabelFocused: Bool

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $navigation.selection) {
                    ForEach(ManagerSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label(store.userDisplayName, systemImage: store.isAuthenticated ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    if store.isAuthenticated {
                        Button { Task { await store.signOut() } } label: {
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader
                    pageContent
                }
                .padding(28)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 940, minHeight: 640)
        .tint(Brand.accent)
        .onAppear {
            if newKeyLabel.isEmpty {
                newKeyLabel = APIKeyLabelSuggestion.next(existingLabels: store.accountKeys.map(\.label))
            }
        }
        .task(id: navigation.apiKeyCreationRequestID) {
            guard navigation.apiKeyCreationRequestID > handledAPIKeyCreationRequestID else { return }
            handledAPIKeyCreationRequestID = navigation.apiKeyCreationRequestID
            newKeyLabel = APIKeyLabelSuggestion.next(existingLabels: store.accountKeys.map(\.label))
            await Task.yield()
            newKeyLabelFocused = true
        }
        .alert("YConnect", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog(
            pendingDelete.map { "删除“\($0.label)”？" } ?? "删除 API Key？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("删除 API Key", role: .destructive) {
                guard let key = pendingDelete else { return }
                pendingDelete = nil
                Task { _ = await store.deleteAPIKey(key) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("删除后使用这把 Key 的客户端会立即失去访问权限，此操作不可撤销。")
        }
        .confirmationDialog("执行一次真实模型调用？", isPresented: $confirmLiveTest) {
            Button("执行最小调用") { Task { await store.runServiceChecks(includeLiveCompletion: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会向当前模型发送固定测试文本并消耗少量额度。")
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(navigation.selectedSection.title).font(.system(size: 24, weight: .bold))
                Text(pageSubtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isAuthenticated {
                Button { Task { await store.refresh() } } label: {
                    Label(store.isBusy ? "正在刷新" : "刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SmallSecondaryButtonStyle())
                .disabled(store.isBusy)
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        if !store.isAuthenticated && navigation.selectedSection != .settings {
            managerLogin
        } else {
            switch navigation.selectedSection {
            case .overview: overview
            case .apiKeys: keys
            case .clients: clients
            case .diagnostics: diagnostics
            case .settings: settings
            }
        }
    }

    private var managerLogin: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择连接方式").font(.system(size: 16, weight: .semibold))
            HStack(alignment: .top, spacing: 16) {
                managerLoginCard(symbol: "qrcode.viewfinder", title: "YakCool 账户", description: "微信扫码登录后管理余额、兑换与 API Keys。") {
                    beginAccountLogin()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("API Key", systemImage: "key.horizontal").font(.system(size: 15, weight: .semibold))
                    Text("只查看当前 Key 的额度与模型，不授予账户管理权限。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SecureField("粘贴 API Key", text: $standaloneKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { connectStandaloneKey() }
                        Button("粘贴") {
                            standaloneKey = NSPasteboard.general.string(forType: .string) ?? ""
                        }
                        .buttonStyle(SmallSecondaryButtonStyle())
                    }
                    Button("验证并连接") {
                        connectStandaloneKey()
                    }
                    .buttonStyle(SmallPrimaryButtonStyle())
                    .disabled(store.isBusy || standaloneKey.isEmpty)
                }
                .padding(18).frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            securityNote
        }
    }

    private func managerLoginCard(
        symbol: String,
        title: String,
        description: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Label("在 YConnect 内扫码", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(SmallPrimaryButtonStyle())
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                overviewMetric("连接状态", "已连接", "checkmark.shield.fill", Brand.green)
                if store.isAccountMode {
                    overviewMetric("可用余额", store.dashboard?.aiServiceCredit.remainingRMB.map { "¥\($0)" } ?? "—", "creditcard.fill", Brand.accent)
                    overviewMetric("API Keys", "\(store.accountKeys.count) / \(store.dashboard?.apiKeyLimit ?? 0)", "key.horizontal.fill", Brand.accent.opacity(0.78))
                } else {
                    overviewMetric(
                        store.businessKeyInfo?.quota.metricTitle ?? "额度状态",
                        store.businessKeyInfo?.quota.metricValue ?? "—",
                        "chart.pie.fill",
                        Brand.accent
                    )
                    overviewMetric("可用模型", "\(store.modelDiscoveryModels.count)", "cube.fill", Brand.accent.opacity(0.78))
                }
            }

            if store.isAccountMode {
                GroupBox("兑换额度") {
                    HStack(spacing: 10) {
                        TextField("输入 12–64 位兑换码", text: $redeemCode).textFieldStyle(.roundedBorder)
                        Button("兑换") {
                            let value = redeemCode
                            redeemCode = ""
                            Task { _ = await store.redeem(code: value) }
                        }
                        .buttonStyle(SmallPrimaryButtonStyle())
                        .disabled(store.isBusy || redeemCode.replacingOccurrences(of: " ", with: "").count < 12)
                    }
                    .padding(.top, 6)
                }
            }

            if let summary = store.dashboard?.accountSummary {
                GroupBox("账户使用概况") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                        detailMetric("总调用", summary.usageCount.map(String.init) ?? "—")
                        detailMetric("成功", summary.successCount.map(String.init) ?? "—")
                        detailMetric("成功率", summary.successRate.map { String(format: "%.1f%%", $0) } ?? "—")
                        detailMetric("活跃天数", summary.activeDays.map { "\($0) 天" } ?? "—")
                    }
                    .padding(.top, 8)
                }
            }
            operationBanner
        }
    }

    @ViewBuilder private var keys: some View {
        if store.isAccountMode {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("新 Key 名称", text: $newKeyLabel)
                        .textFieldStyle(.roundedBorder)
                        .focused($newKeyLabelFocused)
                        .frame(maxWidth: 300)
                    Button(action: createNamedAPIKey) {
                        Label("创建 API Key", systemImage: "plus")
                    }
                    .buttonStyle(SmallPrimaryButtonStyle())
                    .disabled(store.isBusy || newKeyLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Text("\(store.accountKeys.count) / \(store.dashboard?.apiKeyLimit ?? 0)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                ForEach(store.accountKeys) { key in keyRow(key) }
                if store.accountKeys.isEmpty { emptyState("还没有 API Key", symbol: "key.slash") }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if let info = store.businessKeyInfo {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(info.key.label).font(.system(size: 17, weight: .semibold))
                            Text("•••• •••• •••• \(info.key.last4)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(title: info.key.status, good: info.key.status == "enabled")
                        Button { store.copyAuthenticationInfo() } label: { Label("复制接入信息", systemImage: "doc.on.doc.fill") }
                            .buttonStyle(SmallPrimaryButtonStyle())
                        Button { store.copyCurrentAPIKey() } label: { Label("复制 Key", systemImage: "key.horizontal") }
                            .buttonStyle(SmallSecondaryButtonStyle())
                    }
                    .padding(18).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(info.quota.statusDisplay).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keyRow(_ key: APIKeyRecord) -> some View {
        HStack(spacing: 14) {
            Button {
                store.selectedAccountKeyID = key.id
            } label: {
                Image(systemName: store.selectedAccountKeyID == key.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.selectedAccountKeyID == key.id ? Brand.accent : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(key.label).font(.system(size: 14, weight: .semibold))
                    StatusBadge(title: key.active ? "启用" : "停用", good: key.active)
                }
                Text("•••• •••• •••• \(key.last4)  ·  \(key.usageCount) 次调用")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.selectedAccountKeyID = key.id
                store.copyAuthenticationInfo()
            } label: { Image(systemName: "doc.on.doc.fill").frame(width: 28, height: 28) }
                .buttonStyle(PlainHoverButtonStyle())
                .help("复制全部协议 URL 与 API Key")
            Button {
                store.selectedAccountKeyID = key.id
                store.copyCurrentAPIKey()
            } label: { Image(systemName: "key.horizontal").frame(width: 28, height: 28) }
                .buttonStyle(PlainHoverButtonStyle())
                .help("复制完整 API Key")
            Button { pendingDelete = key } label: {
                Image(systemName: "trash").frame(width: 28, height: 28)
            }
            .buttonStyle(PlainHoverButtonStyle()).foregroundStyle(Brand.primaryFill).help("删除")
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.selectedAccountKeyID == key.id ? Brand.accent.opacity(0.45) : Color.primary.opacity(0.07)))
    }

    private var clients: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: 28)).foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("一套 YakCool 凭证，连接不同本地客户端").font(.system(size: 17, weight: .semibold))
                    Text("每个适配器按客户端原生协议生成配置。只改 YakCool 节点与默认模型，写前完整备份；密钥放在权限为 0600 的独立文件，并通过客户端官方支持的 file / helper / command 机制读取。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18).background(Brand.accent.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Label("已检测到 \(store.installedClientDescriptors.count) 个可配置客户端", systemImage: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.installedClientDescriptors.isEmpty ? Color.secondary : Brand.green)
                Spacer()
                Button { store.refreshInstalledClients() } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SmallSecondaryButtonStyle())
            }

            if store.installedClientDescriptors.isEmpty {
                emptyState("没有检测到已安装的受支持客户端", symbol: "macwindow.badge.plus")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                    ForEach(store.installedClientDescriptors) { client in
                    Button { store.selectClientForManagement(client.id) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: client.symbol).font(.system(size: 16, weight: .semibold))
                                Spacer()
                                if client.id == store.selectedClientID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
                                }
                            }
                            Text(client.shortName).font(.system(size: 13, weight: .semibold))
                            Text(client.protocolSummary).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .background(client.id == store.selectedClientID ? Brand.accent.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(client.id == store.selectedClientID ? Brand.accent.opacity(0.55) : Color.primary.opacity(0.08)))
                    }
                }
            }

            if store.installedClientIDs.contains(store.selectedClientID) {
                GroupBox("配置 \(store.selectedClientDescriptor.name)") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("配置文件") {
                        Text(store.selectedClientDescriptor.configurationPath)
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent("连接协议") {
                        Text(store.selectedClientDescriptor.protocolSummary)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if store.isAccountMode {
                        Picker("API Key", selection: $store.selectedAccountKeyID) {
                            ForEach(store.accountKeys) { key in
                                Text("\(key.label) · ••••\(key.last4)").tag(Optional(key.id))
                            }
                        }
                    }
                    modelPicker
                    Text(store.selectedClientDescriptor.restartNote)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                }

                HStack(spacing: 10) {
                    Button { Task { await store.applySelectedClientConfiguration() } } label: {
                        Label("备份并应用到 \(store.selectedClientDescriptor.shortName)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(SmallPrimaryButtonStyle())
                    .disabled(store.isBusy || store.selectedClientCompatibleModels.isEmpty)
                    Button { store.restoreSelectedClientConfiguration() } label: {
                        Label("恢复最近备份", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(SmallSecondaryButtonStyle()).disabled(store.isBusy)
                    Button { Task { await store.refreshConfigurationModels() } } label: {
                        Label("刷新兼容模型", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SmallSecondaryButtonStyle()).disabled(store.isBusy)
                }
                Text(store.selectedClientMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            securityNote
        }
        .task(id: "\(store.selectedClientID.rawValue)-\(store.selectedAccountKeyID ?? 0)-\(store.phase)") {
            store.refreshInstalledClients()
            await store.refreshConfigurationModels()
        }
    }

    @ViewBuilder private var modelPicker: some View {
        let models = store.selectedClientCompatibleModels
        if models.isEmpty {
            LabeledContent("默认模型") {
                Text(store.isBusy ? "正在读取兼容模型…" : "当前 Key 没有兼容模型")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("默认模型", selection: $store.selectedModelID) {
                ForEach(models) { model in Text(model.name).tag(Optional(model.id)) }
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button { Task { await store.runServiceChecks(includeLiveCompletion: false) } } label: {
                    Label("运行只读检查", systemImage: "checkmark.shield")
                }
                .buttonStyle(SmallPrimaryButtonStyle()).disabled(store.isBusy)
                Button { confirmLiveTest = true } label: {
                    Label("测试一次模型调用", systemImage: "sparkles")
                }
                .buttonStyle(SmallSecondaryButtonStyle()).disabled(store.isBusy)
            }
            Text("只读检查不会消耗模型额度；真实模型调用会先二次确认，并仅发送固定测试文本。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(store.serviceChecks) { check in checkRow(check) }
            if store.serviceChecks.isEmpty { emptyState("尚未运行连接测试", symbol: "stethoscope") }
        }
    }

    private func checkRow(_ check: ServiceCheck) -> some View {
        HStack(spacing: 12) {
            Group {
                switch check.state {
                case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.primaryFill)
                }
            }.frame(width: 20)
            Text(check.title).font(.system(size: 13, weight: .semibold)).frame(width: 140, alignment: .leading)
            Text(checkDetail(check.state)).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("常驻体验") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("显示屏幕边缘小组件", isOn: Binding(
                        get: { EdgeDockPreferences.isEnabled },
                        set: { setEdgeDockEnabled($0) }
                    ))
                    Toggle("登录 macOS 后自动启动", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { _ = launchAtLogin.setEnabled($0) }
                    ))
                    Text(launchAtLogin.statusDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            GroupBox("安全边界") {
                VStack(alignment: .leading, spacing: 8) {
                    securityLine("用户会话与 API Key 保存到 macOS 钥匙串")
                    securityLine("只向 yakcool.com 和 aibalance.yaklang.com 发送凭证")
                    securityLine("退出登录不会擅自覆盖或删除任何客户端配置")
                    securityLine(store.environment.isDevelopment ? "开发包使用隔离目录，不修改真实客户端配置" : "每次应用客户端配置前都创建可恢复备份")
                }.padding(.top, 8)
            }
            LabeledContent("版本") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")
            }
            LabeledContent("模式") { Text(store.environment.isDevelopment ? "开发隔离" : "正式") }
        }
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Brand.green)
            Text("登录凭据保存在钥匙串；下游密钥仅写入 0600 私有文件，不进入 UserDefaults、日志、仓库或客户端配置明文。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.green.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var operationBanner: some View {
        if let message = store.operationMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
                Text(message)
            }
            .font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.green.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func overviewMetric(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(color)
            Text(value).font(.system(size: 19, weight: .bold)).lineLimit(2)
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func detailMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 16, weight: .semibold))
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyState(_ title: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 140)
    }

    private func checkDetail(_ state: ServiceCheck.State) -> String {
        switch state {
        case .pending: return "等待检查"
        case .running: return "检查中…"
        case .passed(let detail), .failed(let detail): return detail
        }
    }

    private func securityLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
            Text(text)
        }.font(.system(size: 12))
    }

    private func connectStandaloneKey() {
        let value = standaloneKey
        standaloneKey = ""
        Task { await store.signIn(apiKey: value) }
    }

    private func createNamedAPIKey() {
        let label = newKeyLabel
        Task { @MainActor in
            guard await store.createAPIKey(label: label) else { return }
            newKeyLabel = APIKeyLabelSuggestion.next(existingLabels: store.accountKeys.map(\.label))
            newKeyLabelFocused = true
        }
    }

    private var pageSubtitle: String {
        switch navigation.selectedSection {
        case .overview: return "查看 YakCool 账户状态、额度与使用概况"
        case .apiKeys: return "安全创建、选择、复制和删除 API Key"
        case .clients: return "自动检测并只展示本机已安装、可安全配置的客户端"
        case .diagnostics: return "分层验证服务、权限、模型和实际调用"
        case .settings: return "管理常驻体验与本地安全设置"
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self.padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
    }
}
