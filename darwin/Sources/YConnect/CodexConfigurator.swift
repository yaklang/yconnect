import Foundation

/// Configures the user-level Codex CLI provider without ever placing the API
/// key in `config.toml`. Current Codex custom providers speak Responses only.
final class CodexClientConfigurator: ClientConfiguring {
    static let providerID = "yakcool"
    static let gatewayV1 = "https://aibalance.yaklang.com/v1"
    static let authTimeoutMilliseconds = 5_000
    static let authRefreshIntervalMilliseconds = 300_000

    private static let configurationTargetID = "configuration"
    private static let credentialTargetID = "credential"

    let descriptor = ClientDescriptor(
        id: .codex,
        name: "OpenAI Codex",
        shortName: "Codex",
        symbol: "terminal",
        summary: "OpenAI Codex CLI",
        supportedProtocols: [.responses],
        configurationPath: "~/.codex/config.toml",
        restartNote: "Codex 会在新会话中读取配置",
        availability: .ready
    )

    let configurationURL: URL
    let secretURL: URL

    private let coordinator: ConfigurationTransactionCoordinator

    init(
        environment: AppEnvironment,
        fileManager: FileManager = .default,
        hooks: ConfigurationTransactionHooks = .none
    ) throws {
        guard let configurationURL = environment.configurationURLs(for: .codex).first else {
            throw ClientConfigurationError.invalidConfiguration("Codex 配置路径不存在")
        }
        self.configurationURL = configurationURL
        self.secretURL = environment.managedSecretURL(for: .codex)
        self.coordinator = try ConfigurationTransactionCoordinator(
            identifier: ClientID.codex.rawValue,
            targets: [
                ConfigurationTransactionTarget(
                    id: Self.credentialTargetID,
                    url: self.secretURL,
                    sensitivity: .secret
                ),
                ConfigurationTransactionTarget(
                    id: Self.configurationTargetID,
                    url: self.configurationURL
                ),
            ],
            backupsDirectory: environment.backupsDirectory(for: .codex),
            fileManager: fileManager,
            hooks: hooks
        )
    }

