import AppKit
import QuartzCore

/// Complete live payload for moving a tab between Safarium windows without reloading WebContents.
struct DetachedTabTransfer {
    let tab: BrowserTabEngine
    let loadError: BrowserPageLoadError?
    let theme: AdaptiveChromeTheme
}

/// Visual state captured at the exact moment a tab detaches from `CompactTabAddressBar`.
struct TabDragVisualSnapshot {
    let tabID: String
    let title: String
    let displayDomain: String
    let url: URL?
    let favicon: NSImage?
    let pageSnapshot: NSImage?
    let isActiveTab: Bool
    let isStartPage: Bool
    let isPrivate: Bool
    let isSingleTabSourceWindow: Bool
    let theme: AdaptiveChromeTheme
    let initialPillRectInScreen: NSRect
    /// Cursor position inside `initialPillRectInScreen`, measured from bottom-left of the pill.
    let cursorOffsetInPill: NSPoint
    let sourceWindowSize: NSSize
    let liveFrameSurface: IOSurface?
    let hasOtherCompatibleWindows: Bool

    init(
        tabID: String,
        title: String,
        displayDomain: String,
        url: URL?,
        favicon: NSImage?,
        pageSnapshot: NSImage?,
        isActiveTab: Bool,
        isStartPage: Bool,
        isPrivate: Bool,
        isSingleTabSourceWindow: Bool,
        theme: AdaptiveChromeTheme,
        initialPillRectInScreen: NSRect,
        cursorOffsetInPill: NSPoint,
        sourceWindowSize: NSSize,
        liveFrameSurface: IOSurface? = nil,
        hasOtherCompatibleWindows: Bool = true
    ) {
        self.tabID = tabID
        self.title = title
        self.displayDomain = displayDomain
        self.url = url
        self.favicon = favicon
        self.pageSnapshot = pageSnapshot
        self.isActiveTab = isActiveTab
        self.isStartPage = isStartPage
        self.isPrivate = isPrivate
        self.isSingleTabSourceWindow = isSingleTabSourceWindow
        self.theme = theme
        self.initialPillRectInScreen = initialPillRectInScreen
        self.cursorOffsetInPill = cursorOffsetInPill
        self.sourceWindowSize = sourceWindowSize
        self.liveFrameSurface = liveFrameSurface
        self.hasOtherCompatibleWindows = hasOtherCompatibleWindows
    }
}

/// Drop target resolved for any compatible Safarium window under the cursor.
struct TabBarDropTarget {
    weak var windowController: SafariWindowController?
    let insertionIndex: Int
    let slotRectInScreen: NSRect
    let theme: AdaptiveChromeTheme
}

/// 1:1 macOS 27 Safari 120Hz tab drag-and-drop coordinator:
/// - Pure vsync-locked `CADisplayLink` physics for BOTH live drag morphing and drop/bloom/cancel settlement.
/// - Zero per-frame `NSWindow` resizes (even during full-window bloom via single-allocation union canvas).
/// - Zero per-frame Auto Layout constraint solves, zero CPU snapshot redraws (pure GPU `CALayer.contents`),
///   explicit `shadowPath`, and guarded theme updates so every frame stays locked at 120fps ProMotion.
final class SafariTabDragCoordinator: NSObject {
    static let shared = SafariTabDragCoordinator()

    enum MorphMode: Equatable {
        case pill
        case preview
    }

    private(set) var isDragging: Bool = false

    private var dragPanel: TabDragCanvasPanel?
    private var cardView: TabDragMorphCardView?
    private weak var sourceWindowController: SafariWindowController?
    private weak var hoveredTargetWindowController: SafariWindowController?
    var activeSnapshot: TabDragVisualSnapshot?
    private var lastHoverTarget: TabBarDropTarget?

    // 120Hz continuous spring morph state (0.0 = exact tab pill, 1.0 = preview thumbnail)
    var morphProgress: CGFloat = 0.0
    var morphVelocity: CGFloat = 0.0
    var morphTarget: CGFloat = 0.0

    // Critically-damped pill width & vertical track magnet springs (zero pop on enter/leave!)
    var currentPillWidth: CGFloat = 240.0
    var pillWidthVelocity: CGFloat = 0.0
    var targetPillWidth: CGFloat = 240.0
    var trackMagnetAmount: CGFloat = 0.0
    var trackMagnetVelocity: CGFloat = 0.0
    var trackMagnetTarget: CGFloat = 0.0
    var lastTrackMidY: CGFloat = 0.0

    var previewSize: NSSize = NSSize(width: 288.0, height: 192.0)
    var currentCursorScreen: NSPoint = .zero
    private var dragDisplayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0.0

    // 120Hz CADisplayLink settlement / bloom animation state
    private struct SettleAnimState {
        let fromRect: NSRect
        let toRect: NSRect
        let fromMorph: CGFloat
        let toMorph: CGFloat
        let fadeOutPanel: Bool
        let bloomToWindowRadius: Bool
        let duration: CFTimeInterval
        let startTime: CFTimeInterval
        let extraStep: ((CGFloat) -> Void)?
        let completion: () -> Void
    }
    private var settleDisplayLink: CADisplayLink?
    private var settleState: SettleAnimState?

    private static let shadowPad: CGFloat = 40.0

    override init() {
        super.init()
    }

