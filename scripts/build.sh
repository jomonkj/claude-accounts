#!/usr/bin/env bash
# Build "Claude Accounts.app" into ./build. Usage: scripts/build.sh [version]
# ARCHS="arm64 x86_64" (default) builds a universal binary; ARCHS=arm64 builds a fast local one.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(git -C "$ROOT" describe --tags --always 2>/dev/null | sed 's/^v//' || echo dev)}"
APP="$ROOT/build/Claude Accounts.app"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build"
ARCHS="${ARCHS:-arm64 x86_64}"
bins=()
for a in $ARCHS; do
  swift build -c release --arch "$a" --product ClaudeAccounts --package-path "$ROOT" >&2
  bins+=("$(swift build -c release --arch "$a" --package-path "$ROOT" --show-bin-path)/ClaudeAccounts")
done
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/ClaudeAccounts"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/ClaudeAccounts")"
cp "$ROOT/engine/claude-switch" "$APP/Contents/Resources/claude-switch"

swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ROOT/build/AppIcon.iconset"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Accounts</string>
  <key>CFBundleDisplayName</key><string>Claude Accounts</string>
  <key>CFBundleIdentifier</key><string>local.claude-accounts</string>
  <key>CFBundleExecutable</key><string>ClaudeAccounts</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep -s - "$APP" 2>/dev/null
echo "Built $APP ($VERSION)"
