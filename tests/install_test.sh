#!/usr/bin/env bash
# Tests for scripts/install-release.sh and `claude-switch uninstall` in a fake HOME,
# with fake gh, pkill, launchctl and osascript.
# Needs a build: scripts/build.sh (ARCHS=arm64 is enough).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Claude Accounts.app"
[ -d "$APP" ] || { echo "Build first: scripts/build.sh"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/rel"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }
# Fakes log every call. The uninstall test checks that the engine calls none of them in test mode.
for c in pkill launchctl osascript; do printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$T/called" > "$T/bin/$c"; done
cat > "$T/bin/gh" <<GH
#!/bin/sh
for a; do case "\$prev" in --dir) d="\$a";; esac; prev="\$a"; done
cp "$T/rel/"* "\$d/"
GH
chmod +x "$T/bin/"*
run() { HOME="$T/home" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/scripts/install-release.sh" --no-open "$@" >"$T/out" 2>&1; }
H="$T/home"

echo "local build"
run --app "$APP"
check "app installed" '[ -x "$H/Applications/Claude Accounts.app/Contents/MacOS/ClaudeAccounts" ]'
check "CLI linked" '[ -L "$H/.local/bin/claude-accounts" ] && [ -L "$H/.local/bin/claude-switch" ]'
check "login item written" 'plutil -lint "$H/Library/LaunchAgents/local.claude-accounts.plist" >/dev/null'
check "not an app is refused" '! run --app /nonexistent'

echo "quarantined app (browser download, unzipped by Finder)"
rm -rf "$H"; mkdir -p "$T/q"; cp -R "$APP" "$T/q/"
find "$T/q/Claude Accounts.app" -print0 | xargs -0 xattr -w com.apple.quarantine "0081;00000000;Safari;"
run --app "$T/q/Claude Accounts.app"
check "quarantine flag removed from every file" '! find "$H/Applications/Claude Accounts.app" -print0 | xargs -0 xattr | grep -q quarantine'

echo "download"
rm -rf "$H"
ditto -c -k --keepParent "$APP" "$T/rel/Claude-Accounts-v9.9.9.zip"
(cd "$T/rel" && shasum -a 256 Claude-Accounts-v9.9.9.zip > Claude-Accounts-v9.9.9.zip.sha256)
run
check "good download installs" '[ -x "$H/Applications/Claude Accounts.app/Contents/MacOS/ClaudeAccounts" ]'

rm -rf "$H"; printf x >> "$T/rel/Claude-Accounts-v9.9.9.zip"
run; code=$?
check "damaged download stops" '[ $code != 0 ] && grep -q "Checksum does not match" "$T/out"'
check "damaged download installs nothing" '[ ! -e "$H/Applications/Claude Accounts.app" ]'

echo "uninstall"
rm -rf "$H" "$T/called"
run --app "$APP"
# Use this checkout's engine, also when the build is older.
cp "$ROOT/engine/claude-switch" "$H/Applications/Claude Accounts.app/Contents/Resources/claude-switch"
DATA="$H/Library/Application Support/Claude Account Switcher"
ACC=aaaa1111-0000-0000-0000-000000000000
mkdir -p "$DATA/profiles/$ACC" "$H/Backups/claude-sessions/2026-01-01"
echo '{}' > "$DATA/profiles/$ACC/meta.json"
echo '{}' > "$H/Backups/claude-sessions/2026-01-01/local_a1.json"
rm -f "$T/called"
uninstall() { # [command prefix...]: run the installed CLI link in test mode
  "$@" env HOME="$H" CLAUDE_SWITCH_TEST=1 CLAUDE_INFO_PLIST="$T/none.plist" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$H/.local/bin/claude-switch" uninstall >"$T/out" 2>&1; }
hold_lock() { /usr/bin/python3 -c "import fcntl,subprocess,sys;f=open(sys.argv[1],'w');fcntl.flock(f,fcntl.LOCK_EX);sys.exit(subprocess.call(sys.argv[2:]))" "$DATA/lock" "$@"; }
uninstall hold_lock; code=$?
check "refused while a switch runs" '[ $code != 0 ] && grep -q "Another switch is running" "$T/out"'
check "refused uninstall keeps the app" '[ -x "$H/Applications/Claude Accounts.app/Contents/MacOS/ClaudeAccounts" ] && [ -L "$H/.local/bin/claude-switch" ]'
uninstall; code=$?
check "uninstall succeeds" '[ $code = 0 ]'
check "no app" '[ ! -e "$H/Applications/Claude Accounts.app" ]'
check "app is in the Trash" '[ -d "$H/.Trash/Claude Accounts.app" ]'
check "no LaunchAgent" '[ ! -e "$H/Library/LaunchAgents/local.claude-accounts.plist" ]'
check "no CLI links" '[ ! -L "$H/.local/bin/claude-switch" ] && [ ! -L "$H/.local/bin/claude-accounts" ]'
check "data folder remains" '[ -f "$DATA/profiles/$ACC/meta.json" ]'
check "backups remain" '[ -f "$H/Backups/claude-sessions/2026-01-01/local_a1.json" ]'
check "prints where data and backups are" 'grep -qF "\"data\": \"$DATA\"" "$T/out" && grep -qF "\"backups\": \"$H/Backups/claude-sessions\"" "$T/out"'
check "stops login item and app through the test stub" 'grep -qE "\"stubbed\": \[\"launchctl bootout gui/[0-9]+/local.claude-accounts\", \"pkill -x ClaudeAccounts\"\]" "$T/out"'
check "no real launchctl, pkill or osascript call" '[ ! -e "$T/called" ]'

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
