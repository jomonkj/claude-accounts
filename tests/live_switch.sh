#!/usr/bin/env bash
# LIVE test on the real Claude app. It quits and reopens Claude several times,
# so finish your work in Claude first, and run it from Terminal (not from Claude).
#
#   tests/live_switch.sh <account A> <account B> [rounds]     e.g. 59f2e10c 6bd8db16 3
#
# Pass: every verify is ok, Claude ends on A, and no session file is lost.
set -u
# Refuse only when a parent process is Claude.app. Do not trust CLAUDECODE:
# a Terminal.app window that Claude opened inherits it.
inside_claude() {
  local pid=$$ cmd
  while [ "${pid:-0}" -gt 1 ]; do
    cmd="$(ps -o comm= -p "$pid" 2>/dev/null)" || return 1
    case "$cmd" in */Claude.app/*) return 0 ;; esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  return 1
}
if [ -z "${LIVE_TEST_FORCE:-}" ] && inside_claude; then
  echo "Run this in Terminal.app, not from Claude: a command that runs inside Claude stops Claude from quitting."
  exit 2
fi
ENGINE="${ENGINE:-$HOME/.local/bin/claude-switch}"
A="${1:?account A}"; B="${2:?account B}"; ROUNDS="${3:-3}"
SESS="$HOME/Library/Application Support/Claude/claude-code-sessions"
count() { find "$SESS" -name 'local_*.json' | wc -l | tr -d ' '; }
names() { find "$SESS" -name 'local_*.json' | sort; }
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

echo "This quits and reopens Claude $((ROUNDS * 2)) times. Ctrl-C now to stop."; sleep 5
before_n="$(count)"; before="$(names)"
start="$("$ENGINE" status | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["current"][:8])')"
[ "$start" = "${A:0:8}" ] || { echo "Claude must be on $A now (it is on $start). Switch to it first."; exit 1; }

for r in $(seq 1 "$ROUNDS"); do
  for target in "$B" "$A"; do
    t0=$(date +%s)
    out="$("$ENGINE" switch "$target" 2>&1)"
    check "round $r: switch to $target" 'echo "$out" | grep -q "\"ok\": true"'
    v="$("$ENGINE" verify "$target" 2>&1)"
    check "round $r: verify $target ($(( $(date +%s) - t0 )) s)" 'echo "$v" | grep -q "\"ok\": true"'
  done
done

after_n="$(count)"
check "ends on $A" '"$ENGINE" status | grep -q "\"current\": \"${A:0:8}"'
check "no session file lost ($before_n before, $after_n after)" '[ -z "$(comm -23 <(echo "$before") <(names))" ]'
check "no unfinished switch" '"$ENGINE" status | grep -q "\"pendingRecovery\": false"'
echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
