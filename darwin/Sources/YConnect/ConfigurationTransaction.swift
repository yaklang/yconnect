import CryptoKit
import Darwin
import Foundation

/// Identifies one file managed as part of a client configuration transaction.
///
/// IDs are persisted in backup manifests. They therefore need to remain stable
/// when an adapter is renamed or its UI copy changes.
struct ConfigurationTransactionTarget: Hashable {
    enum Sensitivity: String, Codable {
        case configuration
        case secret
    }

    let id: String
    let url: URL
    let sensitivity: Sensitivity
    let writePermissions: Int
    let maximumByteCount: Int

    init(
        id: String,
        url: URL,
        sensitivity: Sensitivity = .configuration,
        writePermissions: Int = 0o600,
        maximumByteCount: Int = 16 * 1_024 * 1_024
    ) {
        self.id = id
        self.url = url
        self.sensitivity = sensitivity
        self.writePermissions = writePermissions & 0o777
        self.maximumByteCount = maximumByteCount
    }
}

enum ConfigurationTransactionMutation: Equatable {
    case write(targetID: String, data: Data)
    case remove(targetID: String)

    var targetID: String {
        switch self {
        case .write(let targetID, _), .remove(let targetID): return targetID
        }
    }
}

/// A point-in-time view supplied to an adapter's plan and validation closures.
/// File contents are intentionally available only through an explicit accessor;
/// the type's description never renders them.
struct ConfigurationTransactionState: CustomStringConvertible {
    struct File: CustomStringConvertible {
        let targetID: String
        let url: URL
        let exists: Bool
        let byteCount: Int
        let permissions: Int?
        let sha256: String?
        fileprivate let contents: Data?

        var description: String {
            "ConfigurationTransactionState.File(targetID: \(targetID), exists: \(exists), byteCount: \(byteCount), contents: <redacted>)"
        }
    }

    let files: [String: File]

    func file(_ targetID: String) -> File? { files[targetID] }
    func data(for targetID: String) -> Data? { files[targetID]?.contents }

    var description: String {
        "ConfigurationTransactionState(targets: \(files.keys.sorted()))"
    }
}

struct ConfigurationTransactionResult: Equatable {
    enum Action: String, Equatable {
        case applied
        case unchanged
        case restored
    }

    let action: Action
    let changedTargetIDs: [String]
    let backupURL: URL?
    let warnings: [String]
}

enum ConfigurationTransactionError: LocalizedError {
    case invalidDefinition(String)
    case unsafePath(String)
    case fileTooLarge(path: String, maximumByteCount: Int)
    case concurrentModification(paths: [String])
    case validationFailed(String)
    case noBackup
    case invalidBackup(String)
    case fileOperation(String)
    case rollbackConflict(original: String, paths: [String], recoveryBackupURL: URL)
    case rollbackFailed(original: String, rollback: String, recoveryBackupURL: URL)

    var errorDescription: String? {
        switch self {
        case .invalidDefinition(let message),
             .unsafePath(let message),
             .validationFailed(let message),
             .invalidBackup(let message),
             .fileOperation(let message):
            return message
        case .fileTooLarge(let path, let maximumByteCount):
            return "文件过大，拒绝读取（上限 \(maximumByteCount) 字节）：\(path)"
        case .concurrentModification(let paths):
            return "配置在操作过程中被其他程序修改，请重试：\(paths.joined(separator: ", "))"
        case .noBackup:
            return "没有可恢复的配置备份"
        case .rollbackConflict(let original, let paths, let recoveryBackupURL):
            return "配置操作失败（\(original)）；检测到外部修改，未覆盖这些文件：\(paths.joined(separator: ", "))。恢复快照：\(recoveryBackupURL.path)"
        case .rollbackFailed(let original, let rollback, let recoveryBackupURL):
            return "配置操作失败（\(original)），并且自动回滚失败（\(rollback)）。恢复快照：\(recoveryBackupURL.path)"
        }
    }
}

/// Test-only fault-injection points. Keeping these at transaction boundaries also
/// makes races deterministic without teaching adapters about filesystem details.
struct ConfigurationTransactionHooks {
    var afterBackupCreated: ((URL) throws -> Void)?
    var beforeCompareAndSwap: (() throws -> Void)?
    var beforeMutation: ((Int, ConfigurationTransactionMutation) throws -> Void)?
    var afterMutation: ((Int, ConfigurationTransactionMutation) throws -> Void)?
    var beforeValidation: (() throws -> Void)?
    /// Called only while collecting the candidate pass of a stable snapshot.
    /// Arguments are retry attempt, target index, and target ID.
    var afterSnapshotTargetRead: ((Int, Int, String) throws -> Void)?

    static let none = ConfigurationTransactionHooks()
}

/// Executes crash-resistant, compare-and-swap guarded mutations for one client.
///
/// An adapter owns format-specific parsing and supplies ordered mutations plus a
/// post-write validator. This type owns every filesystem safety invariant.
final class ConfigurationTransactionCoordinator {
    typealias Plan = (ConfigurationTransactionState) throws -> [ConfigurationTransactionMutation]
    typealias Validator = (ConfigurationTransactionState) throws -> Void

    private static let manifestName = "manifest.json"
    private static let manifestSchemaVersion = 1
    private static let completedBackupLimit = 20
    private static let stableSnapshotAttemptLimit = 3

    private let identifier: String
    private let targets: [ConfigurationTransactionTarget]
    private let targetByID: [String: ConfigurationTransactionTarget]
    private let backupsDirectory: URL
    private let fileManager: FileManager
    private let hooks: ConfigurationTransactionHooks
    private let operationLock = NSLock()