    /// Runs the 120Hz drag-and-drop session once the user tears a tab past the tab bar boundary.
    func runTearOffSession(
        from source: SafariWindowController,
        snapshot: TabDragVisualSnapshot,
        initialMouseScreen: NSPoint,
        liveSnapshotProvider: ((@escaping (NSImage?) -> Void) -> Void)?
    ) {
        guard !isDragging else { return }
        isDragging = true
        sourceWindowController = source
        activeSnapshot = snapshot
        hoveredTargetWindowController = nil
        lastHoverTarget = nil
        currentCursorScreen = initialMouseScreen

        // Preview thumbnail dimensions matching source window aspect ratio (exact Safari 27 proportion)
        let aspect = max(1.22, min(1.80, snapshot.sourceWindowSize.width / max(1.0, snapshot.sourceWindowSize.height)))
        let pW = round(max(264.0, min(304.0, snapshot.sourceWindowSize.width * 0.24)))
        let pH = round(pW / aspect)
        previewSize = NSSize(width: pW, height: pH)

        currentPillWidth = max(110.0, snapshot.initialPillRectInScreen.width)
        targetPillWidth = currentPillWidth
        pillWidthVelocity = 0.0
        morphProgress = 0.0
        morphVelocity = 0.0
        morphTarget = 0.0
        trackMagnetAmount = 0.0
        trackMagnetVelocity = 0.0
        trackMagnetTarget = 0.0
        lastTrackMidY = snapshot.initialPillRectInScreen.midY

        // Capture freshest Retina snapshot BEFORE source hides the torn-off tab's Chromium hostView
        liveSnapshotProvider? { [weak self] freshImage in
            guard let self, self.isDragging, let freshImage else { return }
            self.cardView?.updatePreviewSnapshot(freshImage)
        }

        // Hide dragged tab in source window (or softly fade single-tab source window)
        if snapshot.isSingleTabSourceWindow {
            source.setSingleTabTearOffGhosted(true)
        } else {
            source.setTearOffHiddenTab(id: snapshot.tabID)
        }

        // Single fixed generous borderless canvas panel: ZERO window resizes during the entire drag!
        let canvasW = max(currentPillWidth, previewSize.width, 380.0) + Self.shadowPad * 2.0
        let canvasH = max(SafariMetrics.tabInnerHeight, previewSize.height) + Self.shadowPad * 2.0
        let card = TabDragMorphCardView(snapshot: snapshot)
        let panel = TabDragCanvasPanel(canvasSize: NSSize(width: canvasW, height: canvasH), cardView: card)
        self.cardView = card
        self.dragPanel = panel

        // Frame 0: lock onto exact tab pill screen rect (zero jump!)
        applyCurrentVisualStateToPanel(snapToExactPillRect: snapshot.initialPillRectInScreen)
        panel.orderFrontRegardless()

        // Evaluate initial target so tearing out immediately launches the smooth pill -> preview spring
        evaluateCursorTarget(screenPoint: initialMouseScreen)
        startDragDisplayLink()

        var cancelled = false
        var finalScreenPoint = initialMouseScreen

        // Synchronous AppKit event tracking loop (handles multi-window, multi-display, Escape)
        while let event = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape cancels cleanly
                    cancelled = true
                    break
                }
                continue
            }

            let screenPt = NSEvent.mouseLocation
            finalScreenPoint = screenPt
            currentCursorScreen = screenPt

            if event.type == .leftMouseUp {
                break
            }

            evaluateCursorTarget(screenPoint: screenPt)
            // Fast GPU window-drag path once morphed in a single-tab single-window drag (zero layout/CGPath/blur work).
            if snapshot.isSingleTabSourceWindow,
               !snapshot.hasOtherCompatibleWindows,
               morphProgress >= 0.9999,
               abs(currentPillWidth - targetPillWidth) < 0.01,
               abs(trackMagnetAmount - trackMagnetTarget) < 0.01,
               let card = cardView,
               abs(card.bounds.width - previewSize.width) < 0.5,
               abs(card.bounds.height - previewSize.height) < 0.5 {
                let rect = computeCurrentCardScreenRect()
                dragPanel?.moveOriginOnly(toScreenRect: rect, shadowPad: Self.shadowPad)
            } else {
                // Immediately move panel origin to track cursor with zero latency; spring ticks on vsync!
                applyCurrentVisualStateToPanel()
            }
        }

        stopDragDisplayLink()

        if cancelled {
            finishCancel()
        } else {
            finishDrop(atScreenPoint: finalScreenPoint)
        }
    }

    // MARK: - 120Hz ProMotion Spring Physics

    private func startDragDisplayLink() {
        stopDragDisplayLink()
        guard let hostView = dragPanel?.contentView else { return }
        lastFrameTime = CACurrentMediaTime()
        let link = hostView.displayLink(target: self, selector: #selector(handleDragDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        link.add(to: .main, forMode: .eventTracking)
        dragDisplayLink = link
    }

    private func stopDragDisplayLink() {
        dragDisplayLink?.invalidate()
        dragDisplayLink = nil
    }

    /// Critically-damped harmonic spring integrator (analytical sub-stepped for unconditional 120Hz stability).
    static func stepSpring(
        value: inout CGFloat,
        velocity: inout CGFloat,
        target: CGFloat,
        omega: CGFloat,
        zeta: CGFloat = 1.0,
        dt: CGFloat
    ) {
        let disp = value - target
        let accel = -(omega * omega) * disp - (2.0 * zeta * omega) * velocity
        velocity += accel * dt
        value += velocity * dt
        if abs(value - target) < 0.0008 && abs(velocity) < 0.004 {
            value = target
            velocity = 0.0
        }
    }

    @objc private func handleDragDisplayLink(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawDt = min(1.0 / 30.0, max(1.0 / 240.0, now - lastFrameTime))
        lastFrameTime = now

        // Two sub-steps guarantee rock-solid spring accuracy even if a system frame hiccups
        let subDt = CGFloat(rawDt * 0.5)
        // Safari macOS 27 feel: fluid ~0.27s critically-damped morph with silky ease-out tail
        let morphOmega: CGFloat = (morphTarget > 0.5) ? 16.5 : 19.0
        for _ in 0..<2 {
            Self.stepSpring(
                value: &morphProgress,
                velocity: &morphVelocity,
                target: morphTarget,
                omega: morphOmega,
                zeta: 0.96,
                dt: subDt
            )
            Self.stepSpring(
                value: &currentPillWidth,
                velocity: &pillWidthVelocity,
                target: targetPillWidth,
                omega: 20.0,
                zeta: 1.0,
                dt: subDt
            )
            Self.stepSpring(
                value: &trackMagnetAmount,
                velocity: &trackMagnetVelocity,
                target: trackMagnetTarget,
                omega: 18.0,
                zeta: 1.0,
                dt: subDt
            )
        }
        morphProgress = max(0.0, min(1.0, morphProgress))
        trackMagnetAmount = max(0.0, min(1.0, trackMagnetAmount))

        // Always sample latest hardware mouse location on vsync for butter-smooth pointer tracking
        currentCursorScreen = NSEvent.mouseLocation
        applyCurrentVisualStateToPanel()
    }

    private func evaluateCursorTarget(screenPoint: NSPoint) {
        guard let snapshot = activeSnapshot,
              let card = cardView,
              let appDelegate = NSApp.delegate as? AppDelegate else { return }

        // Single-tab single-window fast path: no other windows can accept a drop, so skip orderedWindows scans.
        if snapshot.isSingleTabSourceWindow && !snapshot.hasOtherCompatibleWindows {
            morphTarget = 1.0
            targetPillWidth = max(110.0, snapshot.initialPillRectInScreen.width)
            trackMagnetTarget = 0.0
            card.updateThemeIfChanged(snapshot.theme)
            return
        }

        let extraHysteresis: CGFloat = (morphTarget < 0.5 && lastHoverTarget != nil) ? 10.0 : 0.0
        let skipWindow = snapshot.isSingleTabSourceWindow ? sourceWindowController : nil

        let target = appDelegate.tabBarDropTarget(
            atScreenPoint: screenPoint,
            isPrivate: snapshot.isPrivate,
            draggedTabID: snapshot.tabID,
            excludingWindowController: skipWindow,
            extraVerticalHysteresis: extraHysteresis
        )

        if let targetWin = target?.windowController, let resolved = target {
            if hoveredTargetWindowController !== targetWin {
                hoveredTargetWindowController?.clearExternalTabDropPlaceholder()
                hoveredTargetWindowController = targetWin
            }
            targetWin.updateExternalTabDropPlaceholder(
                tabID: snapshot.tabID,
                insertionIndex: resolved.insertionIndex
            )
            let refreshed = targetWin.tabBarDropTarget(
                atScreenPoint: screenPoint,
                draggedTabID: snapshot.tabID,
                extraVerticalHysteresis: extraHysteresis
            )
            lastHoverTarget = refreshed ?? resolved
            if let dropTarget = lastHoverTarget {
                morphTarget = 0.0
                targetPillWidth = max(110.0, dropTarget.slotRectInScreen.width)
                lastTrackMidY = dropTarget.slotRectInScreen.midY
                trackMagnetTarget = 1.0
                card.updateThemeIfChanged(dropTarget.theme)
            }
        } else {
            hoveredTargetWindowController?.clearExternalTabDropPlaceholder()
            hoveredTargetWindowController = nil
            lastHoverTarget = nil
            morphTarget = 1.0
            targetPillWidth = max(110.0, snapshot.initialPillRectInScreen.width)
            trackMagnetTarget = 0.0
            card.updateThemeIfChanged(snapshot.theme)
        }
    }

    /// Retina-half-pixel aligned rounding (0.5pt on 2x displays) eliminates chunky 1pt stepping during smooth morphs.
    @inline(__always)
    func pixelSnap(_ v: CGFloat) -> CGFloat {
        let scale = dragPanel?.backingScaleFactor ?? 2.0
        return Self.pixelSnap(v, scale: scale)
    }

    /// Pure form of `pixelSnap(_:)` for an explicit backing scale (test seam).
    static func pixelSnap(_ v: CGFloat, scale: CGFloat) -> CGFloat {
        (v * scale).rounded() / scale
    }

    func computeCurrentCardScreenRect() -> NSRect {
        guard let snapshot = activeSnapshot else { return .zero }
        let p = morphProgress

        let pillW = currentPillWidth
        let pillH = SafariMetrics.tabInnerHeight
        let w = pillW + (previewSize.width - pillW) * p
        let h = pillH + (previewSize.height - pillH) * p

        let pillGrabX = min(pillW - 14.0, max(14.0, snapshot.cursorOffsetInPill.x))
        let grabRatio = max(0.15, min(0.85, snapshot.cursorOffsetInPill.x / max(1.0, snapshot.initialPillRectInScreen.width)))
        let previewGrabX = previewSize.width * grabRatio
        let anchorX = pillGrabX + (previewGrabX - pillGrabX) * p

        let pillTopOffset = max(6.0, min(pillH - 6.0, pillH - snapshot.cursorOffsetInPill.y))
        let previewTopOffset: CGFloat = 14.0
        let anchorFromTop = pillTopOffset + (previewTopOffset - pillTopOffset) * p

        // Spring-blended vertical magnetic pull toward hovered tab track (zero snap/jump on enter or exit!)
        let magnet = trackMagnetAmount * (1.0 - p * 0.5) * 0.78
        let effectiveCursorY = currentCursorScreen.y * (1.0 - magnet) + lastTrackMidY * magnet

        let originX = pixelSnap(currentCursorScreen.x - anchorX)
        let originY = pixelSnap(effectiveCursorY - (h - anchorFromTop))
        return NSRect(x: originX, y: originY, width: pixelSnap(w), height: pixelSnap(h))
    }

    private func applyCurrentVisualStateToPanel(snapToExactPillRect: NSRect? = nil) {
        guard let panel = dragPanel, let card = cardView else { return }
        let cardScreenRect = snapToExactPillRect ?? computeCurrentCardScreenRect()
        if snapToExactPillRect == nil,
           morphProgress >= 0.9999,
           abs(currentPillWidth - targetPillWidth) < 0.01,
           abs(trackMagnetAmount - trackMagnetTarget) < 0.01,
           abs(card.bounds.width - cardScreenRect.width) < 0.25,
           abs(card.bounds.height - cardScreenRect.height) < 0.25 {
            panel.moveOriginOnly(toScreenRect: cardScreenRect, shadowPad: Self.shadowPad)
            return
        }
        panel.positionCard(atScreenRect: cardScreenRect, shadowPad: Self.shadowPad)
        card.applyMorphProgress(morphProgress)
    }

    // MARK: - 120Hz CADisplayLink Cancel, Drop-Into-TabBar & Window Bloom

    private func finishCancel() {
        guard let source = sourceWindowController,
              let snapshot = activeSnapshot,
              let panel = dragPanel,
              let card = cardView else {
            teardown()
            return
        }

        hoveredTargetWindowController?.clearExternalTabDropPlaceholder()
        hoveredTargetWindowController = nil

        if snapshot.isSingleTabSourceWindow {
            let winFrame = source.window?.frame ?? snapshot.initialPillRectInScreen
            startSettleDisplayLink(
                panel: panel,
                card: card,
                fromRect: panel.currentCardScreenRect,
                toRect: winFrame,
                fromMorph: morphProgress,
                toMorph: 1.0,
                fadeOutPanel: true,
                bloomToWindowRadius: true,
                duration: 0.24,
                extraStep: { t in
                    source.window?.alphaValue = min(1.0, pow(t, 0.85))
                },
                completion: { [weak self] in
                    source.setSingleTabTearOffGhosted(false)
                    source.window?.makeKeyAndOrderFront(nil)
                    self?.teardown()
                }
            )
            return
        }

        let returnRect = source.screenRectForTabOrDefault(
            tabID: snapshot.tabID,
            fallback: snapshot.initialPillRectInScreen
        )
        startSettleDisplayLink(
            panel: panel,
            card: card,
            fromRect: panel.currentCardScreenRect,
            toRect: returnRect,
            fromMorph: morphProgress,
            toMorph: 0.0,
            fadeOutPanel: false,
            bloomToWindowRadius: false,
            duration: 0.22,
            extraStep: nil,
            completion: { [weak self] in
                source.setTearOffHiddenTab(id: nil)
                self?.teardown()
            }
        )
    }

    private func finishDrop(atScreenPoint screenPoint: NSPoint) {
        guard let source = sourceWindowController,
              let snapshot = activeSnapshot,
              let panel = dragPanel,
              let card = cardView,
              let appDelegate = NSApp.delegate as? AppDelegate else {
            teardown()
            return
        }

        if let dropTarget = lastHoverTarget, let destWindow = dropTarget.windowController {
            // Case 1: Dropped into a Safarium window's tab bar -> glide smoothly into exact slot & morph back to pill!
            let targetSlotRect = destWindow.resolvedExternalDropSlotRectInScreen() ?? dropTarget.slotRectInScreen
            let targetIndex = dropTarget.insertionIndex

            startSettleDisplayLink(
                panel: panel,
                card: card,
                fromRect: panel.currentCardScreenRect,
                toRect: targetSlotRect,
                fromMorph: morphProgress,
                toMorph: 0.0,
                fadeOutPanel: false,
                bloomToWindowRadius: false,
                duration: 0.20,
                extraStep: nil,
                completion: { [weak self] in
                    guard let self else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    destWindow.clearExternalTabDropPlaceholder(animated: false)
                    if destWindow === source {
                        source.commitSameWindowTabDrop(tabID: snapshot.tabID, insertionIndex: targetIndex)
                    } else if let transfer = source.detachTabForTransfer(tabID: snapshot.tabID) {
                        destWindow.acceptTransferredTab(transfer, atIndex: targetIndex, activate: true, animatedTabBar: false)
                        destWindow.window?.makeKeyAndOrderFront(nil)
                    } else {
                        source.setTearOffHiddenTab(id: nil)
                    }
                    self.teardown()
                    CATransaction.commit()
                }
            )
            return
        }

        // Case 2: Dropped into NO Safarium window -> bloom smoothly into a full Safarium window!
        hoveredTargetWindowController?.clearExternalTabDropPlaceholder()
        hoveredTargetWindowController = nil

        let targetWinFrame = computeNewWindowFrame(
            dropPoint: screenPoint,
            preferredSize: snapshot.sourceWindowSize
        )

        if snapshot.isSingleTabSourceWindow {
            if let win = source.window {
                if abs(win.frame.width - targetWinFrame.width) < 0.5 &&
                    abs(win.frame.height - targetWinFrame.height) < 0.5 {
                    win.setFrameOrigin(targetWinFrame.origin)
                } else {
                    win.setFrame(targetWinFrame, display: false)
                }
            }
            card.prepareForWindowBloom()
            startSettleDisplayLink(
                panel: panel,
                card: card,
                fromRect: panel.currentCardScreenRect,
                toRect: targetWinFrame,
                fromMorph: morphProgress,
                toMorph: 1.0,
                fadeOutPanel: true,
                bloomToWindowRadius: true,
                duration: 0.28,
                extraStep: { t in
                    source.window?.alphaValue = min(1.0, pow(t, 0.78))
                },
                completion: { [weak self] in
                    source.setSingleTabTearOffGhosted(false)
                    source.window?.makeKeyAndOrderFront(nil)
                    self?.teardown()
                }
            )
            return
        }

        guard let transfer = source.detachTabForTransfer(tabID: snapshot.tabID) else {
            source.setTearOffHiddenTab(id: nil)
            teardown()
            return
        }

        // Create real window hidden at alpha 0 while the preview card blooms seamlessly into its frame on GPU
        let newController = appDelegate.openWindow(
            withTransferredTab: transfer,
            frame: targetWinFrame,
            isPrivate: snapshot.isPrivate,
            initialAlpha: 0.0
        )

        startSettleDisplayLink(
            panel: panel,
            card: card,
            fromRect: panel.currentCardScreenRect,
            toRect: targetWinFrame,
            fromMorph: morphProgress,
            toMorph: 1.0,
            fadeOutPanel: true,
            bloomToWindowRadius: true,
            duration: 0.28,
            extraStep: { t in
                newController?.window?.alphaValue = min(1.0, pow(t, 0.78))
            },
            completion: { [weak self] in
                newController?.window?.alphaValue = 1.0
                newController?.window?.makeKeyAndOrderFront(nil)
                self?.teardown()
            }
        )
    }

    private func startSettleDisplayLink(
        panel: TabDragCanvasPanel,
        card: TabDragMorphCardView,
        fromRect: NSRect,
        toRect: NSRect,
        fromMorph: CGFloat,
        toMorph: CGFloat,
        fadeOutPanel: Bool,
        bloomToWindowRadius: Bool,
        duration: CFTimeInterval,
        extraStep: ((CGFloat) -> Void)?,
        completion: @escaping () -> Void
    ) {
        settleDisplayLink?.invalidate()
        settleDisplayLink = nil

        // Single fixed union canvas allocation for bloom OR drop settle -> ZERO NSWindow resizes during 120Hz playback!
        panel.prepareFixedAnimationCanvas(covering: fromRect.union(toRect), initialCardRect: fromRect, shadowPad: Self.shadowPad)

        settleState = SettleAnimState(
            fromRect: fromRect,
            toRect: toRect,
            fromMorph: fromMorph,
            toMorph: toMorph,
            fadeOutPanel: fadeOutPanel,
            bloomToWindowRadius: bloomToWindowRadius,
            duration: max(0.01, duration),
            startTime: CACurrentMediaTime(),
            extraStep: extraStep,
            completion: completion
        )

        guard let hostView = panel.contentView else {
            completion()
            return
        }
        let link = hostView.displayLink(target: self, selector: #selector(handleSettleDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        settleDisplayLink = link
    }

    @objc private func handleSettleDisplayLink(_ link: CADisplayLink) {
        guard let state = settleState,
              let panel = dragPanel,
              let card = cardView else {
            link.invalidate()
            settleDisplayLink = nil
            return
        }

        let elapsed = CACurrentMediaTime() - state.startTime
        let rawT = min(1.0, max(0.0, elapsed / state.duration))

        // Ultra-smooth quartic ease-out (matches macOS 27 Safari's silky spring-tail deceleration)
        let inv = 1.0 - rawT
        let eased = CGFloat(1.0 - inv * inv * inv * inv)

        let rect = NSRect(
            x: pixelSnap(state.fromRect.minX + (state.toRect.minX - state.fromRect.minX) * eased),
            y: pixelSnap(state.fromRect.minY + (state.toRect.minY - state.fromRect.minY) * eased),
            width: pixelSnap(state.fromRect.width + (state.toRect.width - state.fromRect.width) * eased),
            height: pixelSnap(state.fromRect.height + (state.toRect.height - state.fromRect.height) * eased)
        )
        let m = state.fromMorph + (state.toMorph - state.fromMorph) * eased

        panel.placeCardInsideFixedCanvas(cardScreenRect: rect)
        if state.bloomToWindowRadius {
            let cornerR = 14.0 + (SafariMetrics.windowCornerRadius - 14.0) * eased
            card.applyMorphProgress(m, overrideCornerRadius: cornerR, bloomProgress: eased)
        } else {
            card.applyMorphProgress(m)
        }

        if state.fadeOutPanel {
            panel.alphaValue = max(0.0, 1.0 - eased * 1.04)
        }
        state.extraStep?(eased)

        if rawT >= 1.0 {
            let done = state.completion
            settleState = nil
            link.invalidate()
            settleDisplayLink = nil
            done()
        }
    }

    private func teardown() {
        stopDragDisplayLink()
        settleDisplayLink?.invalidate()
        settleDisplayLink = nil
        settleState = nil
        dragPanel?.orderOut(nil)
        dragPanel = nil
        cardView = nil
        sourceWindowController = nil
        hoveredTargetWindowController = nil
        activeSnapshot = nil
        lastHoverTarget = nil
        isDragging = false
    }

    func computeNewWindowFrame(dropPoint: NSPoint, preferredSize: NSSize) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(dropPoint) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 944)
        let w = min(max(SafariMetrics.minWindowWidth, preferredSize.width), visible.width - 24.0)
        let h = min(max(SafariMetrics.minWindowHeight, preferredSize.height), visible.height - 24.0)

        var x = dropPoint.x - w * 0.5
        var y = dropPoint.y - (h - 26.0)

        x = max(visible.minX + 12.0, min(visible.maxX - w - 12.0, x))
        y = max(visible.minY + 12.0, min(visible.maxY - h - 12.0, y))
        return NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
    }
}

