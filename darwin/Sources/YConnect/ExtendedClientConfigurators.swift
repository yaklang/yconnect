import Foundation

// MARK: - Shared support

private enum ExtendedClientConfiguratorSupport {
    static let gatewayHost = "https://aibalance.yaklang.com"
    static let gatewayV1 = "https://aibalance.yaklang.com/v1"
    static let maximumConfiguredModelCount = 100
    static let maximumModelNameByteCount = 256

    static func validateAPIKey(_ key: String) throws {
        guard !key.isEmpty,
              key.utf8.count <= 512,
              key == key.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }) else {
            throw ClientConfigurationError.invalidConfiguration("API Key 格式无效")
        }
    }

    static func validateModelID(_ modelID: String) throws {
        guard !modelID.isEmpty,
              modelID.utf8.count <= 200,
              modelID == modelID.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }) else {
            throw ClientConfigurationError.invalidSelection("模型 ID 格式无效")
        }
    }

    static func validateModelName(_ name: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= maximumModelNameByteCount,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: {
                  CharacterSet.newlines.union(.controlCharacters).contains($0)
              }) else {
            throw ClientConfigurationError.invalidSelection("模型名称格式无效")
        }
    }

    static func validateOutputModels(_ models: [ClientModelOption]) throws {
        guard !models.isEmpty, models.count <= maximumConfiguredModelCount else {
            throw ClientConfigurationError.invalidSelection(
                "单个客户端最多可配置 \(maximumConfiguredModelCount) 个模型"
            )
        }
        for model in models {
            try validateModelID(model.id)
            try validateModelName(model.name)
        }
    }

    static func preferredProtocol(for model: ClientModelOption) throws -> AIProtocol {
        if model.protocols.contains(.responses) { return .responses }
        if model.protocols.contains(.anthropicMessages) { return .anthropicMessages }
        if model.protocols.contains(.chatCompletions) { return .chatCompletions }
        throw ClientConfigurationError.noCompatibleModel("所选模型没有客户端支持的协议")
    }

    static func endpoint(for protocolValue: AIProtocol) -> String {
        protocolValue == .anthropicMessages ? gatewayHost : gatewayV1
    }

    static func helperData(secretURL: URL) -> Data {
        Data("#!/bin/sh\nexec /bin/cat \(shellQuote(secretURL.path))\n".utf8)
    }

    static func helperCommand(helperURL: URL) -> String {
        shellQuote(helperURL.path)
    }

    static func validateRestoredHelper(
        in state: ConfigurationTransactionState,
        targetID: String,
        secretURL: URL,
        clientName: String
    ) throws {
        guard state.file(targetID)?.exists == true else { return }
        guard state.file(targetID)?.permissions == 0o700,
              state.data(for: targetID) == helperData(secretURL: secretURL) else {
            throw ClientConfigurationError.invalidConfiguration(
                "\(clientName) 备份中的 credential helper 内容或权限不安全"
            )
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func previewAction(
        in state: ConfigurationTransactionState,
        targetID: String,
        desiredData: Data,
        permissions: Int
    ) -> ClientFileChangePreview.Action {
        guard state.file(targetID)?.exists == true else { return .create }
        return state.data(for: targetID) == desiredData
            && state.file(targetID)?.permissions == permissions
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
                "配置预览缺少受管目标：\(targetID)"
            )
        }
        return data
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

    static func jsonPreview(_ data: Data, label: String) throws -> String {
        let root = try ExtendedJSONConfiguration.rootObject(from: data, label: label)
        guard let redacted = redactJSON(root, key: nil) as? [String: Any] else {
            throw ClientConfigurationError.invalidConfiguration("无法生成安全的 \(label) 预览")
        }
        let rendered = try JSONConfigurationEditor.serialized(redacted, label: "\(label) 预览")
        return String(decoding: rendered, as: UTF8.self)
    }

    private static func redactJSON(_ value: Any, key: String?) -> Any {
        if let key, isSensitiveKey(key) { return "<redacted>" }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, element in
                result[element.key] = redactJSON(element.value, key: element.key)
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0, key: nil) }
        }
        return value
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        if [
            "apikeyhelper",
            "inferencecredentialhelper",
            "keycmd",
            "authprovider",
        ].contains(normalized) { return false }
        if normalized == "headers" || normalized == "extraheaders" || normalized == "auth" {
            return true
        }
        return ["apikey", "token", "secret", "password", "authorization", "credential", "cookie"]
            .contains(where: normalized.contains)
    }

    static func contains(_ data: Data, literal: String) -> Bool {
        guard !literal.isEmpty else { return false }
        return data.range(of: Data(literal.utf8)) != nil
    }
}

/// OpenClaw documents JSON5. `JSONConfigurationEditor` handles JSON/JSONC;
/// this wrapper keeps that well-tested path and adds a strict JSON5 fallback
/// for single-quoted strings and unquoted object keys.
private enum ExtendedJSONConfiguration {
    static func rootObject(from data: Data?, label: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        do {
            return try JSONConfigurationEditor.rootObject(from: data, label: label)
        } catch {
            guard let source = String(data: data, encoding: .utf8) else {
                throw ClientConfigurationError.invalidConfiguration("\(label) 不是有效的 UTF-8 文本")
            }
            do {
                var reader = JSON5Reader(source)
                let value = try reader.parse()
                guard let root = value as? [String: Any] else {
                    throw ClientConfigurationError.invalidConfiguration("\(label) 的顶层必须是对象")
                }
                return root
            } catch let configurationError as ClientConfigurationError {
                throw configurationError
            } catch {
                throw ClientConfigurationError.invalidConfiguration("无法解析 \(label)")
            }
        }
    }
}

private struct JSON5Reader {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func parse() throws -> Any {
        try skipTrivia()
        let value = try parseValue()
        try skipTrivia()
        guard index == characters.count else { throw ParseError.invalid }
        return value
    }

    private mutating func parseValue() throws -> Any {
        try skipTrivia()
        guard let character = peek else { throw ParseError.invalid }
        switch character {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"", "'": return try parseString()
        default:
            let token = try parseBareToken()
            switch token {
            case "true": return true
            case "false": return false
            case "null": return NSNull()
            case "Infinity", "+Infinity", "-Infinity", "NaN", "+NaN", "-NaN":
                throw ParseError.invalid
            default:
                return try parseNumber(token)
            }
        }
    }

    private mutating func parseObject() throws -> [String: Any] {
        try consume("{")
        try skipTrivia()
        var result: [String: Any] = [:]
        if take("}") { return result }
        while true {
            try skipTrivia()
            let key: String
            if peek == "\"" || peek == "'" {
                key = try parseString()
            } else {
                key = try parseIdentifier()
            }
            guard result[key] == nil else { throw ParseError.invalid }
            try skipTrivia()
            try consume(":")
            result[key] = try parseValue()
            try skipTrivia()
            if take("}") { return result }
            try consume(",")
            try skipTrivia()
            if take("}") { return result }
        }
    }

    private mutating func parseArray() throws -> [Any] {
        try consume("[")
        try skipTrivia()
        var result: [Any] = []
        if take("]") { return result }
        while true {
            result.append(try parseValue())
            try skipTrivia()
            if take("]") { return result }
            try consume(",")
            try skipTrivia()
            if take("]") { return result }
        }
    }

    private mutating func parseString() throws -> String {
        guard let delimiter = peek, delimiter == "\"" || delimiter == "'" else {
            throw ParseError.invalid
        }
        index += 1
        var result = ""
        while let character = peek {
            index += 1
            if character == delimiter { return result }
            guard character != "\n" && character != "\r" else { throw ParseError.invalid }
            if character != "\\" {
                result.append(character)
                continue
            }
            guard let escaped = peek else { throw ParseError.invalid }
            index += 1
            switch escaped {
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "\\": result.append("\\")
            case "/": result.append("/")
            case "b": result.append("\u{0008}")
            case "f": result.append("\u{000C}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "v": result.append("\u{000B}")
            case "0": result.append("\0")
            case "x": result.append(try parseUnicodeScalar(digitCount: 2))
            case "u": result.append(try parseUnicodeScalar(digitCount: 4))
            case "\n": break
            case "\r":
                _ = take("\n")
            default: result.append(escaped)
            }
        }
        throw ParseError.invalid
    }

    private mutating func parseUnicodeScalar(digitCount: Int) throws -> Character {
        guard index + digitCount <= characters.count else { throw ParseError.invalid }
        let source = String(characters[index..<(index + digitCount)])
        guard let value = UInt32(source, radix: 16), let scalar = UnicodeScalar(value) else {
            throw ParseError.invalid
        }
        index += digitCount
        return Character(scalar)
    }

    private mutating func parseIdentifier() throws -> String {
        guard let first = peek, isIdentifierStart(first) else { throw ParseError.invalid }
        let start = index
        index += 1
        while let character = peek, isIdentifierContinuation(character) { index += 1 }
        return String(characters[start..<index])
    }

    private mutating func parseBareToken() throws -> String {
        let start = index
        while let character = peek,
              !character.isWhitespace,
              ![",", "]", "}", "/"].contains(character) {
            index += 1
        }
        guard index > start else { throw ParseError.invalid }
        return String(characters[start..<index])
    }

    private func parseNumber(_ token: String) throws -> NSNumber {
        var source = token
        var sign = 1
        if source.first == "+" { source.removeFirst() }
        else if source.first == "-" { source.removeFirst(); sign = -1 }
        if source.hasPrefix("0x") || source.hasPrefix("0X") {
            guard let value = Int64(source.dropFirst(2), radix: 16) else { throw ParseError.invalid }
            return NSNumber(value: value * Int64(sign))
        }
        if !source.contains(".") && !source.lowercased().contains("e"),
           let value = Int64(source) {
            return NSNumber(value: value * Int64(sign))
        }
        guard let value = Double((sign < 0 ? "-" : "") + source), value.isFinite else {
            throw ParseError.invalid
        }
        return NSNumber(value: value)
    }

    private mutating func skipTrivia() throws {
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            guard characters[index] == "/", index + 1 < characters.count else { return }
            if characters[index + 1] == "/" {
                index += 2
                while index < characters.count,
                      characters[index] != "\n", characters[index] != "\r" { index += 1 }
            } else if characters[index + 1] == "*" {
                index += 2
                var closed = false
                while index + 1 < characters.count {
                    if characters[index] == "*", characters[index + 1] == "/" {
                        index += 2
                        closed = true
                        break
                    }
                    index += 1
                }
                guard closed else { throw ParseError.invalid }
            } else { return }
        }
    }

