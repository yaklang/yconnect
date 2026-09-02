import Foundation
import XCTest
@testable import YConnect

final class OpenCodeConfiguratorTests: XCTestCase {
    private var temporaryRoot: URL!
    private var configurationURL: URL!
    private var supportURL: URL!
    private var configurator: OpenCodeConfigurator!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("YConnectTests-\(UUID().uuidString)", isDirectory: true)
        configurationURL = temporaryRoot
            .appendingPathComponent("home/.config/opencode/opencode.json", isDirectory: false)
        supportURL = temporaryRoot
            .appendingPathComponent("home/Library/Application Support/YConnect", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        configurator = OpenCodeConfigurator(
            configurationURL: configurationURL,
            applicationSupportDirectory: supportURL
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot,
           FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        configurator = nil
        supportURL = nil
        configurationURL = nil
        temporaryRoot = nil
    }

    func testApplyAcceptsJSONCAndPreservesUnknownFieldsAndOtherProviders() throws {
        let original = """
        {
          // OpenCode accepts JSON with comments.
          "$schema": "https://opencode.ai/config.json",
          "theme": "solarized",
          "features": {
            "nested": [1, 2, 3,],
            "url": "https://example.invalid/a//b",
            "comment_text": "/* this is data, not a comment */",
            "escaped_quote": "say \\\"hello // still data\\\"",
          },
          "provider": {
            "existing": {
              "npm": "@example/provider",
              "options": {
                "baseURL": "https://example.invalid/v1", // must survive
              },
            },
          },
        }
        """
        try Data(original.utf8).write(to: configurationURL)

        let apiKey = "test-key-that-is-never-a-real-credential"
        let result = try configurator.apply(
            apiKey: apiKey,
            models: [
                OpenCodeModelOption(id: "model-b", name: "Model B"),
                OpenCodeModelOption(id: "model-a", name: "Model A"),
            ],
            selectedModelID: "model-a"
        )

        XCTAssertEqual(result.action, .applied)
        XCTAssertEqual(result.modelID, "model-a")
        XCTAssertFalse(result.createdConfig)
        XCTAssertTrue(result.changed)
        XCTAssertNotNil(result.backupURL)

        let writtenData = try Data(contentsOf: configurationURL)
        let writtenText = try XCTUnwrap(String(data: writtenData, encoding: .utf8))
        XCTAssertFalse(writtenText.contains(apiKey), "API Key must never be embedded in opencode.json")

        let root = try jsonObject(at: configurationURL)
        XCTAssertEqual(root["theme"] as? String, "solarized")
        let features = try XCTUnwrap(root["features"] as? [String: Any])
        XCTAssertEqual(features["nested"] as? [Int], [1, 2, 3])
        XCTAssertEqual(features["url"] as? String, "https://example.invalid/a//b")
        XCTAssertEqual(features["comment_text"] as? String, "/* this is data, not a comment */")
        XCTAssertEqual(features["escaped_quote"] as? String, "say \"hello // still data\"")

        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        let existing = try XCTUnwrap(providers["existing"] as? [String: Any])
        XCTAssertEqual(existing["npm"] as? String, "@example/provider")
        let provider = try XCTUnwrap(providers["yakcool"] as? [String: Any])
        XCTAssertEqual(provider["npm"] as? String, "@ai-sdk/openai-compatible")
        let options = try XCTUnwrap(provider["options"] as? [String: Any])
        XCTAssertEqual(options["baseURL"] as? String, "https://aibalance.yaklang.com/v1")
        XCTAssertEqual(options["apiKey"] as? String, "{file:\(configurator.secretURL.path)}")
        let modelMap = try XCTUnwrap(provider["models"] as? [String: Any])
        XCTAssertEqual(Set(modelMap.keys), ["model-a", "model-b"])
        XCTAssertEqual(root["model"] as? String, "yakcool/model-a")

        XCTAssertEqual(try Data(contentsOf: configurator.secretURL), Data(apiKey.utf8))
        XCTAssertEqual(try permissions(of: configurator.secretURL) & 0o777, 0o600)
        XCTAssertEqual(try permissions(of: try XCTUnwrap(result.backupURL)) & 0o777, 0o700)

        let backupConfig = try XCTUnwrap(result.backupURL)
            .appendingPathComponent("opencode.json")
        XCTAssertEqual(try Data(contentsOf: backupConfig), Data(original.utf8))
        for backupFile in try directoryEntries(at: try XCTUnwrap(result.backupURL)) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: backupFile.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else { continue }
            XCTAssertFalse(
                try Data(contentsOf: backupFile).range(of: Data(apiKey.utf8)) != nil,
                "The new API Key must not leak into its pre-write backup"
            )
        }

        let status = try configurator.inspect()
        XCTAssertTrue(status.providerConfigured)
        XCTAssertTrue(status.secretReferenceIsSafe)
        XCTAssertTrue(status.secretExists)
        XCTAssertEqual(status.selectedModelID, "model-a")
        XCTAssertEqual(status.configuredModelIDs, ["model-a", "model-b"])
    }

