import Foundation
import XCTest
@testable import YConnect

final class ClientInstallationTests: XCTestCase {
    func testDetectsOnlyMatchingExecutableClients() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let executables: Set<String> = [
            "/Users/fixture/.opencode/bin/opencode",
            "/Users/fixture/.local/bin/claude",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        let detector = DefaultClientInstallationDetector(
            homeDirectory: home,
            path: "/Users/fixture/.local/bin:/usr/bin",
            applicationDirectories: [URL(fileURLWithPath: "/Applications", isDirectory: true)],
            fileExists: { _ in false },
            isExecutable: { executables.contains($0) }
        )

        XCTAssertEqual(
            detector.installedClientIDs(from: descriptors([.openCode, .pi, .claudeCode, .codex, .grokBuild])),
            [.openCode, .claudeCode, .codex]
        )
    }

    func testGrokBotApplicationDoesNotMasqueradeAsGrokBuild() {
        let detector = DefaultClientInstallationDetector(
            homeDirectory: URL(fileURLWithPath: "/Users/fixture", isDirectory: true),
            path: "",
            applicationDirectories: [URL(fileURLWithPath: "/Applications", isDirectory: true)],
            fileExists: { $0 == "/Applications/Grok Bot.app" },
            isExecutable: { _ in false }
        )

        XCTAssertEqual(detector.installedClientIDs(from: descriptors([.grokBuild])), [])
    }

    func testDetectsClaudeDesktopByExactApplicationName() {
        let detector = DefaultClientInstallationDetector(
            homeDirectory: URL(fileURLWithPath: "/Users/fixture", isDirectory: true),
            path: "",
            applicationDirectories: [URL(fileURLWithPath: "/Applications", isDirectory: true)],
            fileExists: { $0 == "/Applications/Claude.app" },
            isExecutable: { _ in false }
        )

        XCTAssertEqual(detector.installedClientIDs(from: descriptors([.claudeDesktop, .grokBuild])), [.claudeDesktop])
    }

    func testWebLoginAllowsOnlyHTTPSOnApprovedHosts() {
        XCTAssertTrue(AccountLoginCoordinator.isAllowedLoginURL(URL(string: "https://yakcool.com/login")!))
        XCTAssertTrue(AccountLoginCoordinator.isAllowedLoginURL(URL(string: "https://open.weixin.qq.com/connect/qrconnect")!))
        XCTAssertFalse(AccountLoginCoordinator.isAllowedLoginURL(URL(string: "http://yakcool.com/login")!))
        XCTAssertFalse(AccountLoginCoordinator.isAllowedLoginURL(URL(string: "https://yakcool.com.evil.invalid/login")!))
    }

    func testWebLoginBacksOffTheSameRejectedSessionButImmediatelyChecksANewOne() throws {
        let first = try TestFixture.cookie(value: "fake-rejected-session")
        let second = try TestFixture.cookie(value: "fake-new-session")
        let start = Date(timeIntervalSince1970: 10_000)
        var gate = AccountLoginVerificationGate()

        XCTAssertTrue(gate.shouldAttempt(cookies: [first], now: start))
        gate.recordFailure(cookies: [first], now: start)
        XCTAssertFalse(gate.shouldAttempt(cookies: [first], now: start.addingTimeInterval(7.9)))
        XCTAssertTrue(gate.shouldAttempt(cookies: [first], now: start.addingTimeInterval(8)))
        XCTAssertTrue(gate.shouldAttempt(cookies: [second], now: start.addingTimeInterval(1)))
    }

    func testWebLoginUsesStableWaitingTextForExpectedUnauthenticatedResponses() {
        let message = AccountLoginStatusText.afterVerificationFailure(
            YConnectError.server(status: 401, code: "unauthorized", message: "尚未登录")
        )

        XCTAssertEqual(message, AccountLoginStatusText.waiting)
        XCTAssertFalse(message.contains("失败"))
        XCTAssertFalse(message.contains("尚未登录"))
    }

    private func descriptors(_ ids: [ClientID]) -> [ClientDescriptor] {
        ids.map {
            ClientDescriptor(
                id: $0,
                name: $0.rawValue,
                shortName: $0.rawValue,
                symbol: "terminal",
                summary: "fixture",
                supportedProtocols: [.responses],
                configurationPath: "/tmp/fixture",
                restartNote: "",
                availability: .ready
            )
        }
    }
}
