import AppKit
import QuartzCore

/// Exact 1:1 macOS 27.3 Safari GPU-Camera Tab Overview Grid ported from Safarium's proven 120Hz camera engine:
/// - Single `gridCanvasView.layer.transform` (`CATransform3D`) maps the active card's snapshot rect (below its 25pt header)
///   pixel-for-pixel onto `fullPageRect` at `progress = 0` and smoothly into its grid slot at `progress = 1`
/// - Zero CPU redraws at 120Hz; SwiftUI-style analytical damped `springZoom` with continuous release velocity handoff
///   and mid-flight finger interruption (`interruptSpringForInteractivePinch`)
/// - 100% edge-to-edge `EdgeToEdgeTopSnapshotView` (zero dark letterbox padding), `#E9E8E8` / `#1C1C1E` backdrop,
///   legible `.darkAqua`/`.aqua` `Search Tabs` pill, `#D6D6D5`/`#2C2C2E` `+` card, zero made-up hover borders
final class TabOverviewView: NSView, NSSearchFieldDelegate {
    struct CardModel {
        let id: String
        let title: String
        let url: URL?
        let favicon: NSImage?
        let snapshot: NSImage?
        let isActive: Bool
        /// Pixel-exact full-resolution copy of the tab's page (preferred over `snapshot` when present), so the card
        /// shows exactly what was on screen and a pinch starts without a jump.
        var frameSurface: IOSurface? = nil
        var frameSize: CGSize = .zero
        /// Live mirror of the tab's web content (active tab only: hidden tabs aren't rendered), drawn over the copy.
        var liveLayer: CALayer? = nil
    }

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onPresentationStateChanged: ((Bool) -> Void)?

    private(set) var isPresented: Bool = false
    private(set) var transitionProgress: CGFloat = 1.0
    private(set) var zoomRect: NSRect = .zero
    private var backdropLevel: CGFloat = 1.0

    private var zoomCardId: String?
    private weak var zoomTargetCard: TabOverviewCardView?
    private var zoomAnchorInDoc: NSRect = .zero
    private var zoomScrollOrigin: NSPoint = .zero

    private struct SpringZoomState {
        let startRect: NSRect
        let targetRect: NSRect
        let startBackdrop: CGFloat
        let targetBackdrop: CGFloat
        let duration: Double
        let omega: Double
        let zeta: Double
        let velocity: Double
        let startTime: CFTimeInterval
        let completion: () -> Void
    }
    private var springDisplayLink: CADisplayLink?
    private var springState: SpringZoomState?

    var isTransitioning: Bool { zoomCardId != nil || springDisplayLink != nil }

    private let backdropView = NSView()
    private let scrollView = NSScrollView()
    private let gridCanvasView = FlippedOverviewCanvas()
    private let searchPillContainer = NSView()
    private let searchIconView = NSImageView()
    private let searchField = NSTextField()

