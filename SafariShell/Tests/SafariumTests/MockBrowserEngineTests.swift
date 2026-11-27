import XCTest
import AppKit
@testable import Safarium

/// Records every BrowserTabEngineDelegate callback from a tab.
final class RecordingTabDelegate: BrowserTabEngineDelegate {
    var urls: [URL?] = []
    var titles: [String] = []
    var loading: [Bool] = []
    var progress: [Double] = []
    var samples: [TopEdgeColorSample] = []
    var scrollYs: [CGFloat] = []

    func tabEngine(_ tab: BrowserTabEngine, didChangeURL url: URL?) { urls.append(url) }
    func tabEngine(_ tab: BrowserTabEngine, didChangeTitle title: String) { titles.append(title) }
    func tabEngine(_ tab: BrowserTabEngine, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) { loading.append(isLoading) }
    func tabEngine(_ tab: BrowserTabEngine, didUpdateProgress progress: Double) { self.progress.append(progress) }
    func tabEngine(_ tab: BrowserTabEngine, didSampleTopEdgeColor sample: TopEdgeColorSample) { samples.append(sample) }
    func tabEngine(_ tab: BrowserTabEngine, didUpdateScrollY scrollY: CGFloat, contentHeight: CGFloat) { scrollYs.append(scrollY) }
}

