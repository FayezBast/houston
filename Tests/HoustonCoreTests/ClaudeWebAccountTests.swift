import XCTest
@testable import HoustonCore

@MainActor
final class ClaudeWebAccountTests: XCTestCase {
    private let organizationID = "11111111-2222-3333-4444-555555555555"

    func testOnlyMatchingUnexpiredSessionCookieIsRetained() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func cookie(_ name: String = "sessionKey", value: String = "sk-ant-fixture", domain: String = ".claude.ai", path: String = "/", expires: Date? = nil) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        let result = try ClaudeWebAccount.cookieHeader(from: [cookie(), cookie("analytics"), cookie(domain: "notclaude.ai"),
            cookie(path: "/unrelated"), cookie(value: "sk-ant-child-path", path: "/api/organizations/"),
            cookie(value: "sk-ant-expired", expires: now.addingTimeInterval(-1))], now: now)
        XCTAssertEqual(result, "sessionKey=sk-ant-fixture")
        XCTAssertThrowsError(try ClaudeWebAccount.cookieHeader(from: [cookie("analytics")], now: now))
        XCTAssertThrowsError(try ClaudeWebAccount.cookieHeader(from: [cookie(), cookie(value: "sk-ant-other")], now: now))
    }

    func testOrganizationsPreserveMultipleChoicesAndExcludeAPIOnly() async throws {
        let session = mockSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://claude.ai/api/organizations")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-ant-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            return (200, #"[{"uuid":"11111111-2222-3333-4444-555555555555","name":"Personal","capabilities":["chat"]},{"uuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"Work","capabilities":["chat","api"]},{"uuid":"00000000-0000-0000-0000-000000000000","name":"API","capabilities":["api"]},{"uuid":"12345678-0000-0000-0000-000000000000","name":"Billing","capabilities":["api","billing"]},{"uuid":"../../other","name":"Invalid"}]"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let organizations = try await ClaudeWebAccount.organizations(cookieHeader: "sessionKey=sk-ant-fixture", session: session)
        XCTAssertEqual(organizations.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(organizations.first?.id, organizationID)
    }

    func testSavedCredentialUsesOnlyPinnedOrganizationAndRealUsageParser() async throws {
        let credential = try ClaudeWebAccount.credential(cookieHeader: "sessionKey=sk-ant-fixture", organizationID: organizationID)
        let fields = try DeveloperTools.object(Data(credential.utf8))
        XCTAssertEqual(Set(fields.keys), ["cookieHeader", "organizationID"])
        let session = mockSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://claude.ai/api/organizations/11111111-2222-3333-4444-555555555555/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-ant-fixture")
            return (200, #"{"five_hour":{"utilization":31,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":48}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let usage = try await ClaudeWebAccount.readUsage(credential: Data(credential.utf8), session: session)
        XCTAssertEqual(usage.windows.map(\.remaining), [69, 52])
        XCTAssertEqual(usage.detail, "Connected to Claude web")
        XCTAssertNotNil(usage.windows.first?.resetsAt)
        XCTAssertEqual(usage.accountID, UsageAccountIdentity.scope(provider: "claude-web", identity: organizationID + ":sessionKey=sk-ant-fixture"))
    }

    func testCredentialValidationRejectsHeaderAndPathInjection() async throws {
        for header in ["", "sessionKey=other", "sessionKey=sk-ant-x\r\nOther: injected", "sessionKey=sk-ant-x; analytics=secret"] {
            XCTAssertThrowsError(try ClaudeWebAccount.credential(cookieHeader: header, organizationID: organizationID))
        }
        for id in ["../../account", "https://other.example", "", "bad?query=1"] {
            XCTAssertThrowsError(try ClaudeWebAccount.credential(cookieHeader: "sessionKey=sk-ant-fixture", organizationID: id))
        }
        do {
            _ = try await ClaudeWebAccount.readUsage(credential: Data(#"{"cookieHeader":"sessionKey=sk-ant-fixture"}"#.utf8))
            XCTFail("Missing pinned organization must fail before making a request")
        } catch { XCTAssertTrue(error.localizedDescription.contains("invalid")) }
    }

    func testHTTPFailuresKeepPrivateBodiesOutOfErrors() async throws {
        for status in [302, 401, 403, 404, 429, 500] {
            let session = mockSession { _ in (status, "PRIVATE_RESPONSE", [:]) }
            do {
                _ = try await ClaudeWebAccount.readUsage(cookieHeader: "sessionKey=sk-ant-fixture", organizationID: organizationID, session: session)
                XCTFail("HTTP \(status) must fail")
            } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_RESPONSE")) }
            session.invalidateAndCancel()
        }
        let challenged = mockSession { _ in (403, "PRIVATE_RESPONSE", ["cf-mitigated": "challenge"]) }
        defer { challenged.invalidateAndCancel() }
        do {
            _ = try await ClaudeWebAccount.organizations(cookieHeader: "sessionKey=sk-ant-fixture", session: challenged)
            XCTFail("Challenge must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("security check")) }
    }

    func testRedirectDelegateRefusesEvenSameHostRedirects() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let address = URL(string: "https://claude.ai/api/organizations")!
        let task = session.dataTask(with: address)
        for target in ["https://claude.ai/login", "https://other.example/"] {
            let response = HTTPURLResponse(url: address, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!
            ClaudeWebNoRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: target)!)) { XCTAssertNil($0) }
        }
    }

    private func mockSession(_ handler: @escaping @Sendable (URLRequest) -> (Int, String, [String: String])) -> URLSession {
        ClaudeWebFixtureProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeWebFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ClaudeWebFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body, headers) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
