#!/bin/bash
# Создание установочного DMG для AirMonitor
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AirMonitor"
VERSION="0.2.0"
STAGE="dist/dmg_stage"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

# Сначала собрать .app, если нет
if [ ! -d "dist/$APP_NAME.app" ]; then
    ./Tools/build_app.sh
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "dist/$APP_NAME.app" "$STAGE/"

# Симлинк на /Applications для удобной установки
ln -s /Applications "$STAGE/"

rm -f "$DMG"
hdiutil create -volname "AirMonitor" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> Готово: $DMG"
