import SwiftUI

struct AccountSpendingView: View {
    @ObservedObject var store: YConnectStore

    var body: some View {
        if store.isAccountMode {
            let snapshot = AccountSpendingSnapshot(usage: store.accountUsage)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    metric("累计已用", RMBAmount.display(store.dashboard?.aiServiceCredit.spentRMB))
                    metric("今日消费", RMBAmount.display(snapshot.todayRMB))
                    metric("今日调用", snapshot.todayRequests.map { "\($0) 次" } ?? "—")
                }
                HStack(spacing: 4) {
                    Text(snapshot.comparisonText)
                    Spacer(minLength: 0)
                    Text(updateLabel(snapshot))
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 10)
            .frame(height: 76)
            .background(Brand.accent.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("account-spending")
            .help("账户所有 API Key 的人民币消费。今日按北京时间统计，与昨日全天比较；每分钟刷新，服务端记录可能稍有延迟。累计已用来自账户扣费总额，充值不会被算作消费。")
            .task(id: store.phase) {
                while !Task.isCancelled, store.isAccountMode {
                    await store.refreshAccountSpendingIfNeeded()
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateLabel(_ snapshot: AccountSpendingSnapshot) -> String {
        guard let date = store.spendingUpdatedAt, snapshot.unavailableReason == nil else { return "北京时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = AccountSpendingSnapshot.calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return "\(snapshot.hasEstimates ? "含估算 · " : "")\(formatter.string(from: date)) 更新"
    }
}
