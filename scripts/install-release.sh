#!/usr/bin/env bash
# Install Claude Accounts for one user.
#
# From the latest GitHub Release (needs `gh` signed in with access to the repo):
#   gh release download --repo jomonkj/claude-accounts --pattern install-release.sh --output - | bash
# A given release:       ... | bash -s -- --tag v1.0.0
# A local build:         scripts/install-release.sh --app "build/Claude Accounts.app"
#
# It checks the sha256 of the download, installs the app to ~/Applications, removes the
# quarantine flag (the app is not notarized), links the CLI into ~/.local/bin, adds the
# login item, and opens the app.
set -euo pipefail
REPO="${CLAUDE_ACCOUNTS_REPO:-jomonkj/claude-accounts}"
DEST="$HOME/Applications/Claude Accounts.app"
TAG="" APP_SRC="" NO_OPEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --app) APP_SRC="$2"; shift 2 ;;
    --no-open) NO_OPEN=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -z "$APP_SRC" ]; then
  command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh, then gh auth login." >&2; exit 1; }
  echo "Downloading ${TAG:-the latest release} of ${REPO}..."
  gh release download ${TAG:+"$TAG"} --repo "$REPO" --pattern 'Claude-Accounts-*.zip*' --dir "$WORK"
  ZIP="$(ls "$WORK"/Claude-Accounts-*.zip | head -1)"
  (cd "$WORK" && shasum -a 256 -c "$(basename "$ZIP").sha256") || { echo "Checksum does not match. Stopped." >&2; exit 1; }
  ditto -x -k "$ZIP" "$WORK/unzipped"
  APP_SRC="$WORK/unzipped/Claude Accounts.app"
fi
[ -x "$APP_SRC/Contents/MacOS/ClaudeAccounts" ] || { echo "Not an app bundle: $APP_SRC" >&2; exit 1; }

pkill -x ClaudeAccounts 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

RES="$DEST/Contents/Resources/claude-switch"
ln -sf "$RES" "$HOME/.local/bin/claude-switch"
ln -sf "$RES" "$HOME/.local/bin/claude-accounts"

/usr/bin/python3 - "$HOME/Library/LaunchAgents/local.claude-accounts.plist" "$DEST/Contents/MacOS/ClaudeAccounts" <<'EOF'
import plistlib, sys
plistlib.dump({"Label": "local.claude-accounts", "ProgramArguments": [sys.argv[2]], "RunAtLoad": True,
               "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"}, open(sys.argv[1], "wb"))
EOF

VERSION="$(/usr/bin/defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
[ -n "$NO_OPEN" ] || open "$DEST"
echo "Installed Claude Accounts $VERSION in $DEST"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add ~/.local/bin to PATH to use claude-accounts in Terminal." ;; esac
