import AppKit
import Darwin
import ObjectiveC.runtime
import QuartzCore

/// macOS 120 Hz root elastic scrolling, Pull-to-Refresh (`NSRefreshController` model), and keyboard
/// `Space` / `Shift+Space` paging controller modeled on Apple WebKit's `WebCore::ScrollingEffectsController`,
/// `WebCore::ScrollAnimationRubberBand`, and `WebCore::KeyboardScrollingAnimator`, backed by AppKit's
/// elasticity SPI. Inner overflow scrollers (`[data-sx-oby]` / `[data-sx-obx]`) report `canInnerScroll`
/// and rubber-band independently on Chromium's 120 Hz compositor (`OverscrollEffectOnNonRootScrollers`).
final class ElasticScrollEngine: NSObject {

    // MARK: - AppKit Elasticity SPI (`NSScrollViewSPI.h`)

    enum AppKitElasticity {
        private typealias HyperbolicFn = @convention(c) (CGFloat, CGFloat, CGFloat) -> CGFloat
        private typealias ElasticTimeFn = @convention(c) (CGFloat, CGFloat, Double) -> CGFloat

        private static let appKitHandle: UnsafeMutableRawPointer? = {
            let path = "/System/Library/Frameworks/AppKit.framework/AppKit"
            return dlopen(path, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(path, RTLD_LAZY)
        }()

        private static let elasticForReboundFn: HyperbolicFn? = {
            guard let h = appKitHandle,
                  let sym = dlsym(h, "_NSHyperbolicElasticDeltaForReboundDelta") else { return nil }
            return unsafeBitCast(sym, to: HyperbolicFn.self)
        }()

        private static let reboundForElasticFn: HyperbolicFn? = {
            guard let h = appKitHandle,
                  let sym = dlsym(h, "_NSHyperbolicReboundDeltaForElasticDelta") else { return nil }
            return unsafeBitCast(sym, to: HyperbolicFn.self)
        }()

        private static let elasticForTimeFn: ElasticTimeFn? = {
            guard let h = appKitHandle,
                  let sym = dlsym(h, "_NSElasticDeltaForTimeDelta") else { return nil }
            return unsafeBitCast(sym, to: ElasticTimeFn.self)
        }()

        /// `NSScrollingBehaviorHyperbolicCoefficientTouch` (`0.55` Safari direct-stretch slope).
        static let defaultHyperbolicCoefficient: CGFloat = {
            if let h = appKitHandle,
               let sym = dlsym(h, "NSScrollingBehaviorHyperbolicCoefficientTouch") {
                let value = sym.assumingMemoryBound(to: CGFloat.self).pointee
                if value.isFinite && value > 0.05 && value <= 1.0 {
                    return value
                }
            }
            return 0.55
        }()

        /// Forward rubber-band curve `_NSHyperbolicElasticDeltaForReboundDelta(force, c, viewportLength)`.
        static func hyperbolicElasticDelta(
            forReboundDelta force: CGFloat,
            coefficient c: CGFloat = defaultHyperbolicCoefficient,
            viewportLength L: CGFloat
        ) -> CGFloat {
            guard force != 0, L > 0, c > 0 else { return 0 }
            if let fn = elasticForReboundFn {
                return fn(force, c, L)
            }
            let mag = abs(force)
            let damped = (c * mag * L) / (L + c * mag)
            return force < 0 ? -damped : damped
        }

        /// Exact inverse `_NSHyperbolicReboundDeltaForElasticDelta(stretch, c, viewportLength)`.
        static func hyperbolicReboundDelta(
            forElasticDelta stretch: CGFloat,
            coefficient c: CGFloat = defaultHyperbolicCoefficient,
            viewportLength L: CGFloat
        ) -> CGFloat {
            guard stretch != 0, L > 0, c > 0 else { return 0 }
            if let fn = reboundForElasticFn {
                return fn(stretch, c, L)
            }
            let clamped = min(abs(stretch), max(0, L - 1.0))
            let denom = c * max(1.0, L - clamped)
            let force = (clamped * L) / denom
            return stretch < 0 ? -force : force
        }

        /// Time-domain bounce & snapback `_NSElasticDeltaForTimeDelta(initialPosition, initialVelocity, elapsedTime)`.
        static func elasticDelta(
            initialPosition: CGFloat,
            initialVelocity: CGFloat,
            elapsedTime: Double
        ) -> CGFloat {
            let t = max(0.0, elapsedTime)
            if let fn = elasticForTimeFn {
                return fn(initialPosition, initialVelocity, t)
            }
            let term = initialPosition - CGFloat(0.31 * Double(initialVelocity) * t)
            return term * CGFloat(Foundation.exp(-12.5 * t))
        }
    }

    // MARK: - Public Types

    enum SyntheticScrollPhase: Equatable {
        case began
        case changed
        case ended
    }

    struct PageScrollMetrics: Equatable {
        var scrollY: CGFloat = 0
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
        var canInnerScrollUp: Bool = false
        var canInnerScrollDown: Bool = false
        var isReloadableWebPage: Bool = false
        var isPageLoading: Bool = false

        var maxScrollY: CGFloat {
            max(0, contentHeight - viewportHeight)
        }

        var isVerticallyScrollable: Bool {
            maxScrollY > 0.5
        }

        func isAtTopEdge(tolerance: CGFloat = 0.5) -> Bool {
            scrollY <= tolerance && !canInnerScrollUp
        }

        func isAtBottomEdge(tolerance: CGFloat = 0.5) -> Bool {
            scrollY >= maxScrollY - tolerance && !canInnerScrollDown
        }
    }

    // MARK: - WebKit & Refresh-Controller Parameters

    private enum Parameters {
        static let velocityZeroingTimeout: TimeInterval = 0.100
        static let velocityWindowDuration: TimeInterval = 0.040
        static let minVelocitySampleDuration: TimeInterval = 1.0 / 120.0
        static let maxMomentumVelocity: CGFloat = 12_000.0
        static let minBounceImpactVelocity: CGFloat = 80.0
        static let axisLockDecayTimeConstant: TimeInterval = 0.120
        static let minViewportLength: CGFloat = 320.0
        static let maxStretchFraction: CGFloat = 0.44
        static let rubberBandMinElapsedBeforeSettle: TimeInterval = 0.024
        static let rubberBandSettleEpsilon: CGFloat = 0.22

        /// WebKit `NSRefreshController` / Safari 27.3 Pull-to-Refresh geometry & timing.
        static let refreshRevealOffset: CGFloat = 26.0
        static let refreshFullOpacityOffset: CGFloat = 52.0
        static let refreshTriggerOffset: CGFloat = 106.0
        static let refreshFlingProgressDenominator: CGFloat = 162.0
        static let refreshHoldOffset: CGFloat = 68.0
        static let refreshFadeHighOffset: CGFloat = 66.0
        static let refreshFadeLowOffset: CGFloat = 22.0
        static let refreshPopDuration: TimeInterval = 0.155
        static let refreshPopPeakTime: TimeInterval = 0.055
        static let refreshPopPeakScale: CGFloat = 1.28
        static let refreshSpinFPS: Double = 20.0
        static let refreshMinSpinDuration: TimeInterval = 0.40
        static let refreshMaxSpinTimeout: TimeInterval = 3.20

        /// WebKit `Scrollbar::pageStep` (`max(visibleH * 0.875, visibleH - 40)`).
        static let pageStepFraction: CGFloat = 0.875
        static let pageStepOverlap: CGFloat = 40.0
        /// Touchpad-style underdamped spring-momentum Space scroll (`zeta = 0.68`, `omega = 15.0` -> ~5.5% overshoot + settle).
        static let keyboardSpringOmega: CGFloat = 15.0
        static let keyboardSpringZeta: CGFloat = 0.68
        static let keyboardLaunchVelocityFactor: CGFloat = 3.2
        static let keyboardMomentumChainWindow: TimeInterval = 0.55
        static let keyboardMaxMomentumChain: CGFloat = 5.0
        static let keyboardMaxQueuedPages: CGFloat = 7.0
        static let keyboardSettleDistanceEpsilon: CGFloat = 0.30
        static let keyboardSettleVelocityEpsilon: CGFloat = 10.0
    }

