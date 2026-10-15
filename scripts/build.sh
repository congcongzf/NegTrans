#!/bin/bash
# Build NegTrans.app on a macOS runner with swiftc (no Xcode project needed).
set -euo pipefail

APP_NAME="NegTrans"
BUNDLE_ID="com.negtrans.app"
VERSION="0.1.0"

SRC_DIR="$(cd "$(dirname "$0")/../Sources" && pwd)"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/build"
APP="$OUT_DIR/$APP_NAME.app"

rm -rf "$OUT_DIR" "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
swiftc \
  -O \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$SRC_DIR/NegPipeline.swift" \
  "$SRC_DIR/NegTransApp.swift" \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreImage \
  -framework Accelerate \
  -framework UniformTypeIdentifiers

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> verify"
codesign --verify --verbose "$APP"
ls -la "$APP/Contents/MacOS/"

echo "==> DMG"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
ls -la "$OUT_DIR"
echo "BUILD OK: $DMG"
