import SwiftUI
import HoustonCore

struct AgentSessionsView: View {
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HoustonPageHeader(title: "Your agents", subtitle: "See when a response is ready or your agent needs input.")

            if monitor.sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 52, height: 52)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .padding(.bottom, 4).accessibilityHidden(true)
                    Text("Ready when you are").font(.system(size: 15, weight: .semibold))
                    Text(monitor.configured.isEmpty
                         ? "Connect an agent below to follow its progress here."
                         : "Start a conversation in a connected agent. Its next update will appear here.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 28).houstonCard()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HoustonSectionHeading(title: "Recent sessions", count: monitor.sessions.count)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(spacing: 10) {
                            ForEach(monitor.sessions) { session in sessionRow(session, now: context.date) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HoustonSectionHeading(title: "Connections")
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AgentProvider.allCases) { provider in
                        if provider != AgentProvider.allCases.first { Divider().padding(.leading, 44) }
                        HStack(spacing: 12) {
                            BrandLogo(name: provider.logoName, size: 18)
                                .frame(width: 32, height: 32)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.name).font(.system(size: 13, weight: .medium))
                                if monitor.configured.contains(provider) {
                                    Label("Hooks saved", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if monitor.configured.contains(provider) {
                                Menu {
                                    Button("Update hooks") { monitor.setup(provider: provider) }
                                    Button("Disconnect", role: .destructive) { monitor.disconnect(provider: provider) }
                                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel("\(provider.name) connection options")
                            } else {
                                Button("Connect") { monitor.setup(provider: provider) }.controlSize(.regular)
                                    .accessibilityLabel("Connect \(provider.name) session status")
                            }
                        }
                    }
                }.padding(16).houstonCard()
                Text("Review Houston in /hooks for Claude Code or Codex, or Customize → Hooks in Cursor.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                DisclosureGroup("About session status") {
                    Text("Houston reads the latest session event. Response ready means the current response has ended. Codex and Cursor may not report every request for input. Only session metadata is saved on this Mac. Cursor uses the first folder in a workspace.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }

            if let message = monitor.setupMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let error = monitor.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .onAppear { monitor.refreshConfiguration() }
    }

    private func sessionRow(_ session: AgentSession, now: Date) -> some View {
        let stale = session.isStale(at: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(session.status)).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(stale ? .secondary : color(session.status))
                    .frame(width: 36, height: 36)
                    .background((stale ? Color.secondary : color(session.status)).opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.projectName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(session.provider.name).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { monitor.dismiss(session: session) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss session until its next event")
                .accessibilityLabel("Dismiss \(session.provider.name) session in \(session.projectName)")
            }
            let status = Text(session.status.title + (stale ? " · last known" : ""))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(stale ? Color.secondary : Color.primary)
            let updated = Text(session.updatedAt, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityLabel("Last updated").accessibilityValue(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    status.fixedSize()
                    Spacer(minLength: 8)
                    updated.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) { status; updated }
            }
            if stale {
                Text("No recent events. Open the session to check its progress.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(session.provider == .codex ? "Open session" : "Open project") { monitor.open(session: session) }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer(minLength: 0)
                if session.resumeCommand != nil {
                    Button { monitor.copyResumeCommand(session: session) } label: {
                        Label("Copy command", systemImage: "doc.on.doc")
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("Copy the command to resume this session in Terminal")
                        .accessibilityLabel("Copy resume command for \(session.projectName)")
                }
            }
        }
        .padding(16).houstonCard()
        .help(session.projectPath + " · " + session.sessionID)
    }

    private func color(_ status: AgentStatus) -> Color {
        switch status {
        case .running: .blue
        case .waiting, .interrupted: .orange
        case .failed: .red
        case .completed: .green
        case .idle, .ended: .secondary
        }
    }

    private func symbol(_ status: AgentStatus) -> String {
        switch status {
        case .running: "circle.dotted"
        case .waiting: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .interrupted: "pause.circle"
        case .idle: "terminal"
        case .ended: "stop.circle"
        }
    }
}
