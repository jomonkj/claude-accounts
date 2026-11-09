#!/usr/bin/env bash
# Tests for engine/claude-switch. Runs in a fake app folder; never touches the real Claude app.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/claude-switch"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_APP_DIR="$T/app" CLAUDE_SWITCH_HOME="$T/home" CLAUDE_SWITCH_BACKUPS="$T/backups" CLAUDE_SWITCH_TEST=1 HOME="$T/userhome" CLAUDE_INFO_PLIST="$T/Info.plist"
plist() { /usr/bin/python3 -c "import plistlib;plistlib.dump({'CFBundleShortVersionString':'$1'},open('$T/Info.plist','wb'))"; }
plist 4.23118.0
A="$T/app"; mkdir -p "$A/claude-code-sessions/AAAAAAAA-1/org1" "$A/claude-code-sessions/BBBBBBBB-2/org2" "$HOME"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }
cfg() { /usr/bin/python3 -c "import json;print(json.load(open('$A/config.json')).get('$1',''))"; }
cookie() { sqlite3 "$A/Cookies" "select value from cookies" 2>/dev/null; }
login_as() { # <account> <cookie value>
  rm -f "$A/Cookies"; sqlite3 "$A/Cookies" "create table cookies(host_key,name,value); insert into cookies values('.claude.ai','sessionKey','$2');"
  rm -rf "$A/Local Storage"; mkdir -p "$A/Local Storage"; echo "ls-$1" > "$A/Local Storage/data"
  echo "{\"locale\":\"en\",\"lastKnownAccountUuid\":\"$1\",\"oauth:tokenCacheV2\":\"tok-$1\"}" > "$A/config.json"
}
E() { "$ENGINE" "$@" 2>"$T/err"; }

echo '{"sessionId":"local_a1"}' > "$A/claude-code-sessions/AAAAAAAA-1/org1/local_a1.json"
echo '{"sessionId":"local_b1"}' > "$A/claude-code-sessions/BBBBBBBB-2/org2/local_b1.json"
login_as AAAAAAAA-1 cookieA

echo "add"
E add >/dev/null
check "login of A saved" '[ -f "$CLAUDE_SWITCH_HOME/profiles/AAAAAAAA-1/config-keys.json" ]'
check "app is signed out" '[ ! -e "$A/Cookies" ] && [ -z "$(cfg oauth:tokenCacheV2)" ]'
check "other config kept" '[ "$(cfg locale)" = en ]'

echo "sign in as B, switch to A (short id)"
login_as BBBBBBBB-2 cookieB
E switch AAAAAAAA >/dev/null
check "A cookie loaded" '[ "$(cookie)" = cookieA ]'
check "A token loaded" '[ "$(cfg oauth:tokenCacheV2)" = tok-AAAAAAAA-1 ]'
check "A local storage loaded" '[ "$(cat "$A/Local Storage/data")" = ls-AAAAAAAA-1 ]'
check "B login saved" '[ -f "$CLAUDE_SWITCH_HOME/profiles/BBBBBBBB-2/meta.json" ]'

echo "sync on, switch to B"
check "sync without mine accounts fails" '! E sync --dry-run >/dev/null && grep -q "mine" "$T/err"'
E mine AAAAAAAA >/dev/null; E mine BBBBBBBB >/dev/null
E set syncOnSwitch on >/dev/null; E set syncConfirmed true >/dev/null
E switch BBBBBBBB-2 >/dev/null
check "B cookie loaded" '[ "$(cookie)" = cookieB ]'
check "A session shared into B" '[ -f "$A/claude-code-sessions/BBBBBBBB-2/org2/local_a1.json" ]'

