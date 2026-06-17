#!/bin/bash
# Собирает Vaqlo.app из SwiftPM-бинаря + кладёт внутрь whisper-cli: dist/Vaqlo.app
set -euo pipefail

cd "$(dirname "$0")/.."

VENDOR_DIR="$([ -d vendor ] && echo vendor || echo ../vendor)"
WHISPER_CLI="$VENDOR_DIR/whisper.cpp/build/bin/whisper-cli"
if [[ ! -x "$WHISPER_CLI" ]]; then
    echo "whisper-cli не собран. Запустите:"
    echo "  cd ../vendor/whisper.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON && cmake --build build -j8 --target whisper-cli"
    exit 1
fi

LLAMA_CLI="$VENDOR_DIR/llama.cpp/build/bin/llama-completion"
if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "llama-cli не собран. Запустите:"
    echo "  cd ../vendor/llama.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF && cmake --build build -j8 --target llama-completion"
    exit 1
fi

swift build -c release

# Control Center расширение (отдельный xcodegen-проект)
xcodegen --quiet
xcodebuild -project VaqloControl.xcodeproj -target VaqloControl -configuration Release \
    SYMROOT="$(pwd)/.build/appex" CODE_SIGNING_ALLOWED=NO build -quiet

APP="dist/Vaqlo.app"
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

codesign --force --sign - --deep "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP/Contents/Resources/whisper-cli"
codesign --force --sign - "$APP/Contents/Resources/llama-completion"
codesign --force --sign - --entitlements ControlExtension/VaqloControl.entitlements \
    "$APP/Contents/Extensions/VaqloControl.appex"
codesign --force --sign - --entitlements Resources/Vaqlo.entitlements "$APP"

echo "OK: $(pwd)/$APP"
