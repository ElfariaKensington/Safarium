import XCTest
import AppKit
@testable import Safarium

@MainActor
final class SafariSidebarViewTests: HermeticTestCase {
    private static let favoritesOrderKey = "Safarium.FavoritesOrderURLs.v1"
    private static let customFavoritesKey = "Safarium.CustomFavoritesEntries.v1"

    private var sidebar: SafariSidebarView!
    private var window: NSWindow!
    private var originalFavorites: [AssetLoader.BookmarkEntry] = []

    private let fixtureFavorites: [AssetLoader.BookmarkEntry] = [
        AssetLoader.BookmarkEntry(id: "t4-f1", title: "GitHub", url: "https://github.com/", color: nil),
        AssetLoader.BookmarkEntry(id: "t4-f2", title: "Apple", url: "https://www.apple.com/", color: nil),
        AssetLoader.BookmarkEntry(id: "t4-f3", title: "Café Menu", url: "https://cafe.example/menu", color: nil)
    ]

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.makeFixture() }
    }

    override func tearDown() {
        MainActor.assumeIsolated { self.dropFixture() }
        super.tearDown()
    }

    private func makeFixture() {
        _ = NSApplication.shared
        originalFavorites = AssetLoader.shared.favorites()
        AssetLoader.shared.saveFavoritesOrder(fixtureFavorites)
        sidebar = SafariSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 700))
        window = TabUIHost.window(containing: sidebar, size: NSSize(width: 280, height: 700))
        sidebar.apply(theme: .defaultLight, animated: false)
    }

    private func dropFixture() {
        window.close()
        sidebar = nil
        window = nil
        AssetLoader.shared.saveFavoritesOrder(originalFavorites)
        UserDefaults.standard.removeObject(forKey: Self.favoritesOrderKey)
        UserDefaults.standard.removeObject(forKey: Self.customFavoritesKey)
    }

    // MARK: - helpers

    private func tab(_ id: String, title: String? = nil, url: String? = "https://example.com/",
                     active: Bool = false, favicon: NSImage? = nil) -> TabPresentationItem {
        TabPresentationItem(id: id, title: title ?? "Title \(id)", url: url.flatMap { URL(string: $0) },
                            favicon: favicon, isLoading: false, progress: 0, isActive: active)
    }

    private func rowIdentity() -> [ObjectIdentifier] {
        sidebar.contentStack.arrangedSubviews.map { ObjectIdentifier($0) }
    }

    private func renderedTexts() -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let f = v as? NSTextField { out.append(f.stringValue) }
            v.subviews.forEach(walk)
        }
        sidebar.contentStack.arrangedSubviews.forEach(walk)
        return out
    }

    private func bookmarkRowCount() -> Int {
        sidebar.bookmarksListStack?.arrangedSubviews.count ?? -1
    }

    private func searchField(_ text: String) -> NSSearchField {
        let f = NSSearchField()
        f.stringValue = text
        return f
    }

    // MARK: - initial state

    func testInitialModeIsTabsWithNothingRendered() {
        XCTAssertEqual(String(describing: sidebar.mode), "tabs")
        XCTAssertTrue(sidebar.tabItems.isEmpty)
        XCTAssertEqual(sidebar.lastRenderedTabsSig, "")
        XCTAssertFalse(sidebar.needsDeferredRebuild)
    }

    // MARK: - update(tabs:) rendering and invalidation

    func testUpdateTabsStoresItemsAndRecordsSignature() {
        sidebar.update(tabs: [tab("t1", active: true)])
        XCTAssertEqual(sidebar.tabItems.map(\.id), ["t1"])
        XCTAssertEqual(sidebar.lastRenderedTabsSig, "2:t1|1|8:Title t1|20:https://example.com/|0")
        XCTAssertFalse(sidebar.needsDeferredRebuild)
    }

    func testUpdateWithUnchangedTabsSkipsRebuild() {
        sidebar.update(tabs: [tab("t1", active: true)])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", active: true)])
        XCTAssertEqual(rowIdentity(), before, "identical metadata must not rebuild rows")
    }

    func testTitleChangeRebuildsRows() {
        sidebar.update(tabs: [tab("t1", title: "Old", active: true)])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", title: "New", active: true)])
        XCTAssertNotEqual(rowIdentity(), before)
        XCTAssertTrue(sidebar.lastRenderedTabsSig.contains(":New|"))
    }

    func testActiveFlagChangeRebuildsRows() {
        sidebar.update(tabs: [tab("t1", active: true), tab("t2")])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1"), tab("t2", active: true)])
        XCTAssertNotEqual(rowIdentity(), before)
    }

    func testURLChangeRebuildsRows() {
        sidebar.update(tabs: [tab("t1", url: "https://a.example/", active: true)])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", url: "https://b.example/", active: true)])
        XCTAssertNotEqual(rowIdentity(), before)
    }

    func testAddingTabRebuildsRows() {
        sidebar.update(tabs: [tab("t1", active: true)])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", active: true), tab("t2")])
        XCTAssertNotEqual(rowIdentity(), before)
        XCTAssertEqual(sidebar.tabItems.count, 2)
    }

    func testSameFaviconObjectDoesNotRebuild() {
        let fav = TabUIHost.solidImage(width: 8, height: 8)
        sidebar.update(tabs: [tab("t1", active: true, favicon: fav)])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", active: true, favicon: fav)])
        XCTAssertEqual(rowIdentity(), before)
    }

    func testReplacedFaviconObjectRebuildsRows() {
        // Regression for audit P05-4: a replaced favicon image for the same tab must invalidate the row.
        sidebar.update(tabs: [tab("t1", active: true, favicon: TabUIHost.solidImage(width: 8, height: 8))])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", active: true, favicon: TabUIHost.solidImage(width: 8, height: 8))])
        XCTAssertNotEqual(rowIdentity(), before)
    }

    func testNilToPresentFaviconRebuildsRows() {
        sidebar.update(tabs: [tab("t1", active: true)])
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", active: true, favicon: TabUIHost.solidImage(width: 4, height: 4))])
        XCTAssertNotEqual(rowIdentity(), before)
    }

    func testEmptyTabListRendersWithoutCrashing() {
        sidebar.update(tabs: [tab("t1", active: true)])
        sidebar.update(tabs: [])
        XCTAssertTrue(sidebar.tabItems.isEmpty)
        XCTAssertEqual(sidebar.lastRenderedTabsSig, "")
    }

    func testSignatureCollisionIsDocumentedAsBug() {
        // Two different tab lists whose "|"-joined signatures are identical. The second update is
        // skipped, so the sidebar keeps showing stale rows.
        let a = tab("x", title: "y|false|z", url: nil, active: false)
        let b = tab("x|false|y", title: "z", url: nil, active: false)
        sidebar.update(tabs: [a])
        let before = rowIdentity()
        sidebar.update(tabs: [b])
        XCTAssertNotEqual(self.rowIdentity(), before)
    
    }

    // MARK: - hidden sidebar deferral

    func testHiddenSidebarDefersChangedTabsUntilFlushed() {
        sidebar.update(tabs: [tab("t1", active: true)])
        sidebar.isHidden = true
        let before = rowIdentity()
        sidebar.update(tabs: [tab("t1", title: "Changed", active: true)])
        XCTAssertTrue(sidebar.needsDeferredRebuild)
        XCTAssertEqual(rowIdentity(), before, "hidden sidebar must not rebuild")

        sidebar.isHidden = false
        sidebar.flushPendingRebuildIfNeeded()
        XCTAssertFalse(sidebar.needsDeferredRebuild)
        XCTAssertNotEqual(rowIdentity(), before)
        XCTAssertTrue(sidebar.lastRenderedTabsSig.contains(":Changed|"))
    }

    func testHiddenSidebarWithUnchangedTabsDoesNotDefer() {
        sidebar.update(tabs: [tab("t1", active: true)])
        sidebar.isHidden = true
        sidebar.update(tabs: [tab("t1", active: true)])
        XCTAssertFalse(sidebar.needsDeferredRebuild)
    }

    func testFlushWithoutPendingChangeIsNoOp() {
        sidebar.update(tabs: [tab("t1", active: true)])
        let before = rowIdentity()
        sidebar.flushPendingRebuildIfNeeded()
        XCTAssertEqual(rowIdentity(), before)
        XCTAssertFalse(sidebar.needsDeferredRebuild)
    }

    func testShowTabsSectionFlushesDeferredRebuildWhenAlreadyInTabs() {
        sidebar.update(tabs: [tab("t1", active: true)])
        sidebar.isHidden = true
        sidebar.update(tabs: [tab("t1", title: "Deferred", active: true)])
        sidebar.isHidden = false
        sidebar.showTabsSection()
        XCTAssertFalse(sidebar.needsDeferredRebuild)
        XCTAssertTrue(sidebar.lastRenderedTabsSig.contains(":Deferred|"))
    }

    // MARK: - modes and search state

    func testUpdateInBookmarksModeOnlyStoresItems() {
        sidebar.showBookmarksSection()
        sidebar.update(tabs: [tab("t9", active: true)])
        XCTAssertEqual(String(describing: sidebar.mode), "bookmarks")
        XCTAssertEqual(sidebar.tabItems.map(\.id), ["t9"])
        XCTAssertEqual(sidebar.lastRenderedTabsSig, "")
    }

    func testShowTabsSectionRendersItemsStoredWhileAway() {
        sidebar.update(tabs: [tab("t1", active: true)])
        let before = rowIdentity()
        sidebar.showBookmarksSection()
        sidebar.update(tabs: [tab("t9", active: true)])
        sidebar.showTabsSection()
        XCTAssertEqual(String(describing: sidebar.mode), "tabs")
        XCTAssertNotEqual(rowIdentity(), before)
        XCTAssertEqual(sidebar.tabItems.map(\.id), ["t9"])
    }

    func testTabsAfterLeavingBookmarksShowCurrentTabList() {
        // Regression lock for the stale-signature path: after returning from bookmarks the rows must
        // reflect the latest tab list, even when the list matches the one rendered before the detour.
        sidebar.update(tabs: [tab("t1", active: true)])
        sidebar.showBookmarksSection()
        sidebar.update(tabs: [tab("t2", active: true)])
        sidebar.showTabsSection()
        sidebar.update(tabs: [tab("t1", active: true)])
        XCTAssertTrue(self.renderedTexts().contains("Title t1"), "rows: \(self.renderedTexts())")
        XCTAssertFalse(self.renderedTexts().contains("Title t2"), "rows: \(self.renderedTexts())")
    
    }

    func testShowBookmarksSectionTwiceDoesNotRebuild() {
        sidebar.showBookmarksSection()
        let before = rowIdentity()
        sidebar.showBookmarksSection()
        XCTAssertEqual(rowIdentity(), before)
        XCTAssertEqual(String(describing: sidebar.mode), "bookmarks")
    }

    func testShowReadingListSectionChangesMode() {
        sidebar.showReadingListSection()
        XCTAssertEqual(String(describing: sidebar.mode), "readingList")
    }

    func testLeavingBookmarksForTabsClearsSearchQuery() {
        sidebar.showBookmarksSection()
        sidebar.bookmarkSearchQuery = "git"
        sidebar.showTabsSection()
        XCTAssertEqual(sidebar.bookmarkSearchQuery, "")
    }

    func testSwitchingBetweenBookmarkAndReadingListKeepsQuery() {
        sidebar.showBookmarksSection()
        sidebar.bookmarkSearchQuery = "git"
        sidebar.showReadingListSection()
        XCTAssertEqual(sidebar.bookmarkSearchQuery, "git")
    }

    // MARK: - bookmark list filtering

    func testEmptyQueryShowsAllFavorites() {
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 3)
    }

    func testQueryMatchesTitleCaseInsensitively() {
        sidebar.bookmarkSearchQuery = "GITHUB"
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 1)
    }

    func testQueryMatchesURLSubstring() {
        sidebar.bookmarkSearchQuery = "apple.com"
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 1)
    }

    func testQueryIsTrimmedBeforeMatching() {
        sidebar.bookmarkSearchQuery = "   github \n"
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 1)
    }

    func testWhitespaceOnlyQueryShowsEverything() {
        sidebar.bookmarkSearchQuery = "   "
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 3)
    }

    func testQueryWithNoMatchShowsNoRows() {
        sidebar.bookmarkSearchQuery = "zzz-no-such-bookmark"
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 0)
    }

    func testAccentedTitleMatchesUppercaseAccentedQuery() {
        sidebar.bookmarkSearchQuery = "CAFÉ"
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 1)
    }

    func testSearchFieldChangeNotificationFiltersRows() {
        sidebar.showBookmarksSection()
        let field = searchField("apple")
        sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(sidebar.bookmarkSearchQuery, "apple")
        XCTAssertEqual(bookmarkRowCount(), 1)
    }

    func testNotificationFromNonSearchFieldIsIgnored() {
        sidebar.showBookmarksSection()
        let plain = NSTextField(string: "apple")
        sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: plain))
        XCTAssertEqual(sidebar.bookmarkSearchQuery, "")
        XCTAssertEqual(bookmarkRowCount(), 3)
    }

    func testEmptyFavoritesStoreShowsNoRows() {
        AssetLoader.shared.saveFavoritesOrder([])
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 0)
    }

    func testFavoritesChangeNotificationRebuildsBookmarksList() {
        sidebar.showBookmarksSection()
        XCTAssertEqual(bookmarkRowCount(), 3)
        AssetLoader.shared.saveFavoritesOrder([fixtureFavorites[0]])
        XCTAssertEqual(bookmarkRowCount(), 1)
    }
}
