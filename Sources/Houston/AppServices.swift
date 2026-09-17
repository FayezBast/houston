import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon
import Sparkle

@MainActor final class AppServices: ObservableObject {
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var message: String?
    @Published private(set) var shortcutError: String?
    @Published private(set) var canCheckForUpdates = false
    private var updateObservation: AnyCancellable?
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    @Published var shortcutEnabled: Bool {
        didSet { defaults.set(shortcutEnabled, forKey: "globalShortcut"); registerShortcut() }
    }
    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var openPalette: (() -> Void)?
    var updatesAvailable: Bool { controller != nil }
    var loginEnabled: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcutEnabled = defaults.object(forKey: "globalShortcut") as? Bool ?? true
    }

    static func validUpdateConfiguration(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start(openPalette: @escaping () -> Void) {
        self.openPalette = openPalette
        registerShortcut()
        // Local source builds have no feed. Never invent a release URL or disable signature validation.
        if Bundle.main.bundleURL.pathExtension == "app", Self.validUpdateConfiguration(Bundle.main.infoDictionary ?? [:]) {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            do {
                try controller.updater.start()
                self.controller = controller
                updateObservation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
                    MainActor.assumeIsolated { self?.canCheckForUpdates = value }
                }
                refreshStatus()
            } catch { message = "Updates could not start: " + error.localizedDescription }
        }
    }

    func refreshStatus() {
        loginStatus = SMAppService.mainApp.status
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        automaticDownloads = controller?.updater.automaticallyDownloadsUpdates ?? false
    }

    func setLogin(_ enabled: Bool) {
        do {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                throw NSError(domain: "Houston", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch the built Houston.app from its permanent location first."])
            }
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch { message = error.localizedDescription }
        refreshStatus()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        refreshStatus()
    }
    func setAutomaticDownloads(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        refreshStatus()
    }
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    private func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        shortcutError = nil
        guard shortcutEnabled, openPalette != nil else { return }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var keyID = EventHotKeyID()
                let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                             MemoryLayout<EventHotKeyID>.size, nil, &keyID)
                guard read == noErr, keyID.signature == 0x4853544E, keyID.id == 1 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<AppServices>.fromOpaque(context).takeUnretainedValue().openPalette?()
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { shortcutError = "Could not install the global shortcut (\(result))."; return }
        }
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x4853544E, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { shortcutError = "⌃⌥Space is unavailable (\(result)). Use Command Palette in Houston’s menu or disable a conflicting shortcut." }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        openPalette = nil
    }
}

struct AppPreferencesView: View {
    @ObservedObject var services: AppServices
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HoustonSectionHeading(title: "Houston preferences")
            Toggle("Launch at login", isOn: Binding(get: { services.loginEnabled }, set: { services.setLogin($0) }))
            if services.loginStatus == .requiresApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            Toggle("Global command palette · ⌃⌥Space", isOn: $services.shortcutEnabled)
            if let error = services.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
            if services.updatesAvailable {
                Toggle("Check for updates automatically", isOn: Binding(get: { services.automaticChecks }, set: { services.setAutomaticChecks($0) }))
                Toggle("Download and install updates automatically", isOn: Binding(get: { services.automaticDownloads }, set: { services.setAutomaticDownloads($0) }))
                Button("Check for Updates…") { services.checkForUpdates() }.disabled(!services.canCheckForUpdates)
            } else {
                Text("Automatic updates are unavailable in this build. A release feed and signing key must be configured by the publisher.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = services.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.toggleStyle(.switch).controlSize(.small).padding(16).houstonCard()
            .onAppear { services.refreshStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in services.refreshStatus() }
    }
}
