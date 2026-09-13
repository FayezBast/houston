import SwiftUI
import HoustonCore

private let muted = Color.secondary
private let surface = Color.primary.opacity(0.035)
private let accent = Color.accentColor

private struct HoustonCard: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func houstonCard() -> some View { modifier(HoustonCard()) }
}

@MainActor enum BrandAssets {
    static let images: [String: NSImage] = {
        let names = Provider.allCases.map(\.logo) + ["github"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Logos"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (name, image)
        })
    }()
}

struct BrandLogo: View {
    let name: String
    var size: CGFloat = 21
    var color: Color = .primary
    var body: some View {
        Group {
            if let image = BrandAssets.images[name] {
                Image(nsImage: image).resizable()
                    .renderingMode(name == "gemini-color" ? .original : .template)
                    .aspectRatio(contentMode: .fit)
            } else { Text(String(name.prefix(1)).uppercased()).font(.system(size: size, weight: .bold)) }
        }
        .foregroundStyle(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

private func sectionTitle(_ text: String) -> some View {
    Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
        .accessibilityAddTraits(.isHeader)
}

private func meter(_ fraction: Double, color: Color, height: CGFloat = 4) -> some View {
    GeometryReader { geometry in
        Capsule().fill(Color.primary.opacity(0.08))
        Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, fraction)))
    }.frame(height: height)
}

struct IslandView: View {
    @ObservedObject var store: Store
    @State private var repositoryInput = ""
    @State private var apiKey = ""
    @State private var configuring: Provider?
    @State private var showHistory = false
    @State private var rotationStart = Date.now
    @FocusState private var editingField: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(store: Store, configuring: Provider? = nil) {
        self.store = store
        _configuring = State(initialValue: configuring)
    }