echo "newer session wins on sync"
sleep 1.1; echo '{"sessionId":"local_a1","title":"new"}' > "$A/claude-code-sessions/AAAAAAAA-1/org1/local_a1.json"
count() { E sync --dry-run | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['changes'])"; }
check "dry run counts 1" '[ "$(count)" = 1 ]'
E sync >/dev/null
check "newer copy landed" 'grep -q new "$A/claude-code-sessions/BBBBBBBB-2/org2/local_a1.json"'
check "sync made a backup" '[ -n "$(ls "$CLAUDE_SWITCH_BACKUPS")" ]'
check "dry run now 0" '[ "$(count)" = 0 ]'
check "B session synced back into A" '[ -f "$A/claude-code-sessions/AAAAAAAA-1/org1/local_b1.json" ]'

echo "not-mine account is never touched"
mkdir -p "$A/claude-code-sessions/CCCCCCCC-3/org3"; echo '{"x":1}' > "$A/claude-code-sessions/CCCCCCCC-3/org3/local_c1.json"
E sync >/dev/null
check "not-mine account got nothing" '[ "$(ls "$A/claude-code-sessions/CCCCCCCC-3/org3")" = local_c1.json ]'
check "not-mine session not copied out" '[ ! -e "$A/claude-code-sessions/AAAAAAAA-1/org1/local_c1.json" ]'

echo "backups and restore"
echo '{"sessionId":"local_new"}' > "$A/claude-code-sessions/AAAAAAAA-1/org1/local_new.json"
b="$(E backups | /usr/bin/python3 -c "import json,sys;print([x['name'] for x in json.load(sys.stdin)['backups'] if not x['name'].startswith('pre')][0])")"
r="$(E restore "$b")"
check "restore removes files made after the backup" '[ ! -e "$A/claude-code-sessions/AAAAAAAA-1/org1/local_new.json" ]'
undo="$(echo "$r" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['undo'])")"
E restore "$undo" >/dev/null
check "restore of the undo backup brings them back" '[ -f "$A/claude-code-sessions/AAAAAAAA-1/org1/local_new.json" ]'
check "unknown backup name fails" '! E restore ../../etc >/dev/null'

echo "errors"
check "switch to unknown fails" '! E switch DDDD >/dev/null && grep -q Unknown "$T/err"'
E forget AAAAAAAA >/dev/null
check "forget removes login" '[ ! -d "$CLAUDE_SWITCH_HOME/profiles/AAAAAAAA-1" ]'
check "switch without login fails" '! E switch AAAAAAAA >/dev/null && grep -q "No saved login" "$T/err"'
check "lock blocks a second switch" '/usr/bin/python3 -c "import fcntl,subprocess,sys;f=open(\"$CLAUDE_SWITCH_HOME/lock\",\"w\");fcntl.flock(f,fcntl.LOCK_EX);sys.exit(subprocess.call([\"$ENGINE\",\"add\"],stderr=subprocess.DEVNULL)==0)"'

echo "labels, hide, settings"
E label BBBBBBBB "me@example.com" >/dev/null; E hide AAAAAAAA >/dev/null
st="$(E status)"
check "label in status" 'echo "$st" | grep -q me@example.com'
check "hidden in status" 'echo "$st" | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if [a for a in d[\"accounts\"] if a[\"id\"].startswith(\"AAAA\") and a[\"hidden\"]] else 1)"'
check "bad setting fails" '! E set nope 1 >/dev/null'

