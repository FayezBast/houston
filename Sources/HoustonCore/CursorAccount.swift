import Foundation
import SQLite3

/// Reads Cursor's account-wide dashboard allowance with a user-selected web session or Cursor.app sign-in.
public enum CursorAccount {
    public static let usageAddress = "https://cursor.com/api/usage-summary"
    public static let sessionCookieNames: Set<String> = ["WorkosCursorSessionToken", "__Secure-next-auth.session-token",
        "next-auth.session-token", "wos-session", "__Secure-wos-session", "authjs.session-token", "__Secure-authjs.session-token"]
    public static var databaseFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Keep only authentication cookies that a browser would send to the Cursor usage endpoint.
    public static func cookieHeader(from cookies: [HTTPCookie], now: Date = .now) throws -> String {
        let selected = cookies.filter {
            $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == "cursor.com"
                && ["/", "/api", "/api/"].contains($0.path)
                && ($0.expiresDate.map { $0 > now } ?? true) && isSessionCookie($0.name)
        }
        let grouped = Dictionary(grouping: selected, by: \.name)
        guard grouped.values.allSatisfy({ Set($0.map(\.value)).count == 1 }) else {
            throw UsageError.unavailable("This profile contains conflicting Cursor sessions. Sign in below to choose an account.")
        }
        return try validateCookieHeader(grouped.keys.sorted().map { "\($0)=\(grouped[$0]![0].value)" }.joined(separator: "; "))
    }

    static func isSessionCookie(_ name: String) -> Bool {
        if sessionCookieNames.contains(name) { return true }
        guard let dot = name.lastIndex(of: "."), sessionCookieNames.contains(String(name[..<dot])) else { return false }
        let suffix = name[name.index(after: dot)...]
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func validateCookieHeader(_ header: String) throws -> String {
        guard header.utf8.count <= 65_536, !header.isEmpty,
              header.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else {
            throw UsageError.unavailable("No valid Cursor session found. Connect Cursor and sign in again.")
        }
        let pairs = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !pairs.isEmpty, pairs.allSatisfy({ pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 && isSessionCookie(String(parts[0])) && !parts[1].isEmpty
                && !parts[1].contains(" ") && !parts[1].contains(",") && !parts[1].contains("\"")
        }) else { throw UsageError.unavailable("No valid Cursor session found. Connect Cursor and sign in again.") }
        return pairs.joined(separator: "; ")
    }

    public static func localCookieHeader(from file: URL = databaseFile, now: Date = .now) throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw UsageError.unavailable("Connect Cursor here, or open Cursor and sign in, then refresh.")
        }
        var database: OpaquePointer?
        let hasWAL = FileManager.default.fileExists(atPath: file.path + "-wal") || FileManager.default.fileExists(atPath: file.path + "-shm")
        // An idle WAL-mode database must not create sidecars in Cursor's directory.
        let filename = hasWAL ? file.path : file.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(filename, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw UsageError.unavailable("Cursor’s local sign-in is unavailable. Connect Cursor here instead.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0),
              (1...65_536).contains(Int(sqlite3_column_bytes(statement, 0))) else {
            throw UsageError.unavailable("Cursor has no local sign-in. Open Cursor and sign in, or connect here.")
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        let encoding: String.Encoding = data.contains(0) ? .utf16LittleEndian : .utf8
        guard let token = String(data: data, encoding: encoding) else {
            throw UsageError.unavailable("Cursor’s local sign-in could not be read. Sign in to Cursor again.")
        }
        return try cookieHeader(accessToken: token, now: now)
    }

    static func cookieHeader(accessToken: String, now: Date = .now) throws -> String {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }) else {
            throw UsageError.unavailable("Cursor’s local sign-in is invalid. Sign in to Cursor again.")
        }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let root = try? DeveloperTools.object(data),
              let subject = root["sub"] as? String, let user = subject.split(separator: "|").last,
              user.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let expiry = number(root["exp"]), expiry > now.timeIntervalSince1970 + 60 else {
            throw UsageError.unavailable("Cursor’s local sign-in is expired or invalid. Open Cursor to renew it, or connect here.")
        }
        // Cursor's first-party dashboard accepts this representation of its existing app token.
        return try validateCookieHeader("WorkosCursorSessionToken=\(user)%3A%3A\(accessToken)")
    }

