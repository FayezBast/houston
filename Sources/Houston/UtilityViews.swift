import AppKit
import SwiftUI
import HoustonCore

enum UtilityPage: String { case setup = "Welcome to Houston", health = "Connection health", palette = "Command palette" }

@MainActor final class UtilityWindow {
    static let shared = UtilityWindow()
    private var window: NSPanel?

    func show(store: Store, page: UtilityPage) {
        if window == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 500, height: 400)
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.level = .floating
            window.center()
            self.window = window
        }
        window?.title = "Houston · " + page.rawValue
        window?.contentView = NSHostingView(rootView: UtilityContent(store: store, page: page))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func close() { window?.orderOut(nil) }
}

struct UtilityContent: View {
    @ObservedObject var store: Store
    let page: UtilityPage
    var body: some View {
        Group {
            switch page {
            case .palette: CommandPaletteView(store: store)
            case .setup: SetupView(store: store)
            case .health:
                ScrollView { ConnectionHealthView(store: store).padding(24) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand { UtilityWindow.shared.close() }
    }
}

struct PaletteAction: Identifiable {
    enum Destination: Equatable {
        case tab(PanelTab), project(UUID), command(UUID, UUID), agent(String), setup, health
    }
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let destination: Destination

    static func matching(_ actions: [Self], query: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return actions.filter { action in
            words.allSatisfy { (action.title + " " + action.detail).localizedCaseInsensitiveContains($0) }
        }
    }
}

struct CommandPaletteView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searching: Bool

    var actions: [PaletteAction] {
        var items = PanelTab.allCases.map {
            PaletteAction(id: "tab." + $0.rawValue, title: "Open " + $0.rawValue, detail: "Houston", symbol: "arrow.up.right", destination: .tab($0))
        }
        items += [PaletteAction(id: "setup", title: "Guided setup", detail: "Connect your tools", symbol: "sparkles", destination: .setup),
                  PaletteAction(id: "health", title: "Connection health", detail: "Check accounts and repair hooks", symbol: "heart.text.square", destination: .health)]
        for project in store.projects.projects {
            items.append(PaletteAction(id: "project.\(project.id)", title: project.name, detail: project.path, symbol: "folder", destination: .project(project.id)))
            for command in project.commands {
                let running = store.projects.runner.runs.contains { $0.id == command.id && $0.isRunning }
                if !running {
                    items.append(PaletteAction(id: "command.\(command.id)", title: "Run " + command.name,
                                               detail: project.name + " · " + command.command, symbol: "play", destination: .command(project.id, command.id)))
                }
            }
        }
        items += store.agents.sessions.map {
            PaletteAction(id: "agent." + $0.id, title: $0.provider.name + " · " + $0.projectName,
                          detail: $0.status.title + ($0.isStale() ? " · last known" : ""), symbol: "terminal", destination: .agent($0.id))
        }
        return items
    }
    private var filtered: [PaletteAction] { PaletteAction.matching(actions, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search projects, commands, agents, or pages", text: $query).textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { activateSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
            }.padding(20)
            Divider()
            List(selection: $selection) {
                ForEach(filtered) { action in
                    Button { activate(action) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.symbol).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title).font(.headline)
                                Text(action.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).tag(action.id)
                }
            }.overlay { if filtered.isEmpty { Text("No matching actions").foregroundStyle(.secondary) } }
            Divider()
            Text("↑ ↓ to select · Return to open or run · Esc to close · ⌃⌥Space from any app")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .onAppear { searching = true; selection = filtered.first?.id }
        .onChange(of: query) { _, _ in selection = filtered.first?.id }
    }
    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : 0)
        selection = filtered[(index + delta + filtered.count) % filtered.count].id
    }
    private func activateSelected() {
        if let action = filtered.first(where: { $0.id == selection }) ?? filtered.first { activate(action) }
    }
    func activate(_ action: PaletteAction) {
        UtilityWindow.shared.close()
        switch action.destination {
        case .tab(let tab): store.navigate(to: tab)
        case .project(let id):
            store.projects.selectedID = id; store.projects.section = .overview
            ProjectWorkspaceWindow.shared.show(store: store)
        case .command(let projectID, let commandID):
            guard let project = store.projects.projects.first(where: { $0.id == projectID }),
                  let command = project.commands.first(where: { $0.id == commandID }) else { return }
            store.projects.selectedID = projectID; store.projects.section = .commands
            store.projects.runner.run(project: project, command: command)
            ProjectWorkspaceWindow.shared.show(store: store)
        case .agent(let id):
            guard store.agents.sessions.contains(where: { $0.id == id }) else { return }
            store.agents.selectedSessionID = id
            store.navigate(to: .agents)
        case .setup: UtilityWindow.shared.show(store: store, page: .setup)
        case .health: UtilityWindow.shared.show(store: store, page: .health)
        }
    }
}

