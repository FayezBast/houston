import Foundation
import Security
import LocalAuthentication
import SQLite3

public enum LocalCommand {
    public static func executable(_ name: String) -> URL? {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func run(_ name: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Data {
        guard let executable = executable(name) else { throw UsageError.unavailable("Install \(name) and sign in, then refresh.") }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel(); if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsageError.unavailable(failureMessage(command: name, data: data)) }
        return data
    }

    static func failureMessage(command: String, data: Data) -> String {
        if command == "gh", let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = body["status"] as? String ?? (body["status"] as? Int).map(String.init)
            switch status {
            case "404": return "GitHub could not find this resource with the current sign-in. Check the repository name and private-repository access."
            case "401": return "Your GitHub sign-in has expired. Run gh auth login, then retry."
            case "403": return "GitHub denied this request. Check your account’s permissions or rate limit."
            default: break
            }
        }
        return "\(command) could not read this account. Check its sign-in and access, then retry."
    }
}

public enum SecretStore {
    public static func read(account: String) throws -> Data {
        guard let data = try readIfPresent(account: account) else {
            throw UsageError.unavailable("No saved sign-in found. Connect your account first.")
        }
        return data
    }

    /// Only a missing item returns nil; denied access must not silently choose a different account.
    public static func readIfPresent(account: String) throws -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.houston.credentials", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        query[kSecAttrAccount as String] = account
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw UsageError.unavailable("Keychain access is needed. Click Connect to allow it.")
        }
        return data
    }

    public static func save(_ secret: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.houston.credentials", kSecAttrAccount as String: account]
        let data = Data(secret.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw UsageError.unavailable("Could not save the key in macOS Keychain.") }
    }

    public static func remove(account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.houston.credentials", kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UsageError.unavailable("Could not remove the saved connection from macOS Keychain.")
        }
    }
}

