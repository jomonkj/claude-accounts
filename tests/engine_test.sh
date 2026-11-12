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

echo "account details"
# acct <id prefix> <python expression on the account dict "a"> -> prints the result
acct() { E status | /usr/bin/python3 -c "import json,sys;a=[x for x in json.load(sys.stdin)['accounts'] if x['id'].startswith('$1')][0];print($2)"; }
echo '{"oauthAccount":{"accountUuid":"BBBBBBBB-2","emailAddress":"bb@example.com","displayName":"Bee","organizationName":"Bee Org","organizationType":"claude_max","userRateLimitTier":"default_claude_max_20x"}}' > "$HOME/.claude.json"
check "details from the CLI config" '[ "$(acct BBBB "a[\"details\"]")" = "{'"'"'email'"'"': '"'"'bb@example.com'"'"', '"'"'displayName'"'"': '"'"'Bee'"'"', '"'"'plan'"'"': '"'"'Max 20x'"'"', '"'"'orgName'"'"': '"'"'Bee Org'"'"'}" ]'
check "only the email when the CLI config has no more" '[ "$(acct AAAA "a[\"details\"]")" = "{'"'"'email'"'"': '"'"'b@example.com'"'"', '"'"'displayName'"'"': None, '"'"'plan'"'"': None, '"'"'orgName'"'"': None}" ]'
mkdir -p "$A/claude-code-sessions/CCCCCCCC-3/org3"
check "all details null without CLI config" '[ "$(acct CCCC "list(a[\"details\"].values())")" = "[None, None, None, None]" ]'
plan_of() { # <organizationType> <userRateLimitTier> -> plan text of account B
  echo "{\"oauthAccount\":{\"accountUuid\":\"BBBBBBBB-2\",\"organizationType\":\"$1\",\"userRateLimitTier\":\"$2\"}}" > "$HOME/.claude.json"
  acct BBBB 'a["details"]["plan"]'
}
check "plan Max 5x" '[ "$(plan_of claude_max default_claude_max_5x)" = "Max 5x" ]'
check "plan Pro" '[ "$(plan_of claude_pro default_claude_ai)" = "Pro" ]'
check "plan Team with a 5x seat" '[ "$(plan_of claude_team default_claude_max_5x)" = "Team (5x)" ]'
check "plan Team standard seat" '[ "$(plan_of claude_team default_raven)" = "Team" ]'
check "plan Enterprise" '[ "$(plan_of claude_enterprise default_raven)" = "Enterprise" ]'
check "unknown plan type shown in words" '[ "$(plan_of claude_free_trial x)" = "Free Trial" ]'
check "no plan type is null" '[ "$(plan_of "" "")" = None ]'
echo 'not json' > "$HOME/.claude.json"; mkdir -p "$HOME/.claude-c"; echo '{"oauthAccount": 5}' > "$HOME/.claude-c/.claude.json"
check "bad CLI config does not break status" 'E status >/dev/null && [ "$(acct BBBB "a[\"details\"][\"email\"]")" = None ]'
rm -rf "$HOME/.claude-c" "$HOME/.claude.json"
check "switch time recorded for each account" '[ "$(acct AAAA "a[\"switchedAt\"] > 0")" = True ] && [ "$(acct BBBB "a[\"switchedAt\"] > 0")" = True ]'
check "no switch time for an account never switched to" '[ "$(acct CCCC "a[\"switchedAt\"]")" = 0 ]'
rm -rf "$A/claude-code-sessions/CCCCCCCC-3"

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