struct SetupView: View {
    @ObservedObject var store: Store
    @AppStorage("setupStep") private var step = 0
    @AppStorage("setupComplete") private var complete = false
    @State private var verificationSince: Date?
    @State private var detected: Set<Provider> = []
    private let titles = ["Choose your tools", "Connect your agents", "Make Houston yours"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HoustonPageHeader(title: titles[min(2, max(0, step))], subtitle: "Step \(min(2, max(0, step)) + 1) of 3 · Every step is optional.")
            ProgressView(value: Double(min(2, max(0, step)) + 1), total: 3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0:
                        Text("Choose the providers you use. Detection only finds installed apps or tools; Check verifies access to usage.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(Provider.allCases) { provider in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(provider.rawValue + (detected.contains(provider) ? " · Found on this Mac" : ""),
                                       isOn: Binding(get: { store.enabled.contains(provider) }, set: { store.setEnabled(provider, $0) }))
                                Text(store.reading(for: provider).status).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Connect / manage…") { openProvider(provider) }
                                    Button("Check") { store.refresh(provider, allowInteraction: true) }
                                        .disabled(!store.enabled.contains(provider) || store.reading(for: provider).isLoading)
                                }.controlSize(.small)
                                if let error = store.errors[provider] { Text(error).font(.caption).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).houstonCard()
                        }
                    case 1:
                        Text("Keep Houston.app in its permanent location before connecting. Install hooks, review them in your agent, then submit a prompt to verify real event delivery.")
                            .font(.callout).foregroundStyle(.secondary)
                        agentConnections
                        Button("Start event verification") { verificationSince = .now; store.agents.refresh(notify: false) }
                        if let since = verificationSince {
                            let confirmed = Set(store.agents.sessions.filter { $0.updatedAt >= since }.map(\.provider))
                            ForEach(AgentProvider.allCases) { provider in
                                Label(confirmed.contains(provider) ? "\(provider.name): event received" : "\(provider.name): waiting for a new event",
                                      systemImage: confirmed.contains(provider) ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(confirmed.contains(provider) ? Color.green : .secondary).font(.callout)
                            }
                            Text("Submit a prompt in each connected agent. Waiting does not mean a connection has failed; hooks must be trusted and loaded first.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    default:
                        AppPreferencesView(services: store.appServices)
                        Text("Open the command palette with ⌃⌥Space. Search a project, jump to a session, or run a saved command.")
                        Button("Add your first project…") {
                            UtilityWindow.shared.close(); store.navigate(to: .projects)
                        }
                        Button("Review connection health…") { UtilityWindow.shared.show(store: store, page: .health) }
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Button("Later") { complete = true; UtilityWindow.shared.close() }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step < 2 ? "Continue" : "Finish setup") {
                    if step < 2 { step += 1 }
                    else { complete = true; UtilityWindow.shared.close() }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24)
            .onAppear { step = min(2, max(0, step)); detected = Self.detectTools(); store.agents.refreshConfiguration() }
    }
    private var agentConnections: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(AgentProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.name).font(.headline)
                        Spacer()
                        Button(store.agents.configured.contains(provider) ? "Update hooks" : "Connect") { store.agents.setup(provider: provider) }
                    }
                    Text(store.agents.configurationIssues[provider] ?? "Hooks saved. Review them in your agent before testing.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).houstonCard()
            }
            if let message = store.agents.setupMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
    }
    private func openProvider(_ provider: Provider) {
        UtilityWindow.shared.close(); store.navigate(to: .tools, provider: provider)
    }
    static func detectTools() -> Set<Provider> {
        let commands: [(Provider, String)] = [(.codex, "codex"), (.claude, "claude"), (.copilot, "gh"), (.gemini, "gemini")]
        let apps: [(Provider, String)] = [(.codex, "com.openai.codex"), (.cursor, "com.todesktop.230313mzl4w4u92"), (.windsurf, "com.exafunction.windsurf")]
        return Set(commands.compactMap { LocalCommand.executable($0.1) == nil ? nil : $0.0 } +
                   apps.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) == nil ? nil : $0.0 })
    }
}

