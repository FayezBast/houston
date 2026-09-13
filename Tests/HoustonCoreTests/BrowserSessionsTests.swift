import XCTest
import SQLite3
import SweetCookieKit
@testable import HoustonCore

final class BrowserSessionsTests: XCTestCase {
    func testImportFromProfileFiltersDomainsNamesPathsAndExpiryWithoutChangingDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cookies.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let sql = """
        CREATE TABLE moz_cookies(host TEXT, name TEXT, path TEXT, value TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER);
        INSERT INTO moz_cookies VALUES
        ('.claude.ai','sessionKey','/','sk-ant-claude',4102444800,1,1),
        ('claude.ai','analytics','/','unrelated',4102444800,1,0),
        ('other.claude.ai','sessionKey','/','sk-ant-wrong-subdomain',4102444800,1,1),
        ('claude.ai.evil.test','sessionKey','/','sk-ant-wrong-host',4102444800,1,1),
        ('claude.ai','sessionKey','/','sk-ant-expired',1,1,1),
        ('claude.ai','sessionKey','/private','sk-ant-wrong-path',4102444800,1,1),
        ('.cursor.com','WorkosCursorSessionToken','/','cursor-fixture',4102444800,1,1),
        ('cursor.com','analytics','/','unrelated',4102444800,1,0);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: file)
        let source = source("Fixture profile", file: file)
        XCTAssertEqual(try BrowserSessions.session(provider: .claude, source: source).cookieHeader, "sessionKey=sk-ant-claude")
        XCTAssertEqual(try BrowserSessions.session(provider: .cursor, source: source).cookieHeader, "WorkosCursorSessionToken=cursor-fixture")
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["cookies.sqlite"])
    }

    func testScanKeepsDifferentProfilesSeparateAndContinuesAfterDeniedSource() {
        let result = BrowserSessions.scan(provider: .claude, sources: [source("Denied"), source("Personal"), source("Work")]) { source in
            if source.label == "Denied" { throw UsageError.unavailable("PRIVATE ERROR") }
            return "sessionKey=sk-ant-\(source.label)"
        }
        XCTAssertEqual(result.sessions.map(\.source.label), ["Personal", "Work"])
        XCTAssertEqual(result.sessions.map(\.cookieHeader), ["sessionKey=sk-ant-Personal", "sessionKey=sk-ant-Work"])
        XCTAssertEqual(result.inaccessible, ["Denied"])
    }

    func testIdenticalSessionsAreOneChoice() {
        let result = BrowserSessions.scan(provider: .cursor, sources: [source("Chrome"), source("Chrome Network"), source("Firefox")]) { _ in
            "WorkosCursorSessionToken=same-session"
        }
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.source.label, "Chrome")
    }

    func testConflictingCursorCookiesAreRejectedAndIdenticalOnesCollapse() throws {
        let first = cookie(name: "WorkosCursorSessionToken", value: "first", domain: "cursor.com")
        let second = cookie(name: "WorkosCursorSessionToken", value: "second", domain: ".cursor.com")
        XCTAssertThrowsError(try BrowserSessions.cookieHeader(provider: .cursor, cookies: [first, second]))
        XCTAssertEqual(try BrowserSessions.cookieHeader(provider: .cursor, cookies: [first, first]), "WorkosCursorSessionToken=first")
    }

    func testReadErrorsDoNotExposeDatabasePathsOrRawErrors() {
        XCTAssertThrowsError(try BrowserSessions.session(provider: .claude, source: source("Fixture profile", file: URL(fileURLWithPath: "/private/PRIVATE_PATH/cookies.sqlite")))) { error in
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_PATH"))
            XCTAssertTrue(error.localizedDescription.contains("Fixture profile"))
        }
    }

    private func source(_ label: String, file: URL? = nil) -> BrowserSessions.Source {
        BrowserSessions.Source(label: label, store: BrowserCookieStore(browser: .firefox,
            profile: BrowserProfile(id: label, name: label), kind: .primary, label: label, databaseURL: file))
    }

    private func cookie(name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])!
    }
}
