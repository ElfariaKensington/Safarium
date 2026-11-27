import AppKit
import QuartzCore

/// 1:1 port of Safarium's native AppKit floating `NSPanel` + `NSGlassEffectView` Address Bar Popover
/// (`SafariumUnifiedField.swift:1200–2040`), matching native macOS 27.3 Safari (`05_addressbar_popover_top.png`):
/// - Real floating `NSPanel` child window (`cornerRadius = 22 pt`, `NSGlassEffectView(style: .regular)`)
/// - Screen-coordinate centering locked directly 6pt beneath the focused URL pill (`480–620 × ≤560 pt`)
/// - Exact `sidePad = 38 pt`, `20 pt` bold `#383D42` headers, `6×2` `66 × 66 pt` Favorites squircle grid,
///   tall `226 × 156 pt` Recently Viewed cards (with clock timestamp & `"N Tabs ›"` pill), `58 pt` Reading List rows,
///   and full keyboard-navigable query autocomplete (`Top Hit`, `Google Search`, `Switch to Tab`, `Bookmarks and History`)
final class AddressBarPopoverController: NSObject {
    struct RecentGroup {
        let domain: String
        let latestURL: URL
        let title: String
        let count: Int
        let visitedAt: Date
        let favicon: NSImage?
    }

    struct OpenTabInfo {
        let id: String
        let title: String
        let url: URL
        let favicon: NSImage?
        let isActive: Bool
        let isStartPage: Bool
    }

    struct ReadingListEntry {
        let title: String
        let domain: String
        let url: URL
    }

    enum SuggestionKind {
        case url(URL)
        case search(String)
        case switchToTab(String)
    }

    enum SuggestionRowStyle {
        case topHit
        case switchToTab
        case googleSuggestion
        case bookmarkOrHistory
    }

    struct SuggestionItem {
        let title: String
        let subtitle: String
        let iconURLString: String
        let prefetchedIcon: NSImage?
        let symbolName: String?
        let style: SuggestionRowStyle
        let kind: SuggestionKind
        let isBookmarked: Bool

        init(
            title: String,
            subtitle: String,
            iconURLString: String,
            prefetchedIcon: NSImage?,
            symbolName: String?,
            style: SuggestionRowStyle,
            kind: SuggestionKind,
            isBookmarked: Bool = false
        ) {
            self.title = title
            self.subtitle = subtitle
            self.iconURLString = iconURLString
            self.prefetchedIcon = prefetchedIcon
            self.symbolName = symbolName
            self.style = style
            self.kind = kind
            self.isBookmarked = isBookmarked
        }
    }

    var onSelectURL: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onOpenInNewTabGroup: ((URL) -> Void)?
    var onSelectSearch: ((String) -> Void)?
    var onSwitchToTab: ((String) -> Void)?
    var onDismissRequested: (() -> Void)?

    var isShown: Bool { panel?.isVisible == true && panel?.parent != nil && !isClosing }

    private var panel: NSPanel?
    private var transitionToken: Int = 0
    private var isClosing: Bool = false
    private var glassBackground: NSView?
    private var lightGlassBackground: NSView?
    private var darkGlassBackground: NSView?
    private var glassContentWrapper: NSView?
    private var tintOverlayView: NSView?
    private var scrollView: NSScrollView?
    private var contentContainer: PopoverFlippedContainer?

    private weak var popoverFavoritesGrid: PopoverFavoritesReorderGridView?
    private weak var popoverShowAllButton: NSButton?
    private weak var belowFavoritesContainer: NSView?
    private var isFavoritesManuallyExpanded: Bool = false
    private var favoritesGridTopY: CGFloat = 70
    private var belowFavoritesHeight: CGFloat = 0

    private weak var anchorField: NSView?
    private weak var hostWindow: NSWindow?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?

    private var currentQuery: String = ""
    private var currentIsDark: Bool = false
    private var currentIsPrivate: Bool = false
    private var recentGroups: [RecentGroup] = []
    private var openTabs: [OpenTabInfo] = []
    private var activeDomain: String = ""
    var suggestions: [SuggestionItem] = []
    private var autocompleteRowViews: [PopoverAutocompleteRowView] = []
    private var selectedIndex: Int = -1

    // Real live Google Suggestions cache + debounced fetch
    var googleSuggestCache: [String: [String]] = [:]
    private var googleSuggestWorkItem: DispatchWorkItem?
    private var googleSuggestTask: URLSessionDataTask?

    private let defaultReadingList: [ReadingListEntry] = [
        .init(title: "MacBook Pro - Apple", domain: "apple.com", url: URL(string: "https://www.apple.com/macbook-pro/")!),
        .init(title: "GitHub — Build and ship software", domain: "github.com", url: URL(string: "https://github.com/")!),
        .init(title: "WebKit — Open Source Browser Engine", domain: "webkit.org", url: URL(string: "https://webkit.org/")!)
    ]

