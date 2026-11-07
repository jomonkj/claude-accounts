#!/usr/bin/env bash
# Build, install to ~/Applications, link the CLI, start at login, and open the app.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/Claude Accounts.app"
RES="$DEST/Contents/Resources/claude-switch"

"$ROOT/tests/engine_test.sh" >/dev/null || { echo "Engine tests fail. Run tests/engine_test.sh."; exit 1; }
"$ROOT/scripts/build.sh" "$@"

pkill -x ClaudeAccounts 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"; cp -R "$ROOT/build/Claude Accounts.app" "$DEST"

# One CLI, two names. `claude-accounts` prints the table.
ln -sf "$RES" "$HOME/.local/bin/claude-switch"
ln -sf "$RES" "$HOME/.local/bin/claude-accounts"

/usr/bin/python3 - "$HOME/Library/LaunchAgents/local.claude-accounts.plist" "$DEST/Contents/MacOS/ClaudeAccounts" <<'EOF'
import plistlib, sys
plistlib.dump({"Label": "local.claude-accounts", "ProgramArguments": [sys.argv[2]], "RunAtLoad": True,
               "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"}, open(sys.argv[1], "wb"))
EOF
open "$DEST"
echo "Installed $DEST"
