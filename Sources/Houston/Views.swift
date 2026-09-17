import SwiftUI
import HoustonCore

private let muted = Color.secondary
private let surface = Color.primary.opacity(0.06)
private let accent = Color.accentColor

/// Content blocks sit in inset containers, concentric with the island's corners, instead of running to its edge.
private struct HoustonCard: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: IslandStyle.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.045), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func houstonCard() -> some View { modifier(HoustonCard()) }
}

struct HoustonPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HoustonSectionHeading: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let count {
                Text(count, format: .number).monospacedDigit().font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
        }.foregroundStyle(.secondary)
    }
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
    Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(muted)
        .accessibilityAddTraits(.isHeader)
}

private extension PanelTab {
    var symbol: String {
        switch self {
        case .usage: "chart.bar.xaxis"
        case .system: "desktopcomputer"
        case .activity: "arrow.triangle.branch"
        case .tools: "slider.horizontal.3"
        case .agents: "terminal"
        case .projects: "folder"
        case .drop: "tray.and.arrow.down"
        }
    }
}

private struct HoustonMeter: View {
    let fraction: Double
    let color: Color
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.1))
            Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, fraction)))
                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: fraction)
        }.frame(height: height)
    }
}

private func meter(_ fraction: Double, color: Color, height: CGFloat = 4) -> some View {
    HoustonMeter(fraction: fraction, color: color, height: height)
}

struct IslandView: View {
    @ObservedObject var store: Store
    @State private var repositoryInput = ""
    @State private var apiKey = ""
    @State private var configuring: Provider?
    @State private var showHistory = false
    @State private var rotationStart = Date.now
    @FocusState private var editingField: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(store: Store, configuring: Provider? = nil) {
        self.store = store
        _configuring = State(initialValue: configuring)
    }

    var body: some View {
        island
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
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
            .onChange(of: store.requestedProvider) { _, provider in
                if let provider { configuring = provider; store.requestedProvider = nil }
            }
    }

    /// One black shape morphs between every presentation, so the notch appears to grow rather than open a window.
    /// The band beside the camera is shared by all three, which keeps its ring and reading in place while the rest unfolds.
    private var island: some View {
        let presentation = store.presentation
        let size = store.size(for: presentation)
        let notched = store.topInset > 0
        let shape = IslandShape.style(for: presentation, notched: notched)
        return ZStack(alignment: .top) {
            Color.black
            VStack(spacing: 0) {
                rotatingIsland(width: size.width, presentation: presentation)
                if presentation == .expanded {
                    expanded
                        .frame(width: store.expandedWidth, height: max(0, store.expandedHeight - store.bandHeight), alignment: .top)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -12)))
                } else if presentation == .peek, let peek = store.peek {
                    peekRow(peek).frame(width: size.width, height: IslandStyle.peekRowHeight)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay { keyLine(shape, presentation: presentation, notched: notched) }
        .onHover { inside in if inside { store.openIsland() } }
        .animation(IslandMotion.presentation(presentation, moment: store.peek?.moment, reduceMotion: reduceMotion), value: presentation)
    }

