import AppKit
import SwiftUI

extension Brand {
    static let orange = Color(red: 0.949, green: 0.545, blue: 0.267)
    static let orangeNS = NSColor(red: 0.949, green: 0.545, blue: 0.267, alpha: 1)
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

    @MainActor
    static func height(for store: YConnectStore) -> CGFloat {
        if store.phase == .restoring { return 250 }
        if !store.isAuthenticated { return 430 }
        let base: CGFloat = store.isAccountMode ? 360 : 325
        return base + (store.operationMessage == nil ? 0 : 39)
    }
}

@MainActor
final class WidgetPresentationState: ObservableObject {
    @Published var isPinned = false
}

enum ManagerSection: String, CaseIterable, Identifiable {
    case overview
    case apiKeys
    case openCode
    case diagnostics
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "账户概览"
        case .apiKeys: return "API Keys"
        case .openCode: return "OpenCode"
        case .diagnostics: return "连接测试"
        case .settings: return "设置"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .apiKeys: return "key.horizontal"
        case .openCode: return "terminal"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class ManagerNavigation: ObservableObject {
    @Published var selection: ManagerSection? = .overview
    var selectedSection: ManagerSection { selection ?? .overview }
}

struct SmallOrangeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Brand.orange.opacity(configuration.isPressed ? 0.76 : 1))
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
    let closeWidget: () -> Void
    @State private var apiKey = ""

    var body: some View {
        ZStack {
            VisualEffect()
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
            VStack(spacing: 9) {
                header
                switch store.phase {
                case .restoring: restoring
                case .signedOut: login
                case .account, .apiKey: authenticated
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(width: WidgetMetrics.width, height: WidgetMetrics.height(for: store))
        .alert("YConnect", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("知道了") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Brand.orange.gradient)
                Image(systemName: "link").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("YConnect").font(.system(size: 18, weight: .bold))
                Text(store.statusSummary)
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
            .foregroundStyle(presentation.isPinned || store.isBusy ? Brand.orange : .secondary)
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
            Picker("登录方式", selection: $store.preferredAuthenticationMode) {
                ForEach(AuthenticationMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)

            if store.preferredAuthenticationMode == .account {
                loginCard(
                    symbol: "qrcode.viewfinder",
                    title: "微信扫码登录",
                    detail: "打开 YakCool 官方登录页。登录成功后，用户会话加密保存在 macOS 钥匙串。"
                ) {
                    Button(action: beginAccountLogin) {
                        Label("打开扫码登录", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SmallOrangeButtonStyle())
                }
            } else {
                loginCard(
                    symbol: "key.horizontal",
                    title: "使用 API Key",
                    detail: "仅查询这把 Key 的状态、近似额度和可用模型；不会获得账户管理权限。"
                ) {
                    SecureField("粘贴 YakCool API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connectAPIKey() }
                    Button(action: connectAPIKey) {
                        if store.isBusy { ProgressView().controlSize(.small) }
                        else { Label("验证并连接", systemImage: "checkmark.shield") }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(SmallOrangeButtonStyle())
                    .disabled(store.isBusy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("凭证不写入偏好、日志或 OpenCode JSON")
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

    private var authenticated: some View {
        VStack(spacing: 9) {
            accountSummaryCard
            keySelectionCard
            HStack(spacing: 6) {
                Button { store.copyCurrentAPIKey() } label: {
                    Label("复制 API Key", systemImage: "doc.on.doc")
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(SmallSecondaryButtonStyle())

                Button { Task { await store.applyOpenCodeConfiguration() } } label: {
                    if store.isBusy { ProgressView().controlSize(.small) }
                    else { Label("应用到 OpenCode", systemImage: "terminal") }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(SmallOrangeButtonStyle())
                .disabled(store.isBusy)
            }

            if let message = store.operationMessage {
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
                        Text("全部管理").fontWeight(.medium)
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
                    Label("退出", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                }
                .buttonStyle(PlainHoverButtonStyle(cornerRadius: 8))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var accountSummaryCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.userDisplayName).font(.system(size: 14, weight: .semibold))
                    Text(store.isAccountMode ? "YakCool 账户会话" : "独立 API Key 模式")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(title: "已连接", good: true)
            }
            Divider()
            if store.isAccountMode {
                HStack(spacing: 18) {
                    metric("可用余额", store.dashboard?.aiServiceCredit.remainingRMB.map { "¥\($0)" } ?? "—")
                    metric("API Keys", "\(store.accountKeys.count) / \(store.dashboard?.apiKeyLimit ?? 0)")
                    metric("调用次数", formatCount(store.dashboard?.accountSummary?.usageCount))
                }
            } else if let quota = store.businessKeyInfo?.quota {
                HStack(spacing: 18) {
                    metric("额度", quota.remainingRMB.map { "¥\($0)" } ?? quota.display)
                    metric("模式", quota.approximate ? "约数" : "独立限额")
                    metric("模型", "\(store.businessKeyModels.count)")
                }
            }
        }
        .cardStyle()
    }

    private var keySelectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("当前连接", systemImage: "key.horizontal.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text(store.isAccountMode ? (store.selectedAccountKey?.maskedKey ?? "无可用 Key") : "•••• •••• •••• \(store.businessKeyInfo?.key.last4 ?? "----")")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            if store.isAccountMode, !store.accountKeys.isEmpty {
                Picker("API Key", selection: $store.selectedAccountKeyID) {
                    ForEach(store.accountKeys) { key in
                        Text("\(key.label) · ••••\(key.last4)").tag(Optional(key.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            HStack {
                Image(systemName: "cube")
                Text("OpenCode 模型")
                Spacer()
                Text(store.selectedModelName).lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .cardStyle()
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
                .foregroundStyle(Brand.orange)
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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.orange.opacity(0.22)))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatCount(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.notation(value >= 10_000 ? .compactName : .automatic))
    }

    private func connectAPIKey() {
        let value = apiKey
        apiKey = ""
        Task { await store.signIn(apiKey: value) }
    }
}

struct ManagerView: View {
    @ObservedObject var store: YConnectStore
    @ObservedObject var navigation: ManagerNavigation
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    let beginAccountLogin: () -> Void
    let setEdgeDockEnabled: (Bool) -> Void
    @State private var standaloneKey = ""
    @State private var newKeyLabel = "OpenCode"
    @State private var redeemCode = ""
    @State private var pendingDelete: APIKeyRecord?
    @State private var confirmLiveTest = false

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
            case .openCode: openCode
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
                    SecureField("粘贴 API Key", text: $standaloneKey).textFieldStyle(.roundedBorder)
                    Button("验证并连接") {
                        let value = standaloneKey
                        standaloneKey = ""
                        Task { await store.signIn(apiKey: value) }
                    }
                    .buttonStyle(SmallOrangeButtonStyle())
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
            Button("打开扫码登录", action: action).buttonStyle(SmallOrangeButtonStyle())
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                overviewMetric("连接状态", "已连接", "checkmark.shield.fill", Brand.green)
                if store.isAccountMode {
                    overviewMetric("可用余额", store.dashboard?.aiServiceCredit.remainingRMB.map { "¥\($0)" } ?? "—", "creditcard.fill", Brand.orange)
                    overviewMetric("API Keys", "\(store.accountKeys.count) / \(store.dashboard?.apiKeyLimit ?? 0)", "key.horizontal.fill", .blue)
                } else {
                    overviewMetric("额度状态", store.businessKeyInfo?.quota.display ?? "—", "chart.pie.fill", Brand.orange)
                    overviewMetric("可用模型", "\(store.businessKeyModels.count)", "cube.fill", .blue)
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
                        .buttonStyle(SmallOrangeButtonStyle())
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
                    TextField("新 Key 名称", text: $newKeyLabel).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Button { Task { _ = await store.createAPIKey(label: newKeyLabel) } } label: {
                        Label("创建 API Key", systemImage: "plus")
                    }
                    .buttonStyle(SmallOrangeButtonStyle())
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
                        Button { store.copyCurrentAPIKey() } label: { Label("复制", systemImage: "doc.on.doc") }
                            .buttonStyle(SmallSecondaryButtonStyle())
                    }
                    .padding(18).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(info.quota.display).font(.system(size: 13)).foregroundStyle(.secondary)
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
                    .foregroundStyle(store.selectedAccountKeyID == key.id ? Brand.orange : .secondary)
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
                store.copyCurrentAPIKey()
            } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 28) }
                .buttonStyle(PlainHoverButtonStyle())
                .help("复制完整 API Key")
            Button { pendingDelete = key } label: {
                Image(systemName: "trash").frame(width: 28, height: 28)
            }
            .buttonStyle(PlainHoverButtonStyle()).foregroundStyle(.red).help("删除")
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.selectedAccountKeyID == key.id ? Brand.orange.opacity(0.45) : Color.primary.opacity(0.07)))
    }

    private var openCode: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "terminal.fill").font(.system(size: 28)).foregroundStyle(Brand.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("一键连接 OpenCode").font(.system(size: 17, weight: .semibold))
                    Text("YConnect 只修改 YakCool provider 与默认模型；原配置会先完整备份。API Key 存在权限为 0600 的独立文件中，JSON 使用文件引用。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18).background(Brand.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))

            GroupBox("目标") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("配置文件") {
                        Text(store.environment.openCodeConfigurationURL.path)
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    if store.isAccountMode {
                        Picker("API Key", selection: $store.selectedAccountKeyID) {
                            ForEach(store.accountKeys) { key in
                                Text("\(key.label) · ••••\(key.last4)").tag(Optional(key.id))
                            }
                        }
                    }
                    modelPicker
                }
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                Button { Task { await store.applyOpenCodeConfiguration() } } label: {
                    Label("备份并应用配置", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SmallOrangeButtonStyle()).disabled(store.isBusy)
                Button { store.restoreOpenCodeConfiguration() } label: {
                    Label("恢复最近备份", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(SmallSecondaryButtonStyle()).disabled(store.isBusy)
            }
            Text(store.openCodeMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            securityNote
        }
    }

    @ViewBuilder private var modelPicker: some View {
        let models: [(String, String)] = store.isAccountMode
            ? store.accountModels.map { ($0.modelID, $0.displayName) }
            : store.businessKeyModels.map { ($0.id, $0.name) }
        Picker("默认模型", selection: $store.selectedModelID) {
            ForEach(models, id: \.0) { model in Text(model.1).tag(Optional(model.0)) }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button { Task { await store.runServiceChecks(includeLiveCompletion: false) } } label: {
                    Label("运行只读检查", systemImage: "checkmark.shield")
                }
                .buttonStyle(SmallOrangeButtonStyle()).disabled(store.isBusy)
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
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
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
                    securityLine("退出登录不会擅自覆盖或删除 OpenCode 配置")
                    securityLine(store.environment.isDevelopment ? "开发包使用隔离配置目录，不修改真实 OpenCode 配置" : "每次应用 OpenCode 配置前都创建可恢复备份")
                }.padding(.top, 8)
            }
            LabeledContent("版本") { Text("0.1.0") }
            LabeledContent("模式") { Text(store.environment.isDevelopment ? "开发隔离" : "正式") }
        }
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Brand.green)
            Text("敏感信息不会进入 UserDefaults、日志、崩溃信息或仓库；OpenCode 配置可随时恢复最近备份。")
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

    private var pageSubtitle: String {
        switch navigation.selectedSection {
        case .overview: return "查看 YakCool 账户状态、额度与使用概况"
        case .apiKeys: return "安全创建、选择、复制和删除 API Key"
        case .openCode: return "备份现有配置并切换到 YakCool provider"
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
