import XCTest
import AppKit
@testable import Safarium

/// Window chrome invariants, resize behaviour, and the pure rubber-band / velocity / optical-pinch math used by the
/// window controller. Windows are never ordered on screen.
@MainActor
final class WindowLayoutInvariantTests: T8WindowTestCase {

    private func win(_ wc: SafariWindowController) -> NSWindow {
        guard let w = wc.window else { fatalError("controller has no window") }
        return w
    }

    private func contentSize(_ wc: SafariWindowController) -> NSSize {
        win(wc).contentView?.frame.size ?? .zero
    }

    private func setContent(_ wc: SafariWindowController, _ w: CGFloat, _ h: CGFloat) {
        win(wc).setContentSize(NSSize(width: w, height: h))
        win(wc).contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - Window chrome

    func testMinSizeMatchesSafariMetrics() {
        let (wc, _) = makeWindow()
        XCTAssertEqual(win(wc).minSize.width, SafariMetrics.minWindowWidth)
        XCTAssertGreaterThanOrEqual(win(wc).minSize.height, SafariMetrics.minWindowHeight, "frame minimum includes the titlebar strip")
        XCTAssertEqual(SafariMetrics.minWindowWidth, 680)
        XCTAssertEqual(SafariMetrics.minWindowHeight, 460)
    }

    func testInitialWindowFitsDefaultMetrics() {
        let (wc, _) = makeWindow()
        XCTAssertLessThanOrEqual(win(wc).frame.width, SafariMetrics.defaultWindowWidth + 0.5)
        XCTAssertLessThanOrEqual(win(wc).frame.height, SafariMetrics.defaultWindowHeight + 0.5)
        XCTAssertGreaterThanOrEqual(win(wc).frame.width, SafariMetrics.minWindowWidth)
    }

    func testWindowIsOpaqueWithWhiteBackground() {
        let (wc, _) = makeWindow()
        XCTAssertTrue(win(wc).isOpaque)
        XCTAssertTrue(win(wc).backgroundColor == .white)
    }

    func testWindowUsesUnifiedToolbarWithIconOnlyDisplay() {
        let (wc, _) = makeWindow()
        XCTAssertEqual(win(wc).toolbarStyle, .unified)
        XCTAssertEqual(win(wc).toolbar?.identifier, "SafariumUnifiedToolbar")
        XCTAssertEqual(win(wc).toolbar?.displayMode, .iconOnly)
        XCTAssertFalse(win(wc).toolbar?.allowsUserCustomization ?? true)
    }

    func testWindowTitlebarIsTransparentFullSizeContent() {
        let (wc, _) = makeWindow()
        XCTAssertTrue(win(wc).titlebarAppearsTransparent)
        XCTAssertTrue(win(wc).styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(win(wc).titleVisibility, .hidden)
        XCTAssertEqual(win(wc).titlebarSeparatorStyle, .none)
    }

    func testWindowIsNotRestorableAndSupportsFullScreen() {
        let (wc, _) = makeWindow()
        XCTAssertFalse(win(wc).isRestorable)
        XCTAssertTrue(win(wc).collectionBehavior.contains(.fullScreenPrimary))
    }

    func testWindowIsSafariWindowThatCanBecomeKeyAndMain() {
        let (wc, _) = makeWindow()
        XCTAssertTrue(win(wc) is SafariWindow)
        XCTAssertTrue(win(wc).canBecomeKey)
        XCTAssertTrue(win(wc).canBecomeMain)
    }

    func testWindowIsDelegatedToController() {
        let (wc, _) = makeWindow()
        XCTAssertTrue((win(wc).delegate as AnyObject?) === wc)
    }

    func testNormalWindowIsNotPrivateTitle() {
        let (wc, _) = makeWindow()
        XCTAssertEqual(win(wc).title, "Safarium")
    }

    // MARK: - Resize

    func testResizeToRegularSizeIsHonoured() {
        let (wc, _) = makeWindow()
        setContent(wc, 1000, 700)
        XCTAssertEqual(contentSize(wc).width, 1000, accuracy: 0.5)
        XCTAssertEqual(contentSize(wc).height, 700, accuracy: 0.5)
    }

    func testResizeBelowDeclaredMinimumWidthClampsToDeclaredWidth() {
        let (wc, _) = makeWindow()
        setContent(wc, 700, 600)
        XCTAssertEqual(contentSize(wc).width, 700, accuracy: 1.0)
    
    }

    func testResizeWithCurrentMinimumWidthLeavesWindowUsable() {
        let (wc, _) = makeWindow()
        setContent(wc, 834, 600)
        XCTAssertGreaterThanOrEqual(contentSize(wc).width, 834 - 0.5)
    }

    func testActiveTabContentFollowsWindowResize() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 1)
        setContent(wc, 1100, 760)
        let host = t8Mirror(wc, "webContentHost") as? NSView
        let tabView = eng.created.first?.contentView
        XCTAssertNotNil(host)
        XCTAssertEqual(tabView?.frame.size.width ?? -1, host?.bounds.width ?? -2, accuracy: 0.5)
        XCTAssertEqual(tabView?.frame.size.height ?? -1, host?.bounds.height ?? -2, accuracy: 0.5)
    }

