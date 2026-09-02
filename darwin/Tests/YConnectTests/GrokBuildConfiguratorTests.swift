import Foundation
import XCTest
@testable import YConnect

final class GrokBuildConfiguratorTests: XCTestCase {
    private var temporaryRoot: URL!
    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokBuildConfiguratorTests-\(UUID().uuidString)", isDirectory: true)
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

    func testGrokSelectsResponsesThenMessagesThenChatCompletions() throws {
        let grok = try GrokBuildClientConfigurator(environment: environment)
        let cases: [(Set<AIProtocol>, String)] = [
            ([.responses, .anthropicMessages, .chatCompletions], "responses"),
            ([.anthropicMessages, .chatCompletions], "messages"),
            ([.chatCompletions], "chat_completions"),
        ]

        for (offset, item) in cases.enumerated() {
            let modelID = "model-\(offset)"
            let request = ClientApplyRequest(
                apiKey: "grok-protocol-key",
                models: [ClientModelOption(id: modelID, name: "Model \(offset)", protocols: item.0)],
                selectedModelID: modelID
            )
            let preview = try grok.preview(request)
            let rendered = try XCTUnwrap(
                preview.changes.first(where: { $0.url == grok.configurationURL })?.renderedText
            )
            let document = try TOMLClientConfigurationDocument(
                data: Data(rendered.utf8),
                label: "preview"
            )
            XCTAssertEqual(document.string(table: "model.yakcool", key: "api_backend"), item.1)
            XCTAssertEqual(
                document.string(table: "model.yakcool", key: "base_url"),
                GrokBuildClientConfigurator.gatewayV1,
                "Grok Build appends the backend path itself, so every backend needs the /v1 base"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: grok.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: grok.secretURL.path))
    }

