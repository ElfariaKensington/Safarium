import XCTest
import AppKit
import QuartzCore
@testable import Safarium

/// Tests for the `PullToRefreshView` display-state model, geometry constants, spinner frame assets and rendering.
@MainActor
final class PullToRefreshTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func makeView(width: CGFloat = 100, height: CGFloat = 52) -> PullToRefreshView {
        let view = PullToRefreshView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.layout()
        return view
    }

    /// The spinner host is the only sublayer the view adds; its mask carries the frame contents.
    private func hostLayer(_ view: PullToRefreshView) -> CALayer {
        guard let host = view.layer?.sublayers?.first else {
            XCTFail("spinner host layer missing")
            return CALayer()
        }
        return host
    }

    // MARK: DisplayState model

    func testHiddenStatesAreEqual() {
        XCTAssertEqual(PullToRefreshView.DisplayState.hidden, .hidden)
    }

    func testPullingStateEqualityUsesBothAssociatedValues() {
        XCTAssertEqual(PullToRefreshView.DisplayState.pulling(progress: 0.5, opacity: 1),
                       .pulling(progress: 0.5, opacity: 1))
        XCTAssertNotEqual(PullToRefreshView.DisplayState.pulling(progress: 0.5, opacity: 1),
                          .pulling(progress: 0.6, opacity: 1))
        XCTAssertNotEqual(PullToRefreshView.DisplayState.pulling(progress: 0.5, opacity: 1),
                          .pulling(progress: 0.5, opacity: 0.9))
    }

    func testSpinningStateDefaultsShiftUpToZero() {
        XCTAssertEqual(PullToRefreshView.DisplayState.spinning(popScale: 1, opacity: 1),
                       .spinning(popScale: 1, opacity: 1, shiftUp: 0))
        XCTAssertNotEqual(PullToRefreshView.DisplayState.spinning(popScale: 1, opacity: 1),
                          .spinning(popScale: 1, opacity: 1, shiftUp: 3))
    }

    func testDifferentCasesAreNeverEqual() {
        XCTAssertNotEqual(PullToRefreshView.DisplayState.hidden, .pulling(progress: 0, opacity: 0))
        XCTAssertNotEqual(PullToRefreshView.DisplayState.pulling(progress: 1, opacity: 1),
                          .spinning(popScale: 1, opacity: 1))
    }

    // MARK: Geometry contract

    func testSpinnerSizeIsTwentyTwoPoints() {
        XCTAssertEqual(PullToRefreshView.spinnerSize, 22)
    }

    func testSpinnerCenterIsThirtyTwoPointsBelowToolbar() {
        XCTAssertEqual(PullToRefreshView.centerOffsetBelowToolbar, 32)
    }

    func testHostLayerIsTwentyTwoPointsAndHiddenInitially() {
        let view = makeView()
        let host = hostLayer(view)
        XCTAssertEqual(host.bounds.size.width, 22, accuracy: 1e-9)
        XCTAssertEqual(host.bounds.size.height, 22, accuracy: 1e-9)
        XCTAssertTrue(host.isHidden)
        XCTAssertEqual(host.opacity, 0)
    }

    func testLayoutCentersSpinnerHorizontallyAndThirtyTwoBelowTopEdge() {
        let view = makeView(width: 100, height: 52)
        let host = hostLayer(view)
        // AppKit non-flipped: y = bounds.height - 32 = 20
        XCTAssertEqual(host.position.x, 50, accuracy: 1e-9)
        XCTAssertEqual(host.position.y, 20, accuracy: 1e-9)
    }

    func testLayoutWithZeroBoundsKeepsPreviousPosition() {
        let view = makeView(width: 0, height: 0)
        let host = hostLayer(view)
        XCTAssertEqual(host.position.x, 0, accuracy: 1e-9)
        XCTAssertEqual(host.position.y, 0, accuracy: 1e-9)
    }

    func testHitTestNeverCapturesPointer() {
        let view = makeView()
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 26)))
    }

    // MARK: Frame assets

    func testSpinnerFramesLoadFromReferenceAssets() throws {
        let dir = AssetLoader.shared.referenceRootURL.appendingPathComponent("Animations/spinner")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "spinner assets not present")
        let view = makeView()
        XCTAssertEqual(view.pullImages.count, 24, "pull-01 ... pull-24")
        XCTAssertEqual(view.spinImages.count, 16, "spin-00 ... spin-15")
        XCTAssertGreaterThan(view.pullImages.first?.width ?? 0, 0)
        XCTAssertGreaterThan(view.spinImages.last?.height ?? 0, 0)
    }

    // MARK: Rendering

    func testRenderHiddenHidesHostAndResetsTransform() {
        let view = makeView()
        view.render(state: .pulling(progress: 0.5, opacity: 1))
        view.render(state: .hidden)
        let host = hostLayer(view)
        XCTAssertTrue(host.isHidden)
        XCTAssertEqual(host.opacity, 0)
        XCTAssertTrue(CATransform3DIsIdentity(host.transform))
    }

    func testRenderPullingShowsHostAtRequestedOpacity() {
        let view = makeView()
        view.render(state: .pulling(progress: 0.5, opacity: 0.6))
        let host = hostLayer(view)
        XCTAssertFalse(host.isHidden)
        XCTAssertEqual(host.opacity, 0.6, accuracy: 1e-6)
    }

    func testRenderPullingBelowVisibleOpacityHidesHost() {
        let view = makeView()
        view.render(state: .pulling(progress: 0.5, opacity: 0.004))
        XCTAssertTrue(hostLayer(view).isHidden)
    }

    func testPullingProgressSelectsMidFrameFromTwentyFourFrames() throws {
        let view = makeView()
        try XCTSkipUnless(view.pullImages.count == 24, "spinner assets not present")
        view.render(state: .pulling(progress: 0.5, opacity: 1))
        let mask = hostLayer(view).mask
        // round(0.5 * 23) = 12
        XCTAssertTrue((mask?.contents as AnyObject?) === (view.pullImages[12] as AnyObject))
    }

    func testPullingProgressIsClampedToFrameRange() throws {
        let view = makeView()
        try XCTSkipUnless(view.pullImages.count == 24, "spinner assets not present")
        let mask = hostLayer(view).mask
        view.render(state: .pulling(progress: 2.0, opacity: 1))
        XCTAssertTrue((mask?.contents as AnyObject?) === (view.pullImages[23] as AnyObject))
        view.render(state: .pulling(progress: -1.0, opacity: 1))
        XCTAssertTrue((mask?.contents as AnyObject?) === (view.pullImages[0] as AnyObject))
    }

    func testSpinningFrameIndexWrapsAroundSixteenFrames() throws {
        let view = makeView()
        try XCTSkipUnless(view.spinImages.count == 16, "spinner assets not present")
        let mask = hostLayer(view).mask
        view.render(state: .spinning(popScale: 1, opacity: 1), spinFrameIndex: 17)
        XCTAssertTrue((mask?.contents as AnyObject?) === (view.spinImages[1] as AnyObject))
        view.render(state: .spinning(popScale: 1, opacity: 1), spinFrameIndex: -1)
        XCTAssertTrue((mask?.contents as AnyObject?) === (view.spinImages[15] as AnyObject))
    }

    func testSpinningAppliesShiftUpAndPopScale() {
        let view = makeView()
        view.render(state: .spinning(popScale: 1, opacity: 1, shiftUp: 10))
        let t = hostLayer(view).transform
        XCTAssertEqual(t.m42, 10, accuracy: 1e-9, "non-flipped superview shifts spinner upward (+Y)")
        XCTAssertEqual(t.m11, 1, accuracy: 1e-9)

        view.render(state: .spinning(popScale: 1.28, opacity: 1, shiftUp: 0))
        let scaled = hostLayer(view).transform
        XCTAssertEqual(scaled.m11, 1.28, accuracy: 1e-9)
        XCTAssertEqual(scaled.m22, 1.28, accuracy: 1e-9)
    }

    func testSpinningPopScaleHasFloorOfOneHundredthOfAPoint() {
        let view = makeView()
        view.render(state: .spinning(popScale: 0, opacity: 1, shiftUp: 0))
        XCTAssertEqual(hostLayer(view).transform.m11, 0.01, accuracy: 1e-9)
    }

    func testSpinningNegativeShiftIsClampedToZero() {
        let view = makeView()
        view.render(state: .spinning(popScale: 1, opacity: 1, shiftUp: -8))
        XCTAssertEqual(hostLayer(view).transform.m42, 0, accuracy: 1e-9)
    }

    func testSpinningOpacityIsClampedToUnitRange() {
        let view = makeView()
        view.render(state: .spinning(popScale: 1, opacity: 3))
        XCTAssertEqual(hostLayer(view).opacity, 1, accuracy: 1e-6)
        view.render(state: .spinning(popScale: 1, opacity: 0.001))
        XCTAssertTrue(hostLayer(view).isHidden)
    }

    func testApplyThemeLightInkUsesNearWhiteSpokes() throws {
        let view = makeView()
        let theme = AdaptiveChromeTheme(sampledColor: .black, relativeLuminance: 0, prefersLightInk: true)
        view.apply(theme: theme)
        let bg = try XCTUnwrap(hostLayer(view).backgroundColor)
        let c = try XCTUnwrap(NSColor(cgColor: bg)?.usingColorSpace(.sRGB))
        XCTAssertEqual(c.redComponent, 0.94, accuracy: 0.005)
        XCTAssertEqual(c.alphaComponent, 0.85, accuracy: 0.005)
    }

    func testApplyThemeDarkInkUsesDarkGreySpokes() throws {
        let view = makeView()
        let theme = AdaptiveChromeTheme(sampledColor: .white, relativeLuminance: 1, prefersLightInk: false)
        view.apply(theme: theme)
        let bg = try XCTUnwrap(hostLayer(view).backgroundColor)
        let c = try XCTUnwrap(NSColor(cgColor: bg)?.usingColorSpace(.sRGB))
        XCTAssertEqual(c.redComponent, 0.36, accuracy: 0.005)
        XCTAssertEqual(c.alphaComponent, 0.88, accuracy: 0.005)
    }
}
