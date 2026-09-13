import XCTest
@testable import HoustonCore

final class CloudToolsTests: XCTestCase {
    func testRequestsKeepProviderCredentialsAndProjectFiltersIsolated() throws {
        let vercel = try CloudAPI.deploymentsRequest(projectID: "app & worker", teamID: "team_123", token: "vercel-secret")
        XCTAssertEqual(vercel.url?.host, "api.vercel.com")
        XCTAssertEqual(vercel.value(forHTTPHeaderField: "Authorization"), "Bearer vercel-secret")
        let query = URLComponents(url: vercel.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "projectId" }?.value, "app & worker")
        XCTAssertEqual(query.first { $0.name == "teamId" }?.value, "team_123")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "10")
        let sentry = try CloudAPI.sentryRequest(organization: "acme", project: "api", environment: "prod & staging", token: "sentry-secret")
        XCTAssertEqual(sentry.url?.path, "/api/0/organizations/acme/issues")
        XCTAssertEqual(sentry.url?.host, "sentry.io")
        XCTAssertEqual(sentry.value(forHTTPHeaderField: "Authorization"), "Bearer sentry-secret")
        let sentryQuery = URLComponents(url: sentry.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(sentryQuery.first { $0.name == "project" }?.value, "api")
        XCTAssertEqual(sentryQuery.first { $0.name == "environment" }?.value, "prod & staging")
        let linear = try CloudAPI.linearRequest(projectID: "project-123", token: "lin_api_key")
        XCTAssertEqual(linear.url?.host, "api.linear.app")
        XCTAssertEqual(linear.httpMethod, "POST")
        XCTAssertEqual(linear.value(forHTTPHeaderField: "Authorization"), "lin_api_key", "Personal API keys do not use Bearer")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: linear.httpBody!) as? [String: Any])
        let variables = body["variables"] as! [String: Any]
        let filter = variables["filter"] as! [String: Any]
        XCTAssertNotNil(filter["project"])
        XCTAssertNotNil(filter["state"])
        XCTAssertTrue((body["query"] as? String)?.contains("viewer { assignedIssues") == true)
        XCTAssertFalse(String(decoding: linear.httpBody!, as: UTF8.self).contains("lin_api_key"))
        XCTAssertEqual(Set(CloudProvider.allCases.map(\.secretAccount)).count, 3)
        XCTAssertTrue(CloudProvider.allCases.allSatisfy { $0.secretAccount.hasPrefix("cloud.") })
    }

    func testInvalidInputsAndUnsafeLinksAreRejected() throws {
        XCTAssertThrowsError(try CloudAPI.deploymentsRequest(projectID: "", teamID: "", token: "token"))
        XCTAssertThrowsError(try CloudAPI.sentryRequest(organization: "../evil", project: "app", environment: "", token: "token"))
        XCTAssertThrowsError(try CloudAPI.logsRequest(id: "https://evil.example", teamID: "", token: "token"))
        XCTAssertThrowsError(try CloudAPI.linearRequest(projectID: "", token: "token\r\nX-Header: injected"))
        for value in ["http://linear.app/acme", "file:///tmp/example", "https://linear.app.evil.example/", "https://user@linear.app/", "javascript:alert(1)"] {
            XCTAssertNil(CloudAPI.safeLink(value, domain: "linear.app"), value)
        }
        XCTAssertNotNil(CloudAPI.safeLink("https://acme.sentry.io/issues/1", domain: "sentry.io"))
        XCTAssertEqual(CloudAPI.safeLink("app-123.vercel.app", bareHostname: true)?.scheme, "https")
    }

    func testDeploymentsPreserveNullURLAndUnknownStateWithoutFakeSuccess() throws {
        let value = try CloudAPI.parseDeployments(Data(#"{"deployments":[{"uid":"dpl_1","name":"web","state":"BUILDING","url":null,"created":1700000000000,"meta":{"githubCommitRef":"feat/login"}},{"uid":"dpl_2","name":"api","readyState":"FUTURE_STATE","state":"READY","url":"api.vercel.app"}]}"#.utf8))
        XCTAssertEqual(value.count, 2)
        XCTAssertNil(value[0].url)
        XCTAssertEqual(value[0].branch, "feat/login")
        XCTAssertEqual(value[0].createdAt?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertFalse(value[0].isComplete)
        XCTAssertFalse(value[1].isComplete)
        XCTAssertEqual(value[1].state, "FUTURE_STATE")
        XCTAssertTrue(try CloudAPI.parseDeployments(Data(#"{"deployments":[]}"#.utf8)).isEmpty)
        XCTAssertThrowsError(try CloudAPI.parseDeployments(Data(#"{"error":"denied"}"#.utf8)))
    }

    func testSentryAndLinearParseRealCountsAndEmptyResponses() throws {
        let sentry = try CloudAPI.parseSentry(Data(#"[{"id":"12","shortId":"API-12","title":"Connection failed","status":"unresolved","priority":"high","count":"143","userCount":9,"permalink":"https://acme.sentry.io/issues/12/"}]"#.utf8))
        XCTAssertEqual(sentry.first?.eventCount, 143)
        XCTAssertEqual(sentry.first?.userCount, 9)
        XCTAssertEqual(sentry.first?.priority, "high")
        XCTAssertTrue(try CloudAPI.parseSentry(Data("[]".utf8)).isEmpty)
        XCTAssertThrowsError(try CloudAPI.parseSentry(Data("{}".utf8)))
        let linear = try CloudAPI.parseLinear(Data(#"{"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"id1","identifier":"ENG-12","title":"Ship login","url":"https://linear.app/acme/issue/ENG-12","priority":2,"priorityLabel":"High","state":{"name":"In Progress","type":"started"}}]}}}}"#.utf8))
        XCTAssertEqual(linear.first?.identifier, "ENG-12")
        XCTAssertEqual(linear.first?.state, "In Progress")
        XCTAssertNil(linear.first?.userCount)
        XCTAssertTrue(try CloudAPI.parseLinear(Data(#"{"data":{"viewer":{"assignedIssues":{"nodes":[]}}}}"#.utf8)).isEmpty)
        XCTAssertThrowsError(try CloudAPI.parseLinear(Data(#"{"data":{"viewer":{"assignedIssues":{"nodes":[]}}},"errors":[{"message":"partial failure"}]}"#.utf8)))
    }

    func testBuildLogsAreBoundedInReadingOrderAndHTTPFailuresStayFailures() throws {
        let logs = try CloudAPI.parseLogs(Data(#"[{"payload":{"text":"last"}},{"payload":{"text":"first"}}]"#.utf8))
        XCTAssertEqual(logs, "first\nlast")
        XCTAssertTrue(try CloudAPI.parseLogs(Data("[]".utf8)).isEmpty)
        XCTAssertThrowsError(try CloudAPI.parseLogs(Data("{}".utf8)))
        for (code, error) in [(401, CloudAPIError.unauthorized), (403, .forbidden), (429, .rateLimited), (302, .http(302)), (500, .http(500))] {
            XCTAssertThrowsError(try CloudAPI.validateStatus(code)) { XCTAssertEqual($0 as? CloudAPIError, error) }
        }
    }

    func testSentryVerificationRequiresAuthenticatedReadableScopes() async throws {
        let valid = CloudAPI { _ in Data(#"{"auth":{"scopes":["event:read"]},"user":{"id":"1"}}"#.utf8) }
        try await valid.verify(provider: .sentry, token: "token")
        for fixture in [#"{"auth":null,"user":null}"#, #"{"auth":{"scopes":["org:read"]}}"#] {
            let invalid = CloudAPI { _ in Data(fixture.utf8) }
            do {
                try await invalid.verify(provider: .sentry, token: "token")
                XCTFail("An unauthenticated or insufficiently scoped response must not verify")
            } catch { XCTAssertTrue(error is CloudAPIError) }
        }
    }
}
