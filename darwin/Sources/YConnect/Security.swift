import Foundation
import Security

protocol CredentialVault {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

struct KeychainVault: CredentialVault {
    let service: String

    init(service: String = "io.yaklang.yconnect") {
        self.service = service
    }

    func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw YConnectError.file("无法读取 macOS 钥匙串（\(status)）")
        }
        return data
    }

    func write(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        if update != errSecItemNotFound {
            throw YConnectError.file("无法更新 macOS 钥匙串（\(update)）")
        }
        var insert = base
        attributes.forEach { insert[$0.key] = $0.value }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw YConnectError.file("无法写入 macOS 钥匙串（\(status)）")
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw YConnectError.file("无法清理 macOS 钥匙串（\(status)）")
        }
    }
}

final class MemoryCredentialVault: CredentialVault {
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? { values[account] }
    func write(_ data: Data, account: String) throws { values[account] = data }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

struct CredentialRepository {
    static let apiKeyAccount = "yakcool-business-api-key"
    static let webCookiesAccount = "yakcool-web-session-cookies"

    let vault: CredentialVault
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func loadAPIKey() throws -> String? {
        guard let data = try vault.read(account: Self.apiKeyAccount),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    func saveAPIKey(_ value: String) throws {
        try vault.write(Data(value.utf8), account: Self.apiKeyAccount)
    }

    func deleteAPIKey() throws { try vault.delete(account: Self.apiKeyAccount) }

    func loadWebCookies() throws -> [StoredWebCookie] {
        guard let data = try vault.read(account: Self.webCookiesAccount) else { return [] }
        return try decoder.decode([StoredWebCookie].self, from: data).filter(\.isSafeForRequest)
    }

    func saveWebCookies(_ cookies: [StoredWebCookie]) throws {
        let allowed = cookies.filter(\.isSafeForRequest)
        guard !allowed.isEmpty else {
            try deleteWebCookies()
            return
        }
        try vault.write(try encoder.encode(allowed), account: Self.webCookiesAccount)
    }

    func deleteWebCookies() throws { try vault.delete(account: Self.webCookiesAccount) }
}
