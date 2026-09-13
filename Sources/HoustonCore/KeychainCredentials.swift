import Foundation
import Security
import LocalAuthentication

enum KeychainAccess {
    // Legacy Keychain interaction is process-wide. Every synchronous Houston read/write/import uses this lock.
    private static let lock = NSRecursiveLock()

    static func perform<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowInteraction) == errSecSuccess else {
            throw UsageError.unavailable("Keychain access is temporarily unavailable. Try Check connection again.")
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }
}

struct KeychainReadError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain access is needed. Click Check connection to allow it. Choose Always Allow to remember this app." }
}

/// One serialized boundary for Houston-owned credentials and Claude Code's sign-in.
final class KeychainCredentialStore: @unchecked Sendable {
    private let service: String
    private let cacheLifetime: TimeInterval
    private var cache: [String: (data: Data, savedAt: Date)] = [:]
    private let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let update: (CFDictionary, CFDictionary) -> OSStatus
    private let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let delete: (CFDictionary) -> OSStatus

    init(service: String, cacheLifetime: TimeInterval = .infinity,
         copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching,
         update: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
         add: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd,
         delete: @escaping (CFDictionary) -> OSStatus = SecItemDelete) {
        self.service = service
        self.cacheLifetime = cacheLifetime
        self.copyMatching = copyMatching
        self.update = update
        self.add = add
        self.delete = delete
    }

    private func query(account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        query[kSecAttrAccount as String] = account
        return query
    }

    /// Only a missing item returns nil; denied access must never select a different account.
    func readIfPresent(account: String?, allowInteraction: Bool = false, now: Date = .now,
                       isValid: (Data) -> Bool = { _ in true }) throws -> Data? {
        try KeychainAccess.perform(allowInteraction: allowInteraction) {
            if !allowInteraction, let saved = cache[account ?? ""],
               now.timeIntervalSince(saved.savedAt) < cacheLifetime, isValid(saved.data) { return saved.data }
            var query = query(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if !allowInteraction {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
                query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            }
            var result: CFTypeRef?
            let status = copyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { cache[account ?? ""] = nil; return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainReadError(status: status)
            }
            cache[account ?? ""] = (data, now)
            return data
        }
    }

    func save(_ secret: String, account: String) throws {
        try KeychainAccess.perform(allowInteraction: true) {
            let query = query(account: account)
            let data = Data(secret.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            var status = update(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = add(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw UsageError.unavailable("Could not save the key in macOS Keychain.") }
            cache[account] = (data, .now)
        }
    }

    func remove(account: String) throws {
        try KeychainAccess.perform(allowInteraction: true) {
            let status = delete(query(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw UsageError.unavailable("Could not remove the saved connection from macOS Keychain.")
            }
            cache[account] = nil
        }
    }

    func invalidate(account: String?) {
        try? KeychainAccess.perform(allowInteraction: false) { cache[account ?? ""] = nil }
    }
}