    // MARK: - Animation & Refresh State (`ScrollAnimationRubberBand` + `NSRefreshController`)

    private struct RubberBandAnimationState {
        var startTime: CFTimeInterval
        var initialStretchY: CGFloat
        var initialScrollVelocityY: CGFloat
        /// WebKit `m_targetOverscroll` (`0` normally, `-68 pt` while Pull-to-Refresh is holding).
        var targetStretchY: CGFloat
    }

    private enum RefreshControlState {
        case hidden
        case pullingDirect
        case pullingMomentum
        case refreshing(triggeredAt: CFTimeInterval, pageLoadObserved: Bool)
        case dismissing(triggeredAt: CFTimeInterval)
    }

    private struct KeyboardGlideState {
        var lastFrameTime: CFTimeInterval
        var scrollSign: CGFloat
        var remainingScrollDeltaY: CGFloat
        var currentScrollVelocityY: CGFloat
        var peakForwardSpeed: CGFloat
        var isStartPage: Bool
        var emittedBegan: Bool
    }

    private struct VelocitySample {
        var timestamp: TimeInterval
        var scrollDeltaY: CGFloat
    }

    // MARK: - Public Callbacks & State

    var obscuredTopInset: CGFloat = 0
    var onTriggerRefresh: (() -> Void)?
    var onSyntheticScroll: ((CGFloat, SyntheticScrollPhase) -> Void)?
    var onElasticInteractionChanged: ((Bool) -> Void)?

    /// Screen-space vertical displacement (`> 0` = top overhang shifting page DOWN, `< 0` = bottom overhang shifting page UP).
    var currentOverscrollY: CGFloat {
        -stretchY
    }

    var isOverscrolling: Bool {
        abs(stretchY) > 0.01
    }

    private(set) var isElasticInteractionActive: Bool = false
    private(set) var metrics = PageScrollMetrics()
    private(set) var estimatedScrollY: CGFloat = 0

    var isAnimatingRubberBand: Bool {
        rubberBandAnimation != nil
    }

    var isAnimatingKeyboardScroll: Bool {
        keyboardGlide != nil
    }

    // MARK: - Private State (`ScrollingEffectsController`)

    private weak var targetView: NSView?
    private weak var spinnerView: PullToRefreshView?
    private var displayLink: CADisplayLink?

    /// WebKit scroll-space overhang (`< 0` = top overhang, `> 0` = bottom overhang).
    private var stretchY: CGFloat = 0
    private var stretchScrollForceY: CGFloat = 0
    private var residualForwardDeltaY: CGFloat?

    private var inScrollGesture: Bool = false
    private var gestureBeganAtTop: Bool = false
    private var momentumScrollInProgress: Bool = false
    private var ignoreMomentumScrolls: Bool = false
    private var gestureLatchedToInnerUp: Bool = false
    private var gestureLatchedToInnerDown: Bool = false

    private var cumulativeGestureDelta: CGPoint = .zero
    private var lastGestureTimestamp: TimeInterval = 0
    private var velocitySamples: [VelocitySample] = []

    private var rubberBandAnimation: RubberBandAnimationState?
    private var refreshState: RefreshControlState = .hidden
    private var keyboardGlide: KeyboardGlideState?
    private var spaceMomentumChain: CGFloat = 0
    private var lastSpaceTriggerTime: CFTimeInterval = 0
    private var lastSpaceScrollSign: CGFloat = 0
    private var spaceRepeatLatchedEdgeSign: CGFloat = 0

    // MARK: - Lifecycle & Attachment

    func attach(targetView: NSView, spinnerView: PullToRefreshView) {
        self.targetView = targetView
        self.spinnerView = spinnerView
        targetView.wantsLayer = true
        spinnerView.render(state: .hidden)
        applyLayerTranslation()
        updateDisplayLinkRunningState()
    }

    func invalidate() {
        cancelKeyboardGlide(emitEnded: false)
        rubberBandAnimation = nil
        refreshState = .hidden
        tearDownDisplayLink()
        stretchY = 0
        stretchScrollForceY = 0
        residualForwardDeltaY = nil
        applyLayerTranslation()
        spinnerView?.render(state: .hidden)
        updateInteractionState()
    }

    func resetImmediately() {
        cancelKeyboardGlide(emitEnded: true)
        rubberBandAnimation = nil
        refreshState = .hidden
        inScrollGesture = false
        gestureBeganAtTop = false
        momentumScrollInProgress = false
        ignoreMomentumScrolls = false
        gestureLatchedToInnerUp = false
        gestureLatchedToInnerDown = false
        cumulativeGestureDelta = .zero
        lastGestureTimestamp = 0
        velocitySamples.removeAll(keepingCapacity: true)
        residualForwardDeltaY = nil
        stretchScrollForceY = 0
        setStretchY(0)
        spinnerView?.render(state: .hidden)
        updateDisplayLinkRunningState()
        updateInteractionState()
    }

    // MARK: - Page Telemetry & Refresh Lifecycle

    func setReloadableWebPage(_ isReloadable: Bool) {
        metrics.isReloadableWebPage = isReloadable
        if !isReloadable {
            refreshState = .hidden
            spinnerView?.render(state: .hidden)
        }
    }

    func notifyPageLoadingStateChanged(isLoading: Bool) {
        metrics.isPageLoading = isLoading
        if case .refreshing(let triggeredAt, _) = refreshState {
            refreshState = .refreshing(triggeredAt: triggeredAt, pageLoadObserved: true)
            updateDisplayLinkRunningState()
        }
    }

    func updateMetrics(
        scrollY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        canInnerScrollUp: Bool,
        canInnerScrollDown: Bool,
        isReloadableWebPage: Bool,
        isPageLoading: Bool,
        resyncEstimate: Bool = true
    ) {
        let clampedViewport = max(0, viewportHeight)
        let clampedContent = max(clampedViewport, contentHeight)
        let maxScroll = max(0, clampedContent - clampedViewport)
        let clampedScrollY = min(max(0, scrollY), maxScroll)

        metrics = PageScrollMetrics(
            scrollY: clampedScrollY,
            contentHeight: clampedContent,
            viewportHeight: clampedViewport,
            canInnerScrollUp: canInnerScrollUp,
            canInnerScrollDown: canInnerScrollDown,
            isReloadableWebPage: isReloadableWebPage,
            isPageLoading: isPageLoading
        )

        if resyncEstimate && keyboardGlide == nil {
            estimatedScrollY = clampedScrollY
        } else {
            estimatedScrollY = min(max(0, estimatedScrollY), maxScroll)
        }
        if spaceRepeatLatchedEdgeSign < 0 && (estimatedScrollY > 1.0 || canInnerScrollUp) {
            spaceRepeatLatchedEdgeSign = 0
        } else if spaceRepeatLatchedEdgeSign > 0 && (estimatedScrollY < maxScroll - 1.0 || canInnerScrollDown) {
            spaceRepeatLatchedEdgeSign = 0
        }
    }

    func takeResidualForwardDeltaY() -> CGFloat? {
        defer { residualForwardDeltaY = nil }
        return residualForwardDeltaY
    }

    // MARK: - Wheel & Gesture Entry Points

