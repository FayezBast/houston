import AppKit
import SwiftUI
import HoustonCore
import Combine

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
        case .gemini: "https://gemini.google.com"
        case .windsurf: "https://windsurf.com/profile"
        case .openrouter: "https://openrouter.ai/activity"
        }
        return URL(string: address)!
    }
    var setup: String {
        switch self {
        case .codex: "Uses your signed-in Codex CLI."
        case .claude: "Connect using your existing browser sign-in, reuse Claude Code’s sign-in, or use the terminal bridge. Direct connections read usage without needing a terminal response."
        case .cursor: "Uses your signed-in Cursor app or browser. Connect Cursor checks existing browser sessions first; you can also sign in there."
        case .copilot: "Uses GitHub CLI sign-in. Run gh auth login if needed. Your account must expose Copilot usage."
        case .gemini: "Reads quota for an eligible Gemini Code Assist Standard or Enterprise account. Consumer Gemini CLI OAuth ended in June 2026; Gemini app subscriptions do not expose this quota."
        case .windsurf: "Reads Windsurf’s local usage cache. Open Windsurf to update it."
        case .openrouter: "Reads this API key’s spend and optional budget. Keys are saved in macOS Keychain."
        }
    }
    var connectionSource: String {
        switch self {
        case .codex: "Local sign-in"
        case .claude: "Browser or Claude Code"
        case .cursor: "Browser or Cursor app"
        case .copilot: "GitHub CLI"
        case .gemini: "Gemini CLI"
        case .windsurf: "Local cache"
        case .openrouter: "API key"
        }
    }
    var allowanceCoverage: String {
        switch self {
        case .codex: "5-hour · weekly"
        case .claude: "5-hour · weekly · model limits"
        case .cursor: "Plan allowance · extra usage"
        case .copilot: "Premium · chat · completions"
        case .gemini: "Code Assist model quotas"
        case .windsurf: "Daily · weekly · legacy credits"
        case .openrouter: "Key spend · optional budget"
        }
    }
    var coverageNote: String {
        switch self {
        case .codex: "ChatGPT subscription allowance from your signed-in Codex CLI."
        case .claude: "Available windows depend on your plan. The terminal bridge updates after a response."
        case .cursor: "Reads the allowances exposed by your personal or team plan."
        case .copilot: "Shows metered allowances returned for your account; some plans report unlimited usage."
        case .gemini: "Requires eligible Code Assist Standard or Enterprise access. Gemini app subscriptions are separate."
        case .windsurf: "Reads what Windsurf last cached. Open Windsurf to update it."
        case .openrouter: "Tracks this key only. A percentage is available when the key has a budget."
        }
    }
}

enum PanelTab: String, CaseIterable { case usage = "Usage", system = "Mac", activity = "GitHub", tools = "Tools", agents = "Agents", projects = "Projects", drop = "Drop" }

struct ProviderReading {
    let value: String
    let status: String
    var remaining: Double? = nil
    var needsAttention = false
    var isConnected = false
    var isLoading = false
}

@MainActor final class Store: ObservableObject {
    @Published var snapshots: [Provider: UsageSnapshot] = [:]
    @Published private(set) var defaultSnapshots: [Provider: UsageSnapshot] = [:]
    @Published var errors: [Provider: String] = [:]
    @Published var loading: Set<Provider> = []
    @Published var tab: PanelTab = .usage { didSet { updateVisibleWork(); if tab == .tools { checkBridge() } } }
    @Published var expanded = false { didSet { updateVisibleWork(); if expanded { dismissPeek() } } }
    @Published private(set) var peek: IslandPeek?
    @Published var pinned = false
    @Published var editing = false
    @Published var claudeMessage: String?
    @Published var claudeDirect = UserDefaults.standard.bool(forKey: "claudeDirect")
    @Published var bridgeConfigured = false
    @Published var bridgeDate: Date?
    @Published var enabled: Set<Provider> = Set(Provider.allCases) {
        didSet {
            invalidateUsage(oldValue.subtracting(enabled))
            updateBridgeMonitoring()
        }
    }
    @Published private(set) var compactSelection: [Provider] = [.codex, .claude, .cursor, .copilot]
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
    @Published var notchWidth: CGFloat = 0
    @Published var expandedHeight: CGFloat = 530
    let alerts: AlertCenter
    let accounts: AccountStore
    let agents: AgentMonitor
    let projects: ProjectStore
    let dropShelf = DropShelf()
    let appServices = AppServices()
    var reveal: (() -> Void)?
    @Published var requestedProvider: Provider?

