import Foundation
import Combine
import HoustonCore

enum CloudSection: String, CaseIterable, Identifiable {
    case deployments, errors, work
    var id: String { rawValue }
    var provider: CloudProvider { self == .deployments ? .vercel : self == .errors ? .sentry : .linear }
    var title: String { self == .deployments ? "Deployments" : self == .errors ? "Production errors" : "Assigned work" }
    var symbol: String { self == .deployments ? "cloud" : self == .errors ? "exclamationmark.bubble" : "checklist" }
}

struct CloudLoadState {
    var isLoading = false
    var isConnected = false
    var message: String?
    var updatedAt: Date?
}

struct CloudSnapshot {
    var deployments: [CloudDeployment] = []
    var errors: [CloudIssue] = []
    var work: [CloudIssue] = []
    var states: [CloudProvider: CloudLoadState] = [:]
}

struct CloudTransition {
    let projectID: UUID
    let title: String
    let message: String
    let url: URL?
}

@MainActor final class CloudStore: ObservableObject {
    @Published private(set) var snapshots: [UUID: CloudSnapshot] = [:]
    @Published private(set) var connected: Set<CloudProvider> = []
    @Published private(set) var verifying: Set<CloudProvider> = []
    @Published private(set) var connectionMessages: [CloudProvider: String] = [:]
    @Published private(set) var connectionErrors: Set<CloudProvider> = []
    @Published private(set) var logs: [String: String] = [:]
    @Published private(set) var logErrors: [String: String] = [:]
    @Published private(set) var loadingLogs: Set<String> = []
    var onTransition: ((CloudTransition) -> Void)?

    private let api: CloudAPI
    private let readSecret: @Sendable (String, Bool) throws -> Data?
    private let saveSecret: @Sendable (String, String) throws -> Void
    private let removeSecret: @Sendable (String) throws -> Void
    private var revisions: [CloudProvider: Int] = [:]
    private var scopes: [String: String] = [:]
    private var inFlight: [String: UUID] = [:]
    private var logRequests: [String: UUID] = [:]
    private var seenSentryIssues: [UUID: Set<String>] = [:]
    private var retryAfter: [CloudProvider: Date] = [:]

    init(api: CloudAPI = CloudAPI(),
         readSecret: @escaping @Sendable (String, Bool) throws -> Data? = { try SecretStore.readIfPresent(account: $0, allowInteraction: $1) },
         saveSecret: @escaping @Sendable (String, String) throws -> Void = { try SecretStore.save($0, account: $1) },
         removeSecret: @escaping @Sendable (String) throws -> Void = { try SecretStore.remove(account: $0) }) {
        self.api = api
        self.readSecret = readSecret
        self.saveSecret = saveSecret
        self.removeSecret = removeSecret
    }

    func snapshot(for project: HoustonProject) -> CloudSnapshot {
        var snapshot = snapshots[project.id] ?? CloudSnapshot()
        for provider in CloudProvider.allCases where scopes["\(project.id):\(provider.rawValue)"] != configurationScope(provider, project: project) {
            snapshot.states[provider] = nil
            switch provider {
            case .vercel: snapshot.deployments = []
            case .sentry: snapshot.errors = []
            case .linear: snapshot.work = []
            }
        }
        return snapshot
    }

    func prepare(project: HoustonProject) {
        for provider in CloudProvider.allCases {
            let key = "\(project.id):\(provider.rawValue)"
            let scope = configurationScope(provider, project: project)
            guard scopes[key] != scope else { continue }
            reset(provider: provider, projectID: project.id)
            scopes[key] = scope
            inFlight[key] = nil
            if provider == .vercel {
                let prefix = "\(project.id):"
                logs = logs.filter { !$0.key.hasPrefix(prefix) }
                logErrors = logErrors.filter { !$0.key.hasPrefix(prefix) }
                logRequests = logRequests.filter { !$0.key.hasPrefix(prefix) }
                loadingLogs = loadingLogs.filter { !$0.hasPrefix(prefix) }
            }
        }
    }

    /// Root stops its polling tasks; late responses cannot repopulate suspended UI.
    func suspend() {
        for provider in CloudProvider.allCases { revisions[provider, default: 0] += 1 }
        inFlight.removeAll()
        logRequests.removeAll()
        loadingLogs.removeAll()
        for id in snapshots.keys {
            for provider in CloudProvider.allCases {
                snapshots[id]?.states[provider]?.isLoading = false
            }
        }
    }

    func configurationMessage(for provider: CloudProvider, project: HoustonProject) -> String? {
        if provider == .vercel, project.vercelProjectID.isEmpty { return "Add a Vercel project ID or name in Edit project." }
        if provider == .sentry, project.sentryOrganization.isEmpty || project.sentryProject.isEmpty {
            return "Add your Sentry organization and project slugs in Edit project."
        }
        return nil
    }

