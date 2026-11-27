import XCTest
import AppKit
@testable import Safarium

/// Import execution (`performImport`), AssetLoader merge/history rules used by imports, the Netscape bookmark
/// export formatter, and the Clear History range mapping. Every URL is unique per test so shared
/// AssetLoader state (favorites, reading list, history) cannot leak between tests.
@MainActor
final class ImportAndClearHistoryTests: HermeticTestCase {
    private let defaultsKeys = [
        "Safarium.FavoritesOrderURLs.v1",
        "Safarium.CustomFavoritesEntries.v1",
        "Safarium.ReadingListEntries.v1"
    ]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        AssetLoader.shared.clearHistory(range: .allHistory)
        for key in defaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func root() throws -> URL { try ImporterFixtures.makeRoot(self) }

    private func url(_ path: String = "") -> String {
        "https://\(ImporterFixtures.uniqueHost())/\(path)"
    }

    private func profile(_ browser: SupportedBrowserKind = .chrome) -> DetectedBrowserProfile {
        DetectedBrowserProfile(browser: browser, profileName: "Test", directory: Self.sandboxRoot, requiresPermissionGrant: false)
    }

    private func bookmark(_ title: String, _ url: String) -> AssetLoader.BookmarkEntry {
        AssetLoader.BookmarkEntry(id: "t-\(UUID().uuidString)", title: title, url: url, color: nil)
    }

    private func scan(
        bookmarks: [AssetLoader.BookmarkEntry] = [],
        readingList: [AssetLoader.ReadingListItem] = [],
        history: [AssetLoader.HistoryEntry] = [],
        extensions: [ImportedExtensionCandidate] = []
    ) -> BrowserProfileScan {
        BrowserProfileScan(profile: profile(), bookmarks: bookmarks, readingList: readingList,
                           history: history, extensions: extensions, accessBlocked: false)
    }

    private func candidate(
        id: String,
        name: String,
        localDirectory: URL? = nil,
        storeID: String? = nil,
        hasKey: Bool = false,
        compatibility: ExtensionCompatibility = .nativeMV3
    ) -> ImportedExtensionCandidate {
        ImportedExtensionCandidate(
            id: id, name: name, version: "1.0", icon: nil, localDirectory: localDirectory,
            storeID: storeID, hasManifestKey: hasKey, isAlreadyInstalled: false,
            manifestVersion: 3, compatibility: compatibility
        )
    }

    private func installedItem(id: String) -> BrowserExtensionItem {
        BrowserExtensionItem(id: id, name: "Installed", version: "1", icon: nil, badgeText: nil,
                             badgeColor: nil, popupURL: nil, enabled: true)
    }

    /// Records every progress and completion callback from `performImport`.
    private final class ImportLog {
        var statuses: [String] = []
        var fractions: [Double] = []
        var results: [BrowserImportResult] = []
    }

    /// Runs `performImport` and waits for its single completion. Also spins briefly to catch any stray second completion.
    private func runImport(
        _ scan: BrowserProfileScan,
        _ selection: BrowserImportSelection,
        engine: BrowserEngine
    ) -> (result: BrowserImportResult?, log: ImportLog) {
        let log = ImportLog()
        let done = expectation(description: "performImport completion")
        BrowserDataImporter.shared.performImport(
            scan: scan,
            selection: selection,
            engine: engine,
            onProgress: { status, fraction in
                log.statuses.append(status)
                log.fractions.append(fraction)
            },
            completion: { result in
                log.results.append(result)
                if log.results.count == 1 { done.fulfill() }
            }
        )
        wait(for: [done], timeout: 10)
        spinRunLoop(0.05)
        XCTAssertEqual(log.results.count, 1, "completion must fire exactly once")
        return (log.results.first, log)
    }

    private func selection(
        bookmarks: Bool = false,
        history: Bool = false,
        readingList: Bool = false,
        extensions: Set<String> = []
    ) -> BrowserImportSelection {
        BrowserImportSelection(importBookmarks: bookmarks, importHistory: history,
                               importReadingList: readingList, selectedExtensionIDs: extensions)
    }

    // MARK: - performImport: data sections

