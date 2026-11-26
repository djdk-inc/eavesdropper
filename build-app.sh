#!/bin/bash
# Builds Eavesdropper.app from this repo alone.
#  - Hermetic: the build runs with network access denied (sandbox-exec), and every input is in
#    the repo (sources, Vendor/, Models/) or the pinned toolchain (.swift-toolchain).
#  - Versioned: VERSION + git commit count + commit hash are stamped into Info.plist.
#  - Isolated: the recorder is signed with Eavesdropper.entitlements (App Sandbox, no network);
#    the calendar helper is a separate app inside it.
set -euo pipefail
cd "$(dirname "$0")"

expected="$(cat .swift-toolchain)"
actual="$(swift --version 2>/dev/null | grep -o 'Apple Swift version.*' || true)"
if [ "$actual" != "$expected" ] && [ -z "${ALLOW_TOOLCHAIN_MISMATCH:-}" ]; then
    echo "toolchain mismatch: want '$expected', have '$actual' (set ALLOW_TOOLCHAIN_MISMATCH=1 to override)" >&2
    exit 1
fi

version="$(cat VERSION)"
build="$(git rev-list --count HEAD)"
commit="$(git rev-parse --short=12 HEAD)"
git diff --quiet HEAD -- . || commit="$commit-dirty"
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)" LC_ALL=C TZ=UTC ZERO_AR_DATE=1

# SwiftPM's own sandbox is off because it cannot nest inside this one (which also denies network).
scratch="${SCRATCH:-.build-release}"
sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))' \
    swift build -c release --build-system native --scratch-path "$scratch" --disable-automatic-resolution --disable-sandbox

app="${APP:-dist/Eavesdropper.app}"
helper="$app/Contents/Helpers/Eavesdropper Calendar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$helper/Contents/MacOS"
cp "$scratch/release/Eavesdropper" "$app/Contents/MacOS/Eavesdropper"
cp -R Models "$app/Contents/Resources/DiarizerModels"
cp "$scratch/release/EavesdropperCalendar" "$helper/Contents/MacOS/EavesdropperCalendar"

plist() { # bundle-id name executable extra-keys
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$1</string>
    <key>CFBundleName</key><string>$2</string>
    <key>CFBundleExecutable</key><string>$3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>EavesdropperCommit</key><string>$commit</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
$4
</dict>
</plist>
PLIST
}
plist com.djdk.eavesdropper Eavesdropper Eavesdropper '    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Eavesdropper records your side of Zoom and Meet calls.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Eavesdropper records the sound of Zoom and Meet calls.</string>
    <key>NSAppleEventsUsageDescription</key><string>Eavesdropper checks your browser tabs for a Meet or Zoom meeting.</string>' \
    > "$app/Contents/Info.plist"
plist com.djdk.eavesdropper.calendar "Eavesdropper Calendar" EavesdropperCalendar '    <key>LSBackgroundOnly</key><true/>' \
    > "$helper/Contents/Info.plist"

# Stable identity keeps macOS privacy grants across rebuilds (./build.sh creates it); ad-hoc otherwise.
sign_id="${CODESIGN_IDENTITY:-DJDK Local Code Signing}"
security find-certificate -c "$sign_id" >/dev/null 2>&1 || { echo "warning: no \"$sign_id\" signing identity; ad-hoc signing, so macOS asks for permissions again" >&2; sign_id=-; }
codesign --force --sign "$sign_id" --timestamp=none "$helper"
codesign --force --sign "$sign_id" --timestamp=none --entitlements Eavesdropper.entitlements "$app"
echo "built $(pwd)/$app — Eavesdropper $version (build $build, $commit)"
