import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct RechargeView: View {
    @ObservedObject var session: RechargeSession
    let balance: String
    let beginAccountLogin: () -> Void
    let startAnother: () -> Void
    @State private var amountText = "50"
    @State private var channel: PaymentChannel = .wechat
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.accountName).font(.headline)
                    Text("充值至此账户的 AI 服务余额").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(balance).font(.system(size: 28, weight: .semibold, design: .rounded))
            }.padding(18).background(Brand.accent.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
            if session.loginRequired || !session.isCurrent {
                Text("请重新登录要充值的 YAKCOOL 账户")
                Button("登录 YAKCOOL 账户", action: beginAccountLogin).buttonStyle(SmallPrimaryButtonStyle())
            } else if session.orderNo == nil || editing {
                form
            } else {
                order
            }
            Text("一次充值 · 不自动续费 · 余额用于 AI 模型服务").font(.caption).foregroundStyle(.secondary)
            Link("在官网核对账户与订单 ↗", destination: URL(string: "https://yakcool.com/workspace")!).font(.caption)
        }
        .frame(maxWidth: 540, alignment: .leading)
        .onAppear {
            if session.orderNo != nil { amountText = session.amount; channel = session.channel }
        }
        .task {
            if session.orderNo != nil { await session.query() }
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                ticks += 1
                if !editing && ticks % 2 == 0 && session.needsPolling { await session.query() }
                if ticks % 5 == 0 && session.state == .paid && !session.balanceRefreshed { await session.retryBalanceRefresh() }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("充值金额").font(.headline); Spacer(); Text("¥1–¥10,000").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("¥").font(.title)
                TextField("输入金额，最多两位小数", text: $amountText)
                    .textFieldStyle(.roundedBorder).font(.title2).accessibilityIdentifier("recharge-amount")
            }
            HStack {
                ForEach(["50", "100", "200", "500"], id: \.self) { amount in
                    Button("¥\(amount)") { amountText = amount }
                        .buttonStyle(SmallSecondaryButtonStyle()).frame(maxWidth: .infinity)
                }
            }
            Picker("支付方式", selection: $channel) {
                ForEach(PaymentChannel.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Button {
                Task {
                    await session.create(amountText: amountText, channel: channel)
                    if session.orderNo != nil { editing = false }
                }
            } label: { Label(session.isBusy ? "正在核对订单…" : "确认金额 · 生成支付码", systemImage: "qrcode") }
                .buttonStyle(SmallPrimaryButtonStyle()).accessibilityIdentifier("recharge-create")
            Text("下一步使用手机扫码，并在支付页面核对金额后付款。").font(.caption).foregroundStyle(.secondary)
            if session.orderNo != nil {
                Button("返回当前订单") { editing = false }.buttonStyle(.link)
            }
        }.disabled(session.isBusy)
    }

    private var order: some View {
        VStack(spacing: 14) {
            Text(orderTitle).font(.title3.weight(.semibold))
            Text("¥\(session.amount)").font(.system(size: 36, weight: .semibold, design: .rounded))
            // TimelineView removes an expired QR even when a network request is still in flight.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if session.canShowQR, let payload = session.codeURL, let qr = PaymentQRCode.image(payload) {
                    VStack(spacing: 10) {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 220, height: 220).padding(12).background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("支付二维码")
                        Text("请用\(session.channel.title)扫码 · 展示剩余 \(session.secondsLeft / 60):\(String(format: "%02d", session.secondsLeft % 60))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label(orderMessage, systemImage: session.state == .paid ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(session.state == .paid ? Brand.green : .secondary)
                        .font(.callout).padding(18)
                }
            }
            Text("订单号  \(session.orderNo ?? "")").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            if session.state == .paid {
                if !session.balanceRefreshed {
                    Button("刷新余额") { Task { await session.retryBalanceRefresh() } }.buttonStyle(SmallPrimaryButtonStyle())
                }
                Button("再充一笔", action: startAnother).buttonStyle(SmallSecondaryButtonStyle())
            } else {
                Button(session.isBusy ? "查询中…" : "我已支付 · 查询结果") { Task { await session.query() } }
                    .buttonStyle(SmallPrimaryButtonStyle()).accessibilityIdentifier("recharge-check")
                Button("修改金额 / 支付方式 · 重新获取支付码") {
                    amountText = session.amount; channel = session.channel; editing = true
                }.buttonStyle(SmallSecondaryButtonStyle())
                Text("离开页面不会取消订单；本次运行中返回可继续查询。").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).disabled(session.isBusy)
    }

    private var orderTitle: String {
        switch session.state {
        case .paid: return "充值成功"
        case .verifying: return "正在核实支付结果"
        case .mismatch: return "订单需要核对"
        case .failed, .closed: return "订单未完成"
        default: return "扫码充值"
        }
    }
    private var orderMessage: String {
        switch session.state {
        case .paid: return session.balanceRefreshed ? "余额已同步到控制面板与桌面小组件" : "支付已确认，正在同步余额…"
        case .verifying: return "服务端尚未完成核验，请稍后查询，避免重复付款"
        case .mismatch: return "支付金额或上游核验不一致，请到官网核对订单"
        default: return "支付码已隐藏。若已付款，请继续查询结果"
        }
    }
}

enum PaymentQRCode {
    static func image(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8); filter.correctionLevel = "M"
        guard let modules = filter.outputImage else { return nil }
        let quietZone = CIImage(color: .white).cropped(to: modules.extent.insetBy(dx: -4, dy: -4))
        let output = modules.composited(over: quietZone).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