struct ConnectionHealthView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HoustonPageHeader(title: "Connection health", subtitle: "Last successful readings, setup checks, and targeted repairs.")
            Button("Refresh checks") {
                store.refresh(); store.agents.refreshConfiguration(); store.agents.refresh(notify: false)
                store.refreshOverview()
                store.projects.refreshConnections()
            }.disabled(store.projects.checkingConnections)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Provider.allCases.filter { store.enabled.contains($0) }) { provider in
                        let reading = store.reading(for: provider, at: context.date)
                        VStack(alignment: .leading, spacing: 8) {
                            Label(provider.rawValue + " · " + reading.status, systemImage: reading.needsAttention ? "exclamationmark.circle" : "link")
                                .font(.headline)
                            if let date = store.snapshots[provider]?.capturedAt {
                                Text("Last reading: " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(store.errors[provider] ?? provider.setup).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Check connection") { store.refresh(provider, allowInteraction: true) }.disabled(reading.isLoading)
                                Button("Reconnect / manage…") { UtilityWindow.shared.close(); store.navigate(to: .tools, provider: provider) }
                            }.controlSize(.small)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).houstonCard()
                    }
                }
            }
            HoustonSectionHeading(title: "Agent hooks")
            ForEach(AgentProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    Text(provider.name).font(.headline)
                    Text(store.agents.configurationIssues[provider] ?? "All required hooks point to this Houston installation.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let session = store.agents.sessions.first(where: { $0.provider == provider }) {
                        Text("Last event: " + session.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    } else { Text("No event received yet. Submit a prompt after reviewing the hooks.").font(.caption) }
                    Button("Connect / repair hooks") { store.agents.setup(provider: provider) }.controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).houstonCard()
            }
            if let message = store.agents.setupMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let error = store.agents.error { Text(error).foregroundStyle(.orange) }
            HoustonSectionHeading(title: "GitHub")
            Text(store.overviewError ?? (store.overview == nil ? "Not checked. Refresh checks to verify GitHub CLI access." : "GitHub overview received."))
                .font(.callout).foregroundStyle(.secondary)
            Button("Open GitHub settings") { UtilityWindow.shared.close(); store.navigate(to: .activity) }
            HoustonSectionHeading(title: "Project connections")
            ForEach(store.projects.projects) { project in
                VStack(alignment: .leading, spacing: 10) {
                    Text(project.name).font(.headline)
                    ForEach(CloudProvider.allCases) { provider in
                        let state = store.projects.cloud.snapshot(for: project).states[provider]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(provider.title + ": " + cloudMessage(provider, project: project, state: state))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Check " + provider.title + " connection") {
                                Task {
                                    await store.projects.cloud.verifySaved(provider: provider)
                                    await store.projects.cloud.refresh(provider: provider, project: project)
                                }
                            }.controlSize(.small).disabled(store.projects.cloud.verifying.contains(provider) || state?.isLoading == true)
                        }
                    }
                    Button("Manage connections and project mapping…") {
                        store.projects.selectedID = project.id; store.projects.section = .connections
                        UtilityWindow.shared.close(); ProjectWorkspaceWindow.shared.show(store: store)
                    }.controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).houstonCard()
            }
            Button("Return to guided setup") { UtilityWindow.shared.show(store: store, page: .setup) }
        }.onAppear { store.agents.refreshConfiguration() }
    }

    private func cloudMessage(_ provider: CloudProvider, project: HoustonProject, state: CloudLoadState?) -> String {
        if let error = state?.message { return error }
        if store.projects.cloud.connectionErrors.contains(provider), let error = store.projects.cloud.connectionMessages[provider] { return error }
        if let missing = store.projects.cloud.configurationMessage(for: provider, project: project) { return missing }
        if let date = state?.updatedAt { return "Last checked " + date.formatted(date: .abbreviated, time: .shortened) }
        return store.projects.cloud.connectionMessages[provider] ?? "Not checked"
    }
}