    func handleScrollWheel(_ event: NSEvent) -> Bool {
        residualForwardDeltaY = nil

        if MotionPreference.reduced {
            if isOverscrolling || isAnimatingRubberBand || isAnimatingKeyboardScroll {
                resetImmediately()
            }
            if event.hasPreciseScrollingDeltas {
                estimatedScrollY = clampScrollY(estimatedScrollY - event.scrollingDeltaY)
            }
            return false
        }

        let ts = event.timestamp > 0 ? event.timestamp : CACurrentMediaTime()

        if !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty {
            cancelKeyboardGlide(emitEnded: true)
            if !isOverscrolling && !isAnimatingRubberBand {
                estimatedScrollY = clampScrollY(estimatedScrollY - event.scrollingDeltaY)
                return false
            }
        }

        if !event.momentumPhase.isEmpty {
            return handleMomentumEvent(
                momentumPhase: event.momentumPhase,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestamp: ts
            )
        }

        if !event.phase.isEmpty {
            return handleDirectTouchEvent(
                phase: event.phase,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestamp: ts
            )
        }

        estimatedScrollY = clampScrollY(estimatedScrollY - event.scrollingDeltaY)
        return false
    }

    @discardableResult
    func handleDirectTouchEvent(
        phase: NSEvent.Phase,
        deltaX: CGFloat,
        deltaY: CGFloat,
        timestamp: TimeInterval? = nil
    ) -> Bool {
        residualForwardDeltaY = nil

        if MotionPreference.reduced {
            if isOverscrolling || isAnimatingRubberBand {
                resetImmediately()
            }
            estimatedScrollY = clampScrollY(estimatedScrollY - deltaY)
            return false
        }

        let ts = timestamp ?? CACurrentMediaTime()
        let viewportLength = effectiveViewportLength
        let coeff = AppKitElasticity.defaultHyperbolicCoefficient

        if phase == .mayBegin || phase == .began || phase == .changed {
            cancelKeyboardGlide(emitEnded: true)
        }

        if phase == .mayBegin {
            momentumScrollInProgress = false
            ignoreMomentumScrolls = false
            velocitySamples.removeAll(keepingCapacity: true)
            cumulativeGestureDelta = .zero
            lastGestureTimestamp = 0
            gestureLatchedToInnerUp = metrics.canInnerScrollUp
            gestureLatchedToInnerDown = metrics.canInnerScrollDown
            gestureBeganAtTop = estimatedScrollY <= 1.0 && !metrics.canInnerScrollUp

            if isAnimatingRubberBand {
                rubberBandAnimation = nil
                stretchScrollForceY = AppKitElasticity.hyperbolicReboundDelta(
                    forElasticDelta: stretchY,
                    coefficient: coeff,
                    viewportLength: viewportLength
                )
                updateDisplayLinkRunningState()
                updateInteractionState()
                return isOverscrolling
            }
            return false
        }

        if phase == .began {
            inScrollGesture = true
            momentumScrollInProgress = false
            ignoreMomentumScrolls = false
            velocitySamples.removeAll(keepingCapacity: true)
            cumulativeGestureDelta = .zero
            lastGestureTimestamp = 0
            gestureLatchedToInnerUp = metrics.canInnerScrollUp
            gestureLatchedToInnerDown = metrics.canInnerScrollDown
            gestureBeganAtTop = (estimatedScrollY <= 1.0 && !metrics.canInnerScrollUp) || stretchY < -0.5

            rubberBandAnimation = nil
            stretchScrollForceY = AppKitElasticity.hyperbolicReboundDelta(
                forElasticDelta: stretchY,
                coefficient: coeff,
                viewportLength: viewportLength
            )
            updateDisplayLinkRunningState()

            if deltaX == 0 && deltaY == 0 {
                updateInteractionState()
                return isOverscrolling
            }
        }

        if phase == .ended || phase == .cancelled {
            inScrollGesture = false
            cumulativeGestureDelta = .zero
            lastGestureTimestamp = 0

            let targetStretch = activeRefreshTargetStretchY
            if abs(stretchY - targetStretch) > 0.01 || targetStretch != 0 {
                startRubberBandAnimation(
                    initialScrollVelocityY: 0,
                    initialStretchY: stretchY,
                    targetStretchY: targetStretch,
                    now: ts
                )
            } else {
                stretchScrollForceY = 0
                setStretchY(0)
                if case .pullingDirect = refreshState { refreshState = .hidden }
                if case .pullingMomentum = refreshState { refreshState = .hidden }
            }
            updateSpinnerPresentation(now: ts)
            updateDisplayLinkRunningState()
            updateInteractionState()
            return isOverscrolling || isAnimatingRubberBand
        }

        if phase == .stationary {
            return isOverscrolling
        }

        inScrollGesture = true
        if rubberBandAnimation != nil {
            rubberBandAnimation = nil
            stretchScrollForceY = AppKitElasticity.hyperbolicReboundDelta(
                forElasticDelta: stretchY,
                coefficient: coeff,
                viewportLength: viewportLength
            )
            updateDisplayLinkRunningState()
        }

        let scrollDX = -deltaX
        let scrollDY = -deltaY
        recordVelocitySample(scrollDeltaY: scrollDY, timestamp: ts)

        let dominantVertical = updatePredominantGestureAxisIsVertical(
            scrollDX: scrollDX,
            scrollDY: scrollDY,
            timestamp: ts
        )
        if !isOverscrolling && !dominantVertical {
            return false
        }

        guard scrollDY != 0 else {
            return isOverscrolling
        }

        let consumed = applyGestureScrollDeltaY(scrollDY, viewportLength: viewportLength, coefficient: coeff, now: ts)
        logWheelStepIfEnabled(phase: phase.rawValue, momentumPhase: 0, wheelDY: deltaY)
        updateSpinnerPresentation(now: ts)
        updateDisplayLinkRunningState()
        updateInteractionState()
        return consumed
    }

