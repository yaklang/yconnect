import Foundation

enum PaymentChannel: String, CaseIterable, Identifiable, Codable {
    case wechat, alipay
    var id: String { rawValue }
    var title: String { self == .wechat ? "微信支付" : "支付宝" }
}

struct PaymentOrder: Decodable {
    let orderNo: String
    let codeURL: String
    let channel: String
    enum CodingKeys: String, CodingKey {
        case orderNo = "order_no", codeURL = "code_url", channel
    }
}

struct PaymentOrderStatus: Decodable {
    let orderNo: String
    let amountCents: Int64
    let status: String
    let verificationStatus: String?
    enum CodingKeys: String, CodingKey {
        case orderNo = "order_no", amountCents = "amount_cents", status
        case verificationStatus = "verification_status"
    }
}

protocol RechargeAPI {
    func createPayment(amountCents: Int64, channel: PaymentChannel, cookies: [StoredWebCookie]) async throws -> PaymentOrder
    func paymentStatus(orderNo: String, cookies: [StoredWebCookie]) async throws -> PaymentOrderStatus
}

/// An in-memory checkout bound to one login. Closing its view does not discard an outstanding order.
@MainActor
final class RechargeSession: ObservableObject {
    enum State: String { case new, pending, verifying, paid, failed, closed, mismatch, invalid }
    @Published private(set) var state: State = .new
    @Published private(set) var orderNo: String?
    @Published private(set) var amountCents: Int64 = 0
    @Published private(set) var channel: PaymentChannel = .wechat
    @Published private(set) var codeURL: String?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loginRequired = false
    @Published private(set) var balanceRefreshed = false
    let accountName: String
    private let api: RechargeAPI
    private let cookies: [StoredWebCookie]
    private let currentAccount: () -> Bool
    private let clock: () -> Date
    private let refreshBalance: () async throws -> Void
    private var createdAt = Date.distantPast
    private var returnedAmount: Int64?

    init(api: RechargeAPI, cookies: [StoredWebCookie], accountName: String,
         currentAccount: @escaping () -> Bool, clock: @escaping () -> Date = Date.init,
         refreshBalance: @escaping () async throws -> Void = {}) {
        self.api = api; self.cookies = cookies; self.accountName = accountName
        self.currentAccount = currentAccount; self.clock = clock; self.refreshBalance = refreshBalance
    }

    var isCurrent: Bool { currentAccount() }
    var secondsLeft: Int { max(0, Int(ceil(createdAt.addingTimeInterval(120).timeIntervalSince(clock())))) }
    var canShowQR: Bool { isCurrent && !loginRequired && state == .pending && secondsLeft > 0 && codeURL != nil }
    var needsPolling: Bool { !loginRequired && isCurrent && orderNo != nil && (state == .pending || state == .verifying) && secondsLeft > 0 }
    var amount: String { String(format: "%.2f", Double(amountCents) / 100) }

    nonisolated static func parseAmount(_ text: String) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"\A[0-9]{1,5}(?:\.[0-9]{1,2})?\z"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              decimal >= 1, decimal <= 10_000 else {
            throw YConnectError.unsupported("请输入 ¥1–¥10,000 的金额，最多两位小数")
        }
        return NSDecimalNumber(decimal: decimal * 100).int64Value
    }

    nonisolated static func validateOrderNo(_ value: String) throws -> String {
        guard value.range(of: #"\AYC[A-Z0-9_-]{14,64}\z"#, options: .regularExpression) != nil else {
            throw YConnectError.invalidResponse
        }
        return value
    }

    func create(amountText: String, channel: PaymentChannel) async {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try requireCurrent()
            let cents = try Self.parseAmount(amountText)
            if orderNo != nil {
                // The server may reuse a pending order. Reconcile it before requesting another QR.
                if state == .mismatch, let returnedAmount { amountCents = returnedAmount }
                try await queryCore()
                if state == .paid { await syncBalance(); return }
                guard state != .mismatch && state != .verifying else {
                    throw YConnectError.unsupported("上一笔付款仍需核验，请先查询结果或到官网核对")
                }
            }
            codeURL = nil
            let order = try await api.createPayment(amountCents: cents, channel: channel, cookies: cookies)
            try requireCurrent()
            orderNo = try Self.validateOrderNo(order.orderNo)
            amountCents = cents; self.channel = channel; state = .verifying
            createdAt = clock(); balanceRefreshed = false
            guard order.channel == channel.rawValue else {
                state = .mismatch
                throw YConnectError.unsupported("支付方式与订单不一致，请勿付款")
            }
            guard !order.codeURL.isEmpty, order.codeURL.utf8.count <= 2048,
                  !order.codeURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let url = URL(string: order.codeURL),
                  url.scheme == "https" || (channel == .wechat && url.scheme == "weixin") || (channel == .alipay && url.scheme == "alipay") else {
                state = .invalid
                throw YConnectError.unsupported("服务未返回有效支付码，请稍后重试")
            }
            codeURL = order.codeURL // Hidden until the GET confirms the actual amount.
            try await queryCore()
            if state == .paid { await syncBalance() }
        } catch { record(error) }
    }

    func query() async {
        guard !isBusy, orderNo != nil else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            try await queryCore()
            if state == .paid && !balanceRefreshed { await syncBalance() }
        } catch { record(error) }
    }

    func retryBalanceRefresh() async {
        guard !isBusy, state == .paid else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        await syncBalance()
    }

    private func queryCore() async throws {
        try requireCurrent()
        guard state != .paid, let orderNo else { return }
        let result = try await api.paymentStatus(orderNo: orderNo, cookies: cookies)
        try requireCurrent()
        returnedAmount = nil
        guard result.orderNo == orderNo, result.amountCents == amountCents else {
            if result.orderNo == orderNo, (100...1_000_000).contains(result.amountCents) { returnedAmount = result.amountCents }
            state = .mismatch; codeURL = nil
            throw YConnectError.unsupported("服务返回的订单金额不一致，已隐藏支付码。若已付款，请到官网核对，避免重复支付")
        }
        if result.verificationStatus == "mismatch" { state = .mismatch }
        else if result.status == "paid" { state = result.verificationStatus == "verified" ? .paid : .verifying }
        else if ["pending", "failed", "closed"].contains(result.status), let next = State(rawValue: result.status) { state = next }
        else {
            state = .invalid; codeURL = nil
            throw YConnectError.unsupported("订单状态无法识别，请稍后查询")
        }
        if state != .pending { codeURL = nil }
    }

    private func requireCurrent() throws {
        guard isCurrent else {
            codeURL = nil
            throw YConnectError.invalidCredential("充值账户已变更，请重新打开充值页面")
        }
        guard !loginRequired else { throw YConnectError.invalidCredential("登录已过期，请重新连接账户") }
    }

    private func syncBalance() async {
        do { try requireCurrent(); try await refreshBalance(); try requireCurrent(); balanceRefreshed = true }
        catch { errorMessage = "支付已确认，余额暂未刷新，请点击刷新余额重试" }
    }

    private func record(_ error: Error) {
        errorMessage = error.localizedDescription
        if let error = error as? YConnectError, error.invalidatesStoredCredential {
            loginRequired = true; codeURL = nil
        }
    }
}
