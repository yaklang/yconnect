import Foundation
import XCTest
@testable import YConnect

final class AccountSpendingTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-07T04:00:00Z")!

    private func usage(_ rows: [AccountUsageRow] = [], available: Bool = true, partial: Bool = false,
                       to: String = "2026-09-07", from: String = "2026-09-01") -> AccountUsageResponse {
        AccountUsageResponse(available: available, status: "synced", from: from, to: to, rows: rows, partial: partial)
    }

    func testSumsAllKeysAndModelsInRMBAndComparesToYesterday() {
        let snapshot = AccountSpendingSnapshot(usage: usage([
            AccountUsageRow(date: "2026-09-07", requestCount: 10, estimatedCount: 0, amountRMB: "0.1000000"),
            AccountUsageRow(date: "2026-09-07", requestCount: 5, estimatedCount: 1, amountRMB: "0.2000000"),
            AccountUsageRow(date: "2026-09-06", requestCount: 9, estimatedCount: 0, amountRMB: "0.2500000"),
            AccountUsageRow(date: "2026-09-05", requestCount: 300, estimatedCount: 0, amountRMB: "99.9900000"),
        ]), now: now)
        XCTAssertEqual(snapshot.todayRMB, Decimal(string: "0.3"))
        XCTAssertEqual(snapshot.todayRequests, 15)
        XCTAssertEqual(snapshot.comparisonText, "较昨日全天多 ¥0.05")
        XCTAssertTrue(snapshot.hasEstimates)
    }

    func testBeijingMidnightAndMonthBoundaryDoNotReuseYesterdayAsToday() {
        let midnight = ISO8601DateFormatter().date(from: "2026-08-31T16:00:00Z")!
        XCTAssertEqual(AccountSpendingSnapshot.dayString(midnight), "2026-09-01")
        let response = usage([
            AccountUsageRow(date: "2026-08-31", requestCount: 1, estimatedCount: 0, amountRMB: "2"),
        ], to: "2026-09-01", from: "2026-08-26")
        let snapshot = AccountSpendingSnapshot(usage: response, now: midnight)
        XCTAssertEqual(snapshot.todayRMB, 0)
        XCTAssertEqual(snapshot.yesterdayRMB, 2)
        XCTAssertEqual(snapshot.comparisonText, "较昨日全天少 ¥2.00")
        let stale = AccountSpendingSnapshot(usage: usage(to: "2026-08-31", from: "2026-08-25"), now: midnight)
        XCTAssertNil(stale.todayRMB)
    }

    func testUnavailablePartialMalformedAndOutOfRangeDataNeverLookLikeZeroSpend() {
        for response in [nil, usage(available: false), usage(partial: true), usage(from: "2026-09-07"),
            usage([AccountUsageRow(date: "2026-09-07", requestCount: 1, estimatedCount: 0, amountRMB: "1.2garbage")]),
            usage([AccountUsageRow(date: "2026-09-07", requestCount: -1, estimatedCount: 0, amountRMB: "2")]),
            usage([AccountUsageRow(date: "2026-09-07", requestCount: 1, estimatedCount: 2, amountRMB: "2")]),
        ] {
            let snapshot = AccountSpendingSnapshot(usage: response, now: now)
            XCTAssertNil(snapshot.todayRMB)
            XCTAssertNil(snapshot.todayRequests)
            XCTAssertEqual(RMBAmount.display(snapshot.todayRMB), "—")
        }
        XCTAssertEqual(AccountSpendingSnapshot(usage: usage(), now: now).todayRMB, 0)
        XCTAssertEqual(RMBAmount.display(0), "¥0.00")
        XCTAssertEqual(RMBAmount.display(Decimal(string: "0.0000001")), "<¥0.01")
        XCTAssertNil(RMBAmount.parse("-1"))
        XCTAssertNil(RMBAmount.parse("NaN"))
    }

    func testCumulativeSpendUsesBilledAmountAndWeightedFallback() throws {
        func credit(_ json: String) throws -> CreditSummary { try JSONDecoder().decode(CreditSummary.self, from: Data(json.utf8)) }
        XCTAssertEqual(try credit(#"{"status":"synced","token_used_rmb":"24.3031","token_remaining":5000000000}"#).spentRMB, Decimal(string: "24.3031"))
        XCTAssertEqual(try credit(#"{"status":"synced","token_used":123450000,"weighted_tokens_per_rmb":10000000}"#).spentRMB, Decimal(string: "12.345"))
        XCTAssertNil(try credit(#"{"status":"unavailable","token_used_rmb":"0.00"}"#).spentRMB)
        XCTAssertNil(try credit(#"{"status":"synced","token_used":123,"weighted_tokens_per_rmb":0}"#).spentRMB)
    }

    func testUsageAPIUsesAccountCookieAndSevenDayQuery() async throws {
        let cookie = try TestFixture.cookie()
        let transport = MockHTTPTransport { request in
            XCTAssertEqual(request.url?.path, "/api/user/usage")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "days", value: "7")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "yakcool_user_session=fake-session-token-for-tests")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let data = Data(#"{"available":true,"status":"synced","days":7,"from":"2026-09-01","to":"2026-09-07","rows":[],"summary":{"rmb":"0.0000000"}}"#.utf8)
            return (data, TestFixture.httpResponse(for: request, status: 200))
        }
        let response = try await YakCoolAPI(transport: transport).accountUsage(cookies: [cookie])
        XCTAssertTrue(response.available)
        XCTAssertTrue(response.rows.isEmpty)
    }
}
