import XCTest
import AppKit
@testable import Safarium

/// Start Page: recents from history, private-mode isolation, section visibility, favorites grid geometry,
/// wallpaper backdrop state and top-strip color sampling, and scroll helpers.
@MainActor
final class StartPageViewTests: HermeticTestCase {
    private let prefKeys = [
        "Safarium.StartPage.bgEnabled",
        "Safarium.StartPage.wallpaperID",
        "Safarium.StartPage.customWallpaperPath",
        "Safarium.StartPage.showFavorites",
        "Safarium.StartPage.showRecent",
        "Safarium.StartPage.showPrivacy",
    ]
    private var savedFavorites: [AssetLoader.BookmarkEntry] = []
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.setUpIsolated() }
    }

    private func setUpIsolated() {
        _ = NSApplication.shared
        savedFavorites = AssetLoader.shared.favorites()
        AssetLoader.shared.saveFavoritesOrder([])
        AssetLoader.shared.clearHistory()
        prefKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        MainActor.assumeIsolated { self.tearDownIsolated() }
        super.tearDown()
    }

    private func tearDownIsolated() {
        window?.close()
        window = nil
        prefKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        AssetLoader.shared.saveFavoritesOrder(savedFavorites)
        UserDefaults.standard.removeObject(forKey: "Safarium.FavoritesOrderURLs.v1")
        UserDefaults.standard.removeObject(forKey: "Safarium.CustomFavoritesEntries.v1")
        AssetLoader.shared.clearHistory()
    }

    // MARK: helpers

    private func makeView() -> StartPageView {
        StartPageView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var out: [T] = []
        for v in root.subviews {
            if let t = v as? T { out.append(t) }
            out.append(contentsOf: descendants(type, in: v))
        }
        return out
    }

    private func grid(in view: StartPageView) -> FavoritesReorderGridView {
        descendants(FavoritesReorderGridView.self, in: view).first!
    }

    private func wallpaperView(in view: StartPageView) -> NSView? {
        descendants(NSView.self, in: view).first { String(describing: type(of: $0)) == "StartPageWallpaperView" }
    }

    private func scrollView(in view: StartPageView) -> NSScrollView? {
        descendants(NSScrollView.self, in: view).first
    }

    private func seedHistory(_ entries: [(title: String, url: String)]) {
        for e in entries.reversed() {
            AssetLoader.shared.recordHistoryVisit(url: URL(string: e.url)!, title: e.title, visitedAt: Date())
        }
    }

    private func seedFavorites(_ count: Int) {
        let list = (0..<count).map {
            AssetLoader.BookmarkEntry(id: "f\($0)", title: "Site \($0)", url: "https://site\($0).example/", color: nil)
        }
        AssetLoader.shared.saveFavoritesOrder(list)
    }

    private func writeSolidPNG(named name: String, color: NSColor, size: Int) -> String {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for x in 0..<size {
            for y in 0..<size {
                rep.setColor(color, atX: x, y: y)
            }
        }
        let data = rep.representation(using: .png, properties: [:])!
        let url = Self.sandboxRoot.appendingPathComponent(name)
        try? data.write(to: url)
        return url.path
    }

    private func assertColor(_ c: NSColor?, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, accuracy: CGFloat = 0.02, file: StaticString = #filePath, line: UInt = #line) {
        guard let rgb = c?.usingColorSpace(.deviceRGB) else {
            return XCTFail("color missing", file: file, line: line)
        }
        XCTAssertEqual(rgb.redComponent, r, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rgb.greenComponent, g, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rgb.blueComponent, b, accuracy: accuracy, file: file, line: line)
    }

    private func host(_ view: StartPageView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        window = w
        return w
    }

    // MARK: - Recent entries value type

    func testNarrowWindowScalesContentToFitInsteadOfClipping() {
        let v = StartPageView(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
        v.layoutSubtreeIfNeeded()
        let sv = v.subviews.compactMap { $0 as? NSScrollView }.first
        XCTAssertNotNil(sv)
        XCTAssertEqual(sv!.magnification, 680.0 / 834.0, accuracy: 0.001)
        v.setFrameSize(NSSize(width: 1000, height: 600))
        v.layoutSubtreeIfNeeded()
        XCTAssertEqual(sv!.magnification, 1.0, accuracy: 0.001)
    }

    func testRecentEntryEqualityUsesAllFields() {
        let a = StartPageView.RecentEntry(title: "T", domain: "d.com", url: URL(string: "https://d.com/")!, favicon: nil)
        let b = StartPageView.RecentEntry(title: "T", domain: "d.com", url: URL(string: "https://d.com/")!, favicon: nil)
        XCTAssertEqual(a, b)
    }

    func testRecentEntryDiffersByURLOrTitle() {
        let a = StartPageView.RecentEntry(title: "T", domain: "d.com", url: URL(string: "https://d.com/a")!, favicon: nil)
        let b = StartPageView.RecentEntry(title: "T", domain: "d.com", url: URL(string: "https://d.com/b")!, favicon: nil)
        let c = StartPageView.RecentEntry(title: "U", domain: "d.com", url: URL(string: "https://d.com/a")!, favicon: nil)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testRecentEntryKeepsUnicodeTitleAndDomain() {
        let e = StartPageView.RecentEntry(title: "日本語 🍣", domain: "例え.jp", url: URL(string: "https://xn--r8jz45g.jp/")!, favicon: nil)
        XCTAssertEqual(e.title, "日本語 🍣")
        XCTAssertEqual(e.domain, "例え.jp")
        XCTAssertNil(e.favicon)
    }

    func testRecentEntryEmptyTitleIsAllowed() {
        let e = StartPageView.RecentEntry(title: "", domain: "", url: URL(string: "https://x.io/")!, favicon: nil)
        XCTAssertEqual(e.title, "")
        XCTAssertEqual(e.domain, "")
    }

    // MARK: - Recents from history

    func testInitialRecentsDedupeDomainsAndKeepNewestFirstUpToFour() {
        seedHistory([
            (title: "A", url: "https://a.example/1"),
            (title: "A2", url: "https://a.example/2"),
            (title: "B", url: "https://b.example/"),
            (title: "C", url: "https://c.example/"),
            (title: "D", url: "https://d.example/"),
            (title: "E", url: "https://e.example/"),
        ])
        let view = makeView()
        XCTAssertEqual(view.recentEntries.map(\.title), ["A", "B", "C", "D"])
        XCTAssertEqual(view.recentEntries.map(\.domain), ["a.example", "b.example", "c.example", "d.example"])
        XCTAssertEqual(view.recentEntries[0].url.absoluteString, "https://a.example/1")
    }

    func testRecentsWithEmptyHistoryShouldBeEmpty() {
        let view = makeView()
        XCTAssertTrue(view.recentEntries.isEmpty)
    
    }

    func testRecentRowShowsAtMostThreeCards() {
        seedHistory((1...4).map { (title: "Site \($0)", url: "https://s\($0).example/") })
        let view = makeView()
        XCTAssertEqual(view.recentEntries.count, 4)
        XCTAssertEqual(view.recentRowStack.arrangedSubviews.count, 3)
    }

    func testRecentRowShowsAllTwoHistoryCards() {
        seedHistory([(title: "One", url: "https://one.example/"), (title: "Two", url: "https://two.example/")])
        let view = makeView()
        XCTAssertEqual(view.recentRowStack.arrangedSubviews.count, 2)
    }

    func testRecentsIgnoreHistoryTitleWhitespaceWhenRecorded() {
        seedHistory([(title: "   ", url: "https://blank.example/x")])
        let view = makeView()
        XCTAssertEqual(view.recentEntries.first?.title, "blank.example")
    }

    // MARK: - recordRecentVisit

    private func emptyRecents(_ view: StartPageView) {
        view.recentEntries = []
    }

    func testRecordRecentVisitInsertsNewestFirst() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "X", url: URL(string: "https://x.example/")!, favicon: nil)
        view.recordRecentVisit(title: "Y", url: URL(string: "https://y.example/")!, favicon: nil)
        XCTAssertEqual(view.recentEntries.map(\.domain), ["y.example", "x.example"])
    }

    func testRecordRecentVisitDedupesByDomainKeepingLatestURLAndTitle() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "One", url: URL(string: "https://a.example/1")!, favicon: nil)
        view.recordRecentVisit(title: "Two", url: URL(string: "https://a.example/2")!, favicon: nil)
        XCTAssertEqual(view.recentEntries.count, 1)
        XCTAssertEqual(view.recentEntries[0].title, "Two")
        XCTAssertEqual(view.recentEntries[0].url.absoluteString, "https://a.example/2")
    }

    func testRecordRecentVisitCapsStoredEntriesAtFour() {
        let view = makeView()
        emptyRecents(view)
        for i in 1...6 {
            view.recordRecentVisit(title: "S\(i)", url: URL(string: "https://s\(i).example/")!, favicon: nil)
        }
        XCTAssertEqual(view.recentEntries.count, 4)
        XCTAssertEqual(view.recentEntries.first?.domain, "s6.example")
        XCTAssertEqual(view.recentEntries.last?.domain, "s3.example")
    }

    func testRecordRecentVisitRejectsNonWebSchemes() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "F", url: URL(string: "ftp://f.example/")!, favicon: nil)
        view.recordRecentVisit(title: "L", url: URL(string: "file:///tmp/x.html")!, favicon: nil)
        view.recordRecentVisit(title: "S", url: URL(string: "safarium://start")!, favicon: nil)
        XCTAssertTrue(view.recentEntries.isEmpty)
    }

    func testRecordRecentVisitRejectsHostlessWebURL() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "H", url: URL(string: "https:///path-only")!, favicon: nil)
        XCTAssertTrue(view.recentEntries.isEmpty)
    }

    func testRecordRecentVisitIgnoresAboutBlankTitle() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "about:blank", url: URL(string: "https://blank.example/")!, favicon: nil)
        XCTAssertTrue(view.recentEntries.isEmpty)
    }

    func testRecordRecentVisitUsesDomainWhenTitleIsBlank() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "   ", url: URL(string: "https://www.blank.example/x")!, favicon: nil)
        XCTAssertEqual(view.recentEntries.first?.title, "blank.example")
        XCTAssertEqual(view.recentEntries.first?.domain, "blank.example")
    }

    func testRecordRecentVisitTrimsTitle() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "  Padded  ", url: URL(string: "https://p.example/")!, favicon: nil)
        XCTAssertEqual(view.recentEntries.first?.title, "Padded")
    }

    func testRecordRecentVisitStoresUnicodeTitle() {
        let view = makeView()
        emptyRecents(view)
        view.recordRecentVisit(title: "ニュース 📰", url: URL(string: "https://news.example/")!, favicon: nil)
        XCTAssertEqual(view.recentEntries.first?.title, "ニュース 📰")
    }

    func testHiddenViewDefersRecentRebuildUntilFlushed() {
        seedHistory([(title: "One", url: "https://one.example/"), (title: "Two", url: "https://two.example/")])
        let view = makeView()
        XCTAssertEqual(view.recentRowStack.arrangedSubviews.count, 2)
        view.isHidden = true
        view.recordRecentVisit(title: "Three", url: URL(string: "https://three.example/")!, favicon: nil)
        XCTAssertEqual(view.recentEntries.count, 3)
        XCTAssertEqual(view.recentRowStack.arrangedSubviews.count, 2, "row must not rebuild while hidden")
        view.isHidden = false
        view.flushPendingUpdatesIfVisible()
        XCTAssertEqual(view.recentRowStack.arrangedSubviews.count, 3)
    }

    func testFlushWithoutPendingChangeKeepsRowUnchanged() {
        seedHistory([(title: "One", url: "https://one.example/")])
        let view = makeView()
        view.flushPendingUpdatesIfVisible()
        XCTAssertEqual(view.recentRowStack.arrangedSubviews.count, 1)
    }

    // MARK: - Private mode

    func testPrivateModeHidesBannerOnlyWhileEnabled() {
        let view = makeView()
        XCTAssertTrue(view.privateBannerCard.isHidden)
        view.configurePrivateMode(true)
        XCTAssertFalse(view.privateBannerCard.isHidden)
        view.configurePrivateMode(false)
        XCTAssertTrue(view.privateBannerCard.isHidden)
    }

    func testConfigurePrivateModeIsIdempotent() {
        let view = makeView()
        view.configurePrivateMode(true)
        view.configurePrivateMode(true)
        XCTAssertFalse(view.privateBannerCard.isHidden)
    }

    func testPrivateModeClearsHistoryDerivedRecents() {
        seedHistory([(title: "One", url: "https://one.example/"), (title: "Two", url: "https://two.example/")])
        let view = makeView()
        XCTAssertEqual(view.recentEntries.count, 2)
        view.configurePrivateMode(true)
        XCTAssertTrue(view.recentEntries.isEmpty)
        XCTAssertTrue(view.recentRowStack.arrangedSubviews.isEmpty)
    }

    func testLeavingPrivateModeDoesNotResurrectRecents() {
        seedHistory([(title: "One", url: "https://one.example/")])
        let view = makeView()
        view.configurePrivateMode(true)
        view.configurePrivateMode(false)
        XCTAssertTrue(view.recentEntries.isEmpty)
    }

    func testPrivateModeKeepsFavoritesGridVisible() {
        seedFavorites(3)
        let view = makeView()
        view.configurePrivateMode(true)
        XCTAssertFalse(grid(in: view).isHidden)
        XCTAssertEqual(grid(in: view).totalRowCount(), 1)
    }

    func testPrivateModeEmptiesHardCodedRecentsWithNoHistory() {
        let view = makeView()
        view.configurePrivateMode(true)
        XCTAssertTrue(view.recentRowStack.arrangedSubviews.isEmpty)
        XCTAssertEqual(view.recentHeaderLabel?.isHidden, true)
        XCTAssertTrue(view.recentRowStack.isHidden)
    }

    func testPrivateModeMustNotReseedFromHistoryChanges() {
        seedHistory([(title: "Regular", url: "https://regular.example/")])
        let view = makeView()
        view.configurePrivateMode(true)
        AssetLoader.shared.recordHistoryVisit(url: URL(string: "https://other.example/")!, title: "Other")
        XCTAssertTrue(view.recentEntries.isEmpty)
        XCTAssertTrue(view.recentRowStack.arrangedSubviews.isEmpty)
    
    }

    // MARK: - Section visibility preferences

    func testDefaultSectionVisibility() {
        let view = makeView()
        XCTAssertFalse(grid(in: view).isHidden)
        XCTAssertFalse(view.recentRowStack.isHidden)
        XCTAssertTrue(view.privateBannerCard.isHidden)
    }

    func testFavoritesPreferenceHidesGrid() {
        UserDefaults.standard.set(false, forKey: "Safarium.StartPage.showFavorites")
        let view = makeView()
        XCTAssertTrue(grid(in: view).isHidden)
        XCTAssertFalse(view.recentRowStack.isHidden)
    }

    func testRecentPreferenceHidesRecentRow() {
        UserDefaults.standard.set(false, forKey: "Safarium.StartPage.showRecent")
        let view = makeView()
        XCTAssertTrue(view.recentRowStack.isHidden)
        XCTAssertFalse(grid(in: view).isHidden)
    }

    func testPrivacyReportSectionVisibleByDefaultOnNormalStartPage() throws {
        let view = makeView()
        let header = try XCTUnwrap(view.privacyHeaderLabel)
        let card = try XCTUnwrap(view.privacyCardView)
        XCTAssertEqual(header.stringValue, "Privacy Report")
        XCTAssertFalse(header.isHidden)
        XCTAssertFalse(card.isHidden)
    }

    func testPrivacyPreferenceHidesPrivacyReportSection() throws {
        UserDefaults.standard.set(false, forKey: "Safarium.StartPage.showPrivacy")
        let view = makeView()
        XCTAssertTrue(try XCTUnwrap(view.privacyHeaderLabel).isHidden)
        XCTAssertTrue(try XCTUnwrap(view.privacyCardView).isHidden)
    }

    func testPrivateModeHidesPrivacyReportSectionEvenWhenPreferenceEnabled() throws {
        UserDefaults.standard.set(true, forKey: "Safarium.StartPage.showPrivacy")
        let view = makeView()
        XCTAssertFalse(try XCTUnwrap(view.privacyCardView).isHidden)
        view.configurePrivateMode(true)
        XCTAssertTrue(try XCTUnwrap(view.privacyHeaderLabel).isHidden)
        XCTAssertTrue(try XCTUnwrap(view.privacyCardView).isHidden)
        view.configurePrivateMode(false)
        XCTAssertFalse(try XCTUnwrap(view.privacyHeaderLabel).isHidden)
        XCTAssertFalse(try XCTUnwrap(view.privacyCardView).isHidden)
    }

    func testRefreshPrivacyReportRendersPopulatedAndEmptyStates() throws {
        let view = makeView()
        let card = try XCTUnwrap(view.privacyCardView)

        let topTracker = PrivacyReportTrackerEntry(
            entityDomain: "google.com",
            ownerName: "Google",
            category: .advertising,
            trackerDomains: ["doubleclick.net"],
            websites: ["news.example", "shop.example", "blog.example"],
            totalBlockedRequests: 14,
            lastSeen: Date()
        )
        let populated = PrivacyReportSummary(
            uniqueTrackersPrevented: 51,
            totalBlockedRequests: 120,
            totalWebsitesVisited: 100,
            websitesContactingTrackersCount: 43,
            websitesContactingTrackersPercent: 43,
            mostContactedTracker: topTracker,
            httpsUpgradesCount: 5,
            trackingParamsStrippedCount: 3,
            fingerprintingAttemptsBlocked: 2,
            cookiesBlockedCount: 8,
            bounceTrackersMitigatedCount: 0,
            categoryBreakdown: [.advertising: 14],
            websites: [],
            trackers: [topTracker],
            windowDays: 30
        )
        view.refreshPrivacyReport(summary: populated)

        let populatedTexts = descendants(NSTextField.self, in: card).map(\.stringValue)
        XCTAssertTrue(populatedTexts.contains("51"))
        XCTAssertTrue(populatedTexts.contains("43%"))
        XCTAssertTrue(populatedTexts.contains("google.com was prevented from profiling you across 3 websites"))
        XCTAssertTrue(populatedTexts.contains("Last 30 days"))

        let singleSiteTracker = PrivacyReportTrackerEntry(
            entityDomain: "meta.com",
            ownerName: "Meta",
            category: .social,
            trackerDomains: ["connect.facebook.net"],
            websites: ["onlyone.example"],
            totalBlockedRequests: 2,
            lastSeen: Date()
        )
        let singleSummary = PrivacyReportSummary(
            uniqueTrackersPrevented: 1,
            totalBlockedRequests: 2,
            totalWebsitesVisited: 4,
            websitesContactingTrackersCount: 1,
            websitesContactingTrackersPercent: 25,
            mostContactedTracker: singleSiteTracker,
            httpsUpgradesCount: 0,
            trackingParamsStrippedCount: 0,
            fingerprintingAttemptsBlocked: 0,
            cookiesBlockedCount: 0,
            bounceTrackersMitigatedCount: 0,
            categoryBreakdown: [.social: 2],
            websites: [],
            trackers: [singleSiteTracker],
            windowDays: 30
        )
        view.refreshPrivacyReport(summary: singleSummary)
        let singleTexts = descendants(NSTextField.self, in: card).map(\.stringValue)
        XCTAssertTrue(singleTexts.contains("meta.com was prevented from profiling you across 1 website"))

        view.refreshPrivacyReport(summary: .empty)
        let emptyTexts = descendants(NSTextField.self, in: card).map(\.stringValue)
        XCTAssertTrue(emptyTexts.contains("0"))
        XCTAssertTrue(emptyTexts.contains("0%"))
        XCTAssertTrue(emptyTexts.contains("No trackers prevented in the last 30 days"))
    }

    func testPrivacyShowMoreButtonFiresOnOpenPrivacyReport() throws {
        let view = makeView()
        let card = try XCTUnwrap(view.privacyCardView)
        var fired = 0
        view.onOpenPrivacyReport = { fired += 1 }
        let showMoreBtn = try XCTUnwrap(
            descendants(NSButton.self, in: card).first { $0.attributedTitle.string == "Show More" }
        )
        showMoreBtn.performClick(nil)
        XCTAssertEqual(fired, 1)
    }

    func testPrivacyStatTilesHaveNonOverlappingVerticalGeometry() throws {
        let view = makeView()
        _ = host(view)
        let card = try XCTUnwrap(view.privacyCardView)
        view.layoutSubtreeIfNeeded()

        let titles = descendants(NSTextField.self, in: card).filter {
            $0.stringValue == "Trackers prevented from profiling you" ||
            $0.stringValue == "Websites that contacted trackers"
        }
        let values = descendants(NSTextField.self, in: card).filter {
            $0.stringValue == "0" || $0.stringValue == "0%"
        }
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(values.count, 2)
        for titleField in titles {
            let box = try XCTUnwrap(titleField.superview)
            XCTAssertGreaterThanOrEqual(box.bounds.height, 84)
            let valueField = try XCTUnwrap(values.first { $0.superview === box })
            let tRect = titleField.frame
            let vRect = valueField.frame
            XCTAssertFalse(tRect.intersects(vRect), "stat tile title \(tRect) must not overlap value \(vRect)")
        }
    }

    func testPrivateModeClearsPrivacyLabelsAndHidesEditPopoverToggle() throws {
        let view = makeView()
        let topTracker = PrivacyReportTrackerEntry(
            entityDomain: "tracker.example",
            ownerName: "Tracker",
            category: .advertising,
            trackerDomains: ["t.tracker.example"],
            websites: ["site.example"],
            totalBlockedRequests: 9,
            lastSeen: Date()
        )
        let populated = PrivacyReportSummary(
            uniqueTrackersPrevented: 7,
            totalBlockedRequests: 9,
            totalWebsitesVisited: 10,
            websitesContactingTrackersCount: 1,
            websitesContactingTrackersPercent: 10,
            mostContactedTracker: topTracker,
            httpsUpgradesCount: 0,
            trackingParamsStrippedCount: 0,
            fingerprintingAttemptsBlocked: 0,
            cookiesBlockedCount: 0,
            bounceTrackersMitigatedCount: 0,
            categoryBreakdown: [.advertising: 9],
            websites: [],
            trackers: [topTracker],
            windowDays: 30
        )
        view.refreshPrivacyReport(summary: populated)
        view.configurePrivateMode(true)

        let card = try XCTUnwrap(view.privacyCardView)
        let texts = descendants(NSTextField.self, in: card).map(\.stringValue)
        XCTAssertTrue(texts.contains("0"))
        XCTAssertTrue(texts.contains("0%"))
        XCTAssertTrue(texts.contains("No trackers prevented in the last 30 days"))
        XCTAssertFalse(texts.contains("7"))

        _ = host(view)
        let editBtn = try XCTUnwrap(descendants(NSButton.self, in: view).first { $0.title == "Edit" })
        editBtn.performClick(nil)
        if let pop = uiPrivate(view, "activeEditPopover", as: NSPopover.self),
           let popView = pop.contentViewController?.view {
            let popLabels = descendants(NSTextField.self, in: popView).map(\.stringValue)
            XCTAssertFalse(popLabels.contains("Privacy Report"))
            pop.close()
        }
    }

    func testHiddenStartPageDefersPrivacyRefreshUntilFlushed() throws {
        let view = makeView()
        let card = try XCTUnwrap(view.privacyCardView)
        view.isHidden = true

        NotificationCenter.default.post(name: .safariumPrivacyReportDidChange, object: nil)
        XCTAssertEqual(uiPrivate(view, "needsPrivacyRefresh", as: Bool.self), true)

        view.isHidden = false
        view.flushPendingUpdatesIfVisible()
        XCTAssertEqual(uiPrivate(view, "needsPrivacyRefresh", as: Bool.self), false)
        XCTAssertFalse(card.isHidden)
    }

    // MARK: - Favorites grid geometry

    func testGridHeightClampsToOneRow() {
        XCTAssertEqual(FavoritesReorderGridView.height(forVisibleRows: 0), 108)
        XCTAssertEqual(FavoritesReorderGridView.height(forVisibleRows: -3), 108)
        XCTAssertEqual(FavoritesReorderGridView.height(forVisibleRows: 1), 108)
    }

    func testGridHeightIncludesRowSpacing() {
        XCTAssertEqual(FavoritesReorderGridView.height(forVisibleRows: 2), 232)
        XCTAssertEqual(FavoritesReorderGridView.height(forVisibleRows: 3), 356)
    }

    func testGridGeometryConstants() {
        XCTAssertEqual(FavoritesReorderGridView.columns, 8)
        XCTAssertEqual(FavoritesReorderGridView.collapsedMaxCount, 16)
        XCTAssertEqual(FavoritesReorderGridView.gridWidth, 738)
        XCTAssertEqual(FavoritesReorderGridView.colPitch, 94)
        XCTAssertEqual(FavoritesReorderGridView.rowPitch, 124)
    }

    func testGridRowCountBoundariesAroundEightColumns() {
        let cases: [(Int, Int)] = [(0, 1), (1, 1), (7, 1), (8, 1), (9, 2), (15, 2), (16, 2), (17, 3)]
        for (count, rows) in cases {
            seedFavorites(count)
            let view = makeView()
            XCTAssertEqual(grid(in: view).totalRowCount(), rows, "favorites \(count)")
        }
    }

    func testGridCollapsedRowsCapAtTwoAndExpandShowsAll() {
        seedFavorites(17)
        let view = makeView()
        XCTAssertEqual(grid(in: view).visibleRowCount(expanded: false), 2)
        XCTAssertEqual(grid(in: view).visibleRowCount(expanded: true), 3)
    }

    func testGridCollapsedRowsWithFewerThanTwoRows() {
        seedFavorites(3)
        let view = makeView()
        XCTAssertEqual(grid(in: view).visibleRowCount(expanded: false), 1)
    }

    func testGridSlotRectsFollowEightColumnPitch() {
        seedFavorites(17)
        let g = grid(in: makeView())
        XCTAssertEqual(g.slotRect(for: 0), NSRect(x: 0, y: 0, width: 80, height: 108))
        XCTAssertEqual(g.slotRect(for: 7), NSRect(x: 658, y: 0, width: 80, height: 108))
        XCTAssertEqual(g.slotRect(for: 8), NSRect(x: 0, y: 124, width: 80, height: 108))
        XCTAssertEqual(g.slotRect(for: 15), NSRect(x: 658, y: 124, width: 80, height: 108))
    }

    func testGridWithNoFavoritesStillHasOneRow() {
        seedFavorites(0)
        let view = makeView()
        XCTAssertEqual(grid(in: view).totalRowCount(), 1)
        XCTAssertEqual(grid(in: view).visibleRowCount(expanded: true), 1)
    }

    // MARK: - Wallpaper and colors

    func testTopColorWithBackgroundDisabledIsLightGray() {
        let view = makeView()
        assertColor(view.effectiveTopColor, 0.875, 0.875, 0.882, accuracy: 0.001)
    }

    func testDisabledBackgroundIgnoresWallpaperPreference() {
        UserDefaults.standard.set(false, forKey: "Safarium.StartPage.bgEnabled")
        UserDefaults.standard.set("safari-27-orange", forKey: "Safarium.StartPage.wallpaperID")
        let view = makeView()
        XCTAssertFalse(view.hasActiveWallpaper)
        assertColor(view.effectiveTopColor, 0.875, 0.875, 0.882, accuracy: 0.001)
        XCTAssertTrue(wallpaperView(in: view)?.isHidden ?? true)
    }

    func testFallbackTopColorForEachKnownWallpaper() {
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: "safari-27-blue"), 0.16, 0.36, 0.64, accuracy: 0.001)
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: "safari-27-orange"), 0.78, 0.42, 0.22, accuracy: 0.001)
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: "safari-27-pink"), 0.76, 0.38, 0.56, accuracy: 0.001)
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: "california-grizzly-bear"), 0.22, 0.26, 0.24, accuracy: 0.001)
    }

    func testFallbackTopColorForUnknownAndNilIDsIsSlate() {
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: "unknown-id"), 0.24, 0.34, 0.44, accuracy: 0.001)
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: nil), 0.24, 0.34, 0.44, accuracy: 0.001)
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: ""), 0.24, 0.34, 0.44, accuracy: 0.001)
    }

    func testFallbackTopColorIDMatchIsCaseSensitive() {
        assertColor(StartPageView.fallbackTopColor(forWallpaperID: "Safari-27-Blue"), 0.24, 0.34, 0.44, accuracy: 0.001)
    }

    func testEnabledWithoutWallpaperUsesSlateFallback() {
        UserDefaults.standard.set(true, forKey: "Safarium.StartPage.bgEnabled")
        let view = makeView()
        XCTAssertFalse(view.hasActiveWallpaper)
        assertColor(view.effectiveTopColor, 0.24, 0.34, 0.44, accuracy: 0.001)
        XCTAssertTrue(wallpaperView(in: view)?.isHidden ?? true)
    }

    func testCustomWallpaperShowsAndSamplesTopColor() {
        let path = writeSolidPNG(named: "solid-green.png", color: NSColor(deviceRed: 0.2, green: 0.6, blue: 0.4, alpha: 1), size: 40)
        UserDefaults.standard.set(true, forKey: "Safarium.StartPage.bgEnabled")
        UserDefaults.standard.set(path, forKey: "Safarium.StartPage.customWallpaperPath")
        let view = makeView()
        XCTAssertTrue(view.hasActiveWallpaper)
        XCTAssertFalse(wallpaperView(in: view)?.isHidden ?? true)
        assertColor(view.effectiveTopColor, 0.2, 0.6, 0.4)
    }

    func testMissingCustomWallpaperHidesBackdropAndUsesFallback() {
        UserDefaults.standard.set(true, forKey: "Safarium.StartPage.bgEnabled")
        UserDefaults.standard.set("/nonexistent/path/wallpaper.png", forKey: "Safarium.StartPage.customWallpaperPath")
        let view = makeView()
        XCTAssertTrue(wallpaperView(in: view)?.isHidden ?? false)
        assertColor(view.effectiveTopColor, 0.24, 0.34, 0.44, accuracy: 0.001)
    }

    func testMissingCustomWallpaperShouldNotBeTreatedAsActive() {
        UserDefaults.standard.set(true, forKey: "Safarium.StartPage.bgEnabled")
        UserDefaults.standard.set("/nonexistent/path/wallpaper.png", forKey: "Safarium.StartPage.customWallpaperPath")
        let view = makeView()
        XCTAssertFalse(view.hasActiveWallpaper)
    
    }

    func testUnloadableWallpaperIDShouldNotBeTreatedAsActive() {
        UserDefaults.standard.set(true, forKey: "Safarium.StartPage.bgEnabled")
        UserDefaults.standard.set("no-such-wallpaper", forKey: "Safarium.StartPage.wallpaperID")
        let view = makeView()
        XCTAssertFalse(view.hasActiveWallpaper)
    
    }

    func testDisabledBackgroundWithCustomPathIsHidden() {
        let path = writeSolidPNG(named: "disabled-case.png", color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), size: 8)
        UserDefaults.standard.set(false, forKey: "Safarium.StartPage.bgEnabled")
        UserDefaults.standard.set(path, forKey: "Safarium.StartPage.customWallpaperPath")
        let view = makeView()
        XCTAssertFalse(view.hasActiveWallpaper)
        XCTAssertTrue(wallpaperView(in: view)?.isHidden ?? false)
    }

    func testKnownBundledWallpaperLoadsWhenAvailable() throws {
        try XCTSkipIf(AssetLoader.shared.wallpaper(named: "safari-27-blue", thumbnail: false) == nil, "bundled wallpaper not present in this checkout")
        UserDefaults.standard.set(true, forKey: "Safarium.StartPage.bgEnabled")
        UserDefaults.standard.set("safari-27-blue", forKey: "Safarium.StartPage.wallpaperID")
        let view = makeView()
        XCTAssertTrue(view.hasActiveWallpaper)
        XCTAssertFalse(wallpaperView(in: view)?.isHidden ?? true)
    }

    func testSampleTopStripColorOfSolidImage() throws {
        let path = writeSolidPNG(named: "sample-solid.png", color: NSColor(deviceRed: 0.9, green: 0.1, blue: 0.3, alpha: 1), size: 32)
        let image = try XCTUnwrap(NSImage(contentsOfFile: path))
        assertColor(StartPageView.sampleTopStripColor(from: image), 0.9, 0.1, 0.3, accuracy: 0.03)
    }

    func testSampleTopStripColorOfOnePixelImage() throws {
        let path = writeSolidPNG(named: "sample-one-pixel.png", color: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), size: 1)
        let image = try XCTUnwrap(NSImage(contentsOfFile: path))
        assertColor(StartPageView.sampleTopStripColor(from: image), 1, 0, 0, accuracy: 0.03)
    }

    func testSampleTopStripColorNilWithoutBitmapRepresentation() {
        XCTAssertNil(StartPageView.sampleTopStripColor(from: NSImage()))
    }

    func testSampledWhiteWallpaperGivesWhiteTopColor() throws {
        let path = writeSolidPNG(named: "sample-white.png", color: NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), size: 24)
        let image = try XCTUnwrap(NSImage(contentsOfFile: path))
        assertColor(StartPageView.sampleTopStripColor(from: image), 1, 1, 1, accuracy: 0.02)
    }

    // MARK: - Scrolling helpers

    func testScrollToEdgeReachesTopAndBottom() throws {
        seedHistory((1...3).map { (title: "S\($0)", url: "https://s\($0).example/") })
        seedFavorites(40)
        let view = makeView()
        _ = host(view)
        let sv = try XCTUnwrap(scrollView(in: view))
        let doc = try XCTUnwrap(sv.documentView)
        view.scrollToEdge(top: false)
        let maxY = max(0, doc.bounds.height - sv.contentView.bounds.height)
        XCTAssertEqual(sv.contentView.bounds.origin.y, maxY, accuracy: 0.5)
        view.scrollToEdge(top: true)
        XCTAssertEqual(sv.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    func testScrollByDeltaClampsAtTopAndBottom() throws {
        seedFavorites(40)
        let view = makeView()
        _ = host(view)
        let sv = try XCTUnwrap(scrollView(in: view))
        let doc = try XCTUnwrap(sv.documentView)
        let maxY = max(0, doc.bounds.height - sv.contentView.bounds.height)
        view.scrollToEdge(top: true)
        view.scrollByDeltaY(-50)
        XCTAssertEqual(sv.contentView.bounds.origin.y, min(50, maxY), accuracy: 0.5)
        view.scrollByDeltaY(1_000_000)
        XCTAssertEqual(sv.contentView.bounds.origin.y, 0, accuracy: 0.5)
        view.scrollByDeltaY(-1_000_000)
        XCTAssertEqual(sv.contentView.bounds.origin.y, maxY, accuracy: 0.5)
    }
}
