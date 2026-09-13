import Foundation
import Darwin

public struct ProjectCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public init(id: UUID = UUID(), name: String, command: String) {
        self.id = id; self.name = name; self.command = command
    }
}

public struct HoustonProject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var editorBundleID: String
    public var webURL: String
    public var commands: [ProjectCommand]
    public var vercelProjectID: String
    public var vercelTeamID: String
    public var sentryOrganization: String
    public var sentryProject: String
    public var sentryEnvironment: String
    public var linearProjectID: String

    public init(id: UUID = UUID(), name: String, path: String, editorBundleID: String = "", webURL: String = "",
                commands: [ProjectCommand] = [], vercelProjectID: String = "", vercelTeamID: String = "",
                sentryOrganization: String = "", sentryProject: String = "", sentryEnvironment: String = "", linearProjectID: String = "") {
        self.id = id; self.name = name; self.path = path; self.editorBundleID = editorBundleID; self.webURL = webURL
        self.commands = commands; self.vercelProjectID = vercelProjectID; self.vercelTeamID = vercelTeamID
        self.sentryOrganization = sentryOrganization; self.sentryProject = sentryProject
        self.sentryEnvironment = sentryEnvironment; self.linearProjectID = linearProjectID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, editorBundleID, webURL, commands, vercelProjectID, vercelTeamID
        case sentryOrganization, sentryProject, sentryEnvironment, linearProjectID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        editorBundleID = try values.decodeIfPresent(String.self, forKey: .editorBundleID) ?? ""
        webURL = try values.decodeIfPresent(String.self, forKey: .webURL) ?? ""
        commands = try values.decodeIfPresent([ProjectCommand].self, forKey: .commands) ?? []
        vercelProjectID = try values.decodeIfPresent(String.self, forKey: .vercelProjectID) ?? ""
        vercelTeamID = try values.decodeIfPresent(String.self, forKey: .vercelTeamID) ?? ""
        sentryOrganization = try values.decodeIfPresent(String.self, forKey: .sentryOrganization) ?? ""
        sentryProject = try values.decodeIfPresent(String.self, forKey: .sentryProject) ?? ""
        sentryEnvironment = try values.decodeIfPresent(String.self, forKey: .sentryEnvironment) ?? ""
        linearProjectID = try values.decodeIfPresent(String.self, forKey: .linearProjectID) ?? ""
    }
}

public enum ProjectLibrary {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Houston/projects.json")
    }

    public static func load(from url: URL) throws -> [HoustonProject] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let projects = try JSONDecoder().decode([HoustonProject].self, from: Data(contentsOf: url))
        try validate(projects)
        return projects
    }

    public static func save(_ projects: [HoustonProject], to url: URL) throws {
        try validate(projects)
        // Do not replace an unreadable library with an empty one after a failed load.
        if FileManager.default.fileExists(atPath: url.path) { _ = try load(from: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(projects).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func normalizedDirectory(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0") else { throw UsageError.unavailable("Choose a project folder.") }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw UsageError.unavailable("Choose an absolute project folder path.") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw UsageError.unavailable("This project folder is no longer available.")
        }
        return url.path
    }

    private static func validate(_ projects: [HoustonProject]) throws {
        let commandIDs = projects.flatMap(\.commands).map(\.id)
        guard Set(projects.map(\.id)).count == projects.count, Set(commandIDs).count == commandIDs.count else {
            throw UsageError.unavailable("The project library contains duplicate IDs. Restore or repair projects.json before saving.")
        }
    }
}

public struct GitProjectStatus: Equatable, Sendable {
    public let branch: String
    public let changedFiles: Int
    public let remote: String?
    public init(branch: String, changedFiles: Int, remote: String? = nil) {
        self.branch = branch; self.changedFiles = changedFiles; self.remote = remote
    }
}

public struct LocalPort: Equatable, Identifiable, Sendable {
    public var id: String { "\(pid):\(address):\(port)" }
    public let pid: Int32
    public let process: String
    public let port: Int
    public let address: String
    public var projectPath: String?
    public var cpuPercent: Double?
    public var memoryMB: Double?
    public var userID: UInt32?
    public var processIdentity: String?
    public var url: URL? {
        let host = ["*", "0.0.0.0", "[::]"].contains(address) ? "localhost" : address
        return URL(string: "http://\(host):\(port)")
    }
    public init(pid: Int32, process: String, port: Int, address: String, projectPath: String? = nil,
                cpuPercent: Double? = nil, memoryMB: Double? = nil, userID: UInt32? = nil, processIdentity: String? = nil) {
        self.pid = pid; self.process = process; self.port = port; self.address = address
        self.projectPath = projectPath; self.cpuPercent = cpuPercent; self.memoryMB = memoryMB
        self.userID = userID; self.processIdentity = processIdentity
    }
}

public struct DockerContainer: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String
    public let ports: String
    public var cpuPercent: Double?
    public var memory: String?
    public var isRunning: Bool { state == "running" }
    public init(id: String, name: String, image: String, state: String, status: String, ports: String,
                cpuPercent: Double? = nil, memory: String? = nil) {
        self.id = id; self.name = name; self.image = image; self.state = state; self.status = status; self.ports = ports
        self.cpuPercent = cpuPercent; self.memory = memory
    }
}

