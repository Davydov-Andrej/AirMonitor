#!/bin/bash
# Сборка AirMonitor в .app bundle (для локального запуска и дистрибуции)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AirMonitor"
BIN=".build/release/air-monitor"
APP_VERSION="$(tr -d '\r\n' < VERSION)"
APP_BUILD="$APP_VERSION"

echo "==> Сборка (release)..."
swift build -c release --product air-monitor --disable-sandbox

APP_BUNDLE="dist/$APP_NAME.app"
# Обновляем бандл НА МЕСТЕ (не пересоздавая): TCC привязывает mic-разрешение
# к adhoc-подписи, а её cdhash меняется при каждой новой сборке. Если удалять
# и создавать бандл заново, macOS считает это новым приложением и сбрасывает
# разрешение на микрофон.
if [ ! -d "$APP_BUNDLE" ]; then
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"
fi
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/AirMonitor_black.png "$APP_BUNDLE/Contents/Resources/AirMonitor_black.png"
cp Resources/AirMonitor_white.png "$APP_BUNDLE/Contents/Resources/AirMonitor_white.png"
mkdir -p "$APP_BUNDLE/Contents/Resources/en.lproj"
cp Resources/en.lproj/Localizable.strings "$APP_BUNDLE/Contents/Resources/en.lproj/Localizable.strings"
SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP_BUNDLE/Contents/Resources/Sparkle-LICENSE.txt"
UPDATE_PUBLIC_KEY="$(tr -d '\r\n' < Resources/UpdatePublicKey.txt)"

ICONSET="$APP_BUNDLE/Contents/Resources/AirMonitor.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# ICNS is the compatibility icon used by Finder on this hand-built bundle.
# Use the dark artwork so the Applications folder icon remains legible on dark
# macOS. The running Dock icon selects the matching PNG at runtime.
ICON_SOURCE="$APP_BUNDLE/Contents/Resources/AirMonitor_black.png"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
python3 Tools/iconset_to_icns.py "$ICONSET" "$APP_BUNDLE/Contents/Resources/AirMonitor.icns"
rm -rf "$ICONSET"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.airmonitor.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AirMonitor.icns</string>
    <key>CFBundleDisplayName</key>
    <string>AirMonitor</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleLocalizations</key>
    <array><string>ru</string><string>en</string></array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>AirMonitor анализирует звук с выбранного входного аудиоустройства (USB-микшер, аудиоинтерфейс, виртуальная карта).</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/Davydov-Andrej/AirMonitor/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>$UPDATE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
</dict>
</plist>
PLIST

# Keep the standard package type/creator marker alongside Info.plist. Some
# Launch Services paths rely on complete bundle metadata when refreshing an
# app that is updated in place.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Adhoc-подпись со СТАБИЛЬНЫМ designated requirement (identifier-based):
# TCC привязывает mic-разрешение к подписи. Дефолтный adhoc DR = конкретный
# cdhash (меняется каждый билд) -> macOS считал приложение "новым" и сбрасывал
# разрешение. Identifier-based DR переживает любые пересборки.
codesign --force --sign - \
    --identifier com.airmonitor.app \
    --requirements '=designated => identifier "com.airmonitor.app"' \
    "$APP_BUNDLE" >/dev/null

echo "==> Готово: $APP_BUNDLE"
echo "    (бандл обновлён на месте — mic-разрешение TCC сохраняется)"