    var targets: [ClientConfigurationTarget] {
        [
            ClientConfigurationTarget(url: secretURL, role: .credential),
            ClientConfigurationTarget(url: configurationURL, role: .configuration),
        ]
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        let selected = try validatedSelection(request)
        let credential = Data(request.apiKey.utf8)
        return try coordinator.withValidatedPlan(plan: { state in
            let configuration = try self.desiredConfiguration(
                existing: state.data(for: Self.configurationTargetID),
                modelID: selected.id
            )
            return [
                .write(targetID: Self.credentialTargetID, data: credential),
                .write(targetID: Self.configurationTargetID, data: configuration),
            ]
        }) { state, mutations in
            let desiredCredential = try TOMLClientConfiguratorSupport.writtenData(
                for: Self.credentialTargetID,
                in: mutations
            )
            let configuration = try TOMLClientConfiguratorSupport.writtenData(
                for: Self.configurationTargetID,
                in: mutations
            )
            return ClientConfigurationPreview(
                clientID: descriptor.id,
                selectedModelID: selected.id,
                changes: [
                    ClientFileChangePreview(
                        url: secretURL,
                        role: .credential,
                        action: TOMLClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.credentialTargetID,
                            desiredData: desiredCredential
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: configurationURL,
                        role: .configuration,
                        action: TOMLClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.configurationTargetID,
                            desiredData: configuration
                        ),
                        renderedText: try TOMLClientConfiguratorSupport.redactedPreviewText(
                            configuration
                        )
                    ),
                ]
            )
        }
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        let selected = try validatedSelection(request)
        let expectedCredential = Data(request.apiKey.utf8)
        let result = try coordinator.apply(plan: { state in
            let configuration = try self.desiredConfiguration(
                existing: state.data(for: Self.configurationTargetID),
                modelID: selected.id
            )
            return [
                .write(targetID: Self.credentialTargetID, data: expectedCredential),
                .write(targetID: Self.configurationTargetID, data: configuration),
            ]
        }, validate: { state in
            try self.validateInstalled(
                state,
                expectedModelID: selected.id,
                expectedCredential: expectedCredential
            )
        })
        return mappedResult(result, modelID: selected.id, restored: false)
    }

    func inspect() throws -> ClientConfigurationStatus {
        let latestBackup = try coordinator.latestBackupURL()
        return try coordinator.withSnapshot { state in
            let credentialSecure = state.file(Self.credentialTargetID)?.exists == true
                && state.file(Self.credentialTargetID)?.permissions == 0o600

            let document: TOMLClientConfigurationDocument
            do {
                document = try TOMLClientConfigurationDocument(
                    data: state.data(for: Self.configurationTargetID),
                    label: "Codex config.toml"
                )
            } catch {
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: .invalid,
                    selectedModelID: nil,
                    configuredModelIDs: [],
                    credentialProtection: credentialSecure ? .managedFileSecure : .missing,
                    latestBackupURL: latestBackup,
                    issues: [error.localizedDescription]
                )
            }

            let selectedModel = document.string(table: nil, key: "model")
            let selectedProvider = document.string(table: nil, key: "model_provider")
            let providerTable = "model_providers.\(Self.providerID)"
            let authTable = providerTable + ".auth"
            let allowedAssignments: [String: Set<String>] = [
                providerTable: ["name", "base_url", "wire_api"],
                authTable: ["command", "args", "timeout_ms", "refresh_interval_ms"],
            ]
            let hasManagedShapeConflict = document.hasConflictingManagedShape(
                providerTable,
                allowedAssignments: allowedAssignments
            )
            let hasAncestorConflict = document.hasConflictingAncestorAssignment(providerTable)
            let hasManagedMarker = selectedProvider == Self.providerID
                || document.containsManagedNamespace(providerTable)
            let safeReference = document.string(table: authTable, key: "command") == "/bin/cat"
                && document.stringArray(table: authTable, key: "args") == [secretURL.path]
                && document.integer(table: authTable, key: "timeout_ms") == Self.authTimeoutMilliseconds
                && document.integer(table: authTable, key: "refresh_interval_ms")
                    == Self.authRefreshIntervalMilliseconds
            let hasInlineCredential = [
                "env_key", "experimental_bearer_token", "requires_openai_auth", "token",
            ].contains { document.hasAssignment(table: providerTable, key: $0) }
                || document.hasAssignment(table: authTable, key: "token")

            let providerIsCorrect = selectedProvider == Self.providerID
                && document.string(table: providerTable, key: "name") == "YakCool"
                && document.string(table: providerTable, key: "base_url") == Self.gatewayV1
                && document.string(table: providerTable, key: "wire_api") == "responses"
            let configured = hasManagedMarker
                && selectedModel?.isEmpty == false
                && providerIsCorrect
                && safeReference
                && !hasInlineCredential
                && !hasManagedShapeConflict
                && credentialSecure

            var issues: [String] = []
            if hasManagedMarker && !providerIsCorrect {
                issues.append("Codex 的 YakCool provider 与 Responses 配置不一致")
            }
            if hasManagedMarker && hasInlineCredential {
                issues.append("Codex 的 YakCool provider 含有不安全或冲突的认证字段")
            }
            if hasManagedMarker && hasManagedShapeConflict {
                issues.append("Codex 的 YakCool provider 含有额外或冲突的子表、数组表或 dotted 配置")
            }
            if hasManagedMarker && !safeReference {
                issues.append("Codex 的 YakCool provider 未使用 YConnect 管理的命令认证")
            }
            if safeReference && !credentialSecure {
                issues.append("Codex 密钥文件缺失或权限不是 0600")
            }

            let protection: CredentialProtection
            if hasInlineCredential || hasManagedShapeConflict {
                protection = .unexpectedInline
            } else if safeReference {
                protection = credentialSecure ? .safeReference : .missing
            } else {
                protection = credentialSecure ? .managedFileSecure : .missing
            }

            return ClientConfigurationStatus(
                clientID: descriptor.id,
                state: configured
                    ? .configured
                    : (hasAncestorConflict ? .invalid : (hasManagedMarker ? .drifted : .notConfigured)),
                selectedModelID: selectedModel,
                configuredModelIDs: selectedModel.map { [$0] } ?? [],
                credentialProtection: protection,
                latestBackupURL: latestBackup,
                issues: issues
            )
        }
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result: ConfigurationTransactionResult
        do {
            result = try coordinator.restoreLatest { state in
                if let data = state.data(for: Self.configurationTargetID) {
                    _ = try TOMLConfigurationEditor(data: data)
                }
                if state.file(Self.credentialTargetID)?.exists == true,
                   state.file(Self.credentialTargetID)?.permissions != 0o600 {
                    throw ClientConfigurationError.invalidConfiguration("Codex 密钥恢复后的权限不是 0600")
                }
            }
        } catch ConfigurationTransactionError.noBackup {
            throw ClientConfigurationError.noBackup(descriptor.name)
        }
        return mappedResult(result, modelID: nil, restored: true)
    }

    private func validatedSelection(_ request: ClientApplyRequest) throws -> ClientModelOption {
        try TOMLClientConfiguratorSupport.validateAPIKey(request.apiKey)
        guard let selected = compatibleModels(from: request.models).first(where: {
            $0.id == request.selectedModelID && $0.protocols.contains(.responses)
        }) else {
            throw ClientConfigurationError.invalidSelection(
                "所选模型不支持 Codex 所需的 Responses 协议"
            )
        }
        return selected
    }

    private func desiredConfiguration(existing: Data?, modelID: String) throws -> Data {
        var editor = try existing.map(TOMLConfigurationEditor.init(data:)) ?? TOMLConfigurationEditor()
        try editor.upsertTopLevel(key: "model", value: .string(modelID))
        try editor.upsertTopLevel(key: "model_provider", value: .string(Self.providerID))
        try editor.removeManagedSubtree(named: "model_providers.\(Self.providerID)")
        try editor.replaceManagedTable(named: "model_providers.\(Self.providerID)", entries: [
            TOMLConfigurationEntry("name", .string("YakCool")),
            TOMLConfigurationEntry("base_url", .string(Self.gatewayV1)),
            TOMLConfigurationEntry("wire_api", .string("responses")),
        ])
        try editor.replaceManagedTable(named: "model_providers.\(Self.providerID).auth", entries: [
            TOMLConfigurationEntry("command", .string("/bin/cat")),
            TOMLConfigurationEntry("args", .stringArray([secretURL.path])),
            TOMLConfigurationEntry("timeout_ms", .integer(Self.authTimeoutMilliseconds)),
            TOMLConfigurationEntry(
                "refresh_interval_ms",
                .integer(Self.authRefreshIntervalMilliseconds)
            ),
        ])
        return editor.renderedData()
    }

    private func validateInstalled(
        _ state: ConfigurationTransactionState,
        expectedModelID: String,
        expectedCredential: Data
    ) throws {
        guard let configuration = state.data(for: Self.configurationTargetID),
              state.file(Self.configurationTargetID)?.exists == true,
              state.file(Self.configurationTargetID)?.permissions == 0o600,
              state.data(for: Self.credentialTargetID) == expectedCredential,
              state.file(Self.credentialTargetID)?.exists == true,
              state.file(Self.credentialTargetID)?.permissions == 0o600 else {
            throw ClientConfigurationError.invalidConfiguration("Codex 写后文件校验失败")
        }

        let document = try TOMLClientConfigurationDocument(
            data: configuration,
            label: "Codex config.toml"
        )
        let providerTable = "model_providers.\(Self.providerID)"
        let authTable = providerTable + ".auth"
        let allowedAssignments: [String: Set<String>] = [
            providerTable: ["name", "base_url", "wire_api"],
            authTable: ["command", "args", "timeout_ms", "refresh_interval_ms"],
        ]
        guard document.string(table: nil, key: "model") == expectedModelID,
              document.string(table: nil, key: "model_provider") == Self.providerID,
              document.string(table: providerTable, key: "name") == "YakCool",
              document.string(table: providerTable, key: "base_url") == Self.gatewayV1,
              document.string(table: providerTable, key: "wire_api") == "responses",
              document.string(table: authTable, key: "command") == "/bin/cat",
              document.stringArray(table: authTable, key: "args") == [secretURL.path],
              document.integer(table: authTable, key: "timeout_ms") == Self.authTimeoutMilliseconds,
              document.integer(table: authTable, key: "refresh_interval_ms")
                == Self.authRefreshIntervalMilliseconds,
              !document.hasConflictingManagedShape(
                providerTable,
                allowedAssignments: allowedAssignments
              ),
              !document.hasAssignment(table: providerTable, key: "env_key"),
              !document.hasAssignment(table: providerTable, key: "experimental_bearer_token"),
              !document.hasAssignment(table: providerTable, key: "requires_openai_auth"),
              !document.hasAssignment(table: providerTable, key: "token"),
              !document.hasAssignment(table: authTable, key: "token") else {
            throw ClientConfigurationError.invalidConfiguration("Codex 写后 TOML 校验失败")
        }
    }

    private func mappedResult(
        _ result: ConfigurationTransactionResult,
        modelID: String?,
        restored: Bool
    ) -> ClientConfigurationResult {
        let action = TOMLClientConfiguratorSupport.clientAction(result.action)
        let changedTargets = result.changedTargetIDs.compactMap { id -> URL? in
            switch id {
            case Self.credentialTargetID: return secretURL
            case Self.configurationTargetID: return configurationURL
            default: return nil
            }
        }
        let message: String
        if restored {
            message = action == .unchanged
                ? "Codex 配置已是最近备份状态"
                : "已恢复最近一次 Codex 配置备份"
        } else {
            message = action == .unchanged
                ? "Codex 已在使用所选 YakCool 模型"
                : "已将 Codex 切换到 YakCool / \(modelID ?? "")"
        }
        return ClientConfigurationResult(
            action: action,
            clientID: descriptor.id,
            changedTargets: changedTargets,
            backupURL: result.backupURL,
            modelID: modelID,
            message: message
        )
    }
}

