// Tests for ClaudeAccountsCore. Run: swift run CoreTests
// (XCTest and swift-testing need Xcode, so this is a plain program that exits 1 on failure.)
import Foundation
import ClaudeAccountsCore

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0
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

    check("owned accounts", s.ownedAccounts.map(\.id) == [A, B])
    let preview = try! JSONDecoder().decode(SyncResult.self, from: Data(
        #"{"changes": 20, "accounts": {"\#(A)": 4, "\#(B)": 16, "zzzz9999": 0}, "skipped": [], "dryRun": true}"#.utf8))
    check("sync preview: biggest first, names, no zero lines",
          s.syncPreview(preview) == ["jomon@example.com (Team): 16 sessions", "Account aaaa1111: 4 sessions"])
    let backups = try! JSONDecoder().decode([BackupInfo].self, from: Data(
        #"[{"name": "2026-11-08", "sessions": 10, "modified": 1}, {"name": "pre-restore-20261108-1200", "sessions": 9, "modified": 2}]"#.utf8))
    check("undo backup is marked", backups.map(\.isUndo) == [false, true])

    check("paused to notify: new one", s.pausedToNotify(alreadyNotified: []).map(\.id) == ["local_p1"])
    check("paused to notify: already notified", s.pausedToNotify(alreadyNotified: ["local_p1"]).isEmpty)
    check("switch targets: mine, saved, not current", s.switchTargets().map(\.id) == [B])
    let note = s.notificationText(for: s.paused[0])
    check("notification text", note.title == "Usage limit reached"
          && note.body == "\"AWS capacity\" stopped on jomon@example.com (Team). Resets 4:50pm (Asia/Calcutta).")

    print("Reset time")
    let ist = TimeZone(identifier: "Asia/Calcutta")!
    let resetAt = Date(timeIntervalSince1970: 1794136800)  // 2026-11-08 4:50 PM in Asia/Calcutta
    check("reset time decoded", s.paused[0].resetsAt == 1794136800)
    check("reset line before the reset",
          s.resetLine(for: B, now: resetAt.addingTimeInterval(-3600), timeZone: ist) == "Limit resets 4:50 PM")
    check("reset line names the day when it is not today",
          s.resetLine(for: B, now: resetAt.addingTimeInterval(-86400), timeZone: ist) == "Limit resets Sun 4:50 PM")
    check("no reset line after the reset", s.resetLine(for: B, now: resetAt.addingTimeInterval(1), timeZone: ist) == nil)
    check("no reset line for an account without a limit",
          s.resetLine(for: A, now: resetAt.addingTimeInterval(-3600), timeZone: ist) == nil)
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

    print("Sign in to save")
    check("button only on accounts without a saved login", s.accounts.filter(\.needsSignInToSave).map(\.id) == [C])
    let curNoLogin = try! JSONDecoder().decode(Status.self, from: Data(
        String(contentsOf: fixtures.appendingPathComponent("status.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"savedLogin\": true, \"savedAt\": 1794124745.0", with: "\"savedLogin\": false, \"savedAt\": 1794124745.0").utf8))
    check("no button on the current account, even without a saved login",
          curNoLogin.accounts.filter(\.needsSignInToSave).map(\.id) == [C])
    check("sign-in result: still waiting", Status.signInResult(["ok": true, "saved": false, "waiting": true], title: "Test") == nil)
    check("sign-in result: saved", Status.signInResult(["ok": true, "saved": true, "match": true], title: "Test")
          == .success("Login of Test is saved. You can now switch to it with one click."))
    if case .warning(let t)? = Status.signInResult(["ok": true, "saved": false, "match": false, "message": "Claude is signed in to a different account."], title: "Test") {
        check("sign-in result: mismatch is a warning with the engine message", t.contains("different account"))
    } else { check("sign-in result: mismatch is a warning with the engine message", false) }

    print("Account")
    let b = s.account(B)!
    check("short title is first word", b.shortTitle == "jomon")
    check("initials", b.initials == "JE")
    check("color index is stable", b.colorIndex == s.account(B)!.colorIndex)
    check("login text for auto save", s.currentAccount!.loginText.hasSuffix("(auto)"))
    check("never used text", s.account("cccc3333-0000-0000-0000-000000000000")?.lastUsedText == "never used")

    try? FileManager.default.removeItem(at: log)
    print("\n\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

await main()
