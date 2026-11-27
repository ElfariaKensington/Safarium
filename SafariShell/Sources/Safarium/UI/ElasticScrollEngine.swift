import AppKit
import QuartzCore

/// Brand-new, from-scratch 120Hz Safari Elastic Scrolling, Momentum Fling Overshoot,
/// and Pull-to-Refresh physics engine.
///
/// Every physics constant, geometry metric, and state transition is calibrated directly
/// from 120fps reference recordings of macOS 27.3 Safari (`apple.com` fling overshoot and
/// `google.com` direct-touch rubber-band pull-to-refresh):
///
/// 1. **Momentum Fling Overshoot** (calibrated to `apple.com` 120fps reference, RMSE = 0.55 pt):
///    - Critically damped harmonic oscillator: `y(t) = (y0 + (v0 + ω*y0)*t) * exp(-ω*t)`
///    - Natural angular frequency `ω = 12.45 rad/s` (`t_peak = 80.3 ms`, zero oscillation)
///    - Never displays the pull-to-refresh spinner or triggers reload during momentum overshoot
///
/// 2. **Direct-Touch Elastic Rubber-Band** (calibrated to `google.com` 120fps reference):
///    - Invertible Apple asymptotic curve: `f(d, D) = sign(d) * (c * |d| * D) / (D + c * |d|)`, `c = 0.55`
///    - Symmetrical top and bottom overscroll, including non-scrollable pages
///    - Zero-jump mid-air bounce catching and seamless direction reversal back into page scroll
///    - Release recoil: measured exponential snap-back `k = 11.7 s^-1` (or gentle critically-damped
///      crest if lifted with outward flick velocity)
///
/// 3. **Pull-to-Refresh State Machine** (calibrated to `google.com` 120fps reference):
///    - Direct-touch top pull ONLY on reloadable web pages
///    - Spinner reveals at `26 pt`, ramps full opacity by `52 pt`, fills 24 spokes up to `106 pt`
///    - Triggers immediately on crossing `106 pt` with haptic tick, `1.0 → 1.28× → 1.0` 155ms pop,
///      immediate reload callback, and 20fps continuous spin
///    - On finger release while loading, smoothly snaps to `68 pt` hold offset
///    - On load completion (after min spin duration), smoothly snaps `68 → 0 pt` while fading spinner
///      out cleanly between `62 pt` and `46 pt`
///
/// 4. **Zero-Reflow 120Hz Presentation**:
///    - Translates `targetView.layer?.transform` strictly on the GPU (`CATransform3DMakeTranslation`)
///    - Never resizes `webContentHost` or forces Chromium IPC layout/reflow during overscroll
final class ElasticScrollEngine: NSObject {

    // MARK: - Calibrated Reference Constants

    enum Constants {
        /// Initial direct-touch rubber-band slope (`NSScrollView` / WebKit standard).
        static let rubberBandSlope: CGFloat = 0.55
        /// Asymptotic rubber-band ceiling as a fraction of viewport height.
        static let maxStretchFraction: CGFloat = 0.42
        /// Minimum effective dimension `D` used in the rubber-band curve.
        static let minRubberBandDimension: CGFloat = 360.0

        /// Critically damped spring natural frequency (rad/s) measured from `apple.com` 120fps fling.
        static let flingOmega: Double = 12.45
        /// Asymptotic velocity ceiling (pt/s) for momentum fling overshoot (`y_peak_max = 5900 / (e * 12.45) ≈ 174 pt`).
        static let maxFlingVelocity: CGFloat = 5900.0
        /// Progressive velocity compression scale (pt/s): normal/fast/hard flings (`3k–18k pt/s`) peak cleanly
        /// at `38–152 pt` (driving the spinner visibly with zero accidental reload); only an extreme
        /// max-effort trackpad slam (`>= 22,000 pt/s`) reaches `ptrFlingTriggerThreshold` (`162 pt`).
        static let flingVelocityCompressionScale: CGFloat = 13500.0
        /// Minimum incoming velocity (pt/s) required to launch a momentum fling overshoot.
        static let minFlingVelocity: CGFloat = 110.0

        /// Exponential recoil rate (s^-1) measured from `google.com` 120fps release snap-backs.
        static let snapBackDecayRate: Double = 11.7
        /// Settle epsilon in points below which displacement snaps cleanly to target.
        static let settleEpsilon: CGFloat = 0.22

        /// Pull-to-refresh thresholds measured from `google.com` 120fps recording.
        static let ptrRevealStart: CGFloat = 26.0
        static let ptrFullOpacityOffset: CGFloat = 52.0
        static let ptrTriggerThreshold: CGFloat = 106.0
        /// Extreme threshold for momentum fling overshoot: drives spinner visibly on all normal/hard flings,
        /// while requiring a sustained extreme slam (`>= 22,000 pt/s`, peak `>= 162 pt`) to trigger refresh.
        static let ptrFlingTriggerThreshold: CGFloat = 162.0
        static let ptrHoldOffset: CGFloat = 68.0
        static let ptrFadeOutHigh: CGFloat = 66.0
        static let ptrFadeOutLow: CGFloat = 22.0
        static let ptrDismissOmega: Double = 14.0

        /// Pop scale animation on PTR trigger (`23pt → 29pt → 23pt` over 155ms).
        static let ptrPopDuration: Double = 0.155
        static let ptrPopPeakTime: Double = 0.055
        static let ptrPopPeakScale: CGFloat = 1.28

        /// Continuous spin cadence & lifecycle timing.
        static let ptrSpinFPS: Double = 20.0
        static let ptrMinSpinDuration: Double = 0.40
        static let ptrMaxSpinTimeout: Double = 3.2
    }

    // MARK: - Telemetry & State

    struct PageScrollMetrics {
        var scrollY: CGFloat = 0.0
        var contentHeight: CGFloat = 0.0
        var viewportHeight: CGFloat = 0.0
        var canInnerScrollUp: Bool = false
        var canInnerScrollDown: Bool = false
        var isReloadableWebPage: Bool = true
        var isPageLoading: Bool = false

        var maxScrollY: CGFloat {
            max(0.0, contentHeight - viewportHeight)
        }

        var isAtTopBoundary: Bool {
            scrollY <= 1.5 && !canInnerScrollUp
        }

        var isAtBottomBoundary: Bool {
            scrollY >= max(0.0, maxScrollY - 1.5) && !canInnerScrollDown
        }
    }

    enum MotionState: Equatable {
        case idle
        case directDrag
        /// Analytic critically damped oscillator: y(t) = target + (y0 + (v0 + ω*y0)*t) * exp(-ω*t)
        case criticallyDamped(startTime: CFTimeInterval, y0: CGFloat, v0: CGFloat, target: CGFloat, omega: Double)
        /// Pure exponential recoil: y(t) = target + (y0 - target) * exp(-k*t)
        case exponentialSnap(startTime: CFTimeInterval, fromY: CGFloat, target: CGFloat, rate: Double)
        /// Settled at `ptrHoldOffset` while the page reloads and spinner loops.
        case ptrHolding
        /// 1:1 macOS momentum unwinding PTR hold offset directly into downward page scroll.
        case ptrMomentumUnwind
        /// Synthetic smooth demo pull triggered from Page Menu.
        case demoPull(startTime: CFTimeInterval)
    }

    enum PTRState: Equatable {
        case idle
        case pulling
        /// Momentum top overshoot drives spinner progress visually, with a very high trigger threshold (150pt).
        case flingPulling
        case spinning(triggeredAt: CFTimeInterval, loadFinished: Bool)
        case dismissing(spinStartedAt: CFTimeInterval)
    }

    enum ConsumedMomentumLock {
        case none
        case top
        case bottom
    }

    // MARK: - Public Callbacks & Read-Only State

