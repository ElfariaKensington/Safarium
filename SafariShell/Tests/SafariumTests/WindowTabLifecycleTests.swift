import XCTest
import AppKit
@testable import Safarium

/// Tab create / select / close / reopen / cycle / shortcut / pin / context / reorder / transfer behaviour of
/// `SafariWindowController`, driven headlessly through `T8SpyEngine` (never ordered on screen).
@MainActor
final class WindowTabLifecycleTests: T8WindowTestCase {

    private func spyTabs(_ wc: SafariWindowController) -> [T8SpyTab] {
        t8Tabs(wc).compactMap { $0 as? T8SpyTab }
    }

    /// Runs the real private context-menu toggle action for `tab` (no UI is shown).
    private func pinViaContextMenu(_ wc: SafariWindowController, _ tab: BrowserTabEngine) {
        wc.contextMenuTabID = tab.tabID
        _ = wc.perform(NSSelectorFromString("tabCtxTogglePin"))
    }

    private func runCtx(_ wc: SafariWindowController, _ tab: BrowserTabEngine, _ action: String) {
        wc.contextMenuTabID = tab.tabID
        _ = wc.perform(NSSelectorFromString(action))
    }

    // MARK: - Creation

    func testFreshControllerHasNoTabsAndNoActiveState() {
        let (wc, _) = makeWindow()
        XCTAssertEqual(wc.openTabCount, 0)
        XCTAssertNil(wc.activeWebPageURLString)
        XCTAssertNil(wc.activeHostDisplayName)
        XCTAssertFalse(wc.isActiveTabMuted)
        XCTAssertFalse(wc.hasRecentlyClosedTabs)
    }

