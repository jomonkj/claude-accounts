import SwiftUI
import AppKit

import ClaudeAccountsCore

/// UI state of the menu bar app. All file work happens in the engine.
@MainActor
final class Store: ObservableObject {
    @Published var status: Status?
    @Published var busy: String?
    @Published var banner: Banner?
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var showHidden = false
    @Published var backups: [BackupInfo] = []
    @Published var update: UpdateInfo?
    private var lastUpdateCheck = Date.distantPast
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    private var windows: [String: NSWindow] = [:]

    let engine: EngineClient
    let notifier = Notifier()
    private var timer: Timer?
    private var hotKeys: HotKeys?
    private var nextRunning = false

    init(engine: EngineClient = .bundled(), startTimer: Bool = true) {
        self.engine = engine
        guard startTimer else { return }
        notifier.onSwitch = { [weak self] id in
            guard let self, let a = self.account(id) else { return }
            self.switchTo(a)
        }
        notifier.start()
        // No global keys in the debug render modes.
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--render") }) {
            hotKeys = HotKeys { [weak self] key in
                switch key {
                case .openPanel: self?.openPanel()
                case .nextAccount: self?.switchToNext()
                }
            }
            hotKeys?.apply()
        }
        if !UserDefaults.standard.bool(forKey: "welcomeDone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showWelcome() }
        }
        Task { await tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
    }

    // MARK: engine calls

    func run(_ args: [String]) async -> EngineResult { await engine.run(args) }

    private var recovering = false

    func refresh() async {
        do {
            let s = try await engine.status()
            if s != status { status = s }
            if s.pendingRecovery && !recovering { await recover() }
            notifier.update(s)
        } catch let e as EngineError {
            banner = .error(e.message)
        } catch {
            banner = .error("Cannot read the engine output: \(error.localizedDescription)")
        }
    }

    /// Finish or roll back a switch that stopped in the middle (for example, the Mac lost power).
    func recover() async {
        recovering = true
        busy = "Repairing an unfinished switch…"
        let r = await run(["recover"])
        busy = nil
        if r.ok, let msg = Status.recoverMessage(r.json) { banner = .warning(msg) }
        else if !r.ok { banner = .error(r.output) }
        status = try? await engine.status()
        recovering = false
    }

    func tick() async {
        _ = await run(["tick"])
        await refresh()
        if Date().timeIntervalSince(lastUpdateCheck) > 24 * 3600 { await checkForUpdate() }
    }

    @discardableResult
    func perform(_ label: String, _ args: [String]) async -> [String: Any]? {
        busy = label; banner = nil
        let r = await run(args)
        busy = nil
        await refresh()
        guard r.ok else { banner = .error(r.output); return nil }
        return r.json
    }

    // MARK: derived state (see ClaudeAccountsCore/Logic.swift)

    /// All accounts in panel order (Settings → Accounts).
    var accounts: [Account] { status?.panelOrder(showHidden: true) ?? [] }
    var visibleAccounts: [Account] { status?.panelOrder(showHidden: showHidden) ?? [] }
    func isPinned(_ a: Account) -> Bool { status?.isPinned(a.id) ?? false }
    var hiddenCount: Int { status?.hiddenCount ?? 0 }
    var current: Account? { status?.currentAccount }
    func account(_ id: String) -> Account? { status?.account(id) }
    var menuBarTitle: String { status?.menuBarTitle ?? "" }
    /// Badge count for the menu bar: paused sessions, shown only when notifications are not allowed.
    var menuBarBadge: Int { notifier.allowed ? 0 : (status?.paused.count ?? 0) }
    var wrongAccountHint: String? { status?.wrongAccountHint }

    // MARK: actions

    func switchTo(_ a: Account) {
        guard Dialog.confirm("Switch to \(a.title)?",
            "Claude quits, loads the saved login of this account, and opens again. Your current login is saved first, so you can switch back at any time.\n\nRunning tasks in Claude stop. Finish them first.",
            ok: "Switch") else { return }
        Task {
            guard let r = await perform("Switching to \(a.title)… If Claude asks to confirm the quit, click Quit.", ["switch", a.id]) else { return }
            let shared = r["shared"] as? Int ?? 0
            let warning = r["warning"] as? String
            busy = "Checking the login…"
            let v = await run(["verify", a.id])
            busy = nil
            await refresh()
            let obj = v.json
            if obj["ok"] as? Bool == true {
                let text = "Signed in as \(a.title)." + (shared > 0 ? " \(shared) sessions shared." : "")
                banner = warning.map { .warning(text + " " + $0) } ?? .success(text)
                notifier.say("Switched account", text)
            } else {
                banner = .error(obj["message"] as? String ?? v.output)
                notifier.say("Login expired", "\(a.title): sign in again in Claude. The app saves the new login.")
            }
        }
    }

