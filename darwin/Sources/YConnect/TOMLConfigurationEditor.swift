import Foundation

enum TOMLConfigurationEditorError: LocalizedError, Equatable {
    case invalidUTF8
    case invalidKey(String)
    case invalidTableName(String)
    case duplicateEntry(String)
    case conflictingAncestorAssignment(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "TOML 配置不是有效的 UTF-8 文本"
        case .invalidKey(let key):
            return "TOML key 无效：\(key)"
        case .invalidTableName(let table):
            return "TOML table 名称无效：\(table)"
        case .duplicateEntry(let key):
            return "TOML table 中包含重复 key：\(key)"
        case .conflictingAncestorAssignment(let key):
            return "TOML 祖先 key 无法安全局部编辑：\(key)"
        }
    }
}

enum TOMLConfigurationValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case stringArray([String])

    fileprivate var rendered: String {
        switch self {
        case .string(let value):
            return TOMLConfigurationEditor.quoted(value)
        case .integer(let value):
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        case .stringArray(let values):
            return "[\(values.map(TOMLConfigurationEditor.quoted).joined(separator: ", "))]"
        }
    }
}

struct TOMLConfigurationEntry: Equatable, Sendable {
    let key: String
    let value: TOMLConfigurationValue

    init(_ key: String, _ value: TOMLConfigurationValue) {
        self.key = key
        self.value = value
    }
}

/// A deliberately narrow, lossless TOML editor.
///
/// It does not parse and serialize the whole document. Instead, it indexes only
/// table headers and assignments, then replaces the exact source ranges owned by
/// the caller. Untouched bytes (including comments, unknown tables, whitespace,
/// mixed formatting, and line endings) remain untouched.
struct TOMLConfigurationEditor {
    private struct SourceLine {
        var content: String
        var terminator: String
    }

    private enum Section: Equatable {
        case root
        case table([String])
        case arrayTable([String])
    }

    private struct TableHeader {
        let path: [String]
        let isArray: Bool
        let line: Int
    }

    private struct Assignment {
        let keyPath: [String]
        let section: Section
        let lines: Range<Int>
        let indentation: String
        let inlineComment: String
    }

    private struct SyntaxIndex {
        let tables: [TableHeader]
        let assignments: [Assignment]
    }

    private enum StringMode {
        case none
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    private var lines: [SourceLine]
    private let insertionNewline: String
    private let hasByteOrderMark: Bool

    init(data: Data) throws {
        let hasBOM = data.starts(with: Self.byteOrderMark)
        let payload = hasBOM ? Data(data.dropFirst(Self.byteOrderMark.count)) : data
        guard let text = String(data: payload, encoding: .utf8) else {
            throw TOMLConfigurationEditorError.invalidUTF8
        }

        let sourceLines = Self.splitLines(text)
        self.lines = sourceLines
        self.insertionNewline = sourceLines.lazy
            .map(\ .terminator)
            .first(where: { !$0.isEmpty }) ?? "\n"
        self.hasByteOrderMark = hasBOM
    }

    init() {
        self.lines = []
        self.insertionNewline = "\n"
        self.hasByteOrderMark = false
    }

    /// Upserts a scalar root assignment and removes any duplicate assignment of
    /// that exact root key. Dotted keys with the same prefix are not touched.
    mutating func upsertTopLevel(
        key: String,
        value: TOMLConfigurationValue
    ) throws {
        try Self.validateSingleKey(key)
        try upsert(key: key, value: value, in: .root)
    }

    /// Upserts a key in an exact standard table. Array tables with the same path
    /// are separate TOML constructs and are never selected.
    mutating func upsert(
        key: String,
        value: TOMLConfigurationValue,
        inTable tableName: String
    ) throws {
        try Self.validateSingleKey(key)
        let tablePath = try Self.targetTablePath(tableName)
        try upsert(key: key, value: value, in: .table(tablePath))
    }

