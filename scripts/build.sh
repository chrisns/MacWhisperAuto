#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/MacWhisperAuto.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"

# VERSION env var: strip v prefix and any -suffix (e.g. v1.2.3-abc1234 -> 1.2.3)
if [ -n "${VERSION:-}" ]; then
    SEMVER="$(echo "$VERSION" | sed 's/^v//; s/-.*//')"
    echo "==> Version override: $SEMVER"
else
    SEMVER=""
fi

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

# Stamp version into app Info.plist
if [ -n "$SEMVER" ]; then
    echo "==> Stamping version $SEMVER into Info.plist..."
    plutil -replace CFBundleShortVersionString -string "$SEMVER" "$CONTENTS/Info.plist"
fi

# Stamp version into Extension files
if [ -n "$SEMVER" ]; then
    echo "==> Stamping version $SEMVER into Extension files..."
    # Update manifest.json version
    MANIFEST="$ROOT/Extension/manifest.json"
    if [ -f "$MANIFEST" ]; then
        sed -i '' "s/\"version\": \".*\"/\"version\": \"$SEMVER\"/" "$MANIFEST"
    fi

    # Update background.js EXTENSION_VERSION constant
    BG_JS="$ROOT/Extension/background.js"
    if [ -f "$BG_JS" ]; then
        sed -i '' "s/const EXTENSION_VERSION = '.*'/const EXTENSION_VERSION = '$SEMVER'/" "$BG_JS"
    fi
fi

echo "==> Signing (ad-hoc) with entitlements..."
codesign --force --sign - \
    --entitlements "$ROOT/Resources/MacWhisperAuto.entitlements" \
    "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo "   Run with: open $APP_BUNDLE"
