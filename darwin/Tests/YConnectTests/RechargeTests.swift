import CoreImage
import Foundation
import XCTest
@testable import YConnect

final class RechargeTests: XCTestCase {
    @MainActor
    func testRenderedPaymentQRCodeDecodesToOriginalPayload() throws {
        let payload = "weixin://wxpay/bizpayurl?pr=fixture-no-payment"
        let image = try XCTUnwrap(PaymentQRCode.image(payload))
        let ci = try XCTUnwrap(CIImage(data: XCTUnwrap(image.tiffRepresentation)))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(codes, [payload])
    }
    func testAmountsAreExactCentsAndRejectInvalidInput() throws {
        XCTAssertEqual(try RechargeSession.parseAmount("1.01"), 101)
        XCTAssertEqual(try RechargeSession.parseAmount("10000"), 1_000_000)
        for value in ["", "0.99", "10000.01", "50.001", "1e2", "NaN", "-50", "1,000", "50.", "１２"] {
            XCTAssertThrowsError(try RechargeSession.parseAmount(value), value)
        }
    }

    @MainActor
    func testQRRequiresMatchingOrderAndPaidRequiresVerification() async {
        let api = PaymentFixture()
        var refreshes = 0
        let session = api.session(refresh: { refreshes += 1 })
        await session.create(amountText: "12.34", channel: .wechat)
        XCTAssertTrue(session.canShowQR)
        XCTAssertEqual(api.creates, 1); XCTAssertEqual(api.queries, 1)
        XCTAssertEqual(api.requestedAmount, 1234)
        api.status = "paid"
        await session.query()
        XCTAssertEqual(session.state, .verifying); XCTAssertFalse(session.canShowQR)
        XCTAssertEqual(refreshes, 0)
        api.verification = "verified"
        await session.query()
        XCTAssertEqual(session.state, .paid); XCTAssertTrue(session.balanceRefreshed)
        XCTAssertEqual(refreshes, 1)
        await session.create(amountText: "50", channel: .alipay)
        XCTAssertEqual(api.creates, 1, "Must not accidentally create a second order after payment")
    }

    @MainActor
    func testMismatchedAmountOrOrderNeverShowsQR() async {
        for kind in ["amount", "id", "channel", "verification"] {
            let api = PaymentFixture()
            if kind == "amount" { api.amount = 9900 }
            if kind == "id" { api.responseID = "YC20260906123456WRONG" }
            if kind == "channel" { api.returnedChannel = "alipay" }
            if kind == "verification" { api.verification = "mismatch" }
            let session = api.session()
            await session.create(amountText: "12.34", channel: .wechat)
            XCTAssertEqual(session.state, .mismatch, kind)
            XCTAssertFalse(session.canShowQR, kind)
        }
    }

    @MainActor
    func testReusedOrderIsReconciledBeforeAmountOrChannelChange() async {
        let api = PaymentFixture(); let session = api.session()
        await session.create(amountText: "12.34", channel: .wechat)
        await session.create(amountText: "50", channel: .wechat)
        XCTAssertEqual(session.state, .mismatch); XCTAssertFalse(session.canShowQR)
        api.url = "alipay://fixture-no-payment"
        await session.create(amountText: "12.34", channel: .alipay)
        XCTAssertTrue(session.canShowQR); XCTAssertEqual(session.channel, .alipay)
    }

    @MainActor
    func testExpiryHidesQRButAllowsLatePaymentReconciliation() async {
        var now = Date()
        let api = PaymentFixture(); let session = api.session(clock: { now })
        await session.create(amountText: "12.34", channel: .wechat)
        now.addTimeInterval(121)
        XCTAssertFalse(session.canShowQR); XCTAssertFalse(session.needsPolling)
        await session.query()
        XCTAssertFalse(session.canShowQR, "Polling must not renew a QR")
        api.status = "paid"; api.verification = "verified"
        await session.query()
        XCTAssertEqual(session.state, .paid)
    }

    @MainActor
    func testFailedOrClosedOrdersAndInvalidPayloadsNeverRemainPayable() async {
        for state in ["failed", "closed", "unknown"] {
            let api = PaymentFixture(); let session = api.session()
            await session.create(amountText: "12.34", channel: .wechat)
            api.status = state
            await session.query()
            XCTAssertFalse(session.canShowQR); XCTAssertFalse(session.needsPolling)
        }
        for url in ["", "javascript:alert(1)", "file:///tmp/key", "http://bad/", "weixin://bad\nvalue"] {
            let api = PaymentFixture(); api.url = url
            let session = api.session()
            await session.create(amountText: "12.34", channel: .wechat)
            XCTAssertFalse(session.canShowQR); XCTAssertEqual(session.state, .invalid)
        }
    }

