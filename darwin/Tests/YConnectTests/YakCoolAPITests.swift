import Foundation
import XCTest
@testable import YConnect

final class YakCoolAPITests: XCTestCase {
    private let origin = URL(string: "https://unit-test.yakcool.com")!

    func testNormalizedAPIKeyTrimsOnlySurroundingWhitespace() throws {
        XCTAssertEqual(
            try YakCoolAPI.normalizedAPIKey("  \n\tfake-yconnect-key_123.abc\r  "),
            "fake-yconnect-key_123.abc"
        )
        XCTAssertEqual(
            try YakCoolAPI.normalizedAPIKey(String(repeating: "k", count: 512)),
            String(repeating: "k", count: 512)
        )
    }

    func testNormalizedAPIKeyRejectsEmptyInternalWhitespaceControlCharactersAndOversizeValues() {
        assertInvalidAPIKey("")
        assertInvalidAPIKey("  \n\t ")
        assertInvalidAPIKey("fake key")
        assertInvalidAPIKey("fake\nkey")
        assertInvalidAPIKey("fake\u{0000}key")
        assertInvalidAPIKey(String(repeating: "k", count: 513))
    }

    func testCookieRequestSendsCookieButNeverAuthorization() async throws {
        let transport = MockHTTPTransport { request in
            let data = Data(#"{"user":{"id":7,"public_uuid":"fixture-user","display_name":"Fixture User","avatar_url":"","is_enterprise":false,"enterprise_name":null},"staff_session":false}"#.utf8)
            return (data, TestFixture.httpResponse(for: request, status: 200))
        }
        let api = YakCoolAPI(origin: origin, transport: transport)

        let response = try await api.verifyWebCookies([try TestFixture.cookie()])

        XCTAssertEqual(response.user.id, 7)
        XCTAssertEqual(response.user.displayName, "Fixture User")
        XCTAssertEqual(response.staffSession, false)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://unit-test.yakcool.com/api/auth/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "yakcool_user_session=fake-session-token-for-tests")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAPIKeyRequestSendsAuthorizationButNeverCookieAndDecodesResponse() async throws {
        let transport = MockHTTPTransport { request in
            let data = Data(#"{"schema_version":1,"key":{"label":"Fixture Key","last4":"TEST","status":"active"},"quota":{"mode":"account","follows_account":true,"approximate":true,"step_percent":10,"used_percent_approx":20,"remaining_percent_approx":80,"currency":"CNY","limit_rmb":"10.00","used_rmb":"2.00","remaining_rmb":"8.00","exhausted":false,"display":"80% remaining"},"queried_at":"2026-09-03T00:00:00Z"}"#.utf8)
            return (data, TestFixture.httpResponse(for: request, status: 200))
        }
        let api = YakCoolAPI(origin: origin, transport: transport)

        let response = try await api.keyInfo(apiKey: " \n fake-api-key-for-tests \t")

        XCTAssertEqual(response.schemaVersion, 1)
        XCTAssertEqual(response.key.label, "Fixture Key")
        XCTAssertEqual(response.quota.remainingPercentApprox, 80)
        XCTAssertEqual(response.queriedAt, "2026-09-03T00:00:00Z")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://unit-test.yakcool.com/api/key/info")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-api-key-for-tests")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testPublicHealthRequestSendsNoCredentialHeaders() async throws {
        let transport = MockHTTPTransport { request in
            (Data(#"{"status":"ok"}"#.utf8), TestFixture.httpResponse(for: request, status: 200))
        }
        let api = YakCoolAPI(origin: origin, transport: transport)

        let response = try await api.health()

        XCTAssertEqual(response.status, "ok")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://unit-test.yakcool.com/api/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testStructuredServerErrorIsPreserved() async {
        let transport = MockHTTPTransport { request in
            let data = Data(#"{"error":"fixture_unauthorized","message":"The fake credential was rejected"}"#.utf8)
            return (data, TestFixture.httpResponse(for: request, status: 401))
        }
        let api = YakCoolAPI(origin: origin, transport: transport)

        do {
            _ = try await api.keyInfo(apiKey: "fake-rejected-key")
            XCTFail("Expected a server error")
        } catch {
            XCTAssertEqual(
                error as? YConnectError,
                .server(
                    status: 401,
                    code: "fixture_unauthorized",
                    message: "The fake credential was rejected"
                )
            )
        }
    }

    func testNonHTTPResponseIsRejected() async {
        let transport = MockHTTPTransport { request in
            let response = URLResponse(
                url: request.url!,
                mimeType: "application/json",
                expectedContentLength: 0,
                textEncodingName: "utf-8"
            )
            return (Data(), response)
        }
        let api = YakCoolAPI(origin: origin, transport: transport)

        do {
            _ = try await api.health()
            XCTFail("Expected an invalid response error")
        } catch {
            XCTAssertEqual(error as? YConnectError, .invalidResponse)
        }
    }

    func testTransportErrorIsMappedWithoutLeakingCredential() async {
        struct Offline: LocalizedError {
            var errorDescription: String? { "fixture transport is offline" }
        }
        let transport = MockHTTPTransport { _ in throw Offline() }
        let api = YakCoolAPI(origin: origin, transport: transport)

        do {
            _ = try await api.keyInfo(apiKey: "fake-key-must-not-appear-in-error")
            XCTFail("Expected a transport error")
        } catch {
            guard case .transport(let message) = error as? YConnectError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "网络请求失败：fixture transport is offline")
            XCTAssertFalse(message.contains("fake-key-must-not-appear-in-error"))
        }
    }

    func testMalformedSuccessPayloadIsReportedAsInvalidResponse() async {
        let transport = MockHTTPTransport { request in
            (Data(#"{"unexpected":true}"#.utf8), TestFixture.httpResponse(for: request, status: 200))
        }
        let api = YakCoolAPI(origin: origin, transport: transport)

        do {
            _ = try await api.health()
            XCTFail("Expected an invalid response error")
        } catch {
            XCTAssertEqual(error as? YConnectError, .invalidResponse)
        }
    }

    private func assertInvalidAPIKey(
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try YakCoolAPI.normalizedAPIKey(value), file: file, line: line) { error in
            XCTAssertEqual(
                error as? YConnectError,
                .invalidCredential("请输入有效的 YakCool API Key"),
                file: file,
                line: line
            )
        }
    }
}
