import Foundation
import CryptoKit
import Darwin

struct OpenCodeModelOption: Equatable, Hashable, Identifiable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct OpenCodeConfigurationResult: Equatable {
    enum Action: String, Equatable {
        case applied
        case unchanged
        case restored
    }

    let action: Action
    let configURL: URL
    let secretURL: URL
    let backupURL: URL?
    let modelID: String?
    let createdConfig: Bool
    let changed: Bool
    let message: String
}

struct OpenCodeConfigurationStatus: Equatable {
    let configURL: URL
    let secretURL: URL
    let configExists: Bool
    let providerConfigured: Bool
    let selectedModelID: String?
    let configuredModelIDs: [String]
    let secretReferenceIsSafe: Bool
    let secretExists: Bool
    let secretPermissionsAreSecure: Bool
    let latestBackupURL: URL?
}

struct OpenCodeConfigurationPreview: Equatable {
    let configuration: String
    let configURL: URL
    let secretURL: URL
    let selectedModelID: String
}

enum OpenCodeConfigurationError: LocalizedError, Equatable {
    case invalidAPIKey(String)
    case invalidModel(String)
    case invalidConfiguration(String)
    case fileOperation(String)
    case noBackup
    case rollbackConflict(original: String, paths: [String], recoveryBackupURL: URL)
    case rollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let message),
             .invalidModel(let message),
             .invalidConfiguration(let message),
             .fileOperation(let message):
            return message
        case .noBackup:
            return "没有可恢复的 OpenCode 配置备份"
        case .rollbackConflict(let original, let paths, let recoveryBackupURL):
            return "配置操作失败（\(original)）；检测到外部修改，未覆盖这些文件：\(paths.joined(separator: ", "))。恢复快照：\(recoveryBackupURL.path)"
        case .rollbackFailed(let original, let rollback):
            return "配置操作失败（\(original)），并且自动回滚失败（\(rollback)）"
        }
    }
}

/// Test-only fault injection at the same boundary used by the shared client
/// transaction coordinator. Production callers use `.none`.
struct OpenCodeTransactionHooks {
    var beforeValidation: (() throws -> Void)?

    static let none = OpenCodeTransactionHooks()
}

/// Safely installs the YakCool provider into OpenCode's global configuration.
///
/// The API key is deliberately kept out of `opencode.json`. It is written to a
/// mode-0600 file and referenced through OpenCode's `{file:...}` substitution.
final class OpenCodeConfigurator {
    static let providerID = "yakcool"
    static let providerPackage = "@ai-sdk/openai-compatible"
    static let gatewayBaseURL = "https://aibalance.yaklang.com/v1"
    static let schemaURL = "https://opencode.ai/config.json"

    let configurationURL: URL
    let applicationSupportDirectory: URL
    let secretURL: URL
    let backupsDirectory: URL

    private let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter
    private let transactionHooks: OpenCodeTransactionHooks

