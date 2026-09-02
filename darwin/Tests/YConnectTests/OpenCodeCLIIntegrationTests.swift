import Foundation
import XCTest
@testable import YConnect

final class OpenCodeCLIIntegrationTests: XCTestCase {
    func testInstalledOpenCodeAcceptsGeneratedConfigurationWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["YCONNECT_RUN_OPENCODE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set YCONNECT_RUN_OPENCODE_INTEGRATION=1 to validate against an installed OpenCode CLI")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectOpenCodeCLI-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("empty-project", isDirectory: true)
        let openCodeDirectory = root.appendingPathComponent("empty-opencode-dir", isDirectory: true)
        let configurationURL = home
            .appendingPathComponent(".config/opencode", isDirectory: true)
            .appendingPathComponent("opencode.json")
        let supportURL = home
            .appendingPathComponent("Library/Application Support/YConnect", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)

        let configurator = OpenCodeConfigurator(
            configurationURL: configurationURL,
            applicationSupportDirectory: supportURL
        )
        _ = try configurator.apply(
            apiKey: "mf-yconnect-integration-fake",
            models: [OpenCodeModelOption(id: "integration-model", name: "Integration Model")],
            selectedModelID: "integration-model"
        )

        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["opencode", "debug", "config", "--pure"]
        process.currentDirectoryURL = project
        process.standardOutput = standardOutput
        process.standardError = standardError
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config", isDirectory: true).path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data", isDirectory: true).path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache", isDirectory: true).path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state", isDirectory: true).path
        environment["OPENCODE_CONFIG"] = configurationURL.path
        environment["OPENCODE_CONFIG_DIR"] = openCodeDirectory.path
        environment["NO_COLOR"] = "1"
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput + output, as: UTF8.self)
            return XCTFail("OpenCode rejected the generated configuration: \(message)")
        }

        let resolved = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: output) as? [String: Any],
            "OpenCode debug config did not return a JSON object"
        )
        XCTAssertEqual(resolved["model"] as? String, "yakcool/integration-model")
        let providers = try XCTUnwrap(resolved["provider"] as? [String: Any])
        let yakcool = try XCTUnwrap(providers["yakcool"] as? [String: Any])
        XCTAssertEqual(yakcool["npm"] as? String, "@ai-sdk/openai-compatible")
        let options = try XCTUnwrap(yakcool["options"] as? [String: Any])
        XCTAssertEqual(options["baseURL"] as? String, "https://aibalance.yaklang.com/v1")
        let models = try XCTUnwrap(yakcool["models"] as? [String: Any])
        XCTAssertNotNil(models["integration-model"])

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: configurator.secretURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(permissions, 0o600)
    }
}
