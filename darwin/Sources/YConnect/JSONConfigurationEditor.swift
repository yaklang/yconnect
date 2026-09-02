import Foundation

enum JSONConfigurationEditor {
    static func rootObject(from data: Data?, label: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        let cleaned = try normalizedJSONC(data, label: label)
        guard !String(decoding: cleaned, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        do {
            let object = try JSONSerialization.jsonObject(with: cleaned)
            guard let root = object as? [String: Any] else {
                throw ClientConfigurationError.invalidConfiguration("\(label) 的顶层必须是 JSON 对象")
            }
            return root
        } catch let error as ClientConfigurationError {
            throw error
        } catch {
            throw ClientConfigurationError.invalidConfiguration(
                "无法解析 \(label)：\(error.localizedDescription)"
            )
        }
    }

    static func serialized(_ root: [String: Any], label: String) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ClientConfigurationError.invalidConfiguration("\(label) 包含无法序列化的值")
        }
        do {
            var data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            return data
        } catch {
            throw ClientConfigurationError.invalidConfiguration(
                "无法生成 \(label)：\(error.localizedDescription)"
            )
        }
    }

    static func semanticallyEqual(_ lhs: Data?, _ rhs: Data, label: String) throws -> Bool {
        guard let lhs else { return false }
        let left = try rootObject(from: lhs, label: label)
        let right = try rootObject(from: rhs, label: label)
        return NSDictionary(dictionary: left).isEqual(to: right)
    }

    /// Removes JavaScript comments and trailing commas while preserving any
    /// comment-like bytes inside JSON strings.
    private static func normalizedJSONC(_ input: Data, label: String) throws -> Data {
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
                } else { commentFree.append(0x20) }
                index += 1
                continue
            }
            if inBlockComment {
                if byte == 0x2A, next == 0x2F {
                    commentFree.append(contentsOf: [0x20, 0x20])
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
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                index += 1
                continue
            }
            if byte == 0x22 {
                inString = true
                commentFree.append(byte)
                index += 1
            } else if byte == 0x2F, next == 0x2F {
                inLineComment = true
                commentFree.append(contentsOf: [0x20, 0x20])
                index += 2
            } else if byte == 0x2F, next == 0x2A {
                inBlockComment = true
                commentFree.append(contentsOf: [0x20, 0x20])
                index += 2
            } else {
                commentFree.append(byte)
                index += 1
            }
        }
        guard !inBlockComment else {
            throw ClientConfigurationError.invalidConfiguration("\(label) 包含未结束的块注释")
        }
        guard !inString else {
            throw ClientConfigurationError.invalidConfiguration("\(label) 包含未结束的字符串")
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
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
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
                while lookahead < commentFree.count, isWhitespace(commentFree[lookahead]) { lookahead += 1 }
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

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

enum ClientCredentialCommand {
    /// Pi and Claude Code execute a shell command. Single-quote the managed
    /// path so spaces and shell metacharacters in a home directory are inert.
    static func shellReadCommand(for url: URL) -> String {
        "!" + shellReadCommandWithoutSentinel(for: url)
    }

    static func shellReadCommandWithoutSentinel(for url: URL) -> String {
        "/bin/cat \(shellQuote(url.path))"
    }

    static func executableAndArguments(for url: URL) -> (String, [String]) {
        ("/bin/cat", [url.path])
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