    @discardableResult
    func handleMomentumEvent(
        momentumPhase: NSEvent.Phase,
        deltaX: CGFloat = 0,
        deltaY: CGFloat,
        timestamp: TimeInterval? = nil
    ) -> Bool {
        residualForwardDeltaY = nil
        _ = deltaX

        if MotionPreference.reduced {
            estimatedScrollY = clampScrollY(estimatedScrollY - deltaY)
            return false
        }

        let ts = timestamp ?? CACurrentMediaTime()

        if ignoreMomentumScrolls {
            if momentumPhase == .ended || momentumPhase == .cancelled {
                ignoreMomentumScrolls = false
                momentumScrollInProgress = false
                velocitySamples.removeAll(keepingCapacity: true)
            }
            return true
        }

        if momentumPhase == .ended || momentumPhase == .cancelled {
            momentumScrollInProgress = false
            ignoreMomentumScrolls = false
            velocitySamples.removeAll(keepingCapacity: true)
            let targetStretch = activeRefreshTargetStretchY
            if abs(stretchY - targetStretch) > 0.01 && !isAnimatingRubberBand {
                startRubberBandAnimation(
                    initialScrollVelocityY: 0,
                    initialStretchY: stretchY,
                    targetStretchY: targetStretch,
                    now: ts
                )
            }
            updateSpinnerPresentation(now: ts)
            updateDisplayLinkRunningState()
            updateInteractionState()
            return isOverscrolling || isAnimatingRubberBand
        }

        momentumScrollInProgress = true
        let scrollDY = -deltaY
        recordVelocitySample(scrollDeltaY: scrollDY, timestamp: ts)
        let scrollVelY = currentScrollVelocityY(fallbackScrollDeltaY: scrollDY)

        guard scrollDY != 0 else {
            return isOverscrolling || isAnimatingRubberBand
        }

        // 1. Already overhanging (e.g., unwinding Pull-to-Refresh hold or flicking while stretched):
        if abs(stretchY) > 0.01 {
            let opposesStretch = (stretchY < 0 && scrollDY > 0) || (stretchY > 0 && scrollDY < 0)
            if opposesStretch {
                rubberBandAnimation = nil
                let remainingStretch = stretchY + scrollDY
                let crossedZero = (stretchY < 0 && remainingStretch >= 0) || (stretchY > 0 && remainingStretch <= 0)
                if !crossedZero {
                    stretchScrollForceY = AppKitElasticity.hyperbolicReboundDelta(
                        forElasticDelta: remainingStretch,
                        coefficient: AppKitElasticity.defaultHyperbolicCoefficient,
                        viewportLength: effectiveViewportLength
                    )
                    setStretchY(remainingStretch)
                    updateSpinnerPresentation(now: ts)
                    updateDisplayLinkRunningState()
                    updateInteractionState()
                    return true
                }

                // Crossed zero: clear any active refresh hold cleanly and forward remainder into page scroll.
                refreshState = .hidden
                spinnerView?.render(state: .hidden)
                setStretchY(0)
                stretchScrollForceY = 0

                if !metrics.isVerticallyScrollable && canStretchInScrollDirection(remainingStretch) {
                    ignoreMomentumScrolls = true
                    momentumScrollInProgress = false
                    startRubberBandAnimation(
                        initialScrollVelocityY: scrollVelY,
                        initialStretchY: 0,
                        targetStretchY: 0,
                        now: ts
                    )
                    updateDisplayLinkRunningState()
                    updateInteractionState()
                    return true
                }
                if abs(remainingStretch) > 0.001 {
                    residualForwardDeltaY = -remainingStretch
                    estimatedScrollY = clampScrollY(estimatedScrollY + remainingStretch)
                }
                updateDisplayLinkRunningState()
                updateInteractionState()
                return false
            } else {
                ignoreMomentumScrolls = true
                momentumScrollInProgress = false
                if stretchY < 0 && metrics.isReloadableWebPage, case .hidden = refreshState {
                    refreshState = .pullingMomentum
                }
                startRubberBandAnimation(
                    initialScrollVelocityY: scrollVelY,
                    initialStretchY: stretchY,
                    targetStretchY: activeRefreshTargetStretchY,
                    now: ts
                )
                updateSpinnerPresentation(now: ts)
                updateDisplayLinkRunningState()
                updateInteractionState()
                return true
            }
        }

        // 2. In-bounds momentum scrolling toward top or bottom edge.
        if !canStretchInScrollDirection(scrollDY) {
            estimatedScrollY = clampScrollY(estimatedScrollY + scrollDY)
            return false
        }

        if scrollDY < 0 {
            if estimatedScrollY <= 0.5 {
                estimatedScrollY = 0
                ignoreMomentumScrolls = true
                momentumScrollInProgress = false
                if abs(scrollVelY) >= Parameters.minBounceImpactVelocity {
                    if metrics.isReloadableWebPage, case .hidden = refreshState {
                        refreshState = .pullingMomentum
                    }
                    startRubberBandAnimation(
                        initialScrollVelocityY: scrollVelY,
                        initialStretchY: 0,
                        targetStretchY: activeRefreshTargetStretchY,
                        now: ts
                    )
                }
                logWheelStepIfEnabled(phase: 0, momentumPhase: momentumPhase.rawValue, wheelDY: deltaY)
                updateSpinnerPresentation(now: ts)
                updateDisplayLinkRunningState()
                updateInteractionState()
                return true
            }
            if estimatedScrollY + scrollDY < 0 {
                let toEdgeScrollDY = -estimatedScrollY
                estimatedScrollY = 0
                residualForwardDeltaY = -toEdgeScrollDY
                ignoreMomentumScrolls = true
                momentumScrollInProgress = false
                if abs(scrollVelY) >= Parameters.minBounceImpactVelocity {
                    if metrics.isReloadableWebPage, case .hidden = refreshState {
                        refreshState = .pullingMomentum
                    }
                    startRubberBandAnimation(
                        initialScrollVelocityY: scrollVelY,
                        initialStretchY: 0,
                        targetStretchY: activeRefreshTargetStretchY,
                        now: ts
                    )
                }
                logWheelStepIfEnabled(phase: 0, momentumPhase: momentumPhase.rawValue, wheelDY: deltaY)
                updateSpinnerPresentation(now: ts)
                updateDisplayLinkRunningState()
                updateInteractionState()
                return false
            }
            estimatedScrollY = clampScrollY(estimatedScrollY + scrollDY)
            logWheelStepIfEnabled(phase: 0, momentumPhase: momentumPhase.rawValue, wheelDY: deltaY)
            return false
        } else {
            let maxY = metrics.maxScrollY
            if estimatedScrollY >= maxY - 0.5 {
                estimatedScrollY = maxY
                ignoreMomentumScrolls = true
                momentumScrollInProgress = false
                if abs(scrollVelY) >= Parameters.minBounceImpactVelocity {
                    startRubberBandAnimation(
                        initialScrollVelocityY: scrollVelY,
                        initialStretchY: 0,
                        targetStretchY: 0,
                        now: ts
                    )
                }
                logWheelStepIfEnabled(phase: 0, momentumPhase: momentumPhase.rawValue, wheelDY: deltaY)
                updateDisplayLinkRunningState()
                updateInteractionState()
                return true
            }
            if estimatedScrollY + scrollDY > maxY {
                let toEdgeScrollDY = maxY - estimatedScrollY
                estimatedScrollY = maxY
                residualForwardDeltaY = -toEdgeScrollDY
                ignoreMomentumScrolls = true
                momentumScrollInProgress = false
                if abs(scrollVelY) >= Parameters.minBounceImpactVelocity {
                    startRubberBandAnimation(
                        initialScrollVelocityY: scrollVelY,
                        initialStretchY: 0,
                        targetStretchY: 0,
                        now: ts
                    )
                }
                logWheelStepIfEnabled(phase: 0, momentumPhase: momentumPhase.rawValue, wheelDY: deltaY)
                updateDisplayLinkRunningState()
                updateInteractionState()
                return false
            }
            estimatedScrollY = clampScrollY(estimatedScrollY + scrollDY)
            logWheelStepIfEnabled(phase: 0, momentumPhase: momentumPhase.rawValue, wheelDY: deltaY)
            return false
        }
    }

    // MARK: - Keyboard `Space` / `Shift+Space` Paging (`KeyboardScrollingAnimator` + Touchpad Spring & Momentum)

    var currentSpaceMomentumChainForTesting: CGFloat { spaceMomentumChain }
    var currentKeyboardVelocityForTesting: CGFloat { keyboardGlide?.currentScrollVelocityY ?? 0 }

