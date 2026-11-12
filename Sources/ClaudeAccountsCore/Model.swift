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

/// Live usage of one account, from the claude.ai usage request.
public struct LiveAccountUsage: Equatable, Sendable {
    public let ok: Bool
    public let limits: [LiveLimit]
    /// decrypt, no-login, network, http-<code>, not-json; nil when ok.
    public let error: String?

    public init(ok: Bool, limits: [LiveLimit], error: String?) {
        self.ok = ok; self.limits = limits; self.error = error
    }

    public static func failed(_ error: String) -> LiveAccountUsage { LiveAccountUsage(ok: false, limits: [], error: error) }

    public func limit(_ kind: String) -> LiveLimit? { limits.first { $0.kind == kind } }
}

/// One bar of the claude.ai Usage page.
public struct LiveLimit: Equatable, Sendable {
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