echo "account order and pin"
settings_of() { E status | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['settings']['$1'])"; }
check "order is empty by default" '[ "$(settings_of order)" = "[]" ]'
E order BBBBBBBB AAAAAAAA >/dev/null
check "order saves full ids from short ids" '[ "$(settings_of order)" = "['"'"'BBBBBBBB-2'"'"', '"'"'AAAAAAAA-1'"'"']" ]'
check "order with an unknown account fails" '! E order DDDD >/dev/null && grep -q Unknown "$T/err"'
check "...and keeps the old order" '[ "$(settings_of order)" = "['"'"'BBBBBBBB-2'"'"', '"'"'AAAAAAAA-1'"'"']" ]'
check "order with a repeated account fails" '! E order AAAAAAAA AAAAAAAA-1 >/dev/null'
check "set cannot change order" '! E set order 1 >/dev/null'
check "pinned is empty by default" '[ "$(settings_of pinned)" = "[]" ]'
E pin AAAAAAAA >/dev/null
check "pin adds the account" '[ "$(settings_of pinned)" = "['"'"'AAAAAAAA-1'"'"']" ]'
E pin AAAAAAAA >/dev/null
check "pin twice keeps one entry" '[ "$(settings_of pinned)" = "['"'"'AAAAAAAA-1'"'"']" ]'
E unpin AAAAAAAA >/dev/null
check "unpin removes the account" '[ "$(settings_of pinned)" = "[]" ]'
check "pin of an unknown account fails" '! E pin DDDD >/dev/null'

mkdir -p "$HOME/.claude-b"; echo '{"oauthAccount":{"accountUuid":"AAAAAAAA-1","emailAddress":"b@example.com"}}' > "$HOME/.claude-b/.claude.json"
E label AAAAAAAA "" >/dev/null
check "email from a second CLI config folder" 'E status | grep -q b@example.com'

echo "tick auto-saves a running login"
touch "$A/.running"; E tick >/dev/null
check "recent login not saved again" 'grep -q switch "$CLAUDE_SWITCH_HOME/profiles/BBBBBBBB-2/meta.json"'
E forget BBBBBBBB >/dev/null; E tick >/dev/null
check "auto login saved" 'grep -q auto "$CLAUDE_SWITCH_HOME/profiles/BBBBBBBB-2/meta.json"'

echo "paused session found"
mkdir -p "$HOME/.claude/projects/p"
echo '{"sessionId":"local_p1","cliSessionId":"cli-p1","title":"Paused one"}' > "$A/claude-code-sessions/BBBBBBBB-2/org2/local_p1.json"
echo '{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-07T12:00:00Z","message":{"content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 8pm (Asia/Calcutta)"}]}}' > "$HOME/.claude/projects/p/cli-p1.jsonl"
check "paused listed with reset time" 'E status | grep -q "8pm (Asia/Calcutta)"'

echo "resetsAt from the reset text"
resets_at() { # <reset text> <stoppedAt> -> resetsAt of the paused session ("None" when null)
  echo '{"type":"assistant","isApiErrorMessage":true,"timestamp":"'"$2"'","message":{"content":[{"type":"text","text":"You'"'"'ve hit your session limit · '"$1"'"}]}}' > "$HOME/.claude/projects/p/cli-p1.jsonl"
  E status | /usr/bin/python3 -c "import json,sys;p=json.load(sys.stdin)['paused'];print(p[0]['resetsAt'] if p else 'missing')"
}
epoch() { date -ju -f %Y-%m-%dT%H:%M:%SZ "$1" +%s; }
check "8pm later the same day" '[ "$(resets_at "resets 8pm (Asia/Calcutta)" 2026-11-07T12:00:00Z)" = "$(epoch 2026-11-07T14:30:00Z)" ]'
check "4:50pm already passed: next day" '[ "$(resets_at "resets 4:50pm (Asia/Calcutta)" 2026-11-07T12:00:00Z)" = "$(epoch 2026-11-08T11:20:00Z)" ]'
check "12:30am after midnight" '[ "$(resets_at "resets 12:30am (Asia/Calcutta)" 2026-11-07T12:00:00Z)" = "$(epoch 2026-11-07T19:00:00Z)" ]'
check "date and time (weekly limit)" '[ "$(resets_at "resets Nov 10, 5pm (America/New_York)" 2026-11-07T12:00:00Z)" = "$(epoch 2026-11-10T22:00:00Z)" ]'
check "date at the turn of the year" '[ "$(resets_at "resets Jan 2, 9am (UTC)" 2026-12-30T12:00:00Z)" = "$(epoch 2027-01-02T09:00:00Z)" ]'
check "weekday and time" '[ "$(resets_at "resets Mon 12:00am (UTC)" 2026-11-07T12:00:00Z)" = "$(epoch 2026-11-09T00:00:00Z)" ]'
check "no time zone: local time" '[ "$(TZ=UTC resets_at "resets 3pm" 2026-11-07T12:00:00Z)" = "$(epoch 2026-11-07T15:00:00Z)" ]'
check "unreadable text is null" '[ "$(resets_at "resets soon" 2026-11-07T12:00:00Z)" = None ]'
check "unknown time zone is null" '[ "$(resets_at "resets 8pm (Mars/Base)" 2026-11-07T12:00:00Z)" = None ]'
check "no reset text is null" '[ "$(resets_at "try again later" 2026-11-07T12:00:00Z)" = None ]'

