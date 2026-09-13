import Foundation

public struct GitHubSignal: Sendable, Equatable {
    public let id: String
    public let state: String
    public let title: String
    public let detail: String
    public let url: URL

    public init(id: String, state: String, title: String, detail: String, url: URL) {
        self.id = id; self.state = state; self.title = title; self.detail = detail; self.url = url
    }

    public var alertTitle: String? {
        switch state {
        case "FAILURE", "ERROR", "failure", "timed_out", "action_required": "Build failed"
        case "SUCCESS", "success": "Checks passed"
        case "CHANGES_REQUESTED": "Changes requested"
        case "APPROVED": "Pull request approved"
        default: nil
        }
    }
}

public struct GitHubSignalSnapshot: Sendable {
    public let login: String
    public let signals: [GitHubSignal]
}

public enum GitHubSignalReader {
    // One bounded query reads review decisions and checks on the user's open PRs.
    public static func read() throws -> GitHubSignalSnapshot {
        let query = """
        query { viewer { login } search(query: "is:pr is:open archived:false author:@me sort:updated-desc", type: ISSUE, first: 30) {
          nodes { ... on PullRequest { id title url number reviewDecision repository { nameWithOwner }
            commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
          } }
        } }
        """
        return try parse(LocalCommand.run("gh", ["api", "--hostname", "github.com", "graphql", "-f", "query=" + query]))
    }

    public static func parse(_ data: Data) throws -> GitHubSignalSnapshot {
        let root = try DeveloperTools.object(data)
        guard root["errors"] == nil, let payload = root["data"] as? [String: Any],
              let viewer = payload["viewer"] as? [String: Any], let login = viewer["login"] as? String,
              let search = payload["search"] as? [String: Any], let nodes = search["nodes"] as? [[String: Any]] else {
            throw UsageError.unavailable("GitHub could not read pull request checks and reviews. Check your sign-in and repository access.")
        }
        let signals = nodes.flatMap { node -> [GitHubSignal] in
            guard let id = node["id"] as? String, let url = GitHubReader.link(node["url"]) else { return [] }
            let title = node["title"] as? String ?? "Pull request"
            let repository = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            let number = (node["number"] as? Int).map { " #\($0)" } ?? ""
            let commits = (node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]
            let commit = commits?.last?["commit"] as? [String: Any]
            let checks = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String ?? "UNKNOWN"
            return [("review", node["reviewDecision"] as? String ?? "UNKNOWN"), ("checks", checks)].map { kind, state in
                let revision = kind == "checks" ? (commit?["oid"] as? String).map { "-" + $0 } ?? "" : ""
                return GitHubSignal(id: "\(id)-\(kind)" + revision, state: state, title: title, detail: repository + number, url: url)
            }
        }
        return GitHubSignalSnapshot(login: login, signals: signals)
    }

    public static func runs(_ activity: GitHubActivity) -> [GitHubSignal] {
        activity.runs.map { GitHubSignal(id: $0.id, state: $0.state, title: $0.title, detail: $0.detail, url: $0.url) }
    }
}

/// The first successful poll establishes a silent baseline. Failures never clear it.
public struct GitHubAlertTracker: Sendable {
    private var states: [String: [String: String]] = [:]
    public init() {}

    public mutating func observe(_ signals: [GitHubSignal], scope: String) -> [GitHubSignal] {
        let previous = states[scope]
        var next = previous ?? [:]
        var alerts: [GitHubSignal] = []
        for signal in signals {
            if previous != nil, previous?[signal.id] != signal.state, signal.alertTitle != nil { alerts.append(signal) }
            // Missing permissions or incomplete rollups cannot erase a known terminal state.
            if signal.state != "UNKNOWN" { next[signal.id] = signal.state }
        }
        // Scope keys are repository/account-specific. Retain only currently observed entries once bounded.
        if next.count > 300 { next = next.filter { key, _ in signals.contains { $0.id == key } } }
        states[scope] = next
        return alerts
    }
}
