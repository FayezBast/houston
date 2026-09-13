import XCTest
import SQLite3
@testable import HoustonCore

@MainActor
final class CursorAccountTests: XCTestCase {
    func testMonthlyPercentagesUsePercentUnitsAndServerReset() throws {
        let data = Data(#"{"billingCycleEnd":"2030-01-15T12:00:00.000Z","individualUsage":{"plan":{"enabled":true,"totalPercentUsed":0.36,"autoPercentUsed":0.12,"apiPercentUsed":0.60,"used":99,"limit":100}}}"#.utf8)
        let snapshot = try CursorAccount.parseUsage(data)
        XCTAssertEqual(snapshot.windows.map(\.used), [0.36, 0.12, 0.60])
        XCTAssertEqual(snapshot.windows.first?.remaining ?? 0, 99.64, accuracy: 0.00001)
        XCTAssertEqual(snapshot.windows.first?.resetsAt, DeveloperTools.date("2030-01-15T12:00:00Z"))
        let invalidReset = try CursorAccount.parseUsage(Data(#"{"billingCycleEnd":1e100,"individualUsage":{"plan":{"totalPercentUsed":50}}}"#.utf8))
        XCTAssertNil(invalidReset.windows.first?.resetsAt, "Unexpected timestamp units must not reach countdown rendering")
    }

    func testLegacyFreePlanUsesRequestCountInsteadOfTokenNumbers() throws {
        let summary = Data(#"{"membershipType":"hobby","billingCycleEnd":"2030-01-15T12:00:00Z","individualUsage":{"plan":{"totalPercentUsed":0,"autoPercentUsed":0}}}"#.utf8)
        let legacy = Data(#"{"gpt-4":{"numRequests":2,"numRequestsTotal":7,"maxRequestUsage":50}}"#.utf8)
        let result = try CursorAccount.parseUsage(summary, legacy: legacy)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.name, "Requests")
        XCTAssertEqual(result.windows.first?.remaining, 86)
        XCTAssertEqual(result.detail, "7 of 50 requests used")
        let emptySummary = try CursorAccount.parseUsage(Data("{}".utf8), legacy: legacy)
        XCTAssertEqual(emptySummary.windows.first?.remaining, 86)
    }

    func testCentsAndTeamAllowancesRemainSeparateFromPercentages() throws {
        let personal = try CursorAccount.parseUsage(Data(#"{"individualUsage":{"overall":{"used":1000,"limit":4000},"onDemand":{"enabled":true,"used":500,"limit":2000}}}"#.utf8))
        XCTAssertEqual(personal.windows.map(\.remaining), [75, 75])
        XCTAssertEqual(personal.windows.map(\.name), ["Personal allowance", "Extra usage"])
        XCTAssertEqual(personal.detail, "Extra usage: $5.00 spent")
        let pooled = try CursorAccount.parseUsage(Data(#"{"teamUsage":{"pooled":{"remaining":3000,"limit":4000}}}"#.utf8))
        XCTAssertEqual(pooled.windows.first?.remaining, 75)
        XCTAssertEqual(pooled.windows.first?.name, "Shared team allowance")
    }

    func testInvalidQuotasDoNotCreateAFullMeter() throws {
        for value in [#"{}"#, #"{"individualUsage":{"plan":{"used":0,"limit":0}}}"#,
                      #"{"individualUsage":{"plan":{"totalPercentUsed":true}}}"#,
                      #"{"individualUsage":{"plan":{"totalPercentUsed":-1}}}"#,
                      #"{"individualUsage":{"plan":{"enabled":false,"totalPercentUsed":0}}}"#] {
            XCTAssertThrowsError(try CursorAccount.parseUsage(Data(value.utf8)), value)
        }
        XCTAssertNil(CursorAccount.number(Double.infinity))
        XCTAssertNil(CursorAccount.number(Double.nan))
        XCTAssertNil(CursorAccount.percentage(["used": Double.greatestFiniteMagnitude, "limit": 0.00001]))
        let unlimited = try CursorAccount.parseUsage(Data(#"{"isUnlimited":true}"#.utf8))
        XCTAssertTrue(unlimited.windows.isEmpty)
        XCTAssertEqual(unlimited.detail, "Unlimited allowance")
    }

    func testOnlyMatchingUnexpiredSessionCookiesAreSelected() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func cookie(_ name: String, domain: String = ".cursor.com", expires: Date? = nil, path: String = "/") -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "fixture", .domain: domain, .path: path, .secure: true]
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        let header = try CursorAccount.cookieHeader(from: [cookie("WorkosCursorSessionToken"),
            cookie("analytics"), cookie("next-auth.session-token", domain: ".notcursor.com"),
            cookie("wos-session", expires: now.addingTimeInterval(-1)), cookie("authjs.session-token", path: "/unrelated")], now: now)
        XCTAssertEqual(header, "WorkosCursorSessionToken=fixture")
        XCTAssertThrowsError(try CursorAccount.cookieHeader(from: [cookie("analytics")], now: now))
        XCTAssertEqual(try CursorAccount.validateCookieHeader("next-auth.session-token.0=first; next-auth.session-token.1=second"),
                       "next-auth.session-token.0=first; next-auth.session-token.1=second")
        for invalid in ["", "WorkosCursorSessionToken=one\r\nX-Test:bad", "WorkosCursorSessionToken=\0bad", "analytics=abc", "wos-session="] {
            XCTAssertThrowsError(try CursorAccount.validateCookieHeader(invalid))
        }
    }

    func testLocalTokenExpiryValidationAndSQLiteEncodings() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = jwt(["sub": "auth0|user_fixture", "exp": now.timeIntervalSince1970 + 3600])
        XCTAssertEqual(try CursorAccount.cookieHeader(accessToken: token, now: now), "WorkosCursorSessionToken=user_fixture%3A%3A" + token)
        let invalidPayloads: [[String: Any]] = [["sub": "auth0|user_fixture", "exp": now.timeIntervalSince1970 + 30],
            ["sub": "bad;cookie", "exp": now.timeIntervalSince1970 + 3600], ["sub": "user_fixture", "exp": true]]
        for payload in invalidPayloads {
            XCTAssertThrowsError(try CursorAccount.cookieHeader(accessToken: jwt(payload), now: now))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for encoding in [String.Encoding.utf8, .utf16LittleEndian] {
            let file = folder.appendingPathComponent("\(encoding.rawValue).vscdb")
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil), SQLITE_OK)
            let hex = token.data(using: encoding)!.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sqlite3_exec(database, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', X'\(hex)')", nil, nil, nil), SQLITE_OK)
            sqlite3_close(database)
            XCTAssertEqual(try CursorAccount.localCookieHeader(from: file, now: now), "WorkosCursorSessionToken=user_fixture%3A%3A" + token)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-wal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-shm"))
        }
    }

    func testReaderRequestsRealEndpointsAndUsesFreePlanFallback() async throws {
        let session = mockSession { request in
            XCTAssertEqual(request.url?.host, "cursor.com")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            switch request.url?.path {
            case "/api/usage-summary": return (200, #"{"membershipType":"hobby"}"#)
            case "/api/auth/me": return (200, #"{"sub":"user_fixture"}"#)
            case "/api/usage":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "user", value: "user_fixture")])
                return (200, #"{"gpt-4":{"numRequests":10,"maxRequestUsage":50}}"#)
            default: XCTFail("Unexpected endpoint"); return (404, "{}")
            }
        }
        defer { session.invalidateAndCancel() }
        let result = try await CursorAccount.readUsage(cookieHeader: "WorkosCursorSessionToken=fixture", session: session)
        XCTAssertEqual(result.windows.first?.remaining, 80)
    }

    func testReaderMapsAuthenticationAndRateLimitFailuresWithoutLeakingBody() async throws {
        for status in [302, 401, 403, 429, 500] {
            let session = mockSession { _ in (status, "PRIVATE_RESPONSE") }
            do {
                _ = try await CursorAccount.readUsage(cookieHeader: "WorkosCursorSessionToken=fixture", session: session)
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE_RESPONSE"))
                XCTAssertTrue(error.localizedDescription.contains(status == 429 ? "limiting" : status == 500 ? "HTTP 500" : "sign-in"))
            }
            session.invalidateAndCancel()
        }
        let session = mockSession { request in
            request.url?.path == "/api/usage-summary" ? (200, #"{"individualUsage":{"plan":{"totalPercentUsed":25}}}"#) : (503, "{}")
        }
        defer { session.invalidateAndCancel() }
        let result = try await CursorAccount.readUsage(cookieHeader: "WorkosCursorSessionToken=fixture", session: session)
        XCTAssertEqual(result.windows.first?.remaining, 75, "Optional legacy endpoint failure must preserve valid modern usage")
    }

    private func jwt(_ payload: [String: Any]) -> String {
        let encoded = try! JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture.\(encoded).signature"
    }

    private func mockSession(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> URLSession {
        CursorFixtureProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorFixtureProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class CursorFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cursor.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
