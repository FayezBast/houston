import XCTest
import HoustonCore
@testable import Houston

private actor AccountReads {
    private var pending: [Int: CheckedContinuation<UsageSnapshot, Error>] = [:]
    private(set) var accounts: [UsageAccount] = []
    private let started: [XCTestExpectation]
    init(_ started: [XCTestExpectation]) { self.started = started }
    func read(_ account: UsageAccount) async throws -> UsageSnapshot {
        let index = accounts.count
        accounts.append(account)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            started[index].fulfill()
        }
    }
    func finish(_ index: Int, used: Double? = nil) {
        if let used {
            pending.removeValue(forKey: index)?.resume(returning: UsageSnapshot(windows: [UsageWindow(name: "Weekly", used: used, resetsAt: nil)]))
        } else { pending.removeValue(forKey: index)?.resume(throwing: UsageError.unavailable("Account read failed")) }
    }
}

@MainActor private final class AccountSecrets {
    var values = ["claude-web": "legacy-claude", "cursor": "legacy-cursor", "openrouter": "legacy-key"]
    var rejectRemoval = false
    func save(_ value: String, account: String) { values[account] = value }
    func remove(_ account: String) throws {
        if rejectRemoval { throw UsageError.unavailable("Keychain unavailable") }
        values[account] = nil
    }
}