    func loadConnections() async {
        for provider in CloudProvider.allCases where !verifying.contains(provider) {
            let revision = revisions[provider, default: 0]
            do {
                let saved = try await token(for: provider)
                guard revisions[provider, default: 0] == revision else { continue }
                if saved != nil { connected.insert(provider) }
                else { connected.remove(provider) }
            } catch {
                guard revisions[provider, default: 0] == revision else { continue }
                connectionErrors.insert(provider)
                connectionMessages[provider] = error.localizedDescription
            }
        }
    }

    @discardableResult func saveAndVerify(_ token: String, provider: CloudProvider) async -> Bool {
        guard !verifying.contains(provider) else { return false }
        verifying.insert(provider)
        defer { verifying.remove(provider) }
        do {
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            try await api.verify(provider: provider, token: token)
            let save = saveSecret
            try await Task.detached { try save(token, provider.secretAccount) }.value
            invalidate(provider)
            connected.insert(provider)
            connectionErrors.remove(provider)
            connectionMessages[provider] = "Verified and saved in Keychain."
            return true
        } catch {
            connectionErrors.insert(provider)
            connectionMessages[provider] = error.localizedDescription
            return false
        }
    }

    func verifySaved(provider: CloudProvider) async {
        guard !verifying.contains(provider) else { return }
        verifying.insert(provider)
        defer { verifying.remove(provider) }
        do {
            guard let token = try await token(for: provider, allowInteraction: true) else {
                throw CloudAPIError.invalidConfiguration("No saved token. Add a \(provider.title) token below.")
            }
            try await api.verify(provider: provider, token: token)
            connected.insert(provider)
            connectionErrors.remove(provider)
            connectionMessages[provider] = "Connection verified."
        } catch {
            connectionErrors.insert(provider)
            connectionMessages[provider] = error.localizedDescription
        }
    }

    func clearConnection(_ provider: CloudProvider) async {
        guard !verifying.contains(provider) else { return }
        verifying.insert(provider)
        defer { verifying.remove(provider) }
        do {
            let remove = removeSecret
            try await Task.detached { try remove(provider.secretAccount) }.value
            invalidate(provider)
            connected.remove(provider)
            connectionErrors.remove(provider)
            connectionMessages[provider] = "Token removed from Keychain."
        } catch {
            connectionErrors.insert(provider)
            connectionMessages[provider] = error.localizedDescription
        }
    }

    private func invalidate(_ provider: CloudProvider) {
        revisions[provider, default: 0] += 1
        retryAfter[provider] = nil
        inFlight = inFlight.filter { !$0.key.hasSuffix(":\(provider.rawValue)") }
        for id in snapshots.keys { reset(provider: provider, projectID: id) }
        if provider == .vercel { logs = [:]; logErrors = [:]; logRequests = [:]; loadingLogs = [] }
    }

    private func reset(provider: CloudProvider, projectID: UUID) {
        var snapshot = snapshots[projectID] ?? CloudSnapshot()
        snapshot.states[provider] = nil
        switch provider {
        case .vercel: snapshot.deployments = []
        case .sentry: snapshot.errors = []; seenSentryIssues[projectID] = nil
        case .linear: snapshot.work = []
        }
        snapshots[projectID] = snapshot
    }

