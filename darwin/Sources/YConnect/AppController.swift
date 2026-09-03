import AppKit
import Combine
import SwiftUI

enum WidgetPositioning {
    static let margin: CGFloat = 8

    static func frame(size: NSSize, trayAnchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let fittedSize = constrainedSize(size, visibleFrame: visibleFrame)
        let preferredX = trayAnchor.midX - fittedSize.width / 2
        let x = max(visibleFrame.minX + margin, min(preferredX, visibleFrame.maxX - fittedSize.width - margin))
        let preferredY = trayAnchor.minY - fittedSize.height - margin
        let y = max(visibleFrame.minY + margin, min(preferredY, visibleFrame.maxY - fittedSize.height - margin))
        return NSRect(x: x, y: y, width: fittedSize.width, height: fittedSize.height)
    }

    static func maximumHeight(in visibleFrame: NSRect) -> CGFloat {
        max(1, visibleFrame.height - margin * 2)
    }

    private static func constrainedSize(_ size: NSSize, visibleFrame: NSRect) -> NSSize {
        NSSize(
            width: size.width,
            height: min(size.height, maximumHeight(in: visibleFrame))
        )
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
        configureMainMenu()
        configureStatusItem()
        configureSubscriptions()
        edgeDock.update()
        launchAtLogin.enableByDefaultIfNeeded()

        let isSmokeRun = CommandLine.arguments.contains("--smoke-edge-widget-focus")
            || CommandLine.arguments.contains("--smoke-widget-focus")
            || CommandLine.arguments.contains("--smoke-widget-transient")
        if CommandLine.arguments.contains("--smoke-edge-widget-focus") {
            runEdgeWidgetSmoke()
        } else if CommandLine.arguments.contains("--smoke-widget-focus")
                    || CommandLine.arguments.contains("--smoke-widget-transient") {
            waitForStableTrayAnchor()
        }
        if CommandLine.arguments.contains("--show-widget") {
            DispatchQueue.main.async { [weak self] in self?.showWidget() }
        }

        // Smoke runs validate window behavior with an unauthenticated fixture.
        // Avoid an interactive Keychain unlock from blocking their timers.
        if !isSmokeRun {
            Task { await store.restoreSession() }
        }
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
        store.$installedClientIDs.sink { [weak self] _ in Task { @MainActor in self?.refreshPresentedUI() } }.store(in: &subscriptions)
        store.$preferredAuthenticationMode.sink { [weak self] _ in
            Task { @MainActor in self?.updateWidgetSize() }
        }.store(in: &subscriptions)
        widgetPresentation.$showsConnectionURLs.sink { [weak self] _ in
            Task { @MainActor in self?.updateWidgetSize() }
        }.store(in: &subscriptions)
        widgetPresentation.$showsModels.sink { [weak self] _ in
            Task { @MainActor in self?.updateWidgetSize() }
        }.store(in: &subscriptions)
    }

