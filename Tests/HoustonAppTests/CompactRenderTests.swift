import XCTest
import SwiftUI
import HoustonCore
@testable import Houston

/// Fixed-date renders also catch content crossing the physical camera area.
final class CompactRenderTests: XCTestCase {
    private var savedSelection: Any?
    private enum State: String, CaseIterable { case fresh, missing, empty, loading, stale, expired, preview }

    override func setUp() {
        super.setUp()
        savedSelection = UserDefaults.standard.object(forKey: "compactProviders")
        UserDefaults.standard.removeObject(forKey: "compactProviders")
    }

    override func tearDown() {
        if let savedSelection { UserDefaults.standard.set(savedSelection, forKey: "compactProviders") }
        else { UserDefaults.standard.removeObject(forKey: "compactProviders") }
        super.tearDown()
    }

    @MainActor func testCompactScheduleDoesNotAgeFreshReadingsBeforeFirstDeadline() throws {
        let store = Store()
        store.compactWidth = 300
        store.enabled = [.codex, .claude, .cursor, .copilot]
        for provider in store.enabled {
            store.snapshots[provider] = UsageSnapshot(windows: [
                UsageWindow(name: "Current window", used: 24, resetsAt: .now.addingTimeInterval(3600))
            ])
        }
        // Explicit TimelineView schedules can initially provide their first future entry date.
        let renderer = ImageRenderer(content: IslandView(store: store))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        var warningPixels = 0
        var visiblePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.4 { visiblePixels += 1 }
                if color.redComponent > color.greenComponent + 0.15,
                   color.greenComponent > color.blueComponent + 0.1 { warningPixels += 1 }
            }
        }
        XCTAssertGreaterThan(visiblePixels, 100, "The actual island must render its readings")
        XCTAssertEqual(warningPixels, 0, "Fresh allowances must not be marked orange/earlier by a future schedule entry")
    }

    @MainActor func testCompactFavoriteRotationRespectsTimeAndEnabledProviders() {
        let store = Store()
        store.enabled = Set(Provider.allCases)
        let start = Date.now
        func displayed(at seconds: TimeInterval) -> Provider? {
            CompactIsland(store: store, date: start.addingTimeInterval(seconds), rotationStart: start).displayedProvider
        }
        for (seconds, expected) in [(0.0, Provider.codex), (5, .codex), (6, .claude), (12, .cursor), (24, .codex)] {
            XCTAssertEqual(displayed(at: seconds), expected, "Rotation at \(seconds) seconds")
        }
        XCTAssertEqual(displayed(at: -60), .codex, "An earlier date stays on the first favorite")

        store.enabled.remove(.claude)
        XCTAssertEqual(displayed(at: 6), .cursor, "Rotation skips disabled favorites")
        XCTAssertEqual(displayed(at: 12), .copilot)
        XCTAssertEqual(displayed(at: 18), .codex)

        store.enabled = [.copilot]
        for seconds in [0.0, 6, 24, 120] { XCTAssertEqual(displayed(at: seconds), .copilot) }
        store.enabled = []
        XCTAssertNil(displayed(at: 0))
        XCTAssertNil(displayed(at: 24))
    }

    @MainActor func testCompactLayoutsKeepAllReadingStatesOutsideCamera() throws {
        let now = Date.now
        let directory = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

        for (name, width, notch, top) in [
            ("notched", CGFloat(348), CGFloat(180), CGFloat(32)),
            ("external", 180, 0, 0),
            ("narrow", 276, 180, 32)
        ] {
            for state in State.allCases {
                let store = Store { _, _, _, _ in
                    XCTFail("Compact rendering must not start a live usage request")
                    return UsageSnapshot(windows: [])
                }
                store.enabled = state == .empty ? [] : Set(Provider.allCases)
                store.compactWidth = width
                store.notchWidth = notch
                store.topInset = top
                if state == .loading { store.loading = Set(store.compactProviders) }
                if [State.fresh, .stale, .expired].contains(state) {
                    for (index, provider) in store.compactProviders.enumerated() {
                        store.snapshots[provider] = UsageSnapshot(windows: [
                            UsageWindow(name: "Current window", used: Double(24 + index * 15),
                                        resetsAt: now.addingTimeInterval(state == .expired ? -1 : 3600))
                        ], capturedAt: now.addingTimeInterval(state == .stale ? -601 : 0))
                    }
                }
                if state == .preview { store.demo = true }

                let scene = "\(name)-\(state.rawValue)"
                let island = CompactIsland(store: store, date: now, rotationStart: now)
                XCTAssertEqual(island.displayedProvider, state == .empty ? nil : .codex, scene)

                let renderer = ImageRenderer(content: island.background(.black).environment(\.colorScheme, .dark))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, "\(scene) must render")
                XCTAssertEqual(image.width, Int(width * 2), scene)
                XCTAssertEqual(image.height, Int(max(34, top + 6) * 2), scene)
                let bitmap = NSBitmapImageRep(cgImage: image)

                if notch > 0 {
                    let cameraStart = Int((width - notch) / 2 * 2)
                    let cameraEnd = cameraStart + Int(notch * 2)
                    var brightest = CGFloat.zero
                    var leastOpaque = CGFloat(1)
                    for y in 0..<image.height {
                        for x in cameraStart..<cameraEnd {
                            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            brightest = max(brightest, max(color.redComponent, max(color.greenComponent, color.blueComponent)))
                            leastOpaque = min(leastOpaque, color.alphaComponent)
                        }
                    }
                    XCTAssertLessThanOrEqual(brightest, 0.01, "\(scene): no text or logo may cross the camera")
                    XCTAssertGreaterThanOrEqual(leastOpaque, 0.99, "\(scene): camera area must stay opaque black")
                }

                var hasVisibleContent = false
                for y in stride(from: 0, to: image.height, by: 3) {
                    for x in stride(from: 0, to: image.width, by: 3) {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.1 { hasVisibleContent = true }
                    }
                }
                XCTAssertTrue(hasVisibleContent, "\(scene): a successful render must include visible content")

                if let directory {
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent("compact-\(scene).png"))
                }
            }
        }
    }
}
