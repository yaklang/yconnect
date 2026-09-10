import AppKit
import CoreServices
import XCTest
@testable import YConnect

final class StartupTests: XCTestCase {
    func testManualAndLoginLaunchesHaveDifferentPresentation() {
        XCTAssertEqual(StartupPresentation.surface(arguments: [], loginItem: false), .widget)
        XCTAssertEqual(StartupPresentation.surface(arguments: [], loginItem: true), .background)
        XCTAssertEqual(StartupPresentation.surface(arguments: ["--show-widget"], loginItem: true), .widget)
        XCTAssertEqual(StartupPresentation.surface(arguments: ["--show-manager"], loginItem: true), .manager)
    }

    func testLoginAppleEventIsRecognized() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(StartupPresentation.isLoginItem(event: event))
        XCTAssertFalse(StartupPresentation.isLoginItem(event: nil))
    }

    @MainActor
    func testRegistryFailureKeepsAccountAndWidgetAvailable() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YConnectStore(environment: .preview(at: root),
            clientRegistryFactory: { throw CocoaError(.fileWriteNoPermission) }, preview: true)
        XCTAssertNotNil(store.startupWarning)
        XCTAssertTrue(store.clientDescriptors.isEmpty)
        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertEqual(store.selectedClientDescriptor.availability, .planned)
        let presentation = WidgetPresentationState()
        XCTAssertGreaterThan(WidgetMetrics.height(for: store, presentation: presentation), WidgetMetrics.signedOutAccountHeight)
        presentation.maximumHeight = 300
        XCTAssertTrue(WidgetMetrics.requiresVerticalScrolling(for: store, presentation: presentation))
        await store.restoreSession()
        XCTAssertNotNil(store.startupWarning, "Session restoration must not erase a startup failure")
    }

    @MainActor
    func testInterruptedRunIsReportedOnceAndActiveRunIsNotMistakenForCrash() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = StartupDiagnostics(directory: root, processID: 100, isProcessRunning: { _ in false })
        first.record(.clientRegistryUnavailable)
        first.record(.menuBarReady)
        let concurrent = StartupDiagnostics(directory: root, processID: 101, isProcessRunning: { $0 == 100 })
        XCTAssertNil(concurrent.previousInterruptedStage)
        concurrent.record(.cleanExit)
        let next = StartupDiagnostics(directory: root, processID: 102, isProcessRunning: { _ in false })
        XCTAssertEqual(next.previousInterruptedStage, .menuBarReady)
        next.record(.cleanExit)
        let last = StartupDiagnostics(directory: root, processID: 103, isProcessRunning: { _ in false })
        XCTAssertNil(last.previousInterruptedStage)
        last.record(.cleanExit)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let reports = try urls.map { try JSONDecoder().decode(StartupDiagnostics.Report.self, from: Data(contentsOf: $0)) }
        XCTAssertTrue(reports.contains { $0.issues == [.clientRegistryUnavailable] })
        for url in urls {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(Set(fields.keys), Set(["processID", "startedAt", "updatedAt", "version", "build", "system", "architecture", "stage", "issues", "finished", "acknowledged"]))
        }
    }

    @MainActor
    func testUnreadableDiagnosticDirectoryProducesWarningWithoutThrowing() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("file blocks directory creation".utf8).write(to: root)
        let diagnostics = StartupDiagnostics(directory: root)
        XCTAssertNotNil(diagnostics.storageWarning)
        diagnostics.record(.widgetVisible)
        XCTAssertNotNil(diagnostics.storageWarning)
    }

    @MainActor
    func testCorruptAndSymlinkedReportsDoNotPreventStartup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = root.appendingPathComponent("startup-corrupt.json")
        try Data("not json".utf8).write(to: corrupt)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("startup-link.json"), withDestinationURL: corrupt)
        let diagnostics = StartupDiagnostics(directory: root, isProcessRunning: { _ in false })
        XCTAssertNil(diagnostics.storageWarning)
        XCTAssertNil(diagnostics.previousInterruptedStage)
        diagnostics.record(.cleanExit)
        XCTAssertEqual(try String(contentsOf: corrupt), "not json")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("YConnectStartupTests-\(UUID().uuidString)")
    }
}
