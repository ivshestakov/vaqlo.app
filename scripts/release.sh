#!/bin/bash
# Релизная сборка Vaqlo: Developer ID + hardened runtime + нотаризация + DMG.
#
# Разовая настройка учётки нотаризации (создаёт keychain-профиль "vaqlo-notary"):
#   xcrun notarytool store-credentials vaqlo-notary \
#       --apple-id "you@apple.id" --team-id 975ZZPJQNB --password <app-specific-password>
# App-specific password: appleid.apple.com → Sign-In and Security → App-Specific Passwords.
#
# Запуск:           scripts/release.sh
# Без нотаризации:  SKIP_NOTARIZE=1 scripts/release.sh   (только подпись + DMG, для локальной проверки)
set -euo pipefail

cd "$(dirname "$0")/.."

DEV_ID="${DEV_ID:-Developer ID Application: Ivan Shestakov (975ZZPJQNB)}"
TEAM_ID="${TEAM_ID:-975ZZPJQNB}"
NOTARY_PROFILE="${NOTARY_PROFILE:-vaqlo-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="dist/Vaqlo.app"
DMG="dist/Vaqlo-${VERSION}.dmg"

VENDOR_DIR="$([ -d vendor ] && echo vendor || echo ../vendor)"
WHISPER_CLI="$VENDOR_DIR/whisper.cpp/build/bin/whisper-cli"
LLAMA_CLI="$VENDOR_DIR/llama.cpp/build/bin/llama-completion"
for bin in "$WHISPER_CLI" "$LLAMA_CLI"; do
    [[ -x "$bin" ]] || { echo "Нет $bin — сначала соберите vendor-бинари (см. build_app.sh)"; exit 1; }
done

echo "▸ Сборка приложения и виджета"
swift build -c release
xcodegen --quiet
xcodebuild -project VaqloControl.xcodeproj -target VaqloControl -configuration Release \
    SYMROOT="$(pwd)/.build/appex" CODE_SIGNING_ALLOWED=NO build -quiet

echo "▸ Сборка бандла"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Extensions"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Vaqlo "$APP/Contents/MacOS/Vaqlo"
cp "$WHISPER_CLI" "$APP/Contents/Resources/whisper-cli"
cp "$LLAMA_CLI" "$APP/Contents/Resources/llama-completion"
cp -R ".build/appex/Release/VaqloControl.appex" "$APP/Contents/Extensions/"

# Sparkle для автообновлений
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Vaqlo" 2>/dev/null || true

# Provisioning profiles для App Group (если сгенерированы в портале) — встраиваем ДО подписи.
[[ -f "Resources/Vaqlo.provisionprofile" ]] && cp "Resources/Vaqlo.provisionprofile" "$APP/Contents/embedded.provisionprofile"
[[ -f "Resources/VaqloControl.provisionprofile" ]] && cp "Resources/VaqloControl.provisionprofile" "$APP/Contents/Extensions/VaqloControl.appex/Contents/embedded.provisionprofile"

SIGN=(codesign --force --timestamp --options runtime --sign "$DEV_ID")

echo "▸ Подпись изнутри-наружу"
# 0) Sparkle.framework — вложенный код подписываем изнутри
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for xpc in "$SP/XPCServices/"*.xpc; do [[ -e "$xpc" ]] && "${SIGN[@]}" "$xpc"; done
"${SIGN[@]}" "$SP/Autoupdate"
"${SIGN[@]}" "$SP/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
# 1) вложенные исполняемые бинари
"${SIGN[@]}" "$APP/Contents/Resources/whisper-cli"
"${SIGN[@]}" "$APP/Contents/Resources/llama-completion"
# 2) виджет Control Center
"${SIGN[@]}" --entitlements ControlExtension/VaqloControl.entitlements \
    "$APP/Contents/Extensions/VaqloControl.appex"
# 3) само приложение (запечатывает вложенное)
"${SIGN[@]}" --entitlements Resources/Vaqlo.entitlements "$APP"

echo "▸ Проверка подписи"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
    echo "▸ Нотаризация приложения"
    ZIP="dist/Vaqlo.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

echo "▸ Сборка красивого DMG (фон + стрелка + раскладка)"
scripts/make_dmg.sh
codesign --force --timestamp --sign "$DEV_ID" "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
    echo "▸ Нотаризация DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "▸ Финальная проверка Gatekeeper"
spctl -a -vvv "$APP" 2>&1 | head -3 || true

# Готовый блок для appcast.xml на panic-kit (EdDSA-подпись через Sparkle).
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"
echo
echo "════════ appcast item (вставить в panic-kit-site/vaqlo/appcast.xml) ════════"
cat <<ITEM
    <item>
      <title>Vaqlo $VERSION</title>
      <pubDate>$(date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[ <ul><li>…</li></ul> ]]></description>
      <enclosure
        url="https://github.com/ivshestakov/vaqlo.app/releases/download/v$VERSION/Vaqlo-$VERSION.dmg"
        type="application/octet-stream"
        $("$SIGN_TOOL" "$DMG" 2>/dev/null) />
    </item>
ITEM
echo "═══════════════════════════════════════════════════════════════════════════"
echo
echo "Готово: $(pwd)/$DMG"
echo "Версия: $VERSION (build $BUILD)"
