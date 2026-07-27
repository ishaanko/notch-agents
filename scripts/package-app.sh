#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CONFIGURATION="${1:-release}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/build/Notch Agents.app"
ARCHIVE_PATH="$ROOT_DIR/build/Notch-Agents-0.1.0.zip"

cd "$ROOT_DIR"
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift build -c "$CONFIGURATION"

if [[ -d "$APP_DIR" ]]; then
  rm -rf "$APP_DIR"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/NotchAgents" "$APP_DIR/Contents/MacOS/notch-agents"
cp "$BUILD_DIR/NotchAgentsBridge" "$APP_DIR/Contents/Helpers/notch-agents-bridge"

RESOURCE_BUNDLE="$BUILD_DIR/NotchAgents_NotchAgents.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/${RESOURCE_BUNDLE:t}"

ICON_PNG="$ROOT_DIR/build/AppIcon-1024.png"
ICONSET="$ROOT_DIR/build/AppIcon.iconset"
xcrun swift "$ROOT_DIR/scripts/generate-icon.swift" "$ICON_PNG"
mkdir -p "$ICONSET"
for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  pixels="${spec%% *}"
  filename="${spec#* }"
  sips -z "$pixels" "$pixels" "$ICON_PNG" --out "$ICONSET/$filename" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

plutil -create xml1 "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "Notch Agents" "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundleExecutable -string "notch-agents" "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "app.notchagents.macos" "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundleIconFile -string "AppIcon" "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundleName -string "Notch Agents" "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundlePackageType -string "APPL" "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "0.1.0" "$APP_DIR/Contents/Info.plist"
plutil -insert CFBundleVersion -string "1" "$APP_DIR/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string "14.0" "$APP_DIR/Contents/Info.plist"
plutil -insert LSUIElement -bool true "$APP_DIR/Contents/Info.plist"
plutil -insert NSAppleEventsUsageDescription -string "Notch Agents uses terminal automation to jump to the session you select." "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
ARCHIVE_STAGE="$(mktemp -d "$ROOT_DIR/build/.notch-agents-archive.XXXXXX")"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_STAGE/${ARCHIVE_PATH:t}"
mv "$ARCHIVE_STAGE/${ARCHIVE_PATH:t}" "$ARCHIVE_PATH"
rmdir "$ARCHIVE_STAGE"
echo "$APP_DIR"
echo "$ARCHIVE_PATH"
