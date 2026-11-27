import AppKit
import QuartzCore

/// Native 120Hz two-finger trackpad Back / Forward swipe navigation engine matching macOS Safari:
/// - Swiping right (Back): slides the current page smoothly to the right with a crisp left-edge drop shadow
///   while revealing the previous page's cached snapshot underneath (with subtle parallax & dimming veil).
/// - Swiping left (Forward): slides the next page's cached snapshot smoothly in from the right edge
///   over the current page (which parallax-shifts slightly left with a soft dimming veil).
/// - Commits on >= 30% width progress or fast flick velocity (>= 520 pt/s); otherwise springs smoothly back.
final class SwipeNavigationController: NSObject {
    enum Direction {
        case back    // two fingers swipe right (scrollingDeltaX > 0)
        case forward // two fingers swipe left  (scrollingDeltaX < 0)
    }

    var canGoBack: (() -> Bool)?
    var canGoForward: (() -> Bool)?
    /// Returns a cached snapshot payload for the destination page (previous page for `.back`, next page for `.forward`).
    var snapshotForDirection: ((Direction) -> NavigationSnapshotPayload?)?
    /// Supplies the active top toolbar + tab-strip inset so web snapshots register 1:1 with `webContentHost`.
    var topContentInsetProvider: (() -> CGFloat)?
    /// Invoked once the commit animation reaches 100%.
    var onCommitNavigation: ((Direction) -> Void)?

    private weak var stageView: NSView?
    private weak var targetPageView: NSView?

    private enum State {
        case idle
        case tracking(Direction)
        case animating(Direction, committing: Bool)
    }

    private var state: State = .idle
    private var rawOffsetX: CGFloat = 0.0
    private var velocityX: CGFloat = 0.0
    private var lastEventTime: CFTimeInterval = 0.0
    private var activeDirection: Direction?
    /// Prevents mid-pan back/forward triggers when a horizontal pan started away from the X boundary.
    private var gestureBlockedForCurrentTouch: Bool = false

    // Overlay views placed inside `stageView` during an active swipe:
    // For `.back`:
    //   underlayView sits BELOW `targetPageView` showing the previous page snapshot
    //   shadowView tracks the leading edge of `targetPageView`
    // For `.forward`:
    //   forwardSlideView sits ABOVE `targetPageView` showing the next page snapshot sliding in from the right
    private var underlayView: SwipeSnapshotLayerView?
    private var dimVeilView: NSView?
    private var edgeShadowView: SwipeEdgeShadowView?
    private var forwardSlideView: SwipeSnapshotLayerView?
    private var settleTimer: Timer?

    var isTrackingOrAnimating: Bool {
        if case .idle = state { return false }
        return true
    }

    /// True while a committed trackpad swipe snapshot is still pinned awaiting `finishTransitionRevealIfNeeded`.
    var isHoldingCommittedSnapshot: Bool {
        settleTimer != nil
    }

    func attach(stageView: NSView, targetPageView: NSView) {
        self.stageView = stageView
        self.targetPageView = targetPageView
    }

    /// Re-targets the active foreground view (e.g. `webContentHost` vs `startPageView`).
    func setActiveTargetView(_ view: NSView) {
        if case .idle = state {
            self.targetPageView = view
        }
    }

    /// Dismisses any lingering post-commit snapshot smoothly once the real destination page paints
    /// (fast crossfade on instant BFCache restore, smooth crossfade on fresh-load first paint).
    func finishTransitionRevealIfNeeded(fromBFCache: Bool = false) {
        guard settleTimer != nil else { return }
        settleTimer?.invalidate()
        settleTimer = nil
        fadeOutAndCleanup(duration: fromBFCache ? 0.08 : 0.14)
    }

    func cancelImmediately() {
        settleTimer?.invalidate()
        settleTimer = nil
        resetTargetTransform()
        removeOverlays()
        state = .idle
        activeDirection = nil
        rawOffsetX = 0
        velocityX = 0
        gestureBlockedForCurrentTouch = false
    }