    func triggerSpaceScroll(
        direction: Int,
        isRepeat: Bool,
        isStartPage: Bool = false,
        timestamp: CFTimeInterval? = nil
    ) {
        guard direction != 0 else { return }
        let scrollSign: CGFloat = direction < 0 ? 1.0 : -1.0 // +1 = down, -1 = up
        let step = pageStepDistance(isStartPage: isStartPage)
        guard step > 0 else { return }

        if MotionPreference.reduced {
            cancelKeyboardGlide(emitEnded: true)
            let wheelStep = -scrollSign * step
            onSyntheticScroll?(0, .began)
            onSyntheticScroll?(wheelStep, .changed)
            onSyntheticScroll?(0, .ended)
            if !isStartPage {
                estimatedScrollY = clampScrollY(estimatedScrollY + scrollSign * step)
            }
            return
        }

        let pinnedAtTop = !isStartPage && scrollSign < 0 && estimatedScrollY <= 0.5 && !metrics.canInnerScrollUp
        let pinnedAtBottom = !isStartPage && scrollSign > 0 && estimatedScrollY >= metrics.maxScrollY - 0.5 && !metrics.canInnerScrollDown

        // Once Space hits a top/bottom edge, stop key-repeat completely so holding Space never keeps
        // re-bouncing or pumping the rubber-band animation at the boundary.
        if isRepeat {
            if spaceRepeatLatchedEdgeSign == scrollSign
                || isAnimatingRubberBand
                || isOverscrolling
                || (keyboardGlide == nil && (pinnedAtTop || pinnedAtBottom)) {
                return
            }
        } else if spaceRepeatLatchedEdgeSign != scrollSign {
            spaceRepeatLatchedEdgeSign = 0
        }

        let now = timestamp ?? CACurrentMediaTime()
        let gap = lastSpaceTriggerTime > 0 ? max(0, now - lastSpaceTriggerTime) : .infinity
        let sameDirection = (lastSpaceScrollSign == scrollSign)
        let continuesChain = sameDirection
            && (keyboardGlide != nil || isAnimatingRubberBand || gap < Parameters.keyboardMomentumChainWindow)

        if !continuesChain {
            spaceMomentumChain = 0
        } else if isRepeat {
            let dtRepeat = min(max(gap.isFinite ? gap : 0.033, 0.016), 0.120)
            spaceMomentumChain = min(
                Parameters.keyboardMaxMomentumChain,
                spaceMomentumChain + CGFloat(dtRepeat) * 2.4
            )
        } else {
            spaceMomentumChain = min(Parameters.keyboardMaxMomentumChain, spaceMomentumChain + 1.0)
        }
        lastSpaceTriggerTime = now
        lastSpaceScrollSign = scrollSign

        // Explicit non-repeat tap when already pinned at top/bottom edge: do one clean bounce (unless already
        // bouncing in that direction) and latch edge-repeat suppression so holding from here won't repeat.
        if !isStartPage && keyboardGlide == nil && (pinnedAtTop || pinnedAtBottom) {
            spaceRepeatLatchedEdgeSign = scrollSign
            let alreadyBouncingSameWay = (scrollSign < 0 && stretchY < -0.5) || (scrollSign > 0 && stretchY > 0.5)
            guard !alreadyBouncingSameWay else { return }
            refreshState = .hidden
            spinnerView?.render(state: .hidden)
            let impactSpeed = min(
                Parameters.maxMomentumVelocity,
                max(1_650.0, step * 2.4)
            )
            startRubberBandAnimation(
                initialScrollVelocityY: scrollSign * impactSpeed,
                initialStretchY: stretchY,
                targetStretchY: 0,
                now: now
            )
            updateDisplayLinkRunningState()
            updateInteractionState()
            return
        }

        if rubberBandAnimation != nil || isOverscrolling {
            rubberBandAnimation = nil
            refreshState = .hidden
            spinnerView?.render(state: .hidden)
            stretchScrollForceY = 0
            setStretchY(0)
        }

        let signedStep = scrollSign * step

        if var active = keyboardGlide {
            if active.scrollSign == scrollSign {
                if isRepeat {
                    let dtRepeat = CGFloat(min(max(gap.isFinite ? gap : 0.033, 0.016), 0.120))
                    let accelGain = 1.0 + 0.70 * spaceMomentumChain + 0.16 * spaceMomentumChain * spaceMomentumChain
                    let targetCruiseSpeed = min(
                        Parameters.maxMomentumVelocity,
                        step * (2.8 + 1.45 * spaceMomentumChain)
                    )
                    let holdImpulse = signedStep * dtRepeat * 2.5 * accelGain
                    let minCoastLead = targetCruiseSpeed / 3.8
                    let maxHoldLead = max(minCoastLead, step * (1.35 + 0.85 * spaceMomentumChain))
                    let advancedMag = max(abs(active.remainingScrollDeltaY + holdImpulse), minCoastLead)
                    active.remainingScrollDeltaY = scrollSign * min(advancedMag, maxHoldLead)

                    if scrollSign * active.currentScrollVelocityY < targetCruiseSpeed {
                        active.currentScrollVelocityY = scrollSign * targetCruiseSpeed
                    }
                } else {
                    let tapGain = 1.0 + 0.45 * spaceMomentumChain + 0.10 * spaceMomentumChain * spaceMomentumChain
                    let maxQueued = step * Parameters.keyboardMaxQueuedPages
                    let combined = active.remainingScrollDeltaY + signedStep * tapGain
                    active.remainingScrollDeltaY = scrollSign * min(abs(combined), maxQueued)

                    let velKick = signedStep * (2.6 + 0.90 * spaceMomentumChain)
                    let boostedVel = active.currentScrollVelocityY + velKick
                    active.currentScrollVelocityY = min(
                        max(boostedVel, -Parameters.maxMomentumVelocity),
                        Parameters.maxMomentumVelocity
                    )
                }
            } else {
                // Reversing direction mid-glide resets momentum and smoothly redirects in one continuous stream.
                active.scrollSign = scrollSign
                active.remainingScrollDeltaY = signedStep
                active.currentScrollVelocityY = signedStep * Parameters.keyboardLaunchVelocityFactor
                active.peakForwardSpeed = abs(active.currentScrollVelocityY)
            }
            active.isStartPage = isStartPage
            active.peakForwardSpeed = max(active.peakForwardSpeed, abs(active.currentScrollVelocityY))
            keyboardGlide = active
        } else {
            let tapGain: CGFloat = continuesChain
                ? (1.0 + 0.45 * spaceMomentumChain + 0.10 * spaceMomentumChain * spaceMomentumChain)
                : 1.0
            let launchDelta = signedStep * tapGain
            let launchVel = min(
                max(
                    signedStep * (Parameters.keyboardLaunchVelocityFactor + 0.90 * spaceMomentumChain),
                    -Parameters.maxMomentumVelocity
                ),
                Parameters.maxMomentumVelocity
            )
            keyboardGlide = KeyboardGlideState(
                lastFrameTime: now,
                scrollSign: scrollSign,
                remainingScrollDeltaY: launchDelta,
                currentScrollVelocityY: launchVel,
                peakForwardSpeed: abs(launchVel),
                isStartPage: isStartPage,
                emittedBegan: false
            )
        }

        updateDisplayLinkRunningState()
        updateInteractionState()
    }

    func pageStepDistance(isStartPage: Bool) -> CGFloat {
        let inset = isStartPage ? 0 : max(0, obscuredTopInset)
        let visibleHeight = max(1.0, effectiveViewportLength - inset)
        return max(1.0, max(visibleHeight * Parameters.pageStepFraction, visibleHeight - Parameters.pageStepOverlap))
    }

    // MARK: - Deterministic 120 Hz Frame Step (`ScrollAnimationRubberBand` + `NSRefreshController`)

