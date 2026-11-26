#!/usr/bin/env bash
# LIVE spike for #59: does the Claude desktop app resume a marked Code tab session by itself?
# Run in Terminal.app, NOT from Claude: it quits Claude.
#
#   tests/spike_resume.sh <session id prefix>     e.g. tests/spike_resume.sh 2c4f7f7b
#
# It sets interruptedByQuitAt on the session's index file in the SIGNED-IN account's folder,
# restarts Claude, and checks the desktop log and the transcript for a new turn.
set -u
inside_claude() {
  local pid=$$ cmd
  while [ "${pid:-0}" -gt 1 ]; do
    cmd="$(ps -o comm= -p "$pid" 2>/dev/null)" || return 1
    case "$cmd" in */Claude.app/*) return 0 ;; esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  return 1
}
if inside_claude; then
  echo "Run this in Terminal.app, not from Claude: a command that runs inside Claude stops Claude from quitting."
  exit 2
fi
SID="${1:?session id prefix, e.g. 2c4f7f7b}"
APP="$HOME/Library/Application Support/Claude"
LOG="$HOME/Library/Logs/Claude/main.log"
ACCT="$(/usr/bin/python3 -I -c "import json,sys; print(json.load(open(sys.argv[1])).get('lastKnownAccountUuid',''))" "$APP/config.json")"
[ -n "$ACCT" ] || { echo "No signed-in account found"; exit 1; }
F="$(ls "$APP"/claude-code-sessions/"$ACCT"/*/local_"$SID"*.json 2>/dev/null | head -1)"
[ -n "$F" ] || { echo "Session $SID is not in the folder of the signed-in account ${ACCT:0:8}"; exit 1; }
echo "Account ${ACCT:0:8}, session file: ${F#$APP/}"

echo "Quitting Claude (if Claude asks, click Cancel and retry when no session is working)..."
osascript -e 'tell application id "com.anthropic.claudefordesktop" to quit' >/dev/null 2>&1
for _ in $(seq 1 90); do pgrep -qf "Claude.app/Contents/MacOS/Claude" || break; sleep 1; done
if pgrep -qf "Claude.app/Contents/MacOS/Claude"; then echo "Claude did not quit. Nothing changed."; exit 1; fi

cp -p "$F" "$F.spike-backup"
START_MS="$(/usr/bin/python3 -I - "$F" <<'EOF'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); now = int(time.time() * 1000)
d["interruptedByQuitAt"] = now
for k in ("interruptedAwaitingPerson", "interruptedUnseenResume"): d.pop(k, None)
json.dump(d, open(p, "w")); print(now)
EOF
)"
CLI="$(/usr/bin/python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['cliSessionId'])" "$F")"
T="$(ls "$HOME"/.claude/projects/*/"$CLI".jsonl 2>/dev/null | head -1)"
LOGLINES="$(wc -l < "$LOG" | tr -d ' ')"
echo "Marked at $START_MS. Opening Claude and waiting up to 3 minutes..."
open -b com.anthropic.claudefordesktop

warmed=""; turn=""
for _ in $(seq 1 36); do
  sleep 5
  [ -z "$warmed" ] && warmed="$(tail -n +"$((LOGLINES + 1))" "$LOG" | grep -m1 'Relaunch auto-resume')"
  turn="$(/usr/bin/python3 -I - "$T" "$START_MS" <<'EOF'
import json, sys, datetime
path, start = sys.argv[1], int(sys.argv[2]) / 1000
for line in open(path, errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("type") != "assistant" or e.get("isApiErrorMessage"): continue
    try: t = datetime.datetime.fromisoformat(e.get("timestamp", "").replace("Z", "+00:00")).timestamp()
    except ValueError: continue
    if t > start: print(e["timestamp"]); break
EOF
)"
  [ -n "$warmed" ] && [ -n "$turn" ] && break
done
echo
echo "Desktop log:   ${warmed:-NO auto-resume line}"
echo "New turn at:   ${turn:-NONE}"
if [ -n "$turn" ]; then echo "SPIKE PASS"; else echo "SPIKE FAIL"; fi
echo "(Backup of the session file: ${F#$APP/}.spike-backup — delete it when done.)"
