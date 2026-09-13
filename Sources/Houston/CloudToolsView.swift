import SwiftUI
import HoustonCore

struct CloudToolsView: View {
    @ObservedObject var store: CloudStore
    let project: HoustonProject
    let section: CloudSection
    var onEditing: (Bool) -> Void = { _ in }
    var showsHeader = true
    @State private var showingConnections = false
    @State private var selectedDeployment: CloudDeployment?

    private var snapshot: CloudSnapshot { store.snapshot(for: project) }
    private var state: CloudLoadState { snapshot.states[section.provider] ?? CloudLoadState() }
    private var count: Int {
        switch section {
        case .deployments: snapshot.deployments.count
        case .errors: snapshot.errors.count
        case .work: snapshot.work.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader { HoustonPageHeader(title: section.title, subtitle: subtitle) }
            HStack {
                Label(section.provider.title, systemImage: section.symbol).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showingConnections = true } label: { Image(systemName: "key.horizontal") }
                    .help("Cloud connections").accessibilityLabel("Cloud connections")
                Button { Task { await store.refresh(provider: section.provider, project: project) } } label: {
                    Image(systemName: "arrow.clockwise")
                }.disabled(state.isLoading)
                    .help("Refresh \(section.title.lowercased())").accessibilityLabel("Refresh \(section.title.lowercased())")
            }.buttonStyle(.borderless).foregroundStyle(.secondary)
            if state.isLoading && state.updatedAt == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(section.provider.title)…").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18).houstonCard()
            } else if let message = store.configurationMessage(for: section.provider, project: project) {
                emptyCard(title: "Link this project", message: message, symbol: "link")
            } else if !state.isConnected && state.updatedAt == nil {
                emptyCard(title: "Connect \(section.provider.title)", message: state.message ?? "Add your personal token in Cloud connections to see \(section.title.lowercased()) here.", symbol: "key.horizontal")
                Button("Cloud connections") { showingConnections = true }.buttonStyle(.borderedProminent)
            } else if count == 0 && state.message == nil {
                emptyCard(title: emptyTitle, message: emptyMessage, symbol: section == .errors ? "checkmark.seal" : section.symbol)
            }
            if let message = state.message, state.isConnected || state.updatedAt != nil {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).houstonCard()
            }
            if count > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HoustonSectionHeading(title: section == .deployments ? "Latest deployments" : section == .errors ? "Unresolved · last 14 days" : "Assigned to you", count: count)
                    if section == .deployments {
                        ForEach(snapshot.deployments) { deployment in deploymentRow(deployment) }
                    } else {
                        ForEach(section == .errors ? snapshot.errors : snapshot.work) { issue in issueRow(issue) }
                    }
                }
            }
            if let updatedAt = state.updatedAt {
                HStack(spacing: 6) {
                    if state.isLoading { ProgressView().controlSize(.mini) }
                    Text(state.message == nil ? "Updated \(updatedAt.formatted(date: .omitted, time: .shortened))" : "Showing last successful check · \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: showingConnections) { _, value in
            onEditing(value || selectedDeployment != nil)
            if !value { Task { await store.refresh(provider: section.provider, project: project) } }
        }
        .onChange(of: selectedDeployment != nil) { _, value in onEditing(value || showingConnections) }
        .onDisappear { onEditing(false) }
        .sheet(isPresented: $showingConnections) {
            CloudConnectionsSheet(store: store)
        }
        .sheet(item: $selectedDeployment) { deployment in
            CloudDeploymentLogs(store: store, project: project, deployment: deployment)
        }
    }

    private var subtitle: String {
        switch section {
        case .deployments: "Build status and previews for \(project.name)."
        case .errors: "Unresolved issues in \(project.sentryEnvironment.isEmpty ? "all environments" : project.sentryEnvironment)."
        case .work: project.linearProjectID.isEmpty ? "Your open Linear work across projects." : "Your open Linear work for \(project.name)."
        }
    }
    private var emptyTitle: String { section == .deployments ? "No deployments yet" : section == .errors ? "No unresolved issues" : "Your queue is clear" }
    private var emptyMessage: String {
        switch section {
        case .deployments: "New deployments for this project will appear after a refresh."
        case .errors: "Sentry returned no unresolved issues for these filters in the last 14 days."
        case .work: "Linear returned no open issues assigned to you for this project selection."
        }
    }

    private func emptyCard(title: String, message: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).houstonCard()
    }

    private func deploymentRow(_ deployment: CloudDeployment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deployment.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(deployment.branch.isEmpty ? deployment.target.capitalized : "\(deployment.branch) · \(deployment.target)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                statusPill(deployment.state.capitalized, color: deployment.state == "READY" ? .green : ["ERROR", "BLOCKED"].contains(deployment.state) ? .red : .orange)
            }
            HStack(spacing: 12) {
                if let url = deployment.url { Link("Open preview", destination: url) }
                if let url = deployment.inspectorURL { Link("Details", destination: url) }
                Button("Build logs") { selectedDeployment = deployment }
                Spacer(minLength: 0)
            }.font(.system(size: 11, weight: .medium)).buttonStyle(.borderless)
            if let createdAt = deployment.createdAt {
                Text(createdAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.padding(14).houstonCard()
    }

    private func issueRow(_ issue: CloudIssue) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(issue.identifier.isEmpty ? section.provider.title : issue.identifier)
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                statusPill(issue.priority.capitalized, color: ["urgent", "high", "fatal"].contains(issue.priority.lowercased()) ? .orange : .secondary)
            }
            if let url = issue.url {
                Link(destination: url) { Text(issue.title).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).lineLimit(3)
            } else { Text(issue.title).font(.system(size: 13, weight: .semibold)).lineLimit(3) }
            HStack(spacing: 10) {
                Text(issue.state.capitalized)
                if let events = issue.eventCount { Text("\(events.formatted()) events") }
                if let users = issue.userCount { Text("\(users.formatted()) users") }
                Spacer(minLength: 0)
                if issue.url != nil { Image(systemName: "arrow.up.right").accessibilityHidden(true) }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).houstonCard()
    }

    private func statusPill(_ title: String, color: Color) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
            .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct CloudConnectionsView: View {
    @ObservedObject var store: CloudStore
    var onEditing: (Bool) -> Void = { _ in }
    var showsHeader = true
    @FocusState private var focusedProvider: CloudProvider?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader { HoustonPageHeader(title: "Cloud connections", subtitle: "Personal tokens stay in this Mac’s Keychain. Project settings choose what appears in Houston.") }
            ForEach(CloudProvider.allCases) { provider in
                CloudConnectionRow(store: store, provider: provider, focus: $focusedProvider)
            }
        }.task { await store.loadConnections() }
            .onChange(of: focusedProvider) { _, provider in onEditing(provider != nil || !store.verifying.isEmpty) }
            .onChange(of: store.verifying) { _, providers in onEditing(focusedProvider != nil || !providers.isEmpty) }
            .onDisappear { onEditing(false) }
    }
}

