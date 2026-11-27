import AppKit
import QuartzCore

/// Native macOS 27 Tahoe Safari Tab Hover Preview Card (1:1 layout):
/// - Full-bleed edge-to-edge top-anchored live page snapshot inside an `18 pt` continuous-corner floating card
/// - Translucent frosted glass footer band overlaid along the bottom edge showing title + domain (no favicon)
final class TabHoverPreviewController {

    struct PreviewItem {
        let tabID: String
        let title: String
        let domain: String
        let favicon: NSImage?
        let snapshot: NSImage?
        let isStartPage: Bool
        let canClose: Bool

        init(
            tabID: String,
            title: String,
            domain: String,
            favicon: NSImage?,
            snapshot: NSImage?,
            isStartPage: Bool,
            canClose: Bool = false
        ) {
            self.tabID = tabID
            self.title = title
            self.domain = domain
            self.favicon = favicon
            self.snapshot = snapshot
            self.isStartPage = isStartPage
            self.canClose = canClose
        }
    }

    enum Placement {
        /// Centered below the hovered tab in Compact / Separate tab bars.
        case below(anchorView: NSView)
        /// Placed beside the hovered tab in the Vertical tab rail.
        case belowVerticalPill(anchorView: NSView, railRightXInWindow: CGFloat)
    }

    var onCloseTab: ((String) -> Void)?
    var onSelectTab: ((String) -> Void)?

    static let cardWidth: CGFloat = 276.0
    static let cardHeight: CGFloat = 224.0
    private static let footerHeight: CGFloat = 60.0
    private static let cornerRadius: CGFloat = 18.0
    private static let initialHoverDelay: TimeInterval = 0.42
    private static let verticalHoverDelay: TimeInterval = 0.10
    private static let switchHoverDelay: TimeInterval = 0.04

    var panel: NSPanel?
    private var rootCardView: PreviewInteractiveCardView?
    private var borderOverlayView: NSView?
    private var thumbnailView: TopAnchoredSnapshotView?
    var placeholderView: NSView?
    var placeholderIcon: NSImageView?
    private var footerBlurView: NSVisualEffectView?
    private var footerTintView: NSView?
    private var footerTopHairline: NSView?
    private var closeButton: PreviewCloseButton?
    private var titleTrailingToCloseConstraint: NSLayoutConstraint?
    private var titleTrailingToEdgeConstraint: NSLayoutConstraint?
    var titleLabel: NSTextField?
    var domainLabel: NSTextField?

    private weak var hostWindow: NSWindow?
    var currentTabID: String?
    var pendingTabID: String?
    private var isPointerInCard: Bool = false
    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var isDark: Bool = false

    deinit {
        dismiss(animated: false)
    }

    func hoverEntered(
        item: PreviewItem,
        placement: Placement,
        in window: NSWindow,
        isDark: Bool
    ) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        showWorkItem?.cancel()
        showWorkItem = nil

        self.hostWindow = window
        self.isDark = isDark
        self.pendingTabID = item.tabID