// MARK: - Shared, narrow TOML inspection support

/// Reads only the scalar and string-array values owned by the Codex/Grok
/// adapters. Editing remains the responsibility of `TOMLConfigurationEditor`,
/// so unknown TOML syntax never gets reserialized by this view.
struct TOMLClientConfigurationDocument {
    private struct Section: Hashable {
        let path: [String]
        let isArray: Bool

        static let root = Section(path: [], isArray: false)
    }

    private struct AssignmentRecord {
        let section: Section
        let keyPath: [String]
    }

    private var assignments: [Section: [String: [String]]] = [:]
    private var assignmentRecords: [AssignmentRecord] = []
    private var tables: Set<Section> = []

    init(data: Data?, label: String) throws {
        guard let data else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClientConfigurationError.invalidConfiguration("\(label) 不是有效的 UTF-8 文本")
        }

        var section = Section.root
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            var line = String(rawLine)
            if line.last == "\r" { line.removeLast() }
            let code = Self.withoutComment(line).trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { continue }

            if let parsed = Self.tableHeader(code) {
                section = Section(path: parsed.path, isArray: parsed.isArray)
                tables.insert(section)
                continue
            }
            guard !section.isArray, let assignment = Self.assignment(code) else { continue }
            assignmentRecords.append(AssignmentRecord(
                section: section,
                keyPath: assignment.keyPath
            ))
            if assignment.keyPath.count == 1, let key = assignment.keyPath.first {
                assignments[section, default: [:]][key, default: []].append(assignment.value)
            }
        }
    }

    func hasTable(_ dottedName: String) -> Bool {
        guard let path = Self.dottedKey(dottedName) else { return false }
        return tables.contains(Section(path: path, isArray: false))
    }

    func hasAssignment(table dottedName: String?, key: String) -> Bool {
        values(table: dottedName, key: key)?.isEmpty == false
    }

    func string(table dottedName: String?, key: String) -> String? {
        guard let values = values(table: dottedName, key: key), values.count == 1 else { return nil }
        return Self.stringValue(values[0])
    }

    func stringArray(table dottedName: String?, key: String) -> [String]? {
        guard let values = values(table: dottedName, key: key), values.count == 1 else { return nil }
        return Self.stringArrayValue(values[0])
    }

    func integer(table dottedName: String?, key: String) -> Int? {
        guard let values = values(table: dottedName, key: key), values.count == 1 else { return nil }
        let source = values[0]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "")
        return Int(source)
    }

    /// Whether any table or assignment intersects a managed namespace. A
    /// strict ancestor assignment counts because it prevents the namespace
    /// from being represented safely as ordinary TOML tables.
    func containsManagedNamespace(_ dottedName: String) -> Bool {
        guard let target = Self.dottedKey(dottedName) else { return false }
        if tables.contains(where: { Self.path(target, isPrefixOf: $0.path) }) {
            return true
        }
        return assignmentRecords.contains { assignment in
            let fullPath = assignment.section.path + assignment.keyPath
            return Self.path(target, isPrefixOf: fullPath)
                || Self.path(fullPath, isStrictPrefixOf: target)
        }
    }

    /// Rejects any syntactic shape below an owned namespace except the exact
    /// standard tables and direct keys declared by the adapter. This catches
    /// child/array tables and dotted credentials that scalar lookup alone
    /// would otherwise ignore.
    func hasConflictingManagedShape(
        _ dottedName: String,
        allowedAssignments: [String: Set<String>]
    ) -> Bool {
        guard let target = Self.dottedKey(dottedName) else { return true }
        var allowed: [Section: Set<String>] = [:]
        for (table, keys) in allowedAssignments {
            guard let path = Self.dottedKey(table) else { return true }
            allowed[Section(path: path, isArray: false)] = keys
        }

        if tables.contains(where: { table in
            Self.path(target, isPrefixOf: table.path) && allowed[table] == nil
        }) {
            return true
        }

        return assignmentRecords.contains { assignment in
            let fullPath = assignment.section.path + assignment.keyPath
            let intersects = Self.path(target, isPrefixOf: fullPath)
                || Self.path(fullPath, isStrictPrefixOf: target)
            guard intersects else { return false }
            guard assignment.keyPath.count == 1,
                  let key = assignment.keyPath.first,
                  allowed[assignment.section]?.contains(key) == true else {
                return true
            }
            return false
        }
    }

    func hasConflictingAncestorAssignment(_ dottedName: String) -> Bool {
        guard let target = Self.dottedKey(dottedName) else { return true }
        return assignmentRecords.contains { assignment in
            let fullPath = assignment.section.path + assignment.keyPath
            return Self.path(fullPath, isStrictPrefixOf: target)
        }
    }

    private func values(table dottedName: String?, key: String) -> [String]? {
        let section: Section
        if let dottedName {
            guard let path = Self.dottedKey(dottedName) else { return nil }
            section = Section(path: path, isArray: false)
        } else {
            section = .root
        }
        return assignments[section]?[key]
    }

    private static func tableHeader(_ value: String) -> (path: [String], isArray: Bool)? {
        if value.hasPrefix("[["), value.hasSuffix("]]"), value.count >= 4 {
            let interior = String(value.dropFirst(2).dropLast(2))
            guard let path = dottedKey(interior), !path.isEmpty else { return nil }
            return (path, true)
        }
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
            let interior = String(value.dropFirst().dropLast())
            guard let path = dottedKey(interior), !path.isEmpty else { return nil }
            return (path, false)
        }
        return nil
    }

    private static func assignment(_ value: String) -> (keyPath: [String], value: String)? {
        let characters = Array(value)
        var quote: Character?
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if let currentQuote = quote {
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                let keySource = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
                let rawValue = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
                guard let keyPath = dottedKey(keySource), !keyPath.isEmpty, !rawValue.isEmpty else {
                    return nil
                }
                return (keyPath, rawValue)
            }
        }
        return nil
    }

    private static func path(_ prefix: [String], isPrefixOf path: [String]) -> Bool {
        path.count >= prefix.count && path.prefix(prefix.count).elementsEqual(prefix)
    }

    private static func path(_ prefix: [String], isStrictPrefixOf path: [String]) -> Bool {
        path.count > prefix.count && Self.path(prefix, isPrefixOf: path)
    }

    private static func withoutComment(_ value: String) -> String {
        let characters = Array(value)
        var quote: Character?
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if let currentQuote = quote {
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(characters[..<index])
            }
        }
        return value
    }

    private static func dottedKey(_ value: String) -> [String]? {
        let characters = Array(value)
        var result: [String] = []
        var index = 0

        func skipWhitespace(_ index: inout Int) {
            while index < characters.count,
                  characters[index] == " " || characters[index] == "\t" {
                index += 1
            }
        }

        while true {
            skipWhitespace(&index)
            guard index < characters.count else { return result.isEmpty ? nil : result }

            let component: String
            if characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                var value = ""
                var closed = false
                while index < characters.count {
                    let character = characters[index]
                    if character == quote {
                        index += 1
                        closed = true
                        break
                    }
                    if quote == "\"", character == "\\" {
                        guard let escaped = decodedEscape(characters, index: &index) else { return nil }
                        value.unicodeScalars.append(contentsOf: escaped.unicodeScalars)
                    } else {
                        value.append(character)
                        index += 1
                    }
                }
                guard closed else { return nil }
                component = value
            } else {
                let start = index
                while index < characters.count, isBareKeyCharacter(characters[index]) { index += 1 }
                guard index > start else { return nil }
                component = String(characters[start..<index])
            }
            result.append(component)
            skipWhitespace(&index)
            guard index < characters.count else { return result }
            guard characters[index] == "." else { return nil }
            index += 1
        }
    }

    private static func stringValue(_ source: String) -> String? {
        let characters = Array(source.trimmingCharacters(in: .whitespaces))
        guard characters.count >= 2 else { return nil }
        if characters.first == "'", characters.last == "'" {
            return String(characters.dropFirst().dropLast())
        }
        guard characters.first == "\"", characters.last == "\"" else { return nil }
        var result = ""
        var index = 1
        let finalQuote = characters.count - 1
        while index < finalQuote {
            if characters[index] == "\\" {
                guard let escaped = decodedEscape(characters, index: &index), index <= finalQuote else {
                    return nil
                }
                result.unicodeScalars.append(contentsOf: escaped.unicodeScalars)
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return index == finalQuote ? result : nil
    }

    private static func stringArrayValue(_ source: String) -> [String]? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let interior = String(trimmed.dropFirst().dropLast())
        let characters = Array(interior)
        var parts: [String] = []
        var start = 0
        var quote: Character?
        var escaped = false

        for index in characters.indices {
            let character = characters[index]
            if let currentQuote = quote {
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                parts.append(String(characters[start..<index]))
                start = index + 1
            }
        }
        guard quote == nil else { return nil }
        parts.append(String(characters[start...]))
        if parts.count == 1, parts[0].trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let decoded = parts.map { stringValue($0) }
        guard decoded.allSatisfy({ $0 != nil }) else { return nil }
        return decoded.compactMap { $0 }
    }

    private static func decodedEscape(_ characters: [Character], index: inout Int) -> String? {
        guard index < characters.count, characters[index] == "\\", index + 1 < characters.count else {
            return nil
        }
        let marker = characters[index + 1]
        switch marker {
        case "b": index += 2; return "\u{0008}"
        case "t": index += 2; return "\t"
        case "n": index += 2; return "\n"
        case "f": index += 2; return "\u{000C}"
        case "r": index += 2; return "\r"
        case "\"": index += 2; return "\""
        case "\\": index += 2; return "\\"
        case "u", "U":
            let digitCount = marker == "u" ? 4 : 8
            let digitStart = index + 2
            let digitEnd = digitStart + digitCount
            guard digitEnd <= characters.count,
                  let scalarValue = UInt32(String(characters[digitStart..<digitEnd]), radix: 16),
                  let scalar = UnicodeScalar(scalarValue) else { return nil }
            index = digitEnd
            return String(scalar)
        default:
            return nil
        }
    }

    private static func isBareKeyCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
            || value == 95
            || value == 45
    }
}