    /// Replaces all standard-table occurrences of `tableName` with one managed
    /// block. Exact child tables and array tables are preserved. Accepting typed
    /// values keeps API keys, model names, and command arguments from escaping
    /// into TOML syntax.
    mutating func replaceManagedTable(
        named tableName: String,
        entries: [TOMLConfigurationEntry]
    ) throws {
        let path = try Self.targetTablePath(tableName)
        var seen: Set<String> = []
        for entry in entries {
            try Self.validateSingleKey(entry.key)
            guard seen.insert(entry.key).inserted else {
                throw TOMLConfigurationEditorError.duplicateEntry(entry.key)
            }
        }

        let block = [Self.renderedTableHeader(path)] + entries.map {
            Self.renderedAssignment(key: $0.key, value: $0.value)
        }
        let ranges = exactTableRanges(path: path)

        guard let first = ranges.first else {
            appendTableBlock(block)
            return
        }

        // Later ranges cannot affect the first range's offsets, so remove them
        // first and then replace the first occurrence in place.
        for range in ranges.dropFirst().reversed() {
            lines.removeSubrange(range)
        }
        replaceLines(first, with: block)
    }

    /// Removes only the exact standard table. Prefix-related tables, child
    /// tables, and `[[array tables]]` remain byte-for-byte intact.
    mutating func removeManagedTable(named tableName: String) throws {
        let path = try Self.targetTablePath(tableName)
        for range in exactTableRanges(path: path).reversed() {
            lines.removeSubrange(range)
        }
    }

    /// Removes one complete managed namespace by TOML path components.
    ///
    /// This includes the target table, descendant standard/array tables, and
    /// dotted assignments that resolve to the same subtree. Prefix neighbours
    /// remain untouched. An assignment that defines a strict ancestor (for
    /// example `model = { yakcool = ... }` for `model.yakcool`) cannot be
    /// edited without parsing and reserializing user-owned inline data, so the
    /// operation rejects it before changing any bytes.
    mutating func removeManagedSubtree(named tableName: String) throws {
        let path = try Self.targetTablePath(tableName)
        let syntax = syntaxIndex()
        var removals: [Range<Int>] = []

        for (offset, header) in syntax.tables.enumerated()
        where Self.path(path, isPrefixOf: header.path) {
            let start = header.line > 0 &&
                lines[header.line - 1].content.trimmingCharacters(in: .whitespaces).isEmpty
                ? header.line - 1
                : header.line
            var end = offset + 1 < syntax.tables.count
                ? syntax.tables[offset + 1].line
                : lines.count
            while end > header.line + 1 {
                let trailing = lines[end - 1].content.trimmingCharacters(in: .whitespaces)
                guard trailing.isEmpty || trailing.hasPrefix("#") else { break }
                end -= 1
            }
            removals.append(start..<max(header.line + 1, end))
        }

        for assignment in syntax.assignments {
            let fullPath = Self.sectionPath(assignment.section) + assignment.keyPath
            if Self.path(fullPath, isStrictPrefixOf: path) {
                throw TOMLConfigurationEditorError.conflictingAncestorAssignment(
                    fullPath.joined(separator: ".")
                )
            }
            if Self.path(path, isPrefixOf: fullPath) {
                removals.append(assignment.lines)
            }
        }

        for range in Self.mergedRanges(removals).reversed() {
            lines.removeSubrange(range)
        }
    }

    func renderedData() -> Data {
        var data = Data()
        if hasByteOrderMark {
            data.append(contentsOf: Self.byteOrderMark)
        }
        for line in lines {
            data.append(contentsOf: line.content.utf8)
            data.append(contentsOf: line.terminator.utf8)
        }
        return data
    }

    private mutating func upsert(
        key: String,
        value: TOMLConfigurationValue,
        in section: Section
    ) throws {
        let syntax = syntaxIndex()
        let matches = syntax.assignments.filter {
            $0.section == section && $0.keyPath == [key]
        }

        if let first = matches.first {
            for duplicate in matches.dropFirst().reversed() {
                lines.removeSubrange(duplicate.lines)
            }
            let replacement = Self.renderedAssignment(
                key: key,
                value: value,
                indentation: first.indentation,
                inlineComment: first.inlineComment
            )
            replaceLines(first.lines, with: [replacement])
            return
        }

        let assignment = Self.renderedAssignment(key: key, value: value)
        switch section {
        case .root:
            let firstTable = syntax.tables.first?.line ?? lines.count
            let insertion = precedingBlankLineBoundary(before: firstTable)
            insertLines([assignment], at: insertion)

        case .table(let path):
            if let header = syntax.tables.first(where: { !$0.isArray && $0.path == path }) {
                let nextHeader = syntax.tables.first(where: { $0.line > header.line })?.line ?? lines.count
                let insertion = precedingBlankLineBoundary(before: nextHeader, lowerBound: header.line + 1)
                insertLines([assignment], at: insertion)
            } else {
                appendTableBlock([Self.renderedTableHeader(path), assignment])
            }

        case .arrayTable:
            // No public operation targets an array table.
            assertionFailure("Array tables are not editable through this API")
        }
    }

