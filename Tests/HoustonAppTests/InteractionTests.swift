import XCTest
import AppKit
import SwiftUI
@testable import Houston

final class InteractionTests: XCTestCase {
    @MainActor private func harness() -> AppDelegate {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        delegate.layout()
        return delegate
    }

    @MainActor func testConnectionsAlsoCollapsesAfterLeaving() {
        let app = harness()
        app.store.expanded = true
        app.store.connections = true
        app.store.pinned = false
        app.checkHover(at: NSPoint(x: -10000, y: -10000))
        app.checkHover(at: NSPoint(x: -10000, y: -10000), now: .now.addingTimeInterval(4))
        XCTAssertFalse(app.store.expanded, "Connections must not trap the panel open")
    }

    @MainActor func testPointerExitClosesWithinHalfASecond() {
        let app = harness()
        app.store.expanded = true
        app.store.pinned = false
        app.checkHover(at: NSPoint(x: -10000, y: -10000))
        app.checkHover(at: NSPoint(x: -10000, y: -10000), now: .now.addingTimeInterval(0.5))
        XCTAssertFalse(app.store.expanded, "A three-second close delay feels stuck")
    }

    @MainActor func testUsageUpdatesKeepTheSameHostingView() {
        let app = harness()
        let content = app.panel.contentView
        XCTAssertTrue(content is NSHostingView<IslandView>, "Run AppKit tests with display access")
        app.store.loading.insert(.codex)
        app.layout()
        XCTAssertTrue(content === app.panel.contentView, "Usage refresh must not rebuild the panel")
    }

    @MainActor func testHoverOpensImmediatelyAndPinIsExplicit() {
        let app = harness()
        XCTAssertFalse(app.store.pinned)
        app.store.expanded = false
        let point = NSPoint(x: app.panel.frame.midX, y: app.panel.frame.minY - 3)
        app.checkHover(at: point)
        XCTAssertTrue(app.store.expanded, "The island’s edge should react immediately")
        app.store.pinned = true
        app.checkHover(at: NSPoint(x: -10000, y: -10000), now: .now.addingTimeInterval(1))
        XCTAssertTrue(app.store.expanded)
    }

    @MainActor func testAllProviderLogosLoad() {
        for provider in Provider.allCases { XCTAssertNotNil(BrandAssets.images[provider.logo], provider.rawValue) }
        XCTAssertNotNil(BrandAssets.images["github"])
        XCTAssertGreaterThan(BrandAssets.images["gemini-color"]?.size.width ?? 0, 16, "Color logos need a useful intrinsic SVG size")
        if let image = BrandAssets.images["gemini-color"]?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            let filled = (0..<bitmap.pixelsWide).reduce(0) { total, x in
                total + (0..<bitmap.pixelsHigh).filter { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1 }.count
            }
            XCTAssertGreaterThan(filled, bitmap.pixelsWide * bitmap.pixelsHigh / 10, "The Gemini SVG must render its full star, not a clipped fragment")
        } else { XCTFail("Gemini must decode to pixels") }
    }

    func testPanelFitsNotchedExternalAndSmallDisplays() {
        for (screen, visible, inset, notch) in [
            (NSRect(x: 0, y: 0, width: 1512, height: 982), NSRect(x: 0, y: 70, width: 1512, height: 880), CGFloat(32), CGFloat(180)),
            (NSRect(x: -1920, y: 0, width: 1920, height: 1080), NSRect(x: -1920, y: 0, width: 1920, height: 1056), 0, 0),
            (NSRect(x: 0, y: -600, width: 800, height: 600), NSRect(x: 0, y: -530, width: 800, height: 506), 0, 0),
            (NSRect(x: 0, y: 0, width: 360, height: 480), NSRect(x: 0, y: 0, width: 360, height: 456), 0, 0)
        ] {
            for expanded in [true, false] {
                let geometry = IslandGeometry(screen: screen, visible: visible, topInset: inset, notchWidth: notch, expanded: expanded)
                XCTAssertGreaterThanOrEqual(geometry.frame.minX, visible.minX)
                XCTAssertLessThanOrEqual(geometry.frame.maxX, visible.maxX)
                XCTAssertGreaterThanOrEqual(geometry.frame.minY, visible.minY)
                XCTAssertLessThanOrEqual(geometry.frame.maxY, inset > 0 ? screen.maxY : visible.maxY)
                XCTAssertEqual(geometry.frame.midX, visible.midX)
            }
        }
    }

    @MainActor func testEditingAndPointerReentryPreventClosing() {
        let app = harness()
        app.store.expanded = true
        app.layout()
        let inside = NSPoint(x: app.panel.frame.midX, y: app.panel.frame.midY)
        let outside = NSPoint(x: -10000, y: -10000)
        let start = Date.now
        app.checkHover(at: inside, now: start)
        app.checkHover(at: outside, now: start.addingTimeInterval(0.1))
        XCTAssertTrue(app.store.expanded)
        app.checkHover(at: inside, now: start.addingTimeInterval(0.2))
        app.checkHover(at: outside, now: start.addingTimeInterval(0.4))
        XCTAssertTrue(app.store.expanded, "Reentry must restart the grace period")
        app.store.editing = true
        app.checkHover(at: outside, now: start.addingTimeInterval(1))
        XCTAssertTrue(app.store.expanded, "Typing must hold the panel open")
        app.store.editing = false
        app.checkHover(at: outside, now: start.addingTimeInterval(2))
        XCTAssertTrue(app.store.expanded, "Finishing an edit must grant a fresh close delay")
        app.checkHover(at: outside, now: start.addingTimeInterval(2.5))
        XCTAssertFalse(app.store.expanded)
    }

    @MainActor func testLeavingAfterStationaryHoverStillGrantsCloseDelay() {
        let app = harness()
        app.store.expanded = true
        app.layout()
        let start = Date.now
        app.checkHover(at: NSPoint(x: app.panel.frame.midX, y: app.panel.frame.midY), now: start)
        let outside = NSPoint(x: -10000, y: -10000)
        app.checkHover(at: outside, now: start.addingTimeInterval(20))
        XCTAssertTrue(app.store.expanded, "The delay starts on exit, not on the last mouse movement inside")
        app.checkHover(at: outside, now: start.addingTimeInterval(20.2))
        XCTAssertTrue(app.store.expanded)
        app.checkHover(at: outside, now: start.addingTimeInterval(20.4))
        XCTAssertFalse(app.store.expanded)
    }
}