    @ViewBuilder private func keyLine(_ shape: IslandShape, presentation: IslandPresentation, notched: Bool) -> some View {
        if presentation != .compact {
            shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
                .mask {
                    VStack(spacing: 0) {
                        if notched {
                            // The top of the island is the camera housing; the key line only starts below it.
                            Color.clear.frame(height: store.topInset)
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 36)
                        }
                        Color.black
                    }
                }
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func rotatingIsland(width: CGFloat? = nil, notchWidth: CGFloat? = nil,
                                             presentation: IslandPresentation = .compact) -> some View {
        if store.compactProviders.count > 1 {
            TimelineView(.periodic(from: rotationStart, by: 6)) { context in
                band(at: context.date, width: width, notchWidth: notchWidth, presentation: presentation)
            }
        } else {
            TimelineView(.explicit(readingChangeDates)) { context in
                band(at: context.date, width: width, notchWidth: notchWidth, presentation: presentation)
            }
        }
    }

    private func band(at date: Date, width: CGFloat?, notchWidth: CGFloat?, presentation: IslandPresentation) -> CompactIsland {
        CompactIsland(store: store, date: min(date, .now), rotationStart: rotationStart, width: width, notchWidth: notchWidth,
                      presentation: presentation,
                      pin: { store.pinned.toggle(); editingField = nil },
                      collapse: { editingField = nil; store.expanded = false })
    }

    var readingChangeDates: [Date] {
        let quotaDates = store.enabled.flatMap { provider -> [Date] in
            guard let snapshot = store.snapshots[provider] else { return [] }
            return [snapshot.capturedAt.addingTimeInterval(601)] + snapshot.windows.compactMap(\.resetsAt)
        }
        let agentDates = store.agents.sessions.compactMap { $0.currentUntil?.addingTimeInterval(1) }
        return (quotaDates + agentDates).sorted()
    }

    private func peekRow(_ peek: IslandPeek) -> some View {
        Text(peek.detail)
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.72))
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.bottom, 4)
            .accessibilityHidden(true)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            navigation
                .padding(.horizontal, IslandStyle.pagePadding).padding(.top, 8).padding(.bottom, 14)

            ScrollView { page }.id(store.tab.rawValue + (store.tab == .agents ? store.agents.selectedSessionID ?? "" : "")).scrollIndicators(.automatic).frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if store.tab == .drop {
                    DropShelfFooter(shelf: store.dropShelf)
                } else if store.editing {
                    Label("Editing · Esc to close", systemImage: "pencil").foregroundStyle(muted)
                } else if store.tab == .system, let system = store.system {
                    Label("Live · every 2 s · up \(SystemFormat.uptime(system.uptime))", systemImage: "waveform.path.ecg").foregroundStyle(muted)
                }
                Spacer()
                if store.tab != .system && store.tab != .drop {
                    Button { store.refresh() } label: {
                        Label(store.refreshing ? "Updating…" : "Refresh", systemImage: "arrow.clockwise")
                    }.buttonStyle(.plain).foregroundStyle(muted).disabled(store.refreshing)
                        .help("Refresh readings (⌘R)")
                }
            }
            .font(.system(size: 11)).padding(.horizontal, 26).padding(.vertical, 13)
            .background(Color.white.opacity(0.035))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button { store.tab = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 16, weight: .medium))
                            .frame(height: 18).accessibilityHidden(true)
                        Text(tab.rawValue).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(store.tab == tab ? Color.primary : .secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(store.tab == tab ? Color.primary.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }.buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityAddTraits(store.tab == tab ? .isSelected : [])
                    .help("\(tab.rawValue) (⌘\((PanelTab.allCases.firstIndex(of: tab) ?? 0) + 1))")
            }
        }.padding(4)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.secondary, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Sections")
    }

    /// The current tab's content; also rendered on its own by the offscreen render test, which cannot see inside a ScrollView.
    var page: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch store.tab {
            case .usage: usage
            case .system: system
            case .activity: activity
            case .tools: tools
            case .agents: AgentSessionsView(monitor: store.agents)
            case .projects: ProjectsView(store: store)
            case .drop: DropShelfView(shelf: store.dropShelf)
            }
        }.padding(.horizontal, IslandStyle.pagePadding).padding(.top, 4).padding(.bottom, 24)
    }

    // MARK: Usage

    private var usage: some View {
        Group {
            if showHistory {
                Button { showHistory = false } label: {
                    Label("Current usage", systemImage: "chevron.left")
                }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 13, weight: .medium))
                    .padding(.bottom, 4)
                UsageHistoryView(history: store.history)
                if let error = store.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
            } else {
            HStack(alignment: .top, spacing: 12) {
                HoustonPageHeader(title: "AI usage", subtitle: "Your allowances, at a glance.")
                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }.buttonStyle(.plain).help("View your usage history").accessibilityLabel("Usage history")
            }
            if store.enabled.isEmpty {
                empty("Make room for your tools", detail: "Connect a provider to see its remaining allowance here.", symbol: "square.grid.2x2")
                Button("Choose providers") { store.tab = .tools }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            ForEach(Provider.allCases.filter { store.enabled.contains($0) }) { provider in
                UsageCard(provider: provider, store: store) {
                    store.tab = .tools; configuring = provider
                }
                if !store.accounts.accounts(for: provider).isEmpty {
                    AccountComparisonView(store: store.accounts, provider: provider, defaultSnapshot: store.defaultSnapshots[provider])
                }
            }
            }
        }
    }

    // MARK: Mac

    private var system: some View {
        Group {
            HoustonPageHeader(title: "This Mac", subtitle: store.system.map {
                "\($0.chip) · \($0.cores.isEmpty ? "" : "\($0.cores.count) cores · ")\(SystemFormat.memory($0.memoryTotal))"
            } ?? "A live look at your Mac.")
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
                                            .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: core.load)
                                    }.frame(height: 30)
                                    Text(core.efficiency ? "E" : "P").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(muted)
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
                        sectionTitle("Storage")
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
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().contentTransition(.numericText())
        }
    }

    // MARK: Tools

    private var tools: some View {
        Group {
            HoustonPageHeader(title: "Tools", subtitle: "Connections and preferences, in one place.")
            HStack {
                Button("Guided setup…") { UtilityWindow.shared.show(store: store, page: .setup) }
                Button("Connection health…") { UtilityWindow.shared.show(store: store, page: .health) }
            }.controlSize(.small)
            AppPreferencesView(services: store.appServices)
            HoustonSectionHeading(title: "Providers", count: store.enabled.count).padding(.top, 4)
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
                                    Text(store.enabled.contains(provider) ? store.reading(for: provider).status : "Not enabled")
                                        .font(.system(size: 11))
                                        .foregroundStyle(store.enabled.contains(provider) && store.reading(for: provider).needsAttention ? .orange : muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(configuring == provider ? 90 : 0))
                                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: configuring == provider)
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Configure \(provider.rawValue)")
                            .accessibilityValue((store.enabled.contains(provider) ? store.reading(for: provider).status : "Not enabled")
                                                + (configuring == provider ? ". Expanded" : ". Collapsed"))
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
                    if configuring == provider {
                        Divider()
                        Text(provider.connectionSource + " · " + provider.allowanceCoverage)
                            .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
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
                            Button("Check connection") { store.refresh(provider, allowInteraction: true) }
                                .disabled(store.loading.contains(provider)).buttonStyle(.bordered).controlSize(.small)
                        } else {
                            if provider == .cursor {
                                Button("Connect Cursor…") {
                                    ProviderSignIn.cursor.show { snapshot in
                                        store.connectedCursor(snapshot)
                                    }
                                }.buttonStyle(.borderedProminent).controlSize(.regular)
                            }
                            HStack {
                                Button("Check connection") { store.refresh(provider, allowInteraction: true) }.disabled(store.loading.contains(provider))
                                Button("Dashboard ↗") { NSWorkspace.shared.open(provider.dashboard) }
                            }.buttonStyle(.bordered).controlSize(.small)
                            if provider == .gemini {
                                Link("About Gemini Free account support ↗", destination: URL(string: "https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals")!)
                                    .font(.system(size: 11))
                            }
                        }
                        AccountsView(store: store.accounts, provider: provider, defaultSnapshot: store.defaultSnapshots[provider],
                                     onEditing: { store.editing = $0 })
                    }
                }.padding(14)
                if provider != Provider.allCases.last { Divider().padding(.leading, 54) }
              }
            }
            .houstonCard()
            Label("Credentials stay in their app or macOS Keychain.", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(muted)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Compact favorites", systemImage: "star").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(store.compactProviders.count) of 4").font(.system(size: 12)).foregroundStyle(muted)
                }
                GeometryReader { geometry in
                    rotatingIsland(width: geometry.size.width, notchWidth: 0)
                        .disabled(true).allowsHitTesting(false).accessibilityHidden(true)
                }.frame(height: store.bandHeight)
                    .background(.black, in: Capsule())
                    .overlay(Capsule().strokeBorder(IslandStyle.keyLine, lineWidth: 1))
                Text("Star up to four providers above. The island shows one at a time: its ring fills with what is left, and the reading rotates every six seconds beside your agent status.")
                    .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }.padding(16).houstonCard().padding(.top, 8)
            AlertSettingsView(alerts: store.alerts)
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
                    Text("Connect once with your browser or Claude Code sign-in. Houston then refreshes automatically.")
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
            HoustonPageHeader(title: "GitHub", subtitle: store.overview.map { "@\($0.login) · Activity and reviews." }
                              ?? (store.overviewLoading ? "Checking your GitHub account…" : "Pull requests, reviews, and notifications."))
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
        VStack(alignment: .leading, spacing: 10) {
            HoustonSectionHeading(title: title, count: items.count)
            VStack(spacing: 0) {
            if items.isEmpty {
                Label(message, systemImage: "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
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
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open \(item.title) on GitHub")
                if item.id != items.last?.id { Divider().padding(.leading, 44) }
            }
            }.houstonCard()
        }.padding(.top, 4)
    }

    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(accent)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 32)
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
                .contentTransition(.numericText())
            meter(fraction, color: fraction > 0.85 || warning ? .orange : accent)
            Text(caption).font(.system(size: 11)).foregroundStyle(warning ? .orange : muted).lineLimit(1)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).houstonCard()
        .accessibilityElement(children: .combine).accessibilityLabel("\(title): \(value), \(caption)")
    }
}

