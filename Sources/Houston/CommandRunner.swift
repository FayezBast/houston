import Foundation
import Combine
import Darwin
import HoustonCore

struct CommandRun: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Codable, Sendable { case running, succeeded, failed, cancelled, interrupted }
    var runID = UUID()
    /// The saved command ID; the latest result and each historical attempt have separate identities.
    let id: UUID
    let projectID: UUID
    let commandName: String
    let command: String
    let path: String
    var status: Status
    var output: String
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var isRunning: Bool { status == .running }
    var duration: TimeInterval { max(0, (endedAt ?? (isRunning ? .now : startedAt)).timeIntervalSince(startedAt)) }
}

@MainActor final class CommandRunner: ObservableObject {
    @Published private(set) var runs: [CommandRun] = []
    @Published private(set) var history: [CommandRun] = []
    @Published private(set) var historyError: String?
    private let historyFile: URL?
    private var historyReadable = true
    private var saveTask: Task<Void, Never>?
    private let historyQueue = DispatchQueue(label: "dev.houston.command-history", qos: .utility)
    private var saveRevision = 0

    init(historyFile: URL? = nil) {
        self.historyFile = historyFile
        guard let historyFile, FileManager.default.fileExists(atPath: historyFile.path) else { return }
        do {
            let data = try Data(contentsOf: historyFile)
            guard data.count <= 32_000_000 else { throw UsageError.unavailable("Command history is too large to read.") }
            history = Array(try JSONDecoder().decode([CommandRun].self, from: data).prefix(100)).map { saved in
                var run = saved
                if run.isRunning {
                    run.status = .interrupted
                    run.endedAt = nil
                    run.output += "\n[Houston closed before recording a final result. This command was not restarted.]"
                }
                return run
            }
            var seen = Set<UUID>()
            runs = history.filter { seen.insert($0.id).inserted }
        } catch {
            historyReadable = false
            historyError = "Command history could not be read and was left untouched. " + error.localizedDescription
        }
    }

    func clearHistory(projectID: UUID) {
        guard historyReadable else { return }
        history.removeAll { $0.projectID == projectID }
        runs.removeAll { $0.projectID == projectID && !$0.isRunning }
        persistHistory()
    }

