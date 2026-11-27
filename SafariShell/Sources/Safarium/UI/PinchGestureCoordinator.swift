import AppKit
import QuartzCore

/// Coordinates native 120Hz macOS trackpad pinch gestures across:
/// 1. Chromium GPU compositor visual-viewport zoom (`RenderWidgetHostViewCocoa`)
/// 2. Cursor-anchored rubber-band overshoot at `1.0x` (Safari-style, never flying straight into Tab Overview
///    on the same continuous pinch that started zoomed in)
/// 3. Interactive GPU-camera Tab Overview open/close with release velocity handoff
/// 4. Web-app custom pinch zoom (Google Maps, Figma, Excalidraw, PDF viewers via `pageConsumesPinchZoom`)
final class PinchGestureCoordinator {
    struct Context {
        let activeTab: BrowserTabEngine
        let mainPaneView: NSView
        let tabOverviewView: TabOverviewView
        let currentTheme: AdaptiveChromeTheme
        let buildOverviewCards: () -> [TabOverviewView.CardModel]
        let onDismissAddressBarPopover: () -> Void
        let onSetOverviewSnapshotCapturePaused: (Bool) -> Void
        let onUpdateToolbarForOverview: (Bool) -> Void
        let onSelectTabByID: (String) -> Void
    }

    private enum Mode {
        case idle
        case undecided
        case chromiumZoom
        case pageOvershoot
        case swallow
        case openingOverview
        case closingOverview
    }

    private static let debugPinch = ProcessInfo.processInfo.environment["SAFARIUM_DEBUG_PINCH"] == "1"

    private var mode: Mode = .idle
    private var beganPassedToChromium: Bool = false
    /// Latched on `.began` so a continuous pinch-out that started zoomed in (> 1.0x) stops at 1.0x
    /// with rubber-band overshoot instead of accidentally launching Tab Overview.
    private var startedAtBaseScale: Bool = true
    private var gestureStartScale: CGFloat = 1.0
    private var predictedScale: CGFloat = 1.0
    private var pinchAccum: CGFloat = 0.0
    private var passThroughAccum: CGFloat = 0.0
    private var pinchProgress: CGFloat = 1.0
    private var pinchVelocity: CGFloat = 0.0
    private var pinchLastTime: TimeInterval = 0.0
    private var pinchTabID: String?
    private var overshootAccum: CGFloat = 0.0
    private var overshootAnchorInWindow: NSPoint = .zero

    /// Reflects whether Tab Overview is currently targeted open (used by both pinch and button toggles).
    var overviewOpenTarget: Bool = false

    var isActive: Bool {
        mode != .idle
    }

    func reset() {
        mode = .idle
        beganPassedToChromium = false
        startedAtBaseScale = true
        gestureStartScale = 1.0
        predictedScale = 1.0
        pinchAccum = 0.0
        passThroughAccum = 0.0
        pinchProgress = 1.0
        pinchVelocity = 0.0
        pinchLastTime = 0.0
        pinchTabID = nil
        overshootAccum = 0.0
    }

    /// Processes an AppKit `.magnify` event. Returns `true` when consumed (Chromium must not see it).
    func handleMagnify(_ e: NSEvent, context: Context) -> Bool {
        let tab = context.activeTab
        let overview = context.tabOverviewView
        let ptInMain = context.mainPaneView.convert(e.locationInWindow, from: nil)
        guard context.mainPaneView.bounds.contains(ptInMain) || mode != .idle else { return false }

        if Self.debugPinch {
            fputs("[pinch] phase=\(e.phase.rawValue) mag=\(e.magnification) mode=\(mode) hidden=\(overview.isHidden) target=\(overviewOpenTarget) trans=\(overview.isTransitioning) scale=\(tab.pageScale) pred=\(predictedScale) appPinch=\(tab.pageConsumesPinchZoom)\n", stderr)
        }

        let began = e.phase.contains(.began) || e.phase.contains(.mayBegin)
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)

        if began {
            let currentScale = tab.isNativeInternalPage ? 1.0 : max(1.0, tab.pageScale)
            mode = .undecided
            startedAtBaseScale = (currentScale <= 1.001)
            gestureStartScale = currentScale
            predictedScale = currentScale
            pinchAccum = 0.0
            passThroughAccum = 0.0
            pinchProgress = 1.0
            pinchVelocity = 0.0
            pinchLastTime = e.timestamp
            overshootAccum = 0.0
            overshootAnchorInWindow = e.locationInWindow

            // Chromium's RenderWidgetHostViewCocoa ignores `.changed` magnify events unless it saw `.began`.
            // Pass `.began` through whenever Tab Overview is hidden; if we later claim the gesture for
            // Tab Overview or overshoot, we hold `.changed` and pass `.ended` so Chromium closes cleanly.
            beganPassedToChromium = overview.isHidden
            return !beganPassedToChromium
        }

