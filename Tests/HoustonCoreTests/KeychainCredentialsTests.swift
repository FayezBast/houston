import XCTest
import Security
@testable import HoustonCore

final class KeychainCredentialsTests: XCTestCase {
    func testAutomaticReadsDisableLegacyKeychainDialogsAndReuseAuthorizedCredential() throws {
        var original: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        defer { SecKeychainSetUserInteractionAllowed(original.boolValue) }
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)
        var reads = 0
        let credentials = KeychainCredentialStore(service: "houston.test", copyMatching: { query, result in
            reads += 1
            var allowed: DarwinBoolean = true
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertFalse(allowed.boolValue, "A timer read must suppress legacy macOS Keychain dialogs, too")
            let query = query as! [String: Any]
            XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
            result?.pointee = Data("fixture".utf8) as CFData
            return errSecSuccess
        })
        for _ in 0..<12 {
            XCTAssertEqual(try credentials.readIfPresent(account: "personal"), Data("fixture".utf8))
        }
        XCTAssertEqual(reads, 1, "Five-minute refreshes should reuse the credential after authorization")
        var restored: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertTrue(restored.boolValue)
    }

    func testExplicitAuthorizationIsRememberedAndDeniedAccountNeverFallsBack() throws {
        var reads = 0
        var deny = false
        let credentials = KeychainCredentialStore(service: "houston.test", copyMatching: { query, result in
            reads += 1
            var allowed: DarwinBoolean = false
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            if deny {
                XCTAssertFalse(allowed.boolValue)
                return errSecInteractionNotAllowed
            }
            XCTAssertTrue(allowed.boolValue, "Only the explicit connection check permits authorization")
            result?.pointee = Data("authorized".utf8) as CFData
            return errSecSuccess
        })
        XCTAssertNotNil(try credentials.readIfPresent(account: "personal", allowInteraction: true))
        deny = true
        XCTAssertEqual(try credentials.readIfPresent(account: "personal"), Data("authorized".utf8))
        XCTAssertThrowsError(try credentials.readIfPresent(account: "work"))
        XCTAssertEqual(reads, 2)
    }

    func testSavedCredentialsReplaceCacheOnlyAfterSuccessfulWriteAndRemoval() throws {
        var stored: Data?
        var reject = false
        var reads = 0
        let credentials = KeychainCredentialStore(service: "houston.test", copyMatching: { _, result in
            reads += 1
            guard let stored else { return errSecItemNotFound }
            result?.pointee = stored as CFData
            return errSecSuccess
        }, update: { _, attributes in
            if reject { return errSecAuthFailed }
            guard stored != nil else { return errSecItemNotFound }
            stored = (attributes as! [String: Any])[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { attributes, _ in
            stored = (attributes as! [String: Any])[kSecValueData as String] as? Data
            return errSecSuccess
        }, delete: { _ in
            if reject { return errSecAuthFailed }
            stored = nil
            return errSecSuccess
        })
        try credentials.save("first", account: "personal")
        XCTAssertEqual(try credentials.readIfPresent(account: "personal"), Data("first".utf8))
        try credentials.save("replacement", account: "personal")
        XCTAssertEqual(try credentials.readIfPresent(account: "personal"), Data("replacement".utf8))
        reject = true
        XCTAssertThrowsError(try credentials.save("failed", account: "personal"))
        XCTAssertThrowsError(try credentials.remove(account: "personal"))
        XCTAssertEqual(try credentials.readIfPresent(account: "personal"), Data("replacement".utf8))
        XCTAssertEqual(reads, 0, "Connecting already supplied the credential; polling needs no Keychain read")
        reject = false
        try credentials.remove(account: "personal")
        XCTAssertNil(try credentials.readIfPresent(account: "personal"))
    }

    func testClaudeCacheRechecksExpiredOrInvalidTokensAndExplicitChecksBypassCache() throws {
        var reads = 0
        let credentials = KeychainCredentialStore(service: "houston.test", cacheLifetime: 1800, copyMatching: { _, result in
            reads += 1
            result?.pointee = Data("token-\(reads)".utf8) as CFData
            return errSecSuccess
        })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(try credentials.readIfPresent(account: nil, now: now), Data("token-1".utf8))
        XCTAssertEqual(try credentials.readIfPresent(account: nil, now: now.addingTimeInterval(300)), Data("token-1".utf8))
        XCTAssertEqual(try credentials.readIfPresent(account: nil, now: now.addingTimeInterval(1800)), Data("token-2".utf8))
        XCTAssertEqual(try credentials.readIfPresent(account: nil, now: now.addingTimeInterval(1801), isValid: { _ in false }), Data("token-3".utf8))
        XCTAssertEqual(try credentials.readIfPresent(account: nil, allowInteraction: true, now: now.addingTimeInterval(1802)), Data("token-4".utf8))
        credentials.invalidate(account: nil)
        XCTAssertEqual(try credentials.readIfPresent(account: nil, now: now.addingTimeInterval(1803)), Data("token-5".utf8))
    }
}