    deinit {
        transitionToken += 1
        googleSuggestWorkItem?.cancel()
        googleSuggestTask?.cancel()
        removeDismissMonitors()
        if let p = panel {
            glassBackground?.layer?.removeAllAnimations()
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
    }

    func show(
        below field: NSView,
        in parentWindow: NSWindow,
        query: String,
        isDark: Bool,
        isPrivate: Bool = false,
        recentGroups: [RecentGroup],
        openTabs: [OpenTabInfo],
        activeDomain: String
    ) {
        self.anchorField = field
        self.hostWindow = parentWindow
        self.currentQuery = query
        self.currentIsDark = isDark
        self.currentIsPrivate = isPrivate
        self.recentGroups = recentGroups
        self.openTabs = openTabs
        self.activeDomain = activeDomain

        transitionToken += 1
        let token = transitionToken
        let wasHiddenOrClosing = (panel == nil) || (panel?.parent == nil) || isClosing
        isClosing = false

        ensurePanel()
        rebuildContent()
        let targetFrame = repositionPanel(applyFrame: !wasHiddenOrClosing)
        scheduleGoogleSuggestionsFetchIfNeeded()

        if let sv = scrollView {
            sv.contentView.scroll(to: .zero)
            sv.reflectScrolledClipView(sv.contentView)
        }
        installDismissMonitors(parentWindow: parentWindow)

        guard let panel else { return }
        applyBackdropAppearanceImmediately()
        glassBackground?.layer?.removeAnimation(forKey: "popoverScale")
        glassBackground?.layer?.transform = CATransform3DIdentity
        if wasHiddenOrClosing, let targetFrame {
            let startFrame = targetFrame.offsetBy(dx: 0, dy: 10)
            panel.alphaValue = 0.0
            panel.setFrame(startFrame, display: false)
            if panel.parent == nil {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.transitionToken == token, !self.isClosing else { return }
                if let layer = self.glassBackground?.layer {
                    let cx = layer.bounds.midX
                    let topY = layer.bounds.height
                    var startT = CATransform3DIdentity
                    startT = CATransform3DTranslate(startT, cx, topY, 0)
                    startT = CATransform3DScale(startT, 0.96, 0.96, 1.0)
                    startT = CATransform3DTranslate(startT, -cx, -topY, 0)
                    let anim = CABasicAnimation(keyPath: "transform")
                    anim.fromValue = NSValue(caTransform3D: startT)
                    anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                    anim.duration = 0.22
                    anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    layer.transform = CATransform3DIdentity
                    layer.add(anim, forKey: "popoverScale")
                }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    ctx.allowsImplicitAnimation = true
                    panel.animator().alphaValue = 1.0
                    panel.animator().setFrame(targetFrame, display: false)
                }
            }
        } else {
            if panel.parent == nil {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            panel.alphaValue = 1.0
            panel.orderFront(nil)
        }
    }

    func update(
        query: String,
        isDark: Bool,
        isPrivate: Bool = false,
        recentGroups: [RecentGroup],
        openTabs: [OpenTabInfo],
        activeDomain: String
    ) {
        let queryChanged = (self.currentQuery != query)
        self.currentQuery = query
        self.currentIsDark = isDark
        self.currentIsPrivate = isPrivate
        self.recentGroups = recentGroups
        self.openTabs = openTabs
        self.activeDomain = activeDomain
        if queryChanged {
            selectedIndex = 0
        }
        guard panel != nil else { return }
        applyBackdropAppearanceImmediately()
        rebuildContent()
        repositionPanel()
        if queryChanged {
            scheduleGoogleSuggestionsFetchIfNeeded()
        }
    }

    func applyTheme(isDark: Bool) {
        let changed = (currentIsDark != isDark)
        currentIsDark = isDark
        // Always update the cached panel + glass backdrop immediately (even while hidden!)
        // so opening the popover after switching light/dark pages never lags or flashes the old color.
        applyBackdropAppearanceImmediately()
        guard isShown else { return }
        if changed {
            rebuildContent()
        }
        repositionPanel()
    }

    private func applyBackdropAppearanceImmediately() {
        guard let panel else { return }
        let isDark = currentIsDark
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.0
            ctx.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.appearance = appearance
            if #available(macOS 26.0, *),
               let lightGV = lightGlassBackground as? NSGlassEffectView,
               let darkGV = darkGlassBackground as? NSGlassEffectView,
               let wrapper = glassContentWrapper {
                // Swap between two immutable NSGlassEffectView instances so WindowServer NEVER runs
                // its slow (~0.6s) built-in appearance/tintColor material crossfade.
                let targetGV = isDark ? darkGV : lightGV
                let otherGV = isDark ? lightGV : darkGV
                if glassBackground !== targetGV {
                    let bounds = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 540)
                    otherGV.contentView = nil
                    targetGV.frame = bounds
                    wrapper.frame = bounds
                    targetGV.contentView = wrapper
                    panel.contentView = targetGV
                    glassBackground = targetGV
                }
            } else if let vev = glassBackground as? NSVisualEffectView {
                vev.appearance = appearance
                vev.state = .active
                vev.layer?.borderColor = (isDark
                    ? NSColor.white.withAlphaComponent(0.20)
                    : NSColor.black.withAlphaComponent(0.08)).cgColor
            }
            if let tintView = tintOverlayView {
                tintView.layer?.backgroundColor = (isDark
                    ? NSColor(srgbRed: 0.19, green: 0.19, blue: 0.21, alpha: 0.34)
                    : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.62)).cgColor
            }
            if let sv = scrollView {
                sv.wantsLayer = true
                sv.layer?.backgroundColor = NSColor.clear.cgColor
            }
            if let container = contentContainer {
                container.wantsLayer = true
                container.layer?.backgroundColor = NSColor.clear.cgColor
            }
            CATransaction.commit()
        }
    }

    func repositionIfShown() {
        guard isShown else { return }
        repositionPanel()
    }

    func close(animated: Bool = true) {
        googleSuggestWorkItem?.cancel()
        googleSuggestWorkItem = nil
        googleSuggestTask?.cancel()
        googleSuggestTask = nil
        removeDismissMonitors()
        selectedIndex = -1
        isFavoritesManuallyExpanded = false
        guard let panel else { return }
        transitionToken += 1
        let token = transitionToken

        if !animated || !panel.isVisible {
            isClosing = false
            glassBackground?.layer?.removeAnimation(forKey: "popoverScale")
            glassBackground?.layer?.transform = CATransform3DIdentity
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.alphaValue = 1.0
            return
        }

        guard !isClosing else { return }
        isClosing = true
        // Detach from parent window immediately so closing the parent window or quitting the app
        // can never race with a child-window teardown while the fade-out animation is in flight.
        panel.parent?.removeChildWindow(panel)
        let endFrame = panel.frame.offsetBy(dx: 0, dy: 8)
        if let layer = glassBackground?.layer {
            let cx = layer.bounds.midX
            let topY = layer.bounds.height
            var endT = CATransform3DIdentity
            endT = CATransform3DTranslate(endT, cx, topY, 0)
            endT = CATransform3DScale(endT, 0.96, 0.96, 1.0)
            endT = CATransform3DTranslate(endT, -cx, -topY, 0)
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            anim.toValue = NSValue(caTransform3D: endT)
            anim.duration = 0.16
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
            layer.transform = endT
            layer.add(anim, forKey: "popoverScale")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0.0
            panel.animator().setFrame(endFrame, display: false)
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel, self.transitionToken == token else { return }
            self.isClosing = false
            self.glassBackground?.layer?.removeAnimation(forKey: "popoverScale")
            self.glassBackground?.layer?.transform = CATransform3DIdentity
            if panel.parent == nil { panel.orderOut(nil) }
            panel.alphaValue = 1.0
        })
    }

    func moveSelection(delta: Int) {
        guard isShown, !suggestions.isEmpty else { return }
        guard let next = Self.nextSelectionIndex(current: selectedIndex, delta: delta, count: suggestions.count) else { return }
        updateSelectionHighlight(to: next)
    }

    private func updateSelectionHighlight(to index: Int, scrollIntoView: Bool = true) {
        guard index >= 0 && index < autocompleteRowViews.count else { return }
        guard selectedIndex != index else { return }
        if selectedIndex >= 0 && selectedIndex < autocompleteRowViews.count {
            autocompleteRowViews[selectedIndex].setSelected(false)
        }
        selectedIndex = index
        let row = autocompleteRowViews[index]
        row.setSelected(true)
        if scrollIntoView {
            contentContainer?.scrollToVisible(row.frame.insetBy(dx: 0, dy: -6))
        }
    }

    @discardableResult
    func commitSelectedSuggestionIfAny() -> Bool {
        guard isShown, selectedIndex >= 0, selectedIndex < suggestions.count else { return false }
        trigger(suggestions[selectedIndex])
        return true
    }

    private func trigger(_ item: SuggestionItem, openInNewTab: Bool = false) {
        let activeQuery = currentQuery
        let isPrivate = currentIsPrivate
        close()
        switch item.kind {
        case .url(let url):
            SuggestionUsageStore.shared.recordURLSelection(
                query: activeQuery,
                url: url,
                title: item.title,
                isPrivate: isPrivate
            )
            if openInNewTab, let onOpenInNewTab {
                onOpenInNewTab(url)
            } else {
                onSelectURL?(url)
            }
        case .search(let q):
            SuggestionUsageStore.shared.recordSearchSelection(
                query: activeQuery,
                searchQuery: q,
                isPrivate: isPrivate
            )
            onSelectSearch?(q)
        case .switchToTab(let id):
            if let tab = openTabs.first(where: { $0.id == id }), !tab.isStartPage {
                SuggestionUsageStore.shared.recordURLSelection(
                    query: activeQuery,
                    url: tab.url,
                    title: tab.title,
                    isPrivate: isPrivate
                )
            }
            onSwitchToTab?(id)
        }
    }

    // MARK: - Dismiss Monitors (Safarium 1:1)

    private func installDismissMonitors(parentWindow: NSWindow) {
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let panel = self.panel, panel.isVisible else { return event }
                if event.window === panel { return event }
                if let anchor = self.anchorField, let hostWin = self.hostWindow, event.window === hostWin {
                    let ptInAnchor = anchor.convert(event.locationInWindow, from: nil)
                    if anchor.bounds.contains(ptInAnchor) { return event }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onDismissRequested?()
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.onDismissRequested?()
                }
            }
        }
        if resignKeyObserver == nil {
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.onDismissRequested?()
            }
        }
    }

    private func removeDismissMonitors() {
        if let m = localMouseMonitor {
            NSEvent.removeMonitor(m)
            localMouseMonitor = nil
        }
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            resignKeyObserver = nil
        }
    }

    // MARK: - Floating Liquid Glass NSPanel (Safarium 1:1)

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.animationBehavior = .none

        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 540))
        sv.autoresizingMask = [.width, .height]
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.wantsLayer = true

        let container = PopoverFlippedContainer(frame: NSRect(x: 0, y: 0, width: 620, height: 540))
        container.autoresizingMask = [.width]
        sv.documentView = container

        // Native macOS 27 Liquid Glass panel (spacious, luminous Safari Tahoe popover).
        // Keep immutable light & dark NSGlassEffectView instances so light<->dark swaps are instant (0ms).
        if #available(macOS 26.0, *) {
            let frameRect = NSRect(x: 0, y: 0, width: 620, height: 540)
            let lightGV = NSGlassEffectView(frame: frameRect)
            lightGV.style = .regular
            lightGV.cornerRadius = 22.0
            lightGV.appearance = NSAppearance(named: .aqua)
            lightGV.tintColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.84)
            lightGV.autoresizingMask = [.width, .height]

            let darkGV = NSGlassEffectView(frame: frameRect)
            darkGV.style = .regular
            darkGV.cornerRadius = 22.0
            darkGV.appearance = NSAppearance(named: .darkAqua)
            darkGV.tintColor = NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.56)
            darkGV.autoresizingMask = [.width, .height]

            let contentWrapper = NSView(frame: frameRect)
            contentWrapper.autoresizingMask = [.width, .height]
            contentWrapper.wantsLayer = true
            contentWrapper.layer?.cornerRadius = 22.0
            contentWrapper.layer?.cornerCurve = .continuous
            contentWrapper.layer?.masksToBounds = true

            let tintView = NSView(frame: frameRect)
            tintView.wantsLayer = true
            tintView.autoresizingMask = [.width, .height]
            contentWrapper.addSubview(tintView)
            contentWrapper.addSubview(sv)

            let initialGV = currentIsDark ? darkGV : lightGV
            initialGV.contentView = contentWrapper
            p.contentView = initialGV
            self.panel = p
            self.lightGlassBackground = lightGV
            self.darkGlassBackground = darkGV
            self.glassContentWrapper = contentWrapper
            self.glassBackground = initialGV
            self.tintOverlayView = tintView
            self.scrollView = sv
            self.contentContainer = container
        } else {
            let vev = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 620, height: 540))
            vev.material = .popover
            vev.blendingMode = .behindWindow
            vev.state = .active
            vev.maskImage = Self.makePopoverMaskImage(cornerRadius: 22.0)
            vev.wantsLayer = true
            vev.layer?.cornerRadius = 22.0
            vev.layer?.cornerCurve = .continuous
            vev.layer?.masksToBounds = true
            vev.layer?.borderWidth = 0.5
            vev.autoresizingMask = [.width, .height]

            let tintView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 540))
            tintView.wantsLayer = true
            tintView.autoresizingMask = [.width, .height]
            vev.addSubview(tintView)
            vev.addSubview(sv)

            p.contentView = vev
            self.panel = p
            self.glassBackground = vev
            self.tintOverlayView = tintView
            self.scrollView = sv
            self.contentContainer = container
        }
    }

    static func popoverWidth(hostWindowWidth: CGFloat?) -> CGFloat {
        let maxW = max(480, (hostWindowWidth ?? 1280) - 24)
        return min(620, maxW)
    }

    private func startPopoverWidth() -> CGFloat {
        Self.popoverWidth(hostWindowWidth: hostWindow?.frame.width)
    }

    /// Index after moving the selection by `delta` (same arithmetic as `moveSelection(delta:)`).
    static func nextSelectionIndex(current: Int, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        if current < 0 {
            return delta > 0 ? 0 : (count - 1)
        }
        return (((current + delta) % count) + count) % count
    }

    /// Stores parsed Google suggestions; the cache is cleared once it holds 100 keys.
    static func storeSuggestions(_ parsed: [String], forKey key: String, in cache: inout [String: [String]]) {
        if cache.count >= 100 { cache.removeAll(keepingCapacity: true) }
        cache[key] = parsed
    }

    static func aspectFillRect(for size: NSSize, in rect: NSRect) -> NSRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let dw = size.width * scale
        let dh = size.height * scale
        return NSRect(x: rect.midX - dw * 0.5, y: rect.midY - dh * 0.5, width: dw, height: dh)
    }

    static func aspectFitRect(for size: NSSize, in rect: NSRect) -> NSRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let dw = size.width * scale
        let dh = size.height * scale
        return NSRect(x: rect.midX - dw * 0.5, y: rect.midY - dh * 0.5, width: dw, height: dh)
    }

    func isStartPopoverMode() -> Bool {
        let trimmed = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return trimmed.isEmpty || lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    @discardableResult
    private func repositionPanel(applyFrame: Bool = true) -> NSRect? {
        guard let panel, let field = anchorField, let win = hostWindow else { return nil }
        if field.bounds.width < 10 {
            win.contentView?.layoutSubtreeIfNeeded()
        }
        let fieldRectInWin = field.convert(field.bounds, to: nil)
        let fieldRectOnScreen = win.convertToScreen(fieldRectInWin)

        let isStartPopover = isStartPopoverMode()
        let panelW = isStartPopover ? startPopoverWidth() : max(540, min(640, max(580, fieldRectOnScreen.width + 44)))
        let contentH = contentContainer?.preferredHeight ?? 280
        let maxH = isStartPopover
            ? min(560, max(300, win.frame.height - 84))
            : min(520, max(240, win.frame.height - 88))
        let panelH = min(contentH, maxH)

        let rawX = round(fieldRectOnScreen.midX - panelW * 0.5)
        let minX = win.frame.minX + 12
        let maxX = max(minX, win.frame.maxX - panelW - 12)
        let x = min(maxX, max(minX, rawX))
        let y = round(fieldRectOnScreen.minY - panelH - 6)
        let targetFrame = NSRect(x: x, y: y, width: panelW, height: panelH)

        applyBackdropAppearanceImmediately()
        if applyFrame {
            panel.setFrame(targetFrame, display: true)
            panel.invalidateShadow()
        }
        if let container = contentContainer {
            container.frame = NSRect(x: 0, y: 0, width: panelW, height: max(panelH, contentH))
        }
        return targetFrame
    }

    private static func makePopoverMaskImage(cornerRadius r: CGFloat) -> NSImage {
        let edge = 2.0 * r + 2.0
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    // MARK: - Content Builder (Exact Safarium 1:1 Geometry & Typography)

    private func rebuildContent() {
        guard let container = contentContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        let isDark = currentIsDark
        let trimmed = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let startMode = isStartPopoverMode()
        let width = startMode ? startPopoverWidth() : max(540, min(640, max(580, (anchorField?.bounds.width ?? 520) + 44)))
        autocompleteRowViews.removeAll()

        if startMode {
            // Exact Safarium Start Page Popover: Interactive Reorderable Favorites 6x2 Squircle Grid
            // (with live drag reflow & auto-expand matching Start Page) + Recently Viewed + Reading List
            suggestions = []
            selectedIndex = -1
            popoverFavoritesGrid = nil
            popoverShowAllButton = nil
            belowFavoritesContainer = nil

            let sidePad: CGFloat = 38
            let contentW = width - sidePad * 2
            var y: CGFloat = 30
            container.addSubview(makeStartPopoverHeader("Favorites", isDark: isDark, x: sidePad, y: y, width: contentW - 96))

            let allFavs = AssetLoader.shared.favorites()
            let showAllBtn = NSButton(frame: NSRect(x: sidePad + contentW - 88, y: y + 2, width: 88, height: 22))
            showAllBtn.isBordered = false
            showAllBtn.imagePosition = .imageTrailing
            showAllBtn.alignment = .right
            showAllBtn.target = self
            showAllBtn.action = #selector(toggleShowAllFavoritesClicked)
            showAllBtn.isHidden = allFavs.count <= PopoverFavoritesReorderGridView.collapsedMaxCount
            container.addSubview(showAllBtn)
            popoverShowAllButton = showAllBtn
            updateShowAllButtonStyle(isDark: isDark)
            y += 40

            favoritesGridTopY = y
            let btnExtraW: CGFloat = 10
            let grid = PopoverFavoritesReorderGridView(
                origin: NSPoint(x: sidePad - btnExtraW * 0.5, y: y),
                contentWidth: contentW,
                btnExtraW: btnExtraW,
                isDark: isDark
            )
            grid.hostWindowProvider = { [weak self] in self?.hostWindow }
            grid.configure(entries: allFavs, expanded: isFavoritesManuallyExpanded)
            grid.onSelectURL = { [weak self] url in
                self?.close()
                self?.onSelectURL?(url)
            }
            grid.onOpenInNewTab = { [weak self] url in
                self?.close()
                self?.onOpenInNewTab?(url)
            }
            grid.onOpenInNewWindow = { [weak self] url in
                self?.close()
                self?.onOpenInNewWindow?(url)
            }
            grid.onOpenInNewTabGroup = { [weak self] url in
                self?.close()
                self?.onOpenInNewTabGroup?(url)
            }
            grid.onReorderCommit = { [weak self] updatedEntries in
                AssetLoader.shared.saveFavoritesOrder(updatedEntries)
                guard let self else { return }
                self.popoverShowAllButton?.isHidden = updatedEntries.count <= PopoverFavoritesReorderGridView.collapsedMaxCount
                self.updateShowAllButtonStyle(isDark: self.currentIsDark)
            }
            grid.onExpandStateChanged = { [weak self] in
                guard let self else { return }
                self.updateShowAllButtonStyle(isDark: self.currentIsDark)
            }
            grid.onHeightWillChange = { [weak self] newGridH, animated in
                self?.updateBelowFavoritesLayout(gridHeight: newGridH, animated: animated)
            }
            container.addSubview(grid)
            popoverFavoritesGrid = grid

            let initialGridH = grid.frame.height
            let belowStartY = y + initialGridH + 10

            let belowBox = PopoverFlippedContainer(frame: NSRect(x: 0, y: belowStartY, width: width, height: 10))
            belowBox.wantsLayer = true
            belowBox.layer?.masksToBounds = false
            var by: CGFloat = 0

            let filteredRecent = filteredRecentlyViewedGroups()
            if !filteredRecent.isEmpty {
                belowBox.addSubview(makeStartPopoverHeader("Recently Viewed", isDark: isDark, x: sidePad, y: by, width: contentW))
                by += 38
                let cardW: CGFloat = 226
                let cardH: CGFloat = 156
                let cardGap: CGFloat = 14
                for (idx, grp) in filteredRecent.prefix(2).enumerated() {
                    let cardX = sidePad + CGFloat(idx) * (cardW + cardGap)
                    let card = PopoverRecentlyViewedCardView(
                        frame: NSRect(x: cardX, y: by, width: cardW, height: cardH),
                        domain: grp.domain,
                        urlString: grp.latestURL.absoluteString,
                        prefetchedIcon: grp.favicon,
                        timeLabel: Self.formatRelativeDay(grp.visitedAt),
                        tabCount: grp.count,
                        isDark: isDark
                    )
                    card.onClick = { [weak self] in
                        self?.close()
                        self?.onSelectURL?(grp.latestURL)
                    }
                    belowBox.addSubview(card)
                }
                by += cardH + 22
            }

            let readingListEntries: [ReadingListEntry] = AssetLoader.shared.readingList().compactMap { item in
                guard let url = URL(string: item.url) else { return nil }
                return ReadingListEntry(
                    title: item.title,
                    domain: URLInputNormalizer.displayDomain(for: url),
                    url: url
                )
            }
            let effectiveReadingList = readingListEntries.isEmpty ? defaultReadingList : readingListEntries
            if !effectiveReadingList.isEmpty {
                belowBox.addSubview(makeStartPopoverHeader("Reading List", isDark: isDark, x: sidePad, y: by, width: contentW))
                by += 38
                let rowH: CGFloat = 58
                let rowGap: CGFloat = 10
                for entry in effectiveReadingList.prefix(2) {
                    let row = PopoverReadingListRowView(
                        frame: NSRect(x: sidePad, y: by, width: contentW, height: rowH),
                        entry: entry,
                        isDark: isDark
                    )
                    row.onClick = { [weak self] in
                        self?.close()
                        self?.onSelectURL?(entry.url)
                    }
                    belowBox.addSubview(row)
                    by += rowH + rowGap
                }
                by += 14
            } else {
                by += 10
            }

            belowBox.frame.size.height = by
            belowFavoritesHeight = by
            container.addSubview(belowBox, positioned: .below, relativeTo: grid)
            belowFavoritesContainer = belowBox

            container.preferredHeight = belowStartY + by
        } else {
            // Native macOS 27 Tahoe Safari Query Popover:
            // Direct Top Hit card at top (no header), then Switch to Tab, Google Suggestions, Bookmarks and History
            buildQuerySuggestions(query: trimmed)
            if selectedIndex >= suggestions.count { selectedIndex = 0 }
            if selectedIndex < 0 && !suggestions.isEmpty { selectedIndex = 0 }

            let activeEngine = BrowserSettings.shared.effectiveSearchEngine(isPrivate: currentIsPrivate)
            let searchSectionTitle = "\(activeEngine.displayName) Suggestions"
            var y: CGFloat = 10
            var currentSection = ""
            for (idx, item) in suggestions.enumerated() {
                let sectionName: String
                switch item.style {
                case .topHit: sectionName = ""
                case .switchToTab: sectionName = "Switch to Tab"
                case .googleSuggestion: sectionName = searchSectionTitle
                case .bookmarkOrHistory: sectionName = "Bookmarks and History"
                }

                if !sectionName.isEmpty && sectionName != currentSection {
                    if idx > 0 {
                        y += 10
                    }
                    container.addSubview(makeSectionHeader(sectionName, isDark: isDark, x: 18, y: y, width: width - 36))
                    y += 20
                    currentSection = sectionName
                }

                let rowH: CGFloat
                switch item.style {
                case .topHit: rowH = item.subtitle.isEmpty ? 36 : 48
                case .switchToTab: rowH = 44
                case .googleSuggestion: rowH = 28
                case .bookmarkOrHistory: rowH = 44
                }

                let rowView = PopoverAutocompleteRowView(
                    frame: NSRect(x: 10, y: y, width: width - 20, height: rowH),
                    item: item,
                    query: trimmed,
                    isSelected: idx == selectedIndex,
                    isDark: isDark
                )
                rowView.onClick = { [weak self] in self?.trigger(item, openInNewTab: false) }
                rowView.onCommandClick = { [weak self] in self?.trigger(item, openInNewTab: true) }
                rowView.onHover = { [weak self] in self?.updateSelectionHighlight(to: idx, scrollIntoView: false) }
                container.addSubview(rowView)
                autocompleteRowViews.append(rowView)
                y += rowH + (item.style == .googleSuggestion ? 1 : 2)
            }
            container.preferredHeight = y + 8
        }
    }

    func filteredRecentlyViewedGroups() -> [RecentGroup] {
        let valid = recentGroups.filter {
            ($0.latestURL.scheme == "http" || $0.latestURL.scheme == "https") &&
            $0.title.lowercased() != "about:blank"
        }
        if activeDomain.isEmpty { return valid }
        let filtered = valid.filter { $0.domain.lowercased() != activeDomain.lowercased() }
        return filtered.isEmpty ? valid : filtered
    }

    private func scheduleGoogleSuggestionsFetchIfNeeded() {
        googleSuggestWorkItem?.cancel()
        googleSuggestWorkItem = nil
        googleSuggestTask?.cancel()
        googleSuggestTask = nil

        // Never send typed queries to external search engines in Private Browsing or when disabled in Settings.
        guard !currentIsPrivate, BrowserSettings.shared.includeSearchSuggestions else { return }

        let trimmed = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStartPopoverMode() else { return }
        let engine = BrowserSettings.shared.effectiveSearchEngine(isPrivate: currentIsPrivate)
        let cacheKey = "\(engine.rawValue)::\(trimmed.lowercased())"
        if googleSuggestCache[cacheKey] != nil { return }

        let work = DispatchWorkItem { [weak self] in
            self?.fetchGoogleSuggestions(for: trimmed, engine: engine, cacheKey: cacheKey)
        }
        googleSuggestWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: work)
    }

    private func fetchGoogleSuggestions(for query: String, engine: BrowserSettings.SearchEngine, cacheKey: String) {
        guard let url = engine.suggestURL(for: query) else { return }
        let expectedLower = query.lowercased()

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3.0)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let rawSuggestions = json[1] as? [Any] else { return }
            let parsed: [String] = rawSuggestions.compactMap { entry in
                if let s = entry as? String { return s }
                if let arr = entry as? [Any], let first = arr.first as? String { return first }
                return nil
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            DispatchQueue.main.async {
                guard let self else { return }
                Self.storeSuggestions(parsed, forKey: cacheKey, in: &self.googleSuggestCache)
                let liveQuery = self.currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard self.isShown, liveQuery == expectedLower else { return }
                self.rebuildContent()
                self.repositionPanel()
            }
        }
        googleSuggestTask = task
        task.resume()
    }

    func normalizedURLKey(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        // Distinct ports (dev server vs production) and distinct queries (?id=1 vs ?id=2) are different destinations.
        let defaultPort: Int? = { switch url.scheme?.lowercased() { case "http": return 80; case "https": return 443; default: return nil } }()
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        let query = url.query.flatMap { $0.isEmpty ? nil : "?\($0)" } ?? ""
        return "\(host)\(port)/\(path)\(query)"
    }

    /// Formats a clean human-readable URL without scheme, leading `www.`, or trailing slash.
    /// Root URLs return the bare domain (e.g. `github.com`); deep URLs include their path (`github.com/apple/swift`).
    static func cleanDisplayURL(for url: URL) -> String {
        let domain = URLInputNormalizer.displayDomain(for: url)
        guard !domain.isEmpty else { return url.absoluteString }
        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.isEmpty {
            return domain
        }
        return "\(domain)/\(trimmedPath)"
    }

    private struct URLCandidate {
        let urlKey: String
        let url: URL
        let domain: String
        let displayURL: String
        var title: String
        var visitCount: Int
        var lastVisited: Date?
        var isBookmarked: Bool
        var isOpenTab: Bool
        var favicon: NSImage?
        let orderIndex: Int
    }

    private struct MatchEvaluation {
        let matchScore: Double
        let isPrefixOrStrongTopHit: Bool
    }

    private static func evaluateMatch(
        queryLower: String,
        tokens: [String],
        domainLower: String,
        displayURLLower: String,
        fullURLLower: String,
        titleLower: String
    ) -> MatchEvaluation? {
        guard !tokens.isEmpty else { return nil }

        if tokens.count == 1 {
            let q = queryLower
            let domainNoTLD = domainLower.split(separator: ".").first.map(String.init) ?? domainLower

            if domainLower == q || domainNoTLD == q {
                return MatchEvaluation(matchScore: 1000, isPrefixOrStrongTopHit: true)
            }
            if domainLower.hasPrefix(q) {
                return MatchEvaluation(matchScore: 760, isPrefixOrStrongTopHit: true)
            }
            // Subdomain label prefix (e.g. typing `mail` matches `mail.google.com`, `docs` matches `docs.swift.org`)
            let hostLabels = domainLower.split(separator: ".")
            if hostLabels.dropFirst().contains(where: { $0.hasPrefix(q) }) {
                return MatchEvaluation(matchScore: 640, isPrefixOrStrongTopHit: true)
            }
            if displayURLLower.hasPrefix(q) {
                return MatchEvaluation(matchScore: 700, isPrefixOrStrongTopHit: true)
            }
            if titleLower.hasPrefix(q) {
                return MatchEvaluation(matchScore: 560, isPrefixOrStrongTopHit: true)
            }
            // Word-boundary match in title (e.g. `overflow` in `Stack Overflow`)
            let titleWords = titleLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if titleWords.contains(where: { $0.hasPrefix(q) }) {
                return MatchEvaluation(matchScore: 420, isPrefixOrStrongTopHit: false)
            }
            if domainLower.contains(q) || displayURLLower.contains(q) || fullURLLower.contains(q) {
                return MatchEvaluation(matchScore: 320, isPrefixOrStrongTopHit: false)
            }
            if titleLower.contains(q) {
                return MatchEvaluation(matchScore: 240, isPrefixOrStrongTopHit: false)
            }
            return nil
        }

        // Multi-token intuitive matching: every whitespace-separated token must match domain, URL, or title.
        var totalScore: Double = 0
        var hasDomainPrefix = false
        let titleWords = titleLower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for token in tokens {
            if domainLower.hasPrefix(token) {
                totalScore += 220
                hasDomainPrefix = true
            } else if domainLower.contains(token) {
                totalScore += 160
            } else if displayURLLower.contains(token) || fullURLLower.contains(token) {
                totalScore += 130
            } else if titleLower.hasPrefix(token) || titleWords.contains(where: { $0.hasPrefix(token) }) {
                totalScore += 140
            } else if titleLower.contains(token) {
                totalScore += 95
            } else {
                return nil
            }
        }
        return MatchEvaluation(matchScore: totalScore, isPrefixOrStrongTopHit: hasDomainPrefix)
    }

    private static func scoreCandidate(
        _ candidate: URLCandidate,
        match: MatchEvaluation,
        domainVisitCount: Int,
        learnedBoost: SuggestionUsageStore.LearnedBoost,
        now: Date
    ) -> Double {
        var score = match.matchScore + learnedBoost.totalScore

        // Prioritize visit frequency strictly over bookmarks:
        // Any visited history item (especially repeated visits) easily outranks an unvisited bookmark,
        // and higher visit counts always dominate over lower-frequency bookmarked entries.
        if candidate.visitCount > 0 {
            score += 240.0 + log2(Double(candidate.visitCount) + 1.0) * 190.0
        }
        if domainVisitCount > 0 {
            score += log2(Double(domainVisitCount) + 1.0) * 65.0
        }

        // Gentle recency boost so recently-used frequent sites feel fresh without overriding high visit frequency.
        if let visitedAt = candidate.lastVisited {
            let age = max(0, now.timeIntervalSince(visitedAt))
            if age < 3_600 {
                score += 90.0
            } else if age < 86_400 {
                score += 70.0
            } else if age < 7 * 86_400 {
                score += 45.0
            } else if age < 30 * 86_400 {
                score += 20.0
            } else {
                score += 5.0
            }
        }

        // Prefer root/homepage URL when the path is empty so typing `git` surfaces `github.com` cleanly
        // unless a specific deep URL has significantly higher visit frequency.
        let pathTrimmed = candidate.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if pathTrimmed.isEmpty && candidate.url.query == nil {
            score += 65.0
        }

        // Bookmarks get a modest baseline when unvisited (so they still surface when no frequent history matches),
        // and only a tiny tie-breaker when already visited — ensuring frequency always wins over bookmarks.
        if candidate.isBookmarked {
            score += candidate.visitCount > 0 ? 30.0 : 110.0
        }

        // Open tabs matching the query get a helpful boost (e.g., over unvisited bookmarks).
        if candidate.isOpenTab {
            score += 450.0
        }

        return score
    }

    func buildQuerySuggestions(query: String) {
        let q = query.lowercased()
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var list: [SuggestionItem] = []
        let allFavs = AssetLoader.shared.favorites()
        let history = currentIsPrivate ? [] : AssetLoader.shared.browsingHistory()
        let now = Date()

        // Collect live icons by normalized host from open tabs and recent groups so every URL item
        // on a known host gets a crisp favicon immediately without waiting on network fetches.
        var liveIconsByHost: [String: NSImage] = [:]
        for tab in openTabs where !tab.isStartPage {
            if let icon = tab.favicon, let host = FaviconCache.shared.normalizedHost(for: tab.url.absoluteString) {
                liveIconsByHost[host] = icon
            }
        }
        for grp in recentGroups where !currentIsPrivate {
            if let icon = grp.favicon, let host = FaviconCache.shared.normalizedHost(for: grp.latestURL.absoluteString), liveIconsByHost[host] == nil {
                liveIconsByHost[host] = icon
            }
        }

        func resolvedFavicon(for url: URL, explicit: NSImage?) -> NSImage? {
            if let explicit { return explicit }
            if let host = FaviconCache.shared.normalizedHost(for: url.absoluteString), let live = liveIconsByHost[host] {
                return live
            }
            return FaviconCache.shared.bestCachedIcon(forURLString: url.absoluteString)
        }

        // Aggregate total visits per domain across browsing history + recent groups (skipped in Private mode).
        var domainVisitTotals: [String: Int] = [:]
        if !currentIsPrivate {
            for hist in history {
                guard let url = URL(string: hist.url) else { continue }
                let domKey = URLInputNormalizer.displayDomain(for: url).lowercased()
                domainVisitTotals[domKey, default: 0] += max(1, hist.visitCount)
            }
            for grp in recentGroups {
                let domKey = grp.domain.lowercased()
                domainVisitTotals[domKey] = max(domainVisitTotals[domKey] ?? 0, max(1, grp.count))
            }
        }

        // Build unified, deduplicated URL candidate pool.
        var candidatesByKey: [String: URLCandidate] = [:]
        var nextOrder = 0

        func upsertCandidate(
            url: URL,
            title: String,
            visitCount: Int,
            lastVisited: Date?,
            isBookmarked: Bool,
            isOpenTab: Bool,
            favicon: NSImage?
        ) {
            let key = normalizedURLKey(url)
            guard !key.isEmpty else { return }
            let domain = URLInputNormalizer.displayDomain(for: url)
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if var existing = candidatesByKey[key] {
                if existing.title.isEmpty && !cleanTitle.isEmpty {
                    existing.title = cleanTitle
                }
                existing.visitCount = max(existing.visitCount, visitCount)
                if let lv = lastVisited {
                    if let cur = existing.lastVisited {
                        existing.lastVisited = max(cur, lv)
                    } else {
                        existing.lastVisited = lv
                    }
                }
                existing.isBookmarked = existing.isBookmarked || isBookmarked
                existing.isOpenTab = existing.isOpenTab || isOpenTab
                if existing.favicon == nil, let fav = favicon {
                    existing.favicon = fav
                }
                candidatesByKey[key] = existing
            } else {
                let candidate = URLCandidate(
                    urlKey: key,
                    url: url,
                    domain: domain,
                    displayURL: Self.cleanDisplayURL(for: url),
                    title: cleanTitle,
                    visitCount: visitCount,
                    lastVisited: lastVisited,
                    isBookmarked: isBookmarked,
                    isOpenTab: isOpenTab,
                    favicon: favicon,
                    orderIndex: nextOrder
                )
                nextOrder += 1
                candidatesByKey[key] = candidate
            }
        }

        // Ingest browsing history first (with real visitCount & lastVisited; never in Private mode).
        for hist in history {
            guard let url = URL(string: hist.url) else { continue }
            upsertCandidate(
                url: url,
                title: hist.title,
                visitCount: max(1, hist.visitCount),
                lastVisited: hist.lastVisited,
                isBookmarked: false,
                isOpenTab: false,
                favicon: nil
            )
        }

        // Ingest recent groups (skipped in Private mode).
        for grp in recentGroups where !currentIsPrivate {
            upsertCandidate(
                url: grp.latestURL,
                title: grp.title,
                visitCount: max(1, grp.count),
                lastVisited: grp.visitedAt,
                isBookmarked: false,
                isOpenTab: false,
                favicon: grp.favicon
            )
        }

        // Ingest open non-Start-Page tabs.
        for tab in openTabs where !tab.isStartPage {
            upsertCandidate(
                url: tab.url,
                title: tab.title,
                visitCount: 0,
                lastVisited: nil,
                isBookmarked: false,
                isOpenTab: true,
                favicon: tab.favicon
            )
        }

        // Ingest Favorites / Bookmarks (merged cleanly with history if already visited; unvisited get visitCount = 0).
        for fav in allFavs {
            guard let url = URL(string: fav.url) else { continue }
            upsertCandidate(
                url: url,
                title: fav.title,
                visitCount: 0,
                lastVisited: nil,
                isBookmarked: true,
                isOpenTab: false,
                favicon: nil
            )
        }

        // Ingest previously chosen URLs for this prefix from adaptive usage store (skipped in Private mode).
        if !currentIsPrivate {
            for learned in SuggestionUsageStore.shared.learnedURLCandidates(forQuery: q, now: now) {
                upsertCandidate(
                    url: learned.url,
                    title: learned.title,
                    visitCount: learned.count,
                    lastVisited: learned.lastSelected,
                    isBookmarked: false,
                    isOpenTab: false,
                    favicon: nil
                )
            }
        }

        // Score all matching candidates with dynamic usage-learning boost.
        var scoredMatches: [(candidate: URLCandidate, eval: MatchEvaluation, score: Double, learnedTopHit: Bool)] = []
        for candidate in candidatesByKey.values {
            let learned = currentIsPrivate
                ? SuggestionUsageStore.LearnedBoost(totalScore: 0, hasStrongPrefixMatch: false)
                : SuggestionUsageStore.shared.learnedBoost(
                    forQuery: q,
                    urlKey: candidate.urlKey,
                    domain: candidate.domain,
                    now: now
                )
            let eval: MatchEvaluation
            if let directEval = Self.evaluateMatch(
                queryLower: q,
                tokens: tokens,
                domainLower: candidate.domain.lowercased(),
                displayURLLower: candidate.displayURL.lowercased(),
                fullURLLower: candidate.url.absoluteString.lowercased(),
                titleLower: candidate.title.lowercased()
            ) {
                eval = directEval
            } else if learned.hasStrongPrefixMatch {
                // Allow learned shorthand prefixes (e.g. typing "gh" -> github.com) to surface dynamically.
                eval = MatchEvaluation(matchScore: 700.0, isPrefixOrStrongTopHit: true)
            } else {
                continue
            }
            let domVisits = domainVisitTotals[candidate.domain.lowercased()] ?? 0
            let score = Self.scoreCandidate(
                candidate,
                match: eval,
                domainVisitCount: domVisits,
                learnedBoost: learned,
                now: now
            )
            scoredMatches.append((candidate, eval, score, learned.hasStrongPrefixMatch))
        }

        scoredMatches.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.001 {
                return lhs.score > rhs.score
            }
            if lhs.candidate.visitCount != rhs.candidate.visitCount {
                return lhs.candidate.visitCount > rhs.candidate.visitCount
            }
            return lhs.candidate.orderIndex < rhs.candidate.orderIndex
        }

        // 1. Direct Top Hit card (no section header — matches macOS 27 Tahoe Safari)
        var topHitURLKey: String? = nil
        if let bestTop = scoredMatches.first(where: { $0.eval.isPrefixOrStrongTopHit || $0.learnedTopHit }) {
            let c = bestTop.candidate
            topHitURLKey = c.urlKey
            let topSubtitle: String
            if c.isOpenTab && !c.isBookmarked && c.visitCount == 0 {
                topSubtitle = c.displayURL
            } else if c.title.isEmpty || c.title.lowercased() == c.domain.lowercased() {
                topSubtitle = c.displayURL
            } else {
                topSubtitle = c.title
            }
            list.append(SuggestionItem(
                title: c.domain.isEmpty ? c.title : c.domain,
                subtitle: topSubtitle,
                iconURLString: c.url.absoluteString,
                prefetchedIcon: resolvedFavicon(for: c.url, explicit: c.favicon),
                symbolName: nil,
                style: .topHit,
                kind: .url(c.url),
                isBookmarked: c.isBookmarked
            ))
        } else if !query.contains(" ") && query.contains(".") {
            let fullURL = URLInputNormalizer.normalize(query)
            let domain = URLInputNormalizer.displayDomain(for: fullURL)
            topHitURLKey = normalizedURLKey(fullURL)
            list.append(SuggestionItem(
                title: domain.isEmpty ? query : domain,
                subtitle: fullURL.absoluteString,
                iconURLString: fullURL.absoluteString,
                prefetchedIcon: resolvedFavicon(for: fullURL, explicit: nil),
                symbolName: "globe",
                style: .topHit,
                kind: .url(fullURL)
            ))
        }

        // 2. Switch to Tab (matching open tabs, two-line row with "domain • Opened Tab")
        var tabSwitchCount = 0
        for tab in openTabs where !tab.isActive && !tab.isStartPage {
            if tabSwitchCount >= 3 { break }
            let urlStr = tab.url.absoluteString
            let domain = URLInputNormalizer.displayDomain(for: tab.url)
            let displayURL = Self.cleanDisplayURL(for: tab.url)
            let matchesTab = Self.evaluateMatch(
                queryLower: q,
                tokens: tokens,
                domainLower: domain.lowercased(),
                displayURLLower: displayURL.lowercased(),
                fullURLLower: urlStr.lowercased(),
                titleLower: tab.title.lowercased()
            ) != nil
            if matchesTab {
                tabSwitchCount += 1
                let cleanTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
                list.append(SuggestionItem(
                    title: cleanTitle.isEmpty ? domain : cleanTitle,
                    subtitle: "\(domain) • Opened Tab",
                    iconURLString: urlStr,
                    prefetchedIcon: resolvedFavicon(for: tab.url, explicit: tab.favicon),
                    symbolName: nil,
                    style: .switchToTab,
                    kind: .switchToTab(tab.id)
                ))
            }
        }

        // 3. Search Suggestions (real live autocomplete from active search engine, compact single-line rows)
        var seenQueries = Set<String>()
        seenQueries.insert(q)
        list.append(SuggestionItem(
            title: query,
            subtitle: "",
            iconURLString: "",
            prefetchedIcon: nil,
            symbolName: "magnifyingglass",
            style: .googleSuggestion,
            kind: .search(query)
        ))
        let activeEngine = BrowserSettings.shared.effectiveSearchEngine(isPrivate: currentIsPrivate)
        let suggestCacheKey = "\(activeEngine.rawValue)::\(q)"
        var searchAdded = 0
        if !currentIsPrivate {
            for learnedQuery in SuggestionUsageStore.shared.learnedSearchSuggestions(forQuery: q, now: now) {
                if searchAdded >= 2 { break }
                let key = learnedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, !seenQueries.contains(key) else { continue }
                seenQueries.insert(key)
                searchAdded += 1
                list.append(SuggestionItem(
                    title: learnedQuery,
                    subtitle: "",
                    iconURLString: "",
                    prefetchedIcon: nil,
                    symbolName: "magnifyingglass",
                    style: .googleSuggestion,
                    kind: .search(learnedQuery)
                ))
            }
        }
        if !currentIsPrivate, BrowserSettings.shared.includeSearchSuggestions, let liveSuggestions = googleSuggestCache[suggestCacheKey] {
            for suggestion in liveSuggestions {
                if searchAdded >= 5 { break }
                let key = suggestion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, !seenQueries.contains(key) else { continue }
                seenQueries.insert(key)
                searchAdded += 1
                list.append(SuggestionItem(
                    title: suggestion,
                    subtitle: "",
                    iconURLString: "",
                    prefetchedIcon: nil,
                    symbolName: "magnifyingglass",
                    style: .googleSuggestion,
                    kind: .search(suggestion)
                ))
            }
        }

        // 4. Bookmarks and History (ranked by frequency first over bookmarks, deduplicated cleanly)
        var seenURLKeys = Set<String>()
        var seenTitleDomain = Set<String>()
        if let topHitURLKey { seenURLKeys.insert(topHitURLKey) }
        var bookmarkHistoryAdded = 0
        let maxBookmarksHistory = 4

        for entry in scoredMatches {
            guard bookmarkHistoryAdded < maxBookmarksHistory else { break }
            let c = entry.candidate
            // Pure open tabs (not in history or bookmarks) already appear in Top Hit / Switch to Tab.
            guard c.visitCount > 0 || c.isBookmarked else { continue }
            let resolvedTitle = c.title.isEmpty ? c.domain : c.title
            let tdKey = "\(resolvedTitle.lowercased())|\(c.domain.lowercased())"
            guard !seenURLKeys.contains(c.urlKey), !seenTitleDomain.contains(tdKey) else { continue }
            seenURLKeys.insert(c.urlKey)
            seenTitleDomain.insert(tdKey)
            bookmarkHistoryAdded += 1
            list.append(SuggestionItem(
                title: resolvedTitle,
                subtitle: c.displayURL,
                iconURLString: c.url.absoluteString,
                prefetchedIcon: resolvedFavicon(for: c.url, explicit: c.favicon),
                symbolName: nil,
                style: .bookmarkOrHistory,
                kind: .url(c.url),
                isBookmarked: c.isBookmarked
            ))
        }

        suggestions = list
    }

    static func formatRelativeDay(_ date: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 3600 { return "Just now" }
        if diff < 86400 { return "Today" }
        if diff < 172800 { return "Yesterday" }
        let days = max(2, Int(floor(diff / 86400.0)))
        return "\(days) days ago"
    }

    private func makeStartPopoverHeader(_ text: String, isDark: Bool, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: 21.5, weight: .bold)
        lbl.textColor = isDark
            ? NSColor(white: 1.0, alpha: 0.96)
            : NSColor(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 1.0)
        lbl.frame = NSRect(x: x, y: y, width: width, height: 27)
        return lbl
    }

    private func makeSectionHeader(_ text: String, isDark: Bool, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        lbl.textColor = isDark ? NSColor(white: 1.0, alpha: 0.62) : NSColor(white: 0.0, alpha: 0.52)
        lbl.frame = NSRect(x: x, y: y, width: width, height: 18)
        return lbl
    }

    private func makeHairline(isDark: Bool, x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: width, height: 0.5))
        v.wantsLayer = true
        v.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)).cgColor
        return v
    }

    @objc private func toggleShowAllFavoritesClicked() {
        isFavoritesManuallyExpanded.toggle()
        popoverFavoritesGrid?.setExpanded(isFavoritesManuallyExpanded, animated: true)
        updateShowAllButtonStyle(isDark: currentIsDark)
    }

    private func updateShowAllButtonStyle(isDark: Bool) {
        guard let btn = popoverShowAllButton else { return }
        let tint: NSColor = isDark
            ? NSColor(srgbRed: 0.25, green: 0.61, blue: 1.0, alpha: 0.96)
            : NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
        let title = isFavoritesManuallyExpanded ? "Show Less" : "Show All"
        let symbolName = isFavoritesManuallyExpanded ? "chevron.up" : "chevron.right"
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: tint
        ])
        let baseSym = AssetLoader.shared.symbol(named: symbolName, pointSize: 10.5, weight: .semibold)
        let tinted = NSImage(size: baseSym.size, flipped: false) { r in
            baseSym.draw(in: r)
            tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        btn.image = tinted
    }

    private func updateBelowFavoritesLayout(gridHeight: CGFloat, animated: Bool) {
        let newBelowY = favoritesGridTopY + gridHeight + 10
        let newPreferredH = newBelowY + belowFavoritesHeight
        if let container = contentContainer {
            container.preferredHeight = newPreferredH
            let minH = panel?.frame.height ?? newPreferredH
            let targetDocH = max(minH, newPreferredH)
            if !animated {
                container.frame.size.height = targetDocH
            } else if targetDocH > container.frame.size.height {
                container.frame.size.height = targetDocH
            }
        }
        guard let below = belowFavoritesContainer else { return }
        if !animated {
            below.frame.origin.y = newBelowY
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            below.animator().frame.origin.y = newBelowY
        }, completionHandler: { [weak self] in
            guard let self, let container = self.contentContainer else { return }
            let minH = self.panel?.frame.height ?? container.preferredHeight
            container.frame.size.height = max(minH, container.preferredHeight)
        })
    }
}