public enum DeveloperTools {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.unavailable("The provider returned an unexpected response.")
        }
        return object
    }

    public static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        guard var text = value as? String else { return nil }
        // ISO8601DateFormatter accepts at most three fractional digits; some APIs send six.
        if let range = text.range(of: #"\.\d{4,}"#, options: .regularExpression) { text.replaceSubrange(range, with: String(text[range].prefix(4))) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: text) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        if let result = formatter.date(from: text) { return result }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }

    static func request(_ address: String, token: String, body: [String: String]? = nil, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Houston/0.2", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            switch code {
            case 401: throw UsageError.unavailable("Your sign-in has expired. Sign in to the provider again, then retry.")
            case 403: throw UsageError.unavailable("This account does not have access to usage. Check your plan or account permissions.")
            case 429: throw UsageError.unavailable("The provider is limiting usage checks. Houston will wait before trying again.")
            default: throw UsageError.unavailable("Usage is temporarily unavailable (HTTP \(code)).")
            }
        }
        return data
    }

    public static func readCopilot() throws -> UsageSnapshot {
        var environment = ProcessInfo.processInfo.environment
        var token = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"]
        if token == nil {
            let savedToken = try? LocalCommand.run("gh", ["auth", "token", "--hostname", "github.com"])
            token = savedToken.flatMap { String(data: $0, encoding: .utf8) }
        }
        token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pin the request to the exact token being attributed, even if gh's active account changes.
        if let token, !token.isEmpty { environment["GH_TOKEN"] = token }
        let data = try LocalCommand.run("gh", ["api", "--hostname", "github.com", "copilot_internal/user",
            "-H", "Accept: application/json", "-H", "Editor-Version: vscode/1.96.2",
            "-H", "Editor-Plugin-Version: copilot-chat/0.26.7"], environment: environment)
        return try parseCopilot(data).scoped(to: token.flatMap { $0.isEmpty ? nil : UsageAccountIdentity.scope(provider: "copilot", identity: $0) })
    }

    public static func parseCopilot(_ data: Data) throws -> UsageSnapshot {
        let root = try object(data)
        let quotas = root["quota_snapshots"] as? [String: Any] ?? root["quotaSnapshots"] as? [String: Any] ?? [:]
        let reset = date(root["quota_reset_date"] ?? root["quotaResetDate"])
        let windows = [("premium_interactions", "Premium"), ("chat", "Chat"), ("completions", "Completions")].compactMap { key, name -> UsageWindow? in
            let alternate = key == "premium_interactions" ? "premiumInteractions" : key
            guard let value = (quotas[key] ?? quotas[alternate]) as? [String: Any], value["unlimited"] as? Bool != true,
                  let remaining = (value["percent_remaining"] ?? value["percentRemaining"]) as? Double else { return nil }
            // GitHub returns zero-entitlement placeholders for allowances not included in a plan.
            if let entitlement = value["entitlement"] as? Double, entitlement <= 0 { return nil }
            return UsageWindow(name: name, used: 100 - remaining, resetsAt: reset)
        }
        if windows.isEmpty {
            guard quotas.values.contains(where: { ($0 as? [String: Any])?["unlimited"] as? Bool == true }) else {
                throw UsageError.unavailable("Copilot did not return a metered allowance for this account.")
            }
            return UsageSnapshot(windows: [], detail: "Unlimited allowance")
        }
        return UsageSnapshot(windows: windows)
    }

    public static func readGemini() async throws -> UsageSnapshot {
        try await GeminiAccount.readUsage()
    }

    public static func parseGemini(_ data: Data) throws -> UsageSnapshot {
        let root = try object(data)
        let buckets = root["buckets"] as? [[String: Any]] ?? []
        var byModel: [String: UsageWindow] = [:]
        for bucket in buckets {
            guard let model = bucket["modelId"] as? String, let fraction = bucket["remainingFraction"] as? Double, fraction.isFinite else { continue }
            let window = UsageWindow(name: model, used: 100 * (1 - fraction), resetsAt: date(bucket["resetTime"]))
            if window.remaining < (byModel[model]?.remaining ?? 101) { byModel[model] = window }
        }
        guard !byModel.isEmpty else { throw UsageError.unavailable("No Gemini quota returned. Your account may need a Code Assist subscription.") }
        return UsageSnapshot(windows: byModel.values.sorted { $0.name < $1.name })
    }

    public static func readWindsurf() throws -> UsageSnapshot {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: file.path) else { throw UsageError.unavailable("Open Windsurf and sign in to create its local usage cache.") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw UsageError.unavailable("Windsurf’s local usage cache is unavailable.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key='windsurf.settings.cachedPlanInfo' LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
            throw UsageError.unavailable("Windsurf has not cached usage yet. Open its account screen, then refresh.")
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
            if let text = String(data: data, encoding: encoding), let result = try? parseWindsurf(Data(text.utf8)) { return result }
        }
        throw UsageError.unavailable("Windsurf’s cached usage format is not supported yet.")
    }

    public static func parseWindsurf(_ data: Data) throws -> UsageSnapshot {
        let root = try object(data), quota = root["quotaUsage"] as? [String: Any] ?? [:]
        var windows = [("daily", "Daily"), ("weekly", "Weekly")].compactMap { key, name -> UsageWindow? in
            guard let remaining = quota[key + "RemainingPercent"] as? Double else { return nil }
            return UsageWindow(name: name, used: 100 - remaining, resetsAt: date(quota[key + "ResetAtUnix"]))
        }
        if windows.isEmpty, let usage = root["usage"] as? [String: Any] {
            for (totalKey, usedKey, remainingKey, name) in [("messages", "usedMessages", "remainingMessages", "Messages"), ("flowActions", "usedFlowActions", "remainingFlowActions", "Flow actions")] {
                guard let total = usage[totalKey] as? Double, total > 0 else { continue }
                let used = usage[usedKey] as? Double ?? (usage[remainingKey] as? Double).map { total - $0 }
                if let used { windows.append(UsageWindow(name: name, used: used / total * 100, resetsAt: nil)) }
            }
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("No metered usage in Windsurf’s local cache.") }
        return UsageSnapshot(windows: windows, detail: "Cached by Windsurf · may be out of date")
    }

    public static func readOpenRouter() async throws -> UsageSnapshot {
        let data = try SecretStore.read(account: "openrouter")
        return try await UsageAccountReader.read(provider: .openrouter, credential: data)
    }

    public static func parseOpenRouter(_ data: Data) throws -> UsageSnapshot {
        let root = try object(data)
        guard let value = root["data"] as? [String: Any], let usage = value["usage"] as? Double, usage.isFinite, usage >= 0 else {
            throw UsageError.unavailable("OpenRouter did not return key usage.")
        }
        guard value["limit"] is NSNull || value["limit"] is Double else {
            throw UsageError.unavailable("OpenRouter did not return a valid key budget.")
        }
        if let limit = value["limit"] as? Double {
            guard limit.isFinite, limit >= 0 else { throw UsageError.unavailable("OpenRouter returned an invalid key budget.") }
            if limit == 0 { return UsageSnapshot(windows: [], detail: "$0.00 key budget · no allowance", spend: UsageSpend(used: usage, budget: 0)) }
            guard let remaining = value["limit_remaining"] as? Double, remaining.isFinite else {
                throw UsageError.unavailable("OpenRouter did not return the remaining key budget.")
            }
            return UsageSnapshot(windows: [UsageWindow(name: "Key budget", used: 100 * (1 - remaining / limit), resetsAt: nil)],
                detail: String(format: "$%.2f left of $%.2f key budget", remaining, limit), spend: UsageSpend(used: usage, budget: limit))
        }
        return UsageSnapshot(windows: [], detail: String(format: "$%.2f used · no key budget set", usage), spend: UsageSpend(used: usage))
    }
}

