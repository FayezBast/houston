import XCTest
@testable import HoustonCore

final class GitHubAlertTests: XCTestCase {
    private func signal(_ state: String, id: String = "pr-checks") -> GitHubSignal {
        GitHubSignal(id: id, state: state, title: "Ship checkout", detail: "team/app #12", url: URL(string: "https://github.com/team/app/pull/12")!)
    }

    func testBaselineTransitionsAndIndependentAccounts() {
        var tracker = GitHubAlertTracker()
        XCTAssertTrue(tracker.observe([signal("SUCCESS")], scope: "personal").isEmpty)
        XCTAssertTrue(tracker.observe([signal("SUCCESS")], scope: "personal").isEmpty)
        XCTAssertTrue(tracker.observe([signal("PENDING")], scope: "personal").isEmpty)
        XCTAssertEqual(tracker.observe([signal("FAILURE")], scope: "personal").first?.alertTitle, "Build failed")
        XCTAssertTrue(tracker.observe([signal("FAILURE")], scope: "personal").isEmpty)
        XCTAssertTrue(tracker.observe([signal("FAILURE")], scope: "work").isEmpty)
        XCTAssertEqual(tracker.observe([signal("SUCCESS")], scope: "personal").first?.alertTitle, "Checks passed")
        XCTAssertTrue(tracker.observe([signal("UNKNOWN")], scope: "personal").isEmpty)
        XCTAssertTrue(tracker.observe([signal("SUCCESS")], scope: "personal").isEmpty, "An unavailable rollup must not cause a duplicate success alert")
        XCTAssertEqual(tracker.observe([signal("CHANGES_REQUESTED", id: "review")], scope: "personal").first?.alertTitle, "Changes requested")
        XCTAssertEqual(tracker.observe([signal("SUCCESS", id: "pr-checks-new-commit")], scope: "personal").count, 1,
                       "A different commit completing between polls is a new result")
    }

    func testGraphQLRollupsAndPartialErrors() throws {
        let payload = Data(#"{"data":{"viewer":{"login":"developer"},"search":{"nodes":[{"id":"PR_1","title":"Ship checkout","url":"https://github.com/team/app/pull/12","number":12,"reviewDecision":"CHANGES_REQUESTED","repository":{"nameWithOwner":"team/app"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}]}}}"#.utf8)
        let result = try GitHubSignalReader.parse(payload)
        XCTAssertEqual(result.login, "developer")
        XCTAssertEqual(result.signals.map(\.alertTitle), ["Changes requested", "Build failed"])
        XCTAssertEqual(result.signals.first?.url.absoluteString, "https://github.com/team/app/pull/12")
        let next = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\"commit\":{", with: "\"commit\":{\"oid\":\"abc123\",").utf8)
        XCTAssertTrue(try XCTUnwrap(GitHubSignalReader.parse(next).signals.last?.id).hasSuffix("abc123"))
        XCTAssertThrowsError(try GitHubSignalReader.parse(Data(#"{"errors":[{"message":"Forbidden"}],"data":{"viewer":{"login":"developer"},"search":{"nodes":[]}}}"#.utf8)))
        XCTAssertThrowsError(try GitHubSignalReader.parse(Data("{}".utf8)))
    }
}
