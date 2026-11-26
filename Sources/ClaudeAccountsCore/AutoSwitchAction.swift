import Foundation

/// What auto-switch does now (spec #58).
public enum AutoSwitchAction: Codable, Equatable, Sendable {
    /// No limit on the current account.
    case none
    /// Other sessions of the account are still running: wait until they stop, at most 3 minutes
    /// after the first limit stop.
    case wait(until: Double)
    /// Switch to `to`, then resume the stopped sessions.
    case `switch`(to: String, resume: [String], reason: String)
    /// Every account is at its weekly limit: wait for the soonest reset (nil when not known).
    case waitForReset(account: String, at: Double?)
    /// Every account is at its 5-hour limit: the desktop app waits by itself.
    case leaveToDesktop
    /// The loop limit (3 auto-switches in 30 minutes) is reached.
    case stopped(reason: String)
}

/// One Code tab session as the desktop session index has it (engine `sessions`), in epoch seconds.
public struct SessionActivity: Decodable, Equatable, Sendable {
    public let id: String
    public let lastActivityAt: Double
    public let lastTurnEdgeAt: Double?
    public let completedTurns: Int?

    public init(id: String, lastActivityAt: Double, lastTurnEdgeAt: Double?, completedTurns: Int?) {
        self.id = id; self.lastActivityAt = lastActivityAt; self.lastTurnEdgeAt = lastTurnEdgeAt; self.completedTurns = completedTurns
    }

    /// Running: activity in the last 2 minutes, or a turn still open (activity 1 second or more after
    /// the last turn edge; a finished turn ends with both at the same time) with activity in the last
    /// 30 minutes, for a long tool call that writes no index update.
    public func isRunning(now: Double) -> Bool {
        let idle = now - lastActivityAt
        if idle <= 120 { return true }
        guard let edge = lastTurnEdgeAt else { return false }
        return lastActivityAt - edge >= 1 && idle <= 1800
    }
}

/// The engine `sessions` output: what the auto-switch file watch reads.
public struct EngineSessions: Decodable, Equatable, Sendable {
    public let paused: [PausedSession]
    public let running: [SessionActivity]
}

/// One past auto-switch decision.
public struct AutoSwitchRecord: Codable, Equatable, Sendable {
    public let at: Double
    public let action: AutoSwitchAction

    public init(at: Double, action: AutoSwitchAction) { self.at = at; self.action = action }
}

extension PausedSession {
    /// `stoppedAt` in epoch seconds, or nil when it cannot be read.
    public var stoppedAtTime: Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: stoppedAt) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: stoppedAt)?.timeIntervalSince1970
    }
}

extension AutoSwitch {
    /// The longest wait for other running sessions after the first limit stop.
    public static let maxWait: Double = 180
    /// The loop limit: no more than `loopLimit` auto-switches in `loopWindow` seconds.
    public static let loopLimit = 3
    public static let loopWindow: Double = 1800

