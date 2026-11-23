#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -z "${DEVELOPER_DIR:-}" && -z "${SDKROOT:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]] && DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -checkFirstLaunchStatus </dev/null >/dev/null 2>&1; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        swift test "$@"
        exit 0
    elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    fi
fi

CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

swift test \
    --build-system native \
    --enable-swift-testing \
    --disable-xctest \
    -Xswiftc -F -Xswiftc "$CLT_FW" \
    -Xswiftc -load-plugin-library -Xswiftc "$CLT_PLUGIN" \
    -Xlinker -F -Xlinker "$CLT_FW" \
    -Xlinker -rpath -Xlinker "$CLT_FW" \
    "$@"