    /// Processes a trackpad `.scrollWheel` event. Returns `true` when consumed by swipe navigation.
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }

        // Never start a fresh swipe from momentum events after finger lift
        let isMomentum = event.momentumPhase != []
        let phase = event.phase

        if phase.contains(.began) || phase.contains(.mayBegin) {
            gestureBlockedForCurrentTouch = false
        }
        defer {
            if phase.contains(.ended) || phase.contains(.cancelled) {
                gestureBlockedForCurrentTouch = false
            }
        }

        switch state {
        case .animating:
            // Swallow residual momentum from the gesture we just committed/cancelled
            return isMomentum || phase != []

        case .idle:
            if isMomentum || gestureBlockedForCurrentTouch { return false }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if abs(dy) > abs(dx) * 1.15 && abs(dy) > 2.5 {
                gestureBlockedForCurrentTouch = true
                return false
            }
            guard abs(dx) > 1.5, abs(dx) > abs(dy) * 1.35 else { return false }

            // Direct touch only (`.began` or `.changed` early in touch)
            guard phase.contains(.began) || phase.contains(.changed) else { return false }

            let dir: Direction = dx > 0 ? .back : .forward
            if dir == .back && !(canGoBack?() ?? false) {
                gestureBlockedForCurrentTouch = true
                return false
            }
            if dir == .forward && !(canGoForward?() ?? false) {
                gestureBlockedForCurrentTouch = true
                return false
            }

            beginSwipe(direction: dir, initialDeltaX: dx, timestamp: event.timestamp)
            return true

        case .tracking(let dir):
            if isMomentum {
                // Finger lifted and momentum started — finalize immediately
                endSwipe(direction: dir)
                return true
            }
            if phase.contains(.ended) || phase.contains(.cancelled) {
                endSwipe(direction: dir)
                return true
            }

            let dx = event.scrollingDeltaX
            let now = event.timestamp
            let dt = max(0.004, now - lastEventTime)
            velocityX = velocityX * 0.55 + (dx / CGFloat(dt)) * 0.45
            lastEventTime = now

            rawOffsetX += dx
            updateVisuals(direction: dir)
            return true
        }
    }

    private func beginSwipe(direction: Direction, initialDeltaX: CGFloat, timestamp: CFTimeInterval) {
        guard let stage = stageView, let target = targetPageView else { return }
        settleTimer?.invalidate()
        settleTimer = nil
        removeOverlays()

        state = .tracking(direction)
        activeDirection = direction
        rawOffsetX = initialDeltaX
        velocityX = 0
        lastEventTime = timestamp

        target.wantsLayer = true
        let bounds = stage.bounds
        let payload = snapshotForDirection?(direction)
        let topInset = topContentInsetProvider?() ?? SafariMetrics.toolbarHeight

        if direction == .back {
            // Underlay showing previous page snapshot sits directly below `target`
            let under = SwipeSnapshotLayerView(frame: bounds, payload: payload, topContentInset: topInset)
            under.autoresizingMask = [.width, .height]
            stage.addSubview(under, positioned: .below, relativeTo: target)
            self.underlayView = under

            // Subtle dimming veil over the revealed previous page
            let veil = NSView(frame: bounds)
            veil.autoresizingMask = [.width, .height]
            veil.wantsLayer = true
            veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
            stage.addSubview(veil, positioned: .above, relativeTo: under)
            self.dimVeilView = veil

            // Crisp soft drop shadow hugging the left edge of the sliding current page
            let shadowW: CGFloat = 24
            let shadow = SwipeEdgeShadowView(frame: NSRect(x: -shadowW, y: 0, width: shadowW, height: bounds.height))
            shadow.autoresizingMask = [.height]
            stage.addSubview(shadow, positioned: .above, relativeTo: veil)
            self.edgeShadowView = shadow
        } else {
            // Subtle dimming veil over current page as next page slides in from right
            let veil = NSView(frame: bounds)
            veil.autoresizingMask = [.width, .height]
            veil.wantsLayer = true
            veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.0).cgColor
            stage.addSubview(veil, positioned: .above, relativeTo: target)
            self.dimVeilView = veil

            // Next page snapshot sliding in from the right edge
            let slide = SwipeSnapshotLayerView(frame: bounds, payload: payload, topContentInset: topInset)
            slide.autoresizingMask = [.width, .height]
            slide.layer?.transform = CATransform3DMakeTranslation(bounds.width, 0, 0)
            stage.addSubview(slide, positioned: .above, relativeTo: veil)
            self.forwardSlideView = slide

            // Crisp soft drop shadow hugging the left edge of the incoming next page
            let shadowW: CGFloat = 24
            let shadow = SwipeEdgeShadowView(frame: NSRect(x: bounds.width - shadowW, y: 0, width: shadowW, height: bounds.height))
            shadow.autoresizingMask = [.height]
            stage.addSubview(shadow, positioned: .above, relativeTo: veil)
            self.edgeShadowView = shadow
        }

        updateVisuals(direction: direction)
    }

    private func updateVisuals(direction: Direction) {
        guard let stage = stageView, let target = targetPageView else { return }
        let width = max(1.0, stage.bounds.width)
        let parallaxDepth = width * 0.22

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if direction == .back {
            let clamped = max(0.0, min(width, rawOffsetX))
            let progress = clamped / width
            target.layer?.transform = CATransform3DMakeTranslation(clamped, 0, 0)

            let underX = -parallaxDepth * (1.0 - progress)
            underlayView?.layer?.transform = CATransform3DMakeTranslation(underX, 0, 0)
            dimVeilView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14 * (1.0 - progress)).cgColor
            edgeShadowView?.frame.origin.x = clamped - 24.0
            edgeShadowView?.alphaValue = progress > 0.005 ? 1.0 : 0.0
        } else {
            let clamped = max(0.0, min(width, -rawOffsetX))
            let progress = clamped / width
            let incomingX = width - clamped
            forwardSlideView?.layer?.transform = CATransform3DMakeTranslation(incomingX, 0, 0)

            let currentX = -parallaxDepth * progress
            target.layer?.transform = CATransform3DMakeTranslation(currentX, 0, 0)
            dimVeilView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14 * progress).cgColor
            edgeShadowView?.frame.origin.x = incomingX - 24.0
            edgeShadowView?.alphaValue = progress > 0.005 ? 1.0 : 0.0
        }

        CATransaction.commit()
    }

    private func endSwipe(direction: Direction) {
        guard let stage = stageView, let target = targetPageView else {
            cancelImmediately()
            return
        }
        let width = max(1.0, stage.bounds.width)
        let distance = (direction == .back) ? max(0.0, rawOffsetX) : max(0.0, -rawOffsetX)
        let progress = distance / width
        let directedVel = (direction == .back) ? velocityX : -velocityX

        let shouldCommit = (progress >= 0.30) || (directedVel >= 520.0 && progress >= 0.06)
        state = .animating(direction, committing: shouldCommit)

        let duration: CFTimeInterval = shouldCommit
            ? max(0.14, min(0.26, Double(1.0 - progress) * 0.28))
            : max(0.14, min(0.24, Double(progress) * 0.28))
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        let parallaxDepth = width * 0.22

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            if shouldCommit {
                // Keep revealed snapshot cleanly visible while navigation settles, then crossfade out
                self.resetTargetTransform()
                self.edgeShadowView?.removeFromSuperview()
                self.edgeShadowView = nil
                self.dimVeilView?.removeFromSuperview()
                self.dimVeilView = nil

                // Promote the revealed snapshot ABOVE target briefly so there is zero white blink during page swap
                if direction == .back, let under = self.underlayView, let stage = self.stageView, let target = self.targetPageView {
                    under.layer?.transform = CATransform3DIdentity
                    stage.addSubview(under, positioned: .above, relativeTo: target)
                }

                // Arm `settleTimer` BEFORE `onCommitNavigation` so `isHoldingCommittedSnapshot` is true
                // when `navigateBackInActiveTab()` / `navigateForwardInActiveTab()` runs, preventing
                // `NavigationTransitionCoordinator` from stacking a duplicate programmatic veil.
                self.settleTimer?.invalidate()
                self.settleTimer = Timer.scheduledTimer(withTimeInterval: 1.80, repeats: false) { [weak self] _ in
                    self?.fadeOutAndCleanup(duration: 0.16)
                }

                self.state = .idle
                self.activeDirection = nil
                self.onCommitNavigation?(direction)
            } else {
                self.resetTargetTransform()
                self.removeOverlays()
                self.state = .idle
                self.activeDirection = nil
            }
        }

        if direction == .back {
            let finalTargetX = shouldCommit ? width : 0.0
            let finalUnderX = shouldCommit ? 0.0 : -parallaxDepth
            animateTranslationX(on: target.layer, to: finalTargetX, duration: duration, timing: timing)
            animateTranslationX(on: underlayView?.layer, to: finalUnderX, duration: duration, timing: timing)
            if let shadow = edgeShadowView {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = timing
                    shadow.animator().frame.origin.x = finalTargetX - 24.0
                    if !shouldCommit { shadow.animator().alphaValue = 0.0 }
                }
            }
            dimVeilView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(shouldCommit ? 0.0 : 0.14).cgColor
        } else {
            let finalIncomingX = shouldCommit ? 0.0 : width
            let finalCurrentX = shouldCommit ? -parallaxDepth : 0.0
            animateTranslationX(on: forwardSlideView?.layer, to: finalIncomingX, duration: duration, timing: timing)
            animateTranslationX(on: target.layer, to: finalCurrentX, duration: duration, timing: timing)
            if let shadow = edgeShadowView {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = timing
                    shadow.animator().frame.origin.x = finalIncomingX - 24.0
                    if !shouldCommit { shadow.animator().alphaValue = 0.0 }
                }
            }
            dimVeilView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(shouldCommit ? 0.14 : 0.0).cgColor
        }

        CATransaction.commit()
    }

    private func animateTranslationX(on layer: CALayer?, to targetX: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard let layer else { return }
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let targetTransform = CATransform3DMakeTranslation(targetX, 0, 0)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: currentTransform)
        anim.toValue = NSValue(caTransform3D: targetTransform)
        anim.duration = duration
        anim.timingFunction = timing
        layer.transform = targetTransform
        layer.add(anim, forKey: "swipeSettle")
    }

    private func fadeOutAndCleanup(duration: TimeInterval) {
        settleTimer?.invalidate()
        settleTimer = nil
        let toFade: [NSView] = [underlayView, forwardSlideView, dimVeilView, edgeShadowView].compactMap { $0 }
        guard !toFade.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for v in toFade { v.animator().alphaValue = 0.0 }
        }, completionHandler: { [weak self] in
            for v in toFade { v.removeFromSuperview() }
            if self?.underlayView != nil && toFade.contains(where: { $0 === self?.underlayView }) {
                self?.underlayView = nil
            }
            if self?.forwardSlideView != nil && toFade.contains(where: { $0 === self?.forwardSlideView }) {
                self?.forwardSlideView = nil
            }
            if self?.dimVeilView != nil && toFade.contains(where: { $0 === self?.dimVeilView }) {
                self?.dimVeilView = nil
            }
            if self?.edgeShadowView != nil && toFade.contains(where: { $0 === self?.edgeShadowView }) {
                self?.edgeShadowView = nil
            }
        })
    }

    private func resetTargetTransform() {
        guard let layer = targetPageView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "swipeSettle")
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func removeOverlays() {
        underlayView?.removeFromSuperview()
        underlayView = nil
        forwardSlideView?.removeFromSuperview()
        forwardSlideView = nil
        dimVeilView?.removeFromSuperview()
        dimVeilView = nil
        edgeShadowView?.removeFromSuperview()
        edgeShadowView = nil
    }
}

