import XCTest
import HoustonCore
@testable import Houston

final class ReviewRegressionTests: XCTestCase {
    @MainActor func testHistoricalRerunRetainsAnActiveCommandControl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner()
        let cloud = CloudStore(api: CloudAPI { _ in XCTFail("No network expected"); return Data() }, readSecret: { _, _ in nil })
        let store = ProjectStore(file: directory.appendingPathComponent("projects.json"), runner: runner, cloud: cloud,
                                 gitReader: { _ in GitProjectStatus(branch: "main", changedFiles: 0) }, portReader: { [] })
        defer { runner.shutdown(); store.stop() }
        store.section = .commands
        let command = ProjectCommand(name: "Sleep", command: "/bin/sleep 20")
        var project = HoustonProject(name: "Review", path: directory.path, commands: [command])
        XCTAssertTrue(store.save(project))
        let stopped = expectation(description: "first run stopped")
        runner.onCompletion = { _ in stopped.fulfill() }
        runner.run(project: project, command: command)
        runner.stop(id: command.id)
        await fulfillment(of: [stopped], timeout: 5)
        runner.onCompletion = nil
        project.commands = []
        XCTAssertTrue(store.save(project))
        let prior = try XCTUnwrap(runner.history.first)
        runner.run(project: project, command: ProjectCommand(id: prior.id, name: prior.commandName, command: prior.command))
        let active = try XCTUnwrap(runner.runs.first(where: \.isRunning))
        // The Commands view uses these controls, including unsaved historical reruns.
        XCTAssertTrue(store.commandControls(for: store.selected!).contains { $0.id == active.id }, "Historical rerun has no active command card or Stop button")
        XCTAssertTrue(store.selected!.commands.isEmpty, "Rerunning must not silently save deleted commands")
        let rerunStopped = expectation(description: "historical rerun stopped")
        runner.onCompletion = { _ in rerunStopped.fulfill() }
        runner.stop(id: active.id)
        await fulfillment(of: [rerunStopped], timeout: 5)
        XCTAssertTrue(store.commandControls(for: store.selected!).isEmpty)
        XCTAssertEqual(runner.history.count, 2)

        let edited = ProjectCommand(id: command.id, name: "Edited", command: "printf edited")
        project.commands = [edited]
        XCTAssertTrue(store.save(project))
        runner.onCompletion = nil
        runner.run(project: project, command: command)
        XCTAssertEqual(store.commandControls(for: project), [command], "Show the historical command actually running")
        let editedStopped = expectation(description: "old version stopped")
        runner.onCompletion = { _ in editedStopped.fulfill() }
        runner.stop(id: command.id)
        await fulfillment(of: [editedStopped], timeout: 5)
        XCTAssertEqual(store.commandControls(for: project), [edited], "Restore the saved command after the historical run finishes")
    }

    @MainActor func testHealthRefreshChecksCloudWhenLastSectionWasConnections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = CloudStore(api: CloudAPI { _ in XCTFail("No network expected"); return Data() }, readSecret: { _, _ in nil })
        let store = ProjectStore(file: directory.appendingPathComponent("projects.json"), cloud: cloud,
                                 gitReader: { _ in GitProjectStatus(branch: "main", changedFiles: 0) }, portReader: { [] })
        defer { store.stop() }
        store.section = .connections
        let project = HoustonProject(name: "Review", path: directory.path, vercelProjectID: "review-project")
        XCTAssertTrue(store.save(project))
        let secondDirectory = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let second = HoustonProject(name: "Other", path: secondDirectory.path, vercelProjectID: "other-project")
        XCTAssertTrue(store.save(second))
        XCTAssertNil(cloud.snapshot(for: project).states[.vercel])
        XCTAssertNil(cloud.snapshot(for: second).states[.vercel])
        await store.refreshConnections().value
        XCTAssertFalse(store.checkingConnections)
        for checked in [project, second] {
            for provider in CloudProvider.allCases {
                XCTAssertNotNil(cloud.snapshot(for: checked).states[provider]?.message, "Health refresh skipped a project connection")
            }
        }
        XCTAssertEqual(store.section, .connections)
        XCTAssertEqual(store.selectedID, second.id)
    }
    @MainActor func testPaletteRevealsHistoricalAgentSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(bridgeFile: directory.appendingPathComponent("usage.json"))
        for provider in AgentProvider.allCases {
            let payload: [String: Any] = ["session_id": "review-session", "conversation_id": "review-session",
                                         "cwd": directory.appendingPathComponent("missing").path,
                                         "workspace_roots": [directory.appendingPathComponent("missing").path],
                                         "hook_event_name": provider == .cursor ? "stop" : "Stop", "status": "completed"]
            try AgentBridge.capture(JSONSerialization.data(withJSONObject: payload), provider: provider,
                                    directory: directory, now: .now.addingTimeInterval(-86400))
        }
        store.agents.refresh(notify: false)
        XCTAssertEqual(store.agents.sessions.count, AgentProvider.allCases.count)
        var reveals = 0
        store.reveal = { reveals += 1 }
        for session in store.agents.sessions {
            XCTAssertFalse(session.isCurrent())
            let palette = CommandPaletteView(store: store)
            let action = try XCTUnwrap(palette.actions.first { $0.destination == .agent(session.id) })
            palette.activate(action)
            XCTAssertEqual(store.tab, .agents)
            XCTAssertTrue(store.expanded)
            XCTAssertEqual(store.agents.selectedSession, session)
        }
        XCTAssertEqual(reveals, AgentProvider.allCases.count)
        let selected = try XCTUnwrap(store.agents.selectedSession)
        store.agents.dismiss(session: selected)
        XCTAssertNil(store.agents.selectedSessionID)
    }
}
