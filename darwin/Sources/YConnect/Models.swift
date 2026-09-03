import Foundation

enum Brand {
    static let accentHex = 0xC76A55
}

enum AuthenticationMode: String, Codable, CaseIterable, Identifiable {
    case account
    case apiKey

    var id: String { rawValue }
    var title: String {
        switch self {
        case .account: return "YakCool 账号"
        case .apiKey: return "API Key"
        }
    }
}

struct YakCoolUser: Codable, Equatable {
    let id: Int64
    let publicUUID: String?
    let displayName: String
    let avatarURL: String
    let isEnterprise: Bool?
    let enterpriseName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case publicUUID = "public_uuid"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case isEnterprise = "is_enterprise"
        case enterpriseName = "enterprise_name"
    }
}

struct CreditSummary: Codable, Equatable {
    let status: String
    let uid: String?
    let tokenLimit: Int64?
    let tokenUsed: Int64?
    let tokenRemaining: Int64?
    let tokenLimitEnabled: Bool?
    let tokenLimitRMB: String?
    let tokenUsedRMB: String?
    let weightedTokensPerRMB: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, uid, error
        case tokenLimit = "token_limit"
        case tokenUsed = "token_used"
        case tokenRemaining = "token_remaining"
        case tokenLimitEnabled = "token_limit_enable"
        case tokenLimitRMB = "token_limit_rmb"
        case tokenUsedRMB = "token_used_rmb"
        case weightedTokensPerRMB = "weighted_tokens_per_rmb"
    }

    var remainingRMB: String? {
        guard let remaining = tokenRemaining else { return nil }
        let divisor = Decimal(weightedTokensPerRMB ?? 10_000_000)
        guard divisor > 0 else { return nil }
        let value = Decimal(remaining) / divisor
        return Self.rmbFormatter.string(from: value as NSDecimalNumber)
    }

    private static let rmbFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

struct AccountSummary: Codable, Equatable {
    let keyCount: Int?
    let activeKeyCount: Int?
    let inactiveKeyCount: Int?
    let modelCount: Int?
    let usageCount: Int64?
    let successCount: Int64?
    let failureCount: Int64?
    let successRate: Double?
    let webSearchCount: Int64?
    let activeDays: Int?
    let lastUsedTime: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case keyCount = "key_count"
        case activeKeyCount = "active_key_count"
        case inactiveKeyCount = "inactive_key_count"
        case modelCount = "model_count"
        case usageCount = "usage_count"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case successRate = "success_rate"
        case webSearchCount = "web_search_count"
        case activeDays = "active_days"
        case lastUsedTime = "last_used_time"
        case createdAt = "created_at"
    }
}

struct AccessMethod: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let path: String
}

struct DashboardResponse: Codable, Equatable {
    let user: YakCoolUser
    let aiServiceCredit: CreditSummary
    let apiKeyCount: Int
    let apiKeyLimit: Int
    let gatewayURL: String
    let accessMethods: [AccessMethod]
    let accountSummary: AccountSummary?

    enum CodingKeys: String, CodingKey {
        case user
        case aiServiceCredit = "ai_service_credit"
        case apiKeyCount = "api_key_count"
        case apiKeyLimit = "api_key_limit"
        case gatewayURL = "gateway_url"
        case accessMethods = "access_methods"
        case accountSummary = "account_summary"
    }
}

struct UserAccountResponse: Codable, Equatable {
    let id: Int64
    let publicUUID: String
    let displayName: String
    let avatarURL: String
    let loginMethod: String
    let wechatBound: Bool
    let createdAt: Int64
    let lastLoginAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case publicUUID = "public_uuid"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case loginMethod = "login_method"
        case wechatBound = "wechat_bound"
        case createdAt = "created_at"
        case lastLoginAt = "last_login_at"
    }
}

struct APIKeyRecord: Codable, Equatable, Identifiable {
    let id: Int64
    let label: String
    let apiKey: String
    let last4: String
    let allowedModels: [String]
    let tokenUsed: Int64
    let tokenLimit: Int64
    let tokenLimitEnabled: Bool
    let usageCount: Int64
    let successCount: Int64?
    let failureCount: Int64?
    let active: Bool
    let status: String
    let createdAt: String
    let lastUsedTime: String

    enum CodingKeys: String, CodingKey {
        case id, label, active, status
        case apiKey = "api_key"
        case last4
        case allowedModels = "allowed_models"
        case tokenUsed = "token_used"
        case tokenLimit = "token_limit"
        case tokenLimitEnabled = "token_limit_enable"
        case usageCount = "usage_count"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case createdAt = "created_at"
        case lastUsedTime = "last_used_time"
    }

    var maskedKey: String { "•••• •••• •••• \(last4)" }
}

struct APIKeysResponse: Codable, Equatable {
    let keys: [APIKeyRecord]
    let syncStatus: String
    let apiKeyLimit: Int

    enum CodingKeys: String, CodingKey {
        case keys
        case syncStatus = "sync_status"
        case apiKeyLimit = "api_key_limit"
    }
}

struct ModelRecord: Codable, Equatable, Identifiable {
    let id: Int64
    let modelID: String
    let displayName: String
    let provider: String
    let summary: String
    let capabilityTags: [String]
    let contextWindow: Int64
    let recommendedScenarios: String

    enum CodingKeys: String, CodingKey {
        case id, provider, summary
        case modelID = "model_id"
        case displayName = "display_name"
        case capabilityTags = "capability_tags"
        case contextWindow = "context_window"
        case recommendedScenarios = "recommended_scenarios"
    }
}