    func testFirstCreatedTabBecomesActive() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://a.example.com/"))
        XCTAssertEqual(wc.openTabCount, 1)
        XCTAssertEqual(t8ActiveIndex(wc), 0)
        XCTAssertEqual(wc.activeWebPageURLString, "https://a.example.com/")
    }

    func testDefaultActivateMakesNewestTabActive() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        XCTAssertEqual(t8ActiveIndex(wc), 2)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t2.example.com/")
    }

    func testCreateWithoutActivateKeepsCurrentSelection() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://first.example.com/"))
        _ = wc.createNewTab(url: url("https://second.example.com/"), activate: false)
        XCTAssertEqual(wc.openTabCount, 2)
        XCTAssertEqual(t8ActiveIndex(wc), 0)
        XCTAssertEqual(wc.activeWebPageURLString, "https://first.example.com/")
    }

    func testEngineReceivesOneTabPerCreateWithPrivateFlag() {
        let (wc, eng) = makeWindow(isPrivate: true)
        _ = openTabs(wc, count: 4)
        XCTAssertEqual(eng.created.count, 4)
        XCTAssertEqual(eng.privateFlags, [true, true, true, true])
    }

    func testNonPrivateWindowPassesPrivateFalseToEngine() {
        let (wc, eng) = makeWindow(isPrivate: false)
        _ = openTabs(wc, count: 2)
        XCTAssertEqual(eng.privateFlags, [false, false])
    }

    func testNilURLTabHasNoCurrentURLAndNoActiveWebString() {
        let (wc, eng) = makeWindow()
        _ = wc.createNewTab(url: nil)
        XCTAssertEqual(wc.openTabCount, 1)
        XCTAssertNil(eng.created.last?.currentURL)
        XCTAssertNil(wc.activeWebPageURLString)
    }

    func testControllerBecomesDelegateOfEveryCreatedTab() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        for tab in tabs {
            XCTAssertTrue((tab.delegate as AnyObject?) === wc)
        }
    }

    func testOpenTabCountTracksCreatesAndCloses() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 5)
        wc.closeTab(at: 0)
        wc.closeTab(at: 0)
        XCTAssertEqual(wc.openTabCount, 3)
    }

    // MARK: - Selection

    func testSelectTabMakesIndexActive() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        wc.selectTab(at: 1)
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t1.example.com/")
    }

    func testSelectTabOutOfRangeIsIgnored() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        wc.selectTab(at: -1)
        wc.selectTab(at: 3)
        wc.selectTab(at: 99)
        XCTAssertEqual(t8ActiveIndex(wc), 2)
    }

    func testSelectTabOnEmptyStripIsNoop() {
        let (wc, _) = makeWindow()
        wc.selectTab(at: 0)
        XCTAssertEqual(wc.openTabCount, 0)
        XCTAssertNil(wc.activeWebPageURLString)
    }

    func testSelectingSameTabTwiceIsIdempotent() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2)
        wc.selectTab(at: 1)
        wc.selectTab(at: 1)
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertEqual(wc.openTabCount, 2)
    }

    // MARK: - Close

    func testClosingActiveMiddleTabSelectsTheTabThatTakesItsSlot() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: false)
        wc.selectTab(at: 1)
        wc.closeTab(at: 1)
        XCTAssertEqual(wc.openTabCount, 2)
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t2.example.com/")
    }

    func testClosingActiveLastTabSelectsPreviousTab() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        wc.closeTab(at: 2)
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t1.example.com/")
    }

    func testClosingInactiveTabBeforeActiveShiftsActiveIndex() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        wc.closeTab(at: 0)
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t2.example.com/")
    }

    func testClosingInactiveTabAfterActiveKeepsActiveIndex() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3)
        wc.closeTab(at: 2)
        XCTAssertEqual(t8ActiveIndex(wc), 0)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/")
    }

    func testCloseOutOfRangeIsNoop() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3)
        wc.closeTab(at: -1)
        wc.closeTab(at: 3)
        wc.closeTab(at: 500)
        XCTAssertEqual(wc.openTabCount, 3)
    }

    func testClosingOnlyTabEmptiesStripAndTearsDownEngineTab() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 1)
        wc.closeActiveTab()
        XCTAssertEqual(wc.openTabCount, 0)
        XCTAssertEqual(eng.created.first?.closed, true)
    }

    func testClosedTabIsTornDownAndOthersAreNot() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 3)
        wc.closeTab(at: 1)
        XCTAssertEqual(eng.created.map(\.closed), [false, true, false])
    }

    func testCloseActiveTabConvenienceRemovesActiveTab() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2, activateLast: true)
        wc.closeActiveTab()
        XCTAssertEqual(wc.openTabCount, 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/")
    }

    func testHTTPAndHTTPSCloseIsRecorded() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("http://plain.example.com/"))
        _ = wc.createNewTab(url: url("https://secure.example.com/"))
        wc.closeTab(at: 0)
        wc.closeTab(at: 0)
        XCTAssertEqual(t8ClosedURLs(wc), [url("http://plain.example.com/"), url("https://secure.example.com/")])
    }

    func testStartPageCloseIsNotRecorded() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("safarium://start"))
        _ = wc.createNewTab(url: url("https://keep.example.com/"))
        wc.closeTab(at: 0)
        XCTAssertFalse(wc.hasRecentlyClosedTabs)
    }

    func testFileURLCloseIsNotRecorded() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("file:///tmp/t8-local.html"))
        _ = wc.createNewTab(url: url("https://keep.example.com/"))
        wc.closeTab(at: 0)
        XCTAssertTrue(t8ClosedURLs(wc).isEmpty)
    }

    func testChromeAndViewSourceCloseIsNotRecorded() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("chrome://settings"))
        _ = wc.createNewTab(url: url("view-source:https://a.example.com/"))
        _ = wc.createNewTab(url: url("https://keep.example.com/"))
        wc.closeTab(at: 0)
        wc.closeTab(at: 0)
        XCTAssertTrue(t8ClosedURLs(wc).isEmpty)
    }

    func testTabWithoutURLCloseIsNotRecorded() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: nil)
        _ = wc.createNewTab(url: url("https://keep.example.com/"))
        wc.closeTab(at: 0)
        XCTAssertTrue(t8ClosedURLs(wc).isEmpty)
    }

    // MARK: - Reopen

    func testReopenLastClosedTabIsLIFO() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 4)
        wc.closeTab(at: 0)   // t0
        wc.closeTab(at: 0)   // t1
        wc.reopenLastClosedTab()
        XCTAssertEqual(wc.activeWebPageURLString, "https://t1.example.com/")
        wc.reopenLastClosedTab()
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/")
        XCTAssertFalse(wc.hasRecentlyClosedTabs)
    }

    func testReopenOnEmptyStackIsNoop() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 1)
        wc.reopenLastClosedTab()
        XCTAssertEqual(wc.openTabCount, 1)
    }

    func testReopenAddsTabAndActivatesIt() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2)
        wc.closeTab(at: 0)
        wc.reopenLastClosedTab()
        XCTAssertEqual(wc.openTabCount, 2)
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/")
    }

    func testReopenClosedTabAtReversedIndexPicksByRecency() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 4)
        wc.closeTab(at: 0)   // t0 (oldest)
        wc.closeTab(at: 0)   // t1
        wc.closeTab(at: 0)   // t2 (newest)
        wc.reopenClosedTab(atReversedIndex: 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t1.example.com/")
        XCTAssertEqual(t8ClosedURLs(wc), [url("https://t0.example.com/"), url("https://t2.example.com/")])
    }

    func testReopenClosedTabAtOutOfRangeReversedIndexIsNoop() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2)
        wc.closeTab(at: 0)
        wc.reopenClosedTab(atReversedIndex: 1)
        wc.reopenClosedTab(atReversedIndex: -1)
        wc.reopenClosedTab(atReversedIndex: 100)
        XCTAssertEqual(wc.openTabCount, 1)
        XCTAssertTrue(wc.hasRecentlyClosedTabs)
    }

    func testRecentClosedMenuIsNewestFirst() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 4)
        wc.closeTab(at: 0); wc.closeTab(at: 0); wc.closeTab(at: 0)
        XCTAssertEqual(wc.recentClosedURLsForMenu, [url("https://t2.example.com/"), url("https://t1.example.com/"), url("https://t0.example.com/")])
    }

    func testRecentClosedMenuCappedAtTenNewest() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 16)
        for _ in 0..<15 { wc.closeTab(at: 0) }
        let menu = wc.recentClosedURLsForMenu
        XCTAssertEqual(menu.count, 10)
        XCTAssertEqual(menu.first, url("https://t14.example.com/"))
        XCTAssertEqual(menu.last, url("https://t5.example.com/"))
    }

    func testClosedStackCapsAtFiftyAndDropsOldest() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 61)
        for _ in 0..<60 { wc.closeTab(at: 0) }
        XCTAssertEqual(t8ClosedURLs(wc).count, 50)
        XCTAssertEqual(t8ClosedURLs(wc).first, url("https://t10.example.com/"))
        XCTAssertEqual(t8ClosedURLs(wc).last, url("https://t59.example.com/"))
    }

    func testFullyReopenedStackHoldsExactlyFiftyTabs() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 61)
        for _ in 0..<60 { wc.closeTab(at: 0) }
        var reopened = 0
        while wc.hasRecentlyClosedTabs {
            wc.reopenLastClosedTab()
            reopened += 1
            if reopened > 100 { break }
        }
        XCTAssertEqual(reopened, 50)
    }

    // MARK: - Shortcuts and cycling

    func testSelectTabShortcutSelectsTagIndex() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 5)
        wc.selectTabShortcut(tag: 2)
        XCTAssertEqual(t8ActiveIndex(wc), 2)
        wc.selectTabShortcut(tag: 0)
        XCTAssertEqual(t8ActiveIndex(wc), 0)
    }

    func testSelectTabShortcutEightSelectsLastTab() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3)
        wc.selectTabShortcut(tag: 8)
        XCTAssertEqual(t8ActiveIndex(wc), 2)
    }

    func testSelectTabShortcutMissingTagsAreIgnored() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        wc.selectTabShortcut(tag: 3)
        wc.selectTabShortcut(tag: 7)
        wc.selectTabShortcut(tag: -1)
        wc.selectTabShortcut(tag: 1000)
        XCTAssertEqual(t8ActiveIndex(wc), 2)
    }

    func testSelectTabShortcutOnEmptyStripIsNoop() {
        let (wc, _) = makeWindow()
        wc.selectTabShortcut(tag: 8)
        wc.selectTabShortcut(tag: 0)
        XCTAssertEqual(wc.openTabCount, 0)
    }

    func testCycleNextAdvancesAndWraps() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3)
        wc.cycleNextTab()
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        wc.cycleNextTab()
        wc.cycleNextTab()
        XCTAssertEqual(t8ActiveIndex(wc), 0, "cycling forward past the last tab wraps to the first")
    }

    func testCyclePreviousRetreatsAndWraps() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3)
        wc.cyclePreviousTab()
        XCTAssertEqual(t8ActiveIndex(wc), 2, "cycling back from the first tab wraps to the last")
        wc.cyclePreviousTab()
        XCTAssertEqual(t8ActiveIndex(wc), 1)
    }

    func testCycleWithSingleOrNoTabsIsNoop() {
        let (wc, _) = makeWindow()
        wc.cycleNextTab()
        wc.cyclePreviousTab()
        _ = openTabs(wc, count: 1)
        wc.cycleNextTab()
        wc.cyclePreviousTab()
        XCTAssertEqual(t8ActiveIndex(wc), 0)
        XCTAssertEqual(wc.openTabCount, 1)
    }

    // MARK: - Pin / unpin

    func testPinMovesTabToLeadingEdgeAndKeepsActiveTab() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        pinViaContextMenu(wc, tabs[2])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[2].tabID, tabs[0].tabID, tabs[1].tabID])
        XCTAssertTrue(t8PinnedIDs(wc).contains(tabs[2].tabID))
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/", "active tab identity survives the move")
    }

    func testPinningActiveTabFollowsItToFront() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3, activateLast: true)
        pinViaContextMenu(wc, tabs[2])
        XCTAssertEqual(t8ActiveIndex(wc), 0)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t2.example.com/")
    }

    func testPinningTabAfterActiveShiftsNothingWhenAlreadyLeading() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        pinViaContextMenu(wc, tabs[0])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID, tabs[2].tabID])
        XCTAssertEqual(t8ActiveIndex(wc), 0)
    }

    func testPinningTabWhileActiveIsLaterAdjustsActiveIndex() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3, activateLast: true)   // active = t2
        pinViaContextMenu(wc, tabs[1])                          // t1 moves to front, t2 stays active
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[1].tabID, tabs[0].tabID, tabs[2].tabID])
        XCTAssertEqual(wc.activeWebPageURLString, "https://t2.example.com/")
        XCTAssertEqual(t8ActiveIndex(wc), 2)
    }

    func testUnpinPlacesTabAfterRemainingPinnedGroup() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        pinViaContextMenu(wc, tabs[0])
        pinViaContextMenu(wc, tabs[1])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID, tabs[2].tabID])
        pinViaContextMenu(wc, tabs[0]) // unpin t0 -> it lands right after the one still pinned (t1)
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[1].tabID, tabs[0].tabID, tabs[2].tabID])
        XCTAssertEqual(t8PinnedIDs(wc), [tabs[1].tabID])
    }

    func testUnpinLastPinnedTabKeepsOrder() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        pinViaContextMenu(wc, tabs[0])
        pinViaContextMenu(wc, tabs[0])
        XCTAssertTrue(t8PinnedIDs(wc).isEmpty)
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID, tabs[2].tabID])
    }

    func testUnpinActiveTabKeepsItActive() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        pinViaContextMenu(wc, tabs[0])
        pinViaContextMenu(wc, tabs[1])
        wc.selectTab(at: 0)                       // t0 is active and pinned at the front
        pinViaContextMenu(wc, tabs[0])            // unpin the active tab
        XCTAssertFalse(t8PinnedIDs(wc).contains(tabs[0].tabID))
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/")
        XCTAssertEqual(t8Tabs(wc)[t8ActiveIndex(wc)].tabID, tabs[0].tabID)
    }

    func testPinningEveryTabAddsStartPageOnTheRight() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        pinViaContextMenu(wc, tabs[0])
        XCTAssertEqual(wc.openTabCount, 2)
        pinViaContextMenu(wc, tabs[1])
        XCTAssertEqual(wc.openTabCount, 3)
        XCTAssertTrue(t8Tabs(wc).last?.isStartPage ?? false)
    }

    func testPinOnUnknownContextIDIsNoop() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2)
        wc.contextMenuTabID = "missing"
        _ = wc.perform(NSSelectorFromString("tabCtxTogglePin"))
        XCTAssertTrue(t8PinnedIDs(wc).isEmpty)
        XCTAssertEqual(wc.openTabCount, 2)
    }

    // MARK: - Context menu bulk actions

    func testCloseOtherTabsKeepsContextTabAndPinnedTabs() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 4)
        pinViaContextMenu(wc, tabs[2]) // strip: [t2, t0, t1, t3]
        runCtx(wc, tabs[1], "tabCtxCloseOtherTabs")
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[2].tabID, tabs[1].tabID])
    }

    func testCloseTabsToLeftSkipsPinnedTabs() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 4)
        pinViaContextMenu(wc, tabs[0])
        runCtx(wc, tabs[3], "tabCtxCloseTabsToLeft")
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[3].tabID])
    }

    func testCloseTabsToRightSkipsPinnedTabs() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 4)
        pinViaContextMenu(wc, tabs[0])
        pinViaContextMenu(wc, tabs[1])
        runCtx(wc, tabs[1], "tabCtxCloseTabsToRight")
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID])
    }

    func testCloseTabsToLeftOfFirstTabIsNoop() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        runCtx(wc, tabs[0], "tabCtxCloseTabsToLeft")
        XCTAssertEqual(wc.openTabCount, 2)
    }

    func testDuplicateTabOpensSameURLAndActivatesCopy() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        runCtx(wc, tabs[0], "tabCtxDuplicateTab")
        XCTAssertEqual(wc.openTabCount, 3)
        XCTAssertEqual(t8ActiveIndex(wc), 2)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/")
    }

    func testCloseTabContextActionRemovesContextTab() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        runCtx(wc, tabs[1], "tabCtxCloseTab")
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID])
    }

    func testArrangeByTitleSortsCaseInsensitivelyWithPinnedFirst() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 4)
        let spies = spyTabs(wc)
        spies[0].title = "beta"
        spies[1].title = "Alpha"
        spies[2].title = "gamma"
        spies[3].title = "zeta"
        pinViaContextMenu(wc, spies[3])
        _ = wc.perform(NSSelectorFromString("tabCtxArrangeByTitle"))
        XCTAssertEqual(spyTabs(wc).map(\.title), ["zeta", "Alpha", "beta", "gamma"])
    }

    func testArrangeByTitleKeepsActiveTabIdentity() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        let spies = spyTabs(wc)
        spies[0].title = "c"; spies[1].title = "a"; spies[2].title = "b"
        _ = wc.perform(NSSelectorFromString("tabCtxArrangeByTitle"))
        XCTAssertEqual(wc.activeWebPageURLString, "https://t2.example.com/")
        XCTAssertEqual(t8ActiveIndex(wc), 1, "sorted order is a, b, c so the active b-tab moves to index 1")
    }

    func testArrangeByWebsiteSortsByHost() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://b.example.com/"))
        _ = wc.createNewTab(url: url("https://a.example.com/"))
        _ = wc.createNewTab(url: url("https://c.example.com/"))
        _ = wc.perform(NSSelectorFromString("tabCtxArrangeByWebsite"))
        XCTAssertEqual(spyTabs(wc).compactMap { $0.currentURL?.host }, ["a.example.com", "b.example.com", "c.example.com"])
    }

    func testArrangeByWebsiteFallsBackToTitleWithoutHost() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://m.example.com/"))
        _ = wc.createNewTab(url: nil)
        let spies = spyTabs(wc)
        spies[1].title = "Apple"
        _ = wc.perform(NSSelectorFromString("tabCtxArrangeByWebsite"))
        XCTAssertEqual(spyTabs(wc).map(\.title), ["Apple", ""])
    }

    // MARK: - Reorder

    func testReorderTabsAppliesValidPermutation() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        wc.reorderTabs(matchingOrder: [tabs[2].tabID, tabs[0].tabID, tabs[1].tabID])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[2].tabID, tabs[0].tabID, tabs[1].tabID])
    }

    func testReorderTabsPreservesActiveTabIdentity() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        wc.reorderTabs(matchingOrder: [tabs[2].tabID, tabs[1].tabID, tabs[0].tabID])
        XCTAssertEqual(t8ActiveIndex(wc), 2)
        XCTAssertEqual(wc.activeWebPageURLString, "https://t0.example.com/")
    }

    func testReorderWithWrongCountIsIgnored() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        wc.reorderTabs(matchingOrder: [tabs[1].tabID])
        wc.reorderTabs(matchingOrder: [tabs[1].tabID, tabs[0].tabID, tabs[0].tabID])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID])
    }

    func testReorderWithUnknownIDIsIgnored() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        wc.reorderTabs(matchingOrder: [tabs[1].tabID, "not-a-tab"])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID])
    }

    func testReorderEmptyOrderIsIgnored() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        wc.reorderTabs(matchingOrder: [])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID])
    }

    func testReorderWithDuplicateIDMustNotDropATab() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        wc.reorderTabs(matchingOrder: [tabs[0].tabID, tabs[0].tabID])
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID])
    
    }

    // MARK: - Same-window drop and cross-window transfer

    func testCommitSameWindowDropMovesTabToInsertionIndex() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        wc.commitSameWindowTabDrop(tabID: tabs[0].tabID, insertionIndex: 3)
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[1].tabID, tabs[2].tabID, tabs[0].tabID])
        XCTAssertEqual(t8ActiveIndex(wc), 2)
    }

    func testCommitSameWindowDropClampsNegativeIndexToZero() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        wc.commitSameWindowTabDrop(tabID: tabs[2].tabID, insertionIndex: -5)
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[2].tabID, tabs[0].tabID, tabs[1].tabID])
        XCTAssertEqual(t8ActiveIndex(wc), 0)
    }

    func testCommitSameWindowDropWithUnknownIDLeavesStripAlone() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        wc.commitSameWindowTabDrop(tabID: "ghost", insertionIndex: 0)
        XCTAssertEqual(t8Tabs(wc).map(\.tabID), [tabs[0].tabID, tabs[1].tabID])
    }

    func testDetachReturnsTransferAndRemovesTabFromSource() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 3)
        let transfer = wc.detachTabForTransfer(tabID: tabs[1].tabID)
        XCTAssertNotNil(transfer)
        XCTAssertTrue(transfer?.tab === tabs[1])
        XCTAssertEqual(wc.openTabCount, 2)
        XCTAssertNil(tabs[1].delegate, "a detached tab must stop reporting to its old window")
    }

    func testDetachUnknownTabReturnsNil() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2)
        XCTAssertNil(wc.detachTabForTransfer(tabID: "nope"))
        XCTAssertEqual(wc.openTabCount, 2)
    }

    func testDetachingLastTabEmptiesSourceWindow() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 1)
        let transfer = wc.detachTabForTransfer(tabID: tabs[0].tabID)
        XCTAssertNotNil(transfer)
        XCTAssertEqual(wc.openTabCount, 0)
    }

    func testAcceptTransferredTabInsertsAndActivatesInDestination() {
        let (source, _) = makeWindow()
        let (dest, _) = makeWindow()
        let moving = openTabs(source, count: 2)
        _ = openTabs(dest, count: 1)
        guard let transfer = source.detachTabForTransfer(tabID: moving[0].tabID) else {
            return XCTFail("detach failed")
        }
        dest.acceptTransferredTab(transfer, atIndex: 0, activate: true)
        XCTAssertEqual(dest.openTabCount, 2)
        XCTAssertEqual(t8ActiveIndex(dest), 0)
        XCTAssertEqual(dest.activeWebPageURLString, "https://t0.example.com/")
        XCTAssertTrue((moving[0].delegate as AnyObject?) === dest, "accepted tab reports to the new window")
        XCTAssertEqual(source.openTabCount, 1)
    }

    func testAcceptWithoutActivateKeepsDestinationSelection() {
        let (source, _) = makeWindow()
        let (dest, _) = makeWindow()
        let moving = openTabs(source, count: 2)
        _ = openTabs(dest, count: 2)
        dest.selectTab(at: 1)
        guard let transfer = source.detachTabForTransfer(tabID: moving[1].tabID) else {
            return XCTFail("detach failed")
        }
        let keptActive = t8Tabs(dest)[1].tabID
        dest.acceptTransferredTab(transfer, atIndex: 0, activate: false)
        XCTAssertEqual(dest.openTabCount, 3)
        XCTAssertEqual(t8Tabs(dest)[t8ActiveIndex(dest)].tabID, keptActive)
    
    }

    func testAcceptClampsOversizedInsertionIndexToEnd() {
        let (source, _) = makeWindow()
        let (dest, _) = makeWindow()
        let moving = openTabs(source, count: 2)
        _ = openTabs(dest, count: 2)
        guard let transfer = source.detachTabForTransfer(tabID: moving[1].tabID) else {
            return XCTFail("detach failed")
        }
        dest.acceptTransferredTab(transfer, atIndex: 999, activate: true)
        XCTAssertEqual(t8Tabs(dest).last?.tabID, moving[1].tabID)
        XCTAssertEqual(t8ActiveIndex(dest), 2)
    }

    func testTransferredTabKeepsIdentityAcrossWindows() {
        let (source, _) = makeWindow()
        let (dest, _) = makeWindow()
        let moving = openTabs(source, count: 1)
        let id = moving[0].tabID
        guard let transfer = source.detachTabForTransfer(tabID: id) else {
            return XCTFail("detach failed")
        }
        dest.acceptTransferredTab(transfer, atIndex: 0, activate: true)
        XCTAssertEqual(t8Tabs(dest).map(\.tabID), [id])
    }

    // MARK: - Mute, sidebar, overview state

    func testToggleMuteActiveTabFlipsAudioState() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 1)
        wc.toggleMuteActiveTab()
        XCTAssertTrue(wc.isActiveTabMuted)
        wc.toggleMuteActiveTab()
        XCTAssertFalse(wc.isActiveTabMuted)
    }

    func testToggleMuteSkipsStartPage() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("safarium://start"))
        wc.toggleMuteActiveTab()
        XCTAssertFalse(wc.isActiveTabMuted)
    }

    func testMuteOtherTabsLeavesActiveAndStartPagesAudible() {
        let (wc, _) = makeWindow()
        let tabs = openTabs(wc, count: 2)
        _ = wc.createNewTab(url: url("safarium://start"), activate: false)
        wc.muteOtherTabs()
        let spies = spyTabs(wc)
        XCTAssertFalse(spies[0].isAudioMuted, "active tab stays audible")
        XCTAssertTrue(spies[1].isAudioMuted)
        XCTAssertFalse(spies[2].isAudioMuted, "start page is never muted")
        XCTAssertEqual(tabs.count, 2)
    }

    func testSidebarStateFlipsOnToggle() {
        let (wc, _) = makeWindow()
        XCTAssertFalse(wc.isSidebarCurrentlyOpen)
        wc.toggleSidebar()
        XCTAssertTrue(wc.isSidebarCurrentlyOpen)
        wc.toggleSidebar()
        XCTAssertFalse(wc.isSidebarCurrentlyOpen)
    }

    func testShowTabsSidebarOpensAndStaysOpen() {
        let (wc, _) = makeWindow()
        wc.showTabsSidebar()
        XCTAssertTrue(wc.isSidebarCurrentlyOpen)
        wc.showTabsSidebar()
        XCTAssertTrue(wc.isSidebarCurrentlyOpen, "show never toggles closed")
    }

    func testTabOverviewStartsClosed() {
        let (wc, _) = makeWindow()
        XCTAssertFalse(wc.isTabOverviewCurrentlyOpen)
    }

    // MARK: - Summaries and display helpers

    func testOpenWebsitesSummaryDedupesAndStripsWWW() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://www.apple.com/"))
        _ = wc.createNewTab(url: url("https://apple.com/store"))
        _ = wc.createNewTab(url: url("https://github.com/"))
        _ = wc.createNewTab(url: url("safarium://start"))
        _ = wc.createNewTab(url: url("file:///tmp/local.html"))
        _ = wc.createNewTab(url: url("https://Docs.Example.com/"))
        XCTAssertEqual(wc.openWebsitesSummary().map(\.host), ["apple.com", "github.com", "docs.example.com"])
    }

    func testOpenWebsitesSummaryEmptyWithoutWebTabs() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("safarium://start"))
        _ = wc.createNewTab(url: nil)
        XCTAssertTrue(wc.openWebsitesSummary().isEmpty)
    }

    func testOpenWebsitesSummaryCarriesFaviconOfFirstTab() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: url("https://one.example.com/"))
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        (tab as? T8SpyTab)?.favicon = icon
        let summary = wc.openWebsitesSummary()
        XCTAssertEqual(summary.count, 1)
        XCTAssertTrue(summary.first?.favicon === icon)
    }

    func testActiveWebPageURLStringIsNilForNonWebTabs() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("file:///tmp/a.html"))
        XCTAssertNil(wc.activeWebPageURLString)
        _ = wc.createNewTab(url: url("safarium://start"))
        XCTAssertNil(wc.activeWebPageURLString)
        _ = wc.createNewTab(url: url("https://ok.example.com/p?q=1"))
        XCTAssertEqual(wc.activeWebPageURLString, "https://ok.example.com/p?q=1")
    }

    func testActiveHostDisplayNameStripsWWWAndLowercases() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://www.Example.org/a"))
        XCTAssertEqual(wc.activeHostDisplayName, "example.org")
    }

    func testActiveHostDisplayNameNilOnStartPage() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("safarium://start"))
        XCTAssertNil(wc.activeHostDisplayName)
    }

    func testActiveHostDisplayNameNilWithoutHost() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("mailto:someone@example.com"))
        XCTAssertNil(wc.activeHostDisplayName)
    }

    func testSelectingDifferentTabsUpdatesHostDisplayName() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://first.example.net/"))
        _ = wc.createNewTab(url: url("https://second.example.net/"))
        XCTAssertEqual(wc.activeHostDisplayName, "second.example.net")
        wc.selectTab(at: 0)
        XCTAssertEqual(wc.activeHostDisplayName, "first.example.net")
    }
}
