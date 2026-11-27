import AppKit
import QuartzCore

/// Flipped transparent host aligned 1:1 with `webContentHost` that renders REAL macOS 27
/// `NSGlassEffectView` iOS 27 PiP Liquid Glass controls directly over Chromium's embedded
/// `<video controls>` elements — without ever moving or replacing `<video>` in the DOM.
final class NativeVideoOverlayContainerView: NSView {
    struct VideoState {
        var currentTime: Double = 0
        var duration: Double = 0
        var paused: Bool = true
        var muted: Bool = false
        var volume: Double = 1.0
        var cornerRadius: CGFloat = 0
        var clipTop: CGFloat = 0
        var clipBottom: CGFloat = 0

        static func parse(jsonString: String) -> VideoState? {
            guard let data = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            var st = VideoState()
            st.currentTime = (obj["cur"] as? Double) ?? 0
            st.duration = (obj["dur"] as? Double) ?? 0
            st.paused = (obj["paused"] as? Bool) ?? true
            st.muted = (obj["muted"] as? Bool) ?? false
            st.volume = (obj["vol"] as? Double) ?? 1.0
            st.cornerRadius = CGFloat((obj["radius"] as? Double) ?? 0)
            st.clipTop = CGFloat((obj["clipTop"] as? Double) ?? 0)
            st.clipBottom = CGFloat((obj["clipBottom"] as? Double) ?? 0)
            return st
        }
    }

    private var hudsByTab: [String: [String: NativeGlassVideoHUDView]] = [:]
    private var activeTabID: String = ""

    /// Target view that receives forwarded trackpad/mouse wheel scrolling when cursor is over a video HUD.
    weak var scrollForwardTarget: NSView?

    /// Invoked when the user interacts with a glass control to drive the real HTML5 `<video>`.
    var onVideoCommand: ((_ tabID: String, _ videoID: String, _ command: String, _ value: Double?) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        for sub in subviews.reversed() where !sub.isHidden {
            if sub.frame.contains(local) {
                return sub.hitTest(local) ?? sub
            }
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        if let target = scrollForwardTarget {
            target.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func setActiveTab(id: String) {
        guard activeTabID != id else { return }
        activeTabID = id
        for (tabID, map) in hudsByTab {
            let isCurrent = (tabID == id)
            for hud in map.values {
                hud.isHidden = !isCurrent || !hud.isVideoVisible
            }
        }
    }

    func clearTab(id: String) {
        guard let map = hudsByTab.removeValue(forKey: id) else { return }
        for hud in map.values {
            hud.teardown()
            hud.removeFromSuperview()
        }
    }

    func updateVideo(
        tabID: String,
        videoID: String,
        stateJSON: String,
        rect: NSRect,
        visible: Bool
    ) {
        guard !videoID.isEmpty else { return }

        if !visible || stateJSON.isEmpty {
            if let existing = hudsByTab[tabID]?[videoID] {
                existing.isVideoVisible = false
                existing.isHidden = true
                if stateJSON.isEmpty {
                    existing.teardown()
                    existing.removeFromSuperview()
                    hudsByTab[tabID]?.removeValue(forKey: videoID)
                }
            }
            return
        }

        let state = VideoState.parse(jsonString: stateJSON) ?? VideoState()
        var tabMap = hudsByTab[tabID] ?? [:]
        let hud: NativeGlassVideoHUDView
        if let existing = tabMap[videoID] {
            hud = existing
        } else {
            let created = NativeGlassVideoHUDView(videoID: videoID)
            created.scrollForwardTarget = scrollForwardTarget
            created.onCommand = { [weak self] cmd, val in
                self?.onVideoCommand?(tabID, videoID, cmd, val)
            }
            addSubview(created)
            tabMap[videoID] = created
            hudsByTab[tabID] = tabMap
            hud = created
        }

        hud.scrollForwardTarget = scrollForwardTarget
        hud.isVideoVisible = true
        if hud.frame != rect {
            hud.frame = rect
            hud.needsLayout = true
        }
        hud.applyState(state)
        hud.isHidden = (tabID != activeTabID)
    }
}

// MARK: - Real NSGlassEffectView Circular Button

private final class LiquidGlassCircleButton: NSView {
    private var glassView: NSView?
    private let iconView = NSImageView()
    private let onClick: () -> Void
    private var tracking: NSTrackingArea?
    private var isPressed = false

    var onHoverChanged: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(symbolName: String, weight: NSFont.Weight = .semibold, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .clear
            gv.appearance = NSAppearance(named: .darkAqua)
            gv.tintColor = NSColor(white: 0.18, alpha: 0.24)
            if #available(macOS 27.0, *) {
                gv.effectIsInteractive = true
            }
            gv.translatesAutoresizingMaskIntoConstraints = true
            addSubview(gv)
            self.glassView = gv
        } else {
            let vev = NSVisualEffectView()
            vev.material = .hudWindow
            vev.blendingMode = .withinWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.masksToBounds = true
            addSubview(vev)
            self.glassView = vev
        }

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.96)
        setSymbol(symbolName, weight: weight)
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var currentSymbol: String = ""
    private var currentWeight: NSFont.Weight = .semibold

    func setSymbol(_ name: String, weight: NSFont.Weight = .semibold) {
        guard currentSymbol != name || currentWeight != weight else { return }
        currentSymbol = name
        currentWeight = weight
        refreshIconImage()
    }

    private func refreshIconImage() {
        let side = max(20.0, min(bounds.width, bounds.height))
        let pt = max(10.0, round(side * 0.44))
        iconView.image = AssetLoader.shared.symbol(named: currentSymbol, pointSize: pt, weight: currentWeight)
    }

    override func layout() {
        super.layout()
        let r = min(bounds.width, bounds.height) * 0.5
        glassView?.frame = bounds
        if #available(macOS 26.0, *), let gv = glassView as? NSGlassEffectView {
            gv.cornerRadius = r
        } else {
            glassView?.layer?.cornerRadius = r
        }
        let iconSide = round(min(bounds.width, bounds.height) * 0.56)
        let xOff: CGFloat = (currentSymbol == "play.fill") ? round(iconSide * 0.06) : 0
        iconView.frame = NSRect(
            x: (bounds.width - iconSide) * 0.5 + xOff,
            y: (bounds.height - iconSide) * 0.5,
            width: iconSide,
            height: iconSide
        )
        refreshIconImage()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        animateScale(1.06)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        isPressed = false
        animateScale(1.0)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        animateScale(0.93)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        animateScale(inside ? 1.04 : 1.0)
        if isPressed && inside {
            onClick()
        }
        isPressed = false
    }