    init(
        identifier: String,
        targets requestedTargets: [ConfigurationTransactionTarget],
        backupsDirectory requestedBackupsDirectory: URL,
        fileManager: FileManager = .default,
        hooks: ConfigurationTransactionHooks = .none
    ) throws {
        guard Self.isValidStableIdentifier(identifier) else {
            throw ConfigurationTransactionError.invalidDefinition("配置事务标识无效：\(identifier)")
        }
        guard !requestedTargets.isEmpty else {
            throw ConfigurationTransactionError.invalidDefinition("配置事务至少需要一个目标文件")
        }

        var normalizedTargets: [ConfigurationTransactionTarget] = []
        var seenIDs: Set<String> = []
        var seenPaths: Set<String> = []
        for target in requestedTargets {
            guard Self.isValidStableIdentifier(target.id) else {
                throw ConfigurationTransactionError.invalidDefinition("目标标识无效：\(target.id)")
            }
            guard seenIDs.insert(target.id).inserted else {
                throw ConfigurationTransactionError.invalidDefinition("目标标识重复：\(target.id)")
            }
            guard target.maximumByteCount > 0 else {
                throw ConfigurationTransactionError.invalidDefinition("目标文件大小上限必须大于零：\(target.id)")
            }
            guard target.writePermissions == 0o600 || target.writePermissions == 0o700 else {
                throw ConfigurationTransactionError.invalidDefinition(
                    "托管文件权限必须为仅所有者可读写（0600 或 0700）：\(target.id)"
                )
            }
            try Self.rejectFinalSymbolicLink(at: target.url, fileManager: fileManager, label: "目标文件")
            let canonicalURL = Self.canonicalizedURL(target.url, fileManager: fileManager)
            guard seenPaths.insert(canonicalURL.path).inserted else {
                throw ConfigurationTransactionError.invalidDefinition("多个目标指向同一路径：\(canonicalURL.path)")
            }
            normalizedTargets.append(ConfigurationTransactionTarget(
                id: target.id,
                url: canonicalURL,
                sensitivity: target.sensitivity,
                writePermissions: target.writePermissions,
                maximumByteCount: target.maximumByteCount
            ))
        }

        try Self.rejectFinalSymbolicLink(
            at: requestedBackupsDirectory,
            fileManager: fileManager,
            label: "备份目录"
        )
        let canonicalBackups = Self.canonicalizedURL(requestedBackupsDirectory, fileManager: fileManager)
        for target in normalizedTargets where Self.isDescendantOrEqual(target.url, of: canonicalBackups) {
            throw ConfigurationTransactionError.invalidDefinition(
                "目标文件不能位于备份目录中：\(target.url.path)"
            )
        }

        self.identifier = identifier
        self.targets = normalizedTargets
        self.targetByID = Dictionary(uniqueKeysWithValues: normalizedTargets.map { ($0.id, $0) })
        self.backupsDirectory = canonicalBackups
        self.fileManager = fileManager
        self.hooks = hooks
    }

    /// Builds a plan from one authoritative snapshot, then applies it atomically
    /// across the declared target set as far as the filesystem permits.
    func apply(plan: Plan, validate: Validator) throws -> ConfigurationTransactionResult {
        operationLock.lock()
        defer { operationLock.unlock() }

        let original = try snapshotAll()
        let mutations = try validatedMutations(plan(publicState(from: original)))
        let desired = try desiredState(after: mutations, from: original)

        if contentStatesEqual(original, desired) {
            do {
                try validate(publicState(from: original))
            } catch {
                throw ConfigurationTransactionError.validationFailed(error.localizedDescription)
            }
            return ConfigurationTransactionResult(
                action: .unchanged,
                changedTargetIDs: [],
                backupURL: nil,
                warnings: []
            )
        }

        let backup = try createBackup(from: original, mutationOrder: mutations.map(\.targetID), kind: .apply)
        do { try hooks.afterBackupCreated?(backup.directory) }
        catch {
            try? fileManager.removeItem(at: backup.directory)
            throw mapFileError(error)
        }

        do { try hooks.beforeCompareAndSwap?() }
        catch {
            try? fileManager.removeItem(at: backup.directory)
            throw mapFileError(error)
        }

        let beforeMutation = try snapshotAll()
        let changedBeforeMutation = casDifferences(expected: original, actual: beforeMutation)
        guard changedBeforeMutation.isEmpty else {
            try? fileManager.removeItem(at: backup.directory)
            throw ConfigurationTransactionError.concurrentModification(paths: changedBeforeMutation)
        }

        var expectedCurrent = contentStateMap(original)
        var attemptedTargetIDs: [String] = []
        var inFlightMutation: ConfigurationTransactionMutation?
        do {
            for (index, mutation) in mutations.enumerated() {
                inFlightMutation = mutation
                attemptedTargetIDs.append(mutation.targetID)
                try hooks.beforeMutation?(index, mutation)
                try execute(mutation)
                expectedCurrent[mutation.targetID] = try desiredContentState(for: mutation)
                inFlightMutation = nil
                try hooks.afterMutation?(index, mutation)
            }

            let installed = try snapshotAll()
            let installedDifferences = contentDifferences(expected: desired, actual: installed)
            guard installedDifferences.isEmpty else {
                throw ConfigurationTransactionError.concurrentModification(paths: installedDifferences)
            }
            try hooks.beforeValidation?()
            do { try validate(publicState(from: installed)) }
            catch { throw ConfigurationTransactionError.validationFailed(error.localizedDescription) }
            let validated = try snapshotAll()
            let validationDifferences = contentDifferences(expected: desired, actual: validated)
            guard validationDifferences.isEmpty else {
                throw ConfigurationTransactionError.concurrentModification(paths: validationDifferences)
            }
            try markBackupCompleted(backup)
            let warning = pruneCompletedBackupsKeepingNewest(Self.completedBackupLimit)
            return ConfigurationTransactionResult(
                action: .applied,
                changedTargetIDs: mutations.map(\.targetID),
                backupURL: backup.directory,
                warnings: warning.map { [$0] } ?? []
            )
        } catch {
            throw rollbackAfterFailure(
                originalError: error,
                original: original,
                backup: backup,
                mutationOrder: mutations.map(\.targetID),
                attemptedTargetIDs: attemptedTargetIDs,
                expectedCurrent: expectedCurrent,
                inFlightMutation: inFlightMutation
            )
        }
    }