echo "version and layout guard"
E label BBBBBBBB-2 "" >/dev/null
login_as BBBBBBBB-2 cookieB; E add >/dev/null; login_as AAAAAAAA-1 cookieA
plist 9.9.9
out="$(E switch BBBBBBBB-2)"
check "untested version with known layout switches" 'echo "$out" | grep -q "\"ok\": true"'
check "...and warns" 'echo "$out" | grep -q "not tested yet"'
check "status says version not tested" 'E status | grep -q "\"versionTested\": false"'
E verify BBBBBBBB-2 >/dev/null
check "verify adds the version to tested" 'E status | grep -q "\"versionTested\": true"'
plist 9.9.10
echo "not a database" > "$A/Cookies"
appsum() { find "$A" -type f -print0 | sort -z | xargs -0 shasum | shasum; }
before="$(appsum)"
check "unknown layout refuses the switch" '! E switch AAAAAAAA >/dev/null && grep -q "does not know" "$T/err"'
check "...and changes no file" '[ "$(appsum)" = "$before" ]'
check "status lists the layout problem" 'E status | grep -q "not a database"'
check "unknown layout refuses add" '! E add >/dev/null'
check "--force switches anyway" 'E switch AAAAAAAA --force | grep -q "Forced switch"'
check "recover with no journal is a no-op" 'E recover | grep -q "\"recovered\": false"'

echo "Claude does not quit (found in the live test)"
before="$(E status | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['current'])")"
check "switch fails with a clear message" '! CLAUDE_SWITCH_QUIT_FAIL=1 E switch BBBBBBBB >/dev/null && grep -q "did not quit" "$T/err"'
check "...and leaves no journal" '[ ! -e "$CLAUDE_SWITCH_HOME/journal.json" ]'
check "...and nothing to repair" 'E status | grep -q "\"pendingRecovery\": false"'
check "...and the account is unchanged" 'E status | grep -q "\"current\": \"$before\""'
check "add fails the same way, no journal" '! CLAUDE_SWITCH_QUIT_FAIL=1 E add >/dev/null && [ ! -e "$CLAUDE_SWITCH_HOME/journal.json" ]'
check "the next switch works" 'E switch BBBBBBBB | grep -q "\"ok\": true"'

echo "journal during a running switch is not a repair (found in the live test)"
echo '{"op":"switch","step":"started","target":"BBBBBBBB-2"}' > "$CLAUDE_SWITCH_HOME/journal.json"
/usr/bin/python3 -c "import fcntl,time;f=open('$CLAUDE_SWITCH_HOME/lock','w');fcntl.flock(f,fcntl.LOCK_EX);time.sleep(3)" & holder=$!
sleep 0.5
st="$(E status)"
check "status: switch running" 'echo "$st" | grep -q "\"switchRunning\": true"'
check "status: no pending recovery while it runs" 'echo "$st" | grep -q "\"pendingRecovery\": false"'
check "recover waits instead of failing" 'E recover | grep -q "\"running\": true"'
check "journal is kept for the running switch" '[ -e "$CLAUDE_SWITCH_HOME/journal.json" ]'
wait $holder
check "after the lock is free, it is a pending recovery" 'E status | grep -q "\"pendingRecovery\": true"'
E recover >/dev/null