// MARK: - Popover Subviews (Ported 1:1 from SafariumUnifiedField.swift)

private final class PopoverFlippedContainer: NSView {
    var preferredHeight: CGFloat = 260
    override var isFlipped: Bool { true }
}

/// Interactive 6-column Favorites grid inside the Address Bar Popover with live drag-and-drop
/// reordering, cubic ease-out neighbor reflow, auto-expand on drag, and context menu matching Start Page.
final class PopoverFavoritesReorderGridView: NSView {
    static let columns: Int = 6
    static let collapsedMaxRows: Int = 2
    static let collapsedMaxCount: Int = columns * collapsedMaxRows
    static let tileSize: CGFloat = 66.0
    static let tileHeight: CGFloat = 102.0 // tileSize (66) + 36 label/pad
    static let rowStep: CGFloat = 104.0

    var onSelectURL: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onOpenInNewTabGroup: ((URL) -> Void)?
    var onReorderCommit: (([AssetLoader.BookmarkEntry]) -> Void)?
    var onExpandStateChanged: (() -> Void)?
    var onHeightWillChange: ((CGFloat, Bool) -> Void)?
    var hostWindowProvider: (() -> NSWindow?)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let tileWidth: CGFloat
    private let colPitch: CGFloat
    private let isDark: Bool

