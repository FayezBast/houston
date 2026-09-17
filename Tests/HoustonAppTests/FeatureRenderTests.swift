import XCTest
import SwiftUI
import HoustonCore
@testable import Houston

/// Offscreen visual fixtures. All account and session writes stay in a temporary directory.
final class FeatureRenderTests: XCTestCase {
    @MainActor func testAgentHistoryLayoutsRender() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("houston-agent-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date.now
        for (id, event, age, project) in [("running", "UserPromptSubmit", 0.0, "Houston"),
                                           ("ended", "SessionEnd", 60.0, "Previous project"),
                                           ("completed", "Stop", 3600.0, "Yesterday's response"),
                                           ("stale", "PermissionRequest", 3600.0, "Earlier request") ] {
            let payload = ["session_id": id, "hook_event_name": event, "cwd": folder.appendingPathComponent(project).path]
            try AgentBridge.capture(JSONSerialization.data(withJSONObject: payload), provider: .codex, directory: folder, now: now.addingTimeInterval(-age))
        }
        let monitor = AgentMonitor(directory: folder)
        monitor.refresh(notify: false)
        for (name, scheme, width) in [("light", ColorScheme.light, CGFloat(460)), ("dark", .dark, 460), ("narrow", .light, 336), ("narrow-dark", .dark, 336)] {
            try await render(AgentSessionsView(monitor: monitor), name: "agents-history-" + name, scheme: scheme, width: width)
            monitor.selectedSessionID = "codex:completed"
            try await render(AgentSessionsView(monitor: monitor), name: "agents-selected-" + name, scheme: scheme, width: width)
            monitor.selectedSessionID = nil
        }
        monitor.dismiss(session: try XCTUnwrap(monitor.sessions.first { $0.sessionID == "running" }))
        try await render(AgentSessionsView(monitor: monitor), name: "agents-history-only", scheme: .light, width: 336)
        monitor.clearFinished()
        try await render(AgentSessionsView(monitor: monitor), name: "agents-history-cleared", scheme: .dark, width: 336)
    }

    @MainActor func testNewFeatureLayoutsRender() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("houston-feature-render-" + UUID().uuidString)
        let suite = "houston.feature-render." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let now = Date.now
        let accounts = AccountStore(file: folder.appendingPathComponent("accounts.json"), reader: { _, _ in
            XCTFail("Render fixtures must not request live account usage")
            return UsageSnapshot(windows: [])
        }, saveSecret: { _, _ in }, removeSecret: { _ in })
        let personal = UsageSnapshot(windows: [
            UsageWindow(name: "5-hour", used: 32, resetsAt: now.addingTimeInterval(7200)),
            UsageWindow(name: "Weekly", used: 44, resetsAt: now.addingTimeInterval(3 * 86_400))
        ], capturedAt: now)
        let work = UsageSnapshot(windows: [
            UsageWindow(name: "5-hour", used: 87, resetsAt: now.addingTimeInterval(3600)),
            UsageWindow(name: "Weekly", used: 68, resetsAt: now.addingTimeInterval(2 * 86_400))
        ], capturedAt: now)
        try accounts.add(provider: .claude, label: "Personal", credential: "render-only-personal", snapshot: personal)
        try accounts.add(provider: .claude, label: "Work", credential: "render-only-work", snapshot: work)

        // Preferences are preloaded before creating AlertCenter, so rendering never requests notification permission.
        defaults.set(true, forKey: "alerts.quota")
        defaults.set(true, forKey: "alerts.reset")
        defaults.set(true, forKey: "alerts.agents")
        defaults.set(true, forKey: "alerts.github")
        defaults.set(20.0, forKey: "alerts.remainingThreshold")
        let alerts = AlertCenter(defaults: defaults)
        let store = Store(bridgeFile: folder.appendingPathComponent("claude-usage.json"), accounts: accounts, alerts: alerts) { _, _, _, _ in
            XCTFail("Render fixtures must not start live usage requests")
            return UsageSnapshot(windows: [])
        }
        store.enabled = [.codex, .claude]
        store.snapshots[.claude] = work
        store.snapshots[.codex] = personal
        store.expanded = true
        store.pinned = true
        store.expandedHeight = 560

        for (id, provider, event, project) in [
            ("render-codex", AgentProvider.codex, "UserPromptSubmit", "Houston"),
            ("render-claude", .claude, "PermissionRequest", "API migration"),
            ("render-ready", .codex, "Stop", "Website"),
            ("render-failed", .claude, "StopFailure", "Integration tests")
        ] {
            let payload: [String: String] = ["session_id": id, "hook_event_name": event,
                                           "cwd": folder.appendingPathComponent(project).path]
            try AgentBridge.capture(JSONSerialization.data(withJSONObject: payload), provider: provider, directory: folder, now: now)
        }
        store.agents.refresh(notify: false)
        XCTAssertEqual(store.agents.sessions.count, 4)

