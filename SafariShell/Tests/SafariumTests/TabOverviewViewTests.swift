import XCTest
import AppKit
import QuartzCore
@testable import Safarium

@MainActor
final class TabOverviewViewTests: HermeticTestCase {
    private var overview: TabOverviewView!
    private var window: NSWindow!
    private let canvasSize = NSSize(width: 1000, height: 700)

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.makeFixture() }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            self.window.close()
            self.overview = nil
            self.window = nil
        }
        super.tearDown()
    }

    private func makeFixture() {
        _ = NSApplication.shared
        overview = TabOverviewView(frame: NSRect(origin: .zero, size: canvasSize))
        window = TabUIHost.window(containing: overview, size: canvasSize)
        overview.apply(theme: .defaultLight)
        overview.layoutSubtreeIfNeeded()
    }

    // MARK: - helpers

    private func card(_ id: String, title: String? = nil, url: String? = "https://example.com/",
                      active: Bool = false, snapshot: NSImage? = nil) -> TabOverviewView.CardModel {
        TabOverviewView.CardModel(id: id, title: title ?? "Page \(id)", url: url.flatMap { URL(string: $0) },
                                  favicon: nil, snapshot: snapshot, isActive: active)
    }

    private var scrollView: NSScrollView {
        overview.subviews.first(where: { $0 is NSScrollView }) as! NSScrollView
    }

    private var canvas: NSView {
        scrollView.documentView!
    }

    private func findSubview(typeNamed name: String, in root: NSView) -> NSView? {
        for v in root.subviews {
            if String(describing: type(of: v)) == name { return v }
            if let hit = findSubview(typeNamed: name, in: v) { return hit }
        }
        return nil
    }

    private func imageLayer(of v: NSView) -> CALayer? {
        Mirror(reflecting: v).children.first(where: { $0.label == "imageLayer" })?.value as? CALayer
    }

    private func storedCards() -> [TabOverviewView.CardModel] {
        Mirror(reflecting: overview!).children.first(where: { $0.label == "cards" })?.value as? [TabOverviewView.CardModel] ?? []
    }

    private func setSearch(_ text: String) {
        overview.searchQuery = text
    }

    private func layoutCards(_ cards: [TabOverviewView.CardModel]) {
        overview.update(cards: cards)
        overview.layoutSubtreeIfNeeded()
    }

    // MARK: - CardModel

    func testCardModelRetainsEveryField() {
        let img = TabUIHost.solidImage(width: 4, height: 4)
        let url = URL(string: "https://example.com/a?b=c")
        let m = TabOverviewView.CardModel(id: "c1", title: "Title", url: url, favicon: img, snapshot: img, isActive: true)
        XCTAssertEqual(m.id, "c1")
        XCTAssertEqual(m.title, "Title")
        XCTAssertEqual(m.url, url)
        XCTAssertTrue(m.favicon === img)
        XCTAssertTrue(m.snapshot === img)
        XCTAssertTrue(m.isActive)
    }

    func testCardModelAllowsNilURLFaviconAndSnapshot() {
        let m = TabOverviewView.CardModel(id: "n", title: "", url: nil, favicon: nil, snapshot: nil, isActive: false)
        XCTAssertNil(m.url)
        XCTAssertNil(m.favicon)
        XCTAssertNil(m.snapshot)
        XCTAssertEqual(m.title, "")
        XCTAssertFalse(m.isActive)
    }

    func testCardModelKeepsUnicodeTitleVerbatim() {
        let m = TabOverviewView.CardModel(id: "u", title: "日本語 🙂 Ünïcode", url: nil, favicon: nil, snapshot: nil, isActive: false)
        XCTAssertEqual(m.title, "日本語 🙂 Ünïcode")
    }

    // MARK: - grid order and columns

    func testUpdateKeepsModelOrderForVisibleIDs() {
        layoutCards([card("a"), card("b"), card("c")])
        XCTAssertEqual(overview.orderedVisibleIDs, ["a", "b", "c"])
    }

    func testEmptyStateHasOnlyAddCardAndTwoColumns() {
        layoutCards([])
        XCTAssertEqual(overview.orderedVisibleIDs, [])
        XCTAssertEqual(overview.currentColumnCount, 2)
        XCTAssertEqual(canvas.subviews.count, 1, "only the add card")
    }

    func testOneCardPlusAddUsesTwoColumns() {
        layoutCards([card("a")])
        XCTAssertEqual(overview.currentColumnCount, 2)
    }

    func testTwoCardsPlusAddUsesThreeColumns() {
        layoutCards([card("a"), card("b")])
        XCTAssertEqual(overview.currentColumnCount, 3)
    }

    func testFiveCardsPlusAddStillUsesThreeColumns() {
        layoutCards((0..<5).map { card("c\($0)") })
        XCTAssertEqual(overview.currentColumnCount, 3)
    }

    func testSixCardsPlusAddSwitchesToFourColumns() {
        layoutCards((0..<6).map { card("c\($0)") })
        XCTAssertEqual(overview.currentColumnCount, 4)
    }

    func testElevenCardsStayAtFourColumns() {
        layoutCards((0..<11).map { card("c\($0)") })
        XCTAssertEqual(overview.currentColumnCount, 4)
    }

    func testTwoMatchingCardsWithoutAddUseTwoColumns() {
        layoutCards([card("a", title: "alpha x"), card("b", title: "beta x")])
        setSearch("x")
        overview.update(cards: [card("a", title: "alpha x"), card("b", title: "beta x")])
        XCTAssertEqual(overview.orderedVisibleIDs, ["a", "b"])
        XCTAssertEqual(overview.currentColumnCount, 2)
    }

    // MARK: - search filtering

    func testSearchMatchesTitleCaseInsensitively() {
        layoutCards([card("gh", title: "GitHub"), card("ap", title: "Apple")])
        setSearch("GIT")
        overview.update(cards: [card("gh", title: "GitHub"), card("ap", title: "Apple")])
        XCTAssertEqual(overview.orderedVisibleIDs, ["gh"])
    }

    func testSearchMatchesURLSubstring() {
        let cards = [card("a", title: "One", url: "https://apple.com/mac"), card("b", title: "Two", url: "https://example.org")]
        setSearch("apple.com")
        overview.update(cards: cards)
        XCTAssertEqual(overview.orderedVisibleIDs, ["a"])
    }

    func testSearchTrimsWhitespace() {
        let cards = [card("a", title: "Apple"), card("b", title: "Banana")]
        setSearch("   apple \t")
        overview.update(cards: cards)
        XCTAssertEqual(overview.orderedVisibleIDs, ["a"])
    }

    func testWhitespaceOnlySearchShowsAllCardsAndAddCard() {
        let cards = [card("a"), card("b")]
        setSearch("   ")
        overview.update(cards: cards)
        XCTAssertEqual(overview.orderedVisibleIDs, ["a", "b"])
        XCTAssertEqual(canvas.subviews.count, 3, "two cards plus the add card")
    }

    func testNonEmptySearchHidesAddCard() {
        let cards = [card("a", title: "Apple"), card("b", title: "Banana")]
        setSearch("apple")
        overview.update(cards: cards)
        XCTAssertEqual(canvas.subviews.count, 1, "only the matching card, no add card")
    }

    func testSearchWithNoMatchesShowsNoCardsAndNoAddCard() {
        let cards = [card("a", title: "Apple")]
        setSearch("zzz")
        overview.update(cards: cards)
        XCTAssertEqual(overview.orderedVisibleIDs, [])
        XCTAssertEqual(canvas.subviews.count, 0)
        XCTAssertEqual(overview.currentColumnCount, 2)
    }

    func testSearchIsDiacriticSensitiveForTitles() {
        let cards = [card("a", title: "Café", url: "https://x.example"), card("b", title: "Cafeteria", url: "https://y.example")]
        setSearch("CAFÉ")
        overview.update(cards: cards)
        XCTAssertEqual(overview.orderedVisibleIDs, ["a"])
    }

    // MARK: - card geometry

    func testCardFramesStepByColumnGapForThreeColumns() {
        layoutCards([card("a"), card("b"), card("c")]) // 4 items -> 3 columns, gap 28
        guard let r0 = overview.cardRect(for: "a") as NSRect?, let r1 = overview.cardRect(for: "b") as NSRect? else {
            return XCTFail("missing rects")
        }
        XCTAssertEqual(r1.minX - r0.minX, r0.width + 28, accuracy: 0.0001)
        XCTAssertEqual(r1.minY, r0.minY, accuracy: 0.0001)
    }

    func testCardFramesStepByRowGapBetweenRows() {
        layoutCards((0..<4).map { card("c\($0)") }) // 5 items -> 3 columns, row gap 28
        let r0 = overview.cardRect(for: "c0")
        let r3 = overview.cardRect(for: "c3")
        let cardHeight = r0.height + TabOverviewCardView_headerHeight
        XCTAssertEqual(r3.minY - r0.minY, cardHeight + 28, accuracy: 0.0001)
        XCTAssertEqual(r3.minX, r0.minX, accuracy: 0.0001)
    }

    func testTwoColumnLayoutUsesWiderGap() {
        let cards = [card("a", title: "x one"), card("b", title: "x two")]
        overview.update(cards: cards)
        setSearch("x")
        overview.update(cards: cards)
        overview.layoutSubtreeIfNeeded()
        let r0 = overview.cardRect(for: "a")
        let r1 = overview.cardRect(for: "b")
        XCTAssertEqual(r1.minX - r0.minX, r0.width + 46, accuracy: 0.0001)
    }

    func testTwoColumnCardWidthCapsAtFourEightyOnWideView() {
        window.setContentSize(NSSize(width: 2000, height: 700))
        overview.frame = NSRect(x: 0, y: 0, width: 2000, height: 700)
        let cards = [card("a", title: "x one"), card("b", title: "x two")]
        setSearch("x")
        overview.update(cards: cards)
        overview.layoutSubtreeIfNeeded()
        XCTAssertEqual(overview.cardRect(for: "a").width, 480, accuracy: 0.0001)
    }

    func testThreeColumnCardWidthCapsAtThreeEightyOnWideView() {
        window.setContentSize(NSSize(width: 2000, height: 700))
        overview.frame = NSRect(x: 0, y: 0, width: 2000, height: 700)
        layoutCards([card("a"), card("b")])
        XCTAssertEqual(overview.cardRect(for: "a").width, 380, accuracy: 0.0001)
    }

    func testNarrowViewFallsBackToMinimumViewportWidth() {
        window.setContentSize(NSSize(width: 100, height: 700))
        overview.frame = NSRect(x: 0, y: 0, width: 100, height: 700)
        let cards = [card("a", title: "x one"), card("b", title: "x two")]
        setSearch("x")
        overview.update(cards: cards)
        overview.layoutSubtreeIfNeeded()
        // viewW = max(100, 640) = 640; usable = 640 - 144 - 46 = 450; cardW = floor(450 / 2) = 225.
        XCTAssertEqual(overview.cardRect(for: "a").width, 225, accuracy: 0.0001)
    }

    func testCanvasGrowsToContainLastRow() {
        layoutCards((0..<9).map { card("c\($0)") }) // 10 items -> 4 columns, 3 rows
        let last = overview.cardRect(for: "c8")
        let lastMaxY = last.maxY
        XCTAssertGreaterThanOrEqual(canvas.frame.height, lastMaxY + 60 - 0.0001)
    }

    func testAddCardFollowsLastCardInRowMajorOrder() {
        layoutCards([card("a"), card("b")]) // 3 items -> 3 columns; add card lands in column 2, row 0
        let ra = overview.cardRect(for: "a")
        let rb = overview.cardRect(for: "b")
        let frames = canvas.subviews.map(\.frame)
        guard let add = frames.first(where: { $0.minX > rb.minX + 0.5 }) else { return XCTFail("no add card frame") }
        XCTAssertEqual(add.minY, ra.minY - TabOverviewCardView_headerHeight, accuracy: 0.0001)
        XCTAssertGreaterThan(add.minX, rb.minX)
    }

    // MARK: - rects used by zoom and tab identity

    func testFullPageRectTracksBounds() {
        XCTAssertEqual(overview.fullPageRect, NSRect(x: 0, y: 0, width: 1000, height: 700))
    }

    func testFullPageRectFloorsZeroBoundsToOnePoint() {
        overview.frame = .zero
        XCTAssertEqual(overview.fullPageRect, NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testCardRectFallbackForMissingCardIsCenteredAndThirtyFivePercentWide() {
        let r = overview.cardRect(for: "missing")
        let w: CGFloat = 1000 * 0.35
        XCTAssertEqual(r.width, w, accuracy: 0.0001)
        XCTAssertEqual(r.height, w / 1.54, accuracy: 0.0001)
        XCTAssertEqual(r.midX, 500, accuracy: 0.0001)
        XCTAssertEqual(r.midY, 350, accuracy: 0.0001)
    }

    func testCardRectNilIDUsesFallback() {
        XCTAssertEqual(overview.cardRect(for: nil), overview.cardRect(for: "missing"))
    }

    func testCardRectExcludesHeaderFromPresentCard() {
        layoutCards([card("a")])
        let frame = canvas.subviews.first!.frame
        let r = overview.cardRect(for: "a")
        XCTAssertEqual(r.minY, frame.minY + TabOverviewCardView_headerHeight, accuracy: 0.0001)
        XCTAssertEqual(r.height, frame.height - TabOverviewCardView_headerHeight, accuracy: 0.0001)
        XCTAssertEqual(r.width, frame.width, accuracy: 0.0001)
    }

    func testTabIDAtWindowPointResolvesCardCentre() {
        layoutCards([card("a"), card("b")])
        let r = overview.cardRect(for: "b")
        let win = overview.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        XCTAssertEqual(overview.tabId(atWindowPoint: win), "b")
    }

    func testTabIDAtWindowPointOutsideCardsIsNil() {
        layoutCards([card("a")])
        XCTAssertNil(overview.tabId(atWindowPoint: NSPoint(x: 1, y: 1)))
    }

    // MARK: - zoom frame and transition progress

    func testSetZoomFrameRecordsRectAndFullPageGivesProgressZero() {
        let page = overview.fullPageRect
        overview.setZoomFrame(page, backdrop: 0)
        XCTAssertEqual(overview.zoomRect, page)
        XCTAssertEqual(overview.transitionProgress, 0, accuracy: 0.0001)
    }

    func testSetZoomFrameAnchorSizedRectGivesProgressOne() {
        overview.setZoomFrame(NSRect(x: 0, y: 0, width: 1, height: 1), backdrop: 1)
        XCTAssertEqual(overview.transitionProgress, 1, accuracy: 0.0001)
    }

    func testSetZoomFrameHalfScaleGivesProgressHalf() {
        // page width 1000, anchor width 1: progress = (1000 - kx) / 999 = 0.5 when kx = 500.5
        overview.setZoomFrame(NSRect(x: 0, y: 0, width: 500.5, height: 350), backdrop: 0.5)
        XCTAssertEqual(overview.transitionProgress, 0.5, accuracy: 0.0001)
    }

    func testSetZoomFrameUsesBackdropWhenAnchorCannotZoom() {
        // A 1 pt wide page makes the full-page scale 1.0, so progress falls back to the backdrop value.
        overview.frame = NSRect(x: 0, y: 0, width: 1, height: 600)
        overview.setZoomFrame(NSRect(x: 0, y: 0, width: 1, height: 600), backdrop: 0.4)
        XCTAssertEqual(overview.transitionProgress, 0.4, accuracy: 0.0001)
        overview.setZoomFrame(NSRect(x: 0, y: 0, width: 1, height: 600), backdrop: 2)
        XCTAssertEqual(overview.transitionProgress, 1, accuracy: 0.0001)
        overview.setZoomFrame(NSRect(x: 0, y: 0, width: 1, height: 600), backdrop: -3)
        XCTAssertEqual(overview.transitionProgress, 0, accuracy: 0.0001)
    }

    func testSetTransitionProgressClampsToUnitInterval() {
        overview.setTransitionProgress(2)
        XCTAssertEqual(overview.transitionProgress, 1)
        overview.setTransitionProgress(-1)
        XCTAssertEqual(overview.transitionProgress, 0)
        overview.setTransitionProgress(0.3)
        XCTAssertEqual(overview.transitionProgress, 0.3, accuracy: 0.0001)
    }

    func testBeginZoomAtProgressOneLandsOnCardRect() {
        let cards = [card("a"), card("b")]
        overview.beginZoomTransition(cards: cards, tabId: "b", progress: 1)
        overview.layoutSubtreeIfNeeded()
        let expected = overview.cardRect(for: "b")
        XCTAssertEqual(overview.zoomRect.minX, expected.minX, accuracy: 0.01)
        XCTAssertEqual(overview.zoomRect.width, expected.width, accuracy: 0.01)
        XCTAssertEqual(overview.zoomRect.height, expected.height, accuracy: 0.01)
    }

    func testBeginZoomAtProgressZeroCoversFullPage() {
        overview.beginZoomTransition(cards: [card("a")], tabId: "a", progress: 0)
        XCTAssertEqual(overview.zoomRect, overview.fullPageRect)
    }

    func testBeginZoomMidProgressInterpolatesBetweenPageAndCard() {
        let cards = [card("a"), card("b")]
        overview.beginZoomTransition(cards: cards, tabId: "a", progress: 0.25)
        let a = overview.fullPageRect
        let b = overview.cardRect(for: "a")
        XCTAssertEqual(overview.zoomRect.width, a.width + (b.width - a.width) * 0.25, accuracy: 0.5)
        XCTAssertEqual(overview.zoomRect.minY, a.minY + (b.minY - a.minY) * 0.25, accuracy: 0.5)
    }

    func testBeginZoomMarksTransitionAndEndClearsIt() {
        overview.beginZoomTransition(cards: [card("a")], tabId: "a", progress: 1)
        XCTAssertTrue(overview.isTransitioning)
        overview.endZoomTransition(keepPresented: true)
        XCTAssertFalse(overview.isTransitioning)
        XCTAssertTrue(overview.isPresented)
        overview.endZoomTransition(keepPresented: false)
        XCTAssertFalse(overview.isPresented)
    }

    func testIdleOverviewIsNotTransitioningAndInterruptIsSafe() {
        XCTAssertFalse(overview.isTransitioning)
        overview.interruptSpringForInteractivePinch()
        XCTAssertFalse(overview.isTransitioning)
    }

    func testReleaseCachedCardsRemovesHitTargets() {
        layoutCards([card("a")])
        let r = overview.cardRect(for: "a")
        let win = overview.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        XCTAssertEqual(overview.tabId(atWindowPoint: win), "a")
        overview.releaseCachedCards()
        XCTAssertNil(overview.tabId(atWindowPoint: win))
        XCTAssertTrue(storedCards().isEmpty)
    }

    func testUpdateSnapshotReplacesModelImageForKnownTab() {
        let img = TabUIHost.solidImage(width: 10, height: 10)
        layoutCards([card("a")])
        overview.updateSnapshot(img, forTabID: "a")
        XCTAssertTrue(storedCards().first?.snapshot === img)
    }

    func testUpdateSnapshotForUnknownTabIsNoOp() {
        layoutCards([card("a")])
        overview.updateSnapshot(TabUIHost.solidImage(width: 10, height: 10), forTabID: "zzz")
        XCTAssertEqual(storedCards().map(\.id), ["a"])
        XCTAssertNil(storedCards().first?.snapshot)
    }

    // MARK: - snapshot image layer geometry (EdgeToEdgeTopSnapshotView)
    // The card's constraints own the snapshot frame, so these tests read the view's real bounds and
    // assert the aspect-fill math against them rather than forcing a size.

    private func snapshotLayer(for id: String, url: String = "https://example.com/", image: NSImage) -> (bounds: NSRect, layer: CALayer?) {
        layoutCards([card(id, url: url, snapshot: image)])
        guard let snap = findSubview(typeNamed: "EdgeToEdgeTopSnapshotView", in: overview) else {
            XCTFail("snapshot view not found")
            return (.zero, nil)
        }
        snap.needsLayout = true
        snap.layoutSubtreeIfNeeded()
        return (snap.bounds, imageLayer(of: snap))
    }

    func testSnapshotWiderImageAspectFillsAndCentres() {
        let (b, layer) = snapshotLayer(for: "w", image: TabUIHost.solidImage(width: 600, height: 100))
        guard let l = layer else { return XCTFail("no image layer") }
        let scale = max(b.width / 600, b.height / 100)
        XCTAssertEqual(l.frame.width, 600 * scale, accuracy: 0.01)
        XCTAssertEqual(l.frame.height, 100 * scale, accuracy: 0.01)
        XCTAssertEqual(l.frame.midX, b.midX, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(l.frame.width, b.width - 0.01)
        XCTAssertGreaterThanOrEqual(l.frame.height, b.height - 0.01)
    }

    func testSnapshotTallerImageAnchorsTopEdge() {
        // Pages run behind the toolbar, so the image's toolbar band sits just above the card's top edge.
        let (b, layer) = snapshotLayer(for: "t", image: TabUIHost.solidImage(width: 300, height: 600))
        guard let l = layer else { return XCTFail("no image layer") }
        let trim = SafariMetrics.toolbarHeight / 600
        let scale = max(b.width / 300, b.height / (600 * (1 - trim)))
        XCTAssertEqual(l.frame.height, 600 * scale, accuracy: 0.01)
        XCTAssertEqual((l.frame.maxY - b.maxY) / l.frame.height, trim, accuracy: 0.0005)
        XCTAssertGreaterThanOrEqual(l.frame.width, b.width - 0.01)
    }

    func testSnapshotKeepsImageAspectRatio() {
        let (_, layer) = snapshotLayer(for: "e", image: TabUIHost.solidImage(width: 600, height: 400))
        guard let l = layer else { return XCTFail("no image layer") }
        XCTAssertEqual(l.frame.width / l.frame.height, 1.5, accuracy: 0.0001)
    }

    func testSafariumStartPageTrimsToolbarFromTop() {
        // safarium:// pages extend behind the toolbar, so their top 52 pt is trimmed proportionally.
        let (_, layer) = snapshotLayer(for: "start", url: "safarium://start", image: TabUIHost.solidImage(width: 1000, height: 800))
        guard let l = layer, let snap = findSubview(typeNamed: "EdgeToEdgeTopSnapshotView", in: overview) else {
            return XCTFail("no image layer")
        }
        let trimFraction = SafariMetrics.toolbarHeight / 800
        XCTAssertEqual((l.frame.maxY - snap.bounds.maxY) / l.frame.height, trimFraction, accuracy: 0.0005)
    }

    func testWebPageTrimsToolbarLikeNativePages() {
        // Web pages run behind the toolbar too (page-under-toolbar), so their snapshots carry the same top band.
        let (b, layer) = snapshotLayer(for: "web", image: TabUIHost.solidImage(width: 1000, height: 800))
        guard let l = layer else { return XCTFail("no image layer") }
        XCTAssertEqual((l.frame.maxY - b.maxY) / l.frame.height, SafariMetrics.toolbarHeight / 800, accuracy: 0.0005)
    }

    func testShortStartPageImageIsNotTrimmed() {
        // Images no taller than toolbar + 100 pt are never trimmed.
        let (b, layer) = snapshotLayer(for: "short", url: "safarium://start", image: TabUIHost.solidImage(width: 1000, height: 120))
        guard let l = layer else { return XCTFail("no image layer") }
        XCTAssertEqual(l.frame.maxY, b.maxY, accuracy: 0.01)
    }

    func testZeroSizeSnapshotImageClearsLayerContents() {
        let (_, layer) = snapshotLayer(for: "z", image: TabUIHost.solidImage(width: 0, height: 0))
        XCTAssertNil(layer?.contents)
    }
}

/// Mirrors the private `TabOverviewCardView.headerHeight` (25 pt) for frame arithmetic in these tests.
private let TabOverviewCardView_headerHeight: CGFloat = 25.0