    private var entries: [AssetLoader.BookmarkEntry] = []
    private var tileViews: [PopoverFavoriteSquircleButton] = []
    private var isExpanded: Bool = false
    private var contextMenuEntryID: String?

    // Live drag state
    private var pressedTile: PopoverFavoriteSquircleButton?
    private var pressedIndex: Int?
    private var mouseDownPoint: NSPoint = .zero
    private var grabOffset: NSPoint = .zero
    private var isDragging: Bool = false
    private var dragPlaceholderIndex: Int = 0
    private var wasExpandedBeforeDrag: Bool = false
    private var didAutoExpandForDrag: Bool = false

    // Option-key iOS Home Screen jiggle & delete mode
    private var isOptionJiggling: Bool = false
    private var pressedDeleteBadgeIndex: Int?
    private var flagsMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        guard window != nil else {
            setOptionJiggling(false, animated: false)
            return
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setOptionJiggling(event.modifierFlags.contains(.option), animated: true)
            return event
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setOptionJiggling(false, animated: true)
        }
        setOptionJiggling(NSEvent.modifierFlags.contains(.option), animated: false)
    }

    private func setOptionJiggling(_ jiggling: Bool, animated: Bool) {
        guard isOptionJiggling != jiggling else { return }
        isOptionJiggling = jiggling
        for (idx, tile) in tileViews.enumerated() {
            let active = jiggling && !(isDragging && tile === pressedTile)
            tile.setJiggling(active, phaseSeed: idx, animated: animated)
        }
    }

    init(origin: NSPoint, contentWidth: CGFloat, btnExtraW: CGFloat, isDark: Bool) {
        self.tileWidth = Self.tileSize + btnExtraW
        let colGap = (contentWidth - Self.tileSize * CGFloat(Self.columns)) / CGFloat(Self.columns - 1)
        self.colPitch = Self.tileSize + colGap
        self.isDark = isDark
        super.init(frame: NSRect(x: origin.x, y: origin.y, width: contentWidth + btnExtraW, height: Self.height(forVisibleRows: 2)))
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    static func height(forVisibleRows rows: Int) -> CGFloat {
        CGFloat(max(1, rows)) * rowStep
    }

    func totalRowCount() -> Int {
        max(1, (entries.count + Self.columns - 1) / Self.columns)
    }

    func visibleRowCount(expanded: Bool) -> Int {
        let total = totalRowCount()
        return expanded ? total : min(Self.collapsedMaxRows, total)
    }

    func slotRect(for index: Int) -> NSRect {
        let col = index % Self.columns
        let row = index / Self.columns
        return NSRect(
            x: CGFloat(col) * colPitch,
            y: CGFloat(row) * Self.rowStep,
            width: tileWidth,
            height: Self.tileHeight
        )
    }

    func configure(entries: [AssetLoader.BookmarkEntry], expanded: Bool) {
        self.entries = entries
        self.isExpanded = expanded
        for tile in tileViews {
            tile.removeFromSuperview()
        }
        tileViews.removeAll()

        for (idx, entry) in entries.enumerated() {
            let tile = PopoverFavoriteSquircleButton(
                frame: slotRect(for: idx),
                title: entry.title,
                urlString: entry.url,
                tileSize: Self.tileSize,
                isDark: isDark
            )
            tile.handlesOwnClick = false
            let isOverflow = idx >= Self.collapsedMaxCount
            tile.alphaValue = (!expanded && isOverflow) ? 0.0 : 1.0
            tile.isHidden = (!expanded && isOverflow)
            addSubview(tile)
            tileViews.append(tile)
            if isOptionJiggling {
                tile.setJiggling(true, phaseSeed: idx, animated: false)
            }
        }

        frame.size.height = Self.height(forVisibleRows: visibleRowCount(expanded: expanded))
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        let targetH = Self.height(forVisibleRows: visibleRowCount(expanded: expanded))

        if !animated {
            frame.size.height = targetH
            for (idx, tile) in tileViews.enumerated() {
                let hide = !expanded && idx >= Self.collapsedMaxCount
                tile.isHidden = hide
                tile.alphaValue = hide ? 0.0 : 1.0
            }
            onHeightWillChange?(targetH, false)
            return
        }

        if expanded {
            for (idx, tile) in tileViews.enumerated() where idx >= Self.collapsedMaxCount {
                tile.isHidden = false
                tile.alphaValue = 0.0
            }
        }

        onHeightWillChange?(targetH, true)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            self.animator().frame.size.height = targetH
            for (idx, tile) in self.tileViews.enumerated() where idx >= Self.collapsedMaxCount {
                tile.animator().alphaValue = expanded ? 1.0 : 0.0
            }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.isExpanded {
                for (idx, tile) in self.tileViews.enumerated() where idx >= Self.collapsedMaxCount {
                    tile.isHidden = true
                    tile.alphaValue = 0.0
                }
            }
        })
    }

    // MARK: - Pointer Handling & Live Spring Reflow

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hitBounds = isOptionJiggling ? bounds.insetBy(dx: -10, dy: -10) : bounds
        return hitBounds.contains(local) ? self : nil
    }

    private func deleteBadgeTileIndex(at point: NSPoint) -> Int? {
        guard isOptionJiggling else { return nil }
        for (idx, tile) in tileViews.enumerated() {
            guard !tile.isHidden, tile.alphaValue > 0.05 else { continue }
            let localPt = NSPoint(x: point.x - tile.frame.origin.x, y: point.y - tile.frame.origin.y)
            if tile.isPointInDeleteBadge(localPt) {
                return idx
            }
        }
        return nil
    }

    private func tileIndex(at point: NSPoint) -> Int? {
        for (idx, tile) in tileViews.enumerated() {
            guard !tile.isHidden, tile.alphaValue > 0.05 else { continue }
            if tile.frame.contains(point) {
                return idx
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let badgeIdx = deleteBadgeTileIndex(at: pt) {
            pressedDeleteBadgeIndex = badgeIdx
            pressedIndex = nil
            pressedTile = nil
            isDragging = false
            return
        }
        pressedDeleteBadgeIndex = nil
        guard let idx = tileIndex(at: pt) else {
            super.mouseDown(with: event)
            return
        }
        pressedIndex = idx
        pressedTile = tileViews[idx]
        mouseDownPoint = pt
        grabOffset = NSPoint(x: pt.x - tileViews[idx].frame.origin.x, y: pt.y - tileViews[idx].frame.origin.y)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tile = pressedTile, let startIdx = pressedIndex else { return }
        if isDragging {
            autoscroll(with: event)
        }
        let pt = convert(event.locationInWindow, from: nil)

        if !isDragging {
            let dist = hypot(pt.x - mouseDownPoint.x, pt.y - mouseDownPoint.y)
            guard dist >= 5.0 else { return }
            beginDrag(tile: tile, index: startIdx)
        }

        // Keep dragged tile 1:1 locked to cursor on GPU with zero lag
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.frame.origin = NSPoint(x: pt.x - grabOffset.x, y: pt.y - grabOffset.y)
        CATransaction.commit()

        let center = NSPoint(x: tile.frame.midX, y: tile.frame.midY)
        let col = max(0, min(Self.columns - 1, Int(floor(center.x / max(1.0, colPitch)))))
        let maxRows = visibleRowCount(expanded: isExpanded)
        let row = max(0, min(maxRows - 1, Int(floor(center.y / Self.rowStep))))
        let targetIdx = max(0, min(entries.count - 1, row * Self.columns + col))

        if targetIdx != dragPlaceholderIndex {
            movePlaceholder(from: dragPlaceholderIndex, to: targetIdx, draggedTile: tile)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let badgeIdx = pressedDeleteBadgeIndex {
            pressedDeleteBadgeIndex = nil
            let pt = convert(event.locationInWindow, from: nil)
            if deleteBadgeTileIndex(at: pt) == badgeIdx {
                deleteFavorite(at: badgeIdx)
            }
            return
        }
        defer {
            pressedTile = nil
            pressedIndex = nil
            isDragging = false
        }
        guard let tile = pressedTile, let idx = pressedIndex else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if !isDragging {
            if idx < entries.count, tile.frame.contains(pt), let url = URL(string: entries[idx].url) {
                onSelectURL?(url)
            }
            return
        }

        endDrag(tile: tile)
    }

    private func beginDrag(tile: PopoverFavoriteSquircleButton, index: Int) {
        isDragging = true
        dragPlaceholderIndex = index
        wasExpandedBeforeDrag = isExpanded
        didAutoExpandForDrag = false

        // Elevate dragged tile cleanly above all neighbors
        if isOptionJiggling {
            tile.setJiggling(false, phaseSeed: index, animated: false)
        }
        tile.removeFromSuperview()
        addSubview(tile)
        tile.setDragElevated(true, animated: true)

        // Auto-expand collapsed Favorites grid during drag (matching Start Page)
        if !isExpanded && entries.count > Self.collapsedMaxCount {
            didAutoExpandForDrag = true
            setExpanded(true, animated: true)
        }
    }

    private func movePlaceholder(from oldIdx: Int, to newIdx: Int, draggedTile: PopoverFavoriteSquircleButton) {
        let movedEntry = entries.remove(at: oldIdx)
        entries.insert(movedEntry, at: newIdx)

        let movedTile = tileViews.remove(at: oldIdx)
        tileViews.insert(movedTile, at: newIdx)

        dragPlaceholderIndex = newIdx

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            for (idx, t) in self.tileViews.enumerated() where t !== draggedTile {
                t.animator().frame = self.slotRect(for: idx)
            }
        }
    }

    private func endDrag(tile: PopoverFavoriteSquircleButton) {
        let finalRect = slotRect(for: dragPlaceholderIndex)
        let shouldAutoCollapse = didAutoExpandForDrag && !wasExpandedBeforeDrag
        let willHideDroppedTile = shouldAutoCollapse && dragPlaceholderIndex >= Self.collapsedMaxCount

        tile.setDragElevated(false, animated: true)
        if isOptionJiggling {
            tile.setJiggling(true, phaseSeed: dragPlaceholderIndex, animated: false)
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            tile.animator().frame = finalRect
            if willHideDroppedTile {
                tile.animator().alphaValue = 0.0
            }
        })

        onReorderCommit?(entries)

        if shouldAutoCollapse {
            didAutoExpandForDrag = false
            setExpanded(false, animated: true)
            onExpandStateChanged?()
        }
    }

    // MARK: - Native Right-Click Context Menu (matches Start Page Favorites)

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        guard let idx = tileIndex(at: pt), idx < entries.count else {
            return nil
        }
        let entry = entries[idx]
        contextMenuEntryID = entry.id

        let menu = NSMenu(title: entry.title)
        menu.autoenablesItems = false

        let openTab = NSMenuItem(title: "Open in New Tab", action: #selector(contextOpenInNewTab), keyEquivalent: "")
        openTab.target = self
        menu.addItem(openTab)

        let openWindow = NSMenuItem(title: "Open in New Window", action: #selector(contextOpenInNewWindow), keyEquivalent: "")
        openWindow.target = self
        menu.addItem(openWindow)

        menu.addItem(.separator())

        let renameItem = NSMenuItem(title: "Rename", action: #selector(contextRenameFavorite), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        let editAddrItem = NSMenuItem(title: "Edit Address…", action: #selector(contextEditAddress), keyEquivalent: "")
        editAddrItem.target = self
        menu.addItem(editAddrItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopyAddress), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextDeleteFavorite), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        return menu
    }

    private func currentContextEntry() -> (Int, AssetLoader.BookmarkEntry)? {
        guard let id = contextMenuEntryID,
              let idx = entries.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return (idx, entries[idx])
    }

    @objc private func contextOpenInNewTab() {
        guard let (_, entry) = currentContextEntry(), let url = URL(string: entry.url) else { return }
        onOpenInNewTab?(url)
    }

    @objc private func contextOpenInNewWindow() {
        guard let (_, entry) = currentContextEntry(), let url = URL(string: entry.url) else { return }
        onOpenInNewWindow?(url)
    }

    @objc private func contextOpenInTabGroup() {
        guard let (_, entry) = currentContextEntry(), let url = URL(string: entry.url) else { return }
        onOpenInNewTabGroup?(url)
    }

    @objc private func contextRenameFavorite() {
        guard let (idx, entry) = currentContextEntry() else { return }
        presentInlineEditAlert(
            title: "Rename Favorite",
            message: "Enter a new name for “\(entry.title)”.",
            initialValue: entry.title,
            placeholder: "Favorite name"
        ) { [weak self] newValue in
            guard let self, !newValue.isEmpty, idx < self.entries.count else { return }
            self.entries[idx].title = newValue
            self.tileViews[idx].update(title: newValue, urlString: self.entries[idx].url)
            self.onReorderCommit?(self.entries)
        }
    }

    @objc private func contextEditAddress() {
        guard let (idx, entry) = currentContextEntry() else { return }
        presentInlineEditAlert(
            title: "Edit Address",
            message: "Enter the website address for “\(entry.title)”.",
            initialValue: entry.url,
            placeholder: "https://example.com"
        ) { [weak self] newValue in
            guard let self, !newValue.isEmpty, idx < self.entries.count else { return }
            let normalized = URLInputNormalizer.normalize(newValue).absoluteString
            self.entries[idx].url = normalized
            self.tileViews[idx].update(title: self.entries[idx].title, urlString: normalized)
            self.onReorderCommit?(self.entries)
        }
    }

    private func presentInlineEditAlert(
        title: String,
        message: String,
        initialValue: String,
        placeholder: String,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24))
        input.stringValue = initialValue
        input.placeholderString = placeholder
        alert.accessoryView = input

        let applyEdit: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                completion(trimmed)
            }
        }

        if let win = hostWindowProvider?() {
            alert.beginSheetModal(for: win) { response in
                applyEdit(response)
            }
            win.makeFirstResponder(input)
        } else {
            applyEdit(alert.runModal())
        }
    }

    @objc private func contextCopyAddress() {
        guard let (_, entry) = currentContextEntry() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.url, forType: .string)
    }

    @objc private func contextDeleteFavorite() {
        guard let (idx, _) = currentContextEntry() else { return }
        deleteFavorite(at: idx)
    }

    private func deleteFavorite(at idx: Int) {
        guard idx >= 0 && idx < entries.count && idx < tileViews.count else { return }
        entries.remove(at: idx)
        let removedTile = tileViews.remove(at: idx)
        let targetH = Self.height(forVisibleRows: visibleRowCount(expanded: isExpanded))
        onHeightWillChange?(targetH, true)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            removedTile.animator().alphaValue = 0.0
            self.animator().frame.size.height = targetH
            for (i, tile) in self.tileViews.enumerated() {
                let shouldHide = !self.isExpanded && i >= Self.collapsedMaxCount
                if !shouldHide && tile.isHidden {
                    tile.isHidden = false
                    tile.alphaValue = 0.0
                }
                tile.animator().frame = self.slotRect(for: i)
                tile.animator().alphaValue = shouldHide ? 0.0 : 1.0
            }
        }, completionHandler: { [weak self] in
            removedTile.removeFromSuperview()
            guard let self else { return }
            for (i, tile) in self.tileViews.enumerated() {
                tile.isHidden = !self.isExpanded && i >= Self.collapsedMaxCount
            }
        })

        onReorderCommit?(entries)
    }
}

