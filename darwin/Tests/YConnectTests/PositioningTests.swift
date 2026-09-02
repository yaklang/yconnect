import AppKit
import XCTest
@testable import YConnect

final class PositioningTests: XCTestCase {
    func testEdgeDockUsesRequestedSideAndVerticalPercentage() {
        let screen = NSRect(x: 100, y: 200, width: 1_000, height: 800)

        XCTAssertEqual(
            EdgeDockPositioning.frame(screenFrame: screen, onLeft: true, yPercent: 50),
            NSRect(x: 100, y: 544, width: 30, height: 112)
        )
        XCTAssertEqual(
            EdgeDockPositioning.frame(screenFrame: screen, onLeft: false, yPercent: 50),
            NSRect(x: 1_070, y: 544, width: 30, height: 112)
        )
    }

    func testEdgeDockClampsVerticalPositionInsideScreenMargins() {
        let screen = NSRect(x: -1_440, y: 100, width: 1_440, height: 900)

        XCTAssertEqual(
            EdgeDockPositioning.frame(screenFrame: screen, onLeft: true, yPercent: -100).minY,
            screen.minY + EdgeDockPositioning.screenMargin
        )
        XCTAssertEqual(
            EdgeDockPositioning.frame(screenFrame: screen, onLeft: false, yPercent: 1_000).maxY,
            screen.maxY - EdgeDockPositioning.screenMargin
        )
    }

    func testEdgeWidgetAppearsBesideEitherEdgeTab() {
        let visibleFrame = NSRect(x: 100, y: 200, width: 1_000, height: 800)
        let size = NSSize(width: 360, height: 420)
        let leftTab = NSRect(x: 100, y: 544, width: 30, height: 112)
        let rightTab = NSRect(x: 1_070, y: 544, width: 30, height: 112)

        XCTAssertEqual(
            EdgeWidgetPositioning.frame(size: size, tabFrame: leftTab, onLeft: true, visibleFrame: visibleFrame),
            NSRect(x: 138, y: 390, width: 360, height: 420)
        )
        XCTAssertEqual(
            EdgeWidgetPositioning.frame(size: size, tabFrame: rightTab, onLeft: false, visibleFrame: visibleFrame),
            NSRect(x: 702, y: 390, width: 360, height: 420)
        )
    }

    func testEdgeWidgetClampsToVisibleFrameMargins() {
        let visibleFrame = NSRect(x: 100, y: 200, width: 1_000, height: 800)
        let size = NSSize(width: 360, height: 420)
        let belowScreenTab = NSRect(x: 0, y: 0, width: 30, height: 112)
        let aboveScreenTab = NSRect(x: 2_000, y: 1_100, width: 30, height: 112)

        let lowerLeft = EdgeWidgetPositioning.frame(
            size: size,
            tabFrame: belowScreenTab,
            onLeft: true,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(lowerLeft.minX, visibleFrame.minX + EdgeWidgetPositioning.screenMargin)
        XCTAssertEqual(lowerLeft.minY, visibleFrame.minY + EdgeWidgetPositioning.screenMargin)

        let upperRight = EdgeWidgetPositioning.frame(
            size: size,
            tabFrame: aboveScreenTab,
            onLeft: false,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(upperRight.maxX, visibleFrame.maxX - EdgeWidgetPositioning.screenMargin)
        XCTAssertEqual(upperRight.maxY, visibleFrame.maxY - EdgeWidgetPositioning.screenMargin)
    }

    func testQuickActionsVisibilityTruthTable() {
        XCTAssertFalse(EdgeDockVisibilityPolicy.shouldShowQuickActions(widgetPresented: false, tabHovered: false))
        XCTAssertTrue(EdgeDockVisibilityPolicy.shouldShowQuickActions(widgetPresented: false, tabHovered: true))
        XCTAssertFalse(EdgeDockVisibilityPolicy.shouldShowQuickActions(widgetPresented: true, tabHovered: false))
        XCTAssertFalse(EdgeDockVisibilityPolicy.shouldShowQuickActions(widgetPresented: true, tabHovered: true))
    }

    func testTrayWidgetUsesPreferredFrameWhenItFits() {
        let visibleFrame = NSRect(x: 100, y: 200, width: 1_000, height: 800)
        let trayAnchor = NSRect(x: 600, y: 950, width: 24, height: 24)

        XCTAssertEqual(
            WidgetPositioning.frame(
                size: NSSize(width: 360, height: 420),
                trayAnchor: trayAnchor,
                visibleFrame: visibleFrame
            ),
            NSRect(x: 432, y: 522, width: 360, height: 420)
        )
    }

    func testTrayWidgetClampsToEveryVisibleFrameEdge() {
        let visibleFrame = NSRect(x: 100, y: 200, width: 1_000, height: 800)
        let size = NSSize(width: 360, height: 420)

        let lowerLeft = WidgetPositioning.frame(
            size: size,
            trayAnchor: NSRect(x: 0, y: 0, width: 20, height: 20),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(lowerLeft.minX, visibleFrame.minX + WidgetPositioning.margin)
        XCTAssertEqual(lowerLeft.minY, visibleFrame.minY + WidgetPositioning.margin)

        let upperRight = WidgetPositioning.frame(
            size: size,
            trayAnchor: NSRect(x: 1_200, y: 1_100, width: 20, height: 20),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(upperRight.maxX, visibleFrame.maxX - WidgetPositioning.margin)
        XCTAssertEqual(upperRight.maxY, visibleFrame.maxY - WidgetPositioning.margin)
    }

    func testQuartzConversionAndNearEquality() {
        XCTAssertEqual(
            WidgetPositioning.appKitFrame(
                fromQuartz: CGRect(x: -1_440, y: 24, width: 80, height: 24),
                primaryScreenTop: 900
            ),
            NSRect(x: -1_440, y: 852, width: 80, height: 24)
        )

        let reference = NSRect(x: 100, y: 200, width: 360, height: 420)
        XCTAssertTrue(WidgetPositioning.nearlyEqual(
            reference,
            NSRect(x: 101, y: 199, width: 361, height: 419)
        ))
        XCTAssertFalse(WidgetPositioning.nearlyEqual(
            reference,
            NSRect(x: 101.01, y: 200, width: 360, height: 420)
        ))
    }
}
