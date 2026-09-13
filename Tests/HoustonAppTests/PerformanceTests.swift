import XCTest
import Combine
import HoustonCore
@testable import Houston

final class PerformanceTests: XCTestCase {
    @MainActor func testHiddenGitHubDoesNotLaunchRefreshes() {
        let store = Store()
        store.enabled = []
        store.repository = "apple/swift"
        store.refresh()
        XCTAssertFalse(store.overviewLoading, "Hidden GitHub must not launch its five CLI requests")
        XCTAssertFalse(store.activityLoading, "Hidden repository must not launch CLI requests")
    }

    @MainActor func testPreviewDoesNotStartLiveWork() {
        let store = Store()
        store.demo = true
        store.repository = "apple/swift"
        store.refresh()
        store.refresh(.codex)
        store.refreshOverview()
        store.refreshActivity()
        XCTAssertTrue(store.loading.isEmpty)
        XCTAssertFalse(store.overviewLoading)
        XCTAssertFalse(store.activityLoading)
    }

    @MainActor func testBridgeObservesRepeatedAtomicReplacementsAndStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("claude-usage.json")
        let store = Store(bridgeFile: file)
        store.enabled = [.claude]
        store.claudeDirect = false
        store.start()
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }

        for used in [17.0, 29.0] {
            let updated = expectation(description: "Atomic write with usage \(used) is delivered")
            let subscription = store.$snapshots.filter { $0[.claude]?.windows.first?.used == used }
                .prefix(1).sink { _ in updated.fulfill() }
            try UsageReader.captureClaude(Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(used)}}}".utf8), to: file)
            await fulfillment(of: [updated], timeout: 3)
            subscription.cancel()
        }
        store.demo = true
        try UsageReader.captureClaude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":45}}}"#.utf8), to: file)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.snapshots[.claude]?.windows.first?.used, 29)
        store.demo = false
        XCTAssertEqual(store.snapshots[.claude]?.windows.first?.used, 45, "Returning to live must catch up immediately")
        // Let the explicitly requested refresh finish before stopping the watcher.
        try await Task.sleep(for: .milliseconds(150))
        store.stop()
        try UsageReader.captureClaude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":60}}}"#.utf8), to: file)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.snapshots[.claude]?.windows.first?.used, 45)
    }
}
