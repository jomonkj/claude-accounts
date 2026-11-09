#!/usr/bin/env bash
# Tests scripts/ocr-check.swift on PNGs with known text.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# Draw lines of text into a PNG.
cat > "$T/draw.swift" <<'EOF'
import AppKit
let a = CommandLine.arguments
let lines = a[2...].joined(separator: "\n") as NSString
let size = NSSize(width: 900, height: 60 + 50 * a.count)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
lines.draw(at: NSPoint(x: 20, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
EOF
swiftc -O -o "$T/draw" "$T/draw.swift" 2>/dev/null || { echo "cannot build the drawing helper"; exit 1; }
swiftc -O -o "$T/ocr" "$ROOT/scripts/ocr-check.swift" 2>/dev/null || { echo "FAIL: ocr-check.swift does not build"; exit 1; }

"$T/draw" "$T/demo.png" "alex@example.com" "Sync 23 sessions"
"$T/draw" "$T/gmail.png" "someone@gmail.com" "alex@example.com"
"$T/draw" "$T/other.png" "pat@company.org signed in"

# 1. Demo text: passes, prints the text, finds the expected names.
out=$("$T/ocr" --expect alex@example.com "$T/demo.png" 2>&1); rc=$?
[ $rc -eq 0 ] && ok || bad "demo image should pass (rc=$rc): $out"
echo "$out" | grep -q "Sync 23 sessions" && ok || bad "prints the text found: $out"

# 2. A non-demo email fails.
"$T/ocr" --expect alex@example.com "$T/gmail.png" >/dev/null 2>&1 && bad "gmail email should fail" || ok
"$T/ocr" "$T/other.png" >/dev/null 2>&1 && bad "a non-example.com email should fail" || ok

# 3. An expected name that is not in any image fails (proves OCR read something).
"$T/ocr" --expect sam@example.com "$T/demo.png" >/dev/null 2>&1 && bad "missing expected name should fail" || ok

# 4. --deny adds a pattern (for private words that must not be in the repo).
"$T/ocr" --deny 'Sync 2[0-9]' "$T/demo.png" >/dev/null 2>&1 && bad "--deny match should fail" || ok
out=$("$T/ocr" --deny 'Sync 2[0-9]' "$T/demo.png" 2>&1)
echo "$out" | grep -q "DENIED" && ok || bad "a denied line is reported: $out"

# 5. Several files: the expected name may be in any one of them.
"$T/ocr" --expect alex@example.com --expect "pat" "$T/demo.png" "$T/other.png" --allow-domain company.org >/dev/null 2>&1 && ok || bad "expect across files, --allow-domain"

echo "ocr_check_test: $pass passed, $fail failed"
[ $fail -eq 0 ]