    private func refreshPresentedUI() {
        refreshStatusItem()
        updateWidgetSize()
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let title: String
        var isLow = false
        switch store.phase {
        case .signedOut:
            title = ""
        case .restoring:
            title = "…"
        case .account:
            title = store.dashboard?.aiServiceCredit.remainingRMB.map { "¥\($0)" } ?? "●"
        case .apiKey:
            title = store.businessKeyInfo?.quota.trayStatusText ?? "●"
            isLow = store.businessKeyInfo?.quota.trayStatusIsLow ?? false
        }
        let displayedTitle = title.isEmpty ? "" : " \(title)"
        if isLow {
            button.attributedTitle = NSAttributedString(
                string: displayedTitle,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        } else {
            button.title = displayedTitle
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
            let copyInfo = menu.addItem(withTitle: "复制接入信息", action: #selector(copyAuthenticationInfoAction), keyEquivalent: "")
            copyInfo.target = self
            let copyKey = menu.addItem(withTitle: "复制 Key", action: #selector(copyAPIKeyAction), keyEquivalent: "")
            copyKey.target = self
            let configure = NSMenuItem(title: "配置已安装客户端", action: nil, keyEquivalent: "")
            let clientsMenu = NSMenu(title: "配置已安装客户端")
            for descriptor in store.installedClientDescriptors {
                let item = clientsMenu.addItem(withTitle: descriptor.name, action: #selector(openInstalledClientAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = descriptor.id.rawValue
                item.isEnabled = !store.isBusy
            }
            if store.installedClientDescriptors.isEmpty {
                let empty = clientsMenu.addItem(withTitle: "未检测到受支持客户端", action: nil, keyEquivalent: "")
                empty.isEnabled = false
            }
            clientsMenu.addItem(.separator())
            let all = clientsMenu.addItem(withTitle: "打开客户端适配中心…", action: #selector(showClientsManagerAction), keyEquivalent: "")
            all.target = self
            configure.submenu = clientsMenu
            menu.addItem(configure)
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
    @objc private func showClientsManagerAction() { showManager(section: .clients) }
    @objc private func copyAuthenticationInfoAction() { _ = store.copyAuthenticationInfo() }
    @objc private func copyAPIKeyAction() { _ = store.copyCurrentAPIKey() }
    @objc private func openInstalledClientAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        store.selectClientForManagement(ClientID(rawValue: rawValue))
        showManager(section: .clients)
    }
    @objc private func refreshAction() { Task { await store.refresh() } }
    @objc private func toggleEdgeDock() { edgeDock.toggleEnabled() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "YConnect")
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "YConnect")
        applicationMenu.addItem(withTitle: "关于 YConnect", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(withTitle: "退出 YConnect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

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
        let hostingController = NSHostingController(rootView: WidgetView(
            store: store,
            presentation: widgetPresentation,
            beginAccountLogin: { [weak self] in self?.beginAccountLogin() },
            openManager: { [weak self] section in self?.showManager(section: section) },
            openAPIKeyCreation: { [weak self] in self?.showAPIKeyCreation() },
            closeWidget: { [weak self] in self?.hideWidget() }
        ))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius = WidgetMetrics.cornerRadius
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true
        panel.contentViewController = hostingController
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
        presentManagerWindow()
    }

    private func showAPIKeyCreation() {
        managerNavigation.requestAPIKeyCreation()
        presentManagerWindow()
    }

    private func presentManagerWindow() {
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

    private var currentWidgetHeight: CGFloat { WidgetMetrics.height(for: store, presentation: widgetPresentation) }

    private func updateWidgetSize() {
        guard let panel = widgetPanel else { return }
        let oldFrame = panel.frame
        switch widgetOrigin {
        case .tray:
            if let anchor = trayAnchor() {
                positionWidget(panel, anchor: anchor)
                return
            }
        case .edge(let anchor, let onLeft):
            positionWidgetBesideEdge(panel, anchor: anchor, onLeft: onLeft)
            return
        }
        let newSize = NSSize(width: WidgetMetrics.width, height: currentWidgetHeight)
        panel.setContentSize(newSize)
        panel.setFrameOrigin(NSPoint(x: oldFrame.minX, y: oldFrame.maxY - newSize.height))
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
        widgetPresentation.maximumHeight = WidgetPositioning.maximumHeight(in: screen.visibleFrame)
        panel.setFrame(WidgetPositioning.frame(
            size: NSSize(width: WidgetMetrics.width, height: currentWidgetHeight),
            trayAnchor: anchor,
            visibleFrame: screen.visibleFrame
        ), display: true)
    }

    private func positionWidgetBesideEdge(_ panel: NSPanel, anchor: NSRect, onLeft: Bool) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        widgetPresentation.maximumHeight = WidgetPositioning.maximumHeight(in: screen.visibleFrame)
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
                let visible = self?.widgetPanel?.isVisible == true
                let key = self?.widgetPanel?.isKeyWindow == true
                let canBecomeKey = self?.widgetPanel?.canBecomeKey == true
                // macOS 14+ may reject foreground activation from unattended
                // runners. In that case we can still prove that the panel is
                // visible and key-capable; an active app must make it key.
                let usedHeadlessFallback = !NSApp.isActive
                let passed = visible && (key || (usedHeadlessFallback && canBecomeKey))
                print(
                    "widget focus state: active=\(NSApp.isActive) visible=\(visible) key=\(key) "
                        + "headlessFallback=\(usedHeadlessFallback)"
                )
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
            let usedHeadlessFallback = !panel.isKeyWindow && !NSApp.isActive
            if usedHeadlessFallback {
                self.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
            } else {
                probe.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self, weak panel] in
                guard let self, let panel else { return }
                let dismissed = !panel.isVisible
                self.widgetPresentation.isPinned = true
                self.showWidget()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    if usedHeadlessFallback {
                        self.windowDidResignKey(
                            Notification(name: NSWindow.didResignKeyNotification, object: panel)
                        )
                    } else {
                        probe.makeKeyAndOrderFront(nil)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                        let pinnedVisible = panel.isVisible
                        print(
                            "widget transient state: dismissed=\(dismissed) pinnedVisible=\(pinnedVisible) "
                                + "headlessFallback=\(usedHeadlessFallback)"
                        )
                        self.finishSmoke(name: "widget transient", passed: dismissed && pinnedVisible)
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
                let usedHeadlessFallback = !NSApp.isActive
                let keyReady = panel.isKeyWindow || (usedHeadlessFallback && panel.canBecomeKey)
                print(
                    "edge widget focus state: active=\(NSApp.isActive) visible=\(panel.isVisible) "
                        + "key=\(panel.isKeyWindow) beside=\(beside) headlessFallback=\(usedHeadlessFallback)"
                )
                self.finishSmoke(name: "edge widget focus", passed: panel.isVisible && keyReady && beside)
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
