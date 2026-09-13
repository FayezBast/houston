import Foundation
import Security

/// Optional direct connection: reads usage with Claude Code's own sign-in so the island works without a terminal status line.
/// The access token is read from macOS Keychain (with the user's permission), used for one usage request, and never stored by Houston.
public enum ClaudeAccount {
    public static let keychainService = "Claude Code-credentials"
    public static let usageAddress = "https://api.anthropic.com/api/oauth/usage"
    public static var fallbackFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json") }
    public static var configFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    /// The signed-in Claude.ai email from Claude Code's local config, if present. No secrets are read.
    public static func accountEmail() -> String? {
        guard let data = try? Data(contentsOf: configFile), let root = try? DeveloperTools.object(data),
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    public static func accessToken(now: Date = .now) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        var data = status == errSecSuccess ? result as? Data : nil
        if status == errSecUserCanceled || status == errSecAuthFailed {
            throw UsageError.unavailable("macOS did not allow Houston to read Claude Code’s sign-in. Turn the direct connection on again and choose Allow.")
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

    public static func readUsage() async throws -> UsageSnapshot {
        let token = try accessToken()
        do {
            return try parseUsage(await DeveloperTools.request(usageAddress, token: token, headers: ["anthropic-beta": "oauth-2025-04-20"]))
        } catch UsageError.unavailable(let message) where message.hasPrefix("Your sign-in has expired") {
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