    private func token(for provider: CloudProvider, allowInteraction: Bool = false) async throws -> String? {
        let read = readSecret
        let data = try await Task.detached { try read(provider.secretAccount, allowInteraction) }.value
        return data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    // Root owns the polling cadence. Each source has independent failures and a quiet first baseline.
    func refresh(project: HoustonProject) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in CloudProvider.allCases {
                group.addTask { await self.refresh(provider: provider, project: project) }
            }
        }
    }

    func refresh(provider: CloudProvider, project: HoustonProject) async {
        guard !Task.isCancelled else { return }
        let key = "\(project.id):\(provider.rawValue)"
        let scope = configurationScope(provider, project: project)
        if scopes[key] != scope {
            reset(provider: provider, projectID: project.id)
            scopes[key] = scope
            inFlight[key] = nil
        }
        guard inFlight[key] == nil, !verifying.contains(provider) else { return }
        if let retry = retryAfter[provider], retry > .now { return }
        var state = snapshots[project.id]?.states[provider] ?? CloudLoadState()
        if let message = configurationMessage(for: provider, project: project) {
            state.message = message
            setState(state, provider: provider, projectID: project.id)
            return
        }
        let requestID = UUID(), revision = revisions[provider, default: 0]
        inFlight[key] = requestID
        state.isLoading = true
        state.message = nil
        setState(state, provider: provider, projectID: project.id)
        defer { if inFlight[key] == requestID { inFlight[key] = nil } }
        func isCurrent() -> Bool { inFlight[key] == requestID && revisions[provider, default: 0] == revision && scopes[key] == scope }
        do {
            guard let token = try await token(for: provider) else {
                guard isCurrent() else { return }
                connected.remove(provider)
                reset(provider: provider, projectID: project.id)
                setState(CloudLoadState(message: "Connect \(provider.title) in Cloud connections to begin."), provider: provider, projectID: project.id)
                return
            }
            try Task.checkCancellation()
            guard isCurrent() else { return }
            connected.insert(provider)
            var deployments: [CloudDeployment] = [], issues: [CloudIssue] = []
            switch provider {
            case .vercel:
                deployments = try await api.deployments(projectID: project.vercelProjectID, teamID: project.vercelTeamID, token: token)
            case .sentry:
                issues = try await api.sentryIssues(organization: project.sentryOrganization, project: project.sentryProject, environment: project.sentryEnvironment, token: token)
            case .linear:
                issues = try await api.assignedIssues(projectID: project.linearProjectID, token: token)
            }
            try Task.checkCancellation()
            guard isCurrent() else { return }
            var snapshot = snapshots[project.id] ?? CloudSnapshot()
            if let previousCheck = snapshot.states[provider]?.updatedAt {
                if provider == .vercel {
                    let previous = Dictionary(snapshot.deployments.map { ($0.id, $0.state) }, uniquingKeysWith: { _, latest in latest })
                    for deployment in deployments where deployment.isComplete && previous[deployment.id] != deployment.state {
                        // A fast build may finish between checks. Historical newly paged items stay quiet.
                        guard previous[deployment.id] != nil || deployment.createdAt.map({ $0 >= previousCheck }) == true else { continue }
                        onTransition?(CloudTransition(projectID: project.id, title: "\(project.name) deployment \(deployment.state.lowercased())",
                            message: [deployment.name, deployment.branch].filter { !$0.isEmpty }.joined(separator: " · "), url: deployment.inspectorURL ?? deployment.url))
                    }
                } else if provider == .sentry {
                    let previous = seenSentryIssues[project.id] ?? Set(snapshot.errors.map(\.id))
                    for issue in issues where !previous.contains(issue.id) && ["high", "fatal"].contains(issue.priority.lowercased()) {
                        onTransition?(CloudTransition(projectID: project.id, title: "\(project.name) needs attention", message: issue.title, url: issue.url))
                    }
                }
            }
            switch provider {
            case .vercel: snapshot.deployments = deployments
            case .sentry:
                snapshot.errors = issues
                seenSentryIssues[project.id, default: []].formUnion(issues.map(\.id))
            case .linear: snapshot.work = issues
            }
            snapshot.states[provider] = CloudLoadState(isConnected: true, updatedAt: .now)
            snapshots[project.id] = snapshot
        } catch {
            guard isCurrent() else { return }
            var state = snapshots[project.id]?.states[provider] ?? CloudLoadState()
            state.isLoading = false
            state.isConnected = connected.contains(provider)
            state.message = error is CancellationError ? "Refresh paused. Try again." : error.localizedDescription
            if error as? CloudAPIError == .rateLimited { retryAfter[provider] = .now.addingTimeInterval(120) }
            setState(state, provider: provider, projectID: project.id)
        }
    }

    func loadLogs(deployment: CloudDeployment, project: HoustonProject) async {
        guard !Task.isCancelled else { return }
        let key = logKey(deploymentID: deployment.id, projectID: project.id)
        guard !loadingLogs.contains(key) else { return }
        loadingLogs.insert(key)
        let requestID = UUID()
        logRequests[key] = requestID
        logErrors[key] = nil
        let revision = revisions[.vercel, default: 0], scope = configurationScope(.vercel, project: project)
        defer {
            if logRequests[key] == requestID { loadingLogs.remove(key); logRequests[key] = nil }
        }
        do {
            guard let token = try await token(for: .vercel) else { throw CloudAPIError.unauthorized }
            let value = try await api.deploymentLogs(id: deployment.id, teamID: project.vercelTeamID, token: token)
            try Task.checkCancellation()
            guard logRequests[key] == requestID, revision == revisions[.vercel, default: 0], scopes["\(project.id):vercel"] == scope else { return }
            logs[key] = value
        } catch {
            guard logRequests[key] == requestID, revision == revisions[.vercel, default: 0], scopes["\(project.id):vercel"] == scope else { return }
            logErrors[key] = error.localizedDescription
        }
    }

    func logKey(deploymentID: String, projectID: UUID) -> String { "\(projectID):\(deploymentID)" }

    private func setState(_ state: CloudLoadState, provider: CloudProvider, projectID: UUID) {
        var snapshot = snapshots[projectID] ?? CloudSnapshot()
        snapshot.states[provider] = state
        snapshots[projectID] = snapshot
    }

    private func configurationScope(_ provider: CloudProvider, project: HoustonProject) -> String {
        let fields: [String]
        switch provider {
        case .vercel: fields = [project.vercelProjectID, project.vercelTeamID]
        case .sentry: fields = [project.sentryOrganization, project.sentryProject, project.sentryEnvironment]
        case .linear: fields = [project.linearProjectID]
        }
        return fields.joined(separator: "\u{0}")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
