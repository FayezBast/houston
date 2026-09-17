import XCTest
import SwiftUI
import HoustonCore
@testable import Houston

final class WorkflowTests: XCTestCase {
    @MainActor func testHistoryPreservesAttemptsRecoversInterruptionAndClearsOnlyOneProject() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let runner = CommandRunner(historyFile: file)
        let project = HoustonProject(name: "History", path: folder.path)
        let command = ProjectCommand(name: "Test", command: "printf saved-output")
        for index in 0..<2 {
            let completed = expectation(description: "Run \(index)")
            runner.onCompletion = { _ in completed.fulfill() }
            runner.run(project: project, command: command)
            await fulfillment(of: [completed], timeout: 8)
        }
        XCTAssertEqual(runner.runs.count, 1)
        XCTAssertEqual(runner.history.count, 2)
        XCTAssertEqual(Set(runner.history.map(\.runID)).count, 2)
        runner.flushHistory()
        let restored = CommandRunner(historyFile: file)
        XCTAssertEqual(restored.history, runner.history)
        XCTAssertEqual(restored.runs.first?.output, "saved-output")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let other = HoustonProject(name: "Other", path: folder.path)
        var records = restored.history
        records.insert(CommandRun(id: UUID(), projectID: other.id, commandName: "Unfinished", command: "sleep 30", path: folder.path,
                                  status: .running, output: "partial", startedAt: .now), at: 0)
        try JSONEncoder().encode(records).write(to: file)
        let recovered = CommandRunner(historyFile: file)
        XCTAssertEqual(recovered.history.first?.status, .interrupted)
        XCTAssertFalse(recovered.runs.contains(where: \.isRunning))
        XCTAssertTrue(recovered.history.first?.output.contains("not restarted") == true)
        recovered.clearHistory(projectID: project.id)
        recovered.flushHistory()
        XCTAssertEqual(CommandRunner(historyFile: file).history.map(\.projectID), [other.id])

        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)
        let broken = CommandRunner(historyFile: file)
        XCTAssertNotNil(broken.historyError)
        broken.clearHistory(projectID: other.id)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor func testPaletteMatchesAllWordsAndUpdateConfigRequiresHTTPSAndPublicKey() {
        let actions = [PaletteAction(id: "1", title: "Run Tests", detail: "Houston · swift test", symbol: "play", destination: .health),
                       PaletteAction(id: "2", title: "Open Mac", detail: "Houston", symbol: "gear", destination: .setup)]
        XCTAssertEqual(PaletteAction.matching(actions, query: "  HOUSTON tests ").map(\.id), ["1"])
        XCTAssertEqual(PaletteAction.matching(actions, query: "").count, 2)
        XCTAssertTrue(PaletteAction.matching(actions, query: "missing").isEmpty)
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertTrue(AppServices.validUpdateConfiguration(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key]))
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/appcast.xml", "invalid"] {
            XCTAssertFalse(AppServices.validUpdateConfiguration(["SUFeedURL": feed, "SUPublicEDKey": key]))
        }
        XCTAssertFalse(AppServices.validUpdateConfiguration(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "bad"]))
    }

    func testHookHealthDetectsMovedInstallMissingHookAndDisabledConfiguration() throws {
        let executable = URL(fileURLWithPath: "/Applications/Houston.app/Contents/MacOS/Houston")
        for provider in AgentProvider.allCases {
            let data = try AgentBridge.mergedConfiguration(nil, provider: provider, executable: executable)
            XCTAssertNil(AgentBridge.configurationIssue(data, provider: provider, executable: executable))
            XCTAssertNotNil(AgentBridge.configurationIssue(data, provider: provider, executable: URL(fileURLWithPath: "/tmp/Houston")))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
            hooks.removeValue(forKey: provider == .cursor ? "stop" : "Stop")
            object["hooks"] = hooks
            XCTAssertNotNil(AgentBridge.configurationIssue(try JSONSerialization.data(withJSONObject: object), provider: provider, executable: executable))
            object["disableAllHooks"] = true
            XCTAssertTrue(AgentBridge.configurationIssue(try JSONSerialization.data(withJSONObject: object), provider: provider, executable: executable)?.contains("disabled") == true)
        }
    }

    @MainActor func testWorkflowWindowsRender() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "houston.workflow-render." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Store(bridgeFile: folder.appendingPathComponent("usage.json"))
        store.enabled = [.codex]
        store.errors[.codex] = "Your sign-in has expired. Reconnect to read usage."
        for page in [UtilityPage.setup, .health, .palette] {
            // AppKit hosting renders controls and scroll views that ImageRenderer omits.
            let view = NSHostingView(rootView: UtilityContent(store: store, page: page).defaultAppStorage(defaults))
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 580)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let output = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("workflow-\(page).png"))
            }
            window.orderOut(nil)
        }
    }
}