enum TOMLClientConfiguratorSupport {
    private struct PreviewLine {
        let content: String
        let terminator: String
    }

    private enum PreviewStringMode {
        case none
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    static func validateAPIKey(_ key: String) throws {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !key.isEmpty,
              key == key.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.unicodeScalars.contains(where: forbidden.contains) else {
            throw ClientConfigurationError.invalidConfiguration("API Key 格式无效")
        }
    }

    static func previewAction(
        in state: ConfigurationTransactionState,
        targetID: String,
        desiredData: Data
    ) -> ClientFileChangePreview.Action {
        guard state.file(targetID)?.exists == true else { return .create }
        return state.file(targetID)?.permissions == 0o600
            && state.data(for: targetID) == desiredData
            ? .unchanged
            : .update
    }

    static func writtenData(
        for targetID: String,
        in mutations: [ConfigurationTransactionMutation]
    ) throws -> Data {
        guard let mutation = mutations.first(where: { $0.targetID == targetID }),
              case .write(_, let data) = mutation else {
            throw ClientConfigurationError.invalidConfiguration(
                "TOML 预览计划缺少目标：\(targetID)"
            )
        }
        return data
    }

    /// Produces UI-safe TOML without changing the bytes that will be written.
    /// Any assignment whose key (or containing table) looks credential-bearing
    /// is replaced as one unit, including multiline arrays/inline tables.
    static func redactedPreviewText(_ data: Data) throws -> String {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ClientConfigurationError.invalidConfiguration(
                "TOML 预览不是有效的 UTF-8 文本"
            )
        }
        let lines = splitPreviewLines(source)
        var output: [PreviewLine] = []
        var tableIsSensitive = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if let header = tableHeaderSource(line.content) {
                tableIsSensitive = containsSensitiveIdentifier(header)
                output.append(line)
                index += 1
                continue
            }

