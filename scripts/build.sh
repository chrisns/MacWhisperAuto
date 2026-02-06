#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/MacWhisperAuto.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"

echo "==> Building with swift build (release)..."
cd "$ROOT"
swift build -c release

EXECUTABLE="$(swift build -c release --show-bin-path)/MacWhisperAuto"
if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    exit 1
fi

echo "==> Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"

cp "$EXECUTABLE" "$MACOS/MacWhisperAuto"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

echo "==> Signing (ad-hoc) with entitlements..."
codesign --force --sign - \
    --entitlements "$ROOT/Resources/MacWhisperAuto.entitlements" \
    "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo "   Run with: open $APP_BUNDLE"
