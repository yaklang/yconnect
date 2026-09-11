import AppKit
import SwiftUI
import XCTest
@testable import YConnect

final class ClientSelectionCardTests: XCTestCase {
    @MainActor
    func testEveryClientKeepsTheSameHeightAndAcceptsClicksInEmptySpace() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yconnect-card-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let clients = try DefaultClientConfigurationRegistry.make(environment: .preview(at: scratch)).descriptors

        for width in [145.0, 160.0, 230.0] {
            for client in clients {
                for selected in [false, true] {
                    var clicks = 0
                    let hosting = NSHostingView(rootView: ClientSelectionCard(client: client, isSelected: selected) { clicks += 1 }.frame(width: width))
                    XCTAssertEqual(hosting.fittingSize.height, 96, accuracy: 0.5, client.name)
                    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: 96), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = hosting
                    window.orderFrontRegardless()
                    hosting.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))

                    // Each edge midpoint is inside padding, away from any text/icon.
                    for point in [NSPoint(x: 3, y: 48), NSPoint(x: width - 3, y: 48), NSPoint(x: width / 2, y: 3), NSPoint(x: width / 2, y: 93)] {
                        let before = clicks
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                            window.sendEvent(event)
                        }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                        XCTAssertEqual(clicks, before + 1, "\(client.name), width \(width), selected \(selected), point \(point)")
                    }
                    window.close()
                }
            }
        }
    }
}
