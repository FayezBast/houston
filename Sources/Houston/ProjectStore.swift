import AppKit
import Combine
import HoustonCore

enum ProjectSection: String, CaseIterable, Identifiable {
    case overview = "Overview", servers = "Servers", commands = "Commands", containers = "Containers"
    case deployments = "Deployments", errors = "Errors", work = "Work", connections = "Connections"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .servers: "network"
        case .commands: "terminal"
        case .containers: "shippingbox"
        case .deployments: "paperplane"
        case .errors: "exclamationmark.bubble"
        case .work: "checklist"
        case .connections: "link"
        }
    }
}

@MainActor final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [HoustonProject] = []
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { refresh() } } }
    @Published var section: ProjectSection = .overview { didSet { refresh() } }
    @Published private(set) var git: [UUID: GitProjectStatus] = [:]
    @Published private(set) var ports: [LocalPort] = []
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published var message: String?
    @Published var workspaceOpen = false { didSet { updateMonitoring() } }
    @Published private(set) var capturedAt: [String: Date] = [:]
    var onCompletion: ((CommandRun) -> Void)?
    var monitorInBackground = false { didSet { updateMonitoring() } }
    var suspended = false { didSet { if suspended { stop() }; updateMonitoring() } }
    let runner: CommandRunner
    let cloud: CloudStore
    private let file: URL
    private var readable = true
    private var islandVisible = false
    private var timer: Timer?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cloudAttempt: [UUID: Date] = [:]
    private var cloudTasks: [UUID: Task<Void, Never>] = [:]
    private let gitReader: @Sendable (String) throws -> GitProjectStatus
    private let portReader: @Sendable () throws -> [LocalPort]
    private let containerReader: @Sendable () throws -> [DockerContainer]
    private var observations = Set<AnyCancellable>()

    init(file: URL, runner: CommandRunner? = nil, cloud: CloudStore? = nil,
         gitReader: @escaping @Sendable (String) throws -> GitProjectStatus = ProjectTools.readGit,
         portReader: @escaping @Sendable () throws -> [LocalPort] = ProjectTools.readPorts,
         containerReader: @escaping @Sendable () throws -> [DockerContainer] = ProjectTools.dockerContainers) {
        self.file = file
        self.gitReader = gitReader; self.portReader = portReader; self.containerReader = containerReader
        self.runner = runner ?? CommandRunner()
        self.cloud = cloud ?? CloudStore()
        do { projects = try ProjectLibrary.load(from: file) }
        catch { readable = false; message = "Your project library could not be read. It has been left untouched. " + error.localizedDescription }
        selectedID = projects.first?.id
        for publisher in [self.runner.objectWillChange.eraseToAnyPublisher(), self.cloud.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        self.runner.onCompletion = { [weak self] run in self?.onCompletion?(run) }
    }

    var selected: HoustonProject? { projects.first { $0.id == selectedID } }
    var visible: Bool { islandVisible || workspaceOpen }
    var projectPorts: [LocalPort] {
        guard let selected else { return [] }
        return ports.filter { Self.belongs($0.projectPath, to: selected.path) }
    }
    var projectRuns: [CommandRun] { runner.runs.filter { $0.projectID == selectedID } }
    var runningCount: Int { runner.runs.filter(\.isRunning).count }

    static func belongs(_ child: String?, to path: String) -> Bool {
        guard let child else { return false }
        let parent = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: child).standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == parent || candidate.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    @discardableResult func save(_ project: HoustonProject) -> Bool {
        do {
            guard readable else { throw UsageError.unavailable("Resolve the unreadable project library before saving changes.") }
            var project = project
            project.path = try ProjectLibrary.normalizedDirectory(project.path)
            project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            project.webURL = project.webURL.trimmingCharacters(in: .whitespacesAndNewlines)
            project.vercelProjectID = project.vercelProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            project.vercelTeamID = project.vercelTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
            project.sentryOrganization = project.sentryOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            project.sentryProject = project.sentryProject.trimmingCharacters(in: .whitespacesAndNewlines)
            project.sentryEnvironment = project.sentryEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
            project.linearProjectID = project.linearProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !project.name.isEmpty else { throw UsageError.unavailable("Give this project a name.") }
            guard !projects.contains(where: { $0.id != project.id && $0.path == project.path }) else {
                throw UsageError.unavailable("This folder is already in your projects.")
            }
            if !project.webURL.isEmpty, Self.webURL(project.webURL) == nil {
                throw UsageError.unavailable("Use an http or https address for the project website.")
            }
            guard project.commands.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw UsageError.unavailable("Each command needs a name and a command to run.")
            }
            var updated = projects
            let activeIDs = Set(runner.runs.filter { $0.projectID == project.id && $0.isRunning }.map(\.id))
            if let existing = projects.first(where: { $0.id == project.id }), !activeIDs.isEmpty {
                guard existing.path == project.path, existing.commands.filter({ activeIDs.contains($0.id) }) == project.commands.filter({ activeIDs.contains($0.id) }) else {
                    throw UsageError.unavailable("Stop running commands before editing or removing them, or changing the project folder.")
                }
            }
            if let index = updated.firstIndex(where: { $0.id == project.id }) { updated[index] = project }
            else { updated.append(project) }
            try ProjectLibrary.save(updated, to: file)
            if let previous = projects.first(where: { $0.id == project.id }), previous.path != project.path {
                let key = "git.\(project.id)"
                tasks[key]?.cancel(); tasks[key] = nil; loading.remove(key)
                git[project.id] = nil; errors[key] = nil; capturedAt[key] = nil
            }
            projects = updated
            selectedID = project.id
            message = nil
            cloudAttempt[project.id] = nil
            cloud.prepare(project: project)
            refresh()
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func remove(_ project: HoustonProject) {
        do {
            guard !runner.runs.contains(where: { $0.projectID == project.id && $0.isRunning }) else {
                throw UsageError.unavailable("Stop this project’s running commands before removing it.")
            }
            let updated = projects.filter { $0.id != project.id }
            try ProjectLibrary.save(updated, to: file)
            projects = updated; git[project.id] = nil
            if selectedID == project.id { selectedID = updated.first?.id }
            message = nil
        } catch { message = error.localizedDescription }
    }

    func setIslandVisible(_ visible: Bool) { islandVisible = visible; updateMonitoring() }

    private func updateMonitoring() {
        timer?.invalidate(); timer = nil
        guard !suspended, visible || monitorInBackground else { return }
        refresh(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: visible ? 10 : 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: false) }
        }
        timer?.tolerance = visible ? 2 : 10
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); loading.removeAll()
        for task in cloudTasks.values { task.cancel() }
        cloudTasks.removeAll()
        cloud.suspend()
    }

    func refresh(force: Bool = true) {
        guard !suspended, force || visible || monitorInBackground else { return }
        if let project = selected {
            if visible || force {
                let key = "git.\(project.id)"
                if tasks[key] == nil {
                    loading.insert(key)
                    let read = gitReader
                    tasks[key] = Task { [weak self] in
                        let result = await Task.detached(priority: .utility) { Result { try read(project.path) } }.value
                        guard let self, !Task.isCancelled else { return }
                        if self.projects.contains(where: { $0.id == project.id && $0.path == project.path }) {
                            switch result {
                            case .success(let value): self.git[project.id] = value; self.errors[key] = nil; self.capturedAt[key] = .now
                            case .failure(let error): self.errors[key] = error.localizedDescription
                            }
                        }
                        self.loading.remove(key); self.tasks[key] = nil
                    }
                }
            }
            let needsCloud = [.overview, .deployments, .errors, .work].contains(section) || monitorInBackground
            if needsCloud, cloudTasks[project.id] == nil, force || Date.now.timeIntervalSince(cloudAttempt[project.id] ?? .distantPast) >= 60 {
                cloudAttempt[project.id] = .now
                cloudTasks[project.id] = Task { [weak self] in
                    guard let self else { return }
                    await self.cloud.refresh(project: project)
                    guard !Task.isCancelled else { return }
                    self.cloudTasks[project.id] = nil
                    if self.selected?.id == project.id, self.selected != project { self.refresh() }
                }
            }
        }
        if visible || force {
            if [.overview, .servers].contains(section), tasks["ports"] == nil {
                loading.insert("ports")
                let read = portReader
                tasks["ports"] = Task { [weak self] in
                    let result = await Task.detached(priority: .utility) { Result { try read() } }.value
                    guard let self, !Task.isCancelled else { return }
                    switch result {
                    case .success(let value): self.ports = value; self.errors["ports"] = nil; self.capturedAt["ports"] = .now
                    case .failure(let error): self.errors["ports"] = error.localizedDescription
                    }
                    self.loading.remove("ports"); self.tasks["ports"] = nil
                }
            }
            if section == .containers, tasks["docker"] == nil { refreshContainers() }
        }
    }

    private func refreshContainers() {
        loading.insert("docker")
        let read = containerReader
        tasks["docker"] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try read() } }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let value): self.containers = value; self.errors["docker"] = nil; self.capturedAt["docker"] = .now
            case .failure(let error): self.errors["docker"] = error.localizedDescription
            }
            self.loading.remove("docker"); self.tasks["docker"] = nil
        }
    }

    func stopPort(_ port: LocalPort) {
        perform("stop.\(port.id)") { [runner] in try await runner.stop(port: port) }
    }

    func containerAction(_ container: DockerContainer, _ action: DockerAction) {
        perform("container.\(container.id)") { try ProjectTools.dockerAction(id: container.id, action: action) }
    }

    private func perform(_ key: String, operation: @escaping @Sendable () async throws -> Void) {
        guard !suspended, tasks[key] == nil else { return }
        loading.insert(key)
        tasks[key] = Task { [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do { try await operation(); return .success(()) }
                catch { return .failure(error) }
            }.value
            guard let self, !Task.isCancelled else { return }
            if case .failure(let error) = result { self.message = error.localizedDescription }
            else { self.message = nil }
            self.loading.remove(key); self.tasks[key] = nil; self.refresh()
        }
    }

    static func webURL(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func openProject(_ project: HoustonProject, terminal: Bool = false) {
        let url = URL(fileURLWithPath: project.path)
        guard FileManager.default.fileExists(atPath: url.path) else { message = "The project folder is no longer available."; return }
        let bundleID = terminal ? "com.apple.Terminal" : project.editorBundleID
        if !bundleID.isEmpty {
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                message = "The selected app is not installed. Choose another app in project settings."; return
            }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.message = error.localizedDescription } }
            }
        } else { NSWorkspace.shared.open(url) }
    }
}