    func testApplyIsIdempotentAndDoesNotCreateAnotherBackup() throws {
        let first = try configurator.apply(
            apiKey: "test-idempotent-key",
            models: [OpenCodeModelOption(id: "model-one", name: "Model One")],
            selectedModelID: "model-one"
        )
        let firstConfiguration = try Data(contentsOf: configurationURL)
        let backupCount = try visibleBackupDirectories().count

        let second = try configurator.apply(
            apiKey: "test-idempotent-key",
            models: [OpenCodeModelOption(id: "model-one", name: "Model One")],
            selectedModelID: "model-one"
        )

        XCTAssertEqual(first.action, .applied)
        XCTAssertTrue(first.createdConfig)
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertFalse(second.createdConfig)
        XCTAssertFalse(second.changed)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try Data(contentsOf: configurationURL), firstConfiguration)
        XCTAssertEqual(try visibleBackupDirectories().count, backupCount)
    }

    func testRestoreLatestRestoresOriginalConfigAndSecretExactly() throws {
        let originalConfig = Data("""
        {
          // Preserve this formatting byte-for-byte on restore.
          "model": "old-provider/old-model",
          "provider": { "old-provider": { "npm": "old-package", }, },
        }
        """.utf8)
        let originalSecret = Data("previous-test-secret".utf8)
        try originalConfig.write(to: configurationURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: configurationURL.path
        )
        try FileManager.default.createDirectory(
            at: configurator.secretURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalSecret.write(to: configurator.secretURL)

        let applied = try configurator.apply(
            apiKey: "replacement-test-secret",
            models: [OpenCodeModelOption(id: "selected-model", name: "Selected Model")],
            selectedModelID: "selected-model"
        )
        XCTAssertNotEqual(try Data(contentsOf: configurationURL), originalConfig)
        XCTAssertNotEqual(try Data(contentsOf: configurator.secretURL), originalSecret)

        let restored = try configurator.restoreLatest()

        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(restored.backupURL, applied.backupURL)
        XCTAssertEqual(try Data(contentsOf: configurationURL), originalConfig)
        XCTAssertEqual(try Data(contentsOf: configurator.secretURL), originalSecret)
        XCTAssertEqual(try permissions(of: configurationURL) & 0o777, 0o640)
        XCTAssertEqual(try permissions(of: configurator.secretURL) & 0o777, 0o600)
        XCTAssertFalse(
            try directoryEntries(at: configurator.backupsDirectory)
                .contains(where: { $0.lastPathComponent.hasPrefix(".restore-rollback-") })
        )
    }

    func testRestoreRemovesFilesThatDidNotExistBeforeFirstApply() throws {
        let applied = try configurator.apply(
            apiKey: "first-install-test-secret",
            models: [],
            selectedModelID: "default-model"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurator.secretURL.path))

        let restored = try configurator.restoreLatest()

        XCTAssertEqual(restored.backupURL, applied.backupURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.secretURL.path))
    }

    func testWriteFailureRollsBackSecretAndLeavesOriginalConfigUntouched() throws {
        let originalConfig = Data(#"{"keep":"original"}"#.utf8)
        let originalSecret = Data("original-test-secret".utf8)
        try originalConfig.write(to: configurationURL)
        try FileManager.default.createDirectory(
            at: configurator.secretURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalSecret.write(to: configurator.secretURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurator.secretURL.path
        )

        let configDirectory = configurationURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: configDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configDirectory.path
            )
        }

        XCTAssertThrowsError(
            try configurator.apply(
                apiKey: "replacement-test-secret",
                models: [OpenCodeModelOption(id: "replacement-model", name: "Replacement")],
                selectedModelID: "replacement-model"
            )
        )

        XCTAssertEqual(try Data(contentsOf: configurationURL), originalConfig)
        XCTAssertEqual(try Data(contentsOf: configurator.secretURL), originalSecret)
        XCTAssertNil(try configurator.inspect().latestBackupURL)
    }

    func testInvalidConfigurationDoesNotChangeConfigOrCreateSecretOrBackup() throws {
        let invalid = Data("{ \"provider\": /* unterminated".utf8)
        try invalid.write(to: configurationURL)

        XCTAssertThrowsError(
            try configurator.apply(
                apiKey: "safe-test-key",
                models: [OpenCodeModelOption(id: "model", name: "Model")],
                selectedModelID: "model"
            )
        ) { error in
            guard case OpenCodeConfigurationError.invalidConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: configurationURL), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.secretURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.backupsDirectory.path))
    }

    func testCorruptedBackupIsRejectedBeforeRestoreMutatesCurrentFiles() throws {
        let originalConfig = Data(#"{"model":"original/model"}"#.utf8)
        let originalSecret = Data("original-test-secret".utf8)
        try originalConfig.write(to: configurationURL)
        try FileManager.default.createDirectory(
            at: configurator.secretURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalSecret.write(to: configurator.secretURL)

        let applied = try configurator.apply(
            apiKey: "current-test-secret",
            models: [OpenCodeModelOption(id: "current-model", name: "Current")],
            selectedModelID: "current-model"
        )
        let currentConfig = try Data(contentsOf: configurationURL)
        let currentSecret = try Data(contentsOf: configurator.secretURL)
        let backupConfig = try XCTUnwrap(applied.backupURL)
            .appendingPathComponent("opencode.json")
        try Data("{".utf8).write(to: backupConfig)

        XCTAssertThrowsError(try configurator.restoreLatest())
        XCTAssertEqual(try Data(contentsOf: configurationURL), currentConfig)
        XCTAssertEqual(try Data(contentsOf: configurator.secretURL), currentSecret)
    }

    func testLatestOfMultipleBackupsRestoresImmediatelyPreviousState() throws {
        try Data(#"{"model":"before/all"}"#.utf8).write(to: configurationURL)
        let first = try configurator.apply(
            apiKey: "first-test-secret",
            models: [OpenCodeModelOption(id: "first-model", name: "First")],
            selectedModelID: "first-model"
        )
        XCTAssertNotNil(first.backupURL)
        let firstConfig = try Data(contentsOf: configurationURL)
        let firstSecret = try Data(contentsOf: configurator.secretURL)

        let second = try configurator.apply(
            apiKey: "second-test-secret",
            models: [OpenCodeModelOption(id: "second-model", name: "Second")],
            selectedModelID: "second-model"
        )
        let restored = try configurator.restoreLatest()

        XCTAssertEqual(restored.backupURL, second.backupURL)
        XCTAssertEqual(try Data(contentsOf: configurationURL), firstConfig)
        XCTAssertEqual(try Data(contentsOf: configurator.secretURL), firstSecret)
    }

    func testRestoreDetectsConcurrentChangeWithoutOverwritingIt() throws {
        let racingFileManager = RestoreRaceFileManager()
        let service = OpenCodeConfigurator(
            configurationURL: configurationURL,
            applicationSupportDirectory: supportURL,
            fileManager: racingFileManager
        )
        try Data(#"{"model":"before/model"}"#.utf8).write(to: configurationURL)
        _ = try service.apply(
            apiKey: "current-race-test-secret",
            models: [OpenCodeModelOption(id: "current", name: "Current")],
            selectedModelID: "current"
        )

        let externalChange = Data(#"{"external_change":true}"#.utf8)
        racingFileManager.onCreateDirectory = { url in
            guard url.lastPathComponent.hasPrefix(".restore-rollback-") else { return }
            try? externalChange.write(to: self.configurationURL)
        }

        XCTAssertThrowsError(try service.restoreLatest())
        XCTAssertEqual(try Data(contentsOf: configurationURL), externalChange)
        XCTAssertEqual(
            try Data(contentsOf: service.secretURL),
            Data("current-race-test-secret".utf8)
        )
    }

    func testExistingManagedDirectoriesAreHardenedTo0700() throws {
        let secretsDirectory = configurator.secretURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: secretsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: configurator.backupsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: secretsDirectory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: configurator.backupsDirectory.path
        )

        _ = try configurator.apply(
            apiKey: "directory-mode-test-secret",
            models: [],
            selectedModelID: "model"
        )

        XCTAssertEqual(try permissions(of: secretsDirectory) & 0o777, 0o700)
        XCTAssertEqual(try permissions(of: configurator.backupsDirectory) & 0o777, 0o700)
    }

    func testConfigurationSymlinkIsPreservedAndRealTargetIsUpdated() throws {
        let target = temporaryRoot.appendingPathComponent("managed-dotfiles/opencode.json")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"keep":"through-symlink"}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: configurationURL, withDestinationURL: target)
        let service = OpenCodeConfigurator(
            configurationURL: configurationURL,
            applicationSupportDirectory: supportURL
        )

        _ = try service.apply(
            apiKey: "symlink-config-test-secret",
            models: [],
            selectedModelID: "model"
        )

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: configurationURL.path))
        let root = try jsonObject(at: target)
        XCTAssertEqual(root["keep"] as? String, "through-symlink")
        XCTAssertEqual(root["model"] as? String, "yakcool/model")
    }

    func testManagedSecretParentSymlinkIsRejected() throws {
        let externalDirectory = temporaryRoot.appendingPathComponent("external-secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: supportURL.appendingPathComponent("Secrets", isDirectory: true),
            withDestinationURL: externalDirectory
        )

        XCTAssertThrowsError(
            try configurator.apply(
                apiKey: "symlink-test-secret",
                models: [],
                selectedModelID: "model"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalDirectory.appendingPathComponent("opencode-yakcool-key").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path))
    }

    func testProviderMustBeObjectAndOriginalFileIsUntouched() throws {
        let invalidShape = Data(#"{"provider":"wrong-type","keep":true}"#.utf8)
        try invalidShape.write(to: configurationURL)

        XCTAssertThrowsError(
            try configurator.apply(
                apiKey: "shape-test-secret",
                models: [],
                selectedModelID: "model"
            )
        )
        XCTAssertEqual(try Data(contentsOf: configurationURL), invalidShape)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.secretURL.path))
    }

    func testRestoreWithoutBackupReturnsNoBackupError() throws {
        XCTAssertThrowsError(try configurator.restoreLatest()) { error in
            XCTAssertEqual(error as? OpenCodeConfigurationError, .noBackup)
        }
    }

    func testPreviewContainsOnlySecretFileReferenceAndDoesNotWrite() throws {
        let preview = try configurator.preview(
            models: [OpenCodeModelOption(id: "preview-model", name: "Preview Model")],
            selectedModelID: "preview-model"
        )

        XCTAssertTrue(preview.configuration.contains("@ai-sdk/openai-compatible"))
        XCTAssertTrue(preview.configuration.contains("https://opencode.ai/config.json"))
        XCTAssertTrue(preview.configuration.contains("{file:\(configurator.secretURL.path)}"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.secretURL.path))
    }

    func testRejectsWhitespaceInAPIKeyBeforeTouchingFiles() throws {
        XCTAssertThrowsError(
            try configurator.apply(
                apiKey: "test key with spaces",
                models: [],
                selectedModelID: "model"
            )
        ) { error in
            guard case OpenCodeConfigurationError.invalidAPIKey = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.secretURL.path))
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func visibleBackupDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: configurator.backupsDirectory.path) else { return [] }
        return try directoryEntries(at: configurator.backupsDirectory)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private func directoryEntries(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }
}

private final class RestoreRaceFileManager: FileManager {
    var onCreateDirectory: ((URL) -> Void)?

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
        onCreateDirectory?(url)
    }
}