echo "remove account"
S="$A/claude-code-sessions"; D=DDDDDDDD-4
mkdir -p "$S/$D/org4"; for i in 1 2; do echo "{\"sessionId\":\"local_d$i\"}" > "$S/$D/org4/local_d$i.json"; done
mkdir -p "$CLAUDE_SWITCH_HOME/profiles/$D"; echo '{"savedAt":1,"mode":"switch"}' > "$CLAUDE_SWITCH_HOME/profiles/$D/meta.json"
E label "$D" "sam@example.com" >/dev/null; E mine DDDDDDDD >/dev/null; E hide DDDDDDDD >/dev/null
cur="$(E status | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['current'])")"
E order "$D" "$cur" >/dev/null; E pin DDDDDDDD >/dev/null; E pin "$cur" >/dev/null
setting() { /usr/bin/python3 -c "import json;print(' '.join(json.load(open('$CLAUDE_SWITCH_HOME/settings.json')).get('$1') or []))"; }
others() { (cd "$S" && find . -type f ! -path "./$D/*" -print0 | sort -z | xargs -0 shasum); }
o_before="$(others)"
check "remove the current account is refused" '! E remove "$cur" >/dev/null && grep -q "current account" "$T/err"'
check "...and its folder stays" '[ -d "$S/$cur" ]'
check "remove an unknown account fails" '! E remove EEEE >/dev/null && grep -q Unknown "$T/err"'
/usr/bin/python3 -c "import fcntl,time;f=open('$CLAUDE_SWITCH_HOME/lock','w');fcntl.flock(f,fcntl.LOCK_EX);time.sleep(2)" & holder=$!
sleep 0.5
check "remove during a switch is refused" '! E remove DDDDDDDD >/dev/null && grep -q "Another switch" "$T/err"'
wait $holder
check "...and changes nothing" '[ -f "$S/$D/org4/local_d1.json" ] && [ -d "$CLAUDE_SWITCH_HOME/profiles/$D" ]'
echo '{"op":"switch","step":"started"}' > "$CLAUDE_SWITCH_HOME/journal.json"
check "remove with a pending recovery is refused" '! E remove DDDDDDDD >/dev/null && grep -q "recover" "$T/err"'
rm "$CLAUDE_SWITCH_HOME/journal.json"
out="$(E remove DDDDDDDD)"
check "remove succeeds" 'echo "$out" | grep -q "\"ok\": true"'
bk="$(echo "$out" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['backup'])")"
check "account is gone from status" '! E status | grep -q "$D"'
check "session folder is gone" '[ ! -e "$S/$D" ]'
check "session folder moved into the backups" '[ -f "$CLAUDE_SWITCH_BACKUPS/$bk/$D/org4/local_d2.json" ]'
check "saved login deleted" '[ ! -e "$CLAUDE_SWITCH_HOME/profiles/$D" ]'
check "label, owned and hidden removed" '! grep -q "$D" "$CLAUDE_SWITCH_HOME/settings.json"'
check "removed from order and pinned, others kept" '[ "$(setting order)" = "$cur" ] && [ "$(setting pinned)" = "$cur" ]'
check "other accounts unchanged" '[ "$(others)" = "$o_before" ]'
check "no journal left" '[ ! -e "$CLAUDE_SWITCH_HOME/journal.json" ]'
check "removal is in the log" 'grep -q "removed account $D" "$CLAUDE_SWITCH_HOME/switch.log"'
E sync >/dev/null
check "sync does not bring the folder back" '[ ! -e "$S/$D" ]'
check "backups lists the removed account" 'E backups | grep -q "\"name\": \"$bk\""'
o_before="$(others)"
E restore "$bk" >/dev/null
check "restore brings the sessions back" '[ -f "$S/$D/org4/local_d1.json" ] && [ -f "$S/$D/org4/local_d2.json" ]'
check "...and keeps the other accounts" '[ "$(others)" = "$o_before" ]'
check "...and the account is not mine" 'E status | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if [a for a in d[\"accounts\"] if a[\"id\"]==\"$D\" and not a[\"owned\"] and not a[\"savedLogin\"]] else 1)"'

