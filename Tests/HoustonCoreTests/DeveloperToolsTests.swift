import XCTest
@testable import HoustonCore

final class DeveloperToolsTests: XCTestCase {
    func testLocalCommandsInheritEnvironmentUnlessExplicitlyOverridden() throws {
        let name = "HOUSTON_TEST_ENV_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        setenv(name, "inherited-marker", 1)
        defer { unsetenv(name) }
        let inherited = try LocalCommand.run("printenv", [name])
        XCTAssertEqual(String(decoding: inherited, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "inherited-marker")
        let overridden = try LocalCommand.run("printenv", [name], environment: [name: "explicit-marker"])
        XCTAssertEqual(String(decoding: overridden, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "explicit-marker")
    }

    func testCopilotUnlimitedIsNotFake100Percent() throws {
        let snapshot = try DeveloperTools.parseCopilot(Data(#"{"quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#.utf8))
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.detail, "Unlimited allowance")
        let metered = try DeveloperTools.parseCopilot(Data(#"{"quota_snapshots":{"premium_interactions":{"percent_remaining":67,"unlimited":false}},"quota_reset_date":"2030-01-01"}"#.utf8))
        XCTAssertEqual(metered.windows.first?.remaining, 67)
        XCTAssertNotNil(metered.windows.first?.resetsAt)
        let freePlan = try DeveloperTools.parseCopilot(Data(#"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"percent_remaining":0,"unlimited":false},"chat":{"entitlement":200,"percent_remaining":100,"unlimited":false}}}"#.utf8))
        XCTAssertEqual(freePlan.windows.count, 1)
        XCTAssertEqual(freePlan.windows.first?.name, "Chat")
        XCTAssertEqual(freePlan.windows.first?.remaining, 100)
    }

    func testGeminiUsesMostRestrictiveBucketForEachModel() throws {
        let snapshot = try DeveloperTools.parseGemini(Data(#"{"buckets":[{"modelId":"pro","remainingFraction":0.8},{"modelId":"pro","remainingFraction":0.3},{"modelId":"flash","remainingFraction":0.9}]}"#.utf8))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.first(where: { $0.name == "pro" })?.remaining, 30)
        XCTAssertThrowsError(try DeveloperTools.parseGemini(Data(#"{"buckets":[]}"#.utf8)))
    }

    func testWindsurfCacheSupportsQuotaAndLegacyCounters() throws {
        let quota = try DeveloperTools.parseWindsurf(Data(#"{"quotaUsage":{"dailyRemainingPercent":62,"weeklyRemainingPercent":88}}"#.utf8))
        XCTAssertEqual(quota.windows.map(\.remaining), [62, 88])
        let legacy = try DeveloperTools.parseWindsurf(Data(#"{"usage":{"messages":500,"usedMessages":125,"flowActions":100,"remainingFlowActions":40}}"#.utf8))
        XCTAssertEqual(legacy.windows.map(\.remaining), [75, 40])
        XCTAssertTrue(legacy.detail?.contains("may be out of date") ?? false)
        XCTAssertThrowsError(try DeveloperTools.parseWindsurf(Data(#"{"usage":{"messages":0,"usedMessages":10}}"#.utf8)))
    }

    func testOpenRouterBudgetIsSeparateFromAllTimeSpend() throws {
        let result = try DeveloperTools.parseOpenRouter(Data(#"{"data":{"limit":20,"limit_remaining":12,"usage":100}}"#.utf8))
        XCTAssertEqual(result.windows.first?.remaining, 60)
        let uncapped = try DeveloperTools.parseOpenRouter(Data(#"{"data":{"limit":null,"limit_remaining":null,"usage":100}}"#.utf8))
        XCTAssertTrue(uncapped.windows.isEmpty)
        XCTAssertEqual(uncapped.detail, "$100.00 used · no key budget set")
        let zero = try DeveloperTools.parseOpenRouter(Data(#"{"data":{"limit":0,"limit_remaining":0,"usage":0}}"#.utf8))
        XCTAssertTrue(zero.windows.isEmpty)
        XCTAssertEqual(zero.detail, "$0.00 key budget · no allowance")
        XCTAssertThrowsError(try DeveloperTools.parseOpenRouter(Data(#"{"data":{"limit":20,"usage":3}}"#.utf8)))
        XCTAssertThrowsError(try DeveloperTools.parseOpenRouter(Data(#"{"data":{"limit":-1,"usage":3}}"#.utf8)))
    }

    func testGitHubRejectsUnsafeRepoPathsAndLinks() throws {
        let message = LocalCommand.failureMessage(command: "gh", data: Data(#"{"message":"Not Found","status":"404"}"#.utf8))
        XCTAssertTrue(message.contains("repository name"))
        XCTAssertTrue(message.contains("private-repository access"))
        XCTAssertTrue(GitHubReader.validRepository("apple/swift"))
        for invalid in ["../secret", "owner/..", "owner/repo?x=y", "https://github.com/a/b", "a/b/c", "a/$(echo secret)"] {
            XCTAssertFalse(GitHubReader.validRepository(invalid), invalid)
        }
        let result = try GitHubReader.parse(
            pulls: Data(#"[{"id":1,"title":"Review me","draft":true,"html_url":"https://github.com/a/b/pull/1"},{"id":2,"html_url":"https://evil.example/"}]"#.utf8),
            runs: Data(#"{"workflow_runs":[{"id":3,"display_title":"Build","status":"completed","conclusion":"failure","html_url":"https://github.com/a/b/actions/runs/3"}]}"#.utf8))
        XCTAssertEqual(result.pullRequests.count, 1)
        XCTAssertEqual(result.pullRequests.first?.state, "Draft")
        XCTAssertEqual(result.runs.first?.state, "failure")
    }

    func testRepositoryInputAcceptsLinksAndSuggestsTheRealOwner() {
        XCTAssertEqual(GitHubReader.normalizeRepository("https://github.com/Tamayaz-io/coachxo/pull/401?x=1"), "Tamayaz-io/coachxo")
        XCTAssertEqual(GitHubReader.normalizeRepository("git@github.com:apple/swift.git"), "apple/swift")
        XCTAssertEqual(GitHubReader.normalizeRepository("  apple/swift  "), "apple/swift")
        XCTAssertEqual(GitHubReader.normalizeRepository("nonsense"), "nonsense")
        let repositories = ["Tamayaz-io/coachxo", "FayezBast/muse", "Tamayaz-io/prime"]
        XCTAssertEqual(GitHubReader.suggestion(for: "tamayaz/coachxo", among: repositories), "Tamayaz-io/coachxo")
        XCTAssertEqual(GitHubReader.suggestion(for: "tamayaz-io/COACHXO", among: repositories), "Tamayaz-io/coachxo")
        XCTAssertNil(GitHubReader.suggestion(for: "Tamayaz-io/coachxo", among: repositories), "An exact match needs no suggestion")
        XCTAssertNil(GitHubReader.suggestion(for: "someone/unknown", among: repositories))
    }

    func testOverviewParsingLinksNotificationsToGitHubPages() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let search = Data(#"{"items":[{"id":7,"number":401,"title":"fix(auth)","draft":false,"html_url":"https://github.com/Tamayaz-io/coachxo/pull/401","repository_url":"https://api.github.com/repos/Tamayaz-io/coachxo","updated_at":"2027-01-15T08:00:00Z"},{"id":8,"html_url":"https://evil.example/x"}]}"#.utf8)
        let notifications = Data(#"[{"id":"1","reason":"review_requested","updated_at":"2027-01-15T09:00:00Z","subject":{"title":"Please review","type":"PullRequest","url":"https://api.github.com/repos/o/r/pulls/12"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}},{"id":"2","reason":"subscribed","subject":{"title":"v1.0","type":"Release","url":"https://api.github.com/repos/o/r/releases/99"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}},{"id":"3","reason":"mention","subject":{"title":"Thread","type":"Discussion","url":null},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}}]"#.utf8)
        let repositories = Data(#"[{"full_name":"Tamayaz-io/coachxo"},{"full_name":"FayezBast/muse"}]"#.utf8)
        let overview = try GitHubReader.parseOverview(login: "fayez", authored: search, reviews: Data("[]".utf8), notifications: notifications, repositories: repositories, now: now.addingTimeInterval(2 * 3600))
        XCTAssertEqual(overview.authored.count, 1, "Links outside github.com are dropped")
        XCTAssertEqual(overview.authored.first?.detail, "Tamayaz-io/coachxo · #401 · 2h ago")
        XCTAssertEqual(overview.notifications.map(\.url.absoluteString), ["https://github.com/o/r/pull/12", "https://github.com/o/r/releases", "https://github.com/o/r"])
        XCTAssertEqual(overview.notifications.first?.state, "Review Requested")
        XCTAssertEqual(overview.repositories, ["Tamayaz-io/coachxo", "FayezBast/muse"])
        XCTAssertTrue(overview.reviewRequests.isEmpty)
    }
}
