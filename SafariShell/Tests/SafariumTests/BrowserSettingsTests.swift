import XCTest
import AppKit
@testable import Safarium

/// Uses an isolated UserDefaults suite per test (never `.standard`), so nothing leaks between tests.
final class BrowserSettingsTests: HermeticTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var s: BrowserSettings!

    override func setUp() {
        super.setUp()
        suiteName = "SafariumTests.BrowserSettings.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        s = BrowserSettings(defaults: suite)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        s = nil
        suite = nil
        super.tearDown()
    }

    // MARK: - Keys

    func testKeyStringsAreStable() {
        XCTAssertEqual(BrowserSettings.Key.opensWith, "Safarium.Pref.OpensWith")
        XCTAssertEqual(BrowserSettings.Key.homepage, "Safarium.Pref.Homepage")
        XCTAssertEqual(BrowserSettings.Key.removeHistory, "Safarium.Pref.RemoveHistory")
        XCTAssertEqual(BrowserSettings.Key.downloadLocation, "Safarium.Pref.DownloadLocation")
        XCTAssertEqual(BrowserSettings.Key.customDownloadDir, "Safarium.Pref.CustomDownloadDir")
        XCTAssertEqual(BrowserSettings.Key.autoCloseTabs, "Safarium.Pref.AutoCloseTabs")
        XCTAssertEqual(BrowserSettings.Key.searchEngine, "Safarium.Pref.SearchEngine")
        XCTAssertEqual(BrowserSettings.Key.privateSearchEngine, "Safarium.Pref.PrivateSearchEngine")
        XCTAssertEqual(BrowserSettings.Key.samePrivateSearch, "Safarium.Pref.SamePrivateSearch")
        XCTAssertEqual(BrowserSettings.Key.quickWebsiteSearch, "Safarium.Pref.QuickWebsiteSearch")
        XCTAssertEqual(BrowserSettings.Key.showFullAddress, "Safarium.Pref.ShowFullAddress")
        XCTAssertEqual(BrowserSettings.Key.minFontSize, "Safarium.Pref.MinFontSize")
        XCTAssertEqual(BrowserSettings.Key.customStyleSheetPath, "Safarium.Pref.CustomStyleSheetPath")
        XCTAssertEqual(BrowserSettings.Key.savedSessionTabs, "Safarium.Session.SavedTabs.v1")
        XCTAssertEqual(BrowserSettings.Key.savedSessionActiveIndex, "Safarium.Session.ActiveIndex.v1")
    }

    func testNotificationNamesAreStable() {
        XCTAssertEqual(Notification.Name.safariumSettingsDidChange.rawValue, "SafariumSettingsDidChangeNotification")
        XCTAssertEqual(Notification.Name.safariumWebsitePoliciesDidChange.rawValue, "SafariumWebsitePoliciesDidChangeNotification")
    }

    func testSharedIsSingleton() {
        XCTAssertTrue(BrowserSettings.shared === BrowserSettings.shared)
    }

    func testIsolatedInstancesDoNotShareStorage() {
        s.set(3, forKey: BrowserSettings.Key.opensWith)
        let other = BrowserSettings(defaults: UserDefaults(suiteName: "SafariumTests.Other.\(UUID().uuidString)")!)
        XCTAssertEqual(other.opensWithIndex, 0)
        XCTAssertEqual(s.opensWithIndex, 3)
    }

    // MARK: - Search engine enum

    func testSearchEngineRawValuesAreStable() {
        XCTAssertEqual(BrowserSettings.SearchEngine.allCases.count, 7)
        XCTAssertEqual(BrowserSettings.SearchEngine.google.rawValue, 0)
        XCTAssertEqual(BrowserSettings.SearchEngine.duckDuckGo.rawValue, 1)
        XCTAssertEqual(BrowserSettings.SearchEngine.bing.rawValue, 2)
        XCTAssertEqual(BrowserSettings.SearchEngine.yahoo.rawValue, 3)
        XCTAssertEqual(BrowserSettings.SearchEngine.ecosia.rawValue, 4)
        XCTAssertEqual(BrowserSettings.SearchEngine.perplexity.rawValue, 5)
        XCTAssertEqual(BrowserSettings.SearchEngine.kagi.rawValue, 6)
    }

    func testSearchEngineDisplayNames() {
        let names = BrowserSettings.SearchEngine.allCases.map(\.displayName)
        XCTAssertEqual(names, ["Google", "DuckDuckGo", "Bing", "Yahoo", "Ecosia", "Perplexity", "Kagi"])
    }

    func testSearchURLForEachEngine() {
        let expected: [BrowserSettings.SearchEngine: String] = [
            .google: "https://www.google.com/search?q=swift",
            .duckDuckGo: "https://duckduckgo.com/?q=swift",
            .bing: "https://www.bing.com/search?q=swift",
            .yahoo: "https://search.yahoo.com/search?p=swift",
            .ecosia: "https://www.ecosia.org/search?q=swift",
            .perplexity: "https://www.perplexity.ai/search?q=swift",
            .kagi: "https://kagi.com/search?q=swift"
        ]
        for engine in BrowserSettings.SearchEngine.allCases {
            XCTAssertEqual(engine.searchURL(for: "swift").absoluteString, expected[engine], engine.displayName)
        }
    }

    func testSearchURLEmptyQueryKeepsKeyWithEmptyValue() {
        XCTAssertEqual(BrowserSettings.SearchEngine.google.searchURL(for: "").absoluteString, "https://www.google.com/search?q=")
        XCTAssertEqual(BrowserSettings.SearchEngine.yahoo.searchURL(for: "").absoluteString, "https://search.yahoo.com/search?p=")
    }

    func testSearchURLEncodesSpacesAsPercent20() {
        XCTAssertEqual(BrowserSettings.SearchEngine.google.searchURL(for: "hello world").absoluteString,
                       "https://www.google.com/search?q=hello%20world")
    }

    func testSearchURLEncodesUnicodeAsUTF8() {
        XCTAssertEqual(BrowserSettings.SearchEngine.google.searchURL(for: "café").absoluteString,
                       "https://www.google.com/search?q=caf%C3%A9")
        XCTAssertEqual(BrowserSettings.SearchEngine.duckDuckGo.searchURL(for: "東京").absoluteString,
                       "https://duckduckgo.com/?q=%E6%9D%B1%E4%BA%AC")
    }

    func testSearchURLEncodesAmpersandEqualsAndHash() {
        let url = BrowserSettings.SearchEngine.google.searchURL(for: "a&b=c#d")
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=a%26b%3Dc%23d")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)
    }

    func testSearchURLPlusIsEncodedSoServersDoNotReadItAsSpace() {
        // A literal '+' in a query value is decoded as a space by most servers, so it must be %2B.
        XCTAssertEqual(BrowserSettings.SearchEngine.google.searchURL(for: "c++").absoluteString,
                       "https://www.google.com/search?q=c%2B%2B")
    
    }

    func testSearchURLFullWidthUnicodeRoundTripsThroughQueryItems() {
        let query = "🙂 emoji & more"
        let url = BrowserSettings.SearchEngine.bing.searchURL(for: query)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(comps?.queryItems?.first?.value, query)
    }

    func testSuggestURLs() {
        XCTAssertEqual(BrowserSettings.SearchEngine.google.suggestURL(for: "swift")?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&q=swift")
        XCTAssertEqual(BrowserSettings.SearchEngine.perplexity.suggestURL(for: "swift")?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&q=swift")
        XCTAssertEqual(BrowserSettings.SearchEngine.kagi.suggestURL(for: "swift")?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&q=swift")
        XCTAssertEqual(BrowserSettings.SearchEngine.duckDuckGo.suggestURL(for: "swift")?.absoluteString,
                       "https://duckduckgo.com/ac/?q=swift&type=list")
        XCTAssertEqual(BrowserSettings.SearchEngine.bing.suggestURL(for: "swift")?.absoluteString,
                       "https://api.bing.com/osjson.aspx?query=swift")
        XCTAssertEqual(BrowserSettings.SearchEngine.yahoo.suggestURL(for: "swift")?.absoluteString,
                       "https://search.yahoo.com/sugg/ff?output=fxjson&command=swift")
        XCTAssertEqual(BrowserSettings.SearchEngine.ecosia.suggestURL(for: "swift")?.absoluteString,
                       "https://ac.ecosia.org/autocomplete?q=swift&type=list")
    }

    func testSuggestURLEncodesDelimitersAndEmptyQuery() {
        XCTAssertEqual(BrowserSettings.SearchEngine.bing.suggestURL(for: "a&b")?.absoluteString,
                       "https://api.bing.com/osjson.aspx?query=a%26b")
        XCTAssertEqual(BrowserSettings.SearchEngine.google.suggestURL(for: "")?.absoluteString,
                       "https://suggestqueries.google.com/complete/search?client=firefox&q=")
    }

    // MARK: - Generic typed accessors

    func testTypedAccessorsReturnDefaultsWhenAbsent() {
        XCTAssertTrue(s.bool("missing.bool", default: true))
        XCTAssertFalse(s.bool("missing.bool", default: false))
        XCTAssertEqual(s.int("missing.int", default: 7), 7)
        XCTAssertEqual(s.string("missing.string", default: "fallback"), "fallback")
        XCTAssertEqual(s.string("missing.string"), "")
    }

    func testStoredFalseAndZeroOverrideTrueAndNonZeroDefaults() {
        s.set(false, forKey: "k.bool")
        s.set(0, forKey: "k.int")
        XCTAssertFalse(s.bool("k.bool", default: true))
        XCTAssertEqual(s.int("k.int", default: 5), 0)
    }

    func testStoredEmptyStringOverridesDefault() {
        s.set("", forKey: "k.str")
        XCTAssertEqual(s.string("k.str", default: "fallback"), "")
    }

    func testStoredValuesAreReturned() {
        s.set(true, forKey: "k.bool")
        s.set(42, forKey: "k.int")
        s.set("hello", forKey: "k.str")
        XCTAssertTrue(s.bool("k.bool", default: false))
        XCTAssertEqual(s.int("k.int", default: 0), 42)
        XCTAssertEqual(s.string("k.str"), "hello")
    }

    func testIntAccessorOnNonNumericStringFallsBackToZero() {
        s.set("abc", forKey: "k.int")
        XCTAssertEqual(s.int("k.int", default: 9), 0)
    }

    func testSetNilRemovesValueAndRestoresDefault() {
        s.set(5, forKey: "k.int")
        s.set(nil, forKey: "k.int")
        XCTAssertEqual(s.int("k.int", default: 11), 11)
    }

    func testSetPostsSettingsChangedNotificationWithKey() {
        var received: String?
        let token = NotificationCenter.default.addObserver(forName: .safariumSettingsDidChange, object: s, queue: nil) { note in
            received = note.userInfo?["key"] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }
        s.set(1, forKey: BrowserSettings.Key.opensWith)
        XCTAssertEqual(received, BrowserSettings.Key.opensWith)
    }

    func testNotifyChangedPostsWithoutWritingDefaults() {
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: .safariumSettingsDidChange, object: s, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        s.notifyChanged(key: "x")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(s.int("x", default: -1), -1)
    }

    // MARK: - General

    func testGeneralDefaults() {
        XCTAssertEqual(s.opensWithIndex, 0)
        XCTAssertEqual(s.newWindowOpensWithIndex, 0)
        XCTAssertEqual(s.newTabOpensWithIndex, 0)
    }

    func testHomepageURLIsNilForEmptyOrWhitespace() {
        XCTAssertNil(s.homepageURL)
        s.set("", forKey: BrowserSettings.Key.homepage)
        XCTAssertNil(s.homepageURL)
        s.set(" \n\t  ", forKey: BrowserSettings.Key.homepage)
        XCTAssertNil(s.homepageURL)
    }

    func testHomepageURLAddsHTTPSWhenSchemeMissing() {
        s.set("example.com", forKey: BrowserSettings.Key.homepage)
        XCTAssertEqual(s.homepageURL?.absoluteString, "https://example.com")
    }

    func testHomepageURLTrimsWhitespaceBeforeParsing() {
        s.set("  apple.com/mac \n", forKey: BrowserSettings.Key.homepage)
        XCTAssertEqual(s.homepageURL?.absoluteString, "https://apple.com/mac")
    }

    func testHomepageURLKeepsExplicitScheme() {
        s.set("http://example.com/x?y=1", forKey: BrowserSettings.Key.homepage)
        XCTAssertEqual(s.homepageURL?.absoluteString, "http://example.com/x?y=1")
        s.set("safarium://start", forKey: BrowserSettings.Key.homepage)
        XCTAssertEqual(s.homepageURL?.absoluteString, "safarium://start")
    }

    func testHomepageURLMalformedWithSpaceIsNil() {
        s.set("http://exa mple.com", forKey: BrowserSettings.Key.homepage)
        XCTAssertNil(s.homepageURL)
    }

    func testResolvedNewTabURLForEachIndex() {
        let active = URL(string: "https://active.example/page")!
        s.set(0, forKey: BrowserSettings.Key.newTabOpensWith)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: active).absoluteString, "safarium://start")
        s.set(1, forKey: BrowserSettings.Key.newTabOpensWith)
        s.set("example.com", forKey: BrowserSettings.Key.homepage)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: active).absoluteString, "https://example.com")
        s.set(2, forKey: BrowserSettings.Key.newTabOpensWith)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: active).absoluteString, "about:blank")
        s.set(3, forKey: BrowserSettings.Key.newTabOpensWith)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: active), active)
    }

    func testResolvedNewTabURLHomepageFallsBackToStartWhenEmpty() {
        s.set(1, forKey: BrowserSettings.Key.newTabOpensWith)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: nil).absoluteString, "safarium://start")
    }

    func testResolvedNewTabSamePageRequiresHTTPOrHTTPS() {
        s.set(3, forKey: BrowserSettings.Key.newTabOpensWith)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: URL(string: "http://a.example")!).absoluteString, "http://a.example")
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: URL(string: "safarium://start")!).absoluteString, "safarium://start")
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: URL(string: "file:///tmp/a.html")!).absoluteString, "safarium://start")
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: nil).absoluteString, "safarium://start")
    }

    func testResolvedNewTabUnknownIndexFallsBackToStart() {
        s.set(42, forKey: BrowserSettings.Key.newTabOpensWith)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: URL(string: "https://a.example")!).absoluteString, "safarium://start")
        s.set(-1, forKey: BrowserSettings.Key.newTabOpensWith)
        XCTAssertEqual(s.resolvedNewTabURL(activeTabURL: URL(string: "https://a.example")!).absoluteString, "safarium://start")
    }

    func testResolvedNewWindowURLForEachIndex() {
        let active = URL(string: "https://active.example")!
        s.set("example.com", forKey: BrowserSettings.Key.homepage)
        s.set(0, forKey: BrowserSettings.Key.newWindowOpensWith)
        XCTAssertEqual(s.resolvedNewWindowURL(activeTabURL: active).absoluteString, "safarium://start")
        s.set(1, forKey: BrowserSettings.Key.newWindowOpensWith)
        XCTAssertEqual(s.resolvedNewWindowURL(activeTabURL: active).absoluteString, "https://example.com")
        s.set(2, forKey: BrowserSettings.Key.newWindowOpensWith)
        XCTAssertEqual(s.resolvedNewWindowURL(activeTabURL: active).absoluteString, "about:blank")
        s.set(3, forKey: BrowserSettings.Key.newWindowOpensWith)
        XCTAssertEqual(s.resolvedNewWindowURL(activeTabURL: active), active)
        XCTAssertEqual(s.resolvedNewWindowURL(activeTabURL: nil).absoluteString, "safarium://start")
        s.set(9, forKey: BrowserSettings.Key.newWindowOpensWith)
        XCTAssertEqual(s.resolvedNewWindowURL(activeTabURL: active).absoluteString, "safarium://start")
    }

    func testHistoryRetentionSecondsForEachSelection() {
        XCTAssertEqual(s.historyRetentionSeconds, 86_400 * 365, "default is one year")
        let expected: [(Int, TimeInterval?)] = [
            (0, 86_400), (1, 604_800), (2, 1_209_600), (3, 2_592_000), (4, 31_536_000),
            (5, nil), (-1, nil), (99, nil)
        ]
        for (raw, value) in expected {
            s.set(raw, forKey: BrowserSettings.Key.removeHistory)
            XCTAssertEqual(s.historyRetentionSeconds, value, "removeHistory=\(raw)")
        }
    }

    // MARK: - Downloads

    func testDownloadDefaults() {
        XCTAssertEqual(s.downloadLocationMode, 0)
        XCTAssertFalse(s.askForEachDownload)
        XCTAssertEqual(s.removeDownloadsMode, 0)
        XCTAssertFalse(s.openSafeFilesAfterDownloading)
    }

    func testDefaultDownloadDirectoryIsDownloadsFolder() {
        XCTAssertTrue(s.resolvedDownloadDirectoryPath.hasSuffix("Downloads"), s.resolvedDownloadDirectoryPath)
    }

    func testDesktopDownloadModeResolvesDesktop() {
        s.set(1, forKey: BrowserSettings.Key.downloadLocation)
        XCTAssertTrue(s.resolvedDownloadDirectoryPath.hasSuffix("Desktop"), s.resolvedDownloadDirectoryPath)
        XCTAssertFalse(s.askForEachDownload)
    }

    func testAskModeIsFlaggedAndUsesDownloadsFolder() {
        s.set(2, forKey: BrowserSettings.Key.downloadLocation)
        XCTAssertTrue(s.askForEachDownload)
        XCTAssertTrue(s.resolvedDownloadDirectoryPath.hasSuffix("Downloads"))
    }

    func testCustomDownloadFolderIsUsedWhenSet() {
        s.set(3, forKey: BrowserSettings.Key.downloadLocation)
        s.set("/Volumes/Scratch/Incoming", forKey: BrowserSettings.Key.customDownloadDir)
        XCTAssertEqual(s.resolvedDownloadDirectoryPath, "/Volumes/Scratch/Incoming")
    }

    func testCustomDownloadModeWithEmptyPathFallsBackToDownloads() {
        s.set(3, forKey: BrowserSettings.Key.downloadLocation)
        s.set("", forKey: BrowserSettings.Key.customDownloadDir)
        XCTAssertTrue(s.resolvedDownloadDirectoryPath.hasSuffix("Downloads"))
    }

    func testCustomPathIgnoredWhenNotCustomMode() {
        s.set(0, forKey: BrowserSettings.Key.downloadLocation)
        s.set("/Volumes/Scratch", forKey: BrowserSettings.Key.customDownloadDir)
        XCTAssertNotEqual(s.resolvedDownloadDirectoryPath, "/Volumes/Scratch")
    }

    func testSafeDownloadExtensionsAreAllowed() {
        let safe = ["a.pdf", "a.PNG", "photo.jpeg", "clip.MP4", "song.flac", "notes.txt", "data.csv",
                    "archive.zip", "archive.tar", "bundle.tar.gz", "pic.HEIC", "vec.svg", "x.webp", "m.m4a"]
        for name in safe {
            XCTAssertTrue(s.isSafeDownloadFile(atPath: "/Users/me/Downloads/" + name), name)
        }
    }

    func testUnsafeDownloadExtensionsAreRejected() {
        let unsafe = ["setup.exe", "run.sh", "app.app", "image.dmg", "pkg.pkg", "lib.dylib", "x.js", "page.html", "x.jar"]
        for name in unsafe {
            XCTAssertFalse(s.isSafeDownloadFile(atPath: "/Users/me/Downloads/" + name), name)
        }
    }

    func testExtensionlessAndHiddenFilesAreNotSafe() {
        XCTAssertFalse(s.isSafeDownloadFile(atPath: "/Users/me/Downloads/README"))
        XCTAssertFalse(s.isSafeDownloadFile(atPath: ""))
    }

    func testSafeExtensionInDirectoryNameDoesNotCount() {
        XCTAssertFalse(s.isSafeDownloadFile(atPath: "/Users/me/bundle.zip/payload"))
    }

    func testOnlyLastExtensionIsConsideredForSafety() {
        XCTAssertFalse(s.isSafeDownloadFile(atPath: "/tmp/evil.pdf.exe"))
        XCTAssertTrue(s.isSafeDownloadFile(atPath: "/tmp/report.exe.pdf"))
    }

    // MARK: - Session save / restore

    func testSaveAndRestoreSessionRoundTrip() {
        s.saveSession(urls: ["https://a.example", "https://b.example", "https://c.example"], activeIndex: 1)
        let restored = s.savedSession()
        XCTAssertEqual(restored.urls.map(\.absoluteString), ["https://a.example", "https://b.example", "https://c.example"])
        XCTAssertEqual(restored.activeIndex, 1)
    }

    func testSavedSessionIsEmptyWhenNothingStored() {
        let restored = s.savedSession()
        XCTAssertTrue(restored.urls.isEmpty)
        XCTAssertEqual(restored.activeIndex, 0)
    }

    func testSaveEmptyListStoresEmptySession() {
        s.saveSession(urls: [], activeIndex: 4)
        let restored = s.savedSession()
        XCTAssertTrue(restored.urls.isEmpty)
        XCTAssertEqual(restored.activeIndex, 0)
    }

    func testSaveDropsEmptyEntriesBeforeActiveAndRemapsIndex() {
        s.saveSession(urls: ["", "https://a.example", "https://active.example", "https://later.example"], activeIndex: 2)
        let restored = s.savedSession()
        XCTAssertEqual(restored.urls.map(\.absoluteString), ["https://a.example", "https://active.example", "https://later.example"])
        XCTAssertEqual(restored.urls[restored.activeIndex].absoluteString, "https://active.example")
    }

    func testSaveKeepsActiveTabWhenEmptyEntryPrecedesIt() {
        s.saveSession(urls: ["https://a.example", "", "https://active.example", "https://later.example"], activeIndex: 2)
        let restored = s.savedSession()
        XCTAssertEqual(restored.urls[restored.activeIndex].absoluteString, "https://active.example")
    }

    func testSaveWhenActiveTabIsEmptyPointsAtPreviousRetainedTab() {
        s.saveSession(urls: ["https://a.example", ""], activeIndex: 1)
        let restored = s.savedSession()
        XCTAssertEqual(restored.urls.map(\.absoluteString), ["https://a.example"])
        XCTAssertEqual(restored.activeIndex, 0)
    }

    func testSaveAllEmptyEntriesStoresNoTabs() {
        s.saveSession(urls: ["", ""], activeIndex: 0)
        XCTAssertTrue(s.savedSession().urls.isEmpty)
    }

    func testSaveClampsActiveIndexBeyondEnd() {
        s.saveSession(urls: ["https://a.example", "https://b.example"], activeIndex: 10)
        XCTAssertEqual(s.savedSession().activeIndex, 1)
    }

    func testSaveClampsNegativeActiveIndexToZero() {
        s.saveSession(urls: ["https://a.example", "https://b.example"], activeIndex: -5)
        XCTAssertEqual(s.savedSession().activeIndex, 0)
    }

    func testSaveOverwritesPreviousSession() {
        s.saveSession(urls: ["https://old.example"], activeIndex: 0)
        s.saveSession(urls: ["https://new.example"], activeIndex: 0)
        XCTAssertEqual(s.savedSession().urls.map(\.absoluteString), ["https://new.example"])
    }

    func testSavedSessionDropsMalformedURLAndRemapsIndex() {
        suite.set(["https://ok.example", "http://bad url", "https://later.example"],
                  forKey: BrowserSettings.Key.savedSessionTabs)
        suite.set(2, forKey: BrowserSettings.Key.savedSessionActiveIndex)
        let restored = s.savedSession()
        XCTAssertEqual(restored.urls.map(\.absoluteString), ["https://ok.example", "https://later.example"])
        XCTAssertEqual(restored.urls[restored.activeIndex].absoluteString, "https://later.example")
    }

    func testSavedSessionClampsStoredIndexAndNegativeValues() {
        suite.set(["https://a.example", "https://b.example"], forKey: BrowserSettings.Key.savedSessionTabs)
        suite.set(99, forKey: BrowserSettings.Key.savedSessionActiveIndex)
        XCTAssertEqual(s.savedSession().activeIndex, 1)
        suite.set(-3, forKey: BrowserSettings.Key.savedSessionActiveIndex)
        XCTAssertEqual(s.savedSession().activeIndex, 0)
    }

    // MARK: - Tabs

    func testTabDefaults() {
        XCTAssertEqual(s.openPagesInTabsMode, 0)
        XCTAssertNil(s.autoCloseTabInterval)
        XCTAssertEqual(s.tabLayout, "compact")
        XCTAssertTrue(s.showWebsiteColorInToolbar)
        XCTAssertFalse(s.alwaysShowWebsiteTitles)
        XCTAssertFalse(s.activateNewTabsOnOpen)
        XCTAssertTrue(s.cmdNumberSwitchesTabs)
    }

    func testAutoCloseIntervals() {
        let expected: [(Int, TimeInterval?)] = [(0, nil), (1, 86_400), (2, 604_800), (3, 2_592_000), (4, nil), (-2, nil)]
        for (raw, value) in expected {
            s.set(raw, forKey: BrowserSettings.Key.autoCloseTabs)
            XCTAssertEqual(s.autoCloseTabInterval, value, "autoCloseTabs=\(raw)")
        }
    }

    func testTabLayoutAndBooleanOverrides() {
        s.set("wide", forKey: BrowserSettings.Key.tabLayout)
        s.set(false, forKey: BrowserSettings.Key.showWebsiteColor)
        s.set(true, forKey: BrowserSettings.Key.alwaysShowTabTitles)
        s.set(true, forKey: BrowserSettings.Key.activateNewTabs)
        s.set(false, forKey: BrowserSettings.Key.cmdNumberSwitch)
        s.set(2, forKey: BrowserSettings.Key.openPagesInTabs)
        XCTAssertEqual(s.tabLayout, "wide")
        XCTAssertFalse(s.showWebsiteColorInToolbar)
        XCTAssertTrue(s.alwaysShowWebsiteTitles)
        XCTAssertTrue(s.activateNewTabsOnOpen)
        XCTAssertFalse(s.cmdNumberSwitchesTabs)
        XCTAssertEqual(s.openPagesInTabsMode, 2)
    }

    // MARK: - Quick website search and sites store

    func testDefaultQuickSearchSites() {
        let sites = BrowserSettings.defaultQuickSearchSites
        XCTAssertEqual(sites.map(\.keyword), ["youtube", "github", "wikipedia", "reddit", "amazon"])
        XCTAssertEqual(sites.map(\.domain), ["youtube.com", "github.com", "wikipedia.org", "reddit.com", "amazon.com"])
        XCTAssertTrue(sites.allSatisfy { $0.templateURL.contains("%@") })
    }

    func testQuickSearchSitesDefaultWhenNothingSaved() {
        XCTAssertEqual(s.quickSearchSites(), BrowserSettings.defaultQuickSearchSites)
    }

    func testQuickSearchSitesRoundTrip() {
        let custom = [BrowserSettings.QuickSearchSite(keyword: "docs", domain: "docs.example", templateURL: "https://docs.example/?q=%@")]
        s.saveQuickSearchSites(custom)
        XCTAssertEqual(s.quickSearchSites(), custom)
    }

    func testSavingEmptyQuickSearchListIsHonored() {
        s.saveQuickSearchSites([])
        XCTAssertTrue(s.quickSearchSites().isEmpty)
    }

    func testCorruptQuickSearchDataFallsBackToDefaults() {
        suite.set(Data([0x00, 0xFF, 0x12]), forKey: "Safarium.QuickSearchSites.v1")
        XCTAssertEqual(s.quickSearchSites(), BrowserSettings.defaultQuickSearchSites)
    }

    func testQuickSearchSiteCodableRoundTripPreservesFields() throws {
        let site = BrowserSettings.QuickSearchSite(keyword: "ñ", domain: "例え.jp", templateURL: "https://例え.jp/?q=%@")
        let data = try JSONEncoder().encode(site)
        let decoded = try JSONDecoder().decode(BrowserSettings.QuickSearchSite.self, from: data)
        XCTAssertEqual(decoded, site)
        XCTAssertEqual(decoded.templateURL, "https://例え.jp/?q=%@")
    }

    func testQuickSearchSiteDecodingRejectsMissingField() {
        let json = Data(#"{"keyword":"x","domain":"y.com"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BrowserSettings.QuickSearchSite.self, from: json))
    }

    func testQuickSearchSiteEqualityComparesAllFields() {
        let a = BrowserSettings.QuickSearchSite(keyword: "k", domain: "d.com", templateURL: "https://d.com/%@")
        XCTAssertEqual(a, BrowserSettings.QuickSearchSite(keyword: "k", domain: "d.com", templateURL: "https://d.com/%@"))
        XCTAssertNotEqual(a, BrowserSettings.QuickSearchSite(keyword: "K", domain: "d.com", templateURL: "https://d.com/%@"))
        XCTAssertNotEqual(a, BrowserSettings.QuickSearchSite(keyword: "k", domain: "e.com", templateURL: "https://d.com/%@"))
        XCTAssertNotEqual(a, BrowserSettings.QuickSearchSite(keyword: "k", domain: "d.com", templateURL: "https://d.com/x%@"))
    }

    func testQuickSearchMatchesKeywordWithQuery() {
        let match = s.matchQuickWebsiteSearch(for: "github cef")
        XCTAssertEqual(match?.site.keyword, "github")
        XCTAssertEqual(match?.query, "cef")
        XCTAssertEqual(match?.url.absoluteString, "https://github.com/search?q=cef")
    }

    func testQuickSearchKeywordIsCaseInsensitive() {
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "GITHUB cef")?.url.absoluteString, "https://github.com/search?q=cef")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "GitHub cef")?.site.keyword, "github")
    }

    func testQuickSearchMatchesDomainAsPrefix() {
        let match = s.matchQuickWebsiteSearch(for: "github.com swift")
        XCTAssertEqual(match?.site.domain, "github.com")
        XCTAssertEqual(match?.url.absoluteString, "https://github.com/search?q=swift")
    }

    func testQuickSearchEncodesSpacesInQuery() {
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "youtube rust tutorial")?.url.absoluteString,
                       "https://www.youtube.com/results?search_query=rust%20tutorial")
    }

    func testQuickSearchTakesEverythingAfterFirstWhitespaceAsQuery() {
        let match = s.matchQuickWebsiteSearch(for: "github cef extra words")
        XCTAssertEqual(match?.query, "cef extra words")
        XCTAssertEqual(match?.url.absoluteString, "https://github.com/search?q=cef%20extra%20words")
    }

    func testQuickSearchAcceptsAnyWhitespaceSeparator() {
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github\tswift")?.query, "swift")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github\nswift")?.query, "swift")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github\u{00A0}swift")?.query, "swift")
    }

    func testQuickSearchTrimsLeadingWhitespaceOfQuery() {
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "amazon    mug  ")?.url.absoluteString, "https://www.amazon.com/s?k=mug")
    }

    func testQuickSearchReturnsNilWithoutWhitespaceSeparator() {
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "github"))
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "github/cef"))
    }

    func testQuickSearchReturnsNilForWhitespaceOnlyOrMissingQuery() {
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "github   "))
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "github \t\n"))
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "   "))
        XCTAssertNil(s.matchQuickWebsiteSearch(for: ""))
    }

    func testQuickSearchReturnsNilForUnknownKeyword() {
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "unknownsite cef"))
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "git cef"), "keyword must match exactly")
    }

    func testQuickSearchPercentEncodesReservedQueryDelimiters() {
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github a&b")?.url.absoluteString, "https://github.com/search?q=a%26b")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github a=b")?.url.absoluteString, "https://github.com/search?q=a%3Db")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github x#y")?.url.absoluteString, "https://github.com/search?q=x%23y")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github c++")?.url.absoluteString, "https://github.com/search?q=c%2B%2B")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github a;b")?.url.absoluteString, "https://github.com/search?q=a%3Bb")
    }

    func testQuickSearchEncodesPercentAndUnicode() {
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "github 100%")?.url.absoluteString, "https://github.com/search?q=100%25")
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "wikipedia 東京")?.url.absoluteString,
                       "https://en.wikipedia.org/w/index.php?search=%E6%9D%B1%E4%BA%AC")
    }

    func testQuickSearchDisabledReturnsNil() {
        s.set(false, forKey: BrowserSettings.Key.quickWebsiteSearch)
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "github cef"))
    }

    func testQuickSearchFirstMatchingSiteWins() {
        s.saveQuickSearchSites([
            .init(keyword: "dup", domain: "first.example", templateURL: "https://first.example/?q=%@"),
            .init(keyword: "dup", domain: "second.example", templateURL: "https://second.example/?q=%@")
        ])
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "dup x")?.url.absoluteString, "https://first.example/?q=x")
    }

    func testQuickSearchMatchesCustomSiteByDomain() {
        s.saveQuickSearchSites([.init(keyword: "k", domain: "Docs.Example", templateURL: "https://docs.example/s?q=%@")])
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "docs.example term")?.url.absoluteString, "https://docs.example/s?q=term")
    }

    func testQuickSearchTemplateWithoutPlaceholderIsReturnedUnchanged() {
        s.saveQuickSearchSites([.init(keyword: "k", domain: "d.example", templateURL: "https://static.example/")])
        XCTAssertEqual(s.matchQuickWebsiteSearch(for: "k anything")?.url.absoluteString, "https://static.example/")
    }

    func testQuickSearchEmptyTemplateYieldsNoURL() {
        s.saveQuickSearchSites([.init(keyword: "k", domain: "d.example", templateURL: "")])
        XCTAssertNil(s.matchQuickWebsiteSearch(for: "k anything"))
    }

    // MARK: - Search selection

    func testSearchDefaults() {
        XCTAssertEqual(s.primarySearchEngine, .google)
        XCTAssertTrue(s.samePrivateSearchEngine)
        XCTAssertEqual(s.privateSearchEngine, .duckDuckGo)
        XCTAssertTrue(s.includeSearchSuggestions)
        XCTAssertTrue(s.enableQuickWebsiteSearch)
        XCTAssertTrue(s.showFavoritesInSearch)
    }

    func testInvalidPrimarySearchEngineFallsBackToGoogle() {
        s.set(77, forKey: BrowserSettings.Key.searchEngine)
        XCTAssertEqual(s.primarySearchEngine, .google)
        s.set(-1, forKey: BrowserSettings.Key.searchEngine)
        XCTAssertEqual(s.primarySearchEngine, .google)
    }

    func testInvalidPrivateSearchEngineFallsBackToDuckDuckGo() {
        s.set(42, forKey: BrowserSettings.Key.privateSearchEngine)
        XCTAssertEqual(s.privateSearchEngine, .duckDuckGo)
    }

    func testEffectiveSearchEngineUsesPrimaryWhenSamePrivateEnabled() {
        s.set(4, forKey: BrowserSettings.Key.searchEngine)
        XCTAssertEqual(s.effectiveSearchEngine(isPrivate: true), .ecosia)
        XCTAssertEqual(s.effectiveSearchEngine(isPrivate: false), .ecosia)
    }

    func testEffectiveSearchEngineUsesPrivateEngineWhenSeparate() {
        s.set(2, forKey: BrowserSettings.Key.searchEngine)
        s.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        s.set(6, forKey: BrowserSettings.Key.privateSearchEngine)
        XCTAssertEqual(s.effectiveSearchEngine(isPrivate: true), .kagi)
        XCTAssertEqual(s.effectiveSearchEngine(isPrivate: false), .bing)
    }

    func testEffectiveSearchEngineSeparateButDefaultPrivateEngine() {
        s.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        XCTAssertEqual(s.effectiveSearchEngine(isPrivate: true), .duckDuckGo)
        XCTAssertEqual(s.effectiveSearchEngine(isPrivate: false), .google)
    }

    func testSearchSuggestionAndFavoritesToggles() {
        s.set(false, forKey: BrowserSettings.Key.searchSuggestions)
        s.set(false, forKey: BrowserSettings.Key.showFavoritesInSearch)
        XCTAssertFalse(s.includeSearchSuggestions)
        XCTAssertFalse(s.showFavoritesInSearch)
    }

    // MARK: - Security, privacy

    func testSecurityAndPrivacyDefaults() {
        XCTAssertTrue(s.warnFraudulentWebsites)
        XCTAssertTrue(s.enableJavaScript)
        XCTAssertFalse(s.warnBeforeHTTP)
        XCTAssertTrue(s.preventCrossSiteTracking)
        XCTAssertTrue(s.requireTouchIDForPrivate)
    }

    func testSecurityAndPrivacyOverrides() {
        s.set(false, forKey: BrowserSettings.Key.warnFraudulent)
        s.set(false, forKey: BrowserSettings.Key.enableJavaScript)
        s.set(true, forKey: BrowserSettings.Key.warnHTTP)
        s.set(false, forKey: BrowserSettings.Key.preventTracking)
        s.set(false, forKey: BrowserSettings.Key.touchIDLockedPrivate)
        XCTAssertFalse(s.warnFraudulentWebsites)
        XCTAssertFalse(s.enableJavaScript)
        XCTAssertTrue(s.warnBeforeHTTP)
        XCTAssertFalse(s.preventCrossSiteTracking)
        XCTAssertFalse(s.requireTouchIDForPrivate)
    }

    // MARK: - Advanced & developer

    func testAdvancedDefaults() {
        XCTAssertFalse(s.showFullWebsiteAddress)
        XCTAssertFalse(s.minFontEnabled)
        XCTAssertEqual(s.effectiveMinimumFontSize, 0)
        XCTAssertFalse(s.tabHighlightsAll)
        XCTAssertTrue(s.advancedFingerprintProtection)
        XCTAssertEqual(s.advancedFingerprintScope, 1)
        XCTAssertFalse(s.globalPrivacyControl)
        XCTAssertFalse(s.blockAllCookies)
        XCTAssertTrue(s.showDeveloperFeatures)
        XCTAssertTrue(s.devAllowUnsignedExtensions)
        XCTAssertFalse(s.devSeparateDevToolsWindow)
        XCTAssertFalse(s.devDisableCache)
        XCTAssertFalse(s.remoteDebuggingEnabled)
    }

    func testMinimumFontSizeOnlyAppliesWhenEnabled() {
        s.set(7, forKey: BrowserSettings.Key.minFontSize)
        XCTAssertEqual(s.effectiveMinimumFontSize, 0, "disabled must ignore the stored size")
        s.set(true, forKey: BrowserSettings.Key.minFontEnabled)
        XCTAssertEqual(s.effectiveMinimumFontSize, 24, "stored index 7 selects the last size")
    }

    func testMinimumFontSizeMapsEveryIndexAndClamps() {
        s.set(true, forKey: BrowserSettings.Key.minFontEnabled)
        let expected = [9, 10, 11, 12, 14, 16, 18, 24]
        for (i, size) in expected.enumerated() {
            s.set(i, forKey: BrowserSettings.Key.minFontSize)
            XCTAssertEqual(s.effectiveMinimumFontSize, size, "index \(i)")
        }
        s.set(99, forKey: BrowserSettings.Key.minFontSize)
        XCTAssertEqual(s.effectiveMinimumFontSize, 24)
        s.set(-4, forKey: BrowserSettings.Key.minFontSize)
        XCTAssertEqual(s.effectiveMinimumFontSize, 9)
    }

    func testDefaultEncodingCharsetMapsAndClamps() {
        XCTAssertEqual(s.defaultEncodingCharset, "UTF-8")
        let names = ["UTF-8", "ISO-8859-1", "windows-1252", "ISO-8859-9", "Shift_JIS"]
        for (i, name) in names.enumerated() {
            s.set(i, forKey: BrowserSettings.Key.defaultEncoding)
            XCTAssertEqual(s.defaultEncodingCharset, name)
        }
        s.set(99, forKey: BrowserSettings.Key.defaultEncoding)
        XCTAssertEqual(s.defaultEncodingCharset, "Shift_JIS")
        s.set(-1, forKey: BrowserSettings.Key.defaultEncoding)
        XCTAssertEqual(s.defaultEncodingCharset, "UTF-8")
    }

    func testCustomStyleSheetPathRequiresCustomMode() {
        s.set("/styles/site.css", forKey: BrowserSettings.Key.customStyleSheetPath)
        XCTAssertEqual(s.customStyleSheetPath, "", "mode 0 means no custom sheet")
        s.set(1, forKey: BrowserSettings.Key.customStyleSheet)
        XCTAssertEqual(s.customStyleSheetPath, "/styles/site.css")
    }

    func testCustomStyleSheetCustomModeWithoutPathIsEmpty() {
        s.set(1, forKey: BrowserSettings.Key.customStyleSheet)
        XCTAssertEqual(s.customStyleSheetPath, "")
    }

    func testCustomStyleSheetOtherModesAreIgnored() {
        s.set("/styles/site.css", forKey: BrowserSettings.Key.customStyleSheetPath)
        s.set(2, forKey: BrowserSettings.Key.customStyleSheet)
        XCTAssertEqual(s.customStyleSheetPath, "")
    }

    // MARK: - Website policies

    func testNormalizedHostStripsOneWWWAndLowercases() {
        XCTAssertEqual(BrowserSettings.normalizedHost(from: URL(string: "https://www.Example.com/path")), "example.com")
        XCTAssertEqual(BrowserSettings.normalizedHost(from: URL(string: "https://example.com")), "example.com")
        XCTAssertEqual(BrowserSettings.normalizedHost(from: URL(string: "http://WWW.foo.org")), "foo.org")
    }

    func testNormalizedHostOnlyStripsFirstWWW() {
        XCTAssertEqual(BrowserSettings.normalizedHost(from: URL(string: "https://www.www.x.com")), "www.x.com")
    }

    func testNormalizedHostLeavesOtherSubdomainsAndLookalikes() {
        XCTAssertEqual(BrowserSettings.normalizedHost(from: URL(string: "https://sub.www.example.com")), "sub.www.example.com")
        XCTAssertEqual(BrowserSettings.normalizedHost(from: URL(string: "https://wwwexample.com")), "wwwexample.com")
        XCTAssertEqual(BrowserSettings.normalizedHost(from: URL(string: "https://localhost:8080")), "localhost")
    }

    func testNormalizedHostNilForNilOrHostless() {
        XCTAssertNil(BrowserSettings.normalizedHost(from: nil))
        XCTAssertNil(BrowserSettings.normalizedHost(from: URL(string: "file:///tmp/x")))
        XCTAssertNil(BrowserSettings.normalizedHost(from: URL(string: "about:blank")))
    }

    func testWebsitePolicyDefaultWhenUnset() {
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: "example.com", defaultIndex: 2), 2)
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: nil, defaultIndex: 5), 5)
    }

    func testWebsitePolicyGlobalDefaultAppliesWhenNoHostOverride() {
        s.setWebsiteDefaultPolicy(category: "Camera", index: 1)
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: "example.com", defaultIndex: 2), 1)
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: nil, defaultIndex: 2), 1)
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: "", defaultIndex: 2), 1)
    }

    func testWebsitePolicyHostOverrideWinsOverGlobal() {
        s.setWebsiteDefaultPolicy(category: "Camera", index: 1)
        s.setWebsitePolicy(category: "Camera", host: "example.com", index: 0)
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: "example.com", defaultIndex: 2), 0)
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: "other.com", defaultIndex: 2), 1)
    }

    func testWebsitePolicyHostOverrideZeroIsHonored() {
        s.setWebsitePolicy(category: "Camera", host: "example.com", index: 0)
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: "example.com", defaultIndex: 9), 0)
    }

    func testRemovingHostPolicyRevertsToGlobal() {
        s.setWebsiteDefaultPolicy(category: "Camera", index: 3)
        s.setWebsitePolicy(category: "Camera", host: "example.com", index: 0)
        s.removeWebsitePolicy(category: "Camera", host: "example.com")
        XCTAssertEqual(s.websitePolicyIndex(category: "Camera", host: "example.com", defaultIndex: 9), 3)
    }

    func testPoliciesAreScopedByCategory() {
        s.setWebsitePolicy(category: "Camera", host: "example.com", index: 0)
        XCTAssertEqual(s.websitePolicyIndex(category: "Microphone", host: "example.com", defaultIndex: 7), 7)
    }

    func testConfiguredHostsAreSortedAndScopedToCategory() {
        s.setWebsitePolicy(category: "Camera", host: "zeta.com", index: 1)
        s.setWebsitePolicy(category: "Camera", host: "alpha.com", index: 1)
        s.setWebsitePolicy(category: "Camera", host: "mid.org", index: 0)
        s.setWebsitePolicy(category: "Camera2", host: "other.com", index: 0)
        s.setWebsiteDefaultPolicy(category: "Camera", index: 1)
        XCTAssertEqual(s.configuredHosts(for: "Camera"), ["alpha.com", "mid.org", "zeta.com"])
    }

    func testConfiguredHostsEmptyWhenNothingConfigured() {
        XCTAssertTrue(s.configuredHosts(for: "Nothing").isEmpty)
    }

    func testPolicyChangeNotificationsCarryCategoryAndHost() {
        var received: [String: Any] = [:]
        let token = NotificationCenter.default.addObserver(forName: .safariumWebsitePoliciesDidChange, object: s, queue: nil) { note in
            received = (note.userInfo as? [String: Any]) ?? [:]
        }
        defer { NotificationCenter.default.removeObserver(token) }
        s.setWebsitePolicy(category: "Camera", host: "example.com", index: 2)
        XCTAssertEqual(received["category"] as? String, "Camera")
        XCTAssertEqual(received["host"] as? String, "example.com")
        XCTAssertEqual(received["index"] as? Int, 2)
        s.removeWebsitePolicy(category: "Camera", host: "example.com")
        XCTAssertEqual(received["host"] as? String, "example.com")
        XCTAssertNil(received["index"])
    }

    func testDefaultPolicyNotificationCarriesCategoryAndIndex() {
        var received: [String: Any] = [:]
        let token = NotificationCenter.default.addObserver(forName: .safariumWebsitePoliciesDidChange, object: s, queue: nil) { note in
            received = (note.userInfo as? [String: Any]) ?? [:]
        }
        defer { NotificationCenter.default.removeObserver(token) }
        s.setWebsiteDefaultPolicy(category: "Page Zoom", index: 6)
        XCTAssertEqual(received["category"] as? String, "Page Zoom")
        XCTAssertEqual(received["index"] as? Int, 6)
        XCTAssertNil(received["host"])
    }

    // MARK: - Page zoom

    func testPageZoomDefaultsToOneHundredPercent() {
        XCTAssertEqual(s.pageZoomFactor(for: URL(string: "https://example.com")), 1.0)
        XCTAssertEqual(s.pageZoomFactor(for: nil), 1.0)
    }

    func testPageZoomValuesAreStable() {
        XCTAssertEqual(BrowserSettings.pageZoomValues, [0.50, 0.75, 0.85, 1.0, 1.15, 1.25, 1.50, 1.75, 2.0, 2.5, 3.0])
    }

    func testPageZoomPerHostAndClamping() {
        let url = URL(string: "https://www.example.com/a")
        s.setWebsitePolicy(category: "Page Zoom", host: "example.com", index: 0)
        XCTAssertEqual(s.pageZoomFactor(for: url), 0.5)
        s.setWebsitePolicy(category: "Page Zoom", host: "example.com", index: 8)
        XCTAssertEqual(s.pageZoomFactor(for: url), 2.0)
        s.setWebsitePolicy(category: "Page Zoom", host: "example.com", index: 10)
        XCTAssertEqual(s.pageZoomFactor(for: url), 3.0)
        s.setWebsitePolicy(category: "Page Zoom", host: "example.com", index: 99)
        XCTAssertEqual(s.pageZoomFactor(for: url), 3.0)
        s.setWebsitePolicy(category: "Page Zoom", host: "example.com", index: -4)
        XCTAssertEqual(s.pageZoomFactor(for: url), 0.5)
    }

    func testPageZoomUsesGlobalDefaultWhenHostUnset() {
        s.setWebsiteDefaultPolicy(category: "Page Zoom", index: 6)
        XCTAssertEqual(s.pageZoomFactor(for: URL(string: "https://nothing.example")), 1.5)
    }

    // MARK: - Engine preferences snapshot

    func testEnginePreferencesDictionaryDefaults() {
        let d = s.enginePreferencesDictionary()
        XCTAssertEqual(d["enableJavaScript"] as? Bool, true)
        XCTAssertEqual(d["warnFraudulent"] as? Bool, true)
        XCTAssertEqual(d["preventCrossSiteTracking"] as? Bool, true)
        XCTAssertEqual(d["blockAllCookies"] as? Bool, false)
        XCTAssertEqual(d["globalPrivacyControl"] as? Bool, false)
        XCTAssertEqual(d["webrtcIPProtection"] as? Bool, true)
        XCTAssertEqual(d["minimumFontSize"] as? Int, 0)
        XCTAssertEqual(d["defaultEncoding"] as? String, "UTF-8")
        XCTAssertEqual(d["askForEachDownload"] as? Bool, false)
        XCTAssertEqual(d["allowUnsignedExtensions"] as? Bool, true)
        XCTAssertEqual(d["autofillPasswords"] as? Bool, true)
        XCTAssertEqual(d["autofillAddresses"] as? Bool, true)
        XCTAssertEqual(d["autofillCards"] as? Bool, true)
        XCTAssertEqual(d["customStyleSheetPath"] as? String, "")
        XCTAssertEqual(d["downloadDirectory"] as? String, s.resolvedDownloadDirectoryPath)
        XCTAssertEqual(d.count, 15)
    }

    func testEnginePreferencesDictionaryReflectsChanges() {
        s.set(false, forKey: BrowserSettings.Key.enableJavaScript)
        s.set(true, forKey: BrowserSettings.Key.minFontEnabled)
        s.set(3, forKey: BrowserSettings.Key.minFontSize)
        s.set(2, forKey: BrowserSettings.Key.defaultEncoding)
        s.set(2, forKey: BrowserSettings.Key.downloadLocation)
        s.set(false, forKey: BrowserSettings.Key.webrtcIPProtection)
        let d = s.enginePreferencesDictionary()
        XCTAssertEqual(d["enableJavaScript"] as? Bool, false)
        XCTAssertEqual(d["minimumFontSize"] as? Int, 12)
        XCTAssertEqual(d["defaultEncoding"] as? String, "windows-1252")
        XCTAssertEqual(d["askForEachDownload"] as? Bool, true)
        XCTAssertEqual(d["webrtcIPProtection"] as? Bool, false)
    }

    // MARK: - Privacy Bridge Keys, Content Blockers, and Policy Dictionary

    func testPrivacyKeysAndDefaults() {
        XCTAssertEqual(BrowserSettings.Key.httpsOnlyMode, "Safarium.Pref.HTTPSOnlyMode")
        XCTAssertEqual(BrowserSettings.Key.stripTrackingParams, "Safarium.Pref.StripTrackingParams")
        XCTAssertEqual(BrowserSettings.Key.referrerTrimming, "Safarium.Pref.ReferrerTrimming")
        XCTAssertEqual(BrowserSettings.Key.webrtcIPProtection, "Safarium.Pref.WebRTCIPProtection")
        XCTAssertEqual(BrowserSettings.Key.privacyProtectionLevel, "Safarium.Pref.PrivacyProtectionLevel")

        XCTAssertTrue(s.httpsOnlyMode)
        XCTAssertTrue(s.stripTrackingParams)
        XCTAssertTrue(s.referrerTrimming)
        XCTAssertTrue(s.webrtcIPProtection)
        XCTAssertEqual(s.privacyProtectionLevel, .standard)
        XCTAssertEqual(s.privacyProtectionLevel.rawValue, 0)
    }

    func testPrivacyProtectionOverrides() {
        s.set(false, forKey: BrowserSettings.Key.httpsOnlyMode)
        s.set(false, forKey: BrowserSettings.Key.stripTrackingParams)
        s.set(false, forKey: BrowserSettings.Key.referrerTrimming)
        s.set(false, forKey: BrowserSettings.Key.webrtcIPProtection)
        s.set(1, forKey: BrowserSettings.Key.privacyProtectionLevel)

        XCTAssertFalse(s.httpsOnlyMode)
        XCTAssertFalse(s.stripTrackingParams)
        XCTAssertFalse(s.referrerTrimming)
        XCTAssertFalse(s.webrtcIPProtection)
        XCTAssertEqual(s.privacyProtectionLevel, .strict)

        s.set(99, forKey: BrowserSettings.Key.privacyProtectionLevel)
        XCTAssertEqual(s.privacyProtectionLevel, .standard)
    }

    func testContentBlockersCanonicalHelpersUseZeroOnOneOffConvention() {
        XCTAssertTrue(s.isContentBlockersEnabled(forHost: "example.com"))

        s.setContentBlockersEnabled(false, forHost: "WWW.Example.COM")
        XCTAssertEqual(s.websitePolicyIndex(category: "Content Blockers", host: "example.com", defaultIndex: 0), 1)
        XCTAssertFalse(s.isContentBlockersEnabled(forHost: "example.com"))
        XCTAssertFalse(s.isContentBlockersEnabled(forHost: "www.example.com"))

        s.setContentBlockersEnabled(true, forHost: "example.com")
        XCTAssertEqual(s.websitePolicyIndex(category: "Content Blockers", host: "example.com", defaultIndex: 0), 0)
        XCTAssertTrue(s.isContentBlockersEnabled(forHost: "example.com"))

        s.setWebsiteDefaultPolicy(category: "Content Blockers", index: 1)
        XCTAssertFalse(s.isContentBlockersEnabled(forHost: "unconfigured.example"))
        XCTAssertTrue(s.isContentBlockersEnabled(forHost: "example.com"))
    }

    func testPrivacyPolicyDictionaryDefaultsAndOverrides() {
        let defaultsDict = s.privacyPolicyDictionary()
        XCTAssertEqual(defaultsDict["preventCrossSiteTracking"] as? Bool, true)
        XCTAssertEqual(defaultsDict["blockAllCookies"] as? Bool, false)
        XCTAssertEqual(defaultsDict["advancedFingerprint"] as? Bool, true)
        XCTAssertEqual(defaultsDict["advancedFingerprintScope"] as? Int, 1)
        XCTAssertEqual(defaultsDict["globalPrivacyControl"] as? Bool, false)
        XCTAssertEqual(defaultsDict["httpsOnlyMode"] as? Bool, true)
        XCTAssertEqual(defaultsDict["warnHTTP"] as? Bool, false)
        XCTAssertEqual(defaultsDict["stripTrackingParams"] as? Bool, true)
        XCTAssertEqual(defaultsDict["referrerTrimming"] as? Bool, true)
        XCTAssertEqual(defaultsDict["webrtcIPProtection"] as? Bool, true)
        XCTAssertEqual(defaultsDict["protectionLevel"] as? Int, 0)
        XCTAssertEqual(defaultsDict["contentBlockersDefault"] as? Int, 0)
        XCTAssertEqual(defaultsDict["contentBlockersDisabledHosts"] as? [String], [])
        XCTAssertEqual(defaultsDict["contentBlockersEnabledHosts"] as? [String], [])
        XCTAssertEqual(defaultsDict["microphoneDefault"] as? Int, 0)
        XCTAssertEqual(defaultsDict["cameraDefault"] as? Int, 0)
        XCTAssertEqual(defaultsDict["microphoneAllowedHosts"] as? [String], [])
        XCTAssertEqual(defaultsDict["cameraAllowedHosts"] as? [String], [])
        XCTAssertEqual(defaultsDict.count, 18)

        s.set(false, forKey: BrowserSettings.Key.httpsOnlyMode)
        s.set(false, forKey: BrowserSettings.Key.stripTrackingParams)
        s.set(false, forKey: BrowserSettings.Key.referrerTrimming)
        s.set(false, forKey: BrowserSettings.Key.webrtcIPProtection)
        s.set(1, forKey: BrowserSettings.Key.privacyProtectionLevel)
        s.set(true, forKey: BrowserSettings.Key.globalPrivacyControl)
        s.setWebsiteDefaultPolicy(category: "Content Blockers", index: 1)
        s.setContentBlockersEnabled(false, forHost: "zeta.example")
        s.setContentBlockersEnabled(false, forHost: "alpha.example")
        s.setContentBlockersEnabled(true, forHost: "beta.example")
        s.setWebsiteDefaultPolicy(category: "Microphone", index: 1)
        s.setWebsitePolicy(category: "Microphone", host: "meet.google.com", index: 2)
        s.setWebsitePolicy(category: "Camera", host: "zoom.us", index: 2)
        s.setWebsitePolicy(category: "Camera", host: "denied.example", index: 1)

        let updated = s.privacyPolicyDictionary()
        XCTAssertEqual(updated["httpsOnlyMode"] as? Bool, false)
        XCTAssertEqual(updated["stripTrackingParams"] as? Bool, false)
        XCTAssertEqual(updated["referrerTrimming"] as? Bool, false)
        XCTAssertEqual(updated["webrtcIPProtection"] as? Bool, false)
        XCTAssertEqual(updated["protectionLevel"] as? Int, 1)
        XCTAssertEqual(updated["globalPrivacyControl"] as? Bool, true)
        XCTAssertEqual(updated["contentBlockersDefault"] as? Int, 1)
        XCTAssertEqual(updated["contentBlockersDisabledHosts"] as? [String], ["alpha.example", "zeta.example"])
        XCTAssertEqual(updated["contentBlockersEnabledHosts"] as? [String], ["beta.example"])
        XCTAssertEqual(updated["microphoneDefault"] as? Int, 1)
        XCTAssertEqual(updated["cameraDefault"] as? Int, 0)
        XCTAssertEqual(updated["microphoneAllowedHosts"] as? [String], ["meet.google.com"])
        XCTAssertEqual(updated["cameraAllowedHosts"] as? [String], ["zoom.us"])
    }

    // MARK: - Default browser (no system state touched)

    func testSetAsDefaultBrowserFailsOutsideAppBundle() {
        let exp = expectation(description: "completion")
        s.setAsDefaultBrowser { success, error in
            XCTAssertFalse(success)
            XCTAssertNil(error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - MockBrowserEngine privacy bridge & tab simulation

    @MainActor
    func testMockBrowserEnginePrivacyBridgeAndTabSimulation() {
        final class PrivacyDelegate: BrowserTabEngineDelegate {
            var events: [PrivacyEvent] = []
            var securityUpdates: [(ConnectionSecurityState, String)] = []
            func tabEngine(_ tab: BrowserTabEngine, didChangeURL url: URL?) {}
            func tabEngine(_ tab: BrowserTabEngine, didChangeTitle title: String) {}
            func tabEngine(_ tab: BrowserTabEngine, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {}
            func tabEngine(_ tab: BrowserTabEngine, didUpdateProgress progress: Double) {}
            func tabEngine(_ tab: BrowserTabEngine, didSampleTopEdgeColor sample: TopEdgeColorSample) {}
            func tabEngine(_ tab: BrowserTabEngine, didRecordPrivacyEvent event: PrivacyEvent) {
                events.append(event)
            }
            func tabEngine(_ tab: BrowserTabEngine, didUpdateConnectionSecurity state: ConnectionSecurityState, host: String) {
                securityUpdates.append((state, host))
            }
        }

        let engine = MockBrowserEngine()
        let policy = s.privacyPolicyDictionary()
        engine.syncPrivacyPolicy(policy)
        XCTAssertEqual(engine.syncedPrivacyPolicies.count, 1)

        engine.allowInsecureHTTP(forHost: "http-only.example")
        XCTAssertEqual(engine.allowedInsecureHTTPHosts, ["http-only.example"])

        engine.mockWebsiteDataRecords = [
            WebsiteDataRecord(domain: "example.com", cookieCount: 3, hasCookies: true, hasCache: false),
            WebsiteDataRecord(domain: "tracker.net", cookieCount: 1, hasCookies: true, hasCache: true)
        ]

        var fetched: [WebsiteDataRecord] = []
        engine.fetchWebsiteDataRecords { fetched = $0 }
        XCTAssertEqual(fetched.map(\.domain), ["example.com", "tracker.net"])

        var removedOk = false
        engine.removeWebsiteData(forDomains: ["www.example.com"]) { removedOk = $0 }
        XCTAssertTrue(removedOk)
        XCTAssertEqual(engine.removedWebsiteDataDomains, [["www.example.com"]])
        XCTAssertEqual(engine.mockWebsiteDataRecords.map(\.domain), ["tracker.net"])

        let tab = engine.createTab(initialURL: URL(string: "https://example.com")!, parentView: nil, isPrivate: true) as! MockBrowserTab
        let delegate = PrivacyDelegate()
        tab.delegate = delegate
        XCTAssertEqual(tab.connectionSecurityState, .secureHTTPS)
        XCTAssertEqual(tab.connectionSecurityHost, "example.com")

        tab.simulateConnectionSecurity(.upgradedHTTPS, host: "WWW.Example.org")
        XCTAssertEqual(tab.connectionSecurityState, .upgradedHTTPS)
        XCTAssertEqual(tab.connectionSecurityHost, "example.org")
        XCTAssertEqual(delegate.securityUpdates.last?.0, .upgradedHTTPS)
        XCTAssertEqual(delegate.securityUpdates.last?.1, "example.org")

        let ev = PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: "example.org",
            trackerHost: "doubleclick.net",
            entityDomain: "google.com",
            ownerName: "Google",
            category: .advertising,
            isPrivate: false
        )
        tab.simulatePrivacyEvent(ev)
        XCTAssertEqual(delegate.events.count, 1)
        XCTAssertTrue(delegate.events[0].isPrivate, "private tab must mark simulated events as private")
    }
}
