cmake_minimum_required(VERSION 3.21)
project(SafariumBrowserCore LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES "arm64")

if(NOT DEFINED CEF_ROOT)
  set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cef")
endif()

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

# Build CEF's C++ DLL wrapper library.
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)

# Common include directories for BrowserCore targets.
set(BROWSERCORE_INCLUDES
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
  "${CEF_INCLUDE_PATH}"
)

# ------------------------------------------------------------------------------
# 1. libSafariumBrowserCore.dylib — Objective-C++ bridge linked by SafariShell
# ------------------------------------------------------------------------------
add_library(SafariumBrowserCore SHARED
  src/SXApp.mm
  src/SXBrowserClient.mm
  src/SXExtensionManager.mm
  src/SXMediaTranscodeServer.mm
  src/SXPrivacyEngine.mm
  src/SXTopEdgeColorSampler.mm
  src/SafariumEngineBridge.mm
)

target_include_directories(SafariumBrowserCore
  PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE
    ${BROWSERCORE_INCLUDES}
)

target_compile_options(SafariumBrowserCore PRIVATE
  -fobjc-arc
  -fvisibility=default
  -Wno-unused-parameter
  -Wno-deprecated-declarations
  -Wno-missing-field-initializers
)

target_link_libraries(SafariumBrowserCore PRIVATE
  libcef_dll_wrapper
  "-framework AppKit"
  "-framework AVFoundation"
  "-framework Cocoa"
  "-framework CoreGraphics"
  "-framework CoreMedia"
  "-framework Foundation"
  "-framework ImageIO"
  "-framework IOSurface"
  "-framework QuartzCore"
)

set_target_properties(SafariumBrowserCore PROPERTIES
  INSTALL_NAME_DIR "@rpath"
  BUILD_WITH_INSTALL_RPATH ON
  MACOSX_RPATH ON
  OUTPUT_NAME "SafariumBrowserCore"
)

# ------------------------------------------------------------------------------
# 2. SafariumHelper — Chromium subprocess executable (Renderer/GPU/Plugin/Alerts)
# ------------------------------------------------------------------------------
add_executable(SafariumHelper
  src/SXHelperMain.mm
)

target_include_directories(SafariumHelper PRIVATE ${BROWSERCORE_INCLUDES})

target_compile_options(SafariumHelper PRIVATE
  -fobjc-arc
  -Wno-unused-parameter
  -Wno-deprecated-declarations
)

target_link_libraries(SafariumHelper PRIVATE
  libcef_dll_wrapper
  "-framework AppKit"
  "-framework Cocoa"
  "-framework Foundation"
  "-framework IOSurface"
)

# Package the 5 required macOS CEF Helper .app bundles into build/helpers/.
set(HELPERS_OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/helpers")
add_custom_target(SafariumHelpers ALL
  DEPENDS SafariumHelper
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/make-helper-bundles.sh"
          "$<TARGET_FILE:SafariumHelper>"
          "${HELPERS_OUT_DIR}"
          "${CMAKE_CURRENT_SOURCE_DIR}/Safarium.entitlements"
  COMMENT "Packaging macOS CEF Helper app bundles..."
)

# ------------------------------------------------------------------------------
# 3. BrowserCoreSmokeTest — Native AppKit verification harness
# ------------------------------------------------------------------------------
add_executable(BrowserCoreSmokeTest
  src/SXSmokeTestMain.mm
)

target_include_directories(BrowserCoreSmokeTest PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_compile_options(BrowserCoreSmokeTest PRIVATE
  -fobjc-arc
  -Wno-unused-parameter
)

target_link_libraries(BrowserCoreSmokeTest PRIVATE
  SafariumBrowserCore
  "-framework AppKit"
  "-framework Foundation"
  "-framework QuartzCore"
)

set_target_properties(BrowserCoreSmokeTest PROPERTIES
  BUILD_RPATH "@executable_path/../Frameworks;${CMAKE_CURRENT_BINARY_DIR}"
)

# ------------------------------------------------------------------------------
# 4. BrowserCorePrivacyTests — Standalone C++ privacy engine unit tests
# ------------------------------------------------------------------------------
add_executable(BrowserCorePrivacyTests
  src/SXPrivacyEngine.mm
  src/SXPrivacyEngineTests.mm
)

target_include_directories(BrowserCorePrivacyTests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

target_compile_options(BrowserCorePrivacyTests PRIVATE
  -fobjc-arc
  -Wno-unused-parameter
)

target_link_libraries(BrowserCorePrivacyTests PRIVATE
  "-framework Foundation"
)