    private func scheduleSave() {
        guard historyFile != nil, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.persistHistory()
        }
    }

    /// A serial queue preserves write order and keeps bounded log encoding off the UI thread.
    private func persistHistory() {
        guard let historyFile, historyReadable else { return }
        let records = Array((runs.filter(\.isRunning) + history).prefix(100))
        saveRevision += 1
        let revision = saveRevision
        historyQueue.async { [weak self] in
            let error = Self.writeHistory(records, to: historyFile)
            Task { @MainActor [weak self] in
                guard let self, self.saveRevision == revision else { return }
                self.historyError = error
            }
        }
    }

    /// Only shutdown and persistence checks wait for disk; normal operation remains asynchronous.
    func flushHistory() { historyQueue.sync {} }

    private nonisolated static func writeHistory(_ records: [CommandRun], to historyFile: URL) -> String? {
        do {
            let directory = historyFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".commands-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            // Set permissions before writing logs, which may include sensitive command output.
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw UsageError.unavailable("Could not create the command history file.")
            }
            try JSONEncoder().encode(records).write(to: temporary)
            guard rename(temporary.path, historyFile.path) == 0 else { throw POSIXError(.EIO) }
            return nil
        } catch { return "Command history could not be saved. " + error.localizedDescription }
    }

    var onCompletion: ((CommandRun) -> Void)?
    private var jobs: [UUID: CommandProcessGroup] = [:]
    private var generations: [UUID: UUID] = [:]

    func run(project: HoustonProject, command: ProjectCommand) {
        guard jobs[command.id] == nil else { return }
        let generation = UUID()
        generations[command.id] = generation
        let run = CommandRun(id: command.id, projectID: project.id, commandName: command.name,
                             command: command.command, path: project.path, status: .running, output: "", startedAt: .now)
        runs.removeAll { $0.id == command.id }
        runs.insert(run, at: 0)
        // Retain recent results; active servers always remain visible.
        if runs.count > 100 { runs = Array(runs.filter(\.isRunning)) + Array(runs.filter { !$0.isRunning }.prefix(max(0, 100 - runs.filter(\.isRunning).count))) }
        persistHistory()
        do {
            let path = try ProjectLibrary.normalizedDirectory(project.path)
            guard !command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.command.contains("\0") else {
                throw UsageError.unavailable("Enter a command before running it.")
            }
            let job = try CommandProcessGroup(command: command.command, path: path, onOutput: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generations[command.id] == generation,
                          let index = self.runs.firstIndex(where: { $0.id == command.id }) else { return }
                    self.runs[index].output += text
                    if self.runs[index].output.utf8.count > 131_072 {
                        self.runs[index].output = "[Earlier output omitted]\n" + String(decoding: self.runs[index].output.utf8.suffix(65_536).drop(while: { $0 & 0xc0 == 0x80 }), as: UTF8.self)
                    }
                    self.scheduleSave()
                }
            }, onExit: { [weak self] code, cancelled in
                Task { @MainActor in
                    guard let self, self.generations[command.id] == generation else { return }
                    self.finish(id: command.id, code: code, cancelled: cancelled)
                }
            })
            jobs[command.id] = job
            job.observe()
        } catch {
            if let index = runs.firstIndex(where: { $0.id == command.id }) { runs[index].output = error.localizedDescription }
            finish(id: command.id, code: -1, cancelled: false)
        }
    }

    func stop(id: UUID) { jobs[id]?.cancel() }

    func stop(port: LocalPort) async throws {
        let active = Array(jobs.values)
        try await Task.detached(priority: .userInitiated) {
            let groupID = try ProjectTools.validatedProcessGroup(port: port)
            if let job = active.first(where: { $0.processGroupID == groupID }), job.cancel() { return }
            // Outside commands retain the existing fresh identity check and single-process SIGTERM.
            try ProjectTools.stop(port: port)
        }.value
    }

    func stopAll() { jobs.values.forEach { $0.cancel() } }

    /// Called only when the app terminates, while its worker queues can still reap owned children.
    func shutdown() {
        saveTask?.cancel(); saveTask = nil
        let active = Array(jobs.values)
        active.forEach { $0.cancel() }
        let gracefulDeadline = DispatchTime.now() + 3
        let pending = active.filter { !$0.waitUntilStopped(deadline: gracefulDeadline) }
        pending.forEach { $0.forceStop() }
        let finalDeadline = DispatchTime.now() + 1
        for job in pending { _ = job.waitUntilStopped(deadline: finalDeadline) }
        // Completion callbacks are queued on this actor; record an honest interrupted state before exit.
        for index in runs.indices where runs[index].isRunning {
            runs[index].status = .interrupted
            runs[index].output += "\n[Houston quit before a final result was recorded.]"
            history.insert(runs[index], at: 0)
        }
        history = Array(history.prefix(100))
        persistHistory()
        flushHistory()
    }

    private func finish(id: UUID, code: Int32, cancelled: Bool) {
        jobs.removeValue(forKey: id)
        guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].isRunning else { return }
        runs[index].status = cancelled ? .cancelled : (code == 0 ? .succeeded : .failed)
        runs[index].exitCode = code
        runs[index].endedAt = .now
        history.insert(runs[index], at: 0)
        history = Array(history.prefix(100))
        persistHistory()
        onCompletion?(runs[index])
    }
}

