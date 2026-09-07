import Foundation

/// Account-wide daily totals, across every API Key and model. Amounts are RMB,
/// already weighted by the billing service; raw token counts are not prices.
struct AccountUsageResponse: Codable, Equatable {
    let available: Bool
    let status: String
    let from: String
    let to: String
    let rows: [AccountUsageRow]
    let partial: Bool?
}

struct AccountUsageRow: Codable, Equatable {
    let date: String
    let requestCount: Int64
    let estimatedCount: Int64
    let amountRMB: String

    enum CodingKeys: String, CodingKey {
        case date
        case requestCount = "request_count"
        case estimatedCount = "estimated_count"
        case amountRMB = "amount_rmb"
    }
}

enum RMBAmount {
    static func parse(_ text: String) -> Decimal? {
        guard text.range(of: #"\A[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN else { return nil }
        return amount
    }

    static func display(_ amount: Decimal?) -> String {
        guard let amount, !amount.isNaN else { return "—" }
        let magnitude = amount < 0 ? -amount : amount
        if magnitude > 0 && magnitude < Decimal(string: "0.01")! { return "<¥0.01" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: magnitude as NSDecimalNumber).map { "¥\($0)" } ?? "—"
    }
}

extension CreditSummary {
    var spentRMB: Decimal? {
        guard ["synced", "ok"].contains(status) else { return nil }
        if let tokenUsedRMB, let amount = RMBAmount.parse(tokenUsedRMB) { return amount }
        guard let tokenUsed, tokenUsed >= 0 else { return nil }
        let divisor = weightedTokensPerRMB ?? 10_000_000
        guard divisor > 0 else { return nil }
        return Decimal(tokenUsed) / Decimal(divisor)
    }
}

struct AccountSpendingSnapshot: Equatable {
    let todayRMB: Decimal?
    let yesterdayRMB: Decimal?
    let todayRequests: Int64?
    let hasEstimates: Bool
    let unavailableReason: String?

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    init(usage: AccountUsageResponse?, now: Date = Date()) {
        let today = Self.dayString(now)
        let yesterday = Self.dayString(Self.calendar.date(byAdding: .day, value: -1, to: now)!)
        var reason: String?
        if usage?.available != true || usage?.status != "synced" {
            reason = usage?.status == "uninitialized" ? "尚无用量统计" : "今日统计暂不可用"
        } else if usage?.partial == true {
            reason = "今日统计不完整"
        } else if usage?.to != today || (usage?.from ?? today) > yesterday {
            reason = "等待今日统计更新"
        }
        var total: Decimal = 0
        var previous: Decimal = 0
        var requests: Int64 = 0
        var estimates = false
        if reason == nil, let usage {
            for row in usage.rows where row.date == today || row.date == yesterday {
                guard let amount = RMBAmount.parse(row.amountRMB), row.requestCount >= 0,
                      row.estimatedCount >= 0, row.estimatedCount <= row.requestCount else {
                    reason = "今日统计暂不可用"; break
                }
                if row.date == today {
                    let sum = requests.addingReportingOverflow(row.requestCount)
                    guard !sum.overflow else { reason = "今日统计暂不可用"; break }
                    total += amount
                    requests = sum.partialValue
                } else { previous += amount }
                estimates = estimates || row.estimatedCount > 0
            }
            if total.isNaN || previous.isNaN { reason = "今日统计暂不可用" }
        }
        todayRMB = reason == nil ? total : nil
        yesterdayRMB = reason == nil ? previous : nil
        todayRequests = reason == nil ? requests : nil
        hasEstimates = reason == nil && estimates
        unavailableReason = reason
    }

    var comparisonText: String {
        guard let todayRMB, let yesterdayRMB else { return unavailableReason ?? "今日统计暂不可用" }
        let difference = todayRMB - yesterdayRMB
        if difference == 0 { return "与昨日全天持平" }
        return "较昨日全天\(difference > 0 ? "多" : "少") \(RMBAmount.display(difference))"
    }
}