    private var peek: Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func take(_ character: Character) -> Bool {
        guard peek == character else { return false }
        index += 1
        return true
    }

    private mutating func consume(_ character: Character) throws {
        guard take(character) else { throw ParseError.invalid }
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private enum ParseError: Error { case invalid }
}

// MARK: - Narrow YAML support

/// A deliberately small YAML mapping editor for Hermes' documented config
/// shape. It preserves unrelated block-mapping content and the source line
/// ending style, while replacing only YConnect-owned scalar/model entries.
/// YAML features that could make those owned paths ambiguous are rejected.
private struct HermesYAMLDocument {
    private struct MappingLine {
        let index: Int
        let indent: Int
        let key: String
        let rawValue: String
    }

    private var lines: [String]
    private let newline: String
    private let hadTrailingNewline: Bool

    init(data: Data?) throws {
        guard let data, !data.isEmpty else {
            lines = []
            newline = "\n"
            hadTrailingNewline = true
            return
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ClientConfigurationError.invalidConfiguration("Hermes config.yaml 不是有效的 UTF-8 文本")
        }
        newline = source.contains("\r\n") ? "\r\n" : "\n"
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        hadTrailingNewline = normalized.hasSuffix("\n")
        lines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        for line in lines {
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            if prefix.contains("\t") {
                throw ClientConfigurationError.invalidConfiguration("Hermes config.yaml 的缩进不能包含 Tab")
            }
        }
        try validateDocumentShape()
        try validateUniqueOwnedPaths()
        try validateOwnedMappingShapes()
    }

    mutating func configureProvider(
        api: String,
        keyCommand: String,
        transport: String,
        defaultModel: String,
        models: [String]
    ) throws {
        try upsertScalars(
            in: ["providers", "yakcool"],
            entries: [
                ("api", try Self.quoted(api)),
                ("key_cmd", try Self.quoted(keyCommand)),
                ("transport", try Self.quoted(transport)),
                ("default_model", try Self.quoted(defaultModel)),
            ],
            removing: [
                "api_key", "key_env", "base_url", "url", "api_mode",
                "extra_headers",
            ]
        )
        try reconcileEmptyMappings(in: ["providers", "yakcool", "models"], keys: models)
        try upsertScalars(
            in: ["model"],
            entries: [
                ("default", try Self.quoted(defaultModel)),
                ("provider", try Self.quoted("custom:yakcool")),
            ],
            removing: []
        )
    }

    func scalar(at path: [String]) throws -> String? {
        guard path.count >= 2 else { return nil }
        let parentPath = Array(path.dropLast())
        guard let parent = try locateMapping(parentPath) else { return nil }
        let children = directChildren(of: parent)
        let matches = children.filter { $0.key == path.last }
        guard matches.count <= 1 else {
            throw ClientConfigurationError.invalidConfiguration("Hermes config.yaml 含有重复配置字段")
        }
        return matches.first.flatMap { Self.scalarValue($0.rawValue) }
    }

    func directKeys(in path: [String]) throws -> [String] {
        guard let parent = try locateMapping(path) else { return [] }
        return directChildren(of: parent).map(\.key)
    }

    func hasKey(at path: [String]) throws -> Bool {
        guard path.count >= 2,
              let parent = try locateMapping(Array(path.dropLast())) else { return false }
        return directChildren(of: parent).contains { $0.key == path.last }
    }

    func renderedData() -> Data {
        var result = lines.joined(separator: newline)
        if hadTrailingNewline { result += newline }
        return Data(result.utf8)
    }

    func redactedText() throws -> String {
        var output: [String] = []
        var hiddenIndent: Int?
        for (index, line) in lines.enumerated() {
            if let hiddenIndent {
                if Self.isBlankOrComment(line) {
                    continue
                }
                let indent = Self.indentation(line)
                if indent > hiddenIndent { continue }
            }
            hiddenIndent = nil
            guard let mapping = try Self.parseMappingLine(line, index: index),
                  ExtendedClientConfiguratorSupport.isSensitiveKey(mapping.key) else {
                output.append(line)
                continue
            }
            output.append(String(repeating: " ", count: mapping.indent) + Self.renderKey(mapping.key) + ": \"<redacted>\"")
            if mapping.rawValue.isEmpty { hiddenIndent = mapping.indent }
        }
        var result = output.joined(separator: newline)
        if hadTrailingNewline { result += newline }
        return result
    }

    private mutating func upsertScalars(
        in path: [String],
        entries: [(String, String)],
        removing: Set<String>
    ) throws {
        let parent = try ensureMapping(path)
        let ownedKeys = Set(entries.map(\.0)).union(removing)
        let matches = directChildren(of: parent).filter { ownedKeys.contains($0.key) }
        removeMappingSpans(matches)
        guard let refreshed = try locateMapping(path) else {
            throw ClientConfigurationError.invalidConfiguration("无法生成 Hermes 配置")
        }
        let childIndent = directChildIndent(of: refreshed) ?? refreshed.indent + 2
        let insertion = mappingEnd(refreshed)
        let rendered = entries.map {
            String(repeating: " ", count: childIndent) + Self.renderKey($0.0) + ": " + $0.1
        }
        lines.insert(contentsOf: rendered, at: insertion)
    }

    private mutating func reconcileEmptyMappings(in path: [String], keys: [String]) throws {
        let parent = try ensureMapping(path)
        let desired = Set(keys)
        var seen: Set<String> = []
        let obsoleteOrDuplicate = directChildren(of: parent).filter { child in
            !desired.contains(child.key) || !seen.insert(child.key).inserted
        }
        removeMappingSpans(obsoleteOrDuplicate)
        guard let refreshed = try locateMapping(path) else {
            throw ClientConfigurationError.invalidConfiguration("无法生成 Hermes 模型配置")
        }
        let existing = Set(directChildren(of: refreshed).map(\.key))
        let missing = keys.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return }
        let childIndent = directChildIndent(of: refreshed) ?? refreshed.indent + 2
        let insertion = mappingEnd(refreshed)
        let rendered = try missing.map { key in
            String(repeating: " ", count: childIndent) + (try Self.quoted(key)) + ": {}"
        }
        lines.insert(contentsOf: rendered, at: insertion)
    }

    private mutating func ensureMapping(_ path: [String]) throws -> MappingLine {
        var prefix: [String] = []
        for component in path {
            let parent = prefix.isEmpty ? nil : try locateMapping(prefix)
            prefix.append(component)
            if let existing = try locateMapping(prefix) {
                guard existing.rawValue.isEmpty else {
                    throw ClientConfigurationError.invalidConfiguration("Hermes config.yaml 的 \(component) 必须是映射")
                }
                continue
            }
            let indent: Int
            let insertion: Int
            if let parent {
                indent = directChildIndent(of: parent) ?? parent.indent + 2
                insertion = mappingEnd(parent)
            } else {
                indent = 0
                insertion = lines.count
                if insertion > 0, !lines[insertion - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("")
                }
            }
            lines.insert(String(repeating: " ", count: indent) + Self.renderKey(component) + ":", at: insertion)
        }
        guard let result = try locateMapping(path) else {
            throw ClientConfigurationError.invalidConfiguration("无法生成 Hermes 配置")
        }
        return result
    }

    private func locateMapping(_ path: [String]) throws -> MappingLine? {
        var parent: MappingLine?
        var lowerBound = 0
        var upperBound = lines.count
        for component in path {
            let expectedIndent: Int
            if let parent {
                guard parent.rawValue.isEmpty else { return nil }
                expectedIndent = directChildIndent(of: parent) ?? parent.indent + 2
                lowerBound = parent.index + 1
                upperBound = mappingEnd(parent)
            } else {
                expectedIndent = 0
            }
            var found: [MappingLine] = []
            for index in lowerBound..<upperBound {
                guard let parsed = try Self.parseMappingLine(lines[index], index: index),
                      parsed.indent == expectedIndent,
                      parsed.key == component else { continue }
                found.append(parsed)
            }
            guard found.count <= 1 else {
                throw ClientConfigurationError.invalidConfiguration("Hermes config.yaml 含有重复配置字段")
            }
            guard let match = found.first else { return nil }
            parent = match
            lowerBound = match.index + 1
            upperBound = mappingEnd(match)
        }
        return parent
    }

    private func directChildren(of parent: MappingLine) -> [MappingLine] {
        guard let indentation = directChildIndent(of: parent) else { return [] }
        let end = mappingEnd(parent)
        return (parent.index + 1..<end).compactMap { index in
            guard let parsed = try? Self.parseMappingLine(lines[index], index: index),
                  parsed.indent == indentation else { return nil }
            return parsed
        }
    }

    private func directChildIndent(of parent: MappingLine) -> Int? {
        let end = mappingEnd(parent)
        return (parent.index + 1..<end).compactMap { index -> Int? in
            guard let parsed = try? Self.parseMappingLine(lines[index], index: index),
                  parsed.indent > parent.indent else { return nil }
            return parsed.indent
        }.min()
    }

    private func mappingEnd(_ mapping: MappingLine) -> Int {
        var index = mapping.index + 1
        while index < lines.count {
            if Self.isBlankOrComment(lines[index]) {
                index += 1
                continue
            }
            if Self.indentation(lines[index]) <= mapping.indent { break }
            index += 1
        }
        return index
    }