        if mode == .idle { return false }
        pinchAccum += e.magnification

        if mode == .undecided {
            if ended {
                mode = .idle
                return !beganPassedToChromium
            }
            if abs(pinchAccum) < 0.004 { return true }

            let overviewShown = !overview.isHidden && overviewOpenTarget
            let pageHandlesPinch = !tab.isNativeInternalPage && tab.pageConsumesPinchZoom

            if overviewShown {
                if pinchAccum > 0 {
                    if overview.isTransitioning {
                        overview.interruptSpringForInteractivePinch()
                    } else {
                        pinchTabID = overview.tabId(atWindowPoint: e.locationInWindow) ?? tab.tabID
                        overview.apply(theme: context.currentTheme)
                        overview.beginZoomTransition(
                            cards: context.buildOverviewCards(),
                            tabId: pinchTabID,
                            progress: 1.0
                        )
                    }
                    mode = .closingOverview
                    let pageW = max(1, overview.fullPageRect.width)
                    let curRatio = max(0.1, overview.zoomRect.width / pageW)
                    let cardRatio = max(0.1, overview.cardRect(for: pinchTabID).width / pageW)
                    pinchProgress = curRatio
                    pinchAccum = log(max(0.1, curRatio / cardRatio)) / 2.25
                } else {
                    mode = .swallow
                }
            } else if pinchAccum < 0
                        && startedAtBaseScale
                        && !pageHandlesPinch
                        && (overview.isHidden || overview.isTransitioning) {
                context.onDismissAddressBarPopover()
                if overview.isTransitioning {
                    overview.interruptSpringForInteractivePinch()
                } else {
                    pinchTabID = tab.tabID
                    overviewOpenTarget = true
                    context.onSetOverviewSnapshotCapturePaused(true)
                    context.onUpdateToolbarForOverview(true)
                    overview.apply(theme: context.currentTheme)
                    overview.beginZoomTransition(
                        cards: context.buildOverviewCards(),
                        tabId: pinchTabID,
                        progress: 0.0
                    )
                }
                mode = .openingOverview
                let pageW = max(1, overview.fullPageRect.width)
                let curRatio = max(0.1, min(1.05, overview.zoomRect.width / pageW))
                pinchProgress = curRatio
                pinchAccum = log(max(0.1, curRatio)) / 2.25
            } else {
                // Native 120Hz Chromium compositor zoom (or web-app custom pinch zoom on maps/canvas/PDF).
                mode = .chromiumZoom
                passThroughAccum = pinchAccum
                predictedScale = max(1.0, min(4.0, gestureStartScale * exp(passThroughAccum)))
                return false
            }
        }

