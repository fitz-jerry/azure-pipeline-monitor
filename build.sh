#!/bin/bash
# Builds AzurePipelinesMonitor.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=AzurePipelinesMonitor
BUILD=build

rm -rf "$BUILD/$APP.app"
mkdir -p "$BUILD/$APP.app/Contents/MacOS" "$BUILD/$APP.app/Contents/Resources"

swiftc -O Sources/*.swift -o "$BUILD/$APP.app/Contents/MacOS/$APP"
cp Info.plist "$BUILD/$APP.app/Contents/Info.plist"
cp Icon/AppIcon.icns "$BUILD/$APP.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$BUILD/$APP.app"

rm -rf "/Applications/$APP.app"
cp -R "$BUILD/$APP.app" "/Applications/$APP.app"
echo "Installed: /Applications/$APP.app"
