import AppKit
import Foundation

/// Opt-in integration check: fake credentials, temporary files, no account or network access.
enum TerminalLaunchSmoke {
    @MainActor
    static func run(bundleID: String) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("yconnect-terminal-smoke-\(UUID().uuidString) space 'quote $dollar 中文")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let applications = ClientLauncher.terminalApplications()
        guard applications[bundleID] != nil || bundleID == "fixture.missing-terminal" else {
            throw YConnectError.unsupported("Smoke terminal is not installed: \(bundleID)")
        }
        let executable = root.appendingPathComponent("fixture-agent")
        let marker = root.appendingPathComponent("passed")
        let fakeKey = "fake-terminal-smoke-key"
        let script = """
        #!/bin/zsh -f
        [[ -t 0 && -t 1 ]] || exit 40
        [[ "$YCONNECT_API_KEY" == \(ClientLauncher.shellQuote(fakeKey)) ]] || exit 41
        [[ "$YCONNECT_MODEL" == "fixture-model" ]] || exit 42
        [[ "$PWD" == \(ClientLauncher.shellQuote(root.resolvingSymlinksInPath().path)) ]] || exit 43
        print -r -- 'Y CONNECT terminal smoke: isolated model, key, directory and TTY verified'
        print -r -- PASS > \(ClientLauncher.shellQuote(marker.path))
        sleep 2
        """
        try ClientLauncher.write(Data(script.utf8), to: executable, permissions: 0o700)
        let runner = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let plan = try ClientLauncher.prepare(environment: .preview(at: root), clientID: .codex,
            model: ClientModelOption(id: "fixture-model", name: "Fixture", protocols: [.responses]),
            apiKey: fakeKey, directory: root.path, autoStart: true, executable: executable, runner: runner)
        let message = try await ClientLauncher.start(plan, preferredTerminalBundleID: bundleID)
        for _ in 0..<100 {
            if let status = try? String(contentsOf: plan.exitURL),
               !fm.fileExists(atPath: plan.manifest.secretPath) {
                guard status == "0", (try? String(contentsOf: marker)) == "PASS\n",
                      !fm.fileExists(atPath: plan.manifestURL.path) else {
                    throw YConnectError.unsupported("Terminal fixture failed")
                }
                print("PASS: \(bundleID), \(message), literal path, TTY, isolated credentials and cleanup")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw YConnectError.unsupported("Terminal fixture did not exit and clean its credential")
    }
}
