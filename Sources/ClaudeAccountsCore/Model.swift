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

    public var title: String { name.isEmpty ? "Account \(id.prefix(8))" : name }

    /// Short name for the menu bar: first word of the name, or the first 4 characters of the ID.
    public var shortTitle: String {
        if name.isEmpty { return String(id.prefix(4)) }
        let first = name.split(whereSeparator: { " @(".contains($0) }).first.map(String.init) ?? name
        return String(first.prefix(12))
    }

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

    public static func relative(_ t: Double, now: Date = Date()) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: t), relativeTo: now)
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
    public let sessions: Int
    public let modified: Double
    public var isUndo: Bool { name.hasPrefix("pre-restore-") }
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
