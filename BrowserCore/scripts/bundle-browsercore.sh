#!/usr/bin/env bash
# Embeds BrowserCore (libSafariumBrowserCore.dylib, Chromium Embedded Framework.framework,
# and all 5 Safarium Helper*.app bundles) into a target macOS .app bundle.
# Usage: BrowserCore/scripts/bundle-browsercore.sh /path/to/Safarium.app
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <PathToAppBundle>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSERCORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BROWSERCORE_DIR}/build"
APP_BUNDLE="$1"
FRAMEWORKS_DIR="${APP_BUNDLE}/Contents/Frameworks"
ENTITLEMENTS="${BROWSERCORE_DIR}/Safarium.entitlements"

# Resolve active Chromium framework (custom-compiled takes precedence over prebuilt CEF).
if [[ -d "${BROWSERCORE_DIR}/third_party/custom-chromium/Chromium Embedded Framework.framework" ]]; then
  CEF_FRAMEWORK="${BROWSERCORE_DIR}/third_party/custom-chromium/Chromium Embedded Framework.framework"
else
  CEF_FRAMEWORK="${BROWSERCORE_DIR}/third_party/cef/Release/Chromium Embedded Framework.framework"
fi

if [[ ! -f "${BUILD_DIR}/libSafariumBrowserCore.dylib" ]]; then
  echo "ERROR: ${BUILD_DIR}/libSafariumBrowserCore.dylib not found. Build BrowserCore first." >&2
  exit 1
fi

if [[ ! -d "${CEF_FRAMEWORK}" ]]; then
  echo "ERROR: Chromium Embedded Framework.framework not found at ${CEF_FRAMEWORK}" >&2
  exit 1
fi

mkdir -p "${FRAMEWORKS_DIR}"

# 1. Copy libSafariumBrowserCore.dylib
cp -f "${BUILD_DIR}/libSafariumBrowserCore.dylib" "${FRAMEWORKS_DIR}/libSafariumBrowserCore.dylib"

# 2. Sync Chromium Embedded Framework.framework incrementally (fast on repeated builds!)
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "${CEF_FRAMEWORK}/" "${FRAMEWORKS_DIR}/Chromium Embedded Framework.framework/"
else
  rm -rf "${FRAMEWORKS_DIR}/Chromium Embedded Framework.framework"
  ditto "${CEF_FRAMEWORK}" "${FRAMEWORKS_DIR}/Chromium Embedded Framework.framework"
fi

# 3. Copy all 5 macOS CEF Helper .app bundles (rename prefix if app bundle has a different executable name)
APP_NAME="$(basename "${APP_BUNDLE}" .app)"
for helper_src in "${BUILD_DIR}/helpers/"*.app; do
  base="$(basename "${helper_src}")"
  # Replace leading "Safarium" with target app name if different (e.g. BrowserCoreSmokeTest Helper*.app)
  target_base="${base/Safarium/${APP_NAME}}"
  target_app="${FRAMEWORKS_DIR}/${target_base}"
  rm -rf "${target_app}"
  ditto "${helper_src}" "${target_app}"

  if [[ "${APP_NAME}" != "Safarium" ]]; then
    old_exec="${base%.app}"
    new_exec="${target_base%.app}"
    mv "${target_app}/Contents/MacOS/${old_exec}" "${target_app}/Contents/MacOS/${new_exec}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${new_exec}" "${target_app}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ${new_exec}" "${target_app}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${new_exec}" "${target_app}/Contents/Info.plist"
  fi
done

# 4. Ad-hoc sign frameworks, helpers, and dylib with Safarium entitlements
codesign --force --sign - "${FRAMEWORKS_DIR}/libSafariumBrowserCore.dylib" >/dev/null 2>&1 || true
for helper_app in "${FRAMEWORKS_DIR}/"*Helper*.app; do
  codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${helper_app}" >/dev/null 2>&1 || true
done

echo "Bundled BrowserCore + Chromium framework + Helpers into ${APP_BUNDLE}"