echo "restore of a removed account keeps newer session files"
F=FFFFFFFF-5; mkdir -p "$S/$F/org5"
for i in 1 2 3; do echo "{\"v\":\"backup-$i\"}" > "$S/$F/org5/local_f$i.json"; done
touch -t 202601010000 "$S/$F/org5/"*.json
bk="$(E remove FFFFFFFF | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['backup'])")"
mkdir -p "$S/$F/org5"  # the user signed in again: Claude made new files
echo '{"v":"new"}' > "$S/$F/org5/local_f1.json"
echo '{"v":"old"}' > "$S/$F/org5/local_f2.json"; touch -t 202501010000 "$S/$F/org5/local_f2.json"
out="$(E restore "$bk")"
check "a newer file is not overwritten" 'grep -q new "$S/$F/org5/local_f1.json"'
check "an older file is updated" 'grep -q backup-2 "$S/$F/org5/local_f2.json"'
check "a missing file comes back" 'grep -q backup-3 "$S/$F/org5/local_f3.json"'
undo="$(echo "$out" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['undo'])")"
check "there is an undo backup" '[ -n "$undo" ] && grep -q new "$CLAUDE_SWITCH_BACKUPS/$undo/$F/org5/local_f1.json"'

echo "sign in to save (save-login)"
mkdir -p "$A/claude-code-sessions/DDDDDDDD-4/org4"
login_as BBBBBBBB-2 cookieB; E add >/dev/null
check "waits while Claude is signed out" 'E save-login DDDDDDDD | grep -q "\"waiting\": true"'
login_as BBBBBBBB-2 cookieB2
out="$(E save-login DDDDDDDD)"
check "other account signed in: mismatch" 'echo "$out" | grep -q "\"match\": false"'
check "...and the message names the signed-in account" 'echo "$out" | grep -q "BBBBBBBB-2"'
check "...and no login saved for the picked account" '[ ! -d "$CLAUDE_SWITCH_HOME/profiles/DDDDDDDD-4" ]'
login_as DDDDDDDD-4 cookieD
out="$(E save-login DDDDDDDD)"
check "picked account signed in: saved" 'echo "$out" | grep -q "\"saved\": true"'
check "...and the login is in the profile" '[ -f "$CLAUDE_SWITCH_HOME/profiles/DDDDDDDD-4/meta.json" ]'
check "status shows the saved login" 'E status | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if [a for a in d[\"accounts\"] if a[\"id\"]==\"DDDDDDDD-4\" and a[\"savedLogin\"]] else 1)"'
check "unknown account fails" '! E save-login ZZZZ >/dev/null'

echo "update check (fake gh)"
cat > "$T/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  "release view") [ -n "$GH_FAIL" ] && { echo "HTTP 404: Not Found" >&2; exit 1; }
                  echo '{"tagName":"v1.2.0","url":"https://example/r","publishedAt":"2026-11-08T00:00:00Z"}' ;;
  "release download") for a; do case "$prev" in --dir) d="$a";; esac; prev="$a"; done
                      echo 'echo installed' > "$d/install-release.sh" ;;
