import AppKit
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

protocol LaunchAtLoginBackend {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SystemLaunchAtLoginBackend: LaunchAtLoginBackend {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let firstLaunchKey = "yconnect.launch-at-login.setup.v1"

    @Published private(set) var status: LaunchAtLoginStatus
    @Published var errorMessage: String?

    private let backend: LaunchAtLoginBackend
    private let defaults: UserDefaults
    private let packagedApplication: Bool

    init(
        backend: LaunchAtLoginBackend = SystemLaunchAtLoginBackend(),
        defaults: UserDefaults = .standard,
        packagedApplication: Bool = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    ) {
        self.backend = backend
        self.defaults = defaults
        self.packagedApplication = packagedApplication
        status = packagedApplication ? backend.status : .unavailable
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    var statusDetail: String {
        switch status {
        case .enabled: return "登录 macOS 后，YConnect 会自动进入菜单栏。"
        case .disabled: return "YConnect 不会随登录自动运行。"
        case .requiresApproval: return "请在“系统设置 → 通用 → 登录项”中允许 YConnect。"
        case .unavailable:
            return packagedApplication
                ? "系统没有找到可注册的应用，请将 YConnect 放入“应用程序”后重试。"
                : "开发构建不会修改登录项；安装版可正常使用。"
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard packagedApplication else {
            errorMessage = "开发构建不会修改系统登录项。"
            status = .unavailable
            return false
        }
        refresh()
        if enabled ? isEnabled : status == .disabled {
            defaults.set(true, forKey: Self.firstLaunchKey)
            errorMessage = nil
            return true
        }
        do {
            if enabled { try backend.register() } else { try backend.unregister() }
            refresh()
            let succeeded = enabled ? isEnabled : status == .disabled
            if succeeded {
                defaults.set(true, forKey: Self.firstLaunchKey)
                errorMessage = nil
            }
            return succeeded
        } catch {
            refresh()
            errorMessage = "无法\(enabled ? "开启" : "关闭")开机启动：\(error.localizedDescription)"
            return false
        }
    }

    func refresh() { status = packagedApplication ? backend.status : .unavailable }
    func openSystemSettings() { backend.openSystemSettings() }

    func enableByDefaultIfNeeded() {
        guard packagedApplication, !defaults.bool(forKey: Self.firstLaunchKey) else { return }
        _ = setEnabled(true)
    }
}

struct PreviewLaunchAtLoginBackend: LaunchAtLoginBackend {
    var status: LaunchAtLoginStatus = .enabled
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
