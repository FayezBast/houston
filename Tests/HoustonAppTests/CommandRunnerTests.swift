import XCTest
import HoustonCore
@testable import Houston

final class CommandRunnerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("houston-command-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor func testCommandTracksWorkingDirectoryOutputExitAndRerun() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner(), project = HoustonProject(name: "Fixture", path: directory.path)
        var command = ProjectCommand(name: "Test", command: "pwd; printf 'stdout marker'; printf 'stderr marker' >&2; exit 7")
        let failure = expectation(description: "failed command")
        runner.onCompletion = { _ in failure.fulfill() }
        runner.run(project: project, command: command)
        runner.run(project: project, command: command)
        XCTAssertEqual(runner.runs.count, 1, "A repeated click must not launch a duplicate")
        await fulfillment(of: [failure], timeout: 8)
        let failed = try XCTUnwrap(runner.runs.first)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.exitCode, 7)
        XCTAssertTrue(failed.output.contains(directory.resolvingSymlinksInPath().path))
        XCTAssertTrue(failed.output.contains("stdout marker"))
        XCTAssertTrue(failed.output.contains("stderr marker"))
        XCTAssertNotNil(failed.endedAt)
        command.command = "printf success"
        let success = expectation(description: "successful rerun")
        runner.onCompletion = { _ in success.fulfill() }
        runner.run(project: project, command: command)
        await fulfillment(of: [success], timeout: 8)
        XCTAssertEqual(runner.runs.count, 1)
        XCTAssertEqual(runner.runs.first?.status, .succeeded)
        XCTAssertEqual(runner.runs.first?.output, "success")
    }

    @MainActor func testStopCancelsOnlyOwnedCommandGroupAndItsChildren() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner(), project = HoustonProject(name: "Fixture", path: directory.path)
        let command = ProjectCommand(name: "Server", command: "sleep 60 & echo $! > child.pid; wait")
        let stopped = expectation(description: "cancelled command")
        runner.onCompletion = { _ in stopped.fulfill() }
        runner.run(project: project, command: command)
        let childFile = directory.appendingPathComponent("child.pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: childFile.path) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let child = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(child, 0), 0)
        runner.stop(id: command.id)
        await fulfillment(of: [stopped], timeout: 8)
        XCTAssertEqual(runner.runs.first?.status, .cancelled)
        // A terminated child may briefly remain a zombie until launchd reaps it.
        let state = try? LocalCommand.run("ps", ["-p", String(child), "-o", "stat="])
        XCTAssertTrue(state == nil || String(decoding: state!, as: UTF8.self).contains("Z"), "The dev server child must no longer be executing")
        XCTAssertEqual(kill(getpid(), 0), 0)
    }

    @MainActor func testOutputPreservesUTF8AcrossBatchesAndFlushesIncompleteFinalBytes() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner(), completed = expectation(description: "streamed Unicode output")
        defer { runner.shutdown() }
        runner.onCompletion = { _ in completed.fulfill() }
        let command = #"printf 'prefix \303'; sleep 0.2; printf '\251 \342'; sleep 0.2; printf '\202'; sleep 0.2; printf '\254 \360\237'; sleep 0.2; printf '\232\200 suffix\342'"#
        runner.run(project: HoustonProject(name: "Fixture", path: directory.path), command: ProjectCommand(name: "Unicode", command: command))
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertEqual(runner.runs.first?.status, .succeeded)
        XCTAssertEqual(runner.runs.first?.output, "prefix é € 🚀 suffix�")
    }

    @MainActor func testShutdownWaitsForOwnedChildrenAndLeavesUnrelatedProcessAlone() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        let runner = CommandRunner(), project = HoustonProject(name: "Fixture", path: directory.path)
        runner.run(project: project, command: ProjectCommand(name: "Server", command: "sleep 60 & echo $! > child.pid; wait"))
        let childFile = directory.appendingPathComponent("child.pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: childFile.path) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let child = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        runner.shutdown()
        let state = try? LocalCommand.run("ps", ["-p", String(child), "-o", "stat="])
        XCTAssertTrue(state == nil || String(decoding: state!, as: UTF8.self).contains("Z"))
        XCTAssertTrue(unrelated.isRunning, "Quitting must leave outside processes untouched")
    }

    @MainActor func testStoppingSavedServersThroughPortControlsCancelsTheirCommands() async throws {
        for shellCommand in ["/usr/bin/python3 -u server.py", "/usr/bin/python3 -u server.py & wait"] {
            let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
            try "import socket,pathlib,time,os; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); pathlib.Path('pid.txt').write_text(str(os.getpid())); pathlib.Path('port.txt').write_text(str(s.getsockname()[1])); time.sleep(30)".write(to: directory.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
            let runner = CommandRunner()
            let store = ProjectStore(file: directory.appendingPathComponent("projects.json"), runner: runner)
            defer { store.stop(); runner.shutdown() }
            let project = HoustonProject(name: "Fixture", path: directory.path)
            let command = ProjectCommand(name: "Server", command: shellCommand)
            runner.run(project: project, command: command)
            let portFile = directory.appendingPathComponent("port.txt")
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: portFile.path) { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            let number = try XCTUnwrap(Int(String(contentsOf: portFile, encoding: .utf8)))
            let pid = try XCTUnwrap(Int32(String(contentsOf: directory.appendingPathComponent("pid.txt"), encoding: .utf8)))
            let listener = try XCTUnwrap(ProjectTools.readPorts().first { $0.port == number && $0.pid == pid })
            let stopped = expectation(description: "port control completes saved server")
            var completedStatus: CommandRun.Status?
            store.onCompletion = { run in completedStatus = run.status; stopped.fulfill() }
            var stale = listener; stale.processIdentity = "reused PID"
            do { try await runner.stop(port: stale); XCTFail("A stale listener must be rejected") }
            catch { XCTAssertTrue(runner.runs.first?.isRunning == true) }
            store.stopPort(listener)
            await fulfillment(of: [stopped], timeout: 8)
            XCTAssertEqual(runner.runs.first?.status, .cancelled, shellCommand)
            XCTAssertEqual(completedStatus, .cancelled, "An intentional server stop must not emit a failed-command completion")
        }
    }

    @MainActor func testExit143WithoutAnIntentionalStopRemainsAFailure() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner(), completed = expectation(description: "ordinary exit 143")
        runner.onCompletion = { _ in completed.fulfill() }
        runner.run(project: HoustonProject(name: "Fixture", path: directory.path), command: ProjectCommand(name: "Exit", command: "exit 143"))
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertEqual(runner.runs.first?.status, .failed)
        XCTAssertEqual(runner.runs.first?.exitCode, 143)
    }

    @MainActor func testInvalidProjectFailsWithoutExecutingCommandAndLogsStayBounded() async throws {
        let runner = CommandRunner()
        runner.run(project: HoustonProject(name: "Missing", path: "/houston-missing-" + UUID().uuidString), command: ProjectCommand(name: "No", command: "touch should-not-exist"))
        XCTAssertEqual(runner.runs.first?.status, .failed)
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let completed = expectation(description: "large output")
        runner.onCompletion = { _ in completed.fulfill() }
        runner.run(project: HoustonProject(name: "Fixture", path: directory.path), command: ProjectCommand(name: "Output", command: "head -c 400000 /dev/zero | tr '\\0' x"))
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertEqual(runner.runs.first?.status, .succeeded)
        XCTAssertLessThanOrEqual(runner.runs.first?.output.utf8.count ?? 0, 131_072)
    }
}