/// Each selected command owns a fresh process group, so Stop reaches its dev server children.
/// Only groups created here are signalled; application shutdown does not touch outside processes.
private final class CommandProcessGroup: @unchecked Sendable {
    private let pid: pid_t
    var processGroupID: pid_t { pid }
    private let outputFD: Int32
    private let onOutput: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32, Bool) -> Void
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var cancelledAt: TimeInterval?
    private var finished = false

    init(command: String, path: String, onOutput: @escaping @Sendable (String) -> Void,
         onExit: @escaping @Sendable (Int32, Bool) -> Void) throws {
        self.onOutput = onOutput; self.onExit = onExit
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        let directoryResult = path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = ["/bin/zsh", "-lc", command]
        let argv = arguments.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        if environment["PATH"] == nil { environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        environment["TERM"] = "dumb"; environment["NO_COLOR"] = "1"
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let result = directoryResult == 0 ? argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(&child, "/bin/zsh", &actions, &attributes, argvBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        } : directoryResult
        Darwin.close(writeFD)
        guard result == 0 else {
            Darwin.close(readFD)
            throw UsageError.unavailable("Could not start the command: " + String(cString: strerror(result)))
        }
        pid = child; outputFD = readFD
        completion.enter()
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
    }

    @discardableResult func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        guard cancelledAt == nil else { return true }
        cancelledAt = ProcessInfo.processInfo.systemUptime
        _ = Darwin.kill(-pid, SIGTERM)
        return true
    }

    func waitUntilStopped(deadline: DispatchTime) -> Bool { completion.wait(timeout: deadline) == .success }

    func forceStop() {
        lock.lock(); defer { lock.unlock() }
        if !finished { _ = Darwin.kill(-pid, SIGKILL) }
    }

    func observe() {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completion.leave() }
            var pending = Data(), lastDelivery = ProcessInfo.processInfo.systemUptime
            func drain() {
                var buffer = [UInt8](repeating: 0, count: 8192)
                for _ in 0..<16 {
                    let count = Darwin.read(outputFD, &buffer, buffer.count)
                    guard count > 0 else { return }
                    pending.append(contentsOf: buffer.prefix(count))
                    if pending.count > 131_072 { pending.removeFirst(pending.count - 131_072) }
                }
            }
            func deliver(final: Bool = false) {
                var count = pending.count
                // A pipe read can end in the middle of a UTF-8 scalar. Keep its
                // incomplete suffix (at most three bytes) until the next batch.
                if !final, let start = pending.suffix(4).lastIndex(where: { $0 & 0xc0 != 0x80 }) {
                    let byte = pending[start]
                    let length = (0xf0...0xf4).contains(byte) ? 4 : (0xe0...0xef).contains(byte) ? 3 : (0xc2...0xdf).contains(byte) ? 2 : 1
                    if pending.distance(from: start, to: pending.endIndex) < length {
                        count = pending.distance(from: pending.startIndex, to: start)
                    }
                }
                guard count > 0 else { return }
                onOutput(String(decoding: pending.prefix(count), as: UTF8.self))
                pending.removeFirst(count)
            }
            while true {
                drain()
                let now = ProcessInfo.processInfo.systemUptime
                if !pending.isEmpty, now - lastDelivery >= 0.08 {
                    deliver(); lastDelivery = now
                }
                lock.lock()
                if let cancelledAt, now - cancelledAt > 2 { _ = Darwin.kill(-pid, SIGKILL) }
                lock.unlock()
                // WNOWAIT keeps our child PID reserved until descendants have been stopped.
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0 && info.si_pid == pid { break }
                if result == -1 && errno != EINTR { break }
                usleep(20_000)
            }
            lock.lock()
            finished = true
            let wasCancelled = cancelledAt != nil
            // A shell command that backgrounds a server must not leave an untracked child behind.
            _ = Darwin.kill(-pid, SIGTERM)
            lock.unlock()
            usleep(100_000)
            _ = Darwin.kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            drain()
            deliver(final: true)
            Darwin.close(outputFD)
            let signal = status & 0x7f
            let code: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            onExit(code, wasCancelled)
        }
    }
}