struct ModelsResponse: Codable, Equatable {
    let models: [ModelRecord]
}

struct BusinessKeySummary: Codable, Equatable {
    let label: String
    let last4: String
    let status: String
}

struct BusinessQuota: Codable, Equatable {
    let mode: String
    let followsAccount: Bool
    let approximate: Bool
    let stepPercent: Int?
    let usedPercentApprox: Int?
    let remainingPercentApprox: Int?
    let currency: String?
    let limitRMB: String?
    let usedRMB: String?
    let remainingRMB: String?
    let exhausted: Bool?
    let display: String

    enum CodingKeys: String, CodingKey {
        case mode, approximate, currency, display, exhausted
        case followsAccount = "follows_account"
        case stepPercent = "step_percent"
        case usedPercentApprox = "used_percent_approx"
        case remainingPercentApprox = "remaining_percent_approx"
        case limitRMB = "limit_rmb"
        case usedRMB = "used_rmb"
        case remainingRMB = "remaining_rmb"
    }

    var followsMainBalance: Bool {
        followsAccount || mode == "shared_account" || mode == "account"
    }

    var formattedRemainingRMB: String? {
        guard let remainingRMB,
              let value = Decimal(string: remainingRMB, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return Self.rmbFormatter.string(from: value as NSDecimalNumber)
    }

    var remainingPercentValue: Int? {
        if let remainingPercentApprox {
            return min(100, max(0, remainingPercentApprox))
        }
        if let usedPercentApprox {
            return 100 - min(100, max(0, usedPercentApprox))
        }
        return nil
    }

    var statusDisplay: String {
        if followsMainBalance {
            return remainingPercentValue.map { "跟随主余额，剩余约 \($0)%" } ?? "跟随主余额"
        }
        return formattedRemainingRMB.map { "Key 独立额度，剩余 ¥\($0)" } ?? display
    }

    var metricTitle: String {
        followsMainBalance ? "剩余比例" : "可用余额"
    }

    var metricValue: String {
        if followsMainBalance {
            return remainingPercentValue.map { "约 \($0)%" } ?? display
        }
        return formattedRemainingRMB.map { "¥\($0)" } ?? display
    }

    var modeDisplay: String {
        followsMainBalance ? "跟随主余额" : "独立限额"
    }

    var connectionModeDisplay: String {
        followsMainBalance ? "跟随主余额 API Key" : "独立余额 API Key"
    }

    var trayStatusText: String? {
        if followsMainBalance {
            return remainingPercentValue.map { "\($0)%" }
        }
        return formattedRemainingRMB.map { "¥\($0)" }
    }

    var trayStatusIsLow: Bool {
        guard followsMainBalance, let remainingPercentValue else { return false }
        return remainingPercentValue < 30
    }

    private static let rmbFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

struct BusinessKeyInfoResponse: Codable, Equatable {
    let schemaVersion: Int
    let key: BusinessKeySummary
    let quota: BusinessQuota
    let queriedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case key, quota
        case queriedAt = "queried_at"
    }
}

struct BusinessKeyModel: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let protocols: [String]
}

struct BusinessKeyModelsResponse: Codable, Equatable {
    let schemaVersion: Int
    let object: String
    let data: [BusinessKeyModel]
    let queriedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case object, data
        case queriedAt = "queried_at"
    }
}

struct CreateKeyResponse: Codable {
    let key: APIKeyRecord
}

struct StatusResponse: Codable {
    let status: String
    let message: String?
    let amountCents: Int64?

    enum CodingKeys: String, CodingKey {
        case status, message
        case amountCents = "amount_cents"
    }
}

struct ServiceCheck: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case running
        case passed(String)
        case failed(String)
    }

    let id: String
    let title: String
    var state: State
}

struct StoredWebCookie: Codable, Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresAt: Date?

    init?(cookie: HTTPCookie) {
        guard Self.allowedNames.contains(cookie.name), Self.isAllowedDomain(cookie.domain) else { return nil }
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresAt = cookie.expiresDate
    }

    // The employee/admin cookie is intentionally excluded. YConnect is a public
    // account client and must not silently cross the staff/public auth boundary.
    static let allowedNames: Set<String> = ["yakcool_user_session"]

    static func isAllowedDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // The production session is host-only (or may be serialized as
        // `.yakcool.com`). Never promote a cookie issued by a sibling
        // subdomain into a Cookie header for the apex API origin.
        return normalized == "yakcool.com"
    }

    var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    var isSafeForRequest: Bool {
        !isExpired
            && Self.allowedNames.contains(name)
            && Self.isAllowedDomain(domain)
            && path == "/"
            && !value.isEmpty
            && !value.unicodeScalars.contains(where: {
                $0 == ";" || CharacterSet.controlCharacters.contains($0)
            })
    }
}

enum YConnectError: LocalizedError, Equatable {
    case invalidCredential(String)
    case invalidResponse
    case server(status: Int, code: String, message: String)
    case transport(String)
    case unsupported(String)
    case file(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential(let message), .transport(let message), .unsupported(let message), .file(let message):
            return message
        case .invalidResponse:
            return "服务返回了无法识别的数据"
        case .server(_, _, let message):
            return message
        }
    }

    var invalidatesStoredCredential: Bool {
        switch self {
        case .invalidCredential:
            return true
        case .server(let status, _, _):
            return status == 401
        case .invalidResponse, .transport, .unsupported, .file:
            return false
        }
    }
}