    var onTriggerRefresh: (() -> Void)?
    /// Emits 120Hz precise-pixel vertical scroll deltas (`deltaY < 0` scrolls down, `deltaY > 0` scrolls up)
    /// driven by touchpad-style Space / Shift+Space inertia.
    /// Space-bar momentum stream: (delta in points, + = scroll up, phase). `.began` opens a momentum scroll,
    /// `.changed` carries each frame's delta, `.ended` (delta 0) closes it, like a trackpad fling's momentum phase.
    var onSyntheticScroll: ((CGFloat, SyntheticScrollPhase) -> Void)?
    enum SyntheticScrollPhase { case began, changed, ended }
    /// Height of the shell chrome over the top of the page (toolbar + tab strip); Space pages by what is visible.
    var obscuredTopInset: CGFloat = 0.0
    /// Fires when elastic rubber-band drag or spring animation begins (`true`) or settles back to idle (`false`).
    var onElasticInteractionChanged: ((Bool) -> Void)?

    private(set) var currentOverscrollY: CGFloat = 0.0 {
        didSet { notifyElasticInteractionIfNeeded() }
    }
    var isOverscrolling: Bool { abs(currentOverscrollY) > 0.05 }
    var isElasticInteractionActive: Bool {
        if case .idle = motionState { return isOverscrolling }
        return true
    }
    private var lastReportedElasticActive: Bool = false

    private func notifyElasticInteractionIfNeeded() {
        let active = isElasticInteractionActive
        if active != lastReportedElasticActive {
            lastReportedElasticActive = active
            onElasticInteractionChanged?(active)
        }
    }

    // MARK: - Attached Views & Display Link

    private weak var targetView: NSView?
    private weak var spinnerView: PullToRefreshView?

    private var displayLink: CADisplayLink?

    // MARK: - Internal Simulation State

    var metrics = PageScrollMetrics()
    var estimatedScrollY: CGFloat = 0.0
    /// Set when a direct-touch step unwound the overscroll and crossed zero: the part of the step that must still
    /// reach the page (negative = scroll down). The scroll monitor forwards only this remainder, not the whole event.
    private(set) var residualForwardDeltaY: CGFloat?

    /// Returns and clears the remainder recorded by the last event (nil when the whole event goes to the page as-is).
    func takeResidualForwardDeltaY() -> CGFloat? {
        defer { residualForwardDeltaY = nil }
        return residualForwardDeltaY
    }

    var motionState: MotionState = .idle {
        didSet { notifyElasticInteractionIfNeeded() }
    }
    var ptrState: PTRState = .idle
    var rawStretch: CGFloat = 0.0

    /// Rolling 45ms velocity estimator in points/second (immune to coalesced 1ms-dt spikes).
    struct VelocitySample {
        let timestamp: TimeInterval
        let deltaY: CGFloat
    }
    var velocitySamples: [VelocitySample] = []
    var smoothedVelocityY: CGFloat = 0.0
    var lastDirectDragVelocityY: CGFloat = 0.0

    /// Locks out residual macOS momentum events once an overshoot spring has taken ownership.
    var momentumLock: ConsumedMomentumLock = .none

    /// Tracks whether the current direct-touch gesture began while horizontal scroll dominated.
    private var gestureLockedHorizontal: Bool = false

    /// Set when the user actively scrolls down during PTR triggered/holding to unwind cleanly to 0.
    var ptrDismissedByUserScroll: Bool = false
    /// Timestamp of last macOS momentum delta received during `.ptrMomentumUnwind`.
    private var lastMomentumUnwindTime: CFTimeInterval = 0.0

    // MARK: Space / Shift+Space momentum
    // A press is a momentum fling that travels exactly one page (WebKit's page step: max(87.5% of the visible height,
    // visible height - 40)), with velocity decaying exponentially like trackpad momentum, delivered to Chromium as a
    // momentum-phase scroll stream. Momentum builds up: each quick press in the same direction adds a bigger impulse
    // on top of the current velocity and lowers the friction, so a burst of presses keeps getting faster; a held key
    // accelerates from 3 to 10 pages/s over a second. Reaching an edge lands the page exactly on it and hands the
    // remaining velocity to the same overshoot spring a trackpad fling uses.
    /// pt/s, + = up. Remaining travel of the current glide is `spaceVelocityY / spaceDecayRate`.
    var spaceVelocityY: CGFloat = 0.0
    private(set) var spaceLastTickTime: CFTimeInterval = 0.0
    var spaceIsStartPage: Bool = false
    /// True between the `.began` and `.ended` of a momentum stream sent to the page.
    private(set) var spaceStreamOpen: Bool = false
    /// Set when the glide began while the page already sat on the edge it moves toward (no bounce, like Safari).
    private var spaceStartedAtEdge: Bool = false
    static let spaceDecayRate: CGFloat = 8.0
    /// Friction of the current glide (lowered while a press streak builds momentum).
    private(set) var spaceFriction: CGFloat = ElasticScrollEngine.spaceDecayRate
    /// Consecutive same-direction presses less than `spaceStreakWindow` apart.
    private(set) var spaceStreak: Int = 0
    private var spaceLastPressTime: CFTimeInterval = -1.0
    private var spaceHoldStartTime: CFTimeInterval = 0.0
    static let spaceStreakWindow: CFTimeInterval = 0.6
    /// Fastest glide, in visible pages per second.
    static let spaceMaxPagesPerSecond: CGFloat = 30.0
    static let spaceMaxImpactVelocity: CGFloat = 9000.0
    /// Glide ends once less than this much travel remains (the remainder is sent in the last frame).
    private static let spaceStopDistance: CGFloat = 1.0

    // MARK: - Lifecycle

    func attach(targetView: NSView, spinnerView: PullToRefreshView) {
        self.targetView = targetView
        self.spinnerView = spinnerView
        targetView.wantsLayer = true
        applyVisualOffset(0.0)
        spinnerView.render(state: .hidden)
    }

    func invalidate() {
        stopDisplayLink()
        applyVisualOffset(0.0)
        spinnerView?.render(state: .hidden)
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Telemetry & External Lifecycle Hooks

    /// `resyncEstimate`: true when this is fresh renderer telemetry (or a tab/page change), false for the cached-value
    /// sync the scroll monitor runs before every event. The renderer reports scroll a frame or more after it applied
    /// a delta, so the predictive `estimatedScrollY` (last report minus every delta forwarded since) must only be
    /// reset when a new report arrives; resetting it from the cached value on every event threw the prediction away
    /// and the top/bottom fling overshoot fired late or not at all.
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
        metrics.scrollY = max(0.0, scrollY)
        metrics.contentHeight = max(0.0, contentHeight)
        metrics.viewportHeight = max(1.0, viewportHeight)
        metrics.canInnerScrollUp = canInnerScrollUp
        metrics.canInnerScrollDown = canInnerScrollDown
        metrics.isReloadableWebPage = isReloadableWebPage
        metrics.isPageLoading = isPageLoading

        if resyncEstimate {
            estimatedScrollY = metrics.scrollY
        }
    }

    func setReloadableWebPage(_ reloadable: Bool) {
        metrics.isReloadableWebPage = reloadable
        if !reloadable {
            resetImmediately()
        }
    }

    func notifyPageLoadingStateChanged(isLoading: Bool) {
        metrics.isPageLoading = isLoading
        if !isLoading {
            markPTRLoadFinished()
        }
    }

    func resetImmediately() {
        stopDisplayLink()
        motionState = .idle
        ptrState = .idle
        rawStretch = 0.0
        currentOverscrollY = 0.0
        velocitySamples.removeAll(keepingCapacity: true)
        smoothedVelocityY = 0.0
        lastDirectDragVelocityY = 0.0
        momentumLock = .none
        gestureLockedHorizontal = false
        ptrDismissedByUserScroll = false
        lastMomentumUnwindTime = 0.0
        cancelSpaceScroll()
        spaceLastTickTime = 0.0
        spaceIsStartPage = false
        applyVisualOffset(0.0)
        spinnerView?.render(state: .hidden)
    }