    /// ⌃⌥⌘N: switch to the next account that is mine and has a saved login, in panel order.
    /// Does nothing while a switch or another engine task runs.
    func switchToNext() {
        guard busy == nil, !nextRunning else { return }
        nextRunning = true
        Task {
            defer { nextRunning = false }
            await refresh()
            guard busy == nil else { return }
            guard let next = status?.nextAccount(showHidden: showHidden) else {
                notifier.say("No other account", "Save the login of another account first. Then the shortcut can switch to it.")
                return
            }
            switchTo(next)
        }
    }

    /// ⌃⌥⌘C: open the panel, as a click on the menu bar icon does.
    func openPanel() {
        NSApp.activate(ignoringOtherApps: true)
        func button(in v: NSView?) -> NSStatusBarButton? {
            guard let v else { return nil }
            if let b = v as? NSStatusBarButton { return b }
            return v.subviews.lazy.compactMap { button(in: $0) }.first
        }
        for w in NSApp.windows where w.className.contains("StatusBar") {
            if let b = button(in: w.contentView) { b.performClick(nil); return }
        }
    }

    /// Turns a shortcut on or off (Settings → General).
    func setShortcut(_ key: HotKeys.Key, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key.setting)
        hotKeys?.apply()
        objectWillChange.send()
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

    /// "Sign in to save": the `add` flow, then wait until Claude is signed in to the picked account.
    func signInToSave(_ a: Account) {
        guard Dialog.confirm("Sign in to \(a.title) to save its login?",
            "1. Claude quits. Your current login is saved first.\n2. Claude opens signed out.\n3. In Claude, sign in to \(a.title).\n4. The app sees the sign-in and saves the login. It tells you when the login is saved.\n\nRunning tasks in Claude stop. Finish them first.",
            ok: "Continue") else { return }
        Task {
            guard await perform("Saving your login…", ["add"]) != nil else { return }
            banner = .info("Now sign in to \(a.title) in Claude. The app waits for the sign-in.")
            await waitForSignIn(a)
        }
    }

