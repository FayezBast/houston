import Foundation
import XCTest
@testable import HoustonCore

final class GeminiAccountTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let client = ["GEMINI_OAUTH_CLIENT_ID": "test-client", "GEMINI_OAUTH_CLIENT_SECRET": "test-secret"]
    private let quota = #"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.4}]}"#

    private func credentials(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("oauth_creds.json")
        try Data(text.utf8).write(to: file)
        return file
    }

    func testDiscoversProjectAndSendsItInQuotaRequest() async throws {
        let file = try credentials(#"{"access_token":"access"}"#)
        let server = Responses([(#"{"cloudaicompanionProject":"managed-project","paidTier":{"name":"Enterprise"}}"#, 200), (quota, 200)])
        let result = try await GeminiAccount.readUsage(credentialsFile: file, environment: [:], now: now, load: { try await server.load($0) })
        XCTAssertEqual(result.windows.first?.remaining, 40)
        XCTAssertEqual(result.detail, "Enterprise")
        XCTAssertEqual(result.accountID, UsageAccountIdentity.scope(provider: "gemini", identity: "access:managed-project"))
        let requests = await server.requests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, ["https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer access" })
        let body = try DeveloperTools.object(requests[1].httpBody!)
        XCTAssertEqual(body["project"] as? String, "managed-project")
    }

    func testConfiguredProjectUsedWhenServiceOmitsIt() async throws {
        let file = try credentials(#"{"access_token":"access"}"#)
        let server = Responses([(#"{"currentTier":{"id":"standard-tier"}}"#, 200), (quota, 200)])
        _ = try await GeminiAccount.readUsage(credentialsFile: file, environment: ["GOOGLE_CLOUD_PROJECT": "organization-project"], now: now, load: { try await server.load($0) })
        let requests = await server.requests
        XCTAssertEqual(try DeveloperTools.object(requests[0].httpBody!)["cloudaicompanionProject"] as? String, "organization-project")
        XCTAssertEqual(try DeveloperTools.object(requests[1].httpBody!)["project"] as? String, "organization-project")
    }

    func testExpiredOAuthRefreshesAndReusesTokenWithoutChangingCLIFile() async throws {
        let file = try credentials(#"{"access_token":"old","refresh_token":"refresh+&= token","expiry_date":1000}"#)
        let original = try Data(contentsOf: file)
        let account = #"{"cloudaicompanionProject":{"id":"managed-project"}}"#
        let server = Responses([(#"{"access_token":"fresh","expires_in":3600}"#, 200), (account, 200), (quota, 200), (account, 200), (quota, 200)])
        for _ in 0..<2 {
            let snapshot = try await GeminiAccount.readUsage(credentialsFile: file, environment: client, now: now, load: { try await server.load($0) })
            XCTAssertEqual(snapshot.accountID, UsageAccountIdentity.scope(provider: "gemini", identity: "refresh+&= token:managed-project"))
        }
        let requests = await server.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertTrue(String(data: requests[0].httpBody!, encoding: .utf8)!.contains("refresh_token=refresh%2B%26%3D%20token"))
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnauthorizedRefreshesOnceAndRetriesDiscovery() async throws {
        let file = try credentials(#"{"access_token":"rejected","refresh_token":"retry-refresh"}"#)
        let server = Responses([("{}", 401), (#"{"access_token":"retried","expires_in":3600}"#, 200), (#"{"cloudaicompanionProject":"project"}"#, 200), (quota, 200)])
        _ = try await GeminiAccount.readUsage(credentialsFile: file, environment: client, now: now, load: { try await server.load($0) })
        let requests = await server.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer rejected")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer retried")
    }

    func testRevokedRefreshHasActionableErrorAndNoQuotaCalls() async throws {
        let file = try credentials(#"{"refresh_token":"revoked-refresh"}"#)
        let server = Responses([(#"{"error":"invalid_grant","error_description":"sensitive server details"}"#, 400)])
        do {
            _ = try await GeminiAccount.readUsage(credentialsFile: file, environment: client, now: now, load: { try await server.load($0) })
            XCTFail("Revoked refresh must not return a snapshot")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sign in again"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive"))
        }
        let count = await server.requests.count
        XCTAssertEqual(count, 1)
    }

    func testUnsupportedConsumerDoesNotFetchQuota() async throws {
        let file = try credentials(#"{"access_token":"consumer"}"#)
        let server = Responses([(#"{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#, 200)])
        do {
            _ = try await GeminiAccount.readUsage(credentialsFile: file, environment: [:], now: now, load: { try await server.load($0) })
            XCTFail("Consumer deprecation must be explained")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Antigravity")) }
        let count = await server.requests.count
        XCTAssertEqual(count, 1)
    }

    func testMissingProjectNeverSendsEmptyQuotaRequest() async throws {
        let file = try credentials(#"{"access_token":"no-project"}"#)
        let server = Responses([("{}", 200)])
        do {
            _ = try await GeminiAccount.readUsage(credentialsFile: file, environment: [:], now: now, load: { try await server.load($0) })
            XCTFail("Must resolve a quota project first")
        } catch { XCTAssertTrue(error.localizedDescription.contains("quota project")) }
        let count = await server.requests.count
        XCTAssertEqual(count, 1)
    }

    func testDifferentCLIAuthModeDoesNotReuseAnOldGoogleAccount() async throws {
        let file = try credentials(#"{"access_token":"old-google-account"}"#)
        try Data(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#.utf8)
            .write(to: file.deletingLastPathComponent().appendingPathComponent("settings.json"))
        let server = Responses([])
        do {
            _ = try await GeminiAccount.readUsage(credentialsFile: file, environment: [:], now: now, load: { try await server.load($0) })
            XCTFail("Must not reuse Google credentials while CLI uses an API key")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API-key")) }
        let count = await server.requests.count
        XCTAssertEqual(count, 0)
    }

    func testReadsClientConfigurationFromInstalledCLIFile() throws {
        let source = "const OAUTH_CLIENT_ID = 'client.apps.googleusercontent.com';\nconst OAUTH_CLIENT_SECRET = \"public-installed-client\";"
        let file = try credentials(source)
        XCTAssertEqual(GeminiAccount.oauthClient(environment: ["GEMINI_OAUTH2_JS_PATH": file.path]),
                       GeminiAccount.OAuthClient(id: "client.apps.googleusercontent.com", secret: "public-installed-client"))
        XCTAssertNil(GeminiAccount.parseOAuthClient("const SOME_OTHER_CLIENT_ID = 'wrong';"))
    }

    private actor Responses {
        var requests: [URLRequest] = []
        var replies: [(String, Int)]
        init(_ replies: [(String, Int)]) { self.replies = replies }
        func load(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw URLError(.badServerResponse) }
            let (body, status) = replies.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
