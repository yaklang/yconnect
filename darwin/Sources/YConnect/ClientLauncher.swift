import AppKit
import Darwin
import Foundation

struct AgentLaunchManifest: Codable {
    let clientID: String
    let model: String
    let executable: String
    let arguments: [String]
    let directory: String
    let variables: [String: String]
    let removeVariables: [String]
    let secretPath: String
    let autoStart: Bool
    let expiresAt: Date
}

struct AgentLaunchPlan {
    let root: URL
    let manifest: AgentLaunchManifest
    var manifestURL: URL { root.appendingPathComponent("session.json") }
    var commandURL: URL { root.appendingPathComponent("启动 Agent.command") }
    var readyURL: URL { root.appendingPathComponent("ready") }
    var exitURL: URL { root.appendingPathComponent("exit-status") }
}

enum ClientLauncher {
    static func supports(_ id: ClientID) -> Bool {
        [.openCode, .codex, .claudeCode, .pi, .grokBuild, .hermes, .openClaw].contains(id)
    }
    static func canAutoStart(_ id: ClientID) -> Bool { supports(id) && id != .openClaw }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func prepare(environment: AppEnvironment, clientID: ClientID, model: ClientModelOption,
                        apiKey: String, directory: String, autoStart: Bool,
                        executable: URL, runner: URL, contextWindow: Int? = nil) throws -> AgentLaunchPlan {
        try ContextWindowSetting.validate(contextWindow)
        guard supports(clientID), !autoStart || canAutoStart(clientID) else {
            throw YConnectError.unsupported("此客户端需要先打开专用终端准备网关")
        }
        let key = try YakCoolAPI.normalizedAPIKey(apiKey)
        guard model.id.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,199}\z"#, options: .regularExpression) != nil else {
            throw YConnectError.unsupported("模型 ID 无法安全传入命令行")
        }
        let fm = FileManager.default
        let directory = (directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw YConnectError.unsupported("请选择已存在的完整工作目录")
        }
        guard executable.isFileURL, fm.isExecutableFile(atPath: executable.path),
              runner.isFileURL, fm.isExecutableFile(atPath: runner.path) else {
            throw YConnectError.unsupported("客户端或启动器不存在，请重新检测安装")
        }
        let sessions = environment.applicationSupportDirectory.appendingPathComponent("LaunchSessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessions.path)
        cleanExpiredSecrets(in: sessions)
        let root = sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let isolated = AppEnvironment.preview(at: root)
            let registry = try DefaultClientConfigurationRegistry.make(environment: isolated)
            guard let client = registry[clientID], client.compatibleModels(from: [model]).contains(where: { $0.id == model.id }) else {
                throw YConnectError.unsupported("所选模型不兼容此客户端")
            }
            let secret = isolated.managedSecretURL(for: clientID)
            var variables = ["YCONNECT_MODEL": model.id, "YCONNECT_BASE_URL": "https://aibalance.yaklang.com/v1"]
            var arguments: [String] = []
            var removals = ["YCONNECT_API_KEY"]
            let provider = "yconnect_" + root.lastPathComponent.replacingOccurrences(of: "-", with: "").lowercased()
            let gateway = "https://aibalance.yaklang.com"
            switch clientID {
            case .codex:
                // A new provider name prevents saved auth helpers from winning a deep merge.
                arguments = ["-m", model.id, "-c", "model_provider=\(provider)",
                    "-c", "model_providers.\(provider).name=YAKCOOL",
                    "-c", "model_providers.\(provider).base_url=\(gateway)/v1",
                    "-c", "model_providers.\(provider).wire_api=responses",
                    "-c", "model_providers.\(provider).env_key=YCONNECT_API_KEY",
                    "-c", "model_providers.\(provider).requires_openai_auth=false"]
                try write(Data(key.utf8), to: secret)
            case .openCode:
                let config: [String: Any] = ["model": "\(provider)/\(model.id)", "provider": [provider: [
                    "name": "YAKCOOL", "npm": "@ai-sdk/openai-compatible",
                    "options": ["baseURL": gateway + "/v1", "apiKey": "{env:YCONNECT_API_KEY}"],
                    "models": [model.id: ["name": model.name]]]]]
                variables["OPENCODE_CONFIG_CONTENT"] = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
                arguments = ["--model", "\(provider)/\(model.id)"]
                try write(Data(key.utf8), to: secret)
            default:
                _ = try client.apply(ClientApplyRequest(apiKey: key, models: [model], selectedModelID: model.id,
                                                       contextWindow: contextWindow))
                let configuration = isolated.configurationURLs(for: clientID)[0]
                switch clientID {
                case .claudeCode:
                    // Limit settings sources so a project credential cannot override the session helper.
                    arguments = ["--setting-sources", "", "--settings", configuration.path, "--model", model.id]
                    variables["ANTHROPIC_BASE_URL"] = gateway
                    for name in ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"] { variables[name] = model.id }
                    for name in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { variables[name] = "0" }
                    removals += ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"]
                case .pi:
                    variables["PI_CODING_AGENT_DIR"] = configuration.deletingLastPathComponent().path
                    arguments = ["--provider", "yakcool", "--model", model.id]
                case .grokBuild:
                    variables["GROK_HOME"] = configuration.deletingLastPathComponent().path
                    arguments = ["--model", "yakcool"]
                case .hermes:
                    variables["HERMES_HOME"] = configuration.deletingLastPathComponent().path
                    removals += ["OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "OPENROUTER_API_KEY"]
                case .openClaw:
                    variables["OPENCLAW_STATE_DIR"] = configuration.deletingLastPathComponent().path
                    variables["OPENCLAW_CONFIG_PATH"] = configuration.path
                    arguments = ["--help"]
                default: break
                }
            }
            // Native .app launches have a short PATH. Preserve the detected CLI's runtime lookup.
            let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            variables["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:" + inheritedPath
            let manifest = AgentLaunchManifest(clientID: clientID.rawValue, model: model.id,
                executable: executable.path, arguments: arguments,
                directory: URL(fileURLWithPath: directory).resolvingSymlinksInPath().path,
                variables: variables, removeVariables: removals, secretPath: secret.path,
                autoStart: autoStart, expiresAt: Date().addingTimeInterval(120))
            let plan = AgentLaunchPlan(root: root, manifest: manifest)
            let data = try JSONEncoder().encode(manifest)
            guard !String(decoding: data, as: UTF8.self).contains(key) else { throw YConnectError.unsupported("启动配置不能包含明文 Key") }
            try write(data, to: plan.manifestURL)
            try write(Data("#!/bin/zsh -f\nexec \(shellQuote(runner.path)) --run-agent-session \(shellQuote(plan.manifestURL.path))\n".utf8), to: plan.commandURL, permissions: 0o700)
            if !autoStart {
                let command = ([executable.path] + arguments).map(shellQuote).joined(separator: " ")
                let rc = "unset HISTFILE\nHISTSIZE=0\nSAVEHIST=0\nfunction yconnect-agent() { \(command) \"$@\"; }\nPS1='Y CONNECT %1~ %# '\nprint -r -- '输入 yconnect-agent 启动所选模型；exit 关闭此会话。'\n"
                try write(Data(rc.utf8), to: root.appendingPathComponent(".zshrc"))
            }
            return plan
        } catch { try? fm.removeItem(at: root); throw error }
    }

    @MainActor
    static func start(_ plan: AgentLaunchPlan) async throws -> String {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw YConnectError.unsupported("未找到 macOS 终端")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // The macOS 14 SDK's async overlay moves non-Sendable AppKit objects
        // across actors. Keep the request on the main actor and bridge only
        // its completion, without transferring NSRunningApplication.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([plan.commandURL], withApplicationAt: terminal, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(200))
            if let status = try? String(contentsOf: plan.exitURL), let code = Int32(status.trimmingCharacters(in: .whitespacesAndNewlines)), code != 0 {
                throw YConnectError.unsupported("Agent 启动后退出（状态 \(code)），请查看终端中的提示")
            }
            if FileManager.default.fileExists(atPath: plan.readyURL.path) {
                return plan.manifest.autoStart ? "Agent 进程已在新终端启动 · \(plan.manifest.model)" : "专用终端已就绪 · 输入 yconnect-agent 启动"
            }
        }
        throw YConnectError.unsupported("终端尚未确认启动，请查看终端窗口。启动请求两分钟后失效")
    }

    static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func cleanExpiredSecrets(in sessions: URL, now: Date = Date()) {
        let fm = FileManager.default
        for root in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard UUID(uuidString: root.lastPathComponent) != nil,
                  (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let pending = root.appendingPathComponent("session.json")
            let consumed = root.appendingPathComponent("consumed.json")
            guard let data = (try? Data(contentsOf: pending)) ?? (try? Data(contentsOf: consumed)),
                  let manifest = try? JSONDecoder().decode(AgentLaunchManifest.self, from: data), manifest.expiresAt < now else { continue }
            if let value = try? String(contentsOf: root.appendingPathComponent("ready")),
               let pid = Int32(value), kill(pid, 0) == 0 { continue }
            let secret = URL(fileURLWithPath: manifest.secretPath).resolvingSymlinksInPath()
            if secret.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") { try? fm.removeItem(at: secret) }
        }
    }
}

