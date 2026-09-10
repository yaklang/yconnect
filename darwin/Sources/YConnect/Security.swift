import Foundation
import Security
import LocalAuthentication

protocol CredentialVault {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

protocol KeychainAccessing {
    func read(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainAccess: KeychainAccessing {
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

struct KeychainError: LocalizedError, Equatable {
    enum Operation: String { case read = "读取", write = "写入", update = "更新", delete = "清理" }
    let operation: Operation
    let status: OSStatus

    var errorDescription: String? {
        let detail: String
        switch status {
        case errSecInteractionNotAllowed:
            detail = "钥匙串需要解锁或授权。请解锁登录钥匙串后重新登录。"
        case errSecAuthFailed, errSecUserCanceled:
            detail = "钥匙串授权未完成。请重新登录，并确认系统的访问授权。"
        case errSecNotAvailable:
            detail = "系统钥匙串暂时不可用，请稍后重试。"
        case errSecMissingEntitlement:
            detail = "应用签名或权限不匹配，请重新安装官方签名版本。"
        case errSecParam:
            detail = "凭据存储参数不兼容，请更新客户端并提供此错误码。"
        default:
            detail = "凭据未能完成安全存储操作，请将此错误码提供给支持人员。"
        }
        return "无法\(operation.rawValue) macOS 钥匙串（\(status)）。\(detail)"
    }
}

struct KeychainVault: CredentialVault {
    let service: String
    let access: any KeychainAccessing

    init(service: String = "io.yaklang.yconnect", access: any KeychainAccessing = SystemKeychainAccess()) {
        self.service = service
        self.access = access
    }

    private func query(account: String) -> [String: Any] {
        // Keep the existing file-based login keychain and service/account pair.
        // Data Protection-only attributes require a different store and signing
        // entitlements; adding them here does not provide ThisDeviceOnly protection.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> Data? {
        var request = query(account: account)
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        let (status, data) = access.read(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(operation: .read, status: status) }
        guard let data else { throw KeychainError(operation: .read, status: errSecDecode) }
        return data
    }

    func write(_ data: Data, account: String) throws {
        let base = query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = access.update(base, attributes: attributes)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(operation: .update, status: update) }
        let status = access.add(base.merging(attributes, uniquingKeysWith: { _, new in new }))
        guard status == errSecSuccess else { throw KeychainError(operation: .write, status: status) }
    }

    func delete(account: String) throws {
        let status = access.delete(query(account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: .delete, status: status)
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

/// Security.framework calls are synchronous. This serial queue owns repository
/// access so a system prompt or securityd delay never blocks AppKit's main thread.
final class AsyncCredentialRepository: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.yaklang.yconnect.credentials", qos: .userInitiated)
    private let repository: CredentialRepository

    init(vault: any CredentialVault) { repository = CredentialRepository(vault: vault) }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (CredentialRepository) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try operation(repository)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func loadAPIKey() async throws -> String? { try await perform { try $0.loadAPIKey() } }
    func loadWebCookies() async throws -> [StoredWebCookie] { try await perform { try $0.loadWebCookies() } }
    func saveAPIKey(_ value: String) async throws { try await perform { try $0.saveAPIKey(value) } }
    func saveWebCookies(_ cookies: [StoredWebCookie]) async throws { try await perform { try $0.saveWebCookies(cookies) } }
    func deleteAPIKey() async throws { try await perform { try $0.deleteAPIKey() } }
    func deleteWebCookies() async throws { try await perform { try $0.deleteWebCookies() } }
}
