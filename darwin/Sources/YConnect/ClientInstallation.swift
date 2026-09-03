import Foundation

protocol ClientInstallationDetecting {
    func installedClientIDs(from descriptors: [ClientDescriptor]) -> Set<ClientID>
}

struct DefaultClientInstallationDetector: ClientInstallationDetecting {
    private let homeDirectory: URL
    private let pathDirectories: [URL]
    private let applicationDirectories: [URL]
    private let fileExists: (String) -> Bool
    private let isExecutable: (String) -> Bool

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        applicationDirectories: [URL]? = nil,
        fileExists: @escaping (String) -> Bool = FileManager.default.fileExists(atPath:),
        isExecutable: @escaping (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) {
        self.homeDirectory = homeDirectory
        pathDirectories = path
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        self.fileExists = fileExists
        self.isExecutable = isExecutable
    }

    func installedClientIDs(from descriptors: [ClientDescriptor]) -> Set<ClientID> {
        let supported = Set(descriptors.map(\.id))
        return Set(supported.filter(isInstalled))
    }

    private func isInstalled(_ clientID: ClientID) -> Bool {
        switch clientID {
        case .openCode:
            return hasExecutable(named: "opencode", extras: [".opencode/bin/opencode"])
        case .pi:
            return hasExecutable(named: "pi")
        case .claudeCode:
            return hasExecutable(named: "claude")
        case .claudeDesktop:
            return hasApplication(named: "Claude.app")
        case .codex:
            return hasExecutable(
                named: "codex",
                absoluteExtras: ["/Applications/ChatGPT.app/Contents/Resources/codex"]
            )
        case .grokBuild:
            // Grok Bot.app is a different product and must not be treated as Grok Build.
            return hasExecutable(named: "grok") || hasExecutable(named: "grok-build")
        case .openClaw:
            return hasExecutable(named: "openclaw")
        case .hermes:
            return hasExecutable(named: "hermes") || hasExecutable(named: "hermes-agent")
        default:
            return false
        }
    }

    private func hasExecutable(
        named name: String,
        extras: [String] = [],
        absoluteExtras: [String] = []
    ) -> Bool {
        let conventionalDirectories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".bun/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent("bin", isDirectory: true).path,
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let candidates = (pathDirectories + conventionalDirectories).map {
            $0.appendingPathComponent(name, isDirectory: false).path
        } + extras.map {
            homeDirectory.appendingPathComponent($0, isDirectory: false).path
        } + absoluteExtras
        return candidates.contains(where: isExecutable)
    }

    private func hasApplication(named name: String) -> Bool {
        applicationDirectories.contains {
            fileExists($0.appendingPathComponent(name, isDirectory: true).path)
        }
    }
}

struct StaticClientInstallationDetector: ClientInstallationDetecting {
    let clientIDs: Set<ClientID>?

    init(_ clientIDs: Set<ClientID>? = nil) {
        self.clientIDs = clientIDs
    }

    func installedClientIDs(from descriptors: [ClientDescriptor]) -> Set<ClientID> {
        clientIDs ?? Set(descriptors.map(\.id))
    }
}
