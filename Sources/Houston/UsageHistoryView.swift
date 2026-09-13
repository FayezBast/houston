import SwiftUI
import Charts
import HoustonCore

struct UsageHistoryView: View {
    let history: UsageHistory
    @State private var provider = ""
    @State private var account = ""
    @State private var window: UsageHistorySample.Scope?
    @State private var days = 7

    private var providers: [String] { Array(Set(history.samples.map(\.provider))).sorted() }
    private var selectedProvider: String { providers.contains(provider) ? provider : providers.first ?? "" }
    private var accounts: [UsageHistorySample] {
        var seen = Set<String>()
        return history.samples.reversed().filter { $0.provider == selectedProvider && seen.insert($0.accountID).inserted }
            .sorted { $0.accountLabel.localizedStandardCompare($1.accountLabel) == .orderedAscending }
    }
    private var selectedAccount: String { accounts.contains { $0.accountID == account } ? account : accounts.first?.accountID ?? "" }
    private var windows: [UsageHistorySample] {
        var seen = Set<UsageHistorySample.Scope>()
        return history.samples.reversed().filter {
            $0.provider == selectedProvider && $0.accountID == selectedAccount && seen.insert($0.scope).inserted
        }.sorted { $0.metric == $1.metric ? $0.window < $1.window : $0.metric.rawValue < $1.metric.rawValue }
    }
    private var selectedWindow: UsageHistorySample? { windows.first { $0.scope == window } ?? windows.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HoustonPageHeader(title: "Usage history", subtitle: "Understand how your usage changes over time.")
            if history.samples.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 52, height: 52)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .padding(.bottom, 4).accessibilityHidden(true)
                    Text("Your history starts here").font(.system(size: 15, weight: .semibold))
                    Text("Connect an account in Tools. Houston saves usage readings on this Mac as your accounts update.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 28).houstonCard()
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                    GridRow {
                        Text("Provider").foregroundStyle(.secondary)
                        Picker("Provider", selection: Binding(get: { selectedProvider }, set: { provider = $0; account = ""; window = nil })) {
                            ForEach(providers, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        Text("Account").foregroundStyle(.secondary)
                        Picker("Account", selection: Binding(get: { selectedAccount }, set: { account = $0; window = nil })) {
                            ForEach(accounts, id: \.accountID) { Text($0.accountLabel).tag($0.accountID) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    GridRow {
                        Text("Window").foregroundStyle(.secondary)
                        Picker("Window", selection: Binding(get: { selectedWindow?.scope }, set: { window = $0 })) {
                            ForEach(windows, id: \.scope) { sample in
                                Text(sample.window + (sample.metric == .spend ? " · \(sample.currency ?? "USD")" : " · %"))
                                    .tag(Optional(sample.scope))
                            }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.font(.system(size: 12)).controlSize(.regular).padding(16).houstonCard()
                VStack(spacing: 12) {
                    Picker("History period", selection: $days) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                    if let selectedWindow {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            chart(for: selectedWindow, now: context.date)
                        }
                    }
                }
                Label("Up to 90 days saved on this Mac. Gaps appear when no fresh readings are available.", systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder private func chart(for selected: UsageHistorySample, now: Date) -> some View {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let samples = history.samples.filter { $0.scope == selected.scope && $0.capturedAt >= since && $0.capturedAt <= now }
        if let latest = samples.last {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.metric == .spend ? "Reported API spend" : selected.provider == "OpenRouter" ? "API budget used" : "Allowance used")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(value(latest)).font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit().tracking(-0.8)
                        .lineLimit(1).minimumScaleFactor(0.65)
                    Text("Last observed \(latest.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Chart(plotPoints(samples)) { point in
                    LineMark(x: .value("Date", point.sample.capturedAt), y: .value(axisLabel(selected), point.sample.used),
                             series: .value("Observed segment", point.segment))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Provider(rawValue: selected.provider)?.color ?? .accentColor)
                    PointMark(x: .value("Date", point.sample.capturedAt), y: .value(axisLabel(selected), point.sample.used))
                        .symbolSize(samples.count > 100 ? 3 : 10)
                        .foregroundStyle(Provider(rawValue: selected.provider)?.color ?? .accentColor)
                }
                .chartXScale(domain: since...now)
                .chartYScale(domain: selected.metric == .quota ? 0...100 : 0...max(1, (samples.map(\.used).max() ?? 0) * 1.1))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: days == 7 ? 2 : 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 160)
                .accessibilityLabel("\(selected.provider), \(selected.accountLabel), \(selected.window), \(days)-day history")
                .accessibilityValue("Latest reading \(value(latest))")

                if samples.count == 1 {
                    Text("Your first reading is saved. A trend will appear as more readings arrive.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if selected.metric == .spend {
                    Text("\(selected.window) · reported in \(latest.currency ?? "USD")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let first = samples.first, samples.count > 1,
                       zip(samples, samples.dropFirst()).allSatisfy({ $0.used <= $1.used }) {
                        Text("Observed increase: \((latest.used - first.used).formatted(.currency(code: latest.currency ?? "USD")))")
                            .font(.system(size: 12, weight: .medium))
                    }
                } else {
                    let hits = history.observedLimitHits(provider: selected.provider, accountID: selected.accountID, window: selected.window, since: since)
                    Label(hits == 0 ? "No limit reached in the saved readings" : "Limit reached in \(hits) \(hits == 1 ? "window" : "windows") over \(days) days",
                          systemImage: hits == 0 ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    UsagePaceLabel(history: history, provider: selected.provider, accountID: selected.accountID, window: selected.window, now: now)
                }
            }
            .padding(16).houstonCard()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 24)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("No readings in \(days) days").font(.system(size: 14, weight: .semibold))
                Text("Choose another period, account or usage window.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(24).houstonCard()
        }
    }

    private func value(_ sample: UsageHistorySample) -> String {
        sample.metric == .spend ? sample.used.formatted(.currency(code: sample.currency ?? "USD")) : "\(sample.used.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private struct PlotPoint: Identifiable {
        let sample: UsageHistorySample
        let segment: Int
        var id: UUID { sample.id }
    }

    private func plotPoints(_ samples: [UsageHistorySample]) -> [PlotPoint] {
        var segment = 0
        return samples.enumerated().map { index, sample in
            if index > 0, sample.resetsAt != samples[index - 1].resetsAt || sample.capturedAt.timeIntervalSince(samples[index - 1].capturedAt) > 900 {
                segment += 1
            }
            return PlotPoint(sample: sample, segment: segment)
        }
    }

    private func axisLabel(_ sample: UsageHistorySample) -> String {
        sample.metric == .spend ? "Spend (\(sample.currency ?? "USD"))" : "Used (%)"
    }
}

struct UsagePaceLabel: View {
    let history: UsageHistory
    let provider: String
    let accountID: String
    let window: String
    var now: Date = .now

    var body: some View {
        if let estimate = history.forecast(provider: provider, accountID: accountID, window: window, now: now) {
            Label {
                Text(estimate.runsOutBeforeReset
                     ? "At recent pace, allowance may run out \(estimate.exhaustionDate.formatted(date: .abbreviated, time: .shortened)), before reset."
                     : "At recent pace, this allowance is expected to last until reset.")
                    .foregroundStyle(estimate.runsOutBeforeReset ? Color.primary : Color.secondary)
            } icon: {
                Image(systemName: estimate.runsOutBeforeReset ? "exclamationmark.triangle" : "chart.line.uptrend.xyaxis")
                    .foregroundStyle(estimate.runsOutBeforeReset ? Color.orange : Color.secondary)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("A pace estimate appears after fresh, increasing readings at least 5 minutes apart in one reset cycle.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
