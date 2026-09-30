import SwiftUI
import HoustonCore

/// The small open island: what is live right now, the favorite allowances, and a way into every section. Like the
/// Dynamic Island's expanded view it is sized to its content, and the full pages open only when something is chosen.
struct IslandHome: View {
    @ObservedObject var store: Store

    nonisolated private static let rowHeight: CGFloat = 44
    nonisolated private static let rowSpacing: CGFloat = 6
    nonisolated private static let tileHeight: CGFloat = 50
    nonisolated private static let dockHeight: CGFloat = 46
    nonisolated private static let spacing: CGFloat = 10
    nonisolated private static let top: CGFloat = 2
    nonisolated private static let bottom: CGFloat = 12

    /// The height under the band, known before the island opens so the panel can make room for the spring.
    nonisolated static func height(agentRows: Int) -> CGFloat {
        let agents = agentRows > 0 ? CGFloat(agentRows) * rowHeight + CGFloat(agentRows - 1) * rowSpacing + spacing : 0
        return top + agents + tileHeight + spacing + dockHeight + bottom
    }

    var body: some View {
        let agents = store.homeAgents
        VStack(spacing: Self.spacing) {
            if !agents.isEmpty {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(agents) { session in
                        HomeAgentRow(session: session) {
                            store.agents.selectedSessionID = session.id
                            store.openPage(.agents)
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
            }
            favorites.frame(height: Self.tileHeight)
            dock.frame(height: Self.dockHeight)
        }
        // Clear of the island's walls, which sit inside the flared ears.
        .padding(.horizontal, 22).padding(.top, Self.top).padding(.bottom, Self.bottom)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var favorites: some View {
        HStack(spacing: 8) {
            let providers = store.compactProviders
            if providers.isEmpty {
                Button { store.openPage(.tools) } label: {
                    Label("Star up to four providers in Tools to keep them here", systemImage: "star")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(IslandRowStyle())
            } else {
                ForEach(providers) { provider in
                    let reading = store.reading(for: provider)
                    Button { store.openPage(.usage) } label: {
                        HStack(spacing: 8) {
                            ProviderRing(provider: provider, reading: reading, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(reading.value)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(reading.needsAttention ? Color.orange : .white)
                                    .contentTransition(.numericText())
                                Text(caption(provider, named: providers.count <= 2)).font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                            }.lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(IslandRowStyle())
                    .help("\(provider.rawValue): \(reading.value) remaining · \(reading.status)")
                    .accessibilityLabel("\(provider.rawValue) usage")
                    .accessibilityValue("\(reading.value) remaining, \(reading.status)")
                }
            }
        }
    }

    /// When the allowance comes back, which the ring and percentage cannot say; wide tiles also name the provider.
    private func caption(_ provider: Provider, named: Bool) -> String {
        guard let window = store.snapshots[provider]?.windows.first, window.resetsAt != nil, !window.expired(at: .now) else {
            return provider.rawValue
        }
        let reset = window.countdown().replacingOccurrences(of: "Resets in ", with: "↻ ")
        return named ? provider.rawValue + " · " + reset : reset
    }

    private var dock: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button { store.openPage(tab) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 14, weight: .medium)).frame(height: 17)
                            .overlay(alignment: .topTrailing) { badge(for: tab) }
                        Text(tab.rawValue).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(IslandRowStyle(radius: 12, fill: 0))
                .help("\(tab.rawValue) (⌘\((PanelTab.allCases.firstIndex(of: tab) ?? 0) + 1))")
                .accessibilityLabel(tab.rawValue)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Sections")
    }

    @ViewBuilder private func badge(for tab: PanelTab) -> some View {
        let count = tab == .drop ? store.dropShelf.items.count : tab == .agents ? store.homeAgents.count : 0
        if count > 0 {
            Text("\(count)").font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.black).padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                .background(tab == .drop ? Color.cyan : .white, in: Capsule())
                .offset(x: 10, y: -6)
                .accessibilityHidden(true)
        }
    }
}

/// One live session in the home view: the agent's mark, the project, and what it is doing now.
private struct HomeAgentRow: View {
    let session: AgentSession
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                BrandLogo(name: session.provider.logoName, size: 15, color: .white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(session.provider.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }.lineLimit(1)
                Spacer(minLength: 8)
                status
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(IslandRowStyle())
        .help(session.projectPath)
        .accessibilityLabel("\(session.provider.name) in \(session.projectName)")
        .accessibilityValue(session.status.title)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            switch session.status {
            case .running:
                WorkingOrbit(tint: .white, size: 14, turning: !reduceMotion).frame(width: 14, height: 14)
                if let start = session.turnStartedAt {
                    Text(start, style: .timer).monospacedDigit().foregroundStyle(.white.opacity(0.85)).fixedSize()
                } else { Text("Working").foregroundStyle(.white.opacity(0.85)) }
            case .waiting:
                BreathingSymbol(name: "hand.raised.fill", tint: .systemOrange, pointSize: 12, breathing: !reduceMotion)
                    .frame(width: 16, height: 16)
                Text("Needs input").foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(session.turnDuration.map { "Took " + IslandPeek.duration($0) } ?? "Response ready").foregroundStyle(.white.opacity(0.85))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Turn failed").foregroundStyle(.white.opacity(0.85))
            default:
                Text(session.status.title).foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}

/// A notification dropped down from the notch: the brand it concerns, what happened, and where to go from here.
/// Pointing at it holds it open; clicking anywhere opens it like the Open button.
struct IslandBanner: View {
    let peek: IslandPeek
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 12) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                Text(peek.bannerTitle).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text(peek.bannerSubtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).truncationMode(.middle)
            }.lineLimit(1)
            Spacer(minLength: 6)
            Button("Dismiss") { store.dismissPeek() }.buttonStyle(IslandPillStyle())
                .help("Dismiss this notification; it stays in Recent alerts")
            Button("Open") { store.open(peek) }.buttonStyle(IslandPillStyle(prominent: true))
                .help(peek.tab == .activity && peek.url != nil ? "Open on GitHub" : "Show in Houston")
        }
        // Clear of the flared ears and the rounded corners below them.
        .padding(.horizontal, 24).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { store.open(peek) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(peek.bannerTitle)
        .accessibilityValue(peek.bannerSubtitle)
    }

    private var mark: some View {
        Group {
            if let mark = peek.mark { BrandLogo(name: mark, size: 18, color: .white) }
            else { Image(systemName: peek.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(peek.tint) }
        }
        .frame(width: 34, height: 34)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Rows and tiles on the black island: a quiet fill that brightens under the pointer and dips when pressed.
struct IslandRowStyle: ButtonStyle {
    var radius: CGFloat = 14
    var fill: Double = 0.07

    func makeBody(configuration: Configuration) -> some View {
        IslandRowBody(configuration: configuration, radius: radius, fill: fill)
    }
}

private struct IslandRowBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    let fill: Double
    @State private var hovering = false

    var body: some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(Color.white.opacity(fill + (configuration.isPressed ? 0.1 : hovering ? 0.06 : 0)),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The banner's actions: a white capsule for the way forward and a quiet one beside it.
struct IslandPillStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : .white)
            .padding(.horizontal, 12).frame(height: 26)
            .background(prominent ? Color.white : Color.white.opacity(0.15), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
