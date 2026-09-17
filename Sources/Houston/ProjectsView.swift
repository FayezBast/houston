import AppKit
import SwiftUI
import HoustonCore

struct ProjectsView: View {
    @ObservedObject var store: Store
    @ObservedObject var projects: ProjectStore
    var compact = true
    @State private var editingProject: HoustonProject?
    @State private var removeProject: HoustonProject?

    init(store: Store, compact: Bool = true) {
        self.store = store; self.projects = store.projects; self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                HoustonPageHeader(title: projects.selected == nil || projects.section == .overview ? "Your projects" : projects.section.rawValue,
                                  subtitle: subtitle)
                if compact {
                    Button { ProjectWorkspaceWindow.shared.show(store: store) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 32, height: 32)
                    }.buttonStyle(.borderless).help("Open the project workspace")
                        .accessibilityLabel("Open project workspace")
                }
            }
            projectControls
            if let message = projects.message {
                Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let project = projects.selected {
                if compact {
                    Picker("Show", selection: $projects.section) {
                        ForEach(ProjectSection.allCases) { section in Label(section.rawValue, systemImage: section.symbol).tag(section) }
                    }.pickerStyle(.menu).font(.system(size: 13)).accessibilityLabel("Project section")
                }
                ProjectContentView(store: store, project: project, onEdit: { editingProject = project })
            } else {
                ProjectEmptyState(title: "A home for your work", detail: "Add a project folder to bring its branch, servers, commands, agents, and cloud tools into one place.", symbol: "folder.badge.plus")
                Button("Add a project…", action: chooseProject).buttonStyle(.borderedProminent)
            }
        }
        .sheet(item: $editingProject, onDismiss: { store.editing = false }) { project in
            ProjectEditor(project: project, projects: projects) { editingProject = nil; store.editing = false }
                .onAppear { store.editing = true }
        }
        .alert("Remove project?", isPresented: Binding(get: { removeProject != nil }, set: { if !$0 { removeProject = nil } })) {
            Button("Cancel", role: .cancel) { removeProject = nil }
            Button("Remove", role: .destructive) {
                if let project = removeProject { projects.remove(project) }
                removeProject = nil
            }
        } message: { Text("The folder and its files will stay on your Mac.") }
    }

    private var projectControls: some View {
        HStack(spacing: 10) {
            if !projects.projects.isEmpty {
                Picker("Project", selection: $projects.selectedID) {
                    ForEach(projects.projects) { project in Text(project.name).tag(Optional(project.id)) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel("Selected project")
            }
            Button(action: chooseProject) { Image(systemName: "plus").frame(width: 20, height: 22) }
                .help("Add project").accessibilityLabel("Add project")
            if let project = projects.selected {
                Menu {
                    Button("Project settings…") { editingProject = project }
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
                    Divider()
                    Button("Remove project…", role: .destructive) { removeProject = project }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Project actions")
            }
        }.controlSize(.regular)
    }

    private func chooseProject() {
        store.editing = true
        let panel = NSOpenPanel()
        panel.title = "Add a project"; panel.prompt = "Choose project"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            editingProject = HoustonProject(name: url.lastPathComponent, path: url.path)
        } else { store.editing = false }
    }

    private var subtitle: String {
        guard let project = projects.selected else { return "Your work, in one place." }
        switch projects.section {
        case .overview: return "Everything running. Everything that needs you."
        case .servers: return "Listening ports and processes for \(project.name)."
        case .commands: return "Build, test, and run \(project.name)."
        case .containers: return "Local services in your Docker context."
        case .deployments: return "Build status and previews for \(project.name)."
        case .errors: return "Production issues that need your attention."
        case .work: return "Reviews and assigned work for \(project.name)."
        case .connections: return "Connect your tools. Credentials stay in Keychain."
        }
    }
}

struct ProjectContentView: View {
    @ObservedObject var store: Store
    @ObservedObject var projects: ProjectStore
    let project: HoustonProject
    let onEdit: () -> Void
    @State private var portToStop: LocalPort?
    @State private var containerToStop: DockerContainer?
    @State private var showAllPorts = false
    @State private var search = ""
    @State private var log: ProjectLog?
    @State private var loadingLog = false
    @State private var historySearch = ""
    @State private var clearingHistory = false

    init(store: Store, project: HoustonProject, onEdit: @escaping () -> Void) {
        self.store = store; self.projects = store.projects; self.project = project; self.onEdit = onEdit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch projects.section {
            case .overview: overview
            case .servers: servers
            case .commands: commands
            case .containers: containers
            case .deployments: CloudToolsView(store: projects.cloud, project: project, section: .deployments, onEditing: { store.editing = $0 }, showsHeader: false)
            case .errors: CloudToolsView(store: projects.cloud, project: project, section: .errors, onEditing: { store.editing = $0 }, showsHeader: false)
            case .work:
                githubWork
                CloudToolsView(store: projects.cloud, project: project, section: .work, onEditing: { store.editing = $0 }, showsHeader: false)
            case .connections:
                Text("Connect an account once, then choose its project in Project settings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Project settings…", action: onEdit)
                CloudConnectionsView(store: projects.cloud, onEditing: { store.editing = $0 }, showsHeader: false)
            }
        }
        .onChange(of: project.id) { _, _ in search = ""; showAllPorts = false; log = nil }
        .alert("Stop this server?", isPresented: Binding(get: { portToStop != nil }, set: { if !$0 { portToStop = nil } })) {
            Button("Cancel", role: .cancel) { portToStop = nil }
            Button("Stop server", role: .destructive) { if let port = portToStop { projects.stopPort(port) }; portToStop = nil }
        } message: { Text(verbatim: "Houston will ask \(portToStop?.process ?? "the process") on port \(portToStop?.port ?? 0) to quit. If Houston launched this server, its command will stop too. Other ports owned by the process will close.") }
        .alert("Stop this container?", isPresented: Binding(get: { containerToStop != nil }, set: { if !$0 { containerToStop = nil } })) {
            Button("Cancel", role: .cancel) { containerToStop = nil }
            Button("Stop container", role: .destructive) { if let container = containerToStop { projects.containerAction(container, .stop) }; containerToStop = nil }
        } message: { Text(containerToStop?.name ?? "") }
        .sheet(item: $log, onDismiss: { store.editing = false }) { item in
            ProjectLogView(title: item.title, output: item.output, commandID: item.commandID, runner: projects.runner)
                .onAppear { store.editing = true }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.fill").font(.system(size: 23)).foregroundStyle(.blue)
                        .frame(width: 44, height: 44).background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.name).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                        Text(project.path).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                if let git = projects.git[project.id] {
                    HStack(spacing: 8) {
                        Label(git.branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                        Spacer(minLength: 2)
                        Text(git.changedFiles == 0 ? "Clean" : "\(git.changedFiles) changed")
                            .foregroundStyle(git.changedFiles == 0 ? Color.secondary : .orange)
                    }.font(.system(size: 12)).help("Working tree status")
                }
                if let error = projects.errors["git.\(project.id)"] {
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { projectActions }
                    VStack(alignment: .leading, spacing: 8) { projectActions }
                }.controlSize(.small)
            }.padding(16).houstonCard()

            attention
            HStack(spacing: 10) {
                metric("Servers", value: projects.errors["ports"] != nil ? "Unavailable" : projects.capturedAt["ports"] == nil ? "—" : "\(projects.projectPorts.count)", symbol: "network", section: .servers)
                metric("Commands", value: "\(projects.projectRuns.filter(\.isRunning).count) running", symbol: "terminal", section: .commands)
            }
            quickCommands
            let sessions = store.agents.sessions.filter { ProjectStore.belongs($0.projectPath, to: project.path) }
            VStack(alignment: .leading, spacing: 10) {
                HoustonSectionHeading(title: "Agents", count: sessions.count)
                if sessions.isEmpty {
                    Button { store.tab = .agents; store.expanded = true } label: {
                        Label("Connect an agent to follow its work here", systemImage: "terminal")
                            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.buttonStyle(.plain).houstonCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(sessions.prefix(5)) { session in
                            Button { store.agents.open(session: session) } label: {
                                HStack(spacing: 10) {
                                    BrandLogo(name: session.provider.rawValue == "codex" ? "openai" : session.provider.rawValue, size: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.provider.name).font(.system(size: 13, weight: .medium))
                                        Text(session.isStale() ? "Earlier status · \(session.status.title)" : session.status.title)
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                }.padding(14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if session.id != sessions.prefix(5).last?.id { Divider().padding(.leading, 42) }
                        }
                    }.houstonCard()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HoustonSectionHeading(title: "Connected work")
                overviewLink("Deployments", detail: cloudSummary(.vercel), section: .deployments)
                overviewLink("Production errors", detail: cloudSummary(.sentry), section: .errors)
                overviewLink("Reviews & assigned issues", detail: cloudSummary(.linear), section: .work)
            }
        }
    }

    @ViewBuilder private var attention: some View {
        let items = ProjectAttention.items(for: project, runs: projects.projectRuns, snapshot: projects.cloud.snapshot(for: project))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HoustonSectionHeading(title: "Needs attention", count: items.count)
                ForEach(items) { item in
                    overviewLink(item.title, detail: item.detail, section: item.section, tint: .orange)
                }
            }
        }
    }

    private var quickCommands: some View {
        let controls = projects.commandControls(for: project)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                HoustonSectionHeading(title: "Quick commands", count: controls.count)
                Button("View all") { projects.section = .commands }.controlSize(.small)
            }
            if controls.isEmpty {
                Button(action: onEdit) {
                    Label("Add a dev, build, or test command", systemImage: "plus.circle")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.buttonStyle(.plain).houstonCard()
            } else {
                ForEach(controls.prefix(3)) { command in commandCard(command, compact: true) }
            }
        }
    }

    @ViewBuilder private var projectActions: some View {
        Button { projects.openProject(project) } label: { Label(project.editorBundleID.isEmpty ? "Folder" : "Editor", systemImage: "arrow.up.forward.app") }
        Button { projects.openProject(project, terminal: true) } label: { Label("Terminal", systemImage: "terminal") }
        if let url = ProjectStore.webURL(project.webURL) { Link(destination: url) { Label("Website", systemImage: "globe") } }
    }

    private func metric(_ title: String, value: String, symbol: String, section: ProjectSection) -> some View {
        Button { projects.section = section } label: {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).houstonCard()
        }.buttonStyle(.plain)
    }

    private func cloudSummary(_ provider: CloudProvider) -> String {
        let snapshot = projects.cloud.snapshot(for: project)
        guard let state = snapshot.states[provider] else { return "Connect \(provider.title)" }
        if state.isLoading && state.updatedAt == nil { return "Checking \(provider.title)…" }
        if state.message != nil { return state.updatedAt == nil ? "Set up \(provider.title)" : "Update failed · earlier reading" }
        guard state.updatedAt != nil else { return "Connect \(provider.title)" }
        switch provider {
        case .vercel:
            guard let deployment = snapshot.deployments.first else { return "No deployments yet" }
            return [deployment.state.capitalized, deployment.branch].filter { !$0.isEmpty }.joined(separator: " · ")
        case .sentry: return snapshot.errors.isEmpty ? "No unresolved issues" : "\(snapshot.errors.count) unresolved issues"
        case .linear: return snapshot.work.isEmpty ? "No assigned issues · GitHub reviews" : "\(snapshot.work.count) assigned issues · GitHub reviews"
        }
    }

    private func overviewLink(_ title: String, detail: String, section: ProjectSection, tint: Color = .blue) -> some View {
        Button { projects.section = section } label: {
            HStack(spacing: 12) {
                Image(systemName: section.symbol).foregroundStyle(tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(14).contentShape(Rectangle()).houstonCard()
        }.buttonStyle(.plain)
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 14) {
            HoustonSectionHeading(title: "Local servers")
            Toggle("Show all listening ports on this Mac", isOn: $showAllPorts).font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            TextField("Filter by port or process", text: $search).textFieldStyle(.roundedBorder)
            status("ports")
            let ports = (showAllPorts ? projects.ports : projects.projectPorts).filter { search.isEmpty || "\($0.port) \($0.process)".localizedCaseInsensitiveContains(search) }
            if ports.isEmpty, !projects.loading.contains("ports") {
                ProjectEmptyState(title: search.isEmpty ? "No servers in view" : "No matching servers", detail: showAllPorts ? "Start a development server, then refresh." : "Servers are matched by their working folder. Turn on all ports to find services launched elsewhere.", symbol: "network")
            }
            ForEach(ports) { port in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green).accessibilityHidden(true)
                        Text(verbatim: ":\(port.port)").font(.system(size: 16, weight: .semibold, design: .monospaced))
                        Text(port.process).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Text(verbatim: "PID \(port.pid)")
                        if let cpu = port.cpuPercent { Text(String(format: "%.1f%% CPU", cpu)) }
                        if let memory = port.memoryMB { Text(String(format: "%.0f MB", memory)) }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    HStack {
                        Button("Open address") {
                            if let url = port.url { NSWorkspace.shared.open(url) }
                        }
                        Button("Copy address") { copy(port.url?.absoluteString ?? "localhost:\(port.port)") }
                        Spacer(minLength: 0)
                        Button { portToStop = port } label: { Image(systemName: "stop.fill") }
                            .disabled(projects.loading.contains("stop.\(port.id)"))
                            .accessibilityLabel(Text(verbatim: "Stop \(port.process) on port \(port.port)")).help("Stop server…")
                    }.controlSize(.small)
                }.padding(16).houstonCard()
            }
        }
    }

    private var commands: some View {
        let controls = projects.commandControls(for: project)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HoustonSectionHeading(title: "Project commands", count: controls.count)
                Button("Edit…", action: onEdit).controlSize(.small)
            }
            if controls.isEmpty {
                ProjectEmptyState(title: "Make the repetitive work easy", detail: "Save your dev, build, test, and lint commands. Each runs in this project’s folder when you press Run.", symbol: "terminal")
                Button("Add commands…", action: onEdit).buttonStyle(.borderedProminent)
            }
            ForEach(controls) { command in commandCard(command) }
            commandHistory
            Text("The latest 100 runs and bounded output are saved on this Mac. Logs can contain sensitive output; clear history when needed. Closing the panel keeps commands running; quitting Houston stops them.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandHistory: some View {
        let records = projects.runner.history.filter {
            $0.projectID == project.id && (historySearch.isEmpty ||
                ($0.commandName + " " + $0.command + " " + $0.output).localizedCaseInsensitiveContains(historySearch))
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                HoustonSectionHeading(title: "Run history", count: records.count)
                Button("Clear…") { clearingHistory = true }.disabled(records.isEmpty)
            }
            if let error = projects.runner.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
            TextField("Search commands and output", text: $historySearch).textFieldStyle(.roundedBorder)
            ForEach(records, id: \.runID) { run in
                VStack(alignment: .leading, spacing: 8) {
                    Text(run.commandName).font(.headline)
                    Text(run.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label(runLabel(run), systemImage: runSymbol(run)).foregroundStyle(runColor(run))
                        Spacer()
                        Button("Output") { log = ProjectLog(title: run.commandName, output: run.output) }
                        Button("Rerun") {
                            projects.runner.run(project: project, command: ProjectCommand(id: run.id, name: run.commandName, command: run.command))
                        }.disabled(run.path != project.path || projects.runner.runs.contains { $0.id == run.id && $0.isRunning })
                            .help("Run this exact command again in its original project folder")
                    }.font(.caption).controlSize(.small)
                }.padding(14).houstonCard()
            }
            if records.isEmpty { Text("No matching runs yet.").font(.caption).foregroundStyle(.secondary) }
        }
        .alert("Clear command history for this project?", isPresented: $clearingHistory) {
            Button("Cancel", role: .cancel) {}
            Button("Clear history", role: .destructive) { projects.runner.clearHistory(projectID: project.id) }
        } message: { Text("Saved results and logs will be removed. Running commands stay active.") }
    }

    private func commandCard(_ command: ProjectCommand, compact: Bool = false) -> some View {
        let run = projects.runner.runs.first {
            $0.id == command.id && $0.projectID == project.id && $0.path == project.path && $0.command == command.command
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(command.name).font(.system(size: 14, weight: .semibold))
                    Text(command.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 3).textSelection(.enabled)
                }
                Spacer(minLength: 4)
                if run?.isRunning == true {
                    Button { projects.runner.stop(id: command.id) } label: { Image(systemName: "stop.fill") }
                        .help("Stop command").accessibilityLabel("Stop \(command.name)")
                } else {
                    Button { projects.runner.run(project: project, command: command) } label: { Image(systemName: "play.fill") }
                        .help("Run command").accessibilityLabel("Run \(command.name)").tint(.blue)
                }
            }
            if let run {
                HStack {
                    Label(runLabel(run), systemImage: runSymbol(run)).foregroundStyle(runColor(run))
                    Spacer()
                    Button("View output") { log = ProjectLog(title: command.name, output: run.output, commandID: command.id) }
                }.font(.system(size: 11)).controlSize(.small)
                if !compact, let ended = run.endedAt {
                    Text("\(max(0, Int(ended.timeIntervalSince(run.startedAt)))) s · \(ended.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }.padding(16).houstonCard()
    }

    private var containers: some View {
        VStack(alignment: .leading, spacing: 14) {
            HoustonSectionHeading(title: "Docker containers", count: projects.containers.count)
            Text("All containers in your current Docker context.").font(.system(size: 12)).foregroundStyle(.secondary)
            status("docker")
            if projects.containers.isEmpty, !projects.loading.contains("docker"), projects.errors["docker"] == nil {
                ProjectEmptyState(title: "No containers yet", detail: "Start Docker and create a container to see its state, ports, and logs here.", symbol: "shippingbox")
            }
            ForEach(projects.containers) { container in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "shippingbox").foregroundStyle(container.state == "running" ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(container.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text(container.image).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(container.status).font(.system(size: 12)).foregroundStyle(container.state == "running" ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !container.ports.isEmpty { Text(container.ports).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack(spacing: 8) {
                        if let cpu = container.cpuPercent { Text(String(format: "%.1f%% CPU", cpu)) }
                        if let memory = container.memory { Text(memory) }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Logs") { loadLogs(container) }.disabled(loadingLog)
                        Spacer(minLength: 0)
                        if container.state == "running" {
                            Button("Restart") { projects.containerAction(container, .restart) }
                            Button("Stop") { containerToStop = container }
                        } else { Button("Start") { projects.containerAction(container, .start) } }
                    }.controlSize(.small).disabled(projects.loading.contains("container.\(container.id)"))
                }.padding(16).houstonCard()
            }
        }
    }

    private var githubWork: some View {
        VStack(alignment: .leading, spacing: 10) {
            HoustonSectionHeading(title: "GitHub reviews")
            if let overview = store.overview {
                let repository = projects.git[project.id]?.remote.map(GitHubReader.normalizeRepository).flatMap { GitHubReader.validRepository($0) ? $0 : nil }
                let items = overview.reviewRequests.filter { item in
                    guard let repository else { return true }
                    return item.url.path.lowercased().hasPrefix("/" + repository.lowercased() + "/")
                }
                Text("Showing up to \(GitHubReader.overviewReviewLimit) recent requests across GitHub\(repository.map { ", filtered to " + $0 } ?? ""). Older requests may be missing.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = store.overviewError ?? overview.note {
                    Label("GitHub could not fully refresh. " + error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if items.isEmpty {
                    Label("No matching reviews in these recent results", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(items.prefix(10)) { item in
                    Link(destination: item.url) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).houstonCard()
                    }.buttonStyle(.plain)
                }
                Link("View all review requests on GitHub ↗", destination: GitHubReader.reviewSearchURL(repository: repository))
                    .font(.caption)
            } else {
                Text(store.overviewError ?? "Use your GitHub CLI sign-in to load review requests.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(store.overviewLoading ? "Checking…" : "Refresh GitHub") { store.refreshOverview() }
                .disabled(store.overviewLoading).controlSize(.small)
        }
    }

    @ViewBuilder private func status(_ key: String) -> some View {
        if let error = projects.errors[key] {
            Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if projects.capturedAt[key] != nil { Text("Showing the last successful reading.").font(.caption).foregroundStyle(.secondary) }
        }
        if projects.loading.contains(key) { ProgressView("Updating…").controlSize(.small).font(.caption) }
        else if let captured = projects.capturedAt[key] {
            Text("Updated \(captured.formatted(date: .omitted, time: .standard))").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func loadLogs(_ container: DockerContainer) {
        loadingLog = true
        Task {
            let result = await Task.detached(priority: .utility) { Result { try ProjectTools.dockerLogs(id: container.id) } }.value
            loadingLog = false
            switch result {
            case .success(let output): log = ProjectLog(title: container.name, output: output)
            case .failure(let error): projects.message = error.localizedDescription
            }
        }
    }

    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func runLabel(_ run: CommandRun) -> String {
        switch run.status {
        case .running: "Running"
        case .succeeded: "Passed"
        case .failed: run.exitCode.map { "Failed · exit \($0)" } ?? "Could not start"
        case .cancelled: "Stopped"
        case .interrupted: "Interrupted"
        }
    }
    private func runSymbol(_ run: CommandRun) -> String {
        switch run.status {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .interrupted: "pause.circle"
        }
    }
    private func runColor(_ run: CommandRun) -> Color {
        switch run.status {
        case .running: .blue
        case .succeeded: .green
        case .failed: .orange
        case .cancelled, .interrupted: .secondary
        }
    }
}

struct ProjectEmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(.secondary).padding(.bottom, 4)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).houstonCard()
    }
}

private struct ProjectLog: Identifiable {
    let id = UUID()
    let title: String
    let output: String
    var commandID: UUID? = nil
}

struct ProjectLogView: View {
    let title: String
    let output: String
    let commandID: UUID?
    @ObservedObject var runner: CommandRunner
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var text: String { commandID.flatMap { id in runner.runs.first { $0.id == id }?.output } ?? output }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            TextField("Filter output lines", text: $query).textFieldStyle(.roundedBorder)
            ScrollView([.horizontal, .vertical]) {
                Text(query.isEmpty ? (text.isEmpty ? "No output recorded." : text) : text.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
            }.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }.padding(20).frame(minWidth: 500, idealWidth: 680, minHeight: 360, idealHeight: 500)
    }
}

struct ProjectEditor: View {
    @State var project: HoustonProject
    @ObservedObject var projects: ProjectStore
    let done: () -> Void
    @State private var page = "General"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Project settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") { if projects.save(project) { done() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            Picker("Settings", selection: $page) {
                Text("General").tag("General"); Text("Commands").tag("Commands"); Text("Cloud projects").tag("Cloud projects")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case "Commands": commandFields
                    case "Cloud projects": cloudFields
                    default: generalFields
                    }
                }.padding(.vertical, 8)
            }
            if let message = projects.message { Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.padding(24).frame(width: 530, height: 510)
    }

    private var generalFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("Name", text: $project.name, prompt: "My project")
            field("Folder", text: $project.path, prompt: "/path/to/project")
            Picker("Open with", selection: $project.editorBundleID) {
                Text("Finder").tag("")
                Text("Cursor").tag("com.todesktop.230313mzl4w4u92")
                Text("Visual Studio Code").tag("com.microsoft.VSCode")
                Text("Xcode").tag("com.apple.dt.Xcode")
                Text("Zed").tag("dev.zed.Zed")
                Text("Sublime Text").tag("com.sublimetext.4")
            }
            field("Website or local preview", text: $project.webURL, prompt: "http://localhost:3000")
            Text("Your folder stays where it is. Houston saves only these settings and the commands you add.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commands run in this project’s folder using your login shell environment.").font(.callout).foregroundStyle(.secondary)
            ForEach($project.commands) { $command in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Name · e.g. Tests", text: $command.name)
                        Button(role: .destructive) { project.commands.removeAll { $0.id == command.id } } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Remove command \(command.name)")
                    }
                    TextField("Command · e.g. npm test", text: $command.command, axis: .vertical)
                        .font(.system(size: 12, design: .monospaced)).lineLimit(2...5)
                }.textFieldStyle(.roundedBorder).padding(14).houstonCard()
            }
            Button { project.commands.append(ProjectCommand(name: "", command: "")) } label: { Label("Add command", systemImage: "plus") }
            Text("Examples: npm run dev · swift test · pytest · cargo build. Adding or editing a command never runs it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cloudFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect account tokens under Connections. Map each service to this project here.").font(.callout).foregroundStyle(.secondary)
            GroupBox("Vercel") {
                VStack(spacing: 12) {
                    field("Project ID or name", text: $project.vercelProjectID, prompt: "prj_… or my-project")
                    field("Team ID (optional)", text: $project.vercelTeamID, prompt: "team_…")
                }.padding(8)
            }
            GroupBox("Sentry") {
                VStack(spacing: 12) {
                    field("Organization slug", text: $project.sentryOrganization, prompt: "my-team")
                    field("Project slug", text: $project.sentryProject, prompt: "my-app")
                    field("Environment (optional)", text: $project.sentryEnvironment, prompt: "production")
                }.padding(8)
            }
            GroupBox("Linear") {
                field("Project ID (optional)", text: $project.linearProjectID, prompt: "Leave empty for all assigned issues").padding(8)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

@MainActor final class ProjectWorkspaceWindow: NSObject, NSWindowDelegate {
    static let shared = ProjectWorkspaceWindow()
    private var window: NSWindow?
    private weak var projects: ProjectStore?

    func show(store: Store) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Houston · Projects"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 700, height: 520)
            window.contentView = NSHostingView(rootView: ProjectWorkspaceView(store: store))
            window.delegate = self; window.center(); self.window = window
        }
        projects = store.projects; store.projects.workspaceOpen = true
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { projects?.workspaceOpen = false }
    func windowDidMiniaturize(_ notification: Notification) { projects?.workspaceOpen = false }
    func windowDidDeminiaturize(_ notification: Notification) { projects?.workspaceOpen = true }
}

struct ProjectWorkspaceView: View {
    @ObservedObject var store: Store
    @ObservedObject var projects: ProjectStore
    init(store: Store) { self.store = store; self.projects = store.projects }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Label("HOUSTON", systemImage: "circle.hexagongrid.fill").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 12)
                List(selection: $projects.section) {
                    Section("Workspace") {
                        ForEach(ProjectSection.allCases) { section in
                            Label(section.rawValue, systemImage: section.symbol).tag(section)
                        }
                    }
                }.listStyle(.sidebar)
                HStack {
                    Text("\(projects.runningCount) commands running").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { projects.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh project").accessibilityLabel("Refresh project")
                }.padding(12)
            }.frame(width: 200).background(.ultraThinMaterial)
            Divider()
            ScrollView {
                ProjectsView(store: store, compact: false).frame(maxWidth: 720, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
