import Foundation
import XCTest
@testable import YConnect

final class CredentialRepositoryTests: XCTestCase {
    func testMemoryVaultSavesLoadsAndDeletesAPIKey() throws {
        let vault = MemoryCredentialVault()
        let repository = CredentialRepository(vault: vault)

        XCTAssertNil(try repository.loadAPIKey())
        try repository.saveAPIKey("fake-persisted-api-key")
        XCTAssertEqual(try repository.loadAPIKey(), "fake-persisted-api-key")

        try repository.deleteAPIKey()
        XCTAssertNil(try repository.loadAPIKey())
    }

    func testCookieNameFilteringPersistsOnlyPublicUserSession() throws {
        let vault = MemoryCredentialVault()
        let repository = CredentialRepository(vault: vault)
        let publicSession = try TestFixture.cookie(value: "fake-public-session")
        let staffSession = try TestFixture.cookie(
            name: "yakcool_staff_session",
            value: "fake-staff-session"
        )

        try repository.saveWebCookies([staffSession, publicSession])

        XCTAssertEqual(try repository.loadWebCookies(), [publicSession])
    }

    func testCookieDomainFilteringPersistsOnlyYakCoolDomains() throws {
        let vault = MemoryCredentialVault()
        let repository = CredentialRepository(vault: vault)
        let apex = try TestFixture.cookie(value: "fake-apex-session", domain: "yakcool.com")
        let subdomain = try TestFixture.cookie(value: "fake-subdomain-session", domain: ".account.yakcool.com")
        let lookalike = try TestFixture.cookie(value: "fake-lookalike-session", domain: "notyakcool.com")
        let suffixAttack = try TestFixture.cookie(value: "fake-suffix-session", domain: "yakcool.com.example.invalid")

        try repository.saveWebCookies([lookalike, apex, suffixAttack, subdomain])

        XCTAssertEqual(try repository.loadWebCookies(), [apex])
    }

    func testAllowedDomainRecognitionIsCaseInsensitiveAndRejectsLookalikes() {
        XCTAssertTrue(StoredWebCookie.isAllowedDomain("yakcool.com"))
        XCTAssertTrue(StoredWebCookie.isAllowedDomain(".YAKCOOL.COM"))
        XCTAssertFalse(StoredWebCookie.isAllowedDomain("account.yakcool.com"))
        XCTAssertFalse(StoredWebCookie.isAllowedDomain("notyakcool.com"))
        XCTAssertFalse(StoredWebCookie.isAllowedDomain("yakcool.com.example.invalid"))
        XCTAssertFalse(StoredWebCookie.isAllowedDomain("example.invalid"))
    }

    func testExpiredCookieClearsPreviouslySavedSession() throws {
        let vault = MemoryCredentialVault()
        let repository = CredentialRepository(vault: vault)
        try repository.saveWebCookies([try TestFixture.cookie(value: "fake-current-session")])
        XCTAssertFalse(try repository.loadWebCookies().isEmpty)

        let expired = try TestFixture.cookie(
            value: "fake-expired-session",
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        try repository.saveWebCookies([expired])

        XCTAssertEqual(try repository.loadWebCookies(), [])
        XCTAssertNil(try vault.read(account: CredentialRepository.webCookiesAccount))
    }

    func testCookieRequestSafetyRejectsScopedPathsAndHeaderInjection() throws {
        let scoped = try TestFixture.cookie(value: "fake-scoped-session", path: "/login")
        let injected = try TestFixture.cookie(value: "fake-session; admin=true")
        let valid = try TestFixture.cookie(value: "fake-safe-session")

        XCTAssertFalse(scoped.isSafeForRequest)
        XCTAssertFalse(injected.isSafeForRequest)
        XCTAssertTrue(valid.isSafeForRequest)
    }

    func testDeleteWebCookiesRemovesStoredSession() throws {
        let vault = MemoryCredentialVault()
        let repository = CredentialRepository(vault: vault)
        try repository.saveWebCookies([try TestFixture.cookie()])

        try repository.deleteWebCookies()

        XCTAssertEqual(try repository.loadWebCookies(), [])
        XCTAssertNil(try vault.read(account: CredentialRepository.webCookiesAccount))
    }
}
