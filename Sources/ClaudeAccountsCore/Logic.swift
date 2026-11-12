import Foundation

/// The debug renders (--render, --render-settings, --render-sync, --render-welcome) for the README
/// screenshots. A render draws one PNG and exits: no notifications, timer, shortcuts or welcome window.
public enum RenderMode {
    public static func isOn(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains { $0.hasPrefix("--render") }
    }
}

/// Derived state the UI shows. Pure functions, so CoreTests can check them.
public extension Status {
    var currentAccount: Account? { accounts.first(where: { $0.current }) }

    func account(_ id: String) -> Account? { accounts.first(where: { $0.id == id }) }

    /// Accounts to list. The current account always shows, even when hidden.
    func visibleAccounts(showHidden: Bool) -> [Account] {
        accounts.filter { showHidden || !$0.hidden || $0.current }
    }

    /// Accounts in panel order: pinned accounts first, then the saved order, then accounts
    /// not in the saved order (new ones) in engine order. The panel, Settings and the
    /// next-account shortcut all use this order.
    func panelOrder(showHidden: Bool) -> [Account] {
        let rank = Dictionary(settings.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = Set(settings.pinned)
        func key(_ e: (offset: Int, element: Account)) -> (Int, Int, Int) {
            (pinned.contains(e.element.id) ? 0 : 1, rank[e.element.id] ?? Int.max, e.offset)
        }
        return visibleAccounts(showHidden: showHidden).enumerated()
            .sorted { key($0) < key($1) }
            .map(\.element)
    }

    /// The full saved order after a drag in Settings: `ids` move to `index` of the panel order
    /// with hidden accounts shown (an insert index, as in a SwiftUI drop).
    func orderAfterMove(_ ids: [String], to index: Int) -> [String] {
        let all = panelOrder(showHidden: true).map(\.id)
        let moving = all.filter { ids.contains($0) }
        let before = all.prefix(max(0, min(index, all.count))).filter { ids.contains($0) }.count
        var rest = all.filter { !ids.contains($0) }
        rest.insert(contentsOf: moving, at: max(0, min(index - before, rest.count)))
        return rest
    }

    /// The account the next-account shortcut switches to: the first account after the current one
    /// in panel order that is mine and has a saved login. Wraps from the last account to the first.
    /// Nil when no other account fits.
    func nextAccount(showHidden: Bool) -> Account? {
        let list = panelOrder(showHidden: showHidden)
        let start = list.firstIndex(where: { $0.current }).map { $0 + 1 } ?? 0
        return (list[start...] + list[..<start]).first { !$0.current && $0.owned && $0.savedLogin }
    }

    func isPinned(_ id: String) -> Bool { settings.pinned.contains(id) }

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
        if json["op"] as? String == "remove" {
            return json["action"] as? String == "finished"
                ? "A removal of an account stopped in the middle. It is now finished. Its sessions are in the backups."
                : "A removal of an account stopped before it changed anything. The account is unchanged."
        }
        switch json["action"] as? String {
        case "rolled back": return "A switch stopped in the middle (after \(step)). Your previous login is back."
        case "finished": return "A switch stopped in the middle (after \(step)). It is now finished."
        default: return "A switch stopped before it changed anything. Claude is unchanged."
        }
    }

    /// Claude must always keep its signed-in account, so the current account cannot be removed.
    func canRemove(_ a: Account) -> Bool { !a.current }

    /// Why `a` cannot be removed now, or nil when it can. `status` is nil before the first refresh.
    static func removeRefusal(_ status: Status?, _ a: Account) -> String? {
        guard let status else { return "The app has not read the accounts yet. Try again in a moment." }
        return status.canRemove(a) ? nil : "You cannot remove the current account. Switch to another account first."
    }

    /// Title and text of the confirm dialog for `claude-switch remove`.
    func removeConfirmation(_ a: Account) -> (title: String, text: String) {
        ("Remove \(a.title)?",
         "The app deletes the saved login, the name and the settings of this account. "
         + "Sync no longer uses it. Its sessions move into the backups. "
         + "To get them back, restore \"Removed account \(a.id.prefix(8))\" in Backups.\n\n"
         + "The account comes back only when you sign in to it again in Claude.")
    }

    /// Banner for the result of `claude-switch save-login <account>`, or nil while Claude is not signed in yet.
    static func signInResult(_ json: [String: Any], title: String) -> Banner? {
        if json["saved"] as? Bool == true {
            return .success("Login of \(title) is saved. You can now switch to it with one click.")
        }
        if json["match"] as? Bool == false {
            return .warning(json["message"] as? String ?? "Claude is signed in to another account. The login of \(title) was not saved.")
        }
        return nil
    }

    var ownedAccounts: [Account] { accounts.filter(\.owned) }

    /// Engine arguments for the debug report. The app adds the settings only it knows
    /// (the keyboard shortcuts), as on/off.
    /// `liveUsage` adds each account's live usage state: "ok", or the newest error type. Never a
    /// percent or a cookie: the report is for a GitHub issue.
    static func reportArguments(appSettings: [(String, Bool)], liveUsage: [String: CachedUsage] = [:]) -> [String] {
        ["report"] + appSettings.flatMap { ["--app-setting", "\($0.0)=\($0.1 ? "on" : "off")"] }
            + liveUsage.sorted { $0.key < $1.key }.flatMap { ["--live-usage", "\($0.key)=\($0.value.error ?? "ok")"] }
    }

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

