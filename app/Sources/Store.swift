import SwiftUI
import AppKit

/// Talks to the engine (engine/claude-switch, bundled in the app) and holds the UI state.
@MainActor
final class Store: ObservableObject {
    @Published var status: Status?
    @Published var busy: String?
    @Published var banner: Banner?
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var showHidden = false

    private var timer: Timer?

    nonisolated static var engine: String {
        Bundle.main.path(forResource: "claude-switch", ofType: nil)
            ?? (NSHomeDirectory() + "/.local/bin/claude-switch")
    }

    init() {
        Task { await tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
    }

    // MARK: engine calls

    nonisolated func run(_ args: [String]) async -> (ok: Bool, out: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-I", Store.engine] + args
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            do { try p.run() } catch { return (false, error.localizedDescription) }
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let os = String(decoding: o, as: UTF8.self), es = String(decoding: e, as: UTF8.self)
            if p.terminationStatus == 0 { return (true, os) }
            let msg = es.isEmpty ? os : es
            return (false, msg.replacingOccurrences(of: "ERROR: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    func refresh() async {
        let r = await run(["status"])
        if r.ok, let s = try? JSONDecoder().decode(Status.self, from: Data(r.out.utf8)) {
            if s != status { status = s }
        } else if !r.ok {
            banner = .error(r.out)
        }
    }

    func tick() async {
        _ = await run(["tick"])
        await refresh()
    }

    @discardableResult
    func perform(_ label: String, _ args: [String]) async -> [String: Any]? {
        busy = label; banner = nil
        let r = await run(args)
        busy = nil
        await refresh()
        guard r.ok else { banner = .error(r.out); return nil }
        return (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: derived state

    var accounts: [Account] { status?.accounts ?? [] }
    var visibleAccounts: [Account] { accounts.filter { showHidden || !$0.hidden || $0.current } }
    var hiddenCount: Int { accounts.filter { $0.hidden && !$0.current }.count }
    var current: Account? { accounts.first(where: { $0.current }) }

    func account(_ id: String) -> Account? { accounts.first(where: { $0.id == id }) }

    var menuBarTitle: String {
        guard status?.settings.showNameInMenuBar == true, let c = current else { return "" }
        return c.shortTitle
    }

    var wrongAccountHint: String? {
        guard let cur = current, let top = accounts.max(by: { $0.sessions < $1.sessions }),
              top.id != cur.id, cur.sessions < 10, top.sessions > 50 else { return nil }
        return "This account has only \(cur.sessions) sessions. Your \(top.sessions) sessions are in \(top.title)."
    }

    // MARK: actions

    func switchTo(_ a: Account) {
        guard Dialog.confirm("Switch to \(a.title)?",
            "Claude quits, loads the saved login of this account, and opens again. Your current login is saved first, so you can switch back at any time.\n\nRunning tasks in Claude stop. Finish them first.",
            ok: "Switch") else { return }
        Task {
            guard let r = await perform("Switching to \(a.title)…", ["switch", a.id]) else { return }
            let shared = r["shared"] as? Int ?? 0
            busy = "Checking the login…"
            let v = await run(["verify", a.id])
            busy = nil
            await refresh()
            let obj = (try? JSONSerialization.jsonObject(with: Data(v.out.utf8))) as? [String: Any]
            if obj?["ok"] as? Bool == true {
                banner = .success("Signed in as \(a.title)." + (shared > 0 ? " \(shared) sessions shared." : ""))
            } else {
                banner = .error(obj?["message"] as? String ?? v.out)
            }
        }
    }

    func addAccount() {
        guard Dialog.confirm("Add another account?",
            "Claude quits, saves your current login, and opens signed out. Sign in with the other account. The app saves that login too, so you can switch with one click.",
            ok: "Continue") else { return }
        Task {
            if await perform("Saving your login…", ["add"]) != nil {
                banner = .info("Sign in to the new account in Claude. The app saves the login within 5 minutes, or when you switch.")
            }
        }
    }

    func shareNow() {
        Task {
            let dry = await run(["share", "--dry-run"])
            let n = ((try? JSONSerialization.jsonObject(with: Data(dry.out.utf8))) as? [String: Any])?["count"] as? Int ?? 0
            guard n > 0 else { banner = .info("This account already has every session."); return }
            guard Dialog.confirm("Share \(n) sessions into this account?",
                "A backup is made first. Claude quits, the new or newer sessions of your other accounts are copied into this account, and Claude opens again. Other accounts keep their own sessions.",
                ok: "Share") else { return }
            if let r = await perform("Sharing sessions…", ["share"]) {
                banner = .success("\(r["count"] as? Int ?? 0) sessions are now in this account.")
            }
        }
    }

    func backup() {
        Task {
            if let r = await perform("Backing up…", ["backup"]), let p = r["path"] as? String {
                banner = .success("Backup saved to \(p.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
            }
        }
    }

    func rename(_ a: Account) {
        guard let v = Dialog.ask("Name this account", "For example, its email address. Leave empty to remove the name.", value: a.name) else { return }
        Task { await perform("Saving…", ["label", a.id, v]) }
    }

    func forget(_ a: Account) {
        guard Dialog.confirm("Forget the saved login of \(a.title)?",
            "Its sessions stay. To switch to this account again, you must sign in once more.", ok: "Forget") else { return }
        Task { await perform("Saving…", ["forget", a.id]) }
    }

    func setHidden(_ a: Account, _ hide: Bool) {
        Task { await perform("Saving…", [hide ? "hide" : "unhide", a.id]) }
    }

    func set(_ key: String, _ value: Bool) {
        Task { await perform("Saving…", ["set", key, value ? "true" : "false"]) }
    }

    func setNumber(_ key: String, _ value: Int) {
        Task { await perform("Saving…", ["set", key, String(value)]) }
    }

    func open(_ p: PausedSession) {
        Task { await perform("Opening…", ["open-session", p.id]) }
    }

    func openLog() {
        let log = NSHomeDirectory() + "/Library/Application Support/Claude Account Switcher/switch.log"
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }
}

// MARK: - Launch at login (LaunchAgent)

enum LoginItem {
    static let label = "local.claude-accounts"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ on: Bool) {
        if on {
            let dict: [String: Any] = ["Label": label, "ProgramArguments": [Bundle.main.executablePath ?? ""],
                                       "RunAtLoad": true, "ProcessType": "Interactive",
                                       "LimitLoadToSessionType": "Aqua"]
            try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            (dict as NSDictionary).write(to: plist, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plist)
        }
    }
}

// MARK: - Dialogs

enum Dialog {
    static func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func ask(_ title: String, _ text: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        f.stringValue = value; f.placeholderString = "name@example.com"
        a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return f.stringValue.trimmingCharacters(in: .whitespaces)
    }
}