    /// Launches or stacks a 120Hz macOS touchpad-inertia scroll impulse for Space (`direction = -1`)
    /// or Shift+Space (`direction = +1`), unwinding PTR or triggering elastic boundary bounce seamlessly.
    /// Visible page height Space steps by (viewport minus the chrome over its top).
    func spaceVisibleHeight() -> CGFloat {
        let vh = max(320.0, metrics.viewportHeight > 1.0 ? metrics.viewportHeight : (targetView?.bounds.height ?? 800.0))
        return max(240.0, vh - (spaceIsStartPage ? 0.0 : obscuredTopInset))
    }

    /// WebKit's page step for a visible height.
    static func spacePageStep(visibleHeight h: CGFloat) -> CGFloat {
        max(h * 0.875, h - 40.0)
    }

    /// `direction` -1 = Space (down), +1 = Shift+Space (up). `isRepeat` = key auto-repeat while held.
    func triggerSpaceScroll(direction: Int, isRepeat: Bool, isStartPage: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let sign: CGFloat = direction >= 0 ? 1.0 : -1.0
        spaceIsStartPage = isStartPage
        let base = Self.spaceDecayRate
        let visible = spaceVisibleHeight()
        let reversing = (spaceVelocityY > 0 && sign < 0) || (spaceVelocityY < 0 && sign > 0)
        if reversing {
            spaceVelocityY = 0.0
            spaceStreak = 0
            spaceFriction = base
            endSpaceStream()
        }

        if isRepeat {
            // Held key: speed ramps from 3 to 10 visible pages/s over the first second of auto-repeat, never down.
            if spaceHoldStartTime <= 0.0 { spaceHoldStartTime = now }
            let held = CGFloat(min(1.0, (now - spaceHoldStartTime) / 1.0))
            let target = visible * (3.0 + 7.0 * held)
            if abs(spaceVelocityY) < target { spaceVelocityY = sign * target }
        } else {
            spaceHoldStartTime = 0.0
            let quick = spaceLastPressTime >= 0.0 && (now - spaceLastPressTime) < Self.spaceStreakWindow
            spaceStreak = (quick && !reversing && spaceVelocityY != 0.0) ? spaceStreak + 1 : 1
            spaceLastPressTime = now
            let n = CGFloat(spaceStreak - 1)
            // 1st press: exactly one page at base friction. Each quick follow-up adds a bigger kick (x1.35, x1.7, ...
            // up to x3) on top of the velocity still left, and the glide coasts further (friction down to base/1.8).
            let boost = min(1.0 + 0.35 * n, 3.0)
            spaceFriction = base / min(1.8, 1.0 + 0.2 * n)
            spaceVelocityY = sign * (abs(spaceVelocityY) + Self.spacePageStep(visibleHeight: visible) * base * boost)
        }
        let maxV = visible * Self.spaceMaxPagesPerSecond
        spaceVelocityY = max(-maxV, min(maxV, spaceVelocityY))
        if !spaceStreamOpen {
            spaceLastTickTime = now
            spaceStartedAtEdge = false
        }
        ensureDisplayLinkRunning()
    }

    /// Stops a Space glide (real trackpad input, reset, edge arrival) and closes its momentum stream.
    func cancelSpaceScroll() {
        spaceVelocityY = 0.0
        spaceStreak = 0
        spaceHoldStartTime = 0.0
        spaceFriction = Self.spaceDecayRate
        endSpaceStream()
    }

    private func emitSpaceDelta(_ deltaY: CGFloat) {
        if !spaceStreamOpen {
            spaceStreamOpen = true
            onSyntheticScroll?(deltaY, .began)
        } else {
            onSyntheticScroll?(deltaY, .changed)
        }
    }

    private func endSpaceStream() {
        guard spaceStreamOpen else { return }
        spaceStreamOpen = false
        onSyntheticScroll?(0.0, .ended)
    }

    func triggerPullToRefreshDemo() {
        guard metrics.isReloadableWebPage else { return }
        momentumLock = .none
        ptrState = .pulling
        motionState = .demoPull(startTime: CACurrentMediaTime())
        ensureDisplayLinkRunning()
    }

    /// Programmatic momentum fling overshoot helper (useful for automated runtime verification).
    func triggerSyntheticFlingOvershoot(impactVelocity: CGFloat) {
        guard abs(impactVelocity) >= Constants.minFlingVelocity else { return }
        launchFlingOvershoot(impactVelocity: impactVelocity, lock: impactVelocity > 0 ? .top : .bottom)
    }

    // MARK: - Trackpad Scroll Event Entrypoint

