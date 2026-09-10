import SwiftUI

struct RedemptionView: View {
    @ObservedObject var store: YConnectStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var feedback: String?
    @State private var submitting = false
    @FocusState private var focused: Bool

    private var validCode: Bool {
        (try? YakCoolAPI.normalizedRedemptionCode(code)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("兑换码").font(.title2.bold())
            Text("兑换至账户：\(store.userDisplayName)").foregroundStyle(.secondary)
            TextField("输入 12–64 位兑换码", text: $code)
                .textFieldStyle(.roundedBorder).focused($focused)
                .disabled(submitting).onSubmit { submit() }
            if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(submitting ? "正在兑换…" : "兑换") { submit() }
                    .buttonStyle(SmallPrimaryButtonStyle())
                    .disabled(!validCode || store.isBusy || submitting || !store.isAccountMode)
                    .opacity(validCode && !store.isBusy && !submitting && store.isAccountMode ? 1 : 0.5)
            }
        }
        .padding(24).frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(submitting)
        .onAppear { focused = true }
        .onChange(of: store.isAccountMode) { _, account in if !account { dismiss() } }
    }

    private func submit() {
        guard validCode, !store.isBusy, !submitting, store.isAccountMode else { return }
        submitting = true
        feedback = nil
        Task {
            let success = await store.redeem(code: code)
            feedback = store.errorMessage ?? store.operationMessage
            store.errorMessage = nil
            if success { code = "" }
            submitting = false
        }
    }
}