    public static func readUsage(cookieHeader: String? = nil, session: URLSession? = nil, allowInteraction: Bool = false) async throws -> UsageSnapshot {
        let cookie: String
        if let cookieHeader {
            cookie = try validateCookieHeader(cookieHeader)
        } else if let saved = try SecretStore.readIfPresent(account: "cursor", allowInteraction: allowInteraction) {
            guard let header = String(data: saved, encoding: .utf8) else {
                throw UsageError.unavailable("The saved Cursor session is invalid. Connect Cursor again.")
            }
            cookie = try validateCookieHeader(header)
        } else {
            cookie = try localCookieHeader()
        }
        let client = session ?? URLSession(configuration: .ephemeral, delegate: CursorNoRedirects(), delegateQueue: nil)
        defer { if session == nil { client.invalidateAndCancel() } }
        let summary = try await fetch(URL(string: usageAddress)!, cookie: cookie, session: client)
        var legacy: Data?
        // Old request-based plans expose their quota separately; optional endpoints never hide a valid current allowance.
        if let identityData = try? await fetch(URL(string: "https://cursor.com/api/auth/me")!, cookie: cookie, session: client, timeout: 5),
           let identity = try? DeveloperTools.object(identityData), let user = identity["sub"] as? String, !user.isEmpty {
            let address = URL(string: "https://cursor.com/api/usage")!.appending(queryItems: [URLQueryItem(name: "user", value: user)])
            legacy = try? await fetch(address, cookie: cookie, session: client, timeout: 5)
        }
        return try parseUsage(summary, legacy: legacy)
            .scoped(to: UsageAccountIdentity.scope(provider: "cursor", identity: cookie))
    }

    static func fetch(_ address: URL, cookie: String, session: URLSession, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Houston/0.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 301...308, 401, 403: throw UsageError.unavailable("Cursor rejected this sign-in. Connect Cursor again, or sign in to Cursor and refresh.")
        case 429: throw UsageError.unavailable("Cursor is limiting usage checks. Wait a few minutes before refreshing.")
        default: throw UsageError.unavailable("Cursor usage is temporarily unavailable (HTTP \(status)).")
        }
    }

    public static func parseUsage(_ data: Data, legacy: Data? = nil, capturedAt: Date = .now) throws -> UsageSnapshot {
        guard let root = try? DeveloperTools.object(data) else {
            throw UsageError.unavailable("Cursor returned an unexpected usage response. Reconnect and try again.")
        }
        let reset = (root["billingCycleEnd"] as? String).flatMap { DeveloperTools.date($0) }
        if let legacy, let counts = (try? DeveloperTools.object(legacy))?["gpt-4"] as? [String: Any],
           let used = number(counts["numRequestsTotal"] ?? counts["numRequests"]),
           let limit = number(counts["maxRequestUsage"]), limit > 0, (used / limit * 100).isFinite {
            return UsageSnapshot(windows: [UsageWindow(name: "Requests", used: used / limit * 100, resetsAt: reset)],
                capturedAt: capturedAt, detail: String(format: "%.0f of %.0f requests used", used, limit))
        }
        let individual = root["individualUsage"] as? [String: Any] ?? [:]
        let team = root["teamUsage"] as? [String: Any] ?? [:]
        let plan = individual["plan"] as? [String: Any] ?? [:]
        var windows: [UsageWindow] = []
        if plan["enabled"] as? Bool != false {
            if let total = number(plan["totalPercentUsed"]) ?? percentage(plan) {
                windows.append(UsageWindow(name: "Included plan", used: total, resetsAt: reset))
            }
            // These are percentage units, including values below 1%; never multiply them by 100.
            for (key, label) in [("autoPercentUsed", "Cursor models"), ("apiPercentUsed", "Third-party models")] {
                if let used = number(plan[key]) { windows.append(UsageWindow(name: label, used: used, resetsAt: reset)) }
            }
        }
        if windows.isEmpty, let overall = individual["overall"] as? [String: Any], let used = percentage(overall) {
            windows.append(UsageWindow(name: "Personal allowance", used: used, resetsAt: reset))
        }
        if windows.isEmpty, let pooled = team["pooled"] as? [String: Any], let used = percentage(pooled) {
            windows.append(UsageWindow(name: "Shared team allowance", used: used, resetsAt: reset))
        }
        var details: [String] = []
        for (source, label) in [(individual, "Extra usage"), (team, "Team extra usage")] {
            guard let extra = source["onDemand"] as? [String: Any], extra["enabled"] as? Bool == true else { continue }
            if let used = percentage(extra) { windows.append(UsageWindow(name: label, used: used, resetsAt: reset)) }
            if let spent = number(extra["used"]) { details.append(String(format: "%@: $%.2f spent", label, spent / 100)) }
        }
        if windows.isEmpty {
            guard root["isUnlimited"] as? Bool == true else {
                throw UsageError.unavailable("Cursor returned no metered allowance. Check the account’s usage dashboard.")
            }
            details.insert("Unlimited allowance", at: 0)
        }
        return UsageSnapshot(windows: windows, capturedAt: capturedAt, detail: details.isEmpty ? nil : details.joined(separator: " · "))
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
        return value.doubleValue
    }

    static func percentage(_ quota: [String: Any]) -> Double? {
        guard quota["enabled"] as? Bool != false, let limit = number(quota["limit"]), limit > 0 else { return nil }
        let used = number(quota["used"]) ?? number(quota["remaining"]).map { max(0, limit - $0) }
        guard let used, (used / limit * 100).isFinite else { return nil }
        return used / limit * 100
    }
}

private final class CursorNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
