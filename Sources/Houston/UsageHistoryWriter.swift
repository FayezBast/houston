import Foundation
import HoustonCore

/// Serialize archive writes off the main actor, in collection order.
actor UsageHistoryWriter {
    func save(_ history: UsageHistory, to file: URL) -> String? {
        do { try history.save(to: file); return nil }
        catch { return "Usage history could not be saved. Check available disk space and folder access." }
    }
}