    private mutating func removeMappingSpans(_ mappings: [MappingLine]) {
        for mapping in mappings.sorted(by: { $0.index > $1.index }) {
            var end = mappingEnd(mapping)
            while end > mapping.index + 1, Self.isBlankOrComment(lines[end - 1]) {
                end -= 1
            }
            lines.removeSubrange(mapping.index..<end)
        }
    }

    private func validateUniqueOwnedPaths() throws {
        for path in [
            ["providers"],
            ["providers", "yakcool"],
            ["providers", "yakcool", "models"],
            ["model"],
        ] {
            _ = try locateMapping(path)
        }
    }

    private func validateDocumentShape() throws {
        for line in lines {
            let code = Self.codeBeforeComment(line)
                .trimmingCharacters(in: .whitespaces)
            if code == "---" || code == "..." || code.hasPrefix("%YAML")
                || code.hasPrefix("%TAG") {
                throw ClientConfigurationError.invalidConfiguration(
                    "Hermes config.yaml 不支持 YAML 文档标记或指令"
                )
            }
        }
    }

    private func validateOwnedMappingShapes() throws {
        let paths = [
            ["providers"],
            ["providers", "yakcool"],
            ["providers", "yakcool", "models"],
            ["model"],
        ]
        for path in paths {
            guard let mapping = try locateMapping(path) else { continue }
            guard mapping.rawValue.isEmpty else {
                throw ClientConfigurationError.invalidConfiguration(
                    "Hermes config.yaml 的 \(path.joined(separator: ".")) 必须使用块映射"
                )
            }
            let directLines = physicalDirectChildren(of: mapping)
            for item in directLines {
                let trimmed = item.line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("-") else {
                    throw ClientConfigurationError.invalidConfiguration(
                        "Hermes config.yaml 的 \(path.joined(separator: ".")) 不能是序列"
                    )
                }
                guard let child = try Self.parseMappingLine(item.line, index: item.index) else {
                    throw ClientConfigurationError.invalidConfiguration(
                        "Hermes config.yaml 的 \(path.joined(separator: ".")) 含有不支持的 YAML 结构"
                    )
                }
                guard child.key != "<<" else {
                    throw ClientConfigurationError.invalidConfiguration(
                        "Hermes config.yaml 的 YConnect 配置不能使用 YAML merge key"
                    )
                }
                if path == ["providers"], child.key != "yakcool" { continue }
                if path == ["model"], !["default", "provider"].contains(child.key) {
                    continue
                }
                let value = child.rawValue.trimmingCharacters(in: .whitespaces)
                let isGeneratedEmptyModel = path == ["providers", "yakcool", "models"]
                    && value == "{}"
                // `extra_headers` is an owned compatibility override that is
                // removed wholesale, so a flow collection is safe to discard.
                let isDiscardedExtraHeadersFlow = path == ["providers", "yakcool"]
                    && child.key == "extra_headers"
                    && (value.hasPrefix("{") || value.hasPrefix("["))
                if !value.isEmpty,
                   !isGeneratedEmptyModel,
                   !isDiscardedExtraHeadersFlow,
                   ["[", "{", "&", "*", "!", "|", ">"]
                    .contains(where: value.hasPrefix) {
                    throw ClientConfigurationError.invalidConfiguration(
                        "Hermes config.yaml 的 YConnect 配置不能使用 flow、anchor、tag 或块标量"
                    )
                }
            }
        }
    }

    private func physicalDirectChildren(
        of parent: MappingLine
    ) -> [(index: Int, line: String)] {
        let end = mappingEnd(parent)
        let content = (parent.index + 1..<end).compactMap { index -> (Int, String, Int)? in
            let line = lines[index]
            guard !Self.isBlankOrComment(line) else { return nil }
            let indent = Self.indentation(line)
            guard indent > parent.indent else { return nil }
            return (index, line, indent)
        }
        guard let directIndent = content.map(\.2).min() else { return [] }
        return content.filter { $0.2 == directIndent }.map { ($0.0, $0.1) }
    }