// MARK: - Fixed-Canvas Borderless Drag Panel (Zero Window-Resize Stutter at 120Hz)

private final class TabDragCanvasPanel: NSPanel {
    private let hostContainer = NSView()
    private let cardView: TabDragMorphCardView
    private(set) var currentCardScreenRect: NSRect = .zero

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(canvasSize: NSSize, cardView: TabDragMorphCardView) {
        self.cardView = cardView
        super.init(
            contentRect: NSRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .none

        hostContainer.frame = NSRect(origin: .zero, size: canvasSize)
        hostContainer.wantsLayer = true
        hostContainer.layer?.masksToBounds = false
        self.contentView = hostContainer

        cardView.translatesAutoresizingMaskIntoConstraints = true
        cardView.autoresizingMask = []
        hostContainer.addSubview(cardView)
    }

    /// Pure origin translation when card size & morph are already settled (zero layout or layer work).
    func moveOriginOnly(toScreenRect cardRect: NSRect, shadowPad: CGFloat) {
        currentCardScreenRect = cardRect
        let panelOriginX = cardRect.minX - shadowPad
        let panelOriginY = cardRect.maxY + shadowPad - frame.height
        if abs(frame.origin.x - panelOriginX) > 0.05 || abs(frame.origin.y - panelOriginY) > 0.05 {
            setFrameOrigin(NSPoint(x: panelOriginX, y: panelOriginY))
        }
    }

    /// Positions `cardView` at exact screen coordinates WITHOUT resizing the NSPanel.
    func positionCard(atScreenRect cardRect: NSRect, shadowPad: CGFloat) {
        currentCardScreenRect = cardRect

        let neededW = cardRect.width + shadowPad * 2.0
        let neededH = cardRect.height + shadowPad * 2.0
        if frame.width < neededW || frame.height < neededH {
            let newSize = NSSize(width: max(frame.width, neededW), height: max(frame.height, neededH))
            setContentSize(newSize)
            hostContainer.frame = NSRect(origin: .zero, size: newSize)
        }

        let panelOriginX = cardRect.minX - shadowPad
        let panelOriginY = cardRect.maxY + shadowPad - frame.height
        setFrameOrigin(NSPoint(x: panelOriginX, y: panelOriginY))

        let localRect = NSRect(
            x: shadowPad,
            y: frame.height - shadowPad - cardRect.height,
            width: cardRect.width,
            height: cardRect.height
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardView.frame = localRect
        cardView.layoutManuallyForBounds()
        CATransaction.commit()
    }

    /// Allocates ONE fixed panel spanning `unionRect` so 120Hz settle & full-window bloom NEVER resize an NSWindow!
    func prepareFixedAnimationCanvas(covering unionRect: NSRect, initialCardRect: NSRect, shadowPad: CGFloat) {
        let canvasFrame = unionRect.insetBy(dx: -shadowPad, dy: -shadowPad)
        setFrame(canvasFrame, display: false)
        hostContainer.frame = NSRect(origin: .zero, size: canvasFrame.size)
        placeCardInsideFixedCanvas(cardScreenRect: initialCardRect)
    }

    /// Pure subview/layer repositioning inside the fixed animation canvas (0 WindowServer surface reallocations!).
    func placeCardInsideFixedCanvas(cardScreenRect: NSRect) {
        currentCardScreenRect = cardScreenRect
        let localRect = NSRect(
            x: cardScreenRect.minX - frame.minX,
            y: cardScreenRect.minY - frame.minY,
            width: cardScreenRect.width,
            height: cardScreenRect.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardView.frame = localRect
        cardView.layoutManuallyForBounds()
        CATransaction.commit()
    }
}

// MARK: - Pure-GPU 120Hz Pill <-> Preview Thumbnail Morph Card (Zero Auto Layout / Zero CPU Redraws)

private final class TabDragMorphCardView: NSView {
    override var isFlipped: Bool { true }

    private let snapshot: TabDragVisualSnapshot
    private var theme: AdaptiveChromeTheme
    private var lastAppliedRadius: CGFloat = SafariMetrics.tabInnerCornerRadius

    private let clippedSurface = NSView()
    private let frostEffectView = NSVisualEffectView()
    private let surfaceTintView = NSView()

    // Preview Thumbnail layer (morphProgress -> 1.0)
    private let previewContainer = NSView()
    private let previewHeaderBar = NSView()
    private let previewFaviconView = NSImageView()
    private let previewTitleLabel = NSTextField(labelWithString: "")
    private let previewHeaderHairline = NSView()
    private let previewFallbackBg = NSView()
    private let previewSnapshotView = GPUEdgeToEdgeSnapshotView()

    // Exact Compact Tab Pill layer (morphProgress -> 0.0)
    private let pillContainer = NSView()
    private let pillFaviconBadge = NSView()
    private let pillFaviconView = NSImageView()
    private let pillTitleLabel = NSTextField(labelWithString: "")
    private let pillPageMenuIcon = NSImageView()

    private let showPageMenuIcon: Bool
    private var lastLaidOutSize: CGSize = .zero
    private var cachedPreviewTitleFitWidth: CGFloat = 0
    private var cachedPreviewAvailWidth: CGFloat = -1
    private var cachedPillTitleFitWidth: CGFloat = 0
    private var cachedPillAvailWidth: CGFloat = -1
    private var lastAppliedShadowMorph: CGFloat = -1
    private var lastAppliedShadowSize: CGSize = .zero
    private var isWindowBlooming: Bool = false

    init(snapshot: TabDragVisualSnapshot) {
        self.snapshot = snapshot
        self.theme = snapshot.theme
        self.showPageMenuIcon = (snapshot.isActiveTab && !snapshot.isStartPage)
        super.init(frame: .zero)
        setupViews()
        applyAppearance()
        applyMorphProgress(0.0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 9.0
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        clippedSurface.wantsLayer = true
        clippedSurface.layer?.cornerRadius = SafariMetrics.tabInnerCornerRadius
        clippedSurface.layer?.cornerCurve = .continuous
        clippedSurface.layer?.masksToBounds = true
        clippedSurface.layer?.borderWidth = 0.5
        addSubview(clippedSurface)

        frostEffectView.material = .popover
        frostEffectView.blendingMode = .behindWindow
        frostEffectView.state = .active
        clippedSurface.addSubview(frostEffectView)

        surfaceTintView.wantsLayer = true
        clippedSurface.addSubview(surfaceTintView)

        // --- 1. Preview Thumbnail Subtree (manual frame layout, GPU snapshot CALayer) ---
        previewContainer.wantsLayer = true
        previewContainer.alphaValue = 0.0
        clippedSurface.addSubview(previewContainer)

        previewHeaderBar.wantsLayer = true
        previewContainer.addSubview(previewHeaderBar)

        previewFaviconView.imageScaling = .scaleProportionallyDown
        previewHeaderBar.addSubview(previewFaviconView)

        previewTitleLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        previewTitleLabel.lineBreakMode = .byTruncatingTail
        previewTitleLabel.maximumNumberOfLines = 1
        previewTitleLabel.stringValue = snapshot.title.isEmpty ? snapshot.displayDomain : snapshot.title
        previewHeaderBar.addSubview(previewTitleLabel)

        previewHeaderHairline.wantsLayer = true
        previewContainer.addSubview(previewHeaderHairline)

        previewFallbackBg.wantsLayer = true
        previewContainer.addSubview(previewFallbackBg)

        if let liveSurface = snapshot.liveFrameSurface {
            previewSnapshotView.setLiveSurface(liveSurface)
        } else {
            previewSnapshotView.setSnapshot(snapshot.pageSnapshot)
        }
        previewContainer.addSubview(previewSnapshotView)

        // --- 2. Exact Compact Tab Pill Subtree (manual frame layout, zero constraint solves) ---
        pillContainer.wantsLayer = true
        pillContainer.alphaValue = 1.0
        clippedSurface.addSubview(pillContainer)

        pillFaviconBadge.wantsLayer = true
        pillFaviconBadge.layer?.cornerRadius = SafariMetrics.fieldIconBadgeSize * 0.5
        pillFaviconBadge.layer?.masksToBounds = true
        pillContainer.addSubview(pillFaviconBadge)

        pillFaviconView.imageScaling = .scaleProportionallyDown
        pillFaviconBadge.addSubview(pillFaviconView)

        pillTitleLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        pillTitleLabel.lineBreakMode = snapshot.isStartPage ? .byTruncatingTail : .byTruncatingMiddle
        pillTitleLabel.maximumNumberOfLines = 1
        pillTitleLabel.stringValue = snapshot.isActiveTab
            ? snapshot.displayDomain
            : (snapshot.title.isEmpty ? snapshot.displayDomain : snapshot.title)
        pillContainer.addSubview(pillTitleLabel)

        pillPageMenuIcon.imageScaling = .scaleProportionallyDown
        pillPageMenuIcon.image = Self.makePageMenuIcon()
        pillPageMenuIcon.isHidden = !showPageMenuIcon
        pillContainer.addSubview(pillPageMenuIcon)

        configureIcons()
    }

    /// Ultra-fast direct frame layout (zero Auto Layout solver passes at 120Hz).
    func layoutManuallyForBounds() {
        let b = bounds
        let w = b.width
        let h = b.height
        guard w > 1, h > 1 else { return }
        guard abs(w - lastLaidOutSize.width) > 0.05 || abs(h - lastLaidOutSize.height) > 0.05 else {
            return
        }
        lastLaidOutSize = b.size

        clippedSurface.frame = b
        if !frostEffectView.isHidden {
            frostEffectView.frame = b
        }
        surfaceTintView.frame = b

        // Preview subtree
        let headerH: CGFloat = 26.0
        previewContainer.frame = b
        previewHeaderBar.frame = NSRect(x: 0, y: 0, width: w, height: headerH)
        previewHeaderHairline.frame = NSRect(x: 0, y: headerH, width: w, height: 0.5)
        let bodyRect = NSRect(x: 0, y: headerH + 0.5, width: w, height: max(0, h - headerH - 0.5))
        previewFallbackBg.frame = bodyRect
        previewSnapshotView.frame = bodyRect
        previewSnapshotView.layoutSnapshotLayer()

        // Centered favicon + title in preview header (cache CoreText width across translation/vertical steps)
        let pFavSz: CGFloat = 14.0
        let pGap: CGFloat = 5.0
        let pAvailW = max(20.0, w - 20.0)
        let maxPreviewTextW = max(12.0, pAvailW - pFavSz - pGap)
        if abs(maxPreviewTextW - cachedPreviewAvailWidth) > 0.5 {
            cachedPreviewAvailWidth = maxPreviewTextW
            cachedPreviewTitleFitWidth = ceil(previewTitleLabel.sizeThatFits(NSSize(width: maxPreviewTextW, height: 18.0)).width)
        }
        let pTitleW = min(maxPreviewTextW, max(12.0, cachedPreviewTitleFitWidth))
        let pTotalW = pFavSz + pGap + pTitleW
        let pStartX = max(10.0, (w - pTotalW) * 0.5)
        previewFaviconView.frame = NSRect(x: pStartX, y: (headerH - pFavSz) * 0.5, width: pFavSz, height: pFavSz)
        previewTitleLabel.frame = NSRect(x: pStartX + pFavSz + pGap, y: (headerH - 16.0) * 0.5, width: pTitleW, height: 16.0)

        // Pill subtree (stays pinned to top 31pt of card when pill is visible)
        if (pillContainer.layer?.opacity ?? 1.0) > 0.001 {
            let pillH = SafariMetrics.tabInnerHeight
            pillContainer.frame = NSRect(x: 0, y: 0, width: w, height: pillH)

            let leftPad: CGFloat = 10.0
            let rightPad: CGFloat = showPageMenuIcon ? 32.0 : 10.0
            let badgeSz = SafariMetrics.fieldIconBadgeSize
            let gap: CGFloat = 6.0
            let availPillW = max(24.0, w - leftPad - rightPad)
            let maxPillTextW = max(12.0, availPillW - badgeSz - gap)
            if abs(maxPillTextW - cachedPillAvailWidth) > 0.5 {
                cachedPillAvailWidth = maxPillTextW
                cachedPillTitleFitWidth = ceil(pillTitleLabel.sizeThatFits(NSSize(width: maxPillTextW, height: 18.0)).width)
            }
            let titleW = min(maxPillTextW, max(12.0, cachedPillTitleFitWidth))
            let totalPillContentW = badgeSz + gap + titleW
            let pillStartX = max(leftPad, min(w - rightPad - totalPillContentW, (w - totalPillContentW) * 0.5))

            pillFaviconBadge.frame = NSRect(x: pillStartX, y: (pillH - badgeSz) * 0.5, width: badgeSz, height: badgeSz)
            pillFaviconView.frame = NSRect(x: (badgeSz - 14.5) * 0.5, y: (badgeSz - 14.5) * 0.5, width: 14.5, height: 14.5)
            pillTitleLabel.frame = NSRect(x: pillStartX + badgeSz + gap, y: (pillH - 17.0) * 0.5, width: titleW, height: 17.0)
            if showPageMenuIcon {
                pillPageMenuIcon.frame = NSRect(x: w - 11.0 - 16.0, y: (pillH - 16.0) * 0.5, width: 16.0, height: 16.0)
            }
        }

        // Update explicit GPU shadowPath only when shadow is visible
        if !isWindowBlooming, (layer?.shadowOpacity ?? 0) > 0.001 {
            let r = min(lastAppliedRadius, min(w, h) * 0.5)
            layer?.shadowPath = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
            lastAppliedShadowSize = b.size
        }
    }

    private static func makePageMenuIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 11), flipped: true) { _ in
            NSColor.labelColor.setStroke()
            let lines: [(CGFloat, CGFloat)] = [(1.5, 11.5), (5.5, 11.5), (9.5, 7.5)]
            for (y, w) in lines {
                let p = NSBezierPath()
                p.lineWidth = 1.45
                p.lineCapStyle = .round
                p.move(to: NSPoint(x: 1.2, y: y))
                p.line(to: NSPoint(x: 1.2 + w, y: y))
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func configureIcons() {
        if let fav = snapshot.favicon, !snapshot.isStartPage {
            pillFaviconView.image = fav
            pillFaviconView.contentTintColor = nil
            previewFaviconView.image = fav
            previewFaviconView.contentTintColor = nil
        } else {
            let pillSymName = snapshot.isStartPage
                ? (snapshot.isActiveTab ? "magnifyingglass" : "star")
                : "globe"
            pillFaviconView.image = AssetLoader.shared.symbol(named: pillSymName, pointSize: 13.5, weight: .regular)
            previewFaviconView.image = AssetLoader.shared.symbol(
                named: snapshot.isStartPage ? "star" : "globe",
                pointSize: 13.0,
                weight: .regular
            )
        }
    }

    func updatePreviewSnapshot(_ image: NSImage) {
        previewSnapshotView.setSnapshot(image)
    }

    /// Guarded theme update: skips redundant AppKit window appearance invalidations during mouse drags!
    func updateThemeIfChanged(_ newTheme: AdaptiveChromeTheme) {
        guard newTheme != theme else { return }
        self.theme = newTheme
        applyAppearance()
    }

    private func applyAppearance() {
        let isDark = snapshot.isPrivate || theme.prefersLightInk
        let fill = theme.activeTabFillColor.usingColorSpace(.sRGB) ?? theme.activeTabFillColor

        let targetAppearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if window?.appearance?.name != targetAppearance?.name {
            window?.appearance = targetAppearance
        }
        if frostEffectView.appearance?.name != targetAppearance?.name {
            frostEffectView.appearance = targetAppearance
        }
        frostEffectView.state = .active

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if snapshot.isPrivate {
            surfaceTintView.layer?.backgroundColor = NSColor(srgbRed: 0.355, green: 0.355, blue: 0.370, alpha: 0.90).cgColor
            clippedSurface.layer?.backgroundColor = NSColor(srgbRed: 0.345, green: 0.345, blue: 0.360, alpha: 0.96).cgColor
            clippedSurface.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        } else if isDark {
            surfaceTintView.layer?.backgroundColor = fill.withAlphaComponent(0.76).cgColor
            clippedSurface.layer?.backgroundColor = fill.withAlphaComponent(0.92).cgColor
            clippedSurface.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        } else {
            surfaceTintView.layer?.backgroundColor = fill.withAlphaComponent(0.84).cgColor
            clippedSurface.layer?.backgroundColor = NSColor(srgbRed: 0.992, green: 0.992, blue: 0.996, alpha: 0.96).cgColor
            clippedSurface.layer?.borderColor = NSColor.black.withAlphaComponent(0.09).cgColor
        }

        previewHeaderBar.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 0.98)
            : NSColor.white.withAlphaComponent(0.98)).cgColor
        previewHeaderHairline.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.08)).cgColor
        previewFallbackBg.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0)
            : theme.sampledColor).cgColor

        let secondaryInk = snapshot.isPrivate
            ? NSColor.white.withAlphaComponent(0.76)
            : (theme.prefersLightInk
                ? NSColor.white.withAlphaComponent(0.55)
                : NSColor(srgbRed: 0.478, green: 0.478, blue: 0.490, alpha: 1.0))

        let primaryInk = isDark
            ? NSColor.white.withAlphaComponent(0.96)
            : NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1.0)

        pillTitleLabel.textColor = (snapshot.isStartPage && snapshot.isActiveTab) ? secondaryInk : primaryInk
        previewTitleLabel.textColor = primaryInk
        pillPageMenuIcon.contentTintColor = isDark
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor(srgbRed: 0.32, green: 0.32, blue: 0.35, alpha: 0.88)

        if snapshot.favicon != nil && !snapshot.isStartPage {
            pillFaviconBadge.layer?.backgroundColor = snapshot.isPrivate
                ? NSColor.white.withAlphaComponent(0.96).cgColor
                : (theme.prefersLightInk
                    ? NSColor.white.withAlphaComponent(0.14).cgColor
                    : NSColor.black.withAlphaComponent(0.048).cgColor)
        } else {
            pillFaviconBadge.layer?.backgroundColor = NSColor.clear.cgColor
            pillFaviconView.contentTintColor = secondaryInk
            previewFaviconView.contentTintColor = secondaryInk
        }

        CATransaction.commit()
    }

    /// Disables behind-window NSVisualEffectView reallocations and shadow path updates during full-window bloom.
    func prepareForWindowBloom() {
        isWindowBlooming = true
        frostEffectView.isHidden = true
        layer?.shadowPath = nil
        layer?.shadowOpacity = 0.0
    }

    /// Drives the continuous 120Hz pill (`0.0`) <-> preview thumbnail (`1.0`) visual morph on GPU layers.
    func applyMorphProgress(_ raw: CGFloat, overrideCornerRadius: CGFloat? = nil, bloomProgress: CGFloat? = nil) {
        let p = max(0.0, min(1.0, raw))
        let radius = overrideCornerRadius ?? (SafariMetrics.tabInnerCornerRadius + (14.0 - SafariMetrics.tabInnerCornerRadius) * p)
        lastAppliedRadius = radius

        // Smooth overlapping crossfade curve: pill fades 0..0.46, preview unfolds 0.10..0.76
        let pillAlpha = max(0.0, min(1.0, 1.0 - p / 0.46))
        let previewAlpha = max(0.0, min(1.0, (p - 0.10) / 0.66))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        clippedSurface.layer?.cornerRadius = radius
        pillContainer.layer?.opacity = Float(pillAlpha)
        previewContainer.layer?.opacity = Float(previewAlpha)
        clippedSurface.layer?.opacity = Float(1.0 - 0.03 * p)

        if isWindowBlooming || bloomProgress != nil {
            if (layer?.shadowOpacity ?? 0) > 0.001 {
                layer?.shadowOpacity = 0.0
                layer?.shadowPath = nil
            }
        } else if abs(p - lastAppliedShadowMorph) > 0.002 || bounds.size != lastAppliedShadowSize {
            lastAppliedShadowMorph = p
            lastAppliedShadowSize = bounds.size
            layer?.shadowOpacity = Float(0.16 + (0.28 - 0.16) * p)
            layer?.shadowRadius = 9.0 + (22.0 - 9.0) * p
            layer?.shadowOffset = CGSize(width: 0, height: 3.0 + (8.0 - 3.0) * p)
            if bounds.width > 1, bounds.height > 1 {
                let r = min(radius, min(bounds.width, bounds.height) * 0.5)
                layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
            }
        }

        CATransaction.commit()
    }
}

