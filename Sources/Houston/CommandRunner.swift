import Foundation
import Combine
import Darwin
import HoustonCore

struct CommandRun: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable { case running, succeeded, failed, cancelled }
    /// The saved command ID; rerunning replaces its last result.
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
    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
}

@MainActor final class CommandRunner: ObservableObject {
    @Published private(set) var runs: [CommandRun] = []
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
                        self.runs[index].output = "[Earlier output omitted]\n" + String(self.runs[index].output.suffix(65_536))
                    }
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
        let active = Array(jobs.values)
        active.forEach { $0.cancel() }
        let gracefulDeadline = DispatchTime.now() + 3
        let pending = active.filter { !$0.waitUntilStopped(deadline: gracefulDeadline) }
        pending.forEach { $0.forceStop() }
        let finalDeadline = DispatchTime.now() + 1
        for job in pending { _ = job.waitUntilStopped(deadline: finalDeadline) }
    }

    private func finish(id: UUID, code: Int32, cancelled: Bool) {
        jobs.removeValue(forKey: id)
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].status = cancelled ? .cancelled : (code == 0 ? .succeeded : .failed)
        runs[index].exitCode = code
        runs[index].endedAt = .now
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
            while true {
                drain()
                let now = ProcessInfo.processInfo.systemUptime
                if !pending.isEmpty, now - lastDelivery >= 0.08 {
                    onOutput(String(decoding: pending, as: UTF8.self)); pending.removeAll(keepingCapacity: true); lastDelivery = now
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
            if !pending.isEmpty { onOutput(String(decoding: pending, as: UTF8.self)) }
            Darwin.close(outputFD)
            let signal = status & 0x7f
            let code: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            onExit(code, wasCancelled)
        }
    }
}
