#!/bin/bash
# Builds "Phone Control.app" — a menu bar item with Lock / Unlock / Mirror.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/Phone Control.app"

# Swift only allows top-level code in a file literally named main.swift, so the
# entry point is copied under that name when compiling alongside other sources.
BUILD_TMP="$(mktemp -d)"
cp "$HERE/PhoneControl.swift" "$BUILD_TMP/main.swift"
cp "$HERE/Trackpad.swift" "$BUILD_TMP/Trackpad.swift"
cp "$HERE/Surface.swift" "$BUILD_TMP/Surface.swift"
cp "$HERE/Mirror.swift" "$BUILD_TMP/Mirror.swift"
swiftc -O -o "$HERE/PhoneControl" "$BUILD_TMP/main.swift" "$BUILD_TMP/Trackpad.swift" "$BUILD_TMP/Surface.swift" "$BUILD_TMP/Mirror.swift" -framework Cocoa -framework AVFoundation
rm -rf "$BUILD_TMP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/PhoneControl" "$APP/Contents/MacOS/PhoneControl"
chmod +x "$APP/Contents/MacOS/PhoneControl"
[ -f "$HERE/icon.icns" ] && cp "$HERE/icon.icns" "$APP/Contents/Resources/icon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Phone Control</string>
  <key>CFBundleDisplayName</key>       <string>Phone Control</string>
  <key>CFBundleExecutable</key>        <string>PhoneControl</string>
  <key>CFBundleIconFile</key>          <string>icon</string>
  <key>CFBundleIdentifier</key>        <string>local.gaurav.phonecontrol</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign "Phone Control Signing" "$APP" 2>/dev/null || true
touch "$APP"
echo "Built: $APP"
