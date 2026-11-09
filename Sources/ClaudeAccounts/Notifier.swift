import AppKit
@preconcurrency import UserNotifications
import ClaudeAccountsCore

/// Sends macOS notifications. A "limit reached" notification has one Switch button per
/// "mine" account with a saved login. The app never switches without that click, and the
/// click still shows the normal switch confirmation.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// false when macOS does not allow notifications for this app; the menu bar then shows a badge.
    @Published private(set) var allowed = true
    var onSwitch: ((String) -> Void)?

    private let notifiedKey = "notifiedPausedSessions"
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Set by start(). A Store made for a debug render never starts, so it never notifies.
    private var started = false

    func start() {
        guard let center else { allowed = false; return }
        started = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.allowed = ok }
        }
    }

    private var notified: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: notifiedKey) }
    }

    /// Notify each paused session one time. Sessions that are no longer paused are forgotten,
    /// so a session that stops on the limit again is notified again.
    func update(_ status: Status) {
        guard started else { return }
        let now = Set(status.paused.map(\.id))
        let fresh = status.pausedToNotify(alreadyNotified: notified)
        notified = notified.intersection(now).union(fresh.map(\.id))
        guard allowed, let center else { return }
        for p in fresh {
            let targets = status.switchTargets()
            let category = "limit-\(p.id)"
            let actions = targets.map {
                UNNotificationAction(identifier: "switch:\($0.id)", title: "Switch to \($0.shortTitle)", options: [.foreground])
            } + [UNNotificationAction(identifier: "open:\(p.id)", title: "Open session", options: [.foreground])]
            center.getNotificationCategories { cats in
                var all = cats.filter { !$0.identifier.hasPrefix("limit-") || $0.identifier == category }
                all.insert(UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: []))
                center.setNotificationCategories(all)
                let text = status.notificationText(for: p)
                let content = UNMutableNotificationContent()
                content.title = text.title
                content.body = text.body
                content.categoryIdentifier = category
                center.add(UNNotificationRequest(identifier: category, content: content, trigger: nil))
            }
        }
    }

    func say(_ title: String, _ body: String) {
        guard started, allowed, let center else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = response.actionIdentifier
        Task { @MainActor in
            if id.hasPrefix("switch:") { self.onSwitch?(String(id.dropFirst("switch:".count))) }
            else if id.hasPrefix("open:") {
                NSWorkspace.shared.open(URL(string: "claude://claude.ai/epitaxy/\(id.dropFirst("open:".count))")!)
            }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
