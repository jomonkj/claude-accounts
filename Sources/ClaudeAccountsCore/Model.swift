import Foundation

/// One Claude account on this Mac, as the engine reports it.
public struct Account: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let sessions: Int
    public let lastUsed: Double
    public let savedLogin: Bool
    public let savedAt: Double
    public let savedMode: String
    public let current: Bool
    public let hidden: Bool
    public let owned: Bool
    /// Last switch to this account (epoch seconds); 0 or nil when never.
    public let switchedAt: Double?
    /// From the Claude Code sign-in data; nil from an older engine.
    public let details: AccountDetails?
    /// Newest usage-limit error of this account in the last 8 days; nil when none.
    public let limit: LimitHit?

    public var title: String { name.isEmpty ? "Account \(id.prefix(8))" : name }

    /// Text for a field with no data.
    public static let none = "—"
    public var planText: String { details?.plan ?? Self.none }
    public var orgText: String { details?.orgName ?? Self.none }
    public var displayNameText: String { details?.displayName ?? Self.none }
    public var emailText: String { details?.email ?? Self.none }
    public var switchedText: String { (switchedAt ?? 0) > 0 ? Self.relative(switchedAt!) : Self.none }

    /// "Weekly · 2 days ago" for the Settings table, or a dash.
    public func lastLimitText(now: Date = Date()) -> String {
        guard let l = limit else { return Self.none }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return l.windowName + " · " + f.localizedString(for: Date(timeIntervalSince1970: l.hitAt), relativeTo: now)
    }

    /// Panel line: plan, organization, then email (when the title does not already have it), only
    /// the fields that are known. The email goes last, so a long line cuts the email, not the plan.
    /// Nil when none is known.
    public var detailsLine: String? {
        let email = details?.email.flatMap { name.contains($0) ? nil : $0 }
        let parts = [details?.plan, details?.orgName, email].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Second line in Settings → Accounts: display name, email (when not in the title), short ID.
    public var settingsSubtitle: String {
        let email = details?.email.flatMap { name.contains($0) ? nil : $0 }
        return ([details?.displayName, email].compactMap { $0 } + [String(id.prefix(8))]).joined(separator: " · ")
    }

    /// Short name for the menu bar: first word of the name, or the first 4 characters of the ID.
    public var shortTitle: String {
        if name.isEmpty { return String(id.prefix(4)) }
        let first = name.split(whereSeparator: { " @(".contains($0) }).first.map(String.init) ?? name
        return String(first.prefix(12))
    }

    /// Show "Sign in to save": no saved login, and not the account Claude uses now.
    public var needsSignInToSave: Bool { !savedLogin && !current }

    public var initials: String {
        let base = name.isEmpty ? String(id.prefix(2)) : name
        let parts = base.split(whereSeparator: { " @._-()".contains($0) }).prefix(2)
        return parts.map { String($0.prefix(1)) }.joined().uppercased()
    }

    /// Stable index into a color palette (the same on every launch).
    public var colorIndex: Int { id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } }

    public var lastUsedText: String { lastUsed > 0 ? "used " + Self.relative(lastUsed) : "never used" }
    /// The panel's last line: "Used 55 minutes ago". The session count is left out: sync gives
    /// every "mine" account the same sessions, so it does not tell the accounts apart.
    public var lastUsedLine: String { lastUsed > 0 ? "Used " + Self.relative(lastUsed) : "Never used" }

    public var loginText: String {
        guard savedLogin else { return "No saved login" }
        return "Login saved " + Self.relative(savedAt) + (savedMode == "auto" ? " (auto)" : "")
    }

    /// A time a little ahead of the clock (a file written this second) counts as 1 second ago, so the text
    /// never reads "in 0 seconds".
    public static func relative(_ t: Double, now: Date = Date()) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: min(t, now.timeIntervalSince1970 - 1)), relativeTo: now)
    }
}

/// What the Claude Code sign-in data says about an account. Each field may be nil.
public struct AccountDetails: Decodable, Equatable, Sendable {
    public let email: String?
    public let displayName: String?
    public let plan: String?
    public let orgName: String?
}

/// The newest usage-limit error of an account, from its session transcripts.
public struct LimitHit: Decodable, Equatable, Sendable {
    /// "5h", "week", or nil when the error text names no known window.
    public let window: String?
    public let hitAt: Double
    public let resets: String
    /// When the limit resets (epoch seconds), or nil when the reset text could not be read.
    public let resetsAt: Double?