    /// The action for the current account, given the ranking of the other accounts.
    static func action(_ input: AutoSwitchInput, ranking: [RankedAccount]) -> AutoSwitchAction {
        guard let current = input.accounts.first(where: \.current) else { return .none }
        let since = current.switchedAt ?? 0
        // Limit stops of the current account since the switch to it, whose limit has not reset yet.
        let stops = input.paused.filter { p in
            guard p.account == current.id, let at = p.stoppedAtTime, at >= since else { return false }
            return p.resetsAt.map { $0 > input.now } ?? true
        }.sorted { ($0.stoppedAtTime ?? 0, $0.id) < ($1.stoppedAtTime ?? 0, $1.id) }
        let usage = input.usage[current.id].flatMap { $0.error == nil ? $0 : nil }
        let fiveFull = (usage?.limits.first { $0.kind == "session" }?.percent ?? 0) >= 100
        let weekFull = (usage?.limits.first { $0.kind == "weekly_all" }?.percent ?? 0) >= 100
        guard !stops.isEmpty || fiveFull || weekFull else { return .none }
        // Other sessions still running: wait for them, at most 3 minutes after the first limit stop.
        let stopped = Set(input.paused.map(\.id))
        if let first = stops.first?.stoppedAtTime, input.now < first + AutoSwitch.maxWait,
           input.running.contains(where: { !stopped.contains($0.id) && $0.isRunning(now: input.now) }) {
            return .wait(until: first + AutoSwitch.maxWait)
        }
        if let next = ranking.first {
            // Loop limit: at most 3 auto-switches in any 30 minutes.
            let recent = input.history.filter { r in
                if case .switch = r.action { return input.now - r.at < AutoSwitch.loopWindow }
                return false
            }
            if recent.count >= AutoSwitch.loopLimit { return .stopped(reason: "3 auto-switches in 30 minutes") }
            return .switch(to: next.id, resume: stops.map(\.id), reason: next.reason)
        }
        // No account is allowed. Only the 5-hour limit on the current account: it resets within
        // 5 hours, and the desktop app shows that and waits by itself.
        let weekStops = stops.filter { $0.window == "week" }
        guard weekFull || !weekStops.isEmpty else { return .leaveToDesktop }
        // The current account is at its weekly limit: wait for the account that is free soonest. Its
        // weekly reset, or the 5-hour reset of another account that is mine with a saved login.
        let currentReset = weekStops.compactMap(\.resetsAt).min()
            ?? usage?.limits.first { $0.kind == "weekly_all" }?.resetsAt
        var free: [(at: Double?, id: String)] = [(currentReset, current.id)]
        for a in input.accounts where !a.current && a.owned && a.savedLogin {
            guard let u = input.usage[a.id], u.error == nil else { continue }
            let five = u.limits.first { $0.kind == "session" }, week = u.limits.first { $0.kind == "weekly_all" }
            free.append(((week?.percent ?? 0) >= 100 ? week?.resetsAt : five?.resetsAt, a.id))
        }
        let soonest = free.min { ($0.at ?? .infinity, $0.id) < ($1.at ?? .infinity, $1.id) }!
        return .waitForReset(account: soonest.id, at: soonest.at)
    }
}

/// The history of auto-switch decisions and their switch log lines. A decision is stored and logged
/// only when it differs from the last one, so a limit that lasts gives one line, not one per timer run.
/// The switches in it are the past auto-switches for the loop limit.
public enum AutoSwitchLog {
    public static let keep: Double = 86400
    public static let prefix = "autoswitch (dry run): "

    /// The history after a decision, and the line to write to the switch log (nil: nothing new).
    /// Entries older than a day are removed, but the newest is kept so a lasting action is not logged again.
    public static func record(_ history: [AutoSwitchRecord], _ action: AutoSwitchAction, now: Double,
                              timeZone: TimeZone = .current) -> (history: [AutoSwitchRecord], line: String?) {
        let last = history.last?.action ?? .none
        var out = history
        if action != last { out.append(AutoSwitchRecord(at: now, action: action)) }
        let newest = out.count - 1
        out = out.enumerated().filter { i, r in i == newest || now - r.at <= keep }.map(\.element)
        return (out, action != last ? line(action, timeZone: timeZone) : nil)
    }

    /// The switch log line of an action, with account IDs (the debug report hides them); nil for none.
    public static func line(_ action: AutoSwitchAction, timeZone: TimeZone = .current) -> String? {
        func time(_ t: Double) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "EEE HH:mm"
            return f.string(from: Date(timeIntervalSince1970: t))
        }
        switch action {
        case .none: return nil
        case .wait(let until): return prefix + "wait for other running sessions until \(time(until))"
        case .switch(let to, let resume, let reason):
            return prefix + "switch to \(to) (\(reason)), resume \(resume.count) session\(resume.count == 1 ? "" : "s")"
        case .waitForReset(let account, let at):
            return prefix + "every account at its limit, wait for \(account) to reset " + (at.map(time) ?? "(time not known)")
        case .leaveToDesktop: return prefix + "every account at its 5-hour limit, Claude waits for the reset"
        case .stopped(let reason): return prefix + "stopped, \(reason)"
        }
    }

    public static func encode(_ history: [AutoSwitchRecord]) -> Data {
        (try? JSONEncoder().encode(history)) ?? Data("[]".utf8)
    }

    public static func decode(_ data: Data) -> [AutoSwitchRecord] {
        (try? JSONDecoder().decode([AutoSwitchRecord].self, from: data)) ?? []
    }
}
