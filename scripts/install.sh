#!/usr/bin/env bash
# Run all tests, build for this Mac, and install the build (see install-release.sh).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tests/engine_test.sh" >/dev/null || { echo "Engine tests fail. Run tests/engine_test.sh."; exit 1; }
"$ROOT/tests/crash_test.sh" >/dev/null || { echo "Crash test fails. Run tests/crash_test.sh."; exit 1; }
"$ROOT/tests/sync_property_test.py" 50 >/dev/null || { echo "Sync property test fails. Run tests/sync_property_test.py."; exit 1; }
swift run --package-path "$ROOT" CoreTests >/dev/null || { echo "Core tests fail. Run: swift run CoreTests"; exit 1; }
ARCHS="${ARCHS:-$(uname -m)}" "$ROOT/scripts/build.sh" "$@"
"$ROOT/scripts/install-release.sh" --app "$ROOT/build/Claude Accounts.app"
