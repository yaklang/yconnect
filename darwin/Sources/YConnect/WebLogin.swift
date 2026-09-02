import AppKit
import WebKit

@MainActor
final class AccountLoginCoordinator: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let api: YakCoolAPI
    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var timer: Timer?
    private var isVerifying = false
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

        let status = NSTextField(labelWithString: "请在 YakCool 官方页面使用微信扫码登录。YConnect 只读取登录成功后的用户会话。")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let reload = NSButton(title: "重新加载", target: self, action: #selector(reloadPage))
        reload.bezelStyle = .rounded
        reload.controlSize = .small

        let header = NSStackView(views: [status, NSView(), reload])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(header)
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "登录 YakCool"
        window.minSize = NSSize(width: 760, height: 620)
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
    }

    @objc private func reloadPage() { loadLoginPage() }
    @objc private func loginTimerFired() { inspectCookies() }

    private func loadLoginPage() {
        guard let url = URL(string: "https://yakcool.com/login") else { return }
        webView?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
    }

    private func inspectCookies() {
        guard !isVerifying, let webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.isVerifying else { return }
                let stored = cookies.compactMap(StoredWebCookie.init(cookie:)).filter { !$0.isExpired }
                guard !stored.isEmpty else { return }
                self.isVerifying = true
                self.statusLabel?.stringValue = "检测到用户会话，正在向 YakCool 验证…"
                do {
                    _ = try await self.api.verifyWebCookies(stored)
                    if let completion = self.completion { try await completion(stored) }
                    self.dismiss()
                } catch {
                    self.statusLabel?.stringValue = "会话验证失败：\(error.localizedDescription)"
                    self.isVerifying = false
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { inspectCookies() }
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
        guard url.scheme?.lowercased() == "https", Self.isAllowedLoginHost(url.host) else {
            if navigationAction.targetFrame?.isMainFrame != false {
                _ = MainActor.assumeIsolated { NSWorkspace.shared.open(url) }
            }
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
           url.scheme?.lowercased() == "https",
           Self.isAllowedLoginHost(url.host) {
            _ = MainActor.assumeIsolated { webView.load(navigationAction.request) }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) { dismiss() }

    nonisolated private static func isAllowedLoginHost(_ host: String?) -> Bool {
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