public struct GitHubActivity: Sendable {
    public struct Item: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let state: String
        public let detail: String
        public let url: URL
        public init(id: String, title: String, state: String, detail: String = "", url: URL) {
            self.id = id; self.title = title; self.state = state; self.detail = detail; self.url = url
        }
    }
    public let pullRequests: [Item]
    public let runs: [Item]
}

/// Zero-configuration view of the signed-in GitHub account: your open pull requests, review requests, unread notifications and recent repositories.
public struct GitHubOverview: Sendable {
    public let login: String
    public let authored: [GitHubActivity.Item]
    public let reviewRequests: [GitHubActivity.Item]
    public let notifications: [GitHubActivity.Item]
    public let repositories: [String]
    public let note: String?
}

public enum GitHubReader {
    public static func validRepository(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    /// Accepts pasted GitHub links and clone addresses as well as `owner/repository`.
    public static func normalizeRepository(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "https://www.github.com/", "git@github.com:", "github.com/", "www.github.com/"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if let query = value.firstIndex(where: { $0 == "?" || $0 == "#" }) { value = String(value[..<query]) }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return value }
        var repository = parts[1]
        if repository.lowercased().hasSuffix(".git") { repository = String(repository.dropLast(4)) }
        return parts[0] + "/" + repository
    }

    /// A repository from the account's own list that matches a mistyped name, such as `tamayaz/coachxo` for `Tamayaz-io/coachxo`.
    public static func suggestion(for repository: String, among repositories: [String]) -> String? {
        guard !repositories.contains(repository) else { return nil }
        let wanted = repository.lowercased()
        if let exact = repositories.first(where: { $0.lowercased() == wanted }) { return exact }
        guard let name = wanted.split(separator: "/").last else { return nil }
        let sameName = repositories.filter { $0.lowercased().split(separator: "/").last == name }
        return sameName.count == 1 ? sameName[0] : nil
    }

    public static func read(repository: String) throws -> GitHubActivity {
        guard validRepository(repository) else { throw UsageError.unavailable("Enter a repository as owner/repository.") }
        let pulls = try LocalCommand.run("gh", ["api", "--hostname", "github.com", "repos/\(repository)/pulls?state=open&per_page=5"])
        let runs = try LocalCommand.run("gh", ["api", "--hostname", "github.com", "repos/\(repository)/actions/runs?per_page=5"])
        return try parse(pulls: pulls, runs: runs)
    }

    public static func readOverview() throws -> GitHubOverview {
        let user = try DeveloperTools.object(LocalCommand.run("gh", ["api", "--hostname", "github.com", "user"]))
        guard let login = user["login"] as? String else { throw UsageError.unavailable("GitHub CLI is not signed in. Run gh auth login, then retry.") }
        var note: String?
        func fetch(_ path: String) -> Data {
            do { return try LocalCommand.run("gh", ["api", "--hostname", "github.com", path]) }
            catch { if note == nil { note = error.localizedDescription }; return Data("[]".utf8) }
        }
        let authored = fetch("search/issues?q=is:pr+is:open+archived:false+author:@me&sort=updated&per_page=5")
        let reviews = fetch("search/issues?q=is:pr+is:open+archived:false+review-requested:@me&sort=updated&per_page=5")
        let notifications = fetch("notifications?per_page=8")
        let repositories = fetch("user/repos?sort=pushed&per_page=8&affiliation=owner,collaborator,organization_member")
        return try parseOverview(login: login, authored: authored, reviews: reviews, notifications: notifications, repositories: repositories, note: note)
    }