        let alreadyVisible = (panel?.isVisible == true && panel?.alphaValue ?? 0 > 0.1)
        let isVertical: Bool
        if case .belowVerticalPill = placement { isVertical = true } else { isVertical = false }
        let delay = alreadyVisible ? Self.switchHoverDelay : (isVertical ? Self.verticalHoverDelay : Self.initialHoverDelay)

        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.pendingTabID == item.tabID else { return }
            self.present(item: item, placement: placement, in: window, isDark: isDark, glide: alreadyVisible)
        }
        showWorkItem = work
        if delay <= 0.001 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func hoverExited(tabID: String) {
        if pendingTabID == tabID {
            pendingTabID = nil
            showWorkItem?.cancel()
            showWorkItem = nil
        }
        guard currentTabID == tabID else { return }
        scheduleDismissIfPointerOutside()
    }

    private func scheduleDismissIfPointerOutside() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingTabID == nil, !self.isPointerInCard else { return }
            self.dismiss(animated: true)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func dismiss(animated: Bool = false) {
        showWorkItem?.cancel()
        showWorkItem = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        pendingTabID = nil
        currentTabID = nil
        isPointerInCard = false

        guard let p = panel else { return }
        if animated && p.isVisible && p.alphaValue > 0.05 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.11
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().alphaValue = 0.0
            }, completionHandler: { [weak self, weak p] in
                guard let self, let p else { return }
                if self.currentTabID == nil {
                    p.parent?.removeChildWindow(p)
                    p.orderOut(nil)
                }
            })
        } else {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
            p.alphaValue = 0.0
        }
    }

    // MARK: - Presentation & Layout

    private func present(
        item: PreviewItem,
        placement: Placement,
        in window: NSWindow,
        isDark: Bool,
        glide: Bool
    ) {
        let cardSize = NSSize(width: Self.cardWidth, height: Self.cardHeight)
        ensurePanel(size: cardSize)
        guard let panel else { return }

        currentTabID = item.tabID
        populate(item: item, isDark: isDark)

        let targetFrame = computePanelFrame(cardSize: cardSize, placement: placement, parentWindow: window)

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 0.0
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        } else if glide && panel.isVisible && panel.alphaValue > 0.1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        } else {
            panel.setFrame(targetFrame, display: true)
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }
    }

    func computePanelFrame(
        cardSize: NSSize,
        placement: Placement,
        parentWindow: NSWindow
    ) -> NSRect {
        let screenFrame = (parentWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 10.0

        var x: CGFloat
        var y: CGFloat

        switch placement {
        case .below(let anchorView):
            let inWin = anchorView.convert(anchorView.bounds, to: nil)
            let onScreen = parentWindow.convertToScreen(inWin)
            x = round(onScreen.midX - cardSize.width * 0.5)
            y = round(onScreen.minY - 6.0 - cardSize.height)

        case .belowVerticalPill(let anchorView, let railRightXInWindow):
            let inWin = anchorView.convert(anchorView.bounds, to: nil)
            let onScreen = parentWindow.convertToScreen(inWin)
            let railEdgeOnScreen = parentWindow.convertToScreen(NSRect(x: railRightXInWindow, y: 0, width: 0, height: 0)).origin.x
            x = round(railEdgeOnScreen + 4.0)
            y = round(onScreen.midY - cardSize.height * 0.5)
        }

        x = max(screenFrame.minX + margin, min(screenFrame.maxX - cardSize.width - margin, x))
        y = max(screenFrame.minY + margin, min(screenFrame.maxY - cardSize.height - margin, y))
        return NSRect(x: x, y: y, width: cardSize.width, height: cardSize.height)
    }

    func ensurePanel(size: NSSize) {
        if panel != nil { return }

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.level = .floating
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.alphaValue = 0.0

        // Rounded full-bleed interactive card root
        let card = PreviewInteractiveCardView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.onHoverChanged = { [weak self] inside in
            guard let self else { return }
            self.isPointerInCard = inside
            if inside {
                self.hideWorkItem?.cancel()
                self.hideWorkItem = nil
            } else {
                self.scheduleDismissIfPointerOutside()
            }
        }
        card.onCardClick = { [weak self] in
            guard let self, let id = self.currentTabID else { return }
            self.dismiss(animated: false)
            self.onSelectTab?(id)
        }

        // Full-bleed top-anchored webpage snapshot spanning the entire card
        let thumb = TopAnchoredSnapshotView()
        thumb.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(thumb)

        // Fallback placeholder when snapshot is not yet captured
        let ph = NSView()
        ph.translatesAutoresizingMaskIntoConstraints = false
        ph.wantsLayer = true
        let phIcon = NSImageView()
        phIcon.translatesAutoresizingMaskIntoConstraints = false
        phIcon.imageScaling = .scaleProportionallyDown
        ph.addSubview(phIcon)
        card.addSubview(ph)

        // Bottom frosted glass overlay band (matches Tahoe Safari's bottom title+domain band 1:1)
        let footerBlur = NSVisualEffectView()
        footerBlur.translatesAutoresizingMaskIntoConstraints = false
        footerBlur.material = .popover
        footerBlur.blendingMode = .behindWindow
        footerBlur.state = .active
        footerBlur.wantsLayer = true
        card.addSubview(footerBlur)

        let footerTint = NSView()
        footerTint.translatesAutoresizingMaskIntoConstraints = false
        footerTint.wantsLayer = true
        footerBlur.addSubview(footerTint)

        let hairline = NSView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        footerBlur.addSubview(hairline)

        let titleLbl = NSTextField(labelWithString: "")
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.maximumNumberOfLines = 1
        titleLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerBlur.addSubview(titleLbl)

        let domLbl = NSTextField(labelWithString: "")
        domLbl.translatesAutoresizingMaskIntoConstraints = false
        domLbl.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
        domLbl.lineBreakMode = .byTruncatingTail
        domLbl.maximumNumberOfLines = 1
        domLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerBlur.addSubview(domLbl)

        let closeBtn = PreviewCloseButton()
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.onClick = { [weak self] in
            guard let self, let id = self.currentTabID else { return }
            self.dismiss(animated: false)
            self.onCloseTab?(id)
        }
        footerBlur.addSubview(closeBtn)

        // Crisp 0.5pt outer glass rim sitting above both thumbnail and footer
        let borderOverlay = NSView()
        borderOverlay.translatesAutoresizingMaskIntoConstraints = false
        borderOverlay.wantsLayer = true
        borderOverlay.layer?.cornerRadius = Self.cornerRadius
        borderOverlay.layer?.cornerCurve = .continuous
        borderOverlay.layer?.borderWidth = 0.5
        borderOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        card.addSubview(borderOverlay)

        let titleTrailingToClose = titleLbl.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8)
        let titleTrailingToEdge = titleLbl.trailingAnchor.constraint(equalTo: footerBlur.trailingAnchor, constant: -15)
        titleTrailingToClose.isActive = false
        titleTrailingToEdge.isActive = true

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: card.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            ph.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            ph.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ph.topAnchor.constraint(equalTo: card.topAnchor),
            ph.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            phIcon.centerXAnchor.constraint(equalTo: ph.centerXAnchor),
            phIcon.centerYAnchor.constraint(equalTo: ph.centerYAnchor, constant: -Self.footerHeight * 0.45),
            phIcon.widthAnchor.constraint(equalToConstant: 36),
            phIcon.heightAnchor.constraint(equalToConstant: 36),

            footerBlur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footerBlur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footerBlur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footerBlur.heightAnchor.constraint(equalToConstant: Self.footerHeight),

            footerTint.leadingAnchor.constraint(equalTo: footerBlur.leadingAnchor),
            footerTint.trailingAnchor.constraint(equalTo: footerBlur.trailingAnchor),
            footerTint.topAnchor.constraint(equalTo: footerBlur.topAnchor),
            footerTint.bottomAnchor.constraint(equalTo: footerBlur.bottomAnchor),

            hairline.leadingAnchor.constraint(equalTo: footerBlur.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: footerBlur.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: footerBlur.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            closeBtn.trailingAnchor.constraint(equalTo: footerBlur.trailingAnchor, constant: -12),
            closeBtn.centerYAnchor.constraint(equalTo: footerBlur.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 24),
            closeBtn.heightAnchor.constraint(equalToConstant: 24),

            titleLbl.leadingAnchor.constraint(equalTo: footerBlur.leadingAnchor, constant: 15),
            titleLbl.topAnchor.constraint(equalTo: footerBlur.topAnchor, constant: 12),

            domLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            domLbl.trailingAnchor.constraint(equalTo: titleLbl.trailingAnchor),
            domLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),

            borderOverlay.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            borderOverlay.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            borderOverlay.topAnchor.constraint(equalTo: card.topAnchor),
            borderOverlay.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        p.contentView = card

        self.panel = p
        self.rootCardView = card
        self.borderOverlayView = borderOverlay
        self.thumbnailView = thumb
        self.placeholderView = ph
        self.placeholderIcon = phIcon
        self.footerBlurView = footerBlur
        self.footerTintView = footerTint
        self.footerTopHairline = hairline
        self.closeButton = closeBtn
        self.titleTrailingToCloseConstraint = titleTrailingToClose
        self.titleTrailingToEdgeConstraint = titleTrailingToEdge
        self.titleLabel = titleLbl
        self.domainLabel = domLbl
    }

    func populate(item: PreviewItem, isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        panel?.appearance = appearance
        footerBlurView?.appearance = appearance
        footerBlurView?.material = isDark ? .hudWindow : .popover

        closeButton?.isHidden = !item.canClose
        closeButton?.apply(isDark: isDark)
        titleTrailingToCloseConstraint?.isActive = item.canClose
        titleTrailingToEdgeConstraint?.isActive = !item.canClose

        let cleanTitle = item.isStartPage ? "Start Page" : (item.title.isEmpty ? item.domain : item.title)
        titleLabel?.stringValue = cleanTitle
        domainLabel?.stringValue = item.isStartPage ? "Favorites & Recently Viewed" : item.domain

        titleLabel?.textColor = isDark ? NSColor.white.withAlphaComponent(0.95) : NSColor(white: 0.10, alpha: 1.0)
        domainLabel?.textColor = isDark ? NSColor.white.withAlphaComponent(0.58) : NSColor(white: 0.42, alpha: 1.0)

        footerTintView?.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.13, green: 0.135, blue: 0.15, alpha: 0.62)
            : NSColor(srgbRed: 0.98, green: 0.985, blue: 1.0, alpha: 0.68)).cgColor
        footerTopHairline?.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.06)).cgColor
        borderOverlayView?.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.12)).cgColor

        if let snap = item.snapshot {
            thumbnailView?.image = snap
            thumbnailView?.isHidden = false
            placeholderView?.isHidden = true
        } else {
            thumbnailView?.image = nil
            thumbnailView?.isHidden = true
            placeholderView?.isHidden = false
            placeholderView?.layer?.backgroundColor = (isDark
                ? NSColor(srgbRed: 0.16, green: 0.165, blue: 0.18, alpha: 0.96)
                : NSColor(srgbRed: 0.95, green: 0.955, blue: 0.97, alpha: 0.96)).cgColor
            if let fav = item.favicon, !item.isStartPage {
                placeholderIcon?.image = fav
                placeholderIcon?.contentTintColor = nil
            } else {
                placeholderIcon?.image = NSImage(
                    systemSymbolName: item.isStartPage ? "safari" : "globe",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(.init(pointSize: 30, weight: .light))
                placeholderIcon?.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.42) : NSColor.black.withAlphaComponent(0.32)
            }
        }
    }
}

