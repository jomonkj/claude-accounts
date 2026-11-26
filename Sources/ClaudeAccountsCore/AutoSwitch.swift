import Foundation

/// Everything the auto-switch decision looks at. Later fields get default values, so callers
/// that do not need them do not change.
public struct AutoSwitchInput: Sendable {
    public var accounts: [Account]
    /// The last live usage of each account (LiveUsageCache).
    public var usage: [String: CachedUsage]
    public var now: Double
    /// For the reason text ("resets Thu").
    public var timeZone: TimeZone
    /// The app's own usage history (UsageHistory), for the forecast. Empty means rule 1 only.
    public var usageHistory: [UsageReading] = []
    /// Sessions stopped on a usage limit (engine `paused`).
    public var paused: [PausedSession] = []
    /// Recent Code tab sessions, to tell which are still running (SessionActivity.isRunning).
    public var running: [SessionActivity] = []
    /// Past auto-switch decisions (AutoSwitchLog), for the loop limit.
    public var history: [AutoSwitchRecord] = []

    public init(accounts: [Account], usage: [String: CachedUsage], now: Double, timeZone: TimeZone = .current) {
        self.accounts = accounts; self.usage = usage; self.now = now; self.timeZone = timeZone
    }

    public init(accounts: [Account], usage: [String: CachedUsage], now: Double, timeZone: TimeZone = .current,
                paused: [PausedSession], running: [SessionActivity] = [], history: [AutoSwitchRecord] = []) {
        self.init(accounts: accounts, usage: usage, now: now, timeZone: timeZone)
        self.paused = paused; self.running = running; self.history = history
    }
}

/// One allowed account in the ranking, with the reason the panel shows.
public struct RankedAccount: Equatable, Sendable {
    public let id: String
    public let fivePercent: Double
    public let weeklyPercent: Double
    /// When the weekly limit resets (epoch seconds), or nil when claude.ai did not say.
    public let weeklyResetsAt: Double?
    /// The expected weekly use (percent) until the weekly reset, from the usage history, or nil
    /// when there is no forecast (less than 7 days of history, or no reset known).
    public let forecast: Double?
    public let reason: String

    /// True when the forecast says the quota left is not used before the reset anyway: no quota is
    /// lost at the reset, so the account moves down.
    public var movedDown: Bool { forecast.map { $0 < 100 - weeklyPercent } ?? false }
}

/// What the auto-switch decision returns. Later outputs are added as new fields.
public struct AutoSwitchDecision: Equatable, Sendable {
    /// The allowed accounts, best first.
    public let ranking: [RankedAccount]
    /// What to do now (AutoSwitch.action).
    public var action: AutoSwitchAction = .none
    /// The best account, or nil when no account is allowed.
    public var next: RankedAccount? { ranking.first }
}

