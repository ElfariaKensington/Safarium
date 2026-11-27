import XCTest
import AppKit
import ObjectiveC
@testable import Safarium

/// Address-bar popover: suggestion building, selection math, popover mode, row layout, relative dates, monogram and artwork rects.
@MainActor
final class AddressBarPopoverTests: HermeticTestCase {
    typealias Ctl = AddressBarPopoverController
    private var controller: Ctl!
    private var savedFavorites: [AssetLoader.BookmarkEntry] = []

    private let suggestionsKey = "Safarium.Pref.SearchSuggestions"
    private let favoritesOrderKey = "Safarium.FavoritesOrderURLs.v1"
    private let customFavoritesKey = "Safarium.CustomFavoritesEntries.v1"

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.setUpIsolated() }
    }

    private func setUpIsolated() {
        _ = NSApplication.shared
        savedFavorites = AssetLoader.shared.favorites()
        AssetLoader.shared.saveFavoritesOrder([])
        AssetLoader.shared.clearHistory()
        UserDefaults.standard.removeObject(forKey: suggestionsKey)
        controller = Ctl()
    }

    override func tearDown() {
        MainActor.assumeIsolated { self.tearDownIsolated() }
        super.tearDown()
    }

    private func tearDownIsolated() {
        controller.close()
        controller = nil
        AssetLoader.shared.saveFavoritesOrder(savedFavorites)
        UserDefaults.standard.removeObject(forKey: favoritesOrderKey)
        UserDefaults.standard.removeObject(forKey: customFavoritesKey)
        AssetLoader.shared.clearHistory()
        UserDefaults.standard.removeObject(forKey: suggestionsKey)
    }

    // MARK: helpers

    private func bookmark(_ id: String, _ title: String, _ url: String) -> AssetLoader.BookmarkEntry {
        AssetLoader.BookmarkEntry(id: id, title: title, url: url, color: nil)
    }

    private func tab(_ id: String, _ title: String, _ url: String, active: Bool = false, start: Bool = false) -> Ctl.OpenTabInfo {
        Ctl.OpenTabInfo(id: id, title: title, url: URL(string: url)!, favicon: nil, isActive: active, isStartPage: start)
    }

    private func group(_ domain: String, _ url: String, title: String = "", visited: Date = Date(), count: Int = 1) -> Ctl.RecentGroup {
        Ctl.RecentGroup(domain: domain, latestURL: URL(string: url)!, title: title, count: count, visitedAt: visited, favicon: nil)
    }

    /// Sets the controller's query and context without showing the panel.
    private func setState(query: String, isPrivate: Bool = false, recent: [Ctl.RecentGroup] = [], tabs: [Ctl.OpenTabInfo] = [], activeDomain: String = "") {
        controller.update(query: query, isDark: false, isPrivate: isPrivate, recentGroups: recent, openTabs: tabs, activeDomain: activeDomain)
    }

    private func build(_ query: String, isPrivate: Bool = false, recent: [Ctl.RecentGroup] = [], tabs: [Ctl.OpenTabInfo] = []) -> [Ctl.SuggestionItem] {
        setState(query: query, isPrivate: isPrivate, recent: recent, tabs: tabs)
        controller.buildQuerySuggestions(query: query)
        return controller.suggestions
    }

    private func styles(_ items: [Ctl.SuggestionItem]) -> [Ctl.SuggestionRowStyle] {
        items.map(\.style)
    }

    private func urlOf(_ item: Ctl.SuggestionItem) -> URL? {
        if case .url(let u) = item.kind { return u }
        return nil
    }

    private func searchOf(_ item: Ctl.SuggestionItem) -> String? {
        if case .search(let q) = item.kind { return q }
        return nil
    }

    private func tabIDOf(_ item: Ctl.SuggestionItem) -> String? {
        if case .switchToTab(let id) = item.kind { return id }
        return nil
    }

    private func setSearchSuggestions(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: suggestionsKey)
    }

    private func engineKey(query: String) -> String {
        "\(BrowserSettings.shared.effectiveSearchEngine(isPrivate: false).rawValue)::\(query)"
    }

    private func seedHistory(_ entries: [(title: String, url: String)]) {
        // recordHistoryVisit inserts at the front, so record oldest first to keep the given order (newest first).
        for e in entries.reversed() {
            AssetLoader.shared.recordHistoryVisit(url: URL(string: e.url)!, title: e.title, visitedAt: Date())
        }
    }

    // MARK: - Value models

    func testRecentGroupStoresAllFields() {
        let now = Date(timeIntervalSince1970: 1_000)
        let g = Ctl.RecentGroup(domain: "a.com", latestURL: URL(string: "https://a.com/x")!, title: "A", count: 3, visitedAt: now, favicon: nil)
        XCTAssertEqual(g.domain, "a.com")
        XCTAssertEqual(g.latestURL.absoluteString, "https://a.com/x")
        XCTAssertEqual(g.title, "A")
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g.visitedAt, now)
        XCTAssertNil(g.favicon)
    }

    func testOpenTabInfoStoresStartPageAndActiveFlags() {
        let t = tab("t9", "Start", "safarium://start", active: true, start: true)
        XCTAssertEqual(t.id, "t9")
        XCTAssertTrue(t.isActive)
        XCTAssertTrue(t.isStartPage)
        XCTAssertEqual(t.url.scheme, "safarium")
    }

    func testReadingListEntryStoresFields() {
        let e = Ctl.ReadingListEntry(title: "WebKit", domain: "webkit.org", url: URL(string: "https://webkit.org/")!)
        XCTAssertEqual(e.title, "WebKit")
        XCTAssertEqual(e.domain, "webkit.org")
        XCTAssertEqual(e.url.host, "webkit.org")
    }

    func testSuggestionItemKeepsKindAndStyle() {
        let item = Ctl.SuggestionItem(title: "T", subtitle: "S", iconURLString: "", prefetchedIcon: nil,
                                      symbolName: "globe", style: .topHit, kind: .url(URL(string: "https://x.io")!))
        XCTAssertEqual(item.title, "T")
        XCTAssertEqual(item.subtitle, "S")
        XCTAssertEqual(item.symbolName, "globe")
        XCTAssertEqual(item.style, .topHit)
        XCTAssertEqual(urlOf(item)?.host, "x.io")
    }

    func testSuggestionKindCasesCarryPayloads() {
        XCTAssertEqual(searchOf(Ctl.SuggestionItem(title: "", subtitle: "", iconURLString: "", prefetchedIcon: nil, symbolName: nil, style: .googleSuggestion, kind: .search("q"))), "q")
        XCTAssertEqual(tabIDOf(Ctl.SuggestionItem(title: "", subtitle: "", iconURLString: "", prefetchedIcon: nil, symbolName: nil, style: .switchToTab, kind: .switchToTab("tab-7"))), "tab-7")
    }

    func testSuggestionRowStylesAreDistinct() {
        let all: [Ctl.SuggestionRowStyle] = [.topHit, .switchToTab, .googleSuggestion, .bookmarkOrHistory]
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() where i != j {
                XCTAssertNotEqual(String(describing: a), String(describing: b))
            }
        }
    }

    // MARK: - Controller state

    func testNewControllerIsNotShown() {
        XCTAssertFalse(controller.isShown)
    }

    func testCommitWithoutShownPanelReturnsFalse() {
        XCTAssertFalse(controller.commitSelectedSuggestionIfAny())
    }

    func testMoveSelectionWhenNotShownIsNoOp() {
        controller.moveSelection(delta: 1)
        controller.moveSelection(delta: -1)
        XCTAssertFalse(controller.isShown)
        XCTAssertTrue(controller.suggestions.isEmpty)
    }

    func testRepositionWhenNotShownIsNoOp() {
        controller.repositionIfShown()
        XCTAssertFalse(controller.isShown)
    }

    func testUpdateWithoutPanelStoresSuggestionsOnlyOnBuild() {
        setState(query: "abc")
        XCTAssertTrue(controller.suggestions.isEmpty)
        controller.buildQuerySuggestions(query: "abc")
        XCTAssertEqual(controller.suggestions.count, 1)
    }

    // MARK: - Selection wraparound (nextSelectionIndex)

    func testSelectionFromNoneForwardStartsAtFirst() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: -1, delta: 1, count: 5), 0)
    }

    func testSelectionFromNoneBackwardStartsAtLast() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: -1, delta: -1, count: 5), 4)
    }

    func testSelectionFromNoneWithZeroDeltaStartsAtLast() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: -1, delta: 0, count: 5), 4)
    }

    func testSelectionForwardSteps() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 0, delta: 1, count: 5), 1)
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 3, delta: 1, count: 5), 4)
    }

    func testSelectionForwardWrapsFromLast() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 4, delta: 1, count: 5), 0)
    }

    func testSelectionBackwardWrapsFromFirst() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 0, delta: -1, count: 5), 4)
    }

    func testSelectionBackwardSteps() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 3, delta: -2, count: 5), 1)
    }

    func testSelectionDeltaEqualToCountWrapsToSameIndex() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 2, delta: 5, count: 5), 2)
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 2, delta: -5, count: 5), 2)
    }

    func testSelectionDeltaLargerThanCountWraps() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 0, delta: 7, count: 5), 2)
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 1, delta: 12, count: 5), 3)
    }

    func testSelectionSingleItemAlwaysZero() {
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 0, delta: 1, count: 1), 0)
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 0, delta: -1, count: 1), 0)
        XCTAssertEqual(Ctl.nextSelectionIndex(current: -1, delta: 1, count: 1), 0)
    }

    func testSelectionEmptyListReturnsNil() {
        XCTAssertNil(Ctl.nextSelectionIndex(current: -1, delta: 1, count: 0))
        XCTAssertNil(Ctl.nextSelectionIndex(current: 0, delta: 1, count: 0))
    }

    func testSelectionNegativeDeltaLargerThanCountStaysInRange() {
        // Regression target: a backward move larger than the list must still land on a valid row.
        XCTAssertEqual(Ctl.nextSelectionIndex(current: 1, delta: -5, count: 3), 2)
    
    }

    func testSelectionResultAlwaysInRangeForForwardDeltas() {
        for count in 1...9 {
            for current in 0..<count {
                for delta in 0...20 {
                    let r = Ctl.nextSelectionIndex(current: current, delta: delta, count: count)
                    XCTAssertNotNil(r)
                    XCTAssertTrue((0..<count).contains(r ?? -1), "current \(current) delta \(delta) count \(count)")
                }
            }
        }
    }

    // MARK: - Popover width

    func testPopoverWidthWithoutHostUsesDefaultWidthCap() {
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: nil), 536)
    }

    func testPopoverWidthCapsAtFiveHundredThirtySix() {
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 1000), 536)
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 560), 536)
    }

    func testPopoverWidthShrinksWithNarrowHostButNotBelowFourForty() {
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 500), 476)
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 464), 440)
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 300), 440)
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 0), 440)
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: -100), 440)
    }

    func testPopoverWidthBoundaryAtFourSixtyFiveAndFiveSixty() {
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 465), 441)
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 559), 535)
        XCTAssertEqual(Ctl.popoverWidth(hostWindowWidth: 560), 536)
    }

    // MARK: - Start popover mode (blank / URL query)

    func testStartModeForBlankQueries() {
        for q in ["", "   ", "\n\t", " \u{00A0}"] {
            setState(query: q)
            XCTAssertTrue(controller.isStartPopoverMode(), "query '\(q)'")
        }
    }

    func testStartModeForHTTPAndHTTPSPrefixes() {
        for q in ["http://", "https://x.com", "  https://x  ", "http://example.com/path?q=1"] {
            setState(query: q)
            XCTAssertTrue(controller.isStartPopoverMode(), "query '\(q)'")
        }
    }

    func testStartModeAcceptsUppercaseSchemes() {
        for q in ["HTTP://EXAMPLE.COM", "HTTPS://A.B", "Https://mixed.case"] {
            setState(query: q)
            XCTAssertTrue(controller.isStartPopoverMode(), "query '\(q)'")
        }
    }

    func testSearchModeForPlainWords() {
        for q in ["swift", "example.com", "hello world", "http", "https", "httpx://a", "ftp://x", "http:", "www.apple.com"] {
            setState(query: q)
            XCTAssertFalse(controller.isStartPopoverMode(), "query '\(q)'")
        }
    }

    func testSearchModeForFullwidthSchemeIsNotAURL() {
        setState(query: "ｈｔｔｐ://x")
        XCTAssertFalse(controller.isStartPopoverMode())
    }

    func testStartModeChangesWhenQueryUpdates() {
        setState(query: "swift")
        XCTAssertFalse(controller.isStartPopoverMode())
        setState(query: "https://swift.org")
        XCTAssertTrue(controller.isStartPopoverMode())
        setState(query: "")
        XCTAssertTrue(controller.isStartPopoverMode())
    }

    // MARK: - Recently viewed filtering

    func testRecentlyViewedKeepsOnlyHTTPAndHTTPS() {
        setState(query: "", recent: [
            group("a.com", "https://a.com/"),
            group("b.com", "http://b.com/"),
            group("c.com", "ftp://c.com/"),
            group("d", "safarium://start"),
            group("e", "file:///tmp/x.html"),
        ])
        let out = controller.filteredRecentlyViewedGroups().map(\.domain)
        XCTAssertEqual(out, ["a.com", "b.com"])
    }

    func testRecentlyViewedDropsAboutBlankTitlesCaseInsensitively() {
        setState(query: "", recent: [
            group("a.com", "https://a.com/", title: "about:blank"),
            group("b.com", "https://b.com/", title: "About:Blank"),
            group("c.com", "https://c.com/", title: "Real"),
        ])
        XCTAssertEqual(controller.filteredRecentlyViewedGroups().map(\.domain), ["c.com"])
    }

    func testRecentlyViewedExcludesActiveDomainCaseInsensitively() {
        setState(query: "", recent: [group("a.com", "https://a.com/"), group("b.com", "https://b.com/")], activeDomain: "A.COM")
        XCTAssertEqual(controller.filteredRecentlyViewedGroups().map(\.domain), ["b.com"])
    }

    func testRecentlyViewedFallsBackWhenEveryGroupIsActiveDomain() {
        setState(query: "", recent: [group("a.com", "https://a.com/")], activeDomain: "a.com")
        XCTAssertEqual(controller.filteredRecentlyViewedGroups().map(\.domain), ["a.com"])
    }

    func testRecentlyViewedEmptyActiveDomainKeepsAll() {
        setState(query: "", recent: [group("a.com", "https://a.com/"), group("b.com", "https://b.com/")], activeDomain: "")
        XCTAssertEqual(controller.filteredRecentlyViewedGroups().count, 2)
    }

    func testRecentlyViewedUnknownActiveDomainKeepsAll() {
        setState(query: "", recent: [group("a.com", "https://a.com/")], activeDomain: "zzz.io")
        XCTAssertEqual(controller.filteredRecentlyViewedGroups().map(\.domain), ["a.com"])
    }

    func testRecentlyViewedEmptyInputGivesEmpty() {
        setState(query: "", recent: [])
        XCTAssertTrue(controller.filteredRecentlyViewedGroups().isEmpty)
    }

    func testRecentlyViewedAllInvalidGivesEmpty() {
        setState(query: "", recent: [group("x", "ftp://x/"), group("y", "about:blank")])
        XCTAssertTrue(controller.filteredRecentlyViewedGroups().isEmpty)
    }

    // MARK: - URL keys for de-duplication

    func testURLKeyDropsSchemeAndWWWAndLowercasesHost() {
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://WWW.Example.COM/Path/")!), "example.com/path")
    }

    func testURLKeyForRootPathsIsSameWithOrWithoutSlash() {
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://example.com")!), "example.com/")
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://example.com/")!), "example.com/")
    }

    func testURLKeyStripsWWWOnlyOnce() {
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://www.www.example.com/")!), "www.example.com/")
    }

    func testURLKeyKeepsSubdomainWWWInside() {
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://sub.www.example.com/")!), "sub.www.example.com/")
    }

    func testURLKeyDoesNotStripWWWWithoutDot() {
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://wwwexample.com/")!), "wwwexample.com/")
    }

    func testURLKeyTrimsSlashesAroundPathAndKeepsCase() {
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://example.com//A/B//")!), "example.com/a/b")
    }

    func testURLKeySchemeAndWWWIgnoredForSamePath() {
        // Same host and path → same key; this is the intended dedupe for identical pages.
        XCTAssertEqual(controller.normalizedURLKey(URL(string: "https://example.com/a")!),
                       controller.normalizedURLKey(URL(string: "http://www.example.com/a")!))
    }

    func testURLKeysForDifferentQueriesMustDiffer() {
        XCTAssertNotEqual(controller.normalizedURLKey(URL(string: "https://example.com/item?id=1")!),
                          controller.normalizedURLKey(URL(string: "https://example.com/item?id=2")!))
    
    }

    func testURLKeysForDifferentPortsMustDiffer() {
        XCTAssertNotEqual(controller.normalizedURLKey(URL(string: "https://example.com:8443/")!),
                          controller.normalizedURLKey(URL(string: "https://example.com/")!))
    
    }

    // MARK: - Query suggestions: top hit

    func testEmptyStateProducesOnlySearchRow() {
        let items = build("xyz")
        XCTAssertEqual(styles(items), [.googleSuggestion])
        XCTAssertEqual(items[0].title, "xyz")
        XCTAssertEqual(items[0].symbolName, "magnifyingglass")
        XCTAssertEqual(searchOf(items[0]), "xyz")
    }

    func testTopHitFromOpenTabByDomainPrefix() {
        let items = build("app", tabs: [tab("t1", "Shop", "https://www.apple.com/shop")])
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.first?.title, "apple.com")
        XCTAssertEqual(urlOf(items[0])?.absoluteString, "https://www.apple.com/shop")
    }

    func testTopHitFromOpenTabByTitlePrefixShowsDomain() {
        let items = build("apple", tabs: [tab("t1", "Apple Store", "https://example.org/x")])
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.first?.title, "example.org")
        XCTAssertEqual(items.first?.subtitle, "example.org")
    }

    func testStartPageTabIsNeverTopHit() {
        let items = build("app", tabs: [tab("s", "App Start", "safarium://start", start: true)])
        XCTAssertFalse(items.contains { $0.style == .topHit })
    }

    func testActiveTabCanBeTopHit() {
        let items = build("gith", tabs: [tab("a", "GitHub", "https://github.com/", active: true)])
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(urlOf(items[0])?.host, "github.com")
    }

    func testOpenTabBeatsFavoriteAsTopHit() {
        AssetLoader.shared.saveFavoritesOrder([bookmark("f1", "Apple", "https://www.apple.com/")])
        let items = build("app", tabs: [tab("t1", "Apple Tab", "https://apple.example/tab")])
        XCTAssertEqual(urlOf(items[0])?.absoluteString, "https://apple.example/tab")
    }

    func testFavoriteTopHitShowsFavoriteTitleAsSubtitle() {
        AssetLoader.shared.saveFavoritesOrder([bookmark("f1", "Apple Store", "https://www.apple.com/")])
        let items = build("app")
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.first?.title, "apple.com")
        XCTAssertEqual(items.first?.subtitle, "Apple Store")
        XCTAssertEqual(urlOf(items[0])?.absoluteString, "https://www.apple.com/")
    }

    func testFavoriteTopHitSubtitleIsDomainWhenTitleMatchesDomain() {
        AssetLoader.shared.saveFavoritesOrder([bookmark("f1", "APPLE.COM", "https://www.apple.com/")])
        let items = build("app")
        XCTAssertEqual(items.first?.subtitle, "apple.com")
    }

    func testFavoriteWithMalformedURLIsSkipped() {
        AssetLoader.shared.saveFavoritesOrder([bookmark("f1", "Bad", "http://[bad")])
        let items = build("bad")
        XCTAssertEqual(styles(items), [.googleSuggestion])
    }

    func testRecentGroupTopHitWithEmptyTitleUsesDomainAsSubtitle() {
        let items = build("git", recent: [group("github.com", "https://github.com/repo")])
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.first?.title, "github.com")
        XCTAssertEqual(items.first?.subtitle, "github.com")
    }

    func testRecentGroupTopHitUsesTitleAsSubtitleWhenPresent() {
        let items = build("swift", recent: [group("forums.swift.org", "https://forums.swift.org/", title: "Swift Forums")])
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.first?.subtitle, "Swift Forums")
    }

    func testTypedDomainBecomesTopHitWithGlobeSymbol() {
        let items = build("example.org/path")
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.first?.symbolName, "globe")
        XCTAssertEqual(urlOf(items[0])?.absoluteString, "https://example.org/path")
        XCTAssertEqual(items.first?.title, "example.org")
    }

    func testTypedTextWithSpaceIsNotDomainTopHit() {
        let items = build("my site.com")
        XCTAssertEqual(styles(items), [.googleSuggestion])
    }

    func testTypedTextWithoutDotIsNotDomainTopHit() {
        let items = build("localhost")
        XCTAssertEqual(styles(items), [.googleSuggestion])
    }

    func testUppercaseHTTPSQueryTopHitIsNormalizedAsURL() {
        let items = build("HTTPS://EXAMPLE.COM")
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(urlOf(items.first ?? items[0])?.host?.lowercased(), "example.com")
    
    }

    func testUnicodeTitlePrefixMatchesCaseInsensitively() {
        let items = build("ÜNÏ", tabs: [tab("t1", "Ünïcode Page", "https://unicode.example/")])
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.first?.title, "unicode.example")
    }

    func testEmojiTitlePrefixMatches() {
        let items = build("🍎", tabs: [tab("t1", "🍎 Apple", "https://apple.example/")])
        XCTAssertEqual(items.first?.style, .topHit)
    }

    // MARK: - Query suggestions: switch to tab

    func testSwitchToTabRowsForMatchingInactiveTabs() {
        let items = build("gi", tabs: [
            tab("a", "Git Book", "https://git-scm.com/book", active: true),
            tab("b", "Git Docs", "https://git-scm.com/docs"),
        ])
        let switchRows = items.filter { $0.style == .switchToTab }
        XCTAssertEqual(switchRows.map { tabIDOf($0) }, ["b"])
        XCTAssertEqual(switchRows.first?.subtitle, "git-scm.com • Opened Tab")
    }

    func testSwitchToTabCapsAtThree() {
        let tabs = (1...5).map { tab("t\($0)", "Git \($0)", "https://git\($0).example/") }
        let items = build("git", tabs: tabs)
        let ids = items.filter { $0.style == .switchToTab }.compactMap { tabIDOf($0) }
        XCTAssertEqual(ids, ["t1", "t2", "t3"])
    }

    func testSwitchToTabSkipsStartPages() {
        let items = build("start", tabs: [tab("s", "Start Page", "safarium://start", start: true)])
        XCTAssertFalse(items.contains { $0.style == .switchToTab })
    }

    func testSwitchToTabTitleFallsBackToDomainWhenBlank() {
        let items = build("blank", tabs: [tab("t", "   ", "https://blank.example/x")])
        let row = items.first { $0.style == .switchToTab }
        XCTAssertEqual(row?.title, "blank.example")
    }

    func testSwitchToTabMatchesOnURLText() {
        let items = build("docs", tabs: [tab("t", "Reference", "https://docs.example/")])
        XCTAssertTrue(items.contains { $0.style == .switchToTab && tabIDOf($0) == "t" })
    }

    func testSwitchToTabMatchesOnDomain() {
        let items = build("parser", tabs: [tab("t", "Notes", "https://parser.example/")])
        XCTAssertTrue(items.contains { $0.style == .switchToTab })
    }

    func testSwitchRowsFollowTopHitAndPrecedeSearch() {
        let items = build("gi", tabs: [tab("a", "Git A", "https://a.example/"), tab("b", "Git B", "https://b.example/")])
        XCTAssertEqual(styles(items).first, .topHit)
        XCTAssertEqual(styles(items).last, .googleSuggestion)
    }

    // MARK: - Query suggestions: live Google cache

    func testLiveSuggestionsAppendedAfterTypedQuery() {
        setSearchSuggestions(true)
        controller.googleSuggestCache[engineKey(query: "xy")] = ["xyz", "xyzzy"]
        let items = build("xy")
        let search = items.filter { $0.style == .googleSuggestion }.map(\.title)
        XCTAssertEqual(search, ["xy", "xyz", "xyzzy"])
    }

    func testLiveSuggestionsAreDeduplicatedAndTrimmed() {
        setSearchSuggestions(true)
        controller.googleSuggestCache[engineKey(query: "xy")] = ["xyz", "XYZ", "  ", "XY", "xy   ", "xyzzy", "xyz "]
        let items = build("xy")
        let search = items.filter { $0.style == .googleSuggestion }.map(\.title)
        XCTAssertEqual(search, ["xy", "xyz", "xyzzy"])
    }

    func testLiveSuggestionsCappedAtFive() {
        setSearchSuggestions(true)
        controller.googleSuggestCache[engineKey(query: "q")] = (1...8).map { "q\($0)" }
        let items = build("q")
        let search = items.filter { $0.style == .googleSuggestion }
        XCTAssertEqual(search.count, 6)
        XCTAssertEqual(search.last?.title, "q5")
    }

    func testLiveSuggestionsIgnoredWhenSuggestionsDisabled() {
        setSearchSuggestions(false)
        controller.googleSuggestCache[engineKey(query: "xy")] = ["xyz"]
        let items = build("xy")
        XCTAssertEqual(styles(items), [.googleSuggestion])
    }

    func testLiveSuggestionsIgnoredInPrivateMode() {
        setSearchSuggestions(true)
        controller.googleSuggestCache[engineKey(query: "xy")] = ["xyz"]
        let items = build("xy", isPrivate: true)
        XCTAssertEqual(items.filter { $0.style == .googleSuggestion }.count, 1)
    }

    func testLiveSuggestionCacheMissLeavesOnlyTypedQuery() {
        setSearchSuggestions(true)
        let items = build("nothing-cached")
        XCTAssertEqual(styles(items), [.googleSuggestion])
    }

    func testTypedQueryRowIsFirstSearchRowAndCarriesOriginalCase() {
        let items = build("MixedCase")
        XCTAssertEqual(searchOf(items[0]), "MixedCase")
    }

    // MARK: - Query suggestions: bookmarks and history

    func testFavoriteMatchingTitleAppearsAsBookmarkRow() {
        AssetLoader.shared.saveFavoritesOrder([bookmark("f1", "Zebra Guide", "https://zoo.example/z")])
        let items = build("zebra")
        XCTAssertTrue(items.contains { $0.style == .topHit && $0.title == "zoo.example" })
    }

    func testDuplicateOfTopHitIsNotRepeatedInBookmarks() {
        AssetLoader.shared.saveFavoritesOrder([
            bookmark("f1", "Apple", "https://www.apple.com/"),
            bookmark("f2", "Apple Dev", "https://developer.apple.com/"),
        ])
        let items = build("apple")
        let bookmarkRows = items.filter { $0.style == .bookmarkOrHistory }
        XCTAssertEqual(bookmarkRows.count, 1)
        XCTAssertEqual(urlOf(bookmarkRows[0])?.host, "developer.apple.com")
    }

    func testHistoryTitleAndDomainDuplicateIsSkipped() {
        seedHistory([(title: "Docs", url: "https://a.example/x"), (title: "Docs", url: "https://a.example/y")])
        let items = build("docs")
        XCTAssertEqual(items.filter { $0.style == .bookmarkOrHistory }.count, 1)
    }

    func testBookmarkHistoryRowsCappedAtFour() {
        seedHistory((1...6).map { (title: "News \($0)", url: "https://news\($0).example/") })
        let items = build("news")
        XCTAssertEqual(items.filter { $0.style == .bookmarkOrHistory }.count, 4)
    }

    func testBookmarkHistoryRowUsesDomainWhenTitleBlank() {
        seedHistory([(title: "   ", url: "https://blank.example/page")])
        let items = build("blank")
        let row = items.first { $0.style == .bookmarkOrHistory }
        XCTAssertEqual(row?.title, "blank.example")
        XCTAssertEqual(row?.subtitle, "blank.example")
    }

    func testHistoryMatchesOnURLText() {
        seedHistory([(title: "Unrelated", url: "https://match-by-url.example/")])
        let items = build("match-by-url")
        XCTAssertTrue(items.contains { $0.style == .bookmarkOrHistory })
    }

    func testRecentGroupMatchesBookmarkRowWhenNotTopHit() {
        let recents = [
            group("alpha.example", "https://alpha.example/a", title: "Zed"),
            group("beta.example", "https://beta.example/b", title: "Beta Zed"),
        ]
        let items = build("zed", recent: recents)
        XCTAssertEqual(items.first?.style, .topHit)
        XCTAssertEqual(items.filter { $0.style == .bookmarkOrHistory }.map(\.title), ["Beta Zed"])
    }

    func testBookmarkRowsKeepHistoryOrder() {
        seedHistory([(title: "Gamma news", url: "https://g.example/"), (title: "Beta news", url: "https://b.example/")])
        let items = build("news")
        XCTAssertEqual(items.filter { $0.style == .bookmarkOrHistory }.map(\.title), ["Gamma news", "Beta news"])
    }

    func testPrivateModeHidesHistoryRows() {
        seedHistory([(title: "Secret Journal", url: "https://journal.example/")])
        let items = build("journal", isPrivate: true)
        XCTAssertFalse(items.contains { urlOf($0)?.host == "journal.example" })
    
    }

    func testPrivateModeKeepsBookmarkRows() {
        AssetLoader.shared.saveFavoritesOrder([bookmark("f1", "Private Fav", "https://fav.example/")])
        let items = build("private", isPrivate: true)
        XCTAssertTrue(items.contains { urlOf($0)?.host == "fav.example" })
    }

    func testHistoryTitleMatchAddsSingleRow() {
        AssetLoader.shared.recordHistoryVisit(url: URL(string: "https://ok.example/")!, title: "Broken Candidate")
        let items = build("broken")
        XCTAssertEqual(items.filter { $0.style == .bookmarkOrHistory }.count, 1)
    }

    // MARK: - Suggestion row ordering and totals

    func testRowOrderIsTopHitSwitchSearchThenBookmarks() {
        seedHistory([(title: "Fox News", url: "https://fox.example/")])
        let items = build("fox", tabs: [
            tab("a", "Fox A", "https://a.example/"),
            tab("b", "Fox B", "https://b.example/"),
        ])
        XCTAssertEqual(styles(items), [.topHit, .switchToTab, .switchToTab, .googleSuggestion, .bookmarkOrHistory])
    }

    func testSuggestionsReplacedOnEachBuild() {
        _ = build("one", tabs: [tab("t", "One", "https://one.example/")])
        let second = build("two")
        XCTAssertEqual(styles(second), [.googleSuggestion])
    }

    // MARK: - Relative day labels

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func label(secondsAgo: TimeInterval) -> String {
        Ctl.formatRelativeDay(now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testRelativeDayJustNowForSameMoment() {
        XCTAssertEqual(label(secondsAgo: 0), "Just now")
    }

    func testRelativeDayJustNowJustBelowOneHour() {
        XCTAssertEqual(label(secondsAgo: 3599), "Just now")
    }

    func testRelativeDayTodayAtExactlyOneHour() {
        XCTAssertEqual(label(secondsAgo: 3600), "Today")
    }

    func testRelativeDayTodayJustBelowOneDay() {
        XCTAssertEqual(label(secondsAgo: 86399), "Today")
    }

    func testRelativeDayYesterdayAtExactlyOneDay() {
        XCTAssertEqual(label(secondsAgo: 86400), "Yesterday")
    }

    func testRelativeDayYesterdayJustBelowTwoDays() {
        XCTAssertEqual(label(secondsAgo: 172799), "Yesterday")
    }

    func testRelativeDayTwoDaysAgoAtBoundary() {
        XCTAssertEqual(label(secondsAgo: 172800), "2 days ago")
    }

    func testRelativeDayFractionalDaysFloorDown() {
        XCTAssertEqual(label(secondsAgo: 172800 + 0.5), "2 days ago")
        XCTAssertEqual(label(secondsAgo: 86400 * 2.5), "2 days ago")
    }

    func testRelativeDayManyDays() {
        XCTAssertEqual(label(secondsAgo: 86400 * 3), "3 days ago")
        XCTAssertEqual(label(secondsAgo: 86400 * 30), "30 days ago")
        XCTAssertEqual(label(secondsAgo: 86400 * 365), "365 days ago")
    }

    func testRelativeDayFutureDatesReadAsJustNow() {
        XCTAssertEqual(Ctl.formatRelativeDay(now.addingTimeInterval(100), now: now), "Just now")
        XCTAssertEqual(Ctl.formatRelativeDay(now.addingTimeInterval(86400 * 5), now: now), "Just now")
    }

    func testRelativeDayDefaultsToCurrentTime() {
        XCTAssertEqual(Ctl.formatRelativeDay(Date()), "Just now")
    }

    // MARK: - Google suggestion cache cap

    func testCacheStoresUnderCapacityWithoutClearing() {
        var cache: [String: [String]] = [:]
        for i in 0..<100 {
            Ctl.storeSuggestions(["s\(i)"], forKey: "k\(i)", in: &cache)
        }
        XCTAssertEqual(cache.count, 100)
        XCTAssertEqual(cache["k0"], ["s0"])
        XCTAssertEqual(cache["k99"], ["s99"])
    }

    func testCacheClearsWhenInsertingPastOneHundred() {
        var cache: [String: [String]] = [:]
        for i in 0..<100 {
            Ctl.storeSuggestions(["s\(i)"], forKey: "k\(i)", in: &cache)
        }
        Ctl.storeSuggestions(["fresh"], forKey: "new", in: &cache)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache["new"], ["fresh"])
        XCTAssertNil(cache["k0"])
    }

    func testCacheEmptyStartAcceptsFirstEntry() {
        var cache: [String: [String]] = [:]
        Ctl.storeSuggestions([], forKey: "empty", in: &cache)
        XCTAssertEqual(cache["empty"], [])
        XCTAssertEqual(cache.count, 1)
    }

    func testCacheSecondClearCycleStartsFresh() {
        var cache: [String: [String]] = [:]
        for i in 0..<250 {
            Ctl.storeSuggestions([String(i)], forKey: "k\(i)", in: &cache)
        }
        XCTAssertLessThanOrEqual(cache.count, 100)
        XCTAssertEqual(cache["k249"], ["249"])
    }

    // MARK: - Favorites grid row math

    private func gridWith(count: Int, expanded: Bool = false) -> PopoverFavoritesReorderGridView {
        let grid = PopoverFavoritesReorderGridView(origin: .zero, contentWidth: 446, btnExtraW: 0, isDark: false)
        let entries = (0..<count).map { bookmark("e\($0)", "Site \($0)", "https://site\($0).example/") }
        grid.configure(entries: entries, expanded: expanded)
        return grid
    }

    func testGridHeightClampsToOneRow() {
        XCTAssertEqual(PopoverFavoritesReorderGridView.height(forVisibleRows: 0), 104)
        XCTAssertEqual(PopoverFavoritesReorderGridView.height(forVisibleRows: -2), 104)
        XCTAssertEqual(PopoverFavoritesReorderGridView.height(forVisibleRows: 1), 104)
    }

    func testGridHeightForMultipleRows() {
        XCTAssertEqual(PopoverFavoritesReorderGridView.height(forVisibleRows: 2), 208)
        XCTAssertEqual(PopoverFavoritesReorderGridView.height(forVisibleRows: 5), 520)
    }

    func testGridRowCountBoundaries() {
        let expectations: [(Int, Int)] = [(0, 1), (1, 1), (6, 1), (7, 2), (12, 2), (13, 3)]
        for (count, rows) in expectations {
            XCTAssertEqual(gridWith(count: count).totalRowCount(), rows, "entries \(count)")
        }
    }

    func testGridVisibleRowsCollapseToTwo() {
        XCTAssertEqual(gridWith(count: 13).visibleRowCount(expanded: false), 2)
        XCTAssertEqual(gridWith(count: 13).visibleRowCount(expanded: true), 3)
        XCTAssertEqual(gridWith(count: 3).visibleRowCount(expanded: false), 1)
        XCTAssertEqual(gridWith(count: 0).visibleRowCount(expanded: true), 1)
    }

    func testGridSlotRectsUseSixColumnsAndRowStep() {
        let grid = gridWith(count: 13)
        XCTAssertEqual(grid.slotRect(for: 0), NSRect(x: 0, y: 0, width: 66, height: 102))
        XCTAssertEqual(grid.slotRect(for: 5).origin.x, 5 * 76, accuracy: 0.001)
        XCTAssertEqual(grid.slotRect(for: 5).origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(grid.slotRect(for: 6).origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(grid.slotRect(for: 6).origin.y, 104, accuracy: 0.001)
        XCTAssertEqual(grid.slotRect(for: 12).origin.y, 208, accuracy: 0.001)
    }

    // MARK: - Autocomplete bold-prefix range

    func testBoldPrefixLengthMatchesCaseInsensitively() {
        XCTAssertEqual(PopoverAutocompleteRowView.boldPrefixLength(title: "Apple", query: "app"), 3)
        XCTAssertEqual(PopoverAutocompleteRowView.boldPrefixLength(title: "apple", query: "APP"), 3)
        XCTAssertEqual(PopoverAutocompleteRowView.boldPrefixLength(title: "apple", query: "Apple"), 5)
    }

    func testBoldPrefixNilForEmptyQuery() {
        XCTAssertNil(PopoverAutocompleteRowView.boldPrefixLength(title: "Apple", query: ""))
    }

    func testBoldPrefixNilWhenNotAtStart() {
        XCTAssertNil(PopoverAutocompleteRowView.boldPrefixLength(title: "Apple", query: "pple"))
    }

    func testBoldPrefixNilWhenQueryLongerThanTitle() {
        XCTAssertNil(PopoverAutocompleteRowView.boldPrefixLength(title: "Apple", query: "apples"))
    }

    func testBoldPrefixNilForLeadingWhitespaceInQuery() {
        XCTAssertNil(PopoverAutocompleteRowView.boldPrefixLength(title: "Apple", query: " app"))
    }

    func testBoldPrefixUsesUTF16LengthForSurrogatePairs() {
        XCTAssertEqual(PopoverAutocompleteRowView.boldPrefixLength(title: "😀 smile", query: "😀"), 2)
    }

    func testBoldPrefixWithAccentedQuery() {
        XCTAssertEqual(PopoverAutocompleteRowView.boldPrefixLength(title: "Café au lait", query: "café"), 4)
        XCTAssertEqual(PopoverAutocompleteRowView.boldPrefixLength(title: "CAFÉ", query: "café"), 4)
    }

    // MARK: - Monogram letter

    func testMonogramUsesFirstLetterOfTitle() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "apple", urlString: "https://apple.com"), "A")
    }

    func testMonogramSkipsPunctuationAndSpacesInTitle() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "  !!! zebra", urlString: "https://z.example"), "Z")
    }

    func testMonogramAcceptsDigits() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "1st Page", urlString: "https://x.example"), "1")
    }

    func testMonogramUsesUppercaseForAccentedLetters() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "ñandú", urlString: "https://x.example"), "Ñ")
    }

    func testMonogramUsesCJKLetter() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "日本語", urlString: "https://x.example"), "日")
    }

    func testMonogramSkipsEmojiInTitle() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "😀 smile", urlString: "https://x.example"), "S")
    }

    func testMonogramFallsBackToDomainWhenTitleBlank() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "", urlString: "https://www.github.com/x"), "G")
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "!!!", urlString: "https://www.example.org"), "E")
    }

    func testMonogramFallsBackToWWhenNothingUsable() {
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "", urlString: ""), "W")
    
        XCTAssertEqual(PopoverBrandArtwork.monogramInitial(title: "   ", urlString: "https://---.--"), "W")
    }

    // MARK: - Artwork aspect rects

    func testAspectFillWideImageIntoSquareCropsSides() {
        let r = AddressBarPopoverController.aspectFillRect(for: NSSize(width: 200, height: 100), in: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(r, NSRect(x: -50, y: 0, width: 200, height: 100))
    }

    func testAspectFitWideImageIntoSquareLetterboxes() {
        let r = AddressBarPopoverController.aspectFitRect(for: NSSize(width: 200, height: 100), in: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(r, NSRect(x: 0, y: 25, width: 100, height: 50))
    }

    func testAspectFillTallImageCropsTopAndBottom() {
        let r = AddressBarPopoverController.aspectFillRect(for: NSSize(width: 50, height: 200), in: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(r, NSRect(x: 0, y: -150, width: 100, height: 400))
    }

    func testAspectFitTallImageCentersHorizontally() {
        let r = AddressBarPopoverController.aspectFitRect(for: NSSize(width: 50, height: 200), in: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(r, NSRect(x: 37.5, y: 0, width: 25, height: 100))
    }

    func testAspectRectsRespectRectOrigin() {
        let r = AddressBarPopoverController.aspectFitRect(for: NSSize(width: 100, height: 50), in: NSRect(x: 10, y: 20, width: 50, height: 50))
        XCTAssertEqual(r, NSRect(x: 10, y: 32.5, width: 50, height: 25))
    }

    func testAspectFillSmallImageScalesUp() {
        let r = AddressBarPopoverController.aspectFillRect(for: NSSize(width: 100, height: 50), in: NSRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(r, NSRect(x: -150, y: 0, width: 600, height: 300))
    }

    func testAspectRectsNilForEmptyOrNegativeSize() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(AddressBarPopoverController.aspectFillRect(for: .zero, in: rect))
        XCTAssertNil(AddressBarPopoverController.aspectFitRect(for: NSSize(width: 0, height: 10), in: rect))
        XCTAssertNil(AddressBarPopoverController.aspectFillRect(for: NSSize(width: -4, height: 10), in: rect))
    }

    func testAspectSquareImageFillsExactly() {
        let rect = NSRect(x: 5, y: 5, width: 90, height: 90)
        XCTAssertEqual(AddressBarPopoverController.aspectFillRect(for: NSSize(width: 30, height: 30), in: rect), rect)
        XCTAssertEqual(AddressBarPopoverController.aspectFitRect(for: NSSize(width: 30, height: 30), in: rect), rect)
    }
}
