#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$ROOT_DIR/SafariShell"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Safarium.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

CONFIG="${SAFARIUM_CONFIG:-debug}"

echo "[Safarium] Building SafariShell ($CONFIG) incrementally..."
cd "$SHELL_DIR"

# Compile incrementally via SwiftPM — if this fails, `set -e` exits immediately
# and ANY previously running Safarium instance remains untouched.
swift build -c "$CONFIG" --arch arm64

BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
BUILT_BINARY="$BIN_DIR/Safarium"

if [[ ! -x "$BUILT_BINARY" ]]; then
    echo "[Safarium] ERROR: Compiled binary not found at $BUILT_BINARY" >&2
    exit 1
fi

echo "[Safarium] Packaging $APP_BUNDLE..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp -f "$BUILT_BINARY" "$MACOS_DIR/Safarium"
cp -f "$SHELL_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$SHELL_DIR/Resources/AppIcon.icns" ]]; then
    cp -f "$SHELL_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
rm -rf "$BUILD_DIR/SafariX.app"

# Stamp native macOS 26.0/27.2 LC_BUILD_VERSION so macOS 27 Tahoe activates native 3D glossy
# 16pt traffic lights (23pt pitch) and full Tahoe chrome instead of Sequoia 15.0 compatibility mode.
if command -v vtool >/dev/null 2>&1; then
    vtool -set-build-version macos 26.0 27.2 -replace -output "$MACOS_DIR/Safarium" "$MACOS_DIR/Safarium"
fi

# Expose Reference/ assets inside the app bundle (copy when SAFARIUM_BUNDLE_COPY_ASSETS=1, else symlink for fast dev)
if [[ "${SAFARIUM_BUNDLE_COPY_ASSETS:-0}" == "1" ]]; then
    rm -rf "$RESOURCES_DIR/Reference"
    ditto "$ROOT_DIR/Reference" "$RESOURCES_DIR/Reference"
else
    ln -sfn "$ROOT_DIR/Reference" "$RESOURCES_DIR/Reference"
fi

# If BrowserCore is built and its bundler helper exists, embed Chromium/CEF frameworks cleanly
if [[ -x "$ROOT_DIR/BrowserCore/scripts/bundle-browsercore.sh" && -f "$ROOT_DIR/BrowserCore/build/libSafariumBrowserCore.dylib" ]]; then
    echo "[Safarium] Embedding BrowserCore frameworks..."
    "$ROOT_DIR/BrowserCore/scripts/bundle-browsercore.sh" "$APP_BUNDLE"
fi

# Pick BrowserCore entitlements if available, else SafariShell entitlements
ENTITLEMENTS="$SHELL_DIR/Safarium.entitlements"
if [[ -f "$ROOT_DIR/BrowserCore/Safarium.entitlements" ]]; then
    ENTITLEMENTS="$ROOT_DIR/BrowserCore/Safarium.entitlements"
fi

# Sign bundle with valid Apple Development cert if available (stable TeamID for Keychain/Touch ID/Passkeys), else ad-hoc
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -v 'REVOKED' | grep 'Apple Development' | head -n 1 | awk '{print $2}' || true)"
if [[ -n "$SIGN_ID" ]]; then
    echo "[Safarium] Signing with Apple Development identity $SIGN_ID..."
    codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" 2>&1 ||         codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null 2>&1 || true
else
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

if [[ "${SAFARIUM_NO_LAUNCH:-0}" == "1" ]]; then
    echo "[Safarium] Build & bundle complete (SAFARIUM_NO_LAUNCH=1)."
    exit 0
fi

# ONLY now — after compilation and packaging succeeded — terminate previous Safarium process(es)
PREV_PIDS="$(pgrep -f "$MACOS_DIR/Safarium" || true)"
if [[ -n "$PREV_PIDS" ]]; then
    echo "[Safarium] Stopping previous Safarium PID(s): $PREV_PIDS"
    kill $PREV_PIDS 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        if ! pgrep -f "$MACOS_DIR/Safarium" >/dev/null 2>&1; then
            break
        fi
        sleep 0.15
    done
fi

echo "[Safarium] Launching $APP_BUNDLE in background..."
if [[ -n "${SAFARIUM_DESKTOP:-}" ]]; then
    SAFARIUM_DESKTOP="$SAFARIUM_DESKTOP" open -g -n "$APP_BUNDLE"
elif [[ -n "${SAFARIUM_BACKGROUND:-}" ]]; then
    # Launch without activating (keeps the user's focus; used by automated checks).
    open -g -n ${SAFARIUM_FREEZE_DEBUG:+--env SAFARIUM_FREEZE_DEBUG=1} "$APP_BUNDLE"
else
    open -n "$APP_BUNDLE"
fi

echo "[Safarium] Launched successfully."
