import AppKit
import Darwin
import SwiftUI

@main
enum YConnectMain {
    @MainActor
    static func main() {
        if let manifest = argument(after: "--run-agent-session") {
            exit(AgentSessionRunner.run(manifestURL: URL(fileURLWithPath: manifest)))
        }
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--dark"), CommandLine.arguments.contains(where: { $0.hasPrefix("--render-") }) {
            application.appearance = NSAppearance(named: .darkAqua)
        }
        if let output = argument(after: "--render-widget") {
            renderWidget(application: application, output: output)
            return
        }
        if let output = argument(after: "--render-manager") {
            renderManager(application: application, output: output)
            return
        }
        if let output = argument(after: "--render-redemption") {
            renderRedemption(application: application, output: output)
            return
        }
        if let output = argument(after: "--render-recharge") {
            renderRecharge(application: application, output: output)
            return
        }
        if let output = argument(after: "--render-edge-dock") {
            application.setActivationPolicy(.prohibited)
            do {
                try YConnectEdgeDockController.renderPreview(to: URL(fileURLWithPath: output))
                print("edge dock rendered: \(output)")
            } catch {
                fputs("edge dock render failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let output = argument(after: "--render-tray-icon") {
            renderTrayIcon(application: application, output: output)
            return
        }

        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private static func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor
    private static func renderWidget(application: NSApplication, output: String) {
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yconnect-preview-\(UUID().uuidString)", isDirectory: true)
        let environment = AppEnvironment.preview(at: scratch)
        let installedClientIDs = detectedClientIDsForPreview(environment: environment)
        let store = YConnectStore.preview(
            environment: environment,
            authenticated: !CommandLine.arguments.contains("--signed-out"),
            authenticationMode: CommandLine.arguments.contains("--api-key-mode") ? .apiKey : .account,
            includeAPIKeys: !CommandLine.arguments.contains("--without-api-keys"),
            installedClientIDs: installedClientIDs,
            operationMessage: CommandLine.arguments.contains("--with-operation-message")
                ? "“Y CONNECT-4”已删除"
                : nil
        )
        let presentation = WidgetPresentationState()
        if let maximumHeight = argument(after: "--maximum-height").flatMap(Double.init), maximumHeight >= 300 {
            presentation.maximumHeight = maximumHeight
        }
        presentation.showsConnectionURLs = CommandLine.arguments.contains("--expanded-urls")
        presentation.showsModels = CommandLine.arguments.contains("--expanded-models")
        let view = WidgetView(
            store: store,
            presentation: presentation,
            beginAccountLogin: {}, openManager: { _ in }, openAPIKeyCreation: {}, closeWidget: {}
        )
        do {
            try render(
                view: view,
                size: NSSize(width: WidgetMetrics.width, height: WidgetMetrics.height(for: store, presentation: presentation)),
                output: output
            )
            print("widget rendered: \(output)")
        } catch {
            fputs("widget render failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func renderManager(application: NSApplication, output: String) {
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yconnect-preview-\(UUID().uuidString)", isDirectory: true)
        let environment = AppEnvironment.preview(at: scratch)
        let store = YConnectStore.preview(
            environment: environment,
            authenticated: !CommandLine.arguments.contains("--signed-out"),
            authenticationMode: CommandLine.arguments.contains("--api-key-mode") ? .apiKey : .account,
            installedClientIDs: detectedClientIDsForPreview(environment: environment)
        )
        if let clientName = argument(after: "--client") {
            let requested = ClientID(rawValue: clientName)
            if store.clientDescriptors.contains(where: { $0.id == requested }) {
                store.selectedClientID = requested
            }
        }
        if let contextWindow = argument(after: "--context-window") { store.contextWindowInput = contextWindow }
        let navigation = ManagerNavigation()
        if let sectionName = argument(after: "--section"),
           let section = ManagerSection(rawValue: sectionName == "openCode" ? "clients" : sectionName) {
            navigation.selection = section
        }
        let launch = LaunchAtLoginManager(backend: PreviewLaunchAtLoginBackend(), packagedApplication: true)
        let view = ManagerView(
            store: store, navigation: navigation, launchAtLogin: launch,
            beginAccountLogin: {}, setEdgeDockEnabled: { _ in }
        )
        do {
            try render(view: view, size: NSSize(width: 1080, height: 720), output: output)
            print("manager rendered: \(output)")
        } catch {
            fputs("manager render failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func renderRedemption(application: NSApplication, output: String) {
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yconnect-redemption-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = YConnectStore.preview(environment: .preview(at: scratch))
        do { try render(view: RedemptionView(store: store), size: NSSize(width: 448, height: 230), output: output) }
        catch { fputs("redemption render failed\n", stderr); exit(1) }
    }

    @MainActor
    private static func renderRecharge(application: NSApplication, output: String) {
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let session = RechargeSession(api: RechargePreviewAPI(), cookies: [], accountName: "预览账户",
                                      currentAccount: { true })
        if CommandLine.arguments.contains("--with-payment-order") {
            var ready = false
            Task { await session.create(amountText: "50", channel: .wechat); ready = true }
            while !ready { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let view = VStack(alignment: .leading, spacing: 18) {
            Text("账户充值").font(.title.bold())
            Text("演示数据 · 仅用于界面预览，不可付款").font(.caption).foregroundStyle(.orange)
            RechargeView(session: session, balance: "¥396.2", beginAccountLogin: {}, startAnother: {})
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).tint(Brand.accent)
        do { try render(view: view, size: NSSize(width: 600, height: 760), output: output) }
        catch { fputs("recharge render failed\n", stderr); exit(1) }
    }

    @MainActor
    private static func detectedClientIDsForPreview(environment: AppEnvironment) -> Set<ClientID>? {
        guard CommandLine.arguments.contains("--detect-installed") else { return nil }
        guard let registry = try? DefaultClientConfigurationRegistry.make(environment: environment) else { return [] }
        return DefaultClientInstallationDetector().installedClientIDs(from: registry.descriptors)
    }

    @MainActor
    private static func render<V: View>(view: V, size: NSSize, output: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // NavigationSplitView completes some deferred layout after its first pass;
        // let the snapshot reach the same settled state as the live manager window.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw YConnectError.file("无法创建预览位图")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw YConnectError.file("无法编码预览 PNG")
        }
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        window.orderOut(nil)
    }

    @MainActor
    private static func renderTrayIcon(application: NSApplication, output: String) {
        application.setActivationPolicy(.prohibited)
        let pixels = 220
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        TrayIconRenderer.makeImage().draw(
            in: NSRect(x: 20, y: 20, width: 180, height: 180),
            from: NSRect(origin: .zero, size: TrayIconRenderer.canvasSize),
            operation: .sourceOver, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("tray icon rendered: \(output)")
        } catch {
            fputs("tray icon render failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct RechargePreviewAPI: RechargeAPI {
    func createPayment(amountCents: Int64, channel: PaymentChannel, cookies: [StoredWebCookie]) async throws -> PaymentOrder {
        PaymentOrder(orderNo: "YC20260907000000PREVIEW", codeURL: "https://yakcool.com/#yconnect-preview-no-payment", channel: channel.rawValue)
    }
    func paymentStatus(orderNo: String, cookies: [StoredWebCookie]) async throws -> PaymentOrderStatus {
        PaymentOrderStatus(orderNo: orderNo, amountCents: 5000, status: "pending", verificationStatus: "")
    }
}
