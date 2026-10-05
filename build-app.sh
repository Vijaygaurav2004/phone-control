#!/bin/bash
# Builds "Nothing Phone 3a.app" and puts it in /Applications + on the Desktop.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Nothing Phone 3a"
BUILD="$HERE/$APP_NAME.app"

python3 "$HERE/make-icon.py"

rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

cp "$HERE/launcher.sh" "$BUILD/Contents/MacOS/launch"
chmod +x "$BUILD/Contents/MacOS/launch"

# Run scrcpy from inside the bundle so macOS labels the menu bar and Dock
# "Nothing Phone 3a" instead of "scrcpy". Re-copied on every rebuild, so a
# Homebrew upgrade is picked up next time this script runs.
cp "$(readlink -f "$(command -v scrcpy)" 2>/dev/null || command -v scrcpy)" "$BUILD/Contents/MacOS/scrcpy"
chmod +x "$BUILD/Contents/MacOS/scrcpy"
cp /opt/homebrew/share/scrcpy/scrcpy-server "$BUILD/Contents/Resources/scrcpy-server"
cp "$HERE/icon.icns" "$BUILD/Contents/Resources/icon.icns"
cp "$HERE/icon.png"  "$BUILD/Contents/Resources/icon.png"

cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Nothing Phone 3a</string>
  <key>CFBundleDisplayName</key>       <string>Nothing Phone 3a</string>
  <key>CFBundleExecutable</key>        <string>launch</string>
  <key>CFBundleIconFile</key>          <string>icon</string>
  <key>CFBundleIdentifier</key>        <string>local.gaurav.nothingphone3a</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Finds your Nothing Phone 3a on the local network to mirror its screen.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS treats it as a stable app identity (keeps
# local-network + accessibility permissions from resetting each launch).
codesign --force --deep --sign "Phone Control Signing" "$BUILD" 2>/dev/null || true

# Refresh the icon cache so Finder shows the new icon immediately
touch "$BUILD"

echo "Built: $BUILD"