/// GPU-backed resize-safe snapshot view used underneath/above during trackpad swipe navigation.
/// When the window size matches capture size (within 2pt), fills the viewport cleanly; when resized,
/// anchors the snapshot top-left at its original logical dimensions over the page's background color
/// so text and UI never stretch or distort.
final class SwipeSnapshotLayerView: NSView {
    private let imageLayer = CALayer()
    private let capturedLogicalSize: CGSize
    private let isFullBleedBehindToolbar: Bool
    private let topContentInset: CGFloat

    init(frame: NSRect, payload: NavigationSnapshotPayload?, topContentInset: CGFloat = SafariMetrics.toolbarHeight) {
        self.capturedLogicalSize = payload?.logicalSize ?? .zero
        self.isFullBleedBehindToolbar = payload?.isFullBleedBehindToolbar ?? false
        self.topContentInset = max(0.0, topContentInset)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        let bg = payload?.backgroundColor ?? NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1.0)
        layer?.backgroundColor = bg.cgColor

        imageLayer.contentsGravity = .resize
        imageLayer.masksToBounds = true
        if let img = payload?.image, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cg
            layer?.addSublayer(imageLayer)
        }
        layoutImageLayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutImageLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func layoutImageLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        // Non-flipped AppKit coordinates (`y = 0` at bottom): full-bleed native pages span `0..b.height`,
        // whereas web snapshots captured from `webContentHost` span `0..(b.height - topContentInset)`.
        let targetHeight = isFullBleedBehindToolbar ? b.height : max(1.0, b.height - topContentInset)
        let targetRect = CGRect(x: 0.0, y: 0.0, width: b.width, height: targetHeight)
        if capturedLogicalSize.width >= 32, capturedLogicalSize.height >= 32 {
            let dw = abs(targetRect.width - capturedLogicalSize.width)
            let dh = abs(targetRect.height - capturedLogicalSize.height)
            if dw <= 2.0 && dh <= 2.0 {
                imageLayer.frame = targetRect
            } else {
                // Anchor to top-left of the content viewport (`y = targetRect.maxY - capturedHeight`).
                imageLayer.frame = CGRect(
                    x: 0.0,
                    y: targetRect.maxY - capturedLogicalSize.height,
                    width: capturedLogicalSize.width,
                    height: capturedLogicalSize.height
                )
            }
        } else {
            imageLayer.frame = targetRect
        }
        CATransaction.commit()
    }
}

/// Soft vertical gradient drop shadow hugging the leading edge of a sliding page (exact Safari swipe depth).
private final class SwipeEdgeShadowView: NSView {
    private let grad = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        grad.colors = [
            NSColor.black.withAlphaComponent(0.0).cgColor,
            NSColor.black.withAlphaComponent(0.06).cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor
        ]
        grad.locations = [0.0, 0.55, 1.0]
        grad.startPoint = CGPoint(x: 0.0, y: 0.5)
        grad.endPoint = CGPoint(x: 1.0, y: 0.5)
        grad.frame = bounds
        layer?.addSublayer(grad)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grad.frame = bounds
        CATransaction.commit()
    }
}
