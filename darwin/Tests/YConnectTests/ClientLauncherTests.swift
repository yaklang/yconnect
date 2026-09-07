import Foundation
import XCTest
@testable import YConnect

final class ClientLauncherTests: XCTestCase {
    private let key = "fake-launcher-key-do-not-use"
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YConnectLaunchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func plan(_ root: URL, id: ClientID = .codex, modelID: String = "test-model", auto: Bool = true, executable: URL? = nil, directory: String? = nil) throws -> AgentLaunchPlan {
        try ClientLauncher.prepare(environment: .preview(at: root), clientID: id,
            model: ClientModelOption(id: modelID, name: "Test Model", protocols: [.responses, .anthropicMessages, .chatCompletions]),
            apiKey: key, directory: directory ?? root.path, autoStart: auto,
            executable: executable ?? URL(fileURLWithPath: "/bin/echo"), runner: URL(fileURLWithPath: "/bin/echo"))
    }

    func testAllCLIClientsHaveIsolatedConfigurationsWithoutInlineCredentials() throws {
        let root = try root()
        for id in [ClientID.codex, .openCode, .claudeCode, .pi, .grokBuild, .hermes, .openClaw] {
            let plan = try plan(root, id: id, auto: id != .openClaw)
            let contents = try String(contentsOf: plan.manifestURL)
            XCTAssertFalse(contents.contains(key)); XCTAssertFalse(plan.manifest.arguments.contains(key))
            let mode = try FileManager.default.attributesOfItem(atPath: plan.root.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700)
            XCTAssertEqual(try String(contentsOfFile: plan.manifest.secretPath), key)
            let files = FileManager.default.enumerator(at: plan.root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in files {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
                XCTAssertEqual(mode.intValue & 0o077, 0, url.path)
                if url.resolvingSymlinksInPath().path != URL(fileURLWithPath: plan.manifest.secretPath).resolvingSymlinksInPath().path {
                    XCTAssertFalse((try? String(contentsOf: url).contains(key)) ?? false, "Key in non-credential file: \(url.lastPathComponent)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/config.toml").path))
    }

    func testSessionsKeepDifferentModelsAndSecretsIndependent() throws {
        let root = try root()
        let first = try plan(root, modelID: "first-model")
        let second = try plan(root, modelID: "second-model")
        XCTAssertNotEqual(first.root, second.root)
        XCTAssertNotEqual(first.manifest.secretPath, second.manifest.secretPath)
        XCTAssertTrue(first.manifest.arguments.contains("first-model"))
        XCTAssertTrue(second.manifest.arguments.contains("second-model"))
        XCTAssertNotEqual(first.manifest.arguments[3], second.manifest.arguments[3])
    }

    func testRejectsBadModelsDirectoriesAndUnsupportedAutomaticLaunch() throws {
        let root = try root()
        for model in ["$(touch nope)", "model;echo", "x\n", "-option"] {
            XCTAssertThrowsError(try plan(root, modelID: model))
        }
        XCTAssertThrowsError(try plan(root, directory: root.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try plan(root, directory: "relative"))
        XCTAssertThrowsError(try plan(root, id: .claudeDesktop))
        XCTAssertThrowsError(try plan(root, id: .openClaw))
    }

    func testRunnerPassesLiteralArgumentsEnvironmentAndDirectoryThenDeletesSecret() throws {
        let root = try root()
        let directory = root.appendingPathComponent("space 'quote $dollar `tick` 中文")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake agent.sh")
        let output = root.appendingPathComponent("observed")
        let script = "#!/bin/sh\n[ \"$YCONNECT_API_KEY\" = \(ClientLauncher.shellQuote(key)) ] || exit 41\n[ \"$YCONNECT_MODEL\" = 'test-model' ] || exit 42\n[ \"$PWD\" = \(ClientLauncher.shellQuote(directory.resolvingSymlinksInPath().path)) ] || exit 43\nprintf '%s\\n' \"$@\" > \(ClientLauncher.shellQuote(output.path))\n"
        try ClientLauncher.write(Data(script.utf8), to: executable, permissions: 0o700)
        let plan = try plan(root, executable: executable, directory: directory.path)
        XCTAssertEqual(AgentSessionRunner.run(manifestURL: plan.manifestURL), 0)
        XCTAssertEqual(try String(contentsOf: output).components(separatedBy: "\n").dropLast(), ArraySlice(plan.manifest.arguments))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.manifest.secretPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.readyURL.path))
        XCTAssertEqual(AgentSessionRunner.run(manifestURL: plan.manifestURL), 1, "Consumed launch must not run again")
        XCTAssertEqual(try String(contentsOf: plan.exitURL), "0", "Duplicate open must not overwrite the original launch status")
    }

    func testClientFailureIsRecordedAndStillCleansCredentials() throws {
        let root = try root()
        let executable = root.appendingPathComponent("fail.sh")
        try ClientLauncher.write(Data("#!/bin/sh\nexit 37\n".utf8), to: executable, permissions: 0o700)
        let plan = try plan(root, executable: executable)
        XCTAssertEqual(AgentSessionRunner.run(manifestURL: plan.manifestURL), 37)
        XCTAssertEqual(try String(contentsOf: plan.exitURL), "37")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.manifest.secretPath))
    }

    func testClaudeSessionClearsCompetingAuthAndUsesExplicitSettings() throws {
        let plan = try plan(root(), id: .claudeCode)
        XCTAssertTrue(plan.manifest.removeVariables.contains("ANTHROPIC_API_KEY"))
        XCTAssertTrue(plan.manifest.removeVariables.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        XCTAssertEqual(plan.manifest.variables["CLAUDE_CODE_USE_BEDROCK"], "0")
        XCTAssertEqual(plan.manifest.variables["ANTHROPIC_DEFAULT_SONNET_MODEL"], "test-model")
        XCTAssertEqual(Array(plan.manifest.arguments.prefix(2)), ["--setting-sources", ""])
    }

    func testExpiredUnstartedSessionsCleanOnlyTheirOwnSecrets() throws {
        let root = try root(); let plan = try plan(root)
        ClientLauncher.cleanExpiredSecrets(in: plan.root.deletingLastPathComponent(), now: Date().addingTimeInterval(121))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.manifest.secretPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.manifestURL.path))
    }

    func testTerminalOnlyDefinesModelBoundCommandWithoutSecrets() throws {
        let plan = try plan(root(), auto: false)
        let script = try String(contentsOf: plan.root.appendingPathComponent(".zshrc"))
        XCTAssertTrue(script.contains("function yconnect-agent()"))
        XCTAssertTrue(script.contains("test-model")); XCTAssertFalse(script.contains(key))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", plan.commandURL.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testInstalledOpenCodeReadsSessionOverrideWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["YCONNECT_RUN_LAUNCHER_INTEGRATION"] == "1" else { throw XCTSkip("Opt-in installed CLI check") }
        let root = try root()
        let cli = try XCTUnwrap(DefaultClientInstallationDetector().executableURL(for: .openCode))
        let plan = try plan(root, id: .openCode, executable: cli)
        var env = ProcessInfo.processInfo.environment
        for (name, value) in plan.manifest.variables { env[name] = value }
        env["YCONNECT_API_KEY"] = key
        for name in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "OPENCODE_CONFIG_DIR"] {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); env[name] = path.path
        }
        env.removeValue(forKey: "OPENCODE_CONFIG")
        env["NO_COLOR"] = "1"
        let output = root.appendingPathComponent("resolved.json")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = cli
        process.arguments = ["debug", "config", "--pure"]
        process.currentDirectoryURL = root; process.environment = env
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        let requested = try JSONSerialization.jsonObject(with: Data(plan.manifest.variables["OPENCODE_CONFIG_CONTENT"]!.utf8)) as! [String: Any]
        XCTAssertEqual(config["model"] as? String, requested["model"] as? String)
        let providerID = (config["model"] as! String).components(separatedBy: "/")[0]
        let providers = config["provider"] as! [String: Any]
        let provider = providers[providerID] as! [String: Any]
        let options = provider["options"] as! [String: Any]
        XCTAssertEqual(options["baseURL"] as? String, "https://aibalance.yaklang.com/v1")
        XCTAssertEqual(options["apiKey"] as? String, key)
    }
}