    private var cards: [CardModel] = []
    private var cardViews: [String: TabOverviewCardView] = [:]
    private var addCardView: TabOverviewAddCardView?
    var searchQuery: String = ""
    private var isDarkMode: Bool = false
    var orderedVisibleIDs: [String] = []
    var currentColumnCount: Int = 2
    private var keyboardSelectedIndex: Int = -1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        springDisplayLink?.invalidate()
        springDisplayLink = nil
        releaseCachedCards()
    }

    /// Releases all card views, snapshot references, and GPU layer textures when overview is closed.
    func releaseCachedCards() {
        for card in cardViews.values {
            card.setSnapshot(nil)
            card.removeFromSuperview()
        }
        for sub in gridCanvasView.subviews {
            sub.removeFromSuperview()
        }
        cardViews.removeAll()
        cards.removeAll()
        orderedVisibleIDs.removeAll()
        addCardView = nil
        zoomTargetCard = nil
        zoomCardId = nil
    }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.wantsLayer = true
        addSubview(backdropView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.wantsLayer = true
        addSubview(scrollView)

        gridCanvasView.wantsLayer = true
        scrollView.documentView = gridCanvasView

        // Top-right `Search Tabs` rounded pill (184 × 24 pt, r = 12 pt, 8 pt below toolbar, 12 pt from right)
        searchPillContainer.translatesAutoresizingMaskIntoConstraints = false
        searchPillContainer.wantsLayer = true
        searchPillContainer.layer?.cornerRadius = 12.0
        searchPillContainer.layer?.cornerCurve = .continuous
        searchPillContainer.layer?.borderWidth = 0.5
        addSubview(searchPillContainer)

        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.image = AssetLoader.shared.symbol(named: "magnifyingglass", pointSize: 11.5, weight: .medium)
        searchPillContainer.addSubview(searchIconView)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
        searchField.delegate = self
        searchPillContainer.addSubview(searchField)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchPillContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchPillContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchPillContainer.widthAnchor.constraint(equalToConstant: 184),
            searchPillContainer.heightAnchor.constraint(equalToConstant: 24),

            searchIconView.leadingAnchor.constraint(equalTo: searchPillContainer.leadingAnchor, constant: 8),
            searchIconView.centerYAnchor.constraint(equalTo: searchPillContainer.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 13),
            searchIconView.heightAnchor.constraint(equalToConstant: 13),

            searchField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 5),
            searchField.trailingAnchor.constraint(equalTo: searchPillContainer.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchPillContainer.centerYAnchor)
        ])

        applyThemeStyle()
    }

    func apply(theme: AdaptiveChromeTheme) {
        self.isDarkMode = theme.prefersLightInk
        applyThemeStyle()
        for card in cardViews.values {
            card.applyDarkMode(isDarkMode)
        }
        addCardView?.applyDarkMode(isDarkMode)
    }

    private func applyThemeStyle() {
        backdropView.layer?.backgroundColor = isDarkMode
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1.0).cgColor
            : NSColor(srgbRed: 0.914, green: 0.910, blue: 0.910, alpha: 1.0).cgColor

        searchPillContainer.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)
        searchPillContainer.layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.white.withAlphaComponent(0.95).cgColor
        searchPillContainer.layer?.borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.18).cgColor
            : NSColor.black.withAlphaComponent(0.14).cgColor
        searchIconView.contentTintColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.75)
            : NSColor.black.withAlphaComponent(0.45)
        searchField.textColor = isDarkMode ? .white : .black
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search Tabs",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.0, weight: .regular),
                .foregroundColor: isDarkMode
                    ? NSColor.white.withAlphaComponent(0.62)
                    : NSColor.black.withAlphaComponent(0.44)
            ]
        )
    }

    func update(cards: [CardModel]) {
        self.cards = cards
        rebuildGrid()
    }

    func updateSnapshot(_ image: NSImage?, forTabID id: String) {
        if let idx = cards.firstIndex(where: { $0.id == id }) {
            let old = cards[idx]
            cards[idx] = CardModel(id: old.id, title: old.title, url: old.url, favicon: old.favicon, snapshot: image, isActive: old.isActive)
        }
        cardViews[id]?.setSnapshot(image)
    }

    /// Replaces a card's picture with the tab's exact frame copy.
    func updateFrameSurface(_ surface: IOSurface, size: CGSize, forTabID id: String) {
        if let idx = cards.firstIndex(where: { $0.id == id }) {
            cards[idx].frameSurface = surface
            cards[idx].frameSize = size
        }
        cardViews[id]?.setFrameSurface(surface, size: size)
    }

    // MARK: - Safarium 120Hz GPU-Camera Page <-> Grid Zoom Geometry

    var fullPageRect: NSRect {
        NSRect(x: 0, y: 0, width: max(1, bounds.width), height: max(1, bounds.height))
    }

    /// Resting thumbnail rect (in `self` coordinates, below the 25pt card header) for `tabId`.
    func cardRect(for tabId: String?) -> NSRect {
        if let tabId, let card = cardViews[tabId] {
            let scrollOrig = scrollView.contentView.bounds.origin
            let f = card.frame
            let hh: CGFloat = TabOverviewCardView.headerHeight
            return NSRect(
                x: f.minX - scrollOrig.x,
                y: f.minY + hh - scrollOrig.y,
                width: max(1, f.width),
                height: max(1, f.height - hh)
            )
        }
        let p = fullPageRect
        let w = p.width * 0.35
        let h = w / 1.54
        return NSRect(x: p.midX - w * 0.5, y: p.midY - h * 0.5, width: w, height: h)
    }

    /// Returns the tab card ID under a window point (for cursor-targeted pinch-in zoom from Tab Overview).
    func tabId(atWindowPoint ptInWindow: NSPoint) -> String? {
        let ptInCanvas = gridCanvasView.convert(ptInWindow, from: nil)
        for (id, card) in cardViews {
            if card.frame.contains(ptInCanvas) {
                return id
            }
        }
        return nil
    }

    func beginZoomTransition(cards: [CardModel], tabId: String?, progress: CGFloat) {
        springDisplayLink?.invalidate()
        springDisplayLink = nil
        springState = nil

        if let prev = zoomTargetCard {
            prev.setZoomPresentation(cardProgress: 1.0)
            prev.layer?.zPosition = 0
        }

        self.cards = cards
        self.searchQuery = ""
        self.searchField.stringValue = ""
        self.keyboardSelectedIndex = -1
        self.zoomCardId = tabId ?? cards.first(where: { $0.isActive })?.id ?? cards.first?.id

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridCanvasView.layer?.transform = CATransform3DIdentity
        layoutSubtreeIfNeeded()
        rebuildGrid()
        // Force immediate card subview layout BEFORE frame 0 so GPU snapshot layers are sized cleanly with zero frame-1 pop
        gridCanvasView.layoutSubtreeIfNeeded()

        let targetCard = zoomCardId.flatMap { cardViews[$0] } ?? cardViews.values.first
        zoomTargetCard = targetCard
        if let card = targetCard {
            card.layer?.zPosition = 20
            let hh = TabOverviewCardView.headerHeight
            zoomAnchorInDoc = NSRect(
                x: card.frame.minX,
                y: card.frame.minY + hh,
                width: max(1, card.frame.width),
                height: max(1, card.frame.height - hh)
            )
        } else {
            let p = fullPageRect
            zoomAnchorInDoc = NSRect(x: p.midX - p.width * 0.175, y: p.midY - p.height * 0.175, width: p.width * 0.35, height: p.height * 0.35)
        }
        zoomScrollOrigin = scrollView.contentView.bounds.origin

        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = false
        scrollView.layer?.masksToBounds = false
        gridCanvasView.layer?.masksToBounds = false

        setTransitionProgress(progress)
        self.isHidden = false
        CATransaction.commit()
    }

    func interruptSpringForInteractivePinch() {
        springDisplayLink?.invalidate()
        springDisplayLink = nil
        springState = nil
    }

    /// Maps `zoomAnchorInDoc` directly onto `rect` (in `self` coordinates) via ONE GPU `CATransform3D` — zero CPU redraws at 120Hz!
    /// Uses exact independent `(kx, ky)` so `zoomAnchorInDoc` settles onto `fullPageRect` with 0.0pt edge error on all 4 sides.
    func setZoomFrame(_ rect: NSRect, backdrop: CGFloat) {
        zoomRect = rect
        backdropLevel = backdrop

        let page = fullPageRect
        let anchorW = max(1, zoomAnchorInDoc.width)
        let anchorH = max(1, zoomAnchorInDoc.height)
        let kx = max(0.2, rect.width / anchorW)
        let ky = max(0.2, rect.height / anchorH)
        let fullK = page.width / anchorW
        let cardProgress: CGFloat = fullK > 1.01
            ? max(0, min(1, (fullK - kx) / (fullK - 1)))
            : max(0, min(1, backdrop))
        transitionProgress = cardProgress

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Real Safari: overview backdrop becomes solid quickly as soon as the page detaches from full-bleed edges
        backdropView.alphaValue = max(0, min(1, cardProgress * 3.2))
        searchPillContainer.alphaValue = max(0, min(1, (cardProgress - 0.45) / 0.45))

        if let layer = gridCanvasView.layer {
            let b = gridCanvasView.bounds
            let ap = layer.anchorPoint
            let ax = zoomAnchorInDoc.minX
            let ay = zoomAnchorInDoc.minY
            let dxDoc = rect.minX + zoomScrollOrigin.x
            let dyDoc = rect.minY + zoomScrollOrigin.y
            let px = ap.x * b.width
            let py = ap.y * b.height
            let tx = dxDoc - px - kx * (ax - px)
            let ty = dyDoc - py - ky * (ay - py)

            var t = CATransform3DMakeTranslation(tx, ty, 0)
            t = CATransform3DScale(t, kx, ky, 1)
            layer.transform = t
        }
        zoomTargetCard?.setZoomPresentation(cardProgress: cardProgress)
        CATransaction.commit()
    }

    func setTransitionProgress(_ raw: CGFloat) {
        let p = max(0, min(1, raw))
        transitionProgress = p
        guard zoomCardId != nil else {
            backdropView.alphaValue = p
            return
        }
        let a = fullPageRect
        let b = cardRect(for: zoomCardId)
        setZoomFrame(
            NSRect(
                x: a.minX + (b.minX - a.minX) * p,
                y: a.minY + (b.minY - a.minY) * p,
                width: a.width + (b.width - a.width) * p,
                height: a.height + (b.height - a.height) * p
            ),
            backdrop: p
        )
    }

    /// Vsync-locked 120Hz `CADisplayLink` analytical damped spring with continuous velocity handoff.
    func springZoom(
        to target: NSRect,
        backdrop: CGFloat,
        duration: Double,
        bounce: Double,
        velocity: Double = 0,
        completion: @escaping () -> Void
    ) {
        springDisplayLink?.invalidate()
        springDisplayLink = nil

        let omega = 2.0 * Double.pi / max(0.05, duration)
        let zeta = max(0.05, 1.0 - bounce)

        springState = SpringZoomState(
            startRect: zoomRect,
            targetRect: target,
            startBackdrop: backdropLevel,
            targetBackdrop: backdrop,
            duration: duration,
            omega: omega,
            zeta: zeta,
            velocity: velocity,
            startTime: CACurrentMediaTime(),
            completion: completion
        )

        let link = displayLink(target: self, selector: #selector(handleSpringDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        link.add(to: .main, forMode: .eventTracking)
        springDisplayLink = link
    }

    @objc private func handleSpringDisplayLink(_ link: CADisplayLink) {
        guard let st = springState else {
            link.invalidate()
            springDisplayLink = nil
            return
        }
        let t = max(0.0, CACurrentMediaTime() - st.startTime)
        let x: Double
        if st.zeta < 1.0 {
            let wd = st.omega * sqrt(1.0 - st.zeta * st.zeta)
            x = exp(-st.zeta * st.omega * t) * (cos(wd * t) + ((st.zeta * st.omega - st.velocity) / wd) * sin(wd * t))
        } else {
            x = exp(-st.omega * t) * (1.0 + (st.omega - st.velocity) * t)
        }
        let f = CGFloat(1.0 - x)
        let done = (t > st.duration * 0.55 && abs(x) < 0.0014) || t > st.duration * 2.6
        let ff: CGFloat = done ? 1.0 : f

        setZoomFrame(
            NSRect(
                x: st.startRect.minX + (st.targetRect.minX - st.startRect.minX) * ff,
                y: st.startRect.minY + (st.targetRect.minY - st.startRect.minY) * ff,
                width: st.startRect.width + (st.targetRect.width - st.startRect.width) * ff,
                height: st.startRect.height + (st.targetRect.height - st.startRect.height) * ff
            ),
            backdrop: st.startBackdrop + (st.targetBackdrop - st.startBackdrop) * max(0, min(1, ff))
        )

        if done {
            let completion = st.completion
            springState = nil
            link.invalidate()
            springDisplayLink = nil
            completion()
        }
    }

    func endZoomTransition(keepPresented: Bool) {
        springDisplayLink?.invalidate()
        springDisplayLink = nil
        springState = nil
        isPresented = keepPresented
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridCanvasView.layer?.transform = CATransform3DIdentity
        if let card = zoomTargetCard {
            card.setZoomPresentation(cardProgress: 1.0)
            card.layer?.zPosition = 0
        }
        zoomTargetCard = nil
        zoomCardId = nil
        zoomAnchorInDoc = .zero
        scrollView.contentView.layer?.masksToBounds = true
        backdropView.alphaValue = 1.0
        searchPillContainer.alphaValue = 1.0
        if !keepPresented {
            isHidden = true
            keyboardSelectedIndex = -1
            releaseCachedCards()
        }
        CATransaction.commit()
        onPresentationStateChanged?(keepPresented)
        if keepPresented {
            // Focus Search Tabs pill (matching macOS Safari Tab Overview) unless user is typing in the address bar.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented, !self.isHidden, let win = self.window else { return }
                let frIsText = (win.firstResponder is NSTextView)
                if !frIsText {
                    win.makeFirstResponder(self.searchField)
                }
            }
        }
    }

    // MARK: - Button / Keyboard Open & Close Convenience

    func openAnimated(cards: [CardModel], completion: (() -> Void)? = nil) {
        isPresented = true
        onPresentationStateChanged?(true)
        let activeId = cards.first(where: { $0.isActive })?.id ?? cards.first?.id
        beginZoomTransition(cards: cards, tabId: activeId, progress: 0.0)
        springZoom(
            to: cardRect(for: activeId),
            backdrop: 1.0,
            duration: 0.38,
            bounce: 0.06
        ) { [weak self] in
            self?.endZoomTransition(keepPresented: true)
            completion?()
        }
    }

    func closeAnimated(selectingTabID targetID: String? = nil, beforeHide: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        guard !isHidden else {
            isPresented = false
            onPresentationStateChanged?(false)
            beforeHide?()
            completion?()
            return
        }
        let chosen = targetID ?? cards.first(where: { $0.isActive })?.id ?? cards.first?.id
        if !isTransitioning {
            beginZoomTransition(cards: cards, tabId: chosen, progress: 1.0)
        }
        isPresented = false
        springZoom(
            to: fullPageRect,
            backdrop: 0.0,
            duration: 0.34,
            bounce: 0.0
        ) { [weak self] in
            // Switch underlying live tab BEFORE hiding overview so the old tab never flashes for a frame!
            beforeHide?()
            self?.endZoomTransition(keepPresented: false)
            completion?()
        }
    }

    func closeAnimatedIntoNewCard(
        _ model: CardModel,
        beforeHide: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard !isHidden else {
            isPresented = false
            onPresentationStateChanged?(false)
            beforeHide?()
            completion?()
            return
        }

        springDisplayLink?.invalidate()
        springDisplayLink = nil
        springState = nil

        if let prev = zoomTargetCard {
            prev.setZoomPresentation(cardProgress: 1.0)
            prev.layer?.zPosition = 0
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        gridCanvasView.layer?.transform = CATransform3DIdentity
        if addCardView == nil {
            searchQuery = ""
            searchField.stringValue = ""
            layoutSubtreeIfNeeded()
            rebuildGrid()
            gridCanvasView.layoutSubtreeIfNeeded()
        }

        let targetFrame: NSRect
        if let addFrame = addCardView?.frame, addFrame.width > 10, addFrame.height > 10 {
            targetFrame = addFrame
        } else {
            let p = fullPageRect
            let w = p.width * 0.35
            let h = w / 1.54 + TabOverviewCardView.headerHeight
            targetFrame = NSRect(x: p.midX - w * 0.5, y: p.midY - h * 0.5, width: w, height: h)
        }

        addCardView?.isHidden = true

        let newCard = TabOverviewCardView(
            model: model,
            isDarkMode: isDarkMode,
            onSelect: {},
            onClose: {}
        )
        newCard.frame = targetFrame
        newCard.layer?.zPosition = 20
        gridCanvasView.addSubview(newCard)
        newCard.layoutSubtreeIfNeeded()

        cards.append(model)
        cardViews[model.id] = newCard
        zoomCardId = model.id
        zoomTargetCard = newCard

        let hh = TabOverviewCardView.headerHeight
        zoomAnchorInDoc = NSRect(
            x: targetFrame.minX,
            y: targetFrame.minY + hh,
            width: max(1, targetFrame.width),
            height: max(1, targetFrame.height - hh)
        )
        zoomScrollOrigin = scrollView.contentView.bounds.origin

        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = false
        scrollView.layer?.masksToBounds = false
        gridCanvasView.layer?.masksToBounds = false

        setTransitionProgress(1.0)
        CATransaction.commit()

        isPresented = false
        springZoom(
            to: fullPageRect,
            backdrop: 0.0,
            duration: 0.34,
            bounce: 0.0
        ) { [weak self] in
            beforeHide?()
            self?.endZoomTransition(keepPresented: false)
            completion?()
        }
    }

    // MARK: - Grid Layout (`04_tab_overview.png` 1:1)

    override func layout() {
        super.layout()
        if !isHidden && !isTransitioning {
            layoutGridCards()
        }
    }

    private func rebuildGrid() {
        for sub in gridCanvasView.subviews {
            sub.removeFromSuperview()
        }
        cardViews.removeAll()
        addCardView = nil

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleCards = q.isEmpty
            ? cards
            : cards.filter {
                $0.title.localizedCaseInsensitiveContains(q) ||
                ($0.url?.absoluteString.localizedCaseInsensitiveContains(q) ?? false)
            }

        let allowClose = cards.count > 1
        for model in visibleCards {
            let card = TabOverviewCardView(
                model: model,
                isDarkMode: isDarkMode,
                showCloseButton: allowClose,
                onSelect: { [weak self] in
                    self?.closeAnimated(
                        selectingTabID: model.id,
                        beforeHide: {
                            self?.onSelectTab?(model.id)
                        }
                    )
                },
                onClose: { [weak self] in
                    self?.onCloseTab?(model.id)
                }
            )
            gridCanvasView.addSubview(card)
            cardViews[model.id] = card
        }

        if q.isEmpty {
            let addCard = TabOverviewAddCardView(isDarkMode: isDarkMode) { [weak self] in
                self?.onNewTab?()
            }
            gridCanvasView.addSubview(addCard)
            self.addCardView = addCard
        }

        layoutGridCards()
    }

    private func layoutGridCards() {
        let viewW = max(bounds.width, 640)
        let viewH = max(bounds.height, 440)

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderedIDs: [String] = cards.compactMap { model in
            cardViews[model.id] != nil ? model.id : nil
        }
        self.orderedVisibleIDs = orderedIDs
        let totalItems = orderedIDs.count + (q.isEmpty ? 1 : 0)

        let cols: Int
        if totalItems <= 2 {
            cols = 2
        } else if totalItems <= 6 {
            cols = 3
        } else {
            cols = 4
        }
        self.currentColumnCount = cols
        syncKeyboardSelectionRing()

        let horizontalMargin: CGFloat = (cols == 2) ? 72.0 : 52.0
        let interColGap: CGFloat = (cols == 2) ? 46.0 : 28.0
        let interRowGap: CGFloat = 28.0
        let topMargin: CGFloat = 54.0

        let usableW = max(320, viewW - horizontalMargin * 2 - interColGap * CGFloat(cols - 1))
        let cardW = floor(min(usableW / CGFloat(cols), (cols == 2) ? 480.0 : 380.0))
        // Match visible viewport aspect ratio so the zoomed card lands 1:1 on the live page with zero bottom gap or distortion
        let viewportAspect = max(1.25, min(1.95, viewW / max(1.0, viewH)))
        let cardH = round(cardW / viewportAspect + TabOverviewCardView.headerHeight)

        let rowWidth = CGFloat(cols) * cardW + CGFloat(cols - 1) * interColGap
        let startX = floor((viewW - rowWidth) / 2.0)

        var maxY: CGFloat = topMargin
        for (idx, id) in orderedIDs.enumerated() {
            let col = idx % cols
            let row = idx / cols
            let x = startX + CGFloat(col) * (cardW + interColGap)
            let y = topMargin + CGFloat(row) * (cardH + interRowGap)
            let frame = NSRect(x: x, y: y, width: cardW, height: cardH)
            cardViews[id]?.frame = frame
            maxY = max(maxY, frame.maxY)
        }

        if let addCardView {
            let idx = orderedIDs.count
            let col = idx % cols
            let row = idx / cols
            let x = startX + CGFloat(col) * (cardW + interColGap)
            let y = topMargin + CGFloat(row) * (cardH + interRowGap)
            addCardView.frame = NSRect(x: x, y: y, width: cardW, height: cardH)
            maxY = max(maxY, y + cardH)
        }

        gridCanvasView.frame = NSRect(x: 0, y: 0, width: viewW, height: max(viewH, maxY + 60))
    }

    func controlTextDidChange(_ obj: Notification) {
        searchQuery = searchField.stringValue
        keyboardSelectedIndex = 0
        rebuildGrid()
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let activeTextView = window?.firstResponder as? NSTextView
        let isEditingSearch = (activeTextView?.delegate as? NSTextField === searchField)
        // If the user is typing in another text field (e.g. the toolbar address bar), never steal keys!
        if activeTextView != nil && !isEditingSearch {
            return false
        }

        switch event.keyCode {
        case 53: // Escape
            if !searchQuery.isEmpty {
                searchField.stringValue = ""
                searchQuery = ""
                keyboardSelectedIndex = -1
                rebuildGrid()
                return true
            }
            closeAnimated(completion: { [weak self] in self?.onDismiss?() })
            return true

        case 123, 124, 125, 126: // Left, Right, Down, Up
            guard !orderedVisibleIDs.isEmpty else { return false }
            let count = orderedVisibleIDs.count
            let cols = max(1, currentColumnCount)
            if keyboardSelectedIndex < 0 || keyboardSelectedIndex >= count {
                keyboardSelectedIndex = orderedVisibleIDs.firstIndex(where: { id in
                    cards.first(where: { $0.id == id })?.isActive == true
                }) ?? 0
            } else {
                switch event.keyCode {
                case 123: keyboardSelectedIndex = max(0, keyboardSelectedIndex - 1)
                case 124: keyboardSelectedIndex = min(count - 1, keyboardSelectedIndex + 1)
                case 126: keyboardSelectedIndex = max(0, keyboardSelectedIndex - cols)
                case 125: keyboardSelectedIndex = min(count - 1, keyboardSelectedIndex + cols)
                default: break
                }
            }
            syncKeyboardSelectionRing()
            return true

        case 36, 76: // Return / Enter
            guard !orderedVisibleIDs.isEmpty else { return false }
            let idx = (keyboardSelectedIndex >= 0 && keyboardSelectedIndex < orderedVisibleIDs.count) ? keyboardSelectedIndex : 0
            let targetID = orderedVisibleIDs[idx]
            closeAnimated(selectingTabID: targetID, beforeHide: { [weak self] in
                self?.onSelectTab?(targetID)
            })
            return true

        case 51, 117: // Backspace / Forward Delete (when not typing in Search Tabs)
            guard !isEditingSearch,
                  keyboardSelectedIndex >= 0,
                  keyboardSelectedIndex < orderedVisibleIDs.count else { return false }
            let targetID = orderedVisibleIDs[keyboardSelectedIndex]
            onCloseTab?(targetID)
            return true

        default:
            // Type-to-filter: any plain printable character focuses Search Tabs automatically
            if !isEditingSearch,
               !mods.contains(.command), !mods.contains(.control), !mods.contains(.option),
               let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                window?.makeFirstResponder(searchField)
                searchField.stringValue += chars
                searchQuery = searchField.stringValue
                keyboardSelectedIndex = 0
                rebuildGrid()
                if let editor = searchField.currentEditor() {
                    let len = (searchField.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: len, length: 0)
                }
                return true
            }
            return false
        }
    }

    private func syncKeyboardSelectionRing() {
        let selectedID: String? = (keyboardSelectedIndex >= 0 && keyboardSelectedIndex < orderedVisibleIDs.count)
            ? orderedVisibleIDs[keyboardSelectedIndex]
            : nil
        for (id, view) in cardViews {
            view.setKeyboardSelected(id == selectedID)
        }
        if let selectedID, let view = cardViews[selectedID] {
            gridCanvasView.scrollToVisible(view.frame.insetBy(dx: -24, dy: -24))
        }
    }
}