private struct CloudConnectionRow: View {
    @ObservedObject var store: CloudStore
    let provider: CloudProvider
    var focus: FocusState<CloudProvider?>.Binding
    @State private var token = ""
    private var busy: Bool { store.verifying.contains(provider) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                else if store.connected.contains(provider) {
                    Label("Token saved", systemImage: "key.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text(instructions).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(provider == .linear ? "Personal API key" : "Access token", text: $token)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .focused(focus, equals: provider)
                .accessibilityLabel("\(provider.title) access token")
                .disabled(busy)
            HStack(spacing: 12) {
                Button("Save & verify") {
                    Task { if await store.saveAndVerify(token, provider: provider) { token = "" } }
                }.buttonStyle(.borderedProminent).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Button("Check") { Task { await store.verifySaved(provider: provider) } }.disabled(busy)
                if store.connected.contains(provider) {
                    Button("Remove", role: .destructive) { Task { await store.clearConnection(provider) } }.disabled(busy)
                }
            }.controlSize(.small).font(.system(size: 11))
            if let message = store.connectionMessages[provider] {
                Text(message).font(.system(size: 11))
                    .foregroundStyle(store.connectionErrors.contains(provider) ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Create a \(provider.title) token ↗", destination: tokenURL).font(.system(size: 11))
        }.padding(16).houstonCard()
    }
    private var instructions: String {
        switch provider {
        case .vercel: "Use an access token for the account or team that owns your project."
        case .sentry: "Use a personal auth token with event:read permission. Houston reads issue summaries."
        case .linear: "Use a personal API key with read access to the teams you want to follow."
        }
    }
    private var tokenURL: URL {
        switch provider {
        case .vercel: URL(string: "https://vercel.com/account/settings/tokens")!
        case .sentry: URL(string: "https://sentry.io/settings/account/api/auth-tokens/")!
        case .linear: URL(string: "https://linear.app/settings/account/security")!
        }
    }
}

private struct CloudConnectionsSheet: View {
    @ObservedObject var store: CloudStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            ScrollView { CloudConnectionsView(store: store).padding(20) }
        }.frame(width: 440, height: 650)
    }
}

private struct CloudDeploymentLogs: View {
    @ObservedObject var store: CloudStore
    let project: HoustonProject
    let deployment: CloudDeployment
    @Environment(\.dismiss) private var dismiss
    private var key: String { store.logKey(deploymentID: deployment.id, projectID: project.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Build logs").font(.headline)
                    Text("\(deployment.name) · latest 200 events").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if store.loadingLogs.contains(key) { ProgressView().controlSize(.small) }
            if let message = store.logErrors[key] {
                Text(message + (store.logs[key] == nil ? "" : " Showing the last fetched output."))
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(store.logs[key].flatMap { $0.isEmpty ? "No build output returned for this deployment." : $0 } ?? (store.logErrors[key] == nil ? "Loading build output…" : "Build output is unavailable. Try refreshing or open Vercel."))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Refresh logs") { Task { await store.loadLogs(deployment: deployment, project: project) } }.disabled(store.loadingLogs.contains(key))
                Spacer()
                if let url = deployment.inspectorURL { Link("Open in Vercel ↗", destination: url) }
            }.font(.caption)
        }.padding(20).frame(width: 620, height: 460)
            .task { await store.loadLogs(deployment: deployment, project: project) }
    }
}
