import Foundation

/// One good live usage read of one account. The forecast in the auto-switch ranking uses these.
public struct UsageReading: Equatable, Sendable {
    /// Read time (epoch seconds).
    public let at: Double
    public let account: String
    public let fivePercent: Double
    public let weeklyPercent: Double

    public init(at: Double, account: String, fivePercent: Double, weeklyPercent: Double) {
        self.at = at; self.account = account; self.fivePercent = fivePercent; self.weeklyPercent = weeklyPercent
    }
}

/// The app's own history of live usage reads, for every account, kept for 35 days on this Mac.
/// Readings are in time order; readings of the same time are in account order.
public enum UsageHistory {
    public static let keep: Double = 35 * 86400

    /// The history after a live read: one reading for each good read with a weekly limit (a read with
    /// no 5-hour limit means no session started: 0%), and no reading older than 35 days.
    public static func record(_ history: [UsageReading], reads: [String: LiveAccountUsage], now: Double) -> [UsageReading] {
        let new = reads.sorted { $0.key < $1.key }.compactMap { id, u -> UsageReading? in
            guard u.ok, let week = u.limit("weekly_all") else { return nil }
            return UsageReading(at: now, account: id, fivePercent: u.limit("session")?.percent ?? 0, weeklyPercent: week.percent)
        }
        return (history + new).filter { now - $0.at <= keep }
    }

    /// The stored form: for each account, a list of [time, 5-hour percent, weekly percent].
    /// About 25 bytes for each reading, so 35 days of reads fit in the app's preferences.
    public static func encode(_ history: [UsageReading]) -> Data {
        let grouped = Dictionary(grouping: history, by: \.account).mapValues { $0.map { [$0.at, $0.fivePercent, $0.weeklyPercent] } }
        return (try? JSONSerialization.data(withJSONObject: grouped, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The history from its stored form; empty when the data cannot be read.
    public static func decode(_ data: Data) -> [UsageReading] {
        guard let grouped = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[Double]]] else { return [] }
        return grouped.flatMap { id, rows in
            rows.compactMap { r in r.count == 3 ? UsageReading(at: r[0], account: id, fivePercent: r[1], weeklyPercent: r[2]) : nil }
        }.sorted { ($0.at, $0.account) < ($1.at, $1.account) }
    }
}