    public static func parseOverview(login: String, authored: Data, reviews: Data, notifications: Data, repositories: Data, note: String? = nil, now: Date = .now) throws -> GitHubOverview {
        func searchItems(_ data: Data) -> [GitHubActivity.Item] {
            let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return (root["items"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["id"] as? Int, let url = link(value["html_url"]) else { return nil }
                let repository = (value["repository_url"] as? String).map { $0.split(separator: "/").suffix(2).joined(separator: "/") } ?? ""
                let number = (value["number"] as? Int).map { "#\($0)" } ?? ""
                let state = value["draft"] as? Bool == true ? "Draft" : "Open"
                return GitHubActivity.Item(id: "search-\(id)", title: value["title"] as? String ?? "Pull request", state: state,
                                           detail: [repository, number, age(DeveloperTools.date(value["updated_at"]), now: now)].filter { !$0.isEmpty }.joined(separator: " · "), url: url)
            }
        }
        let inbox = ((try? JSONSerialization.jsonObject(with: notifications) as? [[String: Any]]) ?? []).compactMap { value -> GitHubActivity.Item? in
            guard let id = value["id"] as? String, let subject = value["subject"] as? [String: Any], let repository = value["repository"] as? [String: Any],
                  let url = notificationLink(subject: subject, repository: repository) else { return nil }
            let reason = (value["reason"] as? String ?? "activity").replacingOccurrences(of: "_", with: " ").capitalized
            return GitHubActivity.Item(id: "notification-\(id)", title: subject["title"] as? String ?? "Notification", state: reason,
                                       detail: [repository["full_name"] as? String ?? "", age(DeveloperTools.date(value["updated_at"]), now: now)].filter { !$0.isEmpty }.joined(separator: " · "), url: url)
        }
        let names = ((try? JSONSerialization.jsonObject(with: repositories) as? [[String: Any]]) ?? []).compactMap { $0["full_name"] as? String }
        return GitHubOverview(login: login, authored: searchItems(authored), reviewRequests: searchItems(reviews), notifications: inbox, repositories: names, note: note)
    }

    public static func parse(pulls: Data, runs: Data, now: Date = .now) throws -> GitHubActivity {
        let requests = try JSONSerialization.jsonObject(with: pulls) as? [[String: Any]] ?? []
        let workflows = try DeveloperTools.object(runs)["workflow_runs"] as? [[String: Any]] ?? []
        func item(_ value: [String: Any], pull: Bool) -> GitHubActivity.Item? {
            guard let id = value["id"] as? Int, let url = link(value["html_url"]) else { return nil }
            let title = (pull ? value["title"] : value["display_title"] ?? value["name"]) as? String ?? "GitHub activity"
            let state = pull ? (value["draft"] as? Bool == true ? "Draft" : "Open") : (value["conclusion"] as? String ?? value["status"] as? String ?? "Unknown")
            let detail: String
            if pull {
                detail = [(value["number"] as? Int).map { "#\($0)" } ?? "", age(DeveloperTools.date(value["updated_at"]), now: now)].filter { !$0.isEmpty }.joined(separator: " · ")
            } else {
                detail = [value["name"] as? String ?? "", value["head_branch"] as? String ?? "", age(DeveloperTools.date(value["updated_at"] ?? value["created_at"]), now: now)].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            let attempt = pull ? "" : (value["run_attempt"] as? Int).map { "-attempt-\($0)" } ?? ""
            return GitHubActivity.Item(id: (pull ? "pull-" : "run-") + String(id) + attempt, title: title, state: state, detail: detail, url: url)
        }
        return GitHubActivity(pullRequests: requests.compactMap { item($0, pull: true) }, runs: workflows.compactMap { item($0, pull: false) })
    }

    static func link(_ value: Any?) -> URL? {
        guard let address = value as? String, let url = URL(string: address), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    /// Notifications carry API addresses; map them to the matching page on github.com.
    static func notificationLink(subject: [String: Any], repository: [String: Any]) -> URL? {
        let home = link(repository["html_url"])
        guard let api = subject["url"] as? String, let address = URL(string: api), address.host == "api.github.com" else { return home }
        var path = address.path
        guard path.hasPrefix("/repos/") else { return home }
        path = String(path.dropFirst("/repos".count))
        path = path.replacingOccurrences(of: "/pulls/", with: "/pull/").replacingOccurrences(of: "/commits/", with: "/commit/")
        if path.contains("/releases/"), let home { return home.appendingPathComponent("releases") }
        return link("https://github.com" + path) ?? home
    }

    public static func age(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 1440 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1440)d ago"
    }
}
