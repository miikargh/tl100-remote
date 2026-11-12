#!/bin/sh
# Builds both apps into ~/Applications:
#   TL100 Remote.app      the native floating widget (TL100Remote.swift). Launching it again toggles the panel.
#   TL100 Remote Web.app  the Chrome page with hand + music modes (tl100-remote.html + launcher.applescript)
set -e
cd "$(dirname "$0")"
NATIVE="$HOME/Applications/TL100 Remote.app"
WEB="$HOME/Applications/TL100 Remote Web.app"
TMP=$(mktemp -d)

swiftc -O -parse-as-library -o "$TMP/TL100Remote" TL100Remote.swift

# icon: the binary draws it, sips + iconutil package it
"$TMP/TL100Remote" --icon "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$TMP/AppIcon.icns" "$TMP/AppIcon.iconset"

pkill -x TL100Remote || true
rm -rf "$NATIVE" "$WEB"

mkdir -p "$NATIVE/Contents/MacOS" "$NATIVE/Contents/Resources"
cp "$TMP/TL100Remote" "$NATIVE/Contents/MacOS/"
cp "$TMP/AppIcon.icns" "$NATIVE/Contents/Resources/"
cat > "$NATIVE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TL100 Remote</string>
  <key>CFBundleIdentifier</key><string>local.tl100-remote</string>
  <key>CFBundleExecutable</key><string>TL100Remote</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>TL100 Remote controls your lamp over Bluetooth.</string>
</dict></plist>
PLIST
# Signed with your developer certificate when there is one: macOS then keeps the Bluetooth permission across
# rebuilds. An ad-hoc signature (the fallback) changes every build, so macOS asks again each time.
codesign --force -s "Apple Development" "$NATIVE" 2>/dev/null || codesign --force -s - "$NATIVE"

osacompile -o "$WEB" launcher.applescript
cp tl100-remote.html "$WEB/Contents/Resources/"
cp "$TMP/AppIcon.icns" "$WEB/Contents/Resources/applet.icns"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$WEB/Contents/Info.plist"   # no Dock icon, never steals focus
codesign --force -s - "$WEB"

codesign -v "$NATIVE" && codesign -v "$WEB" && echo "built: $NATIVE and $WEB"
rm -rf "$TMP"
