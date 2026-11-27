import AppKit
import QuartzCore

/// Unified AppKit compositor freeze-frame & crossfade coordinator for Safarium.
///
/// Enforces the strict zero-flicker invariant above `RenderWidgetHostViewCocoa` and native pages:
/// no forward navigation from a native page (`safarium://start`, `history`, `inspect`), programmatic
/// Back/Forward jump (`Cmd+[`, `Cmd+]`, toolbar `<`/`>`, 3-finger `.swipe`), or cold background tab
/// switch ever exposes an unpainted `about:blank` or evicted GPU surface.
///
/// When idle (`isTransitionActive == false`), zero overlay views remain in the view hierarchy and
/// zero GPU overdraw occurs.
final class NavigationTransitionCoordinator: NSObject {
    enum TransitionKind: Equatable {
        case nativeToWeb
        case historyJump(SwipeNavigationController.Direction)
        case coldTabSwitch
    }

    /// Supplies the current top toolbar + tab-strip inset in `stageView` coordinates (default 52pt).
    var topContentInsetProvider: (() -> CGFloat)?

    /// Fired inside the reveal `NSAnimationContext` group right as the freeze-frame veil begins
    /// dissolving so deferred toolbar/chrome theme updates animate in lockstep with the viewport.
    var onWillRevealTransition: ((String) -> Void)?

    private weak var stageView: NSView?
    private weak var anchorAboveView: NSView?

    private var veilContainer: NonHitTestingVeilView?
    private var primarySnapshotView: SwipeSnapshotLayerView?
    private var outgoingCrossfadeView: SwipeSnapshotLayerView?
    private var settleTimer: Timer?
    private var transitionGeneration: UInt64 = 0

    private(set) var activeTabID: String?
    private(set) var activeKind: TransitionKind?

    /// Longest a veil waits for the incoming page's first contentful paint (`sx.nav_ready`) before giving up.
    /// Safari keeps the previous page until the new one has painted; this cap only covers pages that never do.
    static let maxHoldDuration: TimeInterval = 3.0

    var isTransitionActive: Bool {
        veilContainer != nil
    }

    var isHoldingNativeToWebVeil: Bool {
        activeKind == .nativeToWeb && settleTimer != nil && veilContainer != nil
    }

    /// Attaches the coordinator to `stageView`, inserting transient veils directly above `anchorAboveView`
    /// (above web and native page views, below floating popovers, find bar, Tab Overview, and toolbar glass).
    func attach(stageView: NSView, anchorAbove anchorAboveView: NSView) {
        self.stageView = stageView
        self.anchorAboveView = anchorAboveView
    }

    // MARK: - Transition Entry Points

