import XCTest
import AppKit
@testable import Safarium

@MainActor
final class TabHoverPreviewTests: HermeticTestCase {
    private var controller: TabHoverPreviewController!
    private var hostWindow: NSWindow!
    private var anchor: NSView!
    private let containerSize = NSSize(width: 900, height: 600)

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.makeFixture() }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            self.controller.dismiss(animated: false)
            self.hostWindow.close()
            self.controller = nil
            self.hostWindow = nil
            self.anchor = nil
        }
        super.tearDown()
    }

    private func makeFixture() {
        _ = NSApplication.shared
        controller = TabHoverPreviewController()
        let container = NSView()
        hostWindow = TabUIHost.window(containing: container, size: containerSize)
        anchor = NSView(frame: NSRect(x: 400, y: 300, width: 80, height: 30))
        container.addSubview(anchor)
        container.layoutSubtreeIfNeeded()
    }

    // MARK: - helpers

    /// Positions the host window so its content origin sits at `origin` in screen coordinates.
    private func moveWindow(to origin: NSPoint) {
        hostWindow.setFrameOrigin(origin)
    }

    /// Mirrors the controller's screen choice: the window's screen, else the main screen, else 1440x900.
    private func visibleFrame() -> NSRect {
        hostWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func item(_ id: String = "t1", title: String = "Example", domain: String = "example.com",
                      favicon: NSImage? = nil, snapshot: NSImage? = nil, start: Bool = false) -> TabHoverPreviewController.PreviewItem {
        TabHoverPreviewController.PreviewItem(tabID: id, title: title, domain: domain, favicon: favicon,
                                              snapshot: snapshot, isStartPage: start)
    }

    private func frame(_ cardSize: NSSize = NSSize(width: 276, height: 224), placement: TabHoverPreviewController.Placement) -> NSRect {
        controller.computePanelFrame(cardSize: cardSize, placement: placement, parentWindow: hostWindow)
    }

    private func screenRect(of v: NSView) -> NSRect {
        hostWindow.convertToScreen(v.convert(v.bounds, to: nil))
    }

    private func mirrorValue<T>(_ label: String, as type: T.Type) -> T? {
        Mirror(reflecting: controller!).children.first(where: { $0.label == label })?.value as? T
    }

    // MARK: - models and constants

    func testPreviewItemRetainsEveryField() {
        let fav = TabUIHost.solidImage(width: 4, height: 4)
        let snap = TabUIHost.solidImage(width: 8, height: 8)
        let it = item("tab-9", title: "Title", domain: "news.example", favicon: fav, snapshot: snap, start: false)
        XCTAssertEqual(it.tabID, "tab-9")
        XCTAssertEqual(it.title, "Title")
        XCTAssertEqual(it.domain, "news.example")
        XCTAssertTrue(it.favicon === fav)
        XCTAssertTrue(it.snapshot === snap)
        XCTAssertFalse(it.isStartPage)
    }

    func testStartPagePreviewItemWithoutSnapshotOrFavicon() {
        let it = item("start", title: "", domain: "", start: true)
        XCTAssertNil(it.favicon)
        XCTAssertNil(it.snapshot)
        XCTAssertTrue(it.isStartPage)
        XCTAssertEqual(it.title, "")
    }

    func testPlacementBelowCarriesAnchorView() {
        let p = TabHoverPreviewController.Placement.below(anchorView: anchor)
        guard case .below(let v) = p else { return XCTFail("wrong case") }
        XCTAssertTrue(v === anchor)
    }

    func testPlacementBelowVerticalPillCarriesRailEdge() {
        let p = TabHoverPreviewController.Placement.belowVerticalPill(anchorView: anchor, railRightXInWindow: 123.5)
        guard case .belowVerticalPill(let v, let x) = p else { return XCTFail("wrong case") }
        XCTAssertTrue(v === anchor)
        XCTAssertEqual(x, 123.5)
    }

    func testCardDimensionsMatchMacOSPreviewCard() {
        XCTAssertEqual(TabHoverPreviewController.cardWidth, 276)
        XCTAssertEqual(TabHoverPreviewController.cardHeight, 224)
    }

    // MARK: - computePanelFrame placement

    func testBelowPlacementCentresCardUnderAnchorAndDropsSixPoints() {
        moveWindow(to: NSPoint(x: visibleFrame().midX - 450, y: visibleFrame().midY - 300))
        let f = frame(placement: .below(anchorView: anchor))
        let a = screenRect(of: anchor)
        XCTAssertEqual(f.size, NSSize(width: 276, height: 224))
        XCTAssertEqual(f.midX, round(a.midX), accuracy: 1.0)
        XCTAssertEqual(f.maxY, a.minY - 6, accuracy: 1.0)
    }

    func testBelowPlacementExactFormula() {
        moveWindow(to: NSPoint(x: visibleFrame().midX - 450, y: visibleFrame().midY - 300))
        let f = frame(placement: .below(anchorView: anchor))
        let a = screenRect(of: anchor)
        XCTAssertEqual(f.minX, round(a.midX - 138), accuracy: 0.0001)
        XCTAssertEqual(f.minY, round(a.minY - 6 - 224), accuracy: 0.0001)
    }

    func testBelowPlacementClampsToLeftEdgeWithMargin() {
        let vis = visibleFrame()
        anchor.frame = NSRect(x: 0, y: 300, width: 40, height: 30)
        moveWindow(to: NSPoint(x: vis.minX, y: vis.midY))
        let f = frame(placement: .below(anchorView: anchor))
        XCTAssertEqual(f.minX, vis.minX + 10, accuracy: 0.0001)
    }

    func testBelowPlacementClampsToRightEdgeWithMargin() {
        let vis = visibleFrame()
        anchor.frame = NSRect(x: 860, y: 300, width: 40, height: 30)
        moveWindow(to: NSPoint(x: vis.maxX - 900, y: vis.midY))
        let f = frame(placement: .below(anchorView: anchor))
        XCTAssertEqual(f.maxX, vis.maxX - 10, accuracy: 0.0001)
    }

    func testBelowPlacementClampsToBottomEdgeWithMargin() {
        let vis = visibleFrame()
        anchor.frame = NSRect(x: 400, y: 0, width: 80, height: 30)
        moveWindow(to: NSPoint(x: vis.midX - 450, y: vis.minY))
        let f = frame(placement: .below(anchorView: anchor))
        XCTAssertEqual(f.minY, vis.minY + 10, accuracy: 0.0001)
    }

    func testBelowPlacementClampsToTopEdgeWhenAnchorIsHigh() {
        let vis = visibleFrame()
        anchor.frame = NSRect(x: 400, y: 5000, width: 80, height: 30)
        moveWindow(to: NSPoint(x: vis.midX - 450, y: vis.midY))
        let f = frame(placement: .below(anchorView: anchor))
        XCTAssertEqual(f.maxY, vis.maxY - 10, accuracy: 0.0001)
    }

    func testVerticalPillPlacementUsesRailEdgePlusSix() {
        let vis = visibleFrame()
        moveWindow(to: NSPoint(x: vis.midX - 450, y: vis.midY - 300))
        let railX: CGFloat = 300
        let f = frame(placement: .belowVerticalPill(anchorView: anchor, railRightXInWindow: railX))
        let railOnScreen = hostWindow.convertToScreen(NSRect(x: railX, y: 0, width: 0, height: 0)).origin.x
        XCTAssertEqual(f.minX, round(railOnScreen + 6), accuracy: 0.0001)
    }

    func testVerticalPillPlacementSitsBelowPillMidline() {
        let vis = visibleFrame()
        moveWindow(to: NSPoint(x: vis.midX - 450, y: vis.midY - 300))
        let f = frame(placement: .belowVerticalPill(anchorView: anchor, railRightXInWindow: 300))
        let a = screenRect(of: anchor)
        let pillMinY = round(a.midY - 14)
        XCTAssertEqual(f.maxY, pillMinY - 6, accuracy: 0.0001)
    }

    func testVerticalPillFlipsAboveWhenNoRoomBelow() {
        let vis = visibleFrame()
        anchor.frame = NSRect(x: 400, y: 0, width: 80, height: 30)
        moveWindow(to: NSPoint(x: vis.midX - 450, y: vis.minY + 5))
        let f = frame(placement: .belowVerticalPill(anchorView: anchor, railRightXInWindow: 300))
        let a = screenRect(of: anchor)
        // Not enough room below, so the card goes above the pill: midY + 14 + 6 = midY + 20.
        let expectedY = min(max(round(a.midY + 20), vis.minY + 10), vis.maxY - 224 - 10)
        XCTAssertEqual(f.minY, expectedY, accuracy: 0.0001)
    }

    func testPanelFrameKeepsRequestedCardSize() {
        moveWindow(to: NSPoint(x: visibleFrame().midX - 450, y: visibleFrame().midY - 300))
        let f = frame(NSSize(width: 100, height: 50), placement: .below(anchorView: anchor))
        XCTAssertEqual(f.width, 100)
        XCTAssertEqual(f.height, 50)
    }

    func testPanelFrameStaysInsideVisibleFrameForAnyAnchorPosition() {
        let vis = visibleFrame()
        for x in stride(from: CGFloat(-200), through: 1000, by: 300) {
            for y in stride(from: CGFloat(-200), through: 800, by: 250) {
                anchor.frame = NSRect(x: x, y: y, width: 40, height: 30)
                moveWindow(to: NSPoint(x: vis.midX - 450, y: vis.midY - 300))
                let f = frame(placement: .below(anchorView: anchor))
                XCTAssertGreaterThanOrEqual(f.minX, vis.minX + 10 - 0.0001, "x=\(x) y=\(y)")
                XCTAssertLessThanOrEqual(f.maxX, vis.maxX - 10 + 0.0001, "x=\(x) y=\(y)")
            }
        }
    }

    // MARK: - hover state machine

    func testHoverEnteredSetsPendingTab() {
        controller.hoverEntered(item: item("A"), placement: .below(anchorView: anchor), in: hostWindow, isDark: false)
        XCTAssertEqual(controller.pendingTabID, "A")
        XCTAssertNil(controller.currentTabID)
    }

    func testHoverExitForPendingTabClearsPending() {
        controller.hoverEntered(item: item("A"), placement: .below(anchorView: anchor), in: hostWindow, isDark: false)
        controller.hoverExited(tabID: "A")
        XCTAssertNil(controller.pendingTabID)
    }

    func testHoverExitForOtherTabKeepsPending() {
        controller.hoverEntered(item: item("A"), placement: .below(anchorView: anchor), in: hostWindow, isDark: false)
        controller.hoverExited(tabID: "B")
        XCTAssertEqual(controller.pendingTabID, "A")
    }

    func testHoverEnteredReplacesPendingTab() {
        controller.hoverEntered(item: item("A"), placement: .below(anchorView: anchor), in: hostWindow, isDark: false)
        controller.hoverEntered(item: item("B"), placement: .below(anchorView: anchor), in: hostWindow, isDark: true)
        XCTAssertEqual(controller.pendingTabID, "B")
    }

    func testDismissClearsAllTrackingState() {
        controller.hoverEntered(item: item("A"), placement: .below(anchorView: anchor), in: hostWindow, isDark: false)
        controller.dismiss(animated: false)
        XCTAssertNil(controller.pendingTabID)
        XCTAssertNil(controller.currentTabID)
    }

    func testDismissOrdersOutExistingPanel() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        let panel = mirrorValue("panel", as: NSPanel.self)
        XCTAssertNotNil(panel)
        controller.dismiss(animated: false)
        XCTAssertFalse(panel?.isVisible ?? true)
        XCTAssertEqual(panel?.alphaValue ?? 1, 0, accuracy: 0.0001)
    }

    // MARK: - card population

    func testPopulateStartPageUsesFixedTitleAndDomainLine() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        controller.populate(item: item("s", title: "ignored", domain: "ignored", start: true), isDark: false)
        XCTAssertEqual(controller.titleLabel?.stringValue, "Start Page")
        XCTAssertEqual(controller.domainLabel?.stringValue, "Favorites & Recently Viewed")
    }

    func testPopulateRegularPageShowsTitleAndDomain() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        controller.populate(item: item(title: "Report", domain: "news.example"), isDark: false)
        XCTAssertEqual(controller.titleLabel?.stringValue, "Report")
        XCTAssertEqual(controller.domainLabel?.stringValue, "news.example")
    }

    func testPopulateEmptyTitleFallsBackToDomain() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        controller.populate(item: item(title: "", domain: "fallback.example"), isDark: true)
        XCTAssertEqual(controller.titleLabel?.stringValue, "fallback.example")
    }

    func testPopulateWithoutSnapshotShowsPlaceholderAndHidesThumbnail() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        controller.populate(item: item(), isDark: false)
        XCTAssertEqual(controller.placeholderView?.isHidden, false)
        let thumb = mirrorValue("thumbnailView", as: NSView.self)
        XCTAssertEqual(thumb?.isHidden, true)
    }

    func testPopulateWithSnapshotShowsThumbnailAndHidesPlaceholder() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        controller.populate(item: item(snapshot: TabUIHost.solidImage(width: 40, height: 30)), isDark: false)
        XCTAssertEqual(controller.placeholderView?.isHidden, true)
        XCTAssertEqual(mirrorValue("thumbnailView", as: NSView.self)?.isHidden, false)
    }

    func testPopulateUsesFaviconInPlaceholderForRegularPage() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        let fav = TabUIHost.solidImage(width: 16, height: 16)
        controller.populate(item: item(favicon: fav), isDark: false)
        XCTAssertTrue(controller.placeholderIcon?.image === fav)
    }

    func testPopulateStartPageIgnoresFaviconAndUsesSymbol() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        let fav = TabUIHost.solidImage(width: 16, height: 16)
        controller.populate(item: item(favicon: fav, start: true), isDark: false)
        XCTAssertFalse(controller.placeholderIcon?.image === fav)
        XCTAssertNotNil(controller.placeholderIcon?.image)
    }

    func testPopulateDarkModeUsesLightTitleInk() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        controller.populate(item: item(), isDark: true)
        let ink = controller.titleLabel?.textColor?.usingColorSpace(.genericGray)
        XCTAssertNotNil(ink)
        XCTAssertGreaterThan(ink?.whiteComponent ?? 0, 0.9)
    }

    func testPopulateLightModeUsesDarkTitleInk() {
        controller.ensurePanel(size: NSSize(width: 276, height: 224))
        controller.populate(item: item(), isDark: false)
        let ink = controller.titleLabel?.textColor?.usingColorSpace(.genericGray)
        XCTAssertNotNil(ink)
        XCTAssertLessThan(ink?.whiteComponent ?? 1, 0.2)
    }
}
