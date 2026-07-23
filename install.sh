#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="pstConvert"
SRC="dist/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

if [ ! -d "$SRC" ]; then
    echo "No build found at $SRC — run ./build.sh first."
    exit 1
fi

if [ -d "$DEST" ]; then
    echo "==> Removing existing installed copy…"
    rm -rf "$DEST"
fi

echo "==> Installing to $DEST…"
cp -R "$SRC" "$DEST"
echo "==> Done."