            guard let assignment = assignmentStart(line.content) else {
                output.append(line)
                index += 1
                continue
            }
            let keyIsSensitive = containsSensitiveIdentifier(assignment.keySource)
            guard tableIsSensitive || keyIsSensitive else {
                output.append(line)
                index += 1
                continue
            }

            let end = assignmentEnd(
                lines,
                startingAt: index,
                valueOffset: assignment.valueOffset
            )
            let terminator = lines[max(index, end - 1)].terminator
            output.append(PreviewLine(
                content: assignment.prefixThroughEquals + " \"<redacted>\"",
                terminator: terminator
            ))
            index = max(index + 1, end)
        }

        return output.map { $0.content + $0.terminator }.joined()
    }

    static func clientAction(
        _ action: ConfigurationTransactionResult.Action
    ) -> ClientConfigurationResult.Action {
        switch action {
        case .applied: return .applied
        case .unchanged: return .unchanged
        case .restored: return .restored
        }
    }

    private static func containsSensitiveIdentifier(_ source: String) -> Bool {
        let value = source.lowercased()
        return [
            "api_key", "apikey", "api-key", "token", "authorization",
            "headers", "secret", "password", "credential",
        ].contains(where: value.contains)
    }

    private static func tableHeaderSource(_ line: String) -> String? {
        let code = codeBeforeComment(line).trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("[["), code.hasSuffix("]]"), code.count >= 4 {
            return String(code.dropFirst(2).dropLast(2))
        }
        if code.hasPrefix("["), code.hasSuffix("]"), code.count >= 2 {
            return String(code.dropFirst().dropLast())
        }
        return nil
    }

    private static func assignmentStart(
        _ line: String
    ) -> (keySource: String, valueOffset: Int, prefixThroughEquals: String)? {
        let characters = Array(line)
        var quote: Character?
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if let currentQuote = quote {
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
                continue
            }
            if character == "#" { return nil }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                let keySource = String(characters[..<index])
                guard !keySource.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return (
                    keySource,
                    index + 1,
                    String(characters[...index])
                )
            }
        }
        return nil
    }

    private static func assignmentEnd(
        _ lines: [PreviewLine],
        startingAt firstLine: Int,
        valueOffset: Int
    ) -> Int {
        var mode = PreviewStringMode.none
        var squareDepth = 0
        var curlyDepth = 0

        for lineNumber in firstLine..<lines.count {
            let characters = Array(lines[lineNumber].content)
            var offset = lineNumber == firstLine ? min(valueOffset, characters.count) : 0
            while offset < characters.count {
                let character = characters[offset]
                switch mode {
                case .none:
                    if character == "#" {
                        offset = characters.count
                        continue
                    }
                    if character == "\"", hasRun("\"", count: 3, in: characters, at: offset) {
                        mode = .multilineBasic
                        offset += 3
                        continue
                    }
                    if character == "'", hasRun("'", count: 3, in: characters, at: offset) {
                        mode = .multilineLiteral
                        offset += 3
                        continue
                    }
                    if character == "\"" { mode = .basic }
                    else if character == "'" { mode = .literal }
                    else if character == "[" { squareDepth += 1 }
                    else if character == "]" { squareDepth = max(0, squareDepth - 1) }
                    else if character == "{" { curlyDepth += 1 }
                    else if character == "}" { curlyDepth = max(0, curlyDepth - 1) }

                case .basic:
                    if character == "\\" {
                        offset += 2
                        continue
                    }
                    if character == "\"" { mode = .none }

                case .literal:
                    if character == "'" { mode = .none }

                case .multilineBasic:
                    if character == "\\" {
                        offset += 2
                        continue
                    }
                    if character == "\"", hasRun("\"", count: 3, in: characters, at: offset) {
                        mode = .none
                        offset += runLength("\"", in: characters, at: offset)
                        continue
                    }

                case .multilineLiteral:
                    if character == "'", hasRun("'", count: 3, in: characters, at: offset) {
                        mode = .none
                        offset += runLength("'", in: characters, at: offset)
                        continue
                    }
                }
                offset += 1
            }

            if mode == .basic || mode == .literal { mode = .none }
            if mode == .none, squareDepth == 0, curlyDepth == 0 {
                return lineNumber + 1
            }
        }
        return lines.count
    }

    private static func codeBeforeComment(_ line: String) -> String {
        let characters = Array(line)
        var quote: Character?
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if let currentQuote = quote {
                if currentQuote == "\"", escaped {
                    escaped = false
                } else if currentQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == currentQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(characters[..<index])
            }
        }
        return line
    }

    private static func hasRun(
        _ character: Character,
        count: Int,
        in characters: [Character],
        at offset: Int
    ) -> Bool {
        guard offset >= 0, count > 0, offset + count <= characters.count else { return false }
        return characters[offset..<(offset + count)].allSatisfy { $0 == character }
    }

    private static func runLength(
        _ character: Character,
        in characters: [Character],
        at offset: Int
    ) -> Int {
        var end = offset
        while end < characters.count, characters[end] == character { end += 1 }
        return end - offset
    }

    private static func splitPreviewLines(_ text: String) -> [PreviewLine] {
        guard !text.isEmpty else { return [] }
        let bytes = Array(text.utf8)
        var result: [PreviewLine] = []
        var start = 0
        var cursor = 0
        while cursor < bytes.count {
            if bytes[cursor] == 0x0A {
                result.append(PreviewLine(
                    content: String(decoding: bytes[start..<cursor], as: UTF8.self),
                    terminator: "\n"
                ))
                cursor += 1
                start = cursor
            } else if bytes[cursor] == 0x0D {
                let isCRLF = cursor + 1 < bytes.count && bytes[cursor + 1] == 0x0A
                result.append(PreviewLine(
                    content: String(decoding: bytes[start..<cursor], as: UTF8.self),
                    terminator: isCRLF ? "\r\n" : "\r"
                ))
                cursor += isCRLF ? 2 : 1
                start = cursor
            } else {
                cursor += 1
            }
        }
        if start < bytes.count {
            result.append(PreviewLine(
                content: String(decoding: bytes[start..<bytes.count], as: UTF8.self),
                terminator: ""
            ))
        }
        return result
    }
}
