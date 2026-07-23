#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="pstConvert"
BUNDLE_ID="com.local.pstconvert"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"

echo "==> Building Swift package (release)…"
swift build -c release --arch arm64

echo "==> Assembling app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/bin"

cp "$BUILD_DIR/PSTConvert" "$APP_DIR/Contents/MacOS/PSTConvert"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "Resources/bin/readpst" "$APP_DIR/Contents/Resources/bin/readpst"
chmod 755 "$APP_DIR/Contents/Resources/bin/readpst"
chmod 755 "$APP_DIR/Contents/MacOS/PSTConvert"

echo "==> Ad-hoc code signing…"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
