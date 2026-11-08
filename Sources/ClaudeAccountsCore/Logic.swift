import Foundation

/// Derived state the UI shows. Pure functions, so CoreTests can check them.
public extension Status {
    var currentAccount: Account? { accounts.first(where: { $0.current }) }

    func account(_ id: String) -> Account? { accounts.first(where: { $0.id == id }) }

    /// Accounts to list. The current account always shows, even when hidden.
    func visibleAccounts(showHidden: Bool) -> [Account] {
        accounts.filter { showHidden || !$0.hidden || $0.current }
    }

    var hiddenCount: Int { accounts.filter { $0.hidden && !$0.current }.count }

    /// Text next to the menu bar icon, or "" when the setting is off.
    var menuBarTitle: String {
        guard settings.showNameInMenuBar, let c = currentAccount else { return "" }
        return c.shortTitle
    }

    /// Warning when the active account has few sessions and another account has many.
    var wrongAccountHint: String? {
        guard let cur = currentAccount, let top = accounts.max(by: { $0.sessions < $1.sessions }),
              top.id != cur.id, cur.sessions < 10, top.sessions > 50 else { return nil }
        return "This account has only \(cur.sessions) sessions. Your \(top.sessions) sessions are in \(top.title)."
    }

    /// Warning about the Claude version or login layout, or nil when all is known.
    var guardBanner: Banner? {
        if !layoutProblems.isEmpty {
            return .error("Switching is blocked. Claude \(claudeVersion) stores its login in a way this app does not know: "
                + layoutProblems.joined(separator: "; ") + ". Update Claude Accounts.")
        }
        if !versionTested {
            return .info("Claude \(claudeVersion.isEmpty ? "(unknown version)" : claudeVersion) is not tested yet. Its login layout looks the same, so switching works. The first good switch marks it as tested.")
        }
        return nil
    }

    /// Text for the result of `claude-switch recover`.
    static func recoverMessage(_ json: [String: Any]) -> String? {
        guard json["recovered"] as? Bool == true else { return nil }
        let step = json["step"] as? String ?? "?"
        switch json["action"] as? String {
        case "rolled back": return "A switch stopped in the middle (after \(step)). Your previous login is back."
        case "finished": return "A switch stopped in the middle (after \(step)). It is now finished."
        default: return "A switch stopped before it changed anything. Claude is unchanged."
        }
    }

    /// Banner for the result of `claude-switch save-login <account>`, or nil while Claude is not signed in yet.
    static func signInResult(_ json: [String: Any], title: String) -> Banner? {
        if json["saved"] as? Bool == true {
            return .success("Login of \(title) is saved. You can now switch to it with one click.")
        }
        if json["match"] as? Bool == false {
            return .warning(json["message"] as? String ?? "Claude is signed in to a different account. The login was not saved under \(title).")
        }
        return nil
    }

    var ownedAccounts: [Account] { accounts.filter(\.owned) }

    /// Lines for the sync preview, for example "jomon@example.com: 16 sessions". Accounts with 0 changes are left out.
    func syncPreview(_ r: SyncResult) -> [String] {
        r.accounts.filter { $0.value > 0 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\(account($0.key)?.title ?? String($0.key.prefix(8))): \($0.value) sessions" }
    }

    /// True when another account has a saved login, so a switch is possible.
    var canSwitchElsewhere: Bool { accounts.contains(where: { !$0.current && $0.savedLogin }) }

    /// Paused sessions that have not been notified yet.
    func pausedToNotify(alreadyNotified: Set<String>) -> [PausedSession] {
        paused.filter { !alreadyNotified.contains($0.id) }
    }

    /// Accounts a notification can offer to switch to: mine, with a saved login, not current.
    func switchTargets(limit: Int = 3) -> [Account] {
        Array(accounts.filter { !$0.current && $0.savedLogin && $0.owned }.prefix(limit))
    }

    /// Title and body of the notification for a paused session.
    func notificationText(for p: PausedSession) -> (title: String, body: String) {
        let who = account(p.account)?.title ?? String(p.account.prefix(8))
        let reset = p.resets.isEmpty ? "" : " Resets \(p.resets)."
        return ("Usage limit reached", "\"\(p.title)\" stopped on \(who).\(reset)")
    }

    /// Sessions that are paused now but were not paused in `previous`.
    func newlyPaused(since previous: Status?) -> [PausedSession] {
        let old = Set(previous?.paused.map(\.id) ?? [])
        return paused.filter { !old.contains($0.id) }
    }
}
