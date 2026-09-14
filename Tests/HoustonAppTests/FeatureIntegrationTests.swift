import XCTest
import HoustonCore
@testable import Houston

private actor UnknownAccountReads {
    var count = 0
    let reset = Date.now.addingTimeInterval(3600)
    func read() -> UsageSnapshot {
        count += 1
        return UsageSnapshot(windows: [UsageWindow(name: "Current", used: count == 1 ? 60 : 90, resetsAt: reset)],
                             capturedAt: .now.addingTimeInterval(count == 1 ? -5 : 0))
    }
}

final class FeatureIntegrationTests: XCTestCase {
    @MainActor func testClearFinishedPreservesLiveAndResumedSessionsAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date.now
        func capture(_ event: String, id: String, provider: AgentProvider = .claude, at date: Date) throws {
            let payload = ["session_id": id, "cwd": "/tmp/project", "hook_event_name": event]
            try AgentBridge.capture(JSONSerialization.data(withJSONObject: payload), provider: provider, directory: directory, now: date)
        }
        for (id, event) in [("running", "UserPromptSubmit"), ("waiting", "PermissionRequest"), ("ready", "SessionStart"),
                            ("complete", "Stop"), ("failed", "StopFailure"), ("ended", "SessionEnd"), ("resumed", "Stop")] {
            try capture(event, id: id, at: now.addingTimeInterval(-1_000))
        }
        try capture("Interrupt", id: "interrupted", provider: .codex, at: now)
        // IDs are scoped to the provider: clearing Claude's response must preserve Codex's work.
        try capture("UserPromptSubmit", id: "complete", provider: .codex, at: now)
        let monitor = AgentMonitor(directory: directory)
        monitor.refresh(notify: false)
        XCTAssertEqual(monitor.sessions.count, 9)
        try capture("UserPromptSubmit", id: "resumed", at: now)
        var notifications = 0
        monitor.onTransition = { _, _ in notifications += 1 }
        monitor.clearFinished()
        XCTAssertNil(monitor.error)
        XCTAssertEqual(Set(monitor.sessions.map(\.id)), ["claude:running", "claude:waiting", "claude:ready", "claude:resumed", "codex:complete"])
        XCTAssertEqual(notifications, 0, "Clearing entries must not announce existing sessions")
        let reopened = AgentMonitor(directory: directory)
        reopened.refresh(notify: false)
        XCTAssertEqual(reopened.sessions, monitor.sessions)
        try capture("UserPromptSubmit", id: "ended", at: now.addingTimeInterval(1))
        reopened.refresh(notify: false)
        XCTAssertTrue(reopened.sessions.contains { $0.id == "claude:ended" && $0.status == .running }, "A dismissed session returns on its next event")
    }

    @MainActor func testCoalescedAgentCompletionsNotifyOncePerNewResponse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = Data(#"{"session_id":"test-session","cwd":"/tmp/project","hook_event_name":"Stop"}"#.utf8)
        let monitor = AgentMonitor(directory: directory)
        var notifications = 0
        monitor.onTransition = { _, _ in notifications += 1 }
        try AgentBridge.capture(event, provider: .claude, directory: directory, now: .now.addingTimeInterval(-10))
        monitor.refresh(notify: false)
        try AgentBridge.capture(event, provider: .claude, directory: directory)
        monitor.refresh()
        monitor.refresh()
        XCTAssertEqual(notifications, 1, "A new response is actionable even if its running state happened between reads")
    }

    @MainActor func testSelectedAccountsAndDefaultHistoryRemainSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let alerts = AlertCenter(defaults: defaults)
        let accounts = AccountStore(file: directory.appendingPathComponent("accounts.json"), reader: { _, _ in
            UsageSnapshot(windows: [UsageWindow(name: "Plan", used: 15, resetsAt: .now.addingTimeInterval(3600))])
        }, saveSecret: { _, _ in }, removeSecret: { _ in })
        let store = Store(bridgeFile: directory.appendingPathComponent("usage.json"), accounts: accounts, alerts: alerts) { _, _, _, _ in
            UsageSnapshot(windows: [UsageWindow(name: "Plan", used: 60, resetsAt: .now.addingTimeInterval(3600))], accountID: "default-personal")
        }
        store.enabled = []
        store.start()
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.enabled = [.cursor]
        await store.refresh(.cursor)?.value
        XCTAssertEqual(store.history.samples.first?.accountID, "default-personal")
        XCTAssertEqual(store.snapshots[.cursor]?.windows.first?.used, 60)

        let work = try accounts.add(provider: .cursor, label: "Work", credential: "test-only",
            snapshot: UsageSnapshot(windows: [UsageWindow(name: "Plan", used: 10, resetsAt: .now.addingTimeInterval(3600))]))
        XCTAssertEqual(store.snapshots[.cursor]?.windows.first?.used, 10)
        XCTAssertEqual(Set(store.history.samples.map(\.accountID)), ["default-personal", work.id.uuidString])
        XCTAssertEqual(store.defaultSnapshots[.cursor]?.windows.first?.used, 60)
        await store.refresh(.cursor)?.value
        XCTAssertEqual(store.snapshots[.cursor]?.windows.first?.used, 15)
        XCTAssertEqual(store.history.samples.filter { $0.accountID == "default-personal" }.count, 1)

        accounts.select(nil, for: .cursor)
        XCTAssertEqual(store.snapshots[.cursor]?.windows.first?.used, 60)
        store.stop()
    }

    @MainActor func testAlertsUseFreshAccountScopedCrossings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "alerts.quota")
        let alerts = AlertCenter(defaults: defaults)
        let accounts = AccountStore(file: directory.appendingPathComponent("accounts.json"), saveSecret: { _, _ in }, removeSecret: { _ in })
        let store = Store(bridgeFile: directory.appendingPathComponent("usage.json"), accounts: accounts, alerts: alerts) { _, _, _, _ in
            UsageSnapshot(windows: [])
        }
        store.enabled = []
        store.start()
        store.enabled = [.cursor]
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        let reset = Date.now.addingTimeInterval(3600)
        let work = try accounts.add(provider: .cursor, label: "Work", credential: "test-only", snapshot:
            UsageSnapshot(windows: [UsageWindow(name: "Plan", used: 70, resetsAt: reset)], capturedAt: .now.addingTimeInterval(-10)))
        XCTAssertTrue(alerts.recent.isEmpty, "First reading must be quiet")
        accounts.onSnapshot?(work, UsageSnapshot(windows: [UsageWindow(name: "Plan", used: 85, resetsAt: reset)]))
        XCTAssertEqual(alerts.recent.count, 1)
        XCTAssertTrue(alerts.recent[0].body.contains("Work"))
        accounts.onSnapshot?(work, UsageSnapshot(windows: [UsageWindow(name: "Plan", used: 99, resetsAt: reset)], capturedAt: .now.addingTimeInterval(-700)))
        XCTAssertEqual(alerts.recent.count, 1)
        XCTAssertFalse(store.history.samples.contains { $0.used == 99 })
        store.enabled = []
        accounts.onSnapshot?(work, UsageSnapshot(windows: [UsageWindow(name: "Plan", used: 100, resetsAt: reset)]))
        XCTAssertFalse(store.history.samples.contains { $0.used == 100 })
    }

    @MainActor func testUnknownAccountsCanWarnWithoutPersistingUnattributedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "alerts.quota")
        let alerts = AlertCenter(defaults: defaults)
        let reads = UnknownAccountReads()
        let store = Store(bridgeFile: directory.appendingPathComponent("usage.json"), alerts: alerts) { _, _, _, _ in await reads.read() }
        store.enabled = []
        store.start()
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        store.enabled = [.codex]
        await store.refresh(.codex)?.value
        XCTAssertTrue(alerts.recent.isEmpty)
        await store.refresh(.codex)?.value
        XCTAssertEqual(alerts.recent.count, 1)
        XCTAssertTrue(store.history.samples.isEmpty)
    }
}