    /// "5-hour", "Weekly" or "Limit".
    public var windowName: String {
        switch window { case "5h": "5-hour"; case "week": "Weekly"; default: "Limit" }
    }
}

/// A session whose last turn ended on a usage-limit error.
public struct PausedSession: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let account: String
    public let cwd: String
    public let message: String
    public let resets: String
    /// When the limit resets (epoch seconds), or nil when the engine could not read the reset text.
    public let resetsAt: Double?
    public let stoppedAt: String
}

public struct EngineSettings: Decodable, Equatable, Sendable {
    public var syncOnSwitch: Bool
    public var syncConfirmed: Bool
    public var autoSaveLogins: Bool
    public var dailyBackup: Bool
    public var backupKeep: Int
    public var showNameInMenuBar: Bool
    public var hidden: [String]
    /// Account IDs in the order the user chose. Accounts not in the list go last.
    public var order: [String]
    /// Account IDs pinned to the top of the panel.
    public var pinned: [String]
    /// Show live usage from claude.ai (docs/usage-live.md). Nil from an older engine.
    public var liveUsage: Bool?
    public var liveUsageOn: Bool { liveUsage ?? false }
}

/// Output of `claude-switch usage-cookies`: for each account with a login, the org and the cookie
/// header for the app's usage request. Secret: keep it in memory only, never log or store it.
public struct LiveCookiesResult: Decodable, Sendable {
    public let accounts: [String: LiveCookies]
}

public struct LiveCookies: Decodable, Sendable {
    public let ok: Bool
    public let org: String?
    public let cookie: String?
    /// decrypt or no-login; nil when ok.
    public let error: String?
}

/// Live usage of one account, from the claude.ai usage request. Decodable for demo renders only.
public struct LiveAccountUsage: Equatable, Sendable, Decodable {
    public let ok: Bool
    public let limits: [LiveLimit]
    /// decrypt, no-login, network, http-<code>, not-json; nil when ok.
    public let error: String?

    public init(ok: Bool, limits: [LiveLimit], error: String?) {
        self.ok = ok; self.limits = limits; self.error = error
    }

    public static func failed(_ error: String) -> LiveAccountUsage { LiveAccountUsage(ok: false, limits: [], error: error) }

    public func limit(_ kind: String) -> LiveLimit? { limits.first { $0.kind == kind } }

    /// An error type in plain words, for the panel's help text.
    public static func reason(_ error: String) -> String {
        switch error {
        case "network": "No connection to claude.ai."
        case "no-login": "This account has no saved login."
        case "decrypt": "The saved login could not be read."
        case "not-json": "claude.ai sent an unexpected answer."
        case "http-401": "The saved login has expired. Switch to this account to sign in again."
        case "http-403": "claude.ai refused the request (HTTP 403)."
        default:
            error.hasPrefix("http-") ? "claude.ai answered with an error (HTTP \(error.dropFirst(5)))." : "Live usage failed (\(error))."
        }
    }
}

/// How full a usage bar is: the bar color in the panel.
public enum UsageLevel: Equatable, Sendable {
    case normal, high, critical

    public init(percent: Double) {
        self = percent >= 90 ? .critical : percent >= 70 ? .high : .normal
    }
}

/// One usage bar in the panel, for example "5h 42%".
public struct UsageBar: Equatable, Sendable {
    public let label: String
    public let percent: Double
    /// When the limit resets, for example "4:50 PM" or "Mon 8:30 PM"; nil when not known or past.
    public let resetText: String?

    public init(label: String, percent: Double, resetText: String?) {
        self.label = label; self.percent = percent; self.resetText = resetText
    }

    public var text: String { "\(Int(percent.rounded()))%" }
    public var fraction: Double { min(max(percent / 100, 0), 1) }
    public var level: UsageLevel { UsageLevel(percent: percent) }
    /// The panel shows the reset time next to a high or critical bar, where it matters.
    public var showsReset: Bool { level != .normal && resetText != nil }

