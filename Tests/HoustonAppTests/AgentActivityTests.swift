import XCTest
import SwiftUI
import HoustonCore
@testable import Houston

/// An agent's lifecycle plays out in the island: a session starts, works, needs input, finishes, or fails, and
/// each of those is a moment with its own motion, and a chime for the ones that need the person.
final class AgentActivityTests: XCTestCase {
    @MainActor private final class CueLog { var cues: [IslandSounds.Cue] = [] }

    /// A store over a temporary bridge directory whose chimes are recorded instead of played.
    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("houston-activity-" + UUID().uuidString)
        let store: Store
        private let log = CueLog()

        init() {
            let log = log
            store = Store(bridgeFile: directory.appendingPathComponent("usage.json"),
                          alerts: AlertCenter(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                          sounds: IslandSounds { log.cues.append($0) }) { _, _, _, _ in
                XCTFail("Activity tests must not start live usage requests")
                return UsageSnapshot(windows: [])
            }
        }

        var cues: [IslandSounds.Cue] { log.cues }
        var peek: IslandPeek? { store.peek }

        /// Deliver one hook event as the bridge would, then let the monitor notice it as a fresh change.
        func event(_ name: String, session: String = "session-1", provider: AgentProvider = .claude,
                   project: String = "API migration", age: TimeInterval = 0, refresh: Bool = true) throws {
            let payload = ["hook_event_name": name, "session_id": session, "cwd": "/Users/dev/" + project]
            try AgentBridge.capture(JSONSerialization.data(withJSONObject: payload), provider: provider,
                                    directory: directory, now: .now.addingTimeInterval(-age))
            if refresh { store.agents.refresh() }
        }

        func remove() {
            store.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor func testLifecycleMomentsPeekAndChime() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(fixture.store.presentation, .compact)
        try fixture.event("SessionStart")
        XCTAssertNil(fixture.peek, "A session that is merely ready says nothing yet")

        try fixture.event("UserPromptSubmit")
        XCTAssertEqual(fixture.store.presentation, .peek)
        XCTAssertEqual(fixture.peek?.moment, .start)
        XCTAssertEqual(fixture.peek?.headline, "Working")
        XCTAssertEqual(fixture.peek?.detail, "Claude Code · API migration")
        XCTAssertEqual(fixture.peek?.logo, "claude")
        XCTAssertEqual(fixture.peek?.tab, .agents)
        XCTAssertEqual(fixture.peek?.sessionID, "claude:session-1")
        XCTAssertTrue(fixture.cues.isEmpty, "Starting is quiet")
        let started = fixture.peek?.id
        try fixture.event("PostToolUse")
        XCTAssertEqual(fixture.peek?.id, started, "Tool use keeps working without a new moment")

        try fixture.event("PermissionRequest")
        XCTAssertEqual(fixture.peek?.moment, .attention)
        XCTAssertEqual(fixture.peek?.headline, "Needs input")
        XCTAssertEqual(fixture.peek?.symbol, "hand.raised.fill")
        XCTAssertEqual(fixture.cues, [.attention])
        try fixture.event("PostToolUse")
        XCTAssertNil(fixture.peek, "Answering retracts the request; the working ring says the rest")
        XCTAssertEqual(fixture.cues, [.attention], "Resuming after an answer is quiet")

        try fixture.event("Stop")
        XCTAssertEqual(fixture.peek?.moment, .finish)
        XCTAssertEqual(fixture.peek?.headline, "Response ready")
        XCTAssertEqual(fixture.peek?.symbol, "checkmark.circle.fill")
        XCTAssertEqual(fixture.cues, [.attention, .finish])

        try fixture.event("UserPromptSubmit")
        XCTAssertEqual(fixture.peek?.moment, .start, "A new prompt after a response starts again")
        try fixture.event("StopFailure")
        XCTAssertEqual(fixture.peek?.moment, .failure)
        XCTAssertEqual(fixture.peek?.headline, "Turn failed")
        XCTAssertEqual(fixture.cues, [.attention, .finish, .failure])
        try fixture.event("SessionEnd")
        XCTAssertEqual(fixture.peek?.moment, .failure, "Ending a session is not a moment of its own")
        XCTAssertTrue(fixture.store.alerts.recent.isEmpty, "macOS notifications stay opt-in")
    }

    @MainActor func testFailedRetryBetweenReadsAnnouncesOnce() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.store.alerts.agentEnabled = true
        try fixture.event("StopFailure", age: 10)
        let firstPeek = fixture.peek?.id

        try fixture.event("UserPromptSubmit", age: 5, refresh: false)
        try fixture.event("StopFailure", refresh: false)
        fixture.store.agents.refresh()
        fixture.store.agents.refresh()

        XCTAssertEqual(fixture.peek?.moment, .failure)
        XCTAssertNotEqual(fixture.peek?.id, firstPeek, "A failed retry gets a new moment even when its running state was not read")
        XCTAssertEqual(fixture.cues, [.failure, .failure])
        XCTAssertEqual(fixture.store.alerts.recent.map(\.title), ["Agent turn failed", "Agent turn failed"],
                       "Each failed turn notifies once; rereading the same event stays quiet")
    }

