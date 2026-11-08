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

    /// True when another account has a saved login, so a switch is possible.
    var canSwitchElsewhere: Bool { accounts.contains(where: { !$0.current && $0.savedLogin }) }

    /// Sessions that are paused now but were not paused in `previous`.
    func newlyPaused(since previous: Status?) -> [PausedSession] {
        let old = Set(previous?.paused.map(\.id) ?? [])
        return paused.filter { !old.contains($0.id) }
    }
}
