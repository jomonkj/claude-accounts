import SwiftUI

struct Account: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let sessions: Int
    let lastUsed: Double
    let savedLogin: Bool
    let savedAt: Double
    let savedMode: String
    let current: Bool
    let hidden: Bool

    var title: String { name.isEmpty ? "Account \(id.prefix(8))" : name }
    var shortTitle: String {
        if name.isEmpty { return String(id.prefix(4)) }
        let first = name.split(whereSeparator: { " @(".contains($0) }).first.map(String.init) ?? name
        return String(first.prefix(12))
    }
    var initials: String {
        let base = name.isEmpty ? String(id.prefix(2)) : name
        let parts = base.split(whereSeparator: { " @._-()".contains($0) }).prefix(2)
        return parts.map { String($0.prefix(1)) }.joined().uppercased()
    }
    var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint]
        let n = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[n % palette.count]
    }
    var lastUsedText: String {
        lastUsed > 0 ? "used " + Self.relative(lastUsed) : "never used"
    }
    var loginText: String {
        guard savedLogin else { return "No saved login" }
        return "Login saved " + Self.relative(savedAt) + (savedMode == "auto" ? " (auto)" : "")
    }
    static func relative(_ t: Double) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }
}

struct PausedSession: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let account: String
    let cwd: String
    let message: String
    let resets: String
    let stoppedAt: String
}

struct EngineSettings: Decodable, Equatable {
    var shareSessions: Bool
    var autoSaveLogins: Bool
    var dailyBackup: Bool
    var backupKeep: Int
    var showNameInMenuBar: Bool
    var hidden: [String]
}

struct Status: Decodable, Equatable {
    let current: String
    let signedIn: Bool
    let claudeRunning: Bool
    let settings: EngineSettings
    let accounts: [Account]
    let paused: [PausedSession]
}

enum Banner: Equatable {
    case error(String), warning(String), success(String), info(String)
}