    @MainActor func testMomentsHaveTheirOwnTimingAndMotion() {
        XCTAssertLessThan(IslandMoment.start.duration, IslandMoment.finish.duration, "A start is a glance; a result stays longer")
        XCTAssertGreaterThanOrEqual(IslandMoment.attention.duration, IslandMoment.finish.duration)
        XCTAssertNil(IslandMoment.start.cue)
        XCTAssertNil(IslandMoment.notice.cue)
        XCTAssertEqual(IslandMoment.attention.cue, .attention)
        XCTAssertEqual(IslandMoment.finish.cue, .finish)
        XCTAssertEqual(IslandMoment.failure.cue, .failure)
        XCTAssertNotEqual(IslandMotion.presentation(.peek, moment: .attention, reduceMotion: false),
                          IslandMotion.presentation(.peek, moment: .start, reduceMotion: false), "A request arrives with more bounce than a start")
        XCTAssertEqual(IslandMotion.presentation(.peek, moment: .attention, reduceMotion: true),
                       IslandMotion.presentation(.peek, moment: .start, reduceMotion: true), "Reduce Motion fades every moment alike")
    }

    @MainActor func testNotificationsMirrorMomentsWithoutDoublingThem() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.store.alerts.agentEnabled = true
        try fixture.event("UserPromptSubmit")
        XCTAssertTrue(fixture.store.alerts.recent.isEmpty, "Starting is status, not an alert")
        try fixture.event("PermissionRequest")
        XCTAssertEqual(fixture.store.alerts.recent.map(\.title), ["Agent needs your input"])
        XCTAssertEqual(fixture.store.alerts.recent.first?.body, "Claude · API migration")
        XCTAssertEqual(fixture.peek?.moment, .attention)
        XCTAssertNotEqual(fixture.peek?.id, fixture.store.alerts.recent.first?.id, "The moment is the peek; its alert does not add a second one")
        XCTAssertEqual(fixture.cues, [.attention], "One chime per moment, never one per channel")
        try fixture.event("Stop")
        XCTAssertEqual(fixture.store.alerts.recent.map(\.title), ["Agent response ready", "Agent needs your input"])
        // An agent alert sent from anywhere else still peeks on its own, as before.
        fixture.store.alerts.send(title: "Agent response ready", body: "Codex · Houston", sessionID: "codex:other")
        XCTAssertEqual(fixture.peek?.id, fixture.store.alerts.recent.first?.id)
        XCTAssertEqual(fixture.peek?.moment, .finish)
    }

    @MainActor func testMomentsRespectSoundsAndTheOpenPanel() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.store.alerts.soundsEnabled = false
        try fixture.event("UserPromptSubmit")
        try fixture.event("Stop")
        XCTAssertEqual(fixture.peek?.moment, .finish)
        XCTAssertTrue(fixture.cues.isEmpty, "Sounds off keeps the moment silent but visible")
        fixture.store.alerts.soundsEnabled = true
        fixture.store.expanded = true
        XCTAssertNil(fixture.peek)
        try fixture.event("PermissionRequest")
        XCTAssertNil(fixture.peek, "The open panel already shows the session itself")
        XCTAssertEqual(fixture.cues, [.attention], "The chime still reaches the person")
    }

    @MainActor func testOldEventsAndRereadsDoNotAnnounce() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.event("PermissionRequest", age: 200)
        XCTAssertNil(fixture.peek, "A stale request found on a later read is not news")
        XCTAssertTrue(fixture.cues.isEmpty)
        fixture.store.agents.refresh()
        fixture.store.agents.refresh()
        XCTAssertNil(fixture.peek)
        XCTAssertTrue(fixture.cues.isEmpty, "Rereading the same events never repeats a moment")
    }

    @MainActor func testTrailingSlotShowsTheSessionThatNeedsYouFirst() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.event("PermissionRequest", session: "older")
        try fixture.event("UserPromptSubmit", session: "newer", provider: .codex)
        let island = CompactIsland(store: fixture.store, date: .now, rotationStart: .now)
        XCTAssertEqual(island.activeAgents.map(\.sessionID), ["older", "newer"], "A request outranks newer work")
        try fixture.event("Stop", session: "older")
        XCTAssertEqual(island.activeAgents.map(\.sessionID), ["newer", "older"], "Work outranks a response that already landed")
        try fixture.event("StopFailure", session: "older")
        XCTAssertEqual(island.activeAgents.map(\.sessionID), ["older", "newer"])
        XCTAssertEqual(island.activeAgents.first?.status, .failed, "A failed turn is what needs the person now")
    }

    @MainActor func testExpiredOutcomesLeaveTheNotchAndCurrentActivityTogether() throws {
        for event in ["StopFailure", "Stop"] {
            let fixture = Fixture()
            defer { fixture.remove() }
            fixture.store.enabled = [] // Exercise the explicit redraw schedule with no rotating favorites.
            try fixture.event(event, refresh: false)
            fixture.store.agents.refresh(notify: false)
            let session = try XCTUnwrap(fixture.store.agents.sessions.first)
            let deadline = session.updatedAt.addingTimeInterval(301)
            XCTAssertEqual(IslandView(store: fixture.store).readingChangeDates, [deadline],
                           "Both outcomes must redraw as soon as their five-minute visibility ends")
            let lastVisible = session.updatedAt.addingTimeInterval(300)
            XCTAssertTrue(session.isCurrent(at: lastVisible))
            XCTAssertEqual(fixture.store.activeAgents(at: lastVisible).map(\.id), [session.id])
            XCTAssertFalse(session.isCurrent(at: deadline))
            XCTAssertTrue(fixture.store.activeAgents(at: deadline).isEmpty,
                          "A session in collapsed History must not stay highlighted in the notch")
            fixture.store.openIsland(defaultTab: .usage, at: deadline)
            XCTAssertEqual(fixture.store.tab, .usage, "An expired outcome must not redirect hover to Agents")

            try fixture.event("UserPromptSubmit", session: "working", refresh: false)
            fixture.store.agents.refresh(notify: false)
            XCTAssertEqual(fixture.store.activeAgents(at: deadline).map(\.sessionID), ["working"],
                           "An old failure must not outrank ongoing work")
        }
    }

    @MainActor func testSoundsDefaultOnAndPersist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertTrue(AlertCenter(defaults: defaults).soundsEnabled)
        AlertCenter(defaults: defaults).soundsEnabled = false
        XCTAssertFalse(AlertCenter(defaults: defaults).soundsEnabled)
        XCTAssertNil(AlertCenter(defaults: defaults).permissionMessage, "Sounds never ask for notification permission")
    }

    func testChimesAreShortSoftAndPlayable() throws {
        for cue in IslandSounds.Cue.allCases {
            let samples = IslandSounds.samples(for: cue)
            let seconds = Double(samples.count) / Double(IslandSounds.sampleRate)
            XCTAssertGreaterThan(seconds, 0.3, "\(cue)")
            XCTAssertLessThan(seconds, 1, "\(cue): a chime is over before the person looks up")
            XCTAssertEqual(samples.map { abs($0) }.max() ?? 0, 0.42, accuracy: 0.01, "\(cue): peaks well below full scale")
            XCTAssertEqual(samples.first ?? 1, 0, accuracy: 0.001, "\(cue): starts from silence")
            XCTAssertEqual(abs(samples.last ?? 1), 0, accuracy: 0.001, "\(cue): fades out instead of clicking")
            let wave = IslandSounds.wave(for: cue)
            XCTAssertEqual(String(decoding: wave.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: wave[8..<12], as: UTF8.self), "WAVE")
            XCTAssertEqual(wave.count, 44 + samples.count * 2)
            XCTAssertNotNil(NSSound(data: wave), "\(cue): NSSound must accept the WAV")
            // Keep the chimes next to the renders so they can be auditioned and checked with afinfo.
            if let path = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try wave.write(to: directory.appendingPathComponent("chime-\(cue.rawValue).wav"))
            }
        }
        // A request knocks twice: the loudness dips between the taps, then rises again.
        let knock = IslandSounds.samples(for: .attention)
        func loudness(_ from: Double, _ to: Double) -> Float {
            knock[Int(from * 44_100)..<Int(to * 44_100)].map { abs($0) }.max() ?? 0
        }
        XCTAssertLessThan(loudness(0.1, 0.14), loudness(0, 0.05) * 0.5)
        XCTAssertGreaterThan(loudness(0.15, 0.2), loudness(0.1, 0.14) * 2)
    }

    /// Fixed renders of the compact indicator in each state and of every moment's peek, on notch geometry.
    /// Set HOUSTON_RENDER_DIR to keep the PNGs for review; the camera area must stay black in all of them.
    @MainActor func testAgentStatesRenderClearOfTheCamera() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store
        store.enabled = [.codex, .claude]
        store.compactWidth = 297
        store.notchWidth = 185
        store.topInset = 32
        store.expandedWidth = 460
        store.expandedHeight = 600
        store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: 24, resetsAt: .now.addingTimeInterval(3600))])
        store.snapshots[.claude] = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: 91, resetsAt: .now.addingTimeInterval(3600))])
        let directory = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

        for (scene, event) in [("working", "UserPromptSubmit"), ("waiting", "PermissionRequest"), ("ready", "Stop"), ("failed", "StopFailure")] {
            try fixture.event(event)
            try fixture.event("UserPromptSubmit", session: "second", provider: .codex, project: "Website")
            store.dismissPeek()
            XCTAssertEqual(store.presentation, .compact)
            try await capture(store, scene: "compact-agent-" + scene, directory: directory, expectTrailing: true, settle: 0.08)
        }
        let session = try XCTUnwrap(store.agents.sessions.first { $0.sessionID == "session-1" })
        for moment in [IslandMoment.start, .attention, .finish, .failure] {
            store.present(IslandPeek(session, moment: moment))
            XCTAssertEqual(store.presentation, .peek)
            // The mark pops in over about 0.7 s; capture the settled pose.
            try await capture(store, scene: "island-moment-\(moment)", directory: directory, expectTrailing: false, settle: 0.9)
        }
    }

    @MainActor private func capture(_ store: Store, scene: String, directory: URL?, expectTrailing: Bool, settle: TimeInterval) async throws {
        let size = store.size(for: store.presentation)
        let hosting = NSHostingView(rootView: IslandView(store: store))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(settle))
        hosting.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = try XCTUnwrap(representation.cgImage, "\(scene) must render")
        let scale = window.backingScaleFactor
        XCTAssertEqual(image.width, Int(size.width * scale), scene)
        XCTAssertEqual(image.height, Int(size.height * scale), scene)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let cameraStart = Int((size.width - 185) / 2 * scale), cameraEnd = cameraStart + Int(185 * scale)
        var brightest = CGFloat.zero
        var leading = 0, trailing = 0
        for y in stride(from: 0, to: Int(38 * scale), by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let brightness = max(color.redComponent, max(color.greenComponent, color.blueComponent))
                if x >= cameraStart && x < cameraEnd { if y < Int(32 * scale) { brightest = max(brightest, brightness) } }
                else if brightness > 0.3 { if x < cameraStart { leading += 1 } else { trailing += 1 } }
            }
        }
        XCTAssertLessThanOrEqual(brightest, 0.01, "\(scene): nothing may cross the camera")
        XCTAssertGreaterThan(leading, 20, "\(scene): the ring or the moment's mark must show beside the camera")
        if expectTrailing { XCTAssertGreaterThan(trailing, 10, "\(scene): the agent indicator must show on the trailing side") }
        else { XCTAssertGreaterThan(trailing, 20, "\(scene): the headline must show on the trailing side") }
        if let directory {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(scene + ".png"))
        }
    }

    /// Opt in with HOUSTON_MEASURE=1. Hosts each continuous indicator on screen for five seconds and prints the
    /// process CPU it costs, next to a SwiftUI repeat-forever rotation of the same mark for comparison.
    @MainActor func testContinuousIndicatorsCostNoMainThreadTime() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOUSTON_MEASURE"] != nil, "Set HOUSTON_MEASURE=1 to measure on screen")
        let screen = try XCTUnwrap(NSScreen.main)
        var report: [String: Double] = [:]
        for (name, view) in [
            ("still", AnyView(WorkingOrbit(size: 16, turning: false).frame(width: 16, height: 16))),
            ("orbit", AnyView(WorkingOrbit(size: 16).frame(width: 16, height: 16))),
            ("breathing", AnyView(BreathingSymbol(name: "hand.raised.fill", tint: .systemOrange, pointSize: 13).frame(width: 18, height: 18))),
            ("swiftui-repeat", AnyView(SpinningSymbol()))
        ] {
            let hosting = NSHostingView(rootView: view.frame(width: 120, height: 40).background(Color.black))
            let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.maxX - 140, y: screen.visibleFrame.minY + 20, width: 120, height: 40),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = hosting
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(600))
            let cpu = processCPUSeconds(), began = Date.now
            try await Task.sleep(for: .seconds(5))
            let percent = (processCPUSeconds() - cpu) / Date.now.timeIntervalSince(began) * 100
            report[name] = percent
            print(String(format: "measure %@: %.1f%% of one core", name, percent))
            window.close()
        }
        XCTAssertLessThan(report["orbit"] ?? 100, 2, "The working ring must not cost the app main-thread time")
        XCTAssertLessThan(report["breathing"] ?? 100, 2, "The waiting hand must not cost the app main-thread time")
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
}

/// The SwiftUI way to spin a symbol forever, kept only as the measurement's point of comparison.
private struct SpinningSymbol: View {
    @State private var turning = false
    var body: some View {
        Image(systemName: "circle.dotted").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}
