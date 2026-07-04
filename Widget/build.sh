#!/bin/bash
# Builds AzurePipelinesWidget.app (host app + WidgetKit extension) and
# installs it to /Applications. Requires full Xcode.
#
# The build runs from a local temp copy of the sources: this folder lives in
# OneDrive, whose sync metadata (extended attributes) makes codesign fail with
# "resource fork, Finder information, or similar detritus not allowed".
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/AzurePipelinesWidget.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
rsync -a --exclude build --exclude '*.xcodeproj' ./ "$WORK/"
cd "$WORK"
xattr -cr .

xcodegen generate
xcodebuild -project AzurePipelinesWidget.xcodeproj \
    -scheme AzurePipelinesWidget \
    -configuration Release \
    -derivedDataPath build \
    build

rm -rf /Applications/AzurePipelinesWidget.app
cp -R build/Build/Products/Release/AzurePipelinesWidget.app /Applications/
echo "Installed: /Applications/AzurePipelinesWidget.app"