    private static func parseMappingLine(_ line: String, index: Int) throws -> MappingLine? {
        if isBlankOrComment(line) { return nil }
        let indent = indentation(line)
        let content = String(line.dropFirst(indent))
        if content.hasPrefix("-") || content == "---" || content == "..." { return nil }
        var quote: Character?
        var escaped = false
        var colon: String.Index?
        var cursor = content.startIndex
        while cursor < content.endIndex {
            let character = content[cursor]
            if let active = quote {
                if active == "\"" {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == active { quote = nil }
                } else if character == active {
                    let next = content.index(after: cursor)
                    if next < content.endIndex, content[next] == "'" { cursor = next }
                    else { quote = nil }
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ":" {
                colon = cursor
                break
            } else if character == "#" {
                return nil
            }
            cursor = content.index(after: cursor)
        }
        guard quote == nil, let colon else { return nil }
        let rawKey = content[..<colon].trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty, let key = decodeKey(String(rawKey)) else { return nil }
        let afterColon = content.index(after: colon)
        let rawValue = codeBeforeComment(String(content[afterColon...]))
            .trimmingCharacters(in: .whitespaces)
        return MappingLine(index: index, indent: indent, key: key, rawValue: rawValue)
    }

    private static func decodeKey(_ raw: String) -> String? {
        if raw.hasPrefix("\"") {
            guard let data = "[\(raw)]".data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
            return values.first
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    private static func scalarValue(_ raw: String) -> String? {
        guard !raw.isEmpty, raw != "{}", raw != "[]" else { return nil }
        if raw.hasPrefix("\"") {
            guard let data = "[\(raw)]".data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
            return values.first
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    private static func codeBeforeComment(_ source: String) -> String {
        var quote: Character?
        var escaped = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if let active = quote {
                if active == "\"" {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == active { quote = nil }
                } else if character == active {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(source[..<index])
            }
            index = source.index(after: index)
        }
        return source
    }

    private static func quoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let source = String(decoding: data, as: UTF8.self)
        return String(source.dropFirst().dropLast())
    }

    private static func renderKey(_ key: String) -> String {
        let bare = key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
        }
        return bare && !key.isEmpty ? key : ((try? quoted(key)) ?? "\"invalid\"")
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }
}

// MARK: - Claude Desktop on third-party inference

final class ClaudeDesktopClientConfigurator: ClientConfiguring {
    static let profileID = "9d254f75-6d3a-4b8c-a0e8-4d3a4f4d42f7"
    static let profileName = "YakCool (YConnect)"
    static let helperTTLSeconds = 300
    static let helperTimeoutSeconds = 5

    static let descriptor = ClientDescriptor(
        id: .claudeDesktop,
        name: "Claude Desktop",
        shortName: "Claude Desktop",
        symbol: "desktopcomputer",
        summary: "Claude Desktop third-party inference",
        supportedProtocols: [.anthropicMessages],
        configurationPath: "~/Library/Application Support/Claude-3p/configLibrary",
        restartNote: "请完全退出并重新打开 Claude Desktop",
        availability: .ready
    )

    var descriptor: ClientDescriptor { ClaudeDesktopClientConfigurator.descriptor }
    let profileURL: URL
    let metadataURL: URL
    let helperURL: URL
    let secretURL: URL

    private static let credentialTargetID = "credential"
    private static let helperTargetID = "helper"
    private static let profileTargetID = "profile"
    private static let metadataTargetID = "metadata"
    private let coordinator: ConfigurationTransactionCoordinator

    init(
        environment: AppEnvironment,
        fileManager: FileManager = .default,
        hooks: ConfigurationTransactionHooks = .none
    ) throws {
        let urls = environment.configurationURLs(for: .claudeDesktop)
        guard urls.count == 2 else {
            throw ClientConfigurationError.invalidConfiguration("Claude Desktop 配置路径不完整")
        }
        profileURL = urls[0]
        metadataURL = urls[1]
        helperURL = environment.managedHelperURL(for: .claudeDesktop)
        secretURL = environment.managedSecretURL(for: .claudeDesktop)
        guard profileURL.deletingPathExtension().lastPathComponent == Self.profileID else {
            throw ClientConfigurationError.invalidConfiguration("Claude Desktop 配置档案 ID 不一致")
        }
        coordinator = try ConfigurationTransactionCoordinator(
            identifier: ClientID.claudeDesktop.rawValue,
            targets: [
                ConfigurationTransactionTarget(
                    id: Self.credentialTargetID,
                    url: secretURL,
                    sensitivity: .secret,
                    writePermissions: 0o600
                ),
                ConfigurationTransactionTarget(
                    id: Self.helperTargetID,
                    url: helperURL,
                    writePermissions: 0o700
                ),
                ConfigurationTransactionTarget(id: Self.profileTargetID, url: profileURL),
                ConfigurationTransactionTarget(id: Self.metadataTargetID, url: metadataURL),
            ],
            backupsDirectory: environment.backupsDirectory(for: .claudeDesktop),
            fileManager: fileManager,
            hooks: hooks
        )
    }

    var targets: [ClientConfigurationTarget] {
        [
            ClientConfigurationTarget(url: secretURL, role: .credential),
            ClientConfigurationTarget(url: helperURL, role: .helper),
            ClientConfigurationTarget(url: profileURL, role: .configuration),
            ClientConfigurationTarget(url: metadataURL, role: .configuration),
        ]
    }

    func compatibleModels(from models: [ClientModelOption]) -> [ClientModelOption] {
        models.filter {
            $0.protocols.contains(.anthropicMessages) && Self.isClaudeModelID($0.id)
        }
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        let selected = try validatedSelection(request)
        let plan = mutationPlan(request, selected: selected)
        return try coordinator.withValidatedPlan(plan: plan) { state, mutations in
            let credential = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.credentialTargetID,
                in: mutations
            )
            let helper = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.helperTargetID,
                in: mutations
            )
            let profile = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.profileTargetID,
                in: mutations
            )
            let metadata = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.metadataTargetID,
                in: mutations
            )
            return ClientConfigurationPreview(
                clientID: descriptor.id,
                selectedModelID: selected.id,
                changes: [
                    ClientFileChangePreview(
                        url: secretURL,
                        role: .credential,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.credentialTargetID,
                            desiredData: credential,
                            permissions: 0o600
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: helperURL,
                        role: .helper,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.helperTargetID,
                            desiredData: helper,
                            permissions: 0o700
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: profileURL,
                        role: .configuration,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.profileTargetID,
                            desiredData: profile,
                            permissions: 0o600
                        ),
                        renderedText: try ExtendedClientConfiguratorSupport.jsonPreview(
                            profile,
                            label: "Claude Desktop profile"
                        )
                    ),
                    ClientFileChangePreview(
                        url: metadataURL,
                        role: .configuration,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.metadataTargetID,
                            desiredData: metadata,
                            permissions: 0o600
                        ),
                        renderedText: try ExtendedClientConfiguratorSupport.jsonPreview(
                            metadata,
                            label: "Claude Desktop _meta.json"
                        )
                    ),
                ]
            )
        }
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        let selected = try validatedSelection(request)
        let expectedCredential = Data(request.apiKey.utf8)
        let plan = mutationPlan(request, selected: selected)
        let result = try coordinator.apply(plan: plan) { state in
            try self.validateInstalled(
                state,
                expectedModelID: selected.id,
                expectedCredential: expectedCredential
            )
        }
        return mappedResult(result, modelID: selected.id, restored: false)
    }

    func inspect() throws -> ClientConfigurationStatus {
        let backupURL = try coordinator.latestBackupURL()
        return try coordinator.withSnapshot { state in
            do {
                let profile = try ExtendedJSONConfiguration.rootObject(
                    from: state.data(for: Self.profileTargetID),
                    label: "Claude Desktop profile"
                )
                let metadata = try ExtendedJSONConfiguration.rootObject(
                    from: state.data(for: Self.metadataTargetID),
                    label: "Claude Desktop _meta.json"
                )
                let modelIDs = Self.modelIDs(in: profile)
                let selectedModelID = modelIDs.first
                let active = metadata["appliedId"] as? String == Self.profileID
                let entryPresent = Self.metadataHasManagedEntry(metadata)
                let helperConfigured = profile["inferenceCredentialKind"] as? String == "helper-script"
                    && profile["inferenceCredentialHelper"] as? String == helperURL.path
                let inlineCredential = profile["inferenceGatewayApiKey"] != nil
                let secretSecure = state.file(Self.credentialTargetID)?.exists == true
                    && state.file(Self.credentialTargetID)?.permissions == 0o600
                let helperSecure = state.file(Self.helperTargetID)?.exists == true
                    && state.file(Self.helperTargetID)?.permissions == 0o700
                    && state.data(for: Self.helperTargetID)
                        == ExtendedClientConfiguratorSupport.helperData(secretURL: secretURL)
                let modelValid = selectedModelID.map(Self.isClaudeModelID) == true
                    && modelIDs.allSatisfy(Self.isClaudeModelID)
                let profileValid = profile["inferenceProvider"] as? String == "gateway"
                    && profile["inferenceGatewayBaseUrl"] as? String
                        == ExtendedClientConfiguratorSupport.gatewayHost
                    && profile["inferenceGatewayAuthScheme"] as? String == "bearer"
                    && profile["inferenceCredentialHelperTtlSec"] as? Int == Self.helperTTLSeconds
                    && profile["inferenceCredentialHelperTimeoutSec"] as? Int == Self.helperTimeoutSeconds
                    && profile["inferenceCredentialHelperSilentRefreshEnabled"] as? Bool == true
                    && modelValid
                let hasMarker = state.file(Self.profileTargetID)?.exists == true || active || entryPresent
                let configured = hasMarker && active && entryPresent && profileValid
                    && helperConfigured && helperSecure && secretSecure && !inlineCredential

                var issues: [String] = []
                if hasMarker && !active { issues.append("Claude Desktop 未启用 YConnect 配置档案") }
                if hasMarker && !entryPresent { issues.append("Claude Desktop 配置库缺少 YConnect 条目") }
                if hasMarker && !profileValid { issues.append("Claude Desktop YakCool 配置或模型无效") }
                if inlineCredential { issues.append("Claude Desktop 配置含有内联 API Key") }
                if hasMarker && !helperConfigured { issues.append("Claude Desktop 未使用 YConnect credential helper") }
                if helperConfigured && !helperSecure { issues.append("Claude Desktop helper 缺失、内容漂移或权限不是 0700") }
                if helperConfigured && !secretSecure { issues.append("Claude Desktop 密钥文件缺失或权限不是 0600") }

                let protection: CredentialProtection
                if inlineCredential {
                    protection = .unexpectedInline
                } else if helperConfigured {
                    protection = helperSecure && secretSecure ? .safeReference : .missing
                } else if secretSecure {
                    protection = .managedFileSecure
                } else {
                    protection = .missing
                }
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: configured ? .configured : (hasMarker ? .drifted : .notConfigured),
                    selectedModelID: selectedModelID,
                    configuredModelIDs: modelIDs,
                    credentialProtection: protection,
                    latestBackupURL: backupURL,
                    issues: issues
                )
            } catch {
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: .invalid,
                    selectedModelID: nil,
                    configuredModelIDs: [],
                    credentialProtection: .missing,
                    latestBackupURL: backupURL,
                    issues: ["Claude Desktop 配置无法解析"]
                )
            }
        }
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result: ConfigurationTransactionResult
        do {
            result = try coordinator.restoreLatest { state in
                if state.file(Self.profileTargetID)?.exists == true {
                    _ = try ExtendedJSONConfiguration.rootObject(
                        from: state.data(for: Self.profileTargetID),
                        label: "Claude Desktop profile"
                    )
                }
                if state.file(Self.metadataTargetID)?.exists == true {
                    _ = try ExtendedJSONConfiguration.rootObject(
                        from: state.data(for: Self.metadataTargetID),
                        label: "Claude Desktop _meta.json"
                    )
                }
                try ExtendedClientConfiguratorSupport.validateRestoredHelper(
                    in: state,
                    targetID: Self.helperTargetID,
                    secretURL: self.secretURL,
                    clientName: self.descriptor.name
                )
            }
        } catch ConfigurationTransactionError.noBackup {
            throw ClientConfigurationError.noBackup(descriptor.name)
        }
        return mappedResult(result, modelID: nil, restored: true)
    }

    private struct DesiredDocuments {
        let credential: Data
        let helper: Data
        let profile: Data
        let metadata: Data
    }

    private func mutationPlan(
        _ request: ClientApplyRequest,
        selected: ClientModelOption
    ) -> ConfigurationTransactionCoordinator.Plan {
        { state in
            let desired = try self.desiredDocuments(request, selected: selected, state: state)
            return [
                .write(targetID: Self.credentialTargetID, data: desired.credential),
                .write(targetID: Self.helperTargetID, data: desired.helper),
                .write(targetID: Self.profileTargetID, data: desired.profile),
                .write(targetID: Self.metadataTargetID, data: desired.metadata),
            ]
        }
    }

    private func desiredDocuments(
        _ request: ClientApplyRequest,
        selected: ClientModelOption,
        state: ConfigurationTransactionState
    ) throws -> DesiredDocuments {
        var profile = try ExtendedJSONConfiguration.rootObject(
            from: state.data(for: Self.profileTargetID),
            label: "Claude Desktop profile"
        )
        var metadata = try ExtendedJSONConfiguration.rootObject(
            from: state.data(for: Self.metadataTargetID),
            label: "Claude Desktop _meta.json"
        )
        profile.removeValue(forKey: "inferenceGatewayApiKey")
        profile["inferenceProvider"] = "gateway"
        profile["inferenceGatewayBaseUrl"] = ExtendedClientConfiguratorSupport.gatewayHost
        profile["inferenceGatewayAuthScheme"] = "bearer"
        profile["inferenceCredentialKind"] = "helper-script"
        profile["inferenceCredentialHelper"] = helperURL.path
        profile["inferenceCredentialHelperTtlSec"] = Self.helperTTLSeconds
        profile["inferenceCredentialHelperTimeoutSec"] = Self.helperTimeoutSeconds
        profile["inferenceCredentialHelperSilentRefreshEnabled"] = true
        profile["inferenceModels"] = orderedModels(request, selected: selected).map { model in
            ["name": model.id, "labelOverride": model.name]
        }

        var entries: [Any]
        if let value = metadata["entries"] {
            guard let array = value as? [Any] else {
                throw ClientConfigurationError.invalidConfiguration("Claude Desktop _meta.json 的 entries 必须是数组")
            }
            entries = array
        } else {
            entries = []
        }
        var managedEntry = entries.compactMap { $0 as? [String: Any] }
            .first { $0["id"] as? String == Self.profileID } ?? [:]
        entries.removeAll { ($0 as? [String: Any])?["id"] as? String == Self.profileID }
        managedEntry["id"] = Self.profileID
        managedEntry["name"] = Self.profileName
        entries.append(managedEntry)
        metadata["entries"] = entries
        metadata["appliedId"] = Self.profileID

        let credential = Data(request.apiKey.utf8)
        let helper = ExtendedClientConfiguratorSupport.helperData(secretURL: secretURL)
        let profileData = try JSONConfigurationEditor.serialized(profile, label: "Claude Desktop profile")
        let metadataData = try JSONConfigurationEditor.serialized(metadata, label: "Claude Desktop _meta.json")
        guard !ExtendedClientConfiguratorSupport.contains(profileData, literal: request.apiKey),
              !ExtendedClientConfiguratorSupport.contains(metadataData, literal: request.apiKey),
              !ExtendedClientConfiguratorSupport.contains(helper, literal: request.apiKey) else {
            throw ClientConfigurationError.invalidConfiguration("Claude Desktop 配置含有不安全的内联凭据")
        }
        return DesiredDocuments(
            credential: credential,
            helper: helper,
            profile: profileData,
            metadata: metadataData
        )
    }

    private func validatedSelection(_ request: ClientApplyRequest) throws -> ClientModelOption {
        try ExtendedClientConfiguratorSupport.validateAPIKey(request.apiKey)
        try ExtendedClientConfiguratorSupport.validateModelID(request.selectedModelID)
        guard let selected = compatibleModels(from: request.models).first(where: {
            $0.id == request.selectedModelID
        }) else {
            throw ClientConfigurationError.invalidSelection(
                "Claude Desktop 仅支持声明 Anthropic Messages 的 Claude 模型"
            )
        }
        try ExtendedClientConfiguratorSupport.validateModelName(selected.name)
        try ExtendedClientConfiguratorSupport.validateOutputModels(
            orderedModels(request, selected: selected)
        )
        return selected
    }

    private func orderedModels(
        _ request: ClientApplyRequest,
        selected: ClientModelOption
    ) -> [ClientModelOption] {
        var seen: Set<String> = [selected.id]
        return [selected] + compatibleModels(from: request.models).filter { seen.insert($0.id).inserted }
    }

    private func validateInstalled(
        _ state: ConfigurationTransactionState,
        expectedModelID: String,
        expectedCredential: Data
    ) throws {
        let profile = try ExtendedJSONConfiguration.rootObject(
            from: state.data(for: Self.profileTargetID),
            label: "Claude Desktop profile"
        )
        let metadata = try ExtendedJSONConfiguration.rootObject(
            from: state.data(for: Self.metadataTargetID),
            label: "Claude Desktop _meta.json"
        )
        guard state.data(for: Self.credentialTargetID) == expectedCredential,
              state.file(Self.credentialTargetID)?.permissions == 0o600,
              state.data(for: Self.helperTargetID)
                == ExtendedClientConfiguratorSupport.helperData(secretURL: secretURL),
              state.file(Self.helperTargetID)?.permissions == 0o700,
              state.file(Self.profileTargetID)?.permissions == 0o600,
              state.file(Self.metadataTargetID)?.permissions == 0o600,
              profile["inferenceProvider"] as? String == "gateway",
              profile["inferenceGatewayBaseUrl"] as? String
                == ExtendedClientConfiguratorSupport.gatewayHost,
              profile["inferenceGatewayAuthScheme"] as? String == "bearer",
              profile["inferenceCredentialKind"] as? String == "helper-script",
              profile["inferenceCredentialHelper"] as? String == helperURL.path,
              profile["inferenceCredentialHelperTtlSec"] as? Int == Self.helperTTLSeconds,
              profile["inferenceCredentialHelperTimeoutSec"] as? Int == Self.helperTimeoutSeconds,
              profile["inferenceCredentialHelperSilentRefreshEnabled"] as? Bool == true,
              profile["inferenceGatewayApiKey"] == nil,
              Self.modelIDs(in: profile).first == expectedModelID,
              metadata["appliedId"] as? String == Self.profileID,
              Self.metadataHasManagedEntry(metadata) else {
            throw ClientConfigurationError.invalidConfiguration("Claude Desktop 写后校验失败")
        }
    }

    private func mappedResult(
        _ result: ConfigurationTransactionResult,
        modelID: String?,
        restored: Bool
    ) -> ClientConfigurationResult {
        let urls: [String: URL] = [
            Self.credentialTargetID: secretURL,
            Self.helperTargetID: helperURL,
            Self.profileTargetID: profileURL,
            Self.metadataTargetID: metadataURL,
        ]
        let action = ExtendedClientConfiguratorSupport.clientAction(result.action)
        let message: String
        if restored {
            message = action == .unchanged
                ? "Claude Desktop 配置已是最近备份状态"
                : "已恢复最近一次 Claude Desktop 配置备份"
        } else {
            message = action == .unchanged
                ? "Claude Desktop 已在使用所选 YakCool 模型"
                : "已将 Claude Desktop 切换到 YakCool / \(modelID ?? "")"
        }
        return ClientConfigurationResult(
            action: action,
            clientID: descriptor.id,
            changedTargets: result.changedTargetIDs.compactMap { urls[$0] },
            backupURL: result.backupURL,
            modelID: modelID,
            message: message
        )
    }

    private static func isClaudeModelID(_ modelID: String) -> Bool {
        let normalized = modelID.lowercased()
        if normalized.hasPrefix("anthropic/claude-") {
            return normalized.count > "anthropic/claude-".count
        }
        if normalized.hasPrefix("claude-") {
            return normalized.count > "claude-".count
        }
        return false
    }

    private static func modelIDs(in profile: [String: Any]) -> [String] {
        guard let models = profile["inferenceModels"] as? [Any] else { return [] }
        return models.compactMap { value in
            if let string = value as? String { return string }
            return (value as? [String: Any])?["name"] as? String
        }
    }

    private static func metadataHasManagedEntry(_ metadata: [String: Any]) -> Bool {
        (metadata["entries"] as? [Any])?.contains {
            ($0 as? [String: Any])?["id"] as? String == profileID
        } == true
    }
}