    func testEveryTabViewIsResizedNotOnlyActive() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 3, activateLast: true)
        setContent(wc, 1050, 720)
        let host = t8Mirror(wc, "webContentHost") as? NSView
        for tab in eng.created {
            XCTAssertEqual(tab.contentView.frame.width, host?.bounds.width ?? -1, accuracy: 0.5)
        }
    }

    func testResizeWithNoTabsDoesNotCrash() {
        let (wc, _) = makeWindow()
        setContent(wc, 900, 600)
        setContent(wc, 1200, 800)
        XCTAssertEqual(wc.openTabCount, 0)
    }

    // MARK: - Constraint conflicts

    func testVerticalRailWidthConstraintDoesNotConflictWhileHidden() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2)
        win(wc).contentView?.layoutSubtreeIfNeeded()
        let rail = t8Mirror(wc, "verticalTabRailWidthConstraint") as? NSLayoutConstraint
        XCTAssertNotNil(rail)
        // The rail collapses to width 0 (required); its scroll view's -1pt trailing inset must therefore not be required,
        // otherwise AppKit logs an unsatisfiable-constraint break on every launch.
        let railView = t8Mirror(wc, "verticalTabRailView") as? NSView
        let insets = railView?.constraints.filter { $0.firstAttribute == .trailing && $0.constant == -1 } ?? []
        XCTAssertFalse(insets.isEmpty)
        XCTAssertTrue(insets.allSatisfy { $0.priority < .required })

    }

    // MARK: - Rubber-band math

    func testRubberBandIsZeroForNonPositiveOverflowOrDimension() {
        XCTAssertEqual(PinchGestureCoordinator.rubberBand(0, dimension: 100), 0)
        XCTAssertEqual(PinchGestureCoordinator.rubberBand(-5, dimension: 100), 0)
        XCTAssertEqual(PinchGestureCoordinator.rubberBand(10, dimension: 0), 0)
        XCTAssertEqual(PinchGestureCoordinator.rubberBand(10, dimension: -3), 0)
    }

    func testRubberBandKnownValueAtOverflowEqualToDimension() {
        // (1 - 1/(1*0.55 + 1)) * 100 = 100 * 0.55/1.55
        XCTAssertEqual(PinchGestureCoordinator.rubberBand(100, dimension: 100), 35.48387, accuracy: 0.0001)
    }

    func testRubberBandIsMonotonicInOverflow() {
        let values = [1, 5, 10, 50, 100, 1000].map { PinchGestureCoordinator.rubberBand(CGFloat($0), dimension: 100) }
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertLessThan(a, b)
        }
    }

    func testRubberBandStaysBelowDimension() {
        for overflow in [0.001, 1, 1e3, 1e6, 1e9] {
            XCTAssertLessThan(PinchGestureCoordinator.rubberBand(CGFloat(overflow), dimension: 50), 50)
        }
    }

    func testRubberBandApproachesDimensionForHugeOverflow() {
        XCTAssertGreaterThan(PinchGestureCoordinator.rubberBand(1_000_000, dimension: 100), 99.9)
    }

    func testRubberBandIsScaleInvariantInDimension() {
        let base = PinchGestureCoordinator.rubberBand(30, dimension: 100)
        let scaled = PinchGestureCoordinator.rubberBand(60, dimension: 200)
        XCTAssertEqual(scaled, base * 2, accuracy: 0.0001)
    }

    func testRubberBandIsPositiveForTinyPositiveOverflow() {
        XCTAssertGreaterThan(PinchGestureCoordinator.rubberBand(0.0001, dimension: 100), 0)
    }

    // MARK: - Velocity math

    func testUnitVelocityZeroWhenWidthDeltaWithinTwoPoints() {
        let from = NSRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: 40, from: from, to: NSRect(x: 0, y: 0, width: 101, height: 50), cap: 4), 0)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: 40, from: from, to: NSRect(x: 0, y: 0, width: 102, height: 50), cap: 4), 0)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: 40, from: from, to: NSRect(x: 0, y: 0, width: 98, height: 50), cap: 4), 0)
    }

    func testUnitVelocityNonZeroJustAboveTwoPoints() {
        let from = NSRect(x: 0, y: 0, width: 100, height: 50)
        let v = PinchGestureCoordinator.unitVelocity(widthVelocity: 10, from: from, to: NSRect(x: 0, y: 0, width: 102.5, height: 50), cap: 4)
        XCTAssertEqual(v, 10.0 / 2.5, accuracy: 0.0001)
    }

    func testUnitVelocityScalesWidthVelocityByWidthChange() {
        let from = NSRect(x: 0, y: 0, width: 100, height: 50)
        let to = NSRect(x: 0, y: 0, width: 200, height: 50)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: 50, from: from, to: to, cap: 4), 0.5, accuracy: 0.0001)
    }

    func testUnitVelocityIsCappedAbove() {
        let from = NSRect(x: 0, y: 0, width: 100, height: 50)
        let to = NSRect(x: 0, y: 0, width: 200, height: 50)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: 1000, from: from, to: to, cap: 4), 4, accuracy: 0.0001)
    }

    func testUnitVelocityIsFlooredAtMinusSix() {
        let from = NSRect(x: 0, y: 0, width: 100, height: 50)
        let to = NSRect(x: 0, y: 0, width: 200, height: 50)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: -1000, from: from, to: to, cap: 4), -6, accuracy: 0.0001)
    }

    func testUnitVelocityPositiveWhenShrinkingWithNegativeVelocity() {
        let from = NSRect(x: 0, y: 0, width: 200, height: 50)
        let to = NSRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: -25, from: from, to: to, cap: 4), 0.25, accuracy: 0.0001)
    }

    func testUnitVelocityIgnoresHeightChanges() {
        let from = NSRect(x: 0, y: 0, width: 100, height: 10)
        let to = NSRect(x: 0, y: 0, width: 200, height: 900)
        XCTAssertEqual(PinchGestureCoordinator.unitVelocity(widthVelocity: 50, from: from, to: to, cap: 4), 0.5, accuracy: 0.0001)
    }

    // MARK: - Optical pinch ratio (no overview geometry: zero-size page/card)

    func testOpticalPinchOpeningAtZeroAccumIsFullSize() {
        let wc = OpticalPinchProbe()
        XCTAssertEqual(wc.computeOpticalPinchRatio(accum: 0, opening: true), 1.0, accuracy: 0.0001)
    }

    func testOpticalPinchClosingAtZeroAccumIsMinimumRatio() {
        let wc = OpticalPinchProbe()
        let minRatio = wc.computeOpticalPinchRatio(accum: 0, opening: false)
        XCTAssertGreaterThanOrEqual(minRatio, 0.12)
        XCTAssertLessThanOrEqual(minRatio, 0.9)
    }

    func testOpticalPinchNeverFallsBelowEightPercent() {
        let wc = OpticalPinchProbe()
        let r = wc.computeOpticalPinchRatio(accum: -1000, opening: true)
        XCTAssertGreaterThanOrEqual(r, 0.08)
        XCTAssertLessThan(r, wc.computeOpticalPinchRatio(accum: 0, opening: false), "overshoot below the minimum rubber-bands, it does not jump past it")
    }

    func testOpticalPinchOvershootAboveOneRubberBands() {
        let wc = OpticalPinchProbe()
        let r = wc.computeOpticalPinchRatio(accum: 1, opening: true)
        XCTAssertGreaterThan(r, 1.0)
        XCTAssertLessThan(r, 1.065, "overshoot is capped by the 0.065 rubber-band dimension")
    }

    func testOpticalPinchRatioIsMonotonicWhenOpening() {
        let wc = OpticalPinchProbe()
        let a = wc.computeOpticalPinchRatio(accum: 0.0, opening: true)
        let b = wc.computeOpticalPinchRatio(accum: 0.1, opening: true)
        let c = wc.computeOpticalPinchRatio(accum: 0.2, opening: true)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }
}

/// The optical pinch curve now lives on `PinchGestureCoordinator`; with an empty overview (zero-size page/card) it
/// uses the minimum card ratio, which is what these tests pin down.
private struct OpticalPinchProbe {
    let coordinator = PinchGestureCoordinator()
    let overview = TabOverviewView()
    func computeOpticalPinchRatio(accum: CGFloat, opening: Bool) -> CGFloat {
        coordinator.computeOpticalPinchRatio(accum: accum, opening: opening, overview: overview)
    }
}
