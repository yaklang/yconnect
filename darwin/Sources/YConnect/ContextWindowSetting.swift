import Foundation

enum ContextWindowSetting {
    static let supportedRange = 1_024...10_000_000

    static func parse(_ text: String) throws -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let tokens = Int(value), supportedRange.contains(tokens) else {
            throw ClientConfigurationError.invalidSelection("上下文长度请输入 1,024–10,000,000 之间的整数 tokens，或留空使用客户端默认值")
        }
        return tokens
    }

    static func validate(_ tokens: Int?) throws {
        if let tokens, !supportedRange.contains(tokens) {
            throw ClientConfigurationError.invalidSelection("上下文长度必须在 1,024–10,000,000 tokens 之间")
        }
    }
}
