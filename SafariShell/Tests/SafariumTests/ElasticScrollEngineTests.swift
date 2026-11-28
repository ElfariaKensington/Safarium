import XCTest
import AppKit
@testable import Safarium

@MainActor
final class ElasticScrollEngineTests: HermeticTestCase {

    private func makeEngine(
        scrollY: CGFloat = 0,
        contentHeight: CGFloat = 2400,
        viewportHeight: CGFloat = 800,
        canUp: Bool = false,
        canDown: Bool = false,
        reloadable: Bool = true
    ) -> ElasticScrollEngine {
        let engine = ElasticScrollEngine()
        engine.updateMetrics(
            scrollY: scrollY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            canInnerScrollUp: canUp,
            canInnerScrollDown: canDown,
            isReloadableWebPage: reloadable,
            isPageLoading: false
        )
        return engine
    }

    // MARK: - AppKit Elasticity SPI & Hyperbolic Curve

    func testAppKitHyperbolicCoefficientAndRoundTrip() {
        let c = ElasticScrollEngine.AppKitElasticity.defaultHyperbolicCoefficient
        XCTAssertEqual(c, 0.55, accuracy: 0.001)

        for force: CGFloat in [-600, -120, -25, 25, 120, 600] {
            let stretch = ElasticScrollEngine.AppKitElasticity.hyperbolicElasticDelta(
                forReboundDelta: force,
                coefficient: c,
                viewportLength: 800
            )
            XCTAssertLessThan(abs(stretch), 800)
            let reconstructed = ElasticScrollEngine.AppKitElasticity.hyperbolicReboundDelta(
                forElasticDelta: stretch,
                coefficient: c,
                viewportLength: 800
            )
            XCTAssertEqual(reconstructed, force, accuracy: 0.05)
        }
    }

    func testAppKitElasticDeltaForTimeMatchesBounceAndSnapbackShape() {
        // Momentum impact from rest: peaks near t = 80 ms and decays monotonically back to 0.
        let peak = ElasticScrollEngine.AppKitElasticity.elasticDelta(
            initialPosition: 0,
            initialVelocity: 3000,
            elapsedTime: 0.080
        )
        XCTAssertEqual(peak, -27.37, accuracy: 0.25)

        let late = ElasticScrollEngine.AppKitElasticity.elasticDelta(
            initialPosition: 0,
            initialVelocity: 3000,
            elapsedTime: 0.65
        )
        XCTAssertLessThan(abs(late), 0.25)

        // Pure release snapback from 60 pt with zero velocity.
        let mid = ElasticScrollEngine.AppKitElasticity.elasticDelta(
            initialPosition: -60,
            initialVelocity: 0,
            elapsedTime: 0.080
        )
        XCTAssertEqual(mid, -60 * exp(-1.0), accuracy: 0.25)
    }

    // MARK: - PageScrollMetrics & Predictive Estimate

    func testPageScrollMetricsEdgeDetection() {
        let top = ElasticScrollEngine.PageScrollMetrics(scrollY: 0, contentHeight: 2000, viewportHeight: 800)
        XCTAssertTrue(top.isAtTopEdge())
        XCTAssertFalse(top.isAtBottomEdge())
        XCTAssertEqual(top.maxScrollY, 1200)

        let innerUp = ElasticScrollEngine.PageScrollMetrics(
            scrollY: 0, contentHeight: 2000, viewportHeight: 800, canInnerScrollUp: true
        )
        XCTAssertFalse(innerUp.isAtTopEdge())

        let bottom = ElasticScrollEngine.PageScrollMetrics(scrollY: 1200, contentHeight: 2000, viewportHeight: 800)
        XCTAssertTrue(bottom.isAtBottomEdge())
    }

