#!/usr/bin/python3 -I
"""Property test for `claude-switch sync`.

Builds random session stores (3-5 accounts, some "mine", some with 2 org folders or none,
random sessions, random modification times, random deleted markers), runs sync through the
engine CLI, and checks the rules that must always hold:

  1. no file is lost: every session file that existed before still exists
  2. newest wins: each "mine" account has the newest content of every session it holds
     or received
  3. not-mine accounts are byte-for-byte unchanged, and their sessions are not copied out
  4. deleted stays deleted: a session deleted in any "mine" account is not added to a
     "mine" account that did not have it
  5. idempotent: a second sync reports 0 changes and changes no file
  6-9. random remove, sync and sign-in steps afterwards (see random_steps)

Usage: tests/sync_property_test.py [cases] [seed]
"""
import hashlib, json, os, random, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(ROOT, "engine", "claude-switch")
CASES = int(sys.argv[1]) if len(sys.argv) > 1 else 500
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 20261108


def snapshot(sess):
    out = {}
    for dp, _, fs in os.walk(sess):
        for f in fs:
            p = os.path.join(dp, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, sess)] = (hashlib.sha1(fh.read()).hexdigest(), int(os.path.getmtime(p)))
    return out


def run(env, *args) -> dict:
    r = subprocess.run([ENGINE, *args], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(f"engine {' '.join(args)} failed: {r.stderr.strip()}")
    return json.loads(r.stdout)


def one_case(rng, case):
    tmp = tempfile.mkdtemp(prefix="syncprop-")
    try:
        app, sess = os.path.join(tmp, "app"), os.path.join(tmp, "app", "claude-code-sessions")
        os.makedirs(sess)
        env = {"PATH": "/usr/bin:/bin", "HOME": os.path.join(tmp, "home"), "CLAUDE_APP_DIR": app,
               "CLAUDE_SWITCH_HOME": os.path.join(tmp, "sw"), "CLAUDE_SWITCH_BACKUPS": os.path.join(tmp, "bk"),
               "CLAUDE_SWITCH_TEST": "1", "CLAUDE_INFO_PLIST": os.path.join(tmp, "none.plist")}
        with open(os.path.join(app, "config.json"), "w") as f:
            json.dump({}, f)
        pool = [f"local_{i:08x}-0000-0000-0000-000000000000.json" for i in range(rng.randint(2, 8))]
        accounts = [f"{chr(65 + i) * 8}-{case:04d}-0000-0000-000000000000" for i in range(rng.randint(3, 5))]
        mine = [a for a in accounts if rng.random() < 0.7] or [accounts[0]]
        base = 1_700_000_000
        for a in accounts:
            n_orgs = rng.choice([0, 1, 1, 1, 2])
            orgs = [os.path.join(sess, a, f"org{k}") for k in range(n_orgs)]
            for o in orgs:
                os.makedirs(o)
            for name in pool:
                if orgs and rng.random() < 0.55:
                    o = rng.choice(orgs)
                    p = os.path.join(o, name)
                    with open(p, "w") as f:
                        f.write(json.dumps({"id": name, "v": rng.random()}))
                    t = base + rng.randrange(0, 10_000) * 2  # even seconds: no ties within 1 s
                    os.utime(p, (t, t))
                if orgs and rng.random() < 0.12:
                    sid = name[len("local_"):-len(".json")]
                    with open(os.path.join(rng.choice(orgs), f"deleted_{sid}"), "w") as f:
                        f.write("deleted")
        # "mine" may include an account with no session folder, which `mine` cannot name,
        # so write the list into the engine's settings file.
        os.makedirs(env["CLAUDE_SWITCH_HOME"], exist_ok=True)
        with open(os.path.join(env["CLAUDE_SWITCH_HOME"], "settings.json"), "w") as f:
            json.dump({"owned": mine}, f)

        before = snapshot(sess)
        out = run(env, "sync")
        after = snapshot(sess)

        def acc_of(rel): return rel.split(os.sep)[0]
        def name_of(rel): return os.path.basename(rel)
        mine_set = set(mine)
        # newest content per session among "mine" accounts, before sync
        newest = {}
        for rel, (h, t) in before.items():
            if acc_of(rel) in mine_set and name_of(rel).startswith("local_"):
                if name_of(rel) not in newest or t > newest[name_of(rel)][1]:
                    newest[name_of(rel)] = (h, t)
        deleted = {name_of(r)[len("deleted_"):] for r in before if acc_of(r) in mine_set and name_of(r).startswith("deleted_")}

        errors = []
        # 1. nothing lost
        for rel in before:
            if rel not in after:
                errors.append(f"lost {rel}")
        # 3. not-mine unchanged
        for rel, v in before.items():
            if acc_of(rel) not in mine_set and after.get(rel) != v:
                errors.append(f"not-mine file changed: {rel}")
        for rel in after:
            if acc_of(rel) not in mine_set and rel not in before:
                errors.append(f"file added to not-mine account: {rel}")
        not_mine_only = {name_of(r) for r in before if acc_of(r) not in mine_set and name_of(r).startswith("local_")} - set(newest)
        for rel in after:
            if acc_of(rel) in mine_set and name_of(rel).startswith("local_") and name_of(rel) in not_mine_only:
                errors.append(f"not-mine session copied out: {rel}")
        # 2. newest wins, 4. deleted stays deleted
        for rel, (h, t) in after.items():
            n = name_of(rel)
            if acc_of(rel) in mine_set and n.startswith("local_") and n in newest and h != newest[n][0]:
                errors.append(f"not newest: {rel}")
            if acc_of(rel) in mine_set and rel not in before and n.startswith("local_") \
                    and n[len("local_"):-len(".json")] in deleted:
                errors.append(f"deleted session came back: {rel}")
        # every "mine" account with a folder holds every non-deleted session
        for a in mine_set:
            if not os.path.isdir(os.path.join(sess, a)):
                continue
            held = {name_of(r) for r in after if acc_of(r) == a}
            for n in newest:
                if n not in held and n[len("local_"):-len(".json")] not in deleted:
                    errors.append(f"{a[:8]} is missing {n}")
        # reported count equals the files that changed
        changed = sum(1 for r in after if r not in before or after[r] != before[r])
        if out["changes"] != changed:
            errors.append(f"reported {out['changes']} changes, files changed: {changed}")
        # 5. idempotent
        again = run(env, "sync")
        if again["changes"] != 0 or snapshot(sess) != after:
            errors.append(f"second sync changed {again['changes']} files")
        if not errors:
            errors += random_steps(rng, env, sess, accounts)
        return errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def random_steps(rng, env, sess, accounts):
    """Random remove, sync and sign-in steps after the first sync. Rules:

      6. remove moves only the removed account's files, all of them, into the backups
      7. a removed account is not mine, and sync never brings its folder back
      8. no step except remove makes any file disappear
      9. signing in to a removed account again brings it back as a new, not-mine account
    """
    errors, removed, back, current, new = [], set(), set(), "", 0
    cfg = os.path.join(env["CLAUDE_APP_DIR"], "config.json")
    steps = rng.randint(2, 4)
    for i in range(steps + 1):
        # One status per step checks the state left by the step before (rules 7 and 9).
        st = {a["id"]: a for a in run(env, "status")["accounts"]}
        still_mine = sorted(a for a in removed if a in st and st[a]["owned"])
        if still_mine:
            errors.append(f"removed accounts still mine: {still_mine}")
        for a in back:
            if a not in st or st[a]["owned"] or st[a]["savedLogin"]:
                errors.append(f"signed-in removed {a[:8]} is not back as a new account")
        back.clear()
        if errors or i == steps:
            break
        before = snapshot(sess)
        kind = rng.choice(["remove", "remove", "sync", "sign-in"])
        acc = rng.choice(accounts)
        if kind == "remove":
            if acc == current or acc not in st:  # an account with no folder is unknown
                continue
            had = os.path.isdir(os.path.join(sess, acc))
            out = run(env, "remove", acc)
            removed.add(acc)
            after = snapshot(sess)
            mine = {k: v for k, v in before.items() if k.split(os.sep)[0] == acc}
            gone = {k: v for k, v in before.items() if k not in after}
            if gone != mine:
                errors.append(f"remove {acc[:8]} took other files: {sorted(set(gone) - set(mine))[:3]}")
            if {k for k in after if k not in before}:
                errors.append(f"remove {acc[:8]} added files")
            if had:
                saved = snapshot(os.path.join(env["CLAUDE_SWITCH_BACKUPS"], out["backup"]))
                if {k: v[0] for k, v in saved.items()} != {k: v[0] for k, v in mine.items()}:
                    errors.append(f"backup of removed {acc[:8]} is not complete")
        elif kind == "sync":
            if not [a for a in st.values() if a["owned"]]:
                continue
            run(env, "sync")
            after = snapshot(sess)
            lost = [k for k in before if k not in after]
            if lost:
                errors.append(f"sync lost {lost[:3]}")
            for a in removed:
                if os.path.exists(os.path.join(sess, a)):
                    errors.append(f"sync brought back removed {a[:8]}")
        else:  # Claude signs in to acc and writes one new session
            current = acc
            with open(cfg, "w") as f:
                json.dump({"lastKnownAccountUuid": acc}, f)
            org = os.path.join(sess, acc, "org-new")
            os.makedirs(org, exist_ok=True)
            new += 1
            with open(os.path.join(org, f"local_new{new}.json"), "w") as f:
                f.write(json.dumps({"id": new}))
            if [k for k in before if k not in snapshot(sess)]:
                errors.append("sign-in lost files")
            if acc in removed:
                removed.discard(acc)
                back.add(acc)
    return errors


def main():
    rng = random.Random(SEED)
    failed = 0
    for case in range(CASES):
        errs = one_case(rng, case)
        if errs:
            failed += 1
            print(f"  FAIL case {case}: " + "; ".join(errs[:4]))
            if failed >= 5:
                break
    print(f"{CASES - failed if failed < 5 else '?'} passed, {failed} failed (seed {SEED})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