    /// The bar label of a limit kind: "5h", "Week", the model name of a scoped limit, or the
    /// kind in words for a kind this app does not know yet.
    public static func label(kind: String, model: String?) -> String {
        switch kind {
        case "session": "5h"
        case "weekly_all": "Week"
        case "weekly_scoped": model ?? "Scoped"
        default: kind.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }
}

/// What the panel shows for live usage under one account.
public enum LiveRowState: Equatable, Sendable {
    /// `lastRead` ("Last read 25 min. ago") and `reason` are set when the newest read failed
    /// and the bars show the last good value.
    case bars([UsageBar], lastRead: String?, reason: String?)
    /// The reason in plain words.
    case unavailable(String)
}

/// The last good live usage of one account, kept between reads and app launches.
/// It holds no cookie: only limits, the read time and the newest error type.
public struct CachedUsage: Codable, Equatable, Sendable {
    public let limits: [LiveLimit]
    /// When `limits` was read (epoch seconds); 0 when never.
    public let readAt: Double
    /// The newest read's error type, when it failed; nil when the newest read was good.
    public let error: String?

    public init(limits: [LiveLimit], readAt: Double, error: String?) {
        self.limits = limits; self.readAt = readAt; self.error = error
    }
}

public enum LiveUsageCache {
    /// The cache after a read: a good read replaces the value; a failed read keeps the last good
    /// value and notes the error. Accounts the read did not ask (no login any more) are dropped.
    public static func merge(_ old: [String: CachedUsage], _ new: [String: LiveAccountUsage], now: Double) -> [String: CachedUsage] {
        var out: [String: CachedUsage] = [:]
        for (id, u) in new {
            if u.ok {
                out[id] = CachedUsage(limits: u.limits, readAt: now, error: nil)
            } else {
                out[id] = CachedUsage(limits: old[id]?.limits ?? [], readAt: old[id]?.readAt ?? 0, error: u.error ?? "network")
            }
        }
        return out
    }
}

/// When live usage is read again: every 10 minutes, and when the panel opens if the last read
/// is 2 minutes old or more. Never more often than every 2 minutes.
public enum LiveSchedule {
    public static let minimum: Double = 120
    public static let interval: Double = 600

    public static func due(lastAttempt: Double?, now: Double, panelOpened: Bool) -> Bool {
        guard let last = lastAttempt else { return true }
        return now - last >= (panelOpened ? minimum : interval)
    }
}

/// One bar of the claude.ai Usage page.
public struct LiveLimit: Equatable, Sendable, Codable {
    /// session, weekly_all, weekly_scoped, or a kind this app does not know yet.
    public let kind: String
    public let percent: Double
    public let resetsAt: Double?
    /// The model name of a scoped limit, for example "Fable".
    public let label: String?

    public init(kind: String, percent: Double, resetsAt: Double?, label: String?) {
        self.kind = kind; self.percent = percent; self.resetsAt = resetsAt; self.label = label
    }
}

/// Output of `claude-switch sync --dry-run` and `sync`.
public struct SyncResult: Decodable, Equatable, Sendable {
    public let changes: Int
    public let accounts: [String: Int]
    public let skipped: [String]
    public let dryRun: Bool
}

/// Output of `claude-switch update-check <version>`.
public struct UpdateInfo: Decodable, Equatable, Sendable {
    public let available: Bool
    public let latest: String?
    public let url: String?
    public let error: String?
}

/// One entry of `claude-switch backups`.
public struct BackupInfo: Decodable, Equatable, Sendable {
    public let name: String
    /// "daily", "pre-restore" (the undo of a restore) or "removed" (the sessions of a removed account).
    /// Nil from an engine older than v1.1.
    public let kind: String?
    /// Time to show, for example "2026-11-08 12:34".
    public let time: String?
    /// First 8 characters of the removed account (kind "removed").
    public let account: String?
    public let sessions: Int
    public let modified: Double
    public var isUndo: Bool { kind == "pre-restore" }
    public var isRemoved: Bool { kind == "removed" }

    /// Name to show in the Backups list.
    public var title: String {
        switch kind {
        case "pre-restore": return "Before restore " + (time ?? name)
        case "removed": return "Removed account \(account ?? "?") (\(time ?? name))"
        default: return name
        }
    }
}

/// Output of `claude-switch status`.
public struct Status: Decodable, Equatable, Sendable {
    public let current: String
    public let signedIn: Bool
    public let claudeRunning: Bool
    public let claudeVersion: String
    public let versionTested: Bool
    public let layoutProblems: [String]
    public let pendingRecovery: Bool
    public let settings: EngineSettings
    public let accounts: [Account]
    public let paused: [PausedSession]
}

public enum Banner: Equatable, Sendable {
    case error(String), warning(String), success(String), info(String)
}