echo "last limit hit for each account"
mv "$HOME/.claude/projects/p/cli-p1.jsonl" "$T/cli-p1.keep"
Q="$HOME/.claude/projects/q"; mkdir -p "$Q"
iso() { /usr/bin/python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
logtime() { /usr/bin/python3 -c "import datetime;print((datetime.datetime.now()-datetime.timedelta(hours=$1)).strftime('%Y-%m-%d %H:%M:%S'))"; }
err() { # <hours ago> <text> -> one transcript line with a usage-limit error
  echo '{"type":"assistant","isApiErrorMessage":true,"timestamp":"'"$(iso $1)"'","message":{"content":[{"type":"text","text":"'"$2"'"}]}}'
}
sess() { # <account> <session> <cli id>: a desktop session file
  mkdir -p "$A/claude-code-sessions/$1/org"; echo '{"sessionId":"'"$2"'","cliSessionId":"'"$3"'","title":"t"}' > "$A/claude-code-sessions/$1/org/$2.json"
}
lim() { acct "$1" "a[\"limit\"] and (a[\"limit\"][\"window\"], a[\"limit\"][\"resetsAt\"] is not None)"; }
check "no limit error is null" '[ "$(acct AAAA "a[\"limit\"]")" = None ] && [ "$(acct BBBB "a[\"limit\"]")" = None ]'
sess BBBBBBBB-2 local_l1 cli-l1
{ err 30 "You've hit your 5-hour limit · resets 8pm (UTC)"; echo 'not json'; echo '{"type":"user","timestamp":"'"$(iso 29)"'"}'; } > "$Q/cli-l1.jsonl"
check "5-hour limit, with a bad line in the transcript" '[ "$(lim BBBB)" = "('"'"'5h'"'"', True)" ]'
check "hitAt is the error time" '[ "$(acct BBBB "abs(a[\"limit\"][\"hitAt\"] - __import__(\"time\").time() + 30*3600) < 5")" = True ]'
check "reset text kept" '[ "$(acct BBBB "a[\"limit\"][\"resets\"]")" = "8pm (UTC)" ]'
err 20 "You've hit your session limit · resets 9pm (UTC)" >> "$Q/cli-l1.jsonl"
check "session limit counts as 5-hour, newest wins" '[ "$(lim BBBB)" = "('"'"'5h'"'"', True)" ] && [ "$(acct BBBB "a[\"limit\"][\"resets\"]")" = "9pm (UTC)" ]'
sess BBBBBBBB-2 local_l2 cli-l2
err 10 "You've hit your weekly limit · resets Nov 30, 8:30pm (UTC)" > "$Q/cli-l2.jsonl"
check "weekly limit, newest across sessions" '[ "$(lim BBBB)" = "('"'"'week'"'"', True)" ]'
err 1 "You've hit some new limit" >> "$Q/cli-l2.jsonl"
check "unknown window and no reset are null" '[ "$(acct BBBB "(a[\"limit\"][\"window\"], a[\"limit\"][\"resetsAt\"])")" = "(None, None)" ]'
sess AAAAAAAA-1 local_l3 cli-l3
err 200 "You've hit your 5-hour limit · resets 8pm (UTC)" > "$Q/cli-l3.jsonl"
check "error older than 8 days ignored" '[ "$(acct AAAA "a[\"limit\"]")" = None ]'
{ err 3 "You've hit your 5-hour limit · resets 8pm (UTC)"; /usr/bin/python3 -c "print(('{\"type\":\"user\",\"x\":\"' + 'y'*900 + '\"}\n')*200, end='')"; } > "$Q/cli-l3.jsonl"
check "error far before the end of a long transcript" '[ "$(lim AAAA)" = "('"'"'5h'"'"', True)" ]'
err 2 "You've hit your weekly limit · resets Nov 30, 8:30pm (UTC)" > "$Q/cli-l3.jsonl"
check "a rewritten (shorter) transcript is scanned again" '[ "$(lim AAAA)" = "('"'"'week'"'"', True)" ]'
rm "$Q/cli-l3.jsonl"; E status >/dev/null
check "a removed transcript drops its error" '[ "$(acct AAAA "a[\"limit\"]")" = None ]'
echo "sync copied a session to both accounts; the log says A was active"
sess AAAAAAAA-1 local_l4 cli-l4; sess BBBBBBBB-2 local_l4 cli-l4
touch "$A/claude-code-sessions/BBBBBBBB-2/org/local_l4.json"
err 0.5 "You've hit your weekly limit · resets Nov 30, 8:30pm (UTC)" > "$Q/cli-l4.jsonl"
check "without a log entry the newest copy owns it" '[ "$(lim BBBB)" = "('"'"'week'"'"', True)" ] && [ "$(acct AAAA "a[\"limit\"]")" = None ]'
cp "$CLAUDE_SWITCH_HOME/switch.log" "$T/log.keep"
echo "$(logtime 0.75) switched to AAAAAAAA-1" >> "$CLAUDE_SWITCH_HOME/switch.log"
check "the account active at the error time owns it" '[ "$(lim AAAA)" = "('"'"'week'"'"', True)" ]'
check "...and the other copy does not" '[ "$(acct BBBB "a[\"limit\"][\"hitAt\"] < __import__(\"time\").time() - 3000")" = True ]'
echo "$(logtime 0.6) saved login of BBBBBBBB-2 (auto)" >> "$CLAUDE_SWITCH_HOME/switch.log"
check "an auto save marks the active account too" '[ "$(acct BBBB "a[\"limit\"][\"hitAt\"] > __import__(\"time\").time() - 3000")" = True ]'
echo "$(logtime 0.55) saved login of AAAAAAAA-1 (switch)" >> "$CLAUDE_SWITCH_HOME/switch.log"
check "a save on switch does not mark the account active" '[ "$(acct BBBB "a[\"limit\"][\"hitAt\"] > __import__(\"time\").time() - 3000")" = True ]'
echo "one session hits a limit on A, then (after a switch) on B"
rm -f "$Q"/cli-l[124].jsonl; E status >/dev/null
{ err 0.7 "You've hit your 5-hour limit · resets 8pm (UTC)"; err 0.4 "You've hit your weekly limit · resets Nov 30, 8:30pm (UTC)"; } > "$Q/cli-l4.jsonl"
echo "$(logtime 0.5) switched to BBBBBBBB-2" >> "$CLAUDE_SWITCH_HOME/switch.log"
check "the older error stays with A" '[ "$(lim AAAA)" = "('"'"'5h'"'"', True)" ]'
check "the newer error goes to B" '[ "$(lim BBBB)" = "('"'"'week'"'"', True)" ]'
S="$CLAUDE_SWITCH_HOME/limit-scan.json"
echo '{"v":3,"sessions":{"local_l4.json":"x"},"transcripts":{"cli-l4":{"size":"x","hits":[["a",1,2],5]}}}' > "$S"
check "a damaged scan cache is rebuilt" '[ "$(lim AAAA)" = "('"'"'5h'"'"', True)" ] && [ "$(lim BBBB)" = "('"'"'week'"'"', True)" ]'
echo 'not json' > "$S"
check "an unreadable scan cache is rebuilt" '[ "$(lim AAAA)" = "('"'"'5h'"'"', True)" ]'
check "the cache holds no transcript text beyond the limit message" '! grep -q "\"type\"" "$S"'
cp "$T/log.keep" "$CLAUDE_SWITCH_HOME/switch.log"

echo "paused session: the account active at the stop time"
sess AAAAAAAA-1 local_pz cli-pz; sess BBBBBBBB-2 local_pz cli-pz
touch -t "$(date -v+1M +%Y%m%d%H%M)" "$A/claude-code-sessions/BBBBBBBB-2/org/local_pz.json"
err 0.3 "You've hit your 5-hour limit · resets 8pm (UTC)" > "$Q/cli-pz.jsonl"
paused_acct() { E status | /usr/bin/python3 -c "import json,sys;print([p['account'] for p in json.load(sys.stdin)['paused'] if p['id']=='local_pz'])"; }
check "without a log entry the newest copy owns the paused session" '[ "$(paused_acct)" = "['"'"'BBBBBBBB-2'"'"']" ]'
echo "$(logtime 0.5) switched to AAAAAAAA-1" >> "$CLAUDE_SWITCH_HOME/switch.log"
check "the account active at the stop time owns the paused session" '[ "$(paused_acct)" = "['"'"'AAAAAAAA-1'"'"']" ]'
echo "$(logtime 0.4) switched to DDDDDDDD-9" >> "$CLAUDE_SWITCH_HOME/switch.log"
check "an unknown account in the log is ignored" '[ "$(paused_acct)" = "['"'"'BBBBBBBB-2'"'"']" ]'
cp "$T/log.keep" "$CLAUDE_SWITCH_HOME/switch.log"
rm -rf "$Q" "$A"/claude-code-sessions/*/org; mv "$T/cli-p1.keep" "$HOME/.claude/projects/p/cli-p1.jsonl"

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
/usr/bin/python3 -c "import fcntl,time;f=open('$CLAUDE_SWITCH_HOME/lock','w');fcntl.flock(f,fcntl.LOCK_EX);time.sleep(4)" & holder=$!
sleep 0.5
check "remove during a switch is refused" '! E remove DDDDDDDD >/dev/null && grep -q "Another switch" "$T/err"'
# The checks run inside the lock: the switch may change the current account or end with a journal.
check "current-account check waits for the lock" '! E remove "$cur" >/dev/null && grep -q "Another switch" "$T/err"'
echo '{"op":"switch","step":"started"}' > "$CLAUDE_SWITCH_HOME/journal.json"
check "pending-recovery check waits for the lock" '! E remove DDDDDDDD >/dev/null && grep -q "Another switch" "$T/err"'
rm "$CLAUDE_SWITCH_HOME/journal.json"
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
kinds() { E backups | /usr/bin/python3 -c "
import json,sys
for b in json.load(sys.stdin)['backups']: print(b['name'], b.get('kind'), b.get('account', '-'), b.get('time', '-'))"; }
check "backup kind: removed, with account and time" 'kinds | grep -qE "^$bk removed DDDDDDDD [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$"'
check "backup kind: daily" 'kinds | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} daily - [0-9]{4}-[0-9]{2}-[0-9]{2}$"'
check "backup kind: pre-restore" 'kinds | grep -qE "^pre-restore-[0-9-]+ pre-restore - [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$"'
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
/usr/bin/python3 -c "import fcntl,time;f=open('$CLAUDE_SWITCH_HOME/lock','w');fcntl.flock(f,fcntl.LOCK_EX);time.sleep(2)" & holder=$!
sleep 0.5
out="$(E save-login DDDDDDDD)"; rc=$?
check "lock busy (the 5-minute tick): not an error, busy" '[ "$rc" = 0 ] && echo "$out" | grep -q "\"busy\": true" && echo "$out" | grep -q "\"saved\": false"'
check "...and nothing saved yet" '[ ! -d "$CLAUDE_SWITCH_HOME/profiles/DDDDDDDD-4" ]'
wait $holder
echo '{"op":"switch","step":"loaded"}' > "$CLAUDE_SWITCH_HOME/journal.json"
check "unfinished switch: busy, not an error" 'E save-login DDDDDDDD | grep -q "\"busy\": true"'
rm "$CLAUDE_SWITCH_HOME/journal.json"
out="$(E save-login DDDDDDDD)"
check "picked account signed in: saved" 'echo "$out" | grep -q "\"saved\": true"'
check "...and the login is in the profile" '[ -f "$CLAUDE_SWITCH_HOME/profiles/DDDDDDDD-4/meta.json" ]'
check "status shows the saved login" 'E status | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if [a for a in d[\"accounts\"] if a[\"id\"]==\"DDDDDDDD-4\" and a[\"savedLogin\"]] else 1)"'
check "unknown account fails" '! E save-login ZZZZ >/dev/null'

echo "update check (curl, no gh)"
# A file:// folder that acts as the GitHub API. Real curl reads it; no gh on the way.
R="$T/api/repos/jomonkj/claude-accounts/releases"; mkdir -p "$R/tags" "$T/dl"
echo 'echo installed' > "$T/dl/install-release.sh"
release_json() { # <tag>
  echo "{\"tag_name\":\"$1\",\"html_url\":\"https://example/r/$1\",\"published_at\":\"2026-11-08T00:00:00Z\",
        \"assets\":[{\"name\":\"install-release.sh\",\"browser_download_url\":\"file://$T/dl/install-release.sh\"}]}"; }
release_json v1.2.0 > "$R/latest"; release_json v1.2.0 > "$R/tags/v1.2.0"
echo '{"tag_name":"v1.3.0","assets":[]}' > "$R/tags/v1.3.0"
export CLAUDE_ACCOUNTS_API="file://$T/api" CLAUDE_ACCOUNTS_WEB="file://$T/web" CLAUDE_SWITCH_GH="$T/no-gh"
# github.com fallback links (used when the API fails): only v1.4.0 is there.
mkdir -p "$T/web/jomonkj/claude-accounts/releases/download/v1.4.0"
echo 'echo web-installer' > "$T/web/jomonkj/claude-accounts/releases/download/v1.4.0/install-release.sh"
check "newer release found" 'E update-check 1.0.0 | grep -q "\"available\": true"'
check "...with the tag and the page URL" 'E update-check 1.0.0 | grep -q "\"latest\": \"v1.2.0\"" && E update-check 1.0.0 | grep -q "example/r/v1.2.0"'
check "same version is not newer" 'E update-check 1.2.0 | grep -q "\"available\": false"'
check "dev build counts as older" 'E update-check 0.3.0-dev | grep -q "\"available\": true"'
check "9.9.9 is newer than release 1.2.0 (numeric compare)" 'E update-check 9.9.9 | grep -q "\"available\": false"'
echo 'not json' > "$R/latest"
check "bad API answer is an error, not a crash" 'E update-check 1.0.0 | grep -q "did not return JSON"'
mv "$R/latest" "$R/latest.off"
check "missing release is an error, not a crash" 'E update-check 1.0.0 | grep -q "\"error\""'
mv "$R/latest.off" "$R/latest"; release_json v1.2.0 > "$R/latest"
check "update-install downloads the installer" 'E update-install v1.2.0 | grep -q install-release.sh'
check "...and the file is the release's installer" 'grep -q "echo installed" "$CLAUDE_SWITCH_HOME/update/install-release.sh"'
check "update-install fails for a release with no installer" '! E update-install v1.3.0 >/dev/null && grep -q "no install-release.sh" "$T/err"'
check "update-install refuses a bad tag" '! E update-install "v1; rm -rf /" >/dev/null'
check "API fails: update-install uses the github.com link" 'E update-install v1.4.0 | grep -q "\"ok\": true" && grep -q web-installer "$CLAUDE_SWITCH_HOME/update/install-release.sh"'
check "API and github.com fail: error names the API problem" '! E update-install v1.5.0 >/dev/null && grep -q "Cannot download" "$T/err"'
check "unreachable API is an error, not a crash" 'CLAUDE_ACCOUNTS_API=https://127.0.0.1:9 E update-check 1.0.0 | grep -q "\"error\""'

echo "update check (gh fallback when curl fails)"
export CLAUDE_ACCOUNTS_API="file://$T/no-api"
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
echo "{\"oauthAccount\":{\"accountUuid\":\"$IB\",\"emailAddress\":\"sam@example.com\",\"displayName\":\"Samwise Person\",\"organizationName\":\"Secretorg Ltd\",\"organizationType\":\"claude_max\",\"userRateLimitTier\":\"default_claude_max_20x\"}}" > "$HOME/.claude.json"
echo '{"sessionId":"local_r1","cliSessionId":"cli-r1"}' > "$R/app/claude-code-sessions/$IB/o2/local_r1.json"
mkdir -p "$HOME/.claude/projects/r"
echo '{"type":"assistant","isApiErrorMessage":true,"timestamp":"'"$(iso 3)"'","message":{"content":[{"type":"text","text":"You'"'"'ve hit your weekly limit · resets Nov 30, 8:30pm (UTC)"}]}}' > "$HOME/.claude/projects/r/cli-r1.jsonl"
out="$(E report)"
check "report has the plan of each account" 'echo "$out" | grep -E "^  account 2:" | grep -q "plan Max 20x" && echo "$out" | grep -E "^  account 1:" | grep -q "plan unknown"'
check "report has the last limit window" 'echo "$out" | grep -E "^  account 2:" | grep -q "last limit weekly" && echo "$out" | grep -E "^  account 1:" | grep -q "last limit none"'
check "display name and org name are not in the report" '! echo "$out" | grep -qiE "samwise|secretorg"'
check "still no email and no ID" '[ "$(echo "$out" | grep -cE "[0-9a-f]{8}-[0-9a-f]{4}|@")" = 0 ]'
check "report has versions, layout, settings" 'echo "$out" | grep -q "Claude version:" && echo "$out" | grep -q "Layout check:" && echo "$out" | grep -q "syncOnSwitch"'
check "report from Terminal points to the app for shortcuts" 'echo "$out" | grep -q "shortcut settings: see the app"'
out="$(E report --app-setting shortcutOpenPanel=on --app-setting shortcutNextAccount=off)"
check "report from the app lists the shortcut states" 'echo "$out" | grep -q "  shortcutOpenPanel: on" && echo "$out" | grep -q "  shortcutNextAccount: off" && ! echo "$out" | grep -q "see the app"'
check "app settings must be key=value words" '! E report --app-setting "x=1 y" >/dev/null'
for i in $(seq 1 300); do echo "2026-11-02 10:00:00 line $i"; done >> "$R/home/switch.log"
check "only the last 200 log lines" '[ "$(E report | grep -c "  2026-")" = 200 ] && E report | grep -q "line 300" && ! E report | grep -q "line 100$"'
out="$(E report --live-usage "$IA=ok" --live-usage "$IB=http-403" --app-setting usageWarning=on)"
check "report has the live usage state of each account" 'echo "$out" | grep -E "^  account 1:" | grep -q "live usage ok" && echo "$out" | grep -E "^  account 2:" | grep -q "live usage http-403"'
check "report with live usage has no account ID" '! echo "$out" | grep -qE "[0-9a-f]{8}-[0-9a-f]{4}|aaaa1111|bbbb2222"'
check "report lists the warning setting" 'echo "$out" | grep -q "  usageWarning: on"'
check "a live usage state must be ok or an error type" '! E report --live-usage "$IA=sk-ant secret" >/dev/null && ! E report --live-usage "$IA=" >/dev/null'

echo "live usage cookies (usage-cookies)"
# own fake Mac: A is active (live cookies in the app folder), B has a saved login, C has none
U="$T/live"; export CLAUDE_APP_DIR="$U/app" CLAUDE_SWITCH_HOME="$U/home" HOME="$U/userhome"
LA=aaaa1111-1111-4111-8111-aaaaaaaaaaaa; LB=bbbb2222-2222-4222-8222-bbbbbbbbbbbb; LC=cccc3333-3333-4333-8333-cccccccccccc
mkdir -p "$U/app/claude-code-sessions/$LA/o" "$U/app/claude-code-sessions/$LB/o" "$U/app/claude-code-sessions/$LC/o" "$U/home/profiles/$LB" "$HOME"
echo "{\"lastKnownAccountUuid\":\"$LA\"}" > "$U/app/config.json"
echo '{"savedAt": 1, "mode": "switch"}' > "$U/home/profiles/$LB/meta.json"
PW="test-safe-storage-pw"
cookiedb() { # <db path> <password> <name=value>... : a Chromium v24 cookie database with v10 values
  /usr/bin/python3 - "$@" <<'PY'
import hashlib, sqlite3, subprocess, sys
path, pw, pairs = sys.argv[1], sys.argv[2].encode(), sys.argv[3:]
key = hashlib.pbkdf2_hmac("sha1", pw, b"saltysalt", 1003, 16)
con = sqlite3.connect(path)
con.execute("create table meta(key, value)"); con.execute("insert into meta values('version','24')")
con.execute("create table cookies(host_key, name, encrypted_value)")
for p in pairs:
    name, value = p.split("=", 1)
    plain = hashlib.sha256(b".claude.ai").digest() + value.encode()
    enc = subprocess.run(["/usr/bin/openssl", "enc", "-aes-128-cbc", "-nosalt", "-K", key.hex(), "-iv", "20" * 16],
                         input=plain, capture_output=True, check=True).stdout
    con.execute("insert into cookies values('.claude.ai', ?, ?)", (name, b"v10" + enc))
con.commit()
PY
}
cookiedb "$U/app/Cookies" "$PW" sessionKey=sk-ant-SECRET-A lastActiveOrg=org-a cf_clearance=CF-SECRET-A
cookiedb "$U/home/profiles/$LB/Cookies" "$PW" sessionKey=sk-ant-SECRET-B lastActiveOrg=org-b
live() { echo "$PW" | E usage-cookies; }
lv() { live | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin)['accounts'];a=d.get('$1');print($2)"; }
check "live usage is off by default" '[ "$(E status | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)[\"settings\"][\"liveUsage\"])")" = False ]'
check "no password on stdin is an error" '! E usage-cookies </dev/null >/dev/null && grep -q "stdin" "$T/err"'
check "a password on the command line is refused" '! echo "$PW" | E usage-cookies "$PW" >/dev/null && ! grep -q "$PW" "$T/err"'
check "active account: org and cookies from the live cookies" '[ "$(lv $LA "(a[\"ok\"], a[\"org\"], a[\"cookie\"])")" = "(True, '"'"'org-a'"'"', '"'"'sessionKey=sk-ant-SECRET-A; lastActiveOrg=org-a; cf_clearance=CF-SECRET-A'"'"')" ]'
check "saved login: org and cookies from its profile" '[ "$(lv $LB "(a[\"ok\"], a[\"org\"], a[\"cookie\"])")" = "(True, '"'"'org-b'"'"', '"'"'sessionKey=sk-ant-SECRET-B; lastActiveOrg=org-b'"'"')" ]'
check "an account without a login is left out" '[ "$(lv $LC "a")" = None ]'
live >/dev/null
check "no cookie or password in the log" '! grep -qE "SECRET|$PW" "$U/home/switch.log"'
check "the log names the counts" 'tail -1 "$U/home/switch.log" | grep -q "usage-cookies: 2 ok, 0 failed"'
check "no cookie or password in the report" '! E report | grep -qE "SECRET|$PW"'
check "no cookie or password in a file the engine wrote" '! grep -rqE "SECRET|$PW" "$U/home" --exclude=Cookies'
check "a wrong password gives an error, not a crash" '[ "$(echo wrong | E usage-cookies | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin)[\"accounts\"];print(sorted((a[\"ok\"], a[\"error\"], a[\"cookie\"]) for a in d.values()))")" = "[(False, '"'"'decrypt'"'"', None), (False, '"'"'decrypt'"'"', None)]" ]'
check "the log names the error types" 'tail -1 "$U/home/switch.log" | grep -q "usage-cookies: 0 ok, 2 failed (decrypt: 2)"'
rm -f "$U/home/profiles/$LB/Cookies"; cookiedb "$U/home/profiles/$LB/Cookies" "$PW" sessionKey=sk-ant-SECRET-B
check "no lastActiveOrg is a login error, with no cookie" '[ "$(lv $LB "(a[\"ok\"], a[\"error\"], a[\"cookie\"])")" = "(False, '"'"'no-login'"'"', None)" ]'

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
