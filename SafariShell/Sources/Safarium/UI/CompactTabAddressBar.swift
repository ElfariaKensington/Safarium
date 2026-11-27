import AppKit
import QuartzCore

/// Presentation model passed from `SafariWindowController` into `CompactTabAddressBar` & `SafariSidebarView`.
struct TabPresentationItem {
    let id: String
    let title: String
    let url: URL?
    let favicon: NSImage?
    let isLoading: Bool
    let progress: Double
    let isActive: Bool
    let isPinned: Bool

    init(id: String, title: String, url: URL?, favicon: NSImage?, isLoading: Bool, progress: Double, isActive: Bool, isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.favicon = favicon
        self.isLoading = isLoading
        self.progress = progress
        self.isActive = isActive
        self.isPinned = isPinned
    }
}

/// 1:1 port of Safarium's `SafariumCompactTrackHostView` + `SafariumTabItemView` + `SafariumFocusRingOverlayView`
/// (`SafariumTabBarView.swift:703–1528`, `SafariumUnifiedField.swift:738–783`):
/// - **Exact Safarium Sizing & Positioning**:
///   - Continuous `36 pt` (`r = 18 pt`) outer stadium track centered cleanly between left & right toolbar capsules
///   - Natural tab width = `310 pt` (`1 tab = 310 pt`, `2 tabs = 620 pt`, `N tabs = min(avail, N * 310 pt)`)
///   - Equal tab widths across all tabs (active pill keeps `min(maxActive, max(equal, 200))` only when crowded)
///   - **NEVER expands or shifts on URL focus or active-tab click**
/// - **Exact Safarium Animations**:
///   - Tab open/close & sidebar toggle: `0.28 s` `CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)`
///     for both track width (`widthConstraint.animator()`) and individual slot frames (`v.animator().frame`)
///   - Newly opened tab expands smoothly from width `0 -> slotW` & `alpha 0 -> 1`
///   - Closed tab fades out cleanly over `0.18 s` before removal
///   - Plain tab switch: instant crisp frame swap (zero laggy slide, matching native macOS 27 Safari)
///   - Track tint color crossfade: `0.22 s` `.easeInEaseOut`
///   - Focus blue halo contraction: `0.20 s` (`inset(-5.5, -4.5) -> tight`, `lineWidth 4.2 -> 2.75`, `opacity 0 -> 1`)
///     and `0.08 s` `.easeOut` vanish on unfocus, completely unclipped above the track
///   - Asymmetric icon/URL focus glide: `0.19 s` in / `0.28 s` out (`controlPoints(0.2, 0.9, 0.3, 1.0)`)
///   - Live horizontal drag-to-reorder tabs inside the compact track with `0.28 s` sibling swaps
final class CompactTabAddressBar: NSView, NSTextFieldDelegate, NSGestureRecognizerDelegate {
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onTabHoverChanged: ((String, NSView, Bool) -> Void)?
    var onReorderTabs: (([String]) -> Void)?
    var canTearOffSingleTab: (() -> Bool)?
    /// Fired when a tab is dragged past the tab bar boundary: `(tabID, pillRectInScreen, cursorOffsetInPill, mouseScreen)`.
    var onBeginTabTearOff: ((String, NSRect, NSPoint, NSPoint) -> Void)?
    var onSubmitURLString: ((String) -> Void)?
    var onReloadOrStop: (() -> Void)?
    var onShowPageMenu: ((NSButton) -> Void)?
    var onAddressFocusChanged: ((Bool) -> Void)?
    var onAddressQueryChanged: ((String) -> Void)?
    var onActivePillLayoutChanged: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onCommitSelectedSuggestion: (() -> Bool)?
    /// Fired when a URL or file is dropped onto the tab/address bar: `(url, targetTabID, openInNewTab)`.
    var onDropURL: ((URL, String?, Bool) -> Void)?

    /// Enables exact macOS 27 Safari Private Browsing active-pill styling (dark charcoal `#5B5B5E` active pill
    /// with crisp white text/icons while keeping the surrounding tab track & inactive tabs light/theme-adaptive).
    var isPrivateMode: Bool = false {
        didSet {
            guard isPrivateMode != oldValue else { return }
            applyAppearanceToSubviews(animated: false)
        }
    }

    var activePillAnchorView: NSView { activePillSurfaceView }
    var isAddressBarEditing: Bool { isEditingAddress }
    var isTabDragActive: Bool { compactDraggingTabId != nil || SafariTabDragCoordinator.shared.isDragging }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Returns true when `ptInWindow` falls inside the visible tab track (active or inactive tabs).
    func isPointInTabTrack(_ ptInWindow: NSPoint) -> Bool {
        let ptInHost = trackHostView.convert(ptInWindow, from: nil)
        return trackHostView.bounds.contains(ptInHost)
    }

    /// Hit-tests a window point against both the active tab pill and every inactive tab slot (for middle-click-to-close).
    func tabID(atWindowPoint ptInWindow: NSPoint) -> String? {
        guard !items.isEmpty else { return nil }
        let ptInHost = trackHostView.convert(ptInWindow, from: nil)
        guard trackHostView.bounds.contains(ptInHost) else { return nil }
        if activePillSurfaceView.frame.contains(ptInHost), !activeTabID.isEmpty {
            return activeTabID
        }
        for v in inactiveTabViews {
            if v.frame.contains(ptInHost) {
                return v.tabID
            }
        }
        return nil
    }

    var isSidebarOpen: Bool = false {
        didSet {
            guard oldValue != isSidebarOpen else { return }
            rebuildAndLayout()
        }
    }

    override var isFlipped: Bool { true }

    // Outer centered track host (36pt tall, dynamic width min(avail, N * 310pt))
    private let trackHostView = FlippedTrackHostView()
    private var trackWidthConstraint: NSLayoutConstraint?
    private var trackCenterXConstraint: NSLayoutConstraint?

    private let trackBgView = PassthroughTrackView()
    private var trackGlassView: NSView?
    private let activePillSurfaceView = FlippedActivePillView()
    private let activePillGlassHost = PassthroughTrackView()
    private var activePillGlassView: NSView?
    private let activePillHoverTintView = PassthroughTrackView()
    private let hdrHighlightView = HDRPillHighlightView()
    private let activeCloseButton = CompactTabCloseButton()
    private let centeredTitleStack = NSStackView()
    private let centeredFaviconBadge = NSView()
    private let centeredFaviconView = NSImageView()
    private let activeDisplayLabel = NSTextField(labelWithString: "")
    private let editingIconView = NSImageView()
    private let addressTextField = NSTextField()
    private let hoverReloadButton = HoverablePillIconButton()
    private let pageMenuButton = HoverablePillIconButton()
    private let progressBarHostView = PassthroughTrackView()
    private let progressBarLayer = CALayer()
    private var displayedProgress: Double = 0.0
    private var lastRawProgress: Double = 0.0
    private var wasProgressLoading: Bool = false
    private var progressTabID: String = ""
    private var progressURLString: String = ""
    private var lastProgressBarWidth: CGFloat = 0.0
    private var progressFadeWorkItem: DispatchWorkItem?
    private var progressShowWorkItem: DispatchWorkItem?
    private var isShowingLoadingUI: Bool = false
    private var progressTrickleTimer: Timer?
    private let focusRingOverlay = SafariFocusRingOverlayView()

    private var inactiveTabViews: [CompactInactiveTabView] = []
    private var separatorViews: [NSView] = []
    private var separatorsInUse = 0
    private var activePillTrackingArea: NSTrackingArea?
    private var isActivePillHovered = false

    private var items: [TabPresentationItem] = []
    private var theme: AdaptiveChromeTheme = .defaultLight
    private var isEditingAddress = false
    private var isFocusingAddressBar = false
    private var activeTabID: String = ""
    private var activeURLString: String = ""
    private var activeIsLoading: Bool = false
    private var activeIsStartPage: Bool = false
    private var activeFavicon: NSImage?
    private var centeredTitleLeadingConstraint: NSLayoutConstraint?
    private var centeredTitleTrailingConstraint: NSLayoutConstraint?
    private var addressTextFieldLeadingConstraint: NSLayoutConstraint?
    private var addressTextFieldTrailingConstraint: NSLayoutConstraint?

    private var hasLaidOutOnce = false
    private var lastLayoutBoundsWidth: CGFloat = 0
    private var lastStructureSig: String = ""
    private var lastActiveTabID: String = ""
    private var lastTrackBgColor: CGColor?
    private var lastActiveTargetFrame: NSRect = .zero
    private var lastReportedPillRectInWindow: NSRect = .zero

    /// Ref-counted deferral so the blue focus ring never floats ahead of concurrent tab/track/sidebar animations.
    private var activeLayoutAnimationCount: Int = 0
    private var pendingAnimatedFocusRing: Bool = false
    private var isDeferringFocusRing: Bool {
        activeLayoutAnimationCount > 0 || compactDraggingTabId != nil
    }

    // Compact drag-to-reorder & cross-window tear-off state (Safarium 1:1)
    private var compactDraggingTabId: String?
    private var compactDragStartX: CGFloat = 0
    private var compactDragStartOriginX: CGFloat = 0
    private var activeDragOriginInWindow: NSPoint?
    private var hiddenDraggedTabID: String?
    var externalDropPlaceholder: (tabID: String, index: Int)?
    var lastExternalPlaceholderSlotRectInTrack: NSRect = .zero

    /// When `true` (Separate or Vertical tab layout), renders only the active tab's address pill
    /// inside the top toolbar while the tab list lives in the Separate tab strip or Vertical sidebar.
    var singleAddressOnlyMode: Bool = false {
        didSet {
            guard singleAddressOnlyMode != oldValue else { return }
            updateActiveHoverControls()
            rebuildAndLayout(forceAnimated: true)
        }
    }

    /// When `true` (Tab Overview is presented), keeps all tabs in their exact slots in the tab bar
    /// while switching only the active tab pill to Safari's empty "Search or enter website name" prompt.
    var isTabOverviewActive: Bool = false {
        didSet {
            guard isTabOverviewActive != oldValue else { return }
            if isEditingAddress {
                endAddressEditing(restoreURL: true)
            }
            applyOverviewPresentationState()
            updateActiveHoverControls()
        }
    }

    var isCurrentlyEditingAddress: Bool { isEditingAddress }

    var displayedItems: [TabPresentationItem] {
        var base = items
        if let hiddenID = hiddenDraggedTabID {
            base = base.filter { $0.id != hiddenID }
        }
        if singleAddressOnlyMode, let active = base.first(where: { $0.isActive }) {
            return [active]
        }
        return base
    }

    private func applyOverviewPresentationState() {
        if isTabOverviewActive {
            activeDisplayLabel.stringValue = "Search or enter website name"
            activeDisplayLabel.lineBreakMode = .byTruncatingTail
            centeredFaviconView.image = AssetLoader.shared.symbol(
                named: "magnifyingglass",
                pointSize: 13.5,
                weight: .medium
            )
            centeredFaviconView.contentTintColor = placeholderSecondaryInk()
            centeredFaviconBadge.layer?.backgroundColor = NSColor.clear.cgColor
            if !isEditingAddress {
                addressTextField.stringValue = ""
            }
            updateProgress(1.0, isLoading: false, urlString: "", tabID: activeTabID)
            applyAppearanceToSubviews(animated: false)
        } else {
            update(items: items, animated: false)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
        registerForDraggedTypes([.URL, .fileURL, .string])
    }

    static func extractDroppedURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first,
           let scheme = first.scheme?.lowercased(),
           ["http", "https", "file", "safarium", "chrome", "view-source"].contains(scheme) {
            return first
        }
        if let str = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            if let u = URL(string: str), let s = u.scheme?.lowercased(),
               ["http", "https", "file", "safarium", "chrome", "view-source"].contains(s) {
                return u
            }
            if str.contains(".") && !str.contains(" ") && !str.contains("://") {
                return URL(string: "https://\(str)")
            }
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.extractDroppedURL(from: sender.draggingPasteboard) else { return false }
        let ptInHost = trackHostView.convert(sender.draggingLocation, from: nil)
        let cmdHeld = NSEvent.modifierFlags.contains(.command)

        var targetTabID: String?
        if activePillSurfaceView.frame.contains(ptInHost), !activeTabID.isEmpty {
            targetTabID = activeTabID
        } else if let hitInactive = inactiveTabViews.first(where: { !$0.isHidden && $0.frame.contains(ptInHost) }) {
            targetTabID = hitInactive.tabID
        } else if trackHostView.bounds.contains(ptInHost) {
            // Dropped on a 1–2 pt gap/border inside the tab track: pick the nearest tab slot horizontally.
            var candidates: [(id: String, midX: CGFloat)] = []
            if !activeTabID.isEmpty {
                candidates.append((activeTabID, activePillSurfaceView.frame.midX))
            }
            for v in inactiveTabViews where !v.isHidden {
                candidates.append((v.tabID, v.frame.midX))
            }
            targetTabID = candidates.min(by: { abs($0.midX - ptInHost.x) < abs($1.midX - ptInHost.x) })?.id
        }

        let openInNewTab = cmdHeld || (targetTabID == nil)
        onDropURL?(url, targetTabID, openInNewTab)
        return true
    }

    deinit {
        progressTrickleTimer?.invalidate()
        progressTrickleTimer = nil
        progressFadeWorkItem?.cancel()
        progressFadeWorkItem = nil
        progressShowWorkItem?.cancel()
        progressShowWorkItem = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        trackHostView.translatesAutoresizingMaskIntoConstraints = false
        trackHostView.wantsLayer = true
        trackHostView.layer?.masksToBounds = false
        addSubview(trackHostView)

        let twc = trackHostView.widthAnchor.constraint(equalToConstant: SafariMetrics.activePillSingleTabWidth)
        // Must stay BELOW NSLayoutPriority.windowSizeStayPut (500): above it, a wide track makes AppKit grow the window
        // (e.g. when the sidebar takes 240 pt) instead of letting the track shrink to the space that is left.
        twc.priority = .init(480)
        self.trackWidthConstraint = twc

        let tcxc = trackHostView.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 0.0)
        tcxc.priority = .init(479)
        self.trackCenterXConstraint = tcxc