    func testGrokPreviewApplyInspectIdempotenceAndRestorePreserveUnknownTOML() throws {
        let grok = try GrokBuildClientConfigurator(environment: environment)
        let originalConfiguration = Data("""
        # preserve Grok settings\r
        [models]\r
        default = "old"\r
        web_search = "keep-search"\r
        \r
        [model.yakcool]\r
        model = "old-model"\r
        base_url = "https://old.invalid/v1"\r
        name = "Old YakCool"\r
        api_backend = "chat_completions"\r
        api_key = "old-inline-api-key"\r
        env_key = "OLD_GROK_KEY"\r
        auth_provider = "old-auth"\r
        http_headers.Authorization = "Bearer stale-grok-dotted"\r
        \r
        [model.yakcool.http_headers]\r
        Authorization = "Bearer stale-grok-child"\r
        \r
        [auth_provider.yconnect]\r
        command = "/bin/false"\r
        args = ["bad"]\r
        token = "old-inline-token"\r
        \r
        [auth_provider.yconnect.aws]\r
        token = "stale-aws-token"\r
        \r
        [ui]\r
        title = "keep # quoted hash"\r
        \r
        [model.other]\r
        api_key = "unrelated-grok-api-key"\r
        password = "unrelated-grok-password"\r
        \r
        [model.other.headers]\r
        Authorization = "Bearer unrelated-grok-authorization"\r
        x_company = "unrelated-grok-header-secret"\r
        \r
        [[model.yakcool]]\r
        future = "keep-array-table"\r
        \r
        [model.yakcooler]\r
        token = "keep-prefix-neighbour"\r
        """.utf8)
        let originalSecret = Data("old-grok-secret".utf8)
        try write(originalConfiguration, to: grok.configurationURL, permissions: 0o640)
        try write(originalSecret, to: grok.secretURL, permissions: 0o600)

        let apiKey = "grok-fake-secret-6b815c41"
        let modelID = "claude#proxy\"model"
        let modelName = "Messages \"Bridge\""
        let request = ClientApplyRequest(
            apiKey: apiKey,
            models: [
                ClientModelOption(
                    id: modelID,
                    name: modelName,
                    protocols: [.anthropicMessages, .chatCompletions]
                ),
            ],
            selectedModelID: modelID
        )

        let preview = try grok.preview(request)
        XCTAssertEqual(try Data(contentsOf: grok.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: grok.secretURL), originalSecret)
        assertCredentialAbsent(apiKey, from: preview)
        for secret in [
            "unrelated-grok-api-key",
            "unrelated-grok-password",
            "Bearer unrelated-grok-authorization",
            "unrelated-grok-header-secret",
        ] {
            assertCredentialAbsent(secret, from: preview)
        }
        let rendered = try XCTUnwrap(
            preview.changes.first(where: { $0.url == grok.configurationURL })?.renderedText
        )
        XCTAssertTrue(rendered.contains("default = \"yakcool\""))
        XCTAssertTrue(rendered.contains("api_backend = \"messages\""))
        XCTAssertTrue(rendered.contains("auth_provider = \"yconnect\""))
        XCTAssertTrue(rendered.contains("command = \"/bin/cat\""))
        XCTAssertTrue(rendered.contains("timeout_secs = 5"))
        XCTAssertFalse(rendered.contains(apiKey))

        let first = try grok.apply(request)
        XCTAssertEqual(first.action, .applied)
        XCTAssertEqual(first.changedTargets, [grok.secretURL, grok.configurationURL])
        XCTAssertEqual(try Data(contentsOf: grok.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: grok.secretURL), 0o600)
        XCTAssertEqual(try permissions(of: grok.configurationURL), 0o600)

        let installedData = try Data(contentsOf: grok.configurationURL)
        let installed = try XCTUnwrap(String(data: installedData, encoding: .utf8))
        XCTAssertTrue(installed.contains("# preserve Grok settings\r\n"))
        XCTAssertTrue(installed.contains("web_search = \"keep-search\"\r\n"))
        XCTAssertTrue(installed.contains("title = \"keep # quoted hash\"\r\n"))
        XCTAssertTrue(installed.contains("unrelated-grok-api-key"))
        XCTAssertTrue(installed.contains("unrelated-grok-password"))
        XCTAssertTrue(installed.contains("Bearer unrelated-grok-authorization"))
        XCTAssertTrue(installed.contains("unrelated-grok-header-secret"))
        XCTAssertFalse(installed.contains("[[model.yakcool]]\r\n"))
        XCTAssertFalse(installed.contains("future = \"keep-array-table\""))
        XCTAssertFalse(installed.contains("stale-grok-dotted"))
        XCTAssertFalse(installed.contains("stale-grok-child"))
        XCTAssertFalse(installed.contains("stale-aws-token"))
        XCTAssertTrue(installed.contains("[model.yakcooler]\r\n"))
        XCTAssertTrue(installed.contains("keep-prefix-neighbour"))
        XCTAssertFalse(installed.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertFalse(installed.contains(apiKey))
        XCTAssertEqual(installed.components(separatedBy: "[model.yakcool]\r\n").count - 1, 1)
        XCTAssertEqual(installed.components(separatedBy: "[auth_provider.yconnect]\r\n").count - 1, 1)

        let document = try TOMLClientConfigurationDocument(data: installedData, label: "test")
        XCTAssertEqual(document.string(table: "models", key: "default"), "yakcool")
        XCTAssertEqual(document.string(table: "models", key: "web_search"), "keep-search")
        XCTAssertEqual(document.string(table: "model.yakcool", key: "model"), modelID)
        XCTAssertEqual(document.string(table: "model.yakcool", key: "base_url"), GrokBuildClientConfigurator.gatewayV1)
        XCTAssertEqual(document.string(table: "model.yakcool", key: "name"), "YakCool · \(modelName)")
        XCTAssertEqual(document.string(table: "model.yakcool", key: "api_backend"), "messages")
        XCTAssertEqual(document.string(table: "model.yakcool", key: "auth_provider"), "yconnect")
        XCTAssertFalse(document.hasAssignment(table: "model.yakcool", key: "api_key"))
        XCTAssertFalse(document.hasAssignment(table: "model.yakcool", key: "env_key"))
        XCTAssertEqual(document.string(table: "auth_provider.yconnect", key: "command"), "/bin/cat")
        XCTAssertEqual(
            document.stringArray(table: "auth_provider.yconnect", key: "args"),
            [grok.secretURL.path]
        )
        XCTAssertEqual(document.integer(table: "auth_provider.yconnect", key: "token_ttl_secs"), 300)
        XCTAssertEqual(document.integer(table: "auth_provider.yconnect", key: "timeout_secs"), 5)
        XCTAssertFalse(document.hasAssignment(table: "auth_provider.yconnect", key: "token"))

        let status = try grok.inspect()
        XCTAssertEqual(status.state, .configured)
        XCTAssertEqual(status.selectedModelID, modelID)
        XCTAssertEqual(status.configuredModelIDs, [modelID])
        XCTAssertEqual(status.credentialProtection, .safeReference)
        XCTAssertTrue(status.issues.isEmpty)

        let manifest = try manifestText(for: first)
        for forbidden in [
            apiKey,
            "old-grok-secret",
            "old-inline-api-key",
            "OLD_GROK_KEY",
            "stale-grok-dotted",
            "stale-grok-child",
            "stale-aws-token",
            "unrelated-grok-api-key",
            "Bearer unrelated-grok-authorization",
        ] {
            XCTAssertFalse(manifest.contains(forbidden), "manifest must contain metadata only")
        }

        let second = try grok.apply(request)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertTrue(second.changedTargets.isEmpty)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleBackups(for: .grokBuild).count, 1)

        let restored = try grok.restoreLatest()
        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(restored.backupURL, first.backupURL)
        XCTAssertEqual(try Data(contentsOf: grok.configurationURL), originalConfiguration)
        XCTAssertEqual(try Data(contentsOf: grok.secretURL), originalSecret)
        XCTAssertEqual(try permissions(of: grok.configurationURL), 0o640)
        XCTAssertEqual(try permissions(of: grok.secretURL), 0o600)
    }

