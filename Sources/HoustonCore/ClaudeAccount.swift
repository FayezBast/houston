import Foundation
import Security

/// Optional direct connection: reads usage with Claude Code's own sign-in so the island works without a terminal status line.
/// Authorized tokens stay in memory for up to 30 minutes; Houston never persists or refreshes Claude Code’s tokens.
public enum ClaudeAccount {
    public static let keychainService = "Claude Code-credentials"
    private static let credentials = KeychainCredentialStore(service: keychainService, cacheLifetime: 30 * 60)
    public static let usageAddress = "https://api.anthropic.com/api/oauth/usage"
    public static var fallbackFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json") }
    public static var configFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    /// The signed-in Claude.ai email from Claude Code's local config, if present. No secrets are read.
    public static func accountEmail() -> String? {
        guard let data = try? Data(contentsOf: configFile), let root = try? DeveloperTools.object(data),
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    public static func accessToken(now: Date = .now, allowInteraction: Bool = false) throws -> String {
        var data: Data?
        do {
            data = try credentials.readIfPresent(account: nil, allowInteraction: allowInteraction, now: now) {
                (try? parseToken($0, now: now)) != nil
            }
        } catch let error as KeychainReadError {
            if error.status == errSecUserCanceled || error.status == errSecAuthFailed { throw error }
            if FileManager.default.fileExists(atPath: fallbackFile.path) { data = try? Data(contentsOf: fallbackFile) }
            if data == nil { throw error }
        }
        if data == nil, FileManager.default.fileExists(atPath: fallbackFile.path) { data = try? Data(contentsOf: fallbackFile) }
        guard let data else { throw UsageError.unavailable("No Claude Code sign-in found. Run claude in a terminal and sign in, then retry.") }
        return try parseToken(data, now: now)
    }

    public static func parseToken(_ data: Data, now: Date = .now) throws -> String {
        let root = try DeveloperTools.object(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.unavailable("Claude Code is not signed in with a Claude.ai account. Subscription usage needs a Pro or Max sign-in.")
        }
        if let expires = oauth["expiresAt"] as? Double, Date(timeIntervalSince1970: expires / 1000) < now {
            throw UsageError.unavailable("Claude Code’s sign-in has expired. Send a message in claude to refresh it, then retry.")
        }
        return token
    }

    public static func readUsage(allowInteraction: Bool = false) async throws -> UsageSnapshot {
        if let saved = try SecretStore.readIfPresent(account: "claude-web", allowInteraction: allowInteraction) {
            return try await ClaudeWebAccount.readUsage(credential: saved)
        }
        let token = try accessToken(allowInteraction: allowInteraction)
        do {
            return try parseUsage(await DeveloperTools.request(usageAddress, token: token, headers: ["anthropic-beta": "oauth-2025-04-20"]))
                .scoped(to: UsageAccountIdentity.scope(provider: "claude-code", identity: token))
        } catch UsageError.unavailable(let message) where message.hasPrefix("Your sign-in has expired") {
            credentials.invalidate(account: nil)
            throw UsageError.unavailable("Claude rejected the saved sign-in. Send a message in claude to refresh it, then retry.")
        }
    }

    public static func parseUsage(_ data: Data, capturedAt: Date = .now) throws -> UsageSnapshot {
        let root = try DeveloperTools.object(data)
        let names = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly · Opus"),
                     ("seven_day_sonnet", "Weekly · Sonnet"), ("seven_day_oauth_apps", "Weekly · apps")]
        let windows = names.compactMap { key, name -> UsageWindow? in
            guard let value = root[key] as? [String: Any],
                  let used = (value["utilization"] ?? value["used_percentage"]) as? Double, used.isFinite else { return nil }
            return UsageWindow(name: name, used: used, resetsAt: DeveloperTools.date(value["resets_at"]))
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("Claude returned no subscription usage for this sign-in.") }
        return UsageSnapshot(windows: windows, capturedAt: capturedAt, detail: "Read directly with Claude Code’s sign-in")
    }
}