    func stepAnimation(at timestamp: CFTimeInterval) {
        // Check Pull-to-Refresh spin completion / safety timeout (`0.40s` min spin, `3.20s` max timeout).
        if case .refreshing(let triggeredAt, let observed) = refreshState {
            let spinElapsed = max(0, timestamp - triggeredAt)
            let finishedNormally = observed && !metrics.isPageLoading && spinElapsed >= Parameters.refreshMinSpinDuration
            let timedOut = spinElapsed >= Parameters.refreshMaxSpinTimeout
            if finishedNormally || timedOut {
                transitionRefreshToDismissing(now: timestamp, triggeredAt: triggeredAt)
            }
        }

        if let rb = rubberBandAnimation {
            let elapsed = max(0.0, timestamp - rb.startTime)
            // WebKit `ScrollAnimationRubberBand.mm`:
            // `relativeInitial = initialOverscroll - targetOverscroll`
            // `offset = elasticDeltaForTimeDelta(relativeInitial, -initialVelocity, elapsed) + targetOverscroll`
            let relativeInitial = rb.initialStretchY - rb.targetStretchY
            let relativeStretch = AppKitElasticity.elasticDelta(
                initialPosition: relativeInitial,
                initialVelocity: -rb.initialScrollVelocityY,
                elapsedTime: elapsed
            )
            let nextStretch = relativeStretch + rb.targetStretchY

            let settled = elapsed > Parameters.rubberBandMinElapsedBeforeSettle
                && abs(relativeStretch) < Parameters.rubberBandSettleEpsilon

            if settled {
                rubberBandAnimation = nil
                setStretchY(rb.targetStretchY)
                stretchScrollForceY = AppKitElasticity.hyperbolicReboundDelta(
                    forElasticDelta: rb.targetStretchY,
                    coefficient: AppKitElasticity.defaultHyperbolicCoefficient,
                    viewportLength: effectiveViewportLength
                )
                if rb.targetStretchY == 0 {
                    refreshState = .hidden
                    spinnerView?.render(state: .hidden)
                }
            } else {
                setStretchY(nextStretch)
            }

            if ScrollDebugLog.isEnabled {
                ScrollDebugLog.write(String(
                    format: "anim step t=%.3f v=0 sy=%.1f est=%.1f ov=%.1f",
                    elapsed, metrics.scrollY, estimatedScrollY, currentOverscrollY
                ))
            }
        }

        if var glide = keyboardGlide {
            let rawDt = timestamp - glide.lastFrameTime
            let dt = min(max(rawDt > 0 ? rawDt : (1.0 / 120.0), 1.0 / 240.0), 0.050)
            glide.lastFrameTime = timestamp

            // Exact closed-form underdamped spring-damper step (`e = -remainingScrollDeltaY`, `v = currentScrollVelocityY`):
            // accelerates smoothly like a touchpad flick, overshoots target slightly (~5.5%), and cushions back to 0.
            let omega = Double(Parameters.keyboardSpringOmega)
            let zeta = Double(Parameters.keyboardSpringZeta)
            let zetaOmega = zeta * omega
            let omegaD = omega * Foundation.sqrt(max(1e-6, 1.0 - zeta * zeta))

            let e0 = -Double(glide.remainingScrollDeltaY)
            let v0 = Double(glide.currentScrollVelocityY)
            let a = e0
            let b = (v0 + zetaOmega * e0) / omegaD
            let env = Foundation.exp(-zetaOmega * dt)
            let c = Foundation.cos(omegaD * dt)
            let s = Foundation.sin(omegaD * dt)

            let e1 = env * (a * c + b * s)
            let v1 = env * ((b * omegaD - zetaOmega * a) * c - (a * omegaD + zetaOmega * b) * s)

            var stepScrollDY = CGFloat(e1 - e0)
            let newRemaining = CGFloat(-e1)
            let instantVelY = CGFloat(v1)
            glide.remainingScrollDeltaY = newRemaining
            glide.currentScrollVelocityY = instantVelY
            if glide.scrollSign * instantVelY > 0 {
                glide.peakForwardSpeed = max(glide.peakForwardSpeed, abs(instantVelY))
            }

            let phase: SyntheticScrollPhase = glide.emittedBegan ? .changed : .began
            glide.emittedBegan = true

            var hitPinnedEdge = false
            if !glide.isStartPage {
                if stepScrollDY < 0 && !metrics.canInnerScrollUp && estimatedScrollY + stepScrollDY <= 0 {
                    stepScrollDY = -estimatedScrollY
                    estimatedScrollY = 0
                    hitPinnedEdge = (glide.scrollSign < 0)
                } else if stepScrollDY > 0 && !metrics.canInnerScrollDown && estimatedScrollY + stepScrollDY >= metrics.maxScrollY {
                    stepScrollDY = metrics.maxScrollY - estimatedScrollY
                    estimatedScrollY = metrics.maxScrollY
                    hitPinnedEdge = (glide.scrollSign > 0)
                } else {
                    estimatedScrollY = clampScrollY(estimatedScrollY + stepScrollDY)
                }
            }

            let settled = abs(glide.remainingScrollDeltaY) <= Parameters.keyboardSettleDistanceEpsilon
                && abs(instantVelY) <= Parameters.keyboardSettleVelocityEpsilon

            if hitPinnedEdge {
                if abs(stepScrollDY) > 0.001 || phase == .began {
                    onSyntheticScroll?(-stepScrollDY, phase)
                }
                onSyntheticScroll?(0, .ended)
                keyboardGlide = nil
                spaceRepeatLatchedEdgeSign = glide.scrollSign
                spaceMomentumChain = 0
                let minEdgeImpact = min(2_200.0, glide.peakForwardSpeed * 0.34)
                let impactSpeed = max(abs(instantVelY), minEdgeImpact)
                if impactSpeed >= Parameters.minBounceImpactVelocity {
                    startRubberBandAnimation(
                        initialScrollVelocityY: glide.scrollSign * impactSpeed,
                        initialStretchY: 0,
                        targetStretchY: 0,
                        now: timestamp
                    )
                }
            } else if settled {
                let finalStep = stepScrollDY + glide.remainingScrollDeltaY
                if !glide.isStartPage {
                    estimatedScrollY = clampScrollY(estimatedScrollY + glide.remainingScrollDeltaY)
                }
                if abs(finalStep) > 0.001 || phase == .began {
                    onSyntheticScroll?(-finalStep, phase)
                }
                onSyntheticScroll?(0, .ended)
                keyboardGlide = nil
            } else {
                onSyntheticScroll?(-stepScrollDY, phase)
                keyboardGlide = glide
            }
        }

        updateSpinnerPresentation(now: timestamp)
        updateDisplayLinkRunningState()
        updateInteractionState()
    }

    // MARK: - Internal Stretch & Refresh Helpers

    private var effectiveViewportLength: CGFloat {
        if metrics.viewportHeight > 1 {
            return max(Parameters.minViewportLength, metrics.viewportHeight)
        }
        if let viewH = targetView?.bounds.height, viewH > 1 {
            return max(Parameters.minViewportLength, viewH)
        }
        return 800.0
    }

    private var activeRefreshTargetStretchY: CGFloat {
        if case .refreshing = refreshState {
            return -Parameters.refreshHoldOffset
        }
        return 0
    }

    private var isRefreshingSpinnerActive: Bool {
        switch refreshState {
        case .refreshing, .dismissing:
            return true
        case .hidden, .pullingDirect, .pullingMomentum:
            return false
        }
    }

    private func clampScrollY(_ value: CGFloat) -> CGFloat {
        min(max(0, value), metrics.maxScrollY)
    }

    private func canStretchInScrollDirection(_ scrollDY: CGFloat) -> Bool {
        if scrollDY < 0 {
            return !metrics.canInnerScrollUp && !gestureLatchedToInnerUp
        }
        if scrollDY > 0 {
            return !metrics.canInnerScrollDown && !gestureLatchedToInnerDown
        }
        return false
    }

    private func clampStretch(_ stretch: CGFloat, viewportLength: CGFloat) -> CGFloat {
        let limit = viewportLength * Parameters.maxStretchFraction
        return min(max(stretch, -limit), limit)
    }

