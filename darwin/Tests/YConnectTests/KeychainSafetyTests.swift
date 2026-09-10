import AppKit
import LocalAuthentication
import Security
import XCTest
@testable import YConnect

final class KeychainSafetyTests: XCTestCase {
    func testQueriesKeepExistingKeychainAndAvoidUnsupportedProtectionAttributes() throws {
        let access = FakeKeychainAccess()
        let vault = KeychainVault(service: "test-service", access: access)
        access.updateStatus = errSecItemNotFound
        try vault.write(Data("test-value".utf8), account: "test-account")
        XCTAssertEqual(access.lastAdd[kSecAttrService as String] as? String, "test-service")
        XCTAssertEqual(access.lastAdd[kSecAttrAccount as String] as? String, "test-account")
        for key in [kSecAttrAccessible, kSecAttrAccessControl, kSecUseDataProtectionKeychain, kSecAttrSynchronizable] {
            XCTAssertNil(access.lastAdd[key as String])
            XCTAssertNil(access.lastUpdate[key as String])
        }
        access.readStatus = errSecItemNotFound
        XCTAssertNil(try vault.read(account: "test-account"))
        let context = try XCTUnwrap(access.lastRead[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
    }

    func testKeychainFailuresHaveActionableErrorsAndDoNotFallBackToPlaintext() throws {
        let access = FakeKeychainAccess()
        let vault = KeychainVault(access: access)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNotAvailable, errSecMissingEntitlement, errSecParam] {
            access.readStatus = status
            XCTAssertThrowsError(try vault.read(account: "test-account")) { error in
                XCTAssertEqual((error as? KeychainError)?.status, status)
                XCTAssertTrue(error.localizedDescription.contains(String(status)))
            }
            access.updateStatus = status
            XCTAssertThrowsError(try vault.write(Data("test".utf8), account: "test-account"))
        }
        XCTAssertTrue(access.lastAdd.isEmpty, "An access failure must not create a second credential elsewhere")
        XCTAssertTrue(AccountLoginStatusText.afterVerificationFailure(KeychainError(operation: .write, status: errSecAuthFailed)).contains("重新加载"))
    }

    @MainActor
    func testSlowKeychainDoesNotBlockMainActor() async throws {
        let started = expectation(description: "credential read started")
        let vault = SlowCredentialVault(started: started)
        let repository = AsyncCredentialRepository(vault: vault)
        let task = Task { try await repository.loadAPIKey() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertFalse(vault.hasReturned, "The main actor must run while the credential queue is waiting")
        vault.resume.signal()
        let value = try await task.value
        XCTAssertEqual(value, "fake-key")
        XCTAssertFalse(vault.ranOnMainThread)
    }

    @MainActor
    func testRestoreFailureKeepsCredentialsAndPresentsError() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = FailingCredentialVault()
        let store = YConnectStore(environment: .preview(at: root), credentialVault: vault,
            clientRegistry: ClientConfigurationRegistry())
        await store.restoreSession()
        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertEqual(store.keychainFailureStatus, errSecInteractionNotAllowed)
        XCTAssertTrue(store.startupWarning?.contains("钥匙串") == true)
        XCTAssertEqual(vault.deletedAccounts.count, 0)
        await store.signOut()
        XCTAssertTrue(store.errorMessage?.contains("未能清理") == true)
        XCTAssertEqual(store.phase, .signedOut)
    }

    @MainActor
    func testDiagnosticRetainsOnlyKeychainErrorCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = StartupDiagnostics(directory: root)
        diagnostics.recordKeychainFailure(status: errSecAuthFailed)
        diagnostics.record(.cleanExit)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let report = try JSONDecoder().decode(StartupDiagnostics.Report.self, from: Data(contentsOf: file))
        XCTAssertEqual(report.keychainStatus, errSecAuthFailed)
        XCTAssertEqual(report.issues, [.keychainUnavailable])
    }

    func testRealKeychainRoundTripWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["YCONNECT_RUN_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt-in isolated Keychain item round trip")
        }
        let repository = AsyncCredentialRepository(vault: KeychainVault(service: "io.yaklang.yconnect.tests.\(UUID().uuidString)"))
        do {
            try await repository.saveAPIKey("fake-key-for-keychain-check-only")
            let value = try await repository.loadAPIKey()
            XCTAssertEqual(value, "fake-key-for-keychain-check-only")
            try await repository.deleteAPIKey()
            let deleted = try await repository.loadAPIKey()
            XCTAssertNil(deleted)
        } catch {
            try? await repository.deleteAPIKey()
            throw error
        }
    }
}

private final class FakeKeychainAccess: KeychainAccessing {
    var readStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var lastRead: [String: Any] = [:]
    var lastUpdate: [String: Any] = [:]
    var lastAdd: [String: Any] = [:]
    func read(_ query: [String: Any]) -> (OSStatus, Data?) { lastRead = query; return (readStatus, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { lastUpdate = attributes; return updateStatus }
    func add(_ attributes: [String: Any]) -> OSStatus { lastAdd = attributes; return errSecSuccess }
    func delete(_ query: [String: Any]) -> OSStatus { errSecSuccess }
}

private final class SlowCredentialVault: CredentialVault, @unchecked Sendable {
    let resume = DispatchSemaphore(value: 0)
    let started: XCTestExpectation
    private let lock = NSLock()
    private var returned = false
    private var onMain = false
    var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    var ranOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    init(started: XCTestExpectation) { self.started = started }
    func read(account: String) throws -> Data? {
        lock.lock(); onMain = Thread.isMainThread; lock.unlock()
        started.fulfill()
        _ = resume.wait(timeout: .now() + 2)
        lock.lock(); returned = true; lock.unlock()
        return Data("fake-key".utf8)
    }
    func write(_ data: Data, account: String) throws {}
    func delete(account: String) throws {}
}

private final class FailingCredentialVault: CredentialVault {
    var deletedAccounts: [String] = []
    func read(account: String) throws -> Data? { throw KeychainError(operation: .read, status: errSecInteractionNotAllowed) }
    func write(_ data: Data, account: String) throws { throw KeychainError(operation: .write, status: errSecAuthFailed) }
    func delete(account: String) throws {
        deletedAccounts.append(account)
        throw KeychainError(operation: .delete, status: errSecInteractionNotAllowed)
    }
}