    private func syntaxIndex() -> SyntaxIndex {
        var tables: [TableHeader] = []
        var assignments: [Assignment] = []
        var section = Section.root
        var lineIndex = 0

        while lineIndex < lines.count {
            let text = lines[lineIndex].content
            if let header = Self.parseTableHeader(text, line: lineIndex) {
                tables.append(header)
                section = header.isArray ? .arrayTable(header.path) : .table(header.path)
                lineIndex += 1
                continue
            }

            if let start = Self.parseAssignmentStart(text) {
                let end = Self.assignmentEnd(
                    in: lines,
                    startingAt: lineIndex,
                    valueOffset: start.valueOffset
                )
                assignments.append(Assignment(
                    keyPath: start.keyPath,
                    section: section,
                    lines: lineIndex..<end,
                    indentation: start.indentation,
                    inlineComment: start.inlineComment
                ))
                lineIndex = end
                continue
            }

            lineIndex += 1
        }

        return SyntaxIndex(tables: tables, assignments: assignments)
    }

    private func exactTableRanges(path: [String]) -> [Range<Int>] {
        let syntax = syntaxIndex()
        var result: [Range<Int>] = []

        for (offset, header) in syntax.tables.enumerated()
        where !header.isArray && header.path == path {
            var end = offset + 1 < syntax.tables.count
                ? syntax.tables[offset + 1].line
                : lines.count

            // Separator blank lines are not part of the managed block. Keeping
            // them prevents an exact-table replacement from reformatting its
            // neighbours.
            while end > header.line + 1,
                  lines[end - 1].content.trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
            }
            result.append(header.line..<max(header.line + 1, end))
        }
        return result
    }

    private static func sectionPath(_ section: Section) -> [String] {
        switch section {
        case .root:
            return []
        case .table(let path), .arrayTable(let path):
            return path
        }
    }

    private static func path(_ prefix: [String], isPrefixOf path: [String]) -> Bool {
        path.count >= prefix.count && path.prefix(prefix.count).elementsEqual(prefix)
    }

    private static func path(_ prefix: [String], isStrictPrefixOf path: [String]) -> Bool {
        path.count > prefix.count && Self.path(prefix, isPrefixOf: path)
    }