    private func waitForSignIn(_ a: Account) async {
        let end = Date().addingTimeInterval(15 * 60)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let r = await run(["save-login", a.id])
            guard r.ok else { banner = .error(r.output); return }
            if let b = Status.signInResult(r.json, title: a.title) {
                banner = b
                await refresh()
                if case .success(let t) = b { notifier.say("Login saved", t) }
                else if case .warning(let t) = b { notifier.say("Different account", t) }
                return
            }
        }
        banner = .info("No sign-in to \(a.title) in 15 minutes. Click Sign in to save to try again.")
    }

    func syncNow() {
        Task {
            guard let s = status else { return }
            guard !s.ownedAccounts.isEmpty else {
                banner = .info("Mark your own accounts first: right-click an account, then Mark as mine.")
                return
            }
            let dry = await run(["sync", "--dry-run"])
            guard dry.ok, let r = try? JSONDecoder().decode(SyncResult.self, from: Data(dry.output.utf8)) else {
                banner = .error(dry.output); return
            }
            guard r.changes > 0 else { banner = .info("All your accounts already have every session."); return }
            let p = Self.syncPrompt(s, r)
            guard Dialog.confirm(p.title, p.text, ok: "Sync") else { return }
            if let out = await perform("Syncing sessions…", ["sync"]) {
                banner = .success("\(out["changes"] as? Int ?? 0) sessions synced.")
            }
        }
    }

    /// Title and text of the sync preview dialog.
    static func syncPrompt(_ s: Status, _ r: SyncResult) -> (title: String, text: String) {
        let lines = s.syncPreview(r).map { "• " + $0 }.joined(separator: "\n")
        let first = s.settings.syncConfirmed ? "" : "This is your first sync. Check the numbers.\n\n"
        return ("Sync \(r.changes) sessions between your accounts?",
                first + lines + "\n\nA backup is made first. Claude quits during the sync and opens again. Accounts that are not marked as mine are not touched.")
    }

    func setOwned(_ a: Account, _ mine: Bool) {
        Task { await perform("Saving…", [mine ? "mine" : "not-mine", a.id]) }
    }

    func restoreBackup() {
        Task {
            let r = await run(["backups"])
            guard r.ok, let data = try? JSONSerialization.data(withJSONObject: r.json["backups"] ?? []),
                  let list = try? JSONDecoder().decode([BackupInfo].self, from: data), !list.isEmpty else {
                banner = .info("No backups yet."); return
            }
            let titles = list.map { b in b.title + "  (\(b.sessions) sessions)" }
            guard let i = Dialog.choose("Restore a backup",
                "The session lists of all accounts go back to the backup. The current state is backed up first, so you can undo this. Claude quits and opens again.\n\nA \"Removed account\" backup brings back only the sessions of that account.",
                titles, ok: "Restore") else { return }
            await restoreDone(list[i], await perform("Restoring…", ["restore", list[i].name]))
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

    func remove(_ a: Account) {
        if let why = Status.removeRefusal(status, a) { banner = .info(why); return }
        guard let s = status else { return }
        let c = s.removeConfirmation(a)
        guard Dialog.confirm(c.title, c.text, ok: "Remove") else { return }
        Task {
            if let r = await perform("Removing \(a.title)…", ["remove", a.id]) {
                banner = .success("Removed \(a.title). Its sessions are in the backup \(r["backup"] as? String ?? "").")
                await loadBackups()
            }
        }
    }

    func setHidden(_ a: Account, _ hide: Bool) {
        Task { await perform("Saving…", [hide ? "hide" : "unhide", a.id]) }
    }

    func setPinned(_ a: Account, _ pin: Bool) {
        Task { await perform("Saving…", [pin ? "pin" : "unpin", a.id]) }
    }

    /// Saves the order after a drag in Settings → Accounts.
    func reorder(_ ids: [String], to index: Int) {
        guard let order = status?.orderAfterMove(ids, to: index), order != accounts.map(\.id) else { return }
        Task { await perform("Saving…", ["order"] + order) }
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

    // MARK: updates

    func checkForUpdate() async {
        lastUpdateCheck = Date()
        let r = await run(["update-check", Self.version])
        update = try? JSONDecoder().decode(UpdateInfo.self, from: Data(r.output.utf8))
    }

    func installUpdate() {
        guard let tag = update?.latest else { return }
        guard Dialog.confirm("Install Claude Accounts \(tag)?",
            "The app downloads the release, checks its checksum, replaces itself, and opens again. Claude is not touched.",
            ok: "Install") else { return }
        Task {
            if await perform("Downloading \(tag)…", ["update-install", tag]) != nil {
                busy = "Installing \(tag)…"  // the installer stops this app and opens the new one
            }
        }
    }

    // MARK: uninstall

    func uninstall() {
        guard Dialog.confirm("Uninstall Claude Accounts?",
            """
            This removes the app, the login item and the claude-switch and claude-accounts commands. \
            Claude and its sessions do not change.

            These stay, so you can install again without losing anything:
            • Saved logins and settings: ~/Library/Application Support/Claude Account Switcher
            • Backups: ~/Backups/claude-sessions
            """, ok: "Uninstall") else { return }
        Task {
            busy = "Uninstalling…"; banner = nil
            // The engine stops this app when it is done, so there is nothing to refresh after it.
            let r = await run(["uninstall"])
            busy = nil
            if r.ok { NSApp.terminate(nil) } else { banner = .error(r.output) }
        }
    }

    // MARK: windows

    /// Opens (or brings to front) a normal window. The app is a menu bar app, so it must
    /// activate itself for the window to come to the front.
    func open<V: View>(_ id: String, title: String, _ view: V) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view.environmentObject(self)))
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[id] = w
    }

    func showSettings(tab: String = "general") {
        windows["settings"]?.close(); windows["settings"] = nil
        open("settings", title: "Claude Accounts Settings", SettingsView(tab: tab))
    }

    func showWelcome() {
        open("welcome", title: "Welcome to Claude Accounts",
             WelcomeView(close: { [weak self] in self?.windows["welcome"]?.close() }))
    }

    func finishWelcome() { UserDefaults.standard.set(true, forKey: "welcomeDone") }

    func loadBackups() async {
        let r = await run(["backups"])
        guard r.ok, let data = try? JSONSerialization.data(withJSONObject: r.json["backups"] ?? []),
              let list = try? JSONDecoder().decode([BackupInfo].self, from: data) else { return }
        backups = list
    }

    func restore(_ b: BackupInfo) {
        guard Dialog.confirm("Restore the backup \(b.title)?", b.isRemoved
            ? "The sessions of the removed account come back. Other accounts do not change. The account comes back as not mine and without a saved login."
            : "The session lists of all accounts go back to this backup. The current state is backed up first, so you can undo this. Claude quits and opens again.",
            ok: "Restore") else { return }
        Task {
            await restoreDone(b, await perform("Restoring…", ["restore", b.name]))
            await loadBackups()
        }
    }

    private func restoreDone(_ b: BackupInfo, _ out: [String: Any]?) async {
        guard let out else { return }
        banner = .success(b.isRemoved ? "The sessions of the removed account are back."
            : "Restored \(b.title). To undo, restore \"Before restore\" (\(out["undo"] as? String ?? "")).")
    }

    /// Copies the engine's debug report (no emails, no account IDs) to the clipboard.
    /// Returns a short message for the user.
    func copyDebugReport() async -> String {
        let r = await run(["report"])
        guard r.ok, !r.output.isEmpty else { return "Cannot make the report: \(r.output)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.output, forType: .string)
        return "Report copied. It has no emails and no account IDs."
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
        return alert(title, text, ok: ok).runModal() == .alertFirstButtonReturn
    }

    /// The alert that `confirm` shows (also used by the debug render of the sync preview).
    static func alert(_ title: String, _ text: String, ok: String) -> NSAlert {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
        return a
    }

    /// A list choice. Returns the chosen index, or nil.
    static func choose(_ title: String, _ text: String, _ items: [String], ok: String) -> Int? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        pop.addItems(withTitles: items)
        a.accessoryView = pop
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? pop.indexOfSelectedItem : nil
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
