import Foundation

/// A user-selected Claude web session and organization, independent of Claude Code's sign-in.
public enum ClaudeWebAccount {
    public struct Organization: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
    }

    public static func cookieHeader(from cookies: [HTTPCookie], now: Date = .now) throws -> String {
        let values = Set(cookies.filter {
            $0.name == "sessionKey" && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == "claude.ai"
                && ["/", "/api", "/api/", "/api/organizations"].contains($0.path)
                && ($0.expiresDate.map { $0 > now } ?? true)
        }.map(\.value))
        guard values.count == 1, let value = values.first else {
            throw UsageError.unavailable("No unambiguous Claude session found. Sign in to Claude, then choose Use this account.")
        }
        return try validateCookie("sessionKey=\(value)")
    }

    public static func organizations(cookieHeader: String, session: URLSession? = nil) async throws -> [Organization] {
        let data = try await fetch(path: "organizations", cookie: validateCookie(cookieHeader), session: session)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UsageError.unavailable("Claude returned an unexpected organization list. Try connecting again.")
        }
        var seen = Set<String>()
        let result = rows.compactMap { row -> Organization? in
            guard let rawID = row["uuid"] as? String, let id = UUID(uuidString: rawID)?.uuidString.lowercased() else { return nil }
            let capabilities = Set((row["capabilities"] as? [String] ?? []).map { $0.lowercased() })
            guard capabilities.isEmpty || capabilities.contains("chat"), seen.insert(id).inserted else { return nil }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Organization(id: id, name: name?.isEmpty == false ? name! : "Organization \(id.prefix(8))")
        }
        guard !result.isEmpty else { throw UsageError.unavailable("This Claude account has no chat organization with usage to connect.") }
        return result
    }

    public static func credential(cookieHeader: String, organizationID: String) throws -> String {
        let saved = try Credential(cookieHeader: validateCookie(cookieHeader), organizationID: validateOrganization(organizationID))
        return String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
    }

    /// A saved UUID stays pinned. A failed request never selects another organization or sign-in.
    public static func readUsage(credential: Data? = nil, session: URLSession? = nil) async throws -> UsageSnapshot {
        let data = try credential ?? SecretStore.read(account: "claude-web")
        guard let saved = try? JSONDecoder().decode(Credential.self, from: data) else {
            throw UsageError.unavailable("The saved Claude web connection is invalid. Connect Claude again.")
        }
        return try await readUsage(cookieHeader: saved.cookieHeader, organizationID: saved.organizationID, session: session)
    }

    public static func readUsage(cookieHeader: String, organizationID: String, session: URLSession? = nil) async throws -> UsageSnapshot {
        let id = try validateOrganization(organizationID)
        let data = try await fetch(path: "organizations/\(id)/usage", cookie: validateCookie(cookieHeader), session: session)
        let usage = try ClaudeAccount.parseUsage(data)
        return UsageSnapshot(windows: usage.windows, capturedAt: usage.capturedAt, detail: "Connected to Claude web",
            accountID: UsageAccountIdentity.scope(provider: "claude-web", identity: id + ":" + cookieHeader))
    }

    private struct Credential: Codable { let cookieHeader: String; let organizationID: String }

    private static func validateCookie(_ header: String) throws -> String {
        let prefix = "sessionKey="
        guard header.hasPrefix(prefix + "sk-ant-"), header.utf8.count > prefix.utf8.count + 7, header.utf8.count <= 32_768,
              header.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E && ![0x22, 0x2C, 0x3B, 0x5C].contains($0.value) }) else {
            throw UsageError.unavailable("The Claude session is invalid. Connect Claude and sign in again.")
        }
        return header
    }

    private static func validateOrganization(_ value: String) throws -> String {
        guard let id = UUID(uuidString: value) else { throw UsageError.unavailable("The Claude organization is invalid. Connect Claude again.") }
        return id.uuidString.lowercased()
    }

    private static func fetch(path: String, cookie: String, session: URLSession?) async throws -> Data {
        let address = URL(string: "https://claude.ai/api/\(path)")!
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let client = session ?? URLSession(configuration: .ephemeral)
        defer { if session == nil { client.invalidateAndCancel() } }
        let (data, response) = try await client.data(for: request, delegate: ClaudeWebNoRedirects())
        guard let http = response as? HTTPURLResponse else { throw UsageError.unavailable("Claude returned an unexpected response.") }
        if http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" {
            throw UsageError.unavailable("Claude’s web service requires a browser security check on this network. Open Claude in the connection window or try another network.")
        }
        switch http.statusCode {
        case 200: return data
        case 301...308, 401: throw UsageError.unavailable("Claude’s web sign-in has expired. Connect Claude again.")
        case 403: throw UsageError.unavailable("Claude denied this web session or organization. Check access in Claude, then reconnect.")
        case 404: throw UsageError.unavailable("The selected Claude organization is no longer available. Connect Claude and choose an organization again.")
        case 429: throw UsageError.unavailable("Claude is limiting usage checks. Wait a few minutes before refreshing.")
        default: throw UsageError.unavailable("Claude web usage is temporarily unavailable (HTTP \(http.statusCode)).")
        }
    }
}

final class ClaudeWebNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
