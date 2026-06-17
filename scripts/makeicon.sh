#!/bin/bash
# Пересобирает иконку приложения из исходника vault/image.png:
# делает внешний белый прозрачным → масштабирует → AppIcon.icns в Resources/.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Resources/AppIcon-source.png"
[[ -f "$SRC" ]] || { echo "Нет исходника $SRC"; exit 1; }

TMP="$(mktemp -d)"
swiftc scripts/icon_transparent.swift -o "$TMP/icon_transparent"
"$TMP/icon_transparent" "$SRC" "$TMP/icon_src.png"
sips -z 1024 1024 "$TMP/icon_src.png" --out "$TMP/icon_1024.png" >/dev/null

rm -rf "$TMP/AppIcon.iconset"; mkdir "$TMP/AppIcon.iconset"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
    d=$((sz * 2))
    sips -z $d $d "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Resources/AppIcon-1024.png
rm -rf "$TMP"
echo "OK: Resources/AppIcon.icns (из $SRC)"