    var body: some View {
        Group {
            if store.expanded { expanded.padding(.top, store.topInset) }
            else { compact.environment(\.colorScheme, .dark) }
        }
        .frame(width: store.expanded ? store.expandedWidth : store.compactWidth,
               height: store.expanded ? store.expandedHeight : max(34, store.topInset + 6), alignment: .top)
        .background {
            if !store.expanded { Color.black }
            else if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else {
                Rectangle().fill(.regularMaterial)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: store.topInset > 0 ? 0 : (store.expanded ? 24 : 15),
                                          bottomLeadingRadius: store.expanded ? 24 : 15,
                                          bottomTrailingRadius: store.expanded ? 24 : 15,
                                          topTrailingRadius: store.topInset > 0 ? 0 : (store.expanded ? 24 : 15)))
        .overlay {
            if store.expanded {
                UnevenRoundedRectangle(topLeadingRadius: store.topInset > 0 ? 0 : 24, bottomLeadingRadius: 24,
                                       bottomTrailingRadius: 24, topTrailingRadius: store.topInset > 0 ? 0 : 24)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in if inside && !store.expanded { store.expanded = true } }
        .onExitCommand { editingField = nil; store.editing = false; store.expanded = false }
        .onChange(of: editingField) { _, value in store.editing = value != nil }
        .onChange(of: store.tab) { _, tab in
            editingField = nil
            if tab == .activity { repositoryInput = store.repository }
        }
        .onChange(of: store.expanded) { _, expanded in
            if !expanded { editingField = nil; store.editing = false }
        }
        .onAppear { repositoryInput = store.repository }
    }

    private var compact: some View { rotatingCompact() }

    @ViewBuilder private func rotatingCompact(width: CGFloat? = nil, notchWidth: CGFloat? = nil) -> some View {
        if store.compactProviders.count > 1 {
            TimelineView(.periodic(from: rotationStart, by: 6)) { context in
                CompactIsland(store: store, date: min(context.date, .now), rotationStart: rotationStart, width: width, notchWidth: notchWidth)
            }
        } else {
            TimelineView(.explicit(readingChangeDates)) { context in
                CompactIsland(store: store, date: min(context.date, .now), rotationStart: rotationStart, width: width, notchWidth: notchWidth)
            }
        }
    }

    private var readingChangeDates: [Date] {
        let quotaDates = store.enabled.flatMap { provider -> [Date] in
            guard !store.demo, let snapshot = store.snapshots[provider] else { return [] }
            return [snapshot.capturedAt.addingTimeInterval(601)] + snapshot.windows.compactMap(\.resetsAt)
        }
        let agentDates = store.agents.sessions.map { $0.updatedAt.addingTimeInterval($0.status == .completed ? 301 : 901) }
        return (quotaDates + agentDates).sorted()
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(accent).font(.system(size: 17))
                Text("Houston").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { store.pinned.toggle(); editingField = nil } label: {
                    Label(store.pinned ? "Pinned" : "Keep open", systemImage: store.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(store.pinned ? accent : muted)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(store.pinned ? accent.opacity(0.12) : surface, in: Capsule())
                }.buttonStyle(.plain).help("Keep Houston open (⌘P)")
                .accessibilityLabel("Keep Houston open").accessibilityValue(store.pinned ? "On" : "Off")
                iconButton("chevron.up", "Collapse panel") { editingField = nil; store.expanded = false }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)

            Picker("Section", selection: $store.tab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .padding(.horizontal, 20).padding(.bottom, 12)

            ScrollView { page }.id(store.tab).scrollIndicators(.automatic).frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if store.editing {
                    Label("Editing · Esc to close", systemImage: "pencil").foregroundStyle(muted)
                } else if store.tab == .system, let system = store.system {
                    Label("Live · every 2 s · up \(SystemFormat.uptime(system.uptime))", systemImage: "waveform.path.ecg").foregroundStyle(muted)
                } else {
                    Button { store.demo.toggle() } label: {
                        Label(store.demo ? "Preview · Return to live" : "Preview", systemImage: store.demo ? "circle.fill" : "play.circle")
                            .foregroundStyle(store.demo ? .orange : muted)
                    }.buttonStyle(.plain).help(store.demo ? "Return to your live readings" : "Explore Houston with sample data")
                }
                Spacer()
                if store.tab != .system {
                    Button { store.refresh() } label: {
                        Label(store.refreshing ? "Updating…" : "Refresh", systemImage: "arrow.clockwise")
                    }.buttonStyle(.plain).foregroundStyle(muted).disabled(store.refreshing || store.demo)
                        .help("Refresh readings (⌘R)")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 22).padding(.vertical, 13)
            .background(surface)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// The current tab's content; also rendered on its own by the offscreen render test, which cannot see inside a ScrollView.
    var page: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.tab {
            case .usage: usage
            case .system: system
            case .activity: activity
            case .tools: tools
            case .agents:
                if store.demo {
                    Text("Agent sessions are paused during Preview.").font(.callout).foregroundStyle(.secondary)
                } else { AgentSessionsView(monitor: store.agents) }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
    }

    // MARK: Usage

    private var usage: some View {
        Group {
            if showHistory {
                Button { showHistory = false } label: {
                    Label("Current usage", systemImage: "chevron.left")
                }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 13, weight: .medium))
                    .padding(.bottom, 4)
                if store.demo {
                    empty("Your history starts with live usage", detail: "Return to live readings to see your usage over time.", symbol: "chart.xyaxis.line")
                } else {
                    UsageHistoryView(history: store.history)
                    if let error = store.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            } else {
            HStack(alignment: .center) {
                Text("AI usage").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { showHistory = true } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }.buttonStyle(.bordered).controlSize(.regular).help("View your usage history")
            }
            Text(store.demo ? "Sample allowances. Your live usage is paused." : "Your remaining allowances, at a glance.")
                .font(.system(size: 13)).foregroundStyle(store.demo ? .orange : muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, -6).padding(.bottom, 4)
            if store.enabled.isEmpty {
                empty("Make room for your tools", detail: "Connect a provider to see its remaining allowance here.", symbol: "square.grid.2x2")
                Button("Choose providers") { store.tab = .tools }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            ForEach(Provider.allCases.filter { store.enabled.contains($0) }) { provider in
                UsageCard(provider: provider, store: store) {
                    store.tab = .tools; configuring = provider
                }
                if !store.demo, !store.accounts.accounts(for: provider).isEmpty {
                    AccountComparisonView(store: store.accounts, provider: provider, defaultSnapshot: store.defaultSnapshots[provider])
                }
            }
            }
        }
    }

    // MARK: Mac

    private var system: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("This Mac").font(.system(size: 24, weight: .semibold)).tracking(-0.5).accessibilityAddTraits(.isHeader)
                if let system = store.system {
                    Text("\(system.chip) · \(system.cores.isEmpty ? "" : "\(system.cores.count) cores · ")\(SystemFormat.memory(system.memoryTotal))")
                        .font(.system(size: 13)).foregroundStyle(muted)
                }
            }.padding(.bottom, 4)
            if let system = store.system {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(title: "CPU", value: system.cpuLoad.map { "\(Int($0.rounded()))%" } ?? "—", fraction: (system.cpuLoad ?? 0) / 100,
                             caption: system.loadAverage.first.map { String(format: "Load %.2f", $0) } ?? "Measuring…")
                    StatTile(title: "GPU", value: system.gpuLoad.map { "\(Int($0.rounded()))%" } ?? "—", fraction: (system.gpuLoad ?? 0) / 100,
                             caption: system.sensors.first { $0.name == "GPU" }.map { "\(Int($0.hottest.rounded()))° hottest" } ?? "Utilization")
                    StatTile(title: "Memory", value: SystemFormat.memory(system.memoryUsed), fraction: system.memoryFraction,
                             caption: system.swapUsed > 0 ? "Swap \(SystemFormat.memory(system.swapUsed))" : "of \(SystemFormat.memory(system.memoryTotal))")
                    StatTile(title: "CPU temp", value: system.cpuTemperature.map { "\(Int($0.rounded()))°C" } ?? "—", fraction: (system.cpuTemperature ?? 0) / 110,
                             caption: system.fans.first.map { "Fan \(Int($0.rpm)) rpm" } ?? "Thermal \(system.thermalState.lowercased())",
                             warning: system.thermalState != "Nominal")
                }
                if !system.cores.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Cores")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 18), spacing: 4)], spacing: 8) {
                            ForEach(system.cores) { core in
                                VStack(spacing: 4) {
                                    ZStack(alignment: .bottom) {
                                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                                        RoundedRectangle(cornerRadius: 3).fill(core.load > 90 ? .orange : accent).frame(height: max(2, 30 * core.load / 100))
                                    }.frame(height: 30)
                                    Text(core.efficiency ? "E" : "P").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                                }.accessibilityLabel("Core \(core.id + 1): \(Int(core.load)) percent")
                            }
                        }
                    }.padding(16).houstonCard()
                }
                if !system.sensors.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        sectionTitle("Temperatures")
                        ForEach(system.sensors) { sensor in
                            HStack(spacing: 10) {
                                Text(sensor.name).font(.system(size: 12, weight: .medium)).frame(width: 60, alignment: .leading)
                                meter(sensor.hottest / 110, color: sensor.hottest >= 95 ? .orange : accent)
                                Text("\(Int(sensor.hottest.rounded()))°").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 34, alignment: .trailing)
                                Text(sensor.count > 1 ? "avg \(Int(sensor.average.rounded()))°" : "").font(.system(size: 11)).foregroundStyle(muted).frame(width: 46, alignment: .trailing)
                            }
                        }
                        Text("Hottest of \(system.sensors.map(\.count).reduce(0, +)) SMC sensors · thermal pressure \(system.thermalState.lowercased())")
                            .font(.system(size: 11)).foregroundStyle(system.thermalState == "Nominal" ? muted : .orange)
                    }.padding(16).houstonCard()
                }
                VStack(alignment: .leading, spacing: 9) {
                    sectionTitle("Power")
                    if let power = system.systemPower {
                        statRow("System draw", String(format: "%.1f W", power), detail: system.chargerPower.map { String(format: "charger %.0f W", $0) })
                    }
                    if let battery = system.battery {
                        let state = battery.charging ? "charging" : battery.external ? "plugged in" : "on battery"
                        let time = battery.minutesRemaining.map { SystemFormat.duration(minutes: $0) + (battery.charging ? " to full" : " left") }
                        statRow("Battery", "\(battery.percent)%", detail: [state, time].compactMap { $0 }.joined(separator: " · "))
                        meter(Double(battery.percent) / 100, color: battery.percent <= 15 && !battery.external ? .orange : accent)
                    }
                    ForEach(system.fans) { fan in
                        statRow(system.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan", "\(Int(fan.rpm)) rpm",
                                detail: fan.maximum > fan.minimum ? "\(Int(fan.minimum))–\(Int(fan.maximum)) rpm" : nil)
                        if fan.maximum > fan.minimum { meter((fan.rpm - fan.minimum) / (fan.maximum - fan.minimum), color: accent) }
                    }
                    if system.systemPower == nil && system.battery == nil && system.fans.isEmpty {
                        Text("No power or fan sensors reported.").font(.system(size: 11)).foregroundStyle(muted)
                    }
                }.padding(16).houstonCard()
                if system.diskTotal > 0 {
                    VStack(alignment: .leading, spacing: 9) {
                        sectionTitle("STORAGE")
                        statRow("Startup disk", SystemFormat.disk(system.diskUsed), detail: "of \(SystemFormat.disk(system.diskTotal)) used")
                        meter(system.diskFraction, color: system.diskFraction > 0.9 ? .orange : accent)
                    }.padding(16).houstonCard()
                }
            } else {
                empty("Reading this Mac…", detail: "CPU and GPU load, memory, temperatures, fan and power arrive in a moment.", symbol: "gauge.with.dots.needle.33percent")
            }
        }
    }

    private func statRow(_ title: String, _ value: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            if let detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(muted) }
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    // MARK: Tools

    private var tools: some View {
        Group {
            HStack(alignment: .firstTextBaseline) {
                Text("Tools").font(.system(size: 24, weight: .semibold)).tracking(-0.5).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(store.enabled.count) enabled").font(.system(size: 12)).foregroundStyle(muted)
            }
            Text("Your connections and preferences.").font(.system(size: 13)).foregroundStyle(muted).padding(.top, -6)
            sectionTitle("Providers").padding(.top, 8)
            VStack(spacing: 0) {
              ForEach(Provider.allCases) { provider in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            editingField = nil
                            configuring = configuring == provider ? nil : provider
                        } label: {
                            HStack(spacing: 10) {
                                BrandLogo(name: provider.logo, size: 22, color: provider.color)
                                    .frame(width: 30, height: 34)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.rawValue).font(.system(size: 14, weight: .semibold))
                                    Text(provider.connectionSource).font(.system(size: 11)).foregroundStyle(muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: configuring == provider ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Configure \(provider.rawValue)")
                            .accessibilityValue(configuring == provider ? "Expanded" : "Collapsed")
                        Button { store.setCompactPinned(provider, !store.isCompactPinned(provider)) } label: {
                            Image(systemName: store.isCompactPinned(provider) ? "star.fill" : "star")
                                .font(.system(size: 12)).foregroundStyle(store.isCompactPinned(provider) ? accent : muted)
                                .frame(width: 28, height: 30).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(!store.enabled.contains(provider) || (!store.isCompactPinned(provider) && store.compactProviders.count >= 4))
                            .help(store.isCompactPinned(provider) ? "Remove from compact island" : store.compactProviders.count >= 4 ? "Unstar a provider to make room" : "Show in compact island")
                            .accessibilityLabel("Favorite \(provider.rawValue) in compact island")
                            .accessibilityValue(store.isCompactPinned(provider) ? "On" : "Off")
                        Toggle("Show \(provider.rawValue)", isOn: Binding(get: { store.enabled.contains(provider) }, set: { store.setEnabled(provider, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(accent)
                    }
                    HStack(spacing: 5) {
                        Text(provider.allowanceCoverage).foregroundStyle(muted)
                        Spacer(minLength: 2)
                        Text(store.reading(for: provider).status)
                            .foregroundStyle(store.reading(for: provider).needsAttention ? .orange : muted)
                    }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    if configuring == provider {
                        Divider()
                        Text(provider.coverageNote).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        Text(provider.setup).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        if let error = store.errors[provider] {
                            Text(error).font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                        if provider == .claude { claudeSetup }
                        else if provider == .openrouter {
                            HStack {
                                SecureField("OpenRouter API key", text: $apiKey).textFieldStyle(.roundedBorder).focused($editingField, equals: "key")
                                Button("Save") {
                                    store.saveOpenRouter(apiKey); apiKey = ""; editingField = nil
                                }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }.controlSize(.small)
                        } else {
                            if provider == .cursor {
                                Button("Connect Cursor…") {
                                    ProviderSignIn.cursor.show { snapshot in
                                        store.connectedCursor(snapshot)
                                    }
                                }.buttonStyle(.borderedProminent).controlSize(.regular)
                            }
                            HStack {
                                Button("Check connection") { store.refresh(provider) }.disabled(store.loading.contains(provider))
                                Button("Dashboard ↗") { NSWorkspace.shared.open(provider.dashboard) }
                            }.buttonStyle(.bordered).controlSize(.small)
                            if provider == .gemini {
                                Link("About Gemini Free account support ↗", destination: URL(string: "https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals")!)
                                    .font(.system(size: 11))
                            }
                        }
                        AccountsView(store: store.accounts, provider: provider, defaultSnapshot: store.defaultSnapshots[provider],
                                     onEditing: { store.editing = $0 }).disabled(store.demo)
                    }
                }.padding(14)
                if provider != Provider.allCases.last { Divider().padding(.leading, 54) }
              }
            }
            .houstonCard()
            Label("Credentials stay in their existing app or macOS Keychain.", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(muted).padding(.top, 7)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Compact favorites", systemImage: "star").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(store.compactProviders.count) of 4").font(.system(size: 12)).foregroundStyle(muted)
                }
                GeometryReader { geometry in
                    rotatingCompact(width: geometry.size.width, notchWidth: 0)
                        .disabled(true).allowsHitTesting(false).accessibilityHidden(true)
                }.frame(height: max(34, store.topInset + 6))
                    .background(.black, in: RoundedRectangle(cornerRadius: 12)).environment(\.colorScheme, .dark)
                Text("Star up to four providers above. Their allowances rotate every six seconds beside your agent status.")
                    .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }.padding(16).houstonCard().padding(.top, 8)
            AlertSettingsView(alerts: store.alerts).disabled(store.demo)
            RecentAlertsView(alerts: store.alerts)
        }
    }

    private var claudeSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = store.claudeMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(Provider.claude.color).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(get: { store.claudeDirect }, set: { store.setClaudeDirect($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Direct connection").font(.system(size: 12, weight: .medium))
                    Text("Reads usage from your connected Claude web account or Claude Code sign-in. Works without a terminal response.")
                        .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).controlSize(.small).tint(Provider.claude.color)
            HStack {
                Button("Connect Claude…") {
                    ProviderSignIn.claude.show { snapshot in store.connectedClaude(snapshot) }
                }.buttonStyle(.borderedProminent)
                Button("Use Claude Code sign-in") { store.useClaudeCodeSignIn() }
            }.buttonStyle(.bordered).controlSize(.small)
            HStack {
                Button(store.claudeDirect ? "Check connection" : "Repair local bridge") {
                    if store.claudeDirect { store.refresh(.claude, allowInteraction: true) } else { store.connectClaude(); store.refresh(.claude) }
                }.disabled(store.loading.contains(.claude))
                Button("Usage dashboard ↗") { NSWorkspace.shared.open(Provider.claude.dashboard) }
            }.buttonStyle(.bordered).controlSize(.small)
            Text(bridgeStatus).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bridgeStatus: String {
        guard store.bridgeConfigured else { return "Terminal bridge: not configured. Repair it to also update after Claude Code terminal responses." }
        if let date = store.bridgeDate, store.snapshots[.claude] != nil || store.errors[.claude] == nil {
            return "Terminal bridge: last update \(GitHubReader.age(date)). The token is never read by the bridge."
        }
        return "Terminal bridge: configured, waiting for a Claude Code terminal response. The desktop app does not run status lines."
    }

    // MARK: GitHub

    private var activity: some View {
        Group {
            HStack(alignment: .firstTextBaseline) {
                Text("GitHub").font(.system(size: 24, weight: .semibold)).tracking(-0.5).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(store.overview.map { "@\($0.login)" } ?? (store.overviewLoading ? "Checking…" : "Not signed in"))
                    .font(.system(size: 12)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
            }
            Text("Pull requests, reviews, and notifications. All in one place.").font(.system(size: 13)).foregroundStyle(muted)
            if let error = store.githubAlertError, store.alerts.githubEnabled {
                Text("Checks and reviews: " + error).font(.caption).foregroundStyle(.orange)
            }
            if let error = store.overviewError, store.overview == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Text("Install GitHub CLI (brew install gh), run gh auth login in a terminal, then check again.").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    Button("Check again") { store.refreshOverview() }.buttonStyle(.bordered).controlSize(.small).disabled(store.overviewLoading)
                }.padding(16).houstonCard()
            } else if let overview = store.overview {
                activitySection("Your pull requests", items: overview.authored, empty: "No open pull requests", symbol: "arrow.triangle.pull")
                activitySection("Waiting on your review", items: overview.reviewRequests, empty: "Nothing waiting on you", symbol: "eye")
                activitySection("Unread notifications", items: overview.notifications, empty: "You’re all caught up", symbol: "bell")
                if let note = overview.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            } else {
                empty("Checking GitHub…", detail: "Houston uses your existing GitHub CLI sign-in and checks every five minutes.", symbol: "arrow.triangle.branch")
            }
            sectionTitle("Watch a repository").padding(.top, 10)
            HStack {
                TextField("owner/repository or GitHub link", text: $repositoryInput).textFieldStyle(.roundedBorder)
                    .focused($editingField, equals: "repository")
                    .onSubmit { store.saveRepository(repositoryInput); editingField = nil }
                Button("Watch") { store.saveRepository(repositoryInput); editingField = nil }.buttonStyle(.borderedProminent).tint(accent)
                if !store.repository.isEmpty { Button("Clear") { store.clearRepository(); repositoryInput = "" } }
            }.controlSize(.regular).padding(.vertical, 4)
            if let error = store.activityError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if let suggestion = store.repositorySuggestion {
                    Button("Did you mean \(suggestion)? Watch it") { repositoryInput = suggestion; store.saveRepository(suggestion) }
                        .buttonStyle(.bordered).controlSize(.small).tint(accent)
                }
            }
            if store.repository.isEmpty, let repositories = store.overview?.repositories, !repositories.isEmpty {
                Text("Recently pushed").font(.system(size: 11)).foregroundStyle(muted)
                FlowChips(items: Array(repositories.prefix(5))) { name in repositoryInput = name; store.saveRepository(name) }
            }
            if let activity = store.activity {
                Text("Watching \(store.repository)").font(.system(size: 11)).foregroundStyle(muted)
                activitySection("Pull requests", items: activity.pullRequests, empty: "No open pull requests", symbol: "arrow.triangle.pull")
                activitySection("Latest CI runs", items: activity.runs, empty: "No workflow runs", symbol: "bolt")
            } else if !store.repository.isEmpty, store.activityLoading {
                Text("Checking \(store.repository)…").font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }

    private func activitySection(_ title: String, items: [GitHubActivity.Item], empty message: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle(title)
                Spacer()
                if !items.isEmpty { Text(items.count, format: .number).font(.system(size: 12)).foregroundStyle(muted).monospacedDigit() }
            }
            if items.isEmpty { Text(message).font(.system(size: 13)).foregroundStyle(muted).padding(.vertical, 4) }
            ForEach(items) { item in
                Button { NSWorkspace.shared.open(item.url) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol).foregroundStyle(item.state.lowercased() == "failure" ? .orange : accent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Text([item.state.replacingOccurrences(of: "_", with: " ").capitalized, item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(muted)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).houstonCard().contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open \(item.title) on GitHub")
            }
        }.padding(.top, 10)
    }

    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(accent)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 32)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(muted).frame(width: 30, height: 30).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(items[start..<min(start + 2, items.count)], id: \.self) { name in
                        Button { action(name) } label: {
                            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, 9).padding(.vertical, 5).background(surface, in: Capsule())
                        }.buttonStyle(.plain).foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let fraction: Double
    let caption: String
    var warning = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(muted)
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit().tracking(-0.5).lineLimit(1).minimumScaleFactor(0.7)
            meter(fraction, color: fraction > 0.85 || warning ? .orange : accent)
            Text(caption).font(.system(size: 11)).foregroundStyle(warning ? .orange : muted).lineLimit(1)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).houstonCard()
        .accessibilityElement(children: .combine).accessibilityLabel("\(title): \(value), \(caption)")
    }
}

struct CompactProviderBadge: View {
    let provider: Provider
    let reading: ProviderReading
    var width: CGFloat = 60

    var body: some View {
        HStack(spacing: width < 50 ? 4 : 5) {
            BrandLogo(name: provider.logo, size: width < 50 ? 12 : 15, color: .white.opacity(reading.remaining == nil ? 0.55 : 0.95))
            Text(reading.value).font(.system(size: width < 50 ? 10 : 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(reading.needsAttention ? .orange : .white.opacity(0.9))
                .lineLimit(1).minimumScaleFactor(0.65)
        }.frame(width: width)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.rawValue), \(reading.value) remaining, \(reading.status)")
    }
}

struct CompactIsland: View {
    @ObservedObject var store: Store
    var date: Date = .now
    var rotationStart: Date = .now
    var width: CGFloat?
    var notchWidth: CGFloat?
    private var activeAgents: [AgentSession] {
        store.demo ? [] : store.agents.sessions.filter {
            !$0.isStale(at: date) && ($0.status == .running || $0.status.needsAttention)
                && ($0.status != .completed || date.timeIntervalSince($0.updatedAt) <= 300)
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var displayedProvider: Provider? {
        let providers = store.compactProviders
        guard !providers.isEmpty else { return nil }
        let index = Int(max(0, date.timeIntervalSince(rotationStart)) / 6) % providers.count
        return providers[index]
    }

    var body: some View {
        let totalWidth = width ?? store.compactWidth
        let camera = min(notchWidth ?? store.notchWidth, totalWidth)
        let side = max(0, (totalWidth - camera) / 2)
        Button { store.tab = activeAgents.isEmpty ? .usage : .agents; store.expanded = true } label: {
            HStack(spacing: 0) {
                ZStack {
                    if let provider = displayedProvider {
                        VStack(spacing: 3) {
                            CompactProviderBadge(provider: provider, reading: store.reading(for: provider, at: date), width: max(0, min(60, side - 8)))
                            if store.demo {
                                Text("PREVIEW").font(.system(size: 6, weight: .semibold)).foregroundStyle(.orange)
                            } else if store.compactProviders.count > 1 {
                                HStack(spacing: 3) {
                                    ForEach(store.compactProviders) { item in
                                        Circle().fill(.white.opacity(item == provider ? 0.8 : 0.25)).frame(width: 2, height: 2)
                                    }
                                }.accessibilityHidden(true)
                            }
                        }.id(provider).transition(.opacity)
                    } else {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                }.frame(width: side).clipped()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: displayedProvider)
                Color.clear.frame(width: camera).accessibilityHidden(true)
                Group {
                    if let session = activeAgents.first {
                        HStack(spacing: 4) {
                            Image(systemName: session.status == .running ? "circle.dotted" : session.status == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            Text("\(activeAgents.count)").monospacedDigit()
                        }.font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(session.status == .running ? .white : session.status == .completed ? .green : .orange)
                    } else {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                    }
                }.frame(width: side).clipped().accessibilityHidden(true)
            }.frame(width: totalWidth, height: max(34, store.topInset + 6)).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(activeAgents.isEmpty ? "Open Houston usage panel" : "Open Houston agent sessions")
            .accessibilityValue(summary)
            .help(summary + (activeAgents.isEmpty ? "\nClick to see all providers" : "\nClick to see agent sessions"))
    }

    private var summary: String {
        var text = "Houston · Choose compact favorites in Tools"
        if let provider = displayedProvider {
            let reading = store.reading(for: provider, at: date)
            text = (store.demo ? "Preview. " : "") + "\(provider.rawValue): \(reading.value) remaining · \(reading.status)"
                + (store.compactProviders.count > 1 ? "\nRotates through \(store.compactProviders.count) favorites every six seconds" : "")
        }
        if let session = activeAgents.first {
            text += "\n\(activeAgents.count) agent sessions · \(session.projectName): \(session.status.title)"
        }
        return text
    }
}

private struct UsageCard: View {
    let provider: Provider
    @ObservedObject var store: Store
    let configure: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let reading = store.reading(for: provider, at: context.date)
            let snapshot = store.snapshot(for: provider)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    BrandLogo(name: provider.logo, size: 23, color: provider.color)
                        .frame(width: 38, height: 38).background(provider.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.rawValue).font(.system(size: 15, weight: .semibold))
                        Text(reading.status).font(.system(size: 11)).foregroundStyle(reading.needsAttention ? .orange : muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if snapshot != nil {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(reading.value).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().tracking(-0.7)
                                .foregroundStyle(reading.needsAttention ? .orange : .primary)
                                .lineLimit(1).minimumScaleFactor(0.75)
                            Text(reading.value.contains("∞") ? "allowance" : "remaining").font(.system(size: 11)).foregroundStyle(muted)
                        }
                    } else if reading.isLoading {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking \(provider.rawValue)")
                    } else {
                        Button("Set up", action: configure).buttonStyle(.bordered).controlSize(.small)
                    }
                    Menu {
                        Button("Open usage dashboard", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(provider.dashboard) }
                        Button("Refresh usage", systemImage: "arrow.clockwise") { store.refresh(provider) }
                            .disabled(store.demo || reading.isLoading)
                        Divider()
                        Button(store.isCompactPinned(provider) ? "Remove from compact island" : "Show in compact island", systemImage: "star") {
                            store.setCompactPinned(provider, !store.isCompactPinned(provider))
                        }.disabled(!store.isCompactPinned(provider) && store.compactProviders.count >= 4)
                        Button("Connection settings…", systemImage: "gearshape", action: configure)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
                            .frame(width: 24, height: 30).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("\(provider.rawValue) actions")
                }
                if let snapshot {
                    if !store.demo, let account = store.accounts.selectedAccount(for: provider) {
                        Text(account.label).font(.system(size: 11, weight: .medium)).foregroundStyle(provider.color)
                    }
                    VStack(spacing: 12) {
                        ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                            if !window.expired(at: context.date), window.used.isFinite {
                                VStack(spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(window.name).fontWeight(.medium).foregroundStyle(.primary)
                                        Text("\(Int(window.remaining))%")
                                            .foregroundStyle(window.remaining <= 10 ? .orange : muted)
                                        Spacer(minLength: 6)
                                        Text(window.countdown(at: context.date)).foregroundStyle(muted)
                                    }.font(.system(size: 11)).monospacedDigit()
                                    meter(window.remaining / 100, color: window.remaining <= 10 ? .orange : provider.color, height: 6)
                                        .opacity(reading.value.hasPrefix("~") ? 0.55 : 1)
                                }.accessibilityElement(children: .ignore)
                                    .accessibilityLabel("\(window.name): \(Int(window.remaining)) percent remaining. \(window.countdown(at: context.date))")
                            } else {
                                Label("\(window.name) · awaiting updated usage", systemImage: "clock")
                                    .font(.system(size: 12)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if let detail = snapshot.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if !store.demo, let identity = store.historyAccountID(for: provider), let window = snapshot.windows.first,
                       store.history.forecast(provider: provider.rawValue, accountID: identity, window: window.name, now: context.date) != nil {
                        UsagePaceLabel(history: store.history, provider: provider.rawValue, accountID: identity, window: window.name, now: context.date)
                    }
                } else {
                    Text(reading.isLoading ? "Checking your allowance…" : store.errors[provider] ?? (provider == .openrouter ? "Connect an API key to track spending." : "Connect \(provider.rawValue) to see your remaining allowance."))
                        .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16).houstonCard()
        }
    }
}