public enum DockerAction: String, CaseIterable, Sendable { case start, stop, restart }

public enum ProjectTools {
    public static func readGit(path: String) throws -> GitProjectStatus {
        let path = try ProjectLibrary.normalizedDirectory(path)
        // Git status can invoke a configured fsmonitor hook; disable hooks and optional writes for inspection.
        let prefix = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", path]
        let status = try BoundedProjectProcess.run("git", prefix + ["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
        let branchResult = try BoundedProjectProcess.run("git", prefix + ["symbolic-ref", "--short", "-q", "HEAD"], allowedExitCodes: [0, 1])
        let branch = branchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let detached = branch.isEmpty ? try BoundedProjectProcess.run("git", prefix + ["rev-parse", "--short", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let remote = try BoundedProjectProcess.run("git", prefix + ["config", "--get", "remote.origin.url"], allowedExitCodes: [0, 1]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitProjectStatus(branch: branch.isEmpty ? "Detached · " + detached : branch,
                                changedFiles: changedFileCount(status.output), remote: remote.isEmpty ? nil : remote)
    }

    static func changedFileCount(_ data: Data) -> Int {
        let records = data.split(separator: 0)
        var count = 0, index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else { index += 1; continue }
            count += 1
            let status = Array(record.prefix(2))
            index += status.contains(82) || status.contains(67) ? 2 : 1 // Renames/copies contain a second NUL-delimited path.
        }
        return count
    }

    public static func readPorts() throws -> [LocalPort] {
        let result = try BoundedProjectProcess.run("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcun"], allowedExitCodes: [0, 1])
        var ports = parsePorts(result.text)
        guard !ports.isEmpty else { return [] }
        let processes = try processDetails()
        let ids = Set(ports.map(\.pid)).sorted().map(String.init).joined(separator: ",")
        let directories = try? BoundedProjectProcess.run("lsof", ["-a", "-p", ids, "-d", "cwd", "-Fpn"], allowedExitCodes: [0, 1])
        let paths = parseWorkingDirectories(directories?.text ?? "")
        for index in ports.indices {
            let detail = processes[ports[index].pid]
            ports[index].projectPath = paths[ports[index].pid]
            ports[index].cpuPercent = detail?.cpu
            ports[index].memoryMB = detail?.memory
            ports[index].processIdentity = detail?.identity
            ports[index].userID = detail?.uid ?? ports[index].userID
        }
        return ports.sorted { ($0.port, $0.pid, $0.address) < ($1.port, $1.pid, $1.address) }
    }

    static func parsePorts(_ text: String) -> [LocalPort] {
        var pid: Int32?, process = "", uid: UInt32?, ports: [LocalPort] = []
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value); process = ""; uid = nil
            case "c": process = value
            case "u": uid = UInt32(value)
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { continue }
                let listener = LocalPort(pid: pid, process: process, port: port, address: String(value[..<colon]), userID: uid)
                if !ports.contains(where: { $0.id == listener.id }) { ports.append(listener) }
            default: break
            }
        }
        return ports
    }

    static func parseWorkingDirectories(_ text: String) -> [Int32: String] {
        var pid: Int32?, result: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "n", let pid { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    public static func stop(port: LocalPort) throws {
        _ = try validatedProcessGroup(port: port)
        guard Darwin.kill(port.pid, SIGTERM) == 0 else { throw UsageError.unavailable("The process could not be stopped: " + String(cString: strerror(errno))) }
    }

    /// Revalidate the selected listener before mapping it to a command owned by Houston.
    public static func validatedProcessGroup(port: LocalPort) throws -> Int32 {
        guard port.pid > 1, port.pid != getpid(), port.userID == getuid(), let identity = port.processIdentity else {
            throw UsageError.unavailable("Houston can only stop a verified process owned by your account.")
        }
        let fresh = try BoundedProjectProcess.run("lsof", ["-nP", "-a", "-p", String(port.pid), "-iTCP", "-sTCP:LISTEN", "-Fpcun"], allowedExitCodes: [0, 1])
        guard parsePorts(fresh.text).contains(where: { $0.id == port.id && $0.process == port.process && $0.userID == getuid() }),
              let current = processIdentity(pid: port.pid), current.uid == getuid(), current.identity == identity else {
            throw UsageError.unavailable("This listener changed. Refresh the list before stopping it.")
        }
        return current.groupID
    }

    private static func processIdentity(pid: Int32) -> (uid: UInt32, identity: String, groupID: Int32)? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return (info.pbi_uid, "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)", Int32(info.pbi_pgid))
    }

    private struct ProcessDetail {
        var uid: UInt32
        var cpu: Double?
        var memory: Double?
        var identity: String?
    }

    private static func processDetails(pid: Int32? = nil) throws -> [Int32: ProcessDetail] {
        let selection = pid.map { ["-p", String($0)] } ?? ["-ax"]
        let result = try BoundedProjectProcess.run("ps", selection + ["-o", "pid=,uid=,%cpu=,rss=,lstart=,comm="], allowedExitCodes: [0, 1])
        var details: [Int32: ProcessDetail] = [:]
        for line in result.text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10, let pid = Int32(fields[0]), let uid = UInt32(fields[1]) else { continue }
            details[pid] = ProcessDetail(uid: uid, cpu: Double(fields[2]), memory: Double(fields[3]).map { $0 / 1024 }, identity: processIdentity(pid: pid)?.identity)
        }
        return details
    }