    /// Restores the most recent completed backup for this coordinator only.
    /// The caller validates the restored format before the operation commits.
    func restoreLatest(validate: Validator) throws -> ConfigurationTransactionResult {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard let targetBackup = try latestCompletedBackup() else {
            throw ConfigurationTransactionError.noBackup
        }
        let desired = try loadBackupState(targetBackup)
        let current = try snapshotAll()
        if contentStatesEqual(current, desired) {
            do { try validate(publicState(from: current)) }
            catch { throw ConfigurationTransactionError.validationFailed(error.localizedDescription) }
            return ConfigurationTransactionResult(
                action: .unchanged,
                changedTargetIDs: [],
                backupURL: targetBackup.directory,
                warnings: []
            )
        }

        let rollbackBackup = try createBackup(
            from: current,
            mutationOrder: targetBackup.manifest.mutationOrder,
            kind: .temporaryRollback
        )
        do { try hooks.afterBackupCreated?(rollbackBackup.directory) }
        catch {
            try? fileManager.removeItem(at: rollbackBackup.directory)
            throw mapFileError(error)
        }
        do { try hooks.beforeCompareAndSwap?() }
        catch {
            try? fileManager.removeItem(at: rollbackBackup.directory)
            throw mapFileError(error)
        }

        let beforeMutation = try snapshotAll()
        let changedBeforeMutation = casDifferences(expected: current, actual: beforeMutation)
        guard changedBeforeMutation.isEmpty else {
            try? fileManager.removeItem(at: rollbackBackup.directory)
            throw ConfigurationTransactionError.concurrentModification(paths: changedBeforeMutation)
        }

        let restoreOrder = orderedTargetIDsForRestore(targetBackup.manifest.mutationOrder)
        var expectedCurrent = contentStateMap(current)
        var attemptedTargetIDs: [String] = []
        var inFlightTargetID: String?
        do {
            for (index, targetID) in restoreOrder.enumerated() {
                guard let target = targetByID[targetID], let wanted = desired[targetID] else { continue }
                inFlightTargetID = targetID
                attemptedTargetIDs.append(targetID)
                let mutation: ConfigurationTransactionMutation = wanted.exists
                    ? .write(targetID: targetID, data: wanted.data ?? Data())
                    : .remove(targetID: targetID)
                try hooks.beforeMutation?(index, mutation)
                try restore(wanted, to: target)
                expectedCurrent[targetID] = wanted.contentState
                inFlightTargetID = nil
                try hooks.afterMutation?(index, mutation)
            }

            let installed = try snapshotAll()
            let differences = contentDifferences(expected: desired, actual: installed)
            guard differences.isEmpty else {
                throw ConfigurationTransactionError.concurrentModification(paths: differences)
            }
            try hooks.beforeValidation?()
            do { try validate(publicState(from: installed)) }
            catch { throw ConfigurationTransactionError.validationFailed(error.localizedDescription) }
            let validated = try snapshotAll()
            let validationDifferences = contentDifferences(expected: desired, actual: validated)
            guard validationDifferences.isEmpty else {
                throw ConfigurationTransactionError.concurrentModification(paths: validationDifferences)
            }
            try? fileManager.removeItem(at: rollbackBackup.directory)
            return ConfigurationTransactionResult(
                action: .restored,
                changedTargetIDs: restoreOrder.filter { current[$0]?.contentState != desired[$0]?.contentState },
                backupURL: targetBackup.directory,
                warnings: []
            )
        } catch {
            let syntheticInFlight = inFlightTargetID.flatMap { targetID -> ConfigurationTransactionMutation? in
                guard let wanted = desired[targetID] else { return nil }
                return wanted.exists
                    ? .write(targetID: targetID, data: wanted.data ?? Data())
                    : .remove(targetID: targetID)
            }
            throw rollbackAfterFailure(
                originalError: error,
                original: current,
                backup: rollbackBackup,
                mutationOrder: restoreOrder,
                attemptedTargetIDs: attemptedTargetIDs,
                expectedCurrent: expectedCurrent,
                inFlightMutation: syntheticInFlight
            )
        }
    }

    func latestBackupURL() throws -> URL? {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try latestCompletedBackup()?.directory
    }

