#!/bin/bash
# Собирает красивый DMG: фон со стрелкой, крупные иконки, app слева + Applications справа.
# Использует dist/Vaqlo.app (уже подписанный) и Resources/dmg_background.png.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Vaqlo.app"
VOL="Vaqlo"
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/Vaqlo-${VER}.dmg"

[[ -d "$APP" ]] || { echo "Нет $APP — сначала соберите приложение"; exit 1; }
[[ -f "Resources/dmg_background.png" ]] || { echo "Нет фона — запустите scripts/dmg_background.swift"; exit 1; }

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Vaqlo.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/dmg_background.png "$STAGE/.background/background.png"

RW="$(mktemp -u).dmg"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null

hdiutil detach "/Volumes/$VOL" 2>/dev/null || true
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 2

# Раскладка окна (требует разрешения «Автоматизация → Finder»; при отказе DMG соберётся без стилей).
osascript <<EOF || echo "WARN: не удалось применить стиль окна (нет доступа к автоматизации Finder)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 540}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 112
    set background picture of vo to file ".background:background.png"
    set position of item "Vaqlo.app" of container window to {165, 205}
    set position of item "Applications" of container window to {495, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync; sleep 1
hdiutil detach "$DEV" >/dev/null || hdiutil detach "$DEV" -force >/dev/null
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"
echo "OK: $DMG"