/// Pure GPU `CALayer` top-aligned edge-to-edge Retina snapshot view (0 CPU bitmap draws at 120Hz).
/// Non-flipped (`isFlipped == false`) so `CGImage` / `IOSurface` always composites right-side up directly on GPU.
private final class GPUEdgeToEdgeSnapshotView: NSView {
    private let imageLayer = CALayer()
    private var pixelSize: CGSize = .zero
    private var usingLiveSurface: Bool = false

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLiveSurface(_ surface: IOSurface?) {
        guard let surface else { return }
        let w = CGFloat(IOSurfaceGetWidth(surface))
        let h = CGFloat(IOSurfaceGetHeight(surface))
        guard w > 1, h > 1 else { return }
        usingLiveSurface = true
        pixelSize = CGSize(width: w, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        layoutSnapshotLayer()
        CATransaction.commit()
    }

    func setSnapshot(_ image: NSImage?) {
        if usingLiveSurface { return }
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            imageLayer.contents = nil
            pixelSize = .zero
            return
        }
        pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = cgImage
        layoutSnapshotLayer()
        CATransaction.commit()
    }

    func layoutSnapshotLayer() {
        guard pixelSize.width > 1, pixelSize.height > 1, bounds.width > 1, bounds.height > 1 else {
            return
        }
        let scale = max(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let drawW = pixelSize.width * scale
        let drawH = pixelSize.height * scale
        let drawX = (bounds.width - drawW) * 0.5
        // Non-flipped coordinates: top edge is `bounds.height`, so `y = bounds.height - drawH` pins top of page!
        imageLayer.frame = CGRect(x: drawX, y: bounds.height - drawH, width: drawW, height: drawH)
    }
}