// MARK: - OpenClaw

final class OpenClawClientConfigurator: ClientConfiguring {
    static let providerID = "yakcool"
    static let secretProviderID = "yconnect"
    static let secretTimeoutMilliseconds = 5_000

    static let descriptor = ClientDescriptor(
        id: .openClaw,
        name: "OpenClaw",
        shortName: "OpenClaw",
        symbol: "pawprint",
        summary: "OpenClaw agent gateway",
        supportedProtocols: [.responses, .anthropicMessages, .chatCompletions],
        configurationPath: "~/.openclaw/openclaw.json",
        restartNote: "请重新启动 OpenClaw gateway",
        availability: .ready
    )

    var descriptor: ClientDescriptor { OpenClawClientConfigurator.descriptor }
    let configurationURL: URL
    let secretURL: URL

    private static let configurationTargetID = "configuration"
    private static let credentialTargetID = "credential"
    private let coordinator: ConfigurationTransactionCoordinator

    init(
        environment: AppEnvironment,
        fileManager: FileManager = .default,
        hooks: ConfigurationTransactionHooks = .none,
        maximumConfigurationByteCount: Int = 16 * 1_024 * 1_024
    ) throws {
        guard let configurationURL = environment.configurationURLs(for: .openClaw).first else {
            throw ClientConfigurationError.invalidConfiguration("OpenClaw 配置路径不存在")
        }
        self.configurationURL = configurationURL
        secretURL = environment.managedSecretURL(for: .openClaw)
        coordinator = try ConfigurationTransactionCoordinator(
            identifier: ClientID.openClaw.rawValue,
            targets: [
                ConfigurationTransactionTarget(
                    id: Self.credentialTargetID,
                    url: secretURL,
                    sensitivity: .secret,
                    writePermissions: 0o600
                ),
                ConfigurationTransactionTarget(
                    id: Self.configurationTargetID,
                    url: configurationURL,
                    maximumByteCount: maximumConfigurationByteCount
                ),
            ],
            backupsDirectory: environment.backupsDirectory(for: .openClaw),
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
        let protocolValue = try ExtendedClientConfiguratorSupport.preferredProtocol(for: selected)
        let plan = mutationPlan(
            request,
            selected: selected,
            protocolValue: protocolValue
        )
        return try coordinator.withValidatedPlan(plan: plan) { state, mutations in
            let credential = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.credentialTargetID,
                in: mutations
            )
            let configuration = try ExtendedClientConfiguratorSupport.writtenData(
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
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.credentialTargetID,
                            desiredData: credential,
                            permissions: 0o600
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: configurationURL,
                        role: .configuration,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.configurationTargetID,
                            desiredData: configuration,
                            permissions: 0o600
                        ),
                        renderedText: try ExtendedClientConfiguratorSupport.jsonPreview(
                            configuration,
                            label: "OpenClaw openclaw.json"
                        )
                    ),
                ]
            )
        }
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        let selected = try validatedSelection(request)
        let protocolValue = try ExtendedClientConfiguratorSupport.preferredProtocol(for: selected)
        let expectedModelIDs = orderedModels(
            request,
            selected: selected,
            protocolValue: protocolValue
        ).map(\.id)
        let expectedCredential = Data(request.apiKey.utf8)
        let plan = mutationPlan(
            request,
            selected: selected,
            protocolValue: protocolValue
        )
        let result = try coordinator.apply(plan: plan) { state in
            try self.validateInstalled(
                state,
                expectedModelID: selected.id,
                expectedModelIDs: expectedModelIDs,
                expectedProtocol: protocolValue,
                expectedCredential: expectedCredential
            )
        }
        return mappedResult(result, modelID: selected.id, restored: false)
    }

    func inspect() throws -> ClientConfigurationStatus {
        let backupURL = try coordinator.latestBackupURL()
        return try coordinator.withSnapshot { state in
            do {
                let root = try ExtendedJSONConfiguration.rootObject(
                    from: state.data(for: Self.configurationTargetID),
                    label: "OpenClaw openclaw.json"
                )
                let models = root["models"] as? [String: Any]
                let providers = models?["providers"] as? [String: Any]
                let provider = providers?[Self.providerID] as? [String: Any]
                let secrets = root["secrets"] as? [String: Any]
                let secretProviders = secrets?["providers"] as? [String: Any]
                let secretProvider = secretProviders?[Self.secretProviderID] as? [String: Any]
                let agents = root["agents"] as? [String: Any]
                let defaults = agents?["defaults"] as? [String: Any]
                let modelSelection = defaults?["model"] as? [String: Any]
                let primary = modelSelection?["primary"] as? String
                let selectedModelID = Self.selectedModelID(from: primary)
                let configuredModels = Self.providerModelIDs(provider)
                let apiName = provider?["api"] as? String
                let expectedEndpoint = Self.protocolValue(forAPIName: apiName)
                    .map(ExtendedClientConfiguratorSupport.endpoint(for:))
                let endpointValid = provider?["baseUrl"] as? String == expectedEndpoint
                    && expectedEndpoint != nil
                let reference = provider?["apiKey"] as? [String: Any]
                let referenceValid = reference?["source"] as? String == "file"
                    && reference?["provider"] as? String == Self.secretProviderID
                    && reference?["id"] as? String == "value"
                let secretProviderValid = secretProvider?["source"] as? String == "file"
                    && secretProvider?["path"] as? String == secretURL.path
                    && secretProvider?["mode"] as? String == "singleValue"
                    && secretProvider?["timeoutMs"] as? Int == Self.secretTimeoutMilliseconds
                let inlineCredential = provider?["apiKey"] != nil && reference == nil
                    || ["api_key", "token", "authorization", "password", "secret"].contains {
                        provider?[$0] != nil
                    }
                    || provider?["headers"] != nil
                    || provider?["extraHeaders"] != nil
                    || provider?["request"] != nil
                    || ["apiKey", "token", "password", "secret", "value"].contains {
                        secretProvider?[$0] != nil
                    }
                    || secretProvider?["headers"] != nil
                    || secretProvider?["extraHeaders"] != nil
                let credentialSecure = state.file(Self.credentialTargetID)?.exists == true
                    && state.file(Self.credentialTargetID)?.permissions == 0o600
                let modelValid = selectedModelID?.isEmpty == false
                    && selectedModelID.map(configuredModels.contains) == true
                let hasMarker = provider != nil || secretProvider != nil
                    || selectedModelID != nil
                let configured = hasMarker
                    && models?["mode"] as? String == "merge"
                    && endpointValid
                    && modelValid
                    && referenceValid
                    && secretProviderValid
                    && credentialSecure
                    && !inlineCredential

                var issues: [String] = []
                if hasMarker && !endpointValid { issues.append("OpenClaw YakCool 协议或端点无效") }
                if hasMarker && !modelValid { issues.append("OpenClaw 默认模型未指向 YakCool 模型目录") }
                if inlineCredential { issues.append("OpenClaw YakCool 配置含有内联凭据") }
                if hasMarker && (!referenceValid || !secretProviderValid) {
                    issues.append("OpenClaw 未使用 YConnect file SecretRef")
                }
                if referenceValid && !credentialSecure {
                    issues.append("OpenClaw 密钥文件缺失或权限不是 0600")
                }

                let protection: CredentialProtection
                if inlineCredential {
                    protection = .unexpectedInline
                } else if referenceValid && secretProviderValid {
                    protection = credentialSecure ? .safeReference : .missing
                } else if credentialSecure {
                    protection = .managedFileSecure
                } else {
                    protection = .missing
                }
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: configured ? .configured : (hasMarker ? .drifted : .notConfigured),
                    selectedModelID: selectedModelID,
                    configuredModelIDs: configuredModels,
                    credentialProtection: protection,
                    latestBackupURL: backupURL,
                    issues: issues
                )
            } catch {
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: .invalid,
                    selectedModelID: nil,
                    configuredModelIDs: [],
                    credentialProtection: .missing,
                    latestBackupURL: backupURL,
                    issues: ["OpenClaw 配置无法解析"]
                )
            }
        }
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result: ConfigurationTransactionResult
        do {
            result = try coordinator.restoreLatest { state in
                if state.file(Self.configurationTargetID)?.exists == true {
                    _ = try ExtendedJSONConfiguration.rootObject(
                        from: state.data(for: Self.configurationTargetID),
                        label: "OpenClaw openclaw.json"
                    )
                }
            }
        } catch ConfigurationTransactionError.noBackup {
            throw ClientConfigurationError.noBackup(descriptor.name)
        }
        return mappedResult(result, modelID: nil, restored: true)
    }

    private func validatedSelection(_ request: ClientApplyRequest) throws -> ClientModelOption {
        try ExtendedClientConfiguratorSupport.validateAPIKey(request.apiKey)
        try ExtendedClientConfiguratorSupport.validateModelID(request.selectedModelID)
        guard let selected = compatibleModels(from: request.models).first(where: {
            $0.id == request.selectedModelID
        }) else {
            throw ClientConfigurationError.invalidSelection(
                "所选模型不支持 OpenClaw 可用的 Responses、Messages 或 Chat Completions 协议"
            )
        }
        try ExtendedClientConfiguratorSupport.validateModelName(selected.name)
        let protocolValue = try ExtendedClientConfiguratorSupport.preferredProtocol(for: selected)
        try ExtendedClientConfiguratorSupport.validateOutputModels(
            orderedModels(request, selected: selected, protocolValue: protocolValue)
        )
        return selected
    }

    private func mutationPlan(
        _ request: ClientApplyRequest,
        selected: ClientModelOption,
        protocolValue: AIProtocol
    ) -> ConfigurationTransactionCoordinator.Plan {
        { state in
            let configuration = try self.desiredConfiguration(
                request,
                selected: selected,
                protocolValue: protocolValue,
                existing: state.data(for: Self.configurationTargetID)
            )
            return [
                .write(targetID: Self.credentialTargetID, data: Data(request.apiKey.utf8)),
                .write(targetID: Self.configurationTargetID, data: configuration),
            ]
        }
    }

    private func desiredConfiguration(
        _ request: ClientApplyRequest,
        selected: ClientModelOption,
        protocolValue: AIProtocol,
        existing: Data?
    ) throws -> Data {
        var root = try ExtendedJSONConfiguration.rootObject(
            from: existing,
            label: "OpenClaw openclaw.json"
        )

        var models = try Self.object(root["models"], label: "OpenClaw models")
        var providers = try Self.object(models["providers"], label: "OpenClaw models.providers")
        var provider = try Self.object(
            providers[Self.providerID],
            label: "OpenClaw models.providers.yakcool"
        )
        let compatible = orderedModels(request, selected: selected, protocolValue: protocolValue)
        provider["baseUrl"] = ExtendedClientConfiguratorSupport.endpoint(for: protocolValue)
        provider["api"] = Self.apiName(for: protocolValue)
        provider["apiKey"] = [
            "source": "file",
            "provider": Self.secretProviderID,
            "id": "value",
        ]
        for key in [
            "api_key", "token", "authorization", "password", "secret",
            "headers", "extraHeaders", "request",
        ] {
            provider.removeValue(forKey: key)
        }
        provider["models"] = try mergedModelEntries(existing: provider["models"], models: compatible)
        providers[Self.providerID] = provider
        models["providers"] = providers
        models["mode"] = "merge"
        root["models"] = models

        var secrets = try Self.object(root["secrets"], label: "OpenClaw secrets")
        var secretProviders = try Self.object(
            secrets["providers"],
            label: "OpenClaw secrets.providers"
        )
        var secretProvider = try Self.object(
            secretProviders[Self.secretProviderID],
            label: "OpenClaw secrets.providers.yconnect"
        )
        for key in [
            "apiKey", "token", "password", "secret", "value",
            "headers", "extraHeaders",
        ] {
            secretProvider.removeValue(forKey: key)
        }
        secretProvider["source"] = "file"
        secretProvider["path"] = secretURL.path
        secretProvider["mode"] = "singleValue"
        secretProvider["timeoutMs"] = Self.secretTimeoutMilliseconds
        secretProviders[Self.secretProviderID] = secretProvider
        secrets["providers"] = secretProviders
        root["secrets"] = secrets

        var agents = try Self.object(root["agents"], label: "OpenClaw agents")
        var defaults = try Self.object(agents["defaults"], label: "OpenClaw agents.defaults")
        var modelSelection: [String: Any]
        if defaults["model"] is String {
            modelSelection = [:]
        } else {
            modelSelection = try Self.object(
                defaults["model"],
                label: "OpenClaw agents.defaults.model"
            )
        }
        modelSelection["primary"] = "\(Self.providerID)/\(selected.id)"
        defaults["model"] = modelSelection
        agents["defaults"] = defaults
        root["agents"] = agents

        let data = try JSONConfigurationEditor.serialized(root, label: "OpenClaw openclaw.json")
        guard !ExtendedClientConfiguratorSupport.contains(data, literal: request.apiKey) else {
            throw ClientConfigurationError.invalidConfiguration("OpenClaw 配置含有不安全的内联凭据")
        }
        return data
    }

    private func orderedModels(
        _ request: ClientApplyRequest,
        selected: ClientModelOption,
        protocolValue: AIProtocol
    ) -> [ClientModelOption] {
        var seen: Set<String> = [selected.id]
        return [selected] + request.models.filter {
            $0.protocols.contains(protocolValue) && seen.insert($0.id).inserted
        }
    }

    private func mergedModelEntries(existing: Any?, models: [ClientModelOption]) throws -> [[String: Any]] {
        let oldEntries: [[String: Any]]
        if let existing {
            guard let array = existing as? [Any],
                  array.allSatisfy({ $0 is [String: Any] }) else {
                throw ClientConfigurationError.invalidConfiguration("OpenClaw YakCool models 必须是对象数组")
            }
            oldEntries = array.compactMap { $0 as? [String: Any] }
        } else {
            oldEntries = []
        }
        let byID = Dictionary(
            oldEntries.compactMap { entry -> (String, [String: Any])? in
                guard let id = entry["id"] as? String else { return nil }
                return (id, entry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return models.map { model in
            var entry = byID[model.id] ?? [:]
            entry["id"] = model.id
            entry["name"] = model.name
            return entry
        }
    }

    private func validateInstalled(
        _ state: ConfigurationTransactionState,
        expectedModelID: String,
        expectedModelIDs: [String],
        expectedProtocol: AIProtocol,
        expectedCredential: Data
    ) throws {
        let root = try ExtendedJSONConfiguration.rootObject(
            from: state.data(for: Self.configurationTargetID),
            label: "OpenClaw openclaw.json"
        )
        let models = root["models"] as? [String: Any]
        let provider = (models?["providers"] as? [String: Any])?[Self.providerID] as? [String: Any]
        let secretProvider = ((root["secrets"] as? [String: Any])?["providers"] as? [String: Any])?[Self.secretProviderID] as? [String: Any]
        let defaults = (root["agents"] as? [String: Any])?["defaults"] as? [String: Any]
        let primary = (defaults?["model"] as? [String: Any])?["primary"] as? String
        let reference = provider?["apiKey"] as? [String: Any]
        guard state.data(for: Self.credentialTargetID) == expectedCredential,
              state.file(Self.credentialTargetID)?.permissions == 0o600,
              state.file(Self.configurationTargetID)?.permissions == 0o600,
              models?["mode"] as? String == "merge",
              provider?["baseUrl"] as? String
                == ExtendedClientConfiguratorSupport.endpoint(for: expectedProtocol),
              provider?["api"] as? String == Self.apiName(for: expectedProtocol),
              provider?["headers"] == nil,
              provider?["extraHeaders"] == nil,
              provider?["request"] == nil,
              reference?["source"] as? String == "file",
              reference?["provider"] as? String == Self.secretProviderID,
              reference?["id"] as? String == "value",
              secretProvider?["source"] as? String == "file",
              secretProvider?["path"] as? String == secretURL.path,
              secretProvider?["mode"] as? String == "singleValue",
              secretProvider?["timeoutMs"] as? Int == Self.secretTimeoutMilliseconds,
              primary == "\(Self.providerID)/\(expectedModelID)",
              Self.providerModelIDs(provider) == expectedModelIDs else {
            throw ClientConfigurationError.invalidConfiguration("OpenClaw 写后校验失败")
        }
    }

    private func mappedResult(
        _ result: ConfigurationTransactionResult,
        modelID: String?,
        restored: Bool
    ) -> ClientConfigurationResult {
        let urls = [Self.credentialTargetID: secretURL, Self.configurationTargetID: configurationURL]
        let action = ExtendedClientConfiguratorSupport.clientAction(result.action)
        let message: String
        if restored {
            message = action == .unchanged
                ? "OpenClaw 配置已是最近备份状态"
                : "已恢复最近一次 OpenClaw 配置备份"
        } else {
            message = action == .unchanged
                ? "OpenClaw 已在使用所选 YakCool 模型"
                : "已将 OpenClaw 切换到 YakCool / \(modelID ?? "")"
        }
        return ClientConfigurationResult(
            action: action,
            clientID: descriptor.id,
            changedTargets: result.changedTargetIDs.compactMap { urls[$0] },
            backupURL: result.backupURL,
            modelID: modelID,
            message: message
        )
    }

    private static func object(_ value: Any?, label: String) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            throw ClientConfigurationError.invalidConfiguration("\(label) 必须是对象")
        }
        return object
    }

    private static func apiName(for protocolValue: AIProtocol) -> String {
        switch protocolValue {
        case .responses: return "openai-responses"
        case .anthropicMessages: return "anthropic-messages"
        default: return "openai-completions"
        }
    }

    private static func protocolValue(forAPIName value: String?) -> AIProtocol? {
        switch value {
        case "openai-responses": return .responses
        case "anthropic-messages": return .anthropicMessages
        case "openai-completions": return .chatCompletions
        default: return nil
        }
    }

    private static func selectedModelID(from primary: String?) -> String? {
        guard let primary, primary.hasPrefix("\(providerID)/") else { return nil }
        let value = String(primary.dropFirst(providerID.count + 1))
        return value.isEmpty ? nil : value
    }

    private static func providerModelIDs(_ provider: [String: Any]?) -> [String] {
        (provider?["models"] as? [Any])?.compactMap {
            ($0 as? [String: Any])?["id"] as? String
        } ?? []
    }
}