final class AccountStoreTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("houston-accounts-\(UUID())").appendingPathComponent("accounts.json")
    }
    private func snapshot(_ used: Double) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(name: "Weekly", used: used, resetsAt: nil)])
    }

    @MainActor func testAccountIsolationSelectionAndRenameSurviveReloadWithoutChangingLegacyCredentials() throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let secrets = AccountSecrets()
        let store = AccountStore(file: file, saveSecret: secrets.save, removeSecret: secrets.remove)
        let work = try store.add(provider: .claude, label: "Work", credential: "work-secret", snapshot: snapshot(90))
        let personal = try store.add(provider: .claude, label: "Personal", credential: "personal-secret", snapshot: snapshot(15))
        XCTAssertEqual(store.selectedAccount(for: .claude)?.id, personal.id)
        XCTAssertEqual(store.snapshots[work.id]?.windows.first?.used, 90)
        XCTAssertEqual(store.snapshots[personal.id]?.windows.first?.used, 15)
        store.select(work.id, for: .cursor)
        XCTAssertNil(store.selectedAccount(for: .cursor), "A provider can never select another provider’s credential")
        store.select(work.id, for: .claude)
        try store.rename(work.id, to: " Office ")
        let restored = AccountStore(file: file, saveSecret: secrets.save, removeSecret: secrets.remove)
        XCTAssertEqual(restored.selectedAccount(for: .claude)?.label, "Office")
        XCTAssertEqual(restored.accounts(for: .claude).map(\.id), [work.id, personal.id])
        XCTAssertEqual(secrets.values[work.keychainAccount], "work-secret")
        XCTAssertEqual(secrets.values[personal.keychainAccount], "personal-secret")
        let metadata = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(metadata.contains("work-secret"))
        XCTAssertFalse(metadata.contains("personal-secret"))
        try store.remove(work.id)
        XCTAssertNil(store.selectedAccount(for: .claude), "Removal returns to the existing connection, not another saved account")
        XCTAssertNil(secrets.values[work.keychainAccount])
        XCTAssertEqual(secrets.values[personal.keychainAccount], "personal-secret")
        XCTAssertEqual(secrets.values["claude-web"], "legacy-claude")
        XCTAssertEqual(secrets.values["cursor"], "legacy-cursor")
        XCTAssertEqual(secrets.values["openrouter"], "legacy-key")
    }

    @MainActor func testRemovedAccountsCannotReturnThroughPendingReads() async throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let started = expectation(description: "Account read started")
        let reads = AccountReads([started])
        let store = AccountStore(file: file, reader: { account, _ in try await reads.read(account) }, saveSecret: { _, _ in }, removeSecret: { _ in })
        let account = try store.add(provider: .cursor, label: "Work", credential: "secret", snapshot: snapshot(20))
        var callbacks = 0
        store.onSnapshot = { _, _ in callbacks += 1 }
        let task = try XCTUnwrap(store.refresh(account.id))
        await fulfillment(of: [started], timeout: 2)
        try store.remove(account.id)
        await reads.finish(0, used: 90)
        await task.value
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.loading.isEmpty)
        XCTAssertEqual(callbacks, 0)
    }

    @MainActor func testSelectionDoesNotMixReadingsAndFailuresKeepLastGoodSnapshot() async throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = expectation(description: "Work read started")
        let second = expectation(description: "Personal read started")
        let reads = AccountReads([first, second])
        let store = AccountStore(file: file, reader: { account, _ in try await reads.read(account) }, saveSecret: { _, _ in }, removeSecret: { _ in })
        let work = try store.add(provider: .claude, label: "Work", credential: "work", snapshot: snapshot(70))
        let personal = try store.add(provider: .claude, label: "Personal", credential: "personal", snapshot: snapshot(10))
        store.select(work.id, for: .claude)
        let workTask = try XCTUnwrap(store.refresh(work.id))
        await fulfillment(of: [first], timeout: 2)
        store.select(personal.id, for: .claude)
        let personalTask = try XCTUnwrap(store.refresh(personal.id))
        await fulfillment(of: [second], timeout: 2)
        await reads.finish(0, used: 95)
        await reads.finish(1)
        await workTask.value
        await personalTask.value
        XCTAssertEqual(store.selectedAccount(for: .claude)?.id, personal.id)
        XCTAssertEqual(store.snapshots[work.id]?.windows.first?.used, 95)
        XCTAssertEqual(store.snapshots[personal.id]?.windows.first?.used, 10)
        XCTAssertEqual(store.errors[personal.id], "Account read failed")
        XCTAssertNil(store.errors[work.id])
    }

    @MainActor func testInvalidationAllowsFreshReadAndDropsOlderCompletion() async throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = expectation(description: "Original read started")
        let second = expectation(description: "Replacement read started")
        let reads = AccountReads([first, second])
        let store = AccountStore(file: file, reader: { account, _ in try await reads.read(account) }, saveSecret: { _, _ in }, removeSecret: { _ in })
        let account = try store.add(provider: .openrouter, label: "Personal", credential: "secret", snapshot: snapshot(10))
        let original = try XCTUnwrap(store.refresh(account.id))
        await fulfillment(of: [first], timeout: 2)
        store.stop()
        let replacement = try XCTUnwrap(store.refresh(account.id))
        await fulfillment(of: [second], timeout: 2)
        await reads.finish(0, used: 95)
        await original.value
        XCTAssertEqual(store.snapshots[account.id]?.windows.first?.used, 10)
        XCTAssertTrue(store.loading.contains(account.id))
        await reads.finish(1, used: 20)
        await replacement.value
        XCTAssertEqual(store.snapshots[account.id]?.windows.first?.used, 20)
        XCTAssertTrue(store.loading.isEmpty)
    }

    @MainActor func testFailedRemovalPreservesMetadataAndCredentials() throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let secrets = AccountSecrets()
        let store = AccountStore(file: file, saveSecret: secrets.save, removeSecret: secrets.remove)
        let account = try store.add(provider: .claude, label: "Work", credential: "secret", snapshot: snapshot(20))
        secrets.rejectRemoval = true
        XCTAssertThrowsError(try store.remove(account.id))
        let restored = AccountStore(file: file, saveSecret: secrets.save, removeSecret: secrets.remove)
        XCTAssertEqual(restored.accounts, [account])
        XCTAssertEqual(restored.selectedAccount(for: .claude)?.id, account.id)
        XCTAssertEqual(store.snapshots[account.id]?.windows.first?.used, 20)
        XCTAssertEqual(secrets.values[account.keychainAccount], "secret")
    }

    @MainActor func testMalformedMetadataIsNotOverwritten() throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("invalid metadata".utf8)
        try original.write(to: file)
        let secrets = AccountSecrets()
        let store = AccountStore(file: file, saveSecret: secrets.save, removeSecret: secrets.remove)
        XCTAssertNotNil(store.message)
        XCTAssertThrowsError(try store.add(provider: .claude, label: "Work", credential: "secret", snapshot: snapshot(20)))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(secrets.values.count, 3)
    }
}
