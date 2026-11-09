#!/usr/bin/env bash
# Install Claude Accounts for one user.
#
# From the latest GitHub Release (no sign-in, no gh needed):
#   curl -fsSL https://github.com/jomonkj/claude-accounts/releases/latest/download/install-release.sh | bash
# A given release:       ... | bash -s -- --tag v1.0.0
# A local build:         scripts/install-release.sh --app "build/Claude Accounts.app"
#
# It gets the release from the public GitHub API with curl (gh only as a fallback), checks
# the sha256 of the download, installs the app to ~/Applications, removes the quarantine
# flag (the app is not notarized), links the CLI into ~/.local/bin, adds the login item,
# and opens the app.
set -euo pipefail
REPO="${CLAUDE_ACCOUNTS_REPO:-jomonkj/claude-accounts}"
# Test seam: tests point CLAUDE_ACCOUNTS_API to a file:// folder.
API="${CLAUDE_ACCOUNTS_API:-https://api.github.com}"; API="${API%/}"
PROTO="=https"; case "$API" in file://*) PROTO="=https,file" ;; esac
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

fetch() { /usr/bin/curl -fsSL --proto "$PROTO" --proto-redir =https --retry 2 --max-time 300 "$@"; }

# Prints the download URL of the first asset whose name matches the regex.
asset_url() { # <release.json> <name regex>
  /usr/bin/python3 -c 'import json, re, sys
for a in json.load(open(sys.argv[1])).get("assets", []):
    if re.fullmatch(sys.argv[2], a.get("name", "")):
        print(a["browser_download_url"]); break' "$1" "$2"
}

download_curl() {
  local rel="releases/latest" zip sha
  [ -z "$TAG" ] || rel="releases/tags/$TAG"
  fetch -H "Accept: application/vnd.github+json" -o "$WORK/release.json" "$API/repos/$REPO/$rel" || return 1
  zip="$(asset_url "$WORK/release.json" 'Claude-Accounts-.*\.zip')" || return 1
  sha="$(asset_url "$WORK/release.json" 'Claude-Accounts-.*\.zip\.sha256')" || return 1
  [ -n "$zip" ] && [ -n "$sha" ] || { echo "The release has no app zip." >&2; return 1; }
  fetch -o "$WORK/${zip##*/}" "$zip" && fetch -o "$WORK/${sha##*/}" "$sha"
}

if [ -z "$APP_SRC" ]; then
  echo "Downloading ${TAG:-the latest release} of ${REPO}..."
  if ! download_curl; then
    command -v gh >/dev/null || { echo "Cannot download the release. Check the network and try again." >&2; exit 1; }
    echo "curl failed. Trying gh..." >&2
    rm -f "$WORK"/Claude-Accounts-*
    gh release download ${TAG:+"$TAG"} --repo "$REPO" --pattern 'Claude-Accounts-*.zip*' --dir "$WORK"
  fi
  for ZIP in "$WORK"/Claude-Accounts-*.zip; do break; done
  (cd "$WORK" && shasum -a 256 -c "$(basename "$ZIP").sha256") || { echo "Checksum does not match. Stopped." >&2; exit 1; }
  ditto -x -k "$ZIP" "$WORK/unzipped"
  APP_SRC="$WORK/unzipped/Claude Accounts.app"
fi
[ -x "$APP_SRC/Contents/MacOS/ClaudeAccounts" ] || { echo "Not an app bundle: $APP_SRC" >&2; exit 1; }

pkill -x ClaudeAccounts 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
# Not notarized: remove the quarantine flag from every file (this xattr has no -r).
find "$DEST" -print0 | xargs -0 xattr -d com.apple.quarantine 2>/dev/null || true
if find "$DEST" -print0 | xargs -0 xattr 2>/dev/null | grep -q com.apple.quarantine; then
  echo "Could not remove the quarantine flag. The first time, right-click the app -> Open." >&2
fi

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