@MainActor
final class MockBrowserEngineTests: HermeticTestCase {
    private nonisolated static let touchedKeys = [
        BrowserSettings.Key.searchEngine,
        BrowserSettings.Key.samePrivateSearch,
        BrowserSettings.Key.privateSearchEngine,
        BrowserSettings.Key.quickWebsiteSearch
    ]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        resetSettings()
    }

    override func tearDown() {
        resetSettings()
        super.tearDown()
    }

    private nonisolated func resetSettings() {
        for key in Self.touchedKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func assertColor(_ color: NSColor?, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let c = color?.usingColorSpace(.sRGB) else {
            return XCTFail("missing color", file: file, line: line)
        }
        XCTAssertEqual(c.redComponent, r, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(c.greenComponent, g, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(c.blueComponent, b, accuracy: 0.005, file: file, line: line)
    }

    /// Gradient midpoints go through AppKit colour blending, so assert each channel lies between the endpoints.
    private func assertBetween(_ color: NSColor?, left: (CGFloat, CGFloat, CGFloat), right: (CGFloat, CGFloat, CGFloat),
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let c = color?.usingColorSpace(.sRGB) else {
            return XCTFail("missing color", file: file, line: line)
        }
        let pairs = [(c.redComponent, left.0, right.0), (c.greenComponent, left.1, right.1), (c.blueComponent, left.2, right.2)]
        for (value, a, b) in pairs {
            XCTAssertGreaterThanOrEqual(value, min(a, b) - 0.005, file: file, line: line)
            XCTAssertLessThanOrEqual(value, max(a, b) + 0.005, file: file, line: line)
        }
    }

    private func makeTab(_ initial: String? = nil) -> MockBrowserTab {
        let tab = MockBrowserTab()
        if let initial { tab.loadURL(url(initial)) }
        return tab
    }

    private func scrollView(of tab: MockBrowserTab) -> NSScrollView? {
        tab.contentView.subviews.compactMap { $0 as? NSScrollView }.first
    }

    // MARK: - Preset catalogue

    func testCatalogueHasSixPresetsInStableOrder() {
        XCTAssertEqual(MockPagePreset.allPresets.map(\.urlString), [
            "https://gemini.google.com", "https://apple.com", "https://youtube.com",
            "https://stripe.com", "https://news.ycombinator.com", "safarium://start"
        ])
    }

    func testCataloguePresetTitlesAndBadges() {
        XCTAssertEqual(MockPagePreset.allPresets.map(\.title), ["Gemini", "Apple", "YouTube", "Stripe", "Hacker News", "Start Page"])
        XCTAssertEqual(MockPagePreset.allPresets.map(\.badgeLetter), ["G", "A", "Y", "S", "Y", "★"])
    }

    func testCataloguePresetGeometryAndSections() {
        let heights = MockPagePreset.allPresets.map(\.heroHeight)
        XCTAssertEqual(heights, [400, 360, 380, 400, 330, 960])
        XCTAssertEqual(MockPagePreset.allPresets.map { $0.sections.count }, [3, 3, 3, 3, 3, 0])
        XCTAssertTrue(MockPagePreset.allPresets.allSatisfy { $0.quickLinks.count == 5 })
    }

    func testEveryCataloguePresetRoutesToItself() {
        for preset in MockPagePreset.allPresets {
            XCTAssertEqual(MockPagePreset.preset(for: url(preset.urlString)).title, preset.title, preset.urlString)
        }
    }

    func testPresetRoutingIsCaseInsensitive() {
        XCTAssertEqual(MockPagePreset.preset(for: url("HTTPS://APPLE.COM")).title, "Apple")
        XCTAssertEqual(MockPagePreset.preset(for: url("https://YOUTUBE.com/watch")).title, "YouTube")
    }

    func testPresetRoutingMatchesSubstringsAnywhereInURL() {
        XCTAssertEqual(MockPagePreset.preset(for: url("https://example.com/?ref=gemini")).title, "Gemini")
        XCTAssertEqual(MockPagePreset.preset(for: url("https://myapple.com.example/x")).title, "Apple")
        XCTAssertEqual(MockPagePreset.preset(for: url("https://stripe.example.net")).title, "Stripe")
    }

    func testPresetRoutingOrderPrefersEarlierPresetWhenSeveralMatch() {
        // Contains both "gemini" and "youtube"; gemini is checked first.
        XCTAssertEqual(MockPagePreset.preset(for: url("https://youtube.com/?q=gemini")).title, "Gemini")
    }

    func testStartPageRoutingUsesSafariumStartSubstring() {
        XCTAssertEqual(MockPagePreset.preset(for: url("safarium://start")).title, "Start Page")
        XCTAssertEqual(MockPagePreset.preset(for: url("safarium://start?x=1")).title, "Start Page")
    }

    func testHackerNewsRoutesByYCombinatorSubstring() {
        XCTAssertEqual(MockPagePreset.preset(for: url("https://news.ycombinator.com/item?id=1")).title, "Hacker News")
    }

    func testHnSubstringInPathDoesNotRouteToHackerNews() {
        XCTAssertNotEqual(MockPagePreset.preset(for: url("https://example.com/hn")).title, "Hacker News")  // routing is by host, not by "hn" substring
    }

    func testGithubHnswIsNotHackerNews() {
        XCTAssertNotEqual(MockPagePreset.preset(for: url("https://github.com/hnsw")).title, "Hacker News")
    
    }

    func testGeneratedPresetForArbitraryHost() {
        let preset = MockPagePreset.preset(for: url("https://example.org/page"))
        XCTAssertEqual(preset.urlString, "https://example.org/page")
        XCTAssertEqual(preset.title, "example.org".capitalized)
        XCTAssertEqual(preset.heroTitle, "example.org")
        XCTAssertEqual(preset.badgeLetter, "E")
        XCTAssertEqual(preset.heroHeight, 360)
        XCTAssertEqual(preset.sections.count, 2)
        XCTAssertEqual(preset.quickLinks.count, 5)
        XCTAssertTrue(preset.heroTextLight)
    }

    func testGeneratedPresetDropsWWWFromDisplayedHost() {
        let preset = MockPagePreset.preset(for: url("https://www.example.org"))
        XCTAssertEqual(preset.heroTitle, "example.org")
    }

    func testGeneratedPresetColorIsStableWithinProcess() {
        let a = MockPagePreset.preset(for: url("https://example.org"))
        let b = MockPagePreset.preset(for: url("https://example.org"))
        XCTAssertEqual(a.badgeColor, b.badgeColor)
        XCTAssertEqual(a.accentColor, b.accentColor)
        let hero = a.badgeColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(hero.alphaComponent, 1.0, accuracy: 0.001)
    }

    func testGeneratedPresetForHostlessURLUsesAbsoluteString() {
        let preset = MockPagePreset.preset(for: url("file:///tmp/notes.txt"))
        XCTAssertEqual(preset.heroTitle, "file:///tmp/notes.txt")
        XCTAssertEqual(preset.badgeLetter, "F")
    }

    func testGeneratedPresetForAboutBlank() {
        let preset = MockPagePreset.preset(for: url("about:blank"))
        XCTAssertEqual(preset.heroTitle, "about:blank")
        XCTAssertEqual(preset.badgeLetter, "A")
    }

    func testGeneratedPresetForShowFullAddressUsesWholeURL() {
        BrowserSettings.shared.set(true, forKey: BrowserSettings.Key.showFullAddress)
        defer { UserDefaults.standard.removeObject(forKey: BrowserSettings.Key.showFullAddress) }
        let preset = MockPagePreset.preset(for: url("https://example.org/a"))
        XCTAssertEqual(preset.heroTitle, "https://example.org/a")
    }

    // MARK: - Mock engine and tab creation

    func testMockEngineIdentityAndLifecycle() {
        let engine = MockBrowserEngine()
        XCTAssertFalse(engine.isRealChromium)
        XCTAssertEqual(engine.engineName, "MockBrowserEngine (Phase 1 Interactive)")
        XCTAssertNoThrow(try engine.start())
        engine.shutdown()
    }

    func testCreateTabWithoutURLLoadsGeminiAndTitle() {
        let tab = MockBrowserEngine().createTab(initialURL: nil, parentView: nil, isPrivate: false) as! MockBrowserTab
        XCTAssertEqual(tab.currentURL, url("https://gemini.google.com"))
        XCTAssertEqual(tab.title, "Gemini")
        XCTAssertFalse(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
    }

    func testCreateTabWithURLAttachesToParentAndLoadsURL() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let tab = MockBrowserEngine().createTab(initialURL: url("https://stripe.com"), parentView: parent, isPrivate: false) as! MockBrowserTab
        XCTAssertTrue(tab.contentView.superview === parent)
        XCTAssertEqual(tab.currentURL, url("https://stripe.com"))
        XCTAssertEqual(tab.tabID.count, 36, "tab identifiers are UUID strings")
    }

    func testEachCreatedTabGetsItsOwnIdentifier() {
        let engine = MockBrowserEngine()
        let ids = (0..<5).map { _ in engine.createTab(initialURL: nil, parentView: nil, isPrivate: false).tabID }
        XCTAssertEqual(Set(ids).count, 5)
    }

    func testNormalTabUsesPrimarySearchEngine() {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        BrowserSettings.shared.set(3, forKey: BrowserSettings.Key.privateSearchEngine)
        let tab = MockBrowserEngine().createTab(initialURL: nil, parentView: nil, isPrivate: false) as! MockBrowserTab
        tab.loadInput("cats")
        XCTAssertEqual(tab.currentURL, url("https://www.google.com/search?q=cats"))
    }

    func testPrivateTabSearchShouldUseSeparatePrivateEngine() {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.samePrivateSearch)
        BrowserSettings.shared.set(1, forKey: BrowserSettings.Key.privateSearchEngine)
        let tab = MockBrowserEngine().createTab(initialURL: nil, parentView: nil, isPrivate: true) as! MockBrowserTab
        tab.loadInput("cats")
        XCTAssertEqual(tab.currentURL, url("https://duckduckgo.com/?q=cats"))
    
    }

    // MARK: - loadInput

    func testLoadInputNormalizesURLsAndSearches() {
        let tab = makeTab()
        tab.loadInput("example.com")
        XCTAssertEqual(tab.currentURL, url("https://example.com"))
        tab.loadInput("")
        XCTAssertEqual(tab.currentURL, url("safarium://start"))
        XCTAssertTrue(tab.isStartPage)
        tab.loadInput("cats and dogs")
        XCTAssertEqual(tab.currentURL, url("https://www.google.com/search?q=cats%20and%20dogs"))
    }

    // MARK: - History navigation

    func testBackAndForwardWalkTheHistory() {
        let tab = makeTab("https://apple.com")
        tab.loadURL(url("https://stripe.com"))
        tab.loadURL(url("https://youtube.com"))
        XCTAssertTrue(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
        tab.goBack()
        XCTAssertEqual(tab.currentURL, url("https://stripe.com"))
        tab.goBack()
        XCTAssertEqual(tab.currentURL, url("https://apple.com"))
        XCTAssertFalse(tab.canGoBack)
        XCTAssertTrue(tab.canGoForward)
        tab.goForward()
        XCTAssertEqual(tab.currentURL, url("https://stripe.com"))
        tab.goForward()
        XCTAssertEqual(tab.currentURL, url("https://youtube.com"))
        XCTAssertFalse(tab.canGoForward)
    }

    func testBackAndForwardAreNoOpsAtHistoryEnds() {
        let tab = makeTab("https://apple.com")
        tab.goBack()
        XCTAssertEqual(tab.currentURL, url("https://apple.com"))
        tab.goForward()
        XCTAssertEqual(tab.currentURL, url("https://apple.com"))
    }

    func testBackAndForwardOnFreshTabDoNothing() {
        let tab = MockBrowserTab()
        XCTAssertNil(tab.currentURL)
        XCTAssertFalse(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
        tab.goBack()
        tab.goForward()
        XCTAssertNil(tab.currentURL)
    }

    func testNewLoadAfterGoingBackDropsForwardHistory() {
        let tab = makeTab("https://apple.com")
        tab.loadURL(url("https://stripe.com"))
        tab.loadURL(url("https://youtube.com"))
        tab.goBack()
        tab.goBack()
        tab.loadURL(url("https://news.ycombinator.com"))
        XCTAssertEqual(tab.currentURL, url("https://news.ycombinator.com"))
        XCTAssertFalse(tab.canGoForward)
        tab.goBack()
        XCTAssertEqual(tab.currentURL, url("https://apple.com"))
        XCTAssertFalse(tab.canGoBack)
    }

    func testReloadingSameURLDoesNotAddDuplicateHistoryEntry() {
        let tab = makeTab("https://apple.com")
        tab.loadURL(url("https://apple.com"))
        tab.loadURL(url("https://apple.com"))
        XCTAssertFalse(tab.canGoBack)
        tab.loadURL(url("https://stripe.com"))
        tab.goBack()
        XCTAssertEqual(tab.currentURL, url("https://apple.com"))
        XCTAssertFalse(tab.canGoBack, "only one apple entry exists")
    }

    func testReloadRepeatsCurrentURLWithoutChangingHistory() {
        let tab = makeTab("https://apple.com")
        tab.loadURL(url("https://stripe.com"))
        tab.reload()
        XCTAssertEqual(tab.currentURL, url("https://stripe.com"))
        XCTAssertTrue(tab.canGoBack)
        tab.goBack()
        XCTAssertEqual(tab.currentURL, url("https://apple.com"))
    }

    func testReloadOnFreshTabDoesNothing() {
        let tab = MockBrowserTab()
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        tab.reload()
        XCTAssertNil(tab.currentURL)
        XCTAssertTrue(delegate.urls.isEmpty)
    }

    // MARK: - Loading state and delegate callbacks

    func testLoadStartsLoadingAndFinishesAfterDelay() {
        let tab = MockBrowserTab()
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        tab.loadURL(url("https://apple.com"))
        XCTAssertTrue(tab.isLoading)
        XCTAssertEqual(tab.estimatedProgress, 0.25, accuracy: 0.0001)
        spinRunLoop(0.3)
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.estimatedProgress, 1.0, accuracy: 0.0001)
        XCTAssertEqual(delegate.loading, [true, false])
        XCTAssertEqual(delegate.progress, [0.25, 1.0])
    }

    func testNavigationCallbacksArriveInOrderWithURLTitleAndFavicon() {
        let tab = MockBrowserTab()
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        tab.loadURL(url("https://stripe.com"))
        XCTAssertEqual(delegate.urls, [url("https://stripe.com")])
        XCTAssertEqual(delegate.titles, ["Stripe"])
        XCTAssertEqual(delegate.loading, [true])
        XCTAssertEqual(tab.favicon?.size, NSSize(width: 16, height: 16))
        spinRunLoop(0.3)
    }

    func testStopLoadingCancelsPendingCompletion() {
        let tab = MockBrowserTab()
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        tab.loadURL(url("https://apple.com"))
        tab.stopLoading()
        XCTAssertFalse(tab.isLoading)
        XCTAssertEqual(tab.estimatedProgress, 1.0)
        spinRunLoop(0.3)
        XCTAssertEqual(delegate.loading, [true, false], "the pending finish must not fire after stop")
        XCTAssertEqual(delegate.progress, [0.25, 1.0])
        XCTAssertFalse(tab.isLoading)
    }

    func testCloseTabStopsPendingCallbacksAndDetachesView() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tab = MockBrowserTab()
        tab.attach(to: parent)
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        tab.loadURL(url("https://apple.com"))
        tab.closeTab()
        spinRunLoop(0.3)
        XCTAssertEqual(delegate.loading, [true])
        XCTAssertNil(tab.contentView.superview)
    }

    func testNavigationCallbackOnDelegateIsOptional() {
        let tab = MockBrowserTab()
        tab.loadURL(url("https://apple.com"))
        XCTAssertNil(tab.delegate)
        spinRunLoop(0.3)
        XCTAssertFalse(tab.isLoading)
    }

    func testTopEdgeSampleIsDeliveredAfterLoad() {
        let tab = MockBrowserTab()
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        tab.loadURL(url("https://apple.com"))
        spinRunLoop(0.3)
        XCTAssertNotNil(tab.lastTopEdgeColorSample)
        XCTAssertEqual(delegate.samples.last, tab.lastTopEdgeColorSample)
        let lum = tab.lastTopEdgeColorSample?.relativeLuminance ?? -1
        XCTAssertTrue((0.0...1.0).contains(lum), "luminance must be normalised, got \(lum)")
    }

    func testSampleTopEdgeColorCompletesWithSample() {
        let tab = makeTab("https://youtube.com")
        var result: TopEdgeColorSample?
        var called = false
        tab.sampleTopEdgeColor(stripHeight: 3) { sample in
            result = sample
            called = true
        }
        XCTAssertTrue(called, "completion is synchronous")
        XCTAssertNotNil(result)
    }

    func testScrollingReportsScrollYToDelegateAndTab() {
        let tab = makeTab("https://apple.com")
        let delegate = RecordingTabDelegate()
        tab.delegate = delegate
        guard let sv = scrollView(of: tab) else { return XCTFail("no scroll view") }
        sv.contentView.scroll(to: NSPoint(x: 0, y: 120))
        sv.reflectScrolledClipView(sv.contentView)
        XCTAssertEqual(tab.scrollY, 120)
        XCTAssertEqual(delegate.scrollYs.last, 120)
        XCTAssertFalse(tab.isScrolledToTop)
        XCTAssertEqual(tab.contentHeight, 1280)
    }

    func testScrollBackToTopResetsScrollY() {
        let tab = makeTab("https://apple.com")
        guard let sv = scrollView(of: tab) else { return XCTFail("no scroll view") }
        sv.contentView.scroll(to: NSPoint(x: 0, y: 200))
        sv.reflectScrolledClipView(sv.contentView)
        sv.contentView.scroll(to: .zero)
        sv.reflectScrolledClipView(sv.contentView)
        XCTAssertEqual(tab.scrollY, 0)
        XCTAssertTrue(tab.isScrolledToTop)
    }

    func testLoadResetsScrollPositionToTop() {
        let tab = makeTab("https://apple.com")
        guard let sv = scrollView(of: tab) else { return XCTFail("no scroll view") }
        sv.contentView.scroll(to: NSPoint(x: 0, y: 200))
        sv.reflectScrolledClipView(sv.contentView)
        tab.loadURL(url("https://stripe.com"))
        XCTAssertEqual(tab.scrollY, 0)
        XCTAssertEqual(tab.contentHeight, 400 + 920, accuracy: 0.5, "content height follows the preset")
    }

    func testPinchMagnificationDoesNothingOnMock() {
        let tab = makeTab("https://apple.com")
        XCTAssertEqual(tab.applyPinchMagnification(0.8, atPoint: .zero, isPinching: true), 1.0)
    }

    // MARK: - Title and favicon per URL

    func testTitleForGeneratedHostIsCapitalizedDomain() {
        let tab = makeTab("https://example.org")
        XCTAssertEqual(tab.title, "example.org".capitalized)
    }

    func testStartPageTitle() {
        let tab = makeTab("safarium://start")
        XCTAssertEqual(tab.title, "Start Page")
        XCTAssertTrue(tab.isStartPage)
        XCTAssertFalse(tab.isHistoryPage)
    }

    func testAllMockPageHeroSampleColorsAreDistinctAcrossPresets() {
        let tab = MockBrowserTab()
        var luminances: [Double] = []
        for preset in MockPagePreset.allPresets.prefix(5) {
            tab.loadURL(url(preset.urlString))
            var sample: TopEdgeColorSample?
            tab.sampleTopEdgeColor(stripHeight: 3) { sample = $0 }
            luminances.append(sample?.relativeLuminance ?? -1)
        }
        XCTAssertEqual(luminances.count, 5)
        XCTAssertTrue(luminances.allSatisfy { $0 >= 0 })
        XCTAssertGreaterThan(Set(luminances.map { ($0 * 100).rounded() }).count, 2, "presets have visibly different top edges")
    }

    // MARK: - MockPageDocumentView

    private func document(for preset: MockPagePreset, width: CGFloat = 800) -> MockPageDocumentView {
        let doc = MockPageDocumentView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        doc.configure(with: preset, viewportWidth: width)
        return doc
    }

    func testDocumentHeightFollowsHeroHeightForWebPages() {
        let doc = document(for: MockPagePreset.allPresets[1], width: 1000)
        XCTAssertEqual(doc.frame.height, 360 + 920)
        XCTAssertEqual(doc.frame.width, 1000)
        XCTAssertTrue(doc.isFlipped)
    }

    func testDocumentStartPageHasMinimumHeight() {
        let doc = document(for: MockPagePreset.allPresets[5], width: 900)
        XCTAssertEqual(doc.frame.height, 960, "start page uses max(860, heroHeight)")
    }

    func testDocumentUpdateWidthChangesOnlyWidth() {
        let doc = document(for: MockPagePreset.allPresets[2], width: 1000)
        let height = doc.frame.height
        doc.updateWidth(700)
        XCTAssertEqual(doc.frame.width, 700)
        XCTAssertEqual(doc.frame.height, height)
    }

    func testTopSurfaceFallbackColorPerStyleAtTop() {
        assertColor(document(for: MockPagePreset.allPresets[0]).topSurfaceFallbackColor(atScrollY: 0), 0.043, 0.063, 0.149)
        assertColor(document(for: MockPagePreset.allPresets[1]).topSurfaceFallbackColor(atScrollY: 0), 1, 1, 1)
        assertColor(document(for: MockPagePreset.allPresets[2]).topSurfaceFallbackColor(atScrollY: 0), 0.80, 0.06, 0.09)
        assertBetween(document(for: MockPagePreset.allPresets[3]).topSurfaceFallbackColor(atScrollY: 0), left: (0.36, 0.21, 0.96), right: (0.0, 0.78, 1.0))
        assertColor(document(for: MockPagePreset.allPresets[4]).topSurfaceFallbackColor(atScrollY: 0), 0.965, 0.965, 0.937)
        assertColor(document(for: MockPagePreset.allPresets[5]).topSurfaceFallbackColor(atScrollY: 0), 0.14, 0.32, 0.62)
    }

    func testTopSurfaceFallbackSwitchesToBodyAtHeroBoundary() {
        let apple = document(for: MockPagePreset.allPresets[1])
        assertColor(apple.topSurfaceFallbackColor(atScrollY: 359.9), 1, 1, 1)
        assertColor(apple.topSurfaceFallbackColor(atScrollY: 360), 0.96, 0.96, 0.97)
        let youtube = document(for: MockPagePreset.allPresets[2])
        assertColor(youtube.topSurfaceFallbackColor(atScrollY: 379.5), 0.80, 0.06, 0.09)
        assertColor(youtube.topSurfaceFallbackColor(atScrollY: 380), 0.06, 0.06, 0.07)
        assertColor(youtube.topSurfaceFallbackColor(atScrollY: 5000), 0.06, 0.06, 0.07)
    }

    func testTopSurfaceFallbackForGeneratedPreset() {
        let preset = MockPagePreset.preset(for: url("https://example.org"))
        let doc = document(for: preset)
        let top = doc.topSurfaceFallbackColor(atScrollY: 0)
        XCTAssertNotNil(top)
        let expected = preset.badgeColor.usingColorSpace(.sRGB)!
        assertColor(top, expected.redComponent, expected.greenComponent, expected.blueComponent)
        assertColor(doc.topSurfaceFallbackColor(atScrollY: 360), 0.97, 0.97, 0.98)
    }

    func testTopSurfaceFallbackForWallpaperStyleUsesFallbackColor() {
        let doc = document(for: MockPagePreset.allPresets[5])
        assertColor(doc.topSurfaceFallbackColor(atScrollY: 959), 0.14, 0.32, 0.62)
        assertColor(doc.topSurfaceFallbackColor(atScrollY: 960), 0.14, 0.32, 0.62)
    }

    func testDocumentConfigureResetsWhenPresetChanges() {
        let doc = document(for: MockPagePreset.allPresets[1])
        doc.configure(with: MockPagePreset.allPresets[2], viewportWidth: 800)
        XCTAssertEqual(doc.frame.height, 380 + 920)
        assertColor(doc.topSurfaceFallbackColor(atScrollY: 0), 0.80, 0.06, 0.09)
    }
}