/// 66 × 66 pt Safari Favorites Squircle Tile (cr = 0.22 * size) with full-bleed branded tiles
/// (matching Safarium + `05_addressbar_popover_top.png` 1:1), real `FaviconCache` artwork,
/// and GPU drag-lift elevation matching Start Page tiles.
private final class PopoverFavoriteSquircleButton: NSView {
    private(set) var title: String
    private(set) var urlString: String
    let tileSize: CGFloat
    let isDark: Bool
    var onClick: (() -> Void)?
    var handlesOwnClick: Bool = true

    private let jiggleHost = PopoverFlippedContainer()
    private let shadowHost = NSView()
    private let squircleCanvas = PopoverSquircleCanvasView()
    private let deleteBadgeView = NSView()
    private let deleteBadgeIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isJiggling: Bool = false

    override var isFlipped: Bool { true }

    init(frame: NSRect, title: String, urlString: String, tileSize: CGFloat = 66, isDark: Bool) {
        self.title = title
        self.urlString = urlString
        self.tileSize = tileSize
        self.isDark = isDark
        super.init(frame: frame)

        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false

        let tileX = (frame.width - tileSize) * 0.5
        let cr = tileSize * 0.22

        jiggleHost.frame = NSRect(x: 0, y: 0, width: frame.width, height: tileSize + 8)
        jiggleHost.wantsLayer = true
        jiggleHost.clipsToBounds = false
        jiggleHost.layer?.masksToBounds = false
        addSubview(jiggleHost)

        shadowHost.frame = NSRect(x: tileX, y: 4, width: tileSize, height: tileSize)
        shadowHost.wantsLayer = true
        shadowHost.clipsToBounds = false
        shadowHost.layer?.masksToBounds = false
        shadowHost.layer?.cornerRadius = cr
        shadowHost.layer?.cornerCurve = .continuous
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.0
        shadowHost.layer?.shadowRadius = 6.0
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadowHost.layer?.shadowPath = CGPath(
            roundedRect: shadowHost.bounds,
            cornerWidth: cr,
            cornerHeight: cr,
            transform: nil
        )
        jiggleHost.addSubview(shadowHost)

        squircleCanvas.frame = shadowHost.bounds
        squircleCanvas.wantsLayer = true
        squircleCanvas.layer?.cornerRadius = cr
        squircleCanvas.layer?.cornerCurve = .continuous
        squircleCanvas.layer?.masksToBounds = true
        squircleCanvas.title = title
        squircleCanvas.urlString = urlString
        squircleCanvas.isDark = isDark
        squircleCanvas.touchIcon = FaviconCache.shared.cachedTouchIcon(forURLString: urlString)
        shadowHost.addSubview(squircleCanvas)

        // jiggleHost is flipped (y=0 top); badge sits cleanly inside jiggleHost overlapping icon top-left corner
        deleteBadgeView.frame = NSRect(x: max(0, tileX - 4), y: 0, width: 20, height: 20)
        deleteBadgeView.wantsLayer = true
        deleteBadgeView.layer?.cornerRadius = 10.0
        deleteBadgeView.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 0.95)
            : NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 0.90)).cgColor
        deleteBadgeView.layer?.borderWidth = 0.5
        deleteBadgeView.layer?.borderColor = (isDark
            ? NSColor.black.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.22)).cgColor
        deleteBadgeView.layer?.shadowColor = NSColor.black.cgColor
        deleteBadgeView.layer?.shadowOpacity = 0.28
        deleteBadgeView.layer?.shadowRadius = 2.5
        deleteBadgeView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        deleteBadgeView.alphaValue = 0.0
        deleteBadgeView.isHidden = true
        jiggleHost.addSubview(deleteBadgeView)

        deleteBadgeIcon.frame = NSRect(x: 5, y: 5, width: 10, height: 10)
        deleteBadgeIcon.image = AssetLoader.shared.symbol(named: "xmark", pointSize: 9.0, weight: .bold)
        deleteBadgeIcon.contentTintColor = isDark
            ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 0.95)
            : NSColor.white.withAlphaComponent(0.96)
        deleteBadgeView.addSubview(deleteBadgeIcon)

        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center
        pStyle.lineBreakMode = .byWordWrapping
        titleLabel.frame = NSRect(x: 0, y: tileSize + 8.5, width: frame.width, height: 28)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.wraps = true
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: isDark ? NSColor(white: 1, alpha: 0.94) : NSColor(white: 0.14, alpha: 1.0),
            .paragraphStyle: pStyle
        ])
        addSubview(titleLabel)

        if squircleCanvas.touchIcon == nil {
            FaviconCache.shared.fetchTouchIcon(forURLString: urlString) { [weak self] res in
                guard let self, self.urlString == urlString else { return }
                self.squircleCanvas.touchIcon = res
                self.squircleCanvas.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func isPointInDeleteBadge(_ pointInTile: NSPoint) -> Bool {
        guard !deleteBadgeView.isHidden, deleteBadgeView.alphaValue > 0.1 else { return false }
        let badgeInTile = convert(deleteBadgeView.bounds, from: deleteBadgeView)
        return badgeInTile.insetBy(dx: -5, dy: -5).contains(pointInTile)
    }

    func setJiggling(_ jiggling: Bool, phaseSeed: Int, animated: Bool) {
        isJiggling = jiggling
        if jiggling {
            deleteBadgeView.isHidden = false
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    deleteBadgeView.animator().alphaValue = 1.0
                }
            } else {
                deleteBadgeView.alphaValue = 1.0
            }

            if let l = jiggleHost.layer, l.animation(forKey: "iosJiggle") == nil {
                let cx = jiggleHost.bounds.midX
                let cy = jiggleHost.bounds.midY
                func wobbleTransform(angle: CGFloat, dx: CGFloat, dy: CGFloat) -> NSValue {
                    var t = CATransform3DIdentity
                    t = CATransform3DTranslate(t, cx + dx, cy + dy, 0)
                    t = CATransform3DRotate(t, angle, 0, 0, 1)
                    t = CATransform3DTranslate(t, -cx, -cy, 0)
                    return NSValue(caTransform3D: t)
                }
                let dir: CGFloat = (phaseSeed % 2 == 0) ? 1.0 : -1.0
                let angle: CGFloat = 0.038 * dir
                let anim = CAKeyframeAnimation(keyPath: "transform")
                anim.values = [
                    wobbleTransform(angle: -angle, dx: -0.5 * dir, dy: 0.4),
                    wobbleTransform(angle: angle, dx: 0.5 * dir, dy: -0.4),
                    wobbleTransform(angle: -angle, dx: -0.5 * dir, dy: 0.4)
                ]
                anim.keyTimes = [0.0, 0.5, 1.0]
                anim.duration = 0.25 + Double(phaseSeed % 5) * 0.014
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.timeOffset = Double(phaseSeed % 7) * 0.037
                l.add(anim, forKey: "iosJiggle")
            }
        } else {
            jiggleHost.layer?.removeAnimation(forKey: "iosJiggle")
            if animated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    deleteBadgeView.animator().alphaValue = 0.0
                }, completionHandler: { [weak self] in
                    guard let self, !self.isJiggling else { return }
                    self.deleteBadgeView.isHidden = true
                })
            } else {
                deleteBadgeView.alphaValue = 0.0
                deleteBadgeView.isHidden = true
            }
        }
    }

    func update(title newTitle: String, urlString newURL: String) {
        self.title = newTitle
        self.urlString = newURL
        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center
        pStyle.lineBreakMode = .byWordWrapping
        titleLabel.attributedStringValue = NSAttributedString(string: newTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: isDark ? NSColor(white: 1, alpha: 0.94) : NSColor(white: 0.14, alpha: 1.0),
            .paragraphStyle: pStyle
        ])
        squircleCanvas.title = newTitle
        squircleCanvas.urlString = newURL
        let cached = FaviconCache.shared.cachedTouchIcon(forURLString: newURL)
        squircleCanvas.touchIcon = cached
        squircleCanvas.needsDisplay = true
        if cached == nil {
            FaviconCache.shared.fetchTouchIcon(forURLString: newURL) { [weak self] res in
                guard let self, self.urlString == newURL else { return }
                self.squircleCanvas.touchIcon = res
                self.squircleCanvas.needsDisplay = true
            }
        }
    }

    func setDragElevated(_ elevated: Bool, animated: Bool) {
        wantsLayer = true
        layer?.masksToBounds = false
        shadowHost.layer?.masksToBounds = false

        let targetScale: CGFloat = elevated ? 1.06 : 1.0
        let targetShadowOpacity: Float = elevated ? 0.36 : 0.0
        let targetShadowRadius: CGFloat = elevated ? 18.0 : 6.0
        let targetShadowOffset = elevated ? CGSize(width: 0, height: -9) : CGSize(width: 0, height: -2)
        let targetAlpha: CGFloat = elevated ? 0.96 : 1.0

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0.0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0))
        if let l = shadowHost.layer {
            let cr = tileSize * 0.22
            if l.bounds.width > 0 && l.bounds.height > 0 {
                l.shadowPath = CGPath(roundedRect: l.bounds, cornerWidth: cr, cornerHeight: cr, transform: nil)
            }
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = targetShadowOpacity
            l.shadowRadius = targetShadowRadius
            l.shadowOffset = targetShadowOffset
            let cx = l.bounds.midX
            let cy = l.bounds.midY
            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, cx, cy, 0)
            t = CATransform3DScale(t, targetScale, targetScale, 1.0)
            t = CATransform3DTranslate(t, -cx, -cy, 0)
            l.transform = t
        }
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.16 : 0.0
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.animator().alphaValue = targetAlpha
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard handlesOwnClick else {
            super.mouseUp(with: event)
            return
        }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

