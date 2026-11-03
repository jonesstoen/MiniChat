#!/bin/bash
# Builds Mini Chat.app. Usage: bash build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Mini Chat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MiniChat "$APP/Contents/MacOS/MiniChat"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MiniChat 2>/dev/null || true
    rm -rf "/Applications/Mini Chat.app"
    cp -R "$APP" /Applications/
    touch "/Applications/Mini Chat.app"
    killall Dock 2>/dev/null || true   # refreshes the Dock icon
    sleep 1
    open "/Applications/Mini Chat.app"
    echo "Installed to /Applications and launched."
fi
