import AppKit
import Combine
import SwiftUI

enum WidgetPositioning {
    static let margin: CGFloat = 8

    static func frame(size: NSSize, trayAnchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let preferredX = trayAnchor.midX - size.width / 2
        let x = max(visibleFrame.minX + margin, min(preferredX, visibleFrame.maxX - size.width - margin))
        let preferredY = trayAnchor.minY - size.height - margin
        let y = max(visibleFrame.minY + margin, min(preferredY, visibleFrame.maxY - size.height - margin))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func appKitFrame(fromQuartz frame: CGRect, primaryScreenTop: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: primaryScreenTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func nearlyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 1) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let environment: AppEnvironment
    let store: YConnectStore
    let launchAtLogin: LaunchAtLoginManager

    private let widgetPresentation = WidgetPresentationState()
    private let managerNavigation = ManagerNavigation()
    private let accountLogin = AccountLoginCoordinator()
    private var statusItem: NSStatusItem!
    private var widgetPanel: NSPanel?
    private var managerWindow: NSWindow?
    private var smokeWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var widgetOrigin: WidgetOrigin = .tray
    private var suppressWidgetDismissalUntil = Date.distantPast
    private var hasPresentedWidget = false

    private lazy var edgeDock = YConnectEdgeDockController(
        store: store,
        onOpenWidget: { [weak self] frame, left in self?.showWidgetFromEdge(anchor: frame, onLeft: left) },
        onOpenManager: { [weak self] section in self?.showManager(section: section) }
    )

    private enum WidgetOrigin {
        case tray
        case edge(anchor: NSRect, onLeft: Bool)
    }

    init(environment: AppEnvironment = .current(), store: YConnectStore? = nil) {
        self.environment = environment
        self.store = store ?? YConnectStore(environment: environment)
        launchAtLogin = LaunchAtLoginManager(
            packagedApplication: Bundle.main.bundleURL.pathExtension.lowercased() == "app"
                && !environment.isDevelopment
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureSubscriptions()
        edgeDock.update()
        launchAtLogin.enableOnFirstLaunchIfNeeded()

        if CommandLine.arguments.contains("--smoke-edge-widget-focus") {
            runEdgeWidgetSmoke()
        } else if CommandLine.arguments.contains("--smoke-widget-focus")
                    || CommandLine.arguments.contains("--smoke-widget-transient") {
            waitForStableTrayAnchor()
        }

        Task { await store.restoreSession() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "yconnect.main"
        guard let button = statusItem.button else { return }
        button.image = TrayIconRenderer.makeImage()
        button.imagePosition = .imageLeft
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "YConnect · 左键打开小组件 / 右键菜单"
        refreshStatusItem()
    }

    private func configureSubscriptions() {
        store.$phase.sink { [weak self] _ in Task { @MainActor in self?.refreshPresentedUI() } }.store(in: &subscriptions)
        store.$dashboard.sink { [weak self] _ in Task { @MainActor in self?.refreshPresentedUI() } }.store(in: &subscriptions)
        store.$businessKeyInfo.sink { [weak self] _ in Task { @MainActor in self?.refreshPresentedUI() } }.store(in: &subscriptions)
        store.$accountKeys.sink { [weak self] _ in Task { @MainActor in self?.refreshPresentedUI() } }.store(in: &subscriptions)
        store.$isBusy.sink { [weak self] _ in Task { @MainActor in self?.updateWidgetSize() } }.store(in: &subscriptions)
        store.$operationMessage.sink { [weak self] _ in Task { @MainActor in self?.updateWidgetSize() } }.store(in: &subscriptions)
    }

    private func refreshPresentedUI() {
        refreshStatusItem()
        updateWidgetSize()
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        switch store.phase {
        case .signedOut: button.title = ""
        case .restoring: button.title = " …"
        case .account:
            button.title = store.dashboard?.aiServiceCredit.remainingRMB.map { " ¥\($0)" } ?? " ●"
        case .apiKey: button.title = " ●"
        }
        button.superview?.layoutSubtreeIfNeeded()
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu() }
        else { toggleWidget() }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "显示小组件", action: #selector(showWidgetAction), keyEquivalent: "")
        show.target = self
        let manager = menu.addItem(withTitle: "打开 YConnect", action: #selector(showManagerAction), keyEquivalent: ",")
        manager.target = self
        if store.isAuthenticated {
            menu.addItem(.separator())
            let copy = menu.addItem(withTitle: "复制当前 API Key", action: #selector(copyAPIKeyAction), keyEquivalent: "")
            copy.target = self
            let configure = menu.addItem(withTitle: "应用到 OpenCode", action: #selector(configureOpenCodeAction), keyEquivalent: "")
            configure.target = self
            configure.isEnabled = !store.isBusy
            let refresh = menu.addItem(withTitle: "刷新账户状态", action: #selector(refreshAction), keyEquivalent: "r")
            refresh.target = self
            refresh.isEnabled = !store.isBusy
        }
        menu.addItem(.separator())
        let edge = menu.addItem(
            withTitle: EdgeDockPreferences.isEnabled ? "隐藏边缘小组件" : "显示边缘小组件",
            action: #selector(toggleEdgeDock), keyEquivalent: ""
        )
        edge.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 YConnect", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showWidgetAction() { showWidget() }
    @objc private func showManagerAction() { showManager(section: .overview) }
    @objc private func copyAPIKeyAction() { _ = store.copyCurrentAPIKey() }
    @objc private func configureOpenCodeAction() { Task { await store.applyOpenCodeConfiguration() } }
    @objc private func refreshAction() { Task { await store.refresh() } }
    @objc private func toggleEdgeDock() { edgeDock.toggleEnabled() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func toggleWidget() {
        if widgetPanel?.isVisible == true { hideWidget() } else { showWidget() }
    }

    private func hideWidget() {
        widgetPanel?.orderOut(nil)
        edgeDock.setWidgetPresented(false)
    }

    func showWidget(focus: Bool = true) {
        guard let anchor = trayAnchor() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.showWidget(focus: focus) }
            return
        }
        let panel = preparedWidgetPanel()
        widgetOrigin = .tray
        positionWidget(panel, anchor: anchor)
        presentWidget(panel, focus: focus)
    }

    private func showWidgetFromEdge(anchor: NSRect, onLeft: Bool) {
        let panel = preparedWidgetPanel()
        widgetOrigin = .edge(anchor: anchor, onLeft: onLeft)
        edgeDock.setWidgetPresented(true)
        positionWidgetBesideEdge(panel, anchor: anchor, onLeft: onLeft)
        hasPresentedWidget = true
        suppressWidgetDismissalUntil = Date().addingTimeInterval(0.25)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            self.focusWidget(panel)
        }
    }

    private func preparedWidgetPanel() -> NSPanel {
        if let widgetPanel { return widgetPanel }
        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: WidgetMetrics.width, height: currentWidgetHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .readOnly
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: WidgetView(
            store: store,
            presentation: widgetPresentation,
            beginAccountLogin: { [weak self] in self?.beginAccountLogin() },
            openManager: { [weak self] section in self?.showManager(section: section) },
            closeWidget: { [weak self] in self?.hideWidget() }
        ))
        widgetPanel = panel
        return panel
    }

    private func presentWidget(_ panel: NSPanel, focus: Bool) {
        hasPresentedWidget = true
        edgeDock.setWidgetPresented(true)
        if focus { focusWidget(panel) } else { panel.orderFrontRegardless() }
    }

    private func focusWidget(_ panel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView)
        }
    }

    private func beginAccountLogin() {
        hideWidget()
        NSApp.setActivationPolicy(.regular)
        accountLogin.present { [weak self] cookies in
            guard let self else { return }
            try await self.store.completeAccountLogin(cookies: cookies)
        }
    }

    func showManager(section: ManagerSection) {
        managerNavigation.selection = section
        hideWidget()
        let window = preparedManagerWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func preparedManagerWindow() -> NSWindow {
        if let managerWindow { return managerWindow }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "YConnect"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 940, height: 640)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ManagerView(
            store: store,
            navigation: managerNavigation,
            launchAtLogin: launchAtLogin,
            beginAccountLogin: { [weak self] in self?.beginAccountLogin() },
            setEdgeDockEnabled: { [weak self] enabled in self?.edgeDock.setEnabled(enabled) }
        ))
        managerWindow = window
        return window
    }

    private var currentWidgetHeight: CGFloat { WidgetMetrics.height(for: store) }

    private func updateWidgetSize() {
        guard let panel = widgetPanel else { return }
        let oldFrame = panel.frame
        let newSize = NSSize(width: WidgetMetrics.width, height: currentWidgetHeight)
        panel.setContentSize(newSize)
        switch widgetOrigin {
        case .tray:
            if let anchor = trayAnchor() { positionWidget(panel, anchor: anchor) }
            else { panel.setFrameOrigin(NSPoint(x: oldFrame.minX, y: oldFrame.maxY - newSize.height)) }
        case .edge(let anchor, let onLeft):
            positionWidgetBesideEdge(panel, anchor: anchor, onLeft: onLeft)
        }
    }

    private func trayAnchor() -> NSRect? {
        guard let button = statusItem?.button, let statusWindow = button.window else { return nil }
        button.superview?.layoutSubtreeIfNeeded()
        if let actual = actualWindowFrame(windowNumber: statusWindow.windowNumber) { return actual }
        return statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func actualWindowFrame(windowNumber: Int) -> NSRect? {
        guard windowNumber > 0,
              let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], CGWindowID(windowNumber)) as? [[String: Any]],
              let bounds = rows.first?[kCGWindowBounds as String] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
        let quartzFrame = CGRect(x: x, y: y, width: width, height: height)
        let top = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return WidgetPositioning.appKitFrame(fromQuartz: quartzFrame, primaryScreenTop: top)
    }