private final class PopoverSquircleCanvasView: NSView {
    var title: String = ""
    var urlString: String = ""
    var isDark: Bool = false
    var touchIcon: FaviconCache.TouchIconResult?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        PopoverBrandArtwork.drawFavoriteSquircle(
            in: bounds,
            title: title,
            urlString: urlString,
            touchIcon: touchIcon,
            isDark: isDark
        )
    }
}

/// 226 × 156 pt Tall Safari Recently Viewed Card (exact 1:1 Safarium + `05_addressbar_popover_top.png`)
private final class PopoverRecentlyViewedCardView: NSView {
    let domain: String
    let urlString: String
    let timeLabel: String
    let tabCount: Int
    let isDark: Bool
    var onClick: (() -> Void)?
    private var iconImage: NSImage?

    override var isFlipped: Bool { true }

    init(frame: NSRect, domain: String, urlString: String, prefetchedIcon: NSImage?, timeLabel: String, tabCount: Int, isDark: Bool) {
        self.domain = domain
        self.urlString = urlString
        self.timeLabel = timeLabel
        self.tabCount = tabCount
        self.isDark = isDark
        self.iconImage = prefetchedIcon ?? FaviconCache.shared.memoryCachedIcon(forURLString: urlString)
        super.init(frame: frame)

        if iconImage == nil {
            FaviconCache.shared.fetchFavicon(forURLString: urlString) { [weak self] img in
                guard let self, let img else { return }
                self.iconImage = img
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        let fill = isDark ? NSColor(white: 1.0, alpha: 0.10) : NSColor(white: 1.0, alpha: 0.78)
        fill.setFill()
        path.fill()

        let padX: CGFloat = 14.5
        let iconSize: CGFloat = 33
        let iconRect = NSRect(x: padX, y: 14.5, width: iconSize, height: iconSize)
        let iconClip = NSBezierPath(roundedRect: iconRect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        iconClip.addClip()
        PopoverBrandArtwork.drawSiteBadge(in: iconRect, urlString: urlString, favicon: iconImage, isDark: isDark)
        NSGraphicsContext.restoreGraphicsState()

        let domColor = isDark ? NSColor(white: 1.0, alpha: 0.92) : NSColor(white: 0.133, alpha: 1.0)
        let domAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.0, weight: .semibold),
            .foregroundColor: domColor
        ]
        NSString(string: domain).draw(in: NSRect(x: padX, y: 56.5, width: bounds.width - padX * 2, height: 18), withAttributes: domAttrs)

        let secColor = isDark ? NSColor(white: 1.0, alpha: 0.55) : NSColor(srgbRed: 0.478, green: 0.490, blue: 0.510, alpha: 1.0)
        if let clock = tintedSymbol("clock", pointSize: 11.0, weight: .regular, color: secColor) {
            clock.draw(in: NSRect(x: padX, y: 98.5, width: clock.size.width, height: clock.size.height))
        }
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: secColor
        ]
        NSString(string: timeLabel).draw(at: CGPoint(x: padX + 16, y: 97.5), withAttributes: timeAttrs)

        let pillText = "\(tabCount) \(tabCount == 1 ? "Tab" : "Tabs")"
        let pillTextColor = isDark ? NSColor(white: 1.0, alpha: 0.88) : NSColor(white: 0.20, alpha: 1.0)
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: pillTextColor
        ]
        let tSz = NSString(string: pillText).size(withAttributes: pillAttrs)
        let chev = tintedSymbol("chevron.right", pointSize: 8.5, weight: .semibold, color: pillTextColor)
        let chevW = chev?.size.width ?? 5.5
        let pillW = tSz.width + chevW + 21
        let pillRect = NSRect(x: padX, y: bounds.height - 12 - 22, width: pillW, height: 22)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 11, yRadius: 11)
        (isDark ? NSColor(white: 1.0, alpha: 0.12) : NSColor(white: 0.0, alpha: 0.045)).setFill()
        pillPath.fill()
        NSString(string: pillText).draw(at: CGPoint(x: pillRect.minX + 9, y: pillRect.midY - tSz.height * 0.5), withAttributes: pillAttrs)
        if let chev {
            chev.draw(in: NSRect(x: pillRect.minX + 12 + tSz.width, y: pillRect.midY - chev.size.height * 0.5, width: chev.size.width, height: chev.size.height))
        }
    }
}

