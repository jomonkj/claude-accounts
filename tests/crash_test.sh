#!/usr/bin/env bash
# Crash test: kill the engine after each step of a switch, then run recover.
# Pass for every step: Claude has one complete, consistent login (all parts from the same
# account), every session file keeps its checksum, and no journal is left.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/claude-switch"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

# Steps of a switch, in order, with the account Claude must end on after recover.
#   started, saved, mid-load -> before the target login is complete -> back on A
#   loaded, synced           -> the target login is complete         -> on B
STEPS=("started:AAAA" "saved:AAAA" "mid-load:AAAA" "loaded:BBBB" "synced:BBBB")

login_as() { # <app> <account>
  local A="$1"
  rm -f "$A/Cookies"; sqlite3 "$A/Cookies" "create table cookies(host_key,name,value); insert into cookies values('.claude.ai','sessionKey','cookie-$2');"
  rm -rf "$A/Local Storage"; mkdir -p "$A/Local Storage"; echo "ls-$2" > "$A/Local Storage/data"
  echo "{\"locale\":\"en\",\"lastKnownAccountUuid\":\"$2\",\"oauth:tokenCacheV2\":\"tok-$2\"}" > "$A/config.json"
}
# Prints the account if cookie, token, account ID and storage all agree; else "MIXED".
login_owner() {
  local A="$1" c t k l
  c=$(sqlite3 "$A/Cookies" "select value from cookies where name='sessionKey'" 2>/dev/null | sed 's/^cookie-//')
  t=$(/usr/bin/python3 -c "import json;print(json.load(open('$A/config.json')).get('oauth:tokenCacheV2','').replace('tok-',''))")
  k=$(/usr/bin/python3 -c "import json;print(json.load(open('$A/config.json')).get('lastKnownAccountUuid',''))")
  l=$(sed 's/^ls-//' "$A/Local Storage/data" 2>/dev/null)
  if [ -n "$c" ] && [ "$c" = "$t" ] && [ "$t" = "$k" ] && [ "$k" = "$l" ]; then echo "$c"; else echo "MIXED($c/$t/$k/$l)"; fi
}
sums() { (cd "$1/claude-code-sessions" && find . -type f -print0 | sort -z | xargs -0 shasum) ; }

for entry in "${STEPS[@]}"; do
  step="${entry%%:*}"; want="${entry##*:}"
  T="$(mktemp -d)"
  export CLAUDE_APP_DIR="$T/app" CLAUDE_SWITCH_HOME="$T/home" CLAUDE_SWITCH_BACKUPS="$T/backups" \
         CLAUDE_SWITCH_TEST=1 CLAUDE_INFO_PLIST="$T/Info.plist" HOME="$T/userhome"
  A="$T/app"; mkdir -p "$A/claude-code-sessions/AAAA/org1" "$A/claude-code-sessions/BBBB/org2" "$HOME"
  /usr/bin/python3 -c "import plistlib;plistlib.dump({'CFBundleShortVersionString':'4.23118.0'},open('$T/Info.plist','wb'))"
  for i in 1 2 3; do echo "{\"sessionId\":\"local_a$i\"}" > "$A/claude-code-sessions/AAAA/org1/local_a$i.json"; done
  echo '{"sessionId":"local_b1"}' > "$A/claude-code-sessions/BBBB/org2/local_b1.json"
  # Save a login for B, then sign in as A.
  login_as "$A" BBBB; "$ENGINE" add >/dev/null; login_as "$A" AAAA
  before="$(sums "$A")"

  echo "crash after: $step"
  CLAUDE_SWITCH_CRASH_AFTER="$step" "$ENGINE" switch BBBB >/dev/null 2>&1; code=$?
  check "engine stopped (exit 137)" '[ $code = 137 ]'
  check "status reports pending recovery" '"$ENGINE" status | grep -q "\"pendingRecovery\": true"'
  check "a new switch is refused" '! "$ENGINE" switch BBBB >/dev/null 2>&1'
  check "auto-save does not run" '"$ENGINE" tick | grep -q "\"done\": \[\]"'
  out="$("$ENGINE" recover)"
  check "recover runs ($(echo "$out" | sed 's/.*"action": "\([^"]*\)".*/\1/'))" 'echo "$out" | grep -q "\"recovered\": true"'
  check "login is complete and on $want" '[ "$(login_owner "$A")" = "$want" ]'
  check "session files unchanged" '[ "$(sums "$A")" = "$before" ]'
  check "journal removed" '[ ! -e "$CLAUDE_SWITCH_HOME/journal.json" ]'
  check "next switch works" '"$ENGINE" switch "$( [ $want = AAAA ] && echo BBBB || echo AAAA )" >/dev/null 2>&1'
  rm -rf "$T"
done

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