    /// Grey line under an account that hit its limit, for example "Weekly limit resets Mon 8:30 PM".
    /// It uses the latest future reset of the account's last limit hit and its paused sessions;
    /// the window is named when the last limit hit gives that time. Nil when no reset is in the future.
    func resetLine(for accountID: String, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let limit = account(accountID)?.limit
        let resets = paused.filter { $0.account == accountID }.compactMap(\.resetsAt) + [limit?.resetsAt].compactMap { $0 }
        guard let next = resets.filter({ $0 > now.timeIntervalSince1970 }).max() else { return nil }
        let name = limit?.resetsAt == next && limit?.window != nil ? "\(limit!.windowName) limit" : "Limit"
        return "\(name) resets " + Self.resetTime(Date(timeIntervalSince1970: next), now: now, timeZone: timeZone)
    }

    /// Live usage under an account: a bar for each limit (5h, Week, then scoped and new kinds), or
    /// why it is unavailable. Nil when the setting is off or the account was not asked (no login).
    func liveState(for accountID: String, cache: [String: CachedUsage], now: Date = Date(),
                   timeZone: TimeZone = .current) -> LiveRowState? {
        guard settings.liveUsageOn, let c = cache[accountID] else { return nil }
        if c.limits.isEmpty {
            return .unavailable(c.error.map(LiveAccountUsage.reason) ?? "claude.ai sent no usage for this account.")
        }
        let first = ["session", "weekly_all"]
        let ordered = first.compactMap { k in c.limits.first { $0.kind == k } } + c.limits.filter { !first.contains($0.kind) }
        let bars = ordered.map { l in
            UsageBar(label: UsageBar.label(kind: l.kind, model: l.label), percent: l.percent,
                     resetText: l.resetsAt.flatMap { $0 > now.timeIntervalSince1970
                         ? Self.resetTime(Date(timeIntervalSince1970: $0), now: now, timeZone: timeZone) : nil })
        }
        guard let error = c.error else { return .bars(bars, lastRead: nil, reason: nil) }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        let age = f.localizedString(for: Date(timeIntervalSince1970: min(c.readAt, now.timeIntervalSince1970 - 1)), relativeTo: now)
        return .bars(bars, lastRead: "Last read " + age, reason: LiveAccountUsage.reason(error))
    }

    /// The warning when the active account reaches 90% of its 5-hour limit, or nil. It uses fresh
    /// values only (a failed newest read can be out of date), and comes once for each 5-hour window:
    /// `alreadyWarned` has the keys of the warnings already sent. It names the "mine" account with
    /// a saved login and the most free capacity: under 90% of both its 5-hour and weekly limits.
    func usageWarning(cache: [String: CachedUsage], enabled: Bool, alreadyWarned: Set<String>) -> UsageWarning? {
        guard enabled, settings.liveUsageOn, let cur = currentAccount, let c = cache[cur.id], c.error == nil,
              let five = c.limits.first(where: { $0.kind == "session" }), five.percent >= 90 else { return nil }
        let key = "\(cur.id)|\(five.resetsAt.map { String(Int($0)) } ?? "unknown")"
        guard !alreadyWarned.contains(key) else { return nil }
        func percent(_ u: CachedUsage?, _ kind: String) -> Double? { u?.limits.first { $0.kind == kind }?.percent }
        let free = accounts.filter { $0.owned && !$0.current && $0.savedLogin }.compactMap { a -> (Account, Double, Double)? in
            guard let f = percent(cache[a.id], "session"), f < 90 else { return nil }
            let w = percent(cache[a.id], "weekly_all") ?? 0
            return w < 90 ? (a, f, w) : nil
        }.min { ($0.1, $0.2, $0.0.title) < ($1.1, $1.2, $1.0.title) }
        let pct = { (p: Double) in "\(Int(p.rounded()))%" }
        let first = "\(cur.title) is at \(pct(five.percent)) of its 5-hour limit."
        let body = free.map { a, f, w in "\(first) \(a.title) has the most free capacity: 5h \(pct(f)), week \(pct(w))." }
            ?? "\(first) No other account of yours has free capacity now."
        return UsageWarning(key: key, title: "5-hour limit at \(pct(five.percent))", body: body, target: free?.0.id)
    }

    /// Second line of a paused session row: the reset time while it is in the future, then the account.
    func pausedSubtitle(_ p: PausedSession, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let who = account(p.account)?.shortTitle ?? String(p.account.prefix(8))
        guard let at = p.resetsAt, at > now.timeIntervalSince1970 else { return "Limit reached · \(who)" }
        return "Limit resets " + Self.resetTime(Date(timeIntervalSince1970: at), now: now, timeZone: timeZone) + " · \(who)"
    }

    /// "4:50 PM" today, else "Sun 4:50 PM".
    static func resetTime(_ t: Date, now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = cal.isDate(t, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: t)
    }

    /// Sessions that are paused now but were not paused in `previous`.
    func newlyPaused(since previous: Status?) -> [PausedSession] {
        let old = Set(previous?.paused.map(\.id) ?? [])
        return paused.filter { !old.contains($0.id) }
    }
}