/// 58 pt Reading List Row inside Start Page Popover (exact 1:1 Safarium)
private final class PopoverReadingListRowView: NSView {
    let entry: AddressBarPopoverController.ReadingListEntry
    let isDark: Bool
    var onClick: (() -> Void)?
    private var iconImage: NSImage?

    override var isFlipped: Bool { true }

    init(frame: NSRect, entry: AddressBarPopoverController.ReadingListEntry, isDark: Bool) {
        self.entry = entry
        self.isDark = isDark
        self.iconImage = FaviconCache.shared.memoryCachedIcon(forURLString: entry.url.absoluteString)
        super.init(frame: frame)

        if iconImage == nil {
            FaviconCache.shared.fetchFavicon(forURLString: entry.url.absoluteString) { [weak self] img in
                guard let self, let img else { return }
                self.iconImage = img
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        let fill = isDark ? NSColor(white: 1.0, alpha: 0.10) : NSColor(white: 1.0, alpha: 0.78)
        fill.setFill()
        path.fill()

        let iconSize: CGFloat = 28
        let iconRect = NSRect(x: 14, y: (bounds.height - iconSize) * 0.5, width: iconSize, height: iconSize)
        let iconClip = NSBezierPath(roundedRect: iconRect, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        iconClip.addClip()
        PopoverBrandArtwork.drawSiteBadge(in: iconRect, urlString: entry.url.absoluteString, favicon: iconImage, isDark: isDark)
        NSGraphicsContext.restoreGraphicsState()

        let textX = iconRect.maxX + 12
        let textW = max(60, bounds.width - textX - 14)
        let titleColor = isDark ? NSColor(white: 1.0, alpha: 0.92) : NSColor(white: 0.133, alpha: 1.0)
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: titleColor,
            .paragraphStyle: pStyle
        ]
        NSString(string: entry.title).draw(in: NSRect(x: textX, y: 11, width: textW, height: 17), withAttributes: titleAttrs)

        let subColor = isDark ? NSColor(white: 1.0, alpha: 0.55) : NSColor(srgbRed: 0.478, green: 0.490, blue: 0.510, alpha: 1.0)
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: subColor,
            .paragraphStyle: pStyle
        ]
        NSString(string: entry.domain).draw(in: NSRect(x: textX, y: 31, width: textW, height: 15), withAttributes: subAttrs)
    }
}

/// Native macOS 27 Tahoe Safari Autocomplete Row (Top Hit / Switch to Tab / Google Suggestions / Bookmarks & History)
final class PopoverAutocompleteRowView: NSView {
    /// UTF-16 length of the typed prefix to emphasize, or nil when the title does not start with the query (case-insensitive).
    static func boldPrefixLength(title: String, query: String) -> Int? {
        let lowerQ = query.lowercased()
        guard !lowerQ.isEmpty, title.lowercased().hasPrefix(lowerQ) else { return nil }
        return (query as NSString).length
    }