    func testStalePreEventMetricsSyncDoesNotClobberPredictiveEstimate() {
        let engine = makeEngine(scrollY: 300, contentHeight: 2400, viewportHeight: 800)
        // Scroll down by 100 pt (wheel deltaY = -100 -> estimatedScrollY = 400).
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 1.0))
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -100, timestamp: 1.008))
        XCTAssertEqual(engine.estimatedScrollY, 400, accuracy: 0.01)

        // Pre-event sync (`resyncEstimate: false`) passing stale cached scrollY = 300 must keep 400.
        engine.updateMetrics(
            scrollY: 300,
            contentHeight: 2400,
            viewportHeight: 800,
            canInnerScrollUp: false,
            canInnerScrollDown: false,
            isReloadableWebPage: true,
            isPageLoading: false,
            resyncEstimate: false
        )
        XCTAssertEqual(engine.estimatedScrollY, 400, accuracy: 0.01)

        // Fresh renderer telemetry (`resyncEstimate: true`) resyncs estimate.
        engine.updateMetrics(
            scrollY: 396,
            contentHeight: 2400,
            viewportHeight: 800,
            canInnerScrollUp: false,
            canInnerScrollDown: false,
            isReloadableWebPage: true,
            isPageLoading: false,
            resyncEstimate: true
        )
        XCTAssertEqual(engine.estimatedScrollY, 396, accuracy: 0.01)
    }

    // MARK: - Direct-Touch Stretch, 1:1 Unwind, and Release Snapback

    func testTopAndBottomStretchSymmetryAndOneToOneUnwind() {
        let topEngine = makeEngine(scrollY: 0, contentHeight: 2400, viewportHeight: 800)
        XCTAssertFalse(topEngine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 1.0))
        XCTAssertTrue(topEngine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 200, timestamp: 1.008))
        let topPull = topEngine.currentOverscrollY
        XCTAssertGreaterThan(topPull, 10)

        let bottomEngine = makeEngine(scrollY: 1600, contentHeight: 2400, viewportHeight: 800)
        XCTAssertFalse(bottomEngine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 1.0))
        XCTAssertTrue(bottomEngine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -200, timestamp: 1.008))
        XCTAssertEqual(bottomEngine.currentOverscrollY, -topPull, accuracy: 0.01)

        // Partial opposing movement unwinds 1:1 in screen space and stays consumed.
        XCTAssertTrue(topEngine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -6, timestamp: 1.016))
        XCTAssertEqual(topEngine.currentOverscrollY, topPull - 6, accuracy: 0.02)
        XCTAssertNil(topEngine.takeResidualForwardDeltaY())
    }

    func testFingerReleaseSnapsBackCleanlyToZeroAndUsesNonFlippedAppKitSign() {
        let engine = makeEngine(scrollY: 0)
        let stage = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800)) // isFlipped == false
        let view = NSView(frame: stage.bounds)
        stage.addSubview(view)
        let spinner = PullToRefreshView(frame: NSRect(x: 0, y: 0, width: 60, height: 52))
        engine.attach(targetView: view, spinnerView: spinner)

        engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 10.0)
        engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 140, timestamp: 10.008)
        let initial = engine.currentOverscrollY
        XCTAssertGreaterThan(initial, 40)
        // In non-flipped AppKit coordinates (`isFlipped == false`), top pull (`+overscrollY`) MUST translate `-Y` (down)!
        XCTAssertEqual(view.layer!.transform.m42, -initial, accuracy: 0.02)

        engine.handleDirectTouchEvent(phase: .ended, deltaX: 0, deltaY: 0, timestamp: 10.016)
        XCTAssertTrue(engine.isAnimatingRubberBand)

        engine.stepAnimation(at: 10.096)
        XCTAssertGreaterThan(engine.currentOverscrollY, 1)
        XCTAssertLessThan(engine.currentOverscrollY, initial)

        engine.stepAnimation(at: 10.65)
        XCTAssertFalse(engine.isAnimatingRubberBand)
        XCTAssertEqual(engine.currentOverscrollY, 0, accuracy: 0.001)
        XCTAssertTrue(CATransform3DIsIdentity(view.layer!.transform))
    }

    func testPullToRefreshTriggersHoldsAtSixtyEightPointsAndDismissesOnLoadFinish() {
        let engine = makeEngine(scrollY: 0, reloadable: true)
        let stage = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let view = NSView(frame: stage.bounds)
        stage.addSubview(view)
        let spinner = PullToRefreshView(frame: NSRect(x: 0, y: 0, width: 60, height: 52))
        engine.attach(targetView: view, spinnerView: spinner)

        var refreshCount = 0
        engine.onTriggerRefresh = { refreshCount += 1 }

        engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 30.0)
        // Pull past 106 pt threshold on a reloadable page -> triggers reload once!
        engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 260, timestamp: 30.016)
        XCTAssertGreaterThanOrEqual(engine.currentOverscrollY, 106)
        XCTAssertEqual(refreshCount, 1)

        // Release fingers while loading -> settles onto +68 pt hold offset!
        engine.notifyPageLoadingStateChanged(isLoading: true)
        engine.handleDirectTouchEvent(phase: .ended, deltaX: 0, deltaY: 0, timestamp: 30.032)
        engine.stepAnimation(at: 30.65)
        XCTAssertEqual(engine.currentOverscrollY, 68, accuracy: 0.25)

        // Finish loading after minimum 0.40s spin -> smoothly retracts back to 0!
        engine.notifyPageLoadingStateChanged(isLoading: false)
        engine.stepAnimation(at: 30.70)
        engine.stepAnimation(at: 31.35)
        XCTAssertEqual(engine.currentOverscrollY, 0, accuracy: 0.01)
        XCTAssertTrue(CATransform3DIsIdentity(view.layer!.transform))
    }

    // MARK: - Momentum Edge Bounce & Mid-Bounce Catch

    func testMomentumCrossingTopEdgeFlushesExactResidualAndBouncesOnce() {
        let engine = makeEngine(scrollY: 25, contentHeight: 2400, viewportHeight: 800)
        // Crossing from scrollY = 25 with wheel deltaY = +60 -> flushes +25 residual to Chromium and starts bounce!
        let consumedFirst = engine.handleMomentumEvent(momentumPhase: .began, deltaY: 60, timestamp: 20.000)
        XCTAssertFalse(consumedFirst, "crossing frame must forward the exact in-bounds remainder")
        XCTAssertEqual(engine.takeResidualForwardDeltaY() ?? 0, 25, accuracy: 0.01)
        XCTAssertEqual(engine.estimatedScrollY, 0, accuracy: 0.01)
        XCTAssertTrue(engine.isAnimatingRubberBand)

        // Subsequent OS momentum frames are swallowed while rubber-band owns the bounce.
        XCTAssertTrue(engine.handleMomentumEvent(momentumPhase: .changed, deltaY: 55, timestamp: 20.008))
        XCTAssertNil(engine.takeResidualForwardDeltaY())

        // Peaks around t + 80 ms.
        engine.stepAnimation(at: 20.080)
        let peak = engine.currentOverscrollY
        XCTAssertGreaterThan(peak, 40)

        // Touching the trackpad mid-bounce catches the page with zero visual jump!
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 20.088))
        XCTAssertFalse(engine.isAnimatingRubberBand)
        XCTAssertEqual(engine.currentOverscrollY, peak, accuracy: 0.01)

        // Pulling slightly further continues along the hyperbolic curve seamlessly.
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 40, timestamp: 20.096))
        XCTAssertGreaterThan(engine.currentOverscrollY, peak)
    }

    func testInnerScrollerLatchPreventsMidGestureOuterRubberBand() {
        let engine = makeEngine(scrollY: 0, contentHeight: 2400, viewportHeight: 800, canUp: true)
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 5.0))
        // Inner scroller hits its top mid-gesture (`canInnerScrollUp` becomes false).
        engine.updateMetrics(
            scrollY: 0, contentHeight: 2400, viewportHeight: 800,
            canInnerScrollUp: false, canInnerScrollDown: true,
            isReloadableWebPage: true, isPageLoading: false
        )
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 80, timestamp: 5.008))
        XCTAssertEqual(engine.currentOverscrollY, 0, accuracy: 0.001)

        // Starting a fresh gesture now rubber-bands the outer page.
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 5.200))
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 80, timestamp: 5.208))
        XCTAssertGreaterThan(engine.currentOverscrollY, 4)
    }

    func testPredominantHorizontalGestureSuppressesVerticalStretchInitiation() {
        let engine = makeEngine(scrollY: 0)
        engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0, timestamp: 1.0)
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .changed, deltaX: -90, deltaY: 12, timestamp: 1.008))
        XCTAssertEqual(engine.currentOverscrollY, 0, accuracy: 0.001)
    }

    // MARK: - Keyboard Space / Shift+Space Paging

    func testSpaceScrollTravelsExactWebKitPageStepAndEmitsMomentumPhases() {
        let engine = makeEngine(scrollY: 0, contentHeight: 3000, viewportHeight: 800)
        engine.obscuredTopInset = 48 // visible = 752 -> max(752 * 0.875, 752 - 40) = 712 pt
        XCTAssertEqual(engine.pageStepDistance(isStartPage: false), 712, accuracy: 0.01)

        var phases: [ElasticScrollEngine.SyntheticScrollPhase] = []
        var totalWheelDY: CGFloat = 0
        var peakScrollY: CGFloat = 0
        engine.onSyntheticScroll = { dy, phase in
            phases.append(phase)
            totalWheelDY += dy
        }

        let t0: CFTimeInterval = 10.0
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, timestamp: t0)
        XCTAssertTrue(engine.isAnimatingKeyboardScroll)

        var t = t0
        for _ in 0..<140 where engine.isAnimatingKeyboardScroll {
            t += 1.0 / 120.0
            engine.stepAnimation(at: t)
            peakScrollY = max(peakScrollY, engine.estimatedScrollY)
        }

        XCTAssertFalse(engine.isAnimatingKeyboardScroll)
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        // Must genuinely overshoot past 712 pt like a touchpad flick + spring and settle back to exact 712 pt!
        XCTAssertGreaterThan(peakScrollY, 725.0)
        XCTAssertEqual(totalWheelDY, -712, accuracy: 0.5)
        XCTAssertEqual(engine.estimatedScrollY, 712, accuracy: 0.5)
    }

    func testConsecutiveSpacePressesBuildIncreasingMomentum() {
        let engine = makeEngine(scrollY: 0, contentHeight: 16_000, viewportHeight: 800)
        engine.obscuredTopInset = 48 // step = 712 pt

        var t: CFTimeInterval = 20.0
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, timestamp: t)
        let firstVel = engine.currentKeyboardVelocityForTesting
        for _ in 0..<12 {
            t += 1.0 / 120.0
            engine.stepAnimation(at: t)
        }

        // 2nd Space tap mid-glide builds higher momentum chain & velocity than 1st tap
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, timestamp: t)
        let secondVel = engine.currentKeyboardVelocityForTesting
        XCTAssertEqual(engine.currentSpaceMomentumChainForTesting, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(secondVel, firstVel * 1.4)

        for _ in 0..<12 {
            t += 1.0 / 120.0
            engine.stepAnimation(at: t)
        }

        // 3rd Space tap accelerates even further
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, timestamp: t)
        let thirdVel = engine.currentKeyboardVelocityForTesting
        XCTAssertEqual(engine.currentSpaceMomentumChainForTesting, 2.0, accuracy: 0.001)
        XCTAssertGreaterThan(thirdVel, secondVel)

        for _ in 0..<160 where engine.isAnimatingKeyboardScroll {
            t += 1.0 / 120.0
            engine.stepAnimation(at: t)
        }
        // 1.00 + 1.55 + 2.30 = 4.85 pages (> 3.0 pages, proving compounding distance as well as velocity!)
        XCTAssertGreaterThan(engine.estimatedScrollY, 712.0 * 4.5)
    }

    func testHoldingSpaceKeyRepeatAcceleratesMomentumAndCoastsWithOvershootOnRelease() {
        let engine = makeEngine(scrollY: 0, contentHeight: 20_000, viewportHeight: 800)
        engine.obscuredTopInset = 48

        var t: CFTimeInterval = 40.0
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, timestamp: t)

        // Simulate initial 0.30s delay before macOS key-repeat starts
        for _ in 0..<36 {
            t += 1.0 / 120.0
            engine.stepAnimation(at: t)
        }
        engine.triggerSpaceScroll(direction: -1, isRepeat: true, timestamp: t)
        let earlyHoldSpeed = engine.currentKeyboardVelocityForTesting

        // Hold Space for 0.8s (~24 repeat ticks at 30 Hz)
        for rep in 0..<24 {
            for _ in 0..<4 {
                t += 1.0 / 120.0
                engine.stepAnimation(at: t)
            }
            if rep < 23 {
                engine.triggerSpaceScroll(direction: -1, isRepeat: true, timestamp: t)
            }
        }
        let lateHoldSpeed = engine.currentKeyboardVelocityForTesting
        XCTAssertGreaterThan(lateHoldSpeed, earlyHoldSpeed * 1.5, "holding Space must ramp momentum upward")

        let scrollAtRelease = engine.estimatedScrollY
        var peakAfterRelease = scrollAtRelease
        for _ in 0..<150 where engine.isAnimatingKeyboardScroll {
            t += 1.0 / 120.0
            engine.stepAnimation(at: t)
            peakAfterRelease = max(peakAfterRelease, engine.estimatedScrollY)
        }
        let settledScroll = engine.estimatedScrollY
        XCTAssertGreaterThan(settledScroll - scrollAtRelease, 600.0, "releasing Space must coast forward with touchpad inertia")
        XCTAssertGreaterThan(peakAfterRelease, settledScroll + 15.0, "coast must overshoot slightly and cushion back")
    }

    func testSpaceAtPinnedBottomAndTopEdgesProducesRubberBandOvershoot() {
        let bottomEngine = makeEngine(scrollY: 2200, contentHeight: 3000, viewportHeight: 800)
        bottomEngine.triggerSpaceScroll(direction: -1, isRepeat: false, timestamp: 50.0)
        XCTAssertTrue(bottomEngine.isAnimatingRubberBand)
        bottomEngine.stepAnimation(at: 50.080)
        XCTAssertLessThan(bottomEngine.currentOverscrollY, -10.0)

        let topEngine = makeEngine(scrollY: 0, contentHeight: 3000, viewportHeight: 800)
        var triggeredRefresh = false
        topEngine.onTriggerRefresh = { triggeredRefresh = true }
        topEngine.triggerSpaceScroll(direction: 1, isRepeat: false, timestamp: 60.0)
        XCTAssertTrue(topEngine.isAnimatingRubberBand)
        topEngine.stepAnimation(at: 60.080)
        XCTAssertGreaterThan(topEngine.currentOverscrollY, 10.0)
        XCTAssertFalse(triggeredRefresh, "Shift+Space top bounce must never trigger Pull-to-Refresh")
    }

    func testHoldingSpaceStopsRepeatingOnceEdgeIsHit() {
        // Start 900 pt from bottom (`scrollY = 1300`, `maxScrollY = 2200`) and hold Space (`isRepeat = true` every 33ms)
        let engine = makeEngine(scrollY: 1300, contentHeight: 3000, viewportHeight: 800)
        engine.obscuredTopInset = 48

        var t: CFTimeInterval = 100.0
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, timestamp: t)

        var bouncedOnce = false
        // Keep holding Space (`isRepeat: true` every 4 frames = 30 Hz) for a full 1.5 seconds well past hitting bottom!
        for rep in 0..<45 {
            for _ in 0..<4 {
                t += 1.0 / 120.0
                engine.stepAnimation(at: t)
                if engine.isAnimatingRubberBand {
                    bouncedOnce = true
                }
            }
            engine.triggerSpaceScroll(direction: -1, isRepeat: true, timestamp: t)
        }

        XCTAssertTrue(bouncedOnce, "hitting bottom edge must perform its single arrival overshoot bounce")
        XCTAssertEqual(engine.estimatedScrollY, 2200, accuracy: 0.01)
        // Despite still receiving 30 Hz Space repeats at the bottom edge, the bounce must have completely settled
        // instead of repeating/re-triggering at the edge!
        XCTAssertFalse(engine.isAnimatingKeyboardScroll)
        XCTAssertFalse(engine.isAnimatingRubberBand)
        XCTAssertEqual(engine.currentOverscrollY, 0, accuracy: 0.01)

        // Pressing Shift+Space (opposite direction) immediately scrolls back up from the edge
        engine.triggerSpaceScroll(direction: 1, isRepeat: false, timestamp: t + 0.033)
        XCTAssertTrue(engine.isAnimatingKeyboardScroll)
    }

    func testSpaceScrollIntoPinnedEdgeHandsOffToRubberBandBounce() {
        let engine = makeEngine(scrollY: 120, contentHeight: 2400, viewportHeight: 800)
        engine.obscuredTopInset = 48
        var endedCount = 0
        engine.onSyntheticScroll = { _, phase in
            if phase == .ended { endedCount += 1 }
        }

        // Shift+Space (`direction = +1`) from 120 pt hits top edge with remaining velocity and bounces!
        engine.triggerSpaceScroll(direction: 1, isRepeat: false)
        var t = CACurrentMediaTime()
        for _ in 0..<25 where engine.isAnimatingKeyboardScroll {
            t += 1.0 / 120.0
            engine.stepAnimation(at: t)
        }
        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(engine.estimatedScrollY, 0, accuracy: 0.01)
        XCTAssertTrue(engine.isAnimatingRubberBand)

        engine.stepAnimation(at: t + 0.080)
        XCTAssertGreaterThan(engine.currentOverscrollY, 5)
    }

    // MARK: - Middle-Click / TabOpenDisposition Routing

    func testTabOpenDispositionMiddleClickOpensBackgroundTabWhileTargetBlankActivates() throws {
        BrowserSettings.shared.set(false, forKey: BrowserSettings.Key.activateNewTabs)
        BrowserSettings.shared.set(0, forKey: BrowserSettings.Key.openPagesInTabs)

        let wc = SafariWindowController(engine: MockBrowserEngine())
        let win = try XCTUnwrap(wc.window)
        defer { win.close() }
        wc.openInitialTabsIfNeeded()
        spinRunLoop(0.05)

        wc.openURLInActiveOrNewTab(URL(string: "https://example.com")!)
        let initialTab = try XCTUnwrap(t8Tabs(wc).first)
        XCTAssertEqual(t8Tabs(wc).count, 1)
        XCTAssertEqual(t8ActiveIndex(wc), 0)

        // 1. Middle-click (`newBackgroundTab`) opens tab 2 in background without changing activeTabIndex or source URL!
        wc.tabEngine(initialTab, didRequestOpenURL: URL(string: "https://www.iana.org/help/example-domains")!, disposition: .newBackgroundTab)
        XCTAssertEqual(t8Tabs(wc).count, 2)
        XCTAssertEqual(t8ActiveIndex(wc), 0, "middle-click must keep the originating tab active")
        XCTAssertEqual(t8Tabs(wc)[0].currentURL?.absoluteString, "https://example.com")
        XCTAssertEqual(t8Tabs(wc)[1].currentURL?.absoluteString, "https://www.iana.org/help/example-domains")

        // 2. Shift+Middle-click (`newForegroundTab`) opens tab 3 and activates it!
        wc.tabEngine(initialTab, didRequestOpenURL: URL(string: "https://webkit.org")!, disposition: .newForegroundTab)
        XCTAssertEqual(t8Tabs(wc).count, 3)
        XCTAssertEqual(t8ActiveIndex(wc), 2, "Shift+middle-click must activate the new tab")

        // 3. Normal left-click on `target=_blank` (`newTabDefault`) opens tab 4 and activates it!
        wc.selectTab(at: 0)
        wc.tabEngine(initialTab, didRequestOpenURL: URL(string: "https://apple.com")!, disposition: .newTabDefault)
        XCTAssertEqual(t8Tabs(wc).count, 4)
        XCTAssertEqual(t8ActiveIndex(wc), 3)
    }
}
