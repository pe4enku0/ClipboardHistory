#!/bin/zsh
# Regenerates Resources/AppIcon.png and Resources/AppIcon.icns from scripts/make-icon.swift
set -e
cd "$(dirname "$0")/.."

swift scripts/make-icon.swift Resources/AppIcon.png

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Icon: Resources/AppIcon.icns"
