import AppKit
import Combine
import QuartzCore

enum EdgeDockPreferences {
    static let defaultYPercent = 58
    private static let enabledKey = "yconnect.edge-dock.enabled"
    private static let leftKey = "yconnect.edge-dock.left"
    private static let yPercentKey = "yconnect.edge-dock.y-percent"

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isOnLeft: Bool {
        get { UserDefaults.standard.bool(forKey: leftKey) }
        set { UserDefaults.standard.set(newValue, forKey: leftKey) }
    }

    static var yPercent: Int {
        get {
            guard UserDefaults.standard.object(forKey: yPercentKey) != nil else { return defaultYPercent }
            return min(95, max(5, UserDefaults.standard.integer(forKey: yPercentKey)))
        }
        set { UserDefaults.standard.set(min(95, max(5, newValue)), forKey: yPercentKey) }
    }

    static func resetPosition() {
        isOnLeft = false
        yPercent = defaultYPercent
    }
}

enum EdgeDockPositioning {
    static let tabSize = NSSize(width: 30, height: 112)
    static let screenMargin: CGFloat = 4

    static func frame(screenFrame: NSRect, onLeft: Bool, yPercent: Int) -> NSRect {
        let percent = CGFloat(min(95, max(5, yPercent))) / 100
        let x = onLeft ? screenFrame.minX : screenFrame.maxX - tabSize.width
        var y = screenFrame.minY + screenFrame.height * percent - tabSize.height / 2
        y = max(screenFrame.minY + screenMargin, min(y, screenFrame.maxY - tabSize.height - screenMargin))
        return NSRect(origin: NSPoint(x: x, y: y), size: tabSize)
    }
}

enum EdgeWidgetPositioning {
    static let gap: CGFloat = 8
    static let screenMargin: CGFloat = 8