    init(
        configurationURL: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        transactionHooks: OpenCodeTransactionHooks = .none
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        let configurationCandidate = configurationURL
            ?? home.appendingPathComponent(".config/opencode/opencode.json", isDirectory: false)
        let supportCandidate = applicationSupportDirectory
            ?? home.appendingPathComponent("Library/Application Support/YConnect", isDirectory: true)
        // Dotfile managers commonly symlink `opencode.json`; operate on its real
        // target so an atomic replacement does not break or reject that link.
        self.configurationURL = Self.canonicalizedURL(configurationCandidate, fileManager: fileManager)
        self.applicationSupportDirectory = Self.canonicalizedURL(supportCandidate, fileManager: fileManager)
        self.secretURL = self.applicationSupportDirectory
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("opencode-yakcool-key", isDirectory: false)
        self.backupsDirectory = self.applicationSupportDirectory
            .appendingPathComponent("Backups/OpenCode", isDirectory: true)
        self.fileManager = fileManager
        self.transactionHooks = transactionHooks

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    func apply(
        apiKey: String,
        models: [OpenCodeModelOption],
        selectedModelID: String
    ) throws -> OpenCodeConfigurationResult {
        try validateAPIKey(apiKey)
        try rejectManagedSymbolicLink(at: secretURL, label: "OpenCode 密钥文件")
        try rejectManagedSymbolicLink(at: backupsDirectory, label: "OpenCode 备份目录")
        let normalizedModels = try normalizeModels(models, selectedModelID: selectedModelID)

        let originalState = try stableManagedState()
        let existingConfigData = originalState[.configuration].data
        let existingSecretData = originalState[.secret].data
        let root = try parseRootObject(existingConfigData)
        let desiredRoot = try updatedRoot(
            root,
            models: normalizedModels,
            selectedModelID: selectedModelID
        )
        let desiredConfigData = try serializedConfiguration(desiredRoot)
        let desiredSecretData = Data(apiKey.utf8)

        guard desiredConfigData.range(of: desiredSecretData) == nil else {
            throw OpenCodeConfigurationError.invalidConfiguration(
                "为防止凭据泄露，OpenCode 配置中不能包含 API Key 明文"
            )
        }

        let configAlreadyMatches = try semanticallyEqual(existingConfigData, desiredConfigData)
        let secretAlreadyMatches = existingSecretData == desiredSecretData
        let createdConfig = existingConfigData == nil

        if configAlreadyMatches && secretAlreadyMatches {
            try enforceSecretPermissionsIfPresent()
            return OpenCodeConfigurationResult(
                action: .unchanged,
                configURL: configurationURL,
                secretURL: secretURL,
                backupURL: nil,
                modelID: selectedModelID,
                createdConfig: false,
                changed: false,
                message: "OpenCode 已在使用所选 YakCool 模型"
            )
        }

        let desiredState = ManagedState(
            configuration: ManagedFileState(data: desiredConfigData, permissions: 0o600),
            secret: ManagedFileState(data: desiredSecretData, permissions: 0o600)
        )
        let backup = try createBackup(from: originalState, kind: .apply)

        let mutationOrder: [ManagedTarget] = [.secret, .configuration]
        var expectedCurrent = originalState
        var attemptedTargets: [ManagedTarget] = []
        var inFlightTarget: ManagedTarget?
        do {
            guard try stableManagedState() == originalState else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 配置在操作过程中被其他程序修改，请重试"
                )
            }
            try ensurePrivateDirectory(secretURL.deletingLastPathComponent())
            for target in mutationOrder {
                inFlightTarget = target
                attemptedTargets.append(target)
                try restoreFileState(desiredState[target], target: target)
                expectedCurrent[target] = desiredState[target]
                inFlightTarget = nil
            }

            let installed = try stableManagedState()
            guard installed == desiredState else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 写入后的内容或权限与本次计划不一致"
                )
            }
            try transactionHooks.beforeValidation?()
            try validateInstalledConfiguration(
                state: installed,
                expectedConfigData: desiredConfigData,
                expectedSecretData: desiredSecretData,
                expectedModelID: selectedModelID,
                forbiddenSecret: desiredSecretData
            )
            guard try stableManagedState() == desiredState else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 配置在写后校验期间被其他程序修改"
                )
            }
            try markBackupCompleted(backup)
        } catch {
            guard !attemptedTargets.isEmpty else {
                try? fileManager.removeItem(at: backup.directory)
                throw mapFileError(error)
            }
            throw rollbackAfterFailure(
                originalError: error,
                original: originalState,
                recoveryBackup: backup,
                mutationOrder: mutationOrder,
                attemptedTargets: attemptedTargets,
                expectedCurrent: expectedCurrent,
                inFlightTarget: inFlightTarget,
                inFlightDesired: inFlightTarget.map { desiredState[$0] }
            )
        }

        // Retention is deliberately outside the write/rollback transaction:
        // failure to remove an old snapshot must never turn a successful
        // configuration install into a reported failure. Only completed,
        // regular backup directories are eligible for pruning.
        try? pruneCompletedBackups(retaining: 20)

        return OpenCodeConfigurationResult(
            action: .applied,
            configURL: configurationURL,
            secretURL: secretURL,
            backupURL: backup.directory,
            modelID: selectedModelID,
            createdConfig: createdConfig,
            changed: true,
            message: "已将 OpenCode 切换到 YakCool / \(selectedModelID)"
        )
    }

    func restoreLatest() throws -> OpenCodeConfigurationResult {
        try rejectManagedSymbolicLink(at: secretURL, label: "OpenCode 密钥文件")
        try rejectManagedSymbolicLink(at: backupsDirectory, label: "OpenCode 备份目录")
        guard let target = try latestBackup() else {
            throw OpenCodeConfigurationError.noBackup
        }

        let desiredState = try managedState(from: target)
        let currentState = try stableManagedState()
        let rollbackSnapshot = try createBackup(from: currentState, kind: .temporaryRollback)

        var restoredModelID: String?
        let mutationOrder: [ManagedTarget] = desiredState[.secret].data == nil
            ? [.configuration, .secret]
            : [.secret, .configuration]
        var expectedCurrent = currentState
        var attemptedTargets: [ManagedTarget] = []
        var inFlightTarget: ManagedTarget?
        do {
            guard try stableManagedState() == currentState else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 配置在恢复过程中被其他程序修改，请重试"
                )
            }
            for managedTarget in mutationOrder {
                inFlightTarget = managedTarget
                attemptedTargets.append(managedTarget)
                try restoreFileState(desiredState[managedTarget], target: managedTarget)
                expectedCurrent[managedTarget] = desiredState[managedTarget]
                inFlightTarget = nil
            }

            let installed = try stableManagedState()
            guard installed == desiredState else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 备份恢复后的内容或权限与快照不一致"
                )
            }
            try transactionHooks.beforeValidation?()
            try validateRestoredState(installed, expected: desiredState)
            let validated = try stableManagedState()
            guard validated == desiredState else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 配置在恢复校验期间被其他程序修改"
                )
            }
            if let restoredConfig = validated[.configuration].data {
                restoredModelID = Self.yakCoolModelID(
                    from: try parseRootObject(restoredConfig)["model"] as? String ?? ""
                )
            }
        } catch {
            guard !attemptedTargets.isEmpty else {
                try? fileManager.removeItem(at: rollbackSnapshot.directory)
                throw mapFileError(error)
            }
            throw rollbackAfterFailure(
                originalError: error,
                original: currentState,
                recoveryBackup: rollbackSnapshot,
                mutationOrder: mutationOrder,
                attemptedTargets: attemptedTargets,
                expectedCurrent: expectedCurrent,
                inFlightTarget: inFlightTarget,
                inFlightDesired: inFlightTarget.map { desiredState[$0] }
            )
        }

        try? fileManager.removeItem(at: rollbackSnapshot.directory)
        return OpenCodeConfigurationResult(
            action: .restored,
            configURL: configurationURL,
            secretURL: secretURL,
            backupURL: target.directory,
            modelID: restoredModelID,
            createdConfig: target.manifest.configExisted == false,
            changed: true,
            message: "已恢复最近一次 OpenCode 配置备份"
        )
    }

    func inspect() throws -> OpenCodeConfigurationStatus {
        let data = try readRegularFileIfPresent(at: configurationURL)
        let latest = try latestBackup()?.directory
        let secretIsSymbolicLink = isSymbolicLink(at: secretURL)
        var secretIsDirectory: ObjCBool = false
        let secretExists = fileManager.fileExists(
            atPath: secretURL.path,
            isDirectory: &secretIsDirectory
        ) && !secretIsSymbolicLink && !secretIsDirectory.boolValue
        let secretPermissionsAreSecure = secretExists
            && permissionsIfPresent(at: secretURL) == 0o600

        guard let data else {
            return OpenCodeConfigurationStatus(
                configURL: configurationURL,
                secretURL: secretURL,
                configExists: false,
                providerConfigured: false,
                selectedModelID: nil,
                configuredModelIDs: [],
                secretReferenceIsSafe: false,
                secretExists: secretExists,
                secretPermissionsAreSecure: secretPermissionsAreSecure,
                latestBackupURL: latest
            )
        }

        let root = try parseRootObject(data)
        let provider = providerObject(in: root)
        let selected = (root["model"] as? String).flatMap(Self.yakCoolModelID(from:))
        let models = (provider?["models"] as? [String: Any])?.keys.sorted() ?? []
        let apiKeyValue = ((provider?["options"] as? [String: Any])?["apiKey"] as? String)
        let expectedReference = Self.fileReference(to: secretURL)
        let providerConfigured = (provider?["npm"] as? String) == Self.providerPackage
            && ((provider?["options"] as? [String: Any])?["baseURL"] as? String) == Self.gatewayBaseURL

        return OpenCodeConfigurationStatus(
            configURL: configurationURL,
            secretURL: secretURL,
            configExists: true,
            providerConfigured: providerConfigured,
            selectedModelID: selected,
            configuredModelIDs: models,
            secretReferenceIsSafe: apiKeyValue == expectedReference
                && secretExists
                && secretPermissionsAreSecure,
            secretExists: secretExists,
            secretPermissionsAreSecure: secretPermissionsAreSecure,
            latestBackupURL: latest
        )
    }

    func preview(
        models: [OpenCodeModelOption],
        selectedModelID: String
    ) throws -> OpenCodeConfigurationPreview {
        let normalizedModels = try normalizeModels(models, selectedModelID: selectedModelID)
        let existing = try readRegularFileIfPresent(at: configurationURL)
        let root = try parseRootObject(existing)
        let desired = try updatedRoot(root, models: normalizedModels, selectedModelID: selectedModelID)
        let data = try serializedConfiguration(desired)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeConfigurationError.invalidConfiguration("无法生成 UTF-8 OpenCode 配置预览")
        }
        return OpenCodeConfigurationPreview(
            configuration: text,
            configURL: configurationURL,
            secretURL: secretURL,
            selectedModelID: selectedModelID
        )
    }

    // MARK: - Configuration shaping

    private func updatedRoot(
        _ original: [String: Any],
        models: [OpenCodeModelOption],
        selectedModelID: String
    ) throws -> [String: Any] {
        var root = original
        if root["$schema"] == nil {
            root["$schema"] = Self.schemaURL
        }
        var providers: [String: Any]
        if let existing = root["provider"] {
            guard let dictionary = existing as? [String: Any] else {
                throw OpenCodeConfigurationError.invalidConfiguration(
                    "OpenCode 配置中的 provider 必须是对象"
                )
            }
            providers = dictionary
        } else {
            providers = [:]
        }

        var modelMap: [String: Any] = [:]
        for model in models {
            modelMap[model.id] = ["name": model.name]
        }

        providers[Self.providerID] = [
            "name": "YakCool",
            "npm": Self.providerPackage,
            "options": [
                "apiKey": Self.fileReference(to: secretURL),
                "baseURL": Self.gatewayBaseURL,
            ],
            "models": modelMap,
        ]
        root["provider"] = providers
        root["model"] = "\(Self.providerID)/\(selectedModelID)"
        return root
    }

    private func normalizeModels(
        _ models: [OpenCodeModelOption],
        selectedModelID: String
    ) throws -> [OpenCodeModelOption] {
        let selected = try validatedModelID(selectedModelID)
        var unique: [String: OpenCodeModelOption] = [:]
        for model in models {
            let id = try validatedModelID(model.id)
            let trimmedName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            unique[id] = OpenCodeModelOption(id: id, name: trimmedName.isEmpty ? id : trimmedName)
        }
        if unique[selected] == nil {
            unique[selected] = OpenCodeModelOption(id: selected, name: selected)
        }
        return unique.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func validatedModelID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else {
            throw OpenCodeConfigurationError.invalidModel("请选择有效的 YakCool 模型")
        }
        guard value.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OpenCodeConfigurationError.invalidModel("模型标识无效")
        }
        return value
    }

    private func validateAPIKey(_ value: String) throws {
        guard !value.isEmpty else {
            throw OpenCodeConfigurationError.invalidAPIKey("API Key 不能为空")
        }
        guard value.count <= 512,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw OpenCodeConfigurationError.invalidAPIKey("API Key 格式无效")
        }
    }

    private static func fileReference(to url: URL) -> String {
        "{file:\(url.path)}"
    }

    /// `resolvingSymlinksInPath()` does not consistently resolve an existing
    /// symlink in an ancestor when the final path has not been created yet.
    /// Resolve the deepest existing ancestor and append the missing suffix so
    /// result URLs remain stable before and after the first write (`/var` vs
    /// `/private/var` is the common macOS case).
    private static func canonicalizedURL(_ input: URL, fileManager: FileManager) -> URL {
        let standardized = input.standardizedFileURL
        var ancestor = standardized
        var missingComponents: [String] = []
        var isDirectory: ObjCBool = false

        while !fileManager.fileExists(atPath: ancestor.path, isDirectory: &isDirectory),
              ancestor.path != "/" {
            missingComponents.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }

        let resolvedAncestor: URL
        if let pointer = realpath(ancestor.path, nil) {
            defer { free(pointer) }
            resolvedAncestor = URL(fileURLWithPath: String(cString: pointer), isDirectory: isDirectory.boolValue)
        } else {
            resolvedAncestor = ancestor.resolvingSymlinksInPath()
        }
        var resolved = resolvedAncestor
        for component in missingComponents {
            resolved.appendPathComponent(component, isDirectory: false)
        }
        return resolved
    }

    private static func yakCoolModelID(from value: String) -> String? {
        let prefix = "\(providerID)/"
        guard value.hasPrefix(prefix), value.count > prefix.count else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    private func providerObject(in root: [String: Any]) -> [String: Any]? {
        (root["provider"] as? [String: Any])?[Self.providerID] as? [String: Any]
    }

    // MARK: - JSON / JSONC

    private func parseRootObject(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty else { return [:] }

        let cleaned: Data
        do {
            cleaned = try Self.normalizedJSONC(data)
        } catch let error as OpenCodeConfigurationError {
            throw error
        } catch {
            throw OpenCodeConfigurationError.invalidConfiguration(error.localizedDescription)
        }

        guard !cleaned.isEmpty,
              String(decoding: cleaned, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false else {
            return [:]
        }

        do {
            let object = try JSONSerialization.jsonObject(with: cleaned, options: [])
            guard let root = object as? [String: Any] else {
                throw OpenCodeConfigurationError.invalidConfiguration(
                    "OpenCode 配置的顶层必须是 JSON 对象"
                )
            }
            return root
        } catch let error as OpenCodeConfigurationError {
            throw error
        } catch {
            throw OpenCodeConfigurationError.invalidConfiguration(
                "无法解析 OpenCode 配置：\(error.localizedDescription)"
            )
        }
    }

    private func serializedConfiguration(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw OpenCodeConfigurationError.invalidConfiguration("OpenCode 配置包含无法序列化的值")
        }
        do {
            var data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            return data
        } catch {
            throw OpenCodeConfigurationError.invalidConfiguration(
                "无法生成 OpenCode 配置：\(error.localizedDescription)"
            )
        }
    }

    private func semanticallyEqual(_ lhs: Data?, _ rhs: Data) throws -> Bool {
        guard let lhs else { return false }
        let leftObject = try parseRootObject(lhs)
        let rightObject = try parseRootObject(rhs)
        return NSDictionary(dictionary: leftObject).isEqual(to: rightObject)
    }

    /// Removes JavaScript-style comments and trailing commas without touching
    /// comment-like text inside JSON strings.
    private static func normalizedJSONC(_ input: Data) throws -> Data {
        let bytes = Array(input)
        var commentFree: [UInt8] = []
        commentFree.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false

        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil

            if inLineComment {
                if byte == 0x0A || byte == 0x0D {
                    inLineComment = false
                    commentFree.append(byte)
                } else {
                    commentFree.append(0x20)
                }
                index += 1
                continue
            }

            if inBlockComment {
                if byte == 0x2A, next == 0x2F {
                    commentFree.append(0x20)
                    commentFree.append(0x20)
                    index += 2
                    inBlockComment = false
                } else {
                    commentFree.append((byte == 0x0A || byte == 0x0D) ? byte : 0x20)
                    index += 1
                }
                continue
            }

            if inString {
                commentFree.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                inString = true
                commentFree.append(byte)
                index += 1
            } else if byte == 0x2F, next == 0x2F {
                inLineComment = true
                commentFree.append(0x20)
                commentFree.append(0x20)
                index += 2
            } else if byte == 0x2F, next == 0x2A {
                inBlockComment = true
                commentFree.append(0x20)
                commentFree.append(0x20)
                index += 2
            } else {
                commentFree.append(byte)
                index += 1
            }
        }

        guard !inBlockComment else {
            throw OpenCodeConfigurationError.invalidConfiguration("OpenCode JSONC 包含未结束的块注释")
        }
        guard !inString else {
            throw OpenCodeConfigurationError.invalidConfiguration("OpenCode 配置包含未结束的字符串")
        }

        var result: [UInt8] = []
        result.reserveCapacity(commentFree.count)
        index = 0
        inString = false
        escaped = false
        while index < commentFree.count {
            let byte = commentFree[index]
            if inString {
                result.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                inString = true
                result.append(byte)
                index += 1
                continue
            }

            if byte == 0x2C {
                var lookahead = index + 1
                while lookahead < commentFree.count,
                      Self.isJSONWhitespace(commentFree[lookahead]) {
                    lookahead += 1
                }
                if lookahead < commentFree.count,
                   commentFree[lookahead] == 0x7D || commentFree[lookahead] == 0x5D {
                    index += 1
                    continue
                }
            }
            result.append(byte)
            index += 1
        }
        return Data(result)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    // MARK: - Backups and transactional writes

    private enum ManagedTarget: CaseIterable, Hashable {
        case configuration
        case secret
    }

    private struct ManagedFileState: Equatable {
        let data: Data?
        let permissions: Int?
    }

    private struct ManagedState: Equatable {
        var configuration: ManagedFileState
        var secret: ManagedFileState

        subscript(_ target: ManagedTarget) -> ManagedFileState {
            get {
                switch target {
                case .configuration: return configuration
                case .secret: return secret
                }
            }
            set {
                switch target {
                case .configuration: configuration = newValue
                case .secret: secret = newValue
                }
            }
        }
    }

    private enum BackupKind {
        case apply
        case temporaryRollback
    }

    private struct BackupManifest: Codable {
        let schemaVersion: Int
        let createdAt: String
        let configExisted: Bool
        let secretExisted: Bool
        let configPermissions: Int?
        let secretPermissions: Int?
        let operationCompleted: Bool?
        let createdAtNanoseconds: UInt64?
        let configSHA256: String?
        let secretSHA256: String?
    }

    private struct BackupSnapshot {
        let directory: URL
        let manifest: BackupManifest

        var configURL: URL { directory.appendingPathComponent("opencode.json") }
        var secretURL: URL { directory.appendingPathComponent("opencode-yakcool-key") }
        var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    }

    private func createBackup(from state: ManagedState, kind: BackupKind) throws -> BackupSnapshot {
        let configData = state[.configuration].data
        let secretData = state[.secret].data
        try ensurePrivateDirectory(backupsDirectory)
        let createdAt = Date()
        let createdAtNanoseconds = UInt64(max(0, createdAt.timeIntervalSince1970 * 1_000_000_000))
        let directoryName: String
        switch kind {
        case .apply:
            let timestamp = Self.backupTimestamp(createdAt)
            let ordinal = String(format: "%020llu", createdAtNanoseconds)
            directoryName = "\(timestamp)-\(ordinal)-\(UUID().uuidString.lowercased())"
        case .temporaryRollback:
            directoryName = ".restore-rollback-\(UUID().uuidString.lowercased())"
        }
        let directory = backupsDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try createNewDirectory(directory, permissions: 0o700)

        let manifest = BackupManifest(
            schemaVersion: 1,
            createdAt: isoFormatter.string(from: createdAt),
            configExisted: configData != nil,
            secretExisted: secretData != nil,
            configPermissions: configData == nil ? nil : state[.configuration].permissions,
            secretPermissions: secretData == nil ? nil : state[.secret].permissions,
            operationCompleted: kind == .temporaryRollback ? nil : false,
            createdAtNanoseconds: createdAtNanoseconds,
            configSHA256: configData.map(Self.sha256),
            secretSHA256: secretData.map(Self.sha256)
        )
        let snapshot = BackupSnapshot(directory: directory, manifest: manifest)

        do {
            if let configData {
                try atomicWrite(configData, to: snapshot.configURL, permissions: 0o600)
            }
            if let secretData {
                try atomicWrite(secretData, to: snapshot.secretURL, permissions: 0o600)
            }
            let manifestData = try JSONEncoder().encode(manifest)
            try atomicWrite(manifestData, to: snapshot.manifestURL, permissions: 0o600)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw mapFileError(error)
        }
        return snapshot
    }

    private func latestBackup() throws -> BackupSnapshot? {
        guard fileManager.fileExists(atPath: backupsDirectory.path) else { return nil }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: backupsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw mapFileError(error)
        }

        let sortedDirectories = try urls.sorted { left, right in
            let leftDate = try left.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            let rightDate = try right.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.lastPathComponent > right.lastPathComponent
        }

        for directory in sortedDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 备份目录包含无效条目：\(directory.lastPathComponent)"
                )
            }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard !isSymbolicLink(at: manifestURL),
                  let data = try readRegularFileIfPresent(at: manifestURL) else {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 备份缺少有效 manifest：\(directory.lastPathComponent)"
                )
            }
            let manifest: BackupManifest
            do {
                manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
            } catch {
                throw OpenCodeConfigurationError.fileOperation(
                    "OpenCode 备份 manifest 已损坏：\(directory.lastPathComponent)"
                )
            }
            guard manifest.schemaVersion == 1 else {
                throw OpenCodeConfigurationError.fileOperation(
                    "不支持的 OpenCode 备份版本：\(manifest.schemaVersion)"
                )
            }
            guard manifest.operationCompleted != false else { continue }
            let snapshot = BackupSnapshot(directory: directory, manifest: manifest)
            try validateBackupSnapshot(snapshot)
            return snapshot
        }
        return nil
    }

    private func validateBackupSnapshot(_ snapshot: BackupSnapshot) throws {
        if snapshot.manifest.configExisted {
            let data = try validatedBackupFileData(
                snapshot.configURL,
                label: "opencode.json",
                expectedSHA256: snapshot.manifest.configSHA256
            )
            _ = try parseRootObject(data)
        }
        if snapshot.manifest.secretExisted {
            _ = try validatedBackupFileData(
                snapshot.secretURL,
                label: "OpenCode 密钥",
                expectedSHA256: snapshot.manifest.secretSHA256
            )
        }
    }

    private func validatedBackupFileData(
        _ url: URL,
        label: String,
        expectedSHA256: String?
    ) throws -> Data {
        var isDirectory: ObjCBool = false
        guard !isSymbolicLink(at: url),
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw OpenCodeConfigurationError.fileOperation(
                "OpenCode 备份缺少有效的 \(label)：\(url.deletingLastPathComponent().lastPathComponent)"
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw mapFileError(error)
        }
        if let expectedSHA256, Self.sha256(data) != expectedSHA256 {
            throw OpenCodeConfigurationError.fileOperation(
                "OpenCode 备份的 \(label) 完整性校验失败：\(url.deletingLastPathComponent().lastPathComponent)"
            )
        }
        return data
    }

    private func managedState(from snapshot: BackupSnapshot) throws -> ManagedState {
        let configData: Data?
        let secretData: Data?
        if snapshot.manifest.configExisted {
            configData = try validatedBackupFileData(
                snapshot.configURL,
                label: "opencode.json",
                expectedSHA256: snapshot.manifest.configSHA256
            )
        } else {
            configData = nil
        }
        if snapshot.manifest.secretExisted {
            secretData = try validatedBackupFileData(
                snapshot.secretURL,
                label: "OpenCode 密钥",
                expectedSHA256: snapshot.manifest.secretSHA256
            )
        } else {
            secretData = nil
        }

        return ManagedState(
            configuration: ManagedFileState(
                data: configData,
                permissions: configData == nil ? nil : snapshot.manifest.configPermissions ?? 0o600
            ),
            // Historical secret modes are intentionally not restored. A
            // credential that survives restore is always clamped to 0600.
            secret: ManagedFileState(
                data: secretData,
                permissions: secretData == nil ? nil : 0o600
            )
        )
    }

    private func validateRestoredState(
        _ state: ManagedState,
        expected: ManagedState
    ) throws {
        guard state == expected else {
            throw OpenCodeConfigurationError.fileOperation("OpenCode 备份恢复后的内容校验失败")
        }
        if let configData = state[.configuration].data {
            _ = try parseRootObject(configData)
        }
        if state[.secret].data != nil, state[.secret].permissions != 0o600 {
            throw OpenCodeConfigurationError.fileOperation("OpenCode 密钥恢复后的权限校验失败")
        }
    }

    private func validateInstalledConfiguration(
        state: ManagedState,
        expectedConfigData: Data,
        expectedSecretData: Data,
        expectedModelID: String,
        forbiddenSecret: Data
    ) throws {
        guard let configData = state[.configuration].data else {
            throw OpenCodeConfigurationError.fileOperation("写入后找不到 OpenCode 配置")
        }
        guard configData == expectedConfigData else {
            throw OpenCodeConfigurationError.fileOperation(
                "写入后的 OpenCode 配置不是本次生成的完整内容"
            )
        }
        guard configData.range(of: forbiddenSecret) == nil else {
            throw OpenCodeConfigurationError.invalidConfiguration("OpenCode 配置意外包含 API Key 明文")
        }
        let root = try parseRootObject(configData)
        let provider = providerObject(in: root)
        guard (provider?["npm"] as? String) == Self.providerPackage,
              ((provider?["options"] as? [String: Any])?["baseURL"] as? String) == Self.gatewayBaseURL,
              ((provider?["options"] as? [String: Any])?["apiKey"] as? String)
                == Self.fileReference(to: secretURL),
              (root["model"] as? String) == "\(Self.providerID)/\(expectedModelID)" else {
            throw OpenCodeConfigurationError.invalidConfiguration("写入后的 OpenCode 配置校验失败")
        }
        guard state[.secret].data == expectedSecretData else {
            throw OpenCodeConfigurationError.fileOperation(
                "写入后的 OpenCode 密钥不是本次提交的内容"
            )
        }
        guard state[.secret].permissions == 0o600 else {
            throw OpenCodeConfigurationError.fileOperation("OpenCode 密钥写入后的权限不是 0600")
        }
    }

    private func stableManagedState() throws -> ManagedState {
        for _ in 0..<3 {
            let candidate = try managedStatePass()
            let verification = try managedStatePass()
            if candidate == verification { return candidate }
        }
        throw OpenCodeConfigurationError.fileOperation(
            "OpenCode 配置在读取过程中持续变化，请重试"
        )
    }

    private func managedStatePass() throws -> ManagedState {
        ManagedState(
            configuration: try fileState(at: configurationURL),
            secret: try fileState(at: secretURL)
        )
    }

    private func fileState(at url: URL) throws -> ManagedFileState {
        guard let data = try readRegularFileIfPresent(at: url) else {
            return ManagedFileState(data: nil, permissions: nil)
        }
        return ManagedFileState(data: data, permissions: permissionsIfPresent(at: url))
    }

    private func url(for target: ManagedTarget) -> URL {
        switch target {
        case .configuration: return configurationURL
        case .secret: return secretURL
        }
    }

    private func restoreFileState(_ state: ManagedFileState, target: ManagedTarget) throws {
        let permissions = state.data == nil ? 0o600 : state.permissions ?? 0o600
        try restoreFile(state.data, to: url(for: target), permissions: permissions)
    }

    private func restorableOriginalState(_ state: ManagedState) -> ManagedState {
        var result = state
        if result[.configuration].data != nil, result[.configuration].permissions == nil {
            result[.configuration] = ManagedFileState(
                data: result[.configuration].data,
                permissions: 0o600
            )
        }
        if result[.secret].data != nil {
            result[.secret] = ManagedFileState(data: result[.secret].data, permissions: 0o600)
        }
        return result
    }

    private func rollbackAfterFailure(
        originalError: Error,
        original: ManagedState,
        recoveryBackup: BackupSnapshot,
        mutationOrder: [ManagedTarget],
        attemptedTargets: [ManagedTarget],
        expectedCurrent: ManagedState,
        inFlightTarget: ManagedTarget?,
        inFlightDesired: ManagedFileState?
    ) -> OpenCodeConfigurationError {
        let originalMessage = originalError.localizedDescription
        let current: ManagedState
        do {
            current = try stableManagedState()
        } catch {
            return .rollbackFailed(
                original: originalMessage,
                rollback: "\(error.localizedDescription)。恢复快照：\(recoveryBackup.directory.path)"
            )
        }

        let conflicts = ManagedTarget.allCases.filter { target in
            let actual = current[target]
            if actual == expectedCurrent[target] { return false }
            if target == inFlightTarget,
               actual == inFlightDesired || actual == original[target] {
                return false
            }
            return true
        }
        let conflictSet = Set(conflicts)
        let attemptedSet = Set(attemptedTargets)
        let rollbackOrder = mutationOrder.reversed().filter {
            attemptedSet.contains($0) && !conflictSet.contains($0)
        }
        let restorableOriginal = restorableOriginalState(original)

        do {
            for target in rollbackOrder {
                try restoreFileState(restorableOriginal[target], target: target)
            }
            let restored = try stableManagedState()
            let failedRollbackPaths = rollbackOrder.compactMap { target in
                restored[target] == restorableOriginal[target] ? nil : url(for: target).path
            }
            guard failedRollbackPaths.isEmpty else {
                throw OpenCodeConfigurationError.fileOperation(
                    "自动回滚后的内容或权限校验失败：\(failedRollbackPaths.joined(separator: ", "))"
                )
            }
            if conflicts.isEmpty {
                try fileManager.removeItem(at: recoveryBackup.directory)
                return mapFileError(originalError)
            }
            return .rollbackConflict(
                original: originalMessage,
                paths: conflicts.map { url(for: $0).path },
                recoveryBackupURL: recoveryBackup.directory
            )
        } catch {
            return .rollbackFailed(
                original: originalMessage,
                rollback: "\(error.localizedDescription)。恢复快照：\(recoveryBackup.directory.path)"
            )
        }
    }

    private func markBackupCompleted(_ snapshot: BackupSnapshot) throws {
        let completed = BackupManifest(
            schemaVersion: snapshot.manifest.schemaVersion,
            createdAt: snapshot.manifest.createdAt,
            configExisted: snapshot.manifest.configExisted,
            secretExisted: snapshot.manifest.secretExisted,
            configPermissions: snapshot.manifest.configPermissions,
            secretPermissions: snapshot.manifest.secretPermissions,
            operationCompleted: true,
            createdAtNanoseconds: snapshot.manifest.createdAtNanoseconds,
            configSHA256: snapshot.manifest.configSHA256,
            secretSHA256: snapshot.manifest.secretSHA256
        )
        do {
            let data = try JSONEncoder().encode(completed)
            try atomicWrite(data, to: snapshot.manifestURL, permissions: 0o600)
        } catch {
            throw mapFileError(error)
        }
    }

    private func pruneCompletedBackups(retaining limit: Int) throws {
        guard limit >= 1, fileManager.fileExists(atPath: backupsDirectory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        var completed: [(url: URL, createdAt: Date)] = []
        for directory in entries {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard !isSymbolicLink(at: manifestURL),
                  let data = try? readRegularFileIfPresent(at: manifestURL),
                  let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data),
                  manifest.schemaVersion == 1,
                  manifest.operationCompleted == true else { continue }
            completed.append((directory, values.creationDate ?? .distantPast))
        }

        completed.sort { left, right in
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.url.lastPathComponent > right.url.lastPathComponent
        }
        for snapshot in completed.dropFirst(limit) {
            try fileManager.removeItem(at: snapshot.url)
        }
    }

    private func readRegularFileIfPresent(at url: URL) throws -> Data? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else {
            throw OpenCodeConfigurationError.fileOperation("路径不是文件：\(url.path)")
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw mapFileError(error)
        }
    }

    private func ensureDirectory(_ url: URL, permissions: Int) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw OpenCodeConfigurationError.fileOperation("路径不是目录：\(url.path)")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } catch {
            throw mapFileError(error)
        }
    }

    private func createNewDirectory(_ url: URL, permissions: Int) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } catch {
            throw mapFileError(error)
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try ensureDirectory(url, permissions: 0o700)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw mapFileError(error)
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL, permissions: Int) throws {
        let parent = destination.deletingLastPathComponent()
        try ensureDirectory(parent, permissions: 0o700)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).yconnect-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )

        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: permissions]
            ) else {
                throw OpenCodeConfigurationError.fileOperation(
                    "无法创建临时文件：\(temporary.path)"
                )
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
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    // Do not inherit a pre-existing file's overly broad mode
                    // during the tiny replace-to-chmod interval.
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

    private func removeFileIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw mapFileError(error)
        }
    }

    private func restoreFile(_ data: Data?, to url: URL, permissions: Int) throws {
        guard let data else {
            try removeFileIfPresent(at: url)
            return
        }

        if try readRegularFileIfPresent(at: url) == data {
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions & 0o777],
                    ofItemAtPath: url.path
                )
            } catch {
                throw mapFileError(error)
            }
            return
        }
        try atomicWrite(data, to: url, permissions: permissions & 0o777)
    }

    private func permissionsIfPresent(at url: URL) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return number.intValue & 0o777
    }

    private func rejectManagedSymbolicLink(at url: URL, label: String) throws {
        if isSymbolicLink(at: url)
            || Self.canonicalizedURL(url, fileManager: fileManager).path != url.path {
            throw OpenCodeConfigurationError.fileOperation("\(label)不能是符号链接：\(url.path)")
        }
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func enforceSecretPermissionsIfPresent() throws {
        guard fileManager.fileExists(atPath: secretURL.path) else { return }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        } catch {
            throw mapFileError(error)
        }
    }

    private func mapFileError(_ error: Error) -> OpenCodeConfigurationError {
        if let typed = error as? OpenCodeConfigurationError { return typed }
        return .fileOperation(error.localizedDescription)
    }

    private static func backupTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSSSSS'Z'"
        return formatter.string(from: date)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