    func testEmptySelectionCompletesImmediatelyWithZeroCounts() {
        let engine = ScriptedImportEngine()
        let (result, log) = runImport(scan(bookmarks: [bookmark("X", url())]), selection(), engine: engine)
        XCTAssertEqual(result?.bookmarksImported, 0)
        XCTAssertEqual(result?.extensionsImported, 0)
        XCTAssertEqual(log.statuses, ["Import complete"])
        XCTAssertEqual(log.fractions, [1.0])
    }

    func testBookmarksImportPrependsNewEntriesAndCountsUniqueOnes() {
        let a = url("a"), b = url("b")
        let entries = [bookmark("First", a), bookmark("Dup", a + "/"), bookmark("Second", b)]
        let (result, log) = runImport(scan(bookmarks: entries), selection(bookmarks: true), engine: ScriptedImportEngine())
        XCTAssertEqual(result?.bookmarksImported, 2)
        XCTAssertEqual(AssetLoader.shared.favorites().prefix(2).map(\.url), [a, b])
        XCTAssertEqual(log.statuses.first, "Importing bookmarks…")
        XCTAssertEqual(log.statuses.last, "Import complete")
    }

    func testBookmarksAlreadyPresentAreNotDuplicated() {
        let existing = url("existing")
        _ = runImport(scan(bookmarks: [bookmark("One", existing)]), selection(bookmarks: true), engine: ScriptedImportEngine())
        let (second, _) = runImport(scan(bookmarks: [bookmark("Again", existing)]), selection(bookmarks: true), engine: ScriptedImportEngine())
        XCTAssertEqual(second?.bookmarksImported, 0)
        XCTAssertEqual(AssetLoader.shared.favorites().filter { $0.url == existing }.count, 1)
    }

    func testReadingListImportAddsAtFrontAndDedupes() {
        let item = url("rl")
        let items = [
            AssetLoader.ReadingListItem(id: "imp-1", title: "Saved", url: item, addedAt: Date()),
            AssetLoader.ReadingListItem(id: "imp-2", title: "Saved again", url: item + "/", addedAt: Date())
        ]
        let (result, _) = runImport(scan(readingList: items), selection(readingList: true), engine: ScriptedImportEngine())
        XCTAssertEqual(result?.readingListImported, 1)
        XCTAssertEqual(AssetLoader.shared.readingList().first?.url, item)
    }

    func testHistoryImportCountsNewEntriesAndMergesRepeatVisits() {
        let page = url("hist")
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_750_000_000)
        let first = AssetLoader.HistoryEntry(title: "Old", url: page, visitCount: 2, lastVisited: older)
        let (added, _) = runImport(scan(history: [first]), selection(history: true), engine: ScriptedImportEngine())
        XCTAssertEqual(added?.historyImported, 1)

