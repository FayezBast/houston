import XCTest
import SwiftUI
import HoustonCore
@testable import Houston

/// The island has three presentations: the compact strip, a short alert peek, and the open panel.
final class IslandPresentationTests: XCTestCase {
    @MainActor private func makeStore() -> Store {
        Store(bridgeFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("usage.json"),
              alerts: AlertCenter(defaults: UserDefaults(suiteName: UUID().uuidString)!)) { _, _, _, _ in
            XCTFail("Presentation tests must not start live usage requests")
            return UsageSnapshot(windows: [])
        }
    }

    @MainActor func testAlertsPeekOutOfTheNotchWhileClosedAndClearWhenOpened() {
        let store = makeStore()
        XCTAssertEqual(store.presentation, .compact)
        store.alerts.send(title: "Agent needs your input", body: "Claude Code · API migration", sessionID: "session-1")
        XCTAssertEqual(store.presentation, .peek)
        XCTAssertEqual(store.peek?.tab, .agents)
        XCTAssertEqual(store.peek?.symbol, "hand.raised.fill")
        XCTAssertEqual(store.peek?.headline, "Needs input")
        XCTAssertEqual(store.peek?.detail, "Claude Code · API migration")
        store.alerts.send(title: "Codex quota is low", body: "Current sign-in · 5-hour: 9% remaining", url: Provider.codex.dashboard)
        XCTAssertEqual(store.peek?.tab, .usage, "A newer alert replaces the peek")
        XCTAssertEqual(store.peek?.symbol, "gauge.with.dots.needle.67percent")
        XCTAssertEqual(store.peek?.headline, "Codex quota low")
        store.expanded = true
        XCTAssertNil(store.peek, "Opening the panel dismisses the peek; the alert stays in Recent alerts")
        XCTAssertEqual(store.presentation, .expanded)
        store.expanded = false
        XCTAssertEqual(store.presentation, .compact)
        store.alerts.send(title: "Build failed", body: "CI · Tamayaz-io/coachxo", url: URL(string: "https://github.com/Tamayaz-io/coachxo/pull/1")!)
        XCTAssertEqual(store.peek?.tab, .activity)
        XCTAssertEqual(store.peek?.symbol, "xmark.circle.fill")
        XCTAssertEqual(store.peek?.headline, "Build failed")
        store.alerts.send(title: "Codex quota has reset", body: "Current sign-in · Weekly: 100% remaining", url: Provider.codex.dashboard)
        XCTAssertEqual(store.peek?.symbol, "arrow.clockwise.circle.fill")
        XCTAssertEqual(store.peek?.headline, "Codex quota reset")
        store.dismissPeek()
        XCTAssertEqual(store.presentation, .compact)
        XCTAssertEqual(store.alerts.recent.count, 4)
    }

    @MainActor func testPeekIsNotShownDuringPreviewOrWhileOpen() {
        let store = makeStore()
        store.expanded = true
        store.alerts.send(title: "Agent response ready", body: "Codex · Houston", sessionID: "s")
        XCTAssertNil(store.peek)
        store.expanded = false
        store.demo = true
        store.alerts.send(title: "Agent response ready", body: "Codex · Houston", sessionID: "s")
        XCTAssertNil(store.peek, "Preview never presents alerts")
        XCTAssertEqual(store.presentation, .compact)
    }

    @MainActor func testPeekDismissesItselfAfterAFewSeconds() async throws {
        let store = makeStore()
        store.alerts.send(title: "Agent response ready", body: "Codex · Houston", sessionID: "s")
        XCTAssertNotNil(store.peek)
        let cleared = expectation(description: "The peek clears on its own")
        let subscription = store.$peek.filter { $0 == nil }.prefix(1).sink { _ in cleared.fulfill() }
        await fulfillment(of: [cleared], timeout: 7)
        subscription.cancel()
        XCTAssertEqual(store.presentation, .compact)
    }

    func testPresentationsNestFromCompactToExpanded() {
        XCTAssertTrue(IslandPresentation.compact < .peek)
        XCTAssertTrue(IslandPresentation.peek < .expanded)
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 80, width: 1512, height: 869)
        let geometry = IslandGeometry(screen: screen, visible: visible, topInset: 32, notchWidth: 185, presentation: .peek)
        let compact = geometry.frame(for: .compact), peek = geometry.frame, expanded = geometry.frame(for: .expanded)
        XCTAssertEqual(peek, geometry.frame(for: .peek))
        for frame in [compact, peek, expanded] {
            XCTAssertEqual(frame.midX, screen.midX, "Every presentation stays centered on the camera")
            XCTAssertEqual(frame.maxY, screen.maxY, "Every presentation grows out of the camera housing")
            XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
            XCTAssertLessThanOrEqual(frame.maxX, visible.maxX)
        }
        XCTAssertEqual(compact.height, geometry.bandHeight)
        XCTAssertEqual(peek.height, geometry.bandHeight + IslandStyle.peekRowHeight)
        XCTAssertGreaterThan(peek.width, compact.width)
        XCTAssertLessThanOrEqual(peek.width, expanded.width)
        XCTAssertGreaterThan(expanded.height, peek.height)