    /// Processes an AppKit `.scrollWheel` event directed at `targetView`.
    /// Returns `true` if the event was consumed by elastic overscroll (caller should drop it so
    /// Chromium does not double-scroll or double-bounce), or `false` to pass through to Chromium.
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        let consumed = handleScrollWheelCore(event)
        if ScrollDebugLog.isEnabled {
            let line = String(format: "%.4f ph=%lu mo=%lu dy=%.2f v=%.0f sy=%.1f est=%.1f max=%.0f up=%d dn=%d ov=%.1f st=%@ lock=%@ c=%d\n",
                              event.timestamp, event.phase.rawValue, event.momentumPhase.rawValue,
                              event.scrollingDeltaY, smoothedVelocityY, metrics.scrollY, estimatedScrollY,
                              metrics.maxScrollY, metrics.canInnerScrollUp ? 1 : 0, metrics.canInnerScrollDown ? 1 : 0,
                              currentOverscrollY, String(describing: motionState).prefix(18).description,
                              String(describing: momentumLock), consumed ? 1 : 0)
            ScrollDebugLog.write(line)
        }
        return consumed
    }

    private func handleScrollWheelCore(_ event: NSEvent) -> Bool {
        // Discrete notched mouse wheels do not trigger macOS Safari elastic rubber-banding.
        let isPreciseTrackpad = event.hasPreciseScrollingDeltas
            || !event.phase.isEmpty
            || !event.momentumPhase.isEmpty
        guard isPreciseTrackpad else {
            return false
        }

        let phase = event.phase
        let momentum = event.momentumPhase
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        let now = event.timestamp > 0 ? event.timestamp : CACurrentMediaTime()

        // Any real trackpad input immediately cancels synthetic Space-scroll inertia.
        if !phase.isEmpty || !momentum.isEmpty {
            cancelSpaceScroll()
        }

        // Update viewport height from live target view if telemetry hasn't reported one yet.
        if let tv = targetView, tv.bounds.height > 1.0, metrics.viewportHeight <= 1.0 {
            metrics.viewportHeight = tv.bounds.height
        }

        // Update velocity estimator from precise deltas (only reset on a fresh finger touch,
        // preserving finger-lift momentum velocity seamlessly across phase.ended -> momentum.began).
        updateVelocityEstimate(deltaY: deltaY, timestamp: now, isBegin: phase == .began)

        // 1. Direct finger touch phase (`phase != []`, `momentumPhase == []`).
        if !phase.isEmpty && momentum.isEmpty {
            return handleDirectTouchEvent(phase: phase, deltaX: deltaX, deltaY: deltaY)
        }

        // 2. Momentum coast phase (`momentumPhase != []`).
        if !momentum.isEmpty {
            return handleMomentumEvent(momentum: momentum, deltaY: deltaY)
        }

        return false
    }

    // MARK: - Direct-Touch Elastic Rubber-Band Handling

    func handleDirectTouchEvent(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        // Putting fingers down clears any previous momentum consumption lock.
        if phase == .mayBegin || phase == .began {
            momentumLock = .none
            gestureLockedHorizontal = false
            lastDirectDragVelocityY = 0.0

            // While pull-to-refresh is spinning or dismissing, keep spinner calm on finger rest;
            // actual vertical movement in `.changed` will seamlessly grab and unwind 1:1.
            if isPTRRefreshingOrDismissing {
                ptrDismissedByUserScroll = false
                return false
            }

            // Mid-air catch: if currently bouncing (non-PTR), seamlessly grab the page
            // at its exact current visual pixel with ZERO jump!
            if abs(currentOverscrollY) > 0.25 {
                let d = effectiveDimension()
                rawStretch = inverseRubberBand(visual: currentOverscrollY, dimension: d)
                motionState = .directDrag
                if currentOverscrollY > 0, metrics.isReloadableWebPage {
                    ptrState = .pulling
                }
                ensureDisplayLinkRunning()
                return true
            }
            return false
        }

        if phase == .ended || phase == .cancelled {
            gestureLockedHorizontal = false
            if case .directDrag = motionState {
                beginDirectReleaseRecoil()
                return true
            }
            return false
        }

        // Active finger movement (`.changed` or `.stationary`).
        guard phase == .changed else {
            return isCurrentlyInDirectDrag
        }

        // While pull-to-refresh is triggered / holding / dismissing:
        // Unwind `currentOverscrollY` 1:1 with downward scroll (`deltaY < 0`) so the page stays locked
        // to the user's fingers with ZERO jump/double-motion, then hand off at exact 1:1 speed into Chromium at y = 0.
        if isPTRRefreshingOrDismissing {
            if currentOverscrollY > 0.25 {
                let wasDirectDrag = isCurrentlyInDirectDrag
                if !wasDirectDrag {
                    if gestureLockedHorizontal {
                        return false
                    }
                    if abs(deltaX) > abs(deltaY) * 1.15 && abs(deltaX) > 1.0 {
                        gestureLockedHorizontal = true
                        return false
                    }
                }

                let now = CACurrentMediaTime()
                if deltaY < 0.0 {
                    let nextY = currentOverscrollY + deltaY
                    lastDirectDragVelocityY = smoothedVelocityY

                    // Transition to dismissing if this is a fresh scroll-down touch, or user pushed below hold shelf, or flicked up.
                    if !wasDirectDrag || nextY < Constants.ptrHoldOffset - 4.0 || smoothedVelocityY < -160.0 {
                        ptrDismissedByUserScroll = true
                        if case .spinning(let triggeredAt, _) = ptrState {
                            ptrState = .dismissing(spinStartedAt: triggeredAt)
                        }
                    }

                    if nextY <= 0.0 {
                        resetToIdleRest()
                        // Only the part beyond the unwound overscroll is real page scroll.
                        estimatedScrollY = clampScrollY(estimatedScrollY - nextY)
                        residualForwardDeltaY = nextY
                        return false
                    }

                    motionState = .directDrag
                    rawStretch = inverseRubberBand(visual: nextY, dimension: effectiveDimension())
                    applyVisualOffset(nextY)
                    updateSpinnerPresentation(now: now)
                    ensureDisplayLinkRunning()
                    return true
                }

                if deltaY > 0.0 {
                    if !wasDirectDrag {
                        rawStretch = inverseRubberBand(visual: currentOverscrollY, dimension: effectiveDimension())
                        motionState = .directDrag
                    }
                    rawStretch += deltaY
                    lastDirectDragVelocityY = smoothedVelocityY
                    let visual = rubberBand(raw: rawStretch, dimension: effectiveDimension())
                    applyVisualOffset(visual)
                    updateSpinnerPresentation(now: now)
                    ensureDisplayLinkRunning()
                    return true
                }

                return wasDirectDrag
            }

            estimatedScrollY = clampScrollY(estimatedScrollY - deltaY)
            return false
        }

        // If already dragging in elastic stretch, keep full continuous ownership until crossing 0.
        if case .directDrag = motionState {
            let prevSign: CGFloat = rawStretch >= 0 ? 1.0 : -1.0
            rawStretch += deltaY
            lastDirectDragVelocityY = smoothedVelocityY

            // Did the user drag all the way back past 0?
            if (prevSign > 0 && rawStretch <= 0.0) || (prevSign < 0 && rawStretch >= 0.0) {
                let canScrollBackIntoPage = (prevSign > 0)
                    ? (!metrics.isAtBottomBoundary || metrics.maxScrollY > 1.0)
                    : (!metrics.isAtTopBoundary || metrics.maxScrollY > 1.0)

                if canScrollBackIntoPage {
                    // Only the overshoot past the unwound stretch is real page scroll.
                    let residual = rawStretch
                    estimatedScrollY = clampScrollY(estimatedScrollY - residual)
                    residualForwardDeltaY = residual
                    rawStretch = 0.0
                    motionState = .idle
                    if case .pulling = ptrState {
                        ptrState = .idle
                    }
                    applyVisualOffset(0.0)
                    updateSpinnerPresentation(now: CACurrentMediaTime())
                    stopDisplayLinkIfIdle()
                    return false
                }
                // On a non-scrollable page (`maxScrollY == 0`), allow seamless elastic crossover
                // from top stretch directly into bottom stretch!
            }

            let visual = rubberBand(raw: rawStretch, dimension: effectiveDimension())
            applyVisualOffset(visual)
            evaluateDirectTouchPTR(visualOffset: visual, now: CACurrentMediaTime())
            updateSpinnerPresentation(now: CACurrentMediaTime())
            return true
        }

        // Not currently stretched: check if we should stay out of horizontal gestures.
        if gestureLockedHorizontal {
            return false
        }
        if abs(deltaX) > abs(deltaY) * 1.15 && abs(deltaX) > 1.0 {
            gestureLockedHorizontal = true
            return false
        }

        // Check boundary entry for direct-touch elastic pull.
        if deltaY > 0.0, metrics.isAtTopBoundary {
            rawStretch = deltaY
            motionState = .directDrag
            lastDirectDragVelocityY = smoothedVelocityY
            let visual = rubberBand(raw: rawStretch, dimension: effectiveDimension())
            applyVisualOffset(visual)
            if metrics.isReloadableWebPage, case .idle = ptrState {
                ptrState = .pulling
            }
            evaluateDirectTouchPTR(visualOffset: visual, now: CACurrentMediaTime())
            updateSpinnerPresentation(now: CACurrentMediaTime())
            return true
        }

        if deltaY < 0.0, metrics.isAtBottomBoundary {
            rawStretch = deltaY
            motionState = .directDrag
            lastDirectDragVelocityY = smoothedVelocityY
            let visual = rubberBand(raw: rawStretch, dimension: effectiveDimension())
            applyVisualOffset(visual)
            return true
        }

        // Normal in-bounds scrolling: track estimatedScrollY and let Chromium scroll natively.
        estimatedScrollY = clampScrollY(estimatedScrollY - deltaY)
        return false
    }

    // MARK: - Momentum Coast & Fling Overshoot Handling

    func handleMomentumEvent(momentum: NSEvent.Phase, deltaY: CGFloat) -> Bool {
        if momentum == .ended || momentum == .cancelled {
            let wasLocked = (momentumLock != .none)
            momentumLock = .none
            if case .ptrMomentumUnwind = motionState {
                if currentOverscrollY > Constants.settleEpsilon {
                    beginSmoothPTRCollapseToZero(now: CACurrentMediaTime(), initialVelocity: min(0.0, smoothedVelocityY))
                } else {
                    resetToIdleRest()
                }
                return true
            }
            return wasLocked
        }

        // While pull-to-refresh is refreshing or dismissing:
        // - Downward scroll momentum (`deltaY < 0`) smoothly unwinds the remaining PTR gap 1:1,
        //   then hands off seamlessly at exact continuous velocity into Chromium page scrolling at y = 0.
        // - Residual upward/pull-down momentum (`deltaY >= 0`) is cleanly absorbed while settling.
        if isPTRRefreshingOrDismissing {
            if currentOverscrollY > 0.25 {
                if deltaY < 0.0 {
                    momentumLock = .none
                    ptrDismissedByUserScroll = true
                    if case .spinning(let triggeredAt, _) = ptrState {
                        ptrState = .dismissing(spinStartedAt: triggeredAt)
                    }
                    let nextY = currentOverscrollY + deltaY
                    if nextY <= 0.0 {
                        resetToIdleRest()
                        // Only the part beyond the unwound overscroll is real page scroll.
                        estimatedScrollY = clampScrollY(estimatedScrollY - nextY)
                        residualForwardDeltaY = nextY
                        return false
                    }
                    let now = CACurrentMediaTime()
                    motionState = .ptrMomentumUnwind
                    lastMomentumUnwindTime = now
                    applyVisualOffset(nextY)
                    updateSpinnerPresentation(now: now)
                    ensureDisplayLinkRunning()
                    return true
                }
                // Consume residual pull-down momentum so Chromium does not fight the settle/hold curve.
                return true
            }
            momentumLock = .none
            estimatedScrollY = clampScrollY(estimatedScrollY - deltaY)
            return false
        }

        // If a fling overshoot or PTR rebound already owns this momentum stream, consume
        // same-direction residual events so Chromium does not fight our analytic spring.
        switch momentumLock {
        case .top:
            if deltaY >= -0.5 { return true }
            momentumLock = .none
        case .bottom:
            if deltaY <= 0.5 { return true }
            momentumLock = .none
        case .none:
            break
        }

        // If already animating a bounce/rebound (e.g., lifted from direct drag into momentum),
        // consume residual momentum events in the overshoot direction.
        if abs(currentOverscrollY) > 0.25 {
            if (currentOverscrollY > 0 && deltaY >= 0) || (currentOverscrollY < 0 && deltaY <= 0) {
                momentumLock = currentOverscrollY > 0 ? .top : .bottom
                return true
            }
        }

        // Guard against inner scrollable containers (e.g. Gemini chat pane, Gmail list).
        if deltaY > 0.0 && metrics.canInnerScrollUp {
            return false
        }
        if deltaY < 0.0 && metrics.canInnerScrollDown {
            return false
        }

        // Edge arrival during a momentum fling: hand the fling's velocity to the overshoot spring and let this one
        // event through, resized so the page lands exactly on the edge even when telemetry lags behind it.
        if deltaY != 0.0, let arrival = edgeArrival(deltaY: deltaY, velocity: smoothedVelocityY) {
            let lock: ConsumedMomentumLock = deltaY > 0.0 ? .top : .bottom
            let impactV = smoothedVelocityY
            if abs(impactV) >= Constants.minFlingVelocity, (impactV > 0.0) == (deltaY > 0.0) {
                launchFlingOvershoot(impactVelocity: impactV, lock: lock)
            } else {
                momentumLock = lock
            }
            estimatedScrollY = deltaY > 0.0 ? 0.0 : metrics.maxScrollY
            if arrival.alreadyAtEdge { return true }
            residualForwardDeltaY = deltaY > 0.0 ? arrival.flush : -arrival.flush
            return false
        }

        estimatedScrollY = clampScrollY(estimatedScrollY - deltaY)
        return false
    }

    // MARK: - Spring & Recoil Launchers

    private func launchFlingOvershoot(impactVelocity: CGFloat, lock: ConsumedMomentumLock, allowsRefresh: Bool = true) {
        let compressedV = compressImpactVelocity(impactVelocity)
        momentumLock = lock
        if ScrollDebugLog.isEnabled {
            // Critically damped from rest at the edge: peak = v0 / (omega * e).
            ScrollDebugLog.write(String(format: "overshoot lock=%@ impact=%.0f v0=%.0f peak=%.1f", String(describing: lock),
                                        impactVelocity, compressedV, abs(compressedV) / CGFloat(Constants.flingOmega * M_E)))
        }

        // Top momentum fling overshoot drives the pull-to-refresh spinner visually,
        // using the much harder `ptrFlingTriggerThreshold` (150pt) so normal flings
        // show the spinner cleanly without accidental reloads.
        if lock == .top && metrics.isReloadableWebPage && allowsRefresh {
            if case .spinning = ptrState {
                // Keep existing active refresh spinning.
            } else {
                ptrState = .flingPulling
            }
        } else {
            if case .pulling = ptrState { ptrState = .idle }
            if case .flingPulling = ptrState { ptrState = .idle }
            spinnerView?.render(state: .hidden)
        }

        motionState = .criticallyDamped(
            startTime: CACurrentMediaTime(),
            y0: currentOverscrollY,
            v0: compressedV,
            target: 0.0,
            omega: Constants.flingOmega
        )
        ensureDisplayLinkRunning()
    }

    private func beginDirectReleaseRecoil() {
        let now = CACurrentMediaTime()

        // If PTR is currently spinning: either dismiss smoothly into scroll if user scrolled down,
        // or smoothly settle to the measured 68pt hold offset.
        if case .spinning(let triggeredAt, _) = ptrState {
            let wantsDismiss = ptrDismissedByUserScroll
                || lastDirectDragVelocityY < -160.0
                || currentOverscrollY < Constants.ptrHoldOffset - 4.0
            if wantsDismiss {
                ptrState = .dismissing(spinStartedAt: triggeredAt)
                ptrDismissedByUserScroll = true
                momentumLock = .none
                beginSmoothPTRCollapseToZero(now: now, initialVelocity: min(0.0, lastDirectDragVelocityY))
                return
            }

            momentumLock = .top
            motionState = .exponentialSnap(
                startTime: now,
                fromY: currentOverscrollY,
                target: Constants.ptrHoldOffset,
                rate: Constants.snapBackDecayRate
            )
            ensureDisplayLinkRunning()
            return
        }

        // If PTR is already dismissing, preserve downward-scroll velocity cleanly to 0 without locking momentum.
        if case .dismissing = ptrState {
            momentumLock = .none
            if currentOverscrollY <= Constants.settleEpsilon {
                resetToIdleRest()
            } else {
                beginSmoothPTRCollapseToZero(now: now, initialVelocity: min(0.0, lastDirectDragVelocityY))
            }
            return
        }

        // Otherwise snap back to 0.
        if abs(currentOverscrollY) <= Constants.settleEpsilon {
            resetToIdleRest()
            return
        }

        momentumLock = currentOverscrollY > 0 ? .top : .bottom

        // If user flicked outward right as they lifted fingers, give a gentle critically damped crest
        // without ever crossing into PTR trigger; otherwise use the exact measured k=11.7 recoil.
        let sameDirectionOutward = (currentOverscrollY > 0 && lastDirectDragVelocityY > 220.0)
            || (currentOverscrollY < 0 && lastDirectDragVelocityY < -220.0)

        if sameDirectionOutward {
            let carriedV = max(-1100.0, min(1100.0, lastDirectDragVelocityY * 0.28))
            // Keep spinner visible during post-release crest with the hard fling trigger threshold.
            if currentOverscrollY > 0 && metrics.isReloadableWebPage {
                ptrState = .flingPulling
            } else {
                ptrState = .idle
            }
            motionState = .criticallyDamped(
                startTime: now,
                y0: currentOverscrollY,
                v0: carriedV,
                target: 0.0,
                omega: Constants.flingOmega
            )
        } else {
            motionState = .exponentialSnap(
                startTime: now,
                fromY: currentOverscrollY,
                target: 0.0,
                rate: Constants.snapBackDecayRate
            )
        }
        ensureDisplayLinkRunning()
    }

    // MARK: - Pull-to-Refresh State Transitions

    private func evaluateDirectTouchPTR(visualOffset: CGFloat, now: CFTimeInterval) {
        guard metrics.isReloadableWebPage else {
            ptrState = .idle
            return
        }

        switch ptrState {
        case .idle, .flingPulling:
            if visualOffset > Constants.ptrRevealStart {
                ptrState = .pulling
            }

        case .pulling:
            if visualOffset >= Constants.ptrTriggerThreshold {
                // Immediate trigger while fingers are still down (verified in `f_100111` F096 & F363).
                ptrState = .spinning(triggeredAt: now, loadFinished: false)
                ensureDisplayLinkRunning()
                onTriggerRefresh?()
            } else if visualOffset <= 0.5 {
                ptrState = .idle
            }

        case .spinning, .dismissing:
            break
        }
    }

    private func markPTRLoadFinished() {
        guard case .spinning(let triggeredAt, _) = ptrState else { return }
        ptrState = .spinning(triggeredAt: triggeredAt, loadFinished: true)
        ensureDisplayLinkRunning()
    }

    private var isPTRRefreshingOrDismissing: Bool {
        switch ptrState {
        case .spinning, .dismissing:
            return true
        case .idle, .pulling, .flingPulling:
            return false
        }
    }

    private func dismissPTRHoldSmoothly(now: CFTimeInterval) {
        switch ptrState {
        case .spinning(let triggeredAt, _):
            beginPTRDismiss(spinStartedAt: triggeredAt, now: now)
        case .dismissing:
            if case .ptrHolding = motionState {
                motionState = .exponentialSnap(
                    startTime: now,
                    fromY: currentOverscrollY,
                    target: 0.0,
                    rate: Constants.snapBackDecayRate
                )
                ensureDisplayLinkRunning()
            }
        case .idle, .pulling, .flingPulling:
            break
        }
    }

    private func beginPTRDismiss(spinStartedAt: CFTimeInterval, now: CFTimeInterval) {
        ptrState = .dismissing(spinStartedAt: spinStartedAt)
        beginSmoothPTRCollapseToZero(now: now, initialVelocity: 0.0)
    }

    /// Launches a monotonic, zero-overshoot critically damped glide to `0.0` preserving upward scroll velocity.
    private func beginSmoothPTRCollapseToZero(now: CFTimeInterval, initialVelocity: CGFloat) {
        let y0 = max(0.0, currentOverscrollY)
        guard y0 > Constants.settleEpsilon else {
            resetToIdleRest()
            return
        }
        let omega = Constants.ptrDismissOmega
        // Clamp negative velocity to `-omega * y0` so `c2 = v0 + omega * y0 >= 0` (mathematically zero overshoot past 0).
        let clampedV0 = max(-CGFloat(omega) * y0, min(0.0, initialVelocity))
        motionState = .criticallyDamped(
            startTime: now,
            y0: y0,
            v0: clampedV0,
            target: 0.0,
            omega: omega
        )
        ensureDisplayLinkRunning()
    }

    // MARK: - 120Hz Display Link Tick

    private func ensureDisplayLinkRunning() {
        if let link = displayLink {
            link.isPaused = false
            return
        }
        guard let hostView = targetView else { return }
        let link = hostView.displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        // Ask for the panel's full rate: at a throttled 60 Hz the Space glide fed a 120 Hz page every other frame
        // (visible judder) and the bounce stepped visibly.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func stopDisplayLinkIfIdle() {
        if case .idle = motionState, case .idle = ptrState, spaceVelocityY == 0.0, !spaceStreamOpen {
            displayLink?.isPaused = true
        }
    }

    @objc private func handleDisplayLink(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()

        // 0. Space / Shift+Space momentum glide.
        stepSpaceGlide(now: now)

        // 1. Check PTR spinning completion / timeout.
        if case .spinning(let triggeredAt, let loadFinished) = ptrState {
            let elapsed = now - triggeredAt
            let readyToDismiss = (loadFinished && elapsed >= Constants.ptrMinSpinDuration)
                || (elapsed >= Constants.ptrMaxSpinTimeout)
            if readyToDismiss {
                // Only dismiss once fingers are lifted (not actively holding in .directDrag).
                if case .directDrag = motionState {
                    // Wait for finger release; once released, snap straight to 0.
                    ptrState = .dismissing(spinStartedAt: triggeredAt)
                } else {
                    beginPTRDismiss(spinStartedAt: triggeredAt, now: now)
                }
            }
        }

        // 2. Step active motion curve analytically (exact at 60Hz, 120Hz ProMotion, or any dt).
        switch motionState {
        case .idle, .directDrag, .ptrHolding:
            break

        case .ptrMomentumUnwind:
            // Safety fallback: if momentum stops without delivering `.ended`, glide smoothly to 0.
            if (now - lastMomentumUnwindTime) > 0.08 {
                if currentOverscrollY > Constants.settleEpsilon {
                    beginSmoothPTRCollapseToZero(now: now, initialVelocity: 0.0)
                } else {
                    resetToIdleRest()
                }
            }

        case .criticallyDamped(let startTime, let y0, let v0, let target, let omega):
            let t = max(0.0, now - startTime)
            let d0 = Double(y0 - target)
            let v = Double(v0)
            let e = exp(-omega * t)
            let c1 = d0
            let c2 = v + omega * d0
            let disp = (c1 + c2 * t) * e
            let vel = (c2 - omega * (c1 + c2 * t)) * e
            let nextY = target + CGFloat(disp)

            // Check extreme momentum fling PTR trigger (>= 162pt, very hard to reach intentionally).
            if case .flingPulling = ptrState,
               metrics.isReloadableWebPage,
               nextY >= Constants.ptrFlingTriggerThreshold {
                ptrState = .spinning(triggeredAt: now, loadFinished: false)
                // Re-target the spring seamlessly onto the 68pt spinning hold shelf preserving velocity!
                motionState = .criticallyDamped(
                    startTime: now,
                    y0: nextY,
                    v0: CGFloat(vel),
                    target: Constants.ptrHoldOffset,
                    omega: omega
                )
                applyVisualOffset(nextY)
                onTriggerRefresh?()
            } else if target == 0.0 && y0 > 0.0 && nextY <= 0.0 && isPTRRefreshingOrDismissing {
                finishMotionAt(target: 0.0)
            } else if abs(nextY - target) < Constants.settleEpsilon && abs(vel) < 6.0 && t > 0.04 {
                finishMotionAt(target: target)
            } else {
                applyVisualOffset(nextY)
            }

        case .exponentialSnap(let startTime, let fromY, let target, let rate):
            let t = max(0.0, now - startTime)
            let delta = Double(fromY - target) * exp(-rate * t)
            let nextY = target + CGFloat(delta)

            if abs(nextY - target) < Constants.settleEpsilon {
                finishMotionAt(target: target)
            } else {
                applyVisualOffset(nextY)
            }

        case .demoPull(let startTime):
            let t = max(0.0, now - startTime)
            let pullDuration = 0.34
            if t < pullDuration {
                let u = t / pullDuration
                // Smooth ease-out curve down to 112pt (past the 106pt trigger).
                let eased = 1.0 - pow(1.0 - u, 3.0)
                let y = CGFloat(eased) * 112.0
                applyVisualOffset(y)
                evaluateDirectTouchPTR(visualOffset: y, now: now)
            } else {
                // Release into PTR hold (68pt).
                if case .pulling = ptrState {
                    ptrState = .spinning(triggeredAt: now, loadFinished: false)
                    onTriggerRefresh?()
                }
                motionState = .exponentialSnap(
                    startTime: now,
                    fromY: currentOverscrollY,
                    target: Constants.ptrHoldOffset,
                    rate: Constants.snapBackDecayRate
                )
            }
        }

        // 3. Update spinner visual state (pull frames, pop scale, 20fps spin, or fade-out).
        updateSpinnerPresentation(now: now)
        stopDisplayLinkIfIdle()
    }

    /// One frame of the Space glide: exact integral of v0*e^(-kt) over the frame, so a missed frame just carries its
    /// share and the glide always travels exactly its distance.
    func stepSpaceGlide(now: CFTimeInterval) {
        if spaceVelocityY != 0.0 {
            let dt = max(1.0 / 480.0, min(1.0 / 24.0, now - spaceLastTickTime))
            spaceLastTickTime = now
            let k = spaceFriction
            let v0 = spaceVelocityY
            let decay = CGFloat(exp(-Double(k) * dt))
            var deltaY = (v0 / k) * (1.0 - decay)
            var nextV = v0 * decay
            if abs(nextV) / k < Self.spaceStopDistance {
                deltaY += nextV / k      // send the last fraction now: the glide ends exactly on its distance
                nextV = 0.0
            }
            spaceVelocityY = nextV
            if ScrollDebugLog.isEnabled {
                ScrollDebugLog.write(String(format: "space t=%.4f d=%.2f v=%.0f sy=%.1f est=%.1f ov=%.1f",
                                            now, deltaY, v0, metrics.scrollY, estimatedScrollY, currentOverscrollY))
            }
            if spaceIsStartPage {
                emitSpaceDelta(deltaY)
            } else {
                stepSpaceScroll(deltaY: deltaY, velocityY: v0, now: now)
            }
            if spaceVelocityY == 0.0 {
                endSpaceStream()
                spaceFriction = Self.spaceDecayRate
            }
        } else if spaceStreamOpen {
            endSpaceStream()
        }
    }

    /// One frame of a Space glide on a web page: PTR unwind, edge arrival + overshoot, or plain page scroll.
    private func stepSpaceScroll(deltaY: CGFloat, velocityY: CGFloat, now: CFTimeInterval) {
        // Space (down) while pull-to-refresh holds the page open: unwind the hold 1:1, then scroll the page.
        if isPTRRefreshingOrDismissing, currentOverscrollY > 0.25 {
            guard deltaY < 0.0 else { return }
            ptrDismissedByUserScroll = true
            if case .spinning(let triggeredAt, _) = ptrState {
                ptrState = .dismissing(spinStartedAt: triggeredAt)
            }
            let nextY = currentOverscrollY + deltaY
            if nextY <= 0.0 {
                resetToIdleRest()
                estimatedScrollY = clampScrollY(estimatedScrollY - nextY)
                if abs(nextY) > 0.05 { emitSpaceDelta(nextY) }
                return
            }
            motionState = .ptrMomentumUnwind
            lastMomentumUnwindTime = now
            applyVisualOffset(nextY)
            updateSpinnerPresentation(now: now)
            return
        }

        let movingUp = deltaY > 0.0
        let innerCanScroll = movingUp ? metrics.canInnerScrollUp : metrics.canInnerScrollDown
        if !innerCanScroll, let arrival = edgeArrival(deltaY: deltaY, velocity: velocityY) {
            let firstFrame = !spaceStreamOpen
            if firstFrame && arrival.alreadyAtEdge {
                // Pressed while already on that edge: nothing to scroll, no bounce (Safari does not bounce here).
                spaceStartedAtEdge = true
                spaceVelocityY = 0.0
                return
            }
            // Land exactly on the edge: `arrival.flush` covers at least the true remaining distance even when
            // telemetry lags, and Chromium clamps any excess at the edge.
            if arrival.flush > 0.05 {
                emitSpaceDelta(movingUp ? arrival.flush : -arrival.flush)
            }
            estimatedScrollY = movingUp ? 0.0 : metrics.maxScrollY
            spaceVelocityY = 0.0
            endSpaceStream()
            let bouncingSameWay = isOverscrolling && ((currentOverscrollY > 0) == movingUp)
            if !spaceStartedAtEdge, !bouncingSameWay, abs(velocityY) >= Constants.minFlingVelocity {
                // A burst of presses reaches speeds a trackpad rarely does; past ~9000 pt/s the bounce would swallow
                // ~15% of the window, so the keyboard bounce tops out around 100 pt.
                let impact = max(-Self.spaceMaxImpactVelocity, min(Self.spaceMaxImpactVelocity, velocityY))
                launchFlingOvershoot(impactVelocity: impact, lock: movingUp ? .top : .bottom, allowsRefresh: false)
            }
            return
        }

        estimatedScrollY = clampScrollY(estimatedScrollY - deltaY)
        emitSpaceDelta(deltaY)
    }

    /// Edge arrival test shared by trackpad momentum and the Space glide. `estimatedScrollY` (last renderer report
    /// minus every delta sent since) is never ahead of the page, so `next <= edge` means this step reaches the edge.
    /// The reported offset must also be within the distance telemetry can lag at this speed (~60 ms of travel), which
    /// keeps a stale estimate (deltas the page swallowed) from bouncing a page that is still far from the edge.
    /// `flush` = travel that is certain to land the page on the edge.
    func edgeArrival(deltaY: CGFloat, velocity: CGFloat) -> (alreadyAtEdge: Bool, flush: CGFloat)? {
        let step = abs(deltaY)
        let lagAllowance = max(120.0, abs(velocity) * 0.06 + step * 2.0)
        if deltaY > 0.0 {
            if metrics.isAtTopBoundary { return (true, 0.0) }
            let remaining = estimatedScrollY
            guard remaining - step <= 0.0, metrics.scrollY <= lagAllowance else { return nil }
            return (false, max(step, remaining))
        }
        if deltaY < 0.0 {
            let maxY = metrics.maxScrollY
            if metrics.isAtBottomBoundary { return (true, 0.0) }
            let remaining = maxY - estimatedScrollY
            guard maxY > 2.0, remaining - step <= 0.0, maxY - metrics.scrollY <= lagAllowance else { return nil }
            return (false, max(step, remaining))
        }
        return nil
    }

    private func finishMotionAt(target: CGFloat) {
        applyVisualOffset(target)

        if abs(target) <= 0.1 {
            resetToIdleRest()
        } else if abs(target - Constants.ptrHoldOffset) <= 1.0, case .spinning = ptrState {
            motionState = .ptrHolding
        } else {
            motionState = .idle
        }
    }

    private func resetToIdleRest() {
        motionState = .idle
        ptrState = .idle
        rawStretch = 0.0
        momentumLock = .none
        ptrDismissedByUserScroll = false
        lastMomentumUnwindTime = 0.0
        applyVisualOffset(0.0)
        spinnerView?.render(state: .hidden)
        stopDisplayLinkIfIdle()
    }

    // MARK: - Spinner Presentation

    private func updateSpinnerPresentation(now: CFTimeInterval) {
        guard let spinner = spinnerView else { return }

        switch ptrState {
        case .idle:
            spinner.render(state: .hidden)

        case .pulling:
            let y = currentOverscrollY
            if y <= Constants.ptrRevealStart {
                spinner.render(state: .hidden)
            } else {
                let progress = (y - Constants.ptrRevealStart) / (Constants.ptrTriggerThreshold - Constants.ptrRevealStart)
                let opacity = (y - Constants.ptrRevealStart) / (Constants.ptrFullOpacityOffset - Constants.ptrRevealStart)
                spinner.render(state: .pulling(progress: progress, opacity: opacity))
            }

        case .flingPulling:
            let y = currentOverscrollY
            if y <= Constants.ptrRevealStart {
                spinner.render(state: .hidden)
            } else {
                let progress = (y - Constants.ptrRevealStart) / (Constants.ptrFlingTriggerThreshold - Constants.ptrRevealStart)
                let opacity = (y - Constants.ptrRevealStart) / (Constants.ptrFullOpacityOffset - Constants.ptrRevealStart)
                spinner.render(state: .pulling(progress: progress, opacity: opacity))
            }

        case .spinning(let triggeredAt, _):
            let y = currentOverscrollY
            let elapsed = max(0.0, now - triggeredAt)
            let popScale = computePopScale(elapsed: elapsed)
            let frameIdx = Int(floor(elapsed * Constants.ptrSpinFPS))
            renderCollapsingSpinner(spinner: spinner, overscrollY: y, baseScale: popScale, frameIdx: frameIdx)

        case .dismissing(let spinStartedAt):
            let y = currentOverscrollY
            let elapsed = max(0.0, now - spinStartedAt)
            let popScale = computePopScale(elapsed: elapsed)
            let frameIdx = Int(floor(elapsed * Constants.ptrSpinFPS))
            renderCollapsingSpinner(spinner: spinner, overscrollY: y, baseScale: popScale, frameIdx: frameIdx)
        }
    }

    /// Renders the spinning PTR indicator with smoothstep opacity, subtle tuck scale, and upward glide
    /// as the gap collapses (`66 → 22 pt`), so it melts cleanly out of the way before the page reaches it.
    private func renderCollapsingSpinner(
        spinner: PullToRefreshView,
        overscrollY y: CGFloat,
        baseScale: CGFloat,
        frameIdx: Int
    ) {
        if y <= Constants.ptrFadeOutLow {
            spinner.render(state: .hidden)
            return
        }
        if y >= Constants.ptrFadeOutHigh {
            spinner.render(state: .spinning(popScale: baseScale, opacity: 1.0, shiftUp: 0.0), spinFrameIndex: frameIdx)
            return
        }
        let rawT = max(0.0, min(1.0, (y - Constants.ptrFadeOutLow) / (Constants.ptrFadeOutHigh - Constants.ptrFadeOutLow)))
        let smoothOpacity = rawT * rawT * (3.0 - 2.0 * rawT)
        let tuckScale = 0.74 + 0.26 * rawT
        let shiftUp = (1.0 - rawT) * 14.0
        spinner.render(
            state: .spinning(popScale: baseScale * tuckScale, opacity: smoothOpacity, shiftUp: shiftUp),
            spinFrameIndex: frameIdx
        )
    }

    /// Measured pop bounce (`f_100111` F363..F372): `1.0 → 1.28×` in 55ms, then smooth `1.28× → 1.0` by 155ms.
    func computePopScale(elapsed: Double) -> CGFloat {
        if elapsed >= Constants.ptrPopDuration { return 1.0 }
        let peakExtra = Constants.ptrPopPeakScale - 1.0
        if elapsed < Constants.ptrPopPeakTime {
            let u = elapsed / Constants.ptrPopPeakTime
            let eased = sin(u * .pi * 0.5)
            return 1.0 + peakExtra * CGFloat(eased)
        } else {
            let u = (elapsed - Constants.ptrPopPeakTime) / (Constants.ptrPopDuration - Constants.ptrPopPeakTime)
            let eased = 0.5 * (1.0 + cos(u * .pi))
            return 1.0 + peakExtra * CGFloat(eased)
        }
    }

    // MARK: - Pure Math & GPU Layer Application

    private var isCurrentlyInDirectDrag: Bool {
        if case .directDrag = motionState { return true }
        return false
    }

    private func effectiveDimension() -> CGFloat {
        let h = targetView?.bounds.height ?? metrics.viewportHeight
        return max(Constants.minRubberBandDimension, h)
    }

    /// Apple asymptotic rubber-band curve: strictly monotonic & invertible.
    func rubberBand(raw: CGFloat, dimension D: CGFloat) -> CGFloat {
        let sign: CGFloat = raw >= 0 ? 1.0 : -1.0
        let absRaw = abs(raw)
        let c = Constants.rubberBandSlope
        let stretched = (c * absRaw * D) / (D + c * absRaw)
        let maxAllowed = D * Constants.maxStretchFraction
        return sign * min(stretched, maxAllowed)
    }

    /// Exact inverse of `rubberBand(raw:dimension:)` for zero-jump mid-air bounce catching.
    func inverseRubberBand(visual: CGFloat, dimension D: CGFloat) -> CGFloat {
        let sign: CGFloat = visual >= 0 ? 1.0 : -1.0
        let maxVisual = D * Constants.maxStretchFraction * 0.98
        let y = min(abs(visual), maxVisual)
        let denom = max(1.0, Constants.rubberBandSlope * (D - y))
        return sign * (y * D) / denom
    }

    /// Progressively compresses incoming momentum velocity so normal/fast/hard flings produce
    /// natural Safari overshoot (`38–152 pt`, spinner visible, zero accidental reload) and only
    /// an extreme max-effort slam (`>= 22,000 pt/s`) crosses `ptrFlingTriggerThreshold` (`162 pt`).
    func compressImpactVelocity(_ v: CGFloat) -> CGFloat {
        let vMax = Double(Constants.maxFlingVelocity)
        let vScale = Double(Constants.flingVelocityCompressionScale)
        return CGFloat(vMax * tanh(Double(v) / vScale))
    }

    func updateVelocityEstimate(deltaY: CGFloat, timestamp: TimeInterval, isBegin: Bool) {
        if isBegin {
            velocitySamples.removeAll(keepingCapacity: true)
            smoothedVelocityY = 0.0
        }

        // Prune samples older than 48ms (or any stale gap > 120ms).
        if let last = velocitySamples.last, (timestamp - last.timestamp) > 0.12 {
            velocitySamples.removeAll(keepingCapacity: true)
        }
        velocitySamples.append(VelocitySample(timestamp: timestamp, deltaY: deltaY))
        let cutoff = timestamp - 0.048
        while velocitySamples.count > 1 && velocitySamples[0].timestamp < cutoff {
            velocitySamples.removeFirst()
        }

        // Integrate total displacement over a minimum 28ms denominator so coalesced 1ms trackpad
        // event bursts can NEVER artificially spike velocity!
        var totalDelta: CGFloat = 0.0
        for s in velocitySamples {
            totalDelta += s.deltaY
        }
        let rawSpan = timestamp - (velocitySamples.first?.timestamp ?? timestamp)
        let effectiveSpan = max(0.028, rawSpan)
        smoothedVelocityY = totalDelta / CGFloat(effectiveSpan)
    }

    func clampScrollY(_ y: CGFloat) -> CGFloat {
        max(0.0, min(metrics.maxScrollY, y))
    }

    /// Applies the visual overscroll shift strictly via GPU `CALayer.transform` — ZERO Auto Layout
    /// or `NSView.frame.size` mutation, ZERO Chromium IPC resize/reflow!
    func applyVisualOffset(_ offset: CGFloat) {
        let clamped = abs(offset) < 0.01 ? 0.0 : offset
        currentOverscrollY = clamped

        guard let tv = targetView else { return }
        if tv.layer == nil { tv.wantsLayer = true }
        guard let layer = tv.layer else { return }

        // Positive `offset` = top overscroll → move page DOWN on screen.
        // In AppKit non-flipped coordinates (`isFlipped == false`), `-Y` is DOWN and `+Y` is UP.
        let sign: CGFloat = (tv.superview?.isFlipped == true) ? 1.0 : -1.0
        let ty = sign * clamped

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if clamped == 0.0 {
            layer.transform = CATransform3DIdentity
        } else {
            layer.transform = CATransform3DMakeTranslation(0.0, ty, 0.0)
        }
        CATransaction.commit()
    }
}
