#!/bin/sh
# Builds DiskChrona.app into ./build (menu bar agent, ad-hoc signed); release also packs a .dmg. Usage: ./build-app.sh [release|debug]
set -e
cd "$(dirname "$0")"
CONFIG=${1:-release}
VERSION=1.0.1
swift build -c "$CONFIG"
APP=build/DiskChrona.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/DiskChrona" "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.moonrailgun.DiskChrona</string>
    <key>CFBundleName</key><string>DiskChrona</string>
    <key>CFBundleExecutable</key><string>DiskChrona</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
[ "$CONFIG" = release ] || exit 0
DMG=build/DiskChrona-$VERSION.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname DiskChrona -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
echo "$DMG"
