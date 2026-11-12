import Foundation

/// Invites users who installed with the install command (and so never saw the GitHub page) to
/// visit it: one polite star request after the app proved its value, and a "What's new" link
/// after an update. Nothing is sent anywhere: the counts stay in the app's preferences, and the
/// app never stars the repo itself.
public enum Promotion {
    public static let repoURL = URL(string: "https://github.com/jomonkj/claude-accounts")!

    public static func releaseURL(version: String) -> URL {
        repoURL.appendingPathComponent("releases/tag/v\(version)")
    }

    /// The star request shows after this many successful switches.
    public static let starAfterSwitches = 10

    /// True from the 10th successful switch until the user answers (either button), then never again.
    public static func shouldAskForStar(successfulSwitches: Int, answered: Bool) -> Bool {
        !answered && successfulSwitches >= starAfterSwitches
    }

    public static func starRequestText(successfulSwitches: Int) -> String {
        "Claude Accounts saved you \(successfulSwitches) sign-outs. A star on GitHub helps other people find it."
    }

    /// A released version such as "1.3.0", not a development build such as "1.2.0-8-g68e5dc3".
    public static func isRelease(_ version: String) -> Bool {
        version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    /// The version to announce with "What's new", or nil. Not on the first install (`lastSeen` is
    /// nil), and never for a development build.
    public static func whatsNew(current: String, lastSeen: String?) -> String? {
        guard isRelease(current), let lastSeen, lastSeen != current else { return nil }
        return current
    }
}