    @MainActor
    func testNetworkRecoveryAndExpiredLogin() async {
        let api = PaymentFixture(); api.failure = YConnectError.transport("offline")
        let session = api.session()
        await session.create(amountText: "12.34", channel: .wechat)
        XCTAssertFalse(session.canShowQR); XCTAssertNotNil(session.errorMessage)
        api.failure = nil
        await session.query()
        XCTAssertTrue(session.canShowQR)
        api.failure = YConnectError.server(status: 401, code: "expired", message: "expired")
        await session.query()
        XCTAssertTrue(session.loginRequired); XCTAssertFalse(session.canShowQR)
        XCTAssertFalse(session.needsPolling)
    }

    @MainActor
    func testAccountSwitchDuringCreateAndDoubleClick() async {
        let api = PaymentFixture(); var current = true
        var gate: CheckedContinuation<Void, Never>?
        api.beforeCreate = { await withCheckedContinuation { gate = $0 } }
        let session = api.session(current: { current })
        let first = Task { await session.create(amountText: "12.34", channel: .wechat) }
        while gate == nil { await Task.yield() }
        await session.create(amountText: "12.34", channel: .wechat)
        XCTAssertEqual(api.creates, 1)
        current = false; gate?.resume(); await first.value
        XCTAssertFalse(session.canShowQR); XCTAssertNil(session.orderNo)
        XCTAssertEqual(api.queries, 0)
    }

    @MainActor
    func testBalanceRefreshCanRetryWithoutRepaying() async {
        let api = PaymentFixture(); var failing = true
        let session = api.session(refresh: { if failing { throw YConnectError.transport("offline") } })
        api.status = "paid"; api.verification = "verified"
        await session.create(amountText: "12.34", channel: .wechat)
        XCTAssertEqual(session.state, .paid); XCTAssertFalse(session.balanceRefreshed)
        failing = false; await session.retryBalanceRefresh()
        XCTAssertTrue(session.balanceRefreshed); XCTAssertEqual(api.creates, 1)
    }

    func testPaymentHTTPBoundaryAndOrderPathValidation() async throws {
        let transport = MockHTTPTransport { request in
            XCTAssertEqual(request.url?.host, "yakcool.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "yakcool_user_session=fake-session-token-for-tests")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
                XCTAssertEqual(body["amount_cents"] as? Int, 1234)
                XCTAssertEqual(body["channel"] as? String, "wechat")
                return (Data(#"{"order_no":"YC20260906123456AB_C-D","code_url":"weixin://fixture","channel":"wechat"}"#.utf8), TestFixture.httpResponse(for: request, status: 201))
            }
            return (Data(#"{"order_no":"YC20260906123456AB_C-D","amount_cents":1234,"status":"pending"}"#.utf8), TestFixture.httpResponse(for: request, status: 200))
        }
        let api = YakCoolAPI(transport: transport); let cookies = [try TestFixture.cookie()]
        _ = try await api.createPayment(amountCents: 1234, channel: .wechat, cookies: cookies)
        _ = try await api.paymentStatus(orderNo: PaymentFixture.id, cookies: cookies)
        for id in ["../user/dashboard", PaymentFixture.id + "?x=1", PaymentFixture.id + "%2f", "YCtest\n"] {
            do { _ = try await api.paymentStatus(orderNo: id, cookies: cookies); XCTFail("Invalid path accepted") } catch { }
        }
        XCTAssertEqual(transport.requests.count, 2)
    }
}

private final class PaymentFixture: RechargeAPI {
    static let id = "YC20260906123456AB_C-D"
    var creates = 0, queries = 0
    var requestedAmount: Int64 = 0, amount: Int64 = 1234
    var responseID = id, status = "pending", verification = "", url = "weixin://fixture-no-payment"
    var returnedChannel: String?
    var failure: Error?
    var beforeCreate: (() async -> Void)?
    func createPayment(amountCents: Int64, channel: PaymentChannel, cookies: [StoredWebCookie]) async throws -> PaymentOrder {
        creates += 1; requestedAmount = amountCents
        await beforeCreate?()
        return PaymentOrder(orderNo: Self.id, codeURL: url, channel: returnedChannel ?? channel.rawValue)
    }
    func paymentStatus(orderNo: String, cookies: [StoredWebCookie]) async throws -> PaymentOrderStatus {
        queries += 1
        if let failure { throw failure }
        return PaymentOrderStatus(orderNo: responseID, amountCents: amount, status: status, verificationStatus: verification)
    }
    @MainActor
    func session(current: @escaping () -> Bool = { true }, clock: @escaping () -> Date = Date.init,
                 refresh: @escaping () async throws -> Void = {}) -> RechargeSession {
        RechargeSession(api: self, cookies: [], accountName: "Test Account", currentAccount: current, clock: clock, refreshBalance: refresh)
    }
}