    func navigate(to tab: PanelTab, provider: Provider? = nil) {
        self.tab = tab
        requestedProvider = provider
        expanded = true
        reveal?()
    }
    let sounds: IslandSounds
    @Published private(set) var history = UsageHistory()
    @Published private(set) var historyError: String?
    @Published private(set) var githubAlertError: String?
    private var observations = Set<AnyCancellable>()
    private var githubAlertTracker = GitHubAlertTracker()
    private var githubSignalsRequest: UUID?
    private var overviewRequest: UUID?
    private var activityRequest: UUID?
    private var githubAlertsWereEnabled = false
    private let historyWriter = UsageHistoryWriter()
    private var historySave: Task<Void, Never>?
    private var unscopedQuotaHistory: [Provider: UsageHistory] = [:]
    private var historyRecordingPaused = false
    private var historyFile: URL { bridgeFile.deletingLastPathComponent().appendingPathComponent("usage-history.json") }
    private var timer: Timer?
    private var bridgeWatcher: BridgeWatcher?
    private let bridgeFile: URL
    private let usageReader: @Sendable (Provider, Bool, Bool, URL) async throws -> UsageSnapshot
    private var usageRequests: [Provider: UUID] = [:]
    private var started = false
    private var overviewAttempt: Date?
    private var activityAttempt: Date?
    private var systemTimer: Timer?
    private var systemTask: Task<Void, Never>?
    private var peekDismissal: Task<Void, Never>?
    private let sampler = SystemSampler()
    var refreshing: Bool { !loading.isEmpty || !accounts.loading.isEmpty || activityLoading || overviewLoading }
    var connections: Bool {
        get { tab == .tools }
        set { tab = newValue ? .tools : .usage }
    }
    var claudeEmail: String? { ClaudeAccount.accountEmail() }

    // MARK: Island presentation

    /// Use the same sessions for the compact indicator and its hover/click destination.
    func activeAgents(at date: Date) -> [AgentSession] {
        func rank(_ status: AgentStatus) -> Int {
            switch status {
            case .waiting: 0
            case .failed: 1
            case .running: 2
            default: 3
            }
        }
        return agents.sessions.filter {
            $0.isCurrent(at: date) && ($0.status == .running || $0.status.needsAttention)
        }.sorted { rank($0.status) != rank($1.status) ? rank($0.status) < rank($1.status) : $0.updatedAt > $1.updatedAt }
    }

    /// Capture the destination before expansion dismisses the peek. Repeated hover/click callbacks do nothing.
    func openIsland(defaultTab: PanelTab? = nil, at date: Date = .now) {
        guard !expanded else { return }
        if let peek {
            if let id = peek.projectID { projects.selectedID = id }
            tab = peek.tab
        } else if !dropShelf.items.isEmpty {
            tab = .drop
        } else if !activeAgents(at: date).isEmpty {
            tab = .agents
        } else if let defaultTab {
            tab = defaultTab
        }
        expanded = true
    }

    func openDropShelf() {
        tab = .drop
        expanded = true
    }

    var presentation: IslandPresentation { expanded ? .expanded : peek != nil ? .peek : .compact }
    /// The strip beside the camera; every presentation keeps it, so its contents never jump.
    var bandHeight: CGFloat { max(34, topInset + 6) }
    var peekSize: CGSize { IslandGeometry.peekSize(compactWidth: compactWidth, expandedWidth: expandedWidth, bandHeight: bandHeight) }

    func size(for presentation: IslandPresentation) -> CGSize {
        switch presentation {
        case .compact: CGSize(width: compactWidth, height: bandHeight)
        case .peek: peekSize
        case .expanded: CGSize(width: expandedWidth, height: expandedHeight)
        }
    }

    /// Show an alert in the island for a few seconds while the panel is closed. Opening the panel, or a newer alert, replaces it.
    func present(_ alert: HoustonAlert) { present(IslandPeek(alert)) }