private final class FlippedOverviewCanvas: NSView {
    override var isFlipped: Bool { true }
}

private final class TabOverviewCardView: NSView, NSGestureRecognizerDelegate {
    static let headerHeight: CGFloat = 25.0

    private let onSelect: () -> Void
    private let onClose: () -> Void

    private let cardSurface = NSView()
    private let headerBar = NSView()
    private let headerCenterStack = NSStackView()
    private let faviconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let snapshotView = EdgeToEdgeTopSnapshotView()
    private let fallbackPlaceholder = NSView()
    private var trackingArea: NSTrackingArea?
    private var isDarkMode: Bool
    private var isKeyboardSelected: Bool = false

    func setKeyboardSelected(_ selected: Bool) {
        isKeyboardSelected = selected
        // Never draw a bright blue border around overview cards (matches native Safari Tab Overview).
        cardSurface.layer?.borderWidth = 0.0
        cardSurface.layer?.borderColor = nil
        layer?.shadowOpacity = selected ? 0.28 : 0.14
        layer?.shadowRadius = selected ? 18 : 12
    }

    init(
        model: TabOverviewView.CardModel,
        isDarkMode: Bool,
        showCloseButton: Bool = true,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.isDarkMode = isDarkMode
        super.init(frame: .zero)

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        cardSurface.translatesAutoresizingMaskIntoConstraints = false
        cardSurface.wantsLayer = true
        cardSurface.layer?.cornerRadius = 12.0
        cardSurface.layer?.cornerCurve = .continuous
        cardSurface.layer?.masksToBounds = true
        addSubview(cardSurface)

        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.wantsLayer = true
        cardSurface.addSubview(headerBar)

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyDown
        if let fav = model.favicon {
            faviconView.image = fav
        } else {
            faviconView.image = AssetLoader.shared.symbol(
                named: (model.url?.scheme == "safarium") ? "star" : "globe",
                pointSize: 13.0,
                weight: .regular
            )
            faviconView.contentTintColor = NSColor.secondaryLabelColor
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = model.title.isEmpty ? URLInputNormalizer.displayDomain(for: model.url) : model.title
        titleLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        headerCenterStack.orientation = .horizontal
        headerCenterStack.alignment = .centerY
        headerCenterStack.spacing = 5
        headerCenterStack.translatesAutoresizingMaskIntoConstraints = false
        headerCenterStack.addArrangedSubview(faviconView)
        headerCenterStack.addArrangedSubview(titleLabel)
        headerBar.addSubview(headerCenterStack)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = AssetLoader.shared.symbol(named: "xmark", pointSize: 10.5, weight: .semibold)
        closeButton.isHidden = !showCloseButton
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        headerBar.addSubview(closeButton)

        fallbackPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        fallbackPlaceholder.wantsLayer = true
        cardSurface.addSubview(fallbackPlaceholder)

        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        // Every page (native and web) is drawn behind the toolbar now, so every snapshot carries the toolbar band.
        snapshotView.trimsToolbarTopInset = true
        if let surface = model.frameSurface, model.frameSize.width > 1 {
            snapshotView.setFrameSurface(surface, size: model.frameSize)
        } else {
            snapshotView.snapshotImage = model.snapshot
        }
        snapshotView.setLiveLayer(model.liveLayer)
        cardSurface.addSubview(snapshotView)

        NSLayoutConstraint.activate([
            cardSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardSurface.topAnchor.constraint(equalTo: topAnchor),
            cardSurface.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerBar.leadingAnchor.constraint(equalTo: cardSurface.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: cardSurface.trailingAnchor),
            headerBar.topAnchor.constraint(equalTo: cardSurface.topAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            faviconView.widthAnchor.constraint(equalToConstant: 14),
            faviconView.heightAnchor.constraint(equalToConstant: 14),

            headerCenterStack.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
            headerCenterStack.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerCenterStack.leadingAnchor.constraint(greaterThanOrEqualTo: headerBar.leadingAnchor, constant: showCloseButton ? 28 : 10),
            headerCenterStack.trailingAnchor.constraint(lessThanOrEqualTo: headerBar.trailingAnchor, constant: -10),

            closeButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            fallbackPlaceholder.leadingAnchor.constraint(equalTo: cardSurface.leadingAnchor),
            fallbackPlaceholder.trailingAnchor.constraint(equalTo: cardSurface.trailingAnchor),
            fallbackPlaceholder.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            fallbackPlaceholder.bottomAnchor.constraint(equalTo: cardSurface.bottomAnchor),

            snapshotView.leadingAnchor.constraint(equalTo: cardSurface.leadingAnchor),
            snapshotView.trailingAnchor.constraint(equalTo: cardSurface.trailingAnchor),
            snapshotView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            snapshotView.bottomAnchor.constraint(equalTo: cardSurface.bottomAnchor)
        ])

        applyDarkMode(isDarkMode)

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardTapped))
        click.delegate = self
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func setSnapshot(_ image: NSImage?) {
        snapshotView.snapshotImage = image
    }

    func setFrameSurface(_ surface: IOSurface, size: CGSize) {
        snapshotView.setFrameSurface(surface, size: size)
    }

    func setZoomPresentation(cardProgress p: CGFloat) {
        let clamped = max(0, min(1, p))
        let radius = 12.0 * clamped
        cardSurface.layer?.cornerRadius = radius
        headerBar.alphaValue = max(0, min(1, (clamped - 0.12) / 0.38))
        layer?.shadowOpacity = Float(0.14 * clamped)
        if bounds.width > 1, bounds.height > 1 {
            let r = min(radius, min(bounds.width, bounds.height) * 0.5)
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        }
    }

    override func layout() {
        super.layout()
        if bounds.width > 1, bounds.height > 1 {
            let r = min(cardSurface.layer?.cornerRadius ?? 12.0, min(bounds.width, bounds.height) * 0.5)
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        }
    }

    func applyDarkMode(_ dark: Bool) {
        self.isDarkMode = dark
        headerBar.layer?.backgroundColor = dark
            ? NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1.0).cgColor
            : NSColor.white.cgColor
        fallbackPlaceholder.layer?.backgroundColor = dark
            ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0).cgColor
            : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0).cgColor
        titleLabel.textColor = dark ? NSColor.white.withAlphaComponent(0.92) : NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1.0)
        closeButton.contentTintColor = dark ? NSColor.white.withAlphaComponent(0.76) : NSColor.black.withAlphaComponent(0.62)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let pt = headerBar.convert(event.locationInWindow, from: nil)
        if !closeButton.isHidden && closeButton.frame.insetBy(dx: -4, dy: -4).contains(pt) {
            return false
        }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.contentTintColor = isDarkMode ? .white : .black
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.contentTintColor = isDarkMode ? NSColor.white.withAlphaComponent(0.68) : NSColor.black.withAlphaComponent(0.55)
    }

    @objc private func cardTapped() { onSelect() }
    @objc private func closeTapped() { onClose() }
}