    private func applyGestureScrollDeltaY(
        _ scrollDY: CGFloat,
        viewportLength: CGFloat,
        coefficient: CGFloat,
        now: CFTimeInterval
    ) -> Bool {
        // 1. Already stretched: unwind 1:1 on opposing delta, or accumulate hyperbolic force in same direction.
        if abs(stretchY) > 0.0001 {
            let opposesStretch = (stretchY < 0 && scrollDY > 0) || (stretchY > 0 && scrollDY < 0)
            if opposesStretch {
                let remainingStretch = stretchY + scrollDY
                let crossedZero = (stretchY < 0 && remainingStretch >= 0) || (stretchY > 0 && remainingStretch <= 0)
                if !crossedZero {
                    stretchScrollForceY = AppKitElasticity.hyperbolicReboundDelta(
                        forElasticDelta: remainingStretch,
                        coefficient: coefficient,
                        viewportLength: viewportLength
                    )
                    setStretchY(remainingStretch)
                    return true
                }

                refreshState = .hidden
                spinnerView?.render(state: .hidden)
                setStretchY(0)
                stretchScrollForceY = 0

                if !metrics.isVerticallyScrollable && canStretchInScrollDirection(remainingStretch) {
                    stretchScrollForceY = remainingStretch
                    let rawStretch = AppKitElasticity.hyperbolicElasticDelta(
                        forReboundDelta: stretchScrollForceY,
                        coefficient: coefficient,
                        viewportLength: viewportLength
                    )
                    setStretchY(clampStretch(rawStretch, viewportLength: viewportLength))
                    return true
                }

                if abs(remainingStretch) > 0.001 {
                    residualForwardDeltaY = -remainingStretch
                    estimatedScrollY = clampScrollY(estimatedScrollY + remainingStretch)
                }
                return false
            } else {
                stretchScrollForceY += scrollDY
                let rawStretch = AppKitElasticity.hyperbolicElasticDelta(
                    forReboundDelta: stretchScrollForceY,
                    coefficient: coefficient,
                    viewportLength: viewportLength
                )
                setStretchY(clampStretch(rawStretch, viewportLength: viewportLength))
                evaluateDirectPullToRefresh(now: now)
                return true
            }
        }

        // 2. Not currently stretched: check inner-scroller latch and top/bottom edge boundaries.
        guard canStretchInScrollDirection(scrollDY) else {
            estimatedScrollY = clampScrollY(estimatedScrollY + scrollDY)
            return false
        }

        if scrollDY < 0 {
            if estimatedScrollY <= 0.5 {
                estimatedScrollY = 0
                stretchScrollForceY = scrollDY
                let rawStretch = AppKitElasticity.hyperbolicElasticDelta(
                    forReboundDelta: stretchScrollForceY,
                    coefficient: coefficient,
                    viewportLength: viewportLength
                )
                setStretchY(clampStretch(rawStretch, viewportLength: viewportLength))
                evaluateDirectPullToRefresh(now: now)
                return true
            }
            if estimatedScrollY + scrollDY < 0 {
                let toEdgeScrollDY = -estimatedScrollY
                let excessScrollDY = scrollDY - toEdgeScrollDY
                estimatedScrollY = 0
                residualForwardDeltaY = -toEdgeScrollDY
                stretchScrollForceY = excessScrollDY
                let rawStretch = AppKitElasticity.hyperbolicElasticDelta(
                    forReboundDelta: stretchScrollForceY,
                    coefficient: coefficient,
                    viewportLength: viewportLength
                )
                setStretchY(clampStretch(rawStretch, viewportLength: viewportLength))
                evaluateDirectPullToRefresh(now: now)
                return false
            }
            estimatedScrollY = clampScrollY(estimatedScrollY + scrollDY)
            return false
        } else {
            let maxY = metrics.maxScrollY
            if estimatedScrollY >= maxY - 0.5 {
                estimatedScrollY = maxY
                stretchScrollForceY = scrollDY
                let rawStretch = AppKitElasticity.hyperbolicElasticDelta(
                    forReboundDelta: stretchScrollForceY,
                    coefficient: coefficient,
                    viewportLength: viewportLength
                )
                setStretchY(clampStretch(rawStretch, viewportLength: viewportLength))
                return true
            }
            if estimatedScrollY + scrollDY > maxY {
                let toEdgeScrollDY = maxY - estimatedScrollY
                let excessScrollDY = scrollDY - toEdgeScrollDY
                estimatedScrollY = maxY
                residualForwardDeltaY = -toEdgeScrollDY
                stretchScrollForceY = excessScrollDY
                let rawStretch = AppKitElasticity.hyperbolicElasticDelta(
                    forReboundDelta: stretchScrollForceY,
                    coefficient: coefficient,
                    viewportLength: viewportLength
                )
                setStretchY(clampStretch(rawStretch, viewportLength: viewportLength))
                return false
            }
            estimatedScrollY = clampScrollY(estimatedScrollY + scrollDY)
            return false
        }
    }

    // MARK: - Pull-to-Refresh (`NSRefreshController` + `PullToRefreshView`)

    private func evaluateDirectPullToRefresh(now: CFTimeInterval) {
        guard metrics.isReloadableWebPage, stretchY < 0 else { return }
        switch refreshState {
        case .hidden, .pullingMomentum:
            if gestureBeganAtTop {
                refreshState = .pullingDirect
            } else {
                return
            }
        case .pullingDirect:
            break
        case .refreshing, .dismissing:
            return
        }

        if currentOverscrollY >= Parameters.refreshTriggerOffset {
            refreshState = .refreshing(triggeredAt: now, pageLoadObserved: metrics.isPageLoading)
            onTriggerRefresh?()
        }
    }

    private func transitionRefreshToDismissing(now: CFTimeInterval, triggeredAt: CFTimeInterval) {
        refreshState = .dismissing(triggeredAt: triggeredAt)
        if !inScrollGesture {
            startRubberBandAnimation(
                initialScrollVelocityY: 0,
                initialStretchY: stretchY,
                targetStretchY: 0,
                now: now
            )
        }
        updateDisplayLinkRunningState()
    }

    private func updateSpinnerPresentation(now: CFTimeInterval) {
        guard let spinner = spinnerView else { return }
        let y = currentOverscrollY

        switch refreshState {
        case .hidden:
            spinner.render(state: .hidden)

        case .pullingDirect:
            if y <= Parameters.refreshRevealOffset {
                spinner.render(state: .hidden)
            } else {
                let progress = (y - Parameters.refreshRevealOffset)
                    / (Parameters.refreshTriggerOffset - Parameters.refreshRevealOffset)
                let opacity = (y - Parameters.refreshRevealOffset)
                    / (Parameters.refreshFullOpacityOffset - Parameters.refreshRevealOffset)
                spinner.render(state: .pulling(progress: progress, opacity: opacity))
            }

        case .pullingMomentum:
            if y <= Parameters.refreshRevealOffset {
                spinner.render(state: .hidden)
            } else {
                let progress = (y - Parameters.refreshRevealOffset)
                    / (Parameters.refreshFlingProgressDenominator - Parameters.refreshRevealOffset)
                let opacity = (y - Parameters.refreshRevealOffset)
                    / (Parameters.refreshFullOpacityOffset - Parameters.refreshRevealOffset)
                spinner.render(state: .pulling(progress: progress, opacity: opacity))
            }

        case .refreshing(let triggeredAt, _), .dismissing(let triggeredAt):
            let elapsed = max(0, now - triggeredAt)
            let popScale = refreshPopScale(elapsed: elapsed)
            let frameIdx = Int(floor(elapsed * Parameters.refreshSpinFPS))
            if y <= Parameters.refreshFadeLowOffset {
                spinner.render(state: .hidden)
            } else if y >= Parameters.refreshFadeHighOffset {
                spinner.render(state: .spinning(popScale: popScale, opacity: 1.0, shiftUp: 0.0), spinFrameIndex: frameIdx)
            } else {
                let u = max(0, min(1, (y - Parameters.refreshFadeLowOffset)
                    / (Parameters.refreshFadeHighOffset - Parameters.refreshFadeLowOffset)))
                let smoothOpacity = u * u * (3.0 - 2.0 * u)
                let tuckScale = 0.74 + 0.26 * u
                let shiftUp = (1.0 - u) * 14.0
                spinner.render(
                    state: .spinning(popScale: popScale * tuckScale, opacity: smoothOpacity, shiftUp: shiftUp),
                    spinFrameIndex: frameIdx
                )
            }
        }
    }