// MARK: - Hermes Agent

final class HermesClientConfigurator: ClientConfiguring {
    static let providerID = "yakcool"
    static let gatewayHost = "https://aibalance.yaklang.com"
    static let gatewayV1 = "https://aibalance.yaklang.com/v1"

    static let descriptor = ClientDescriptor(
        id: .hermes,
        name: "Hermes Agent",
        shortName: "Hermes",
        symbol: "figure.walk.motion",
        summary: "Nous Research Hermes Agent",
        supportedProtocols: [.responses, .anthropicMessages, .chatCompletions],
        configurationPath: "~/.hermes/config.yaml",
        restartNote: "请在新 Hermes 会话中载入配置",
        availability: .ready
    )

    var descriptor: ClientDescriptor { HermesClientConfigurator.descriptor }
    let configurationURL: URL
    let helperURL: URL
    let secretURL: URL

    private static let configurationTargetID = "configuration"
    private static let helperTargetID = "helper"
    private static let credentialTargetID = "credential"
    private let coordinator: ConfigurationTransactionCoordinator

    init(
        environment: AppEnvironment,
        fileManager: FileManager = .default,
        hooks: ConfigurationTransactionHooks = .none
    ) throws {
        guard let configurationURL = environment.configurationURLs(for: .hermes).first else {
            throw ClientConfigurationError.invalidConfiguration("Hermes 配置路径不存在")
        }
        self.configurationURL = configurationURL
        helperURL = environment.managedHelperURL(for: .hermes)
        secretURL = environment.managedSecretURL(for: .hermes)
        coordinator = try ConfigurationTransactionCoordinator(
            identifier: ClientID.hermes.rawValue,
            targets: [
                ConfigurationTransactionTarget(
                    id: Self.credentialTargetID,
                    url: secretURL,
                    sensitivity: .secret,
                    writePermissions: 0o600
                ),
                ConfigurationTransactionTarget(
                    id: Self.helperTargetID,
                    url: helperURL,
                    writePermissions: 0o700
                ),
                ConfigurationTransactionTarget(id: Self.configurationTargetID, url: configurationURL),
            ],
            backupsDirectory: environment.backupsDirectory(for: .hermes),
            fileManager: fileManager,
            hooks: hooks
        )
    }

