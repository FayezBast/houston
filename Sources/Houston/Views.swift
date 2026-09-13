import SwiftUI
import HoustonCore

private let muted = Color.secondary
private let surface = Color.primary.opacity(0.045)
private let accent = Color.accentColor

private struct HoustonCard: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.07), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
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
    Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(muted)
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
    @FocusState private var editingField: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        .overlay(alignment: .bottom) {
            if store.expanded { Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 28, height: 3).padding(.bottom, 5).accessibilityHidden(true) }
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

    private var compact: some View {
        Button { store.expanded = true } label: {
            HStack {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 16)).foregroundStyle(.white)
                Spacer()
                Circle().fill(store.snapshots.isEmpty ? .gray : .green).frame(width: 5, height: 5)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(muted)
            }
            .padding(.horizontal, 15).frame(height: max(34, store.topInset + 6)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Open Houston usage panel")
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(accent).font(.system(size: 16))
                Text("Houston").font(.system(size: 16, weight: .semibold, design: .rounded)).tracking(0.3)
                Spacer()
                Button { store.pinned.toggle(); editingField = nil } label: {
                    Label(store.pinned ? "Pinned" : "Keep open", systemImage: store.pinned ? "pin.fill" : "pin.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(store.pinned ? accent : muted)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(store.pinned ? accent.opacity(0.12) : surface, in: Capsule())
                }.buttonStyle(.plain).help("Keep Houston open (⌘P)")
                .accessibilityLabel("Keep Houston open").accessibilityValue(store.pinned ? "On" : "Off")
                iconButton("chevron.up", "Collapse panel") { editingField = nil; store.expanded = false }
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)

            Picker("Section", selection: $store.tab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .padding(.horizontal, 20).padding(.bottom, 8)

            ScrollView { page }.id(store.tab).scrollIndicators(.automatic).frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if store.editing {
                    Label("Editing · Esc to close", systemImage: "pencil").foregroundStyle(muted)
                } else if store.tab == .system, let system = store.system {
                    Label("Live · every 2 s · up \(SystemFormat.uptime(system.uptime))", systemImage: "waveform.path.ecg").foregroundStyle(muted)
                } else {
                    Button { store.demo.toggle() } label: {
                        Label(store.demo ? "Demo data · return to live" : "Preview", systemImage: store.demo ? "circle.fill" : "play.circle")
                            .foregroundStyle(store.demo ? .orange : muted)
                    }.buttonStyle(.plain)
                }
                Spacer()
                if store.tab != .system {
                    Button { store.refresh() } label: {
                        Label(store.refreshing ? "Updating…" : "Refresh", systemImage: "arrow.clockwise")
                    }.buttonStyle(.plain).foregroundStyle(muted).disabled(store.refreshing || store.demo)
                }
            }
            .font(.system(size: 11)).padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 18)
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
            }
        }.padding(.horizontal, 20).padding(.vertical, 18)
    }

    // MARK: Usage

    private var usage: some View {
        Group {
            HStack(alignment: .firstTextBaseline) {
                Text("Workspace").font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                Spacer()
                Text(store.demo ? "PREVIEW" : "\(store.enabled.filter { store.snapshots[$0] != nil }.count) CONNECTED")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(store.demo ? .orange : muted)
            }.padding(.bottom, 4)
            if store.enabled.isEmpty {
                empty("Choose your tools", detail: "Add the tools you use from the Tools tab.", symbol: "square.grid.2x2")
            }
            ForEach(Provider.allCases.filter { store.enabled.contains($0) }) { provider in
                UsageCard(provider: provider, snapshot: store.snapshot(for: provider),
                          error: store.demo ? nil : store.errors[provider], loading: !store.demo && store.loading.contains(provider), direct: store.claudeDirect) {
                    store.tab = .tools; configuring = provider
                }
            }
        }
    }

    // MARK: Mac

    private var system: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("This Mac").font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                if let system = store.system {
                    Text("\(system.chip.uppercased()) · \(system.cores.isEmpty ? "" : "\(system.cores.count) CORES · ")\(SystemFormat.memory(system.memoryTotal).uppercased())")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
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
                        sectionTitle("CORES")
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
                        sectionTitle("TEMPERATURES")
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
                    sectionTitle("POWER")
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
            Text("Your tools").font(.system(size: 23, weight: .semibold)).tracking(-0.5)
            Text("Choose what appears in your island.").font(.system(size: 13)).foregroundStyle(muted).padding(.bottom, 6)
            ForEach(Provider.allCases) { provider in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        BrandLogo(name: provider.logo, size: 20, color: provider.color)
                        Button {
                            editingField = nil
                            configuring = configuring == provider ? nil : provider
                        } label: {
                            HStack {
                                Text(provider.rawValue).font(.system(size: 13, weight: .medium))
                                Image(systemName: configuring == provider ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8)).foregroundStyle(muted)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Toggle("Show \(provider.rawValue)", isOn: Binding(get: { store.enabled.contains(provider) }, set: { store.setEnabled(provider, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(accent)
                    }
                    if configuring == provider {
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
                            HStack {
                                if provider != .cursor { Button("Check connection") { store.refresh(provider) }.disabled(store.loading.contains(provider)) }
                                Button("Dashboard ↗") { NSWorkspace.shared.open(provider.dashboard) }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }.padding(16).houstonCard()
            }
            Label("Credentials stay in their existing app or macOS Keychain.", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(muted).padding(.top, 7)
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
                    Text(store.claudeEmail.map { "Reads usage with Claude Code’s sign-in (\($0)). Works with the desktop app too." }
                         ?? "Reads usage with Claude Code’s sign-in. Works with the desktop app too.")
                        .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).controlSize(.small).tint(Provider.claude.color)
            HStack {
                Button(store.claudeDirect ? "Check connection" : "Repair local bridge") {
                    if store.claudeDirect { store.refresh(.claude) } else { store.connectClaude(); store.refresh(.claude) }
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
                Text("GitHub").font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                Spacer()
                Text(store.overview.map { "@\($0.login)".uppercased() } ?? (store.overviewLoading ? "CHECKING…" : "NOT SIGNED IN"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
            }
            Text("Pull requests, reviews, and notifications. All in one place.").font(.system(size: 13)).foregroundStyle(muted)
            if let error = store.overviewError, store.overview == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Text("Install GitHub CLI (brew install gh), run gh auth login in a terminal, then check again.").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    Button("Check again") { store.refreshOverview() }.buttonStyle(.bordered).controlSize(.small).disabled(store.overviewLoading)
                }.padding(16).houstonCard()
            } else if let overview = store.overview {
                activitySection("YOUR OPEN PULL REQUESTS", items: overview.authored, empty: "No open pull requests", symbol: "arrow.triangle.pull")
                activitySection("WAITING ON YOUR REVIEW", items: overview.reviewRequests, empty: "Nothing waiting on you", symbol: "eye")
                activitySection("UNREAD NOTIFICATIONS", items: overview.notifications, empty: "Inbox zero", symbol: "bell")
                if let note = overview.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            } else {
                empty("Checking GitHub…", detail: "Houston uses your existing GitHub CLI sign-in and checks every five minutes.", symbol: "arrow.triangle.branch")
            }
            sectionTitle("WATCH A REPOSITORY").padding(.top, 10)
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
                activitySection("PULL REQUESTS", items: activity.pullRequests, empty: "No open pull requests", symbol: "arrow.triangle.pull")
                activitySection("LATEST CI RUNS", items: activity.runs, empty: "No workflow runs", symbol: "bolt")
            } else if !store.repository.isEmpty, store.activityLoading {
                Text("Checking \(store.repository)…").font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }

    private func activitySection(_ title: String, items: [GitHubActivity.Item], empty message: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(title)
            if items.isEmpty { Text(message).font(.system(size: 13)).foregroundStyle(muted) }
            ForEach(items) { item in
                Button { NSWorkspace.shared.open(item.url) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol).foregroundStyle(item.state.lowercased() == "failure" ? .orange : accent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Text([item.state.replacingOccurrences(of: "_", with: " ").capitalized, item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(muted)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain)
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
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(muted)
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit().tracking(-0.5).lineLimit(1).minimumScaleFactor(0.7)
            meter(fraction, color: fraction > 0.85 || warning ? .orange : accent)
            Text(caption).font(.system(size: 11)).foregroundStyle(warning ? .orange : muted).lineLimit(1)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).houstonCard()
        .accessibilityElement(children: .combine).accessibilityLabel("\(title): \(value), \(caption)")
    }
}

private struct UsageCard: View {
    let provider: Provider
    let snapshot: UsageSnapshot?
    let error: String?
    let loading: Bool
    let direct: Bool
    let configure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandLogo(name: provider.logo, size: 22, color: provider.color)
                    .frame(width: 34, height: 34).background(provider.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.rawValue).font(.system(size: 13, weight: .semibold))
                    Text(status).font(.system(size: 11)).foregroundStyle(error != nil && snapshot != nil ? .orange : muted)
                }
                Spacer()
                if let window = snapshot?.windows.first, !window.expired() {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(window.remaining))%").font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit().tracking(-0.5)
                        Text("left").font(.system(size: 11)).foregroundStyle(muted)
                    }
                } else if snapshot == nil {
                    Button(provider == .cursor ? "Open ↗" : "Set up") {
                        if provider == .cursor { NSWorkspace.shared.open(provider.dashboard) } else { configure() }
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            if let snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 9) {
                        ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                            if !window.expired(at: context.date) {
                                VStack(spacing: 5) {
                                    meter(window.remaining / 100, color: window.remaining <= 10 ? .orange : provider.color)
                                    HStack {
                                        Text("\(window.name) · \(Int(window.remaining))% left")
                                        Spacer()
                                        Text(window.countdown(at: context.date))
                                    }.font(.system(size: 11)).foregroundStyle(muted)
                                }.accessibilityLabel("\(window.name): \(Int(window.remaining)) percent remaining")
                            } else {
                                Text("\(window.name) ended · awaiting updated usage").font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let detail = snapshot.detail { Text(detail).font(.system(size: 11)).foregroundStyle(muted) }
            } else {
                Text(message).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).houstonCard()
    }

    private var status: String {
        if loading { return "Checking connection…" }
        if snapshot != nil { return error != nil ? "Update failed · saved reading" : snapshot!.isStale ? "Earlier reading" : provider == .windsurf ? "Local cache" : "Connected" }
        if provider == .cursor { return "Dashboard shortcut" }
        if provider == .claude { return direct ? (error == nil ? "Connecting…" : "Not connected") : "Waiting for Claude Code" }
        return "Not connected"
    }
    private var message: String {
        if provider == .claude {
            if direct { return error ?? "Reading usage with Claude Code’s sign-in…" }
            return error ?? "Send a message in a Claude Code terminal session, or turn on the direct connection in Tools to read usage from the desktop app too."
        }
        if provider == .cursor { return "Open Cursor’s usage dashboard." }
        return error ?? provider.setup
    }
}
