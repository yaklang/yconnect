import AppKit
import Foundation
import Sparkle
import SwiftUI

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
            && ($0.count == 1 || $0.first != "0") }),
              fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.compactMap { Int($0) }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppRelease: Decodable {
    struct Asset: Decodable { let platform, architecture, kind, filename, url, sha256: String; let size: Int64 }
    let schema_version: Int
    let product, version, release_notes: String
    let release_notes_text: String?
    let assets: [Asset]

    static let base = "https://aliyun-oss.yaklang.com/yconnect"
    static func parse(_ data: Data, currentVersion: String) throws -> AppRelease? {
        guard data.count <= 524_288, let current = ReleaseVersion(currentVersion) else { throw UpdateError.invalidCatalog }
        let release = try JSONDecoder().decode(Self.self, from: data)
        guard release.schema_version == 1, release.product == "yconnect", let version = ReleaseVersion(release.version),
              release.release_notes == "https://github.com/yaklang/yconnect/releases/tag/v\(release.version)",
              (release.release_notes_text?.count ?? 0) <= 32_000 else { throw UpdateError.invalidCatalog }
        let matches = release.assets.filter { $0.platform == "darwin" && $0.architecture == "universal" && $0.kind == "dmg" }
        guard matches.count == 1, let asset = matches.first,
              asset.filename == "YConnect-\(release.version)-darwin-universal.dmg",
              asset.url == "\(base)/\(release.version)/\(asset.filename)", asset.size > 0, asset.size < 536_870_912,
              asset.sha256.count == 64, asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw UpdateError.invalidCatalog }
        return version > current ? release : nil
    }
}

enum UpdateError: LocalizedError {
    case invalidCatalog, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidCatalog: return "更新信息校验失败，已保留当前版本。请稍后重试。"
        case .unavailable: return "暂时无法连接更新服务，请检查网络后重试。"
        }
    }
}

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let preview = AppUpdates(enabled: false)
    static func availablePreview() -> AppUpdates {
        let updates = AppUpdates(enabled: false)
        updates.release = AppRelease(schema_version: 1, product: "yconnect", version: "0.6.0",
            release_notes: "", release_notes_text: "更新状态演示：优化连接体验，完善异常提示。", assets: [])
        updates.message = "这是界面演示，不会下载或安装。正式版点击后会显示下载进度和安装步骤。"
        return updates
    }
    @Published private(set) var release: AppRelease?
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var message: String?
    @Published private(set) var lastCheck: Date?
    @Published var automaticallyChecks: Bool {
        didSet { if enabled { defaults.set(automaticallyChecks, forKey: "YConnectCheckUpdates") } }
    }
    let enabled: Bool
    var canInstall: () -> Bool = { true }
    var reportError: (String) -> Void = { _ in }
    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?
    private var timer: Task<Void, Never>?

    init(enabled: Bool, defaults: UserDefaults = .standard) {
        self.enabled = enabled
        self.defaults = defaults
        automaticallyChecks = defaults.object(forKey: "YConnectCheckUpdates") as? Bool ?? true
        super.init()
        if !enabled { message = "开发与演示环境不检查或安装正式更新。" }
    }

    func start() {
        guard enabled, timer == nil else { return }
        // Only our quiet catalog check runs automatically. Sparkle performs the
        // signed download/replacement only after an explicit click.
        let driver = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try driver.updater.start()
            driver.updater.automaticallyChecksForUpdates = false
            driver.updater.automaticallyDownloadsUpdates = false
            controller = driver
        } catch { message = "更新组件启动失败：\(error.localizedDescription)；可使用手动下载。" }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticallyChecks { await self.check() }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    func check() async {
        guard enabled, !checking, !installing else { return }
        checking = true
        defer { checking = false }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: AppRelease.base + "/latest.json")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == request.url,
                  response.expectedContentLength <= 524_288 else { throw UpdateError.unavailable }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 524_288 else { throw UpdateError.invalidCatalog }
                data.append(byte)
            }
            release = try AppRelease.parse(data, currentVersion: BuildInfo.version)
            lastCheck = Date()
            message = release == nil ? "已经是最新版本。" : "新版本已就绪，下载后可安装并重新打开。"
        } catch {
            message = (error as? UpdateError)?.localizedDescription ?? UpdateError.unavailable.localizedDescription
        }
    }

    func install() {
        guard enabled, !installing else { return }
        guard canInstall() else { message = "请先完成当前操作，再更新客户端。"; reportError(message!); return }
        guard let controller else { message = "更新组件不可用，请使用手动下载。"; reportError(message!); return }
        installing = true
        message = "请在更新窗口中下载并安装；可以取消，继续使用当前版本。"
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        installing = false
        if let error { message = "更新未完成：\(error.localizedDescription)；当前版本仍可使用，可重试或手动下载。" }
    }

    func stop() { timer?.cancel(); timer = nil }
    func openDownloads() {
        let version = release?.version ?? BuildInfo.version
        let url = URL(string: "\(AppRelease.base)/\(version)/YConnect-\(version)-darwin-universal.dmg")!
        if !NSWorkspace.shared.open(url) { reportError("无法打开浏览器，请前往 yakcool.com 下载客户端。") }
    }
}

struct UpdateBadge: View {
    @ObservedObject var updates: AppUpdates
    var body: some View {
        if updates.release != nil {
            Button(updates.installing ? "更新中" : "新版本") { updates.install() }
                .font(.system(size: 10, weight: .semibold)).buttonStyle(.borderedProminent)
                .tint(Brand.accent).controlSize(.mini).disabled(updates.installing)
                .help("更新至 \(updates.release?.version ?? "")")
                .accessibilityIdentifier("app-update-badge")
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var updates: AppUpdates
    var body: some View {
        GroupBox("软件更新") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Y CONNECT \(BuildInfo.version)").fontWeight(.semibold)
                    Spacer()
                    if let version = updates.release?.version { Text("新版本 \(version)").foregroundStyle(Brand.accent) }
                }
                if let notes = updates.release?.release_notes_text { Text(notes).font(.system(size: 12)).textSelection(.enabled) }
                Text(updates.message ?? "发现新版本时在界面提示，由你决定何时安装。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(updates.checking ? "正在检查…" : "检查更新") { Task { await updates.check() } }
                        .disabled(!updates.enabled || updates.checking || updates.installing)
                    if updates.release != nil { Button("下载并更新") { updates.install() }.disabled(updates.installing) }
                    Button("手动下载") { updates.openDownloads() }
                }
                Toggle("自动检查新版本", isOn: $updates.automaticallyChecks).disabled(!updates.enabled)
                Text("不会自动安装或强制打断工作；账户与客户端配置保留。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let date = updates.lastCheck { Text("上次检查：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 8)
        }
    }
}
