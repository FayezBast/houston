import XCTest
import Combine
import HoustonCore
@testable import Houston

private actor ControlledUsageReads {
    struct Call: Sendable {
        let provider: Provider
        let direct: Bool
        let allowInteraction: Bool
    }
    private(set) var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<UsageSnapshot, Error>] = [:]
    private let started: [XCTestExpectation]

    init(started: [XCTestExpectation]) { self.started = started }

    func read(_ provider: Provider, direct: Bool, allowInteraction: Bool) async throws -> UsageSnapshot {
        let index = calls.count
        calls.append(Call(provider: provider, direct: direct, allowInteraction: allowInteraction))
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            if started.indices.contains(index) { started[index].fulfill() }
        }
    }

    func finish(_ index: Int, used: Double = 25, failure: Bool = false) {
        let continuation = pending.removeValue(forKey: index)
        if failure { continuation?.resume(throwing: UsageError.unavailable("Test read failed")) }
        else {
            continuation?.resume(returning: UsageSnapshot(windows: [UsageWindow(name: "Current", used: used, resetsAt: nil)],
                detail: calls[index].provider == .claude && calls[index].direct ? "Direct test reading" : nil))
        }
    }
}

final class StoreUsageTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let preferenceKeys = ["claudeDirect", "enabledProviders"]

    override func setUp() {
        super.setUp()
        for key in preferenceKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in preferenceKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    @MainActor private func store(using reads: ControlledUsageReads) -> Store {
        Store(bridgeFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("usage.json"),
              alerts: AlertCenter(defaults: UserDefaults(suiteName: UUID().uuidString)!)) {
            provider, direct, allowInteraction, _ in
            try await reads.read(provider, direct: direct, allowInteraction: allowInteraction)
        }
    }

    @MainActor private func finishCurrent(_ reads: ControlledUsageReads, index: Int, store: Store, provider: Provider, used: Double) async {
        let idle = expectation(description: "Current \(provider.rawValue) request finishes")
        let subscription = store.$loading.filter { !$0.contains(provider) }.prefix(1).sink { _ in idle.fulfill() }
        await reads.finish(index, used: used)
        await fulfillment(of: [idle], timeout: 2)
        subscription.cancel()
    }

    @MainActor func testChangingClaudeConnectionDiscardsBothOutdatedModes() async throws {
        for initiallyDirect in [false, true] {
            let firstStarted = expectation(description: "Original Claude source starts")
            let replacementStarted = expectation(description: "Selected Claude source starts immediately")
            let reads = ControlledUsageReads(started: [firstStarted, replacementStarted])
            let store = store(using: reads)
            store.enabled = [.claude]
            store.claudeDirect = initiallyDirect
            defer { store.stop() }
            let original = try XCTUnwrap(store.refresh(.claude))
            await fulfillment(of: [firstStarted], timeout: 2)

            store.setClaudeDirect(!initiallyDirect)
            await fulfillment(of: [replacementStarted], timeout: 2)
            await reads.finish(0, used: 88, failure: !initiallyDirect)
            await original.value
            XCTAssertNil(store.snapshots[.claude], "An old source cannot replace the newly selected source")
            XCTAssertNil(store.errors[.claude], "An old bridge error cannot mark direct mode as disconnected")
            XCTAssertTrue(store.loading.contains(.claude), "The old completion cannot clear the replacement's loading state")

            await finishCurrent(reads, index: 1, store: store, provider: .claude, used: 22)
            XCTAssertEqual(store.snapshots[.claude]?.windows.first?.used, 22)
            let calls = await reads.calls
            XCTAssertEqual(calls.map(\.direct), [initiallyDirect, !initiallyDirect])
            XCTAssertEqual(calls.map(\.allowInteraction), [false, !initiallyDirect], "Only explicitly enabling direct mode may request Keychain interaction")
        }
    }

    @MainActor func testStopIgnoresInFlightReadAndRestartStartsFreshRead() async throws {
        let firstStarted = expectation(description: "Live read starts")
        let replacementStarted = expectation(description: "Restarting starts a replacement")
        let reads = ControlledUsageReads(started: [firstStarted, replacementStarted])
        let store = store(using: reads)
        store.enabled = []
        store.start()
        defer { store.stop() }
        store.enabled = [.codex]
        let original = try XCTUnwrap(store.refresh(.codex))
        await fulfillment(of: [firstStarted], timeout: 2)

        store.stop()
        XCTAssertTrue(store.loading.isEmpty)
        store.start()
        await fulfillment(of: [replacementStarted], timeout: 2)
        await reads.finish(0, used: 88)
        await original.value
        XCTAssertNil(store.snapshots[.codex])
        XCTAssertTrue(store.loading.contains(.codex))
        await finishCurrent(reads, index: 1, store: store, provider: .codex, used: 22)
        XCTAssertEqual(store.snapshots[.codex]?.windows.first?.used, 22)
    }

    @MainActor func testDisabledProviderCanRefreshBeforeOldReadFinishes() async throws {
        let firstStarted = expectation(description: "Cursor read starts")
        let replacementStarted = expectation(description: "Reenabled Cursor starts a replacement")
        let reads = ControlledUsageReads(started: [firstStarted, replacementStarted])
        let store = store(using: reads)
        store.enabled = [.cursor]
        defer { store.stop() }
        let original = try XCTUnwrap(store.refresh(.cursor))
        await fulfillment(of: [firstStarted], timeout: 2)

        store.setEnabled(.cursor, false)
        XCTAssertTrue(store.loading.isEmpty)
        store.setEnabled(.cursor, true)
        await fulfillment(of: [replacementStarted], timeout: 2)
        await finishCurrent(reads, index: 1, store: store, provider: .cursor, used: 22)
        await reads.finish(0, used: 88)
        await original.value
        XCTAssertEqual(store.snapshots[.cursor]?.windows.first?.used, 22)
        XCTAssertTrue(store.loading.isEmpty)
    }

    @MainActor func testVerifiedWebConnectionSupersedesPendingReadsAndEnablesProvider() async throws {
        for provider in [Provider.cursor, .claude] {
            for wasEnabled in [false, true] {
                let started = expectation(description: "Existing web account read starts")
                let reads = ControlledUsageReads(started: [started])
                let store = store(using: reads)
                store.enabled = [provider]
                defer { store.stop() }
                let original = try XCTUnwrap(store.refresh(provider))
                await fulfillment(of: [started], timeout: 2)
                if !wasEnabled { store.enabled.remove(provider) }
                store.errors[provider] = "Old connection failed"
                let snapshot = UsageSnapshot(windows: [UsageWindow(name: "Current", used: 11, resetsAt: nil)])
                if provider == .cursor { store.connectedCursor(snapshot) }
                else { store.connectedClaude(snapshot); XCTAssertTrue(store.claudeDirect) }
                await reads.finish(0, used: 88)
                await original.value
                XCTAssertTrue(store.enabled.contains(provider))
                XCTAssertEqual(store.snapshots[provider]?.windows.first?.used, 11)
                XCTAssertNil(store.errors[provider])
                XCTAssertTrue(store.loading.isEmpty)
                let calls = await reads.calls
                XCTAssertEqual(calls.count, 1, "Verified sign-in already supplied usage; no second fetch is needed")
            }
        }
    }

    @MainActor func testShutdownDiscardsBothSuccessAndErrorCompletions() async throws {
        for failure in [false, true] {
            let started = expectation(description: "Read starts before shutdown")
            let reads = ControlledUsageReads(started: [started])
            let store = store(using: reads)
            store.enabled = [.openrouter]
            let request = try XCTUnwrap(store.refresh(.openrouter))
            await fulfillment(of: [started], timeout: 2)
            store.stop()
            await reads.finish(0, failure: failure)
            await request.value
            XCTAssertTrue(store.loading.isEmpty)
            XCTAssertTrue(store.snapshots.isEmpty)
            XCTAssertTrue(store.errors.isEmpty)
        }
    }

    @MainActor func testFailurePreservesReadingAndRecoveryClearsError() async throws {
        let firstStarted = expectation(description: "Failing request starts")
        let retryStarted = expectation(description: "Retry starts")
        let reads = ControlledUsageReads(started: [firstStarted, retryStarted])
        let store = store(using: reads)
        store.enabled = [.gemini]
        defer { store.stop() }
        store.snapshots[.gemini] = UsageSnapshot(windows: [UsageWindow(name: "Current", used: 17, resetsAt: nil)])
        let first = try XCTUnwrap(store.refresh(.gemini))
        await fulfillment(of: [firstStarted], timeout: 2)
        await reads.finish(0, failure: true)
        await first.value
        XCTAssertEqual(store.snapshots[.gemini]?.windows.first?.used, 17)
        XCTAssertEqual(store.errors[.gemini], "Test read failed")

        let retry = try XCTUnwrap(store.refresh(.gemini))
        await fulfillment(of: [retryStarted], timeout: 2)
        await reads.finish(1, used: 22)
        await retry.value
        XCTAssertEqual(store.snapshots[.gemini]?.windows.first?.used, 22)
        XCTAssertNil(store.errors[.gemini])
    }

    @MainActor func testStopCancelsAQueuedReadBeforeItStarts() async throws {
        let store = Store { _, _, _, _ in
            XCTFail("Stopping before a queued task runs must prevent its live read")
            return UsageSnapshot(windows: [])
        }
        store.enabled = [.codex]
        let task = try XCTUnwrap(store.refresh(.codex))
        store.stop()
        await task.value
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.loading.isEmpty)
    }

    @MainActor func testEveryProviderCanStartALiveRead() async throws {
        let store = Store { provider, _, _, _ in
            UsageSnapshot(windows: [UsageWindow(name: provider.rawValue, used: 25, resetsAt: nil)])
        }
        store.enabled = Set(Provider.allCases)
        defer { store.stop() }
        for provider in Provider.allCases {
            let task = try XCTUnwrap(store.refresh(provider), "\(provider.rawValue) must support live refresh")
            await task.value
            XCTAssertEqual(store.snapshots[provider]?.windows.first?.name, provider.rawValue)
            XCTAssertNil(store.errors[provider])
        }
    }

    @MainActor func testAutomaticRefreshNeverRequestsKeychainInteraction() async throws {
        let started = Provider.allCases.map { expectation(description: "\($0.rawValue) automatic read starts") }
        let reads = ControlledUsageReads(started: started)
        let store = store(using: reads)
        store.enabled = Set(Provider.allCases)
        defer { store.stop() }

        store.refresh()
        await fulfillment(of: started, timeout: 2)
        let calls = await reads.calls
        XCTAssertEqual(Set(calls.map(\.provider)), Set(Provider.allCases))
        XCTAssertTrue(calls.allSatisfy { !$0.allowInteraction })

        let idle = expectation(description: "Automatic reads finish")
        let subscription = store.$loading.filter(\.isEmpty).prefix(1).sink { _ in idle.fulfill() }
        for index in calls.indices { await reads.finish(index) }
        await fulfillment(of: [idle], timeout: 2)
        subscription.cancel()
    }

    @MainActor func testSelectedAccountOnlyAuthorizesExplicitConnectionChecks() async throws {
        for provider in [Provider.claude, .cursor, .openrouter] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let started = (0..<3).map { expectation(description: "\(provider.rawValue) account read \($0) starts") }
            let reads = ControlledUsageReads(started: started)
            let accounts = AccountStore(file: directory.appendingPathComponent("accounts.json"), reader: { _, allowInteraction in
                try await reads.read(provider, direct: false, allowInteraction: allowInteraction)
            }, saveSecret: { _, _ in }, removeSecret: { _ in })
            let account = try accounts.add(provider: provider, label: "Personal", credential: "test-credential",
                                           snapshot: UsageSnapshot(windows: []))
            let store = Store(bridgeFile: directory.appendingPathComponent("usage.json"), accounts: accounts,
                              alerts: AlertCenter(defaults: UserDefaults(suiteName: UUID().uuidString)!)) { _, _, _, _ in
                XCTFail("A selected account must use its own saved connection")
                return UsageSnapshot(windows: [])
            }
            store.enabled = [provider]
            defer { store.stop() }

            for (index, allowInteraction) in [false, true].enumerated() {
                let task = try XCTUnwrap(store.refresh(provider, allowInteraction: allowInteraction))
                await fulfillment(of: [started[index]], timeout: 2)
                await reads.finish(index)
                await task.value
            }
            store.refresh()
            await fulfillment(of: [started[2]], timeout: 2)
            let idle = expectation(description: "Selected account automatic read finishes")
            let subscription = accounts.$loading.filter { !$0.contains(account.id) }.prefix(1).sink { _ in idle.fulfill() }
            await reads.finish(2)
            await fulfillment(of: [idle], timeout: 2)
            subscription.cancel()
            let calls = await reads.calls
            XCTAssertEqual(calls.map(\.allowInteraction), [false, true, false],
                           "Explicit permission must reach the selected account without carrying over to the timer")
        }
    }
}