/// A provider's logo inside a ring that fills with the remaining allowance: one glance carries the reading even when
/// the trailing side is busy showing an agent.
struct ProviderRing: View {
    let provider: Provider
    let reading: ProviderReading
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let unlimited = reading.value.contains("∞")
        let fraction = max(0, min(1, reading.remaining.map { $0 / 100 } ?? (unlimited ? 1 : 0)))
        let tint: Color = reading.needsAttention ? .orange : provider.color
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 2.5)
            Circle().inset(by: 1.25).trim(from: 0, to: fraction)
                .stroke(tint.opacity(reading.value.hasPrefix("~") ? 0.55 : 1), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.8), value: fraction)
            BrandLogo(name: provider.logo, size: size * 0.5,
                      color: .white.opacity(reading.remaining == nil && !unlimited ? 0.5 : 0.95))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The session that matters most, beside the camera: a ring of dots turns while it works, a hand breathes while it
/// waits for you, and a finished or failed turn holds its mark. The continuous motion runs on the render server
/// (a repeating symbol effect costs a fifth of a core in a hosted SwiftUI window), and each change of state swaps
/// the mark with a small scale-and-fade.
private struct AgentIndicator: View {
    let session: AgentSession
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            switch session.status {
            case .running:
                WorkingOrbit(tint: .white, size: 16, turning: !reduceMotion).frame(width: 16, height: 16).transition(enter)
            case .waiting:
                BreathingSymbol(name: "hand.raised.fill", tint: .systemOrange, pointSize: 13, breathing: !reduceMotion)
                    .frame(width: 18, height: 18).transition(enter)
            default:
                Image(systemName: symbol).transition(enter)
            }
            if count > 1 { Text("\(count)").monospacedDigit().contentTransition(reduceMotion ? .opacity : .numericText()) }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }

    private var enter: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)) }

    private var symbol: String {
        switch session.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "hand.raised.fill"
        }
    }

    private var tint: Color {
        switch session.status {
        case .running: .white
        case .completed: .green
        case .failed: .red
        default: .orange
        }
    }
}

