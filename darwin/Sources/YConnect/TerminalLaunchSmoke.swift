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
        sleep 4
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
        let status = (try? String(contentsOf: plan.exitURL)) ?? "missing"
        let markerWritten = fm.fileExists(atPath: marker.path)
        let secretPresent = fm.fileExists(atPath: plan.manifest.secretPath)
        reportSessionProcesses(plan)
        throw YConnectError.unsupported("Terminal fixture did not exit and clean its credential (exit=\(status), marker=\(markerWritten), secret=\(secretPresent))")
    }

    /// Only this opt-in, fake-credential fixture emits process diagnostics.
    private static func reportSessionProcesses(_ plan: AgentLaunchPlan) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid,ppid,pgid,tpgid,stat,sigmask,command"]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let child = (try? String(contentsOf: plan.readyURL)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var selected = Set<Int32>()
        if let child { selected.insert(child) }
        for row in rows where row.contains(plan.root.lastPathComponent) {
            if let pid = row.split(whereSeparator: { $0.isWhitespace }).first.flatMap({ Int32($0) }) { selected.insert(pid) }
        }
        for _ in 0..<4 {
            for row in rows {
                let fields = row.split(whereSeparator: { $0.isWhitespace })
                if fields.count > 1, let pid = Int32(fields[0]), let parent = Int32(fields[1]), selected.contains(parent) { selected.insert(pid) }
            }
        }
        print("Fixture processes (agent PID \(child ?? -1), \(rows.count) rows): PID PPID PGID TPGID STAT SIGMASK COMMAND")
        for row in rows {
            if let pid = row.split(whereSeparator: { $0.isWhitespace }).first.flatMap({ Int32($0) }), selected.contains(pid) { print(row) }
        }
    }
}