    private func refreshPopScale(elapsed: TimeInterval) -> CGFloat {
        if elapsed >= Parameters.refreshPopDuration { return 1.0 }
        let extra = Parameters.refreshPopPeakScale - 1.0
        if elapsed < Parameters.refreshPopPeakTime {
            let u = elapsed / Parameters.refreshPopPeakTime
            return 1.0 + extra * CGFloat(Foundation.sin(u * .pi * 0.5))
        }
        let u = (elapsed - Parameters.refreshPopPeakTime)
            / (Parameters.refreshPopDuration - Parameters.refreshPopPeakTime)
        return 1.0 + extra * CGFloat(0.5 * (1.0 + Foundation.cos(u * .pi)))
    }

    // MARK: - Animation Launch & Layer Translation

    private func startRubberBandAnimation(
        initialScrollVelocityY: CGFloat,
        initialStretchY: CGFloat,
        targetStretchY: CGFloat,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        let clampedVel = min(
            max(initialScrollVelocityY, -Parameters.maxMomentumVelocity),
            Parameters.maxMomentumVelocity
        )
        let relStretch = initialStretchY - targetStretchY
        guard abs(relStretch) > 0.01 || abs(clampedVel) >= Parameters.minBounceImpactVelocity else {
            rubberBandAnimation = nil
            setStretchY(targetStretchY)
            stretchScrollForceY = AppKitElasticity.hyperbolicReboundDelta(
                forElasticDelta: targetStretchY,
                coefficient: AppKitElasticity.defaultHyperbolicCoefficient,
                viewportLength: effectiveViewportLength
            )
            updateDisplayLinkRunningState()
            return
        }

        rubberBandAnimation = RubberBandAnimationState(
            startTime: now,
            initialStretchY: initialStretchY,
            initialScrollVelocityY: clampedVel,
            targetStretchY: targetStretchY
        )

        if ScrollDebugLog.isEnabled && abs(clampedVel) > 0 {
            let peakStretch = AppKitElasticity.elasticDelta(
                initialPosition: relStretch,
                initialVelocity: -clampedVel,
                elapsedTime: 0.080
            ) + targetStretchY
            let edge = (clampedVel < 0 || initialStretchY < 0) ? "top" : "bottom"
            ScrollDebugLog.write(String(
                format: "rubberBand criticallyDamped edge=%@ sy=%.1f est=%.1f v0=%.0f peak=%.1f ov=%.1f",
                edge, metrics.scrollY, estimatedScrollY, -clampedVel, -peakStretch, currentOverscrollY
            ))
        }

        updateDisplayLinkRunningState()
    }

    private func cancelKeyboardGlide(emitEnded: Bool) {
        spaceMomentumChain = 0
        lastSpaceTriggerTime = 0
        lastSpaceScrollSign = 0
        spaceRepeatLatchedEdgeSign = 0
        guard let glide = keyboardGlide else { return }
        keyboardGlide = nil
        if emitEnded && glide.emittedBegan {
            onSyntheticScroll?(0, .ended)
        }
        updateDisplayLinkRunningState()
    }

    private func updatePredominantGestureAxisIsVertical(
        scrollDX: CGFloat,
        scrollDY: CGFloat,
        timestamp: TimeInterval
    ) -> Bool {
        if lastGestureTimestamp > 0 {
            let dt = max(0, timestamp - lastGestureTimestamp)
            let decay = CGFloat(Foundation.exp(-dt / Parameters.axisLockDecayTimeConstant))
            cumulativeGestureDelta.x *= decay
            cumulativeGestureDelta.y *= decay
        }
        lastGestureTimestamp = timestamp
        cumulativeGestureDelta.x += abs(scrollDX)
        cumulativeGestureDelta.y += abs(scrollDY)
        return cumulativeGestureDelta.y >= cumulativeGestureDelta.x
    }

    private func recordVelocitySample(scrollDeltaY: CGFloat, timestamp: TimeInterval) {
        if let last = velocitySamples.last {
            let gap = timestamp - last.timestamp
            if gap >= Parameters.velocityZeroingTimeout || gap < -0.001 {
                velocitySamples.removeAll(keepingCapacity: true)
            }
        }
        velocitySamples.append(VelocitySample(timestamp: timestamp, scrollDeltaY: scrollDeltaY))
        let cutoff = timestamp - Parameters.velocityWindowDuration
        while velocitySamples.count > 2, let first = velocitySamples.first, first.timestamp < cutoff {
            velocitySamples.removeFirst()
        }
    }

    private func currentScrollVelocityY(fallbackScrollDeltaY: CGFloat) -> CGFloat {
        guard let last = velocitySamples.last else {
            return fallbackScrollDeltaY / CGFloat(Parameters.minVelocitySampleDuration)
        }
        if velocitySamples.count >= 2, let first = velocitySamples.first {
            let span = last.timestamp - first.timestamp
            if span > 0 {
                var sumDelta: CGFloat = 0
                for idx in 1..<velocitySamples.count {
                    sumDelta += velocitySamples[idx].scrollDeltaY
                }
                let effectiveSpan = max(span, Parameters.minVelocitySampleDuration * Double(velocitySamples.count - 1))
                return sumDelta / CGFloat(effectiveSpan)
            }
        }
        return fallbackScrollDeltaY / CGFloat(Parameters.minVelocitySampleDuration)
    }

    private func setStretchY(_ newStretchY: CGFloat) {
        let sanitized = newStretchY.isFinite ? newStretchY : 0
        guard abs(sanitized - stretchY) > 0.0001 || (sanitized == 0 && stretchY != 0) else { return }
        stretchY = sanitized
        applyLayerTranslation()
    }

    private func applyLayerTranslation() {
        guard let tv = targetView else { return }
        if tv.layer == nil { tv.wantsLayer = true }
        guard let layer = tv.layer else { return }

        let offset = currentOverscrollY
        // Positive `offset` = top overscroll -> move `webContentHost` DOWN on screen.
        // In AppKit non-flipped coordinates (`contentStageView.isFlipped == false`), `-Y` is DOWN and `+Y` is UP!
        let sign: CGFloat = (tv.superview?.isFlipped == true) ? 1.0 : -1.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if abs(offset) < 0.01 {
            layer.transform = CATransform3DIdentity
        } else {
            layer.transform = CATransform3DMakeTranslation(0, sign * offset, 0)
        }
        CATransaction.commit()
    }

    private func updateInteractionState() {
        let active = isOverscrolling || isAnimatingRubberBand || isAnimatingKeyboardScroll || isRefreshingSpinnerActive
        if active != isElasticInteractionActive {
            isElasticInteractionActive = active
            onElasticInteractionChanged?(active)
        }
    }

    // MARK: - 120 Hz Display Link

    private func updateDisplayLinkRunningState() {
        let needsTick = (rubberBandAnimation != nil) || (keyboardGlide != nil) || isRefreshingSpinnerActive
        guard needsTick else {
            displayLink?.isPaused = true
            return
        }
        if displayLink == nil, let view = targetView {
            let link = view.displayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
            if #available(macOS 14.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLinkTick(_ link: CADisplayLink) {
        stepAnimation(at: link.timestamp)
    }

    private func logWheelStepIfEnabled(phase: UInt, momentumPhase: UInt, wheelDY: CGFloat) {
        guard ScrollDebugLog.isEnabled else { return }
        let vel = currentScrollVelocityY(fallbackScrollDeltaY: -wheelDY)
        ScrollDebugLog.write(String(
            format: "wheel ph=%lu mp=%lu dy=%.1f v=%.0f sy=%.1f est=%.1f ov=%.1f",
            phase, momentumPhase, wheelDY, -vel, metrics.scrollY, estimatedScrollY, currentOverscrollY
        ))
    }
}