        let second = AssetLoader.HistoryEntry(title: "Fresh", url: page, visitCount: 5, lastVisited: newer)
        let (merged, _) = runImport(scan(history: [second]), selection(history: true), engine: ScriptedImportEngine())
        XCTAssertEqual(merged?.historyImported, 0, "a repeat URL is merged, not counted as new")
        let stored = try? XCTUnwrap(AssetLoader.shared.browsingHistory().first { $0.url == page })
        XCTAssertEqual(stored?.visitCount, 5)
        XCTAssertEqual(stored?.title, "Fresh")
        XCTAssertEqual(stored?.lastVisited, newer)
    }

    func testUnselectedSectionsAreNotImported() {
        let skipped = url("skip-bm")
        let (result, _) = runImport(
            scan(bookmarks: [bookmark("No", skipped)],
                 readingList: [AssetLoader.ReadingListItem(id: "x", title: "No", url: url("skip-rl"), addedAt: Date())],
                 history: [AssetLoader.HistoryEntry(title: "No", url: url("skip-h"), visitCount: 1, lastVisited: Date())]),
            selection(history: true),
            engine: ScriptedImportEngine()
        )
        XCTAssertEqual(result?.bookmarksImported, 0)
        XCTAssertEqual(result?.readingListImported, 0)
        XCTAssertEqual(result?.historyImported, 1)
        XCTAssertFalse(AssetLoader.shared.favorites().contains { $0.url == skipped })
    }

    func testProgressFractionsAreMonotonicAndEndAtOne() {
        let entries = (0..<3).map { bookmark("B\($0)", url("p\($0)")) }
        let history = [AssetLoader.HistoryEntry(title: "H", url: url("ph"), visitCount: 1, lastVisited: Date())]
        let (_, log) = runImport(scan(bookmarks: entries, history: history),
                                 selection(bookmarks: true, history: true),
                                 engine: ScriptedImportEngine())
        XCTAssertEqual(log.statuses, ["Importing bookmarks…", "Importing browsing history…", "Import complete"])
        XCTAssertEqual(log.fractions.first, 0.0)
        XCTAssertEqual(log.fractions.last, 1.0)
        XCTAssertEqual(zip(log.fractions, log.fractions.dropFirst()).allSatisfy { $0 <= $1 }, true)
    }

    // MARK: - performImport: extensions

    func testExtensionOutcomesCoverSkipImportAndFailure() throws {
        let failID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let engine = ScriptedImportEngine()
        engine.installed = [installedItem(id: ImporterFixtures.validID)]
        let dir = try root().appendingPathComponent("loadable", isDirectory: true)
        try ImporterFixtures.makeDirectory(dir)
        let failingDir = try root().appendingPathComponent("failing", isDirectory: true)
        try ImporterFixtures.makeDirectory(failingDir)

        let scanned = scan(extensions: [
            candidate(id: ImporterFixtures.validID, name: "Already", localDirectory: dir, hasKey: true),
            candidate(id: ImporterFixtures.otherValidID, name: "Incompatible",
                      localDirectory: dir, compatibility: .incompatible(reason: "nope")),
            candidate(id: ImporterFixtures.ignoredComponentID, name: "Loads", localDirectory: dir, hasKey: true),
            candidate(id: failID, name: "Fails", localDirectory: failingDir)
        ])
        engine.failingPaths = [failingDir.path]
        let ids: Set<String> = [ImporterFixtures.validID, ImporterFixtures.otherValidID,
                                ImporterFixtures.ignoredComponentID, failID]
        // The keyed extension loads; the keyless one goes through the unpacked path and that load fails.
        let (result, log) = runImport(scanned, selection(extensions: ids), engine: engine)

        XCTAssertEqual(result?.extensionsSkipped, 2, "already installed and incompatible are skipped")
        XCTAssertEqual(result?.extensionsImported, 1)
        XCTAssertEqual(result?.extensionsFailed, 1)
        XCTAssertEqual(engine.loadedPaths, [dir.path, failingDir.path])
        XCTAssertTrue(log.statuses.contains("Skipped Already"))
        XCTAssertTrue(log.statuses.contains("Skipped Incompatible"))
        XCTAssertTrue(log.statuses.contains("Installed Loads"))
        XCTAssertTrue(log.statuses.contains("Could not install Fails"))
        XCTAssertEqual(log.statuses.last, "Import complete")
        XCTAssertEqual(log.fractions.last, 1.0)
    }

    func testStoreIDInstallWithoutLocalCopyUsesWebStore() {
        let engine = ScriptedImportEngine()
        engine.webStoreResult = true
        let scanned = scan(extensions: [
            candidate(id: ImporterFixtures.validID, name: "Store", storeID: ImporterFixtures.validID)
        ])
        let (result, _) = runImport(scanned, selection(extensions: [ImporterFixtures.validID]), engine: engine)
        XCTAssertEqual(engine.webStoreIDs, [ImporterFixtures.validID])
        XCTAssertEqual(result?.extensionsImported, 1)
    }

    func testFailedWebStoreInstallWithoutLocalCopyCountsAsFailure() {
        let engine = ScriptedImportEngine()
        engine.webStoreResult = false
        let scanned = scan(extensions: [candidate(id: ImporterFixtures.validID, name: "Store", storeID: ImporterFixtures.validID)])
        let (result, _) = runImport(scanned, selection(extensions: [ImporterFixtures.validID]), engine: engine)
        XCTAssertEqual(result?.extensionsFailed, 1)
        XCTAssertEqual(result?.extensionsImported, 0)
    }

    func testMissingLocalDirectoryAndStoreIDFails() {
        let scanned = scan(extensions: [candidate(id: ImporterFixtures.validID, name: "Orphan")])
        let (result, _) = runImport(scanned, selection(extensions: [ImporterFixtures.validID]), engine: ScriptedImportEngine())
        XCTAssertEqual(result?.extensionsFailed, 1)
    }

    func testUnselectedExtensionsAreIgnored() throws {
        let dir = try root()
        let scanned = scan(extensions: [candidate(id: ImporterFixtures.validID, name: "Off", localDirectory: dir, hasKey: true)])
        let engine = ScriptedImportEngine()
        let (result, log) = runImport(scanned, selection(extensions: []), engine: engine)
        XCTAssertEqual(result?.extensionsImported, 0)
        XCTAssertEqual(result?.extensionsSkipped, 0)
        XCTAssertTrue(engine.loadedPaths.isEmpty)
        XCTAssertEqual(log.statuses, ["Import complete"])
    }

    func testConvertibleExtensionIsConvertedBeforeLoading() throws {
        let src = try root().appendingPathComponent("mv2src", isDirectory: true)
        try ImporterFixtures.writeJSON(["manifest_version": 2, "name": "Legacy", "background": ["scripts": ["bg.js"]]],
                                       to: src.appendingPathComponent("manifest.json"))
        try ImporterFixtures.write("1", to: src.appendingPathComponent("bg.js"))
        let scanned = scan(extensions: [
            candidate(id: ImporterFixtures.validID, name: "Legacy", localDirectory: src,
                      compatibility: .convertible(reasons: ["MV2 → MV3"]))
        ])
        let engine = ScriptedImportEngine()
        let (result, log) = runImport(scanned, selection(extensions: [ImporterFixtures.validID]), engine: engine)

        XCTAssertEqual(result?.extensionsImported, 1)
        let loaded = try XCTUnwrap(engine.loadedPaths.first)
        XCTAssertTrue(loaded.contains("ConvertedExtensions"))
        let converted = try ImporterFixtures.readJSONObject(URL(fileURLWithPath: loaded).appendingPathComponent("manifest.json"))
        XCTAssertEqual(converted["manifest_version"] as? Int, 3)
        XCTAssertTrue(log.statuses.contains("Converting & installing Legacy… (1/1)"))
    }

    func testConversionFailureCountsAsFailureAndLoadsNothing() throws {
        let missing = try root().appendingPathComponent("gone", isDirectory: true)
        let scanned = scan(extensions: [
            candidate(id: ImporterFixtures.validID, name: "Broken", localDirectory: missing,
                      compatibility: .convertible(reasons: ["MV2 → MV3"]))
        ])
        let engine = ScriptedImportEngine()
        let (result, _) = runImport(scanned, selection(extensions: [ImporterFixtures.validID]), engine: engine)
        XCTAssertEqual(result?.extensionsFailed, 1)
        XCTAssertTrue(engine.loadedPaths.isEmpty)
    }

    func testConvertibleWithoutLocalDirectoryFallsThroughToFailure() {
        let scanned = scan(extensions: [
            candidate(id: ImporterFixtures.validID, name: "NoDir", compatibility: .convertible(reasons: ["MV2 → MV3"]))
        ])
        let (result, _) = runImport(scanned, selection(extensions: [ImporterFixtures.validID]), engine: ScriptedImportEngine())
        XCTAssertEqual(result?.extensionsFailed, 1)
    }

    func testStatusTextForInstallSuccessAndFailure() throws {
        let goodDir = try root(), badDir = try root()
        let scanned = scan(extensions: [
            candidate(id: ImporterFixtures.validID, name: "Good", localDirectory: goodDir, hasKey: true),
            candidate(id: ImporterFixtures.otherValidID, name: "Bad", localDirectory: badDir, hasKey: true)
        ])
        let engine = ScriptedImportEngine()
        engine.failingPaths = [badDir.path]
        let (result, log) = runImport(scanned, selection(extensions: [ImporterFixtures.validID, ImporterFixtures.otherValidID]), engine: engine)
        XCTAssertTrue(log.statuses.contains("Installing Good… (1/2)"))
        XCTAssertTrue(log.statuses.contains("Installed Good"))
        XCTAssertTrue(log.statuses.contains("Installing Bad… (2/2)"))
        XCTAssertTrue(log.statuses.contains("Could not install Bad"))
        XCTAssertEqual(result?.extensionsImported, 1)
        XCTAssertEqual(result?.extensionsFailed, 1)
    }

    // MARK: - AssetLoader: favorites and reading list merges

    func testMergeFavoritesEmptyInputReturnsZeroWithoutChange() {
        let before = AssetLoader.shared.favorites().count
        XCTAssertEqual(AssetLoader.shared.mergeImportedFavorites([]), 0)
        XCTAssertEqual(AssetLoader.shared.favorites().count, before)
    }

    func testMergeFavoritesAppendWhenPrependFalse() {
        let first = url("app1"), second = url("app2")
        XCTAssertEqual(AssetLoader.shared.mergeImportedFavorites([bookmark("A", first)], prepend: false), 1)
        XCTAssertEqual(AssetLoader.shared.mergeImportedFavorites([bookmark("B", second)], prepend: false), 1)
        let favs = AssetLoader.shared.favorites()
        XCTAssertEqual(favs.last?.url, second)
        XCTAssertEqual(favs[favs.count - 2].url, first)
    }

    func testMergeFavoritesSkipsEntriesWithEmptyKey() {
        XCTAssertEqual(AssetLoader.shared.mergeImportedFavorites([bookmark("Blank", "   ")]), 0)
    }

    func testMergeFavoritesTreatsWWWAndSchemeVariantsAsSameURL() {
        let host = ImporterFixtures.uniqueHost()
        XCTAssertEqual(AssetLoader.shared.mergeImportedFavorites([bookmark("Plain", "https://\(host)/x")]), 1)
        XCTAssertEqual(AssetLoader.shared.mergeImportedFavorites([bookmark("WWW", "http://www.\(host)/x/")]), 0)
    }

    func testMergeReadingListPrependsAndSkipsExisting() {
        let fresh = url("rl-fresh")
        let item = AssetLoader.ReadingListItem(id: "a", title: "A", url: fresh, addedAt: Date())
        XCTAssertEqual(AssetLoader.shared.mergeImportedReadingList([item, item]), 1)
        XCTAssertEqual(AssetLoader.shared.mergeImportedReadingList([item]), 0)
        XCTAssertEqual(AssetLoader.shared.mergeImportedReadingList([]), 0)
        XCTAssertEqual(AssetLoader.shared.readingList().first?.url, fresh)
    }

    // MARK: - AssetLoader: history rules

    func testMergeHistoryCountsNewEntriesAndSortsNewestFirst() {
        let older = AssetLoader.HistoryEntry(title: "Older", url: url("h-old"), visitCount: 1, lastVisited: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = AssetLoader.HistoryEntry(title: "Newer", url: url("h-new"), visitCount: 1, lastVisited: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(AssetLoader.shared.mergeImportedHistory([older, newer]), 2)
        let stored = AssetLoader.shared.browsingHistory()
        let oldIdx = stored.firstIndex { $0.url == older.url }
        let newIdx = stored.firstIndex { $0.url == newer.url }
        XCTAssertNotNil(oldIdx)
        XCTAssertNotNil(newIdx)
        XCTAssertLessThan(newIdx ?? .max, oldIdx ?? 0)
    }

    func testMergeHistoryKeepsMaxVisitCountAndOnlyNewerTitles() {
        let page = url("h-max")
        let t1 = Date(timeIntervalSince1970: 1_750_000_000)
        AssetLoader.shared.mergeImportedHistory([
            AssetLoader.HistoryEntry(title: "Keep", url: page, visitCount: 9, lastVisited: t1)
        ])
        AssetLoader.shared.mergeImportedHistory([
            AssetLoader.HistoryEntry(title: "Ignored older", url: page, visitCount: 3, lastVisited: Date(timeIntervalSince1970: 1_600_000_000))
        ])
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == page }
        XCTAssertEqual(entry?.visitCount, 9, "visit count takes the maximum, never decreases")
        XCTAssertEqual(entry?.title, "Keep", "an older import does not overwrite the title")
        XCTAssertEqual(entry?.lastVisited, t1)
    }

    func testRecordVisitIncrementsCountAndUpdatesTitle() throws {
        let page = url("visit")
        let link = try XCTUnwrap(URL(string: page))
        AssetLoader.shared.recordHistoryVisit(url: link, title: "  First  ")
        AssetLoader.shared.recordHistoryVisit(url: link, title: "")
        let entry = try XCTUnwrap(AssetLoader.shared.browsingHistory().first { $0.url == page })
        XCTAssertEqual(entry.visitCount, 2)
        XCTAssertEqual(entry.title, "First")
    
    }

    func testRecordVisitIgnoresNonWebSchemes() throws {
        let file = try XCTUnwrap(URL(string: "file:///tmp/\(UUID().uuidString).html"))
        let before = AssetLoader.shared.browsingHistory().count
        AssetLoader.shared.recordHistoryVisit(url: file, title: "Local")
        XCTAssertEqual(AssetLoader.shared.browsingHistory().count, before)
    }

    func testVisitCountSaturatesAtIntMax() throws {
        let page = url("saturate")
        AssetLoader.shared.mergeImportedHistory([
            AssetLoader.HistoryEntry(title: "Max", url: page, visitCount: Int.max, lastVisited: Date())
        ])
        AssetLoader.shared.recordHistoryVisit(url: try XCTUnwrap(URL(string: page)), title: "Max")
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == page }
        XCTAssertEqual(entry?.visitCount, Int.max)
    }

    func testUpdateHistoryTitleChangesStoredTitle() throws {
        // Regression lock: the URL-change callback records a placeholder title that is later replaced.
        let page = url("title-update")
        let link = try XCTUnwrap(URL(string: page))
        AssetLoader.shared.recordHistoryVisit(url: link, title: "Loading")
        AssetLoader.shared.updateHistoryTitle(url: link, title: "  Real Page Title  ")
        XCTAssertEqual(AssetLoader.shared.browsingHistory().first { $0.url == page }?.title, "Real Page Title")
    }

    func testUpdateHistoryTitleRejectsBlankAboutBlankAndNonWebURLs() throws {
        let page = url("title-reject")
        let link = try XCTUnwrap(URL(string: page))
        AssetLoader.shared.recordHistoryVisit(url: link, title: "Keep Me")
        AssetLoader.shared.updateHistoryTitle(url: link, title: "   ")
        AssetLoader.shared.updateHistoryTitle(url: link, title: "about:blank")
        AssetLoader.shared.updateHistoryTitle(url: link, title: "ABOUT:BLANK")
        XCTAssertEqual(AssetLoader.shared.browsingHistory().first { $0.url == page }?.title, "Keep Me")

        let internalURL = try XCTUnwrap(URL(string: "safarium://start"))
        AssetLoader.shared.updateHistoryTitle(url: internalURL, title: "Nope")
        XCTAssertNil(AssetLoader.shared.browsingHistory().first { $0.url == "safarium://start" })
    }

    func testUpdateHistoryTitleForUnknownURLIsNoOp() throws {
        let count = AssetLoader.shared.browsingHistory().count
        AssetLoader.shared.updateHistoryTitle(url: try XCTUnwrap(URL(string: url("never-seen"))), title: "Ghost")
        XCTAssertEqual(AssetLoader.shared.browsingHistory().count, count)
    }

    func testRemoveHistoryEntriesMatchesNormalizedURLs() throws {
        let host = ImporterFixtures.uniqueHost()
        AssetLoader.shared.mergeImportedHistory([
            AssetLoader.HistoryEntry(title: "Gone", url: "https://www.\(host)/a/", visitCount: 1, lastVisited: Date()),
            AssetLoader.HistoryEntry(title: "Kept", url: "https://\(host)/b", visitCount: 1, lastVisited: Date())
        ])
        AssetLoader.shared.removeHistoryEntries(urls: ["https://\(host)/a"])
        let remaining = AssetLoader.shared.browsingHistory().filter { $0.url.contains(host) }.map(\.title)
        XCTAssertEqual(remaining, ["Kept"])
    }

    // MARK: - AssetLoader: normalized URL keys

    func testNormalizedKeyDropsOnlyDefaultPortForScheme() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("http://h.example.test:80/"), "h.example.test")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://h.example.test:443/"), "h.example.test")
        XCTAssertEqual(AssetLoader.normalizedURLKey("http://h.example.test:443/"), "h.example.test:443")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://h.example.test:80/"), "h.example.test:80")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://h.example.test:8443/"), "h.example.test:8443")
    }

    func testNormalizedKeyStripsWWWTrailingSlashesAndLowercasesHostButKeepsPathCase() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("HTTPS://WWW.Example.TEST/Some/PATH///"), "example.test/Some/PATH")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://www.example.test/"), "example.test")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://www.example.test"), "example.test")
    }

    func testNormalizedKeyKeepsQueryAndTrimsWhitespace() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("  https://q.example.test/s?Q=1&b=2/  "), "q.example.test/s?Q=1&b=2/")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://q.example.test/?"), "q.example.test")
    }

    func testNormalizedKeyFallbackForSchemelessInput() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("example.test/Path/"), "example.test/Path")
        XCTAssertEqual(AssetLoader.normalizedURLKey("www.example.test"), "example.test")
        XCTAssertEqual(AssetLoader.normalizedURLKey("/"), "/")
        XCTAssertEqual(AssetLoader.normalizedURLKey(""), "")
        XCTAssertEqual(AssetLoader.normalizedURLKey("   "), "")
    }

    // MARK: - Netscape bookmark export

    func testExportEmitsNetscapeStructureForEmptyCollection() {
        let html = AppDelegate.netscapeBookmarksHTML(for: [])
        XCTAssertEqual(html, """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Safarium Bookmarks</TITLE>
        <H1>Safarium Bookmarks</H1>
        <DL><p>
        </DL><p>
        """)
    }

    func testExportEscapesAmpersandAndAnglesInTitles() {
        let html = AppDelegate.netscapeBookmarksHTML(for: [bookmark("Tom & <Jerry>", "https://x.example.test/")])
        XCTAssertTrue(html.contains("<A HREF=\"https://x.example.test/\">Tom &amp; &lt;Jerry&gt;</A>"))
    }

    func testExportEscapesAmpersandAndQuoteInHREF() {
        let html = AppDelegate.netscapeBookmarksHTML(for: [bookmark("Q", "https://x.example.test/?a=1&b=\"2\"")])
        XCTAssertTrue(html.contains("HREF=\"https://x.example.test/?a=1&amp;b=&quot;2&quot;\""))
    }

    func testExportDoesNotDoubleEscapeEntityLookingText() {
        let html = AppDelegate.netscapeBookmarksHTML(for: [bookmark("&copy;", "https://x.example.test/?c=&copy;")])
        XCTAssertTrue(html.contains("HREF=\"https://x.example.test/?c=&amp;copy;\">&amp;copy;</A>"))
    }

    func testExportKeepsUnicodeTitlesIntact() {
        let html = AppDelegate.netscapeBookmarksHTML(for: [bookmark("日本語 🚀 Café", "https://u.example.test/")])
        XCTAssertTrue(html.contains(">日本語 🚀 Café</A>"))
    }

    func testExportRoundTripsThroughNetscapeImporter() throws {
        let entries = [
            bookmark("AT&T & \"Friends\" <3>", "https://rt.example.test/?a=1&b=2&c=\"x\""),
            bookmark("Entity &copy; text", "https://rt.example.test/?c=&copy;")
        ]
        let html = AppDelegate.netscapeBookmarksHTML(for: entries)
        let file = try root().appendingPathComponent("export.html")
        try ImporterFixtures.write(html, to: file)
        let parsed = BrowserDataImporter.shared.parseNetscapeBookmarksHTML(at: file)
        XCTAssertEqual(parsed.map(\.url), entries.map(\.url))
        XCTAssertEqual(parsed.map(\.title), entries.map(\.title))
    }

    // MARK: - Clear History range mapping

    func testHistoryClearRangeTitlesAndOrder() {
        XCTAssertEqual(AssetLoader.HistoryClearRange.allCases, [.lastHour, .today, .todayAndYesterday, .allHistory])
        XCTAssertEqual(AssetLoader.HistoryClearRange.allCases.map(\.title),
                       ["Last Hour", "Today", "Today and Yesterday", "All History"])
        XCTAssertEqual(AssetLoader.HistoryClearRange.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    func testPopupTagMapsToEveryValidRange() {
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: 0), .lastHour)
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: 1), .today)
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: 2), .todayAndYesterday)
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: 3), .allHistory)
    }

    func testMissingOrUnknownPopupTagFallsBackToAllHistory() {
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: nil), .allHistory)
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: 4), .allHistory)
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: -1), .allHistory)
        XCTAssertEqual(ClearHistorySheetController.historyClearRange(forPopupTag: Int.max), .allHistory)
    }

    func testClearingLastHourKeepsOlderEntries() {
        let old = url("clear-old"), recent = url("clear-recent")
        AssetLoader.shared.mergeImportedHistory([
            AssetLoader.HistoryEntry(title: "Old", url: old, visitCount: 1, lastVisited: Date().addingTimeInterval(-7200)),
            AssetLoader.HistoryEntry(title: "Recent", url: recent, visitCount: 1, lastVisited: Date().addingTimeInterval(-60))
        ])
        AssetLoader.shared.clearHistory(range: .lastHour)
        let urls = AssetLoader.shared.browsingHistory().map(\.url)
        XCTAssertTrue(urls.contains(old))
        XCTAssertFalse(urls.contains(recent))
    }

    func testClearingAllHistoryEmptiesStore() {
        AssetLoader.shared.mergeImportedHistory([
            AssetLoader.HistoryEntry(title: "Any", url: url("clear-all"), visitCount: 1, lastVisited: Date())
        ])
        AssetLoader.shared.clearHistory(range: .allHistory)
        XCTAssertTrue(AssetLoader.shared.browsingHistory().isEmpty)
    }

    // MARK: - Import window pure helpers

    func testClampedProfileIndexStaysInRange() {
        XCTAssertEqual(ImportDataWindowController.clampedProfileIndex(0, profileCount: 3), 0)
        XCTAssertEqual(ImportDataWindowController.clampedProfileIndex(2, profileCount: 3), 2)
        XCTAssertEqual(ImportDataWindowController.clampedProfileIndex(5, profileCount: 3), 2)
        XCTAssertEqual(ImportDataWindowController.clampedProfileIndex(-4, profileCount: 3), 0)
        XCTAssertEqual(ImportDataWindowController.clampedProfileIndex(1, profileCount: 0), 0)
        XCTAssertEqual(ImportDataWindowController.clampedProfileIndex(7, profileCount: 1), 0)
    }

    func testMakeSelectionCoversAllCheckboxCombinations() {
        let ids: Set<String> = [ImporterFixtures.validID, ImporterFixtures.otherValidID]
        for mask in 0..<16 {
            let bm = mask & 1 != 0, hist = mask & 2 != 0, rl = mask & 4 != 0, ext = mask & 8 != 0
            let s = ImportDataWindowController.makeSelection(
                bookmarks: bm, history: hist, readingList: rl, extensions: ext, importableExtensionIDs: ids
            )
            XCTAssertEqual(s.importBookmarks, bm, "mask \(mask)")
            XCTAssertEqual(s.importHistory, hist, "mask \(mask)")
            XCTAssertEqual(s.importReadingList, rl, "mask \(mask)")
            XCTAssertEqual(s.selectedExtensionIDs, ext ? ids : [], "mask \(mask)")
        }
    }

    func testMakeSelectionWithNoImportableExtensionsSelectsNone() {
        let s = ImportDataWindowController.makeSelection(
            bookmarks: false, history: false, readingList: false, extensions: true, importableExtensionIDs: []
        )
        XCTAssertTrue(s.selectedExtensionIDs.isEmpty)
    }
}

extension ImporterFixtures {
    static func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
