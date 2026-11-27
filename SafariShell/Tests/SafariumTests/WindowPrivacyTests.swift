import XCTest
import AppKit
@testable import Safarium

/// Private-window isolation, session persistence (saved tabs + active index), history recording with
/// title updates, and favicon caching rules of `SafariWindowController`.
@MainActor
final class WindowPrivacyTests: T8WindowTestCase {

    private let savedTabsKey = "Safarium.Session.SavedTabs.v1"
    private let savedIndexKey = "Safarium.Session.ActiveIndex.v1"
    private var historyURLs: Set<String> = []

    override func setUp() {
        super.setUp()
        PrivacyReportStore.shared.clearAll()
        PrivacyReportStore.shared.flushSync()
    }

    override func tearDown() {
        AssetLoader.shared.removeHistoryEntries(urls: historyURLs)
        historyURLs.removeAll()
        PrivacyReportStore.shared.clearAll()
        PrivacyReportStore.shared.flushSync()
        super.tearDown()
    }

    /// Unique host per test so process-wide caches (history, favicons) never leak between cases.
    private func uniqueURL(_ path: String = "/") -> URL {
        let u = URL(string: "https://t8-\(UUID().uuidString.prefix(8).lowercased()).example.test\(path)")!
        historyURLs.insert(u.absoluteString)
        return u
    }

    private func savedTabs() -> [String]? {
        UserDefaults.standard.stringArray(forKey: savedTabsKey)
    }

    private func savedIndex() -> Int {
        UserDefaults.standard.integer(forKey: savedIndexKey)
    }

    private func seedSentinelSession() {
        UserDefaults.standard.set(["sentinel://keep"], forKey: savedTabsKey)
        UserDefaults.standard.set(7, forKey: savedIndexKey)
    }