/// The strip beside the camera. Leading and trailing read as one piece of information, snug against the camera,
/// and stay put while the island grows, so the open panel is visibly the same object as the compact strip.
struct CompactIsland: View {
    @ObservedObject var store: Store
    var date: Date = .now
    var rotationStart: Date = .now
    var width: CGFloat?
    var notchWidth: CGFloat?
    var presentation: IslandPresentation = .compact
    var pin: (() -> Void)? = nil
    var collapse: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var activeAgents: [AgentSession] { store.activeAgents(at: date) }

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
        let notched = camera > 0 && store.topInset > 0
        // Keep clear of the flared corner on a notch; a detached pill needs an even, concentric margin.
        let edge: CGFloat = notched ? IslandShape.style(for: presentation, notched: true).earRadius + 4 : 14
        let gap: CGFloat = camera > 0 ? 6 : 4
        let peek = presentation == .peek ? store.peek : nil
        let motion = reduceMotion ? nil : IslandMotion.content(reduceMotion: false)
        HStack(spacing: 0) {
            HStack(spacing: presentation == .expanded ? 8 : 0) {
                if presentation == .expanded {
                    edgeButton(store.pinned ? "pin.fill" : "pin", "Keep Houston open", active: store.pinned, action: pin)
                }
                Spacer(minLength: 0)
                leading(peek)
            }
            .padding(.leading, edge).padding(.trailing, gap).frame(width: side, alignment: .trailing).clipped()
            Color.clear.frame(width: camera).accessibilityHidden(true)
            HStack(spacing: presentation == .expanded ? 8 : 0) {
                trailing(peek)
                Spacer(minLength: 0)
                if presentation == .expanded {
                    edgeButton("chevron.up", "Collapse panel", active: false, action: collapse)
                }
            }
            .padding(.trailing, edge).padding(.leading, gap).frame(width: side, alignment: .leading).clipped()
        }
        .frame(width: totalWidth, height: store.bandHeight)
        .contentShape(Rectangle())
        .onTapGesture { store.openIsland(defaultTab: .usage, at: date) }
        .animation(motion, value: displayedProvider)
        .animation(motion, value: peek?.id)
        .animation(motion, value: activeAgents.first.map { $0.id + $0.status.rawValue } ?? "")
        .animation(motion, value: activeAgents.count)
        .animation(motion, value: store.dropShelf.items.count)
        .accessibilityElement(children: presentation == .expanded ? .contain : .ignore)
        .accessibilityLabel(presentation == .expanded ? "Houston" : peek != nil ? "Open Houston alert" : !store.dropShelf.items.isEmpty ? "Open Houston Drop shelf" : activeAgents.isEmpty ? "Open Houston usage panel" : "Open Houston agent sessions")
        .accessibilityValue(summary(peek))
        .accessibilityAddTraits(presentation == .expanded ? [] : .isButton)
        .accessibilityAction { store.openIsland(defaultTab: .usage, at: date) }
        .help(presentation == .expanded ? "" : summary(peek) + (peek != nil ? "\nClick to open" : !store.dropShelf.items.isEmpty ? "\nClick to open Drop shelf" : activeAgents.isEmpty ? "\nClick to see all providers" : "\nClick to see agent sessions"))
    }

    private var ringSize: CGFloat { store.bandHeight >= 38 ? 22 : 20 }
    private var swap: AnyTransition { reduceMotion ? .opacity : AnyTransition(BlurReplaceTransition(configuration: .downUp)) }

    @ViewBuilder private func leading(_ peek: IslandPeek?) -> some View {
        if let peek {
            MomentBadge(peek: peek, size: ringSize).transition(swap)
        } else if !store.dropShelf.items.isEmpty {
            Image(systemName: "tray.full.fill").font(.system(size: 18)).foregroundStyle(.cyan).transition(swap)
        } else if let provider = displayedProvider {
            ProviderRing(provider: provider, reading: store.reading(for: provider, at: date), size: ringSize)
                .id(provider).transition(swap)
        } else {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.95)).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func trailing(_ peek: IslandPeek?) -> some View {
        if let peek {
            Text(peek.headline).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.8).transition(swap)
        } else if !store.dropShelf.items.isEmpty {
            Text("\(store.dropShelf.items.count) held").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7).transition(swap)
        } else if let session = activeAgents.first {
            AgentIndicator(session: session, count: activeAgents.count).transition(swap)
        } else if let provider = displayedProvider {
            let reading = store.reading(for: provider, at: date)
            Text(reading.value)
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(reading.needsAttention ? Color.orange : Color.white)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(IslandMotion.content(reduceMotion: reduceMotion), value: reading.value)
                .lineLimit(1).minimumScaleFactor(0.7)
                .transition(.opacity)
        } else {
            Text("Houston").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        }
    }

    private func edgeButton(_ symbol: String, _ label: String, active: Bool, action: (() -> Void)?) -> some View {
        let isPin = symbol.hasPrefix("pin")
        return Button { action?() } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(active ? 0.16 : 0.09), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isPin ? "Keep Houston open (⌘P)" : label)
        .accessibilityLabel(label)
        .accessibilityValue(isPin ? (active ? "On" : "Off") : "")
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
    }

    private func summary(_ peek: IslandPeek?) -> String {
        if let peek { return peek.title + " · " + peek.detail }
        if !store.dropShelf.items.isEmpty { return "\(store.dropShelf.items.count) items held in Drop shelf" }
        var text = "Houston · Choose compact favorites in Tools"
        if let provider = displayedProvider {
            let reading = store.reading(for: provider, at: date)
            text = "\(provider.rawValue): \(reading.value) remaining · \(reading.status)"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let reading = store.reading(for: provider, at: context.date)
            let snapshot = store.snapshots[provider]
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    BrandLogo(name: provider.logo, size: 23, color: provider.color)
                        .frame(width: 38, height: 38).background(provider.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                                .contentTransition(.numericText())
                                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: reading.value)
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
                            .disabled(reading.isLoading)
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
                    if let account = store.accounts.selectedAccount(for: provider) {
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
                    if let identity = store.historyAccountID(for: provider), let window = snapshot.windows.first,
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
