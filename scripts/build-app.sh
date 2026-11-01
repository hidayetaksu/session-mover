#!/bin/bash
# Builds build/SessionMover.app from the SwiftPM package.
# Version: the VERSION file (or SM_VERSION). Signs ad hoc, for local use, unless SM_NO_SIGN=1 (release.sh signs it itself).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${SM_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${SM_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/SessionMover.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SessionMover" "$APP/Contents/MacOS/SessionMover"
# The version list is data (FormatGuard reads it from Contents/Resources).
cp Sources/SessionMoverKit/Resources/verified-versions.json "$APP/Contents/Resources/verified-versions.json"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ai.gosmart.sessionmover</string>
    <key>CFBundleName</key><string>Session Mover</string>
    <key>CFBundleDisplayName</key><string>Session Mover</string>
    <key>CFBundleExecutable</key><string>SessionMover</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>Session Mover asks a copy of Claude to quit before it moves that copy's sessions, then reopens it.</string>
</dict>
</plist>
PLIST

if [ "${SM_NO_SIGN:-0}" = "1" ]; then
    echo "Built $APP $VERSION (unsigned)"
else
    codesign --force --sign - --timestamp=none "$APP"
    codesign --verify --verbose=1 "$APP"
    echo "Built $APP $VERSION (ad hoc signed)"
fi
