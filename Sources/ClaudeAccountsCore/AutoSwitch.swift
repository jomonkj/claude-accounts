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

    public init(accounts: [Account], usage: [String: CachedUsage], now: Double, timeZone: TimeZone = .current) {
        self.accounts = accounts; self.usage = usage; self.now = now; self.timeZone = timeZone
    }
}

/// One allowed account in the ranking, with the reason the panel shows.
public struct RankedAccount: Equatable, Sendable {
    public let id: String
    public let fivePercent: Double
    public let weeklyPercent: Double
    /// When the weekly limit resets (epoch seconds), or nil when claude.ai did not say.
    public let weeklyResetsAt: Double?
    public let reason: String
}

/// What the auto-switch decision returns. Later outputs are added as new fields.
public struct AutoSwitchDecision: Equatable, Sendable {
    /// The allowed accounts, best first.
    public let ranking: [RankedAccount]
    /// The best account, or nil when no account is allowed.
    public var next: RankedAccount? { ranking.first }
}

/// The one pure function that decides the next account (spec #58). The 90% warning, the "Switch to"
/// buttons and the panel's "Next" line all use it. New inputs (usage history, paused and running
/// sessions, past auto-switches, settings) go into AutoSwitchInput with default values, and new
/// outputs (the action) into AutoSwitchDecision, so callers do not change.
public enum AutoSwitch {
    public static func decide(_ input: AutoSwitchInput) -> AutoSwitchDecision {
        // Allowed: not current, mine, saved login, last live read good, 5-hour and weekly below 100%.
        // Model-scoped limits (weekly_scoped, for example Fable) are ignored.
        let ranked = input.accounts.compactMap { a -> RankedAccount? in
            guard !a.current, a.owned, a.savedLogin, let u = input.usage[a.id], u.error == nil,
                  let week = u.limits.first(where: { $0.kind == "weekly_all" }), week.percent < 100 else { return nil }
            let five = u.limits.first { $0.kind == "session" }?.percent ?? 0
            guard five < 100 else { return nil }
            return RankedAccount(id: a.id, fivePercent: five, weeklyPercent: week.percent, weeklyResetsAt: week.resetsAt,
                                 reason: reason(week: week, now: input.now, timeZone: input.timeZone))
        }
        // Rule 1: soonest weekly reset, then more weekly quota left. The ID makes the order total.
        func key(_ r: RankedAccount) -> (Double, Double, String) { (r.weeklyResetsAt ?? .infinity, r.weeklyPercent, r.id) }
        return AutoSwitchDecision(ranking: ranked.sorted { key($0) < key($1) })
    }

    /// "resets Thu, 40% left", "resets today, 88% left", or "40% left" when the reset is not known.
    static func reason(week: LiveLimit, now: Double, timeZone: TimeZone) -> String {
        let left = "\(Int((100 - week.percent).rounded()))% left"
        guard let at = week.resetsAt else { return left }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let t = Date(timeIntervalSince1970: at)
        if cal.isDate(t, inSameDayAs: Date(timeIntervalSince1970: now)) { return "resets today, \(left)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE"
        return "resets \(f.string(from: t)), \(left)"
    }
}