        switch mode {
        case .chromiumZoom:
            if ended {
                mode = .idle
                return false
            }
            passThroughAccum += e.magnification
            // Reconcile immediate local prediction with visualViewport telemetry so hitting 1.0x has zero IPC lag.
            let reportedScale = tab.isNativeInternalPage ? 1.0 : max(1.0, tab.pageScale)
            predictedScale = max(1.0, min(4.0, gestureStartScale * exp(passThroughAccum)))
            let effectiveScale = min(reportedScale, predictedScale)

            // When zooming out on a regular webpage (not an interactive canvas/map), stop at 1.0x
            // with Safari-style cursor-anchored rubber-band overshoot instead of hard-clamping or launching Tab Overview.
            if e.magnification < 0 && effectiveScale <= 1.001 && !tab.isNativeInternalPage && !tab.pageConsumesPinchZoom {
                mode = .pageOvershoot
                overshootAccum = 0.0
                overshootAnchorInWindow = e.locationInWindow
                fallthrough
            }
            return false

        case .pageOvershoot:
            if ended {
                mode = .idle
                tab.endPageOvershoot()
                return !beganPassedToChromium
            }
            overshootAccum += e.magnification
            if overshootAccum > 0 {
                // User reversed outward past 1.0x: cleanly snap overshoot back to 1.0x and resume Chromium zoom.
                tab.endPageOvershoot()
                gestureStartScale = 1.0
                passThroughAccum = overshootAccum
                predictedScale = max(1.0, min(4.0, exp(passThroughAccum)))
                mode = .chromiumZoom
                return false
            }
            let scale = 1.0 - Self.rubberBand(-overshootAccum, dimension: 0.22)
            let anchorInTab = tab.contentView.convert(overshootAnchorInWindow, from: nil)
            tab.setPageOvershootScale(scale, anchorPoint: anchorInTab)
            return true

        case .swallow:
            if ended {
                mode = .idle
                return !beganPassedToChromium
            }
            return true

        case .openingOverview, .closingOverview:
            let opening = (mode == .openingOverview)
            let nextRatio = computeOpticalPinchRatio(accum: pinchAccum, opening: opening, overview: overview)
            let dt = max(0.004, e.timestamp - pinchLastTime)
            pinchVelocity = pinchVelocity * 0.45 + ((nextRatio - pinchProgress) / CGFloat(dt)) * 0.55
            pinchLastTime = e.timestamp
            pinchProgress = nextRatio
            if !ended {
                applyPinchFrame(ratio: nextRatio, overview: overview)
                return true
            }
            mode = .idle
            finishPinchTransition(opening: opening, context: context)
            return !beganPassedToChromium

        case .idle, .undecided:
            return false
        }
    }

    // MARK: - Optical Math & Spring Transitions

    static func rubberBand(_ overflow: CGFloat, dimension: CGFloat) -> CGFloat {
        guard overflow > 0, dimension > 0 else { return 0 }
        return (1.0 - 1.0 / (overflow * 0.55 / dimension + 1.0)) * dimension
    }

    static func unitVelocity(widthVelocity dw: CGFloat, from: NSRect, to: NSRect, cap: Double) -> Double {
        let d = to.width - from.width
        guard abs(d) > 2 else { return 0 }
        return min(cap, max(-6, Double(dw / d)))
    }

    func computeOpticalPinchRatio(accum: CGFloat, opening: Bool, overview: TabOverviewView) -> CGFloat {
        let page = overview.fullPageRect
        let card = overview.cardRect(for: pinchTabID)
        let minRatio = max(0.12, min(0.9, card.width / max(1, page.width)))
        var ratio = opening ? exp(accum * 2.25) : (minRatio * exp(accum * 2.25))
        if ratio < minRatio {
            ratio = minRatio - Self.rubberBand(minRatio - ratio, dimension: minRatio * 0.16)
        } else if ratio > 1.0 {
            ratio = 1.0 + Self.rubberBand(ratio - 1.0, dimension: 0.065)
        }
        return max(0.08, ratio)
    }

    private func applyPinchFrame(ratio: CGFloat, overview: TabOverviewView) {
        let page = overview.fullPageRect
        let card = overview.cardRect(for: pinchTabID)
        let minRatio = max(0.12, min(0.9, card.width / max(1, page.width)))
        let span = max(0.001, 1.0 - minRatio)
        let t = (1.0 - ratio) / span
        let posT = max(0.0, min(1.0, t))
        let w = page.width * ratio
        let h = page.height * ratio
        let cx = page.midX + (card.midX - page.midX) * posT
        let cy = page.midY + (card.midY - page.midY) * posT
        overview.setZoomFrame(
            NSRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h),
            backdrop: posT
        )
    }

    private func finishPinchTransition(opening: Bool, context: Context) {
        let overview = context.tabOverviewView
        let ratio = pinchProgress
        let v = pinchVelocity
        let page = overview.fullPageRect
        let card = overview.cardRect(for: pinchTabID)
        let minRatio = max(0.12, min(0.9, card.width / max(1, page.width)))
        let span = max(0.001, 1.0 - minRatio)
        let t = (1.0 - ratio) / span
        let projectedRatio = ratio + v * 0.16
        let projectedT = (1.0 - projectedRatio) / span

        if Self.debugPinch {
            fputs("[pinch] finish opening=\(opening) ratio=\(ratio) t=\(t) v=\(v) projT=\(projectedT)\n", stderr)
        }

        let from = overview.zoomRect
        let widthVel = page.width * v

        if opening {
            let commit = t > 0.30 || projectedT > 0.42
            overviewOpenTarget = commit
            context.onUpdateToolbarForOverview(commit)
            let target = commit ? card : page
            let v0 = Self.unitVelocity(widthVelocity: widthVel, from: from, to: target, cap: commit ? 12 : 10)
            overview.springZoom(
                to: target,
                backdrop: commit ? 1.0 : 0.0,
                duration: commit ? 0.38 : 0.34,
                bounce: commit ? 0.06 : 0.0,
                velocity: v0
            ) { [weak self] in
                guard let self else { return }
                overview.endZoomTransition(keepPresented: self.overviewOpenTarget)
            }
        } else {
            let commit = t < 0.72 || projectedT < 0.58
            let target = commit ? page : card
            let v0 = Self.unitVelocity(widthVelocity: widthVel, from: from, to: target, cap: 12)
            let chosenTabID = pinchTabID
            if commit {
                overviewOpenTarget = false
            }
            overview.springZoom(
                to: target,
                backdrop: commit ? 0.0 : 1.0,
                duration: commit ? 0.35 : 0.34,
                bounce: commit ? 0.0 : 0.05,
                velocity: v0
            ) { [weak self] in
                guard let self else { return }
                if commit, let tid = chosenTabID, tid != context.activeTab.tabID {
                    context.onSelectTabByID(tid)
                }
                overview.endZoomTransition(keepPresented: self.overviewOpenTarget)
            }
        }
    }
}
