import Foundation

/// Reads Code Assist quota with the existing Gemini CLI Google sign-in.
public enum GeminiAccount {
    public static var credentialsFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json") }
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private static let tokenCache = TokenCache()
    private static let endpoint = "https://cloudcode-pa.googleapis.com/v1internal:"
    private static let migrationMessage = "Google no longer serves this Gemini CLI consumer sign-in. Use Antigravity for consumer plans; Gemini Code Assist Standard and Enterprise remain supported."

    public static func readUsage(credentialsFile: URL = credentialsFile,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 now: Date = .now,
                                 load: @escaping Loader = { try await URLSession.shared.data(for: $0) }) async throws -> UsageSnapshot {
        let settingsFile = credentialsFile.deletingLastPathComponent().appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsFile), let settings = try? DeveloperTools.object(data),
           let security = settings["security"] as? [String: Any], let auth = security["auth"] as? [String: Any],
           let type = string(auth["selectedType"]), type != "oauth-personal" {
            throw UsageError.unavailable("This Gemini meter reads Code Assist Google sign-in quota. API-key and Vertex AI billing are available in Google’s usage dashboard.")
        }
        guard let data = try? Data(contentsOf: credentialsFile) else {
            throw UsageError.unavailable("No Gemini Code Assist sign-in found. This meter needs an eligible Gemini CLI Google sign-in; consumer/free, AI Pro and Ultra CLI OAuth ended in June 2026. Gemini web chat usage is separate.")
        }
        let credentials = try DeveloperTools.object(data)
        let cached = await tokenCache.get(source: data, now: now)
        var token = cached ?? string(credentials["access_token"])
        let expiry = (credentials["expiry_date"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        var refreshed = false
        if token == nil || (cached == nil && expiry.map { $0 <= now.addingTimeInterval(60) } == true) {
            token = try await refresh(credentials, source: data, environment: environment, now: now, load: load)
            refreshed = true
        }
        guard var token else { throw UsageError.unavailable("Gemini CLI has no Google sign-in. Open Gemini CLI and sign in again.") }
        let identity = string(credentials["refresh_token"]) ?? token
        do {
            do { return try await quota(token: token, identity: identity, environment: environment, load: load) }
            catch HTTPFailure.status(401) where !refreshed {
                token = try await refresh(credentials, source: data, environment: environment, now: now, load: load)
                return try await quota(token: token, identity: identity, environment: environment, load: load)
            }
        } catch let failure as HTTPFailure { throw failure.usageError }
    }

    private static func quota(token: String, identity: String, environment: [String: String], load: Loader) async throws -> UsageSnapshot {
        let configured = string(environment["GOOGLE_CLOUD_PROJECT"]) ?? string(environment["GOOGLE_CLOUD_PROJECT_ID"])
        var body: [String: Any] = ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]]
        if let configured { body["cloudaicompanionProject"] = configured }
        let account = try DeveloperTools.object(await post(endpoint + "loadCodeAssist", token: token, body: body, load: load))
        let currentTier = account["currentTier"] as? [String: Any]
        let paidTier = account["paidTier"] as? [String: Any]
        if currentTier == nil, paidTier == nil,
           (account["ineligibleTiers"] as? [[String: Any]] ?? []).contains(where: { $0["reasonCode"] as? String == "UNSUPPORTED_CLIENT" }) {
            throw UsageError.unavailable(migrationMessage)
        }
        let projectObject = account["cloudaicompanionProject"] as? [String: Any]
        guard let project = string(account["cloudaicompanionProject"]) ?? string(projectObject?["id"]) ?? string(projectObject?["projectId"]) ?? configured else {
            throw UsageError.unavailable("Gemini returned no quota project. Finish Google sign-in in Gemini CLI; organization accounts may also require GOOGLE_CLOUD_PROJECT.")
        }
        let snapshot = try DeveloperTools.parseGemini(await post(endpoint + "retrieveUserQuota", token: token, body: ["project": project], load: load))
        return UsageSnapshot(windows: snapshot.windows, capturedAt: snapshot.capturedAt,
                             detail: string(paidTier?["name"]) ?? string(currentTier?["name"]),
                             accountID: UsageAccountIdentity.scope(provider: "gemini", identity: identity + ":" + project))
    }

    private static func refresh(_ credentials: [String: Any], source: Data, environment: [String: String], now: Date, load: Loader) async throws -> String {
        guard let refreshToken = string(credentials["refresh_token"]) else {
            throw UsageError.unavailable("Gemini’s sign-in has expired and cannot be refreshed. Open Gemini CLI and sign in again.")
        }
        guard let client = oauthClient(environment: environment) else {
            throw UsageError.unavailable("Gemini’s sign-in needs refreshing. Install or update Gemini CLI so Houston can use its OAuth client, or reopen Gemini CLI to refresh the sign-in.")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["client_id": client.id, "client_secret": client.secret, "refresh_token": refreshToken, "grant_type": "refresh_token"]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await load(request)
        let body = (try? DeveloperTools.object(data)) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = string(body["access_token"]), let seconds = body["expires_in"] as? Double, seconds.isFinite, seconds > 0 else {
            if body["error"] as? String == "invalid_grant" {
                throw UsageError.unavailable("Google rejected Gemini’s saved sign-in. Open Gemini CLI and sign in again.")
            }
            throw UsageError.unavailable("Google could not refresh Gemini’s sign-in. Update Gemini CLI and sign in again, then refresh.")
        }
        // Keep the refreshed access token in memory; never overwrite credentials a CLI session may update.
        await tokenCache.put(source: source, token: token, expires: now.addingTimeInterval(seconds))
        return token
    }

    private static func post(_ address: String, token: String, body: [String: Any], load: Loader) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await load(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPFailure.status(status) }
        return data
    }

    private enum HTTPFailure: Error {
        case status(Int)
        var usageError: UsageError {
            switch self {
            case .status(401): .unavailable("Google rejected Gemini’s sign-in after refreshing it. Sign in again in Gemini CLI.")
            case .status(403): .unavailable("This Google account cannot read Gemini Code Assist quota. Check its Code Assist plan and project permissions.")
            case .status(429): .unavailable("Google is limiting quota checks. Try again later.")
            case .status(let code): .unavailable("Gemini quota is temporarily unavailable (HTTP \(code)).")
            }
        }
    }

    struct OAuthClient: Equatable { let id: String; let secret: String }

    /// Use the installed public CLI client configuration; Houston embeds no borrowed OAuth secret.
    static func oauthClient(environment: [String: String]) -> OAuthClient? {
        if let id = string(environment["GEMINI_OAUTH_CLIENT_ID"]), let secret = string(environment["GEMINI_OAUTH_CLIENT_SECRET"]) {
            return OAuthClient(id: id, secret: secret)
        }
        if let path = string(environment["GEMINI_OAUTH2_JS_PATH"]), let source = try? String(contentsOfFile: path, encoding: .utf8),
           let client = parseOAuthClient(source) { return client }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var roots = ["/opt/homebrew/lib/node_modules/@google/gemini-cli", "/usr/local/lib/node_modules/@google/gemini-cli",
                     "/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli",
                     "/usr/local/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli", home + "/.npm-global/lib/node_modules/@google/gemini-cli"].map { URL(fileURLWithPath: $0) }
        for directory in directories {
            let executable = URL(fileURLWithPath: directory).appendingPathComponent("gemini")
            guard FileManager.default.fileExists(atPath: executable.path) else { continue }
            var current = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                if let data = try? Data(contentsOf: current.appendingPathComponent("package.json")),
                   let package = try? DeveloperTools.object(data), package["name"] as? String == "@google/gemini-cli" {
                    roots.insert(current, at: 0); break
                }
                current.deleteLastPathComponent()
            }
        }
        for root in roots {
            let relative = ["dist/src/code_assist/oauth2.js", "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
                            "../gemini-cli-core/dist/src/code_assist/oauth2.js", "bundle/gemini.js"]
            var files = relative.map { root.appendingPathComponent($0) }
            if let chunks = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("bundle"), includingPropertiesForKeys: nil) {
                files += chunks.filter { $0.pathExtension == "js" }.sorted { $0.path < $1.path }
            }
            for file in files {
                if let source = try? String(contentsOf: file, encoding: .utf8), let client = parseOAuthClient(source) { return client }
            }
        }
        return nil
    }

    static func parseOAuthClient(_ source: String) -> OAuthClient? {
        func constant(_ name: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: "\\b" + name + #"\s*=\s*['"]([^'"\r\n]+)['"]"#),
                  let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source) else { return nil }
            return string(String(source[range]))
        }
        guard let id = constant("OAUTH_CLIENT_ID"), let secret = constant("OAUTH_CLIENT_SECRET") else { return nil }
        return OAuthClient(id: id, secret: secret)
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private actor TokenCache {
        var source: Data?
        var token: String?
        var expires: Date = .distantPast
        func get(source: Data, now: Date) -> String? { self.source == source && expires > now.addingTimeInterval(60) ? token : nil }
        func put(source: Data, token: String, expires: Date) { self.source = source; self.token = token; self.expires = expires }
    }
}