    var targets: [ClientConfigurationTarget] {
        [
            ClientConfigurationTarget(url: secretURL, role: .credential),
            ClientConfigurationTarget(url: helperURL, role: .helper),
            ClientConfigurationTarget(url: configurationURL, role: .configuration),
        ]
    }

    func preview(_ request: ClientApplyRequest) throws -> ClientConfigurationPreview {
        let selected = try validatedSelection(request)
        let protocolValue = try ExtendedClientConfiguratorSupport.preferredProtocol(for: selected)
        let plan = mutationPlan(
            request,
            selected: selected,
            protocolValue: protocolValue
        )
        return try coordinator.withValidatedPlan(plan: plan) { state, mutations in
            let credential = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.credentialTargetID,
                in: mutations
            )
            let helper = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.helperTargetID,
                in: mutations
            )
            let configuration = try ExtendedClientConfiguratorSupport.writtenData(
                for: Self.configurationTargetID,
                in: mutations
            )
            let rendered = try HermesYAMLDocument(data: configuration)
            return ClientConfigurationPreview(
                clientID: descriptor.id,
                selectedModelID: selected.id,
                changes: [
                    ClientFileChangePreview(
                        url: secretURL,
                        role: .credential,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.credentialTargetID,
                            desiredData: credential,
                            permissions: 0o600
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: helperURL,
                        role: .helper,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.helperTargetID,
                            desiredData: helper,
                            permissions: 0o700
                        ),
                        renderedText: nil
                    ),
                    ClientFileChangePreview(
                        url: configurationURL,
                        role: .configuration,
                        action: ExtendedClientConfiguratorSupport.previewAction(
                            in: state,
                            targetID: Self.configurationTargetID,
                            desiredData: configuration,
                            permissions: 0o600
                        ),
                        renderedText: try rendered.redactedText()
                    ),
                ]
            )
        }
    }

    func apply(_ request: ClientApplyRequest) throws -> ClientConfigurationResult {
        let selected = try validatedSelection(request)
        let protocolValue = try ExtendedClientConfiguratorSupport.preferredProtocol(for: selected)
        let expectedModelIDs = orderedModels(
            request,
            selected: selected,
            protocolValue: protocolValue
        ).map(\.id)
        let expectedCredential = Data(request.apiKey.utf8)
        let expectedHelper = ExtendedClientConfiguratorSupport.helperData(secretURL: secretURL)
        let plan = mutationPlan(
            request,
            selected: selected,
            protocolValue: protocolValue
        )
        let result = try coordinator.apply(plan: plan) { state in
            try self.validateInstalled(
                state,
                expectedModelID: selected.id,
                expectedModelIDs: expectedModelIDs,
                expectedProtocol: protocolValue,
                expectedCredential: expectedCredential,
                expectedHelper: expectedHelper
            )
        }
        return mappedResult(result, modelID: selected.id, restored: false)
    }

    func inspect() throws -> ClientConfigurationStatus {
        let backupURL = try coordinator.latestBackupURL()
        return try coordinator.withSnapshot { state in
            do {
                let document = try HermesYAMLDocument(data: state.data(for: Self.configurationTargetID))
                let modelID = try document.scalar(at: ["model", "default"])
                let providerSelection = try document.scalar(at: ["model", "provider"])
                let api = try document.scalar(at: ["providers", Self.providerID, "api"])
                let keyCommand = try document.scalar(at: ["providers", Self.providerID, "key_cmd"])
                let transport = try document.scalar(at: ["providers", Self.providerID, "transport"])
                let providerDefault = try document.scalar(
                    at: ["providers", Self.providerID, "default_model"]
                )
                let configuredModels = try document.directKeys(
                    in: ["providers", Self.providerID, "models"]
                )
                let hasProvider = try document.directKeys(in: ["providers"]).contains(Self.providerID)
                let hasInline = try document.hasKey(
                    at: ["providers", Self.providerID, "api_key"]
                )
                let hasConflictingEnv = try document.hasKey(
                    at: ["providers", Self.providerID, "key_env"]
                )
                let hasExtraHeaders = try document.hasKey(
                    at: ["providers", Self.providerID, "extra_headers"]
                )
                let protocolValue = Self.protocolValue(forTransport: transport)
                let endpointValid = protocolValue.map(ExtendedClientConfiguratorSupport.endpoint(for:)) == api
                let selectionValid = providerSelection == "custom:\(Self.providerID)"
                    && modelID?.isEmpty == false
                    && modelID == providerDefault
                    && modelID.map(configuredModels.contains) == true
                let expectedHelper = ExtendedClientConfiguratorSupport.helperData(secretURL: secretURL)
                let helperConfigured = keyCommand
                    == ExtendedClientConfiguratorSupport.helperCommand(helperURL: helperURL)
                let helperSecure = state.file(Self.helperTargetID)?.exists == true
                    && state.file(Self.helperTargetID)?.permissions == 0o700
                    && state.data(for: Self.helperTargetID) == expectedHelper
                let credentialSecure = state.file(Self.credentialTargetID)?.exists == true
                    && state.file(Self.credentialTargetID)?.permissions == 0o600
                let hasMarker = hasProvider || providerSelection == "custom:\(Self.providerID)"
                let configured = hasMarker
                    && endpointValid
                    && selectionValid
                    && helperConfigured
                    && helperSecure
                    && credentialSecure
                    && !hasInline
                    && !hasConflictingEnv
                    && !hasExtraHeaders

                var issues: [String] = []
                if hasMarker && !endpointValid { issues.append("Hermes YakCool 协议或端点无效") }
                if hasMarker && !selectionValid { issues.append("Hermes 默认模型配置不一致") }
                if hasInline { issues.append("Hermes YakCool provider 含有内联 API Key") }
                if hasConflictingEnv { issues.append("Hermes YakCool provider 仍含 key_env") }
                if hasExtraHeaders { issues.append("Hermes YakCool provider 仍含 extra_headers") }
                if hasMarker && !helperConfigured { issues.append("Hermes 未使用 YConnect key_cmd helper") }
                if helperConfigured && !helperSecure { issues.append("Hermes helper 缺失、内容漂移或权限不是 0700") }
                if helperConfigured && !credentialSecure { issues.append("Hermes 密钥文件缺失或权限不是 0600") }

                let protection: CredentialProtection
                if hasInline || hasExtraHeaders {
                    protection = .unexpectedInline
                } else if helperConfigured {
                    protection = helperSecure && credentialSecure ? .safeReference : .missing
                } else if credentialSecure {
                    protection = .managedFileSecure
                } else {
                    protection = .missing
                }
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: configured ? .configured : (hasMarker ? .drifted : .notConfigured),
                    selectedModelID: modelID,
                    configuredModelIDs: configuredModels,
                    credentialProtection: protection,
                    latestBackupURL: backupURL,
                    issues: issues
                )
            } catch {
                return ClientConfigurationStatus(
                    clientID: descriptor.id,
                    state: .invalid,
                    selectedModelID: nil,
                    configuredModelIDs: [],
                    credentialProtection: .missing,
                    latestBackupURL: backupURL,
                    issues: ["Hermes 配置无法解析"]
                )
            }
        }
    }

    func restoreLatest() throws -> ClientConfigurationResult {
        let result: ConfigurationTransactionResult
        do {
            result = try coordinator.restoreLatest { state in
                if state.file(Self.configurationTargetID)?.exists == true {
                    _ = try HermesYAMLDocument(data: state.data(for: Self.configurationTargetID))
                }
                try ExtendedClientConfiguratorSupport.validateRestoredHelper(
                    in: state,
                    targetID: Self.helperTargetID,
                    secretURL: self.secretURL,
                    clientName: self.descriptor.name
                )
            }
        } catch ConfigurationTransactionError.noBackup {
            throw ClientConfigurationError.noBackup(descriptor.name)
        }
        return mappedResult(result, modelID: nil, restored: true)
    }

    private func validatedSelection(_ request: ClientApplyRequest) throws -> ClientModelOption {
        try ExtendedClientConfiguratorSupport.validateAPIKey(request.apiKey)
        try ExtendedClientConfiguratorSupport.validateModelID(request.selectedModelID)
        guard let selected = compatibleModels(from: request.models).first(where: {
            $0.id == request.selectedModelID
        }) else {
            throw ClientConfigurationError.invalidSelection(
                "所选模型不支持 Hermes 可用的 Responses、Messages 或 Chat Completions 协议"
            )
        }
        try ExtendedClientConfiguratorSupport.validateModelName(selected.name)
        let protocolValue = try ExtendedClientConfiguratorSupport.preferredProtocol(for: selected)
        try ExtendedClientConfiguratorSupport.validateOutputModels(
            orderedModels(request, selected: selected, protocolValue: protocolValue)
        )
        return selected
    }

    private func mutationPlan(
        _ request: ClientApplyRequest,
        selected: ClientModelOption,
        protocolValue: AIProtocol
    ) -> ConfigurationTransactionCoordinator.Plan {
        { state in
            let configuration = try self.desiredConfiguration(
                request,
                selected: selected,
                protocolValue: protocolValue,
                existing: state.data(for: Self.configurationTargetID)
            )
            return [
                .write(targetID: Self.credentialTargetID, data: Data(request.apiKey.utf8)),
                .write(
                    targetID: Self.helperTargetID,
                    data: ExtendedClientConfiguratorSupport.helperData(secretURL: self.secretURL)
                ),
                .write(targetID: Self.configurationTargetID, data: configuration),
            ]
        }
    }

    private func desiredConfiguration(
        _ request: ClientApplyRequest,
        selected: ClientModelOption,
        protocolValue: AIProtocol,
        existing: Data?
    ) throws -> Data {
        var document = try HermesYAMLDocument(data: existing)
        let models = orderedModels(request, selected: selected, protocolValue: protocolValue).map(\.id)
        try document.configureProvider(
            api: ExtendedClientConfiguratorSupport.endpoint(for: protocolValue),
            keyCommand: ExtendedClientConfiguratorSupport.helperCommand(helperURL: helperURL),
            transport: Self.transportName(for: protocolValue),
            defaultModel: selected.id,
            models: models
        )
        let data = document.renderedData()
        guard !ExtendedClientConfiguratorSupport.contains(data, literal: request.apiKey) else {
            throw ClientConfigurationError.invalidConfiguration("Hermes 配置含有不安全的内联凭据")
        }
        return data
    }

    private func orderedModels(
        _ request: ClientApplyRequest,
        selected: ClientModelOption,
        protocolValue: AIProtocol
    ) -> [ClientModelOption] {
        var seen: Set<String> = [selected.id]
        return [selected] + request.models.filter {
            $0.protocols.contains(protocolValue) && seen.insert($0.id).inserted
        }
    }

    private func validateInstalled(
        _ state: ConfigurationTransactionState,
        expectedModelID: String,
        expectedModelIDs: [String],
        expectedProtocol: AIProtocol,
        expectedCredential: Data,
        expectedHelper: Data
    ) throws {
        let document = try HermesYAMLDocument(data: state.data(for: Self.configurationTargetID))
        guard state.data(for: Self.credentialTargetID) == expectedCredential,
              state.file(Self.credentialTargetID)?.permissions == 0o600,
              state.data(for: Self.helperTargetID) == expectedHelper,
              state.file(Self.helperTargetID)?.permissions == 0o700,
              state.file(Self.configurationTargetID)?.permissions == 0o600,
              try document.scalar(at: ["providers", Self.providerID, "api"])
                == ExtendedClientConfiguratorSupport.endpoint(for: expectedProtocol),
              try document.scalar(at: ["providers", Self.providerID, "key_cmd"])
                == ExtendedClientConfiguratorSupport.helperCommand(helperURL: helperURL),
              try document.scalar(at: ["providers", Self.providerID, "transport"])
                == Self.transportName(for: expectedProtocol),
              try document.scalar(at: ["providers", Self.providerID, "default_model"])
                == expectedModelID,
              Set(try document.directKeys(in: ["providers", Self.providerID, "models"]))
                == Set(expectedModelIDs),
              try document.scalar(at: ["model", "default"]) == expectedModelID,
              try document.scalar(at: ["model", "provider"]) == "custom:\(Self.providerID)",
              try !document.hasKey(at: ["providers", Self.providerID, "api_key"]),
              try !document.hasKey(at: ["providers", Self.providerID, "key_env"]),
              try !document.hasKey(at: ["providers", Self.providerID, "extra_headers"]) else {
            throw ClientConfigurationError.invalidConfiguration("Hermes 写后校验失败")
        }
    }

    private func mappedResult(
        _ result: ConfigurationTransactionResult,
        modelID: String?,
        restored: Bool
    ) -> ClientConfigurationResult {
        let urls = [
            Self.credentialTargetID: secretURL,
            Self.helperTargetID: helperURL,
            Self.configurationTargetID: configurationURL,
        ]
        let action = ExtendedClientConfiguratorSupport.clientAction(result.action)
        let message: String
        if restored {
            message = action == .unchanged
                ? "Hermes 配置已是最近备份状态"
                : "已恢复最近一次 Hermes 配置备份"
        } else {
            message = action == .unchanged
                ? "Hermes 已在使用所选 YakCool 模型"
                : "已将 Hermes 切换到 YakCool / \(modelID ?? "")"
        }
        return ClientConfigurationResult(
            action: action,
            clientID: descriptor.id,
            changedTargets: result.changedTargetIDs.compactMap { urls[$0] },
            backupURL: result.backupURL,
            modelID: modelID,
            message: message
        )
    }

    private static func transportName(for protocolValue: AIProtocol) -> String {
        switch protocolValue {
        case .responses: return "codex_responses"
        case .anthropicMessages: return "anthropic_messages"
        default: return "chat_completions"
        }
    }

    private static func protocolValue(forTransport value: String?) -> AIProtocol? {
        switch value {
        case "codex_responses": return .responses
        case "anthropic_messages": return .anthropicMessages
        case "chat_completions": return .chatCompletions
        default: return nil
        }
    }
}