/// Pure GPU `CALayer` Retina tab snapshot (zero CPU redraws at 120Hz) with exact 52pt behind-toolbar top trim
/// so `y = 52..H` of full-bleed `webContentHost`/`startPageView` aligns pixel-for-pixel onto `TabOverviewView`.
private final class EdgeToEdgeTopSnapshotView: NSView {
    private let imageLayer = CALayer()
    private var imagePointSize: CGSize = .zero

    var trimsToolbarTopInset: Bool = false {
        didSet { layoutImageLayer() }
    }

    var snapshotImage: NSImage? {
        didSet { updateImageContents() }
    }

    private var liveLayer: CALayer?

    /// Live web content (a mirror of Chromium's GPU layer) drawn over the snapshot, scaled with one transform.
    func setLiveLayer(_ layer: CALayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer?.removeFromSuperlayer()
        liveLayer = layer
        if let layer {
            layer.anchorPoint = .zero
            self.layer?.addSublayer(layer)
            if imagePointSize.width < 1 { imagePointSize = layer.bounds.size }
            layoutImageLayer()
        }
        CATransaction.commit()
    }

    /// Shows a pixel-exact IOSurface frame copy directly (shared with the window server, no decode or copy).
    func setFrameSurface(_ surface: IOSurface, size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imagePointSize = size
        imageLayer.contents = surface
        layoutImageLayer()
        CATransaction.commit()
    }

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        layoutImageLayer()
    }

    private func updateImageContents() {
        guard let image = snapshotImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            imageLayer.contents = nil
            imagePointSize = .zero
            return
        }
        let ptW = image.size.width > 1 ? image.size.width : CGFloat(cgImage.width) * 0.5
        let ptH = image.size.height > 1 ? image.size.height : CGFloat(cgImage.height) * 0.5
        imagePointSize = CGSize(width: ptW, height: ptH)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = cgImage
        layoutImageLayer()
        CATransaction.commit()
    }

    private func layoutImageLayer() {
        guard imagePointSize.width > 1, imagePointSize.height > 1,
              bounds.width > 1, bounds.height > 1 else {
            return
        }
        // Snapshots are full-bleed (the page runs behind the toolbar); the overview's page rect starts below the
        // toolbar, so the toolbar band is trimmed to line the card up exactly with the live page.
        let topTrimFraction: CGFloat = (trimsToolbarTopInset && imagePointSize.height > SafariMetrics.toolbarHeight + 100.0)
            ? min(0.25, SafariMetrics.toolbarHeight / imagePointSize.height)
            : 0.0
        let visibleH = imagePointSize.height * (1.0 - topTrimFraction)
        let scale = max(bounds.width / imagePointSize.width, bounds.height / max(1.0, visibleH))
        let drawW = imagePointSize.width * scale
        let drawH = imagePointSize.height * scale
        let trimPts = drawH * topTrimFraction
        let drawX = (bounds.width - drawW) * 0.5
        // Non-flipped coords: top of `snapshotView` is `bounds.height`, so shifting up by `trimPts` clips the top 52pt cleanly
        let drawY = (bounds.height + trimPts) - drawH

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)
        if let live = liveLayer, live.bounds.width > 1 {
            // Same rect as the image: the live content keeps its real size and is scaled by one transform.
            live.transform = CATransform3DMakeScale(drawW / live.bounds.width, drawH / max(1, live.bounds.height), 1)
            live.position = CGPoint(x: drawX, y: drawY)
        }
        CATransaction.commit()
    }
}