    /// Freezes the outgoing native page (`Start Page`, `History`, `Inspect`) over the viewport while
    /// Chromium activates `SXBrowserTab` from `about:blank` and begins loading the target web URL.
    func beginNativeToWebTransition(tabID: String, outgoingPayload: NavigationSnapshotPayload) {
        guard let stage = stageView, stage.bounds.width > 2, stage.bounds.height > 2 else { return }
        cancelImmediately()

        transitionGeneration &+= 1
        let gen = transitionGeneration
        activeTabID = tabID
        activeKind = .nativeToWeb

        let topInset = topContentInsetProvider?() ?? SafariMetrics.toolbarHeight
        let container = installVeilContainer(in: stage)
        let snapView = SwipeSnapshotLayerView(frame: container.bounds, payload: outgoingPayload, topContentInset: topInset)
        snapView.autoresizingMask = [.width, .height]
        container.addSubview(snapView)
        self.primarySnapshotView = snapView

        // Perceptual hold cap (0.48s): long enough to mask DNS/TLS/FCP on fast/warm connections
        // and completely hide the `about:blank` activation hop, while gracefully dissolving into
        // the opaque theme-matched pre-paint canvas on slow networks so navigation never feels stuck.
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.maxHoldDuration, repeats: false) { [weak self] _ in
            guard let self, self.transitionGeneration == gen else { return }
            self.revealAndCleanup(duration: 0.12)
        }
    }

    /// Shields toolbar button (`<`/`>`), keyboard (`Cmd+[` / `Cmd+]`), and 3-finger `.swipe` history jumps
    /// that do not pass through 2-finger interactive `SwipeNavigationController` tracking.
    func beginProgrammaticHistoryTransition(
        tabID: String,
        direction: SwipeNavigationController.Direction,
        outgoingPayload: NavigationSnapshotPayload?,
        destinationPayload: NavigationSnapshotPayload?
    ) {
        guard let stage = stageView, stage.bounds.width > 2, stage.bounds.height > 2 else { return }
        guard outgoingPayload != nil || destinationPayload != nil else { return }
        cancelImmediately()

        transitionGeneration &+= 1
        let gen = transitionGeneration
        activeTabID = tabID
        activeKind = .historyJump(direction)

        let topInset = topContentInsetProvider?() ?? SafariMetrics.toolbarHeight
        let container = installVeilContainer(in: stage)

        if let dest = destinationPayload {
            let destView = SwipeSnapshotLayerView(frame: container.bounds, payload: dest, topContentInset: topInset)
            destView.autoresizingMask = [.width, .height]
            container.addSubview(destView)
            self.primarySnapshotView = destView

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if let out = outgoingPayload, !reduceMotion {
                let outView = SwipeSnapshotLayerView(frame: container.bounds, payload: out, topContentInset: topInset)
                outView.autoresizingMask = [.width, .height]
                container.addSubview(outView, positioned: .above, relativeTo: destView)
                self.outgoingCrossfadeView = outView

                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.085
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    outView.animator().alphaValue = 0.0
                }, completionHandler: { [weak self, weak outView] in
                    outView?.removeFromSuperview()
                    if self?.outgoingCrossfadeView === outView {
                        self?.outgoingCrossfadeView = nil
                    }
                })
            }

            settleTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self] _ in
                guard let self, self.transitionGeneration == gen else { return }
                self.revealAndCleanup(duration: 0.10)
            }
        } else if let out = outgoingPayload {
            let outView = SwipeSnapshotLayerView(frame: container.bounds, payload: out, topContentInset: topInset)
            outView.autoresizingMask = [.width, .height]
            container.addSubview(outView)
            self.primarySnapshotView = outView

            settleTimer = Timer.scheduledTimer(withTimeInterval: Self.maxHoldDuration, repeats: false) { [weak self] _ in
                guard let self, self.transitionGeneration == gen else { return }
                self.revealAndCleanup(duration: 0.11)
            }
        }
    }

    /// Shields cold background-to-foreground tab switches (`selectTab(at:)`) against 1–3 frame
    /// blank flashes when Chromium's Viz compositor has evicted a background tab's `IOSurface`.
    func beginColdTabSwitchShield(tabID: String, snapshotPayload: NavigationSnapshotPayload) {
        guard let stage = stageView, stage.bounds.width > 2, stage.bounds.height > 2 else { return }
        cancelImmediately()

        transitionGeneration &+= 1
        let gen = transitionGeneration
        activeTabID = tabID
        activeKind = .coldTabSwitch

        let topInset = topContentInsetProvider?() ?? SafariMetrics.toolbarHeight
        let container = installVeilContainer(in: stage)
        let snapView = SwipeSnapshotLayerView(frame: container.bounds, payload: snapshotPayload, topContentInset: topInset)
        snapView.autoresizingMask = [.width, .height]
        container.addSubview(snapView)
        self.primarySnapshotView = snapView

        // Match Chromium's 66ms UI compositor surface-sync window (~8 frames at 120Hz).
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.068, repeats: false) { [weak self] _ in
            guard let self, self.transitionGeneration == gen else { return }
            self.revealAndCleanup(duration: 0.06)
        }
    }

    // MARK: - Completion & Teardown

    /// Called when `sx.nav_ready` (`didBecomeVisuallyReadyForNavigation`) or load completion signals
    /// that the live destination surface has painted real content underneath the veil.
    func completeTransitionIfNeeded(tabID: String, fromBFCache: Bool = false) {
        guard activeTabID == tabID, settleTimer != nil else { return }
        // The incoming page is painted: swap in one frame, as Safari does. A dissolve here would blend two
        // different pages (ghosting).
        revealAndCleanup(duration: 0)
    }

    func cancelImmediately() {
        transitionGeneration &+= 1
        settleTimer?.invalidate()
        settleTimer = nil
        outgoingCrossfadeView?.removeFromSuperview()
        outgoingCrossfadeView = nil
        primarySnapshotView?.removeFromSuperview()
        primarySnapshotView = nil
        veilContainer?.removeFromSuperview()
        veilContainer = nil
        activeTabID = nil
        activeKind = nil
    }

    // MARK: - Private Helpers

    private func installVeilContainer(in stage: NSView) -> NonHitTestingVeilView {
        let container = NonHitTestingVeilView(frame: stage.bounds)
        container.autoresizingMask = [.width, .height]
        if let anchor = anchorAboveView, anchor.superview === stage {
            stage.addSubview(container, positioned: .above, relativeTo: anchor)
        } else {
            stage.addSubview(container)
        }
        self.veilContainer = container
        return container
    }

    private func revealAndCleanup(duration: TimeInterval) {
        settleTimer?.invalidate()
        settleTimer = nil

        guard let container = veilContainer else {
            activeTabID = nil
            activeKind = nil
            return
        }

        let revealingTabID = activeTabID
        let gen = transitionGeneration

        if duration <= 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let revealingTabID {
                onWillRevealTransition?(revealingTabID)
            }
            container.removeFromSuperview()
            CATransaction.commit()
            outgoingCrossfadeView = nil
            primarySnapshotView = nil
            veilContainer = nil
            activeTabID = nil
            activeKind = nil
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)
            if let revealingTabID {
                self.onWillRevealTransition?(revealingTabID)
            }
            container.animator().alphaValue = 0.0
        }, completionHandler: { [weak self, weak container] in
            container?.removeFromSuperview()
            guard let self, self.transitionGeneration == gen else { return }
            self.outgoingCrossfadeView = nil
            self.primarySnapshotView = nil
            self.veilContainer = nil
            self.activeTabID = nil
            self.activeKind = nil
        })
    }
}

/// Pure compositor container that never intercepts clicks, hover, or trackpad scroll events
/// so users can immediately scroll or click the newly revealed page even during the 80–110ms dissolve.
private final class NonHitTestingVeilView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
