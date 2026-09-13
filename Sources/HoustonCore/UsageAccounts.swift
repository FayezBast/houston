import Foundation
import CryptoKit

/// History stores only an opaque digest. Rotation may start a new series but never combines sign-ins.
public enum UsageAccountIdentity {
    public static func scope(provider: String, identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(provider.lowercased()):\(digest)"
    }

    /// Match local managed-auth metadata to app-server's current login; never use email alone as workspace identity.
    public static func codex(authentication: Data?, accountResponse: Data?) -> String? {
        guard let authentication, let accountResponse,
              let auth = try? DeveloperTools.object(authentication),
              let tokens = auth["tokens"] as? [String: Any],
              let workspace = tokens["account_id"] as? String, !workspace.isEmpty,
              let idToken = tokens["id_token"] as? String,
              let response = try? DeveloperTools.object(accountResponse),
              let result = response["result"] as? [String: Any],
              let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt",
              let email = account["email"] as? String, !email.isEmpty else { return nil }
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        // Claims are used only for local attribution, never as proof of authorization.
        guard let data = Data(base64Encoded: payload), let claims = try? DeveloperTools.object(data),
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let tokenEmail = claims["email"] as? String, tokenEmail.lowercased() == email.lowercased() else { return nil }
        if let authorization = claims["https://api.openai.com/auth"] as? [String: Any],
           let tokenWorkspace = authorization["chatgpt_account_id"] as? String, tokenWorkspace != workspace { return nil }
        return scope(provider: "codex", identity: workspace + ":" + subject)
    }
}

public enum AccountProvider: String, Codable, CaseIterable, Sendable {
    case claude = "Claude", cursor = "Cursor", openrouter = "OpenRouter"
}

/// Labels are local to Houston. The UUID selects one Keychain item, never a provider's active login.
public struct UsageAccount: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let provider: AccountProvider
    public var label: String
    public var keychainAccount: String { "account.\(provider.rawValue.lowercased()).\(id.uuidString.lowercased())" }

    public init(id: UUID = UUID(), provider: AccountProvider, label: String) throws {
        self.id = id
        self.provider = provider
        self.label = try Self.validatedLabel(label)
    }

    public static func validatedLabel(_ value: String) throws -> String {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 60, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw UsageError.unavailable("Use an account label with 1–60 characters.")
        }
        return label
    }
}

public struct UsageAccountCatalog: Codable, Sendable {
    public var accounts: [UsageAccount]
    public var selected: [String: UUID]

    public init(accounts: [UsageAccount] = [], selected: [String: UUID] = [:]) {
        self.accounts = accounts
        self.selected = selected
    }

    public func validated() throws -> Self {
        guard Set(accounts.map(\.id)).count == accounts.count else {
            throw UsageError.unavailable("Houston’s saved accounts contain duplicate IDs. The account file was left unchanged.")
        }
        for account in accounts { _ = try UsageAccount.validatedLabel(account.label) }
        for (provider, id) in selected {
            guard accounts.contains(where: { $0.id == id && $0.provider.rawValue == provider }) else {
                throw UsageError.unavailable("Houston’s saved account selection is invalid. The account file was left unchanged.")
            }
        }
        return self
    }
}

public enum UsageAccountReader {
    public static func read(_ account: UsageAccount) async throws -> UsageSnapshot {
        try await read(provider: account.provider, credential: SecretStore.read(account: account.keychainAccount))
    }

    public static func read(provider: AccountProvider, credential: Data) async throws -> UsageSnapshot {
        switch provider {
        case .claude:
            return try await ClaudeWebAccount.readUsage(credential: credential)
        case .cursor:
            guard let cookie = String(data: credential, encoding: .utf8) else {
                throw UsageError.unavailable("This Cursor connection is invalid. Reconnect the account.")
            }
            return try await CursorAccount.readUsage(cookieHeader: cookie)
        case .openrouter:
            guard let key = String(data: credential, encoding: .utf8), !key.isEmpty,
                  key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
                throw UsageError.unavailable("Enter a valid OpenRouter API key.")
            }
            return try DeveloperTools.parseOpenRouter(await DeveloperTools.request("https://openrouter.ai/api/v1/key", token: key))
                .scoped(to: UsageAccountIdentity.scope(provider: "openrouter", identity: key))
        }
    }
}
