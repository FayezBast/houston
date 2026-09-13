import XCTest
@testable import HoustonCore

final class UsageTests: XCTestCase {
    func testClaudeBridgeOnlyPersistsQuotaFields() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("usage.json")
        let input = Data(#"{"session_id":"private-session","transcript_path":"/private/transcript","workspace":{"current_dir":"/private/repo"},"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":2000000000}}}"#.utf8)
        try UsageReader.captureClaude(input, to: destination)
        let saved = try Data(contentsOf: destination)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["rate_limits"])
        XCTAssertEqual(try UsageReader.parseClaude(saved).windows.first?.remaining, 75)
        try UsageReader.captureClaude(Data("{}".utf8), to: destination)
        XCTAssertThrowsError(try UsageReader.parseClaude(Data(contentsOf: destination)))
    }

    func testPrefersCodexBucketAndPreservesMissingWindows() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":24,"windowDurationMins":300,"resetsAt":2000000000},"secondary":null},"other":{"primary":{"usedPercent":90}}}}}"#.utf8)
        let result = try UsageReader.parseCodex(data)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].remaining, 76)
        XCTAssertEqual(result.windows[0].name, "5-hour")
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 2000000000))
    }

    func testMissingIsNotZeroUsage() {
        XCTAssertThrowsError(try UsageReader.parseCodex(Data(#"{"result":{"rateLimits":null}}"#.utf8)))
        XCTAssertThrowsError(try UsageReader.parseClaude(Data(#"{"rate_limits":{}}"#.utf8)))
        XCTAssertThrowsError(try UsageReader.parseClaude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":null}}}"#.utf8)))
    }

    func testClaudeAndClamping() throws {
        let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":103,"resets_at":2000000000},"seven_day":{"used_percentage":12.5}}}"#.utf8)
        let result = try UsageReader.parseClaude(data)
        XCTAssertEqual(result.windows.map(\.remaining), [0, 87.5])
        XCTAssertNil(result.windows[1].resetsAt)
        XCTAssertEqual(result.windows[1].countdown(), "Reset time unavailable")
    }

    func testResetBoundaryDoesNotInventNewAllowance() {
        let now = Date(timeIntervalSince1970: 10000)
        let expired = UsageWindow(name: "5-hour", used: 100, resetsAt: now)
        XCTAssertTrue(expired.expired(at: now))
        XCTAssertEqual(expired.remaining, 0)
        XCTAssertEqual(expired.countdown(at: now), "Awaiting updated usage")
        XCTAssertEqual(UsageWindow(name: "5-hour", used: 10, resetsAt: now.addingTimeInterval(7200)).countdown(at: now), "Resets in 2h 0m")
    }

    func testClaudeBridgeAcceptsSpendLimitAndIsoResetTimes() throws {
        let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"spend_limit":{"used_percentage":62.8,"resets_at":"2025-02-28T00:00:00Z"}}}"#.utf8)
        let result = try UsageReader.parseClaude(data)
        XCTAssertEqual(result.windows.map(\.name), ["5-hour", "Spend limit"])
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 1738425600))
        XCTAssertEqual(result.windows[1].resetsAt, Date(timeIntervalSince1970: 1740700800))
    }

    func testClaudeDirectUsageParsesUtilizationWindows() throws {
        let data = Data(#"{"five_hour":{"utilization":7.5,"resets_at":"2025-10-01T15:00:00.000000+00:00"},"seven_day":{"utilization":41,"resets_at":"2025-10-07T00:00:00Z"},"seven_day_opus":null,"seven_day_oauth_apps":{"utilization":null}}"#.utf8)
        let result = try ClaudeAccount.parseUsage(data)
        XCTAssertEqual(result.windows.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(result.windows[0].remaining, 92.5)
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 1759330800), "Six fractional digits must still parse")
        XCTAssertEqual(result.windows[1].remaining, 59)
        XCTAssertThrowsError(try ClaudeAccount.parseUsage(Data(#"{"five_hour":null}"#.utf8)))
    }

    func testClaudeTokenParsingChecksExpiryAndShape() throws {
        let valid = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","expiresAt":4102444800000,"subscriptionType":"max"}}"#.utf8)
        XCTAssertEqual(try ClaudeAccount.parseToken(valid), "sk-ant-oat01-test")
        let expired = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","expiresAt":1000}}"#.utf8)
        XCTAssertThrowsError(try ClaudeAccount.parseToken(expired)) { XCTAssertTrue($0.localizedDescription.contains("expired")) }
        XCTAssertThrowsError(try ClaudeAccount.parseToken(Data(#"{"other":{}}"#.utf8)))
    }
}