    static func frame(size: NSSize, tabFrame: NSRect, onLeft: Bool, visibleFrame: NSRect) -> NSRect {
        let preferredX = onLeft ? tabFrame.maxX + gap : tabFrame.minX - size.width - gap
        let x = max(visibleFrame.minX + screenMargin, min(preferredX, visibleFrame.maxX - size.width - screenMargin))
        let preferredY = tabFrame.midY - size.height / 2
        let y = max(visibleFrame.minY + screenMargin, min(preferredY, visibleFrame.maxY - size.height - screenMargin))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

enum EdgeDockVisibilityPolicy {
    static func shouldShowQuickActions(widgetPresented: Bool, tabHovered: Bool) -> Bool {
        tabHovered && !widgetPresented
    }
}

@MainActor
final class YConnectEdgeDockController: NSObject {
    private let store: YConnectStore
    private let onOpenWidget: (NSRect, Bool) -> Void
    private let onOpenManager: (ManagerSection) -> Void
    private var tabWindow: NSPanel?
    private var stripWindow: NSPanel?
    private var stripView: EdgeDockStripView?
    private var tabHovered = false
    private var stripHovered = false
    private var widgetPresented = false
    private var hideTask: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []

    init(
        store: YConnectStore,
        onOpenWidget: @escaping (NSRect, Bool) -> Void = { _, _ in },
        onOpenManager: @escaping (ManagerSection) -> Void = { _ in }
    ) {
        self.store = store
        self.onOpenWidget = onOpenWidget
        self.onOpenManager = onOpenManager
        super.init()
        store.$isBusy.sink { [weak self] _ in
            Task { @MainActor in self?.refreshActionState() }
        }.store(in: &subscriptions)
        store.$phase.sink { [weak self] _ in
            Task { @MainActor in self?.refreshActionState() }
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func update() {
        if EdgeDockPreferences.isEnabled {
            showTab()
            repositionTab()
        } else { hide() }
    }

    func setEnabled(_ enabled: Bool) {
        EdgeDockPreferences.isEnabled = enabled
        update()
    }

    func toggleEnabled() { setEnabled(!EdgeDockPreferences.isEnabled) }

    func setWidgetPresented(_ presented: Bool) {
        widgetPresented = presented
        if presented { closeStrip() }
        else if EdgeDockVisibilityPolicy.shouldShowQuickActions(widgetPresented: false, tabHovered: tabHovered) { showStrip() }
    }

    @discardableResult
    func openWidgetForSmokeTest() -> NSRect? {
        showTab()
        guard let frame = tabWindow?.frame else { return nil }
        openWidget()
        return frame
    }

    private func showTab() {
        guard tabWindow == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = tabFrame(on: screen)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let tab = EdgeDockTabView(frame: NSRect(origin: .zero, size: frame.size))
        tab.onLeft = EdgeDockPreferences.isOnLeft
        tab.onClick = { [weak self] in self?.openWidget() }
        tab.onHoverChanged = { [weak self] hovered in self?.setTabHovered(hovered) }
        tab.onRightClick = { [weak self] event in self?.showContextMenu(with: event) }
        tab.onDragMove = { [weak self] y in self?.moveTab(to: y) }
        tab.onDragEnd = { [weak self] in self?.rememberTabPosition() }
        panel.contentView = tab
        panel.orderFrontRegardless()
        tabWindow = panel
    }

    private func tabFrame(on screen: NSScreen) -> NSRect {
        EdgeDockPositioning.frame(
            screenFrame: screen.frame,
            onLeft: EdgeDockPreferences.isOnLeft,
            yPercent: EdgeDockPreferences.yPercent
        )
    }

    private func repositionTab() {
        guard let panel = tabWindow,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let target = tabFrame(on: screen)
        (panel.contentView as? EdgeDockTabView)?.onLeft = EdgeDockPreferences.isOnLeft
        panel.setFrame(target, display: true, animate: false)
        closeStrip()
    }

    private func moveTab(to proposedY: CGFloat) {
        guard let panel = tabWindow, let screen = panel.screen ?? NSScreen.main else { return }
        let y = max(
            screen.frame.minY + EdgeDockPositioning.screenMargin,
            min(proposedY, screen.frame.maxY - EdgeDockPositioning.tabSize.height - EdgeDockPositioning.screenMargin)
        )
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: y))
        closeStrip()
    }

    private func rememberTabPosition() {
        guard let panel = tabWindow, let screen = panel.screen ?? NSScreen.main else { return }
        EdgeDockPreferences.yPercent = Int(round((panel.frame.midY - screen.frame.minY) / screen.frame.height * 100))
    }

    private func setTabHovered(_ hovered: Bool) {
        tabHovered = hovered
        if EdgeDockVisibilityPolicy.shouldShowQuickActions(widgetPresented: widgetPresented, tabHovered: hovered) { showStrip() }
        scheduleStripHide()
    }

    private func setStripHovered(_ hovered: Bool) {
        stripHovered = hovered
        scheduleStripHide()
    }

    private func openWidget() {
        guard let tabWindow else { return }
        widgetPresented = true
        closeStrip()
        onOpenWidget(tabWindow.frame, EdgeDockPreferences.isOnLeft)
    }

    private func showStrip() {
        guard !widgetPresented, stripWindow == nil, let tabWindow else { return }
        let view = EdgeDockStripView(frame: NSRect(x: 0, y: 0, width: 122, height: 78))
        view.onHoverChanged = { [weak self] hovered in self?.setStripHovered(hovered) }
        view.onConfigure = { [weak self] in
            self?.closeStrip()
            self?.onOpenManager(.openCode)
        }
        view.onCopy = { [weak self] in
            _ = self?.store.copyCurrentAPIKey()
            self?.refreshActionState()
        }
        view.update(authenticated: store.isAuthenticated, busy: store.isBusy)

        let onLeft = EdgeDockPreferences.isOnLeft
        let tabFrame = tabWindow.frame
        let frame = NSRect(
            x: onLeft ? tabFrame.maxX + 6 : tabFrame.minX - view.frame.width - 6,
            y: tabFrame.midY - view.frame.height / 2,
            width: view.frame.width,
            height: view.frame.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
        stripView = view
        stripWindow = panel
    }

    private func refreshActionState() {
        stripView?.update(authenticated: store.isAuthenticated, busy: store.isBusy)
    }

    private func scheduleStripHide() {
        hideTask?.cancel()
        hideTask = nil
        guard stripWindow != nil, !tabHovered, !stripHovered else { return }
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.tabHovered, !self.stripHovered else { return }
                self.closeStrip()
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    private func closeStrip() {
        hideTask?.cancel()
        hideTask = nil
        stripWindow?.orderOut(nil)
        stripWindow = nil
        stripView = nil
        stripHovered = false
    }

    private func hide() {
        closeStrip()
        tabWindow?.orderOut(nil)
        tabWindow = nil
    }

    private func showContextMenu(with event: NSEvent) {
        guard let tab = tabWindow?.contentView else { return }
        let menu = NSMenu()
        let left = NSMenuItem(title: "贴屏幕左缘", action: #selector(dockLeft), keyEquivalent: "")
        left.target = self
        left.state = EdgeDockPreferences.isOnLeft ? .on : .off
        menu.addItem(left)
        let right = NSMenuItem(title: "贴屏幕右缘", action: #selector(dockRight), keyEquivalent: "")
        right.target = self
        right.state = EdgeDockPreferences.isOnLeft ? .off : .on
        menu.addItem(right)
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "恢复默认位置", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let hide = NSMenuItem(title: "隐藏边缘小组件", action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: tab)
    }

    @objc private func dockLeft() { EdgeDockPreferences.isOnLeft = true; repositionTab() }
    @objc private func dockRight() { EdgeDockPreferences.isOnLeft = false; repositionTab() }
    @objc private func resetPosition() { EdgeDockPreferences.resetPosition(); repositionTab() }
    @objc private func hideFromMenu() { setEnabled(false) }
    @objc private func screenParametersChanged() { repositionTab() }

    static func renderPreview(to output: URL) throws {
        let size = NSSize(width: 158, height: 112)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let strip = EdgeDockStripView(frame: NSRect(x: 0, y: 17, width: 122, height: 78))
        strip.update(authenticated: true, busy: false)
        container.addSubview(strip)
        let tab = EdgeDockTabView(frame: NSRect(x: 128, y: 0, width: 30, height: 112))
        tab.debugSetHovered(true)
        container.addSubview(tab)
        guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            throw YConnectError.file("无法渲染边缘小组件")
        }
        container.cacheDisplay(in: container.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw YConnectError.file("无法编码边缘小组件预览")
        }
        try data.write(to: output, options: .atomic)
    }
}

private final class EdgeDockStripView: NSVisualEffectView {
    var onHoverChanged: ((Bool) -> Void)?
    var onConfigure: (() -> Void)?
    var onCopy: (() -> Void)?

    private lazy var configureButton = makeButton(title: "配置 OpenCode", symbol: "terminal", action: #selector(configureClicked), primary: true)
    private lazy var copyButton = makeButton(title: "复制 API Key", symbol: "doc.on.doc", action: #selector(copyClicked), primary: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        let stack = NSStackView(views: [configureButton, copyButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 7, bottom: 6, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = "YConnect 快捷操作"
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    func update(authenticated: Bool, busy: Bool) {
        configureButton.isEnabled = authenticated && !busy
        copyButton.isEnabled = authenticated && !busy
        configureButton.title = busy ? "操作进行中…" : "配置 OpenCode"
    }

    private func makeButton(title: String, symbol: String, action: Selector, primary: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.bezelStyle = .rounded
        button.controlSize = .small
        if primary { button.bezelColor = Brand.orangeNS; button.contentTintColor = .white }
        button.widthAnchor.constraint(equalToConstant: 108).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    @objc private func configureClicked() { onConfigure?() }
    @objc private func copyClicked() { onCopy?() }
}

private final class EdgeDockTabView: NSView {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragMove: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onLeft = false { didSet { if onLeft != oldValue { apply(animated: false) } } }

    private let pill = CALayer()
    private let halo = CALayer()
    private let accent = CALayer()
    private var dots: [CALayer] = []
    private var hovered = false
    private var pressed = false
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var dragMaxDistance: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        pill.cornerRadius = 7
        layer?.addSublayer(pill)
        for glow in [halo, accent] {
            glow.cornerRadius = 1.5
            glow.shadowOffset = .zero
            layer?.addSublayer(glow)
        }
        for _ in 0..<3 {
            let dot = CALayer(); dot.cornerRadius = 1.5; layer?.addSublayer(dot); dots.append(dot)
        }
        toolTip = "YConnect · 点击打开 / 上下拖动调整位置"
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); apply(animated: false) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true); onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false); onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) {
        pressed = true; dragStartMouse = NSEvent.mouseLocation; dragStartOrigin = window?.frame.origin ?? .zero; dragMaxDistance = 0
    }
    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let current = NSEvent.mouseLocation
        let dy = current.y - dragStartMouse.y
        dragMaxDistance = max(dragMaxDistance, abs(dy), abs(current.x - dragStartMouse.x))
        if dragMaxDistance > 4 { onDragMove?(dragStartOrigin.y + dy) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if dragMaxDistance <= 4 {
            if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        } else { onDragEnd?() }
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    func debugSetHovered(_ value: Bool) { setHovered(value) }
    private func setHovered(_ value: Bool) { guard hovered != value else { return }; hovered = value; apply(animated: true) }

    private func apply(animated: Bool) {
        let width: CGFloat = hovered ? 22 : 10
        let glowPadding: CGFloat = 18
        let pillRect = NSRect(x: onLeft ? -10 : bounds.maxX - width, y: glowPadding, width: width + 10, height: bounds.height - glowPadding * 2)
        let orange = Brand.orangeNS
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setDisableActions(!animated)
        pill.frame = pillRect
        pill.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(hovered ? 0.9 : 0.58).cgColor
        let inset: CGFloat = hovered ? 5 : 9
        let lineRect = NSRect(x: onLeft ? 1.5 : bounds.maxX - 4, y: pillRect.minY + inset, width: 2.5, height: pillRect.height - inset * 2)
        halo.frame = lineRect
        halo.backgroundColor = orange.withAlphaComponent(0.92).cgColor
        halo.shadowColor = orange.cgColor
        halo.shadowRadius = hovered ? 8 : 6
        halo.shadowOpacity = hovered ? 0.72 : 0.48
        accent.frame = lineRect
        accent.backgroundColor = orange.cgColor
        accent.shadowColor = orange.cgColor
        accent.shadowRadius = hovered ? 4 : 3
        accent.shadowOpacity = 1
        let centerX = onLeft ? 5 + (width - 5) / 2 : bounds.maxX - width + (width - 5) / 2
        for (index, dot) in dots.enumerated() {
            let centerY = bounds.midY + CGFloat(index - 1) * 8
            dot.frame = NSRect(x: centerX - 1.5, y: centerY - 1.5, width: 3, height: 3)
            dot.backgroundColor = orange.withAlphaComponent(0.95).cgColor
            dot.opacity = hovered ? 1 : 0
        }
        CATransaction.commit()
    }
}
