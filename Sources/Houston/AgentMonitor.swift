import AppKit
import Combine
import HoustonCore

@MainActor final class AgentMonitor: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var configured: Set<AgentProvider> = []
    @Published private(set) var setupMessage: String?
    @Published private(set) var error: String?
    /// Every fresh status change, with the status it replaced, so the island can tell a start from an answer.
    var onTransition: ((AgentSession, AgentStatus?) -> Void)?

    private let directory: URL
    private var watcher: AgentDirectoryWatcher?
    private var timer: Timer?
    private var started = false

    init(directory: URL = AgentBridge.directory) { self.directory = directory }

    func start() {
        guard !started else { return }
        started = true
        refresh(notify: false)
        refreshConfiguration()
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.refreshConfiguration()
                if self.watcher == nil { self.watch() }
            }
        }
        timer?.tolerance = 10
    }

    func stop() {
        started = false
        watcher = nil
        timer?.invalidate()
        timer = nil
    }

    func refresh(notify: Bool = true) {
        do {
            let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            let latest = try AgentBridge.read(directory: directory)
                .filter { Date.now.timeIntervalSince($0.updatedAt) <= 7 * 86_400 }
                .sorted { $0.updatedAt > $1.updatedAt }
            if latest != sessions { sessions = latest }
            error = nil
            if notify {
                for session in latest where Date.now.timeIntervalSince(session.updatedAt) < 120 {
                    let old = previous[session.id]
                    // A whole turn can finish between directory notifications. A newer Stop
                    // still deserves an alert, while rereading the same event does not.
                    if old?.status != session.status || (session.status == .completed && old?.updatedAt != session.updatedAt) {
                        onTransition?(session, old?.status)
                    }
                }
            }
        } catch { self.error = "Agent status could not be read: " + error.localizedDescription }
    }

    func refreshConfiguration() {
        configured = Set(AgentProvider.allCases.filter {
            AgentBridge.isConfigured(try? Data(contentsOf: AgentBridge.configurationURL(for: $0)), provider: $0)
        })
    }

    func setup(provider: AgentProvider) { configure(provider: provider, installing: true) }
    func disconnect(provider: AgentProvider) { configure(provider: provider, installing: false) }

    private func configure(provider: AgentProvider, installing: Bool) {
        do {
            guard let executable = Bundle.main.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw UsageError.unavailable("Move Houston to Applications and try again.")
            }
            let file = AgentBridge.configurationURL(for: provider).resolvingSymlinksInPath()
            let existing = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            let merged = try AgentBridge.mergedConfiguration(existing, provider: provider, executable: executable, installing: installing)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing {
                let backup = file.appendingPathExtension("houston-backup")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try existing.write(to: backup, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
            }
            try merged.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            if installing {
                switch provider {
                case .codex:
                    setupMessage = "Codex hooks saved. Restart Codex, then open /hooks to review and trust Houston’s commands. New session events will appear here."
                case .claude:
                    setupMessage = "Claude Code hooks saved. Restart or resume Claude Code and check /hooks. New session events will appear here."
                case .cursor:
                    setupMessage = "Cursor hooks saved. Check Customize → Hooks in Cursor, then start a conversation. Restart Cursor if the hooks have not loaded."
                }
            } else {
                setupMessage = "Houston’s \(provider.name) hooks removed. Restart your agent to finish disconnecting."
            }
            refreshConfiguration()
        } catch { setupMessage = error.localizedDescription }
    }

    func dismiss(session: AgentSession) {
        do { try AgentBridge.dismiss(session, directory: directory); refresh(notify: false) }
        catch { self.error = error.localizedDescription }
    }

    func open(session: AgentSession) {
        if session.provider == .codex,
           let encoded = session.sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "codex://threads/" + encoded),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
           NSWorkspace.shared.open(url) { return }
        openProject(session: session)
    }

    func openProject(session: AgentSession) {
        let url = URL(fileURLWithPath: session.projectPath)
        guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
            setupMessage = session.resumeCommand == nil
                ? "This project is no longer available. Open Cursor to return to the conversation."
                : "This project is no longer available. Copy the resume command to return to the session."
            return
        }
        if session.provider == .codex { setupMessage = "Opened the project. Install the Codex app for direct session links, or copy the resume command." }
    }

    func copyResumeCommand(session: AgentSession) {
        guard let command = session.resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        setupMessage = "Resume command copied. Run it in a terminal to return to this session."
    }

    private func watch() {
        guard started else { return }
        watcher = AgentDirectoryWatcher(directory: directory) { [weak self] replaced in
            Task { @MainActor in
                guard let self, self.started else { return }
                if replaced { self.watcher = nil; self.watch() }
                self.refresh()
            }
        }
    }
}

private final class AgentDirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(directory: URL, onChange: @escaping @Sendable (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .global(qos: .utility))
        let source = self.source
        source.setEventHandler { [weak source] in
            guard let source else { return }
            onChange(!source.data.intersection([.delete, .rename]).isEmpty)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
