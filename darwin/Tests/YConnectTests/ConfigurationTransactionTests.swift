import Darwin
import Foundation
import XCTest
@testable import YConnect

final class ConfigurationTransactionTests: XCTestCase {
    private enum TestFailure: LocalizedError {
        case injected
        case unexpectedState

        var errorDescription: String? {
            switch self {
            case .injected: return "injected transaction failure"
            case .unexpectedState: return "unexpected transaction state"
            }
        }
    }

    private var temporaryRoot: URL!
    private var configurationURL: URL!
    private var secretURL: URL!
    private var backupsURL: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigurationTransactionTests-\(UUID().uuidString)", isDirectory: true)
        configurationURL = temporaryRoot.appendingPathComponent("client/config.json")
        secretURL = temporaryRoot.appendingPathComponent("client/credentials/api-key")
        backupsURL = temporaryRoot.appendingPathComponent("support/backups/test-client", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secretURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        configurationURL = nil
        secretURL = nil
        backupsURL = nil
    }

    func testApplyIsIdempotentPrivateAndManifestIsRedacted() throws {
        let oldConfig = Data(#"{"owner":"old-config-payload-marker"}"#.utf8)
        let oldSecret = Data("old-secret-payload-marker-7cd210".utf8)
        let newConfig = Data(#"{"owner":"new-config-payload-marker"}"#.utf8)
        let newSecret = Data("new-secret-payload-marker-a34e21".utf8)
        try writeInitial(oldConfig, to: configurationURL, permissions: 0o640)
        try writeInitial(oldSecret, to: secretURL, permissions: 0o600)

        let coordinator = try makeCoordinator()
        let first = try apply(
            coordinator,
            configuration: newConfig,
            secret: newSecret,
            validate: { state in
                guard state.data(for: "configuration") == newConfig,
                      state.data(for: "secret") == newSecret else {
                    throw TestFailure.unexpectedState
                }
                XCTAssertFalse(String(describing: state).contains("payload-marker"))
                XCTAssertFalse(String(describing: state.file("secret")).contains("a34e21"))
            }
        )

        XCTAssertEqual(first.action, .applied)
        XCTAssertEqual(first.changedTargetIDs, ["secret", "configuration"])
        XCTAssertEqual(try Data(contentsOf: configurationURL), newConfig)
        XCTAssertEqual(try Data(contentsOf: secretURL), newSecret)
        XCTAssertEqual(try permissions(of: configurationURL), 0o600)
        XCTAssertEqual(try permissions(of: secretURL), 0o600)
        XCTAssertEqual(try permissions(of: backupsURL), 0o700)

        let backupURL = try XCTUnwrap(first.backupURL)
        XCTAssertEqual(try permissions(of: backupURL), 0o700)
        let backupEntries = try FileManager.default.contentsOfDirectory(
            at: backupURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(backupEntries.isEmpty)
        for entry in backupEntries {
            XCTAssertEqual(try permissions(of: entry), 0o600, "backup files must remain private")
        }

        let manifestURL = backupURL.appendingPathComponent("manifest.json")
        let manifest = try XCTUnwrap(String(data: Data(contentsOf: manifestURL), encoding: .utf8))
        for forbidden in [oldConfig, oldSecret, newConfig, newSecret] {
            let text = try XCTUnwrap(String(data: forbidden, encoding: .utf8))
            XCTAssertFalse(manifest.contains(text), "manifest must not contain configuration or secret payloads")
        }

        let countBeforeSecondApply = try visibleSnapshotDirectories().count
        let second = try apply(
            coordinator,
            configuration: newConfig,
            secret: newSecret,
            validate: { state in
                guard state.data(for: "configuration") == newConfig,
                      state.data(for: "secret") == newSecret else {
                    throw TestFailure.unexpectedState
                }
            }
        )
        XCTAssertEqual(second.action, .unchanged)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(try visibleSnapshotDirectories().count, countBeforeSecondApply)
    }

    func testOrderedPartialFailureRollsBackEveryTouchedFile() throws {
        let oldConfig = Data("old-config".utf8)
        let oldSecret = Data("old-secret".utf8)
        try writeInitial(oldConfig, to: configurationURL, permissions: 0o640)
        try writeInitial(oldSecret, to: secretURL, permissions: 0o600)

        var hooks = ConfigurationTransactionHooks.none
        hooks.beforeMutation = { index, _ in
            if index == 1 { throw TestFailure.injected }
        }
        let coordinator = try makeCoordinator(hooks: hooks)

        XCTAssertThrowsError(try apply(
            coordinator,
            configuration: Data("new-config".utf8),
            secret: Data("new-secret".utf8)
        ))
        XCTAssertEqual(try Data(contentsOf: configurationURL), oldConfig)
        XCTAssertEqual(try Data(contentsOf: secretURL), oldSecret)
        XCTAssertEqual(try permissions(of: configurationURL), 0o640)
        XCTAssertEqual(try permissions(of: secretURL), 0o600)
        XCTAssertEqual(try visibleSnapshotDirectories().count, 0)
    }

    func testAllTargetCompareAndSwapRejectsExternalChangeBeforeFirstWrite() throws {
        let oldConfig = Data("old-config".utf8)
        let oldSecret = Data("old-secret".utf8)
        let externalConfig = Data("external-config".utf8)
        try writeInitial(oldConfig, to: configurationURL, permissions: 0o600)
        try writeInitial(oldSecret, to: secretURL, permissions: 0o600)

        var hooks = ConfigurationTransactionHooks.none
        hooks.beforeCompareAndSwap = { [configurationURL] in
            try externalConfig.write(to: try XCTUnwrap(configurationURL), options: .atomic)
        }
        let coordinator = try makeCoordinator(hooks: hooks)

        XCTAssertThrowsError(try apply(
            coordinator,
            configuration: Data("new-config".utf8),
            secret: Data("new-secret".utf8)
        )) { error in
            guard case ConfigurationTransactionError.concurrentModification(let paths) = error else {
                return XCTFail("expected a compare-and-swap conflict, got \(error)")
            }
            XCTAssertEqual(paths, [self.configurationURL.path])
        }
        XCTAssertEqual(try Data(contentsOf: configurationURL), externalConfig)
        XCTAssertEqual(try Data(contentsOf: secretURL), oldSecret)
        XCTAssertEqual(try visibleSnapshotDirectories().count, 0)
    }

    func testValidationFailureRollsBackTheWholeTransaction() throws {
        let oldConfig = Data("old-config".utf8)
        let oldSecret = Data("old-secret".utf8)
        try writeInitial(oldConfig, to: configurationURL, permissions: 0o640)
        try writeInitial(oldSecret, to: secretURL, permissions: 0o600)
        let coordinator = try makeCoordinator()

        XCTAssertThrowsError(try apply(
            coordinator,
            configuration: Data("new-config".utf8),
            secret: Data("new-secret".utf8),
            validate: { _ in throw TestFailure.injected }
        )) { error in
            guard case ConfigurationTransactionError.validationFailed = error else {
                return XCTFail("expected validation failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: configurationURL), oldConfig)
        XCTAssertEqual(try Data(contentsOf: secretURL), oldSecret)
        XCTAssertEqual(try permissions(of: configurationURL), 0o640)
        XCTAssertEqual(try visibleSnapshotDirectories().count, 0)
    }

    func testExternalChangeDuringValidationIsPreservedAndSafeFilesRollBack() throws {
        let oldConfig = Data("old-config".utf8)
        let oldSecret = Data("old-secret".utf8)
        let externalConfig = Data("external-config-during-validation".utf8)
        try writeInitial(oldConfig, to: configurationURL, permissions: 0o600)
        try writeInitial(oldSecret, to: secretURL, permissions: 0o600)

        var hooks = ConfigurationTransactionHooks.none
        hooks.beforeValidation = { [configurationURL] in
            try externalConfig.write(to: try XCTUnwrap(configurationURL), options: .atomic)
        }
        let coordinator = try makeCoordinator(hooks: hooks)

        XCTAssertThrowsError(try apply(
            coordinator,
            configuration: Data("new-config".utf8),
            secret: Data("new-secret".utf8)
        )) { error in
            guard case ConfigurationTransactionError.rollbackConflict(
                original: _, paths: let paths, recoveryBackupURL: let recoveryURL
            ) = error else {
                return XCTFail("expected conflict-safe rollback, got \(error)")
            }
            XCTAssertEqual(paths, [self.configurationURL.path])
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: configurationURL), externalConfig)
        XCTAssertEqual(try Data(contentsOf: secretURL), oldSecret, "non-conflicting targets should roll back")
        XCTAssertEqual(try visibleSnapshotDirectories().count, 1, "recovery backup must be retained")
    }

    func testRestoreLatestRestoresBytesExistenceAndOriginalConfigurationMode() throws {
        let oldConfig = Data("original-config-byte-for-byte\n".utf8)
        let newConfig = Data("new-config".utf8)
        let newSecret = Data("new-secret".utf8)
        try writeInitial(oldConfig, to: configurationURL, permissions: 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretURL.path))
        let coordinator = try makeCoordinator()

        let applied = try apply(coordinator, configuration: newConfig, secret: newSecret)
        let restored = try coordinator.restoreLatest { state in
            guard state.data(for: "configuration") == oldConfig,
                  state.data(for: "secret") == nil else {
                throw TestFailure.unexpectedState
            }
        }

        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(restored.backupURL, applied.backupURL)
        XCTAssertEqual(try Data(contentsOf: configurationURL), oldConfig)
        XCTAssertEqual(try permissions(of: configurationURL), 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretURL.path))
        XCTAssertEqual(try visibleSnapshotDirectories().count, 1)

        let repeated = try coordinator.restoreLatest { state in
            guard state.data(for: "configuration") == oldConfig,
                  state.data(for: "secret") == nil else {
                throw TestFailure.unexpectedState
            }
        }
        XCTAssertEqual(repeated.action, .unchanged)
    }

    func testRejectsSymbolicLinkAndNonRegularTargets() throws {
        let realFile = temporaryRoot.appendingPathComponent("real-config")
        try Data("real".utf8).write(to: realFile)
        let symbolicLink = temporaryRoot.appendingPathComponent("linked-config")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: realFile)

        XCTAssertThrowsError(try makeCoordinator(configurationURL: symbolicLink)) { error in
            guard case ConfigurationTransactionError.unsafePath = error else {
                return XCTFail("expected symbolic-link rejection, got \(error)")
            }
        }

        let directoryTarget = temporaryRoot.appendingPathComponent("directory-as-target", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
        let coordinator = try makeCoordinator(configurationURL: directoryTarget)
        XCTAssertThrowsError(try coordinator.apply(
            plan: { _ in [.write(targetID: "configuration", data: Data("new".utf8))] },
            validate: { _ in }
        )) { error in
            guard case ConfigurationTransactionError.unsafePath = error else {
                return XCTFail("expected non-regular-file rejection, got \(error)")
            }
        }
    }

    func testKeepsOnlyTwentyCompletedBackups() throws {
        try writeInitial(Data("version-0".utf8), to: configurationURL, permissions: 0o600)
        let coordinator = try makeCoordinator()

        for version in 1...22 {
            let data = Data("version-\(version)".utf8)
            let result = try coordinator.apply(
                plan: { _ in [.write(targetID: "configuration", data: data)] },
                validate: { state in
                    guard state.data(for: "configuration") == data else {
                        throw TestFailure.unexpectedState
                    }
                }
            )
            XCTAssertEqual(result.action, .applied)
        }

        XCTAssertEqual(try visibleSnapshotDirectories().count, 20)
        XCTAssertEqual(try Data(contentsOf: configurationURL), Data("version-22".utf8))
        _ = try coordinator.restoreLatest { state in
            guard state.data(for: "configuration") == Data("version-21".utf8) else {
                throw TestFailure.unexpectedState
            }
        }
        XCTAssertEqual(try Data(contentsOf: configurationURL), Data("version-21".utf8))
    }

    func testReadOnlySnapshotIsBoundedAndRejectsAReplacedSymlink() throws {
        let secret = Data("snapshot-secret-marker".utf8)
        try writeInitial(Data("cfg".utf8), to: configurationURL, permissions: 0o600)
        try writeInitial(secret, to: secretURL, permissions: 0o600)
        let coordinator = try makeCoordinator()

        let observed = try coordinator.withSnapshot { state in
            XCTAssertEqual(state.data(for: "configuration"), Data("cfg".utf8))
            XCTAssertEqual(state.data(for: "secret"), secret)
            XCTAssertEqual(state.file("secret")?.permissions, 0o600)
            XCTAssertFalse(String(describing: state).contains("snapshot-secret-marker"))
            return state.file("configuration")?.sha256
        }
        XCTAssertNotNil(observed)
        XCTAssertEqual(try visibleSnapshotDirectories().count, 0)

        let replacement = temporaryRoot.appendingPathComponent("replacement-config")
        try Data("outside".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: configurationURL)
        try FileManager.default.createSymbolicLink(at: configurationURL, withDestinationURL: replacement)

        XCTAssertThrowsError(try coordinator.withSnapshot { _ in () }) { error in
            guard case ConfigurationTransactionError.unsafePath = error else {
                return XCTFail("expected read-only symlink rejection, got \(error)")
            }
        }

        try FileManager.default.removeItem(at: configurationURL)
        try Data("oversized".utf8).write(to: configurationURL)
        let bounded = try ConfigurationTransactionCoordinator(
            identifier: "bounded-read",
            targets: [
                ConfigurationTransactionTarget(
                    id: "configuration",
                    url: configurationURL,
                    maximumByteCount: 4
                ),
            ],
            backupsDirectory: temporaryRoot.appendingPathComponent("bounded-backups")
        )
        XCTAssertThrowsError(try bounded.withSnapshot { _ in () }) { error in
            guard case ConfigurationTransactionError.fileTooLarge = error else {
                return XCTFail("expected bounded read rejection, got \(error)")
            }
        }
    }

    func testMultiTargetSnapshotRetriesInsteadOfReturningATornView() throws {
        let oldConfiguration = Data("old-configuration".utf8)
        let oldSecret = Data("old-secret".utf8)
        let newConfiguration = Data("new-configuration".utf8)
        let newSecret = Data("new-secret".utf8)
        try writeInitial(oldConfiguration, to: configurationURL, permissions: 0o600)
        try writeInitial(oldSecret, to: secretURL, permissions: 0o600)

        var didReplacePair = false
        var candidateAttempts: [Int] = []
        var hooks = ConfigurationTransactionHooks.none
        hooks.afterSnapshotTargetRead = { [configurationURL, secretURL] attempt, _, targetID in
            guard targetID == "configuration" else { return }
            candidateAttempts.append(attempt)
            guard !didReplacePair else { return }
            didReplacePair = true
            // The first candidate has already read the old configuration but
            // will read the new secret. Verification must reject that torn pair.
            try newConfiguration.write(to: try XCTUnwrap(configurationURL), options: .atomic)
            try newSecret.write(to: try XCTUnwrap(secretURL), options: .atomic)
        }
        let coordinator = try makeCoordinator(hooks: hooks)

        let observed = try coordinator.withSnapshot { state in
            (
                state.data(for: "configuration"),
                state.data(for: "secret")
            )
        }

        XCTAssertEqual(observed.0, newConfiguration)
        XCTAssertEqual(observed.1, newSecret)
        XCTAssertEqual(candidateAttempts, [0, 1])
        XCTAssertEqual(try visibleSnapshotDirectories().count, 0)
    }

    func testMultiTargetSnapshotRejectsContinuousConcurrentModificationAfterBoundedRetries() throws {
        try writeInitial(Data("configuration-0".utf8), to: configurationURL, permissions: 0o600)
        try writeInitial(Data("secret".utf8), to: secretURL, permissions: 0o600)

        var rewriteCount = 0
        var hooks = ConfigurationTransactionHooks.none
        hooks.afterSnapshotTargetRead = { [configurationURL] _, _, targetID in
            guard targetID == "configuration" else { return }
            rewriteCount += 1
            try Data("configuration-\(rewriteCount)".utf8).write(
                to: try XCTUnwrap(configurationURL),
                options: .atomic
            )
        }
        let coordinator = try makeCoordinator(hooks: hooks)
        var bodyWasCalled = false

        XCTAssertThrowsError(try coordinator.withSnapshot { _ in
            bodyWasCalled = true
        }) { error in
            guard case ConfigurationTransactionError.concurrentModification(let paths) = error else {
                return XCTFail("expected bounded snapshot conflict, got \(error)")
            }
            XCTAssertEqual(paths, [self.configurationURL.path])
        }
        XCTAssertFalse(bodyWasCalled)
        XCTAssertEqual(rewriteCount, 3)
    }

    func testReadOnlyValidatedPlanRejectsOversizedPreviewBeforeRenderingOrBackup() throws {
        let original = Data("old".utf8)
        let payloadMarker = "oversized-preview-payload-must-stay-redacted"
        try writeInitial(original, to: configurationURL, permissions: 0o600)
        let coordinator = try ConfigurationTransactionCoordinator(
            identifier: "bounded-preview",
            targets: [
                ConfigurationTransactionTarget(
                    id: "configuration",
                    url: configurationURL,
                    maximumByteCount: 4
                ),
            ],
            backupsDirectory: temporaryRoot.appendingPathComponent("bounded-preview-backups")
        )
        var renderBodyWasCalled = false

        XCTAssertThrowsError(try coordinator.withValidatedPlan(
            plan: { _ in
                [.write(targetID: "configuration", data: Data(payloadMarker.utf8))]
            },
            { _, _ in
                renderBodyWasCalled = true
            }
        )) { error in
            guard case ConfigurationTransactionError.fileTooLarge(let path, let maximumByteCount) = error else {
                return XCTFail("expected preview size rejection, got \(error)")
            }
            XCTAssertEqual(path, self.configurationURL.path)
            XCTAssertEqual(maximumByteCount, 4)
            XCTAssertFalse(error.localizedDescription.contains(payloadMarker))
        }
        XCTAssertFalse(renderBodyWasCalled)
        XCTAssertEqual(try Data(contentsOf: configurationURL), original)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryRoot.appendingPathComponent("bounded-preview-backups").path
        ))
    }

    func testRestoreHardensHistoricalExecutableHelperButPreservesConfigurationMode() throws {
        let helperURL = temporaryRoot.appendingPathComponent("support/helpers/historical-helper")
        let helperBackupsURL = temporaryRoot.appendingPathComponent("helper-restore-backups")
        let oldConfiguration = Data("old-configuration".utf8)
        let oldHelper = Data("#!/bin/sh\nprintf old\\n\n".utf8)
        let newConfiguration = Data("new-configuration".utf8)
        let newHelper = Data("#!/bin/sh\nprintf new\\n\n".utf8)
        try writeInitial(oldConfiguration, to: configurationURL, permissions: 0o640)
        try writeInitial(oldHelper, to: helperURL, permissions: 0o755)
        let coordinator = try ConfigurationTransactionCoordinator(
            identifier: "helper-restore",
            targets: [
                ConfigurationTransactionTarget(
                    id: "configuration",
                    url: configurationURL,
                    sensitivity: .configuration,
                    writePermissions: 0o600
                ),
                ConfigurationTransactionTarget(
                    id: "helper",
                    url: helperURL,
                    sensitivity: .configuration,
                    writePermissions: 0o700
                ),
            ],
            backupsDirectory: helperBackupsURL
        )

        _ = try coordinator.apply(
            plan: { _ in
                [
                    .write(targetID: "helper", data: newHelper),
                    .write(targetID: "configuration", data: newConfiguration),
                ]
            },
            validate: { state in
                guard state.data(for: "helper") == newHelper,
                      state.data(for: "configuration") == newConfiguration else {
                    throw TestFailure.unexpectedState
                }
            }
        )
        XCTAssertEqual(try permissions(of: helperURL), 0o700)
        XCTAssertEqual(try permissions(of: configurationURL), 0o600)

        let restored = try coordinator.restoreLatest { state in
            guard state.data(for: "helper") == oldHelper,
                  state.file("helper")?.permissions == 0o700,
                  state.data(for: "configuration") == oldConfiguration,
                  state.file("configuration")?.permissions == 0o640 else {
                throw TestFailure.unexpectedState
            }
        }

        XCTAssertEqual(restored.action, .restored)
        XCTAssertEqual(try Data(contentsOf: helperURL), oldHelper)
        XCTAssertEqual(try permissions(of: helperURL), 0o700)
        XCTAssertEqual(try Data(contentsOf: configurationURL), oldConfiguration)
        XCTAssertEqual(try permissions(of: configurationURL), 0o640)
    }

    func testFailureRollbackAlsoRefusesToReintroduceWorldReadableHelperMode() throws {
        let helperURL = temporaryRoot.appendingPathComponent("support/helpers/rollback-helper")
        let oldHelper = Data("#!/bin/sh\nexit 0\n".utf8)
        let oldConfiguration = Data("old-configuration".utf8)
        try writeInitial(oldHelper, to: helperURL, permissions: 0o755)
        try writeInitial(oldConfiguration, to: configurationURL, permissions: 0o640)
        var hooks = ConfigurationTransactionHooks.none
        hooks.beforeMutation = { index, _ in
            if index == 1 { throw TestFailure.injected }
        }
        let coordinator = try ConfigurationTransactionCoordinator(
            identifier: "helper-rollback",
            targets: [
                ConfigurationTransactionTarget(
                    id: "helper",
                    url: helperURL,
                    writePermissions: 0o700
                ),
                ConfigurationTransactionTarget(
                    id: "configuration",
                    url: configurationURL,
                    writePermissions: 0o600
                ),
            ],
            backupsDirectory: temporaryRoot.appendingPathComponent("helper-rollback-backups"),
            hooks: hooks
        )

        XCTAssertThrowsError(try coordinator.apply(
            plan: { _ in
                [
                    .write(targetID: "helper", data: Data("new-helper".utf8)),
                    .write(targetID: "configuration", data: Data("new-configuration".utf8)),
                ]
            },
            validate: { _ in }
        )) { error in
            guard case ConfigurationTransactionError.fileOperation = error else {
                return XCTFail("expected injected apply failure after safe rollback, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: helperURL), oldHelper)
        XCTAssertEqual(try permissions(of: helperURL), 0o700)
        XCTAssertEqual(try Data(contentsOf: configurationURL), oldConfiguration)
        XCTAssertEqual(try permissions(of: configurationURL), 0o640)
    }

    func testAllowsPrivateExecutableHelperButRejectsGroupOrWorldAccess() throws {
        let helperURL = temporaryRoot.appendingPathComponent("support/helpers/read-key")
        let helperCoordinator = try ConfigurationTransactionCoordinator(
            identifier: "private-helper",
            targets: [
                ConfigurationTransactionTarget(
                    id: "helper",
                    url: helperURL,
                    sensitivity: .configuration,
                    writePermissions: 0o700
                ),
            ],
            backupsDirectory: temporaryRoot.appendingPathComponent("helper-backups")
        )
        let helper = Data("#!/bin/sh\nexit 0\n".utf8)
        _ = try helperCoordinator.apply(
            plan: { _ in [.write(targetID: "helper", data: helper)] },
            validate: { state in
                guard state.data(for: "helper") == helper,
                      state.file("helper")?.permissions == 0o700 else {
                    throw TestFailure.unexpectedState
                }
            }
        )
        XCTAssertEqual(try permissions(of: helperURL), 0o700)

        for unsafePermissions in [0o640, 0o704, 0o755] {
            XCTAssertThrowsError(try ConfigurationTransactionCoordinator(
                identifier: "unsafe-helper-\(unsafePermissions)",
                targets: [
                    ConfigurationTransactionTarget(
                        id: "helper",
                        url: temporaryRoot.appendingPathComponent("helper-\(unsafePermissions)"),
                        writePermissions: unsafePermissions
                    ),
                ],
                backupsDirectory: temporaryRoot.appendingPathComponent("unsafe-helper-backups-\(unsafePermissions)")
            )) { error in
                guard case ConfigurationTransactionError.invalidDefinition = error else {
                    return XCTFail("expected private-permission rejection, got \(error)")
                }
            }
        }
    }

    private func makeCoordinator(
        configurationURL overrideConfigurationURL: URL? = nil,
        hooks: ConfigurationTransactionHooks = .none
    ) throws -> ConfigurationTransactionCoordinator {
        try ConfigurationTransactionCoordinator(
            identifier: "test-client",
            targets: [
                ConfigurationTransactionTarget(
                    id: "configuration",
                    url: overrideConfigurationURL ?? configurationURL,
                    sensitivity: .configuration
                ),
                ConfigurationTransactionTarget(
                    id: "secret",
                    url: secretURL,
                    sensitivity: .secret
                ),
            ],
            backupsDirectory: backupsURL,
            hooks: hooks
        )
    }

    @discardableResult
    private func apply(
        _ coordinator: ConfigurationTransactionCoordinator,
        configuration: Data,
        secret: Data,
        validate: ConfigurationTransactionCoordinator.Validator? = nil
    ) throws -> ConfigurationTransactionResult {
        try coordinator.apply(
            plan: { _ in
                [
                    .write(targetID: "secret", data: secret),
                    .write(targetID: "configuration", data: configuration),
                ]
            },
            validate: validate ?? { state in
                guard state.data(for: "configuration") == configuration,
                      state.data(for: "secret") == secret else {
                    throw TestFailure.unexpectedState
                }
            }
        )
    }

    private func writeInitial(_ data: Data, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func visibleSnapshotDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backupsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
