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

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
