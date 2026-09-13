import AppKit
import SwiftUI
import UserNotifications

struct HoustonAlert: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let date = Date.now
    let url: URL?
    let sessionID: String?
}

@MainActor final class AlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var quotaEnabled: Bool { didSet { save(quotaEnabled, "quota"); settingsChanged?() } }
    @Published var resetEnabled: Bool { didSet { save(resetEnabled, "reset") } }
    @Published var githubEnabled: Bool { didSet { save(githubEnabled, "github"); settingsChanged?() } }
    @Published var agentEnabled: Bool { didSet { save(agentEnabled, "agents") } }
    @Published var remainingThreshold: Double {
        didSet { defaults.set(remainingThreshold, forKey: "alerts.remainingThreshold") }
    }
    @Published private(set) var recent: [HoustonAlert] = []
    @Published private(set) var permissionMessage: String?
    var settingsChanged: (() -> Void)?
    var openSession: ((String) -> Void)?
    private let defaults: UserDefaults
    private var center: UNUserNotificationCenter? {
        // The command-line executable and XCTest hosts are not notification app bundles.
        guard Bundle.main.bundleIdentifier == "dev.houston.island", Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        quotaEnabled = defaults.bool(forKey: "alerts.quota")
        resetEnabled = defaults.bool(forKey: "alerts.reset")
        githubEnabled = defaults.bool(forKey: "alerts.github")
        agentEnabled = defaults.bool(forKey: "alerts.agents")
        remainingThreshold = min(50, max(1, defaults.object(forKey: "alerts.remainingThreshold") as? Double ?? 20))
        super.init()
    }

    func start() { center?.delegate = self }

    private func save(_ enabled: Bool, _ name: String) {
        defaults.set(enabled, forKey: "alerts." + name)
        if enabled { requestPermission() }
    }

    func requestPermission() {
        guard let center else { permissionMessage = "Open Houston.app to enable macOS notifications."; return }
        center.delegate = self
        Task {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                permissionMessage = allowed ? nil : "Notifications are disabled in macOS. Enable Houston in System Settings → Notifications."
            } catch { permissionMessage = "macOS notifications are unavailable. Alerts still appear in Houston." }
        }
    }

    func send(title: String, body: String, url: URL? = nil, sessionID: String? = nil) {
        let alert = HoustonAlert(title: title, body: body, url: url, sessionID: sessionID)
        recent.insert(alert, at: 0)
        recent = Array(recent.prefix(20))
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        if let url { content.userInfo["url"] = url.absoluteString }
        if let sessionID { content.userInfo["session"] = sessionID }
        Task {
            do { try await center.add(UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)) }
            catch { permissionMessage = "macOS could not deliver an alert. Check Houston’s notification settings." }
        }
    }

    func open(_ alert: HoustonAlert) {
        if let sessionID = alert.sessionID { openSession?(sessionID) }
        else if let url = alert.url { NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let sessionID = response.notification.request.content.userInfo["session"] as? String
        let address = response.notification.request.content.userInfo["url"] as? String
        await MainActor.run {
            if let sessionID { openSession?(sessionID) }
            else if let address, let url = URL(string: address), url.scheme == "https" { NSWorkspace.shared.open(url) }
        }
    }
}

struct AlertSettingsView: View {
    @ObservedObject var alerts: AlertCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Notifications", systemImage: "bell").font(.headline)
            Divider()
            Toggle(isOn: $alerts.agentEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent activity")
                    Text("Needs input, finishes, or fails.")
                        .font(.caption).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $alerts.quotaEnabled) {
                    Text("Low AI quota").frame(maxWidth: .infinity, alignment: .leading)
                }
                if alerts.quotaEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Notify at").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(alerts.remainingThreshold))% remaining").monospacedDigit()
                        }.font(.caption)
                        Slider(value: $alerts.remainingThreshold, in: 5...50, step: 5)
                            .accessibilityLabel("Remaining quota warning threshold")
                            .accessibilityValue("\(Int(alerts.remainingThreshold)) percent remaining")
                    }
                }
                Toggle(isOn: $alerts.resetEnabled) {
                    Text("Quota resets").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $alerts.githubEnabled) {
                    Text("GitHub checks and reviews").fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Checks open pull requests and your watched repository every five minutes while Houston is running. Alerts start after the first successful check.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = alerts.permissionMessage {
                Divider()
                Label {
                    Text(message).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("Check permission") { alerts.requestPermission() }
                    .accessibilityLabel("Check notification permission")
            }
        }.font(.subheadline).toggleStyle(.switch).controlSize(.small).padding(16)
            .frame(maxWidth: .infinity, alignment: .leading).houstonCard()
    }
}

struct RecentAlertsView: View {
    @ObservedObject var alerts: AlertCenter
    var body: some View {
        if !alerts.recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent alerts").font(.headline).padding(16)
                ForEach(alerts.recent.prefix(8)) { alert in
                    Divider().padding(.horizontal, 16)
                    if alert.url != nil || alert.sessionID != nil {
                        Button { alerts.open(alert) } label: { alertRow(alert) }
                            .buttonStyle(.plain)
                    } else {
                        alertRow(alert)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).houstonCard()
        }
    }

    private func alertRow(_ alert: HoustonAlert) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(alert.title).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(alert.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Text(alert.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                Spacer()
                if alert.url != nil || alert.sessionID != nil {
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
            }.font(.caption2).foregroundStyle(.secondary).padding(.top, 3)
        }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).contentShape(Rectangle()).help(alert.body)
    }
}