    private static func mergedRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        var result: [Range<Int>] = []
        for range in sorted {
            guard let last = result.last, range.lowerBound <= last.upperBound else {
                result.append(range)
                continue
            }
            result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        }
        return result
    }

    private func precedingBlankLineBoundary(before requested: Int, lowerBound: Int = 0) -> Int {
        var index = requested
        while index > lowerBound,
              lines[index - 1].content.trimmingCharacters(in: .whitespaces).isEmpty {
            index -= 1
        }
        return index
    }

    private mutating func appendTableBlock(_ contents: [String]) {
        guard !lines.isEmpty else {
            insertLines(contents, at: 0)
            return
        }

        var appended = contents
        if !lines[lines.count - 1].content.trimmingCharacters(in: .whitespaces).isEmpty {
            appended.insert("", at: 0)
        }
        insertLines(appended, at: lines.count)
    }

    private mutating func insertLines(_ contents: [String], at requestedIndex: Int) {
        guard !contents.isEmpty else { return }
        let index = max(0, min(requestedIndex, lines.count))

        if index < lines.count {
            let inserted = contents.map { SourceLine(content: $0, terminator: insertionNewline) }
            lines.insert(contentsOf: inserted, at: index)
            return
        }

        let hadExistingLines = !lines.isEmpty
        let preservedTerminalNewline = lines.last?.terminator.isEmpty == false
        if hadExistingLines, lines[lines.count - 1].terminator.isEmpty {
            lines[lines.count - 1].terminator = insertionNewline
        }

        for (offset, content) in contents.enumerated() {
            let isLast = offset == contents.count - 1
            let terminator: String
            if !hadExistingLines {
                terminator = insertionNewline
            } else if isLast && !preservedTerminalNewline {
                terminator = ""
            } else {
                terminator = insertionNewline
            }
            lines.append(SourceLine(content: content, terminator: terminator))
        }
    }

    private mutating func replaceLines(_ range: Range<Int>, with contents: [String]) {
        guard !contents.isEmpty else {
            lines.removeSubrange(range)
            return
        }
        let finalTerminator = range.isEmpty ? insertionNewline : lines[range.upperBound - 1].terminator
        let replacement = contents.enumerated().map { offset, content in
            SourceLine(
                content: content,
                terminator: offset == contents.count - 1 ? finalTerminator : insertionNewline
            )
        }
        lines.replaceSubrange(range, with: replacement)
    }

    private static func splitLines(_ text: String) -> [SourceLine] {
        guard !text.isEmpty else { return [] }
        // Swift treats CRLF as one extended grapheme cluster, so Character-based
        // iteration cannot reliably distinguish `\r\n` from ordinary content.
        // The input has already passed UTF-8 validation; split on ASCII newline
        // bytes and decode only the resulting valid UTF-8 boundaries.
        let bytes = Array(text.utf8)
        var result: [SourceLine] = []
        var start = 0
        var cursor = 0

        while cursor < bytes.count {
            if bytes[cursor] == 0x0A {
                result.append(SourceLine(
                    content: String(decoding: bytes[start..<cursor], as: UTF8.self),
                    terminator: "\n"
                ))
                cursor += 1
                start = cursor
                continue
            }
            if bytes[cursor] == 0x0D {
                if cursor + 1 < bytes.count, bytes[cursor + 1] == 0x0A {
                    result.append(SourceLine(
                        content: String(decoding: bytes[start..<cursor], as: UTF8.self),
                        terminator: "\r\n"
                    ))
                    cursor += 2
                } else {
                    result.append(SourceLine(
                        content: String(decoding: bytes[start..<cursor], as: UTF8.self),
                        terminator: "\r"
                    ))
                    cursor += 1
                }
                start = cursor
                continue
            }
            cursor += 1
        }

        if start < bytes.count {
            result.append(SourceLine(
                content: String(decoding: bytes[start..<bytes.count], as: UTF8.self),
                terminator: ""
            ))
        }
        return result
    }

    private static func parseTableHeader(_ line: String, line lineNumber: Int) -> TableHeader? {
        let code: String
        if let commentOffset = commentOffset(in: line, startingAt: 0) {
            code = String(Array(line).prefix(commentOffset))
        } else {
            code = line
        }
        let trimmed = code.trimmingCharacters(in: .whitespaces)

        let isArray: Bool
        let interior: String
        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]"), trimmed.count >= 4 {
            isArray = true
            interior = String(trimmed.dropFirst(2).dropLast(2))
        } else if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
            isArray = false
            interior = String(trimmed.dropFirst().dropLast())
        } else {
            return nil
        }

        guard let path = parseDottedKey(interior), !path.isEmpty else { return nil }
        return TableHeader(path: path, isArray: isArray, line: lineNumber)
    }

    private struct AssignmentStart {
        let keyPath: [String]
        let valueOffset: Int
        let indentation: String
        let inlineComment: String
    }

    private static func parseAssignmentStart(_ line: String) -> AssignmentStart? {
        let characters = Array(line)
        var mode = StringMode.none
        var escaped = false
        var equalsOffset: Int?

        for offset in characters.indices {
            let character = characters[offset]
            switch mode {
            case .none:
                if character == "#" { return nil }
                if character == "\"" { mode = .basic }
                else if character == "'" { mode = .literal }
                else if character == "=" {
                    equalsOffset = offset
                    break
                }
            case .basic:
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { mode = .none }
            case .literal:
                if character == "'" { mode = .none }
            case .multilineBasic, .multilineLiteral:
                break
            }
            if equalsOffset != nil { break }
        }

        guard let equalsOffset else { return nil }
        let keyText = String(characters.prefix(equalsOffset))
            .trimmingCharacters(in: .whitespaces)
        guard let keyPath = parseDottedKey(keyText), !keyPath.isEmpty else { return nil }

        var indentationEnd = 0
        while indentationEnd < characters.count,
              characters[indentationEnd] == " " || characters[indentationEnd] == "\t" {
            indentationEnd += 1
        }

        let valueOffset = equalsOffset + 1
        let comment: String
        if let commentStart = commentOffset(in: line, startingAt: valueOffset) {
            var suffixStart = commentStart
            while suffixStart > valueOffset,
                  characters[suffixStart - 1] == " " || characters[suffixStart - 1] == "\t" {
                suffixStart -= 1
            }
            comment = String(characters.suffix(from: suffixStart))
        } else {
            comment = ""
        }

        return AssignmentStart(
            keyPath: keyPath,
            valueOffset: valueOffset,
            indentation: String(characters.prefix(indentationEnd)),
            inlineComment: comment
        )
    }

    private static func assignmentEnd(
        in lines: [SourceLine],
        startingAt firstLine: Int,
        valueOffset: Int
    ) -> Int {
        var mode = StringMode.none
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
                    if character == "\"", hasRun(of: "\"", count: 3, in: characters, at: offset) {
                        mode = .multilineBasic
                        offset += 3
                        continue
                    }
                    if character == "'", hasRun(of: "'", count: 3, in: characters, at: offset) {
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
                    if character == "\"", hasRun(of: "\"", count: 3, in: characters, at: offset) {
                        let run = runLength(of: "\"", in: characters, at: offset)
                        mode = .none
                        offset += run
                        continue
                    }

                case .multilineLiteral:
                    if character == "'", hasRun(of: "'", count: 3, in: characters, at: offset) {
                        let run = runLength(of: "'", in: characters, at: offset)
                        mode = .none
                        offset += run
                        continue
                    }
                }
                offset += 1
            }

            // Single-line strings cannot legally continue. Treat malformed input
            // conservatively as ending here instead of consuming unrelated tables.
            if mode == .basic || mode == .literal { mode = .none }
            if mode == .none, squareDepth == 0, curlyDepth == 0 {
                return lineNumber + 1
            }
        }
        return lines.count
    }

    private static func commentOffset(in line: String, startingAt requestedOffset: Int) -> Int? {
        let characters = Array(line)
        var mode = StringMode.none
        var offset = max(0, min(requestedOffset, characters.count))

        while offset < characters.count {
            let character = characters[offset]
            switch mode {
            case .none:
                if character == "#" { return offset }
                if character == "\"", hasRun(of: "\"", count: 3, in: characters, at: offset) {
                    mode = .multilineBasic
                    offset += 3
                    continue
                }
                if character == "'", hasRun(of: "'", count: 3, in: characters, at: offset) {
                    mode = .multilineLiteral
                    offset += 3
                    continue
                }
                if character == "\"" { mode = .basic }
                else if character == "'" { mode = .literal }

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
                if character == "\"", hasRun(of: "\"", count: 3, in: characters, at: offset) {
                    mode = .none
                    offset += runLength(of: "\"", in: characters, at: offset)
                    continue
                }

            case .multilineLiteral:
                if character == "'", hasRun(of: "'", count: 3, in: characters, at: offset) {
                    mode = .none
                    offset += runLength(of: "'", in: characters, at: offset)
                    continue
                }
            }
            offset += 1
        }
        return nil
    }

    private static func hasRun(
        of character: Character,
        count: Int,
        in characters: [Character],
        at offset: Int
    ) -> Bool {
        guard count > 0, offset >= 0, offset + count <= characters.count else { return false }
        return characters[offset..<(offset + count)].allSatisfy { $0 == character }
    }

    private static func runLength(
        of character: Character,
        in characters: [Character],
        at offset: Int
    ) -> Int {
        var end = offset
        while end < characters.count, characters[end] == character { end += 1 }
        return end - offset
    }

    private static func targetTablePath(_ tableName: String) throws -> [String] {
        guard let path = parseDottedKey(tableName),
              !path.isEmpty,
              path.allSatisfy({ !$0.isEmpty }) else {
            throw TOMLConfigurationEditorError.invalidTableName(tableName)
        }
        return path
    }

    private static func validateSingleKey(_ key: String) throws {
        guard !key.isEmpty,
              !key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw TOMLConfigurationEditorError.invalidKey(key)
        }
    }

    private static func parseDottedKey(_ text: String) -> [String]? {
        let characters = Array(text)
        var result: [String] = []
        var offset = 0

        func skipWhitespace(_ position: inout Int) {
            while position < characters.count,
                  characters[position] == " " || characters[position] == "\t" {
                position += 1
            }
        }

        skipWhitespace(&offset)
        while offset < characters.count {
            let component: String
            if characters[offset] == "\"" {
                guard let parsed = parseBasicQuotedKey(characters, offset: offset) else { return nil }
                component = parsed.value
                offset = parsed.nextOffset
            } else if characters[offset] == "'" {
                guard let parsed = parseLiteralQuotedKey(characters, offset: offset) else { return nil }
                component = parsed.value
                offset = parsed.nextOffset
            } else {
                let start = offset
                while offset < characters.count, isBareKeyCharacter(characters[offset]) {
                    offset += 1
                }
                guard offset > start else { return nil }
                component = String(characters[start..<offset])
            }

            result.append(component)
            skipWhitespace(&offset)
            guard offset < characters.count else { break }
            guard characters[offset] == "." else { return nil }
            offset += 1
            skipWhitespace(&offset)
            guard offset < characters.count else { return nil }
        }
        return result
    }

    private static func parseBasicQuotedKey(
        _ characters: [Character],
        offset start: Int
    ) -> (value: String, nextOffset: Int)? {
        var result = ""
        var offset = start + 1
        while offset < characters.count {
            let character = characters[offset]
            if character == "\"" { return (result, offset + 1) }
            if character != "\\" {
                result.append(character)
                offset += 1
                continue
            }

            offset += 1
            guard offset < characters.count else { return nil }
            switch characters[offset] {
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "b": result.append("\u{8}")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "f": result.append("\u{C}")
            case "r": result.append("\r")
            case "u", "U":
                let digitCount = characters[offset] == "u" ? 4 : 8
                let firstDigit = offset + 1
                let end = firstDigit + digitCount
                guard end <= characters.count else { return nil }
                let digits = String(characters[firstDigit..<end])
                guard let value = UInt32(digits, radix: 16),
                      let scalar = UnicodeScalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
                offset = end - 1
            default:
                return nil
            }
            offset += 1
        }
        return nil
    }

    private static func parseLiteralQuotedKey(
        _ characters: [Character],
        offset start: Int
    ) -> (value: String, nextOffset: Int)? {
        var offset = start + 1
        let contentStart = offset
        while offset < characters.count {
            if characters[offset] == "'" {
                return (String(characters[contentStart..<offset]), offset + 1)
            }
            offset += 1
        }
        return nil
    }

    private static func isBareKeyCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (value >= 48 && value <= 57)
            || (value >= 65 && value <= 90)
            || (value >= 97 && value <= 122)
            || value == 95
            || value == 45
    }

    private static func renderedAssignment(
        key: String,
        value: TOMLConfigurationValue,
        indentation: String = "",
        inlineComment: String = ""
    ) -> String {
        var rendered = "\(indentation)\(renderedKeyComponent(key)) = \(value.rendered)"
        if !inlineComment.isEmpty {
            if inlineComment.first == " " || inlineComment.first == "\t" {
                rendered += inlineComment
            } else {
                rendered += " \(inlineComment)"
            }
        }
        return rendered
    }

    private static func renderedTableHeader(_ path: [String]) -> String {
        "[\(path.map(renderedKeyComponent).joined(separator: "."))]"
    }

    private static func renderedKeyComponent(_ key: String) -> String {
        guard !key.isEmpty, key.allSatisfy(isBareKeyCharacter) else { return quoted(key) }
        return key
    }

    fileprivate static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
