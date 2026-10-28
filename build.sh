#!/bin/zsh
# Builds ClipboardHistory.app (Apple Silicon + Intel) and installs it into ~/Applications.
# `./build.sh --no-install` only builds it into build/
set -e
cd "$(dirname "$0")"

APP="build/ClipboardHistory.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macosx14.0 $(find Sources -name '*.swift') \
        -o "build/ClipboardHistory-$arch"
done
lipo -create build/ClipboardHistory-arm64 build/ClipboardHistory-x86_64 -output "$APP/Contents/MacOS/ClipboardHistory"
rm build/ClipboardHistory-arm64 build/ClipboardHistory-x86_64
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.pe4enku0.ClipboardHistory</string>
    <key>CFBundleName</key><string>ClipboardHistory</string>
    <key>CFBundleDisplayName</key><string>История буфера</string>
    <key>CFBundleExecutable</key><string>ClipboardHistory</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>© 2026</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
if [[ "$1" == "--no-install" ]]; then
    echo "Built: $APP"
    exit 0
fi

pkill -x ClipboardHistory || true
mkdir -p ~/Applications
rm -rf ~/Applications/ClipboardHistory.app
cp -R "$APP" ~/Applications/
open ~/Applications/ClipboardHistory.app
echo "Installed: ~/Applications/ClipboardHistory.app"
