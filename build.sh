#!/bin/zsh
# Builds ClipboardHistory.app and installs it into ~/Applications
set -e
cd "$(dirname "$0")"

APP="build/ClipboardHistory.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 *.swift -o "$APP/Contents/MacOS/ClipboardHistory"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.pe4enku0.ClipboardHistory</string>
    <key>CFBundleName</key><string>ClipboardHistory</string>
    <key>CFBundleDisplayName</key><string>История буфера</string>
    <key>CFBundleExecutable</key><string>ClipboardHistory</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

pkill -x ClipboardHistory || true
mkdir -p ~/Applications
rm -rf ~/Applications/ClipboardHistory.app
cp -R "$APP" ~/Applications/
open ~/Applications/ClipboardHistory.app
echo "Installed: ~/Applications/ClipboardHistory.app"