        let small = IslandGeometry(screen: NSRect(x: 0, y: 0, width: 360, height: 480), visible: NSRect(x: 0, y: 0, width: 360, height: 456),
                                   topInset: 0, notchWidth: 0, presentation: .peek)
        XCTAssertLessThanOrEqual(small.peekSize.width, small.expandedSize.width, "A tiny display clamps the peek to the panel")
        XCTAssertEqual(small.frame.midX, 180)
        XCTAssertEqual(small.bandHeight, 34)
    }

    func testPresentationsFollowTheReportedCameraGapOnAnOffsetDisplay() {
        let screen = NSRect(x: -1512, y: 100, width: 1512, height: 982)
        let visible = NSRect(x: -1440, y: 170, width: 1440, height: 880)
        let cameraCenter: CGFloat = -740
        let geometry = IslandGeometry(screen: screen, visible: visible, topInset: 32, notchWidth: 185,
                                      notchCenterX: cameraCenter, presentation: .compact)
        for presentation in [IslandPresentation.compact, .peek, .expanded] {
            let frame = geometry.frame(for: presentation)
            XCTAssertEqual(frame.midX, cameraCenter, "Use the camera gap in global screen coordinates")
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 12)
            XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 12)
            XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 12)
        }
        XCTAssertEqual(geometry.compactWidth, 185 + 2 * IslandGeometry.notchSide)
    }

    func testIncompleteCameraGeometryUsesTheDetachedPresentation() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 72, y: 70, width: 1440, height: 880)
        for (inset, width) in [(CGFloat(32), CGFloat(0)), (0, 185)] {
            let geometry = IslandGeometry(screen: screen, visible: visible, topInset: inset, notchWidth: width,
                                          presentation: .compact)
            XCTAssertEqual(geometry.topInset, 0)
            XCTAssertEqual(geometry.notchWidth, 0, "The rendered band and panel must agree about the camera")
            XCTAssertEqual(geometry.compactWidth, IslandGeometry.detachedWidth)
            XCTAssertEqual(geometry.bandHeight, 34)
            for presentation in [IslandPresentation.compact, .peek, .expanded] {
                XCTAssertEqual(geometry.frame(for: presentation).midX, visible.midX)
                XCTAssertEqual(geometry.frame(for: presentation).maxY, visible.maxY - 7)
            }
        }
        let hiddenMenu = IslandGeometry(screen: screen, visible: screen, topInset: 32, notchWidth: 0,
                                        presentation: .compact)
        XCTAssertEqual(hiddenMenu.frame.maxY, screen.maxY - 32 - 7, "An unknown camera gap still reserves the unsafe top strip")
    }

    func testReduceMotionDoesNotAnimateIslandGeometry() {
        for presentation in [IslandPresentation.compact, .peek, .expanded] {
            XCTAssertNil(IslandMotion.presentation(presentation, moment: .attention, reduceMotion: true))
            XCTAssertNotNil(IslandMotion.presentation(presentation, reduceMotion: false))
        }
    }

    @MainActor func testHoverOnAPeekOpensThePanel() {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        app.layout()
        app.store.alerts.send(title: "Agent needs your input", body: "Claude Code · API migration", sessionID: "session-1")
        app.layout()
        XCTAssertEqual(app.store.presentation, .peek)
        XCTAssertEqual(app.panel.frame.height, app.store.size(for: .peek).height, "The panel makes room for the peek")
        app.checkHover(at: NSPoint(x: app.panel.frame.midX, y: app.panel.frame.minY - 3))
        XCTAssertTrue(app.store.expanded, "Reaching for the alert opens the panel, like pressing into the Dynamic Island")
        XCTAssertEqual(app.store.tab, .agents, "Hover must follow the alert before its peek is cleared")
        XCTAssertNil(app.store.peek)
    }

    @MainActor func testOpeningAnAlertPreservesItsDestinationAcrossHoverAndClick() {
        let store = makeStore()
        store.projects.suspended = true
        let projectID = UUID()
        for (alert, tab) in [
            (HoustonAlert(title: "Agent needs your input", body: "Agent", url: nil, sessionID: "session-1"), PanelTab.agents),
            (HoustonAlert(title: "Build failed", body: "CI", url: URL(string: "https://github.com/owner/repo"), sessionID: nil), .activity),
            (HoustonAlert(title: "Command passed", body: "Tests", url: nil, sessionID: nil, projectID: projectID), .projects),
            (HoustonAlert(title: "Codex quota is low", body: "9% remaining", url: nil, sessionID: nil), .usage)
        ] {
            store.expanded = false
            store.tab = .tools
            store.present(alert)
            store.openIsland()
            XCTAssertEqual(store.tab, tab)
            XCTAssertNil(store.peek)
            if tab == .projects { XCTAssertEqual(store.projects.selectedID, projectID) }
            store.openIsland(defaultTab: .usage)
            XCTAssertEqual(store.tab, tab, "A click after hover must not replace the alert destination")
        }
        store.stop()
    }

    @MainActor func testHoverFollowsVisibleAgentActivityAndOtherwiseKeepsTheSelectedTab() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Store(bridgeFile: directory.appendingPathComponent("usage.json"))
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        let now = Date.now
        store.tab = .system
        store.openIsland(at: now)
        XCTAssertEqual(store.tab, .system, "Ordinary hover keeps the selected tab")
        store.expanded = false
        try AgentBridge.capture(Data(#"{"session_id":"session-1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}"#.utf8),
                                provider: .claude, directory: directory, now: now)
        store.agents.refresh(notify: false)
        XCTAssertNil(store.peek)
        store.openIsland(at: now)
        XCTAssertEqual(store.tab, .agents, "The compact activity indicator and hover destination agree")
        store.expanded = false
        store.tab = .system
        store.openIsland(at: now.addingTimeInterval(901))
        XCTAssertEqual(store.tab, .system, "Stale activity does not redirect the panel")
    }

    /// Fixed-date renders of every presentation, on a notch and as a detached pill. The camera area must stay black.
    @MainActor func testPresentationsRenderClearOfTheCamera() throws {
        let directory = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let now = Date.now
        for (name, notch, top, width) in [("notched", CGFloat(185), CGFloat(32), CGFloat(297)), ("external", 0, 0, 132)] {
            for presentation in [IslandPresentation.compact, .peek] {
                let store = makeStore()
                store.enabled = [.codex, .claude]
                store.compactWidth = width
                store.notchWidth = notch
                store.topInset = top
                store.expandedWidth = 460
                store.expandedHeight = 600
                store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: 24, resetsAt: now.addingTimeInterval(3600))], capturedAt: now)
                store.snapshots[.claude] = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: 91, resetsAt: now.addingTimeInterval(3600))], capturedAt: now)
                if presentation == .peek {
                    store.alerts.send(title: "Agent needs your input", body: "Claude Code · API migration", sessionID: "session-1")
                }
                XCTAssertEqual(store.presentation, presentation)
                let size = store.size(for: presentation)
                let renderer = ImageRenderer(content: IslandView(store: store))
                renderer.scale = 2
                let scene = "island-\(name)-\(presentation)"
                let image = try XCTUnwrap(renderer.cgImage, "\(scene) must render")
                XCTAssertEqual(image.width, Int(size.width * 2), scene)
                XCTAssertEqual(image.height, Int(size.height * 2), scene)
                let bitmap = NSBitmapImageRep(cgImage: image)
                if notch > 0 {
                    let cameraStart = Int((size.width - notch) / 2 * 2), cameraEnd = cameraStart + Int(notch * 2)
                    var brightest = CGFloat.zero
                    for y in 0..<Int(top * 2) {
                        for x in cameraStart..<cameraEnd {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            brightest = max(brightest, max(color.redComponent, max(color.greenComponent, color.blueComponent)))
                        }
                    }
                    XCTAssertLessThanOrEqual(brightest, 0.01, "\(scene): nothing may cross the camera")
                }
                var visible = 0
                for y in stride(from: 0, to: image.height, by: 2) {
                    for x in stride(from: 0, to: image.width, by: 2) {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.3 { visible += 1 }
                    }
                }
                XCTAssertGreaterThan(visible, 40, "\(scene): the ring, reading or alert must be visible")
                if let directory {
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent(scene + ".png"))
                }
                store.stop()
            }
        }
    }

    /// The open island on notch geometry: the ring and reading flank the camera, with pin and collapse at the edges.
    @MainActor func testExpandedIslandKeepsItsBandAroundTheCamera() async throws {
        let store = makeStore()
        store.enabled = [.codex, .claude]
        store.compactWidth = 297
        store.notchWidth = 185
        store.topInset = 32
        store.expandedWidth = 460
        store.expandedHeight = 560
        store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: 24, resetsAt: .now.addingTimeInterval(3600))])
        store.expanded = true
        store.pinned = true
        let hosting = NSHostingView(rootView: IslandView(store: store))
        let size = store.size(for: .expanded)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close(); store.stop() }
        try await Task.sleep(for: .milliseconds(60))
        hosting.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = try XCTUnwrap(representation.cgImage)
        let scale = window.backingScaleFactor
        XCTAssertEqual(image.width, Int(size.width * scale))
        XCTAssertEqual(image.height, Int(size.height * scale))
        let bitmap = NSBitmapImageRep(cgImage: image)
        let cameraStart = Int((size.width - 185) / 2 * scale), cameraEnd = cameraStart + Int(185 * scale)
        var brightest = CGFloat.zero
        for y in 0..<Int(32 * scale) {
            for x in cameraStart..<cameraEnd {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                brightest = max(brightest, max(color.redComponent, max(color.greenComponent, color.blueComponent)))
            }
        }
        XCTAssertLessThanOrEqual(brightest, 0.01, "The open island keeps the camera area black")
        if let path = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("island-notched-expanded.png"))
        }
    }
}