    /// Supplies callers with the same bounded, no-follow snapshot used by
    /// apply and restore. Adapters must use this for preview and inspection so
    /// read-only operations cannot bypass the transaction's path checks.
    func withSnapshot<T>(
        _ body: (ConfigurationTransactionState) throws -> T
    ) throws -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body(publicState(from: snapshotAll()))
    }

    /// Builds and bounds-checks a read-only plan from the same stable snapshot
    /// used by `apply`. Preview callers receive mutations only inside the
    /// closure so payloads are not accidentally rendered by an error value.
    func withValidatedPlan<T>(
        plan: Plan,
        _ body: (
            ConfigurationTransactionState,
            [ConfigurationTransactionMutation]
        ) throws -> T
    ) throws -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        let state = publicState(from: try snapshotAll())
        let mutations = try validatedMutations(plan(state))
        return try body(state, mutations)
    }

    // MARK: - Snapshot and plans

    private struct ContentState: Equatable {
        let exists: Bool
        let data: Data?
        let permissions: Int?
    }

    private struct Revision: Equatable {
        let exists: Bool
        let device: UInt64?
        let inode: UInt64?
        let mode: UInt16?
        let size: Int64?
        let modifiedSeconds: Int64?
        let modifiedNanoseconds: Int64?
        let sha256: String?
    }

    private struct Snapshot {
        let target: ConfigurationTransactionTarget
        let exists: Bool
        let data: Data?
        let permissions: Int?
        let revision: Revision

        var contentState: ContentState {
            ContentState(exists: exists, data: data, permissions: permissions)
        }
    }

    private func snapshotAll() throws -> [String: Snapshot] {
        var lastChangedPaths = targets.map { $0.url.path }
        for attempt in 0..<Self.stableSnapshotAttemptLimit {
            var candidate: [String: Snapshot] = [:]
            for (index, target) in targets.enumerated() {
                candidate[target.id] = try snapshot(target)
                try hooks.afterSnapshotTargetRead?(attempt, index, target.id)
            }

            // A second complete pass makes the multi-file view linearizable:
            // equal revisions mean every target remained stable across an
            // interval shared by the two ordered passes. SHA-256 is part of a
            // revision so same-size in-place rewrites are detected as well.
            let verification = try snapshotPass()
            let changedPaths = casDifferences(expected: candidate, actual: verification)
            if changedPaths.isEmpty { return candidate }
            lastChangedPaths = changedPaths
        }
        throw ConfigurationTransactionError.concurrentModification(paths: lastChangedPaths)
    }

    private func snapshotPass() throws -> [String: Snapshot] {
        var result: [String: Snapshot] = [:]
        for target in targets {
            result[target.id] = try snapshot(target)
        }
        return result
    }

    private func snapshot(_ target: ConfigurationTransactionTarget) throws -> Snapshot {
        try assertPathStillCanonical(target.url, label: "目标文件")
        var metadata = stat()
        if lstat(target.url.path, &metadata) != 0 {
            if errno == ENOENT {
                return Snapshot(
                    target: target,
                    exists: false,
                    data: nil,
                    permissions: nil,
                    revision: Revision(
                        exists: false, device: nil, inode: nil, mode: nil, size: nil,
                        modifiedSeconds: nil, modifiedNanoseconds: nil, sha256: nil
                    )
                )
            }
            throw ConfigurationTransactionError.fileOperation(Self.posixMessage("无法读取文件状态", path: target.url.path))
        }

        let fileType = metadata.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) {
            throw ConfigurationTransactionError.unsafePath("目标文件不能是符号链接：\(target.url.path)")
        }
        guard fileType == mode_t(S_IFREG) else {
            throw ConfigurationTransactionError.unsafePath("目标路径不是普通文件：\(target.url.path)")
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(target.maximumByteCount) else {
            throw ConfigurationTransactionError.fileTooLarge(
                path: target.url.path,
                maximumByteCount: target.maximumByteCount
            )
        }

        let descriptor = Darwin.open(target.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ConfigurationTransactionError.fileOperation(Self.posixMessage("无法安全打开文件", path: target.url.path))
        }
        defer { Darwin.close(descriptor) }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_dev == metadata.st_dev,
              openedMetadata.st_ino == metadata.st_ino,
              openedMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationTransactionError.concurrentModification(paths: [target.url.path])
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw mapFileError(error)
        }
        guard data.count <= target.maximumByteCount else {
            throw ConfigurationTransactionError.fileTooLarge(
                path: target.url.path,
                maximumByteCount: target.maximumByteCount
            )
        }
        let permissions = Int(openedMetadata.st_mode & 0o777)
        return Snapshot(
            target: target,
            exists: true,
            data: data,
            permissions: permissions,
            revision: Revision(
                exists: true,
                device: UInt64(openedMetadata.st_dev),
                inode: UInt64(openedMetadata.st_ino),
                mode: UInt16(openedMetadata.st_mode & 0o777),
                size: Int64(openedMetadata.st_size),
                modifiedSeconds: Int64(openedMetadata.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(openedMetadata.st_mtimespec.tv_nsec),
                sha256: Self.sha256(data)
            )
        )
    }

    private func publicState(from snapshots: [String: Snapshot]) -> ConfigurationTransactionState {
        ConfigurationTransactionState(files: Dictionary(uniqueKeysWithValues: snapshots.map { id, snapshot in
            (id, ConfigurationTransactionState.File(
                targetID: id,
                url: snapshot.target.url,
                exists: snapshot.exists,
                byteCount: snapshot.data?.count ?? 0,
                permissions: snapshot.permissions,
                sha256: snapshot.revision.sha256,
                contents: snapshot.data
            ))
        }))
    }

    private func validatedMutations(
        _ mutations: [ConfigurationTransactionMutation]
    ) throws -> [ConfigurationTransactionMutation] {
        var seen: Set<String> = []
        for mutation in mutations {
            guard let target = targetByID[mutation.targetID] else {
                throw ConfigurationTransactionError.invalidDefinition("事务引用了未声明的目标：\(mutation.targetID)")
            }
            guard seen.insert(mutation.targetID).inserted else {
                throw ConfigurationTransactionError.invalidDefinition("同一目标在事务中只能出现一次：\(mutation.targetID)")
            }
            if case .write(_, let data) = mutation, data.count > target.maximumByteCount {
                throw ConfigurationTransactionError.fileTooLarge(
                    path: target.url.path,
                    maximumByteCount: target.maximumByteCount
                )
            }
        }
        return mutations
    }

    private func desiredState(
        after mutations: [ConfigurationTransactionMutation],
        from original: [String: Snapshot]
    ) throws -> [String: Snapshot] {
        var desired = original
        for mutation in mutations {
            guard let target = targetByID[mutation.targetID] else { continue }
            switch mutation {
            case .write(_, let data):
                desired[target.id] = syntheticSnapshot(target: target, data: data, permissions: target.writePermissions)
            case .remove:
                desired[target.id] = syntheticSnapshot(target: target, data: nil, permissions: nil)
            }
        }
        return desired
    }

    private func syntheticSnapshot(
        target: ConfigurationTransactionTarget,
        data: Data?,
        permissions: Int?
    ) -> Snapshot {
        let exists = data != nil
        return Snapshot(
            target: target,
            exists: exists,
            data: data,
            permissions: permissions,
            revision: Revision(
                exists: exists, device: nil, inode: nil,
                mode: permissions.map(UInt16.init), size: data.map { Int64($0.count) },
                modifiedSeconds: nil, modifiedNanoseconds: nil, sha256: data.map(Self.sha256)
            )
        )
    }

    private func desiredContentState(for mutation: ConfigurationTransactionMutation) throws -> ContentState {
        guard let target = targetByID[mutation.targetID] else {
            throw ConfigurationTransactionError.invalidDefinition("未知目标：\(mutation.targetID)")
        }
        switch mutation {
        case .write(_, let data):
            return ContentState(exists: true, data: data, permissions: target.writePermissions)
        case .remove:
            return ContentState(exists: false, data: nil, permissions: nil)
        }
    }

    private func contentStateMap(_ snapshots: [String: Snapshot]) -> [String: ContentState] {
        snapshots.mapValues(\.contentState)
    }

    private func contentStatesEqual(_ lhs: [String: Snapshot], _ rhs: [String: Snapshot]) -> Bool {
        contentStateMap(lhs) == contentStateMap(rhs)
    }

    private func casDifferences(
        expected: [String: Snapshot],
        actual: [String: Snapshot]
    ) -> [String] {
        targets.compactMap { target in
            expected[target.id]?.revision == actual[target.id]?.revision ? nil : target.url.path
        }
    }

    private func contentDifferences(
        expected: [String: Snapshot],
        actual: [String: Snapshot]
    ) -> [String] {
        targets.compactMap { target in
            expected[target.id]?.contentState == actual[target.id]?.contentState ? nil : target.url.path
        }
    }

    // MARK: - Mutations and rollback

    private func execute(_ mutation: ConfigurationTransactionMutation) throws {
        guard let target = targetByID[mutation.targetID] else {
            throw ConfigurationTransactionError.invalidDefinition("未知目标：\(mutation.targetID)")
        }
        switch mutation {
        case .write(_, let data): try atomicWrite(data, to: target.url, permissions: target.writePermissions)
        case .remove: try removeRegularFileIfPresent(at: target.url)
        }
    }

    private func restore(_ snapshot: Snapshot, to target: ConfigurationTransactionTarget) throws {
        guard snapshot.exists, let data = snapshot.data else {
            try removeRegularFileIfPresent(at: target.url)
            return
        }
        let permissions = restorationPermissions(
            snapshotPermissions: snapshot.permissions,
            target: target
        )
        try atomicWrite(data, to: target.url, permissions: permissions)
    }

    private func restorationPermissions(
        snapshotPermissions: Int?,
        target: ConfigurationTransactionTarget
    ) -> Int {
        // Executable credential helpers must never regain historical group or
        // world access. Ordinary configuration targets deliberately preserve
        // their original mode byte-for-byte on restore.
        if target.sensitivity == .secret || target.writePermissions == 0o700 {
            return target.writePermissions
        }
        return snapshotPermissions ?? target.writePermissions
    }

    private func restorableContentState(
        _ snapshot: Snapshot,
        target: ConfigurationTransactionTarget
    ) -> ContentState {
        guard snapshot.exists else {
            return ContentState(exists: false, data: nil, permissions: nil)
        }
        return ContentState(
            exists: true,
            data: snapshot.data,
            permissions: restorationPermissions(
                snapshotPermissions: snapshot.permissions,
                target: target
            )
        )
    }

    private func rollbackAfterFailure(
        originalError: Error,
        original: [String: Snapshot],
        backup: BackupSnapshot,
        mutationOrder: [String],
        attemptedTargetIDs: [String],
        expectedCurrent: [String: ContentState],
        inFlightMutation: ConfigurationTransactionMutation?
    ) -> ConfigurationTransactionError {
        let originalMessage = originalError.localizedDescription
        let current: [String: Snapshot]
        do { current = try snapshotAll() }
        catch {
            return .rollbackFailed(
                original: originalMessage,
                rollback: error.localizedDescription,
                recoveryBackupURL: backup.directory
            )
        }

        let inFlightID = inFlightMutation?.targetID
        let inFlightDesired = inFlightMutation.flatMap { try? desiredContentState(for: $0) }
        let conflicts = targets.compactMap { target -> String? in
            guard let actual = current[target.id]?.contentState,
                  let expected = expectedCurrent[target.id] else { return target.url.path }
            if actual == expected { return nil }
            if target.id == inFlightID,
               (actual == inFlightDesired || actual == original[target.id]?.contentState) {
                return nil
            }
            return target.url.path
        }
        let attempted = Set(attemptedTargetIDs)
        let conflictingPaths = Set(conflicts)
        let rollbackOrder = Array(mutationOrder.reversed()).filter { targetID in
            guard attempted.contains(targetID), let target = targetByID[targetID] else { return false }
            return !conflictingPaths.contains(target.url.path)
        }
        do {
            for targetID in rollbackOrder {
                guard let target = targetByID[targetID], let snapshot = original[targetID] else { continue }
                try restore(snapshot, to: target)
            }
            let restored = try snapshotAll()
            let differences = targets.compactMap { target -> String? in
                guard !conflictingPaths.contains(target.url.path) else { return nil }
                guard let originalSnapshot = original[target.id] else { return target.url.path }
                let expected = attempted.contains(target.id)
                    ? restorableContentState(originalSnapshot, target: target)
                    : originalSnapshot.contentState
                return expected == restored[target.id]?.contentState
                    ? nil
                    : target.url.path
            }
            guard differences.isEmpty else {
                throw ConfigurationTransactionError.concurrentModification(paths: differences)
            }
            if conflicts.isEmpty {
                try fileManager.removeItem(at: backup.directory)
            } else {
                return .rollbackConflict(
                    original: originalMessage,
                    paths: conflicts,
                    recoveryBackupURL: backup.directory
                )
            }
            return mapFileError(originalError)
        } catch {
            return .rollbackFailed(
                original: originalMessage,
                rollback: error.localizedDescription,
                recoveryBackupURL: backup.directory
            )
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL, permissions: Int) throws {
        try assertPathStillCanonical(destination, label: "目标文件")
        let parent = destination.deletingLastPathComponent()
        try ensureDirectory(parent, newDirectoryPermissions: 0o700, hardenExisting: false)
        try assertPathStillCanonical(destination, label: "目标文件")
        if fileManager.fileExists(atPath: destination.path) {
            guard let target = targetByID.values.first(where: { $0.url == destination }) else {
                throw ConfigurationTransactionError.invalidDefinition("未知目标路径：\(destination.path)")
            }
            _ = try snapshot(target)
        }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).yconnect-\(UUID().uuidString.lowercased()).tmp"
        )
        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: permissions]
            ) else {
                throw ConfigurationTransactionError.fileOperation("无法创建临时文件：\(temporary.path)")
            }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            try assertPathStillCanonical(destination, label: "目标文件")
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw mapFileError(error)
        }
    }

    private func removeRegularFileIfPresent(at url: URL) throws {
        try assertPathStillCanonical(url, label: "目标文件")
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw ConfigurationTransactionError.fileOperation(Self.posixMessage("无法读取文件状态", path: url.path))
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationTransactionError.unsafePath("拒绝删除非普通文件：\(url.path)")
        }
        do { try fileManager.removeItem(at: url) }
        catch { throw mapFileError(error) }
    }

    // MARK: - Backup format

    private enum BackupKind {
        case apply
        case temporaryRollback
    }

    private struct BackupManifest: Codable {
        struct Entry: Codable {
            let targetID: String
            let targetPath: String
            let sensitivity: ConfigurationTransactionTarget.Sensitivity
            let existed: Bool
            let permissions: Int?
            let byteCount: Int
            let sha256: String?
            let payloadFile: String?
        }

        let schemaVersion: Int
        let transactionIdentifier: String
        let createdAtNanoseconds: UInt64
        let operationCompleted: Bool
        let mutationOrder: [String]
        let entries: [Entry]
    }

    private struct BackupSnapshot {
        let directory: URL
        let manifest: BackupManifest

        var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }
        private static let manifestName = ConfigurationTransactionCoordinator.manifestName
    }

    private func createBackup(
        from snapshots: [String: Snapshot],
        mutationOrder: [String],
        kind: BackupKind
    ) throws -> BackupSnapshot {
        try ensurePrivateBackupRoot()
        let nanoseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000))
        let name: String
        switch kind {
        case .apply:
            name = String(format: "%020llu", nanoseconds) + "-" + UUID().uuidString.lowercased()
        case .temporaryRollback:
            name = ".rollback-\(UUID().uuidString.lowercased())"
        }
        let requestedDirectory = backupsDirectory.appendingPathComponent(name, isDirectory: true)
        try createPrivateDirectory(requestedDirectory)
        let directory = requestedDirectory.resolvingSymlinksInPath().standardizedFileURL

        var entries: [BackupManifest.Entry] = []
        do {
            for (index, target) in targets.enumerated() {
                guard let snapshot = snapshots[target.id] else { continue }
                let payloadName = snapshot.exists ? String(format: "payload-%04d.bin", index) : nil
                if let payloadName, let data = snapshot.data {
                    try atomicWriteBackupPayload(data, to: directory.appendingPathComponent(payloadName))
                }
                entries.append(BackupManifest.Entry(
                    targetID: target.id,
                    targetPath: target.url.path,
                    sensitivity: target.sensitivity,
                    existed: snapshot.exists,
                    permissions: snapshot.permissions,
                    byteCount: snapshot.data?.count ?? 0,
                    sha256: snapshot.data.map(Self.sha256),
                    payloadFile: payloadName
                ))
            }
            let manifest = BackupManifest(
                schemaVersion: Self.manifestSchemaVersion,
                transactionIdentifier: identifier,
                createdAtNanoseconds: nanoseconds,
                operationCompleted: false,
                mutationOrder: mutationOrder,
                entries: entries
            )
            let backup = BackupSnapshot(directory: directory, manifest: manifest)
            try writeManifest(manifest, to: backup.manifestURL)
            return backup
        } catch {
            try? fileManager.removeItem(at: directory)
            throw mapFileError(error)
        }
    }

    private func markBackupCompleted(_ snapshot: BackupSnapshot) throws {
        let manifest = BackupManifest(
            schemaVersion: snapshot.manifest.schemaVersion,
            transactionIdentifier: snapshot.manifest.transactionIdentifier,
            createdAtNanoseconds: snapshot.manifest.createdAtNanoseconds,
            operationCompleted: true,
            mutationOrder: snapshot.manifest.mutationOrder,
            entries: snapshot.manifest.entries
        )
        try writeManifest(manifest, to: snapshot.manifestURL)
    }

    private func writeManifest(_ manifest: BackupManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWriteBackupPayload(try encoder.encode(manifest), to: url)
    }

    private func atomicWriteBackupPayload(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try ensureDirectory(parent, newDirectoryPermissions: 0o700, hardenExisting: true)
        try Self.rejectFinalSymbolicLink(at: destination, fileManager: fileManager, label: "备份文件")
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).yconnect-\(UUID().uuidString.lowercased()).tmp"
        )
        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ConfigurationTransactionError.fileOperation("无法创建备份临时文件：\(temporary.path)")
            }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw mapFileError(error)
        }
    }

    private func latestCompletedBackup() throws -> BackupSnapshot? {
        let backups = try completedBackupsNewestFirst()
        guard let first = backups.first else { return nil }
        _ = try loadBackupState(first)
        return first
    }

    private func completedBackupsNewestFirst() throws -> [BackupSnapshot] {
        guard fileManager.fileExists(atPath: backupsDirectory.path) else { return [] }
        try ensurePrivateBackupRoot()
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: backupsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch { throw mapFileError(error) }

        var snapshots: [BackupSnapshot] = []
        for discoveredDirectory in urls {
            let values = try discoveredDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ConfigurationTransactionError.invalidBackup(
                    "备份目录包含无效条目：\(discoveredDirectory.lastPathComponent)"
                )
            }
            // FileManager may spell macOS temporary paths as `/private/var`
            // even when the coordinator was initialized with `/var`. Rebase the
            // child name so apply and restore return one stable URL identity.
            let directory = backupsDirectory.appendingPathComponent(
                discoveredDirectory.lastPathComponent,
                isDirectory: true
            )
            let manifestURL = directory.appendingPathComponent(Self.manifestName)
            let data = try readPrivateBackupFile(manifestURL, maximumByteCount: 1_024 * 1_024)
            let manifest: BackupManifest
            do { manifest = try JSONDecoder().decode(BackupManifest.self, from: data) }
            catch { throw ConfigurationTransactionError.invalidBackup("备份 manifest 已损坏：\(directory.lastPathComponent)") }
            try validateManifest(manifest, directory: directory)
            guard manifest.operationCompleted else { continue }
            snapshots.append(BackupSnapshot(directory: directory, manifest: manifest))
        }
        return snapshots.sorted {
            if $0.manifest.createdAtNanoseconds != $1.manifest.createdAtNanoseconds {
                return $0.manifest.createdAtNanoseconds > $1.manifest.createdAtNanoseconds
            }
            return $0.directory.lastPathComponent > $1.directory.lastPathComponent
        }
    }

    private func validateManifest(_ manifest: BackupManifest, directory: URL) throws {
        guard manifest.schemaVersion == Self.manifestSchemaVersion else {
            throw ConfigurationTransactionError.invalidBackup("不支持的备份版本：\(manifest.schemaVersion)")
        }
        guard manifest.transactionIdentifier == identifier else {
            throw ConfigurationTransactionError.invalidBackup("备份不属于当前客户端：\(directory.lastPathComponent)")
        }
        guard Set(manifest.entries.map(\.targetID)).count == targets.count,
              manifest.entries.count == targets.count else {
            throw ConfigurationTransactionError.invalidBackup("备份目标集合不完整：\(directory.lastPathComponent)")
        }
        for entry in manifest.entries {
            guard let target = targetByID[entry.targetID],
                  entry.targetPath == target.url.path,
                  entry.sensitivity == target.sensitivity,
                  entry.byteCount >= 0,
                  entry.byteCount <= target.maximumByteCount else {
                throw ConfigurationTransactionError.invalidBackup("备份目标与当前配置不匹配：\(entry.targetID)")
            }
            guard entry.existed == (entry.payloadFile != nil),
                  entry.existed == (entry.sha256 != nil) else {
                throw ConfigurationTransactionError.invalidBackup("备份文件描述无效：\(entry.targetID)")
            }
            if let payloadFile = entry.payloadFile {
                guard payloadFile.range(of: #"^payload-[0-9]{4}\.bin$"#, options: .regularExpression) != nil else {
                    throw ConfigurationTransactionError.invalidBackup("备份文件名无效：\(payloadFile)")
                }
            }
        }
        guard Set(manifest.mutationOrder).count == manifest.mutationOrder.count,
              manifest.mutationOrder.allSatisfy({ targetByID[$0] != nil }) else {
            throw ConfigurationTransactionError.invalidBackup("备份写入顺序无效：\(directory.lastPathComponent)")
        }
    }

    private func loadBackupState(_ backup: BackupSnapshot) throws -> [String: Snapshot] {
        try validateManifest(backup.manifest, directory: backup.directory)
        var result: [String: Snapshot] = [:]
        for entry in backup.manifest.entries {
            guard let target = targetByID[entry.targetID] else { continue }
            if entry.existed {
                guard let payloadFile = entry.payloadFile, let expectedHash = entry.sha256 else {
                    throw ConfigurationTransactionError.invalidBackup("备份缺少 payload：\(entry.targetID)")
                }
                let data = try readPrivateBackupFile(
                    backup.directory.appendingPathComponent(payloadFile),
                    maximumByteCount: target.maximumByteCount
                )
                guard data.count == entry.byteCount, Self.sha256(data) == expectedHash else {
                    throw ConfigurationTransactionError.invalidBackup("备份完整性校验失败：\(entry.targetID)")
                }
                let permissions = restorationPermissions(
                    snapshotPermissions: entry.permissions,
                    target: target
                )
                result[target.id] = syntheticSnapshot(target: target, data: data, permissions: permissions)
            } else {
                result[target.id] = syntheticSnapshot(target: target, data: nil, permissions: nil)
            }
        }
        return result
    }

    private func readPrivateBackupFile(_ url: URL, maximumByteCount: Int) throws -> Data {
        try Self.rejectFinalSymbolicLink(at: url, fileManager: fileManager, label: "备份文件")
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationTransactionError.invalidBackup("备份缺少普通文件：\(url.path)")
        }
        guard Int(metadata.st_mode & 0o777) == 0o600 else {
            throw ConfigurationTransactionError.invalidBackup("备份文件权限不是 0600：\(url.path)")
        }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(maximumByteCount) else {
            throw ConfigurationTransactionError.invalidBackup("备份文件过大：\(url.path)")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ConfigurationTransactionError.invalidBackup("无法安全打开备份文件：\(url.path)")
        }
        defer { Darwin.close(descriptor) }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_dev == metadata.st_dev,
              openedMetadata.st_ino == metadata.st_ino,
              openedMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationTransactionError.invalidBackup("备份文件在读取时发生变化：\(url.path)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            let data = try handle.readToEnd() ?? Data()
            guard data.count <= maximumByteCount else {
                throw ConfigurationTransactionError.invalidBackup("备份文件过大：\(url.path)")
            }
            return data
        } catch {
            throw mapFileError(error)
        }
    }

    private func pruneCompletedBackupsKeepingNewest(_ limit: Int) -> String? {
        do {
            let backups = try completedBackupsNewestFirst()
            for backup in backups.dropFirst(limit) {
                try fileManager.removeItem(at: backup.directory)
            }
            return nil
        } catch {
            return "配置已应用，但清理旧备份失败：\(error.localizedDescription)"
        }
    }

    private func orderedTargetIDsForRestore(_ mutationOrder: [String]) -> [String] {
        var result = Array(mutationOrder.reversed())
        let included = Set(result)
        result.append(contentsOf: targets.map(\.id).filter { !included.contains($0) })
        return result
    }

    // MARK: - Filesystem safety

    private func ensurePrivateBackupRoot() throws {
        try assertPathStillCanonical(backupsDirectory, label: "备份目录")
        try ensureDirectory(backupsDirectory, newDirectoryPermissions: 0o700, hardenExisting: true)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try assertPathStillCanonical(url, label: "备份快照目录")
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { throw mapFileError(error) }
    }

    private func ensureDirectory(
        _ url: URL,
        newDirectoryPermissions: Int,
        hardenExisting: Bool
    ) throws {
        try assertPathStillCanonical(url, label: "目录")
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ConfigurationTransactionError.unsafePath("路径不是目录：\(url.path)")
            }
            try Self.rejectFinalSymbolicLink(at: url, fileManager: fileManager, label: "目录")
            if hardenExisting {
                do { try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
                catch { throw mapFileError(error) }
            }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: newDirectoryPermissions], ofItemAtPath: url.path)
        } catch { throw mapFileError(error) }
    }

    private func assertPathStillCanonical(_ url: URL, label: String) throws {
        try Self.rejectFinalSymbolicLink(at: url, fileManager: fileManager, label: label)
        let current = Self.canonicalizedURL(url, fileManager: fileManager)
        guard current.path == url.path else {
            throw ConfigurationTransactionError.unsafePath("\(label)路径出现符号链接变化：\(url.path)")
        }
    }

    private static func rejectFinalSymbolicLink(
        at url: URL,
        fileManager: FileManager,
        label: String
    ) throws {
        _ = fileManager
        var metadata = stat()
        errno = 0
        if lstat(url.standardizedFileURL.path, &metadata) == 0 {
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw ConfigurationTransactionError.unsafePath("\(label)不能是符号链接：\(url.path)")
            }
            return
        }
        if errno != ENOENT {
            throw ConfigurationTransactionError.fileOperation(
                Self.posixMessage("无法检查路径", path: url.standardizedFileURL.path)
            )
        }
    }

    /// Resolves the deepest existing ancestor. This both normalizes macOS's
    /// `/var` -> `/private/var` path and freezes the directory chain used later.
    private static func canonicalizedURL(_ input: URL, fileManager: FileManager) -> URL {
        ConfigurationPathCanonicalizer.canonicalizedURL(input, fileManager: fileManager)
    }

    private static func isDescendantOrEqual(_ url: URL, of directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = directory.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isValidStableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func posixMessage(_ operation: String, path: String) -> String {
        "\(operation)：\(path)（\(String(cString: strerror(errno)))）"
    }

    private func mapFileError(_ error: Error) -> ConfigurationTransactionError {
        if let typed = error as? ConfigurationTransactionError { return typed }
        return .fileOperation(error.localizedDescription)
    }
}