        NSLayoutConstraint.activate([
            tcxc,
            trackHostView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            trackHostView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            trackHostView.topAnchor.constraint(equalTo: topAnchor),
            trackHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
            trackHostView.heightAnchor.constraint(equalToConstant: SafariMetrics.tabPillHeight),
            trackHostView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            twc
        ])

        // Continuous 36pt recessed translucent stadium track groove (soft recessed fill, zero harsh border)
        trackBgView.wantsLayer = true
        trackBgView.layer?.cornerRadius = SafariMetrics.tabPillCornerRadius
        trackBgView.layer?.cornerCurve = .continuous
        trackBgView.layer?.masksToBounds = true
        trackBgView.layer?.borderWidth = 0.0
        if #available(macOS 26.0, *) {
            let tgv = NSGlassEffectView()
            tgv.style = .regular
            tgv.cornerRadius = SafariMetrics.tabPillCornerRadius
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                tgv.effectIsInteractive = false
            }
            #endif
            tgv.translatesAutoresizingMaskIntoConstraints = false
            tgv.isHidden = !BrowserSettings.shared.refractiveGlassToolbar
            trackBgView.addSubview(tgv)
            NSLayoutConstraint.activate([
                tgv.leadingAnchor.constraint(equalTo: trackBgView.leadingAnchor),
                tgv.trailingAnchor.constraint(equalTo: trackBgView.trailingAnchor),
                tgv.topAnchor.constraint(equalTo: trackBgView.topAnchor),
                tgv.bottomAnchor.constraint(equalTo: trackBgView.bottomAnchor)
            ])
            self.trackGlassView = tgv
        }
        trackHostView.addSubview(trackBgView)

        // Recessed 31pt active pill (`2.5 pt` inset, `15.5 pt` corner radius) positioned via manual frame (Safarium 1:1)
        setupActivePill()
        trackHostView.addSubview(activePillSurfaceView)

        // Unclipped focus ring overlay sitting above active pill (exact SafariumFocusRingOverlayView)
        focusRingOverlay.frame = trackHostView.bounds
        focusRingOverlay.autoresizingMask = [.width, .height]
        focusRingOverlay.layer?.zPosition = 50
        trackHostView.addSubview(focusRingOverlay, positioned: .above, relativeTo: activePillSurfaceView)
    }

    private func setupActivePill() {
        activePillSurfaceView.wantsLayer = true
        activePillSurfaceView.layer?.cornerRadius = SafariMetrics.tabInnerCornerRadius
        activePillSurfaceView.layer?.cornerCurve = .continuous
        activePillSurfaceView.layer?.masksToBounds = false
        activePillSurfaceView.layer?.backgroundColor = NSColor.clear.cgColor
        activePillSurfaceView.layer?.zPosition = 10
        if #available(macOS 26.0, *) {
            activePillSurfaceView.layer?.preferredDynamicRange = .constrainedHigh
        }

        // Native macOS 27 Liquid Glass surface (smooth native glass edge, zero painted fake border)
        activePillGlassHost.translatesAutoresizingMaskIntoConstraints = false
        activePillGlassHost.wantsLayer = true
        activePillGlassHost.layer?.masksToBounds = false
        activePillSurfaceView.addSubview(activePillGlassHost)
        NSLayoutConstraint.activate([
            activePillGlassHost.leadingAnchor.constraint(equalTo: activePillSurfaceView.leadingAnchor),
            activePillGlassHost.trailingAnchor.constraint(equalTo: activePillSurfaceView.trailingAnchor),
            activePillGlassHost.topAnchor.constraint(equalTo: activePillSurfaceView.topAnchor),
            activePillGlassHost.bottomAnchor.constraint(equalTo: activePillSurfaceView.bottomAnchor)
        ])

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .regular
            gv.cornerRadius = SafariMetrics.tabInnerCornerRadius
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                gv.effectIsInteractive = false
            }
            #endif
            gv.translatesAutoresizingMaskIntoConstraints = false
            activePillGlassHost.addSubview(gv)
            NSLayoutConstraint.activate([
                gv.leadingAnchor.constraint(equalTo: activePillGlassHost.leadingAnchor),
                gv.trailingAnchor.constraint(equalTo: activePillGlassHost.trailingAnchor),
                gv.topAnchor.constraint(equalTo: activePillGlassHost.topAnchor),
                gv.bottomAnchor.constraint(equalTo: activePillGlassHost.bottomAnchor)
            ])
            self.activePillGlassView = gv
        }

        // Instant interior hover tint overlay (zero transition animation)
        activePillHoverTintView.translatesAutoresizingMaskIntoConstraints = false
        activePillHoverTintView.wantsLayer = true
        activePillHoverTintView.layer?.cornerRadius = SafariMetrics.tabInnerCornerRadius
        activePillHoverTintView.layer?.cornerCurve = .continuous
        activePillHoverTintView.layer?.masksToBounds = true
        activePillHoverTintView.alphaValue = 0.0
        activePillSurfaceView.addSubview(activePillHoverTintView)
        NSLayoutConstraint.activate([
            activePillHoverTintView.leadingAnchor.constraint(equalTo: activePillSurfaceView.leadingAnchor, constant: 1.0),
            activePillHoverTintView.trailingAnchor.constraint(equalTo: activePillSurfaceView.trailingAnchor, constant: -1.0),
            activePillHoverTintView.topAnchor.constraint(equalTo: activePillSurfaceView.topAnchor, constant: 1.0),
            activePillHoverTintView.bottomAnchor.constraint(equalTo: activePillSurfaceView.bottomAnchor, constant: -1.0)
        ])

        // Handle active pill click (focus) vs tab drag (never moves window!)
        activePillSurfaceView.onMouseDown = { [weak self] event in
            self?.handleActivePillMouseDown(event)
        }
        activePillSurfaceView.interactiveControlsProvider = { [weak self] in
            guard let self else { return [] }
            var controls: [NSView] = [self.activeCloseButton, self.hoverReloadButton, self.pageMenuButton]
            if self.isEditingAddress {
                controls.append(self.addressTextField)
            }
            return controls
        }

        hdrHighlightView.translatesAutoresizingMaskIntoConstraints = false
        hdrHighlightView.cornerRadius = SafariMetrics.tabInnerCornerRadius
        activePillSurfaceView.addSubview(hdrHighlightView)
        NSLayoutConstraint.activate([
            hdrHighlightView.leadingAnchor.constraint(equalTo: activePillSurfaceView.leadingAnchor),
            hdrHighlightView.trailingAnchor.constraint(equalTo: activePillSurfaceView.trailingAnchor),
            hdrHighlightView.topAnchor.constraint(equalTo: activePillSurfaceView.topAnchor),
            hdrHighlightView.bottomAnchor.constraint(equalTo: activePillSurfaceView.bottomAnchor)
        ])

        // Clean `12.5 pt` dark-circle `xmark` close button on LEFT (exact Safarium compact close glyph)
        activeCloseButton.translatesAutoresizingMaskIntoConstraints = false
        activeCloseButton.onClick = { [weak self] in
            self?.activeCloseClicked()
        }
        activeCloseButton.isHidden = true
        activePillSurfaceView.addSubview(activeCloseButton)

        // Centered favicon + domain stack
        centeredTitleStack.orientation = .horizontal
        centeredTitleStack.alignment = .centerY
        centeredTitleStack.spacing = 6.0
        centeredTitleStack.translatesAutoresizingMaskIntoConstraints = false
        centeredTitleStack.wantsLayer = true

        centeredFaviconBadge.translatesAutoresizingMaskIntoConstraints = false
        centeredFaviconBadge.wantsLayer = true
        centeredFaviconBadge.layer?.cornerRadius = 3.0
        centeredFaviconBadge.layer?.masksToBounds = false
        NSLayoutConstraint.activate([
            centeredFaviconBadge.widthAnchor.constraint(equalToConstant: SafariMetrics.fieldIconSize),
            centeredFaviconBadge.heightAnchor.constraint(equalToConstant: SafariMetrics.fieldIconSize)
        ])

        centeredFaviconView.translatesAutoresizingMaskIntoConstraints = false
        centeredFaviconView.imageScaling = .scaleProportionallyDown
        centeredFaviconBadge.addSubview(centeredFaviconView)
        NSLayoutConstraint.activate([
            centeredFaviconView.centerXAnchor.constraint(equalTo: centeredFaviconBadge.centerXAnchor),
            centeredFaviconView.centerYAnchor.constraint(equalTo: centeredFaviconBadge.centerYAnchor),
            centeredFaviconView.widthAnchor.constraint(equalToConstant: SafariMetrics.fieldIconSize),
            centeredFaviconView.heightAnchor.constraint(equalToConstant: SafariMetrics.fieldIconSize)
        ])

        activeDisplayLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        activeDisplayLabel.lineBreakMode = .byTruncatingMiddle
        activeDisplayLabel.maximumNumberOfLines = 1
        activeDisplayLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        centeredTitleStack.addArrangedSubview(centeredFaviconBadge)
        centeredTitleStack.addArrangedSubview(activeDisplayLabel)
        activePillSurfaceView.addSubview(centeredTitleStack)

        // Left-aligned icon + editable URL field shown while editing
        editingIconView.translatesAutoresizingMaskIntoConstraints = false
        editingIconView.wantsLayer = true
        editingIconView.imageScaling = .scaleProportionallyDown
        editingIconView.image = AssetLoader.shared.symbol(named: "magnifyingglass", pointSize: 13.0, weight: .medium)
        editingIconView.isHidden = true
        activePillSurfaceView.addSubview(editingIconView)

        addressTextField.translatesAutoresizingMaskIntoConstraints = false
        addressTextField.wantsLayer = true
        addressTextField.isBordered = false
        addressTextField.drawsBackground = false
        addressTextField.focusRingType = .none
        addressTextField.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        addressTextField.placeholderString = "Search or enter website name"
        addressTextField.cell?.usesSingleLineMode = true
        addressTextField.cell?.wraps = false
        addressTextField.cell?.isScrollable = true
        addressTextField.delegate = self
        addressTextField.isHidden = true
        activePillSurfaceView.addSubview(addressTextField)

        // Right controls: hover Reload + Page Menu (or Stop X while loading)
        hoverReloadButton.translatesAutoresizingMaskIntoConstraints = false
        hoverReloadButton.isBordered = false
        hoverReloadButton.imagePosition = .imageOnly
        hoverReloadButton.image = AssetLoader.shared.symbol(named: "arrow.clockwise", pointSize: 13.5, weight: .regular)
        hoverReloadButton.toolTip = "Reload This Page (⌘R)"
        hoverReloadButton.target = self
        hoverReloadButton.action = #selector(reloadClicked)
        hoverReloadButton.isHidden = true
        activePillSurfaceView.addSubview(hoverReloadButton)

        pageMenuButton.translatesAutoresizingMaskIntoConstraints = false
        pageMenuButton.isBordered = false
        pageMenuButton.imagePosition = .imageOnly
        pageMenuButton.image = Self.makePageMenuIcon()
        pageMenuButton.toolTip = "Page Menu"
        pageMenuButton.target = self
        pageMenuButton.action = #selector(pageMenuClicked)
        activePillSurfaceView.addSubview(pageMenuButton)

        progressBarHostView.translatesAutoresizingMaskIntoConstraints = false
        progressBarHostView.wantsLayer = true
        progressBarHostView.layer?.cornerRadius = SafariMetrics.tabInnerCornerRadius
        progressBarHostView.layer?.cornerCurve = .continuous
        progressBarHostView.layer?.masksToBounds = true
        progressBarHostView.layer?.zPosition = 30
        progressBarHostView.isHidden = true
        progressBarHostView.alphaValue = 0.0
        activePillSurfaceView.addSubview(progressBarHostView)

        progressBarLayer.anchorPoint = CGPoint(x: 0, y: 0)
        progressBarLayer.cornerRadius = 1.25
        progressBarHostView.layer?.addSublayer(progressBarLayer)

        let centerX = centeredTitleStack.centerXAnchor.constraint(equalTo: activePillSurfaceView.centerXAnchor)
        centerX.priority = .init(740)

        let titleLeading = centeredTitleStack.leadingAnchor.constraint(greaterThanOrEqualTo: activePillSurfaceView.leadingAnchor, constant: 10)
        let titleTrailing = centeredTitleStack.trailingAnchor.constraint(lessThanOrEqualTo: activePillSurfaceView.trailingAnchor, constant: -30)
        self.centeredTitleLeadingConstraint = titleLeading
        self.centeredTitleTrailingConstraint = titleTrailing

        let addrLeading = addressTextField.leadingAnchor.constraint(equalTo: activePillSurfaceView.leadingAnchor, constant: 13)
        self.addressTextFieldLeadingConstraint = addrLeading
        let addrTrailing = addressTextField.trailingAnchor.constraint(equalTo: activePillSurfaceView.trailingAnchor, constant: -14)
        self.addressTextFieldTrailingConstraint = addrTrailing

        NSLayoutConstraint.activate([
            activeCloseButton.leadingAnchor.constraint(equalTo: activePillSurfaceView.leadingAnchor, constant: 8),
            activeCloseButton.centerYAnchor.constraint(equalTo: activePillSurfaceView.centerYAnchor),
            activeCloseButton.widthAnchor.constraint(equalToConstant: 15),
            activeCloseButton.heightAnchor.constraint(equalToConstant: 15),

            centerX,
            centeredTitleStack.centerYAnchor.constraint(equalTo: activePillSurfaceView.centerYAnchor),
            titleLeading,
            titleTrailing,

            editingIconView.leadingAnchor.constraint(equalTo: activePillSurfaceView.leadingAnchor, constant: 10.5),
            editingIconView.centerYAnchor.constraint(equalTo: activePillSurfaceView.centerYAnchor),
            editingIconView.widthAnchor.constraint(equalToConstant: 16),
            editingIconView.heightAnchor.constraint(equalToConstant: 16),

            addrLeading,
            addrTrailing,
            addressTextField.centerYAnchor.constraint(equalTo: activePillSurfaceView.centerYAnchor),

            hoverReloadButton.trailingAnchor.constraint(equalTo: pageMenuButton.leadingAnchor, constant: -8),
            hoverReloadButton.centerYAnchor.constraint(equalTo: activePillSurfaceView.centerYAnchor),
            hoverReloadButton.widthAnchor.constraint(equalToConstant: 18),
            hoverReloadButton.heightAnchor.constraint(equalToConstant: 18),

            pageMenuButton.trailingAnchor.constraint(equalTo: activePillSurfaceView.trailingAnchor, constant: -11),
            pageMenuButton.centerYAnchor.constraint(equalTo: activePillSurfaceView.centerYAnchor),
            pageMenuButton.widthAnchor.constraint(equalToConstant: 18),
            pageMenuButton.heightAnchor.constraint(equalToConstant: 18),

            progressBarHostView.leadingAnchor.constraint(equalTo: activePillSurfaceView.leadingAnchor),
            progressBarHostView.trailingAnchor.constraint(equalTo: activePillSurfaceView.trailingAnchor),
            progressBarHostView.topAnchor.constraint(equalTo: activePillSurfaceView.topAnchor),
            progressBarHostView.bottomAnchor.constraint(equalTo: activePillSurfaceView.bottomAnchor)
        ])
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

    // MARK: - Active & Inactive Tab Click, In-Track Reorder & Cross-Window Tear-Off (1:1 Safari macOS 27)

    private func handleActivePillMouseDown(_ event: NSEvent) {
        let pt = activePillSurfaceView.convert(event.locationInWindow, from: nil)
        if !activeCloseButton.isHidden && activeCloseButton.frame.insetBy(dx: -4, dy: -4).contains(pt) { return }
        if !pageMenuButton.isHidden && pageMenuButton.frame.insetBy(dx: -3, dy: -3).contains(pt) { return }
        if !hoverReloadButton.isHidden && hoverReloadButton.frame.insetBy(dx: -3, dy: -3).contains(pt) { return }

        if isEditingAddress {
            return
        }

        guard let win = window else {
            focusAddressBar()
            return
        }

        let start = event.locationInWindow
        win.isMovable = false
        while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                focusAddressBar()
                return
            }
            let dx = next.locationInWindow.x - start.x
            let dy = next.locationInWindow.y - start.y
            if hypot(dx, dy) > 5.0 {
                if !singleAddressOnlyMode && items.count >= 2 {
                    runUnifiedTabDragLoop(
                        tabID: activeTabID,
                        isActive: true,
                        initialEvent: event,
                        triggerEvent: next,
                        draggedView: activePillSurfaceView
                    )
                    return
                }
                if items.count == 1 && canTearOffSingleTab?() == true {
                    triggerTearOff(tabID: activeTabID, draggedView: activePillSurfaceView)
                    return
                }
                // Single tab in sole window: consume drag without hijacking window move!
                while let drain = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    if drain.type == .leftMouseUp { break }
                }
                return
            }
        }
    }

    private func handleInactiveTabMouseDown(view: CompactInactiveTabView, tabID: String, event: NSEvent) {
        guard let win = window else {
            endAddressEditing()
            onSelectTab?(tabID)
            return
        }

        let start = event.locationInWindow
        win.isMovable = false
        while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                let pt = view.convert(next.locationInWindow, from: nil)
                if view.bounds.contains(pt) {
                    endAddressEditing()
                    onSelectTab?(tabID)
                }
                return
            }
            let dx = next.locationInWindow.x - start.x
            let dy = next.locationInWindow.y - start.y
            if hypot(dx, dy) > 5.0 {
                guard items.count >= 2 else { return }
                runUnifiedTabDragLoop(
                    tabID: tabID,
                    isActive: false,
                    initialEvent: event,
                    triggerEvent: next,
                    draggedView: view
                )
                return
            }
        }
    }

    private func runUnifiedTabDragLoop(
        tabID: String,
        isActive: Bool,
        initialEvent: NSEvent,
        triggerEvent: NSEvent,
        draggedView: NSView
    ) {
        guard let win = window, items.count >= 2 else { return }
        win.isMovable = false
        compactDraggingTabId = tabID
        compactDragStartX = initialEvent.locationInWindow.x
        compactDragStartOriginX = draggedView.frame.origin.x
        let initialOrder = items.map(\.id)

        let inactiveView = draggedView as? CompactInactiveTabView
        if !isActive {
            if isEditingAddress {
                pendingAnimatedFocusRing = true
                let ringFrame = lastActiveTargetFrame.width > 10 ? lastActiveTargetFrame : activePillSurfaceView.frame
                let geom = focusRingGeometry(forPillFrame: ringFrame)
                focusRingOverlay.setFocusRing(frame: geom.rect, lineWidth: geom.lineWidth, visible: false, animated: false)
            }
            inactiveView?.isDraggingElevated = true
            draggedView.layer?.zPosition = 25
            trackHostView.addSubview(draggedView, positioned: .above, relativeTo: activePillSurfaceView)
        } else {
            draggedView.layer?.zPosition = 25
        }

        let minXBound: CGFloat = isActive ? 2.5 : 0.0
        let maxXBound: CGFloat = max(minXBound, trackHostView.bounds.width - draggedView.frame.width - (isActive ? 2.5 : 0.0))

        // Vertical tear-off hysteresis band around the 36pt track (exact Safari macOS 27 feel)
        let tearOffTopY: CGFloat = -16.0
        let tearOffBottomY: CGFloat = SafariMetrics.tabPillHeight + 16.0
        let tearOffHorizPad: CGFloat = 26.0

        var toreOff = false

        func processDragEvent(_ ev: NSEvent) -> Bool {
            let ptInTrack = trackHostView.convert(ev.locationInWindow, from: nil)
            let outsideVertically = (ptInTrack.y < tearOffTopY || ptInTrack.y > tearOffBottomY)
            let outsideHorizontally = (ptInTrack.x < -tearOffHorizPad || ptInTrack.x > trackHostView.bounds.width + tearOffHorizPad)

            if outsideVertically || outsideHorizontally {
                toreOff = true
                return false
            }

            let dx = ev.locationInWindow.x - compactDragStartX
            let targetX = max(minXBound, min(maxXBound, compactDragStartOriginX + dx))
            draggedView.layer?.removeAllAnimations()
            draggedView.frame.origin.x = targetX
            checkCompactDragSwap(draggedId: tabID, draggedFrame: draggedView.frame)
            return true
        }

        if processDragEvent(triggerEvent) {
            while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                if !processDragEvent(next) { break }
            }
        }

        let finalOrder = items.map(\.id)

        if toreOff {
            let pillRectInScreen = pillScreenRect(for: draggedView, isActive: isActive)
            inactiveView?.isDraggingElevated = false
            draggedView.layer?.zPosition = isActive ? 10 : 0
            if let inactiveView {
                trackHostView.addSubview(inactiveView, positioned: .below, relativeTo: activePillSurfaceView)
            }
            compactDraggingTabId = nil
            if finalOrder != initialOrder {
                onReorderTabs?(finalOrder)
            }
            triggerTearOff(tabID: tabID, explicitPillRectInScreen: pillRectInScreen)
            return
        }

        inactiveView?.isDraggingElevated = false
        draggedView.layer?.zPosition = isActive ? 10 : 0
        if let inactiveView {
            trackHostView.addSubview(inactiveView, positioned: .below, relativeTo: activePillSurfaceView)
        }
        compactDraggingTabId = nil
        layoutSlots(animated: true)
        if finalOrder != initialOrder {
            onReorderTabs?(finalOrder)
        }
    }

    private func pillScreenRect(for view: NSView, isActive: Bool) -> NSRect {
        guard let win = window else { return .zero }
        let localRect = isActive
            ? view.bounds
            : NSRect(
                x: 2.5,
                y: 2.5,
                width: max(40.0, view.bounds.width - 5.0),
                height: SafariMetrics.tabInnerHeight
            )
        let winRect = view.convert(localRect, to: nil)
        return win.convertToScreen(winRect)
    }

    private func triggerTearOff(
        tabID: String,
        draggedView: NSView? = nil,
        explicitPillRectInScreen: NSRect? = nil
    ) {
        let pillRect: NSRect
        if let explicitPillRectInScreen {
            pillRect = explicitPillRectInScreen
        } else if let draggedView {
            pillRect = pillScreenRect(for: draggedView, isActive: (tabID == activeTabID))
        } else {
            pillRect = screenRectForTab(id: tabID) ?? .zero
        }
        let mouseScreen = NSEvent.mouseLocation
        let cursorOffset = NSPoint(
            x: max(12.0, min(pillRect.width - 12.0, mouseScreen.x - pillRect.minX)),
            y: max(6.0, min(pillRect.height - 6.0, mouseScreen.y - pillRect.minY))
        )
        onBeginTabTearOff?(tabID, pillRect, cursorOffset, mouseScreen)
    }

    private func checkCompactDragSwap(draggedId: String, draggedFrame: NSRect) {
        guard let fromIdx = items.firstIndex(where: { $0.id == draggedId }) else { return }
        let draggedPinned = items[fromIdx].isPinned
        let viewForTab: (String) -> NSView? = { [weak self] id in
            guard let self else { return nil }
            if id == self.activeTabID { return self.activePillSurfaceView }
            return self.inactiveTabViews.first(where: { $0.tabID == id })
        }

        // Compare leading edge (moving left) / trailing edge (moving right) against each neighbour's midpoint.
        // Unlike comparing midX-to-midX, this works reliably when the active pill is much wider than inactive slots
        // and is mathematically oscillation-free because the neighbour shifts by `draggedFrame.width` on swap.
        var targetIdx: Int? = nil
        if fromIdx > 0 {
            for idx in stride(from: fromIdx - 1, through: 0, by: -1) {
                let other = items[idx]
                guard other.isPinned == draggedPinned, let otherView = viewForTab(other.id) else { continue }
                if draggedFrame.minX < otherView.frame.midX - 2.0 {
                    targetIdx = idx
                } else {
                    break
                }
            }
        }
        if targetIdx == nil && fromIdx + 1 < items.count {
            for idx in (fromIdx + 1)..<items.count {
                let other = items[idx]
                guard other.isPinned == draggedPinned, let otherView = viewForTab(other.id) else { continue }
                if draggedFrame.maxX > otherView.frame.midX + 2.0 {
                    targetIdx = idx
                } else {
                    break
                }
            }
        }

        guard let newIdx = targetIdx, newIdx != fromIdx else { return }
        let moved = items.remove(at: fromIdx)
        items.insert(moved, at: newIdx)
        let byId = Dictionary(uniqueKeysWithValues: inactiveTabViews.map { ($0.tabID, $0) })
        inactiveTabViews = items.filter { $0.id != activeTabID }.compactMap { byId[$0.id] }
        layoutSlots(animated: true)
    }

    // MARK: - Cross-Window Drag & Drop Slot Management

    func setTearOffHiddenTab(id: String?, animated: Bool = true) {
        guard hiddenDraggedTabID != id else { return }
        hiddenDraggedTabID = id
        rebuildAndLayout(forceAnimated: animated)
    }

    func updateExternalDropPlaceholder(tabID: String, insertionIndex: Int) {
        let clamped = max(0, min(displayedItems.count, insertionIndex))
        if let existing = externalDropPlaceholder, existing.tabID == tabID && existing.index == clamped {
            return
        }
        externalDropPlaceholder = (tabID, clamped)
        rebuildAndLayout(forceAnimated: true)
    }

    func clearExternalTabDropPlaceholder(animated: Bool = true) {
        guard externalDropPlaceholder != nil else { return }
        externalDropPlaceholder = nil
        lastExternalPlaceholderSlotRectInTrack = .zero
        rebuildAndLayout(forceAnimated: animated)
    }

    func resolvedDropSlotRectInScreen() -> NSRect? {
        guard let win = window, lastExternalPlaceholderSlotRectInTrack.width > 10 else { return nil }
        let rectInWin = trackHostView.convert(lastExternalPlaceholderSlotRectInTrack, to: nil)
        return win.convertToScreen(rectInWin)
    }

    func screenRectForTab(id: String) -> NSRect? {
        if id == activeTabID && !activePillSurfaceView.isHidden {
            return pillScreenRect(for: activePillSurfaceView, isActive: true)
        }
        if let inactive = inactiveTabViews.first(where: { $0.tabID == id }) {
            return pillScreenRect(for: inactive, isActive: false)
        }
        if let dropRect = resolvedDropSlotRectInScreen() {
            return dropRect
        }
        return pillScreenRect(for: activePillSurfaceView, isActive: true)
    }

    func dropHitTest(
        atScreenPoint screenPt: NSPoint,
        extraVerticalHysteresis: CGFloat = 0.0
    ) -> (insertionIndex: Int, slotRectInScreen: NSRect)? {
        guard let win = window else { return nil }
        let ptInWin = win.convertPoint(fromScreen: screenPt)
        let ptInSelf = convert(ptInWin, from: nil)

        // Generous magnetic drop zone spanning the toolbar tab track area (exact Safari macOS 27 ergonomics)
        let hitRect = NSRect(
            x: bounds.minX - 24.0,
            y: bounds.minY - (28.0 + extraVerticalHysteresis),
            width: bounds.width + 48.0,
            height: bounds.height + 52.0 + extraVerticalHysteresis * 2.0
        )
        guard hitRect.contains(ptInSelf) else { return nil }

        let visible = displayedItems
        let totalSlots = visible.count + 1
        let expandedW = computeFillWidth(forSlotCount: totalSlots)
        let expandedCenterOffset = computeTrackCenterOffset(slotCount: totalSlots, trackWidth: expandedW)
        let expandedMinX = (bounds.width - expandedW) * 0.5 + expandedCenterOffset
        let relX = ptInSelf.x - expandedMinX

        // Insertion index = the hypothetical (N + 1)-slot layout whose placeholder centre is nearest the cursor.
        // Using the real per-slot widths (pinned slots are narrow) keeps drop slots identical to the drawn slots.
        var insertionIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for k in 0...visible.count {
            let g = computeHypotheticalPlaceholderGeometry(totalSlots: totalSlots, trackWidth: expandedW, insertionIndex: k, visibleItems: visible)
            let d = abs(relX - (g.x + g.width * 0.5))
            if d < bestDistance - 0.001 { bestDistance = d; insertionIndex = k }
        }

        // Compute exact target 31pt pill rect in screen coordinates for that insertion index
        let slotLocalInTrack: NSRect
        if let currentPH = externalDropPlaceholder, currentPH.index == insertionIndex, lastExternalPlaceholderSlotRectInTrack.width > 10 {
            slotLocalInTrack = lastExternalPlaceholderSlotRectInTrack
            let rectInWin = trackHostView.convert(slotLocalInTrack, to: nil)
            return (insertionIndex, win.convertToScreen(rectInWin))
        } else {
            let (slotX, slotW) = computeHypotheticalPlaceholderGeometry(
                totalSlots: totalSlots,
                trackWidth: expandedW,
                insertionIndex: insertionIndex,
                visibleItems: visible
            )
            let rectInSelf = NSRect(
                x: expandedMinX + slotX + 2.5,
                y: 2.5,
                width: max(40.0, slotW - 5.0),
                height: SafariMetrics.tabInnerHeight
            )
            let rectInWin = convert(rectInSelf, to: nil)
            return (insertionIndex, win.convertToScreen(rectInWin))
        }
    }

    /// Width model shared by `layoutSlots`, drop hit-testing and the drop placeholder, so drawn slots and drop slots
    /// can never disagree (pinned tabs are narrow fixed-size slots that shrink only when the track is crowded).
    static func slotMetrics(trackWidth w: CGFloat, totalSlots: Int, inactivePinnedCount: Int, hasVisibleActive: Bool)
        -> (pinnedW: CGFloat, activeW: CGFloat, eachOtherW: CGFloat) {
        let pinnedW: CGFloat = inactivePinnedCount > 0
            ? min(36.0, max(12.0, floor((w - 120.0) / CGFloat(inactivePinnedCount))))
            : 36.0
        let remainingW = max(120.0, w - CGFloat(inactivePinnedCount) * pinnedW)
        let regularSlots = max(0, totalSlots - inactivePinnedCount)
        let regularInactiveCount = max(0, regularSlots - (hasVisibleActive ? 1 : 0))
        let activeW: CGFloat
        let eachOtherW: CGFloat
        if !hasVisibleActive {
            activeW = 0
            eachOtherW = regularInactiveCount > 0 ? floor(remainingW / CGFloat(regularInactiveCount)) : 0
        } else if regularInactiveCount == 0 {
            activeW = remainingW
            eachOtherW = 0
        } else {
            let equal = floor(remainingW / CGFloat(regularSlots))
            let maxActive = max(248, remainingW - CGFloat(regularInactiveCount) * 44)
            // The 248 pt floor must never push the other tabs out of a narrow track (they keep at least 44 pt each),
            // otherwise the active pill spills into the neighbouring toolbar capsules.
            let roomForActive = max(80.0, remainingW - CGFloat(regularInactiveCount) * 44)
            activeW = min(roomForActive, min(maxActive, max(equal, 248)))
            eachOtherW = floor((remainingW - activeW) / CGFloat(regularInactiveCount))
        }
        return (pinnedW, activeW, eachOtherW)
    }

    func computeHypotheticalPlaceholderGeometry(
        totalSlots: Int,
        trackWidth w: CGFloat,
        insertionIndex: Int,
        visibleItems: [TabPresentationItem]
    ) -> (x: CGFloat, width: CGFloat) {
        let hasActiveInVisible = visibleItems.contains(where: { $0.isActive })
        let inactivePinned = visibleItems.filter { $0.isPinned && !$0.isActive }.count
        var m = Self.slotMetrics(trackWidth: w, totalSlots: totalSlots, inactivePinnedCount: inactivePinned, hasVisibleActive: hasActiveInVisible)
        if inactivePinned == 0, !hasActiveInVisible || totalSlots <= 1 {
            // No active pill and no pinned tabs: the hypothetical track is split into exact equal slots.
            let equalW = w / CGFloat(max(1, totalSlots))
            m = (m.pinnedW, equalW, equalW)
        }
        // The placeholder is a regular inactive slot of width `eachOtherW`; every real tab keeps its own slot width.
        var curX: CGFloat = 0.0
        for slotIdx in 0..<totalSlots {
            if slotIdx == insertionIndex { return (curX, m.eachOtherW) }
            let itemIdx = slotIdx < insertionIndex ? slotIdx : slotIdx - 1
            if itemIdx < visibleItems.count {
                let it = visibleItems[itemIdx]
                curX += it.isActive ? m.activeW : (it.isPinned ? m.pinnedW : m.eachOtherW)
            } else {
                curX += m.eachOtherW
            }
        }
        return (curX, m.eachOtherW)
    }

    // MARK: - Tracking Areas & Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let activePillTrackingArea { removeTrackingArea(activePillTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        activePillTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHoverState(event: event) }
    override func mouseMoved(with event: NSEvent) { updateHoverState(event: event) }

    override func mouseExited(with event: NSEvent) {
        if isActivePillHovered {
            isActivePillHovered = false
            updateActiveHoverControls()
        }
    }

    private func updateHoverState(event: NSEvent) {
        let ptInHost = trackHostView.convert(event.locationInWindow, from: nil)
        let inActive = activePillSurfaceView.frame.contains(ptInHost)
        if inActive != isActivePillHovered {
            isActivePillHovered = inActive
            updateActiveHoverControls()
        }
    }

    private func updateActiveHoverControls() {
        let isMultiTab = items.count > 1
        let showHoverVisuals = isActivePillHovered && !isEditingAddress
        let activeIsPinned = items.first(where: { $0.isActive })?.isPinned ?? false
        let showCloseButton = isActivePillHovered && isMultiTab && !activeIsPinned && !singleAddressOnlyMode && !isTabOverviewActive
        activeCloseButton.isHidden = !showCloseButton
        editingIconView.isHidden = !isEditingAddress || showCloseButton
        // NEVER show Reload or Page Menu on a Start Page, History Page, or Tab Overview; keep Page Menu visible on webpages.
        let hidePageControls = activeIsStartPage || isTabOverviewActive
        let showStopUI = activeIsLoading && isShowingLoadingUI
        hoverReloadButton.isHidden = !(isActivePillHovered && !showStopUI && !hidePageControls)
        pageMenuButton.isHidden = (hidePageControls && !showStopUI) || isTabOverviewActive
        if !hidePageControls {
            // Reserve generous 17pt breathing room before the refresh icon (`w - 55`) so URL text never crowds or jumps on hover
            addressTextFieldTrailingConstraint?.constant = -72
        } else if !pageMenuButton.isHidden {
            addressTextFieldTrailingConstraint?.constant = -46
        } else {
            addressTextFieldTrailingConstraint?.constant = -14
        }
        pageMenuButton.image = showStopUI
            ? AssetLoader.shared.symbol(named: "xmark", pointSize: 13.0, weight: .regular)
            : Self.makePageMenuIcon()
        pageMenuButton.toolTip = showStopUI ? "Stop Loading" : "Page Menu"

        // Instant hover tint (no transition) matching reference (`F027 -> F028`, `F058 -> F059`)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activePillHoverTintView.alphaValue = showHoverVisuals ? 1.0 : 0.0
        CATransaction.commit()

        // Dynamically reserve generous trailing/leading space so domain text NEVER crowds refresh or page menu icons!
        centeredTitleLeadingConstraint?.constant = activeCloseButton.isHidden ? 10 : 28
        if !hoverReloadButton.isHidden {
            centeredTitleTrailingConstraint?.constant = -72
        } else if !pageMenuButton.isHidden {
            centeredTitleTrailingConstraint?.constant = -46
        } else {
            centeredTitleTrailingConstraint?.constant = -12
        }
    }

    // MARK: - Layout & Focus Ring Positioning

    /// Auto Layout resizes this view (sidebar open/close, window zoom) without invalidating its own layout, so the
    /// manually positioned track slots would keep the old width and could overflow into the neighbouring capsules.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { needsLayout = true }
    }

    override func layout() {
        super.layout()
        // While a 0.28s tab-bar track/slot animation is running, keep the track groove synced
        // to trackHostView's live animated bounds WITHOUT snapping constraints or killing slot animators!
        if activeLayoutAnimationCount > 0 {
            let liveBounds = trackHostView.bounds
            if liveBounds.width > 10 {
                trackBgView.frame = liveBounds
                focusRingOverlay.frame = liveBounds
            }
            syncProgressBarWidthIfNeeded()
            notifyActivePillRectIfNeeded()
            return
        }
        let targetW = computeFillWidth()
        // The bar's own width can change outside a live resize (sidebar open/close, zoom, full screen). The track
        // constraint is now below the window-size priority and no longer drags the window along, so it must follow
        // the available width here or the manually laid-out slots would overflow into the right-hand capsule.
        let availableWidthChanged = abs(bounds.width - lastLayoutBoundsWidth) > 0.5
        lastLayoutBoundsWidth = bounds.width
        if abs((trackWidthConstraint?.constant ?? 0) - targetW) > 0.5 && (!(window?.inLiveResize == false && hasLaidOutOnce) || availableWidthChanged) {
            trackWidthConstraint?.constant = targetW
        } else if window?.inLiveResize == true || !hasLaidOutOnce {
            trackWidthConstraint?.constant = targetW
        }
        let slotCount = displayedItems.count + (externalDropPlaceholder != nil ? 1 : 0)
        trackCenterXConstraint?.constant = computeTrackCenterOffset(slotCount: slotCount, trackWidth: targetW)
        trackHostView.layoutSubtreeIfNeeded()
        layoutSlots(animated: false)
        syncProgressBarWidthIfNeeded()
        notifyActivePillRectIfNeeded()
    }

    private func notifyActivePillRectIfNeeded() {
        guard activePillSurfaceView.window != nil else { return }
        let rect = activePillSurfaceView.convert(activePillSurfaceView.bounds, to: nil)
        if abs(rect.midX - lastReportedPillRectInWindow.midX) > 0.5 || abs(rect.width - lastReportedPillRectInWindow.width) > 0.5 {
            lastReportedPillRectInWindow = rect
            onActivePillLayoutChanged?()
        }
    }

    private func updateEditingIcon(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isURLContext = !trimmed.isEmpty && (
            trimmed.hasPrefix("http://") ||
            trimmed.hasPrefix("https://") ||
            trimmed.hasPrefix("chrome-extension://") ||
            (!activeURLString.isEmpty && trimmed == activeURLString)
        )
        let showCloseButton = isActivePillHovered && items.count > 1
        if isURLContext {
            if let fav = activeFavicon {
                editingIconView.image = fav
                editingIconView.contentTintColor = nil
            } else {
                editingIconView.image = AssetLoader.shared.symbol(named: "globe", pointSize: 15.0, weight: .regular)
                editingIconView.contentTintColor = placeholderSecondaryInk()
            }
            editingIconView.isHidden = !isEditingAddress || showCloseButton
            addressTextFieldLeadingConstraint?.constant = 32.0
        } else {
            editingIconView.image = AssetLoader.shared.symbol(named: "magnifyingglass", pointSize: 13.5, weight: .medium)
            editingIconView.contentTintColor = placeholderSecondaryInk()
            editingIconView.isHidden = !isEditingAddress || showCloseButton
            addressTextFieldLeadingConstraint?.constant = 32.0
        }
    }

    func editableURLString(for url: URL?) -> String {
        guard let url, url.scheme != "safarium" else { return "" }
        var raw = url.absoluteString
        if url.path == "/" && url.query == nil && url.fragment == nil && raw.hasSuffix("/") {
            raw.removeLast()
        }
        return raw
    }

    func focusRingGeometry(forPillFrame f: NSRect) -> (rect: NSRect, lineWidth: CGFloat) {
        let isSingleSlot = (displayedItems.count <= 1 && externalDropPlaceholder == nil)
        if isSingleSlot && trackBgView.bounds.width > 10 {
            // Single-tab Safari 27: 3.4pt stroke centered at 1.7pt spans 0.0..3.4pt — replaces outer gray groove cleanly with zero double-border gap
            return (trackBgView.bounds.insetBy(dx: 1.7, dy: 1.7), 3.4)
        }
        return (f.insetBy(dx: -0.75, dy: -0.75), 3.1)
    }

    /// Holds the active tab's blue focus ring hidden while an external toolbar/sidebar animation runs.
    func beginExternalAnimation() {
        beginFocusRingDeferral()
    }

    /// Releases an external animation hold and animates the focus ring onto the settled active pill if focused.
    func endExternalAnimation() {
        endFocusRingDeferral()
    }

    private func beginFocusRingDeferral() {
        activeLayoutAnimationCount += 1
        if isEditingAddress {
            pendingAnimatedFocusRing = true
        }
        let pillFrame = lastActiveTargetFrame.width > 10 ? lastActiveTargetFrame : activePillSurfaceView.frame
        let geom = focusRingGeometry(forPillFrame: pillFrame)
        focusRingOverlay.setFocusRing(frame: geom.rect, lineWidth: geom.lineWidth, visible: false, animated: false)
    }

    private func endFocusRingDeferral() {
        activeLayoutAnimationCount = max(0, activeLayoutAnimationCount - 1)
        // layout() skips its work while an animation hold is active (e.g. the sidebar slide), so catch up on any
        // width change that arrived during the hold.
        if activeLayoutAnimationCount == 0, hasLaidOutOnce, abs(bounds.width - lastLayoutBoundsWidth) > 0.5 {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        flushDeferredFocusRingIfReady()
    }

    private func flushDeferredFocusRingIfReady() {
        guard !isDeferringFocusRing else { return }
        guard isEditingAddress else {
            pendingAnimatedFocusRing = false
            return
        }
        let shouldAnimate = pendingAnimatedFocusRing
        pendingAnimatedFocusRing = false
        let pillFrame = lastActiveTargetFrame.width > 10 ? lastActiveTargetFrame : activePillSurfaceView.frame
        let geom = focusRingGeometry(forPillFrame: pillFrame)
        focusRingOverlay.setFocusRing(frame: geom.rect, lineWidth: geom.lineWidth, visible: true, animated: shouldAnimate)
    }

    private func updateActiveFocusRing(forFrame f: NSRect, editing: Bool, animated: Bool, delay: CFTimeInterval = 0.0) {
        let geom = focusRingGeometry(forPillFrame: f)
        if editing && isDeferringFocusRing {
            pendingAnimatedFocusRing = pendingAnimatedFocusRing || animated
            focusRingOverlay.setFocusRing(frame: geom.rect, lineWidth: geom.lineWidth, visible: false, animated: false)
            return
        }
        if !editing {
            pendingAnimatedFocusRing = false
        }
        focusRingOverlay.setFocusRing(frame: geom.rect, lineWidth: geom.lineWidth, visible: editing, animated: animated, delay: delay)
    }

    // MARK: - Public Updates

    func update(items newItems: [TabPresentationItem], animated: Bool? = nil) {
        guard compactDraggingTabId == nil else { return }
        self.items = newItems

        if let active = items.first(where: { $0.isActive }) {
            activeTabID = active.id
            activeIsStartPage = (active.url == nil || active.url?.scheme == "safarium")
            activeURLString = activeIsStartPage ? "" : editableURLString(for: active.url)
            activeIsLoading = active.isLoading

            if isTabOverviewActive {
                activeDisplayLabel.stringValue = "Search or enter website name"
                activeDisplayLabel.lineBreakMode = .byTruncatingTail
                if !isEditingAddress {
                    addressTextField.stringValue = ""
                }
                activeFavicon = nil
                centeredFaviconView.image = AssetLoader.shared.symbol(
                    named: "magnifyingglass",
                    pointSize: 13.5,
                    weight: .medium
                )
                centeredFaviconView.contentTintColor = placeholderSecondaryInk()
                centeredFaviconBadge.layer?.backgroundColor = NSColor.clear.cgColor
                if isEditingAddress {
                    updateEditingIcon(for: addressTextField.stringValue)
                }
                updateActiveHoverControls()
                updateProgress(1.0, isLoading: false, urlString: "", tabID: active.id)
            } else {
                if active.url?.scheme == "chrome-extension" && !active.title.isEmpty {
                    activeDisplayLabel.stringValue = active.title
                } else if BrowserSettings.shared.alwaysShowWebsiteTitles, !activeIsStartPage, !active.title.isEmpty {
                    activeDisplayLabel.stringValue = active.title
                } else {
                    activeDisplayLabel.stringValue = URLInputNormalizer.displayDomain(for: active.url)
                }
                activeDisplayLabel.lineBreakMode = activeIsStartPage ? .byTruncatingTail : .byTruncatingMiddle

                if !isEditingAddress {
                    addressTextField.stringValue = activeURLString
                }

                if let fav = active.favicon, !activeIsStartPage {
                    activeFavicon = fav
                    centeredFaviconView.image = fav
                    centeredFaviconView.contentTintColor = nil
                    centeredFaviconBadge.layer?.backgroundColor = NSColor.clear.cgColor
                } else {
                    activeFavicon = nil
                    centeredFaviconView.image = AssetLoader.shared.symbol(
                        named: activeIsStartPage ? "magnifyingglass" : "globe",
                        pointSize: activeIsStartPage ? 13.5 : 14.5,
                        weight: .medium
                    )
                    centeredFaviconView.contentTintColor = placeholderSecondaryInk()
                    centeredFaviconBadge.layer?.backgroundColor = NSColor.clear.cgColor
                }
                if isEditingAddress {
                    updateEditingIcon(for: addressTextField.stringValue)
                }

                updateActiveHoverControls()
                updateProgress(
                    active.progress,
                    isLoading: active.isLoading && !activeIsStartPage,
                    urlString: activeURLString,
                    tabID: active.id
                )
            }
        } else {
            activeTabID = ""
            activeIsStartPage = true
            activeURLString = ""
            activeIsLoading = false
        }

        rebuildAndLayout(forceAnimated: animated)
        applyAppearanceToSubviews(animated: hasLaidOutOnce)
        syncProgressBarWidthIfNeeded()
    }

    /// Lightweight fast-path for high-frequency Chromium `OnLoadingProgressChange` ticks:
    /// updates only the active tab's progress bar without tearing down or relayouting any tab/sidebar views.
    func updateActiveProgress(_ progress: Double, isLoading: Bool, url: URL?, tabID: String) {
        guard tabID == activeTabID else { return }
        let isStart = (url == nil || url?.scheme == "safarium")
        let urlStr = isStart ? "" : editableURLString(for: url)
        updateProgress(progress, isLoading: isLoading && !isStart, urlString: urlStr, tabID: tabID)
        syncProgressBarWidthIfNeeded()
    }

    func apply(theme: AdaptiveChromeTheme, animated: Bool) {
        self.theme = theme
        applyAppearanceToSubviews(animated: animated)
    }

    func focusAddressBar() {
        if isEditingAddress {
            if let editor = addressTextField.currentEditor() {
                editor.selectedRange = NSRange(location: 0, length: (addressTextField.stringValue as NSString).length)
            }
            return
        }
        isFocusingAddressBar = true
        isEditingAddress = true

        // Capture exact resting center geometry BEFORE hiding so icon & domain text start at their exact pixels!
        let iconStartX = centeredFaviconBadge.convert(centeredFaviconBadge.bounds, to: activePillSurfaceView).minX
        let domainStartX = activeDisplayLabel.convert(activeDisplayLabel.bounds, to: activePillSurfaceView).minX
        let restingDomainText = activeDisplayLabel.stringValue

        centeredTitleStack.isHidden = true
        editingIconView.isHidden = false
        addressTextField.isHidden = false
        let initialEditText = isTabOverviewActive ? "" : activeURLString
        addressTextField.stringValue = initialEditText
        updateEditingIcon(for: initialEditText)
        hdrHighlightView.isFocused = true
        updateActiveHoverControls()
        applyAppearanceToSubviews(animated: false)

        activePillSurfaceView.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(addressTextField)
        syncAddressFieldSelectionAppearance()
        if let editor = addressTextField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (addressTextField.stringValue as NSString).length)
        }

        let ringFrame = lastActiveTargetFrame.width > 10 ? lastActiveTargetFrame : activePillSurfaceView.frame
        // Match real Safari macOS 27 pacing: smooth 0.28s–0.30s glide first, then 0.26s blue focus halo contraction (0.16s beat)
        updateActiveFocusRing(forFrame: ringFrame, editing: true, animated: true, delay: 0.16)

        let smoothEase = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)

        // 1. Globe / favicon glides smoothly from its centered badge X to the left edge anchor (0.28s)
        let iconDeltaX = max(0, iconStartX - editingIconView.frame.minX)
        if !editingIconView.isHidden && iconDeltaX > 3 {
            let iconGlide = CABasicAnimation(keyPath: "transform.translation.x")
            iconGlide.fromValue = iconDeltaX
            iconGlide.toValue = 0.0
            iconGlide.duration = 0.28
            iconGlide.timingFunction = smoothEase
            editingIconView.layer?.add(iconGlide, forKey: "focusGlide")
        }

        // 2. Full URL + selection highlight glides smoothly left starting with domain aligned at its resting X (0.30s)
        var revealedPrefixWidth: CGFloat = 0.0
        if !activeIsStartPage, !activeURLString.isEmpty, !restingDomainText.isEmpty,
           let range = activeURLString.range(of: restingDomainText, options: .caseInsensitive) {
            let prefix = String(activeURLString[..<range.lowerBound])
            if !prefix.isEmpty {
                let font = addressTextField.font ?? NSFont.systemFont(ofSize: 13.0, weight: .medium)
                revealedPrefixWidth = (prefix as NSString).size(withAttributes: [.font: font]).width
            }
        }
        let fullTextTravel = max(0, domainStartX - addressTextField.frame.minX)
        let rawTextDeltaX = fullTextTravel - revealedPrefixWidth
        let textDeltaX = fullTextTravel > 3 ? max(min(fullTextTravel, 28.0), rawTextDeltaX) : 0.0
        if textDeltaX > 3 {
            let textGlide = CABasicAnimation(keyPath: "transform.translation.x")
            textGlide.fromValue = textDeltaX
            textGlide.toValue = 0.0
            textGlide.duration = 0.30
            textGlide.timingFunction = smoothEase
            addressTextField.layer?.add(textGlide, forKey: "focusGlide")

            let textFade = CABasicAnimation(keyPath: "opacity")
            textFade.fromValue = 0.25
            textFade.toValue = 1.0
            textFade.duration = 0.18
            textFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            addressTextField.layer?.add(textFade, forKey: "focusFade")
        }

        isFocusingAddressBar = false
        onAddressFocusChanged?(true)
    }

    func endAddressEditing(restoreURL: Bool = true) {
        guard isEditingAddress else { return }
        let startIconX = editingIconView.frame.minX
        isEditingAddress = false
        if restoreURL {
            addressTextField.stringValue = activeURLString
        }
        addressTextField.isHidden = true
        editingIconView.isHidden = true
        centeredTitleStack.isHidden = false
        hdrHighlightView.isFocused = false
        updateActiveHoverControls()
        applyAppearanceToSubviews(animated: false)

        activePillSurfaceView.layoutSubtreeIfNeeded()
        let ringFrame = lastActiveTargetFrame.width > 10 ? lastActiveTargetFrame : activePillSurfaceView.frame
        updateActiveFocusRing(forFrame: ringFrame, editing: false, animated: true)

        let deltaX = startIconX - centeredTitleStack.frame.minX
        if abs(deltaX) > 4 {
            let glideBack = CABasicAnimation(keyPath: "transform.translation.x")
            glideBack.fromValue = deltaX
            glideBack.toValue = 0.0
            glideBack.duration = 0.28
            glideBack.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            centeredTitleStack.layer?.add(glideBack, forKey: "unfocusGlide")
        }
        onAddressFocusChanged?(false)
    }

    // MARK: - Exact Safarium Compact Track Sizing & 0.28s Open/Close/Reorder Layout Engine

    var effectiveSlotCount: Int {
        max(1, displayedItems.count + (externalDropPlaceholder != nil ? 1 : 0))
    }

    /// Exact Safari 27.3 `fillWidth()`: single-tab width matches `290 pt` (`280 pt` with sidebar) in Compact mode,
    /// and expands to a wide centered address pill (`380–520 pt`) in Separate / Vertical tab layouts.
    /// NEVER expands on focus!
    func computeFillWidth(forSlotCount slotCount: Int? = nil) -> CGFloat {
        let singleW = isSidebarOpen
            ? SafariMetrics.activePillSingleTabSidebarWidth
            : SafariMetrics.activePillSingleTabWidth
        // Never wider than the bar itself: the track constraint no longer forces the window to grow, so a floor
        // above the real width made the manually laid-out slots spill into the right-hand capsule.
        let avail = bounds.width > 40 ? floor(bounds.width) : max(singleW, 760.0)
        if singleAddressOnlyMode {
            let desired = max(380.0, min(520.0, round(avail * 0.72)))
            return min(avail, desired)
        }
        let visible = displayedItems
        let inactivePinnedCount = visible.filter { $0.isPinned && !$0.isActive }.count
        let totalCount = max(1, slotCount ?? effectiveSlotCount)
        let fullSizeCount = max(1, totalCount - inactivePinnedCount)
        let natural = CGFloat(inactivePinnedCount) * 36.0 + CGFloat(fullSizeCount) * singleW
        return min(avail, natural)
    }

    /// True horizontal centering for single-tab mode: aligns the single address pill to the
    /// toolbar/pane's exact center (`superview.bounds.midX`, matching real Safari) while staying
    /// cleanly clamped inside `tabAddressBar`'s bounds so it never collides with left/right capsules.
    func computeTrackCenterOffset(slotCount: Int, trackWidth: CGFloat) -> CGFloat {
        guard slotCount <= 1 else { return 0.0 }
        guard let parent = superview, parent.bounds.width > 40, bounds.width > 40 else { return 0.0 }
        let desiredOffset = round(parent.bounds.midX - frame.midX)
        let maxHalfTravel = max(0.0, floor((bounds.width - trackWidth) * 0.5))
        return max(-maxHalfTravel, min(maxHalfTravel, desiredOffset))
    }

    private func rebuildAndLayout(forceAnimated: Bool? = nil) {
        // Reuse inactive tab views by ID so slots smoothly slide & resize (SafariumTabBarView.swift:919–998)
        var reusable: [String: CompactInactiveTabView] = [:]
        for v in inactiveTabViews { reusable[v.tabID] = v }
        inactiveTabViews.removeAll()

        let visible = displayedItems
        let totalSlots = effectiveSlotCount
        let targetW = computeFillWidth(forSlotCount: totalSlots)
        let targetCenterX = computeTrackCenterOffset(slotCount: totalSlots, trackWidth: targetW)

        // Animate ONLY when tab structure (open/close/reorder/drop-placeholder), pinned-active state, or sidebar changes — NEVER on plain tab switch or focus!
        let phSig = externalDropPlaceholder.map { "\($0.tabID)@\($0.index)" } ?? ""
        let pinnedSig = visible.map { $0.isPinned ? ($0.isActive ? "PA" : "P") : "N" }.joined()
        let structureSig = visible.map(\.id).joined(separator: ",") + "|p=\(pinnedSig)|h=\(hiddenDraggedTabID ?? "")|ph=\(phSig)|\(isSidebarOpen)"
        let structureChanged = (structureSig != lastStructureSig)
        lastStructureSig = structureSig
        let defaultAnimate = (window?.isVisible == true) && bounds.width > 1.0 && !(window?.inLiveResize ?? true) && hasLaidOutOnce && structureChanged
        let shouldAnimate = forceAnimated ?? defaultAnimate

        let widthChanged = abs((trackWidthConstraint?.constant ?? 0) - targetW) > 0.5
        let centerChanged = abs((trackCenterXConstraint?.constant ?? 0) - targetCenterX) > 0.5
        if widthChanged || centerChanged {
            if shouldAnimate && (window?.isVisible == true) && bounds.width > 1.0 {
                beginFocusRingDeferral()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                    ctx.allowsImplicitAnimation = true
                    trackWidthConstraint?.animator().constant = targetW
                    trackCenterXConstraint?.animator().constant = targetCenterX
                    layoutSubtreeIfNeeded()
                }, completionHandler: { [weak self] in
                    self?.endFocusRingDeferral()
                })
            } else {
                trackWidthConstraint?.constant = targetW
                trackCenterXConstraint?.constant = targetCenterX
            }
        }

        for tab in visible where !tab.isActive {
            if let existing = reusable.removeValue(forKey: tab.id) {
                existing.configure(title: tab.title, url: tab.url, favicon: tab.favicon, isLoading: tab.isLoading, progress: tab.progress, totalCount: totalSlots, isPinned: tab.isPinned, theme: theme)
                inactiveTabViews.append(existing)
                continue
            }
            let v = CompactInactiveTabView(tabID: tab.id)
            v.configure(title: tab.title, url: tab.url, favicon: tab.favicon, isLoading: tab.isLoading, progress: tab.progress, totalCount: totalSlots, isPinned: tab.isPinned, theme: theme)
            let tid = tab.id
            v.onSelect = { [weak self, weak v] in
                if let v { self?.onTabHoverChanged?(tid, v, false) }
                self?.endAddressEditing()
                self?.onSelectTab?(tid)
            }
            v.onClose = { [weak self, weak v] in
                if let v { self?.onTabHoverChanged?(tid, v, false) }
                self?.onCloseTab?(tid)
            }
            v.onHoverChanged = { [weak self, weak v] hovered in
                guard let self, let v, self.compactDraggingTabId == nil else { return }
                self.onTabHoverChanged?(tid, v, hovered)
            }
            v.onMouseDownTrack = { [weak self, weak v] ev in
                guard let self, let v else { return }
                self.onTabHoverChanged?(tid, v, false)
                self.handleInactiveTabMouseDown(view: v, tabID: tid, event: ev)
            }
            trackHostView.addSubview(v, positioned: .below, relativeTo: activePillSurfaceView)
            v.alphaValue = shouldAnimate ? 0.0 : 1.0
            inactiveTabViews.append(v)
        }

        // If a previously-inactive tab just became the active tab (e.g. closing the current active tab):
        // 1. Spawn a brief ghost of the closing active pill at its old frame and collapse/fade it out in place
        //    so the user clearly sees the CURRENT tab closing (never feeling like the left tab was closed).
        // 2. Glide `activePillSurfaceView` smoothly from the promoted tab's former slot into its new target slot.
        if let promoted = reusable.removeValue(forKey: activeTabID) {
            let oldActiveFrame = activePillSurfaceView.frame
            let prevActiveWasClosed = !visible.contains(where: { $0.id == lastActiveTabID }) && !lastActiveTabID.isEmpty && lastActiveTabID != activeTabID

            if shouldAnimate && prevActiveWasClosed && oldActiveFrame.width > 20 && compactDraggingTabId != activeTabID {
                let ghost = NSView(frame: oldActiveFrame)
                ghost.wantsLayer = true
                ghost.layer?.cornerRadius = oldActiveFrame.height * 0.5
                ghost.layer?.cornerCurve = .continuous
                ghost.layer?.backgroundColor = activePillSurfaceView.layer?.backgroundColor
                    ?? (theme.prefersLightInk
                        ? NSColor.white.withAlphaComponent(0.16).cgColor
                        : NSColor.white.withAlphaComponent(0.85).cgColor)
                trackHostView.addSubview(ghost, positioned: .below, relativeTo: activePillSurfaceView)
                let collapsedX = oldActiveFrame.minX > promoted.frame.minX ? oldActiveFrame.maxX : oldActiveFrame.minX
                let collapsedFrame = NSRect(x: collapsedX, y: oldActiveFrame.minY, width: 0, height: oldActiveFrame.height)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.20
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                    ghost.animator().frame = collapsedFrame
                    ghost.animator().alphaValue = 0.0
                }, completionHandler: {
                    ghost.removeFromSuperview()
                })
            }

            if shouldAnimate && promoted.frame.width > 10 && compactDraggingTabId != activeTabID {
                let clampedW = min(max(40.0, promoted.frame.width - 5.0), max(40.0, targetW - 5.0))
                let clampedX = min(promoted.frame.minX + 2.5, max(2.5, targetW - clampedW - 2.5))
                let startFrame = NSRect(
                    x: clampedX,
                    y: 2.5,
                    width: clampedW,
                    height: SafariMetrics.tabPillHeight - 5.0
                )
                setFrameNow(activePillSurfaceView, startFrame)
                activePillSurfaceView.layer?.cornerRadius = startFrame.height * 0.5
                progressBarHostView.layer?.cornerRadius = startFrame.height * 0.5
                hdrHighlightView.cornerRadius = startFrame.height * 0.5
            }
            promoted.removeFromSuperview()
        }
        lastActiveTabID = activeTabID

        // Closed / torn-off inactive tabs fade out smoothly over 0.18s (or disappear instantly if torn off)
        for (goneID, gone) in reusable {
            if shouldAnimate && goneID != hiddenDraggedTabID {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    gone.animator().alphaValue = 0.0
                }, completionHandler: {
                    gone.removeFromSuperview()
                })
            } else {
                gone.removeFromSuperview()
            }
        }

        layoutSlots(animated: shouldAnimate, targetTrackWidth: targetW)
        hasLaidOutOnce = true
    }

    private func setFrameNow(_ v: NSView, _ f: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            v.animator().frame = f
        }
        v.frame = f
    }

    private func layoutSlots(animated: Bool, targetTrackWidth: CGFloat? = nil) {
        let w = targetTrackWidth ?? ((trackWidthConstraint?.constant ?? 0) > 10 ? (trackWidthConstraint?.constant ?? bounds.width) : max(310, bounds.width))
        let h: CGFloat = SafariMetrics.tabPillHeight
        let trackRect = NSRect(x: 0, y: 0, width: w, height: h)
        if !animated {
            trackBgView.frame = trackRect
        }
        focusRingOverlay.frame = trackRect

        // Reuse the hairline views across layouts (allocating one NSView per slot per update was O(n) per tab operation).
        separatorsInUse = 0
        for sep in separatorViews { sep.isHidden = true }
        lastExternalPlaceholderSlotRectInTrack = .zero

        let visible = displayedItems
        let phIndex: Int? = externalDropPlaceholder.map { max(0, min(visible.count, $0.index)) }
        let totalSlots = visible.count + (phIndex != nil ? 1 : 0)

        let activeIsHidden = (hiddenDraggedTabID == activeTabID) || !visible.contains(where: { $0.isActive })
        activePillSurfaceView.isHidden = activeIsHidden && !visible.isEmpty

        guard totalSlots > 0 else {
            let f = NSRect(x: 2.5, y: 2.5, width: max(40, w - 5), height: h - 5)
            lastActiveTargetFrame = f
            setFrameNow(activePillSurfaceView, f)
            trimUnusedSeparators()
            return
        }

        let hasVisibleActive = !activeIsHidden
        let inactivePinnedCount = visible.filter { $0.isPinned && !$0.isActive }.count
        let metricsForTrack = Self.slotMetrics(trackWidth: w, totalSlots: totalSlots, inactivePinnedCount: inactivePinnedCount, hasVisibleActive: hasVisibleActive)
        let pinnedSlotW = metricsForTrack.pinnedW
        let activeW = metricsForTrack.activeW
        let eachOtherW = metricsForTrack.eachOtherW

        // Build unified slot sequence (real visible tabs + optional external drag placeholder gap)
        enum SlotEntry {
            case tab(TabPresentationItem)
            case placeholder
        }
        var slots: [SlotEntry] = visible.map { .tab($0) }
        if let phIndex {
            slots.insert(.placeholder, at: phIndex)
        }

        var inactiveIdx = 0
        var curX: CGFloat = 0
        var animatedFrames: [(NSView, NSRect)] = []
        if animated && abs(trackBgView.frame.width - trackRect.width) > 0.5 {
            animatedFrames.append((trackBgView, trackRect))
        }
        defer {
            if !animatedFrames.isEmpty {
                beginFocusRingDeferral()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                    for (v, f) in animatedFrames {
                        v.animator().frame = f
                        v.animator().alphaValue = 1.0
                    }
                }, completionHandler: { [weak self] in
                    self?.endFocusRingDeferral()
                })
            } else {
                flushDeferredFocusRingIfReady()
            }
        }

        for (slotIdx, entry) in slots.enumerated() {
            let slotW: CGFloat
            let isAct: Bool
            let isPlaceholder: Bool

            switch entry {
            case .placeholder:
                isAct = false
                isPlaceholder = true
                slotW = eachOtherW
                lastExternalPlaceholderSlotRectInTrack = NSRect(
                    x: curX + 2.5,
                    y: 2.5,
                    width: max(40.0, slotW - 5.0),
                    height: h - 5.0
                )

            case .tab(let tab):
                isPlaceholder = false
                isAct = tab.isActive
                if isAct {
                    slotW = activeW
                    let f = NSRect(x: curX + 2.5, y: 2.5, width: max(40, slotW - 5), height: h - 5)
                    lastActiveTargetFrame = f
                    activePillSurfaceView.layer?.cornerRadius = f.height * 0.5
                    progressBarHostView.layer?.cornerRadius = f.height * 0.5
                    hdrHighlightView.cornerRadius = f.height * 0.5
                    if compactDraggingTabId != tab.id {
                        if animated {
                            animatedFrames.append((activePillSurfaceView, f))
                        } else {
                            setFrameNow(activePillSurfaceView, f)
                        }
                    }
                    if animated {
                        if isEditingAddress {
                            pendingAnimatedFocusRing = true
                        }
                        let geom = focusRingGeometry(forPillFrame: f)
                        focusRingOverlay.setFocusRing(frame: geom.rect, lineWidth: geom.lineWidth, visible: false, animated: false)
                    } else {
                        updateActiveFocusRing(forFrame: f, editing: isEditingAddress, animated: false)
                    }
                } else {
                    slotW = tab.isPinned ? pinnedSlotW : eachOtherW
                    if inactiveIdx < inactiveTabViews.count {
                        let v = inactiveTabViews[inactiveIdx]
                        let f = NSRect(x: curX, y: 0, width: max(20, slotW), height: h)
                        if compactDraggingTabId != tab.id {
                            if animated {
                                if v.frame.width < 1 { v.frame = NSRect(x: f.minX, y: 0, width: 0, height: h) }
                                animatedFrames.append((v, f))
                            } else {
                                setFrameNow(v, f)
                                v.alphaValue = 1.0
                            }
                        }
                    }
                    inactiveIdx += 1
                }
            }

            // 1pt × 16pt vertical hairline between adjacent inactive tabs (never adjacent to active pill or open drop gap)
            if !isAct && !isPlaceholder && slotIdx < slots.count - 1 {
                if case .tab(let nextTab) = slots[slotIdx + 1], !nextTab.isActive {
                    let sepFrame = NSRect(x: round(curX + slotW) - 0.5, y: 10, width: 1, height: 16)
                    let sep: NSView
                    if separatorsInUse < separatorViews.count {
                        sep = separatorViews[separatorsInUse]
                    } else {
                        sep = NSView(frame: sepFrame)
                        sep.wantsLayer = true
                        trackHostView.addSubview(sep)
                        separatorViews.append(sep)
                    }
                    sep.frame = sepFrame
                    sep.layer?.backgroundColor = theme.tabDividerColor.cgColor
                    sep.isHidden = false
                    separatorsInUse += 1
                }
            }
            curX += slotW
        }
        trimUnusedSeparators()
    }

    private func trimUnusedSeparators() {
        while separatorViews.count > separatorsInUse { separatorViews.removeLast().removeFromSuperview() }
    }

    // MARK: - Progress & Adaptive Appearance

    private func stopProgressTrickleTimer() {
        progressTrickleTimer?.invalidate()
        progressTrickleTimer = nil
    }

    private func startPreResponseTrickleTimer() {
        stopProgressTrickleTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self, self.wasProgressLoading else {
                self?.stopProgressTrickleTimer()
                return
            }
            // Gently trickle up to 0.28 while waiting for initial server response (TTFB),
            // then yield completely to Chromium's real OnLoadingProgressChange milestones.
            if self.displayedProgress >= 0.28 {
                self.stopProgressTrickleTimer()
                return
            }
            let remaining = 0.28 - self.displayedProgress
            self.displayedProgress = min(0.28, self.displayedProgress + max(0.008, remaining * 0.16))
            self.updateProgressBarFrame(animated: true, duration: 0.16)
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTrickleTimer = timer
    }

    private func updateProgress(_ progress: Double, isLoading: Bool, urlString: String, tabID: String) {
        let switchedTab = (tabID != progressTabID)
        let clampedRaw = max(0.0, min(1.0, progress))
        progressTabID = tabID

        if switchedTab {
            progressFadeWorkItem?.cancel()
            progressFadeWorkItem = nil
            progressShowWorkItem?.cancel()
            progressShowWorkItem = nil
            isShowingLoadingUI = false
            stopProgressTrickleTimer()
            progressBarLayer.removeAllAnimations()
            wasProgressLoading = false
            displayedProgress = 0.0
            lastRawProgress = 0.0
            progressURLString = urlString

            if !isLoading {
                progressBarHostView.isHidden = true
                progressBarHostView.alphaValue = 0.0
                updateProgressBarFrame(animated: false)
                updateActiveHoverControls()
                return
            }
        }

        let restartedNavigation = isLoading && (
            !wasProgressLoading ||
            (clampedRaw <= 0.05 && lastRawProgress >= 0.20) ||
            (!urlString.isEmpty && urlString != progressURLString && clampedRaw <= 0.15 && displayedProgress > 0.35)
        )
        lastRawProgress = clampedRaw
        if !urlString.isEmpty {
            progressURLString = urlString
        }

        if isLoading {
            progressFadeWorkItem?.cancel()
            progressFadeWorkItem = nil
            progressBarLayer.backgroundColor = HDRColorFactory.accentColor(for: window?.screen, alpha: 0.92).cgColor

            if restartedNavigation {
                wasProgressLoading = true
                progressShowWorkItem?.cancel()
                progressShowWorkItem = nil
                isShowingLoadingUI = false
                updateActiveHoverControls()
                progressBarLayer.removeAllAnimations()
                progressBarHostView.isHidden = true
                progressBarHostView.alphaValue = 0.0

                // If Chromium hasn't reset progress from a prior page yet (`>= 0.99`), start cleanly at 0.08
                let effectiveRaw = (clampedRaw >= 0.99) ? 0.0 : clampedRaw
                let initialTarget = max(0.08, min(0.92, effectiveRaw))
                displayedProgress = initialTarget

                let w = activePillSurfaceView.bounds.width > 1.0 ? activePillSurfaceView.bounds.width : lastActiveTargetFrame.width
                lastProgressBarWidth = w
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                progressBarLayer.frame = CGRect(x: 0, y: 0, width: 0.0, height: 2.5)
                CATransaction.commit()

                // Safari-style 140ms grace delay: fast/cached/BFCache navigations finish silently without flashing
                // a progress bar or swapping the Page Menu icon to an X.
                let showWork = DispatchWorkItem { [weak self] in
                    guard let self, self.wasProgressLoading else { return }
                    self.isShowingLoadingUI = true
                    self.updateActiveHoverControls()
                    self.progressBarHostView.isHidden = false
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.14
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.progressBarHostView.animator().alphaValue = 1.0
                    }
                    self.updateProgressBarFrame(animated: true, duration: 0.18)
                    if self.displayedProgress < 0.28 {
                        self.startPreResponseTrickleTimer()
                    } else {
                        self.stopProgressTrickleTimer()
                    }
                }
                progressShowWorkItem = showWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: showWork)
            } else {
                // Real Chromium progress update during active navigation: track monotonically up to 0.98
                let nextTarget = min(0.98, clampedRaw)
                if nextTarget > displayedProgress + 0.005 {
                    displayedProgress = nextTarget
                    if displayedProgress >= 0.28 {
                        stopProgressTrickleTimer()
                    }
                    if isShowingLoadingUI {
                        progressBarHostView.isHidden = false
                        progressBarHostView.alphaValue = 1.0
                        updateProgressBarFrame(animated: true, duration: 0.20)
                    }
                }
            }
        } else if wasProgressLoading {
            wasProgressLoading = false
            let wasVisible = isShowingLoadingUI
            progressShowWorkItem?.cancel()
            progressShowWorkItem = nil
            isShowingLoadingUI = false
            updateActiveHoverControls()
            stopProgressTrickleTimer()
            guard wasVisible else {
                progressBarHostView.isHidden = true
                progressBarHostView.alphaValue = 0.0
                return
            }
            displayedProgress = 1.0
            progressBarLayer.backgroundColor = HDRColorFactory.accentColor(for: window?.screen, alpha: 0.92).cgColor
            updateProgressBarFrame(animated: true, duration: 0.18)

            progressFadeWorkItem?.cancel()
            let fadeWork = DispatchWorkItem { [weak self] in
                guard let self, !self.wasProgressLoading else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.24
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.progressBarHostView.animator().alphaValue = 0.0
                }, completionHandler: { [weak self] in
                    guard let self, !self.wasProgressLoading else { return }
                    self.progressBarHostView.isHidden = true
                    self.displayedProgress = 0.0
                    self.lastRawProgress = 0.0
                })
            }
            progressFadeWorkItem = fadeWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: fadeWork)
        }
    }

    private func syncProgressBarWidthIfNeeded() {
        let w = activePillSurfaceView.bounds.width > 1.0 ? activePillSurfaceView.bounds.width : lastActiveTargetFrame.width
        guard w > 1.0, abs(w - lastProgressBarWidth) > 0.5 else { return }
        lastProgressBarWidth = w
        guard !progressBarHostView.isHidden else { return }
        updateProgressBarFrame(animated: false)
    }

    private func updateProgressBarFrame(animated: Bool = false, duration: CFTimeInterval = 0.18) {
        let w = activePillSurfaceView.bounds.width > 1.0 ? activePillSurfaceView.bounds.width : lastActiveTargetFrame.width
        guard w > 1.0 else { return }
        lastProgressBarWidth = w
        let barHeight: CGFloat = 2.5
        // PassthroughTrackView is non-flipped (y = 0 is bottom edge); clipped cleanly by progressBarHostView's pill radius
        let targetFrame = CGRect(x: 0, y: 0, width: w * CGFloat(max(0.0, min(1.0, displayedProgress))), height: barHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0))
        }
        progressBarLayer.frame = targetFrame
        CATransaction.commit()
    }

    private var activePillPrefersLightInk: Bool {
        isPrivateMode || theme.prefersLightInk
    }

    private func placeholderSecondaryInk() -> NSColor {
        if isPrivateMode {
            return NSColor.white.withAlphaComponent(0.76)
        }
        return theme.prefersLightInk
            ? NSColor.white.withAlphaComponent(0.68)
            : NSColor(srgbRed: 0.478, green: 0.478, blue: 0.490, alpha: 1.0) // Real Safari #7A7A7D
    }

    private func applyAppearanceToSubviews(animated: Bool = false) {
        // Track background smooth 0.22s color crossfade (exact SafariumTabBarView.swift:798)
        let useGlassTrack = BrowserSettings.shared.refractiveGlassToolbar
        if #available(macOS 26.0, *), let tgv = trackGlassView as? NSGlassEffectView {
            tgv.isHidden = !useGlassTrack
            if useGlassTrack {
                tgv.style = .regular
                tgv.appearance = theme.preferredAppearance
                tgv.tintColor = theme.prefersLightInk
                    ? NSColor.black.withAlphaComponent(0.22)
                    : NSColor.white.withAlphaComponent(0.18)
            }
        }
        let targetTrackCg = useGlassTrack ? NSColor.clear.cgColor : theme.tabTrackBackgroundColor.cgColor
        if lastTrackBgColor != targetTrackCg {
            if animated, let prev = lastTrackBgColor, let layer = trackBgView.layer {
                let anim = CABasicAnimation(keyPath: "backgroundColor")
                anim.fromValue = prev
                anim.toValue = targetTrackCg
                anim.duration = 0.22
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(anim, forKey: "trackBgFade")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trackBgView.layer?.backgroundColor = targetTrackCg
            CATransaction.commit()
            lastTrackBgColor = targetTrackCg
        }

        // Native Liquid Glass active pill (or exact macOS 27 Safari Private dark charcoal `#5B5B5E` active pill!)
        let screen = window?.screen ?? NSScreen.main
        let exposure = SafariMetrics.activeTabLinearExposure(for: screen)
        let fill = theme.activeTabFillColor.usingColorSpace(.sRGB) ?? theme.activeTabFillColor
        let pillLightInk = activePillPrefersLightInk

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isEditingAddress {
            // Focused state: native macOS 27 Tahoe translucent Liquid Glass (SDR, zero opaque black/white block)
            if #available(macOS 26.0, *) {
                activePillSurfaceView.layer?.preferredDynamicRange = .standard
            }
            if isPrivateMode {
                activePillGlassHost.isHidden = true
                activePillSurfaceView.layer?.backgroundColor = NSColor(srgbRed: 0.28, green: 0.28, blue: 0.30, alpha: 1.0).cgColor
                activePillSurfaceView.layer?.borderWidth = 0.0
            } else if #available(macOS 26.0, *), let gv = activePillGlassView as? NSGlassEffectView {
                activePillGlassHost.isHidden = false
                activePillGlassHost.layer?.preferredDynamicRange = .standard
                gv.layer?.preferredDynamicRange = .standard
                #if compiler(>=6.4)
                if #available(macOS 27.0, *) {
                    gv.effectIsInteractive = false
                }
                #endif
                gv.cornerRadius = activePillSurfaceView.layer?.cornerRadius ?? SafariMetrics.tabInnerCornerRadius
                if theme.prefersLightInk {
                    gv.style = .clear
                    gv.appearance = NSAppearance(named: .darkAqua)
                    gv.tintColor = NSColor.black.withAlphaComponent(0.18)
                    activePillSurfaceView.layer?.backgroundColor = NSColor.clear.cgColor
                } else {
                    // Pure SDR translucent white fill — hide NSGlassEffectView so zero HDR/EDR glow appears
                    activePillGlassHost.isHidden = true
                    activePillSurfaceView.layer?.backgroundColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.84).cgColor
                }
                activePillSurfaceView.layer?.borderWidth = 0.0
            } else {
                activePillGlassHost.isHidden = true
                activePillSurfaceView.layer?.backgroundColor = theme.prefersLightInk
                    ? NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 0.55).cgColor
                    : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.85).cgColor
                activePillSurfaceView.layer?.borderWidth = 0.5
                activePillSurfaceView.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
            }
        } else if isPrivateMode {
            if #available(macOS 26.0, *) {
                activePillSurfaceView.layer?.preferredDynamicRange = .standard
            }
            activePillGlassHost.isHidden = false
            let privColor = theme.prefersLightInk
                ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.155, alpha: 0.94)
                : NSColor(srgbRed: 0.355, green: 0.355, blue: 0.370, alpha: 0.94)
            if #available(macOS 26.0, *), let gv = activePillGlassView as? NSGlassEffectView {
                gv.style = .regular
                gv.appearance = NSAppearance(named: .darkAqua)
                gv.cornerRadius = activePillSurfaceView.layer?.cornerRadius ?? SafariMetrics.tabInnerCornerRadius
                gv.tintColor = privColor
            }
            activePillSurfaceView.layer?.backgroundColor = privColor.cgColor
            activePillSurfaceView.layer?.borderWidth = 0.0
        } else if #available(macOS 26.0, *), let gv = activePillGlassView as? NSGlassEffectView {
            activePillSurfaceView.layer?.preferredDynamicRange = theme.prefersLightInk ? .standard : .constrainedHigh
            activePillGlassHost.layer?.preferredDynamicRange = theme.prefersLightInk ? .standard : .constrainedHigh
            gv.layer?.preferredDynamicRange = theme.prefersLightInk ? .standard : .constrainedHigh
            activePillGlassHost.isHidden = false
            gv.style = .regular
            gv.appearance = theme.preferredAppearance
            gv.cornerRadius = activePillSurfaceView.layer?.cornerRadius ?? SafariMetrics.tabInnerCornerRadius
            if theme.prefersLightInk {
                gv.tintColor = NSColor(
                    srgbRed: fill.redComponent,
                    green: fill.greenComponent,
                    blue: fill.blueComponent,
                    alpha: 0.14
                )
            } else {
                gv.tintColor = NSColor(
                    red: fill.redComponent,
                    green: fill.greenComponent,
                    blue: fill.blueComponent,
                    alpha: 0.42,
                    linearExposure: exposure
                )
            }
            activePillSurfaceView.layer?.backgroundColor = NSColor.clear.cgColor
            activePillSurfaceView.layer?.borderWidth = 0.0
        } else {
            activePillGlassHost.isHidden = false
            activePillSurfaceView.layer?.backgroundColor = fill.withAlphaComponent(0.90).cgColor
            activePillSurfaceView.layer?.borderWidth = 0.0
        }
        activePillHoverTintView.layer?.backgroundColor = pillLightInk
            ? NSColor.white.withAlphaComponent(0.06).cgColor
            : NSColor.black.withAlphaComponent(0.042).cgColor
        let hoverRadius = max(0, (activePillSurfaceView.layer?.cornerRadius ?? SafariMetrics.tabInnerCornerRadius) - 1.0)
        activePillHoverTintView.layer?.cornerRadius = hoverRadius
        CATransaction.commit()

        if activeFavicon != nil && !activeIsStartPage {
            centeredFaviconBadge.layer?.backgroundColor = NSColor.clear.cgColor
        }

        hdrHighlightView.isLightInkOnDark = pillLightInk
        hdrHighlightView.accentTintColor = theme.sampledColor

        if activeIsStartPage || isTabOverviewActive {
            let phInk = placeholderSecondaryInk()
            activeDisplayLabel.textColor = phInk
            centeredFaviconView.contentTintColor = phInk
        } else {
            activeDisplayLabel.textColor = pillLightInk
                ? NSColor.white.withAlphaComponent(0.96)
                : NSColor(srgbRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)
        }
        addressTextField.textColor = pillLightInk ? NSColor.white.withAlphaComponent(0.96) : theme.primaryInkColor
        addressTextField.placeholderAttributedString = NSAttributedString(
            string: "Search or enter website name",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.0, weight: .medium),
                .foregroundColor: placeholderSecondaryInk()
            ]
        )
        syncAddressFieldSelectionAppearance()
        if isEditingAddress {
            updateEditingIcon(for: addressTextField.stringValue)
        } else {
            editingIconView.contentTintColor = placeholderSecondaryInk()
        }

        if pillLightInk {
            hoverReloadButton.normalTintColor = NSColor.white.withAlphaComponent(0.74)
            hoverReloadButton.hoverTintColor = NSColor.white.withAlphaComponent(0.98)
            pageMenuButton.normalTintColor = NSColor.white.withAlphaComponent(0.74)
            pageMenuButton.hoverTintColor = NSColor.white.withAlphaComponent(0.98)
        } else {
            hoverReloadButton.normalTintColor = NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 0.80)
            hoverReloadButton.hoverTintColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.96)
            pageMenuButton.normalTintColor = NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 0.80)
            pageMenuButton.hoverTintColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.96)
        }
        activeCloseButton.isDark = pillLightInk

        for v in inactiveTabViews {
            v.applyTheme(theme)
        }
        for sep in separatorViews {
            sep.layer?.backgroundColor = theme.tabDividerColor.cgColor
        }
    }

    // MARK: - Actions & NSTextFieldDelegate

    @objc private func reloadClicked() { onReloadOrStop?() }
    @objc private func activeCloseClicked() {
        if isEditingAddress {
            endAddressEditing(restoreURL: false)
            window?.makeFirstResponder(nil)
        }
        onCloseTab?(activeTabID)
    }
    @objc private func pageMenuClicked() {
        if activeIsLoading {
            onReloadOrStop?()
        } else {
            onShowPageMenu?(pageMenuButton)
        }
    }

    private func syncAddressFieldSelectionAppearance() {
        let pillLightInk = activePillPrefersLightInk
        let targetAppearance = NSAppearance(named: pillLightInk ? .darkAqua : .aqua)
        addressTextField.appearance = targetAppearance
        if let editor = addressTextField.currentEditor() as? NSTextView {
            editor.appearance = targetAppearance
            editor.insertionPointColor = pillLightInk ? NSColor.white : NSColor.black
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
            let selBg: NSColor = pillLightInk
                ? accent.withAlphaComponent(0.58)
                : accent.withAlphaComponent(0.28)
            let selFg: NSColor = pillLightInk
                ? NSColor.white
                : NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)
            editor.selectedTextAttributes = [
                .backgroundColor: selBg,
                .foregroundColor: selFg
            ]
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        syncAddressFieldSelectionAppearance()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard isEditingAddress else { return }
        syncAddressFieldSelectionAppearance()
        updateEditingIcon(for: addressTextField.stringValue)
        onAddressQueryChanged?(addressTextField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            onMoveSelection?(1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            onMoveSelection?(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if onCommitSelectedSuggestion?() == true {
                endAddressEditing(restoreURL: false)
                window?.makeFirstResponder(nil)
                return true
            }
            let submitted = addressTextField.stringValue
            endAddressEditing(restoreURL: false)
            window?.makeFirstResponder(nil)
            onSubmitURLString?(submitted)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endAddressEditing(restoreURL: true)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isFocusingAddressBar else { return }
        endAddressEditing(restoreURL: true)
    }
}

// MARK: - Helper Views

private final class FlippedTrackHostView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PassthroughTrackView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FlippedActivePillView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var interactiveControlsProvider: (() -> [NSView])?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sup = superview else { return nil }
        let local = convert(point, from: sup)
        guard bounds.contains(local) else { return nil }
        if let controls = interactiveControlsProvider?() {
            for control in controls where !control.isHidden {
                if let hit = control.hitTest(local) {
                    return hit
                }
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
}

/// Exact Safarium compact tab close glyph: `12.5 pt` filled circle with `6 pt` heavy `xmark`, ZERO hover box!
private final class CompactTabCloseButton: NSView {
    var onClick: (() -> Void)?
    var isDark: Bool = false { didSet { needsDisplay = true } }
    private var isHovered: Bool = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var trackingRef: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingRef { removeTrackingArea(trackingRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 12.5
        let circle = NSRect(x: (bounds.width - d) * 0.5, y: (bounds.height - d) * 0.5, width: d, height: d)
        let circleColor = isDark
            ? NSColor(white: 0.92, alpha: isHovered ? 1.0 : 0.90)
            : NSColor(white: 0.11, alpha: isHovered ? 1.0 : 0.90)
        circleColor.setFill()
        NSBezierPath(ovalIn: circle).fill()

        let base = AssetLoader.shared.symbol(named: "xmark", pointSize: 6.0, weight: .heavy)
        let xImg = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            (self.isDark ? NSColor.black : NSColor.white).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let sz = xImg.size
        xImg.draw(in: NSRect(x: circle.midX - sz.width * 0.5, y: circle.midY - sz.height * 0.5, width: sz.width, height: sz.height))
    }
}

/// 1:1 port of `SafariumTabItemView` in Compact style (`SafariumTabBarView.swift:7–343`):
/// - Pill hover fill (`white 0.08` dark / `black 0.06` light, `r = height * 0.5`)
/// - Exact `12.5 pt` dark-circle `xmark` close button strictly on LEFT (`x = 8 pt`), visible on hover
/// - Centered `15 pt` favicon + `6 pt` gap + `13 pt` regular title
/// - Supports click-to-activate, middle-click-to-close, and horizontal drag-to-reorder!
private final class CompactInactiveTabView: NSView {
    let tabID: String
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onMouseDownTrack: ((NSEvent) -> Void)?
    var isDraggingElevated: Bool = false {
        didSet {
            if oldValue != isDraggingElevated {
                needsDisplay = true
            }
        }
    }

    private var title: String = ""
    private var url: URL?
    private var favicon: NSImage?
    private var isLoading: Bool = false
    private var progress: Double = 1.0
    private var totalTabCount: Int = 2
    private var isPinned: Bool = false
    private var theme: AdaptiveChromeTheme = .defaultLight

    private var isTabHovered = false { didSet { if oldValue != isTabHovered { needsDisplay = true } } }
    private var isCloseHovered = false { didSet { if oldValue != isCloseHovered { needsDisplay = true } } }
    private var trackingRef: NSTrackingArea?
    private var closeMouseDown = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(tabID: String) {
        self.tabID = tabID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, url: URL?, favicon: NSImage?, isLoading: Bool, progress: Double, totalCount: Int, isPinned: Bool = false, theme: AdaptiveChromeTheme) {
        self.title = title
        self.url = url
        self.favicon = favicon
        self.isLoading = isLoading
        self.progress = progress
        self.totalTabCount = totalCount
        self.isPinned = isPinned
        self.theme = theme
        needsDisplay = true
    }

    func applyTheme(_ theme: AdaptiveChromeTheme) {
        self.theme = theme
        needsDisplay = true
    }

    private var closeRect: NSRect {
        let sz: CGFloat = 15.0
        return NSRect(x: 8.0, y: (bounds.height - sz) * 0.5, width: sz, height: sz)
    }

    private var showsCloseButton: Bool {
        !isPinned && !isDraggingElevated && isTabHovered && totalTabCount > 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingRef { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isTabHovered = true
        updateSubHover(event)
        onHoverChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        updateSubHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        isTabHovered = false
        isCloseHovered = false
        onHoverChanged?(false)
    }

    private func updateSubHover(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        isCloseHovered = showsCloseButton && closeRect.contains(pt)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if showsCloseButton && closeRect.contains(pt) {
            closeMouseDown = true
            return
        }
        closeMouseDown = false
        onMouseDownTrack?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if closeMouseDown {
            closeMouseDown = false
            if showsCloseButton && closeRect.contains(pt) {
                onClose?()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = theme.prefersLightInk
        let cr = bounds.height * 0.5
        let pillPath = NSBezierPath(roundedRect: bounds, xRadius: cr, yRadius: cr)

        if isDraggingElevated {
            let liftedRect = bounds.insetBy(dx: 2.5, dy: 2.5)
            let liftedPath = NSBezierPath(roundedRect: liftedRect, xRadius: liftedRect.height * 0.5, yRadius: liftedRect.height * 0.5)
            let liftedFill = isDark
                ? NSColor(white: 1.0, alpha: 0.14)
                : NSColor(white: 1.0, alpha: 0.88)
            liftedFill.setFill()
            liftedPath.fill()
            (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).setStroke()
            liftedPath.lineWidth = 0.5
            liftedPath.stroke()
        } else if isTabHovered {
            let hoverFill = isDark
                ? NSColor(white: 1.0, alpha: 0.08)
                : NSColor(white: 0.0, alpha: 0.06)
            hoverFill.setFill()
            pillPath.fill()
        }

        // 1. Exact Safarium compact close glyph (`12.5 pt` filled circle + `6 pt` heavy `xmark`, ZERO hover square)
        if showsCloseButton {
            let d: CGFloat = 12.5
            let circle = NSRect(x: closeRect.midX - d * 0.5, y: closeRect.midY - d * 0.5, width: d, height: d)
            (isDark ? NSColor(white: 0.92, alpha: isCloseHovered ? 1 : 0.9) : NSColor(white: 0.11, alpha: isCloseHovered ? 1 : 0.9)).setFill()
            NSBezierPath(ovalIn: circle).fill()

            let base = AssetLoader.shared.symbol(named: "xmark", pointSize: 6.0, weight: .heavy)
            let xImg = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                (isDark ? NSColor.black : NSColor.white).set()
                r.fill(using: .sourceAtop)
                return true
            }
            let sz = xImg.size
            xImg.draw(in: NSRect(x: circle.midX - sz.width * 0.5, y: circle.midY - sz.height * 0.5, width: sz.width, height: sz.height))
        }

        // 1b. Pinned inactive tab: compact centered favicon-only pill (matches Safari video_1.mov)
        if isPinned {
            let favSize: CGFloat = 16.0
            let iconRect = NSRect(x: (bounds.width - favSize) * 0.5, y: (bounds.height - favSize) * 0.5, width: favSize, height: favSize)
            if let fav = favicon, url?.scheme != "safarium" {
                if isDark {
                    let badgeRect = iconRect.insetBy(dx: -1.5, dy: -1.5)
                    NSColor.white.withAlphaComponent(0.92).setFill()
                    NSBezierPath(ovalIn: badgeRect).fill()
                }
                fav.draw(in: iconRect)
            } else {
                let sym = AssetLoader.shared.symbol(named: "globe", pointSize: 13.5, weight: .regular)
                let tinted = NSImage(size: sym.size, flipped: false) { r in
                    sym.draw(in: r)
                    self.theme.secondaryInkColor.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: iconRect)
            }
            return
        }

        // 2. Centered Favicon + Title (exact SafariumTabItemView.swift:294–341)
        let leftPad: CGFloat = showsCloseButton ? 28 : 10
        let rightPad: CGFloat = 10
        let availW = max(24, bounds.width - leftPad - rightPad)

        let titleColor = isDark ? NSColor(white: 1.0, alpha: 0.88) : NSColor(white: 52.0 / 255.0, alpha: 1.0)
        let font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: titleColor,
            .paragraphStyle: pStyle
        ]

        let displayTitle = title.isEmpty ? URLInputNormalizer.displayDomain(for: url) : title
        let nsTitle = NSString(string: displayTitle)
        let titleSz = nsTitle.size(withAttributes: attrs)
        let isStart = (url?.scheme == "safarium")
        let showFavicon = availW > 46
        let favSize: CGFloat = 15.0
        let gap: CGFloat = showFavicon ? 6.0 : 0.0
        let contentW = min(availW, (showFavicon ? (favSize + gap) : 0) + titleSz.width)

        let idealX = (bounds.width - contentW) * 0.5
        let startX = max(leftPad, min(bounds.width - rightPad - contentW, idealX))

        var textX = startX
        if showFavicon {
            let iconRect = NSRect(x: startX, y: (bounds.height - favSize) * 0.5, width: favSize, height: favSize)
            if let fav = favicon, !isStart {
                if isDark {
                    let badgeRect = iconRect.insetBy(dx: -1.5, dy: -1.5)
                    NSColor.white.withAlphaComponent(0.92).setFill()
                    NSBezierPath(ovalIn: badgeRect).fill()
                }
                fav.draw(in: iconRect)
            } else {
                let symName = isStart ? "star" : "globe"
                let sym = AssetLoader.shared.symbol(named: symName, pointSize: 13.0, weight: .regular)
                let tinted = NSImage(size: sym.size, flipped: false) { r in
                    sym.draw(in: r)
                    self.theme.secondaryInkColor.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: iconRect)
            }
            textX += favSize + gap
        }

        let drawTitleW = max(16, (startX + contentW) - textX)
        nsTitle.draw(
            in: NSRect(x: textX, y: (bounds.height - titleSz.height) * 0.5, width: drawTitleW, height: titleSz.height + 2),
            withAttributes: attrs
        )
    }
}

/// Subtle hover-darkening icon button for Reload & Page Menu inside the active pill (1:1 Safari macOS 27).
private final class HoverablePillIconButton: NSButton {
    var normalTintColor: NSColor = NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 0.80) {
        didSet { syncTint() }
    }
    var hoverTintColor: NSColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 0.96) {
        didSet { syncTint() }
    }
    private var isHovered: Bool = false { didSet { syncTint() } }
    private var trackingRef: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingRef { removeTrackingArea(trackingRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func syncTint() {
        contentTintColor = isHovered ? hoverTintColor : normalTintColor
    }
}

/// 1:1 macOS 27 Safari focus ring overlay:
/// - Unclipped (`layer.masksToBounds = false`) overlay sitting above the tab track
/// - Soft macOS focus blue (`NSColor.controlAccentColor.withAlphaComponent(0.62)`)
/// - On focus-in: subtle beat after text/icon glide begins, expanded outer halo contracts cleanly onto
///   the capsule perimeter over `0.18s` (`controlPoints(0.22, 1.0, 0.36, 1.0)`)
/// - On unfocus: crisp `0.10s` `.easeOut` opacity fade
private final class SafariFocusRingOverlayView: NSView {
    private let ringLayer = CAShapeLayer()
    private var lastFrame: NSRect = .zero
    private var lastLineWidth: CGFloat = 3.4
    private var isRingVisible: Bool = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 3.4
        ringLayer.opacity = 0
        layer?.addSublayer(ringLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFocusRing(
        frame f: NSRect,
        lineWidth: CGFloat = 3.4,
        visible: Bool,
        animated: Bool,
        delay: CFTimeInterval = 0.0
    ) {
        guard f.width > 10, f.height > 10 else { return }
        let tightPath = CGPath(roundedRect: f, cornerWidth: f.height * 0.5, cornerHeight: f.height * 0.5, transform: nil)
        let expandedRect = f.insetBy(dx: -6.0, dy: -5.0)
        let loosePath = CGPath(roundedRect: expandedRect, cornerWidth: expandedRect.height * 0.5, cornerHeight: expandedRect.height * 0.5, transform: nil)

        let ringColor = NSColor.controlAccentColor.withAlphaComponent(0.58).cgColor
        ringLayer.strokeColor = ringColor

        let stateChanged = (visible != isRingVisible)
        lastFrame = f
        lastLineWidth = lineWidth
        isRingVisible = visible

        if animated && stateChanged {
            ringLayer.removeAnimation(forKey: "safariFocusRing")
            if visible {
                let pathAnim = CABasicAnimation(keyPath: "path")
                pathAnim.fromValue = loosePath
                pathAnim.toValue = tightPath

                let widthAnim = CABasicAnimation(keyPath: "lineWidth")
                widthAnim.fromValue = lineWidth + 1.6
                widthAnim.toValue = lineWidth

                let opacityAnim = CABasicAnimation(keyPath: "opacity")
                opacityAnim.fromValue = 0.0
                opacityAnim.toValue = 1.0

                let group = CAAnimationGroup()
                group.animations = [pathAnim, widthAnim, opacityAnim]
                group.duration = 0.26
                group.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                if delay > 0.001 {
                    group.beginTime = CACurrentMediaTime() + delay
                    group.fillMode = .backwards
                }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                ringLayer.frame = bounds
                ringLayer.path = tightPath
                ringLayer.lineWidth = lineWidth
                ringLayer.opacity = 1.0
                CATransaction.commit()
                ringLayer.add(group, forKey: "safariFocusRing")
            } else {
                let opacityAnim = CABasicAnimation(keyPath: "opacity")
                opacityAnim.fromValue = ringLayer.presentation()?.opacity ?? 1.0
                opacityAnim.toValue = 0.0
                opacityAnim.duration = 0.14
                opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                ringLayer.frame = bounds
                ringLayer.path = tightPath
                ringLayer.lineWidth = lineWidth
                ringLayer.opacity = 0.0
                CATransaction.commit()
                ringLayer.add(opacityAnim, forKey: "safariFocusRing")
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ringLayer.frame = bounds
            ringLayer.path = tightPath
            ringLayer.lineWidth = lineWidth
            ringLayer.opacity = visible ? 1.0 : 0.0
            CATransaction.commit()
        }
    }
}
