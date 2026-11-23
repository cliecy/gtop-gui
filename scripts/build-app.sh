#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GTop"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Prefer CommandLineTools MacOSX26 SDK when Xcode license isn't accepted, since macOS 27
# SwiftUI macros require full Xcode plugins while MacOSX26 SDK compiles natively with CLT.
if [[ -z "${DEVELOPER_DIR:-}" && -z "${SDKROOT:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]] && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -checkFirstLaunchStatus </dev/null >/dev/null 2>&1; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    fi
fi

echo "==> Building release binary..."
cd "$ROOT_DIR"
EXTRA_FLAGS=()
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    EXTRA_FLAGS+=(--build-system native)
fi
if [[ -n "${GTOP_SWIFT_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_FLAGS+=(${GTOP_SWIFT_FLAGS})
fi
swift build -c release --product GTop "${EXTRA_FLAGS[@]}"

BIN_PATH="$(swift build -c release --show-bin-path "${EXTRA_FLAGS[@]}")/GTop"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: compiled binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling ${APP_NAME}.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Generate App Icon (.icns)
swift "$ROOT_DIR/scripts/generate-icon.swift" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>GTop</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.cliecy.gtop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GTop</string>
    <key>CFBundleDisplayName</key>
    <string>GTop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS runs smoothly locally
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Done! App bundle created at: $APP_BUNDLE"
echo "    Launch with: open \"$APP_BUNDLE\""
