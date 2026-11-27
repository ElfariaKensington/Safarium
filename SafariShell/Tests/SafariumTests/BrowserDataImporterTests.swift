import XCTest
import AppKit
@testable import Safarium

/// Profile detection, profile scanning, bookmark/history parsers and the Netscape HTML parser.
/// Every fixture lives under the hermetic sandbox; no real browser profile is ever read.
final class BrowserDataImporterTests: HermeticTestCase {
    private let importer = BrowserDataImporter.shared
    private let showFullAddressKey = "Safarium.Pref.ShowFullAddress"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: showFullAddressKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: showFullAddressKey)
        super.tearDown()
    }

    private func root() throws -> URL { try ImporterFixtures.makeRoot(self) }

    private func emptyScan(_ profile: DetectedBrowserProfile, blocked: Bool = false) -> BrowserProfileScan {
        BrowserProfileScan(profile: profile, bookmarks: [], readingList: [], history: [], extensions: [], accessBlocked: blocked)
    }

    private func profile(_ browser: SupportedBrowserKind, dir: URL, blocked: Bool = false) -> DetectedBrowserProfile {
        DetectedBrowserProfile(browser: browser, profileName: "Test", directory: dir, requiresPermissionGrant: blocked)
    }

    private func isRoot() -> Bool { getuid() == 0 }

    // MARK: - SupportedBrowserKind

    func testEveryBrowserKindHasUniqueBundleIdentifier() {
        let ids = SupportedBrowserKind.allCases.map(\.bundleIdentifier)
        XCTAssertEqual(SupportedBrowserKind.allCases.count, 13)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty && !$0.contains(" ") })
    }

    func testBundleIdentifiersMatchVendorIdentifiers() {
        XCTAssertEqual(SupportedBrowserKind.chrome.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(SupportedBrowserKind.chromeBeta.bundleIdentifier, "com.google.Chrome.beta")
        XCTAssertEqual(SupportedBrowserKind.chromeCanary.bundleIdentifier, "com.google.Chrome.canary")
        XCTAssertEqual(SupportedBrowserKind.safari.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(SupportedBrowserKind.edge.bundleIdentifier, "com.microsoft.edgemac")
        XCTAssertEqual(SupportedBrowserKind.arc.bundleIdentifier, "company.thebrowser.Browser")
        XCTAssertEqual(SupportedBrowserKind.orion.bundleIdentifier, "com.kagi.kagimacOS")
        XCTAssertEqual(SupportedBrowserKind.zen.bundleIdentifier, "app.zen-browser.zen")
    }

    func testShortNamesAbbreviateChromeFamilyOnly() {
        XCTAssertEqual(SupportedBrowserKind.chrome.shortName, "Chrome")
        XCTAssertEqual(SupportedBrowserKind.chromeBeta.shortName, "Chrome Beta")
        XCTAssertEqual(SupportedBrowserKind.chromeCanary.shortName, "Chrome Canary")
        XCTAssertEqual(SupportedBrowserKind.edge.shortName, "Edge")
        XCTAssertEqual(SupportedBrowserKind.operaGX.shortName, "Opera GX")
        XCTAssertEqual(SupportedBrowserKind.safari.shortName, "Safari")
        XCTAssertEqual(SupportedBrowserKind.firefox.shortName, "Firefox")
    }

    func testChromiumFamilyClassificationIsExact() {
        let chromium: Set<SupportedBrowserKind> = [.chrome, .chromeBeta, .chromeCanary, .brave, .edge, .arc, .vivaldi, .opera, .operaGX]
        for kind in SupportedBrowserKind.allCases {
            XCTAssertEqual(kind.isChromiumFamily, chromium.contains(kind), "\(kind)")
        }
        XCTAssertFalse(SupportedBrowserKind.safari.isChromiumFamily)
        XCTAssertFalse(SupportedBrowserKind.firefox.isChromiumFamily)
        XCTAssertFalse(SupportedBrowserKind.zen.isChromiumFamily)
        XCTAssertFalse(SupportedBrowserKind.orion.isChromiumFamily)
    }

    func testAppBundlePathsForSafariIncludeCryptexThenApplications() {
        XCTAssertEqual(SupportedBrowserKind.safari.appBundlePaths, [
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
            "/Applications/Safari.app"
        ])
    }

    func testAppBundlePathsForZenListBothNamingVariants() {
        XCTAssertEqual(SupportedBrowserKind.zen.appBundlePaths, ["/Applications/Zen.app", "/Applications/Zen Browser.app"])
        XCTAssertEqual(SupportedBrowserKind.chrome.appBundlePaths, ["/Applications/Google Chrome.app"])
        XCTAssertEqual(SupportedBrowserKind.operaGX.appBundlePaths, ["/Applications/Opera GX.app"])
    }

    func testEveryKindHasAtLeastOneAppBundlePathUnderApplications() {
        for kind in SupportedBrowserKind.allCases {
            XCTAssertFalse(kind.appBundlePaths.isEmpty, "\(kind)")
            XCTAssertTrue(kind.appBundlePaths.allSatisfy { $0.hasSuffix(".app") }, "\(kind)")
        }
    }

    func testUserDataDirectoriesResolveInsideSandboxHome() {
        for kind in SupportedBrowserKind.allCases {
            XCTAssertTrue(kind.userDataDirectory.path.hasPrefix(Self.sandboxRoot.path), "\(kind): \(kind.userDataDirectory.path)")
        }
    }

    func testUserDataDirectorySuffixesPerBrowser() {
        let expectations: [(SupportedBrowserKind, String)] = [
            (.safari, "Library/Safari"),
            (.chrome, "Library/Application Support/Google/Chrome"),
            (.chromeBeta, "Library/Application Support/Google/Chrome Beta"),
            (.chromeCanary, "Library/Application Support/Google/Chrome Canary"),
            (.brave, "Library/Application Support/BraveSoftware/Brave-Browser"),
            (.edge, "Library/Application Support/Microsoft Edge"),
            (.arc, "Library/Application Support/Arc/User Data"),
            (.vivaldi, "Library/Application Support/Vivaldi"),
            (.opera, "Library/Application Support/com.operasoftware.Opera"),
            (.operaGX, "Library/Application Support/com.operasoftware.OperaGX"),
            (.orion, "Library/Application Support/Orion/Defaults"),
            (.firefox, "Library/Application Support/Firefox/Profiles"),
            (.zen, "Library/Application Support/zen/Profiles")
        ]
        for (kind, suffix) in expectations {
            XCTAssertTrue(kind.userDataDirectory.path.hasSuffix("/" + suffix), "\(kind): \(kind.userDataDirectory.path)")
        }
    }

    func testRawValuesAreDisplayNames() {
        XCTAssertEqual(SupportedBrowserKind(rawValue: "Microsoft Edge"), .edge)
        XCTAssertEqual(SupportedBrowserKind(rawValue: "Opera GX"), .operaGX)
        XCTAssertNil(SupportedBrowserKind(rawValue: "Netscape"))
    }

    // MARK: - Value types

    func testDetectedBrowserProfileEquality() {
        let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let a = DetectedBrowserProfile(browser: .chrome, profileName: "Work", directory: dir, requiresPermissionGrant: false)
        let b = DetectedBrowserProfile(browser: .chrome, profileName: "Work", directory: dir, requiresPermissionGrant: false)
        let c = DetectedBrowserProfile(browser: .chrome, profileName: "Work", directory: dir, requiresPermissionGrant: true)
        let d = DetectedBrowserProfile(browser: .brave, profileName: "Work", directory: dir, requiresPermissionGrant: false)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func testImportedExtensionCandidateEqualityIgnoresNothingAndKeepsFields() {
        let compat = ExtensionCompatibility.convertible(reasons: ["MV2 → MV3"])
        let make = { (name: String) in
            ImportedExtensionCandidate(
                id: ImporterFixtures.validID, name: name, version: "2.0", icon: nil, localDirectory: nil,
                storeID: ImporterFixtures.validID, hasManifestKey: true, isAlreadyInstalled: false,
                manifestVersion: 2, compatibility: compat
            )
        }
        let one = make("Alpha")
        XCTAssertEqual(one, make("Alpha"))
        XCTAssertNotEqual(one, make("Beta"))
        XCTAssertEqual(one.manifestVersion, 2)
        XCTAssertEqual(one.storeID, ImporterFixtures.validID)
        XCTAssertTrue(one.hasManifestKey)
        XCTAssertFalse(one.isAlreadyInstalled)
        XCTAssertEqual(one.compatibility, compat)
    }

    func testBrowserImportResultDefaultsAreAllZero() {
        let r = BrowserImportResult()
        XCTAssertEqual([r.bookmarksImported, r.historyImported, r.readingListImported,
                        r.extensionsImported, r.extensionsSkipped, r.extensionsFailed], [0, 0, 0, 0, 0, 0])
    }

    func testBrowserImportSelectionIsAValueType() {
        var original = BrowserImportSelection(importBookmarks: true, importHistory: false, importReadingList: false, selectedExtensionIDs: ["a"])
        let copy = original
        original.importHistory = true
        original.selectedExtensionIDs.insert("b")
        XCTAssertFalse(copy.importHistory)
        XCTAssertEqual(copy.selectedExtensionIDs, ["a"])
        XCTAssertTrue(original.importHistory)
        XCTAssertEqual(original.selectedExtensionIDs, ["a", "b"])
    }

    func testBrowserProfileScanPreservesBlockedFlagAndProfile() {
        let p = profile(.safari, dir: URL(fileURLWithPath: "/tmp/s", isDirectory: true))
        let scan = emptyScan(p, blocked: true)
        XCTAssertTrue(scan.accessBlocked)
        XCTAssertEqual(scan.profile, p)
        XCTAssertTrue(scan.bookmarks.isEmpty && scan.readingList.isEmpty && scan.history.isEmpty && scan.extensions.isEmpty)
    }

    // MARK: - Extension ID validation

    func testExtensionIDValidatorAcceptsExactly32LettersAToP() {
        XCTAssertTrue(BrowserDataImporter.isValidChromiumExtensionID(ImporterFixtures.validID))
        XCTAssertTrue(BrowserDataImporter.isValidChromiumExtensionID(String(repeating: "a", count: 32)))
        XCTAssertTrue(BrowserDataImporter.isValidChromiumExtensionID(String(repeating: "p", count: 32)))
    }

    func testExtensionIDValidatorRejectsBoundaryLengths() {
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(String(repeating: "a", count: 31)))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(String(repeating: "a", count: 33)))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(""))
    }

    func testExtensionIDValidatorRejectsCharactersOutsideAToP() {
        let base = String(repeating: "a", count: 31)
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(base + "q"))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(base + "`"))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(base + "0"))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(base + "A"))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(base + "-"))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(String(repeating: "a", count: 31) + "é"))
        XCTAssertFalse(BrowserDataImporter.isValidChromiumExtensionID(ImporterFixtures.validID.uppercased()))
    }

    // MARK: - Permission error classification

    func testPermissionErrorDetectsCocoaNoPermissionCodes() {
        XCTAssertTrue(importer.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertTrue(importer.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: 257)))
    }

    func testPermissionErrorDetectsPOSIXEPERMAndEACCES() {
        XCTAssertTrue(importer.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertTrue(importer.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    func testPermissionErrorFollowsUnderlyingError() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertTrue(importer.isPermissionError(outer))
    }

    func testPermissionErrorRejectsUnrelatedErrors() {
        XCTAssertFalse(importer.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
        XCTAssertFalse(importer.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        XCTAssertFalse(importer.isPermissionError(NSError(domain: "Other", code: 1)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
        XCTAssertFalse(importer.isPermissionError(wrapped))
    }

    // MARK: - Profile detection

    func testFirefoxDirectoryWithoutProfilesDetectsNothing() throws {
        let dir = try root().appendingPathComponent("ff", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        let found = importer.detectInstalledProfiles(customDirectories: [.firefox: dir], onlyBrowsers: [.firefox])
        XCTAssertTrue(found.isEmpty)
    }

    func testFirefoxProfileNameIsSuffixAfterLastDot() throws {
        let base = try root().appendingPathComponent("Profiles", isDirectory: true)
        try ImporterFixtures.makeSQLite(at: base.appendingPathComponent("abc123.default-release/places.sqlite"), statements: [])
        try ImporterFixtures.makeDirectory(base.appendingPathComponent("zzz.no-places", isDirectory: true))
        let found = importer.detectInstalledProfiles(customDirectories: [.firefox: base], onlyBrowsers: [.firefox])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.profileName, "default-release")
        XCTAssertEqual(found.first?.directory.lastPathComponent, "abc123.default-release")
        XCTAssertEqual(found.first?.requiresPermissionGrant, false)
    }

    func testFirefoxRootHoldingPlacesDatabaseIsTreatedAsSingleProfile() throws {
        let dir = try root().appendingPathComponent("myprofile", isDirectory: true)
        try ImporterFixtures.makeSQLite(at: dir.appendingPathComponent("places.sqlite"), statements: [])
        let found = importer.detectInstalledProfiles(customDirectories: [.zen: dir], onlyBrowsers: [.zen])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.profileName, "myprofile")
        XCTAssertEqual(found.first?.browser, .zen)
    }

    func testChromiumSingleProfileDirectoryDetectedDirectly() throws {
        let dir = try root().appendingPathComponent("Chrome/Profile 9", isDirectory: true)
        try ImporterFixtures.write("{}", to: dir.appendingPathComponent("Bookmarks"))
        let found = importer.detectInstalledProfiles(customDirectories: [.chrome: dir], onlyBrowsers: [.chrome])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.profileName, "Profile 9")
        XCTAssertEqual(found.first?.directory, dir)
        XCTAssertEqual(found.first?.requiresPermissionGrant, false)
    }

    func testChromiumProfilesSortedDefaultFirstThenNaturalName() throws {
        let base = try root().appendingPathComponent("Chrome", isDirectory: true)
        for name in ["Profile 2", "Default", "Profile 10", "Profile 1"] {
            try ImporterFixtures.write("{}", to: base.appendingPathComponent("\(name)/History"))
        }
        try ImporterFixtures.write("{}", to: base.appendingPathComponent("Profile 3/Preferences"))
        try ImporterFixtures.write("{}", to: base.appendingPathComponent("Guest Profile/History"))
        try ImporterFixtures.write("{}", to: base.appendingPathComponent("System Profile/History"))
        let found = importer.detectInstalledProfiles(customDirectories: [.chrome: base], onlyBrowsers: [.chrome])
        XCTAssertEqual(found.map(\.profileName), ["Default", "Profile 1", "Profile 10", "Profile 2"])
    }

    func testChromiumLocalStateSuppliesProfileDisplayNames() throws {
        let base = try root().appendingPathComponent("Chrome", isDirectory: true)
        try ImporterFixtures.write("{}", to: base.appendingPathComponent("Profile 2/Bookmarks"))
        try ImporterFixtures.write("{}", to: base.appendingPathComponent("Default/Bookmarks"))
        try ImporterFixtures.writeJSON([
            "profile": ["info_cache": [
                "Profile 2": ["name": "Work"],
                "Default": ["name": ""]
            ]]
        ], to: base.appendingPathComponent("Local State"))
        let found = importer.detectInstalledProfiles(customDirectories: [.chrome: base], onlyBrowsers: [.chrome])
        XCTAssertEqual(found.map(\.profileName), ["Default", "Work"])
    }

    func testChromiumProfileWithOnlyExtensionsFolderIsDetected() throws {
        let base = try root().appendingPathComponent("Chrome", isDirectory: true)
        try ImporterFixtures.makeDirectory(base.appendingPathComponent("Default/Extensions", isDirectory: true))
        let found = importer.detectInstalledProfiles(customDirectories: [.chrome: base], onlyBrowsers: [.chrome])
        XCTAssertEqual(found.map(\.profileName), ["Default"])
    }

    func testChromiumEmptyProfileFolderIsNotDetected() throws {
        let base = try root().appendingPathComponent("Chrome", isDirectory: true)
        try ImporterFixtures.makeDirectory(base.appendingPathComponent("Default", isDirectory: true))
        let found = importer.detectInstalledProfiles(customDirectories: [.chrome: base], onlyBrowsers: [.chrome])
        // Only the installed-app fallback can add a profile here, and it is always labelled "Default".
        XCTAssertTrue(found.allSatisfy { $0.profileName == "Default" && $0.directory == base })
        XCTAssertEqual(found.count, SupportedBrowserKind.chrome.isAppInstalled ? 1 : 0)
    }

    func testChromiumMissingDirectoryWithoutInstalledAppIsSkipped() throws {
        try XCTSkipIf(SupportedBrowserKind.brave.isAppInstalled, "Brave is installed on this machine")
        let missing = try root().appendingPathComponent("does-not-exist", isDirectory: true)
        let found = importer.detectInstalledProfiles(customDirectories: [.brave: missing], onlyBrowsers: [.brave])
        XCTAssertTrue(found.isEmpty)
    }

    func testSafariWithReadableHistoryIsNotBlocked() throws {
        let dir = try root().appendingPathComponent("Safari", isDirectory: true)
        try ImporterFixtures.write("x", to: dir.appendingPathComponent("History.db"))
        let found = importer.detectInstalledProfiles(customDirectories: [.safari: dir], onlyBrowsers: [.safari])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.profileName, "Default")
        XCTAssertEqual(found.first?.requiresPermissionGrant, false)
    }

    func testSafariEmptyDirectoryRequiresPermissionGrant() throws {
        let dir = try root().appendingPathComponent("Safari", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        let found = importer.detectInstalledProfiles(customDirectories: [.safari: dir], onlyBrowsers: [.safari])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.requiresPermissionGrant, true)
    }

    func testMissingSafariDirectoryStillListedBecauseSafariIsInstalled() throws {
        try XCTSkipUnless(SupportedBrowserKind.safari.isAppInstalled, "Safari app not found")
        let missing = try root().appendingPathComponent("nope", isDirectory: true)
        let found = importer.detectInstalledProfiles(customDirectories: [.safari: missing], onlyBrowsers: [.safari])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.requiresPermissionGrant, true)
    }

    func testOrionWithFavouritesPlistIsDetectedWithoutGrant() throws {
        let dir = try root().appendingPathComponent("Orion", isDirectory: true)
        try ImporterFixtures.write("x", to: dir.appendingPathComponent("favourites.plist"))
        let found = importer.detectInstalledProfiles(customDirectories: [.orion: dir], onlyBrowsers: [.orion])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.requiresPermissionGrant, false)
    }

    func testUnreadableChromiumRootIsReportedAsNeedingPermission() throws {
        try XCTSkipIf(isRoot(), "root ignores directory permissions")
        let dir = try root().appendingPathComponent("LockedChrome", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let found = importer.detectInstalledProfiles(customDirectories: [.chrome: dir], onlyBrowsers: [.chrome])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.requiresPermissionGrant, true)
        XCTAssertEqual(found.first?.profileName, "Default")
    }

    func testUnreadableOrionRootIsReportedAsNeedingPermission() throws {
        try XCTSkipIf(isRoot(), "root ignores directory permissions")
        let dir = try root().appendingPathComponent("LockedOrion", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let found = importer.detectInstalledProfiles(customDirectories: [.orion: dir], onlyBrowsers: [.orion])
        XCTAssertEqual(found.first?.requiresPermissionGrant, true)
    }

    func testDetectProfilesForSingleBrowserMatchesCustomDetectionWithDefaults() {
        // Real home is sandboxed, so the default data directories do not exist here.
        let found = importer.detectProfiles(for: .firefox)
        XCTAssertTrue(found.allSatisfy { $0.browser == .firefox })
        XCTAssertTrue(found.allSatisfy { $0.directory.path.hasPrefix(Self.sandboxRoot.path) },
                      "default lookup must resolve inside the sandboxed home")
    }

    func testResultsWithInstalledBrowsersComeBeforeResidualOnes() throws {
        try XCTSkipUnless(SupportedBrowserKind.safari.isAppInstalled && !SupportedBrowserKind.firefox.isAppInstalled,
                          "needs Safari installed and Firefox absent")
        let ffDir = try root().appendingPathComponent("ff", isDirectory: true)
        try ImporterFixtures.makeSQLite(at: ffDir.appendingPathComponent("p.default/places.sqlite"), statements: [])
        let safariDir = try root().appendingPathComponent("Safari", isDirectory: true)
        try ImporterFixtures.makeDirectory(safariDir)
        let found = importer.detectInstalledProfiles(
            customDirectories: [.firefox: ffDir, .safari: safariDir],
            onlyBrowsers: [.firefox, .safari]
        )
        XCTAssertEqual(found.map(\.browser), [.safari, .firefox])
    }

    // MARK: - Scanning: dispatch and blocked states

    func testScanReturnsBlockedWithoutReadingWhenPermissionRequiredForNonSafari() throws {
        let dir = try root().appendingPathComponent("Chrome", isDirectory: true)
        try ImporterFixtures.writeJSON(ImporterFixtures.chromeBookmarksFile(bar: [
            ImporterFixtures.chromeURL("A", "https://a.example.test/")
        ]), to: dir.appendingPathComponent("Bookmarks"))
        let scan = importer.scan(profile: profile(.chrome, dir: dir, blocked: true), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertTrue(scan.accessBlocked)
        XCTAssertTrue(scan.bookmarks.isEmpty)
    }

    func testScanIgnoresPermissionFlagForSafariAndReadsReadableFiles() throws {
        let dir = try root().appendingPathComponent("Safari", isDirectory: true)
        try ImporterFixtures.writePlist(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariFolder("BookmarksBar", [ImporterFixtures.safariLeaf("A", "https://s.example.test/")])
        ]), to: dir.appendingPathComponent("Bookmarks.plist"))
        let scan = importer.scan(profile: profile(.safari, dir: dir, blocked: true), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertFalse(scan.accessBlocked)
        XCTAssertEqual(scan.bookmarks.map(\.url), ["https://s.example.test/"])
    }

    func testScanSafariBlockedWhenNeitherFileReadable() throws {
        let dir = try root().appendingPathComponent("Safari", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        let scan = importer.scan(profile: profile(.safari, dir: dir), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertTrue(scan.accessBlocked)
        XCTAssertTrue(scan.bookmarks.isEmpty && scan.history.isEmpty && scan.readingList.isEmpty)
    }

    func testScanChromiumMissingDirectoryIsNotReportedAsBlocked() throws {
        let missing = try root().appendingPathComponent("gone", isDirectory: true)
        let scan = importer.scan(profile: profile(.chrome, dir: missing), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertFalse(scan.accessBlocked)
        XCTAssertTrue(scan.bookmarks.isEmpty)
        XCTAssertTrue(scan.history.isEmpty)
        XCTAssertTrue(scan.extensions.isEmpty)
    }

    func testScanChromiumUnreadableDirectoryIsBlocked() throws {
        try XCTSkipIf(isRoot(), "root ignores directory permissions")
        let dir = try root().appendingPathComponent("LockedChrome", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let scan = importer.scan(profile: profile(.chrome, dir: dir), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertTrue(scan.accessBlocked)
    }

    func testScanChromiumCollectsBookmarksHistoryAndExtensions() throws {
        let dir = try root().appendingPathComponent("Chrome/Default", isDirectory: true)
        try ImporterFixtures.writeJSON(ImporterFixtures.chromeBookmarksFile(bar: [
            ImporterFixtures.chromeURL("Site", "https://scan.example.test/page")
        ]), to: dir.appendingPathComponent("Bookmarks"))
        try ImporterFixtures.makeSQLite(at: dir.appendingPathComponent("History"), statements: [
            "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER)",
            "INSERT INTO urls VALUES (1, 'https://hist.example.test/', 'Hist', 3, 13360000000000000, 0)"
        ])
        try ImporterFixtures.writeChromiumExtension(profileDir: dir, id: ImporterFixtures.validID, version: "1.0", manifest: [
            "manifest_version": 3, "name": "Scanned Ext", "version": "1.0"
        ])
        let scan = importer.scan(profile: profile(.chrome, dir: dir), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertFalse(scan.accessBlocked)
        XCTAssertEqual(scan.bookmarks.map(\.url), ["https://scan.example.test/page"])
        XCTAssertEqual(scan.history.map(\.url), ["https://hist.example.test/"])
        XCTAssertEqual(scan.extensions.map(\.name), ["Scanned Ext"])
    }

    func testScanOrionReadsFavouritesPlistAndHistoryDatabaseFromProfile() throws {
        let dir = try root().appendingPathComponent("Orion", isDirectory: true)
        try ImporterFixtures.writePlist(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariLeaf("Orion Site", "https://orion.example.test/")
        ]), to: dir.appendingPathComponent("favourites.plist"))
        let scan = importer.scan(profile: profile(.orion, dir: dir), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertFalse(scan.accessBlocked)
        XCTAssertEqual(scan.bookmarks.map(\.title), ["Orion Site"])
        XCTAssertTrue(scan.history.isEmpty)
    }

    // MARK: - Chromium bookmarks parser

    private func chromiumBookmarks(_ file: [String: Any]) throws -> ([AssetLoader.BookmarkEntry], [AssetLoader.ReadingListItem]) {
        let dir = try root()
        let url = dir.appendingPathComponent("Bookmarks")
        try ImporterFixtures.writeJSON(file, to: url)
        return importer.parseChromiumBookmarks(fileURL: url)
    }

    func testChromiumBookmarksFlattenFoldersAndKeepOrder() throws {
        let (bm, rl) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(
            bar: [
                ImporterFixtures.chromeFolder("Work", [
                    ImporterFixtures.chromeURL("One", "https://one.example.test/"),
                    ImporterFixtures.chromeFolder("Deeper", [ImporterFixtures.chromeURL("Two", "https://two.example.test/")])
                ]),
                ImporterFixtures.chromeURL("Three", "https://three.example.test/")
            ],
            other: [ImporterFixtures.chromeURL("Four", "https://four.example.test/")]
        ))
        XCTAssertTrue(rl.isEmpty)
        XCTAssertEqual(bm.map(\.title), ["One", "Two", "Three", "Four"])
        XCTAssertTrue(bm.allSatisfy { $0.id.hasPrefix("imp-bm-") && $0.color == nil })
    }

    func testChromiumBookmarkTitleIsTrimmedAndEmptyTitleFallsBackToDomain() throws {
        let (bm, _) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(bar: [
            ImporterFixtures.chromeURL("   Padded  \n", "https://padded.example.test/"),
            ImporterFixtures.chromeURL("   ", "https://www.fallback.example.test/some/path")
        ]))
        XCTAssertEqual(bm.map(\.title), ["Padded", "fallback.example.test"])
    }

    func testChromiumReadingListFolderIsSplitFromBookmarks() throws {
        let (bm, rl) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(bar: [
            ImporterFixtures.chromeURL("Plain", "https://plain.example.test/"),
            ImporterFixtures.chromeFolder("reading list", [
                ImporterFixtures.chromeURL("Saved", "https://saved.example.test/"),
                ImporterFixtures.chromeFolder("Nested", [ImporterFixtures.chromeURL("Deep", "https://deep-rl.example.test/")])
            ])
        ]))
        XCTAssertEqual(bm.map(\.url), ["https://plain.example.test/"])
        XCTAssertEqual(rl.map(\.url), ["https://saved.example.test/", "https://deep-rl.example.test/"])
        XCTAssertTrue(rl.allSatisfy { $0.id.hasPrefix("imp-rl-") })
    }

    func testChromiumDuplicateURLsWithinCollectionAreDeduplicated() throws {
        let (bm, _) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(bar: [
            ImporterFixtures.chromeURL("First", "https://dup.example.test/page/"),
            ImporterFixtures.chromeURL("Second", "https://www.dup.example.test/page"),
            ImporterFixtures.chromeURL("Third", "HTTPS://DUP.example.test/page")
        ]))
        XCTAssertEqual(bm.map(\.title), ["First"])
    }

    func testChromiumSameURLInBookmarksAndReadingListIsKeptInBoth() throws {
        // Regression lock for P02-4: dedupe is per destination collection.
        let (bm, rl) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(bar: [
            ImporterFixtures.chromeURL("Bookmark", "https://shared.example.test/"),
            ImporterFixtures.chromeFolder("Reading List", [ImporterFixtures.chromeURL("Saved", "https://shared.example.test/")])
        ]))
        XCTAssertEqual(bm.map(\.title), ["Bookmark"])
        XCTAssertEqual(rl.map(\.title), ["Saved"])
    }

    func testChromiumRejectsNonWebURLs() throws {
        let (bm, rl) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(bar: [
            ImporterFixtures.chromeURL("Chrome", "chrome://settings"),
            ImporterFixtures.chromeURL("Script", "javascript:alert(1)"),
            ImporterFixtures.chromeURL("Bare", "https://"),
            ImporterFixtures.chromeURL("Spaces", "https://exa mple.test/"),
            ImporterFixtures.chromeURL("Ftp", "ftp://files.example.test/"),
            ImporterFixtures.chromeURL("Empty", "")
        ]))
        XCTAssertTrue(bm.isEmpty)
        XCTAssertTrue(rl.isEmpty)
    }

    func testChromiumOnlyRootsBookmarkBarOtherAndSyncedAreRead() throws {
        let (bm, _) = try chromiumBookmarks([
            "roots": [
                "bookmark_bar": ImporterFixtures.chromeFolder("bar", [ImporterFixtures.chromeURL("Bar", "https://bar.example.test/")]),
                "trash": ImporterFixtures.chromeFolder("trash", [ImporterFixtures.chromeURL("Trash", "https://trash.example.test/")]),
                "synced": ImporterFixtures.chromeFolder("synced", [ImporterFixtures.chromeURL("Synced", "https://synced.example.test/")])
            ]
        ])
        XCTAssertEqual(bm.map(\.title), ["Bar", "Synced"])
    }

    func testChromiumMalformedJSONYieldsNothing() throws {
        let dir = try root()
        let url = dir.appendingPathComponent("Bookmarks")
        try ImporterFixtures.write("{ not json", to: url)
        let (bm, rl) = importer.parseChromiumBookmarks(fileURL: url)
        XCTAssertTrue(bm.isEmpty && rl.isEmpty)
    }

    func testChromiumMissingFileAndMissingRootsYieldNothing() throws {
        let dir = try root()
        let (bm, rl) = importer.parseChromiumBookmarks(fileURL: dir.appendingPathComponent("absent"))
        XCTAssertTrue(bm.isEmpty && rl.isEmpty)
        let (bm2, rl2) = try chromiumBookmarks(["roots": 5])
        XCTAssertTrue(bm2.isEmpty && rl2.isEmpty)
    }

    func testChromiumFolderNestingBeyondCapIsDroppedWithoutCrashing() throws {
        // Depth counts from the bookmark bar (depth 0). 30 folders put the URL at depth 31 (kept);
        // 200 folders put it far past the 64 cap, which must stop the walk instead of overflowing the stack.
        func nested(folders: Int) -> [String: Any] {
            var node: [String: Any] = ImporterFixtures.chromeURL("Leaf", "https://leaf.example.test/\(folders)")
            for i in 0..<folders {
                node = ImporterFixtures.chromeFolder("f\(i)", [node])
            }
            return node
        }
        let (shallow, _) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(bar: [nested(folders: 30)]))
        XCTAssertEqual(shallow.map(\.title), ["Leaf"])

        let (deep, _) = try chromiumBookmarks(ImporterFixtures.chromeBookmarksFile(bar: [nested(folders: 200)]))
        XCTAssertTrue(deep.isEmpty)
    }

    // MARK: - Chromium history parser

    private func makeChromiumHistory(_ rows: [String]) throws -> URL {
        let url = try root().appendingPathComponent("History")
        try ImporterFixtures.makeSQLite(at: url, statements: [
            "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER NOT NULL DEFAULT 0)"
        ] + rows)
        return url
    }

    /// Chrome stores microseconds since 1601-01-01; this converts a Unix second count into that form.
    private func chromeMicros(unix: Int) -> Int {
        (unix + 11_644_473_600) * 1_000_000
    }

    func testChromiumHistoryOrderedByRecencyAndLimited() throws {
        let url = try makeChromiumHistory([
            "INSERT INTO urls VALUES (1, 'https://old.example.test/', 'Old', 1, \(chromeMicros(unix: 1_700_000_000)), 0)",
            "INSERT INTO urls VALUES (2, 'https://new.example.test/', 'New', 1, \(chromeMicros(unix: 1_750_000_000)), 0)",
            "INSERT INTO urls VALUES (3, 'https://mid.example.test/', 'Mid', 1, \(chromeMicros(unix: 1_720_000_000)), 0)"
        ])
        let all = importer.parseChromiumHistory(dbURL: url)
        XCTAssertEqual(all.map(\.title), ["New", "Mid", "Old"])
        let limited = importer.parseChromiumHistory(dbURL: url, limit: 2)
        XCTAssertEqual(limited.map(\.title), ["New", "Mid"])
    }

    func testChromiumHistorySkipsHiddenNonHTTPAndInvalidURLs() throws {
        let url = try makeChromiumHistory([
            "INSERT INTO urls VALUES (1, 'https://hidden.example.test/', 'Hidden', 1, \(chromeMicros(unix: 1_750_000_000)), 1)",
            "INSERT INTO urls VALUES (2, 'chrome://history', 'Internal', 1, \(chromeMicros(unix: 1_750_000_000)), 0)",
            "INSERT INTO urls VALUES (3, 'https://', 'NoHost', 1, \(chromeMicros(unix: 1_750_000_000)), 0)",
            "INSERT INTO urls VALUES (4, 'http://kept.example.test/', 'Kept', 1, \(chromeMicros(unix: 1_750_000_000)), 0)"
        ])
        XCTAssertEqual(importer.parseChromiumHistory(dbURL: url).map(\.url), ["http://kept.example.test/"])
    }

    func testChromiumHistoryTitleTrimmedAndEmptyTitleUsesDomain() throws {
        let url = try makeChromiumHistory([
            "INSERT INTO urls VALUES (1, 'https://www.titled.example.test/a', '  Hello  ', 4, \(chromeMicros(unix: 1_750_000_000)), 0)",
            "INSERT INTO urls VALUES (2, 'https://www.untitled.example.test/b', '', 2, \(chromeMicros(unix: 1_740_000_000)), 0)"
        ])
        let entries = importer.parseChromiumHistory(dbURL: url)
        XCTAssertEqual(entries.map(\.title), ["Hello", "untitled.example.test"])
        XCTAssertEqual(entries.map(\.visitCount), [4, 2])
    }

    func testChromiumHistoryVisitCountFloorIsOne() throws {
        let url = try makeChromiumHistory([
            "INSERT INTO urls VALUES (1, 'https://zero.example.test/', 'Zero', 0, \(chromeMicros(unix: 1_750_000_000)), 0)",
            "INSERT INTO urls VALUES (2, 'https://neg.example.test/', 'Neg', -7, \(chromeMicros(unix: 1_750_000_000)), 0)"
        ])
        XCTAssertEqual(importer.parseChromiumHistory(dbURL: url).map(\.visitCount), [1, 1])
    }

    func testChromiumHistoryTimestampConvertsFromChromeEpoch() throws {
        let url = try makeChromiumHistory([
            "INSERT INTO urls VALUES (1, 'https://time.example.test/', 'T', 1, \(chromeMicros(unix: 1_700_000_000)), 0)"
        ])
        let entry = try XCTUnwrap(importer.parseChromiumHistory(dbURL: url).first)
        XCTAssertEqual(entry.lastVisited.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testChromiumHistoryOutOfRangeTimestampFallsBackToNow() throws {
        let url = try makeChromiumHistory([
            "INSERT INTO urls VALUES (1, 'https://zerotime.example.test/', 'Z', 1, 0, 0)"
        ])
        let before = Date()
        let entry = try XCTUnwrap(importer.parseChromiumHistory(dbURL: url).first)
        XCTAssertGreaterThanOrEqual(entry.lastVisited, before.addingTimeInterval(-5))
        XCTAssertLessThanOrEqual(entry.lastVisited, Date().addingTimeInterval(5))
    }

    func testChromiumHistoryMissingOrCorruptDatabaseYieldsEmpty() throws {
        let dir = try root()
        XCTAssertTrue(importer.parseChromiumHistory(dbURL: dir.appendingPathComponent("missing")).isEmpty)
        let corrupt = dir.appendingPathComponent("corrupt")
        try ImporterFixtures.write("this is not a sqlite database at all", to: corrupt)
        XCTAssertTrue(importer.parseChromiumHistory(dbURL: corrupt).isEmpty)
    }

    // MARK: - Chromium extensions

    private func chromiumProfile() throws -> URL {
        try root().appendingPathComponent("Profile", isDirectory: true)
    }

    func testExtensionScanPicksHighestNumericVersionDirectory() throws {
        let profile = try chromiumProfile()
        for v in ["1.9.0", "1.10.0", "1.2.0"] {
            try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: v, manifest: [
                "manifest_version": 3, "name": "Versioned", "version": v
            ])
        }
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.count, 1)
        XCTAssertEqual(scan.extensions.first?.version, "1.10.0")
        XCTAssertEqual(scan.extensions.first?.localDirectory?.lastPathComponent, "1.10.0")
        XCTAssertEqual(scan.extensions.first?.storeID, ImporterFixtures.validID)
    }

    func testExtensionScanSkipsIgnoredComponentsInvalidIDsAndThemes() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.ignoredComponentID, version: "1", manifest: ["name": "Payments"])
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: "not-a-real-id", version: "1", manifest: ["name": "Bogus"])
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.otherValidID, version: "1", manifest: [
            "name": "Dark Theme", "theme": ["colors": [:]]
        ])
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: ["name": "Keeper"])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.map(\.name), ["Keeper"])
    }

    func testExtensionVersionDirectoryWithoutManifestIsIgnored() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.makeDirectory(profile.appendingPathComponent("Extensions/\(ImporterFixtures.validID)/9.9.9", isDirectory: true))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertTrue(scan.extensions.isEmpty)
    }

    func testExtensionCandidatesAreSortedByNameCaseInsensitively() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: ["name": "zeta"])
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.otherValidID, version: "1", manifest: ["name": "Alpha"])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.map(\.name), ["Alpha", "zeta"])
    }

    func testSideloadedExtensionFromPreferencesIsImportedWithoutStoreID() throws {
        let profile = try chromiumProfile()
        let unpacked = try root().appendingPathComponent("unpacked-src", isDirectory: true)
        try ImporterFixtures.writeJSON(["manifest_version": 3, "name": "Sideload", "version": "0.1", "key": "MIIB"], to: unpacked.appendingPathComponent("manifest.json"))
        try ImporterFixtures.writeJSON([
            "extensions": ["settings": [ImporterFixtures.validID: ["path": unpacked.path]]]
        ], to: profile.appendingPathComponent("Preferences"))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        let ext = try XCTUnwrap(scan.extensions.first)
        XCTAssertEqual(scan.extensions.count, 1)
        XCTAssertNil(ext.storeID)
        XCTAssertTrue(ext.hasManifestKey)
        XCTAssertEqual(ext.name, "Sideload")
        XCTAssertEqual(ext.localDirectory?.lastPathComponent, "unpacked-src")
    }

    func testRelativeSideloadPathResolvesAgainstExtensionsFolder() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.otherValidID, version: "1", manifest: ["name": "Rel"])
        // Keep the directory-scan copy out of the way so only the preference path is used.
        try FileManager.default.removeItem(at: profile.appendingPathComponent("Extensions/\(ImporterFixtures.otherValidID)"))
        let relDir = profile.appendingPathComponent("Extensions/local-copy", isDirectory: true)
        try ImporterFixtures.writeJSON(["manifest_version": 3, "name": "Rel"], to: relDir.appendingPathComponent("manifest.json"))
        try ImporterFixtures.writeJSON([
            "extensions": ["settings": [ImporterFixtures.otherValidID: ["path": "local-copy"]]]
        ], to: profile.appendingPathComponent("Preferences"))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.map(\.name), ["Rel"])
        XCTAssertEqual(scan.extensions.first?.localDirectory?.lastPathComponent, "local-copy")
    }

    func testSecurePreferencesIsUsedWhenPreferencesMissing() throws {
        let profile = try chromiumProfile()
        let unpacked = try root().appendingPathComponent("secure-src", isDirectory: true)
        try ImporterFixtures.writeJSON(["manifest_version": 3, "name": "Secure"], to: unpacked.appendingPathComponent("manifest.json"))
        try ImporterFixtures.writeJSON([
            "extensions": ["settings": [ImporterFixtures.validID: ["path": unpacked.path]]]
        ], to: profile.appendingPathComponent("Secure Preferences"))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.map(\.name), ["Secure"])
    }

    func testPreferenceEntryWithoutManifestOrPathIsSkipped() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeJSON([
            "extensions": ["settings": [
                ImporterFixtures.validID: ["path": "/nonexistent/dir"],
                ImporterFixtures.otherValidID: ["path": ""],
                ImporterFixtures.ignoredComponentID: ["path": "/nonexistent/x"]
            ]]
        ], to: profile.appendingPathComponent("Preferences"))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertTrue(scan.extensions.isEmpty)
    }

    func testAlreadyInstalledMatchesByIDOrByName() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: ["name": "Ad Blocker"])
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.otherValidID, version: "1", manifest: ["name": "Other Tool"])
        let scan = importer.scan(
            profile: self.profile(.chrome, dir: profile),
            installedExtensionIDs: [ImporterFixtures.validID],
            installedExtensionNames: ["other tool"]
        )
        XCTAssertEqual(scan.extensions.count, 2)
        XCTAssertTrue(scan.extensions.allSatisfy(\.isAlreadyInstalled))

        let neither = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: ["ad blocker2"])
        XCTAssertTrue(neither.extensions.allSatisfy { !$0.isAlreadyInstalled })
    }

    func testLocalizedManifestNameResolvesFromDefaultLocale() throws {
        let profile = try chromiumProfile()
        let dir = try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [
            "name": "__MSG_appName__", "default_locale": "de"
        ])
        try ImporterFixtures.writeJSON(["appName": ["message": "Lokalisiert"]], to: dir.appendingPathComponent("_locales/de/messages.json"))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.first?.name, "Lokalisiert")
    }

    func testLocalizedNameFallsBackToEnglishAndKeyIsCaseInsensitive() throws {
        let profile = try chromiumProfile()
        let dir = try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [
            "name": "__MSG_AppName__"
        ])
        try ImporterFixtures.writeJSON(["appname": ["message": "English Name"]], to: dir.appendingPathComponent("_locales/en_US/messages.json"))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.first?.name, "English Name")
    }

    func testUnresolvableLocalizedNameKeepsRawPlaceholder() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [
            "name": "__MSG_missing__"
        ])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.first?.name, "__MSG_missing__")
    }

    func testExtensionDefaultsWhenManifestFieldsAreMissing() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [:])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        let ext = try XCTUnwrap(scan.extensions.first)
        XCTAssertEqual(ext.name, ImporterFixtures.validID, "name falls back to the extension ID")
        XCTAssertEqual(ext.version, "1.0")
        XCTAssertEqual(ext.manifestVersion, 3)
        XCTAssertFalse(ext.hasManifestKey)
        XCTAssertNil(ext.icon)
    }

    func testEmptyManifestNameFallsBackToExtensionID() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: ["name": ""])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.first?.name, ImporterFixtures.validID)
    }

    func testManifestKeyAndLegacyVersionAreRead() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [
            "manifest_version": 2, "name": "Legacy", "key": "", "version": "4.5"
        ])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        let ext = try XCTUnwrap(scan.extensions.first)
        XCTAssertEqual(ext.manifestVersion, 2)
        XCTAssertFalse(ext.hasManifestKey, "an empty key string does not count as a manifest key")
        XCTAssertEqual(ext.version, "4.5")
        XCTAssertEqual(ext.compatibility, .convertible(reasons: ["MV2 → MV3"]))
    }

    func testIconLoadedFromActionDefaultIconAndSizedTo22() throws {
        let profile = try chromiumProfile()
        let dir = try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [
            "name": "Iconic",
            "action": ["default_icon": ["16": "icons/16.png", "48": "icons/48.png"]]
        ])
        try ImporterFixtures.writePNG(to: dir.appendingPathComponent("icons/48.png"))
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        let icon = try XCTUnwrap(scan.extensions.first?.icon)
        XCTAssertEqual(icon.size.width, 22)
        XCTAssertEqual(icon.size.height, 22)
    }

    func testMissingIconFileYieldsNilIconWithoutFailingCandidate() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [
            "name": "NoIcon", "icons": ["128": "missing.png"]
        ])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.map(\.name), ["NoIcon"])
        XCTAssertNil(scan.extensions.first?.icon)
    }

    func testCandidateCompatibilityComesFromConverterAnalysis() throws {
        let profile = try chromiumProfile()
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.validID, version: "1", manifest: [
            "manifest_version": 3, "name": "Native"
        ])
        try ImporterFixtures.writeChromiumExtension(profileDir: profile, id: ImporterFixtures.otherValidID, version: "1", manifest: [
            "manifest_version": 2, "name": "Blocking", "permissions": ["webRequestBlocking"]
        ])
        let scan = importer.scan(profile: self.profile(.chrome, dir: profile), installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.extensions.first { $0.name == "Native" }?.compatibility, .nativeMV3)
        XCTAssertEqual(scan.extensions.first { $0.name == "Blocking" }?.compatibility,
                       .incompatible(reason: "Uses MV2 webRequestBlocking (unsupported in Chromium MV3)"))
    }

    // MARK: - Safari bookmarks plist

    private func safariBookmarks(_ tree: [String: Any]) throws -> ([AssetLoader.BookmarkEntry], [AssetLoader.ReadingListItem]) {
        let url = try root().appendingPathComponent("Bookmarks.plist")
        try ImporterFixtures.writePlist(tree, to: url)
        return importer.parseSafariBookmarksPlist(fileURL: url)
    }

    func testSafariFavoritesFromBookmarksBarComeFirst() throws {
        let (bm, _) = try safariBookmarks(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariFolder("BookmarksMenu", [ImporterFixtures.safariLeaf("Menu", "https://menu.example.test/")]),
            ImporterFixtures.safariLeaf("RootLevel", "https://root.example.test/"),
            ImporterFixtures.safariFolder("BookmarksBar", [ImporterFixtures.safariLeaf("Fav", "https://fav.example.test/")])
        ]))
        XCTAssertEqual(bm.map(\.title), ["Fav", "Menu", "RootLevel"])
    }

    func testSafariReadingListClassifiedByFolderAndUsesDateAdded() throws {
        let added = Date(timeIntervalSince1970: 1_700_000_123)
        let (bm, rl) = try safariBookmarks(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariFolder("com.apple.ReadingList", [
                ImporterFixtures.safariLeaf("Later", "https://later.example.test/", readingDate: added)
            ]),
            ImporterFixtures.safariLeaf("Plain", "https://plain.example.test/")
        ]))
        XCTAssertEqual(bm.map(\.title), ["Plain"])
        XCTAssertEqual(rl.map(\.title), ["Later"])
        XCTAssertEqual(rl.first?.addedAt, added)
        XCTAssertTrue(rl.first?.id.hasPrefix("imp-srl-") ?? false)
    }

    func testSafariReadingListItemWithoutDateUsesNow() throws {
        let before = Date()
        let (_, rl) = try safariBookmarks(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariFolder("com.apple.ReadingList", [ImporterFixtures.safariLeaf("NoDate", "https://nodate.example.test/")])
        ]))
        let added = try XCTUnwrap(rl.first?.addedAt)
        XCTAssertGreaterThanOrEqual(added, before.addingTimeInterval(-1))
    }

    func testSafariBookmarkTitleFallsBackToDomainWhenEmpty() throws {
        let (bm, _) = try safariBookmarks(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariLeaf("  ", "https://www.safari-untitled.example.test/x"),
            ImporterFixtures.safariLeaf("Trimmed ", "https://trim.example.test/")
        ]))
        XCTAssertEqual(bm.map(\.title), ["safari-untitled.example.test", "Trimmed"])
    }

    func testSafariSameURLAcrossCollectionsKeepsBothCopies() throws {
        // Regression lock for P02-4 on the Safari side.
        let (bm, rl) = try safariBookmarks(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariLeaf("Bookmarked", "https://both.example.test/"),
            ImporterFixtures.safariFolder("com.apple.ReadingList", [
                ImporterFixtures.safariLeaf("Queued", "https://both.example.test/")
            ])
        ]))
        XCTAssertEqual(bm.map(\.title), ["Bookmarked"])
        XCTAssertEqual(rl.map(\.title), ["Queued"])
    }

    func testSafariDuplicatesWithinCollectionAreDropped() throws {
        let (bm, _) = try safariBookmarks(ImporterFixtures.safariFolder("", [
            ImporterFixtures.safariLeaf("One", "https://dupe.example.test/a/"),
            ImporterFixtures.safariLeaf("Two", "https://www.dupe.example.test/a")
        ]))
        XCTAssertEqual(bm.map(\.title), ["One"])
    }

    func testSafariRejectsInvalidURLsAndNonLeafNodes() throws {
        let (bm, rl) = try safariBookmarks(ImporterFixtures.safariFolder("", [
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "ftp://x.example.test/", "URIDictionary": ["title": "Ftp"]],
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://", "URIDictionary": ["title": "Bare"]],
            ["WebBookmarkType": "WebBookmarkTypeProxy", "URLString": "https://proxy.example.test/"]
        ]))
        XCTAssertTrue(bm.isEmpty)
        XCTAssertTrue(rl.isEmpty)
    }

    func testSafariMalformedPlistYieldsNothing() throws {
        let url = try root().appendingPathComponent("Bookmarks.plist")
        try ImporterFixtures.write("<<not a plist>>", to: url)
        let (bm, rl) = importer.parseSafariBookmarksPlist(fileURL: url)
        XCTAssertTrue(bm.isEmpty && rl.isEmpty)
    }

    func testSafariDeepFolderNestingIsCappedWithoutCrashing() throws {
        var node = ImporterFixtures.safariLeaf("Deep", "https://deep-safari.example.test/")
        for _ in 0..<200 {
            node = ImporterFixtures.safariFolder("", [node])
        }
        let (bm, _) = try safariBookmarks(ImporterFixtures.safariFolder("", [node]))
        XCTAssertTrue(bm.isEmpty)
    }

    // MARK: - Safari history

    private func makeSafariHistory(_ rows: [String]) throws -> URL {
        let url = try root().appendingPathComponent("History.db")
        try ImporterFixtures.makeSQLite(at: url, statements: [
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER)",
            "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)"
        ] + rows)
        return url
    }

    func testSafariHistoryUsesLatestNonEmptyTitleAndNewestFirst() throws {
        let url = try makeSafariHistory([
            "INSERT INTO history_items VALUES (1, 'https://safari-a.example.test/', 5)",
            "INSERT INTO history_items VALUES (2, 'https://safari-b.example.test/', 2)",
            "INSERT INTO history_visits VALUES (1, 1, 700000000, 'Old Title')",
            "INSERT INTO history_visits VALUES (2, 1, 710000000, 'Newest Title')",
            "INSERT INTO history_visits VALUES (3, 1, 720000000, '')",
            "INSERT INTO history_visits VALUES (4, 2, 600000000, NULL)"
        ])
        let entries = importer.parseSafariHistory(dbURL: url)
        XCTAssertEqual(entries.map(\.url), ["https://safari-a.example.test/", "https://safari-b.example.test/"])
        XCTAssertEqual(entries[0].title, "Newest Title")
        XCTAssertEqual(entries[0].visitCount, 5)
        XCTAssertEqual(entries[0].lastVisited.timeIntervalSinceReferenceDate, 720_000_000, accuracy: 0.001)
        XCTAssertEqual(entries[1].title, "safari-b.example.test")
    }

    func testSafariHistoryLimitAndNonWebFilter() throws {
        var rows = ["INSERT INTO history_items VALUES (99, 'file:///etc/hosts', 1)"]
        for i in 1...5 {
            rows.append("INSERT INTO history_items VALUES (\(i), 'https://lim\(i).example.test/', 1)")
            rows.append("INSERT INTO history_visits VALUES (\(i), \(i), \(700_000_000 + i * 1000), 'T\(i)')")
        }
        let url = try makeSafariHistory(rows)
        let limited = importer.parseSafariHistory(dbURL: url, limit: 3)
        XCTAssertEqual(limited.count, 3)
        XCTAssertTrue(limited.allSatisfy { $0.url.hasPrefix("https://lim") })
        XCTAssertEqual(limited.first?.title, "T5")
    }

    func testSafariHistoryZeroVisitTimeUsesCurrentDate() throws {
        let url = try makeSafariHistory([
            "INSERT INTO history_items VALUES (1, 'https://notime.example.test/', 0)"
        ])
        let before = Date()
        let entry = try XCTUnwrap(importer.parseSafariHistory(dbURL: url).first)
        XCTAssertEqual(entry.visitCount, 1)
        XCTAssertGreaterThanOrEqual(entry.lastVisited, before.addingTimeInterval(-5))
    }

    func testSafariHistoryMissingTablesYieldsEmpty() throws {
        let url = try root().appendingPathComponent("Empty.db")
        try ImporterFixtures.makeSQLite(at: url, statements: ["CREATE TABLE other (x INTEGER)"])
        XCTAssertTrue(importer.parseSafariHistory(dbURL: url).isEmpty)
        XCTAssertTrue(importer.parseSafariHistory(dbURL: try root().appendingPathComponent("absent.db")).isEmpty)
    }

    // MARK: - Gecko (Firefox / Zen) scanner

    private func makeGecko(_ statements: [String]) throws -> DetectedBrowserProfile {
        let dir = try root().appendingPathComponent("ff.default", isDirectory: true)
        try ImporterFixtures.makeSQLite(at: dir.appendingPathComponent("places.sqlite"), statements: [
            "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER)",
            "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, title TEXT, dateAdded INTEGER)"
        ] + statements)
        return DetectedBrowserProfile(browser: .firefox, profileName: "default", directory: dir, requiresPermissionGrant: false)
    }

    func testGeckoBookmarksUseBookmarkTitleAndDedupeByKey() throws {
        let p = try makeGecko([
            "INSERT INTO moz_places VALUES (1, 'https://gk.example.test/', 'Place Title', 1, 0, 1700000000000000)",
            "INSERT INTO moz_places VALUES (2, 'https://www.gk.example.test/', 'Dup', 1, 0, 1700000000000000)",
            "INSERT INTO moz_places VALUES (3, 'https://other.example.test/', '', 1, 0, 1700000000000000)",
            "INSERT INTO moz_bookmarks VALUES (1, 1, 1, 'Bookmark Title', 300)",
            "INSERT INTO moz_bookmarks VALUES (2, 1, 2, NULL, 200)",
            "INSERT INTO moz_bookmarks VALUES (3, 1, 3, NULL, 100)",
            "INSERT INTO moz_bookmarks VALUES (4, 2, 3, 'folder-not-a-bookmark', 50)"
        ])
        let scan = importer.scan(profile: p, installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.bookmarks.map(\.url), ["https://gk.example.test/", "https://other.example.test/"])
        XCTAssertEqual(scan.bookmarks.first?.title, "Bookmark Title")
        XCTAssertEqual(scan.bookmarks.last?.title, "other.example.test", "empty title falls back to the domain")
        XCTAssertTrue(scan.readingList.isEmpty)
        XCTAssertTrue(scan.extensions.isEmpty)
    }

    func testGeckoHistorySkipsHiddenZeroVisitAndConvertsMicroseconds() throws {
        let p = try makeGecko([
            "INSERT INTO moz_places VALUES (1, 'https://visible.example.test/', 'Visible', 4, 0, 1700000000000000)",
            "INSERT INTO moz_places VALUES (2, 'https://hidden.example.test/', 'Hidden', 4, 1, 1700000000000000)",
            "INSERT INTO moz_places VALUES (3, 'https://never.example.test/', 'Never', 0, 0, 1700000000000000)",
            "INSERT INTO moz_places VALUES (4, 'about:config', 'Internal', 3, 0, 1700000000000000)"
        ])
        let scan = importer.scan(profile: p, installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertEqual(scan.history.map(\.url), ["https://visible.example.test/"])
        XCTAssertEqual(scan.history.first?.visitCount, 4)
        XCTAssertEqual(scan.history.first?.lastVisited.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
    }

    func testGeckoZeroLastVisitFallsBackToNow() throws {
        let p = try makeGecko([
            "INSERT INTO moz_places VALUES (1, 'https://zeroday.example.test/', 'Z', 1, 0, 0)"
        ])
        let before = Date()
        let scan = importer.scan(profile: p, installedExtensionIDs: [], installedExtensionNames: [])
        let entry = try XCTUnwrap(scan.history.first)
        XCTAssertGreaterThanOrEqual(entry.lastVisited, before.addingTimeInterval(-5))
    }

    func testGeckoMalformedDatabaseYieldsEmptyScan() throws {
        let dir = try root().appendingPathComponent("broken", isDirectory: true)
        try ImporterFixtures.write("not sqlite", to: dir.appendingPathComponent("places.sqlite"))
        let p = DetectedBrowserProfile(browser: .zen, profileName: "broken", directory: dir, requiresPermissionGrant: false)
        let scan = importer.scan(profile: p, installedExtensionIDs: [], installedExtensionNames: [])
        XCTAssertTrue(scan.bookmarks.isEmpty)
        XCTAssertTrue(scan.history.isEmpty)
        XCTAssertFalse(scan.accessBlocked)
    }

    // MARK: - Netscape HTML bookmark parser

    private func netscapeFile(_ html: String) throws -> URL {
        let url = try root().appendingPathComponent("bookmarks.html")
        try ImporterFixtures.write(html, to: url)
        return url
    }

    func testNetscapeParsesAnchorsWithTitlesAndIDs() throws {
        let url = try netscapeFile("""
        <DL><p>
            <DT><A HREF="https://one.example.test/" ADD_DATE="1">First Site</A>
            <DT><A HREF="http://two.example.test/path">Second</A>
        </DL><p>
        """)
        let entries = importer.parseNetscapeBookmarksHTML(at: url)
        XCTAssertEqual(entries.map(\.title), ["First Site", "Second"])
        XCTAssertEqual(entries.map(\.url), ["https://one.example.test/", "http://two.example.test/path"])
        XCTAssertTrue(entries.allSatisfy { $0.id.hasPrefix("imp-html-") })
    }

    func testNetscapeHrefAmpersandEntityIsDecodedOnce() throws {
        // Regression lock for P02-5: `&amp;` in HREF must become `&` before storage.
        let url = try netscapeFile(#"<A HREF="https://example.test/?a=1&amp;b=2">Query</A>"#)
        XCTAssertEqual(importer.parseNetscapeBookmarksHTML(at: url).map(\.url), ["https://example.test/?a=1&b=2"])
    }

    func testNetscapeDoubleEscapedEntityStaysEscapedOnce() throws {
        let url = try netscapeFile(#"<A HREF="https://example.test/?x=&amp;lt;y">Escaped &amp;lt;tag&amp;gt;</A>"#)
        let entry = try XCTUnwrap(importer.parseNetscapeBookmarksHTML(at: url).first)
        XCTAssertEqual(entry.url, "https://example.test/?x=&lt;y")
        XCTAssertEqual(entry.title, "Escaped &lt;tag&gt;")
    }

    func testNetscapeTitleEntitiesDecoded() throws {
        let url = try netscapeFile(#"<A HREF="https://t.example.test/">Tom &amp; Jerry &quot;Quoted&quot; &#39;single&#39; &lt;b&gt;</A>"#)
        let entry = try XCTUnwrap(importer.parseNetscapeBookmarksHTML(at: url).first)
        XCTAssertEqual(entry.title, "Tom & Jerry \"Quoted\" 'single' <b>")
    }

    func testNetscapeNumericCharacterReferencesAreDecoded() throws {
        // The decoder claims HTML entity decoding; numeric references such as &#38; are not handled.
        let url = try netscapeFile(#"<A HREF="https://num.example.test/">Tom &#38; Jerry</A>"#)
        let entry = try XCTUnwrap(importer.parseNetscapeBookmarksHTML(at: url).first)
        XCTAssertEqual(entry.title, "Tom & Jerry")
    
    }

    func testNetscapeEmptyTitleUsesDomainAndTrimsWhitespace() throws {
        let url = try netscapeFile("""
        <A HREF="https://www.empty.example.test/x">   </A>
        <A HREF="  https://trimmed.example.test/  ">  Padded  </A>
        """)
        let entries = importer.parseNetscapeBookmarksHTML(at: url)
        XCTAssertEqual(entries.map(\.title), ["empty.example.test", "Padded"])
        XCTAssertEqual(entries.last?.url, "https://trimmed.example.test/")
    }

    func testNetscapeDuplicatesAndInvalidURLsAreFiltered() throws {
        let url = try netscapeFile("""
        <A HREF="https://dup.example.test/a/">One</A>
        <A HREF="https://www.dup.example.test/a">Two</A>
        <A HREF="javascript:void(0)">Script</A>
        <A HREF="https://">Bare</A>
        <A HREF="https://has space.example.test/">Space</A>
        <A HREF="place:sort=8">Places</A>
        """)
        let entries = importer.parseNetscapeBookmarksHTML(at: url)
        XCTAssertEqual(entries.map(\.title), ["One"])
    }

    func testNetscapeAcceptsUppercaseAndExtraAttributes() throws {
        let url = try netscapeFile(#"<a target="_blank" href="https://case.example.test/" ICON="data:x">Upper</a>"#)
        XCTAssertEqual(importer.parseNetscapeBookmarksHTML(at: url).map(\.title), ["Upper"])
    }

    func testNetscapeLatin1FallbackWhenNotUTF8() throws {
        let url = try root().appendingPathComponent("latin.html")
        var bytes = Array(#"<A HREF="https://latin.example.test/">Caf"#.utf8)
        bytes.append(0xE9) // "é" in ISO-8859-1, invalid as UTF-8
        bytes.append(contentsOf: Array("</A>".utf8))
        try ImporterFixtures.write(Data(bytes), to: url)
        let entry = try XCTUnwrap(importer.parseNetscapeBookmarksHTML(at: url).first)
        XCTAssertEqual(entry.title, "Café")
    }

    func testNetscapeMissingFileYieldsNothing() throws {
        let url = try root().appendingPathComponent("nope.html")
        XCTAssertTrue(importer.parseNetscapeBookmarksHTML(at: url).isEmpty)
    }

    func testNetscapeIgnoresTextWithoutAnchors() throws {
        let url = try netscapeFile("<DL><p><DT>Folder</DT></DL><p>plain text https://not-a-link.example.test/")
        XCTAssertTrue(importer.parseNetscapeBookmarksHTML(at: url).isEmpty)
    }
}