/// Runs before AppKit starts. Credentials travel in the child environment, never argv or shell history.
enum AgentSessionRunner {
    static func run(manifestURL: URL) -> Int32 {
        let root = manifestURL.deletingLastPathComponent()
        let exitURL = root.appendingPathComponent("exit-status")
        var secretURL: URL?
        var ownsSession = false
        defer { if let secretURL { try? FileManager.default.removeItem(at: secretURL) } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
            guard manifestURL.lastPathComponent == "session.json",
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw YConnectError.invalidResponse }
            let manifest = try JSONDecoder().decode(AgentLaunchManifest.self, from: Data(contentsOf: manifestURL))
            let secret = URL(fileURLWithPath: manifest.secretPath).resolvingSymlinksInPath()
            guard secret.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw YConnectError.invalidResponse }
            // Atomic consumption prevents a duplicate Terminal open from launching another agent.
            let consumed = root.appendingPathComponent("consumed.json")
            try FileManager.default.moveItem(at: manifestURL, to: consumed)
            ownsSession = true
            secretURL = secret
            guard manifest.expiresAt > Date() else { throw YConnectError.unsupported("启动请求已过期，请返回 Y CONNECT 重试") }
            let key = try YakCoolAPI.normalizedAPIKey(String(contentsOf: secret, encoding: .utf8))
            var variables = ProcessInfo.processInfo.environment
            for name in manifest.removeVariables { variables.removeValue(forKey: name) }
            for (name, value) in manifest.variables { variables[name] = value }
            variables["YCONNECT_API_KEY"] = key
            variables["PWD"] = manifest.directory
            let process = Process()
            process.currentDirectoryURL = URL(fileURLWithPath: manifest.directory, isDirectory: true)
            if manifest.autoStart {
                process.executableURL = URL(fileURLWithPath: manifest.executable)
                process.arguments = manifest.arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-d", "-i"]
                variables["ZDOTDIR"] = root.path
            }
            process.environment = variables
            print("Y CONNECT · \(manifest.clientID) · \(manifest.model)\n工作目录：\(manifest.directory)\n")
            // Foundation puts a child in its own process group. Give that group the
            // terminal, otherwise interactive reads stop it with SIGTTIN on macOS.
            let previousForeground = isatty(STDIN_FILENO) == 1 ? tcgetpgrp(STDIN_FILENO) : -1
            let previousTTOU = previousForeground >= 0 ? signal(SIGTTOU, SIG_IGN) : nil
            defer {
                if previousForeground >= 0 {
                    _ = tcsetpgrp(STDIN_FILENO, previousForeground)
                    _ = signal(SIGTTOU, previousTTOU)
                }
            }
            try process.run()
            if previousForeground >= 0 {
                guard tcsetpgrp(STDIN_FILENO, getpgid(process.processIdentifier)) == 0 else {
                    process.terminate()
                    throw YConnectError.unsupported("无法交接终端输入")
                }
                _ = kill(process.processIdentifier, SIGCONT)
            }
            try ClientLauncher.write(Data("\(process.processIdentifier)".utf8), to: root.appendingPathComponent("ready"))
            process.waitUntilExit()
            let code = process.terminationStatus
            try ClientLauncher.write(Data("\(code)".utf8), to: exitURL)
            if code != 0 { print("\nAgent 已退出（状态 \(code)）。请根据上方提示处理后，从 Y CONNECT 重试。") }
            return code
        } catch {
            if ownsSession || !FileManager.default.fileExists(atPath: root.appendingPathComponent("consumed.json").path) {
                try? ClientLauncher.write(Data("1".utf8), to: exitURL)
            }
            fputs("Y CONNECT 无法启动此会话，请返回控制面板重新启动。\n", stderr)
            return 1
        }
    }
}
