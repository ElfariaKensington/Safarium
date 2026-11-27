import XCTest
import AppKit
import QuartzCore
@testable import Safarium

/// Unit tests for `ElasticScrollEngine`: page metrics, rubber-band math, pop curve, velocity estimation,
/// clamping and direct-touch / PTR state transitions. No target view is attached, so no CADisplayLink runs.
@MainActor
final class ElasticScrollEngineTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func makeEngine(scrollY: CGFloat = 0, content: CGFloat = 2000, viewport: CGFloat = 800,
                            reloadable: Bool = true, canUp: Bool = false, canDown: Bool = false) -> ElasticScrollEngine {
        let engine = ElasticScrollEngine()
        engine.updateMetrics(
            scrollY: scrollY,
            contentHeight: content,
            viewportHeight: viewport,
            canInnerScrollUp: canUp,
            canInnerScrollDown: canDown,
            isReloadableWebPage: reloadable,
            isPageLoading: false
        )
        return engine
    }

    // MARK: PageScrollMetrics

    func testMaxScrollYIsContentMinusViewport() {
        let m = ElasticScrollEngine.PageScrollMetrics(scrollY: 0, contentHeight: 2000, viewportHeight: 800)
        XCTAssertEqual(m.maxScrollY, 1200, accuracy: 1e-9)
    }

    func testMaxScrollYClampsShortContentToZero() {
        let m = ElasticScrollEngine.PageScrollMetrics(scrollY: 0, contentHeight: 300, viewportHeight: 800)
        XCTAssertEqual(m.maxScrollY, 0)
    }

    func testMaxScrollYIsZeroForEmptyMetrics() {
        let m = ElasticScrollEngine.PageScrollMetrics()
        XCTAssertEqual(m.maxScrollY, 0)
        XCTAssertEqual(m.contentHeight, 0)
        XCTAssertTrue(m.isReloadableWebPage)
        XCTAssertFalse(m.isPageLoading)
    }

    func testMaxScrollYEqualsZeroWhenContentEqualsViewport() {
        let m = ElasticScrollEngine.PageScrollMetrics(scrollY: 0, contentHeight: 800, viewportHeight: 800)
        XCTAssertEqual(m.maxScrollY, 0)
    }

    func testTopBoundaryToleranceIsOneAndAHalfPoints() {
        var m = ElasticScrollEngine.PageScrollMetrics(scrollY: 0, contentHeight: 2000, viewportHeight: 800)
        XCTAssertTrue(m.isAtTopBoundary)
        m.scrollY = 1.5
        XCTAssertTrue(m.isAtTopBoundary)
        m.scrollY = 1.51
        XCTAssertFalse(m.isAtTopBoundary)
    }

    func testTopBoundaryIsFalseWhenInnerScrollCanGoUp() {
        let m = ElasticScrollEngine.PageScrollMetrics(scrollY: 0, contentHeight: 2000, viewportHeight: 800,
                                                      canInnerScrollUp: true)
        XCTAssertFalse(m.isAtTopBoundary)
    }

    func testBottomBoundaryToleranceIsOneAndAHalfPoints() {
        var m = ElasticScrollEngine.PageScrollMetrics(scrollY: 1198.5, contentHeight: 2000, viewportHeight: 800)
        XCTAssertTrue(m.isAtBottomBoundary)
        m.scrollY = 1198.4
        XCTAssertFalse(m.isAtBottomBoundary)
        m.scrollY = 1200
        XCTAssertTrue(m.isAtBottomBoundary)
    }

    func testBottomBoundaryIsFalseWhenInnerScrollCanGoDown() {
        let m = ElasticScrollEngine.PageScrollMetrics(scrollY: 1200, contentHeight: 2000, viewportHeight: 800,
                                                      canInnerScrollDown: true)
        XCTAssertFalse(m.isAtBottomBoundary)
    }

    func testShortContentIsBothTopAndBottomBoundary() {
        let m = ElasticScrollEngine.PageScrollMetrics(scrollY: 0, contentHeight: 300, viewportHeight: 800)
        XCTAssertTrue(m.isAtTopBoundary)
        XCTAssertTrue(m.isAtBottomBoundary)
    }

    // MARK: isOverscrolling threshold

    func testIsOverscrollingUsesStrictFivePercentPointThreshold() {
        let engine = makeEngine()
        XCTAssertFalse(engine.isOverscrolling)
        engine.applyVisualOffset(0.05)
        XCTAssertFalse(engine.isOverscrolling, "exactly 0.05 is not overscrolling")
        engine.applyVisualOffset(0.06)
        XCTAssertTrue(engine.isOverscrolling)
        engine.applyVisualOffset(-0.05)
        XCTAssertFalse(engine.isOverscrolling)
        engine.applyVisualOffset(-0.06)
        XCTAssertTrue(engine.isOverscrolling, "negative overscroll counts by magnitude")
    }

    func testApplyVisualOffsetSnapsTinyValuesToZero() {
        let engine = makeEngine()
        engine.applyVisualOffset(0.004)
        XCTAssertEqual(engine.currentOverscrollY, 0)
        engine.applyVisualOffset(-0.009)
        XCTAssertEqual(engine.currentOverscrollY, 0)
        engine.applyVisualOffset(12.5)
        XCTAssertEqual(engine.currentOverscrollY, 12.5, accuracy: 1e-9)
    }

    // MARK: Pop scale curve

    func testPopScaleIsOneAtStartAndAfterDuration() {
        let engine = makeEngine()
        XCTAssertEqual(engine.computePopScale(elapsed: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(engine.computePopScale(elapsed: 0.155), 1.0, accuracy: 1e-9)
        XCTAssertEqual(engine.computePopScale(elapsed: 0.2), 1.0, accuracy: 1e-9)
    }

    func testPopScalePeaksAtOneTwentyEightAt55ms() {
        let engine = makeEngine()
        XCTAssertEqual(engine.computePopScale(elapsed: 0.055), 1.28, accuracy: 1e-9)
    }

    func testPopScaleRisesWithSineEaseBeforePeak() {
        let engine = makeEngine()
        // u = 0.5 -> sin(pi/4) * 0.28
        XCTAssertEqual(engine.computePopScale(elapsed: 0.0275), 1.0 + 0.28 * sin(Double.pi / 4), accuracy: 1e-9)
    }

    func testPopScaleDecaysWithCosineEaseAfterPeak() {
        let engine = makeEngine()
        // Midway between peak (0.055) and end (0.155): cosine ease gives exactly half the extra scale.
        XCTAssertEqual(engine.computePopScale(elapsed: 0.105), 1.14, accuracy: 1e-9)
    }

    func testPopScaleIsMonotonicUpThenDownAndBounded() {
        let engine = makeEngine()
        var previous = engine.computePopScale(elapsed: 0)
        for i in 1...55 {
            let s = engine.computePopScale(elapsed: Double(i) * 0.001)
            XCTAssertGreaterThanOrEqual(s, previous - 1e-12)
            XCTAssertLessThanOrEqual(s, 1.28 + 1e-9)
            previous = s
        }
        previous = engine.computePopScale(elapsed: 0.055)
        for i in 1...100 {
            let s = engine.computePopScale(elapsed: 0.055 + Double(i) * 0.001)
            XCTAssertLessThanOrEqual(s, previous + 1e-12)
            XCTAssertGreaterThanOrEqual(s, 1.0 - 1e-12)
            previous = s
        }
    }

    func testPopScaleIsContinuousAtDurationEnd() {
        let engine = makeEngine()
        XCTAssertEqual(engine.computePopScale(elapsed: 0.1549), 1.0, accuracy: 0.01)
    }

    // MARK: Rubber-band curve

    func testRubberBandOfZeroIsZero() {
        let engine = makeEngine()
        XCTAssertEqual(engine.rubberBand(raw: 0, dimension: 800), 0)
    }

    func testRubberBandIsSignSymmetric() {
        let engine = makeEngine()
        for raw: CGFloat in [1, 40, 250, 900] {
            XCTAssertEqual(engine.rubberBand(raw: -raw, dimension: 800),
                           -engine.rubberBand(raw: raw, dimension: 800), accuracy: 1e-9)
        }
    }

    func testRubberBandSmallInputMatchesClosedForm() {
        let engine = makeEngine()
        // 0.55 * 1 * 800 / (800 + 0.55)
        XCTAssertEqual(engine.rubberBand(raw: 1, dimension: 800), 440.0 / 800.55, accuracy: 1e-9)
        // 0.55 * 40 * 800 / (800 + 22)
        XCTAssertEqual(engine.rubberBand(raw: 40, dimension: 800), 17600.0 / 822.0, accuracy: 1e-9)
    }

    func testRubberBandIsStrictlyMonotonic() {
        let engine = makeEngine()
        var previous: CGFloat = -1
        for raw in stride(from: CGFloat(0), through: 3000, by: 25) {
            let v = engine.rubberBand(raw: raw, dimension: 800)
            XCTAssertGreaterThanOrEqual(v, previous)
            previous = v
        }
        XCTAssertGreaterThan(engine.rubberBand(raw: 500, dimension: 800), engine.rubberBand(raw: 400, dimension: 800))
    }

    func testRubberBandSaturatesAtMaxStretchFraction() {
        let engine = makeEngine()
        XCTAssertEqual(engine.rubberBand(raw: 1_000_000, dimension: 800), 800 * 0.42, accuracy: 1e-9)
        XCTAssertEqual(engine.rubberBand(raw: -1_000_000, dimension: 800), -800 * 0.42, accuracy: 1e-9)
    }

    func testRubberBandReachesCeilingNearRawOneThousand() {
        let engine = makeEngine()
        // Below the crossover the curve is still under the ceiling; above it the ceiling is flat.
        XCTAssertLessThan(engine.rubberBand(raw: 900, dimension: 800), 336)
        XCTAssertEqual(engine.rubberBand(raw: 1100, dimension: 800), 336, accuracy: 1e-9)
        XCTAssertEqual(engine.rubberBand(raw: 2000, dimension: 800), 336, accuracy: 1e-9)
    }

    // MARK: Inverse rubber-band

    func testInverseRubberBandOfZeroIsZero() {
        let engine = makeEngine()
        XCTAssertEqual(engine.inverseRubberBand(visual: 0, dimension: 800), 0)
    }

    func testInverseRubberBandRoundTripsBelowCap() {
        let engine = makeEngine()
        for raw: CGFloat in [10, 100, 300, 600] {
            let visual = engine.rubberBand(raw: raw, dimension: 800)
            XCTAssertEqual(engine.inverseRubberBand(visual: visual, dimension: 800), raw, accuracy: 1e-6,
                           "round trip failed for raw \(raw)")
        }
    }

    func testInverseRubberBandIsSignSymmetric() {
        let engine = makeEngine()
        XCTAssertEqual(engine.inverseRubberBand(visual: -100, dimension: 800),
                       -engine.inverseRubberBand(visual: 100, dimension: 800), accuracy: 1e-9)
    }

    func testInverseRubberBandCapsVisualAtNinetyEightPercentOfCeiling() {
        let engine = makeEngine()
        let cap: CGFloat = 800 * 0.42 * 0.98
        let atCeiling = engine.inverseRubberBand(visual: 336, dimension: 800)
        let atCap = engine.inverseRubberBand(visual: cap, dimension: 800)
        XCTAssertEqual(atCeiling, atCap, accuracy: 1e-9, "inputs past the cap clamp to the cap")
        XCTAssertEqual(atCap, cap * 800 / (0.55 * (800 - cap)), accuracy: 1e-6)
        XCTAssertTrue(atCap.isFinite)
        XCTAssertGreaterThan(atCap, 1000)
    }

    // MARK: Impact velocity compression

    func testCompressImpactVelocityZeroAndOddSymmetry() {
        let engine = makeEngine()
        XCTAssertEqual(engine.compressImpactVelocity(0), 0)
        XCTAssertEqual(engine.compressImpactVelocity(-13500), -engine.compressImpactVelocity(13500), accuracy: 1e-9)
    }

    func testCompressImpactVelocityMatchesTanhScale() {
        let engine = makeEngine()
        // 5900 * tanh(13500 / 13500) = 5900 * tanh(1)
        XCTAssertEqual(engine.compressImpactVelocity(13500), 5900 * tanh(1.0), accuracy: 1e-6)
        // Small velocities are nearly linear with slope 5900 / 13500.
        XCTAssertEqual(engine.compressImpactVelocity(100), 5900 * tanh(100.0 / 13500.0), accuracy: 1e-9)
    }

    func testCompressImpactVelocitySaturatesAtMaxFlingVelocity() {
        let engine = makeEngine()
        XCTAssertEqual(engine.compressImpactVelocity(1_000_000_000), 5900, accuracy: 1e-6)
        XCTAssertEqual(engine.compressImpactVelocity(-1_000_000_000), -5900, accuracy: 1e-6)
    }

    func testCompressImpactVelocityIsMonotonic() {
        let engine = makeEngine()
        var previous = engine.compressImpactVelocity(-60000)
        for v in stride(from: CGFloat(-55000), through: 60000, by: 5000) {
            let c = engine.compressImpactVelocity(v)
            XCTAssertGreaterThan(c, previous)
            previous = c
        }
    }

    func testCompressImpactVelocityReducesMagnitude() {
        let engine = makeEngine()
        XCTAssertLessThan(engine.compressImpactVelocity(20000), 20000)
        XCTAssertLessThan(abs(engine.compressImpactVelocity(3000)), 3000)
    }

    // MARK: Velocity estimation

    func testBeginSampleGivesMinimumDenominatorVelocity() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.0, isBegin: true)
        XCTAssertEqual(engine.smoothedVelocityY, 10 / 0.028, accuracy: 1e-6)
        XCTAssertEqual(engine.velocitySamples.count, 1)
    }

    func testSpanShorterThanMinimumUsesTwentyEightMilliseconds() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 5, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: 5, timestamp: 1.01, isBegin: false)
        XCTAssertEqual(engine.smoothedVelocityY, 10 / 0.028, accuracy: 1e-6)
    }

    func testSpanLongerThanMinimumUsesRawSpan() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.04, isBegin: false)
        XCTAssertEqual(engine.smoothedVelocityY, 20 / 0.04, accuracy: 1e-6)
    }

    func testSamplesOlderThan48msArePruned() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 100, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.06, isBegin: false)
        XCTAssertEqual(engine.velocitySamples.count, 1)
        XCTAssertEqual(engine.smoothedVelocityY, 10 / 0.028, accuracy: 1e-6, "the 100 pt sample is no longer in the window")
    }

    func testStaleGapResetsWindowBeforeNewSample() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: 5, timestamp: 1.2, isBegin: false)
        XCTAssertEqual(engine.velocitySamples.count, 1)
        XCTAssertEqual(engine.smoothedVelocityY, 5 / 0.028, accuracy: 1e-6)
    }

    func testNegativeDisplacementGivesNegativeVelocity() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: -10, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: -10, timestamp: 1.01, isBegin: false)
        XCTAssertEqual(engine.smoothedVelocityY, -20 / 0.028, accuracy: 1e-6)
    }

    func testOpposingDeltasCancelOut() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: -10, timestamp: 1.01, isBegin: false)
        XCTAssertEqual(engine.smoothedVelocityY, 0, accuracy: 1e-9)
    }

    func testCoalescedOneMillisecondBurstDoesNotSpike() {
        let engine = makeEngine()
        for i in 0..<10 {
            engine.updateVelocityEstimate(deltaY: 1, timestamp: 1.0 + 0.001 * Double(i), isBegin: i == 0)
        }
        // Ten 1 pt events in a 9 ms burst: 10 pt over the 28 ms floor, not 10 pt / 9 ms.
        XCTAssertEqual(engine.smoothedVelocityY, 10 / 0.028, accuracy: 1e-6)
    }

    func testBeginResetsSamplesAndVelocity() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.01, isBegin: false)
        XCTAssertEqual(engine.velocitySamples.count, 2)
        engine.updateVelocityEstimate(deltaY: 0, timestamp: 2.0, isBegin: true)
        XCTAssertEqual(engine.velocitySamples.count, 1)
        XCTAssertEqual(engine.smoothedVelocityY, 0, accuracy: 1e-9)
    }

    func testNonBeginCallKeepsExistingSamples() {
        let engine = makeEngine()
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.0, isBegin: true)
        engine.updateVelocityEstimate(deltaY: 10, timestamp: 1.01, isBegin: false)
        XCTAssertEqual(engine.velocitySamples.count, 2)
    }

    // MARK: Clamp

    func testClampScrollYClampsToZeroAndMaxScroll() {
        let engine = makeEngine(scrollY: 0, content: 2000, viewport: 800)
        XCTAssertEqual(engine.clampScrollY(-5), 0)
        XCTAssertEqual(engine.clampScrollY(0), 0)
        XCTAssertEqual(engine.clampScrollY(600.5), 600.5, accuracy: 1e-9)
        XCTAssertEqual(engine.clampScrollY(1200), 1200)
        XCTAssertEqual(engine.clampScrollY(1300), 1200)
    }

    func testClampScrollYIsZeroWhenPageDoesNotScroll() {
        let engine = makeEngine(content: 300, viewport: 800)
        XCTAssertEqual(engine.clampScrollY(50), 0)
    }

    // MARK: Metrics ingestion and state lifecycle

    func testUpdateMetricsSyncsEstimateAndClampsInputs() {
        let engine = ElasticScrollEngine()
        engine.updateMetrics(scrollY: -10, contentHeight: -5, viewportHeight: 0,
                             canInnerScrollUp: false, canInnerScrollDown: false,
                             isReloadableWebPage: true, isPageLoading: true)
        XCTAssertEqual(engine.metrics.scrollY, 0)
        XCTAssertEqual(engine.metrics.contentHeight, 0)
        XCTAssertEqual(engine.metrics.viewportHeight, 1, "viewport height is floored at one point")
        XCTAssertTrue(engine.metrics.isPageLoading)
        XCTAssertEqual(engine.estimatedScrollY, 0)
    }

    func testUpdateMetricsResyncsEstimatedScroll() {
        let engine = makeEngine(scrollY: 500)
        XCTAssertEqual(engine.estimatedScrollY, 500)
        engine.updateMetrics(scrollY: 730, contentHeight: 2000, viewportHeight: 800,
                             canInnerScrollUp: false, canInnerScrollDown: false,
                             isReloadableWebPage: true, isPageLoading: false)
        XCTAssertEqual(engine.estimatedScrollY, 730)
    }

    func testResetImmediatelyClearsOverscrollAndPTRState() {
        let engine = makeEngine()
        engine.applyVisualOffset(50)
        engine.ptrState = .pulling
        engine.motionState = .directDrag
        engine.momentumLock = .top
        engine.resetImmediately()
        XCTAssertEqual(engine.currentOverscrollY, 0)
        XCTAssertFalse(engine.isOverscrolling)
        XCTAssertEqual(engine.ptrState, .idle)
        XCTAssertEqual(engine.motionState, .idle)
        XCTAssertEqual(engine.momentumLock, .none)
        XCTAssertTrue(engine.velocitySamples.isEmpty)
    }

    func testSetReloadableFalseResetsEngine() {
        let engine = makeEngine()
        engine.applyVisualOffset(40)
        engine.ptrState = .pulling
        engine.setReloadableWebPage(false)
        XCTAssertFalse(engine.metrics.isReloadableWebPage)
        XCTAssertEqual(engine.currentOverscrollY, 0)
        XCTAssertEqual(engine.ptrState, .idle)
    }

    func testSetReloadableTrueKeepsState() {
        let engine = makeEngine()
        engine.applyVisualOffset(40)
        engine.setReloadableWebPage(true)
        XCTAssertEqual(engine.currentOverscrollY, 40, accuracy: 1e-9)
    }

    func testPageLoadFinishedMarksSpinningStateLoaded() {
        let engine = makeEngine()
        engine.ptrState = .spinning(triggeredAt: 5.0, loadFinished: false)
        engine.notifyPageLoadingStateChanged(isLoading: false)
        XCTAssertEqual(engine.ptrState, .spinning(triggeredAt: 5.0, loadFinished: true))
        XCTAssertFalse(engine.metrics.isPageLoading)
    }

    func testPageLoadFinishedIsIgnoredWhenNotSpinning() {
        let engine = makeEngine()
        engine.notifyPageLoadingStateChanged(isLoading: false)
        XCTAssertEqual(engine.ptrState, .idle)
    }

    func testLoadingStartedDoesNotMarkSpinningLoaded() {
        let engine = makeEngine()
        engine.ptrState = .spinning(triggeredAt: 5.0, loadFinished: false)
        engine.notifyPageLoadingStateChanged(isLoading: true)
        XCTAssertEqual(engine.ptrState, .spinning(triggeredAt: 5.0, loadFinished: false))
    }

    func testPullToRefreshDemoStartsOnReloadablePage() {
        let engine = makeEngine(reloadable: true)
        engine.triggerPullToRefreshDemo()
        XCTAssertEqual(engine.ptrState, .pulling)
        guard case .demoPull = engine.motionState else {
            return XCTFail("expected demoPull motion, got \(engine.motionState)")
        }
    }

    func testPullToRefreshDemoIgnoredOnNonReloadablePage() {
        let engine = makeEngine(reloadable: false)
        engine.triggerPullToRefreshDemo()
        XCTAssertEqual(engine.ptrState, .idle)
        XCTAssertEqual(engine.motionState, .idle)
    }

    func testSyntheticFlingBelowMinimumVelocityIsNoOp() {
        let engine = makeEngine()
        engine.triggerSyntheticFlingOvershoot(impactVelocity: 50)
        engine.triggerSyntheticFlingOvershoot(impactVelocity: -109.9)
        XCTAssertEqual(engine.motionState, .idle)
        XCTAssertEqual(engine.momentumLock, .none)
    }

    // MARK: Space-bar inertia

    func testSpaceScrollImpulseFromRestUsesViewportAndDecayRate() {
        let engine = makeEngine(viewport: 800)
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, isStartPage: true)
        // tap = 800 * 0.82 = 656 pt; v0 = -656 * 6.2 = -4067.2
        XCTAssertEqual(engine.spaceVelocityY, -4067.2, accuracy: 0.01)
        XCTAssertTrue(engine.spaceIsStartPage)
    }

    func testRepeatedSpaceTapStacksWithDecayedVelocity() {
        let engine = makeEngine(viewport: 800)
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, isStartPage: false)
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, isStartPage: false)
        XCTAssertEqual(engine.spaceVelocityY, -4067.2 * 0.65 - 4067.2, accuracy: 0.01)
    }

    func testRepeatTapUsesShorterDistance() {
        let engine = makeEngine(viewport: 800)
        engine.triggerSpaceScroll(direction: 1, isRepeat: true, isStartPage: false)
        XCTAssertEqual(engine.spaceVelocityY, 800 * 0.56 * 6.2, accuracy: 0.01)
    }

    func testReversingSpaceDirectionCancelsOpposingInertia() {
        let engine = makeEngine(viewport: 800)
        engine.triggerSpaceScroll(direction: -1, isRepeat: false, isStartPage: false)
        engine.triggerSpaceScroll(direction: 1, isRepeat: false, isStartPage: false)
        XCTAssertEqual(engine.spaceVelocityY, 4067.2, accuracy: 0.01)
    }

    func testSpaceVelocityIsCappedAtEightPointFiveViewports() {
        let engine = makeEngine(viewport: 800)
        for _ in 0..<10 {
            engine.triggerSpaceScroll(direction: 1, isRepeat: false, isStartPage: false)
        }
        XCTAssertLessThanOrEqual(engine.spaceVelocityY, 800 * 8.5 + 1e-6)
    }

    // MARK: Direct touch: rubber band, PTR and hand-off

    func testTopOverscrollRubberBandsWhileDragging() {
        let engine = makeEngine(scrollY: 0)
        let consumed = engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 40)
        XCTAssertTrue(consumed)
        XCTAssertEqual(engine.currentOverscrollY, 17600.0 / 822.0, accuracy: 1e-6)
        guard case .directDrag = engine.motionState else { return XCTFail("expected directDrag") }
        XCTAssertEqual(engine.ptrState, .pulling)
    }

    func testBottomOverscrollRubberBandsNegatively() {
        let engine = makeEngine(scrollY: 1200)
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -40))
        XCTAssertEqual(engine.currentOverscrollY, -17600.0 / 822.0, accuracy: 1e-6)
    }

    func testMidPageDragIsPassedThroughToPageAndTracksEstimate() {
        let engine = makeEngine(scrollY: 500)
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -40))
        XCTAssertEqual(engine.estimatedScrollY, 540, accuracy: 1e-9)
        XCTAssertEqual(engine.currentOverscrollY, 0)
    }

    func testPullPastThresholdTriggersRefreshOnce() {
        let engine = makeEngine(scrollY: 0)
        var triggers = 0
        engine.onTriggerRefresh = { triggers += 1 }
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 300))
        XCTAssertEqual(triggers, 1)
        guard case .spinning(_, let loaded) = engine.ptrState else {
            return XCTFail("expected spinning, got \(engine.ptrState)")
        }
        XCTAssertFalse(loaded)
        _ = engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 20)
        XCTAssertEqual(triggers, 1, "spinning state must not re-trigger")
    }

    func testSmallPullDoesNotTriggerRefresh() {
        let engine = makeEngine(scrollY: 0)
        var triggers = 0
        engine.onTriggerRefresh = { triggers += 1 }
        _ = engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 40)
        XCTAssertEqual(triggers, 0)
        XCTAssertEqual(engine.ptrState, .pulling)
    }

    func testNonReloadablePageNeverEntersPullState() {
        let engine = makeEngine(scrollY: 0, reloadable: false)
        var triggers = 0
        engine.onTriggerRefresh = { triggers += 1 }
        _ = engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 300)
        XCTAssertEqual(triggers, 0)
        XCTAssertEqual(engine.ptrState, .idle)
    }

    func testReleaseWhileDraggingStartsRecoilAndIsConsumed() {
        let engine = makeEngine(scrollY: 0)
        _ = engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 40)
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .ended, deltaX: 0, deltaY: 0))
        if case .directDrag = engine.motionState {
            XCTFail("release must leave directDrag")
        }
    }

    func testReleaseWithoutDragIsNotConsumed() {
        let engine = makeEngine(scrollY: 0)
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .ended, deltaX: 0, deltaY: 0))
    }

    func testBeginAtRestIsNotConsumed() {
        let engine = makeEngine(scrollY: 0)
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0))
        XCTAssertEqual(engine.motionState, .idle)
    }

    func testBeginCatchesMidAirBounceWithoutJump() {
        let engine = makeEngine(scrollY: 0)
        engine.applyVisualOffset(30)
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .began, deltaX: 0, deltaY: 0))
        guard case .directDrag = engine.motionState else { return XCTFail("expected directDrag") }
        // inverse(30, 800) = 30 * 800 / (0.55 * 770)
        XCTAssertEqual(engine.rawStretch, 24000.0 / 423.5, accuracy: 1e-6)
        XCTAssertEqual(engine.currentOverscrollY, 30, accuracy: 1e-9, "catching must not move the page")
    }

    func testHorizontalGestureIsLockedOutOfElasticScroll() {
        let engine = makeEngine(scrollY: 0)
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .changed, deltaX: 10, deltaY: 2))
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 50),
                       "once horizontal, the gesture stays locked")
        XCTAssertEqual(engine.currentOverscrollY, 0)
    }

    func testMildlyDiagonalGestureStaysVertical() {
        let engine = makeEngine(scrollY: 0)
        // |dx| = 10 but |dy| = 9: 10 > 9 * 1.15 is false, so the gesture is vertical.
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .changed, deltaX: 10, deltaY: 9))
    }

    func testDiscreteWheelEventIsIgnored() throws {
        let engine = makeEngine(scrollY: 0)
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else {
            throw XCTSkip("cannot synthesize scroll event")
        }
        XCTAssertFalse(engine.handleScrollWheel(event))
        XCTAssertEqual(engine.currentOverscrollY, 0)
    }

    // MARK: PTR hold unwind and crossover (known defects, see REPORT.md)

    func testUnwindingPTRHoldPastZeroDoesNotOvershootEstimatedScroll() {
        let engine = makeEngine(scrollY: 0)
        engine.ptrState = .spinning(triggeredAt: CACurrentMediaTime(), loadFinished: false)
        engine.motionState = .ptrHolding
        engine.applyVisualOffset(68)

        // A -90 pt wheel-equivalent step: 68 pt unwinds the hold, only 22 pt is page scroll.
        let consumed = engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -90)
        XCTAssertFalse(consumed, "crossing zero hands the event back to the page")
        XCTAssertEqual(engine.currentOverscrollY, 0, accuracy: 1e-9)
        XCTAssertEqual(engine.ptrState, .idle)

        XCTAssertEqual(engine.estimatedScrollY, 22, accuracy: 0.01)
    
    }

    func testRubberBandCrossoverDoesNotCreditResidualToEstimate() {
        let engine = makeEngine(scrollY: 0)
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 30))
        // +30 stretch, then -50: 30 pt unwinds the stretch, 20 pt is residual page scroll.
        let consumed = engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -50)
        XCTAssertFalse(consumed)
        XCTAssertEqual(engine.rawStretch, 0, accuracy: 1e-9)
        XCTAssertEqual(engine.motionState, .idle)

        XCTAssertEqual(engine.estimatedScrollY, 20, accuracy: 0.01)
    
    }

    func testAnimatingMomentumEndWithoutUnwindIsNotConsumed() {
        let engine = makeEngine(scrollY: 0)
        XCTAssertFalse(engine.handleMomentumEvent(momentum: .ended, deltaY: 0))
        XCTAssertEqual(engine.motionState, .idle)
    }
}