    /// Builds an attributed string that emphasizes matching query tokens cleanly.
    private static func highlightedAttributedString(
        _ text: String,
        query: String,
        baseFont: NSFont,
        highlightFont: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ])
        let nsText = text as NSString
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for token in tokens where !token.isEmpty {
            let range = nsText.range(of: token, options: [.caseInsensitive, .diacriticInsensitive])
            if range.location != NSNotFound, range.location + range.length <= attr.length {
                attr.addAttribute(.font, value: highlightFont, range: range)
            }
        }
        return attr
    }

    let item: AddressBarPopoverController.SuggestionItem
    let query: String
    private(set) var isSelected: Bool
    let isDark: Bool
    var onClick: (() -> Void)?
    var onCommandClick: (() -> Void)?
    var onHover: (() -> Void)?
    private var trackingRef: NSTrackingArea?
    private var fetchedFavicon: NSImage?
    private var faviconIsOpaque: Bool = false

    override var isFlipped: Bool { true }

    init(frame: NSRect, item: AddressBarPopoverController.SuggestionItem, query: String, isSelected: Bool, isDark: Bool) {
        self.item = item
        self.query = query
        self.isSelected = isSelected
        self.isDark = isDark
        let initialIcon = item.prefetchedIcon ?? (item.iconURLString.isEmpty ? nil : FaviconCache.shared.bestCachedIcon(forURLString: item.iconURLString))
        self.fetchedFavicon = initialIcon
        self.faviconIsOpaque = initialIcon.map { FaviconCache.hasOpaqueCorners($0) } ?? false
        super.init(frame: frame)

        // Always fetch the real site favicon for any URL item (even when `symbolName` is a fallback like `globe`).
        if fetchedFavicon == nil && !item.iconURLString.isEmpty {
            FaviconCache.shared.fetchFavicon(forURLString: item.iconURLString) { [weak self] img in
                guard let self, let img else { return }
                self.fetchedFavicon = img
                self.faviconIsOpaque = FaviconCache.hasOpaqueCorners(img)
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingRef { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            if event.modifierFlags.contains(.command), let onCommandClick {
                onCommandClick()
            } else {
                onClick?()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isSelected
        if active {
            let cornerR: CGFloat = (item.style == .topHit) ? 12.0 : (item.style == .googleSuggestion ? 8.5 : 10.0)
            let path = NSBezierPath(roundedRect: bounds, xRadius: cornerR, yRadius: cornerR)
            NSColor.controlAccentColor.setFill()
            path.fill()
        }

        let primaryColor: NSColor = active
            ? .white
            : (isDark ? NSColor(white: 1.0, alpha: 0.92) : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0))
        let secondaryColor: NSColor = active
            ? NSColor(white: 1.0, alpha: 0.84)
            : (isDark ? NSColor(white: 1.0, alpha: 0.54) : NSColor(white: 0.0, alpha: 0.52))
        let iconTintColor: NSColor = active
            ? .white
            : (isDark ? NSColor(white: 1.0, alpha: 0.72) : NSColor(white: 0.22, alpha: 0.82))

        let isTwoLine = !item.subtitle.isEmpty
        let iconSize: CGFloat = (item.style == .topHit && isTwoLine) ? 22.0 : (isTwoLine ? 20.0 : 14.0)
        let iconX: CGFloat = isTwoLine ? 11.0 : 10.0
        let iconRect = NSRect(x: iconX, y: (bounds.height - iconSize) * 0.5, width: iconSize, height: iconSize)

        // Prefer the real site favicon whenever available; fall back to `symbolName` (e.g. `magnifyingglass` or `globe`).
        if let fav = fetchedFavicon {
            let badgeRadius: CGFloat = (item.style == .topHit) ? 5.5 : 5.0
            let clip = NSBezierPath(roundedRect: iconRect, xRadius: badgeRadius, yRadius: badgeRadius)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            if faviconIsOpaque {
                let fillRect = AddressBarPopoverController.aspectFillRect(for: fav.size, in: iconRect) ?? iconRect
                fav.draw(in: fillRect)
            } else {
                // Crisp contrast plate so dark transparent favicons (GitHub, Apple, X, Notion) stay legible
                // in Dark Mode and over the blue accent selection highlight.
                let plateColor: NSColor = active
                    ? NSColor.white.withAlphaComponent(0.95)
                    : (isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(0.96))
                plateColor.setFill()
                iconRect.fill()
                let insetRect = iconRect.insetBy(dx: 2.0, dy: 2.0)
                let fitRect = AddressBarPopoverController.aspectFitRect(for: fav.size, in: insetRect) ?? insetRect
                fav.draw(in: fitRect)
            }
            NSGraphicsContext.restoreGraphicsState()
            if !active {
                let borderColor = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
                borderColor.setStroke()
                clip.lineWidth = 0.5
                clip.stroke()
            }
        } else if let sym = item.symbolName, let img = tintedSymbol(sym, pointSize: isTwoLine ? 15.0 : 12.5, weight: .regular, color: iconTintColor) {
            let drawRect = NSRect(
                x: iconRect.midX - img.size.width * 0.5,
                y: iconRect.midY - img.size.height * 0.5,
                width: img.size.width,
                height: img.size.height
            )
            img.draw(in: drawRect)
        } else if let globe = tintedSymbol("globe", pointSize: 15.0, weight: .regular, color: iconTintColor) {
            let drawRect = NSRect(
                x: iconRect.midX - globe.size.width * 0.5,
                y: iconRect.midY - globe.size.height * 0.5,
                width: globe.size.width,
                height: globe.size.height
            )
            globe.draw(in: drawRect)
        }

        // Optional trailing affordances: subtle return hint on selected row or bookmark star.
        var trailingInset: CGFloat = 12.0
        if active {
            if let retImg = tintedSymbol("return", pointSize: 11.0, weight: .medium, color: NSColor.white.withAlphaComponent(0.85)) {
                let rx = bounds.width - 12.0 - retImg.size.width
                let ry = (bounds.height - retImg.size.height) * 0.5
                retImg.draw(in: NSRect(x: rx, y: ry, width: retImg.size.width, height: retImg.size.height))
                trailingInset = 12.0 + retImg.size.width + 8.0
            }
        } else if item.style == .bookmarkOrHistory && item.isBookmarked {
            let starColor = isDark ? NSColor(white: 1.0, alpha: 0.34) : NSColor(white: 0.0, alpha: 0.28)
            if let star = tintedSymbol("star.fill", pointSize: 10.0, weight: .regular, color: starColor) {
                let sx = bounds.width - 12.0 - star.size.width
                let sy = (bounds.height - star.size.height) * 0.5
                star.draw(in: NSRect(x: sx, y: sy, width: star.size.width, height: star.size.height))
                trailingInset = 12.0 + star.size.width + 8.0
            }
        }

        let textX: CGFloat = isTwoLine ? (iconRect.maxX + 10.0) : 32.0
        let textW = max(40.0, bounds.width - textX - trailingInset)
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineBreakMode = .byTruncatingTail

        if isTwoLine {
            let titleSize: CGFloat = (item.style == .topHit) ? 13.5 : 13.0
            let titleBaseFont = NSFont.systemFont(ofSize: titleSize, weight: (item.style == .topHit) ? .medium : .regular)
            let titleHighlightFont = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
            let subBaseFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            let subHighlightFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

            let titleAttr = Self.highlightedAttributedString(
                item.title,
                query: query,
                baseFont: titleBaseFont,
                highlightFont: titleHighlightFont,
                color: primaryColor,
                paragraphStyle: pStyle
            )
            let subAttr = Self.highlightedAttributedString(
                item.subtitle,
                query: query,
                baseFont: subBaseFont,
                highlightFont: subHighlightFont,
                color: secondaryColor,
                paragraphStyle: pStyle
            )
            let topY: CGFloat = (bounds.height - 34.0) * 0.5
            titleAttr.draw(in: NSRect(x: textX, y: topY, width: textW, height: 18))
            subAttr.draw(in: NSRect(x: textX, y: topY + 18.0, width: textW, height: 16))
        } else {
            // Single-line search suggestion row: subtle weight emphasis on typed prefix
            let attr = NSMutableAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13.0, weight: .regular),
                .foregroundColor: primaryColor,
                .paragraphStyle: pStyle
            ])
            if let prefixLen = Self.boldPrefixLength(title: item.title, query: query), prefixLen <= attr.length {
                attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 13.0, weight: .medium), range: NSRange(location: 0, length: prefixLen))
            }
            let sz = attr.size()
            attr.draw(in: NSRect(x: textX, y: (bounds.height - sz.height) * 0.5, width: textW, height: sz.height + 2))
        }
    }
}

// MARK: - Full-Bleed Safari Squircle Artwork Helper (Safarium 1:1)

enum PopoverBrandArtwork {
    /// Draws macOS Safari's exact monogram letter squircle when a site has no real `>= 72px` touch icon:
    /// solid extracted-favicon color (or Safari neutral silver-gray) + thin/light centered uppercase initial.
    private static func drawMonogramSquircle(in rect: NSRect, letter: String, backgroundColor: NSColor) {
        backgroundColor.setFill()
        rect.fill()
        let ch = String(letter.prefix(1)).uppercased()
        let font = NSFont.systemFont(ofSize: rect.height * 0.56, weight: .light)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let s = NSString(string: ch)
        let sz = s.size(withAttributes: attrs)
        s.draw(
            at: CGPoint(
                x: rect.midX - sz.width * 0.5,
                y: rect.midY - sz.height * 0.5 - rect.height * 0.015
            ),
            withAttributes: attrs
        )
    }

    /// Renders EVERY favorite using real web-fetched Safari Touch Icons (`FaviconCache.TouchIconResult`) with ZERO hardcoded brand drawings:
    /// 1. Real high-res touch icon (`>= 72px`): opaque icons draw full-bleed; transparent icons sit cleanly on a crisp white squircle.
    /// 2. No high-res touch icon: Safari's native monogram letter tile colored from the site's real favicon pixels (or neutral silver-gray).
    static func drawFavoriteSquircle(
        in rect: NSRect,
        title: String = "",
        urlString: String,
        touchIcon: FaviconCache.TouchIconResult?,
        isDark: Bool
    ) {
        if let result = touchIcon, let img = result.image {
            if result.isOpaque {
                drawAspectFill(img, in: rect)
            } else {
                NSColor.white.setFill()
                rect.fill()
                let targetRect = result.hasTightEdges
                    ? rect.insetBy(dx: round(rect.width * 0.14), dy: round(rect.height * 0.14))
                    : rect
                drawAspectFit(img, in: targetRect)
            }
            return
        }

        // Authentic Safari monogram fallback: real extracted accent color or Safari neutral silver-gray
        let defaultGray = isDark
            ? NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 1.0)
            : NSColor(srgbRed: 0.847, green: 0.847, blue: 0.859, alpha: 1.0)
        let bg = touchIcon?.accentColor ?? defaultGray

        drawMonogramSquircle(in: rect, letter: monogramInitial(title: title, urlString: urlString), backgroundColor: bg)
    }

    /// Monogram letter: first letter/number of the title, else of the domain, else "W".
    static func monogramInitial(title: String, urlString: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstAlpha = trimmedTitle.first(where: { $0.isLetter || $0.isNumber }) {
            return String(firstAlpha).uppercased()
        }
        guard let parsed = URL(string: urlString), parsed.host?.isEmpty == false else { return "W" }
        let dom = URLInputNormalizer.displayDomain(for: parsed)
            .replacingOccurrences(of: "www.", with: "")
        if let firstHost = dom.first(where: { $0.isLetter || $0.isNumber }) {
            return String(firstHost).uppercased()
        }
        return "W"
    }

    private static func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        image.draw(in: AddressBarPopoverController.aspectFillRect(for: image.size, in: rect) ?? rect)
    }

    private static func drawAspectFit(_ image: NSImage, in rect: NSRect) {
        image.draw(in: AddressBarPopoverController.aspectFitRect(for: image.size, in: rect) ?? rect)
    }

    static func drawSiteBadge(in rect: NSRect, urlString: String, favicon: NSImage?, isDark: Bool) {
        if let favicon {
            NSColor.white.setFill()
            rect.fill()
            let inset = round(rect.width * 0.12)
            favicon.draw(in: rect.insetBy(dx: inset, dy: inset))
            return
        }
        (isDark ? NSColor(white: 0.22, alpha: 0.9) : NSColor(white: 1.0, alpha: 0.9)).setFill()
        rect.fill()
        if let globe = tintedSymbol("globe", pointSize: rect.width * 0.55, weight: .regular, color: .secondaryLabelColor) {
            let sz = globe.size
            globe.draw(in: NSRect(x: rect.midX - sz.width * 0.5, y: rect.midY - sz.height * 0.5, width: sz.width, height: sz.height))
        }
    }
}

func tintedSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let base = AssetLoader.shared.symbol(named: name, pointSize: pointSize, weight: weight)
    let img = NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    img.isTemplate = false
    return img
}