    func testGrokRejectsUnsupportedSelectionAndReportsMissingManagedSecret() throws {
        let grok = try GrokBuildClientConfigurator(environment: environment)
        let request = ClientApplyRequest(
            apiKey: "grok-key",
            models: [
                ClientModelOption(
                    id: "unsupported",
                    name: "Unsupported",
                    protocols: [AIProtocol(rawValue: "gemini_native")]
                ),
            ],
            selectedModelID: "unsupported"
        )
        XCTAssertThrowsError(try grok.apply(request)) { error in
            guard case ClientConfigurationError.invalidSelection = error else {
                return XCTFail("expected invalidSelection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: grok.configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: grok.secretURL.path))

        let safeLookingConfiguration = Data("""
        [models]
        default = "yakcool"

        [model.yakcool]
        model = "model"
        base_url = "https://aibalance.yaklang.com/v1"
        name = "YakCool · Model"
        api_backend = "responses"
        auth_provider = "yconnect"

        [auth_provider.yconnect]
        command = "/bin/cat"
        args = ["\(grok.secretURL.path)"]
        token_ttl_secs = 300
        timeout_secs = 5
        """.utf8)
        try write(safeLookingConfiguration, to: grok.configurationURL, permissions: 0o600)
        let status = try grok.inspect()
        XCTAssertEqual(status.state, .drifted)
        XCTAssertEqual(status.credentialProtection, .missing)
        XCTAssertTrue(status.issues.contains(where: { $0.contains("缺失") }))
    }

    func testGrokInspectReportsDriftForManagedDottedAuthorization() throws {
        let grok = try GrokBuildClientConfigurator(environment: environment)
        let configuration = Data("""
        [models]
        default = "yakcool"

        [model.yakcool]
        model = "model"
        base_url = "https://aibalance.yaklang.com/v1"
        name = "YakCool · Model"
        api_backend = "responses"
        auth_provider = "yconnect"
        http_headers.Authorization = "Bearer stale-static-secret"

        [auth_provider.yconnect]
        command = "/bin/cat"
        args = ["\(grok.secretURL.path)"]
        token_ttl_secs = 300
        timeout_secs = 5
        """.utf8)
        try write(configuration, to: grok.configurationURL, permissions: 0o600)
        try write(Data("secret".utf8), to: grok.secretURL, permissions: 0o600)

        let status = try grok.inspect()
        XCTAssertEqual(status.state, .drifted)
        XCTAssertEqual(status.credentialProtection, .unexpectedInline)
        XCTAssertTrue(status.issues.contains(where: { $0.contains("dotted") }))
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