private final class TabOverviewAddCardView: NSView {
    private let onClick: () -> Void
    private let plusImageView = NSImageView()
    private var isDarkMode: Bool

    init(isDarkMode: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.isDarkMode = isDarkMode
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12.0
        layer?.cornerCurve = .continuous

        plusImageView.translatesAutoresizingMaskIntoConstraints = false
        plusImageView.image = AssetLoader.shared.symbol(named: "plus", pointSize: 46.0, weight: .light)
        plusImageView.imageScaling = .scaleProportionallyDown
        addSubview(plusImageView)

        NSLayoutConstraint.activate([
            plusImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            plusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusImageView.widthAnchor.constraint(equalToConstant: 56),
            plusImageView.heightAnchor.constraint(equalToConstant: 56)
        ])

        applyDarkMode(isDarkMode)

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func applyDarkMode(_ dark: Bool) {
        self.isDarkMode = dark
        layer?.backgroundColor = dark
            ? NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1.0).cgColor
            : NSColor(srgbRed: 0.839, green: 0.839, blue: 0.835, alpha: 1.0).cgColor
        plusImageView.contentTintColor = dark
            ? NSColor(srgbRed: 0.596, green: 0.596, blue: 0.616, alpha: 1.0)
            : NSColor(srgbRed: 0.431, green: 0.431, blue: 0.451, alpha: 1.0)
    }

    @objc private func tapped() { onClick() }
}
