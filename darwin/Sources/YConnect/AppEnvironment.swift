import Foundation

struct AppEnvironment: Equatable {
    let displayName: String
    let keychainService: String
    let applicationSupportDirectory: URL
    let openCodeConfigurationURL: URL
    /// Root used to resolve every client's documented home-relative paths.
    /// Development and preview builds point this at an isolated sandbox.
    let clientHomeDirectory: URL
    let isDevelopment: Bool

    init(
        displayName: String,
        keychainService: String,
        applicationSupportDirectory: URL,
        openCodeConfigurationURL: URL,
        clientHomeDirectory: URL? = nil,
        isDevelopment: Bool
    ) {
        self.displayName = displayName
        self.keychainService = keychainService
        self.applicationSupportDirectory = applicationSupportDirectory
        self.openCodeConfigurationURL = openCodeConfigurationURL
        self.clientHomeDirectory = clientHomeDirectory
            ?? (isDevelopment
                ? applicationSupportDirectory.appendingPathComponent("ClientSandbox/Home", isDirectory: true)
                : FileManager.default.homeDirectoryForCurrentUser)
        self.isDevelopment = isDevelopment
    }

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
        let clientHome: URL
        let openCodeURL: URL
        if isDevelopment {
            clientHome = support.appendingPathComponent("ClientSandbox/Home", isDirectory: true)
            openCodeURL = clientHome
                .appendingPathComponent(".config/opencode", isDirectory: true)
                .appendingPathComponent("opencode.json", isDirectory: false)
        } else {
            clientHome = fileManager.homeDirectoryForCurrentUser
            openCodeURL = clientHome
                .appendingPathComponent(".config/opencode", isDirectory: true)
                .appendingPathComponent("opencode.json", isDirectory: false)
        }
        return AppEnvironment(
            displayName: isDevelopment ? "YConnect Dev" : "YConnect",
            keychainService: isDevelopment ? "io.yaklang.yconnect.dev" : "io.yaklang.yconnect",
            applicationSupportDirectory: support,
            openCodeConfigurationURL: openCodeURL,
            clientHomeDirectory: clientHome,
            isDevelopment: isDevelopment
        )
    }

    static func preview(at directory: URL) -> AppEnvironment {
        AppEnvironment(
            displayName: "YConnect Preview",
            keychainService: "io.yaklang.yconnect.preview",
            applicationSupportDirectory: directory,
            openCodeConfigurationURL: directory.appendingPathComponent("opencode.json"),
            clientHomeDirectory: directory.appendingPathComponent("ClientSandbox/Home", isDirectory: true),
            isDevelopment: true
        )
    }

    func configurationURLs(for clientID: ClientID) -> [URL] {
        switch clientID {
        case .openCode:
            return [openCodeConfigurationURL]
        case .pi:
            let root = clientHomeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
            return [
                root.appendingPathComponent("models.json", isDirectory: false),
                root.appendingPathComponent("settings.json", isDirectory: false),
            ]
        case .claudeCode:
            return [clientHomeDirectory.appendingPathComponent(".claude/settings.json", isDirectory: false)]
        case .codex:
            return [clientHomeDirectory.appendingPathComponent(".codex/config.toml", isDirectory: false)]
        case .grokBuild:
            return [clientHomeDirectory.appendingPathComponent(".grok/config.toml", isDirectory: false)]
        case .claudeDesktop:
            let root = clientHomeDirectory.appendingPathComponent(
                "Library/Application Support/Claude-3p/configLibrary",
                isDirectory: true
            )
            return [
                root.appendingPathComponent("9d254f75-6d3a-4b8c-a0e8-4d3a4f4d42f7.json", isDirectory: false),
                root.appendingPathComponent("_meta.json", isDirectory: false),
            ]
        case .geminiCLI:
            let root = clientHomeDirectory.appendingPathComponent(".gemini", isDirectory: true)
            return [
                root.appendingPathComponent(".env", isDirectory: false),
                root.appendingPathComponent("settings.json", isDirectory: false),
            ]
        case .openClaw:
            return [clientHomeDirectory.appendingPathComponent(".openclaw/openclaw.json", isDirectory: false)]
        case .hermes:
            return [clientHomeDirectory.appendingPathComponent(".hermes/config.yaml", isDirectory: false)]
        default:
            return []
        }
    }

    func managedSecretURL(for clientID: ClientID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("\(clientID.rawValue)-yakcool-key", isDirectory: false)
    }

    func managedHelperURL(for clientID: ClientID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("\(clientID.rawValue)-credential", isDirectory: false)
    }

    func backupsDirectory(for clientID: ClientID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(clientID.rawValue, isDirectory: true)
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

    static var selectedClientID: ClientID {
        get {
            guard let value = UserDefaults.standard.string(forKey: prefix + "selected-client-id"), !value.isEmpty else {
                return .openCode
            }
            return ClientID(rawValue: value)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: prefix + "selected-client-id") }
    }

    static func selectedModelID(for clientID: ClientID) -> String? {
        UserDefaults.standard.string(forKey: prefix + "selected-model-id." + clientID.rawValue)
    }

    static func setSelectedModelID(_ modelID: String?, for clientID: ClientID) {
        let key = prefix + "selected-model-id." + clientID.rawValue
        if let modelID { UserDefaults.standard.set(modelID, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
