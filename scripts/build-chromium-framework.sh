#!/usr/bin/env bash
# ==============================================================================
# scripts/build-chromium-framework.sh
#
# Builds BrowserCore and manages the Chromium engine framework for Safarium.
#
# Architecture guarantee:
#   SafariShell (Swift + AppKit) links ONLY against `BrowserCore/include/SafariumEngineBridge.h`
#   and `libSafariumBrowserCore.dylib`. `BrowserCore` dynamically loads the active
#   Chromium `.framework` at runtime. Therefore you can swap between:
#     1. Fast bootstrap: Prebuilt Spotify CEF macOS arm64 (Chrome Runtime)
#     2. Custom-compiled Chromium `.framework` (with proprietary codecs / Widevine / custom patches)
#   WITHOUT changing a single line of `SafariShell/`.
#
# Usage:
#   ./scripts/build-chromium-framework.sh --mode=cef
#       (Default) Ensures CEF macOS arm64 is present and builds BrowserCore (Release, arm64).
#
#   ./scripts/build-chromium-framework.sh --swap-framework /path/to/Chromium\ Embedded\ Framework.framework
#       Drops a custom-compiled Chromium/CEF `.framework` into
#       `BrowserCore/third_party/custom-chromium/` (takes automatic precedence over prebuilt CEF)
#       and re-verifies arm64 compatibility.
#
#   ./scripts/build-chromium-framework.sh --mode=custom-chromium [--chromium-src ~/chromium] [--cef-branch 8078]
#       Full source build automation using depot_tools + GN + autoninja for Apple Silicon (arm64)
#       with proprietary codecs (`ffmpeg_branding="Chrome"`, `proprietary_codecs=true`, `enable_widevine=true`),
#       then installs the resulting `.framework` into `BrowserCore/third_party/custom-chromium/`.
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROWSERCORE_DIR="${ROOT_DIR}/BrowserCore"
CEF_DIR="${BROWSERCORE_DIR}/third_party/cef"
CUSTOM_DIR="${BROWSERCORE_DIR}/third_party/custom-chromium"
BUILD_DIR="${BROWSERCORE_DIR}/build"

CEF_VERSION="156.0.32+g3d1f4ab+chromium-156.0.8078.109"
CEF_TARBALL="cef_binary_156.0.32%2Bg3d1f4ab%2Bchromium-156.0.8078.109_macosarm64_minimal.tar.bz2"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_TARBALL}"

MODE="cef"
SWAP_PATH=""
CHROMIUM_SRC="${HOME}/chromium"
CEF_BRANCH="8078"

for arg in "$@"; do
  case "${arg}" in
    --mode=*)
      MODE="${arg#*=}"
      ;;
    --swap-framework)
      shift
      SWAP_PATH="${1:-}"
      MODE="swap"
      ;;
    --swap-framework=*)
      SWAP_PATH="${arg#*=}"
      MODE="swap"
      ;;
    --chromium-src=*)
      CHROMIUM_SRC="${arg#*=}"
      ;;
    --cef-branch=*)
      CEF_BRANCH="${arg#*=}"
      ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
  esac
done

verify_arm64_framework() {
  local fw_path="$1"
  local fw_bin="${fw_path}/Chromium Embedded Framework"
  if [[ ! -f "${fw_bin}" ]]; then
    echo "ERROR: Framework binary not found at ${fw_bin}" >&2
    exit 1
  fi
  local arch_info
  arch_info="$(file "${fw_bin}")"
  echo "Verified framework binary: ${arch_info}"
  if [[ "${arch_info}" != *"arm64"* ]]; then
    echo "ERROR: Expected arm64 Mach-O binary, got: ${arch_info}" >&2
    exit 1
  fi
}

build_browsercore() {
  local sdk_path
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  echo "Configuring BrowserCore (Release, arm64, SDK=${sdk_path})..."
  cmake -G Ninja \
    -S "${BROWSERCORE_DIR}" \
    -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPROJECT_ARCH=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="${sdk_path}" \
    -DCEF_ROOT="${CEF_DIR}"

  echo "Building SafariumBrowserCore, SafariumHelpers, and BrowserCoreSmokeTest..."
  cmake --build "${BUILD_DIR}" --parallel
  echo "BrowserCore build succeeded:"
  echo "  - ${BUILD_DIR}/libSafariumBrowserCore.dylib"
  echo "  - ${BUILD_DIR}/helpers/Safarium Helper*.app"
  echo "  - ${BUILD_DIR}/BrowserCoreSmokeTest"
}