        var history = UsageHistory()
        for day in (1...7).reversed() {
            for step in 0..<4 {
                let date = now.addingTimeInterval(-Double(day) * 86_400 + Double(step) * 600)
                let reset = now.addingTimeInterval(-Double(day) * 86_400 + 18_000)
                let reading = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: Double(10 + day * 4 + step * 12), resetsAt: reset)], capturedAt: date)
                history.record(snapshot: reading, provider: "Claude", accountID: "render-personal", accountLabel: "Personal", now: date)
            }
        }
        for (offset, used) in [(-600.0, 70.0), (0, 85)] {
            let date = now.addingTimeInterval(offset)
            history.record(snapshot: UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: used, resetsAt: now.addingTimeInterval(3600))], capturedAt: date),
                           provider: "Claude", accountID: "render-personal", accountLabel: "Personal", now: date)
            history.record(snapshot: UsageSnapshot(windows: [], capturedAt: date, spend: UsageSpend(used: offset == 0 ? 42.75 : 39.5, budget: 100)),
                           provider: "OpenRouter", accountID: "render-key", accountLabel: "Work API", now: date)
        }

        for (name, scheme, width) in [("light", ColorScheme.light, CGFloat(460)), ("dark", .dark, 460), ("narrow", .light, 336), ("narrow-dark", .dark, 336)] {
            try await render(UsageHistoryView(history: history), name: "feature-history-" + name, scheme: scheme, width: width)
            try await render(AccountsView(store: accounts, provider: .claude), name: "feature-accounts-" + name, scheme: scheme, width: width)
            try await render(AccountComparisonView(store: accounts, provider: .claude).frame(height: 190), name: "feature-comparison-" + name, scheme: scheme, width: width)
            try await render(AgentSessionsView(monitor: store.agents), name: "feature-agents-" + name, scheme: scheme, width: width)
            try await render(AlertSettingsView(alerts: alerts), name: "feature-alerts-" + name, scheme: scheme, width: width)
        }
        // Native hosting captures the complete island, including segmented navigation and scrolling content.
        for width in [CGFloat(336), 460] {
            store.expandedWidth = width
            for tab in [PanelTab.usage, .agents, .tools] {
                store.tab = tab
                try await render(IslandView(store: store), name: "feature-navigation-\(tab.rawValue.lowercased())-\(Int(width))",
                           scheme: .light, width: width, padding: 0)
                try await render(IslandView(store: store), name: "feature-navigation-\(tab.rawValue.lowercased())-\(Int(width))-dark",
                           scheme: .dark, width: width, padding: 0)
            }
        }
        store.tab = .usage
        store.expandedWidth = 336
        try await render(IslandView(store: store), name: "feature-navigation-high-contrast",
            scheme: .light, width: 336, padding: 0, highContrast: true)
        store.tab = .drop
        store.expandedHeight = 360
        let heldFolder = folder.appendingPathComponent("Design files")
        let heldFile = folder.appendingPathComponent("Launch notes.md")
        try FileManager.default.createDirectory(at: heldFolder, withIntermediateDirectories: true)
        try Data("Shelf render fixture".utf8).write(to: heldFile)
        for width in [CGFloat(336), 460] {
            store.expandedWidth = width
            store.dropShelf.clear()
            try await render(IslandView(store: store), name: "drop-empty-\(Int(width))", scheme: .dark, width: width, padding: 0)
            store.dropShelf.isTargeted = true
            try await render(IslandView(store: store), name: "drop-target-\(Int(width))", scheme: .dark, width: width, padding: 0)
            store.dropShelf.isTargeted = false
            store.dropShelf.hold([heldFolder, heldFile])
            try await render(IslandView(store: store), name: "drop-held-\(Int(width))", scheme: .dark, width: width, padding: 0)
        }
        store.stop()
    }

    @MainActor private func render<V: View>(_ view: V, name: String, scheme: ColorScheme, width: CGFloat, padding: CGFloat = 20, highContrast: Bool = false) async throws {
        let content = view.padding(padding).frame(width: width)
            .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97))
            .environment(\.colorScheme, scheme)
        // Host real AppKit controls; ImageRenderer draws placeholders for native pickers and text fields.
        let hosting = NSHostingView(rootView: content)
        if highContrast { hosting.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua) }
        let size = NSSize(width: width, height: max(60, hosting.fittingSize.height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(35))
        hosting.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = try XCTUnwrap(representation.cgImage, "\(name) must render")
        XCTAssertEqual(image.width, Int(width * (window.backingScaleFactor)), name)
        XCTAssertGreaterThan(image.height, 50, name)
        guard let path = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
