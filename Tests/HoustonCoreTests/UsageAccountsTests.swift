import XCTest
@testable import HoustonCore

final class UsageAccountsTests: XCTestCase {
    func testHistoryScopesHideCredentialsAndCopyAllSnapshotFields() {
        let first = UsageAccountIdentity.scope(provider: "Claude", identity: "private-token-one")
        XCTAssertEqual(first, UsageAccountIdentity.scope(provider: "claude", identity: "private-token-one"))
        XCTAssertFalse(first.contains("private-token"))
        XCTAssertNotEqual(first, UsageAccountIdentity.scope(provider: "claude", identity: "private-token-two"))
        XCTAssertNotEqual(first, UsageAccountIdentity.scope(provider: "cursor", identity: "private-token-one"))
        let original = UsageSnapshot(windows: [UsageWindow(name: "Key budget", used: 20, resetsAt: nil)],
            capturedAt: Date(timeIntervalSince1970: 1000), detail: "Details", spend: UsageSpend(used: 3, budget: 15))
        let scoped = original.scoped(to: first)
        XCTAssertEqual(scoped.accountID, first)
        XCTAssertEqual(scoped.windows, original.windows)
        XCTAssertEqual(scoped.capturedAt, original.capturedAt)
        XCTAssertEqual(scoped.detail, original.detail)
        XCTAssertEqual(scoped.spend, original.spend)
        XCTAssertNil(original.accountID)
    }

    func testCodexHistoryRequiresMatchingLoginAndWorkspaceMetadata() throws {
        func auth(workspace: String = "workspace-one", subject: String = "user-one", email: String = "user@example.test",
                  tokenWorkspace: String = "workspace-one") throws -> Data {
            let claims: [String: Any] = ["sub": subject, "email": email, "https://api.openai.com/auth": ["chatgpt_account_id": tokenWorkspace]]
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": workspace, "id_token": "header.\(payload).signature"]])
        }
        let account = Data(#"{"result":{"account":{"type":"chatgpt","email":"user@example.test","planType":"team"}}}"#.utf8)
        let first = UsageAccountIdentity.codex(authentication: try auth(), accountResponse: account)
        XCTAssertNotNil(first)
        XCTAssertFalse(first!.contains("user@example.test"))
        XCTAssertNotEqual(first, UsageAccountIdentity.codex(authentication: try auth(workspace: "workspace-two", tokenWorkspace: "workspace-two"), accountResponse: account))
        XCTAssertNotEqual(first, UsageAccountIdentity.codex(authentication: try auth(subject: "user-two"), accountResponse: account))
        XCTAssertNil(UsageAccountIdentity.codex(authentication: try auth(email: "other@example.test"), accountResponse: account))
        XCTAssertNil(UsageAccountIdentity.codex(authentication: try auth(tokenWorkspace: "different-workspace"), accountResponse: account))
        XCTAssertNil(UsageAccountIdentity.codex(authentication: nil, accountResponse: account))
        XCTAssertNil(UsageAccountIdentity.codex(authentication: Data(#"{"tokens":{"id_token":"not-a-jwt"}}"#.utf8), accountResponse: account))
        XCTAssertNil(UsageAccountIdentity.codex(authentication: try auth(), accountResponse: Data(#"{"result":{"account":{"type":"apiKey"}}}"#.utf8)))
        XCTAssertNil(UsageAccountIdentity.codex(authentication: try auth(), accountResponse: Data(#"{"result":{"account":{"type":"chatgpt","email":null}}}"#.utf8)))
    }

    func testCredentialAddressesStayIsolatedAcrossLabelsAndProviders() throws {
        let id = UUID()
        var work = try UsageAccount(id: id, provider: .claude, label: " Work ")
        let personal = try UsageAccount(provider: .claude, label: "Personal")
        let cursor = try UsageAccount(id: id, provider: .cursor, label: "Work")
        let original = work.keychainAccount
        work.label = "Renamed"
        XCTAssertEqual(work.keychainAccount, original)
        XCTAssertNotEqual(work.keychainAccount, personal.keychainAccount)
        XCTAssertNotEqual(work.keychainAccount, cursor.keychainAccount)
        XCTAssertFalse(["claude-web", "cursor", "openrouter"].contains(work.keychainAccount))
        XCTAssertThrowsError(try UsageAccount(provider: .claude, label: "\n"))
        XCTAssertThrowsError(try UsageAccount(provider: .claude, label: "name\u{0}hidden"))
        XCTAssertThrowsError(try UsageAccount(provider: .claude, label: String(repeating: "a", count: 61)))
    }

    func testCatalogRejectsAmbiguousIDsAndCrossProviderSelections() throws {
        let account = try UsageAccount(provider: .claude, label: "Work")
        XCTAssertThrowsError(try UsageAccountCatalog(accounts: [account, account]).validated())
        XCTAssertThrowsError(try UsageAccountCatalog(accounts: [account], selected: ["Cursor": account.id]).validated())
        XCTAssertThrowsError(try UsageAccountCatalog(accounts: [account], selected: ["Claude": UUID()]).validated())
        let catalog = try UsageAccountCatalog(accounts: [account], selected: ["Claude": account.id]).validated()
        let data = try JSONEncoder().encode(catalog)
        let restored = try JSONDecoder().decode(UsageAccountCatalog.self, from: data).validated()
        XCTAssertEqual(restored.accounts, [account])
        XCTAssertEqual(restored.selected["Claude"], account.id)
    }
}
