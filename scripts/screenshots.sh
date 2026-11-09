#!/usr/bin/env bash
# Render the README screenshots into docs/screenshots with demo data.
# Usage: scripts/screenshots.sh   (then: swift scripts/ocr-check.swift docs/screenshots/*.png)
#
# Safety: the renders run a COPY of the app whose bundled engine is scripts/demo/claude-switch.
# The demo engine prints fixed demo data and touches no files, so no real account shows up.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
DEMO="$ROOT/build/screenshots/Claude Accounts.app"

ARCHS="${ARCHS:-arm64}" "$ROOT/scripts/build.sh" "${VERSION:-1.1.0}" >/dev/null 2>&1
rm -rf "$ROOT/build/screenshots"; mkdir -p "$ROOT/build/screenshots" "$OUT"
cp -R "$ROOT/build/Claude Accounts.app" "$DEMO"
cp "$ROOT/scripts/demo/claude-switch" "$DEMO/Contents/Resources/claude-switch"
codesign --force --deep -s - "$DEMO" 2>/dev/null
# Never render with the real engine: it reads real data.
cmp -s "$ROOT/scripts/demo/claude-switch" "$DEMO/Contents/Resources/claude-switch" \
  || { echo "ERROR: the demo app does not have the demo engine." >&2; exit 1; }

BIN="$DEMO/Contents/MacOS/ClaudeAccounts"
FAKEHOME="$(mktemp -d)"; trap 'rm -rf "$FAKEHOME"' EXIT
render() { HOME="$FAKEHOME" "$BIN" "$@"; }

for mode in light dark; do
  render --render "$OUT/panel-$mode.png" $mode
  render --render-settings accounts "$OUT/settings-accounts-$mode.png" $mode
  render --render-sync "$OUT/sync-preview-$mode.png" $mode
done
render --render-welcome 0 "$OUT/welcome-light.png"

ls -1 "$OUT"/*.png
