import AppKit
import SwiftUI
import HoustonCore

enum Provider: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex", claude = "Claude", cursor = "Cursor", copilot = "Copilot"
    case gemini = "Gemini", windsurf = "Windsurf", openrouter = "OpenRouter"
    var id: String { rawValue }
    var logo: String {
        switch self {
        case .codex: "openai"; case .claude: "claude"; case .cursor: "cursor"
        case .copilot: "githubcopilot"; case .gemini: "gemini-color"; case .windsurf: "windsurf"; case .openrouter: "openrouter"
        }
    }
    var color: Color {
        let rgb: (UInt32, UInt32) = switch self {
        case .codex: (0x237A62, 0x9CE0C4)
        case .claude: (0xA34E27, 0xF0A375)
        case .cursor: (0x555771, 0xCCCFE8)
        case .copilot: (0x7150B8, 0xBAA8FA)
        case .gemini: (0x326CBD, 0x8ABBFF)
        case .windsurf: (0x177A78, 0x6EDFDB)
        case .openrouter: (0x5A5FA9, 0xC4C9FA)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb.1 : rgb.0
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    var dashboard: URL {
        let address = switch self {
        case .codex: "https://chatgpt.com/codex/settings/usage"
        case .claude: "https://claude.ai/settings/usage"
        case .cursor: "https://cursor.com/dashboard?tab=usage"
        case .copilot: "https://github.com/settings/copilot"
        case .gemini: "https://aistudio.google.com/usage"
        case .windsurf: "https://windsurf.com/profile"
        case .openrouter: "https://openrouter.ai/activity"
        }
        return URL(string: address)!
    }
    var setup: String {
        switch self {
        case .codex: "Uses your signed-in Codex CLI."
        case .claude: "Two ways to connect: the terminal status-line bridge (usage only, updates after each Claude Code terminal response) or a direct read with Claude Code’s own sign-in, which also works when you only use the desktop app."
        case .cursor: "Dashboard shortcut. Automatic Cursor usage is not connected."
        case .copilot: "Uses GitHub CLI sign-in. Run gh auth login if needed. Your account must expose Copilot usage."
        case .gemini: "Uses an existing Gemini CLI Google sign-in to read quota. Account eligibility varies."
        case .windsurf: "Reads Windsurf’s local usage cache. Open Windsurf to update it."
        case .openrouter: "Reads this API key’s spend and optional budget. Keys are saved in macOS Keychain."
        }
    }
}

enum PanelTab: String, CaseIterable { case usage = "Usage", system = "Mac", activity = "GitHub", tools = "Tools" }

@MainActor final class Store: ObservableObject {
    @Published var snapshots: [Provider: UsageSnapshot] = [:]
    @Published var errors: [Provider: String] = [:]
    @Published var loading: Set<Provider> = []
    @Published var demo = false {
        didSet {
            updateBridgeMonitoring()
            if started && !demo { refresh() }
            updateVisibleWork()
        }
    }
    @Published var tab: PanelTab = .usage { didSet { updateVisibleWork(); if tab == .tools { checkBridge() } } }
    @Published var expanded = false { didSet { updateVisibleWork() } }
    @Published var pinned = false
    @Published var editing = false
    @Published var claudeMessage: String?
    @Published var claudeDirect = UserDefaults.standard.bool(forKey: "claudeDirect")
    @Published var bridgeConfigured = false
    @Published var bridgeDate: Date?
    @Published var enabled: Set<Provider> = Set(Provider.allCases) { didSet { updateBridgeMonitoring() } }
    @Published var activity: GitHubActivity?
    @Published var activityError: String?
    @Published var activityLoading = false
    @Published var repositorySuggestion: String?
    @Published var overview: GitHubOverview?
    @Published var overviewError: String?
    @Published var overviewLoading = false
    @Published var repository = UserDefaults.standard.string(forKey: "repository") ?? ""
    @Published var system: SystemSnapshot?
    @Published var compactWidth: CGFloat = 260
    @Published var expandedWidth: CGFloat = 460
    @Published var topInset: CGFloat = 0
    @Published var expandedHeight: CGFloat = 530
    private var timer: Timer?
    private var bridgeWatcher: BridgeWatcher?
    private let bridgeFile: URL
    private var started = false
    private var overviewAttempt: Date?
    private var activityAttempt: Date?
    private var systemTimer: Timer?
    private var systemTask: Task<Void, Never>?
    private let sampler = SystemSampler()
    var refreshing: Bool { !loading.isEmpty || activityLoading || overviewLoading }
    var connections: Bool {
        get { tab == .tools }
        set { tab = newValue ? .tools : .usage }
    }
    var claudeEmail: String? { ClaudeAccount.accountEmail() }

    init(bridgeFile: URL = UsageReader.claudeFile) {
        self.bridgeFile = bridgeFile
        if let saved = UserDefaults.standard.stringArray(forKey: "enabledProviders") {
            enabled = Set(saved.compactMap(Provider.init(rawValue:)))
        }
    }

    func start() {
        guard !started else { return }
        started = true
        checkBridge()
        updateBridgeMonitoring()
        refresh()
        updateVisibleWork()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 30
    }

    func stop() {
        started = false
        timer?.invalidate(); timer = nil
        bridgeWatcher = nil
        systemTimer?.invalidate(); systemTimer = nil
    }

    private func updateBridgeMonitoring() {
        guard started, !demo, enabled.contains(.claude) else { bridgeWatcher = nil; return }
        if bridgeWatcher == nil {
            bridgeWatcher = BridgeWatcher(directory: bridgeFile.deletingLastPathComponent()) { [weak self] replaced in
                Task { @MainActor in
                    guard let self, self.started else { return }
                    if replaced { self.bridgeWatcher = nil; self.updateBridgeMonitoring() }
                    self.readBridgeIfChanged()
                }
            }
        }
        readBridgeIfChanged()
    }

    func setEnabled(_ provider: Provider, _ value: Bool) {
        if value { enabled.insert(provider); refresh(provider) }
        else { enabled.remove(provider) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "enabledProviders")
    }

    func snapshot(for provider: Provider) -> UsageSnapshot? {
        guard demo else { return snapshots[provider] }
        let index = Provider.allCases.firstIndex(of: provider) ?? 0
        return UsageSnapshot(windows: [UsageWindow(name: provider == .openrouter ? "Key budget" : "Current window",
            used: Double(24 + index * 9), resetsAt: .now.addingTimeInterval(8040 - Double(index * 420))),
            UsageWindow(name: "Weekly", used: 36, resetsAt: .now.addingTimeInterval(280800))])
    }

    // MARK: Claude

    /// Newer readings win, so a terminal bridge update and a direct read never fight.
    private func updateClaude(_ snapshot: UsageSnapshot) {
        guard (snapshots[.claude]?.capturedAt ?? .distantPast) <= snapshot.capturedAt else { return }
        snapshots[.claude] = snapshot
        errors[.claude] = nil
    }

    private func readBridgeIfChanged() {
        guard !demo, enabled.contains(.claude) else { return }
        let modified = try? bridgeFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let modified, modified != bridgeDate else { return }
        bridgeDate = modified
        do { updateClaude(try UsageReader.readClaude(from: bridgeFile)) }
        catch { if !claudeDirect { errors[.claude] = error.localizedDescription } }
    }

    func setClaudeDirect(_ value: Bool) {
        claudeDirect = value
        UserDefaults.standard.set(value, forKey: "claudeDirect")
        errors[.claude] = nil
        if value {
            claudeMessage = "macOS may ask to let Houston read Claude Code’s sign-in. Choose Allow; the token is used only to read usage and is never stored."
            refresh(.claude)
        } else {
            claudeMessage = nil
            if snapshots[.claude]?.detail != nil { snapshots[.claude] = nil }
            bridgeDate = nil
            readBridgeIfChanged()
        }
    }

    func checkBridge() {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["statusLine"] as? [String: Any] else { bridgeConfigured = false; return }
        bridgeConfigured = status["command"] as? String == claudeCommand
    }

    // MARK: Refresh

    func refresh() {
        guard !demo else { return }
        updateBridgeMonitoring()
        for provider in enabled { refresh(provider) }
        if expanded && tab == .activity {
            refreshOverview()
            if !repository.isEmpty { refreshActivity() }
        }
    }

    func refresh(_ provider: Provider) {
        guard !demo, enabled.contains(provider), !loading.contains(provider), provider != .cursor else { return }
        loading.insert(provider)
        let direct = claudeDirect
        let bridgeFile = bridgeFile
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<UsageSnapshot, Error> in
                do {
                    let snapshot: UsageSnapshot
                    switch provider {
                    case .codex: snapshot = try UsageReader.readCodex()
                    case .claude: snapshot = direct ? try await ClaudeAccount.readUsage() : try UsageReader.readClaude(from: bridgeFile)
                    case .copilot: snapshot = try DeveloperTools.readCopilot()
                    case .gemini: snapshot = try await DeveloperTools.readGemini()
                    case .windsurf: snapshot = try DeveloperTools.readWindsurf()
                    case .openrouter: snapshot = try await DeveloperTools.readOpenRouter()
                    case .cursor: throw UsageError.unavailable("Dashboard only")
                    }
                    return .success(snapshot)
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let snapshot):
                if provider == .claude { updateClaude(snapshot); if direct { claudeMessage = nil } }
                else { snapshots[provider] = snapshot; errors[provider] = nil }
            case .failure(let error): errors[provider] = error.localizedDescription
            }
            loading.remove(provider)
        }
    }

    // MARK: GitHub

    func saveRepository(_ value: String) {
        let normalized = GitHubReader.normalizeRepository(value)
        guard GitHubReader.validRepository(normalized) else { activityError = "Use owner/repository, for example apple/swift."; return }
        repository = normalized
        activityAttempt = nil
        activity = nil
        activityError = nil
        repositorySuggestion = nil
        UserDefaults.standard.set(normalized, forKey: "repository")
        refreshActivity()
    }

    func clearRepository() {
        repository = ""
        activityAttempt = nil
        activity = nil
        activityError = nil
        repositorySuggestion = nil
        UserDefaults.standard.removeObject(forKey: "repository")
    }

    func refreshActivity() {
        guard !demo, !activityLoading, !repository.isEmpty else { return }
        activityAttempt = .now
        activityLoading = true
        let requested = repository
        Task {
            let result = await Task.detached(priority: .utility) { Result { try GitHubReader.read(repository: requested) } }.value
            guard requested == repository else {
                activityLoading = false
                activityAttempt = nil
                if expanded && tab == .activity { refreshActivity() }
                return
            }
            switch result {
            case .success(let value): activity = value; activityError = nil; repositorySuggestion = nil
            case .failure(let error):
                activityError = error.localizedDescription
                repositorySuggestion = GitHubReader.suggestion(for: requested, among: overview?.repositories ?? [])
            }
            activityLoading = false
        }
    }

    func refreshOverview() {
        guard !demo, !overviewLoading else { return }
        overviewAttempt = .now
        overviewLoading = true
        Task {
            let result = await Task.detached(priority: .utility) { Result { try GitHubReader.readOverview() } }.value
            switch result {
            case .success(let value):
                overview = value
                overviewError = nil
                if activityError != nil, repositorySuggestion == nil { repositorySuggestion = GitHubReader.suggestion(for: repository, among: value.repositories) }
            case .failure(let error): overviewError = error.localizedDescription
            }
            overviewLoading = false
        }
    }

    // MARK: Mac stats

    private func updateVisibleWork() {
        updateSystemSampling()
        guard started, !demo, expanded, tab == .activity else { return }
        if Date.now.timeIntervalSince(overviewAttempt ?? .distantPast) >= 300 { refreshOverview() }
        if Date.now.timeIntervalSince(activityAttempt ?? .distantPast) >= 300 { refreshActivity() }
    }

    private func updateSystemSampling() {
        let active = started && expanded && tab == .system
        if active, systemTimer == nil {
            sampleSystem()
            // CPU load needs a second sample; take it soon so the tab fills in quickly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.systemTimer != nil else { return }
                self.sampleSystem()
            }
            systemTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleSystem() }
            }
            systemTimer?.tolerance = 0.2
        } else if !active, let timer = systemTimer {
            timer.invalidate()
            systemTimer = nil
        }
    }

    private func sampleSystem() {
        guard systemTask == nil else { return }
        systemTask = Task { [sampler] in
            let snapshot = await sampler.sample()
            system = snapshot
            systemTask = nil
        }
    }

    // MARK: Keys and bridge

    func saveOpenRouter(_ key: String) {
        do { try SecretStore.save(key, account: "openrouter"); refresh(.openrouter) }
        catch { errors[.openrouter] = error.localizedDescription }
    }

    var claudeCommand: String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' --claude-statusline"
    }

    func connectClaude() {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        defer { checkBridge() }
        do {
            var root: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: settings.path) {
                let data = try Data(contentsOf: settings)
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw UsageError.unavailable("Claude settings are not a JSON object. Your settings were left unchanged.")
                }
                root = existing
                if let status = root["statusLine"] as? [String: Any] {
                    if status["command"] as? String == claudeCommand {
                        claudeMessage = "Bridge ready. It updates after each response in a Claude Code terminal session; the desktop app does not run status lines, so turn on the direct connection for that."
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(claudeCommand, forType: .string)
                        claudeMessage = "You already have a status line. Houston’s command was copied; pipe the same input to it from your existing script. Your settings were preserved."
                    }
                    return
                }
                if root["statusLine"] != nil { throw UsageError.unavailable("An existing status line is configured. Your settings were left unchanged.") }
                try data.write(to: settings.deletingLastPathComponent().appendingPathComponent("settings.houston-backup-\(Int(Date.now.timeIntervalSince1970)).json"), options: .withoutOverwriting)
            }
            root["statusLine"] = ["type": "command", "command": claudeCommand]
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: settings, options: .atomic)
            claudeMessage = "Bridge ready. It updates after each response in a Claude Code terminal session; the desktop app does not run status lines, so turn on the direct connection for that."
        } catch { claudeMessage = error.localizedDescription }
    }
}

/// Watch the directory because Claude replaces its usage file atomically.
private final class BridgeWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(directory: URL, onChange: @escaping @Sendable (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .global(qos: .utility))
        self.source = source
        source.setEventHandler { [weak source] in
            guard let source else { return }
            onChange(!source.data.intersection([.delete, .rename]).isEmpty)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