    private func assertSentinelUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(savedTabs(), ["sentinel://keep"], file: file, line: line)
        XCTAssertEqual(savedIndex(), 7, file: file, line: line)
    }

    // MARK: - Private windows: closed-tab memory

    func testPrivateWindowRecordsNoClosedURLsForWebTabs() {
        let (wc, _) = makeWindow(isPrivate: true)
        _ = openTabs(wc, count: 4)
        wc.closeTab(at: 0)
        wc.closeTab(at: 0)
        XCTAssertTrue(t8ClosedURLs(wc).isEmpty)
        XCTAssertFalse(wc.hasRecentlyClosedTabs)
        XCTAssertTrue(wc.recentClosedURLsForMenu.isEmpty)
    }

    func testPrivateWindowReopenIsNoop() {
        let (wc, _) = makeWindow(isPrivate: true)
        _ = openTabs(wc, count: 2)
        wc.closeTab(at: 0)
        wc.reopenLastClosedTab()
        XCTAssertEqual(wc.openTabCount, 1)
    }

    func testNormalWindowStillRecordsClosedURLsAsControl() {
        let (wc, _) = makeWindow(isPrivate: false)
        _ = openTabs(wc, count: 2)
        wc.closeTab(at: 0)
        XCTAssertTrue(wc.hasRecentlyClosedTabs)
    }

    // MARK: - Private windows: identity and chrome

    func testPrivateWindowTitleMarksPrivate() {
        let (wc, _) = makeWindow(isPrivate: true)
        XCTAssertEqual(wc.window?.title, "Safarium — Private")
        XCTAssertTrue(wc.isPrivate)
    }

    func testNormalWindowTitleIsPlain() {
        let (wc, _) = makeWindow(isPrivate: false)
        XCTAssertEqual(wc.window?.title, "Safarium")
        XCTAssertFalse(wc.isPrivate)
    }

    func testPrivateWindowEngineReceivesPrivateFlagForEveryTab() {
        let (wc, eng) = makeWindow(isPrivate: true)
        _ = wc.createNewTab(url: nil)
        _ = wc.createNewTab(url: url("https://p.example.com/"))
        XCTAssertEqual(eng.privateFlags, [true, true])
    }

    // MARK: - Session persistence

    func testPersistWritesWebTabsInOrderWithActiveIndex() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        wc.persistCurrentSession()
        XCTAssertEqual(savedTabs(), ["https://t0.example.com/", "https://t1.example.com/", "https://t2.example.com/"])
        XCTAssertEqual(savedIndex(), 2)
    }

    func testPersistStoresStartPageAsStartURL() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://a.example.com/"))
        _ = wc.createNewTab(url: url("safarium://start"))
        wc.persistCurrentSession()
        XCTAssertEqual(savedTabs(), ["https://a.example.com/", "safarium://start"])
        XCTAssertEqual(savedIndex(), 1)
    }

    func testPersistSkipsFileChromeAndViewSourceTabs() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://a.example.com/"))
        _ = wc.createNewTab(url: url("file:///tmp/t8-local.html"))
        _ = wc.createNewTab(url: url("chrome://settings"))
        _ = wc.createNewTab(url: url("https://b.example.com/"))
        wc.persistCurrentSession()
        XCTAssertEqual(savedTabs(), ["https://a.example.com/", "https://b.example.com/"])
    }

    func testPersistEmptyStripWritesEmptySession() {
        let (wc, _) = makeWindow()
        wc.persistCurrentSession()
        XCTAssertEqual(savedTabs(), [])
        XCTAssertEqual(savedIndex(), 0)
    }

    func testPersistedSessionRoundTripsThroughBrowserSettings() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2, activateLast: true)
        wc.persistCurrentSession()
        let restored = BrowserSettings.shared.savedSession()
        XCTAssertEqual(restored.urls, [url("https://t0.example.com/"), url("https://t1.example.com/")])
        XCTAssertEqual(restored.activeIndex, 1)
    }

    func testPersistWhenActiveTabIsFileFallsBackToValidIndex() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://a.example.com/"), activate: false)
        _ = wc.createNewTab(url: url("file:///tmp/t8-active.html"))
        _ = wc.createNewTab(url: url("https://b.example.com/"), activate: false)
        wc.persistCurrentSession()
        let saved = savedTabs() ?? []
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue((0..<saved.count).contains(savedIndex()), "active index must stay inside the saved list")
    }

    func testPersistActiveIndexStaysOnActiveTabWhenLocalTabsPrecedeIt() {
        let (wc, _) = makeWindow()
        _ = wc.createNewTab(url: url("https://a.example.com/"), activate: false)
        _ = wc.createNewTab(url: url("file:///tmp/t8-one.html"), activate: false)
        _ = wc.createNewTab(url: url("https://b.example.com/"), activate: true)
        _ = wc.createNewTab(url: url("https://c.example.com/"), activate: false)
        wc.persistCurrentSession()
        XCTAssertEqual(savedTabs(), ["https://a.example.com/", "https://b.example.com/", "https://c.example.com/"])
        XCTAssertEqual(savedIndex(), 1, "B is active; its index in the saved list is 1")
    
    }

    func testPersistNeverWritesWhenPrivate() {
        seedSentinelSession()
        let (wc, _) = makeWindow(isPrivate: true)
        _ = openTabs(wc, count: 3, activateLast: true)
        wc.persistCurrentSession()
        assertSentinelUntouched()
    }

    func testClosingPrivateWindowDoesNotOverwriteSession() {
        seedSentinelSession()
        let (wc, _) = makeWindow(isPrivate: true)
        _ = openTabs(wc, count: 2, activateLast: true)
        wc.window?.close()
        assertSentinelUntouched()
    }

    func testClosingNormalWindowWritesSession() {
        seedSentinelSession()
        let (wc, _) = makeWindow(isPrivate: false)
        _ = openTabs(wc, count: 2, activateLast: true)
        wc.window?.close()
        XCTAssertEqual(savedTabs(), ["https://t0.example.com/", "https://t1.example.com/"])
        XCTAssertEqual(savedIndex(), 1)
    }

    func testClosingWindowTearsDownEveryEngineTab() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 3)
        wc.window?.close()
        XCTAssertEqual(eng.created.map(\.closed), [true, true, true])
        XCTAssertEqual(wc.openTabCount, 0)
    }

    func testSaveSessionDropsEmptyURLsAndRemapsActiveIndex() {
        BrowserSettings.shared.saveSession(urls: ["", "https://a.example.com/", "", "https://b.example.com/"], activeIndex: 3)
        XCTAssertEqual(savedTabs(), ["https://a.example.com/", "https://b.example.com/"])
        XCTAssertEqual(savedIndex(), 1)
    }

    func testSaveSessionClampsOutOfRangeActiveIndex() {
        BrowserSettings.shared.saveSession(urls: ["https://a.example.com/"], activeIndex: 50)
        XCTAssertEqual(savedIndex(), 0)
        BrowserSettings.shared.saveSession(urls: ["https://a.example.com/"], activeIndex: -4)
        XCTAssertEqual(savedIndex(), 0)
    }

    func testSavedSessionRemapsIndexPastDroppedMalformedURLs() {
        UserDefaults.standard.set(["https://ok.example.com/", "http://[bad", "https://z.example.com/"], forKey: savedTabsKey)
        UserDefaults.standard.set(2, forKey: savedIndexKey)
        let restored = BrowserSettings.shared.savedSession()
        XCTAssertEqual(restored.urls, [url("https://ok.example.com/"), url("https://z.example.com/")])
        XCTAssertEqual(restored.activeIndex, 1)
    }

    func testSavedSessionWithNothingStoredIsEmptyAtZero() {
        let restored = BrowserSettings.shared.savedSession()
        XCTAssertTrue(restored.urls.isEmpty)
        XCTAssertEqual(restored.activeIndex, 0)
    }

    // MARK: - History recording and titles

    func testNavigationInNormalWindowRecordsHistory() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/news")
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didChangeURL: u)
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == u.absoluteString }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.visitCount, 1)
    }

    func testNavigationInPrivateWindowRecordsNoHistory() {
        let (wc, _) = makeWindow(isPrivate: true)
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/secret")
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didChangeURL: u)
        XCTAssertFalse(AssetLoader.shared.browsingHistory().contains { $0.url == u.absoluteString })
    }

    func testFileNavigationIsNotRecordedInHistory() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: nil)
        let u = URL(string: "file:///tmp/t8-history-\(UUID().uuidString).html")!
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didChangeURL: u)
        XCTAssertFalse(AssetLoader.shared.browsingHistory().contains { $0.url == u.absoluteString })
    }

    func testPageTitleUpdatesStoredHistoryTitle() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/titled")
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didChangeURL: u)
        wc.tabEngine(tab, didChangeTitle: "  Real Page Title  ")
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == u.absoluteString }
        XCTAssertEqual(entry?.title, "Real Page Title")
    }

    func testAboutBlankTitleDoesNotOverwriteHistoryTitle() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/blank")
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didChangeURL: u)
        wc.tabEngine(tab, didChangeTitle: "Stable Title")
        wc.tabEngine(tab, didChangeTitle: "about:blank")
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == u.absoluteString }
        XCTAssertEqual(entry?.title, "Stable Title")
    }

    func testWhitespaceOnlyTitleDoesNotOverwriteHistoryTitle() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/ws")
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didChangeURL: u)
        wc.tabEngine(tab, didChangeTitle: "Kept")
        wc.tabEngine(tab, didChangeTitle: "   ")
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == u.absoluteString }
        XCTAssertEqual(entry?.title, "Kept")
    }

    func testPrivateTitleChangeDoesNotTouchHistory() {
        let (wc, _) = makeWindow(isPrivate: true)
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/private-title")
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didChangeTitle: "Private Title")
        XCTAssertFalse(AssetLoader.shared.browsingHistory().contains { $0.url == u.absoluteString })
    }

    func testHistoryTitleUpdateRegressionViaAssetLoader() {
        let u = uniqueURL("/direct")
        AssetLoader.shared.recordHistoryVisit(url: u, title: "Old")
        AssetLoader.shared.updateHistoryTitle(url: u, title: "New Title")
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == u.absoluteString }
        XCTAssertEqual(entry?.title, "New Title")
        XCTAssertEqual(entry?.visitCount, 1, "a title update is not a visit")
    }

    func testRepeatVisitIncrementsVisitCount() {
        let u = uniqueURL("/repeat")
        AssetLoader.shared.recordHistoryVisit(url: u, title: "R")
        AssetLoader.shared.recordHistoryVisit(url: u, title: "R")
        AssetLoader.shared.recordHistoryVisit(url: u, title: "R")
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == u.absoluteString }
        XCTAssertEqual(entry?.visitCount, 3)
    }

    func testVisitCountSaturatesAtIntMax() {
        let u = uniqueURL("/saturate")
        _ = AssetLoader.shared.mergeImportedHistory([
            AssetLoader.HistoryEntry(title: "S", url: u.absoluteString, visitCount: Int.max, lastVisited: Date())
        ])
        AssetLoader.shared.recordHistoryVisit(url: u, title: "S")
        let entry = AssetLoader.shared.browsingHistory().first { $0.url == u.absoluteString }
        XCTAssertEqual(entry?.visitCount, Int.max)
    }

    func testHistoryIgnoresNonWebSchemesOnRecord() {
        AssetLoader.shared.recordHistoryVisit(url: URL(string: "safarium://history")!, title: "H")
        XCTAssertFalse(AssetLoader.shared.browsingHistory().contains { $0.url == "safarium://history" })
    }

    // MARK: - Favicons

    func testFaviconFromNormalWindowIsCachedForItsURL() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/icon")
        (tab as? T8SpyTab)?.loadURL(u)
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        wc.tabEngine(tab, didUpdateFavicon: icon)
        XCTAssertNotNil(FaviconCache.shared.cachedImage(forURLString: u.absoluteString))
    }

    func testFaviconFromPrivateWindowIsNeverStoredInSharedCache() {
        let (wc, _) = makeWindow(isPrivate: true)
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/private-icon")
        (tab as? T8SpyTab)?.loadURL(u)
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        wc.tabEngine(tab, didUpdateFavicon: icon)
        XCTAssertNil(FaviconCache.shared.cachedImage(forURLString: u.absoluteString), "private favicons must not reach FaviconCache.shared")
    }

    func testNilFaviconIsNotStored() {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: nil)
        let u = uniqueURL("/nil-icon")
        (tab as? T8SpyTab)?.loadURL(u)
        wc.tabEngine(tab, didUpdateFavicon: nil)
        XCTAssertNil(FaviconCache.shared.cachedImage(forURLString: u.absoluteString))
    }

    // MARK: - Lifetime

    func testPrivateWindowControllerIsReleasedAfterClose() {
        weak var weakWC: SafariWindowController?
        autoreleasepool {
            let (wc, _) = makeWindow(isPrivate: true)
            weakWC = wc
            _ = openTabs(wc, count: 3, activateLast: true)
            wc.toggleSidebar()
            wc.window?.close()
        }
        made.removeAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(weakWC, "private SafariWindowController leaked after window close")
    }

    // MARK: - Privacy Report & Per-Tab Isolation

    func testPrivateWindowPrivacyEventsStayEphemeralAndNeverPersistToStoreSummary() {
        let (wc, _) = makeWindow(isPrivate: true)
        let tab = wc.createNewTab(url: uniqueURL("/private-trackers"))
        let event = PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: "secret.example.test",
            trackerHost: "pixel.tracker.test",
            entityDomain: "tracker.test",
            ownerName: "Tracker Inc",
            category: .advertising,
            count: 2,
            isPrivate: false // window.isPrivate must enforce isolation even if caller omits isPrivate
        )
        wc.tabEngine(tab, didRecordPrivacyEvent: event)
        wc.tabEngine(tab, didUpdateConnectionSecurity: .upgradedHTTPS, host: "secret.example.test")
        PrivacyReportStore.shared.flushSync()

        let snap = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)
        XCTAssertNotNil(snap)
        XCTAssertTrue(snap?.isPrivate == true)
        XCTAssertEqual(snap?.totalTrackersBlocked, 2)
        XCTAssertEqual(snap?.securityState, .upgradedHTTPS)

        let summary = PrivacyReportStore.shared.summary(days: 30)
        XCTAssertEqual(summary.uniqueTrackersPrevented, 0)
        XCTAssertEqual(summary.totalBlockedRequests, 0)
        XCTAssertEqual(summary.totalWebsitesVisited, 0)
    }

    func testNormalWindowPrivacyEventsRecordIntoStoreAndUpdateTabSnapshot() {
        let (wc, _) = makeWindow(isPrivate: false)
        let pageURL = uniqueURL("/article")
        let tab = wc.createNewTab(url: pageURL)
        wc.tabEngine(tab, didChangeURL: pageURL)
        let event = PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: pageURL.host ?? "",
            trackerHost: "ad.doubleclick.net",
            entityDomain: "google.com",
            ownerName: "Google",
            category: .advertising,
            count: 3,
            isPrivate: false
        )
        wc.tabEngine(tab, didRecordPrivacyEvent: event)
        PrivacyReportStore.shared.flushSync()

        let snap = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)
        XCTAssertEqual(snap?.totalTrackersBlocked, 3)
        XCTAssertEqual(snap?.uniqueTrackerEntitiesCount, 1)

        let summary = PrivacyReportStore.shared.summary(days: 30)
        XCTAssertEqual(summary.uniqueTrackersPrevented, 1)
        XCTAssertEqual(summary.totalBlockedRequests, 3)
        XCTAssertEqual(summary.mostContactedTracker?.entityDomain, "google.com")
    }

    func testClosingTabRemovesItsPrivacySnapshotFromStore() {
        let (wc, _) = makeWindow(isPrivate: false)
        let first = wc.createNewTab(url: uniqueURL("/one"))
        let second = wc.createNewTab(url: uniqueURL("/two"))
        XCTAssertNotNil(PrivacyReportStore.shared.tabSnapshot(forTabID: first.tabID))
        XCTAssertNotNil(PrivacyReportStore.shared.tabSnapshot(forTabID: second.tabID))

        wc.closeTab(at: 0)
        XCTAssertNil(PrivacyReportStore.shared.tabSnapshot(forTabID: first.tabID))
        XCTAssertNotNil(PrivacyReportStore.shared.tabSnapshot(forTabID: second.tabID))
    }

    func testCrossHostSecurityUpdateResetsOldTrackersAndPreservesEarlyIncomingEvents() {
        let (wc, _) = makeWindow(isPrivate: false)
        let urlA = uniqueURL("/site-a")
        let hostA = PrivacyDomainClassifier.sanitizeHostForStorage(urlA.host ?? "")
        let tab = wc.createNewTab(url: urlA)
        wc.tabEngine(tab, didChangeURL: urlA)
        wc.tabEngine(tab, didRecordPrivacyEvent: PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: hostA,
            trackerHost: "ad.doubleclick.net",
            entityDomain: "google.com",
            ownerName: "Google",
            category: .advertising,
            count: 4
        ))
        XCTAssertEqual(PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)?.totalTrackersBlocked, 4)

        let urlB = uniqueURL("/site-b")
        let hostB = PrivacyDomainClassifier.sanitizeHostForStorage(urlB.host ?? "")
        wc.tabEngine(tab, didRecordPrivacyEvent: PrivacyEvent(
            eventType: .httpsUpgraded,
            pageHost: hostB,
            trackerHost: hostB,
            entityDomain: hostB,
            category: .httpsUpgrade,
            count: 1
        ))
        wc.tabEngine(tab, didUpdateConnectionSecurity: .upgradedHTTPS, host: hostB)
        (tab as? T8SpyTab)?.loadURL(urlB)
        wc.tabEngine(tab, didChangeURL: urlB)

        let snapB = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)
        XCTAssertEqual(snapB?.host, hostB)
        XCTAssertEqual(snapB?.totalTrackersBlocked, 0)
        XCTAssertEqual(snapB?.httpsUpgraded, true)
        XCTAssertEqual(snapB?.securityState, .upgradedHTTPS)
    }

    func testReloadAndPauseClearStaleTrackersAndRespectTooltipPrecedence() {
        let (wc, _) = makeWindow(isPrivate: false)
        let pageURL = uniqueURL("/reload-test")
        let host = PrivacyDomainClassifier.sanitizeHostForStorage(pageURL.host ?? "")
        let tab = wc.createNewTab(url: pageURL)
        wc.tabEngine(tab, didChangeURL: pageURL)
        wc.tabEngine(tab, didRecordPrivacyEvent: PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: host,
            trackerHost: "pixel.tracker.test",
            entityDomain: "tracker.test",
            ownerName: "Tracker",
            category: .advertising,
            count: 2
        ))
        XCTAssertEqual(PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)?.totalTrackersBlocked, 2)

        wc.reloadActiveTab()
        XCTAssertEqual(PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)?.totalTrackersBlocked, 0)

        wc.tabEngine(tab, didRecordPrivacyEvent: PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: host,
            trackerHost: "pixel.tracker.test",
            entityDomain: "tracker.test",
            ownerName: "Tracker",
            category: .advertising,
            count: 3
        ))
        PrivacyReportStore.shared.updateProtectionsEnabled(false, forTabID: tab.tabID, isPrivate: false)
        wc.tabEngine(tab, didUpdateConnectionSecurity: .secureHTTPS, host: host)

        let shieldCapsule = t8Mirror(wc, "$__lazy_storage_$_privacyShieldCapsule") as? GlassActionCapsule
        let tooltip = shieldCapsule?.button(for: "privacyShield")?.toolTip ?? ""
        XCTAssertTrue(tooltip.contains("Protections paused"), "paused tooltip must take precedence over tracker count, got: \(tooltip)")
    }

    func testGlobalPreventTrackingOffDisablesEffectiveProtectionsAndDimsShield() {
        let saved = UserDefaults.standard.object(forKey: BrowserSettings.Key.preventTracking)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: BrowserSettings.Key.preventTracking)
            } else {
                UserDefaults.standard.removeObject(forKey: BrowserSettings.Key.preventTracking)
            }
        }
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.preventTracking)
        let (wc, _) = makeWindow(isPrivate: false)
        let pageURL = uniqueURL("/global-off")
        let tab = wc.createNewTab(url: pageURL)
        wc.tabEngine(tab, didChangeURL: pageURL)

        let snap = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)
        XCTAssertEqual(snap?.protectionsEnabled, false)
        let shieldCapsule = t8Mirror(wc, "$__lazy_storage_$_privacyShieldCapsule") as? GlassActionCapsule
        XCTAssertTrue((shieldCapsule?.button(for: "privacyShield")?.toolTip ?? "").contains("Protections"))
    }

    func testStaleHTTPConnectionStateDoesNotFlashOntoNewHTTPSHost() {
        let (wc, _) = makeWindow(isPrivate: false)
        let httpURL = URL(string: "http://old-\(UUID().uuidString.prefix(6).lowercased()).example.test/")!
        let tab = wc.createNewTab(url: httpURL)
        wc.tabEngine(tab, didUpdateConnectionSecurity: .insecureHTTP, host: httpURL.host ?? "")

        let httpsURL = uniqueURL("/new-https")
        (tab as? T8SpyTab)?.loadURL(httpsURL)
        wc.tabEngine(tab, didChangeURL: httpsURL)

        let snap = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)
        XCTAssertEqual(snap?.securityState, .secureHTTPS)
    }

    func testRightCustomizablePrivacyReportButtonKeepsTintOverrideAcrossThemeUpdates() {
        let savedRight = ToolbarCustomizationStore.shared.rightActionOrder
        defer {
            ToolbarCustomizationStore.shared.resetToDefaults()
            for item in savedRight {
                ToolbarCustomizationStore.shared.placeAction(item, on: .right)
            }
        }
        ToolbarCustomizationStore.shared.placeAction(.privacyReport, on: .right, at: 0)
        let (wc, _) = makeWindow(isPrivate: false)
        let httpsURL = uniqueURL("/tint-test")
        let tab = wc.createNewTab(url: httpsURL)
        wc.tabEngine(tab, didUpdateConnectionSecurity: .secureHTTPS, host: httpsURL.host ?? "")
        // Trigger toolbar state refresh to verify override survives GlassActionCapsule.updateAppearance().
        wc.tabEngine(tab, didChangeTitle: "Updated Title")

        let rightCapsule = t8Mirror(wc, "$__lazy_storage_$_rightActionCapsule") as? GlassActionCapsule
        let btn = rightCapsule?.button(for: "privacyReport")
        let rgb = btn?.contentTintColor?.usingColorSpace(.sRGB)
        XCTAssertNotNil(rgb)
        XCTAssertEqual(rgb?.greenComponent ?? 0, 0.78, accuracy: 0.05)
    }
}
