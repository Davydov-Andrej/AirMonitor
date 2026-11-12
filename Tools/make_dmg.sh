#!/bin/bash
# Создание установочного DMG для AirMonitor
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AirMonitor"
VERSION="$(tr -d '\r\n' < VERSION)"
STAGE="dist/.${APP_NAME}-dmg-stage"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
INTEL_BIN=".build/x86_64-apple-macosx/release/air-monitor"

# Always include the current release build, not a possibly stale .app bundle.
./Tools/build_app.sh
swift build -c release --product air-monitor --disable-sandbox --triple x86_64-apple-macosx14.0

rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
cp -R "dist/$APP_NAME.app" "$STAGE/"

# Ship one universal app so the same DMG works on Apple Silicon and Intel Macs.
lipo -create \
    "dist/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    "$INTEL_BIN" \
    -output "$STAGE/$APP_NAME.universal"
mv "$STAGE/$APP_NAME.universal" "$STAGE/$APP_NAME.app/Contents/MacOS/$APP_NAME"
codesign --force --sign - \
    --identifier com.airmonitor.app \
    --requirements '=designated => identifier "com.airmonitor.app"' \
    "$STAGE/$APP_NAME.app" >/dev/null
codesign --verify --deep --strict "$STAGE/$APP_NAME.app"
lipo "$STAGE/$APP_NAME.app/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64

# Симлинк на /Applications для удобной установки
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "AirMonitor" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

rm -rf "$STAGE"
trap - EXIT
echo "==> Готово: $DMG"

# Prepare local release assets. Publishing to GitHub is a separate explicit step.
UPDATE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/AirMonitor-updates.XXXXXX")"
trap 'rm -rf "$UPDATE_STAGE"' EXIT
cp "$DMG" "$UPDATE_STAGE/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account com.airmonitor.app \
    --download-url-prefix "https://github.com/Davydov-Andrej/AirMonitor/releases/download/v${VERSION}/" \
    --link "https://github.com/Davydov-Andrej/AirMonitor/releases/tag/v${VERSION}" \
    --maximum-deltas 0 \
    "$UPDATE_STAGE"
cp "$UPDATE_STAGE/appcast.xml" dist/appcast.xml
rm -rf "$UPDATE_STAGE"
trap - EXIT
echo "==> Подписанный канал обновлений: dist/appcast.xml"
