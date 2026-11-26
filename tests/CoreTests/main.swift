// Tests for ClaudeAccountsCore. Run: swift run CoreTests
// (XCTest and swift-testing need Xcode, so this is a plain program that exits 1 on failure.)
import Foundation
import ClaudeAccountsCore

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0
/// A value that a @Sendable closure can change (for the fake network layer).
final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

/// A random generator with a fixed seed, so a property test gives the same cases on every run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func check(_ name: String, _ ok: @autoclosure () -> Bool) {
    if ok() { passed += 1; print("  ok   \(name)") } else { failed += 1; print("  FAIL \(name)") }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fixtures = root.appendingPathComponent("Fixtures")
let engine = EngineClient(path: fixtures.appendingPathComponent("fake-engine").path)
let log = FileManager.default.temporaryDirectory.appendingPathComponent("fake-engine-\(getpid()).log")
setenv("FAKE_ENGINE_LOG", log.path, 1)

let A = "aaaa1111-0000-0000-0000-000000000000", B = "bbbb2222-0000-0000-0000-000000000000"

func main() async {
    print("EngineClient")
    let status = try? await engine.status()
    check("decodes status", status != nil)
    guard let s = status else { exit(1) }
    check("passes arguments", (try? String(contentsOf: log, encoding: .utf8))?.contains("status") == true)
    let fail = await engine.run(["fail"])
    check("error result is not ok", !fail.ok)
    check("error message has no ERROR prefix", fail.output == "Claude did not quit.")
    let ok = await engine.run(["share", "--dry-run"])
    check("json of a good result", ok.ok && ok.json["count"] as? Int == 4)
    let bad = await engine.run(["badjson"])
    check("json of non-JSON output is empty", bad.json.isEmpty)
    let missing = await EngineClient(path: "/nonexistent/engine").run(["status"])
    check("missing engine is an error, not a crash", !missing.ok)

    print("Status logic")
    check("current account", s.currentAccount?.id == A)
    check("lookup by id", s.account(B)?.name == "jomon@example.com (Team)")
    check("hidden account not visible", s.visibleAccounts(showHidden: false).map(\.id) == [A, B])
    check("hidden account visible when asked", s.visibleAccounts(showHidden: true).count == 3)
    check("hidden count", s.hiddenCount == 1)
    check("menu bar shows short id for unnamed account", s.menuBarTitle == "aaaa")
    check("wrong-account hint names the big account",
          s.wrongAccountHint == "This account has only 3 sessions. Your 728 sessions are in jomon@example.com (Team).")
    check("can switch elsewhere", s.canSwitchElsewhere)
    check("all paused are new on first status", s.newlyPaused(since: nil).map(\.id) == ["local_p1"])
    check("paused not new the second time", s.newlyPaused(since: s).isEmpty)

    check("no guard banner for a tested version", s.guardBanner == nil)
    let untested = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"versionTested\": true", with: "\"versionTested\": false").utf8))
    if case .info(let t)? = untested.guardBanner { check("info banner for an untested version", t.contains("not tested yet")) }
    else { check("info banner for an untested version", false) }
    let broken = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"layoutProblems\": []", with: "\"layoutProblems\": [\"no Cookies\"]").utf8))
    if case .error(let t)? = broken.guardBanner { check("error banner for an unknown layout", t.contains("no Cookies")) }
    else { check("error banner for an unknown layout", false) }
    check("recover message: rolled back", Status.recoverMessage(["recovered": true, "action": "rolled back", "step": "saved"])?.contains("previous login is back") == true)
    check("recover message: finished", Status.recoverMessage(["recovered": true, "action": "finished", "step": "loaded"])?.contains("now finished") == true)
    check("recover message: nothing", Status.recoverMessage(["recovered": false]) == nil)
    check("recover message: removal finished", Status.recoverMessage(["recovered": true, "op": "remove", "action": "finished", "step": "moved"]) == "A removal of an account stopped in the middle. It is now finished. Its sessions are in the backups.")
    check("recover message: removal rolled back", Status.recoverMessage(["recovered": true, "op": "remove", "action": "rolled back", "step": "started"]) == "A removal of an account stopped before it changed anything. The account is unchanged.")

    print("Remove account")
    let other = s.account(B)!
    check("other account can be removed", s.canRemove(other))
    check("current account cannot be removed", !s.canRemove(s.currentAccount!))
    check("remove refusal: none for another account", Status.removeRefusal(s, other) == nil)
    check("remove refusal: current account", Status.removeRefusal(s, s.currentAccount!)
          == "You cannot remove the current account. Switch to another account first.")
    check("remove refusal: no status yet is not called the current account",
          Status.removeRefusal(nil, other) == "The app has not read the accounts yet. Try again in a moment.")
    let confirm = s.removeConfirmation(other)
    check("confirm title names the account", confirm.title == "Remove jomon@example.com (Team)?")
    for word in ["saved login", "name", "settings", "sessions", "backups", "sign in"] {
        check("confirm text says what happens: \(word)", confirm.text.contains(word))
    }

    check("owned accounts", s.ownedAccounts.map(\.id) == [A, B])
    let preview = try! JSONDecoder().decode(SyncResult.self, from: Data(
        #"{"changes": 20, "accounts": {"\#(A)": 4, "\#(B)": 16, "zzzz9999": 0}, "skipped": [], "dryRun": true}"#.utf8))
    check("sync preview: biggest first, names, no zero lines",
          s.syncPreview(preview) == ["jomon@example.com (Team): 16 sessions", "Account aaaa1111: 4 sessions"])
    let backups = try! JSONDecoder().decode([BackupInfo].self, from: Data(
        #"[{"name": "2026-11-08", "kind": "daily", "time": "2026-11-08", "sessions": 10, "modified": 1}, {"name": "pre-restore-20261108-1200", "kind": "pre-restore", "time": "2026-11-08 12:00", "sessions": 9, "modified": 2}]"#.utf8))
    check("undo backup is marked by its kind", backups.map(\.isUndo) == [false, true])
    let removedBackup = try! JSONDecoder().decode(BackupInfo.self, from: Data(
        #"{"name": "removed-x", "kind": "removed", "time": "2026-11-08 12:34", "account": "bbbb2222", "sessions": 3, "modified": 3}"#.utf8))
    check("removed-account backup is marked by its kind", removedBackup.isRemoved && !removedBackup.isUndo && !backups[0].isRemoved)
    check("backup titles", backups.map(\.title) == ["2026-11-08", "Before restore 2026-11-08 12:00"])
    check("removed-account backup title", removedBackup.title == "Removed account bbbb2222 (2026-11-08 12:34)")
    let oldEngine = try! JSONDecoder().decode(BackupInfo.self, from: Data(#"{"name": "2026-11-07", "sessions": 1, "modified": 1}"#.utf8))
    check("backup without a kind (older engine) is a plain backup", oldEngine.title == "2026-11-07" && !oldEngine.isUndo)

    check("paused to notify: new one", s.pausedToNotify(alreadyNotified: []).map(\.id) == ["local_p1"])
    check("paused to notify: already notified", s.pausedToNotify(alreadyNotified: ["local_p1"]).isEmpty)
    let ist = TimeZone(identifier: "Asia/Calcutta")!
    let resetAt = Date(timeIntervalSince1970: 1794136800)  // 2026-11-08 4:50 PM in Asia/Calcutta
    let note = s.notificationText(for: s.paused[0], now: resetAt.addingTimeInterval(-3600), timeZone: ist)
    check("notification text: the exact reset time", note.title == "Usage limit reached"
          && note.body == "\"AWS capacity\" stopped on jomon@example.com (Team). Resets 4:50 PM.")
    check("notification names the day of a later reset",
          s.notificationText(for: s.paused[0], now: resetAt.addingTimeInterval(-86400), timeZone: ist).body
          == "\"AWS capacity\" stopped on jomon@example.com (Team). Resets Sun 4:50 PM.")
    let weeklyStatus = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"resetsAt\": 1794136800,", with: "\"resetsAt\": 1794136800, \"window\": \"week\",").utf8))
    check("paused window decoded", weeklyStatus.paused[0].window == "week" && s.paused[0].window == nil)
    check("notification names the window", weeklyStatus.notificationText(for: weeklyStatus.paused[0], now: resetAt, timeZone: ist).title
          == "Weekly limit reached")
    let noEpoch = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"resetsAt\": 1794136800", with: "\"resetsAt\": null").utf8))
    check("notification without a reset epoch uses the reset text",
          noEpoch.notificationText(for: noEpoch.paused[0], now: resetAt, timeZone: ist).body
          == "\"AWS capacity\" stopped on jomon@example.com (Team). Resets 4:50pm (Asia/Calcutta).")

    print("Reset time")
    check("reset time decoded", s.paused[0].resetsAt == 1794136800)
    check("reset line before the reset",
          s.resetLine(for: B, now: resetAt.addingTimeInterval(-3600), timeZone: ist) == "Limit resets 4:50 PM")
    check("reset line names the day when it is not today",
          s.resetLine(for: B, now: resetAt.addingTimeInterval(-86400), timeZone: ist) == "Limit resets Sun 4:50 PM")
    check("no reset line after the reset", s.resetLine(for: B, now: resetAt.addingTimeInterval(1), timeZone: ist) == nil)
    check("no reset line for an account without a limit",
          s.resetLine(for: "cccc3333-0000-0000-0000-000000000000", now: resetAt.addingTimeInterval(-3600), timeZone: ist) == nil)

    print("Last limit hit")
    let weeklyAt = Date(timeIntervalSince1970: 1794236400)  // Mon 2026-11-09 8:30 PM in Asia/Calcutta
    check("decodes the limit", s.currentAccount?.limit?.window == "week" && s.currentAccount?.limit?.resetsAt == 1794236400)
    check("missing limit decodes as nil", s.account(B)?.limit == nil)
    check("weekly reset line names the window",
          s.resetLine(for: A, now: resetAt, timeZone: ist) == "Weekly limit resets Mon 8:30 PM")
    check("no weekly line after the reset", s.resetLine(for: A, now: weeklyAt.addingTimeInterval(1), timeZone: ist) == nil)
    func variant(_ edit: (inout [[String: Any]]) -> Void) -> Status {
        var root = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("status.json"))) as! [String: Any]
        var accounts = root["accounts"] as! [[String: Any]]
        edit(&accounts)
        root["accounts"] = accounts
        return try! JSONDecoder().decode(Status.self, from: JSONSerialization.data(withJSONObject: root))
    }
    let fiveHour = variant { $0[0]["limit"] = ["window": "5h", "hitAt": 1794100000.0, "resets": "x", "resetsAt": 1794136800] }
    check("5-hour reset line", fiveHour.resetLine(for: A, now: resetAt.addingTimeInterval(-3600), timeZone: ist) == "5-hour limit resets 4:50 PM")
    let noWindow = variant { $0[0]["limit"] = ["window": NSNull(), "hitAt": 1794100000.0, "resets": "x", "resetsAt": 1794136800] }
    check("unknown window: plain reset line", noWindow.resetLine(for: A, now: resetAt.addingTimeInterval(-3600), timeZone: ist) == "Limit resets 4:50 PM")
    let both = variant { $0[1]["limit"] = ["window": "week", "hitAt": 1794100000.0, "resets": "x", "resetsAt": 1794236400] }
    check("the later reset wins over a paused session", both.resetLine(for: B, now: resetAt.addingTimeInterval(-3600), timeZone: ist)
          == "Weekly limit resets Mon 8:30 PM")
    check("no line after both resets pass", both.resetLine(for: B, now: weeklyAt.addingTimeInterval(1), timeZone: ist) == nil)
    let now = Date(timeIntervalSince1970: 1794100000 + 2 * 86400)
    check("last limit text", s.currentAccount!.lastLimitText(now: now) == "Weekly · 2 days ago")
    check("last limit text for 5-hour", fiveHour.currentAccount!.lastLimitText(now: now) == "5-hour · 2 days ago")
    check("last limit text without a window", noWindow.currentAccount!.lastLimitText(now: now) == "Limit · 2 days ago")
    check("no limit shows a dash", s.account(B)!.lastLimitText(now: now) == "—")
    let unknown = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"resetsAt\": 1794136800", with: "\"resetsAt\": null").utf8))
    check("no reset line when the reset time is not known",
          unknown.resetLine(for: B, now: resetAt.addingTimeInterval(-3600), timeZone: ist) == nil)
    check("paused row: reset known", s.pausedSubtitle(s.paused[0], now: resetAt.addingTimeInterval(-3600), timeZone: ist)
          == "Limit resets 4:50 PM · jomon")
    check("paused row: reset passed", s.pausedSubtitle(s.paused[0], now: resetAt.addingTimeInterval(1), timeZone: ist)
          == "Limit reached · jomon")
    check("paused row: reset not known", unknown.pausedSubtitle(unknown.paused[0], now: resetAt, timeZone: ist)
          == "Limit reached · jomon")

    print("Account order")
    let C = "cccc3333-0000-0000-0000-000000000000"
    func ordered(order: [String], pinned: [String] = []) -> Status {
        let json = try! String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"order\": []", with: "\"order\": [\(order.map { "\"\($0)\"" }.joined(separator: ","))]")
            .replacingOccurrences(of: "\"pinned\": []", with: "\"pinned\": [\(pinned.map { "\"\($0)\"" }.joined(separator: ","))]")
        return try! JSONDecoder().decode(Status.self, from: Data(json.utf8))
    }
    check("no saved order: engine order", s.panelOrder(showHidden: false).map(\.id) == [A, B])
    check("saved order is used", ordered(order: [B, A]).panelOrder(showHidden: false).map(\.id) == [B, A])
    check("new account goes to the end", ordered(order: [C, B]).panelOrder(showHidden: true).map(\.id) == [C, B, A])
    check("unknown id in the order is ignored",
          ordered(order: ["dddd4444-0000-0000-0000-000000000000", B]).panelOrder(showHidden: false).map(\.id) == [B, A])
    check("pinned account comes first", ordered(order: [], pinned: [B]).panelOrder(showHidden: false).map(\.id) == [B, A])
    check("pinned first, then saved order, then new",
          ordered(order: [A, C], pinned: [B]).panelOrder(showHidden: true).map(\.id) == [B, A, C])
    check("pinned accounts keep the saved order among them",
          ordered(order: [A, B, C], pinned: [C, B]).panelOrder(showHidden: true).map(\.id) == [B, C, A])
    check("hidden pinned account stays hidden", ordered(order: [], pinned: [C]).panelOrder(showHidden: false).map(\.id) == [A, B])
    check("drag down: order after move", s.orderAfterMove([A], to: 2) == [B, A, C])
    check("drag up: order after move", s.orderAfterMove([C], to: 0) == [C, A, B])
    check("drag to the same place keeps the order", s.orderAfterMove([B], to: 1) == [A, B, C])
    check("drag of an unknown id changes nothing", s.orderAfterMove(["dddd4444"], to: 0) == [A, B, C])
    check("isPinned", ordered(order: [], pinned: [B]).isPinned(B) && !s.isPinned(B))

    print("Next account")
    check("next account: the next one after the current one in panel order",
          s.nextAccount(showHidden: false)?.id == B)
    // Panel order C, B, A; A is current, C is not mine and has no saved login.
    check("next account: skips an account that is not mine or has no saved login",
          ordered(order: [C, B]).nextAccount(showHidden: true)?.id == B)
    // Three accounts that are mine with a saved login: A, B, D.
    let D = "dddd4444-0000-0000-0000-000000000000"
    func three(current: String?, order: [String] = [A, B, D], pinned: [String] = [], hidden: [String] = []) -> Status {
        func q(_ ids: [String]) -> String { "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        let accs = [A, B, D].map { id in
            "{\"id\": \"\(id)\", \"name\": \"\", \"sessions\": 1, \"lastUsed\": 0, \"savedLogin\": true, \"savedAt\": 0, "
            + "\"savedMode\": \"switch\", \"current\": \(id == current), \"hidden\": \(hidden.contains(id)), \"owned\": true}"
        }
        let json = "{\"current\": \"\(current ?? "")\", \"signedIn\": true, \"claudeRunning\": true, \"claudeVersion\": \"1\", "
            + "\"versionTested\": true, \"layoutProblems\": [], \"pendingRecovery\": false, \"paused\": [], "
            + "\"settings\": {\"syncOnSwitch\": false, \"syncConfirmed\": false, \"autoSaveLogins\": true, \"dailyBackup\": true, "
            + "\"backupKeep\": 7, \"showNameInMenuBar\": true, \"hidden\": \(q(hidden)), \"order\": \(q(order)), \"pinned\": \(q(pinned))}, "
            + "\"accounts\": [\(accs.joined(separator: ","))]}"
        return try! JSONDecoder().decode(Status.self, from: Data(json.utf8))
    }
    check("next account: from the middle", three(current: B).nextAccount(showHidden: false)?.id == D)
    check("next account: wraps from the last to the first", three(current: D).nextAccount(showHidden: false)?.id == A)
    check("next account: follows the saved order", three(current: A, order: [D, A, B]).nextAccount(showHidden: false)?.id == B)
    check("next account: pinned accounts come first and the order wraps",
          three(current: B, pinned: [D]).nextAccount(showHidden: false)?.id == D)
    check("next account: skips a hidden account", three(current: B, hidden: [D]).nextAccount(showHidden: false)?.id == A)
    check("next account: includes a hidden account when hidden accounts show",
          three(current: B, hidden: [D]).nextAccount(showHidden: true)?.id == D)
    check("next account: no current account starts at the first",
          three(current: nil).nextAccount(showHidden: false)?.id == A)
    check("next account: nil when no other account fits",
          three(current: A, hidden: [B, D]).nextAccount(showHidden: false) == nil)

    print("Sign in to save")
    check("button only on accounts without a saved login", s.accounts.filter(\.needsSignInToSave).map(\.id) == [C])
    let curNoLogin = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"savedLogin\": true, \"savedAt\": 1794124745.0", with: "\"savedLogin\": false, \"savedAt\": 1794124745.0").utf8))
    check("no button on the current account, even without a saved login",
          curNoLogin.accounts.filter(\.needsSignInToSave).map(\.id) == [C])
    check("sign-in result: still waiting", Status.signInResult(["ok": true, "saved": false, "waiting": true], title: "Test") == nil)
    check("sign-in result: engine busy (the tick) keeps waiting",
          Status.signInResult(["ok": true, "saved": false, "waiting": true, "busy": true], title: "Test") == nil)
    check("sign-in result: saved", Status.signInResult(["ok": true, "saved": true, "match": true], title: "Test")
          == .success("Login of Test is saved. You can now switch to it with one click."))
    if case .warning(let t)? = Status.signInResult(["ok": true, "saved": false, "match": false, "message": "Claude is signed in to another account."], title: "Test") {
        check("sign-in result: mismatch is a warning with the engine message", t.contains("another account"))
    } else { check("sign-in result: mismatch is a warning with the engine message", false) }

    print("Render mode")
    check("render modes are found", ["--render", "--render-settings", "--render-sync", "--render-welcome"]
          .allSatisfy { RenderMode.isOn(["/x/ClaudeAccounts", $0, "a.png"]) })
    check("a normal launch is not a render", !RenderMode.isOn(["/x/ClaudeAccounts"]))

    print("Debug report")
    check("report arguments carry the shortcut states",
          Status.reportArguments(appSettings: [("shortcutOpenPanel", true), ("shortcutNextAccount", false)])
          == ["report", "--app-setting", "shortcutOpenPanel=on", "--app-setting", "shortcutNextAccount=off"])
    check("report arguments carry live usage states, never limits or cookies",
          Status.reportArguments(appSettings: [], liveUsage: [B: CachedUsage(limits: [], readAt: 0, error: "http-403"),
                                                                 A: CachedUsage(limits: [LiveLimit(kind: "session", percent: 5, resetsAt: nil, label: nil)], readAt: 1, error: nil)])
          == ["report", "--live-usage", "\(A)=ok", "--live-usage", "\(B)=http-403"])

    print("Account")
    let b = s.account(B)!
    check("short title is first word", b.shortTitle == "jomon")
    check("initials", b.initials == "JE")
    check("color index is stable", b.colorIndex == s.account(B)!.colorIndex)
    check("login text for auto save", s.currentAccount!.loginText.hasSuffix("(auto)"))
    check("never used text", s.account("cccc3333-0000-0000-0000-000000000000")?.lastUsedText == "never used")
    check("panel last-used line starts with a capital", s.account("cccc3333-0000-0000-0000-000000000000")?.lastUsedLine == "Never used"
          && s.account(B)!.lastUsedLine.hasPrefix("Used "))

    print("Account details")
    let a = s.currentAccount!, c = s.account("cccc3333-0000-0000-0000-000000000000")!
    check("decodes details", b.details?.plan == "Team (5x)" && b.details?.orgName == "Example Co")
    check("missing details and switch time decode as nil", c.details == nil && c.switchedAt == nil)
    check("plan text", b.planText == "Team (5x)")
    check("null plan shows a dash", a.planText == "—" && c.planText == "—")
    check("null org shows a dash", a.orgText == "—")
    check("null display name shows a dash", a.displayNameText == "—")
    check("email text", a.emailText == "a@example.com" && c.emailText == "—")
    check("never switched shows a dash", b.switchedText == "—" && c.switchedText == "—")
    check("switch time is relative", a.switchedText.hasSuffix("ago"))
    check("panel details line skips an email that is the title", b.detailsLine == "Team (5x) · Example Co")
    check("panel details line shows only known fields", a.detailsLine == "a@example.com")
    check("no panel details line without details", c.detailsLine == nil)
    let labelled = variant { $0[1]["name"] = "Work" }
    let clock = Date(timeIntervalSince1970: 1794100000)
    check("a time slightly in the future reads as past, not \"in 0 seconds\"", !Account.relative(1794100000.4, now: clock).hasPrefix("in "))
    check("panel details line: plan and org first, email last", labelled.account(B)!.detailsLine == "Team (5x) · Example Co · jomon@example.com")
    check("settings subtitle has name, email and short ID", b.settingsSubtitle == "Jomon · bbbb2222")

    print("Live usage")
    let echo = await engine.run(["stdin"], input: "pw-123\n")
    check("stdin reaches the engine", echo.json["got"] as? String == "pw-123")
    check("stdin text is not in the arguments", (try? String(contentsOf: log, encoding: .utf8))?.contains("pw-123") == false)
    let cookiesOut = await engine.run(["usage-cookies"], input: "pw\n")
    let cookies = (try? JSONDecoder().decode(LiveCookiesResult.self, from: Data(cookiesOut.output.utf8)))?.accounts ?? [:]
    check("decodes the engine cookies", cookies[A]?.org == "org-a" && cookies["cccc3333-0000-0000-0000-000000000000"]?.error == "no-login")
    let req = LiveUsageClient.request(org: "org-a", cookie: "sessionKey=FAKE-A")!
    check("request: the usage URL of the org", req.url?.absoluteString == "https://claude.ai/api/organizations/org-a/usage")
    check("request: the account's cookie header, no cookie store", req.value(forHTTPHeaderField: "Cookie") == "sessionKey=FAKE-A" && !req.httpShouldHandleCookies)
    check("request: an org with odd characters stays in its path segment", LiveUsageClient.request(org: "a/../b?x", cookie: "c")?.url?.absoluteString == "https://claude.ai/api/organizations/a%2F%2E%2E%2Fb%3Fx/usage")
    let cfg = LiveUsageClient.ephemeralConfiguration
    check("the session stores no cookie and no cache", cfg.httpCookieStorage == nil && cfg.urlCache == nil && !cfg.httpShouldSetCookies)
    let body = Data(#"{"five_hour":{"utilization":99},"limits":[{"kind":"session","percent":42.4,"resets_at":"2026-11-08T11:20:00.054311+00:00"},{"kind":"weekly_all","percent":16,"resets_at":"2026-11-09T15:00:00+00:00"},{"kind":"weekly_scoped","percent":29,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}},{"kind":"new_kind","percent":3},{"kind":"bad"}]}"#.utf8)
    let parsed = LiveUsageClient.parse(body, status: 200)
    check("parse: limits, not the old top-level fields", parsed.ok && parsed.limit("session")?.percent == 42.4)
    check("parse: reset time with 6 digits of fraction", parsed.limit("session")?.resetsAt == 1794136800)
    check("parse: Fable label from the model scope", parsed.limit("weekly_scoped")?.label == "Fable" && parsed.limit("weekly_scoped")?.resetsAt == nil)
    check("parse: an unknown kind is kept, an entry without percent is dropped", parsed.limit("new_kind") != nil && parsed.limit("bad") == nil)
    check("parse: Cloudflare challenge is http-403", LiveUsageClient.parse(Data("<html>Just a moment</html>".utf8), status: 403).error == "http-403")
    check("parse: HTML with status 200 is not-json", LiveUsageClient.parse(Data("<html>".utf8), status: 200).error == "not-json")
    let sent = Locked<[String]>([])
    let usage = await LiveUsageClient.fetch(cookies) { r in
        sent.mutate { $0.append(r.value(forHTTPHeaderField: "Cookie") ?? "") }
        if r.url!.path.contains("org-b") { throw URLError(.timedOut) }
        return (body, HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    check("fetch: each account gets its own cookies", Set(sent.value) == ["sessionKey=FAKE-A; lastActiveOrg=org-a", "sessionKey=FAKE-B; lastActiveOrg=org-b"])
    check("fetch: an account without a login sends no request", usage["cccc3333-0000-0000-0000-000000000000"]?.error == "no-login")
    check("fetch: a network error is network", usage[B]?.error == "network" && usage[A]?.ok == true)
    check("live usage setting decoded", s.settings.liveUsageOn)
    let t0: Double = 1794133200  // 2026-11-08 3:50 PM in Asia/Calcutta; the session resets at 4:50 PM
    let ist2 = TimeZone(identifier: "Asia/Calcutta")!
    let cache = LiveUsageCache.merge([:], usage, now: t0)
    func state(_ st: Status, _ id: String, _ c: [String: CachedUsage], at: Double = t0) -> LiveRowState? {
        st.liveState(for: id, cache: c, now: Date(timeIntervalSince1970: at), timeZone: ist2)
    }
    check("panel bars: 5h, Week, then the scoped limit with its model name", state(s, A, cache) == .bars([
        UsageBar(label: "5h", percent: 42.4, resetText: "4:50 PM"), UsageBar(label: "Week", percent: 16, resetText: "Mon 8:30 PM"),
        UsageBar(label: "Fable", percent: 29, resetText: nil), UsageBar(label: "New Kind", percent: 3, resetText: nil)], lastRead: nil, reason: nil))
    let scoped = LiveUsageCache.merge([:], [A: LiveAccountUsage(ok: true, limits: [
        LiveLimit(kind: "weekly_scoped", percent: 5, resetsAt: nil, label: nil),
        LiveLimit(kind: "session", percent: 1, resetsAt: t0 - 60, label: nil)], error: nil)], now: t0)
    check("a scoped limit with no model name; a reset in the past is not shown", state(s, A, scoped) == .bars([
        UsageBar(label: "5h", percent: 1, resetText: nil), UsageBar(label: "Scoped", percent: 5, resetText: nil)], lastRead: nil, reason: nil))
    check("the reset shows on a high or critical bar only",
          UsageBar(label: "x", percent: 69, resetText: "4:50 PM").showsReset == false
          && UsageBar(label: "x", percent: 70, resetText: "4:50 PM").showsReset && UsageBar(label: "x", percent: 95, resetText: nil).showsReset == false)
    check("bar text is a whole percent", UsageBar(label: "5h", percent: 42.4, resetText: nil).text == "42%")
    check("bar fill stays in 0...1", UsageBar(label: "x", percent: 130, resetText: nil).fraction == 1 && UsageBar(label: "x", percent: -5, resetText: nil).fraction == 0)
    check("levels: normal below 70, high from 70, critical from 90",
          [69.4, 70, 89.9, 90, 100].map { UsageLevel(percent: $0) } == [.normal, .high, .high, .critical, .critical])
    check("a failed account with no earlier value is unavailable, with the reason in words",
          state(s, B, cache) == .unavailable("No connection to claude.ai."))
    check("reasons for each error type", ["http-403", "http-401", "no-login", "decrypt", "not-json", "http-500"].map(LiveAccountUsage.reason) == [
        "claude.ai refused the request (HTTP 403).",
        "The saved login has expired. Switch to this account to sign in again.",
        "This account has no saved login.",
        "The saved login could not be read.",
        "claude.ai sent an unexpected answer.",
        "claude.ai answered with an error (HTTP 500)."])
    check("an answer with no limit at all is unavailable",
          state(s, A, LiveUsageCache.merge([:], [A: LiveAccountUsage(ok: true, limits: [], error: nil)], now: t0))
          == .unavailable("claude.ai sent no usage for this account."))
    check("no state for an account that was not asked", state(s, "dddd", cache) == nil)

    print("Live usage cache and schedule")
    check("a good read stores the limits and the read time", cache[A]?.readAt == t0 && cache[A]?.error == nil && cache[A]?.limits.count == 4)
    let later = LiveUsageCache.merge(cache, [A: .failed("http-403")], now: t0 + 1500)
    check("a failure keeps the last value and its read time", later[A]?.limits == cache[A]?.limits && later[A]?.readAt == t0 && later[A]?.error == "http-403")
    check("an account no longer asked is dropped", later[B] == nil)
    check("the old value shows with its age and the reason", state(s, A, later, at: t0 + 1500) == .bars([
        UsageBar(label: "5h", percent: 42.4, resetText: "4:50 PM"), UsageBar(label: "Week", percent: 16, resetText: "Mon 8:30 PM"),
        UsageBar(label: "Fable", percent: 29, resetText: nil), UsageBar(label: "New Kind", percent: 3, resetText: nil)],
        lastRead: "Last read 25 min. ago", reason: "claude.ai refused the request (HTTP 403)."))
    let saved = String(decoding: try! JSONEncoder().encode(later), as: UTF8.self)
    check("the cache holds only kinds, percents, resets, read time and error type", !saved.contains("cookie") && !saved.contains("FAKE")
          && Set((try! JSONSerialization.jsonObject(with: Data(saved.utf8)) as! [String: [String: Any]])[A]!.keys) == ["limits", "readAt", "error"])
    check("the cache reads back", (try? JSONDecoder().decode([String: CachedUsage].self, from: Data(saved.utf8))) == later)
    check("schedule: the first read is always due", LiveSchedule.due(lastAttempt: nil, now: t0, panelOpened: false))
    check("schedule: opening the panel reads again after 2 minutes, not before",
          !LiveSchedule.due(lastAttempt: t0, now: t0 + 119, panelOpened: true) && LiveSchedule.due(lastAttempt: t0, now: t0 + 120, panelOpened: true))
    check("schedule: the timer reads every 10 minutes, not before",
          !LiveSchedule.due(lastAttempt: t0, now: t0 + 599, panelOpened: false) && LiveSchedule.due(lastAttempt: t0, now: t0 + 600, panelOpened: false))
    let offStatus = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"liveUsage\": true", with: "\"liveUsage\": false").utf8))
    check("no state when the setting is off", state(offStatus, A, cache) == nil)
    print("Usage warning (90% of the 5-hour limit)")
    let cID = "cccc3333-0000-0000-0000-000000000000"
    func cached(_ five: Double, _ week: Double = 10, reset: Double? = 1794136800, weekReset: Double? = nil, error: String? = nil) -> CachedUsage {
        CachedUsage(limits: [LiveLimit(kind: "session", percent: five, resetsAt: reset, label: nil),
                             LiveLimit(kind: "weekly_all", percent: week, resetsAt: weekReset, label: nil)], readAt: t0, error: error)
    }
    // A is the active "mine" account; B is "mine" with a saved login; C is not "mine".
    let mineAndOther = variant { $0[2]["savedLogin"] = true; $0[2]["hidden"] = false }
    func warn(_ st: Status, _ c: [String: CachedUsage], enabled: Bool = true, warned: Set<String> = []) -> UsageWarning? {
        st.usageWarning(cache: c, enabled: enabled, alreadyWarned: warned, now: Date(timeIntervalSince1970: t0), timeZone: ist2)
    }
    check("no warning at 89%", warn(mineAndOther, [A: cached(89), B: cached(5)]) == nil)
    let w90 = warn(mineAndOther, [A: cached(90), B: cached(5, 17)])
    check("a warning at 90%, naming the next account of the ranking and the reason", w90?.target == B
          && w90?.title == "5-hour limit at 90%"
          && w90?.body == "\(s.currentAccount!.title) is at 90% of its 5-hour limit. Next: \(s.account(B)!.title) · 83% left.")
    check("never names an account that is not mine, even with more free capacity",
          warn(mineAndOther, [A: cached(95), B: cached(40), cID: cached(0)])?.target == B)
    check("names the first account of the ranking: the soonest weekly reset, not the most free 5-hour capacity",
          warn(variant { $0[2]["owned"] = true; $0[2]["savedLogin"] = true; $0[2]["hidden"] = false },
               [A: cached(95), B: cached(5, 10, weekReset: t0 + 5 * 86400), cID: cached(60, 70, weekReset: t0 + 86400)])?.target == cID)
    let full = warn(mineAndOther, [A: cached(97), B: cached(100)])
    check("no free mine account: the warning says so and offers no switch", full != nil && full?.target == nil
          && full?.body == "\(s.currentAccount!.title) is at 97% of its 5-hour limit. No other account of yours has free capacity now.")
    check("an account at its weekly limit is not free", warn(mineAndOther, [A: cached(95), B: cached(5, 100)])?.target == nil)
    check("an account near (not at) its weekly limit is still offered", warn(mineAndOther, [A: cached(95), B: cached(5, 92)])?.target == B)
    check("an account with no usage value is not offered", warn(mineAndOther, [A: cached(95)])?.target == nil)
    check("no warning when the warning setting is off", warn(mineAndOther, [A: cached(95), B: cached(5)], enabled: false) == nil)
    check("no warning when live usage is off", warn(offStatus, [A: cached(95), B: cached(5)]) == nil)
    check("no warning from a stale value (the newest read failed)", warn(mineAndOther, [A: cached(95, error: "network"), B: cached(5)]) == nil)
    check("one warning per window: the same window does not warn again",
          warn(mineAndOther, [A: cached(96), B: cached(5)], warned: [w90!.key]) == nil)
    check("a new window warns again", warn(mineAndOther, [A: cached(96, reset: 1794154800), B: cached(5)], warned: [w90!.key]) != nil)
    check("switch targets without live usage: mine, saved, not current", offStatus.switchTargets().map(\.id) == [B])
    let bothMine = variant { $0[2]["owned"] = true; $0[2]["savedLogin"] = true; $0[2]["hidden"] = false }
    check("switch targets with live usage: the auto-switch ranking, best first",
          bothMine.switchTargets(cache: [B: cached(5, 10, weekReset: t0 + 5 * 86400), cID: cached(60, 70, weekReset: t0 + 86400)],
                                 now: Date(timeIntervalSince1970: t0)).map(\.id) == [cID, B])
    func nextLine(_ st: Status, _ c: [String: CachedUsage]) -> String? {
        st.nextLine(cache: c, now: Date(timeIntervalSince1970: t0), timeZone: ist2)
    }
    check("panel: the next account and the reason", nextLine(bothMine, [B: cached(5, 60, weekReset: t0 + 4 * 86400)])
          == "Next: \(bothMine.account(B)!.shortTitle) · resets Thu, 40% left")
    check("panel: says when no account is free", nextLine(bothMine, [B: cached(5, 100)]) == "Next: none · no other account has quota left")
    check("panel: no next line when live usage is off", nextLine(offStatus, [B: cached(5, 60)]) == nil)
    check("switch targets with live usage: an account at its limit is not offered",
          bothMine.switchTargets(cache: [B: cached(5, 100), cID: cached(60, 70)], now: Date(timeIntervalSince1970: t0)).map(\.id) == [cID])

    let demo = try? JSONDecoder().decode([String: LiveAccountUsage].self, from: Data(#"{"a":{"ok":true,"error":null,"limits":[{"kind":"session","percent":12,"resetsAt":null,"label":null}]}}"#.utf8))
    check("live usage decodes (demo renders)", demo?["a"]?.limit("session")?.percent == 12)
    let oldSettings = try! JSONDecoder().decode(EngineSettings.self, from: Data(#"{"syncOnSwitch":false,"syncConfirmed":false,"autoSaveLogins":true,"dailyBackup":true,"backupKeep":7,"showNameInMenuBar":true,"hidden":[],"order":[],"pinned":[]}"#.utf8))
    check("older status without the setting means off", oldSettings.liveUsageOn == false)

    print("Auto-switch ranking")
    let rankTZ = TimeZone(identifier: "Asia/Calcutta")!
    let day: Double = 86400
    /// An account as the engine reports it. Defaults: mine, saved login, not current.
    func acct(_ id: String, name: String = "", owned: Bool = true, savedLogin: Bool = true, current: Bool = false) -> Account {
        try! JSONDecoder().decode(Account.self, from: Data(("{\"id\": \"\(id)\", \"name\": \"\(name)\", \"sessions\": 1, \"lastUsed\": 0, "
            + "\"savedLogin\": \(savedLogin), \"savedAt\": 0, \"savedMode\": \"switch\", \"current\": \(current), "
            + "\"hidden\": false, \"owned\": \(owned)}").utf8))
    }
    /// A good live read: 5-hour and weekly percent, and the weekly reset.
    func weekly(five: Double = 10, week: Double, weekResets: Double?, error: String? = nil, extra: [LiveLimit] = []) -> CachedUsage {
        CachedUsage(limits: [LiveLimit(kind: "session", percent: five, resetsAt: t0 + 3600, label: nil),
                             LiveLimit(kind: "weekly_all", percent: week, resetsAt: weekResets, label: nil)] + extra,
                    readAt: t0, error: error)
    }
    func rank(_ accounts: [Account], _ u: [String: CachedUsage]) -> AutoSwitchDecision {
        AutoSwitch.decide(AutoSwitchInput(accounts: accounts, usage: u, now: t0, timeZone: rankTZ))
    }
    let P = "pppp0000-0000-0000-0000-000000000000", Q = "qqqq0000-0000-0000-0000-000000000000"
    let R = "rrrr0000-0000-0000-0000-000000000000"
    check("ranking: the soonest weekly reset comes first",
          rank([acct(P), acct(Q)], [P: weekly(week: 20, weekResets: t0 + 5 * day), Q: weekly(week: 60, weekResets: t0 + 2 * day)])
            .ranking.map(\.id) == [Q, P])
    check("ranking: on the same weekly reset, more weekly quota left comes first",
          rank([acct(P), acct(Q), acct(R)], [P: weekly(week: 70, weekResets: t0 + 2 * day), Q: weekly(week: 30, weekResets: t0 + 2 * day),
                                            R: weekly(week: 50, weekResets: t0 + 2 * day)]).ranking.map(\.id) == [Q, R, P])
    // P would be first on every rule; each case breaks one condition of an allowed account.
    let good = weekly(week: 20, weekResets: t0 + 1 * day), laterReset = weekly(week: 20, weekResets: t0 + 6 * day)
    func picked(_ p: Account, _ pUsage: CachedUsage?) -> [String] {
        rank([p, acct(Q)], [Q: laterReset].merging(pUsage.map { [P: $0] } ?? [:]) { a, _ in a }).ranking.map(\.id)
    }
    check("allowed: never an account at 100% of its weekly limit", picked(acct(P), weekly(week: 100, weekResets: t0 + day)) == [Q])
    check("allowed: never an account at 100% of its 5-hour limit", picked(acct(P), weekly(five: 100, week: 20, weekResets: t0 + day)) == [Q])
    check("allowed: never an account that is not mine", picked(acct(P, owned: false), good) == [Q])
    check("allowed: never an account without a saved login", picked(acct(P, savedLogin: false), good) == [Q])
    check("allowed: never an account whose last read failed", picked(acct(P), weekly(week: 20, weekResets: t0 + day, error: "network")) == [Q])
    check("allowed: never an account with no read", picked(acct(P), nil) == [Q])
    check("allowed: never the current account", picked(acct(P, current: true), good) == [Q])
    // t0 is Sunday 3:50 PM in Asia/Calcutta.
    func reason(_ u: CachedUsage) -> String? { rank([acct(P)], [P: u]).next?.reason }
    check("reason: the weekday of the weekly reset and the weekly quota left",
          reason(weekly(week: 60, weekResets: t0 + 4 * day)) == "resets Thu, 40% left")
    check("reason: a weekly reset later today", reason(weekly(week: 12.4, weekResets: t0 + 3600)) == "resets today, 88% left")
    check("reason: no weekly reset known", reason(weekly(week: 60, weekResets: nil)) == "40% left")
    // Property test: 500 random cases from a fixed seed, so a failure repeats.
    var rng = SplitMix64(seed: 61)
    var badPick = 0, unstable = 0, orderDependent = 0, misordered = 0
    for _ in 0..<500 {
        let n = Int.random(in: 1...6, using: &rng)
        let accounts = (0..<n).map { i in
            acct("acct\(i)-0000", owned: Double.random(in: 0..<1, using: &rng) < 0.8, savedLogin: Double.random(in: 0..<1, using: &rng) < 0.8,
                 current: i == 0 && Bool.random(using: &rng))
        }
        func pct() -> Double { [0, 50, 99.6, 100, 104][Int.random(in: 0..<5, using: &rng)] + Double(Int.random(in: 0...40, using: &rng)) * (Bool.random(using: &rng) ? 0 : 1) }
        var u: [String: CachedUsage] = [:]
        for a in accounts where Double.random(in: 0..<1, using: &rng) < 0.85 {
            u[a.id] = weekly(five: pct(), week: pct(),
                             weekResets: Bool.random(using: &rng) ? t0 + Double(Int.random(in: 0...3, using: &rng)) * day : nil,
                             error: Double.random(in: 0..<1, using: &rng) < 0.15 ? "network" : nil,
                             extra: Bool.random(using: &rng) ? [LiveLimit(kind: "weekly_scoped", percent: pct(), resetsAt: nil, label: "Fable")] : [])
        }
        let d = rank(accounts, u)
        for r in d.ranking {
            let a = accounts.first { $0.id == r.id }, c = u[r.id]
            let five = c?.limits.first { $0.kind == "session" }?.percent ?? 100, week = c?.limits.first { $0.kind == "weekly_all" }?.percent ?? 100
            if !(a?.owned == true && a?.savedLogin == true && a?.current == false && c?.error == nil && five < 100 && week < 100) { badPick += 1 }
        }
        if rank(accounts, u) != d { unstable += 1 }
        if rank(accounts.shuffled(using: &rng), u) != d { orderDependent += 1 }
        for (x, y) in zip(d.ranking, d.ranking.dropFirst())
        where (x.weeklyResetsAt ?? .infinity, x.weeklyPercent) > (y.weeklyResetsAt ?? .infinity, y.weeklyPercent) { misordered += 1 }
    }
    check("property (500 cases): every ranked account is allowed", badPick == 0)
    check("property (500 cases): the same inputs give the same output", unstable == 0)
    check("property (500 cases): the order of the accounts does not change the output", orderDependent == 0)
    check("property (500 cases): soonest weekly reset first, then more quota left", misordered == 0)
    check("allowed: a model limit at 100% is ignored", picked(acct(P), weekly(week: 20, weekResets: t0 + day,
          extra: [LiveLimit(kind: "weekly_scoped", percent: 100, resetsAt: t0 + 0.5 * day, label: "Fable")])) == [P, Q])

    print("Usage history")
    let goodRead = LiveAccountUsage(ok: true, limits: [LiveLimit(kind: "session", percent: 42, resetsAt: nil, label: nil),
                                                       LiveLimit(kind: "weekly_all", percent: 16, resetsAt: nil, label: nil),
                                                       LiveLimit(kind: "weekly_scoped", percent: 90, resetsAt: nil, label: "Fable")], error: nil)
    let h1 = UsageHistory.record([], reads: [P: goodRead, Q: .failed("network")], now: t0)
    check("history: a good read stores one reading (time, account, 5-hour and weekly percent)",
          h1 == [UsageReading(at: t0, account: P, fivePercent: 42, weeklyPercent: 16)])
    check("history: a failed read stores nothing", !h1.contains { $0.account == Q })
    let h2 = UsageHistory.record(h1, reads: [P: goodRead, Q: goodRead], now: t0 + 600)
    check("history: every account with a good read gets a reading", h2.count == 3 && h2.filter { $0.at == t0 + 600 }.map(\.account).sorted() == [P, Q])
    let noFive = LiveAccountUsage(ok: true, limits: [LiveLimit(kind: "weekly_all", percent: 16, resetsAt: nil, label: nil)], error: nil)
    check("history: no 5-hour limit in the read (no session started) is 0%",
          UsageHistory.record([], reads: [P: noFive], now: t0).first?.fivePercent == 0)
    check("history: a read without a weekly limit stores nothing",
          UsageHistory.record([], reads: [P: LiveAccountUsage(ok: true, limits: [], error: nil)], now: t0).isEmpty)
    let old = [UsageReading(at: t0 - 35 * day - 1, account: P, fivePercent: 1, weeklyPercent: 1),
               UsageReading(at: t0 - 35 * day, account: P, fivePercent: 2, weeklyPercent: 2)]
    check("history: readings older than 35 days are removed, 35 days are kept",
          UsageHistory.record(old, reads: [:], now: t0).map(\.fivePercent) == [2])
    let stored = UsageHistory.encode(h2)
    check("history: the stored form reads back", UsageHistory.decode(stored) == h2)
    check("history: the stored form groups by account (small enough for the app's preferences)",
          (try? JSONSerialization.jsonObject(with: stored) as? [String: [[Double]]])?[P]?.count == 2)
    check("history: an unreadable stored form is an empty history", UsageHistory.decode(Data("x".utf8)).isEmpty)

    print("Promotion (star request, what's new)")
    check("no star request before 10 successful switches", !Promotion.shouldAskForStar(successfulSwitches: 9, answered: false))
    check("a star request from the 10th successful switch", Promotion.shouldAskForStar(successfulSwitches: 10, answered: false)
          && Promotion.shouldAskForStar(successfulSwitches: 25, answered: false))
    check("an answered star request never shows again", !Promotion.shouldAskForStar(successfulSwitches: 50, answered: true))
    check("star request text", Promotion.starRequestText(successfulSwitches: 12)
          == "Claude Accounts saved you 12 sign-outs. A star on GitHub helps other people find it.")
    check("what's new after an update to a release", Promotion.whatsNew(current: "1.3.0", lastSeen: "1.2.0") == "1.3.0")
    check("no what's new on the first install", Promotion.whatsNew(current: "1.3.0", lastSeen: nil) == nil)
    check("no what's new when the version did not change", Promotion.whatsNew(current: "1.3.0", lastSeen: "1.3.0") == nil)
    check("no what's new for a development build", Promotion.whatsNew(current: "1.2.0-8-g68e5dc3", lastSeen: "1.2.0") == nil)
    check("only release versions are remembered", Promotion.isRelease("1.3.0") && !Promotion.isRelease("1.2.0-8-g68e5dc3") && !Promotion.isRelease("ci-abc1234"))
    check("the repo and release links", Promotion.repoURL.absoluteString == "https://github.com/jomonkj/claude-accounts"
          && Promotion.releaseURL(version: "1.3.0").absoluteString == "https://github.com/jomonkj/claude-accounts/releases/tag/v1.3.0")

    try? FileManager.default.removeItem(at: log)
    print("\n\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

await main()