    /// Peek out of the notch for as long as the moment asks, then settle back; a newer peek or an opened panel replaces it.
    func present(_ peek: IslandPeek) {
        guard !expanded else { return }
        self.peek = peek
        peekDismissal?.cancel()
        peekDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(peek.moment.duration)) } catch { return }
            guard let self, self.peek?.id == peek.id else { return }
            self.peek = nil
        }
    }

    /// An agent's lifecycle plays out in the island. A session that starts, needs you, finishes, or fails peeks out
    /// of the notch with its own motion, the moments that need the person also chime, and macOS notifications stay
    /// opt-in. Answering an agent retracts its request quietly; the working ring says the rest.
    func announce(_ session: AgentSession, after previous: AgentStatus?) {
        let moment: IslandMoment
        switch session.status {
        case .running:
            guard previous != .running else { return }
            if previous == .waiting {
                if peek?.sessionID == session.id { dismissPeek() }
                return
            }
            moment = .start
        case .waiting: moment = .attention
        case .completed: moment = .finish
        case .failed: moment = .failure
        case .idle, .interrupted, .ended: return
        }
        present(IslandPeek(session, moment: moment))
        if let cue = moment.cue, alerts.soundsEnabled { sounds.play(cue) }
        guard alerts.agentEnabled, session.status.needsAttention else { return }
        let title = switch session.status {
        case .waiting: "Agent needs your input"
        case .failed: "Agent turn failed"
        default: "Agent response ready"
        }
        alerts.send(title: title, body: "\(session.provider.rawValue.capitalized) · \(session.projectName)", sessionID: session.id, island: false)
    }

    func dismissPeek() {
        peekDismissal?.cancel()
        peekDismissal = nil
        if peek != nil { peek = nil }
    }

    init(bridgeFile: URL = UsageReader.claudeFile,
         accounts: AccountStore? = nil, alerts: AlertCenter? = nil, sounds: IslandSounds? = nil, projects: ProjectStore? = nil,
         usageReader: @escaping @Sendable (Provider, Bool, Bool, URL) async throws -> UsageSnapshot = Store.readUsage) {
        self.bridgeFile = bridgeFile
        self.usageReader = usageReader
        self.accounts = accounts ?? AccountStore(file: bridgeFile.deletingLastPathComponent().appendingPathComponent("accounts.json"))
        self.alerts = alerts ?? AlertCenter()
        self.sounds = sounds ?? IslandSounds()
        self.agents = AgentMonitor(directory: bridgeFile.deletingLastPathComponent())
        self.projects = projects ?? ProjectStore(file: bridgeFile.deletingLastPathComponent().appendingPathComponent("projects.json"))
        if let saved = UserDefaults.standard.stringArray(forKey: "enabledProviders") {
            enabled = Set(saved.compactMap(Provider.init(rawValue:)))
        }
        if let saved = UserDefaults.standard.stringArray(forKey: "compactProviders") {
            var selected: [Provider] = []
            for provider in saved.compactMap(Provider.init(rawValue:)) where !selected.contains(provider) {
                if selected.count < 4 { selected.append(provider) }
            }
            compactSelection = selected
        }
        self.alerts.settingsChanged = { [weak self] in
            self?.updateAlertMonitoring()
            if let self { self.projects.monitorInBackground = self.alerts.projectEnabled }
        }
        self.alerts.onAlert = { [weak self] alert in self?.present(alert) }
        self.accounts.onSelectionChanged = { [weak self] provider in self?.selectedAccountChanged(provider) }
        self.accounts.onSnapshot = { [weak self] account, snapshot in
            guard let self, let provider = Provider(rawValue: account.provider.rawValue), self.enabled.contains(provider) else { return }
            self.record(snapshot, provider: provider, accountID: account.id.uuidString, label: account.label)
            if self.accounts.selectedAccount(for: provider)?.id == account.id {
                guard (self.snapshots[provider]?.capturedAt ?? .distantPast) <= snapshot.capturedAt else { return }
                self.snapshots[provider] = snapshot; self.errors[provider] = nil
            }
        }
        self.accounts.onFailure = { [weak self] account, message in
            guard let self, let provider = Provider(rawValue: account.provider.rawValue),
                  self.enabled.contains(provider), self.accounts.selectedAccount(for: provider)?.id == account.id else { return }
            self.errors[provider] = message
        }
        agents.onTransition = { [weak self] session, previous in self?.announce(session, after: previous) }
        self.projects.onCompletion = { [weak self] run in
            guard let self, run.status != .cancelled else { return }
            let title = run.status == .succeeded ? "Command passed" : "Command failed"
            let projectName = self.projects.projects.first { $0.id == run.projectID }?.name ?? "Project"
            let body = projectName + " · " + run.commandName
            if self.alerts.projectEnabled {
                self.alerts.send(title: title, body: body, projectID: run.projectID)
            } else {
                self.present(HoustonAlert(title: title, body: body, url: nil, sessionID: nil, projectID: run.projectID))
            }
        }
        self.projects.cloud.onTransition = { [weak self] transition in
            guard let self, self.alerts.projectEnabled else { return }
            self.alerts.send(title: transition.title, body: transition.message, url: transition.url, projectID: transition.projectID)
        }
        self.alerts.openProject = { [weak self] id in
            guard let self else { return }
            self.projects.selectedID = id; self.tab = .projects; self.expanded = true
        }
        self.alerts.openSession = { [weak self] id in
            guard let self else { return }
            self.tab = .agents; self.expanded = true
            if let session = self.agents.sessions.first(where: { $0.id == id }) { self.agents.open(session: session) }
        }
        for publisher in [self.accounts.objectWillChange.eraseToAnyPublisher(), agents.objectWillChange.eraseToAnyPublisher(), self.projects.objectWillChange.eraseToAnyPublisher(), dropShelf.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        do { history = try UsageHistory.load(from: historyFile) }
        catch {
            // Preserve an unreadable archive before collecting any new readings.
            let backup = historyFile.appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970))")
            do {
                try FileManager.default.copyItem(at: historyFile, to: backup)
                historyError = "Saved history could not be read. It was preserved as \(backup.lastPathComponent)."
            } catch {
                historyRecordingPaused = true
                historyError = "Saved history could not be read or backed up; recording is paused to preserve it."
            }
        }
        alerts.start()
        projects.monitorInBackground = alerts.projectEnabled
        githubAlertsWereEnabled = alerts.githubEnabled
        agents.start()
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
        dismissPeek()
        invalidateUsage()
        invalidateGitHub()
        accounts.stop()
        agents.stop()
        projects.stop()
        timer?.invalidate(); timer = nil
        bridgeWatcher = nil
        systemTimer?.invalidate(); systemTimer = nil
    }

    private func updateBridgeMonitoring() {
        guard started, enabled.contains(.claude) else { bridgeWatcher = nil; return }
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
        else { enabled.remove(provider); accounts.invalidate(provider: provider) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "enabledProviders")
    }

    var compactProviders: [Provider] { compactSelection.filter { enabled.contains($0) } }
    var compactOverflowCount: Int { enabled.count - compactProviders.count }
    var connectedCount: Int { enabled.filter { snapshots[$0] != nil }.count }
    var attentionCount: Int { enabled.filter { reading(for: $0).needsAttention }.count }
    var availableCount: Int { Provider.allCases.count }

    func isCompactPinned(_ provider: Provider) -> Bool { compactProviders.contains(provider) }

    func setCompactPinned(_ provider: Provider, _ value: Bool) {
        var selection = compactProviders
        if value {
            guard enabled.contains(provider), !selection.contains(provider), selection.count < 4 else { return }
            selection.append(provider)
        } else { selection.removeAll { $0 == provider } }
        compactSelection = selection
        UserDefaults.standard.set(selection.map(\.rawValue), forKey: "compactProviders")
    }

    /// A compact value never treats an expired window or an unbounded key budget as remaining quota.
    func reading(for provider: Provider, at now: Date = .now) -> ProviderReading {
        guard enabled.contains(provider) else { return ProviderReading(value: "—", status: "Off") }
        let isLoading = loading.contains(provider) || accounts.selectedAccount(for: provider).map { accounts.loading.contains($0.id) } == true
        let error = errors[provider]
        guard let snapshot = snapshots[provider] else {
            return ProviderReading(value: isLoading ? "…" : "—", status: isLoading ? "Checking…" : error == nil ? "Not connected" : "Needs attention",
                                   needsAttention: error != nil, isLoading: isLoading)
        }
        let stale = now.timeIntervalSince(snapshot.capturedAt) > 600
        let cached = provider == .windsurf
        let saved = stale || cached || error != nil
        var status = error != nil ? "Update failed · saved reading" : stale ? "Earlier reading" : cached ? "Local cache" : "Connected"
        var value = "—"
        var remaining: Double?
        var needsAttention = error != nil || stale
        if let window = snapshot.windows.first {
            if window.expired(at: now) || !window.used.isFinite {
                status = window.expired(at: now) ? "Awaiting updated usage" : "Usage unavailable"
                needsAttention = true
            } else {
                remaining = window.remaining
                value = "\(saved ? "~" : "")\(Int(window.remaining))%"
                needsAttention = needsAttention || window.remaining <= 10
            }
        } else if [Provider.copilot, .cursor].contains(provider), snapshot.detail?.hasPrefix("Unlimited allowance") == true {
            value = saved ? "~∞" : "∞"
            if !saved { status = "Unlimited allowance" }
        } else if provider == .openrouter, !saved {
            status = "Key spend only"
        }
        if isLoading { status = "Updating…" }
        return ProviderReading(value: value, status: status, remaining: remaining, needsAttention: needsAttention,
                               isConnected: true, isLoading: isLoading)
    }

    // MARK: Claude

    /// Newer readings win, so a terminal bridge update and a direct read never fight.
    private func updateClaude(_ snapshot: UsageSnapshot) {
        guard accounts.selectedAccount(for: .claude) == nil else { return }
        guard (snapshots[.claude]?.capturedAt ?? .distantPast) <= snapshot.capturedAt else { return }
        snapshots[.claude] = snapshot
        defaultSnapshots[.claude] = snapshot
        errors[.claude] = nil
        record(snapshot, provider: .claude)
    }

    private func readBridgeIfChanged() {
        guard enabled.contains(.claude), accounts.selectedAccount(for: .claude) == nil else { return }
        let modified = try? bridgeFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let modified, modified != bridgeDate else { return }
        bridgeDate = modified
        do { updateClaude(try UsageReader.readClaude(from: bridgeFile)) }
        catch { if !claudeDirect { errors[.claude] = error.localizedDescription } }
    }

    func setClaudeDirect(_ value: Bool) {
        accounts.select(nil, for: .claude)
        invalidateUsage([.claude])
        claudeDirect = value
        UserDefaults.standard.set(value, forKey: "claudeDirect")
        errors[.claude] = nil
        if value {
            claudeMessage = "Connect once to reuse your sign-in automatically. If macOS asks for Keychain access, choose Always Allow."
            refresh(.claude, allowInteraction: true)
        } else {
            claudeMessage = nil
            if snapshots[.claude]?.detail != nil { snapshots[.claude] = nil }
            bridgeDate = nil
            readBridgeIfChanged()
            refresh(.claude)
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
        updateBridgeMonitoring()
        for provider in enabled where accounts.selectedAccount(for: provider) == nil { refresh(provider) }
        accounts.refreshAll(enabled: enabled)
        if (expanded && tab == .activity) || alerts.githubEnabled {
            refreshOverview()
            if !repository.isEmpty { refreshActivity() }
        }
        if alerts.githubEnabled { refreshGitHubSignals() }
        if (expanded && tab == .projects) || projects.workspaceOpen { projects.refresh() }
    }

    private func invalidateUsage(_ providers: Set<Provider> = Set(Provider.allCases)) {
        for provider in providers { usageRequests[provider] = nil }
        loading.subtract(providers)
    }

    @discardableResult
    func refresh(_ provider: Provider, allowInteraction: Bool = false) -> Task<Void, Never>? {
        guard enabled.contains(provider), !loading.contains(provider) else { return nil }
        if let account = accounts.selectedAccount(for: provider) { return accounts.refresh(account.id, allowInteraction: allowInteraction) }
        let request = UUID()
        usageRequests[provider] = request
        loading.insert(provider)
        let direct = claudeDirect
        let bridgeFile = bridgeFile
        let read = usageReader
        return Task {
            guard usageRequests[provider] == request else { return }
            let result = await Task.detached(priority: .utility) { () -> Result<UsageSnapshot, Error> in
                do { return .success(try await read(provider, direct, allowInteraction, bridgeFile)) }
                catch { return .failure(error) }
            }.value
            // Configuration changes invalidate an old read without blocking its replacement.
            guard usageRequests[provider] == request else { return }
            usageRequests[provider] = nil
            switch result {
            case .success(let snapshot):
                if provider == .claude { updateClaude(snapshot); if direct { claudeMessage = nil } }
                else { snapshots[provider] = snapshot; defaultSnapshots[provider] = snapshot; errors[provider] = nil; record(snapshot, provider: provider) }
            case .failure(let error): errors[provider] = error.localizedDescription
            }
            loading.remove(provider)
        }
    }

    nonisolated static func readUsage(_ provider: Provider, _ direct: Bool, _ allowInteraction: Bool, _ bridgeFile: URL) async throws -> UsageSnapshot {
        switch provider {
        case .codex: return try UsageReader.readCodex()
        case .claude: return direct ? try await ClaudeAccount.readUsage(allowInteraction: allowInteraction) : try UsageReader.readClaude(from: bridgeFile)
        case .cursor: return try await CursorAccount.readUsage(allowInteraction: allowInteraction)
        case .copilot: return try DeveloperTools.readCopilot()
        case .gemini: return try await DeveloperTools.readGemini()
        case .windsurf: return try DeveloperTools.readWindsurf()
        case .openrouter: return try await DeveloperTools.readOpenRouter(allowInteraction: allowInteraction)
        }
    }

    // MARK: Account selection and history

    private func selectedAccountChanged(_ provider: Provider) {
        invalidateUsage([provider])
        errors[provider] = nil
        if let account = accounts.selectedAccount(for: provider) {
            snapshots[provider] = accounts.snapshots[account.id]
            errors[provider] = accounts.errors[account.id]
            if enabled.contains(provider), snapshots[provider] == nil { accounts.refresh(account.id) }
        } else {
            snapshots[provider] = defaultSnapshots[provider]
            refresh(provider)
        }
    }

    func historyAccountID(for provider: Provider) -> String? {
        accounts.selectedAccount(for: provider)?.id.uuidString ?? snapshots[provider]?.accountID
    }

    private func record(_ snapshot: UsageSnapshot, provider: Provider, accountID: String? = nil, label: String = "Current sign-in") {
        guard started else { return }
        let identity = accountID ?? snapshot.accountID
        let canSave = identity != nil && !historyRecordingPaused
        let events: [QuotaAlert]
        if canSave, let identity {
            events = history.record(snapshot: snapshot, provider: provider.rawValue, accountID: identity,
                                    accountLabel: label, remainingThreshold: alerts.remainingThreshold)
        } else {
            // Unknown identity can warn about low quota, but cannot join saved history or infer account resets.
            var transient = unscopedQuotaHistory[provider] ?? UsageHistory()
            events = transient.record(snapshot: snapshot, provider: provider.rawValue, accountID: "current-session",
                                      accountLabel: label, remainingThreshold: alerts.remainingThreshold).filter { $0.kind == .lowQuota }
            unscopedQuotaHistory[provider] = transient
        }
        for event in events {
            if event.kind == .lowQuota, alerts.quotaEnabled {
                alerts.send(title: "\(event.provider) quota is low",
                            body: "\(event.accountLabel) · \(event.window): \(Int(event.remaining))% remaining", url: provider.dashboard)
            } else if event.kind == .reset, alerts.resetEnabled {
                alerts.send(title: "\(event.provider) quota has reset",
                            body: "\(event.accountLabel) · \(event.window): \(Int(event.remaining))% remaining", url: provider.dashboard)
            }
        }
        guard canSave else { return }
        historySave?.cancel()
        historySave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            let error = await historyWriter.save(history, to: historyFile)
            if let error { historyError = error }
        }
    }

    // MARK: GitHub

    private func invalidateGitHub() {
        overviewRequest = nil; activityRequest = nil; githubSignalsRequest = nil
        overviewLoading = false; activityLoading = false
        overviewAttempt = nil; activityAttempt = nil
    }

    private func updateAlertMonitoring() {
        guard started else { return }
        if githubAlertsWereEnabled != alerts.githubEnabled {
            githubAlertsWereEnabled = alerts.githubEnabled
            githubAlertTracker = GitHubAlertTracker()
            githubSignalsRequest = nil
            if alerts.githubEnabled {
                refreshGitHubSignals()
                refreshOverview()
                refreshActivity()
            }
        }
    }

    private func deliverGitHub(_ signals: [GitHubSignal], scope: String) {
        guard alerts.githubEnabled else { return }
        for signal in githubAlertTracker.observe(signals, scope: scope) {
            // The watched repository reports individual workflow runs, so suppress its duplicate PR rollup.
            let signalRepository = signal.url.path.split(separator: "/").prefix(2).joined(separator: "/")
            if scope.hasPrefix("prs:"), signal.id.contains("-checks"), signalRepository.lowercased() == repository.lowercased() { continue }
            guard let title = signal.alertTitle else { continue }
            alerts.send(title: title, body: signal.detail + " · " + signal.title, url: signal.url)
        }
    }

    private func refreshGitHubSignals() {
        guard alerts.githubEnabled, githubSignalsRequest == nil else { return }
        let request = UUID()
        githubSignalsRequest = request
        Task {
            let result = await Task.detached(priority: .utility) { Result { try GitHubSignalReader.read() } }.value
            guard githubSignalsRequest == request else { return }
            githubSignalsRequest = nil
            switch result {
            case .success(let snapshot):
                githubAlertError = nil
                deliverGitHub(snapshot.signals, scope: "prs:" + snapshot.login)
            case .failure(let error): githubAlertError = error.localizedDescription
            }
        }
    }

    func saveRepository(_ value: String) {
        let normalized = GitHubReader.normalizeRepository(value)
        guard GitHubReader.validRepository(normalized) else { activityError = "Use owner/repository, for example apple/swift."; return }
        repository = normalized
        activityRequest = nil; activityLoading = false
        activityAttempt = nil
        activity = nil
        activityError = nil
        repositorySuggestion = nil
        UserDefaults.standard.set(normalized, forKey: "repository")
        refreshActivity()
    }

    func clearRepository() {
        repository = ""
        activityRequest = nil; activityLoading = false
        activityAttempt = nil
        activity = nil
        activityError = nil
        repositorySuggestion = nil
        UserDefaults.standard.removeObject(forKey: "repository")
    }

    func refreshActivity() {
        guard !activityLoading, !repository.isEmpty else { return }
        activityAttempt = .now
        activityLoading = true
        let request = UUID()
        activityRequest = request
        let requested = repository
        Task {
            let result = await Task.detached(priority: .utility) { Result { try GitHubReader.read(repository: requested) } }.value
            guard activityRequest == request, requested == repository else { return }
            activityRequest = nil
            switch result {
            case .success(let value):
                activity = value; activityError = nil; repositorySuggestion = nil
                deliverGitHub(GitHubSignalReader.runs(value), scope: "runs:" + requested)
            case .failure(let error):
                activityError = error.localizedDescription
                repositorySuggestion = GitHubReader.suggestion(for: requested, among: overview?.repositories ?? [])
            }
            activityLoading = false
        }
    }

    func refreshOverview() {
        guard !overviewLoading else { return }
        overviewAttempt = .now
        overviewLoading = true
        let request = UUID()
        overviewRequest = request
        Task {
            let result = await Task.detached(priority: .utility) { Result { try GitHubReader.readOverview() } }.value
            guard overviewRequest == request else { return }
            overviewRequest = nil
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
        projects.setIslandVisible(started && expanded && tab == .projects)
        if started, expanded, tab == .projects, Date.now.timeIntervalSince(overviewAttempt ?? .distantPast) >= 300 { refreshOverview() }
        guard started, expanded, tab == .activity else { return }
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

    func connectedCursor(_ snapshot: UsageSnapshot) {
        accounts.select(nil, for: .cursor)
        invalidateUsage([.cursor])
        unscopedQuotaHistory[.cursor] = nil
        enabled.insert(.cursor)
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "enabledProviders")
        snapshots[.cursor] = snapshot
        defaultSnapshots[.cursor] = snapshot
        record(snapshot, provider: .cursor)
        errors[.cursor] = nil
    }

    func connectedClaude(_ snapshot: UsageSnapshot) {
        accounts.select(nil, for: .claude)
        invalidateUsage([.claude])
        unscopedQuotaHistory[.claude] = nil
        claudeDirect = true
        UserDefaults.standard.set(true, forKey: "claudeDirect")
        enabled.insert(.claude)
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "enabledProviders")
        errors[.claude] = nil
        claudeMessage = nil
        snapshots[.claude] = snapshot
        defaultSnapshots[.claude] = snapshot
        record(snapshot, provider: .claude)
    }

    func useClaudeCodeSignIn() {
        do {
            accounts.select(nil, for: .claude)
            try SecretStore.remove(account: "claude-web")
            snapshots[.claude] = nil
            setClaudeDirect(true)
        } catch { errors[.claude] = error.localizedDescription }
    }

    func resetConnection(_ provider: Provider) {
        invalidateUsage([provider])
        snapshots[provider] = nil
        errors[provider] = nil
        refresh(provider, allowInteraction: true)
    }

    func saveOpenRouter(_ key: String) {
        do {
            try SecretStore.save(key, account: "openrouter")
            accounts.select(nil, for: .openrouter)
            resetConnection(.openrouter)
        }
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
