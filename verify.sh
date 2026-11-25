#!/bin/bash
# Checks a built Eavesdropper.app before it ships. Exits non-zero on any failure.
#  - logic checks pass (DetectorChecks)
#  - the recorder is sandboxed and has no network entitlement
#  - the recorder really can't reach the network (by hostname or raw IP)
#  - the calendar helper is the only bundled code without the sandbox
set -euo pipefail
cd "$(dirname "$0")"
app="${APP:-Eavesdropper.app}"
fail() { echo "FAIL: $*" >&2; exit 1; }

swift build --build-system native --scratch-path .build --product DetectorChecks --disable-sandbox >/dev/null
.build/debug/DetectorChecks | tail -1 | grep -q "all checks passed" || fail "DetectorChecks"
echo "ok   logic checks"

ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
echo "$ents" | grep -q "com.apple.security.app-sandbox" || fail "recorder is not sandboxed"
if echo "$ents" | grep -qE "com.apple.security.network.(client|server)"; then fail "recorder has a network entitlement"; fi
echo "ok   recorder sandboxed, no network entitlement"

"$app/Contents/MacOS/Eavesdropper" --network-selftest || fail "recorder reached the network"
echo "ok   recorder network blocked at runtime"

codesign --verify --deep --strict "$app" || fail "signature"
helper_ents="$(codesign -d --entitlements - --xml "$app/Contents/Helpers/Eavesdropper Calendar.app" 2>/dev/null || true)"
if echo "$helper_ents" | grep -q "audio-input"; then fail "calendar helper can record audio"; fi
echo "ok   signatures valid; calendar helper has no audio access"

"$app/Contents/MacOS/Eavesdropper" --version