esac
GH
chmod +x "$T/gh"; export CLAUDE_SWITCH_GH="$T/gh"
check "newer release found" 'E update-check 1.0.0 | grep -q "\"available\": true"'
check "same version is not newer" 'E update-check 1.2.0 | grep -q "\"available\": false"'
check "dev build counts as older" 'E update-check 0.3.0-dev | grep -q "\"available\": true"'
check "9.9.9 is newer than release 1.2.0 (numeric compare)" 'E update-check 9.9.9 | grep -q "\"available\": false"'
check "gh error is reported, not a failure" 'GH_FAIL=1 E update-check 1.0.0 | grep -q "404"'
check "update-install downloads the installer" 'E update-install v1.2.0 | grep -q install-release.sh'
check "update-install refuses a bad tag" '! E update-install "v1; rm -rf /" >/dev/null'

echo "debug report"
# own fake Mac with real-shaped account IDs (last block, so the env can change)
R="$T/report"; export CLAUDE_APP_DIR="$R/app" CLAUDE_SWITCH_HOME="$R/home" HOME="$R/userhome"
IA=aaaa1111-1111-4111-8111-111111111111; IB=bbbb2222-2222-4222-8222-222222222222
mkdir -p "$R/app/claude-code-sessions/$IA/o1" "$R/app/claude-code-sessions/$IB/o2" "$R/home" "$HOME"
echo "{\"lastKnownAccountUuid\":\"$IA\"}" > "$R/app/config.json"
{ echo "2026-11-01 10:00:00 switch to $IB"
  echo "2026-11-01 10:00:01 saved login of ${IA:0:8} (switch)"
  echo "2026-11-01 10:00:02 switched to $IB"
} > "$R/home/switch.log"
out="$(E report)"; rc=$?
check "report runs" '[ "$rc" = 0 ] && echo "$out" | grep -q "debug report"'
check "report has no account ID" '! echo "$out" | grep -qE "[0-9a-f]{8}-[0-9a-f]{4}|aaaa1111|bbbb2222"'
check "same account, same placeholder" 'echo "$out" | grep -q "switch to account 2" && echo "$out" | grep -q "switched to account 2" && echo "$out" | grep -q "saved login of account 1 "'
echo "{\"oauthAccount\":{\"accountUuid\":\"$IB\",\"emailAddress\":\"sam@example.com\"}}" > "$HOME/.claude.json"
E label "${IA:0:8}" "alex@example.com" >/dev/null
{ echo "2026-11-01 10:00:03 note sam@example.com and Other.Person@mail.example.org"
  echo "2026-11-01 10:00:04 backup -> $HOME/Backups/claude-sessions/2026-11-01"
  echo "2026-11-01 10:00:05 backup -> /Users/demo.user/Backups/claude-sessions/2026-11-01"
} >> "$R/home/switch.log"
out="$(E report)"
check "report has no email and no ID (the pass check)" '[ "$(echo "$out" | grep -cE "[0-9a-f]{8}-[0-9a-f]{4}|@")" = 0 ]'
check "known email gets its account placeholder" 'echo "$out" | grep -q "note account 2 and account 3"'
echo "2026-11-01 10:00:06 label email alex@example.com, id $IA" >> "$R/home/switch.log"
pair="$(E report | sed -n 's/.*label email \(account [0-9]*\), id \(account [0-9]*\)$/\1|\2/p')"
check "account named by its email in the app: email and ID get the same placeholder" '[ -n "$pair" ] && [ "${pair%|*}" = "${pair#*|}" ]'
check "labels are not in the report" '! echo "$out" | grep -qi alex'
check "home folder shown as ~" 'echo "$out" | grep -q "backup -> ~/Backups" && ! echo "$out" | grep -q "$R"'
check "another user folder shown as ~" '! echo "$out" | grep -q "demo.user"'
check "report has versions, layout, settings" 'echo "$out" | grep -q "Claude version:" && echo "$out" | grep -q "Layout check:" && echo "$out" | grep -q "syncOnSwitch"'
for i in $(seq 1 300); do echo "2026-11-02 10:00:00 line $i"; done >> "$R/home/switch.log"
check "only the last 200 log lines" '[ "$(E report | grep -c "  2026-")" = 200 ] && E report | grep -q "line 300" && ! E report | grep -q "line 100$"'

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
