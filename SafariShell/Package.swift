// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent()
let browserCoreInclude = repoRoot.appendingPathComponent("BrowserCore/include").path
let browserCoreBuild = repoRoot.appendingPathComponent("BrowserCore/build").path
let hasBrowserCore = FileManager.default.fileExists(
    atPath: repoRoot.appendingPathComponent("BrowserCore/build/libSafariumBrowserCore.dylib").path
)

var targetSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-parse-as-library"]),
    .swiftLanguageMode(.v5)
]

var targetLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("AVKit"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("Metal"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("LocalAuthentication"),
    .linkedFramework("LocalAuthenticationEmbeddedUI"),
    .linkedFramework("Security"),
    .linkedFramework("AuthenticationServices"),
    .linkedFramework("UniformTypeIdentifiers"),
    .linkedLibrary("sqlite3")
]

if hasBrowserCore {
    targetSwiftSettings.append(
        .unsafeFlags([
            "-I", browserCoreInclude,
            "-DSAFARIUM_CHROMIUM_CORE"
        ])
    )
    targetLinkerSettings.append(
        .unsafeFlags([
            "-L", browserCoreBuild,
            "-lSafariumBrowserCore",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            "-Xlinker", "-rpath", "-Xlinker", browserCoreBuild
        ])
    )
}

var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
var testLinkerSettings: [LinkerSetting] = []
if hasBrowserCore {
    testSwiftSettings.append(.unsafeFlags(["-I", browserCoreInclude]))
    testLinkerSettings.append(
        .unsafeFlags([
            "-L", browserCoreBuild,
            "-lSafariumBrowserCore"
        ])
    )
}

let package = Package(
    name: "Safarium",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Safarium", targets: ["Safarium"])
    ],
    targets: [
        .executableTarget(
            name: "Safarium",
            path: "Sources/Safarium",
            swiftSettings: targetSwiftSettings,
            linkerSettings: targetLinkerSettings
        ),
        .testTarget(
            name: "SafariumTests",
            dependencies: ["Safarium"],
            path: "Tests/SafariumTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