/// Aspect-fill top-anchored snapshot renderer so page previews always display the top of the webpage cleanly.
private final class TopAnchoredSnapshotView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let imgSize = image.size
        guard imgSize.width > 1, imgSize.height > 1 else { return }

        let scale = max(bounds.width / imgSize.width, bounds.height / imgSize.height)
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let drawX = (bounds.width - drawW) * 0.5
        // Non-flipped AppKit coordinates: pin the TOP of the snapshot (`maxY`) to `bounds.maxY`
        let drawY = bounds.height - drawH

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH),
            from: NSRect(origin: .zero, size: imgSize),
            operation: .sourceOver,
            fraction: 1.0
        )
    }
}

private final class PreviewInteractiveCardView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onCardClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onCardClick?()
    }
}

private final class PreviewCloseButton: NSView {
    var onClick: (() -> Void)?
    private let bgView = NSView()
    private let glyphView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isDark = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        bgView.translatesAutoresizingMaskIntoConstraints = false
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 11.0
        addSubview(bgView)

        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 10.0, weight: .semibold))
        addSubview(glyphView)

        NSLayoutConstraint.activate([
            bgView.centerXAnchor.constraint(equalTo: centerXAnchor),
            bgView.centerYAnchor.constraint(equalTo: centerYAnchor),
            bgView.widthAnchor.constraint(equalToConstant: 22),
            bgView.heightAnchor.constraint(equalToConstant: 22),
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        apply(isDark: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        apply(isDark: isDark)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        apply(isDark: isDark)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func apply(isDark: Bool) {
        self.isDark = isDark
        if isHovered {
            bgView.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.10)).cgColor
            glyphView.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.96) : NSColor(white: 0.10, alpha: 0.94)
        } else {
            bgView.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)).cgColor
            glyphView.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.68) : NSColor.black.withAlphaComponent(0.55)
        }
    }
}
