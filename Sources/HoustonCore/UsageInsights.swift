import Foundation

/// A reported currency amount, kept separate from subscription allowance percentages.
public struct UsageSpend: Sendable, Equatable {
    public let used: Double
    public let budget: Double?
    public let currency: String
    public let period: String

    public init(used: Double, budget: Double? = nil, currency: String = "USD", period: String = "Key total") {
        self.used = used
        self.budget = budget
        self.currency = currency
        self.period = period
    }
}

public struct UsageHistorySample: Codable, Sendable, Equatable, Identifiable {
    public enum Metric: String, Codable, Sendable { case quota, spend }
    public struct Scope: Hashable, Sendable {
        public let provider: String
        public let accountID: String
        public let window: String
        public let metric: Metric
        public let currency: String?
    }

    public let id: UUID
    public let provider: String
    public let accountID: String
    public let accountLabel: String
    public let window: String
    public let capturedAt: Date
    public let used: Double
    public let resetsAt: Date?
    public let metric: Metric
    public let currency: String?
    public let budget: Double?

    public var remaining: Double { max(0, 100 - used) }

    public var scope: Scope {
        Scope(provider: provider, accountID: accountID, window: window, metric: metric, currency: currency)
    }
}

public struct QuotaAlert: Sendable, Equatable {
    public enum Kind: String, Sendable { case lowQuota, reset }
    public let kind: Kind
    public let provider: String
    public let accountID: String
    public let accountLabel: String
    public let window: String
    public let remaining: Double
}

public struct UsagePaceEstimate: Sendable, Equatable {
    public let exhaustionDate: Date
    public let resetDate: Date
    public let percentPerHour: Double
    public var runsOutBeforeReset: Bool { exhaustionDate < resetDate }
}

