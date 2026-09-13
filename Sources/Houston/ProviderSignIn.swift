import AppKit
import WebKit
import HoustonCore

/// Reuse a browser session or sign in normally; save only after usage has been verified.
@MainActor final class ProviderSignIn: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let cursor = ProviderSignIn(provider: .cursor)
    static let claude = ProviderSignIn(provider: .claude)
    private let provider: Provider
    private var browser: WKWebView?
    private var message: NSTextField?
    private var connectButton: NSButton?
    private var importButton: NSButton?
    private var verified: ((String, UsageSnapshot) throws -> Void)?
    private var connection: Task<Void, Never>?
    private var connectionID: UUID?
    private var automaticLookup = false
    private var browserProvider: BrowserSessions.Provider { provider == .cursor ? .cursor : .claude }

    private init(provider: Provider) {
        self.provider = provider
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use a provider sign-in window") }

    func show(connected: @escaping (UsageSnapshot) -> Void) {
        open(automaticallyFindSession: true) { [provider] credential, snapshot in
            try SecretStore.save(credential, account: provider == .cursor ? "cursor" : "claude-web")
            connected(snapshot)
        }
    }

    /// A new account receives the verified credential without replacing the legacy connection.
    func show(verified: @escaping (String, UsageSnapshot) throws -> Void) {
        open(automaticallyFindSession: false, verified: verified)
    }

    private func open(automaticallyFindSession: Bool, verified: @escaping (String, UsageSnapshot) throws -> Void) {
        // Never retarget an in-flight lookup from a previous account window.
        if window != nil { close() }
        self.verified = verified
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Connect \(provider.rawValue) to Houston"
        window.minSize = NSSize(width: 540, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        browser.uiDelegate = self
        self.browser = browser
        let message = NSTextField(wrappingLabelWithString: automaticallyFindSession
            ? "Looking for your existing \(provider.rawValue) browser sign-in. You can also sign in below…"
            : "Sign in to the account you want to add, or choose a browser profile with Use browser sign-in. Then choose Use this account.")
        message.font = .systemFont(ofSize: 12)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.message = message
        let connect = NSButton(title: "Use this account", target: self, action: #selector(connect))
        connect.bezelStyle = .rounded
        self.connectButton = connect
        let importBrowser = NSButton(title: "Use browser sign-in…", target: self, action: #selector(importBrowser))
        importBrowser.bezelStyle = .rounded
        self.importButton = importBrowser
        let reload = NSButton(title: "Reload", target: self, action: #selector(reload))
        reload.bezelStyle = .rounded
        let actions = NSStackView(views: [importBrowser, reload, connect])
        actions.spacing = 10
        let bar = NSStackView(views: [message, actions])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let content = NSStackView(views: [bar, browser])
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        window.contentView = content
        bar.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        browser.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        browser.load(URLRequest(url: provider.dashboard))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if automaticallyFindSession { findBrowserSession() }
    }

    @objc private func reload() { browser?.reload() }

    @objc private func connect() {
        guard let browser else { return }
        startConnection {
            let cookies = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
            let header = self.provider == .cursor
                ? try CursorAccount.cookieHeader(from: cookies)
                : try ClaudeWebAccount.cookieHeader(from: cookies)
            try await self.finishConnection(header: header)
        }
    }

    private func findBrowserSession() {
        let provider = browserProvider
        startConnection(automatic: true) {
            let lookup = Task.detached(priority: .utility) {
                BrowserSessions.scan(provider: provider, sources: BrowserSessions.sources())
            }
            let scan = await withTaskCancellationHandler {
                await lookup.value
            } onCancel: { lookup.cancel() }
            try Task.checkCancellation()
            guard !scan.sessions.isEmpty else {
                self.message?.stringValue = "No accessible \(provider.rawValue) browser session found. Choose Use browser sign-in to select a profile and allow access, or sign in below, then choose Use this account."
                return
            }
            let index = try await self.choose(labels: scan.sessions.map { $0.source.label }, title: "Choose your \(provider.rawValue) sign-in",
                                              explanation: "More than one browser session was found. Houston will use only the session you select.")
            let session = scan.sessions[index]
            self.message?.stringValue = "Checking \(provider.rawValue) usage from \(session.source.label)…"
            try await self.finishConnection(header: session.cookieHeader)
        }
    }

    @objc private func importBrowser() {
        let provider = browserProvider
        startConnection {
            let sources = await Task.detached(priority: .utility) { BrowserSessions.sources() }.value
            try Task.checkCancellation()
            guard !sources.isEmpty else { throw UsageError.unavailable("No supported browser profile was found. Sign in below instead.") }
            let index = try await self.choose(labels: sources.map(\.label), title: "Choose a browser profile",
                explanation: "Select the profile signed in to \(provider.rawValue). macOS may ask for access to its Safe Storage key; Safari may need Full Disk Access. Houston reads only this provider’s cookies.")
            let source = sources[index]
            self.message?.stringValue = "Reading \(source.label). macOS may ask for browser storage access…"
            let session = try await Task.detached(priority: .utility) {
                try BrowserSessions.session(provider: provider, source: source, allowInteraction: true)
            }.value
            try Task.checkCancellation()
            try await self.finishConnection(header: session.cookieHeader)
        }
    }

    private func choose(labels: [String], title: String, explanation: String) async throws -> Int {
        try Task.checkCancellation()
        guard labels.count > 1 else { return 0 }
        guard let window else { throw CancellationError() }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = explanation
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        choices.addItems(withTitles: labels)
        alert.accessoryView = choices
        alert.addButton(withTitle: "Use selected account")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { throw CancellationError() }
        try Task.checkCancellation()
        return choices.indexOfSelectedItem
    }

    private func finishConnection(header: String) async throws {
        let snapshot: UsageSnapshot
        let credential: String
        if provider == .cursor {
            credential = header
            snapshot = try await CursorAccount.readUsage(cookieHeader: header)
        } else {
            let organizations = try await ClaudeWebAccount.organizations(cookieHeader: header)
            let index = try await choose(labels: organizations.map(\.name), title: "Choose your Claude organization",
                explanation: "Houston will keep reading only the organization you select.")
            let organization = organizations[index]
            snapshot = try await ClaudeWebAccount.readUsage(cookieHeader: header, organizationID: organization.id)
            credential = try ClaudeWebAccount.credential(cookieHeader: header, organizationID: organization.id)
        }
        try Task.checkCancellation()
        try verified?(credential, snapshot)
        close()
    }

    private func startConnection(automatic: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard connection == nil || automaticLookup else { return }
        connection?.cancel()
        let id = UUID()
        connectionID = id
        automaticLookup = automatic
        connectButton?.isEnabled = automatic
        importButton?.isEnabled = automatic
        connection = Task { [weak self] in
            guard let self else { return }
            defer {
                if connectionID == id {
                    connection = nil
                    connectionID = nil
                    automaticLookup = false
                    connectButton?.isEnabled = true
                    importButton?.isEnabled = true
                }
            }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError {
                if connectionID == id { message?.stringValue = "Choose a browser sign-in or sign in below to connect." }
            } catch {
                if connectionID == id { message?.stringValue = error.localizedDescription }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        connection?.cancel()
        connection = nil
        connectionID = nil
        automaticLookup = false
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel) }
        browser?.stopLoading()
        browser = nil
        verified = nil
        window = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { message?.stringValue = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "https" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