    private func animateScale(_ scale: CGFloat) {
        guard let l = layer, !MotionPreference.reduced else { return }  // Reduce Motion: no hover/press scaling
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        l.transform = t
        CATransaction.commit()
    }
}

// MARK: - Vertical Upward-Opening Liquid Glass Volume Popover

private final class LiquidGlassVolumeSliderPopover: NSView {
    private var glassView: NSView?
    private let trackView = NSView()
    private let fillView = NSView()
    private var tracking: NSTrackingArea?
    private var isDragging = false
    private(set) var volume: Double = 1.0

    var onVolumeChanged: ((Double) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .clear
            gv.appearance = NSAppearance(named: .darkAqua)
            gv.tintColor = NSColor(white: 0.16, alpha: 0.34)
            if #available(macOS 27.0, *) {
                gv.effectIsInteractive = true
            }
            addSubview(gv)
            self.glassView = gv
        } else {
            let vev = NSVisualEffectView()
            vev.material = .hudWindow
            vev.blendingMode = .withinWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.masksToBounds = true
            addSubview(vev)
            self.glassView = vev
        }

        trackView.wantsLayer = true
        trackView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        trackView.layer?.masksToBounds = true
        addSubview(trackView)

        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        trackView.addSubview(fillView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setVolume(_ v: Double) {
        volume = max(0, min(1, v))
        layoutFill()
    }

    override func layout() {
        super.layout()
        let r = bounds.width * 0.5
        glassView?.frame = bounds
        if #available(macOS 26.0, *), let gv = glassView as? NSGlassEffectView {
            gv.cornerRadius = r
        } else {
            glassView?.layer?.cornerRadius = r
        }
        let tw: CGFloat = 6.0
        let padY: CGFloat = 12.0
        trackView.frame = NSRect(x: (bounds.width - tw) * 0.5, y: padY, width: tw, height: max(20, bounds.height - padY * 2))
        trackView.layer?.cornerRadius = tw * 0.5
        layoutFill()
    }

    private func layoutFill() {
        let th = trackView.bounds.height
        let fh = round(th * CGFloat(volume))
        // trackView is non-flipped (y = 0 at bottom), so y = 0 grows UPWARD from bottom as volume increases.
        fillView.frame = NSRect(x: 0, y: 0, width: trackView.bounds.width, height: fh)
        fillView.layer?.cornerRadius = trackView.bounds.width * 0.5
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -6, dy: -12), options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    private func updateVolume(from event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let tf = trackView.frame
        guard tf.height > 1 else { return }
        let frac = Double(max(0, min(1, (tf.maxY - pt.y) / tf.height)))
        volume = frac
        layoutFill()
        onVolumeChanged?(frac)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        onDragStateChanged?(true)
        updateVolume(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        updateVolume(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        updateVolume(from: event)
        isDragging = false
        onDragStateChanged?(false)
    }
}

// MARK: - Bottom Liquid Glass Scrubber Pill

final class LiquidGlassBottomPill: NSView {
    private var glassView: NSView?
    private let curLabel = NSTextField(labelWithString: "0:00")
    private let durLabel = NSTextField(labelWithString: "0:00")
    private let scrubTrack = NSView()
    private let scrubFill = NSView()
    let volumeButton = NSButton()

    private var tracking: NSTrackingArea?
    private var volTracking: NSTrackingArea?
    private var isScrubbing = false
    private var progress: Double = 0
    private var showTimes = false

    var onSeek: ((Double) -> Void)?
    var onScrubStateChanged: ((Bool) -> Void)?
    var onToggleMute: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onVolumeHoverChanged: ((Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .clear
            gv.appearance = NSAppearance(named: .darkAqua)
            gv.tintColor = NSColor(white: 0.16, alpha: 0.24)
            if #available(macOS 27.0, *) {
                gv.effectIsInteractive = true
            }
            addSubview(gv)
            self.glassView = gv
        } else {
            let vev = NSVisualEffectView()
            vev.material = .hudWindow
            vev.blendingMode = .withinWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.masksToBounds = true
            addSubview(vev)
            self.glassView = vev
        }

        for lbl in [curLabel, durLabel] {
            lbl.font = NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .medium)
            lbl.textColor = NSColor.white.withAlphaComponent(0.92)
            lbl.alignment = .center
            addSubview(lbl)
        }

        scrubTrack.wantsLayer = true
        scrubTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        scrubTrack.layer?.masksToBounds = true
        addSubview(scrubTrack)

        scrubFill.wantsLayer = true
        scrubFill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        scrubTrack.addSubview(scrubFill)

        volumeButton.isBordered = false
        volumeButton.image = AssetLoader.shared.symbol(named: "speaker.wave.2.fill", pointSize: 12.5, weight: .medium)
        volumeButton.contentTintColor = NSColor.white.withAlphaComponent(0.94)
        volumeButton.target = self
        volumeButton.action = #selector(volClicked)
        addSubview(volumeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(currentTime: Double, duration: Double, muted: Bool, volume: Double, showTimes: Bool) {
        self.showTimes = showTimes
        curLabel.isHidden = !showTimes
        durLabel.isHidden = !showTimes
        curLabel.stringValue = Self.formatTime(currentTime)
        durLabel.stringValue = Self.formatTime(duration)
        if !isScrubbing {
            progress = (duration > 0 && duration.isFinite) ? max(0, min(1, currentTime / duration)) : 0
        }
        let isMuted = muted || volume <= 0.001
        volumeButton.image = AssetLoader.shared.symbol(
            named: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            pointSize: max(10.5, min(13.5, bounds.height * 0.42)),
            weight: .medium
        )
        volumeButton.alphaValue = isMuted ? 0.55 : 1.0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let r = h * 0.5
        glassView?.frame = bounds
        if #available(macOS 26.0, *), let gv = glassView as? NSGlassEffectView {
            gv.cornerRadius = r
        } else {
            glassView?.layer?.cornerRadius = r
        }

        let volSize = max(20.0, h - 4.0)
        volumeButton.frame = NSRect(x: w - volSize - 4.0, y: (h - volSize) * 0.5, width: volSize, height: volSize)

        let padLeft: CGFloat = 12.0
        let scrubH = max(7.0, min(11.0, round(h * 0.34)))
        let scrubY = (h - scrubH) * 0.5

        if showTimes {
            let tw: CGFloat = 38.0
            curLabel.frame = NSRect(x: padLeft, y: (h - 14) * 0.5, width: tw, height: 14)
            let durX = volumeButton.frame.minX - tw - 6.0
            durLabel.frame = NSRect(x: durX, y: (h - 14) * 0.5, width: tw, height: 14)
            let sx = curLabel.frame.maxX + 8.0
            let sw = max(24.0, durX - sx - 8.0)
            scrubTrack.frame = NSRect(x: sx, y: scrubY, width: sw, height: scrubH)
        } else {
            let sx = padLeft
            let sw = max(24.0, volumeButton.frame.minX - sx - 8.0)
            scrubTrack.frame = NSRect(x: sx, y: scrubY, width: sw, height: scrubH)
        }
        scrubTrack.layer?.cornerRadius = scrubH * 0.5
        layoutFill()
    }

    private func layoutFill() {
        let fw = round(scrubTrack.bounds.width * CGFloat(progress))
        scrubFill.frame = NSRect(x: 0, y: 0, width: fw, height: scrubTrack.bounds.height)
        scrubFill.layer?.cornerRadius = scrubTrack.bounds.height * 0.5
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        if let volTracking { removeTrackingArea(volTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["kind": "pill"])
        addTrackingArea(area)
        tracking = area

        let volRect = volumeButton.frame.insetBy(dx: -4, dy: -6)
        let vArea = NSTrackingArea(rect: volRect, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["kind": "vol"])
        addTrackingArea(vArea)
        volTracking = vArea
    }

    override func mouseEntered(with event: NSEvent) {
        let kind = (event.trackingArea?.userInfo?["kind"] as? String) ?? "pill"
        if kind == "vol" { onVolumeHoverChanged?(true) }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        let kind = (event.trackingArea?.userInfo?["kind"] as? String) ?? "pill"
        if kind == "vol" {
            onVolumeHoverChanged?(false)
        } else {
            onHoverChanged?(false)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if volumeButton.frame.insetBy(dx: -4, dy: -4).contains(local) {
            return volumeButton
        }
        return self
    }

    private func seek(from event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let tf = scrubTrack.frame
        guard tf.width > 1 else { return }
        let frac = Double(max(0, min(1, (pt.x - tf.minX) / tf.width)))
        progress = frac
        layoutFill()
        onSeek?(frac)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if volumeButton.frame.contains(pt) {
            super.mouseDown(with: event)
            return
        }
        let hitTrack = scrubTrack.frame.insetBy(dx: -6, dy: -10)
        if hitTrack.contains(pt) {
            isScrubbing = true
            onScrubStateChanged?(true)
            seek(from: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbing else { return }
        seek(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isScrubbing else { return }
        seek(from: event)
        isScrubbing = false
        onScrubStateChanged?(false)
    }

    @objc private func volClicked() {
        onToggleMute?()
    }

    static func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && sec >= 0 else { return "0:00" }
        let s = Int(sec)
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, r)
        }
        return String(format: "%d:%02d", m, r)
    }
}

// MARK: - iOS 27 PiP Liquid Glass Video HUD (Transparent over Embedded Chromium <video>)

private final class NativeGlassVideoHUDView: NSView {
    let videoID: String
    var isVideoVisible: Bool = true
    weak var scrollForwardTarget: NSView?
    var onCommand: ((_ command: String, _ value: Double?) -> Void)?

    private var state = NativeVideoOverlayContainerView.VideoState()
    private var tracking: NSTrackingArea?

    private let chromeContainer = FlippedGlassView()
    private lazy var hideButton = LiquidGlassCircleButton(symbolName: "xmark", weight: .bold) { [weak self] in
        self?.setManualHidden(true)
    }
    private lazy var fsButton = LiquidGlassCircleButton(symbolName: "arrow.up.left.and.arrow.down.right", weight: .semibold) { [weak self] in
        self?.onCommand?("fullscreen", nil)
    }
    private lazy var pipButton = LiquidGlassCircleButton(symbolName: "pip.enter", weight: .semibold) { [weak self] in
        self?.onCommand?("pip", nil)
    }
    private lazy var back10Button = LiquidGlassCircleButton(symbolName: "gobackward.10", weight: .semibold) { [weak self] in
        self?.onCommand?("seekBy", -10)
        self?.scheduleAutoHide(delay: 2.0)
    }
    private lazy var playButton = LiquidGlassCircleButton(symbolName: "play.fill", weight: .bold) { [weak self] in
        self?.onCommand?("togglePlay", nil)
        self?.scheduleAutoHide(delay: 2.0)
    }
    private lazy var fwd10Button = LiquidGlassCircleButton(symbolName: "goforward.10", weight: .semibold) { [weak self] in
        self?.onCommand?("seekBy", 10)
        self?.scheduleAutoHide(delay: 2.0)
    }
    private let bottomPill = LiquidGlassBottomPill()
    private let volumePopover = LiquidGlassVolumeSliderPopover()

    // Finite hide/show state
    private var isHoveringHUD = false
    private var isHoveringControl = false
    private var isHoveringVolIcon = false
    private var isHoveringVolPop = false
    private var isScrubbing = false
    private var isDraggingVolume = false
    private var isManualHidden = false
    private var isChromeHidden = false
    private var autoHideWorkItem: DispatchWorkItem?
    private var volCloseWorkItem: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(videoID: String) {
        self.videoID = videoID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        chromeContainer.wantsLayer = true
        chromeContainer.layer?.masksToBounds = true
        addSubview(chromeContainer)

        for btn in [hideButton, fsButton, pipButton, back10Button, playButton, fwd10Button] {
            btn.onHoverChanged = { [weak self] hovered in
                self?.controlHoverChanged(hovered)
            }
            chromeContainer.addSubview(btn)
        }

        bottomPill.onSeek = { [weak self] frac in
            self?.onCommand?("seekTo", frac)
        }
        bottomPill.onScrubStateChanged = { [weak self] active in
            guard let self else { return }
            self.isScrubbing = active
            if active { self.cancelAutoHide() } else { self.scheduleAutoHide(delay: 1.8) }
        }
        bottomPill.onToggleMute = { [weak self] in
            self?.onCommand?("toggleMute", nil)
            self?.scheduleAutoHide(delay: 2.0)
        }
        bottomPill.onHoverChanged = { [weak self] hovered in
            self?.controlHoverChanged(hovered)
        }
        bottomPill.onVolumeHoverChanged = { [weak self] hovered in
            guard let self else { return }
            self.isHoveringVolIcon = hovered
            self.updateVolumePopoverVisibility()
        }
        chromeContainer.addSubview(bottomPill)

        volumePopover.alphaValue = 0.0
        volumePopover.isHidden = true
        volumePopover.onVolumeChanged = { [weak self] vol in
            self?.onCommand?("setVolume", vol)
        }
        volumePopover.onDragStateChanged = { [weak self] active in
            guard let self else { return }
            self.isDraggingVolume = active
            if active { self.cancelAutoHide() } else { self.updateVolumePopoverVisibility(); self.scheduleAutoHide(delay: 1.8) }
        }
        volumePopover.onHoverChanged = { [weak self] hovered in
            guard let self else { return }
            self.isHoveringVolPop = hovered
            self.controlHoverChanged(hovered)
            self.updateVolumePopoverVisibility()
        }
        chromeContainer.addSubview(volumePopover)
    }

    required init?(coder: NSCoder) { fatalError() }

    func teardown() {
        cancelAutoHide()
        volCloseWorkItem?.cancel()
        volCloseWorkItem = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if let target = scrollForwardTarget {
            target.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func applyState(_ newState: NativeVideoOverlayContainerView.VideoState) {
        let wasPlaying = !state.paused
        state = newState
        let isPlaying = !state.paused

        playButton.setSymbol(isPlaying ? "pause.fill" : "play.fill", weight: .bold)
        let showTimes = bounds.width >= 460
        bottomPill.apply(
            currentTime: state.currentTime,
            duration: state.duration,
            muted: state.muted,
            volume: state.volume,
            showTimes: showTimes
        )
        if !isDraggingVolume {
            volumePopover.setVolume(state.muted ? 0 : state.volume)
        }

        if isPlaying && !wasPlaying {
            isManualHidden = false
            scheduleAutoHide(delay: 1.8)
        } else if !isPlaying && wasPlaying {
            cancelAutoHide()
            if !isManualHidden {
                setChromeHidden(false, animated: true)
            }
        }
        updateRestingState(animated: true)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        chromeContainer.frame = bounds
        if state.clipTop > 0 || state.clipBottom > 0 {
            let maskLayer = CAShapeLayer()
            let visY = state.clipTop
            let visH = max(0, h - state.clipTop - state.clipBottom)
            maskLayer.path = CGPath(rect: CGRect(x: 0, y: visY, width: w, height: visH), transform: nil)
            chromeContainer.layer?.mask = maskLayer
        } else {
            chromeContainer.layer?.mask = nil
        }

        let minDim = min(w, h)
        let pad = round(max(8.0, min(18.0, minDim * 0.05)))
        let sm = round(max(24.0, min(38.0, minDim * 0.145)))
        let md = round(max(32.0, min(52.0, minDim * 0.20)))
        let lg = round(max(44.0, min(68.0, minDim * 0.27)))
        let gap = round(max(12.0, min(32.0, w * 0.065)))
        let pillH = round(max(24.0, min(38.0, minDim * 0.14)))

        hideButton.frame = NSRect(x: pad, y: pad, width: sm, height: sm)
        pipButton.frame = NSRect(x: w - pad - sm, y: pad, width: sm, height: sm)
        let showFS = w >= 420 && h >= 240
        fsButton.isHidden = !showFS
        fsButton.frame = NSRect(x: pipButton.frame.minX - sm - 8.0, y: pad, width: sm, height: sm)

        let pillW = min(640.0, max(80.0, w - pad * 2.0))
        bottomPill.frame = NSRect(x: (w - pillW) * 0.5, y: h - pad - pillH, width: pillW, height: pillH)

        let isResting = state.paused && !isHoveringHUD && !isHoveringControl && !isScrubbing && !isDraggingVolume
        let centerY = isResting ? (h * 0.5) : ((h - pillH * 0.55) * 0.5)
        let centerX = w * 0.5

        playButton.frame = NSRect(x: centerX - lg * 0.5, y: centerY - lg * 0.5, width: lg, height: lg)
        back10Button.frame = NSRect(x: playButton.frame.minX - gap - md, y: centerY - md * 0.5, width: md, height: md)
        fwd10Button.frame = NSRect(x: playButton.frame.maxX + gap, y: centerY - md * 0.5, width: md, height: md)

        // Position upward-opening vertical volume popover directly above volumeButton
        let popW: CGFloat = 34.0
        let popH: CGFloat = min(104.0, max(64.0, h - pillH - pad * 2.5))
        let volCenterX = bottomPill.frame.minX + bottomPill.volumeButton.frame.midX
        volumePopover.frame = NSRect(
            x: max(4, min(w - popW - 4, volCenterX - popW * 0.5)),
            y: bottomPill.frame.minY - popH - 8.0,
            width: popW,
            height: popH
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHoveringHUD = true
        if !isManualHidden {
            setChromeHidden(false, animated: true)
            scheduleAutoHide(delay: 2.0)
        }
        updateRestingState(animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        if !isManualHidden && !state.paused {
            setChromeHidden(false, animated: true)
            scheduleAutoHide(delay: 2.0)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringHUD = false
        isHoveringControl = false
        isHoveringVolIcon = false
        isHoveringVolPop = false
        updateVolumePopoverVisibility()
        updateRestingState(animated: true)
        if !state.paused && !isScrubbing && !isDraggingVolume {
            scheduleAutoHide(delay: 0.35)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onCommand?("fullscreen", nil)
            return
        }
        // Clicking empty video canvas toggles manual hide / reveal (works both paused and playing)
        if isChromeHidden {
            isManualHidden = false
            setChromeHidden(false, animated: true)
            updateRestingState(animated: true)
            scheduleAutoHide(delay: 2.2)
        } else {
            setManualHidden(true)
        }
    }

    private func setManualHidden(_ hidden: Bool) {
        isManualHidden = hidden
        if hidden {
            cancelAutoHide()
            isHoveringVolIcon = false
            isHoveringVolPop = false
            updateVolumePopoverVisibility()
            setChromeHidden(true, animated: true)
        } else {
            setChromeHidden(false, animated: true)
            scheduleAutoHide(delay: 2.0)
        }
    }

    private func controlHoverChanged(_ hovered: Bool) {
        isHoveringControl = hovered
        if hovered {
            cancelAutoHide()
            if !isManualHidden { setChromeHidden(false, animated: true) }
        } else {
            scheduleAutoHide(delay: 1.0)
        }
        updateRestingState(animated: true)
    }

    private func updateVolumePopoverVisibility() {
        volCloseWorkItem?.cancel()
        volCloseWorkItem = nil
        let shouldShow = (isHoveringVolIcon || isHoveringVolPop || isDraggingVolume) && !isChromeHidden
        if shouldShow {
            volumePopover.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                volumePopover.animator().alphaValue = 1.0
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !(self.isHoveringVolIcon || self.isHoveringVolPop || self.isDraggingVolume) || self.isChromeHidden else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.volumePopover.animator().alphaValue = 0.0
                }, completionHandler: { [weak self] in
                    guard let self else { return }
                    if self.volumePopover.alphaValue < 0.05 {
                        self.volumePopover.isHidden = true
                    }
                })
            }
            volCloseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }
    }

    private func updateRestingState(animated: Bool) {
        let isResting = state.paused && !isHoveringHUD && !isHoveringControl && !isScrubbing && !isDraggingVolume
        let secondaryAlpha: CGFloat = isResting ? 0.0 : 1.0
        let apply = {
            self.hideButton.alphaValue = secondaryAlpha
            self.pipButton.alphaValue = secondaryAlpha
            self.fsButton.alphaValue = secondaryAlpha
            self.back10Button.alphaValue = secondaryAlpha
            self.fwd10Button.alphaValue = secondaryAlpha
            self.bottomPill.alphaValue = secondaryAlpha
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.hideButton.animator().alphaValue = secondaryAlpha
                self.pipButton.animator().alphaValue = secondaryAlpha
                self.fsButton.animator().alphaValue = secondaryAlpha
                self.back10Button.animator().alphaValue = secondaryAlpha
                self.fwd10Button.animator().alphaValue = secondaryAlpha
                self.bottomPill.animator().alphaValue = secondaryAlpha
            }
        } else {
            apply()
        }
        needsLayout = true
    }

    private func setChromeHidden(_ hidden: Bool, animated: Bool) {
        guard isChromeHidden != hidden else { return }
        isChromeHidden = hidden
        if hidden {
            updateVolumePopoverVisibility()
        }
        let targetAlpha: CGFloat = hidden ? 0.0 : 1.0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                chromeContainer.animator().alphaValue = targetAlpha
            }
        } else {
            chromeContainer.alphaValue = targetAlpha
        }
    }

    private func cancelAutoHide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
    }

    private func scheduleAutoHide(delay: TimeInterval) {
        cancelAutoHide()
        guard !isManualHidden else {
            setChromeHidden(true, animated: true)
            return
        }
        guard !state.paused, !isHoveringControl, !isScrubbing, !isDraggingVolume, !isHoveringVolPop else {
            setChromeHidden(false, animated: true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.state.paused && !self.isHoveringControl && !self.isScrubbing && !self.isDraggingVolume && !self.isHoveringVolPop {
                self.setChromeHidden(true, animated: true)
            }
        }
        autoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !isChromeHidden {
            // Check volume popover first when visible
            if !volumePopover.isHidden && volumePopover.alphaValue > 0.1 && volumePopover.frame.contains(local) {
                return volumePopover.hitTest(local) ?? volumePopover
            }
            for sub in chromeContainer.subviews.reversed() where !sub.isHidden && sub.alphaValue > 0.1 {
                if sub.frame.contains(local) {
                    return sub.hitTest(local) ?? sub
                }
            }
        }
        // Empty video area hit: lets click toggle manual hide/show while scrollWheel forwards to page
        return self
    }
}


private final class FlippedGlassView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
