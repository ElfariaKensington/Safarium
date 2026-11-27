import XCTest
@testable import Safarium

/// Compatibility classification and MV2 / Safari / Firefox -> Chromium MV3 conversion.
/// All source trees and staging roots live under the hermetic sandbox.
final class ExtensionCompatibilityConverterTests: HermeticTestCase {
    private let converter = ExtensionCompatibilityConverter.shared

    // MARK: - Fixture helpers

    /// Creates `<base>/src` with the given manifest and files; returns the source directory.
    private func makeSource(_ manifest: [String: Any], files: [String: String] = [:]) throws -> URL {
        let base = try ImporterFixtures.makeRoot(self)
        let src = base.appendingPathComponent("src", isDirectory: true)
        try ImporterFixtures.writeJSON(manifest, to: src.appendingPathComponent("manifest.json"))
        for (path, text) in files {
            try ImporterFixtures.write(text, to: src.appendingPathComponent(path))
        }
        return src
    }

    /// Converts with the staging root placed next to the source (sibling `staging`), never in Application Support.
    private func convert(_ src: URL, id: String = "conv-test") throws -> URL {
        let staging = src.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
        return try converter.convertToChromiumMV3(sourceDir: src, extensionID: id, stagingRootOverride: staging)
    }

    private func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable \(url.lastPathComponent)>"
    }

    private func readManifest(_ dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func analyze(_ manifest: [String: Any], files: [String: String] = [:], safari: Bool = false) throws -> ExtensionCompatibility {
        let src = try makeSource(manifest, files: files)
        return converter.analyze(manifestDir: src, fromSafariBundle: safari)
    }

    // MARK: - ExtensionCompatibility value

    func testNativeMV3IsImportableWithoutBadgeAndHasTooltip() {
        let value = ExtensionCompatibility.nativeMV3
        XCTAssertTrue(value.isImportable)
        XCTAssertNil(value.shortBadgeText)
        XCTAssertEqual(value.detailTooltip, "Native Chromium Manifest V3 extension.")
    }

    func testConvertibleJoinsReasonsInTooltip() {
        let value = ExtensionCompatibility.convertible(reasons: ["MV2 → MV3", "strip background.persistent"])
        XCTAssertTrue(value.isImportable)
        XCTAssertEqual(value.shortBadgeText, "Auto-Convert")
        XCTAssertEqual(value.detailTooltip, "Will be converted for Chromium MV3: MV2 → MV3, strip background.persistent")
    }

    func testConvertibleWithNoReasonsKeepsTrailingPrefix() {
        let value = ExtensionCompatibility.convertible(reasons: [])
        XCTAssertTrue(value.isImportable)
        XCTAssertEqual(value.shortBadgeText, "Auto-Convert")
        XCTAssertEqual(value.detailTooltip, "Will be converted for Chromium MV3: ")
    }

    func testConvertibleWithSingleReasonHasNoSeparator() {
        XCTAssertEqual(ExtensionCompatibility.convertible(reasons: ["MV2 → MV3"]).detailTooltip,
                       "Will be converted for Chromium MV3: MV2 → MV3")
    }

    func testIncompatibleIsNotImportableAndShowsReasonAsTooltip() {
        let value = ExtensionCompatibility.incompatible(reason: "Browser themes are not supported")
        XCTAssertFalse(value.isImportable)
        XCTAssertEqual(value.shortBadgeText, "Incompatible")
        XCTAssertEqual(value.detailTooltip, "Browser themes are not supported")
    }

    func testIncompatibleWithEmptyReasonGivesEmptyTooltipNotNil() {
        let value = ExtensionCompatibility.incompatible(reason: "")
        XCTAssertEqual(value.detailTooltip, "")
    }

    func testCompatibilityEqualityDistinguishesCasesAndPayloads() {
        XCTAssertEqual(ExtensionCompatibility.convertible(reasons: ["a"]), .convertible(reasons: ["a"]))
        XCTAssertNotEqual(ExtensionCompatibility.convertible(reasons: ["a"]), .convertible(reasons: ["b"]))
        XCTAssertNotEqual(ExtensionCompatibility.nativeMV3, .convertible(reasons: []))
        XCTAssertNotEqual(ExtensionCompatibility.incompatible(reason: "x"), .incompatible(reason: "y"))
    }

    // MARK: - analyze: manifest validity and rejection

    func testMissingManifestIsIncompatible() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let empty = base.appendingPathComponent("empty", isDirectory: true)
        try ImporterFixtures.makeDirectory(empty)
        XCTAssertEqual(converter.analyze(manifestDir: empty, fromSafariBundle: false),
                       .incompatible(reason: "Missing or invalid manifest.json"))
    }

    func testMalformedManifestIsIncompatible() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let dir = base.appendingPathComponent("bad", isDirectory: true)
        try ImporterFixtures.write("{ \"manifest_version\": ", to: dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(converter.analyze(manifestDir: dir, fromSafariBundle: false),
                       .incompatible(reason: "Missing or invalid manifest.json"))
    }

    func testTopLevelArrayManifestIsIncompatible() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let dir = base.appendingPathComponent("arr", isDirectory: true)
        try ImporterFixtures.write("[1,2,3]", to: dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(converter.analyze(manifestDir: dir, fromSafariBundle: false),
                       .incompatible(reason: "Missing or invalid manifest.json"))
    }

    func testThemeManifestIsRejected() throws {
        XCTAssertEqual(try analyze(["manifest_version": 3, "theme": ["colors": [:]]]),
                       .incompatible(reason: "Browser themes are not supported"))
    }

    func testUnsupportedManifestVersionsAreRejectedWithNumber() throws {
        XCTAssertEqual(try analyze(["manifest_version": 1]), .incompatible(reason: "Unsupported manifest version (1)"))
        XCTAssertEqual(try analyze(["manifest_version": 4]), .incompatible(reason: "Unsupported manifest version (4)"))
        XCTAssertEqual(try analyze(["name": "no version"]), .incompatible(reason: "Unsupported manifest version (0)"))
    }

    func testPlainMV3ManifestIsNativeAndImportable() throws {
        let result = try analyze(["manifest_version": 3, "name": "Plain", "permissions": ["storage"]])
        XCTAssertEqual(result, .nativeMV3)
        XCTAssertTrue(result.isImportable)
    }

    func testMV2WebRequestBlockingWithoutDNRIsIncompatible() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "permissions": ["webRequest", "webRequestBlocking"]]),
                       .incompatible(reason: "Uses MV2 webRequestBlocking (unsupported in Chromium MV3)"))
    }

    func testOptionalWebRequestBlockingAlsoMakesIncompatible() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "optional_permissions": ["webRequestBlocking"]]),
                       .incompatible(reason: "Uses MV2 webRequestBlocking (unsupported in Chromium MV3)"))
    }

    func testWebRequestBlockingWithDeclarativeNetRequestIsConvertibleNotRejected() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "permissions": ["webRequestBlocking", "declarativeNetRequest"]]),
                       .convertible(reasons: ["MV2 → MV3"]))
        XCTAssertEqual(try analyze(["manifest_version": 2, "permissions": ["webRequestBlocking", "declarativeNetRequestWithHostAccess"]]),
                       .convertible(reasons: ["MV2 → MV3"]))
    }

    func testSafariNativeMessagingIsIncompatibleButChromeNativeMessagingIsNot() throws {
        let manifest: [String: Any] = ["manifest_version": 3, "permissions": ["nativeMessaging"]]
        XCTAssertEqual(try analyze(manifest, safari: true), .incompatible(reason: "Requires native Safari host app bridge"))
        XCTAssertEqual(try analyze(manifest, safari: false), .nativeMV3)
    }

    func testMissingBackgroundPageIsIncompatibleNamingThePage() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "background": ["page": "bg.html"]]),
                       .incompatible(reason: "Background page 'bg.html' not found"))
    }

    func testExistingBackgroundPageIsConvertible() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "background": ["page": "bg.html"]], files: ["bg.html": "<html></html>"]),
                       .convertible(reasons: ["MV2 → MV3", "background.page → Service Worker"]))
    }

    // MARK: - analyze: conversion reasons

    func testBackgroundScriptsWithoutServiceWorkerNeedConversion() throws {
        XCTAssertEqual(try analyze(["manifest_version": 3, "background": ["scripts": ["bg.js"]]]),
                       .convertible(reasons: ["background.scripts → Service Worker"]))
    }

    func testBackgroundScriptsWithServiceWorkerNeedNoScriptsReason() throws {
        XCTAssertEqual(try analyze(["manifest_version": 3, "background": ["scripts": ["bg.js"], "service_worker": "sw.js"]]),
                       .nativeMV3)
    }

    func testPersistentBackgroundFlagIsStripped() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "background": ["scripts": ["bg.js"], "persistent": false]]),
                       .convertible(reasons: ["MV2 → MV3", "background.scripts → Service Worker", "strip background.persistent"]))
    }

    func testBrowserActionAndPageActionBothReportActionMigration() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "browser_action": ["default_popup": "p.html"]]),
                       .convertible(reasons: ["MV2 → MV3", "browser_action → action"]))
        XCTAssertEqual(try analyze(["manifest_version": 2, "page_action": [:]]),
                       .convertible(reasons: ["MV2 → MV3", "browser_action → action"]))
    }

    func testHostPatternsInPermissionsReportHostMigration() throws {
        XCTAssertEqual(try analyze(["manifest_version": 3, "permissions": ["storage", "https://a.example.test/*"]]),
                       .convertible(reasons: ["move host patterns → host_permissions"]))
    }

    func testNonEmptyWebAccessibleResourcesReportUpgrade() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "web_accessible_resources": ["a.png"]]),
                       .convertible(reasons: ["MV2 → MV3", "upgrade web_accessible_resources"]))
        XCTAssertEqual(try analyze(["manifest_version": 2, "web_accessible_resources": []]),
                       .convertible(reasons: ["MV2 → MV3"]))
    }

    func testStringCSPReportsUpgradeButObjectCSPDoesNot() throws {
        XCTAssertEqual(try analyze(["manifest_version": 2, "content_security_policy": "script-src 'self'"]),
                       .convertible(reasons: ["MV2 → MV3", "upgrade CSP format"]))
        XCTAssertEqual(try analyze(["manifest_version": 3, "content_security_policy": ["extension_pages": "script-src 'self'"]]),
                       .nativeMV3)
    }

    func testBrowserSpecificSettingsAndApplicationsAreStripped() throws {
        XCTAssertEqual(try analyze(["manifest_version": 3, "browser_specific_settings": ["gecko": ["id": "x"]]]),
                       .convertible(reasons: ["strip Safari/Firefox manifest keys"]))
        XCTAssertEqual(try analyze(["manifest_version": 3, "applications": ["gecko": [:]]]),
                       .convertible(reasons: ["strip Safari/Firefox manifest keys"]))
    }

    func testReasonsAreReportedInStableOrder() throws {
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "browser_action": ["default_popup": "p.html"],
            "permissions": ["https://a.example.test/*"],
            "content_security_policy": "script-src 'self'",
            "browser_specific_settings": [:]
        ]
        XCTAssertEqual(try analyze(manifest, files: ["p.html": "x"]), .convertible(reasons: [
            "MV2 → MV3",
            "browser_action → action",
            "move host patterns → host_permissions",
            "upgrade CSP format",
            "strip Safari/Firefox manifest keys"
        ]))
    }

    func testBrowserNamespaceReferenceNeedsPolyfillOnlyForSafariBundles() throws {
        let manifest: [String: Any] = ["manifest_version": 3, "background": ["service_worker": "sw.js"]]
        let files = ["sw.js": "browser.runtime.sendMessage({})"]
        XCTAssertEqual(try analyze(manifest, files: files, safari: true),
                       .convertible(reasons: ["inject browser.* API polyfill"]))
        XCTAssertEqual(try analyze(manifest, files: files, safari: false), .nativeMV3)
    }

    func testSafariBundleWithoutBrowserReferenceStaysNative() throws {
        XCTAssertEqual(try analyze(["manifest_version": 3, "background": ["service_worker": "sw.js"]],
                                   files: ["sw.js": "chrome.runtime.id"], safari: true),
                       .nativeMV3)
    }

    func testBrowserNamespaceInContentScriptIsDetected() throws {
        let manifest: [String: Any] = ["manifest_version": 3, "content_scripts": [["matches": ["<all_urls>"], "js": ["cs.js"]]]]
        XCTAssertEqual(try analyze(manifest, files: ["cs.js": "browser.tabs.query({})"], safari: true),
                       .convertible(reasons: ["inject browser.* API polyfill"]))
    }

    func testBrowserNamespaceInSeventhScriptIsDetected() throws {
        // Regression lock for P02-3: scripts past the sixth are inspected too.
        var files: [String: String] = [:]
        var js: [String] = []
        for i in 0..<7 {
            files["s\(i).js"] = i == 6 ? "browser.storage.local.get()" : "console.log(\(i))"
            js.append("s\(i).js")
        }
        let manifest: [String: Any] = ["manifest_version": 3, "content_scripts": [["matches": ["<all_urls>"], "js": js]]]
        XCTAssertEqual(try analyze(manifest, files: files, safari: true),
                       .convertible(reasons: ["inject browser.* API polyfill"]))
    }

    func testBrowserNamespaceBeyondScanLimitIsMissedKnownLimitation() throws {
        // Residual P02-3: only the first 64 declared scripts are inspected.
        var files: [String: String] = [:]
        var js: [String] = []
        for i in 0..<70 {
            files["s\(i).js"] = i == 69 ? "browser.runtime.id" : "void \(i)"
            js.append("s\(i).js")
        }
        let manifest: [String: Any] = ["manifest_version": 3, "content_scripts": [["matches": ["<all_urls>"], "js": js]]]
        let result = try analyze(manifest, files: files, safari: true)
        XCTAssertEqual(result, .convertible(reasons: ["inject browser.* API polyfill"]))
    
    }

    func testScriptPathEscapingExtensionIsNotRead() throws {
        // A `..` path must not let analysis read a file outside the extension.
        let base = try ImporterFixtures.makeRoot(self)
        try ImporterFixtures.write("browser.runtime.id", to: base.appendingPathComponent("outside.js"))
        let src = base.appendingPathComponent("ext", isDirectory: true)
        try ImporterFixtures.writeJSON([
            "manifest_version": 3, "content_scripts": [["matches": ["<all_urls>"], "js": ["../outside.js"]]]
        ], to: src.appendingPathComponent("manifest.json"))
        XCTAssertEqual(converter.analyze(manifestDir: src, fromSafariBundle: true), .nativeMV3)
    }

    func testSymlinkedScriptPointingOutsideIsNotRead() throws {
        let base = try ImporterFixtures.makeRoot(self)
        try ImporterFixtures.write("browser.runtime.id", to: base.appendingPathComponent("secret.js"))
        let src = base.appendingPathComponent("ext", isDirectory: true)
        try ImporterFixtures.writeJSON([
            "manifest_version": 3, "content_scripts": [["matches": ["<all_urls>"], "js": ["link.js"]]]
        ], to: src.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: src.appendingPathComponent("link.js"),
            withDestinationURL: base.appendingPathComponent("secret.js")
        )
        XCTAssertEqual(converter.analyze(manifestDir: src, fromSafariBundle: true), .nativeMV3)
    }

    // MARK: - Host pattern detection

    func testHostPatternRecognizesSchemesAndAllURLs() {
        for pattern in ["<all_urls>", "*://*/*", "https://a.example.test/*", "http://x.example.test/", "file:///tmp/"] {
            XCTAssertTrue(ExtensionCompatibilityConverter.isHostPattern(pattern), pattern)
        }
    }

    func testHostPatternRejectsAPIPermissionNames() {
        for name in ["tabs", "storage", "activeTab", "about:blank", "*.example.test", ""] {
            XCTAssertFalse(ExtensionCompatibilityConverter.isHostPattern(name), name)
        }
    }

    // MARK: - Path containment, HTML scripts, polyfill injection, CSP

    func testContainedFileURLAcceptsPathsInsideAndRejectsEscapes() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let dir = base.appendingPathComponent("ext", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        XCTAssertNotNil(converter.containedFileURL("a.js", in: dir))
        XCTAssertNotNil(converter.containedFileURL("/leading/slash.js", in: dir))
        XCTAssertNotNil(converter.containedFileURL("sub/../a.js", in: dir))
        XCTAssertNil(converter.containedFileURL("../x.js", in: dir))
        XCTAssertNil(converter.containedFileURL("sub/../../x.js", in: dir))
        XCTAssertNil(converter.containedFileURL("", in: dir), "the directory itself is not a file")
    }

    func testExtractScriptsFromHTMLResolvesRelativeAndRootPaths() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let dir = base.appendingPathComponent("ext", isDirectory: true)
        try ImporterFixtures.write("""
        <html><head>
        <script src="app/bg.js"></script>
        <script src='quoted.js'></script>
        <script src="/root.js"></script>
        <script src="https://cdn.example.test/x.js"></script>
        <script src="http://cdn.example.test/y.js"></script>
        <script src=""></script>
        <script>inline()</script>
        </head></html>
        """, to: dir.appendingPathComponent("bg/index.html"))
        XCTAssertEqual(converter.extractScriptsFromHTML(relativePath: "bg/index.html", in: dir),
                       ["bg/app/bg.js", "bg/quoted.js", "root.js"])
    }

    func testExtractScriptsFromTopLevelPageUsesBareNames() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let dir = base.appendingPathComponent("ext", isDirectory: true)
        try ImporterFixtures.write(#"<script src="a.js"></script><script src="b.js"></script>"#,
                                   to: dir.appendingPathComponent("index.html"))
        XCTAssertEqual(converter.extractScriptsFromHTML(relativePath: "index.html", in: dir), ["a.js", "b.js"])
    }

    func testExtractScriptsFromMissingOrEscapingPageReturnsEmpty() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let dir = base.appendingPathComponent("ext", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        try ImporterFixtures.write(#"<script src="evil.js"></script>"#, to: base.appendingPathComponent("escape.html"))
        XCTAssertEqual(converter.extractScriptsFromHTML(relativePath: "missing.html", in: dir), [])
        XCTAssertEqual(converter.extractScriptsFromHTML(relativePath: "../escape.html", in: dir), [])
    }

    func testInjectionPlacesPolyfillAfterHeadOpenTag() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let page = base.appendingPathComponent("popup.html")
        try ImporterFixtures.write("<html><head><title>T</title></head><body></body></html>", to: page)
        converter.injectPolyfillIntoHTML(relativePath: "popup.html", polyfillFilename: "sx-mv3-polyfill.js", in: base)
        XCTAssertEqual(readText(page), "<html><head>\n  <script src=\"/sx-mv3-polyfill.js\"></script><title>T</title></head><body></body></html>")
    }

    func testInjectionFallsBackToBeforeFirstScriptTag() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let page = base.appendingPathComponent("p.html")
        try ImporterFixtures.write("<!doctype html><script src='a.js'></script>", to: page)
        converter.injectPolyfillIntoHTML(relativePath: "p.html", polyfillFilename: "sx-mv3-polyfill.js", in: base)
        XCTAssertEqual(readText(page), "<!doctype html><script src=\"/sx-mv3-polyfill.js\"></script>\n<script src='a.js'></script>")
    }

    func testInjectionPrependsWhenPageHasNoHeadOrScript() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let page = base.appendingPathComponent("plain.html")
        try ImporterFixtures.write("hello", to: page)
        converter.injectPolyfillIntoHTML(relativePath: "plain.html", polyfillFilename: "sx-mv3-polyfill.js", in: base)
        XCTAssertEqual(readText(page), "<script src=\"/sx-mv3-polyfill.js\"></script>\nhello")
    }

    func testInjectionIsIdempotent() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let page = base.appendingPathComponent("again.html")
        try ImporterFixtures.write("<head></head>", to: page)
        converter.injectPolyfillIntoHTML(relativePath: "again.html", polyfillFilename: "sx-mv3-polyfill.js", in: base)
        let once = readText(page)
        converter.injectPolyfillIntoHTML(relativePath: "again.html", polyfillFilename: "sx-mv3-polyfill.js", in: base)
        XCTAssertEqual(readText(page), once)
        XCTAssertEqual(once.components(separatedBy: "sx-mv3-polyfill.js").count - 1, 1)
    }

    func testInjectionRefusesToWriteOutsideExtensionDirectory() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let ext = base.appendingPathComponent("ext", isDirectory: true)
        try ImporterFixtures.makeDirectory(ext)
        let outside = base.appendingPathComponent("outside.html")
        try ImporterFixtures.write("<head>untouched</head>", to: outside)
        converter.injectPolyfillIntoHTML(relativePath: "../outside.html", polyfillFilename: "sx-mv3-polyfill.js", in: ext)
        XCTAssertEqual(readText(outside), "<head>untouched</head>")
    }

    func testCSPStripsUnsafeInlineAndSwapsUnsafeEval() {
        let out = converter.sanitizeMV3CSP("script-src 'self' 'unsafe-inline' 'unsafe-eval'; object-src 'self'")
        XCTAssertFalse(out.contains("'unsafe-inline'"))
        XCTAssertFalse(out.contains("'unsafe-eval'"))
        XCTAssertTrue(out.contains("'wasm-unsafe-eval'"))
        XCTAssertTrue(out.hasSuffix("; object-src 'self'"))
    }

    func testCSPKeepsSafeDirectivesUnchanged() {
        XCTAssertEqual(converter.sanitizeMV3CSP("script-src 'self'; object-src 'none'"), "script-src 'self'; object-src 'none'")
    }

    func testEmptyOrWhitespaceCSPGetsSafeDefault() {
        XCTAssertEqual(converter.sanitizeMV3CSP(""), "script-src 'self'; object-src 'self'")
        XCTAssertEqual(converter.sanitizeMV3CSP("   \n  "), "script-src 'self'; object-src 'self'")
        XCTAssertEqual(converter.sanitizeMV3CSP("'unsafe-inline'"), "script-src 'self'; object-src 'self'")
    }

    // MARK: - convertToChromiumMV3: manifest rewrite

    func testConversionRewritesCoreManifestFields() throws {
        let src = try makeSource([
            "manifest_version": 2,
            "name": "Full",
            "version": "2.1",
            "browser_specific_settings": ["gecko": ["id": "x@example.test"]],
            "applications": ["gecko": ["id": "y"]],
            "minimum_safari_version": "15.0",
            "browser_action": ["default_popup": "pop.html"],
            "permissions": ["tabs", "https://a.example.test/*", "webRequestBlocking", "nativeMessaging", "tabs"],
            "optional_permissions": ["clipboardRead", "https://opt.example.test/*"],
            "web_accessible_resources": ["img.png"],
            "content_security_policy": "script-src 'self' 'unsafe-eval'; object-src 'self'"
        ], files: ["pop.html": "<p>pop</p>", "img.png": "x"])
        let dir = try convert(src)
        let m = try readManifest(dir)

        XCTAssertEqual(m["manifest_version"] as? Int, 3)
        XCTAssertNil(m["browser_specific_settings"])
        XCTAssertNil(m["applications"])
        XCTAssertNil(m["minimum_safari_version"])
        XCTAssertNil(m["browser_action"])
        XCTAssertEqual((m["action"] as? [String: Any])?["default_popup"] as? String, "pop.html")
        XCTAssertEqual(m["permissions"] as? [String], ["tabs"], "duplicates removed and MV2 blocking permissions dropped")
        XCTAssertEqual(m["host_permissions"] as? [String], ["https://a.example.test/*"])
        XCTAssertEqual(m["optional_permissions"] as? [String], ["clipboardRead"])
        XCTAssertEqual(m["optional_host_permissions"] as? [String], ["https://opt.example.test/*"])
        let war = m["web_accessible_resources"] as? [[String: Any]]
        XCTAssertEqual(war?.first?["resources"] as? [String], ["img.png"])
        XCTAssertEqual(war?.first?["matches"] as? [String], ["<all_urls>"])
        let csp = (m["content_security_policy"] as? [String: Any])?["extension_pages"] as? String ?? ""
        XCTAssertFalse(csp.contains("'unsafe-eval'"))
        XCTAssertTrue(csp.contains("'wasm-unsafe-eval'"))
        XCTAssertTrue(csp.contains("object-src 'self'"))
    }

    func testExistingActionWinsOverBrowserActionDuringMigration() throws {
        let src = try makeSource([
            "manifest_version": 3,
            "action": ["default_title": "Keep"],
            "browser_action": ["default_title": "Drop"]
        ])
        let m = try readManifest(try convert(src))
        XCTAssertEqual((m["action"] as? [String: Any])?["default_title"] as? String, "Keep")
        XCTAssertNil(m["browser_action"])
    }

    func testPageActionMigratesToActionWhenNoBrowserAction() throws {
        let src = try makeSource(["manifest_version": 2, "page_action": ["default_title": "Page"]])
        let m = try readManifest(try convert(src))
        XCTAssertEqual((m["action"] as? [String: Any])?["default_title"] as? String, "Page")
        XCTAssertNil(m["page_action"])
    }

    func testExistingHostPermissionsAreMergedWithoutDuplicates() throws {
        let src = try makeSource([
            "manifest_version": 3,
            "host_permissions": ["https://a.example.test/*"],
            "permissions": ["https://a.example.test/*", "https://b.example.test/*"]
        ])
        let m = try readManifest(try convert(src))
        XCTAssertEqual(m["host_permissions"] as? [String], ["https://a.example.test/*", "https://b.example.test/*"])
        XCTAssertEqual(m["permissions"] as? [String], [])
    }

    func testMV3ManifestWithoutHostOrWARKeysGetsNoSpuriousKeys() throws {
        let src = try makeSource(["manifest_version": 3, "name": "Lean", "permissions": ["storage"]])
        let m = try readManifest(try convert(src))
        XCTAssertNil(m["host_permissions"])
        XCTAssertNil(m["optional_host_permissions"])
        XCTAssertNil(m["content_security_policy"])
        XCTAssertEqual(m["permissions"] as? [String], ["storage"])
        XCTAssertEqual(m["name"] as? String, "Lean")
    }

    func testEmptyCSPStringGetsSafeDefaultDictionary() throws {
        let src = try makeSource(["manifest_version": 2, "content_security_policy": ""])
        let m = try readManifest(try convert(src))
        XCTAssertEqual((m["content_security_policy"] as? [String: Any])?["extension_pages"] as? String,
                       "script-src 'self'; object-src 'self'")
    }

    // MARK: - convertToChromiumMV3: background generation

    func testBackgroundScriptsBecomeImportScriptsServiceWorker() throws {
        let src = try makeSource([
            "manifest_version": 2,
            "background": ["scripts": ["bg.js", "/util.js"], "persistent": true]
        ], files: ["bg.js": "1", "util.js": "2"])
        let dir = try convert(src)
        let m = try readManifest(dir)
        XCTAssertEqual(m["background"] as? [String: String], ["service_worker": "sx-mv3-sw.js"])
        XCTAssertEqual(readText(dir.appendingPathComponent("sx-mv3-sw.js")),
                       "importScripts(\"/sx-mv3-polyfill.js\", \"/bg.js\", \"/util.js\");\n")
    }

    func testModuleBackgroundBecomesImportStatementsWithModuleType() throws {
        let src = try makeSource([
            "manifest_version": 2,
            "background": ["scripts": ["m.js"], "type": "module"]
        ], files: ["m.js": "export {}"])
        let dir = try convert(src)
        let bg = try XCTUnwrap(try readManifest(dir)["background"] as? [String: String])
        XCTAssertEqual(bg, ["service_worker": "sx-mv3-sw.js", "type": "module"])
        XCTAssertEqual(readText(dir.appendingPathComponent("sx-mv3-sw.js")),
                       "import \"/sx-mv3-polyfill.js\";\nimport \"/m.js\";\n")
    }

    func testScriptNamesWithQuotesStayValidJavaScript() throws {
        // Regression lock for P02-2: names containing quote characters are escaped.
        let src = try makeSource([
            "manifest_version": 2,
            "background": ["scripts": ["worker's.js", "a\"b.js"]]
        ])
        let dir = try convert(src)
        XCTAssertEqual(readText(dir.appendingPathComponent("sx-mv3-sw.js")),
                       "importScripts(\"/sx-mv3-polyfill.js\", \"/worker's.js\", \"/a\\\"b.js\");\n")
    }

    func testModuleScriptNamesWithQuotesAreEscaped() throws {
        let src = try makeSource([
            "manifest_version": 2,
            "background": ["scripts": ["it\"s.js"], "type": "module"]
        ])
        let dir = try convert(src)
        XCTAssertEqual(readText(dir.appendingPathComponent("sx-mv3-sw.js")),
                       "import \"/sx-mv3-polyfill.js\";\nimport \"/it\\\"s.js\";\n")
    }

    func testBackgroundPageScriptsAreExtractedRelativeToPage() throws {
        let src = try makeSource(
            ["manifest_version": 2, "background": ["page": "bg/index.html"]],
            files: ["bg/index.html": #"<script src="app.js"></script><script src="/root.js"></script>"#]
        )
        let dir = try convert(src)
        XCTAssertEqual(readText(dir.appendingPathComponent("sx-mv3-sw.js")),
                       "importScripts(\"/sx-mv3-polyfill.js\", \"/bg/app.js\", \"/root.js\");\n")
    }

    func testBackgroundPageEscapingExtensionYieldsNoBackground() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let src = base.appendingPathComponent("src", isDirectory: true)
        try ImporterFixtures.writeJSON(["manifest_version": 2, "background": ["page": "../escape.html"]],
                                       to: src.appendingPathComponent("manifest.json"))
        try ImporterFixtures.write(#"<script src="evil.js"></script>"#, to: base.appendingPathComponent("escape.html"))
        let m = try readManifest(try convert(src))
        XCTAssertNil(m["background"])
    }

    func testExistingClassicServiceWorkerIsWrappedWithPolyfill() throws {
        let src = try makeSource(["manifest_version": 3, "background": ["service_worker": "sw.js"]], files: ["sw.js": "1"])
        let dir = try convert(src)
        XCTAssertEqual((try readManifest(dir)["background"] as? [String: String])?["service_worker"], "sx-mv3-sw.js")
        XCTAssertEqual(readText(dir.appendingPathComponent("sx-mv3-sw.js")),
                       "importScripts(\"/sx-mv3-polyfill.js\", \"/sw.js\");\n")
    }

    func testExistingModuleServiceWorkerIsKeptAsIs() throws {
        let src = try makeSource(["manifest_version": 3, "background": ["service_worker": "sw.mjs", "type": "module"]])
        let bg = try XCTUnwrap(try readManifest(try convert(src))["background"] as? [String: String])
        XCTAssertEqual(bg, ["service_worker": "sw.mjs", "type": "module"])
    }

    func testBackgroundWithoutScriptsOrWorkerIsRemoved() throws {
        let src = try makeSource(["manifest_version": 2, "background": ["persistent": false]])
        let m = try readManifest(try convert(src))
        XCTAssertNil(m["background"])
    }

    // MARK: - convertToChromiumMV3: content scripts and HTML pages

    func testContentScriptsGetPolyfillFirstExceptMainWorldAndAvoidDuplicates() throws {
        let src = try makeSource([
            "manifest_version": 2,
            "content_scripts": [
                ["matches": ["<all_urls>"], "js": ["cs.js"]],
                ["matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN"],
                ["matches": ["<all_urls>"], "js": ["lower.js"], "world": "main"],
                ["matches": ["<all_urls>"], "js": ["sx-mv3-polyfill.js", "dup.js"]]
            ]
        ])
        let scripts = try XCTUnwrap(try readManifest(try convert(src))["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts[0]["js"] as? [String], ["sx-mv3-polyfill.js", "cs.js"])
        XCTAssertEqual(scripts[1]["js"] as? [String], ["main.js"])
        XCTAssertEqual(scripts[2]["js"] as? [String], ["lower.js"], "lowercase world name is treated as MAIN")
        XCTAssertEqual(scripts[3]["js"] as? [String], ["sx-mv3-polyfill.js", "dup.js"])
    }

    func testPopupOptionsUIAndOptionsPageAreAllPatched() throws {
        let src = try makeSource([
            "manifest_version": 2,
            "browser_action": ["default_popup": "popup.html"],
            "options_ui": ["page": "ui/options.html"],
            "options_page": "legacy.html"
        ], files: [
            "popup.html": "<head></head>",
            "ui/options.html": "<head></head>",
            "legacy.html": "<head></head>"
        ])
        let dir = try convert(src)
        for page in ["popup.html", "ui/options.html", "legacy.html"] {
            XCTAssertTrue(readText(dir.appendingPathComponent(page)).contains("<script src=\"/sx-mv3-polyfill.js\"></script>"), page)
        }
    }

    func testMissingHTMLPageDoesNotFailConversion() throws {
        let src = try makeSource(["manifest_version": 2, "browser_action": ["default_popup": "absent.html"]])
        let dir = try convert(src)
        XCTAssertEqual((try readManifest(dir)["action"] as? [String: Any])?["default_popup"] as? String, "absent.html")
    }

    func testPopupPathEscapingExtensionIsNeverOverwritten() throws {
        // Regression lock for P02-1: the target lives beside the staged extension and must stay untouched.
        let src = try makeSource(["manifest_version": 2, "browser_action": ["default_popup": "../outside.html"]])
        let staging = src.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
        try ImporterFixtures.write("<head>KEEP ME</head>", to: staging.appendingPathComponent("outside.html"))
        _ = try converter.convertToChromiumMV3(sourceDir: src, extensionID: "conv-test", stagingRootOverride: staging)
        XCTAssertEqual(readText(staging.appendingPathComponent("outside.html")), "<head>KEEP ME</head>")
    }

    func testPolyfillFileIsWrittenIntoConvertedBundle() throws {
        let dir = try convert(try makeSource(["manifest_version": 2]))
        let polyfill = readText(dir.appendingPathComponent("sx-mv3-polyfill.js"))
        XCTAssertTrue(polyfill.contains("globalThis.browser"))
        XCTAssertTrue(polyfill.contains("__sxMv3PolyfillInstalled"))
    }

    // MARK: - convertToChromiumMV3: staging, IDs and failure paths

    func testConvertedBundleLandsInSanitizedIDFolderInsideStaging() throws {
        let src = try makeSource(["manifest_version": 3])
        let staging = src.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
        let dir = try converter.convertToChromiumMV3(sourceDir: src, extensionID: "My Ext/1", stagingRootOverride: staging)
        XCTAssertEqual(dir.lastPathComponent, "my-ext-1")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "staging")
    }

    func testTraversalStyleIDStaysInsideStagingAfterSanitizing() throws {
        let src = try makeSource(["manifest_version": 3])
        let staging = src.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
        let dir = try converter.convertToChromiumMV3(sourceDir: src, extensionID: "../escape", stagingRootOverride: staging)
        XCTAssertEqual(dir.lastPathComponent, "..-escape")
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL.path, staging.standardizedFileURL.path)
    }

    func testDotDotIDCannotReachBeyondStagingRoot() throws {
        // Latent (not reachable from the importer, whose IDs are validated): ID ".." sanitizes to "..", so the
        // destination is the staging root's parent, which conversion removes before copying into it.
        let base = try ImporterFixtures.makeRoot(self)
        let keep = base.appendingPathComponent("keep.txt")
        try ImporterFixtures.write("keep", to: keep)
        let elsewhere = try ImporterFixtures.makeRoot(self)
        let src = elsewhere.appendingPathComponent("src", isDirectory: true)
        try ImporterFixtures.writeJSON(["manifest_version": 3], to: src.appendingPathComponent("manifest.json"))
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        _ = try? converter.convertToChromiumMV3(sourceDir: src, extensionID: "..", stagingRootOverride: staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    
    }

    func testReconvertingReplacesPreviousOutput() throws {
        let src = try makeSource(["manifest_version": 3, "name": "First"])
        _ = try convert(src)
        try ImporterFixtures.writeJSON(["manifest_version": 3, "name": "Second"], to: src.appendingPathComponent("manifest.json"))
        let dir = try convert(src)
        XCTAssertEqual(try readManifest(dir)["name"] as? String, "Second")
    }

    func testConversionDoesNotModifySourceDirectory() throws {
        let src = try makeSource(["manifest_version": 2, "browser_action": ["default_popup": "p.html"]], files: ["p.html": "<head></head>"])
        let manifestURL = src.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)
        let htmlBefore = readText(src.appendingPathComponent("p.html"))
        _ = try convert(src)
        XCTAssertEqual(try Data(contentsOf: manifestURL), before)
        XCTAssertEqual(readText(src.appendingPathComponent("p.html")), htmlBefore)
    }

    func testMissingSourceDirectoryThrows() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let missing = base.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try convert(missing))
    }

    func testMissingManifestThrows() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let src = base.appendingPathComponent("src", isDirectory: true)
        try ImporterFixtures.makeDirectory(src)
        XCTAssertThrowsError(try convert(src))
    }

    func testManifestThatIsNotAnObjectThrowsWithDescriptiveError() throws {
        let base = try ImporterFixtures.makeRoot(self)
        let src = base.appendingPathComponent("src", isDirectory: true)
        try ImporterFixtures.write("[\"not\", \"an\", \"object\"]", to: src.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try convert(src)) { error in
            XCTAssertEqual((error as NSError).domain, "com.safarium.ExtConverter")
            XCTAssertEqual((error as NSError).localizedDescription, "Invalid manifest.json")
        }
    }

    func testConvertedManifestIsValidJSONWithStableKeys() throws {
        let src = try makeSource(["manifest_version": 2, "name": "Stable"])
        let dir = try convert(src)
        let text = readText(dir.appendingPathComponent("manifest.json"))
        XCTAssertTrue(text.contains("\"manifest_version\" : 3"))
        XCTAssertTrue(text.contains("\"name\" : \"Stable\""))
    }
}
