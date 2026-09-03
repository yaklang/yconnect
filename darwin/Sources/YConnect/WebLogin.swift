import AppKit
import WebKit

struct AccountLoginVerificationGate {
    static let retryDelay: TimeInterval = 8

    private var rejectedCookies: [StoredWebCookie]?
    private var retryAfter = Date.distantPast

    mutating func shouldAttempt(cookies: [StoredWebCookie], now: Date = Date()) -> Bool {
        let cookies = canonical(cookies)
        guard !cookies.isEmpty else {
            reset()
            return false
        }
        guard cookies == rejectedCookies else { return true }
        return now >= retryAfter
    }

    func isRepeatedRejectedSession(_ cookies: [StoredWebCookie]) -> Bool {
        canonical(cookies) == rejectedCookies
    }

    mutating func recordFailure(
        cookies: [StoredWebCookie],
        now: Date = Date(),
        retryDelay: TimeInterval = Self.retryDelay
    ) {
        rejectedCookies = canonical(cookies)
        retryAfter = now.addingTimeInterval(retryDelay)
    }

    mutating func reset() {
        rejectedCookies = nil
        retryAfter = .distantPast
    }

    private func canonical(_ cookies: [StoredWebCookie]) -> [StoredWebCookie] {
        cookies.sorted {
            ($0.domain, $0.path, $0.name, $0.value) < ($1.domain, $1.path, $1.name, $1.value)
        }
    }
}

enum AccountLoginStatusText {
    static let loading = "正在加载安全登录页面…"
    static let waiting = "等待扫码登录，成功后会自动连接"
    static let verifying = "检测到新的用户会话，正在安全验证…"

    static func afterVerificationFailure(_ error: Error) -> String {
        if case .server(let status, _, _) = error as? YConnectError,
           status == 401 || status == 403 {
            return waiting
        }
        if case .invalidCredential = error as? YConnectError {
            return waiting
        }
        return "暂时无法确认登录状态，YConnect 会自动重试"
    }
}

@MainActor
final class AccountLoginCoordinator: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let api: YakCoolAPI
    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var timer: Timer?
    private var isVerifying = false
    private var verificationGate = AccountLoginVerificationGate()
    private var completion: (([StoredWebCookie]) async throws -> Void)?

    init(api: YakCoolAPI = YakCoolAPI()) {
        self.api = api
        super.init()
    }

    func present(completion: @escaping ([StoredWebCookie]) async throws -> Void) {
        self.completion = completion
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "qrcode.viewfinder", accessibilityDescription: "扫码登录")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        icon.contentTintColor = Brand.accentNS
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let title = NSTextField(labelWithString: "在 YConnect 内登录 YakCool")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "使用微信扫描下方官方二维码，无需切换到浏览器")
        subtitle.font = .systemFont(ofSize: 11.5, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3

        let host = NSTextField(labelWithString: "  🔒  yakcool.com · 微信官方登录  ")
        host.font = .systemFont(ofSize: 10.5, weight: .medium)
        host.textColor = .secondaryLabelColor
        host.drawsBackground = true
        host.backgroundColor = .controlBackgroundColor
        host.isBezeled = true
        host.bezelStyle = .roundedBezel

        let status = NSTextField(labelWithString: AccountLoginStatusText.loading)
        status.font = .systemFont(ofSize: 11.5, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let reload = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reload.bezelStyle = .rounded
        reload.controlSize = .small

        let header = NSStackView(views: [icon, titles, NSView(), host, reload])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)
        header.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "安全")!), status])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 7
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 17, bottom: 10, right: 17)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let webContainer = NSView()
        webContainer.wantsLayer = true
        webContainer.layer?.cornerRadius = 12
        webContainer.layer?.borderWidth = 1
        webContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        webContainer.layer?.masksToBounds = true
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)

        let content = NSView()
        content.addSubview(header)
        content.addSubview(webContainer)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 70),
            webContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            webContainer.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 42),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "YConnect · YakCool 扫码登录"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 720, height: 620)
        window.center()
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        self.webView = webView
        statusLabel = status

        // A previous WebKit session must never be silently promoted to the
        // Keychain. Remove only the public YakCool session, preserving unrelated
        // website data and the QR provider's cookies.
        configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let stale = cookies.filter {
                StoredWebCookie.allowedNames.contains($0.name)
                    && StoredWebCookie.isAllowedDomain($0.domain)
            }
            let group = DispatchGroup()
            for cookie in stale {
                group.enter()
                configuration.websiteDataStore.httpCookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in self?.loadLoginPage() }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(loginTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        webView = nil
        statusLabel = nil
        completion = nil
        isVerifying = false
        verificationGate.reset()
    }

    @objc private func reloadPage() { loadLoginPage() }
    @objc private func loginTimerFired() { inspectCookies() }

    private func loadLoginPage() {
        guard let url = URL(string: "https://yakcool.com/login") else { return }
        verificationGate.reset()
        statusLabel?.stringValue = AccountLoginStatusText.loading
        webView?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
    }

    private func showBlockedNavigation(_ url: URL) {
        statusLabel?.stringValue = "已阻止离开 YakCool 登录流程：\(url.host ?? url.scheme ?? "未知地址")"
    }

    private func inspectCookies() {
        guard !isVerifying, let webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.isVerifying else { return }
                let stored = cookies.compactMap(StoredWebCookie.init(cookie:)).filter { !$0.isExpired }
                let repeatedSession = self.verificationGate.isRepeatedRejectedSession(stored)
                guard self.verificationGate.shouldAttempt(cookies: stored) else { return }
                self.isVerifying = true
                if !repeatedSession {
                    self.statusLabel?.stringValue = AccountLoginStatusText.verifying
                }
                do {
                    _ = try await self.api.verifyWebCookies(stored)
                    if let completion = self.completion { try await completion(stored) }
                    self.dismiss()
                } catch {
                    self.verificationGate.recordFailure(cookies: stored)
                    self.statusLabel?.stringValue = AccountLoginStatusText.afterVerificationFailure(error)
                    self.isVerifying = false
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if !isVerifying {
                statusLabel?.stringValue = AccountLoginStatusText.waiting
            }
            inspectCookies()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        guard Self.isAllowedLoginURL(url) else {
            MainActor.assumeIsolated { showBlockedNavigation(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           Self.isAllowedLoginURL(url) {
            _ = MainActor.assumeIsolated { webView.load(navigationAction.request) }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) { dismiss() }

    nonisolated static func isAllowedLoginURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && isAllowedLoginHost(url.host)
    }

    nonisolated static func isAllowedLoginHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "yakcool.com"
            || host.hasSuffix(".yakcool.com")
            || host == "yaklang.com"
            || host.hasSuffix(".yaklang.com")
            || host == "weixin.qq.com"
            || host.hasSuffix(".weixin.qq.com")
            || host == "open.weixin.qq.com"
            || host == "wx.qq.com"
            || host.hasSuffix(".wx.qq.com")
    }
}
