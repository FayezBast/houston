import XCTest
import HoustonCore
@testable import Houston

final class ProviderCoverageTests: XCTestCase {
    private var savedSelection: Any?

    override func setUp() {
        super.setUp()
        savedSelection = UserDefaults.standard.object(forKey: "compactProviders")
        UserDefaults.standard.removeObject(forKey: "compactProviders")
    }

    override func tearDown() {
        if let savedSelection { UserDefaults.standard.set(savedSelection, forKey: "compactProviders") }
        else { UserDefaults.standard.removeObject(forKey: "compactProviders") }
        super.tearDown()
    }

    @MainActor private func store() -> Store {
        let store = Store()
        store.enabled = Set(Provider.allCases)
        return store
    }

    @MainActor func testCompactSelectionHasFourSlotsPersistsAndExcludesDisabledProviders() {
        let store = store()
        XCTAssertEqual(store.compactProviders, [.codex, .claude, .cursor, .copilot])
        XCTAssertEqual(store.compactOverflowCount, 3)
        store.setCompactPinned(.gemini, true)
        XCTAssertFalse(store.isCompactPinned(.gemini), "A fifth pin cannot silently replace an existing choice")

        store.enabled.remove(.claude)
        XCTAssertEqual(store.compactProviders, [.codex, .cursor, .copilot])
        XCTAssertEqual(store.compactOverflowCount, 3)
        store.setCompactPinned(.claude, true)
        XCTAssertFalse(store.isCompactPinned(.claude), "An off provider cannot appear in the island")
        store.setCompactPinned(.gemini, true)
        XCTAssertEqual(store.compactProviders, [.codex, .cursor, .copilot, .gemini])
        store.setCompactPinned(.codex, false)
        XCTAssertEqual(self.store().compactProviders, [.cursor, .copilot, .gemini])

        for provider in store.compactProviders { store.setCompactPinned(provider, false) }
        XCTAssertTrue(self.store().compactProviders.isEmpty, "Choosing no pins must survive relaunch")
    }

    @MainActor func testSavedSelectionIgnoresUnknownDuplicateAndExcessProviders() {
        UserDefaults.standard.set(["Unknown", "Cursor", "Cursor", "Codex", "Claude", "Copilot", "Gemini"], forKey: "compactProviders")
        XCTAssertEqual(store().compactProviders, [.cursor, .codex, .claude, .copilot])
    }

    @MainActor func testCompactValueDistinguishesMissingLoadingFreshSavedAndExpiredReadings() {
        let store = store()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(store.reading(for: .codex, at: now).value, "—")
        XCTAssertFalse(store.reading(for: .codex, at: now).isConnected)
        store.loading.insert(.codex)
        XCTAssertEqual(store.reading(for: .codex, at: now).value, "…")
        XCTAssertTrue(store.reading(for: .codex, at: now).isLoading)
        store.loading.remove(.codex)

        let window = UsageWindow(name: "5-hour", used: 24, resetsAt: now.addingTimeInterval(3600))
        store.snapshots[.codex] = UsageSnapshot(windows: [window], capturedAt: now)
        XCTAssertEqual(store.reading(for: .codex, at: now).value, "76%")
        XCTAssertEqual(store.reading(for: .codex, at: now).remaining, 76)
        XCTAssertEqual(store.reading(for: .codex, at: now).status, "Connected")

        let stale = store.reading(for: .codex, at: now.addingTimeInterval(601))
        XCTAssertEqual(stale.value, "~76%")
        XCTAssertEqual(stale.status, "Earlier reading")
        XCTAssertTrue(stale.needsAttention)
        store.errors[.codex] = "Offline"
        XCTAssertEqual(store.reading(for: .codex, at: now).value, "~76%")
        XCTAssertTrue(store.reading(for: .codex, at: now).needsAttention)

        let expired = store.reading(for: .codex, at: now.addingTimeInterval(3600))
        XCTAssertEqual(expired.value, "—")
        XCTAssertNil(expired.remaining)
        XCTAssertEqual(expired.status, "Awaiting updated usage")
        XCTAssertTrue(expired.needsAttention)
        store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(name: "Invalid", used: .nan, resetsAt: nil)], capturedAt: now)
        XCTAssertEqual(store.reading(for: .codex, at: now).value, "—", "Invalid provider values must not crash integer formatting")
    }

    @MainActor func testUnlimitedRequiresExplicitProviderAllowanceAndLocalCacheStaysMarked() {
        let store = store()
        for provider in [Provider.copilot, .cursor] {
            store.snapshots[provider] = UsageSnapshot(windows: [], detail: "Unlimited allowance")
            XCTAssertEqual(store.reading(for: provider).value, "∞")
        }
        store.snapshots[.openrouter] = UsageSnapshot(windows: [], detail: "$12.00 used · no key budget set")
        XCTAssertEqual(store.reading(for: .openrouter).value, "—", "No key budget does not mean unlimited credits")
        store.snapshots[.windsurf] = UsageSnapshot(windows: [UsageWindow(name: "Daily", used: 24, resetsAt: nil)])
        XCTAssertEqual(store.reading(for: .windsurf).value, "~76%")
        XCTAssertEqual(store.reading(for: .windsurf).status, "Local cache")
    }

    @MainActor func testCountsIgnoreDisabledProvidersAndPreviewDoesNotClaimConnections() {
        let store = store()
        store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: 95, resetsAt: nil)])
        store.errors[.claude] = "Sign-in required"
        store.snapshots[.cursor] = UsageSnapshot(windows: [UsageWindow(name: "Included plan", used: 24, resetsAt: nil)])
        store.enabled.remove(.cursor)
        XCTAssertEqual(store.connectedCount, 1)
        XCTAssertEqual(store.attentionCount, 2)
        XCTAssertEqual(store.availableCount, 7)

        store.demo = true
        XCTAssertEqual(store.connectedCount, 0)
        XCTAssertEqual(store.attentionCount, 0)
        XCTAssertEqual(store.reading(for: .claude).status, "Preview")
        XCTAssertEqual(store.reading(for: .claude).value, "67%")
        XCTAssertFalse(store.reading(for: .claude).isConnected)
        XCTAssertEqual(store.snapshot(for: .openrouter)?.windows.count, 1, "Preview must not invent weekly API-key quota")
        XCTAssertNil(store.snapshot(for: .openrouter)?.windows.first?.resetsAt)
    }
}