case "${MODE}" in
  cef)
    if [[ ! -d "${CEF_DIR}/Release/Chromium Embedded Framework.framework" ]]; then
      echo "Downloading Spotify CEF ${CEF_VERSION} (macosarm64 minimal)..."
      mkdir -p "${CEF_DIR}"
      curl -fL --progress-bar "${CEF_URL}" -o "${CEF_DIR}/cef_minimal.tar.bz2"
      tar -xjf "${CEF_DIR}/cef_minimal.tar.bz2" -C "${CEF_DIR}" --strip-components=1
      rm -f "${CEF_DIR}/cef_minimal.tar.bz2"
    fi
    verify_arm64_framework "${CEF_DIR}/Release/Chromium Embedded Framework.framework"
    build_browsercore
    ;;

  swap)
    if [[ -z "${SWAP_PATH}" || ! -d "${SWAP_PATH}" ]]; then
      echo "ERROR: Provide an existing .framework path via --swap-framework=/path/to/Framework.framework" >&2
      exit 1
    fi
    verify_arm64_framework "${SWAP_PATH}"
    mkdir -p "${CUSTOM_DIR}"
    rm -rf "${CUSTOM_DIR}/Chromium Embedded Framework.framework"
    ditto "${SWAP_PATH}" "${CUSTOM_DIR}/Chromium Embedded Framework.framework"
    echo "Installed custom Chromium framework into ${CUSTOM_DIR}/Chromium Embedded Framework.framework"
    echo "BrowserCore/scripts/bundle-browsercore.sh and SXEngineRuntime will automatically load it."
    echo "No changes to SafariShell/ are required — simply re-run scripts/run.sh."
    ;;

  custom-chromium)
    echo "=== Custom Chromium (.framework) Source Build Automation (macOS arm64) ==="
    echo "Target checkout: ${CHROMIUM_SRC} (branch ${CEF_BRANCH})"
    echo "Requires ~100 GB free disk space, Xcode CLT, Python 3, and depot_tools."

    if ! command -v gclient >/dev/null 2>&1; then
      DEPOT_TOOLS="${HOME}/depot_tools"
      if [[ ! -d "${DEPOT_TOOLS}" ]]; then
        echo "Cloning depot_tools into ${DEPOT_TOOLS}..."
        git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS}"
      fi
      export PATH="${DEPOT_TOOLS}:${PATH}"
    fi

    mkdir -p "${CHROMIUM_SRC}"
    cd "${CHROMIUM_SRC}"

    # Standard CEF/Chromium automated build script for arm64 with proprietary codecs & Chrome runtime
    if [[ ! -f "${CHROMIUM_SRC}/automate-git.py" ]]; then
      curl -fL "https://bitbucket.org/chromiumembedded/cef/raw/master/tools/automate/automate-git.py" \
        -o "${CHROMIUM_SRC}/automate-git.py"
    fi

    export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome enable_widevine=true symbol_level=0 use_thin_lto=false chrome_pgo_phase=0"
    export CEF_ARCHIVE_FORMAT="tar.bz2"

    echo "Running automate-git.py for arm64 branch ${CEF_BRANCH}..."
    python3 "${CHROMIUM_SRC}/automate-git.py" \
      --download-dir="${CHROMIUM_SRC}" \
      --branch="${CEF_BRANCH}" \
      --arm64-build \
      --minimal-distrib \
      --client-distrib \
      --no-debug-build \
      --build-target=cefsimple \
      --force-build

    OUT_FRAMEWORK="${CHROMIUM_SRC}/chromium/src/out/Release_GN_arm64/Chromium Embedded Framework.framework"
    verify_arm64_framework "${OUT_FRAMEWORK}"

    mkdir -p "${CUSTOM_DIR}"
    rm -rf "${CUSTOM_DIR}/Chromium Embedded Framework.framework"
    ditto "${OUT_FRAMEWORK}" "${CUSTOM_DIR}/Chromium Embedded Framework.framework"

    echo "Custom Chromium framework installed to ${CUSTOM_DIR}/Chromium Embedded Framework.framework"
    build_browsercore
    echo "Done! Zero changes to SafariShell/ needed — run scripts/run.sh to launch Safarium with your custom Chromium."
    ;;

  *)
    echo "Unknown mode: ${MODE}. Use --mode=cef, --swap-framework=<path>, or --mode=custom-chromium." >&2
    exit 1
    ;;
esac
