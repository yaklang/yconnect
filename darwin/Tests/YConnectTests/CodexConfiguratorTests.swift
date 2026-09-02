import Foundation
import XCTest
@testable import YConnect

final class CodexConfiguratorTests: XCTestCase {
    private var temporaryRoot: URL!
    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexConfiguratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        environment = .preview(at: temporaryRoot)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        environment = nil
        temporaryRoot = nil
    }

    func testCodexAcceptsResponsesOnlyAndRejectsOtherProtocolsWithoutWriting() throws {
        let codex = try CodexClientConfigurator(environment: environment)
        let models = [
            ClientModelOption(id: "response", name: "Response", protocols: [.responses]),
            ClientModelOption(id: "chat", name: "Chat", protocols: [.chatCompletions]),
            ClientModelOption(id: "messages", name: "Messages", protocols: [.anthropicMessages]),
            ClientModelOption(
                id: "all",
                name: "All",
                protocols: [.responses, .chatCompletions, .anthropicMessages]
            ),
        ]
        XCTAssertEqual(codex.compatibleModels(from: models).map(\.id), ["response", "all"])

        let invalid = ClientApplyRequest(apiKey: "codex-key", models: models, selectedModelID: "chat")
        XCTAssertThrowsError(try codex.preview(invalid)) { error in
            guard case ClientConfigurationError.invalidSelection = error else {
                return XCTFail("expected invalidSelection, got \(error)")
            }
        }
        XCTAssertThrowsError(try codex.apply(invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.backupsDirectory(for: .codex).path))
    }

    func testCodexPreviewApplyInspectIdempotenceAndRestoreKeepCredentialOutOfTOML() throws {
        let codex = try CodexClientConfigurator(environment: environment)
        let originalConfiguration = Data("""
        # keep this comment\r
        model = "old-one"\r
        model = "old-two" # duplicate managed root\r
        model_provider = "old-provider"\r
        \r
        [history]\r
        note = "keep # quoted hash"\r
        \r
        [model_providers.unrelated]\r
        api_key = "unrelated-codex-api-key"\r
        password = "unrelated-codex-password"\r
        \r
        [model_providers.unrelated.headers]\r
        Authorization = "Bearer unrelated-codex-authorization"\r
        x_company = "unrelated-codex-header-secret"\r
        \r
        [model_providers.yakcool]\r
        name = "Old"\r
        base_url = "https://old.invalid/v1"\r
        wire_api = "chat"\r
        env_key = "OLD_KEY"\r
        requires_openai_auth = true\r
        token = "old-inline-token"\r
        http_headers.Authorization = "Bearer stale-dotted-authorization"\r
        env_http_headers.Authorization = "STALE_AUTH_ENV"\r
        \r
        [model_providers.yakcool.http_headers]\r
        Authorization = "Bearer stale-child-authorization"\r
        \r
        [model_providers.yakcool.auth]\r
        command = "/bin/false"\r
        args = ["bad"]\r
        token = "old-auth-token"\r
        \r
        [[model_providers.yakcool]]\r
        preserved = true\r
        \r
        [model_providers.yakcooler]\r
        token = "keep-prefix-neighbour"\r
        """.utf8)
        let originalSecret = Data("old-codex-secret".utf8)
        try write(originalConfiguration, to: codex.configurationURL, permissions: 0o640)
        try write(originalSecret, to: codex.secretURL, permissions: 0o600)

        let apiKey = "codex-fake-secret-1fc59ac0"
        let modelID = "gpt-5#quoted\"model"
        let request = ClientApplyRequest(
            apiKey: apiKey,
            models: [ClientModelOption(id: modelID, name: "Codex Model", protocols: [.responses])],
            selectedModelID: modelID
        )

        let preview = try codex.preview(request)
        XCTAssertEqual(try Data(contentsOf: codex.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: codex.secretURL), originalSecret)
        assertCredentialAbsent(apiKey, from: preview)
        for secret in [
            "unrelated-codex-api-key",
            "unrelated-codex-password",
            "Bearer unrelated-codex-authorization",
            "unrelated-codex-header-secret",
        ] {
            assertCredentialAbsent(secret, from: preview)
        }
        let rendered = try XCTUnwrap(
            preview.changes.first(where: { $0.url == codex.configurationURL })?.renderedText
        )
        XCTAssertTrue(rendered.contains("model_provider = \"yakcool\""))
        XCTAssertTrue(rendered.contains("wire_api = \"responses\""))
        XCTAssertTrue(rendered.contains("command = \"/bin/cat\""))
        XCTAssertTrue(rendered.contains("args = [\"\(codex.secretURL.path)\"]"))
        XCTAssertTrue(rendered.contains("timeout_ms = 5000"))
        XCTAssertTrue(rendered.contains("refresh_interval_ms = 300000"))
        XCTAssertFalse(rendered.contains(apiKey))

        let first = try codex.apply(request)
        XCTAssertEqual(first.action, .applied)
        XCTAssertEqual(first.changedTargets, [codex.secretURL, codex.configurationURL])
        XCTAssertEqual(try Data(contentsOf: codex.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: codex.secretURL), 0o600)
        XCTAssertEqual(try permissions(of: codex.configurationURL), 0o600)

        let installedData = try Data(contentsOf: codex.configurationURL)
        let installed = try XCTUnwrap(String(data: installedData, encoding: .utf8))
        XCTAssertTrue(installed.contains("# keep this comment\r\n"))
        XCTAssertTrue(installed.contains("note = \"keep # quoted hash\"\r\n"))
        XCTAssertTrue(installed.contains("unrelated-codex-api-key"))
        XCTAssertTrue(installed.contains("unrelated-codex-password"))
        XCTAssertTrue(installed.contains("Bearer unrelated-codex-authorization"))
        XCTAssertTrue(installed.contains("unrelated-codex-header-secret"))
        XCTAssertFalse(installed.contains("[[model_providers.yakcool]]\r\n"))
        XCTAssertFalse(installed.contains("stale-dotted-authorization"))
        XCTAssertFalse(installed.contains("STALE_AUTH_ENV"))
        XCTAssertFalse(installed.contains("stale-child-authorization"))
        XCTAssertTrue(installed.contains("[model_providers.yakcooler]\r\n"))
        XCTAssertTrue(installed.contains("keep-prefix-neighbour"))
        XCTAssertFalse(installed.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertFalse(installed.contains(apiKey))
        XCTAssertEqual(installed.components(separatedBy: "[model_providers.yakcool]\r\n").count - 1, 1)
        XCTAssertEqual(installed.components(separatedBy: "[model_providers.yakcool.auth]\r\n").count - 1, 1)

        let document = try TOMLClientConfigurationDocument(data: installedData, label: "test")
        XCTAssertEqual(document.string(table: nil, key: "model"), modelID)
        XCTAssertEqual(document.string(table: nil, key: "model_provider"), CodexClientConfigurator.providerID)
        XCTAssertEqual(
            document.string(table: "model_providers.yakcool", key: "base_url"),
            CodexClientConfigurator.gatewayV1
        )
        XCTAssertEqual(document.string(table: "model_providers.yakcool", key: "wire_api"), "responses")
        XCTAssertFalse(document.hasAssignment(table: "model_providers.yakcool", key: "env_key"))
        XCTAssertFalse(document.hasAssignment(table: "model_providers.yakcool", key: "requires_openai_auth"))
        XCTAssertFalse(document.hasAssignment(table: "model_providers.yakcool", key: "token"))
        XCTAssertEqual(document.string(table: "model_providers.yakcool.auth", key: "command"), "/bin/cat")
        XCTAssertEqual(
            document.stringArray(table: "model_providers.yakcool.auth", key: "args"),
            [codex.secretURL.path]
        )
        XCTAssertEqual(document.integer(table: "model_providers.yakcool.auth", key: "timeout_ms"), 5_000)
        XCTAssertEqual(
            document.integer(table: "model_providers.yakcool.auth", key: "refresh_interval_ms"),
            300_000
        )
        XCTAssertFalse(document.hasAssignment(table: "model_providers.yakcool.auth", key: "token"))

        let status = try codex.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.selectedModelID, modelID)
        XCTAssertEqual(status.configuredModelIDs, [modelID])
        XCTAssertEqual(status.credentialProtection, .safeReference)
        XCTAssertTrue(status.issues.isEmpty)

        let manifest = try manifestText(for: first)
        for forbidden in [
            apiKey,
            "old-codex-secret",
            "old-inline-token",
            "OLD_KEY",
            "stale-dotted-authorization",
            "stale-child-authorization",
            "unrelated-codex-api-key",
            "Bearer unrelated-codex-authorization",
        ] {
            XCTAssertFalse(manifest.contains(forbidden), "manifest must contain metadata only")
        }

        let second = try codex.apply(request)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertTrue(second.changedTargets.isEmpty)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleBackups(for: .codex).count, 1)

        let restored = try codex.restoreLatest()
        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(restored.backupURL, first.backupURL)
        XCTAssertEqual(try Data(contentsOf: codex.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: codex.secretURL), originalSecret)
        XCTAssertEqual(try permissions(of: codex.configurationURL), 0o640)
        XCTAssertEqual(try permissions(of: codex.secretURL), 0o600)
    }

    func testCodexInspectReportsDriftForUnsafeAuthReference() throws {
        let codex = try CodexClientConfigurator(environment: environment)
        let configuration = Data("""
        model = "model"
        model_provider = "yakcool"

        [model_providers.yakcool]
        name = "YakCool"
        base_url = "https://aibalance.yaklang.com/v1"
        wire_api = "responses"

        [model_providers.yakcool.auth]
        command = "/bin/cat"
        args = ["/tmp/not-yconnect"]
        timeout_ms = 5000
        refresh_interval_ms = 300000
        """.utf8)
        try write(configuration, to: codex.configurationURL, permissions: 0o600)
        try write(Data("secret".utf8), to: codex.secretURL, permissions: 0o600)

        let status = try codex.inspect()
        XCTAssertEqual(status.state, .drifted)
        XCTAssertEqual(status.credentialProtection, .managedFileSecure)
        XCTAssertTrue(status.issues.contains(where: { $0.contains("命令认证") }))
    }

    func testCodexInspectReportsDriftForStaleAuthorizationChild() throws {
        let codex = try CodexClientConfigurator(environment: environment)
        let configuration = Data("""
        model = "model"
        model_provider = "yakcool"

        [model_providers.yakcool]
        name = "YakCool"
        base_url = "https://aibalance.yaklang.com/v1"
        wire_api = "responses"

        [model_providers.yakcool.auth]
        command = "/bin/cat"
        args = ["\(codex.secretURL.path)"]
        timeout_ms = 5000
        refresh_interval_ms = 300000

        [model_providers.yakcool.http_headers]
        Authorization = "Bearer stale-static-secret"
        """.utf8)
        try write(configuration, to: codex.configurationURL, permissions: 0o600)
        try write(Data("secret".utf8), to: codex.secretURL, permissions: 0o600)

        let status = try codex.inspect()
        XCTAssertEqual(status.state, .drifted)
        XCTAssertEqual(status.credentialProtection, .unexpectedInline)
        XCTAssertTrue(status.issues.contains(where: { $0.contains("子表") }))
    }

    func testCodexPreviewRejectsAncestorInlineProviderWithoutWriting() throws {
        let codex = try CodexClientConfigurator(environment: environment)
        let original = Data("""
        model_providers = { yakcool = { token = "stale" }, other = { name = "keep" } }
        """.utf8)
        try write(original, to: codex.configurationURL, permissions: 0o600)
        let request = ClientApplyRequest(
            apiKey: "codex-key",
            models: [ClientModelOption(id: "model", name: "Model", protocols: [.responses])],
            selectedModelID: "model"
        )

        let status = try codex.inspect()
        XCTAssertEqual(status.state, .invalid)
        XCTAssertEqual(status.credentialProtection, .unexpectedInline)
        XCTAssertThrowsError(try codex.preview(request)) { error in
            XCTAssertEqual(
                error as? TOMLConfigurationEditorError,
                .conflictingAncestorAssignment("model_providers")
            )
        }
        XCTAssertEqual(try Data(contentsOf: codex.configurationURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.secretURL.path))
    }

    func testCodexPreviewBoundsChecksGeneratedConfiguration() throws {
        let codex = try CodexClientConfigurator(environment: environment)
        let oversizedModelID = "oversized-marker-" + String(
            repeating: "m",
            count: 16 * 1_024 * 1_024
        )
        let request = ClientApplyRequest(
            apiKey: "codex-key",
            models: [
                ClientModelOption(
                    id: oversizedModelID,
                    name: "Oversized",
                    protocols: [.responses]
                ),
            ],
            selectedModelID: oversizedModelID
        )

        XCTAssertThrowsError(try codex.preview(request)) { error in
            guard case ConfigurationTransactionError.fileTooLarge(let path, let maximum) = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
            XCTAssertEqual(path, codex.configurationURL.path)
            XCTAssertEqual(maximum, 16 * 1_024 * 1_024)
            XCTAssertFalse(error.localizedDescription.contains("oversized-marker"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.secretURL.path))
    }

    private func write(_ data: Data, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func manifestText(for result: ClientConfigurationResult) throws -> String {
        let backup = try XCTUnwrap(result.backupURL)
        return try XCTUnwrap(String(
            data: Data(contentsOf: backup.appendingPathComponent("manifest.json")),
            encoding: .utf8
        ))
    }

    private func assertCredentialAbsent(
        _ credential: String,
        from preview: ClientConfigurationPreview,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(String(describing: preview).contains(credential), file: file, line: line)
        for change in preview.changes {
            XCTAssertFalse(change.renderedText?.contains(credential) == true, file: file, line: line)
            if change.role == .credential { XCTAssertNil(change.renderedText, file: file, line: line) }
        }
    }

    private func visibleBackups(for clientID: ClientID) throws -> [URL] {
        let directory = environment.backupsDirectory(for: clientID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