/// The one pure function that decides the next account (spec #58). The 90% warning, the "Switch to"
/// buttons and the panel's "Next" line all use it. New inputs (usage history, paused and running
/// sessions, past auto-switches, settings) go into AutoSwitchInput with default values, and new
/// outputs (the action) into AutoSwitchDecision, so callers do not change.
public enum AutoSwitch {
    public static func decide(_ input: AutoSwitchInput) -> AutoSwitchDecision {
        let history = Dictionary(grouping: input.usageHistory.filter { $0.at <= input.now }, by: \.account)
        // Allowed: not current, mine, saved login, last live read good, 5-hour and weekly below 100%.
        // Model-scoped limits (weekly_scoped, for example Fable) are ignored.
        let ranked = input.accounts.compactMap { a -> RankedAccount? in
            guard !a.current, a.owned, a.savedLogin, let u = input.usage[a.id], u.error == nil,
                  let week = u.limits.first(where: { $0.kind == "weekly_all" }), week.percent < 100 else { return nil }
            let five = u.limits.first { $0.kind == "session" }?.percent ?? 0
            guard five < 100 else { return nil }
            let expected = week.resetsAt.flatMap { forecast(history[a.id] ?? [], now: input.now, until: $0, timeZone: input.timeZone) }
            let moved = expected.map { $0 < 100 - week.percent } ?? false
            return RankedAccount(id: a.id, fivePercent: five, weeklyPercent: week.percent, weeklyResetsAt: week.resetsAt,
                                 forecast: expected, reason: reason(week: week, now: input.now, timeZone: input.timeZone, moved: moved))
        }
        // Rule 1: soonest weekly reset, then more weekly quota left. The ID makes the order total.
        func rule1(_ r: RankedAccount) -> (Double, Double, String) { (r.weeklyResetsAt ?? .infinity, r.weeklyPercent, r.id) }
        // Forecast: an account that will not use its quota before its reset anyway moves down.
        func key(_ r: RankedAccount) -> (Int, Double, Double, String) { let k = rule1(r); return (r.movedDown ? 1 : 0, k.0, k.1, k.2) }
        var ranking = ranked.sorted { key($0) < key($1) }
        // When the forecast changed the pick, the next account's reason says why.
        if let first = ranking.first, let ruleFirst = ranked.min(by: { rule1($0) < rule1($1) }), ruleFirst.id != first.id {
            let name = input.accounts.first { $0.id == ruleFirst.id }?.shortTitle ?? String(ruleFirst.id.prefix(8))
            ranking[0] = RankedAccount(id: first.id, fivePercent: first.fivePercent, weeklyPercent: first.weeklyPercent,
                                       weeklyResetsAt: first.weeklyResetsAt, forecast: first.forecast,
                                       reason: "\(first.reason); \(name) \(ruleFirst.reason)")
        }
        var decision = AutoSwitchDecision(ranking: ranking)
        decision.action = action(input, ranking: decision.ranking)
        return decision
    }

    /// The forecast needs this much usage history of the account (7 days).
    public static let forecastMinHistory: Double = 7 * 86400

    /// The expected weekly use (percent) from `now` until `until`, or nil with less than 7 days of
    /// history. The history gives the use per hour at each weekday and hour (168 slots, local time):
    /// the weekly percent gained between two readings is spread evenly over the time between them
    /// (after a weekly reset, the use is the new percent). The forecast adds the use per hour of each
    /// hour's slot until the reset; a slot with no readings counts as no use.
    static func forecast(_ readings: [UsageReading], now: Double, until: Double, timeZone: TimeZone) -> Double? {
        let rs = readings.sorted { $0.at < $1.at }
        guard let first = rs.first, now - first.at >= forecastMinHistory else { return nil }
        var used = [Double](repeating: 0, count: 168), seen = [Double](repeating: 0, count: 168)
        /// Calls `f(slot, seconds)` for each piece of [a, b) inside one local hour.
        func pieces(_ a: Double, _ b: Double, _ f: (Int, Double) -> Void) {
            let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: a)))
            var t = a
            while t < b {
                let hour = ((t + offset) / 3600).rounded(.down)
                let end = min(b, (hour + 1) * 3600 - offset)
                // Hour 0 of the epoch is a Thursday; the same weekday and hour give the same slot.
                f((Int(hour) % 168 + 168) % 168, end - t)
                t = end
            }
        }
        for (x, y) in zip(rs, rs.dropFirst()) where y.at > x.at {
            let use = y.weeklyPercent >= x.weeklyPercent ? y.weeklyPercent - x.weeklyPercent : y.weeklyPercent
            let span = y.at - x.at
            pieces(x.at, y.at) { slot, secs in used[slot] += use * secs / span; seen[slot] += secs }
        }
        var expected = 0.0
        pieces(now, until) { slot, secs in
            if seen[slot] > 0 { expected += used[slot] / seen[slot] * secs }
        }
        return expected
    }

    /// "resets Thu, 40% left", "resets today, 88% left", or "40% left" when the reset is not known.
    /// When the forecast moved the account down: "resets Thu, but you will not use 40% before then".
    static func reason(week: LiveLimit, now: Double, timeZone: TimeZone, moved: Bool = false) -> String {
        let percent = "\(Int((100 - week.percent).rounded()))%"
        guard let at = week.resetsAt else { return "\(percent) left" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let t = Date(timeIntervalSince1970: at)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE"
        let resets = "resets " + (cal.isDate(t, inSameDayAs: Date(timeIntervalSince1970: now)) ? "today" : f.string(from: t))
        return moved ? "\(resets), but you will not use \(percent) before then" : "\(resets), \(percent) left"
    }
}
