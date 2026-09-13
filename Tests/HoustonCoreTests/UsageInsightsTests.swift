import XCTest
@testable import HoustonCore

final class UsageInsightsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    private func quota(_ used: Double, at date: Date, reset: Date?, window: String = "5-hour") -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(name: window, used: used, resetsAt: reset)], capturedAt: date)
    }

    @discardableResult private func record(_ history: inout UsageHistory, _ used: Double, offset: Double,
                                          account: String = "personal", reset: Date? = nil,
                                          threshold: Double = 20) -> [QuotaAlert] {
        let date = start.addingTimeInterval(offset)
        return history.record(snapshot: quota(used, at: date, reset: reset), provider: "Codex", accountID: account,
                              accountLabel: account.capitalized, remainingThreshold: threshold, now: date)
    }

    func testAlertBaselineCrossingAndAccountIsolation() {
        var history = UsageHistory()
        let reset = start.addingTimeInterval(3600)
        XCTAssertTrue(record(&history, 85, offset: 0, account: "work", reset: reset).isEmpty, "Connecting an already-low account is silent")
        XCTAssertTrue(record(&history, 70, offset: 0, reset: reset).isEmpty)
        let crossing = record(&history, 81, offset: 300, reset: reset)
        XCTAssertEqual(crossing.map(\.kind), [.lowQuota])
        XCTAssertEqual(crossing.first?.accountID, "personal")
        XCTAssertEqual(crossing.first?.remaining, 19)
        XCTAssertTrue(record(&history, 90, offset: 300, account: "work", reset: reset).isEmpty)
        XCTAssertTrue(record(&history, 40, offset: 600, reset: reset).isEmpty)
        XCTAssertTrue(record(&history, 90, offset: 900, reset: reset).isEmpty, "A same-cycle correction cannot duplicate an alert")
    }

    func testOnlyFreshObservedCycleChangeProducesReset() {
        var history = UsageHistory()
        let firstReset = start.addingTimeInterval(3600)
        record(&history, 90, offset: 0, reset: firstReset)
        XCTAssertTrue(record(&history, 50, offset: 300, reset: firstReset.addingTimeInterval(60)).isEmpty,
                      "A corrected future reset time is not a completed reset")
        let reset = record(&history, 10, offset: 3661, reset: start.addingTimeInterval(7200))
        XCTAssertEqual(reset.map(\.kind), [.reset])
        XCTAssertTrue(record(&history, 15, offset: 3961, reset: start.addingTimeInterval(7200)).isEmpty)
        XCTAssertEqual(record(&history, 85, offset: 4261, reset: start.addingTimeInterval(7200)).map(\.kind), [.lowQuota])
        XCTAssertTrue(record(&history, 1, offset: 4561, account: "unknown-reset").isEmpty)
        XCTAssertTrue(record(&history, 0, offset: 4861, account: "unknown-reset").isEmpty, "A decrease without a reset time proves no reset")
    }

    func testStaleExpiredDuplicateAndOutOfOrderSamplesCannotInventActivity() {
        var history = UsageHistory()
        let reset = start.addingTimeInterval(3600)
        record(&history, 70, offset: 300, reset: reset)
        let duplicate = quota(99, at: start.addingTimeInterval(300), reset: reset)
        XCTAssertTrue(history.record(snapshot: duplicate, provider: "Codex", accountID: "personal", accountLabel: "Personal", now: start.addingTimeInterval(300)).isEmpty)
        XCTAssertTrue(record(&history, 99, offset: 200, reset: reset).isEmpty)
        let stale = quota(99, at: start, reset: reset)
        XCTAssertTrue(history.record(snapshot: stale, provider: "Codex", accountID: "personal", accountLabel: "Personal", now: start.addingTimeInterval(601)).isEmpty)
        XCTAssertTrue(record(&history, 99, offset: 3600, reset: reset).isEmpty)
        XCTAssertTrue(record(&history, .infinity, offset: 500, reset: reset).isEmpty)
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.used, 70)
    }

    func testPaceRequiresFreshMonotonicReadingsInOneAccountAndCycle() throws {
        var history = UsageHistory()
        let reset = start.addingTimeInterval(7200)
        record(&history, 10, offset: 0, reset: reset)
        record(&history, 50, offset: 0, account: "work", reset: reset)
        XCTAssertNil(history.forecast(provider: "Codex", accountID: "personal", window: "5-hour", now: start))
        record(&history, 20, offset: 600, reset: reset)
        let estimate = try XCTUnwrap(history.forecast(provider: "Codex", accountID: "personal", window: "5-hour", now: start.addingTimeInterval(600)))
        XCTAssertEqual(estimate.percentPerHour, 60, accuracy: 0.001)
        XCTAssertEqual(estimate.exhaustionDate, start.addingTimeInterval(5400))
        XCTAssertTrue(estimate.runsOutBeforeReset)
        XCTAssertNil(history.forecast(provider: "Codex", accountID: "work", window: "5-hour", now: start.addingTimeInterval(600)))
        XCTAssertNil(history.forecast(provider: "Codex", accountID: "personal", window: "5-hour", now: start.addingTimeInterval(1201)))
        XCTAssertNil(history.forecast(provider: "Codex", accountID: "personal", window: "5-hour", now: reset))
        record(&history, 5, offset: 900, reset: reset)
        XCTAssertNil(history.forecast(provider: "Codex", accountID: "personal", window: "5-hour", now: start.addingTimeInterval(900)), "Corrections invalidate a linear pace")
        record(&history, 1, offset: 7201, reset: start.addingTimeInterval(14400))
        XCTAssertNil(history.forecast(provider: "Codex", accountID: "personal", window: "5-hour", now: start.addingTimeInterval(7201)), "Do not carry the previous cycle's pace forward")
    }

    func testSpendPreservesDollarsAndCurrenciesSeparatelyFromPercentages() {
        var history = UsageHistory()
        let snapshot = UsageSnapshot(windows: [UsageWindow(name: "Key budget", used: 50, resetsAt: nil)], capturedAt: start,
                                     spend: UsageSpend(used: 250, budget: 500, currency: "USD"))
        history.record(snapshot: snapshot, provider: "OpenRouter", accountID: "key-a", accountLabel: "Work", now: start)
        XCTAssertEqual(history.samples.count, 2)
        XCTAssertEqual(history.samples.first(where: { $0.metric == .quota })?.used, 50)
        XCTAssertEqual(history.samples.first(where: { $0.metric == .spend })?.used, 250, "Currency amounts must not be clamped to 100")
        let euro = UsageSnapshot(windows: [], capturedAt: start.addingTimeInterval(300), spend: UsageSpend(used: 20, budget: 0, currency: "EUR"))
        history.record(snapshot: euro, provider: "OpenRouter", accountID: "key-a", accountLabel: "Work", now: start.addingTimeInterval(300))
        XCTAssertEqual(history.samples.last?.currency, "EUR")
        XCTAssertEqual(history.samples.last?.budget, 0)
        XCTAssertNotEqual(history.samples[1].scope, history.samples[2].scope)
        let unlimited = UsageSnapshot(windows: [], capturedAt: start.addingTimeInterval(600), spend: UsageSpend(used: 300))
        history.record(snapshot: unlimited, provider: "OpenRouter", accountID: "key-b", accountLabel: "Personal", now: start.addingTimeInterval(600))
        XCTAssertNil(history.samples.last?.budget)
    }

    func testPersistenceKeepsBaselineAndPrunesOldHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage-history.json")
        var history = UsageHistory()
        let reset = start.addingTimeInterval(3600)
        record(&history, 70, offset: 0, reset: reset)
        try history.save(to: file)
        var restored = try UsageHistory.load(from: file, now: start)
        XCTAssertEqual(restored.samples, history.samples)
        XCTAssertEqual(record(&restored, 90, offset: 300, reset: reset).map(\.kind), [.lowQuota])
        try restored.save(to: file)
        restored = try UsageHistory.load(from: file, now: start.addingTimeInterval(300))
        XCTAssertTrue(record(&restored, 95, offset: 600, reset: reset).isEmpty)
        XCTAssertTrue(try UsageHistory.load(from: file, now: start.addingTimeInterval(91 * 86_400)).samples.isEmpty)
    }

    func testObservedHitsCountCyclesOnlyForChosenAccountAndPeriod() {
        var history = UsageHistory()
        let first = start.addingTimeInterval(3600), second = start.addingTimeInterval(7200)
        record(&history, 100, offset: 0, reset: first)
        record(&history, 100, offset: 300, reset: first)
        record(&history, 100, offset: 300, account: "work", reset: first)
        record(&history, 0, offset: 3601, reset: second)
        record(&history, 100, offset: 3901, reset: second)
        XCTAssertEqual(history.observedLimitHits(provider: "Codex", accountID: "personal", window: "5-hour", since: start), 2)
        XCTAssertEqual(history.observedLimitHits(provider: "Codex", accountID: "personal", window: "5-hour", since: start.addingTimeInterval(3600)), 1)
        XCTAssertEqual(history.observedLimitHits(provider: "Codex", accountID: "work", window: "5-hour", since: start), 1)
    }
}
