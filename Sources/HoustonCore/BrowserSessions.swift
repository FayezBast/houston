import Foundation
import SweetCookieKit

/// Imports only the selected provider's session, keeping browser profiles separate.
public enum BrowserSessions {
    public enum Provider: String, Sendable {
        case claude = "Claude", cursor = "Cursor"
        var domain: String { self == .claude ? "claude.ai" : "cursor.com" }
    }

    public struct Source: Sendable {
        public let label: String
        let store: BrowserCookieStore
    }

    public struct Session: Sendable {
        public let source: Source
        public let cookieHeader: String
    }

    public struct Scan: Sendable {
        public let sessions: [Session]
        public let inaccessible: [String]
    }

    public static func sources() -> [Source] {
        BrowserCookieClient().stores(in: Browser.defaultImportOrder).map { Source(label: $0.label, store: $0) }
    }

    /// A connection-window preflight never opens Keychain permission dialogs.
    public static func scan(provider: Provider, sources: [Source]) -> Scan {
        scan(provider: provider, sources: sources) { source in
            try session(provider: provider, source: source).cookieHeader
        }
    }

    static func scan(provider: Provider, sources: [Source], read: (Source) throws -> String) -> Scan {
        var sessions: [Session] = []
        var inaccessible: [String] = []
        var seen = Set<String>()
        for source in sources {
            guard !Task.isCancelled else { break }
            do {
                let header = try read(source)
                // Identical sessions may appear in both Chromium stores or multiple browsers.
                if seen.insert(header).inserted { sessions.append(Session(source: source, cookieHeader: header)) }
            } catch {
                inaccessible.append(source.label)
            }
        }
        return Scan(sessions: sessions, inaccessible: inaccessible)
    }

    /// Interaction is enabled only after the user chooses a browser source explicitly.
    public static func session(provider: Provider, source: Source, allowInteraction: Bool = false) throws -> Session {
        let read = {
            try BrowserCookieClient().cookies(
                matching: BrowserCookieQuery(domains: [provider.domain], domainMatch: .exact), in: source.store)
        }
        let cookies: [HTTPCookie]
        do {
            cookies = try allowInteraction ? read() : BrowserCookieKeychainAccessGate.withUserInteractionDisallowed(read)
        } catch let error as BrowserCookieError {
            if case .accessDenied = error {
                let permission = source.store.browser == .safari
                    ? "Safari may require Full Disk Access for Houston in System Settings → Privacy & Security."
                    : "macOS needs permission to read this browser’s Safe Storage key."
                throw UsageError.unavailable("Cannot read \(source.label). \(permission) You can also sign in below.")
            }
            throw UsageError.unavailable("Could not read \(source.label). Open that browser and sign in to \(provider.rawValue), or sign in below.")
        } catch {
            throw UsageError.unavailable("Could not read \(source.label). You can sign in below instead.")
        }
        return Session(source: source, cookieHeader: try cookieHeader(provider: provider, cookies: cookies))
    }

    static func cookieHeader(provider: Provider, cookies: [HTTPCookie]) throws -> String {
        switch provider {
        case .claude: try ClaudeWebAccount.cookieHeader(from: cookies)
        case .cursor: try CursorAccount.cookieHeader(from: cookies)
        }
    }
}