    private func positionWidget(_ panel: NSPanel, anchor: NSRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                ?? statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(WidgetPositioning.frame(
            size: NSSize(width: WidgetMetrics.width, height: currentWidgetHeight),
            trayAnchor: anchor,
            visibleFrame: screen.visibleFrame
        ), display: true)
    }

    private func positionWidgetBesideEdge(_ panel: NSPanel, anchor: NSRect, onLeft: Bool) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(EdgeWidgetPositioning.frame(
            size: NSSize(width: WidgetMetrics.width, height: currentWidgetHeight),
            tabFrame: anchor,
            onLeft: onLeft,
            visibleFrame: screen.visibleFrame
        ), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === widgetPanel else { return }
        scheduleWidgetDismissal()
    }

    private func scheduleWidgetDismissal() {
        guard !widgetPresentation.isPinned, !store.isBusy, Date() >= suppressWidgetDismissalUntil,
              widgetPanel?.attachedSheet == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.widgetPanel, panel.isVisible, !panel.isKeyWindow,
                  !self.widgetPresentation.isPinned, !self.store.isBusy,
                  panel.attachedSheet == nil, Date() >= self.suppressWidgetDismissalUntil else { return }
            self.hideWidget()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === managerWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.accountLoginWindowIsHidden else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var accountLoginWindowIsHidden: Bool { NSApp.windows.allSatisfy { !$0.isVisible || $0 === widgetPanel } }

    private func waitForStableTrayAnchor(previous: NSRect? = nil, stableSamples: Int = 0) {
        guard !hasPresentedWidget else { return }
        guard let anchor = trayAnchor() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitForStableTrayAnchor(previous: previous, stableSamples: 0) }
            return
        }
        let stable = previous.map { WidgetPositioning.nearlyEqual($0, anchor) } ?? false
        let samples = stable ? stableSamples + 1 : 0
        guard samples >= 2 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitForStableTrayAnchor(previous: anchor, stableSamples: samples) }
            return
        }
        showWidget(focus: true)
        if CommandLine.arguments.contains("--smoke-widget-transient") { runTransientWidgetSmoke() }
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                let passed = NSApp.isActive && self?.widgetPanel?.isKeyWindow == true
                self?.finishSmoke(name: "widget focus", passed: passed)
            }
        }
    }

    private func runTransientWidgetSmoke() {
        guard let panel = widgetPanel else { finishSmoke(name: "widget transient", passed: false); return }
        let probe = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 20, height: 20), styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        smokeWindow = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self, weak panel] in
            guard let self, let panel else { return }
            probe.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self, weak panel] in
                guard let self, let panel else { return }
                let dismissed = !panel.isVisible
                self.widgetPresentation.isPinned = true
                self.showWidget()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    probe.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                        self.finishSmoke(name: "widget transient", passed: dismissed && panel.isVisible)
                    }
                }
            }
        }
    }

    private func runEdgeWidgetSmoke() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let anchor = self.edgeDock.openWidgetForSmokeTest() else {
                self?.finishSmoke(name: "edge widget focus", passed: false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                guard let panel = self.widgetPanel else { self.finishSmoke(name: "edge widget focus", passed: false); return }
                let beside = EdgeDockPreferences.isOnLeft ? panel.frame.minX >= anchor.maxX : panel.frame.maxX <= anchor.minX
                self.finishSmoke(name: "edge widget focus", passed: panel.isVisible && panel.isKeyWindow && beside)
            }
        }
    }

    private func finishSmoke(name: String, passed: Bool) {
        print("\(name) smoke \(passed ? "passed" : "failed")")
        fflush(stdout)
        exit(passed ? 0 : 1)
    }
}

enum TrayIconRenderer {
    static let canvasSize = NSSize(width: 18, height: 18)

    @MainActor
    static func makeImage() -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.appendArc(withCenter: NSPoint(x: 6.2, y: 9), radius: 3.5, startAngle: 55, endAngle: 305)
            path.appendArc(withCenter: NSPoint(x: 11.8, y: 9), radius: 3.5, startAngle: 235, endAngle: 125)
            path.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.25, y: rect.midY - 1.25, width: 2.5, height: 2.5))
            dot.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
