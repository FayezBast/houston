import XCTest
@testable import HoustonCore

final class ProjectToolsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("houston-project-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testProjectLibraryRoundTripAndCorruptionPreservation() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("projects.json")
        let project = HoustonProject(name: "My app", path: directory.path, commands: [ProjectCommand(name: "Test", command: "swift test")], vercelProjectID: "prj_123")
        XCTAssertEqual(try ProjectLibrary.load(from: url), [])
        try ProjectLibrary.save([project], to: url)
        XCTAssertEqual(try ProjectLibrary.load(from: url), [project])
        XCTAssertEqual(try ProjectLibrary.normalizedDirectory(directory.appendingPathComponent(".").path), directory.resolvingSymlinksInPath().path)
        XCTAssertThrowsError(try ProjectLibrary.normalizedDirectory(directory.appendingPathComponent("missing").path))
        let corrupted = Data("{ unreadable".utf8)
        try corrupted.write(to: url)
        XCTAssertThrowsError(try ProjectLibrary.load(from: url))
        XCTAssertThrowsError(try ProjectLibrary.save([], to: url))
        XCTAssertEqual(try Data(contentsOf: url), corrupted)
    }

    func testProjectLibraryDecodesMissingOptionalConfigurationAndRejectsDuplicateIDs() throws {
        let json = "[{\"id\":\"\(UUID())\",\"name\":\"App\",\"path\":\"/tmp/app\"}]"
        let projects = try JSONDecoder().decode([HoustonProject].self, from: Data(json.utf8))
        XCTAssertEqual(projects.first?.commands, [])
        XCTAssertEqual(projects.first?.sentryEnvironment, "")
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("projects.json")
        XCTAssertThrowsError(try ProjectLibrary.save(projects + projects, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testGitCountsRenameRecordsAndDoesNotExecuteConfiguredMonitor() throws {
        XCTAssertEqual(ProjectTools.changedFileCount(Data(" M one\0R  new\0old\0?? file\nname\0".utf8)), 3)
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = try LocalCommand.run("git", ["init", "-b", "main", directory.path])
        let marker = directory.appendingPathComponent("executed")
        let hook = directory.appendingPathComponent("monitor.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try LocalCommand.run("git", ["-C", directory.path, "config", "core.fsmonitor", hook.path])
        _ = try LocalCommand.run("git", ["-C", directory.path, "config", "remote.origin.url", "git@github.com:dev/project.git"])
        let result = try ProjectTools.readGit(path: directory.path)
        XCTAssertEqual(result.branch, "main")
        XCTAssertEqual(result.changedFiles, 1)
        XCTAssertEqual(result.remote, "git@github.com:dev/project.git")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testListeningPortsParseIPv4IPv6AndRepeatedDescriptors() throws {
        let parsed = ProjectTools.parsePorts("p42\ncnode\nu501\nn*:3000\nn*:3000\nn[::1]:8080\np76\ncpython\nu502\nn127.0.0.1:5000\nninvalid\nn*:99999\n")
        XCTAssertEqual(parsed.map(\.port), [3000, 8080, 5000])
        XCTAssertEqual(parsed[1].address, "[::1]")
        XCTAssertEqual(parsed[1].url?.absoluteString, "http://[::1]:8080")
        XCTAssertEqual(parsed[0].userID, 501)
        XCTAssertEqual(ProjectTools.parseWorkingDirectories("p42\nn/Users/dev/My app\np76\nn/tmp/other\n")[42], "/Users/dev/My app")
        XCTAssertThrowsError(try ProjectTools.stop(port: LocalPort(pid: -1, process: "bad", port: 3000, address: "*")))
        XCTAssertThrowsError(try ProjectTools.stop(port: LocalPort(pid: getpid(), process: "self", port: 3000, address: "*", userID: getuid(), processIdentity: "self")))
    }

    func testLiveListenerIsRecognizedAndStaleIdentityCannotStopIt() throws {
        guard let python = LocalCommand.executable("python3") else { throw XCTSkip("Python is not installed") }
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("port.txt")
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import socket,time,pathlib; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); pathlib.Path('port.txt').write_text(str(s.getsockname()[1])); time.sleep(30)"]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) || !process.isRunning { break }
            usleep(20_000)
        }
        guard FileManager.default.fileExists(atPath: ready.path) else { throw XCTSkip("Loopback listener could not start in this environment") }
        let number = try XCTUnwrap(Int(String(contentsOf: ready, encoding: .utf8)))
        let listener = try XCTUnwrap(ProjectTools.readPorts().first { $0.pid == process.processIdentifier && $0.port == number })
        XCTAssertEqual(listener.projectPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, directory.resolvingSymlinksInPath().path)
        XCTAssertNotNil(listener.processIdentity)
        XCTAssertEqual(listener.userID, getuid())
        var stale = listener; stale.processIdentity = "stale process identity"
        XCTAssertThrowsError(try ProjectTools.stop(port: stale))
        XCTAssertTrue(process.isRunning)
        try ProjectTools.stop(port: listener)
        for _ in 0..<100 {
            if !process.isRunning { break }
            usleep(20_000)
        }
        XCTAssertFalse(process.isRunning)
    }

    func testContainerParsingAndActionIDsNeverBecomeOptionsOrShell() throws {
        let containers = try ProjectTools.parseDockerContainers(#"{"ID":"0123456789abcdef","Names":"db","Image":"postgres:17","State":"running","Status":"Up 2 hours","Ports":"0.0.0.0:5432->5432/tcp"}"#)
        XCTAssertEqual(containers.first?.name, "db")
        XCTAssertEqual(containers.first?.isRunning, true)
        XCTAssertTrue(ProjectTools.validContainerID(String(repeating: "a", count: 64)))
        for id in ["--help", "db; touch marker", "$(echo bad)", "../../../tmp", "123", "abc\n0123456789ab", "0123456789ab\n"] {
            XCTAssertFalse(ProjectTools.validContainerID(id))
            XCTAssertThrowsError(try ProjectTools.dockerAction(id: id, action: .stop))
            XCTAssertThrowsError(try ProjectTools.dockerLogs(id: id))
        }
        XCTAssertThrowsError(try ProjectTools.parseDockerContainers("not json"))
    }
}
