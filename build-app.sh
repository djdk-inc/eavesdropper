#!/bin/bash
# Builds Eavesdropper.app (ad-hoc signed) next to this script.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native --scratch-path .build2
app=Eavesdropper.app
mkdir -p "$app/Contents/MacOS"
cp .build2/release/Eavesdropper "$app/Contents/MacOS/Eavesdropper"

# Bundle the speaker-diarization model so the app never downloads it (fetched once into .models/).
models=.models/DiarizerModels
[ -d "$models" ] || .build2/release/Eavesdropper --fetch-diarizer-models "$models"
mkdir -p "$app/Contents/Resources"
rm -rf "$app/Contents/Resources/DiarizerModels"
cp -R "$models" "$app/Contents/Resources/DiarizerModels"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.djdk.eavesdropper</string>
    <key>CFBundleName</key><string>Eavesdropper</string>
    <key>CFBundleExecutable</key><string>Eavesdropper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Eavesdropper records your side of Zoom and Meet calls.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Eavesdropper records the sound of Zoom and Meet calls.</string>
    <key>NSAppleEventsUsageDescription</key><string>Eavesdropper checks your browser tabs for a Meet or Zoom meeting.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$app"
echo "built $(pwd)/$app"