/// Local observations, never inferred provider totals. Initial observations establish a silent alert baseline.
public struct UsageHistory: Codable, Sendable {
    public private(set) var samples: [UsageHistorySample] = []
    public static let retention: TimeInterval = 90 * 86_400
    private static let maximumSamples = 100_000
    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Houston/usage-history.json")
    }

    public init() {}

    public static func load(from file: URL = defaultFile, now: Date = .now) throws -> UsageHistory {
        guard FileManager.default.fileExists(atPath: file.path) else { return UsageHistory() }
        var history = try JSONDecoder().decode(UsageHistory.self, from: Data(contentsOf: file))
        history.samples.removeAll { $0.capturedAt > now.addingTimeInterval(5) || !$0.used.isFinite || $0.used < 0 }
        history.samples.sort { $0.capturedAt < $1.capturedAt }
        history.prune(now: now)
        return history
    }

    public func save(to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    /// Call only for successful live reads. A cached timestamp is preserved by the reader.
    @discardableResult public mutating func record(snapshot: UsageSnapshot, provider: String, accountID: String,
                                                   accountLabel: String, remainingThreshold: Double = 20,
                                                   now: Date = .now) -> [QuotaAlert] {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        guard age >= -5, age <= 600, !provider.isEmpty, !accountID.isEmpty else { return [] }
        let threshold = remainingThreshold.isFinite ? min(100, max(0, remainingThreshold)) : 20
        var alerts: [QuotaAlert] = []
        for window in snapshot.windows where window.used.isFinite && window.used >= 0 && !window.expired(at: now) {
            let sample = UsageHistorySample(id: UUID(), provider: provider, accountID: accountID,
                accountLabel: accountLabel, window: window.name, capturedAt: snapshot.capturedAt,
                used: min(100, window.used), resetsAt: window.resetsAt, metric: .quota, currency: nil, budget: nil)
            let previous = samples.last { $0.scope == sample.scope }
            guard previous.map({ $0.capturedAt < sample.capturedAt }) ?? true else { continue }
            if let previous {
                let reset = previous.resetsAt.map { old in
                    old <= sample.capturedAt && sample.resetsAt.map { $0 > old && $0 > now } == true
                } ?? false
                if reset {
                    alerts.append(alert(.reset, sample: sample))
                } else if previous.resetsAt == sample.resetsAt,
                          previous.remaining > threshold, sample.remaining <= threshold,
                          !samples.contains(where: { $0.scope == sample.scope && $0.resetsAt == sample.resetsAt && $0.remaining <= threshold }) {
                    alerts.append(alert(.lowQuota, sample: sample))
                }
            }
            append(sample)
        }
        if let spend = snapshot.spend, spend.used.isFinite, spend.used >= 0, !spend.currency.isEmpty {
            let sample = UsageHistorySample(id: UUID(), provider: provider, accountID: accountID,
                accountLabel: accountLabel, window: spend.period, capturedAt: snapshot.capturedAt,
                used: spend.used, resetsAt: nil, metric: .spend, currency: spend.currency,
                budget: spend.budget.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
            if samples.last(where: { $0.scope == sample.scope }).map({ $0.capturedAt < sample.capturedAt }) ?? true {
                append(sample)
            }
        }
        prune(now: now)
        return alerts
    }

    public func observations(provider: String, accountID: String, window: String,
                             metric: UsageHistorySample.Metric = .quota, since: Date = .distantPast) -> [UsageHistorySample] {
        samples.filter { $0.provider == provider && $0.accountID == accountID && $0.window == window && $0.metric == metric && $0.capturedAt >= since }
    }

    /// Forecast only from a fresh, increasing series in the same known reset cycle.
    public func forecast(provider: String, accountID: String, window: String, now: Date = .now) -> UsagePaceEstimate? {
        let readings = observations(provider: provider, accountID: accountID, window: window)
        guard let latest = readings.last, latest.capturedAt <= now.addingTimeInterval(5),
              now.timeIntervalSince(latest.capturedAt) <= 600, latest.used < 100,
              let reset = latest.resetsAt, reset > now else { return nil }
        // ponytail: a six-hour linear pace is an estimate; add a richer model only with enough observed history to validate it.
        let recent = readings.filter { $0.resetsAt == reset && $0.capturedAt >= latest.capturedAt.addingTimeInterval(-6 * 3600) }
        guard let first = recent.first, recent.count >= 2,
              latest.capturedAt.timeIntervalSince(first.capturedAt) >= 300,
              zip(recent, recent.dropFirst()).allSatisfy({ $0.used <= $1.used }), latest.used > first.used else { return nil }
        let rate = (latest.used - first.used) / latest.capturedAt.timeIntervalSince(first.capturedAt)
        let exhausted = latest.capturedAt.addingTimeInterval((100 - latest.used) / rate)
        guard exhausted > now else { return nil }
        return UsagePaceEstimate(exhaustionDate: exhausted, resetDate: reset, percentPerHour: rate * 3600)
    }

    /// Count distinct observed exhausted cycles. Unknown reset times count only a newly observed crossing.
    public func observedLimitHits(provider: String, accountID: String, window: String, since: Date) -> Int {
        let readings = observations(provider: provider, accountID: accountID, window: window)
        var cycles = Set<Date>()
        var hits = 0
        var previous: UsageHistorySample?
        for sample in readings {
            if sample.capturedAt >= since, sample.used >= 100 {
                if let reset = sample.resetsAt {
                    if cycles.insert(reset).inserted { hits += 1 }
                } else if (previous?.used ?? 0) < 100 { hits += 1 }
            }
            previous = sample
        }
        return hits
    }

    private func alert(_ kind: QuotaAlert.Kind, sample: UsageHistorySample) -> QuotaAlert {
        QuotaAlert(kind: kind, provider: sample.provider, accountID: sample.accountID,
                   accountLabel: sample.accountLabel, window: sample.window, remaining: sample.remaining)
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let expired = samples.firstIndex { $0.capturedAt >= cutoff } ?? samples.count
        if expired > 0 { samples.removeFirst(expired) }
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
    }

    private mutating func append(_ sample: UsageHistorySample) {
        // Different providers can complete out of order; only a late response needs insertion.
        if samples.last.map({ $0.capturedAt <= sample.capturedAt }) ?? true { samples.append(sample) }
        else {
            let index = samples.lastIndex { $0.capturedAt <= sample.capturedAt }.map { $0 + 1 } ?? 0
            samples.insert(sample, at: index)
        }
    }
}
