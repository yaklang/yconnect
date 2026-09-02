import Foundation

struct AppEnvironment: Equatable {
    let displayName: String
    let keychainService: String
    let applicationSupportDirectory: URL
    let openCodeConfigurationURL: URL
    let isDevelopment: Bool

    static func current(
        processInfo: ProcessInfo = .processInfo,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> AppEnvironment {
        let arguments = Set(processInfo.arguments)
        let identifier = bundle.bundleIdentifier ?? ""
        let isDevelopment = arguments.contains("--development")
            || identifier.hasSuffix(".dev")
            || processInfo.environment["YCONNECT_DEVELOPMENT"] == "1"
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let support = supportRoot.appendingPathComponent(isDevelopment ? "YConnectDev" : "YConnect", isDirectory: true)
        let openCodeURL: URL
        if isDevelopment {
            openCodeURL = support
                .appendingPathComponent("OpenCodeSandbox", isDirectory: true)
                .appendingPathComponent("opencode.json")
        } else {
            openCodeURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode", isDirectory: true)
                .appendingPathComponent("opencode.json")
        }
        return AppEnvironment(
            displayName: isDevelopment ? "YConnect Dev" : "YConnect",
            keychainService: isDevelopment ? "io.yaklang.yconnect.dev" : "io.yaklang.yconnect",
            applicationSupportDirectory: support,
            openCodeConfigurationURL: openCodeURL,
            isDevelopment: isDevelopment
        )
    }

    static func preview(at directory: URL) -> AppEnvironment {
        AppEnvironment(
            displayName: "YConnect Preview",
            keychainService: "io.yaklang.yconnect.preview",
            applicationSupportDirectory: directory,
            openCodeConfigurationURL: directory.appendingPathComponent("opencode.json"),
            isDevelopment: true
        )
    }
}

enum YConnectPreferences {
    private static let prefix = "yconnect."

    static var selectedAccountKeyID: Int64? {
        get {
            guard let value = UserDefaults.standard.object(forKey: prefix + "selected-account-key-id") as? NSNumber else {
                return nil
            }
            return value.int64Value
        }
        set {
            if let newValue { UserDefaults.standard.set(NSNumber(value: newValue), forKey: prefix + "selected-account-key-id") }
            else { UserDefaults.standard.removeObject(forKey: prefix + "selected-account-key-id") }
        }
    }

    static var selectedModelID: String? {
        get { UserDefaults.standard.string(forKey: prefix + "selected-model-id") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "selected-model-id") }
    }
}
