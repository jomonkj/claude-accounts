#!/usr/bin/env bash
# Tests for scripts/install-release.sh in a fake HOME, with fake gh and pkill.
# Needs a build: scripts/build.sh (ARCHS=arm64 is enough).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Claude Accounts.app"
[ -d "$APP" ] || { echo "Build first: scripts/build.sh"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/rel"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pkill"
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

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
