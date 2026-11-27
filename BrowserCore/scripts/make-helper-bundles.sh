#!/usr/bin/env bash
# Creates all 5 required macOS CEF Helper .app bundles from the compiled SafariumHelper binary.
set -euo pipefail

HELPER_BIN="$1"
OUT_DIR="$2"
ENTITLEMENTS="${3:-}"

mkdir -p "${OUT_DIR}"

make_helper() {
  local suffix="$1"
  local id_suffix="$2"
  local app_name="Safarium Helper${suffix}"
  local bundle_dir="${OUT_DIR}/${app_name}.app"
  local macos_dir="${bundle_dir}/Contents/MacOS"

  rm -rf "${bundle_dir}"
  mkdir -p "${macos_dir}"
  cp -f "${HELPER_BIN}" "${macos_dir}/${app_name}"
  chmod +x "${macos_dir}/${app_name}"

  cat > "${bundle_dir}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${app_name}</string>
  <key>CFBundleExecutable</key>
  <string>${app_name}</string>
  <key>CFBundleIdentifier</key>
  <string>com.safarium.browser.helper${id_suffix}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
EOF

  if [[ -n "${ENTITLEMENTS}" && -f "${ENTITLEMENTS}" ]]; then
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${bundle_dir}" >/dev/null 2>&1 || true
  fi
}

make_helper "" ""
make_helper " (Alerts)" ".alerts"
make_helper " (GPU)" ".gpu"
make_helper " (Plugin)" ".plugin"
make_helper " (Renderer)" ".renderer"

echo "Packaged 5 Safarium Helper bundles into ${OUT_DIR}"