    public static func dockerContainers() throws -> [DockerContainer] {
        let result = try BoundedProjectProcess.run("docker", ["ps", "--all", "--no-trunc", "--format", "{{json .}}"])
        var containers = try parseDockerContainers(result.text)
        let running = containers.filter(\.isRunning).map(\.id)
        if !running.isEmpty, let stats = try? BoundedProjectProcess.run("docker", ["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"] + running) {
            let rows = try parseDockerJSON(stats.text)
            for index in containers.indices {
                if let row = rows.first(where: { $0["ID"] == containers[index].id || $0["Container"] == containers[index].id || $0["Name"] == containers[index].name }) {
                    containers[index].cpuPercent = row["CPUPerc"].flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
                    containers[index].memory = row["MemUsage"]
                }
            }
        }
        return containers.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
    }

    static func validContainerID(_ id: String) -> Bool {
        (12...64).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func parseDockerContainers(_ text: String) throws -> [DockerContainer] {
        try parseDockerJSON(text).compactMap { row in
            guard let id = row["ID"], validContainerID(id) else { return nil }
            return DockerContainer(id: id, name: row["Names"] ?? String(id.prefix(12)), image: row["Image"] ?? "",
                                   state: row["State"] ?? "unknown", status: row["Status"] ?? "", ports: row["Ports"] ?? "")
        }
    }

    private static func parseDockerJSON(_ text: String) throws -> [[String: String]] {
        try text.split(separator: "\n").map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
    }

    public static func dockerLogs(id: String) throws -> String {
        guard validContainerID(id) else { throw UsageError.unavailable("The container ID is invalid. Refresh containers.") }
        let result = try BoundedProjectProcess.run("docker", ["logs", "--tail", "300", "--timestamps", id])
        return result.text + (result.errors.isEmpty ? "" : "\n" + result.errors)
    }

    public static func dockerAction(id: String, action: DockerAction) throws {
        guard validContainerID(id) else { throw UsageError.unavailable("The container ID is invalid. Refresh containers.") }
        _ = try BoundedProjectProcess.run("docker", [action.rawValue, id], timeout: 30)
    }
}

/// A bounded CLI reader: drains both pipes, caps retained bytes, and never invokes a shell.
/// Kept separate from LocalCommand because project errors must preserve stderr diagnostics.
private enum BoundedProjectProcess {
    struct Result {
        let output: Data
        let stderr: Data
        var text: String { String(decoding: output, as: UTF8.self) }
        var errors: String { String(decoding: stderr, as: UTF8.self) }
    }

    static func run(_ name: String, _ arguments: [String], timeout: TimeInterval = 12, allowedExitCodes: Set<Int32> = [0]) throws -> Result {
        let executable = LocalCommand.executable(name) ?? ["/bin", "/sbin", "/usr/sbin"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let executable else { throw UsageError.unavailable("Install \(name) to use this tool.") }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdoutFD = output.fileHandleForReading.fileDescriptor, stderrFD = errors.fileHandleForReading.fileDescriptor
        for fd in [stdoutFD, stderrFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        try process.run()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close() }
        var stdout = Data(), stderr = Data(), timedOut = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func drain(_ descriptor: Int32, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Bound each sweep as well as retained output so a noisy child cannot prevent timeout checks.
            for _ in 0..<32 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 524_288 { data.removeFirst(data.count - 524_288) }
            }
        }
        while process.isRunning {
            drain(stdoutFD, into: &stdout); drain(stderrFD, into: &stderr)
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true; process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.3
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        drain(stdoutFD, into: &stdout); drain(stderrFD, into: &stderr)
        let result = Result(output: stdout, stderr: stderr)
        if timedOut { throw UsageError.unavailable("\(name) took too long. Check that the tool is responding, then refresh.") }
        guard allowedExitCodes.contains(process.terminationStatus) else {
            let detail = (result.errors.isEmpty ? result.text : result.errors).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageError.unavailable(detail.isEmpty ? "\(name) exited with status \(process.terminationStatus)." : String(detail.suffix(2000)))
        }
        return result
    }
}
