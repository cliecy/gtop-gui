#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="GTop"
VERSION="${1:-1.1.0}"
DIST_DIR="$ROOT_DIR/dist"
STAGING="$(mktemp -d)"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

# 1. Build release .app (reuses build-app.sh)
./scripts/build-app.sh

# 2. Stage DMG contents: app + /Applications alias
STAGE_APP="$STAGING/${APP_NAME}.app"
cp -R "$DIST_DIR/${APP_NAME}.app" "$STAGE_APP"
ln -s /Applications "$STAGING/Applications"

# 3. Create compressed read-only DMG
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

echo "==> DMG created: $DMG_PATH"
