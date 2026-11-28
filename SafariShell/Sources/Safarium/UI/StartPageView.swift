import AppKit
import UniformTypeIdentifiers

/// Native macOS 27.3 Safari Start Page (`safarium://start`) matching `Reference/Screenshots/03_start_page_bookmarks.png`:
/// - Clean `#E5E5E7` default backdrop or optional Safari 27 wallpaper (`safari-extracted/wallpapers/`)
/// - Favorites 8-column crisp white rounded `60×60 pt` tiles with real high-res cached favicons (`FaviconCache`)
/// - Recently Viewed cards updated dynamically from real visited `http`/`https` pages (never `about:blank`)
/// - Exact Safari Privacy Report card + bottom-right `Edit` pill for live wallpaper switching
/// - ZERO invented hover animations/glows/fades
final class StartPageView: NSView {
    struct RecentEntry: Equatable {
        let title: String
        let domain: String
        let url: URL
        let favicon: NSImage?
    }

    var onSelectURL: ((URL) -> Void)?
    var onHoverURL: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onOpenInNewTabGroup: ((URL) -> Void)?
    var onBackdropColorChanged: ((NSColor) -> Void)?
    var onOpenPrivacyReport: (() -> Void)?

    private let wallpaperView = StartPageWallpaperView()
    private let wallpaperTintOverlay = NSView()
    private let scrollView = StartPageScrollView()
    private let documentView = FlippedStartDocView()
    private let contentStack = NSStackView()
    let privateBannerCard = NSView()
    private let favoritesHeaderRow = NSView()
    private let favoritesHeaderLabel = NSTextField(labelWithString: "Favorites")
    private let showAllButton = NSButton()
    private let favoritesGrid = FavoritesReorderGridView()
    var recentHeaderLabel: NSTextField?
    let recentRowStack = NSStackView()
    var privacyHeaderLabel: NSTextField?
    var privacyCardView: NSView?
    private var privacyCardVisualEffect: NSVisualEffectView?
    private var privacyCardTintView: NSView?
    private var privacyShieldImageView: NSImageView?
    private var privacyStatusLabel: NSTextField?
    private var privacyShowMoreButton: NSButton?
    private var privacyPeriodLabel: NSTextField?
    private var privacyStatBoxes: [NSView] = []
    private var privacyStatTitles: [NSTextField] = []
    private var privacyTrackersValueLabel: NSTextField?
    private var privacyPercentValueLabel: NSTextField?
    private var privacyMostTitleLabel: NSTextField?
    private var privacyMostNarrativeLabel: NSTextField?
    private let editButton = NSButton()

    private var isPrivateMode: Bool = false
    private var isFavoritesManuallyExpanded: Bool = false

    private var isBackgroundEnabled: Bool = false
    private var selectedWallpaperID: String? = nil
    private var customWallpaperPath: String? = nil
    private var sampledWallpaperTopColor: NSColor? = nil
    private var showFavoritesSection: Bool = true
    private var showRecentlyViewedSection: Bool = true
    private var showPrivacyReportSection: Bool = true
    private var needsRecentRebuild: Bool = false
    /// Favorites/history changed while hidden (history changes on every page visit): rebuilt when shown.
    private var needsFavoritesRebuild: Bool = false
    private var needsPrivacyRefresh: Bool = false
    private weak var activeEditPopover: NSPopover?
    private var contentTopConstraint: NSLayoutConstraint?
    /// Starts empty: a fresh profile must not show sites that were never visited as "Recently Viewed".
    var recentEntries: [RecentEntry] = []

    private enum PrefKey {
        static let bgEnabled = "Safarium.StartPage.bgEnabled"
        static let wallpaperID = "Safarium.StartPage.wallpaperID"
        static let customPath = "Safarium.StartPage.customWallpaperPath"
        static let showFavorites = "Safarium.StartPage.showFavorites"
        static let showRecent = "Safarium.StartPage.showRecent"
        static let showPrivacy = "Safarium.StartPage.showPrivacy"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        loadPreferences()
        loadInitialRecentFromHistory()
        setupHierarchy()
        rebuildFavorites()
        rebuildRecent()
        refreshPrivacyReport()
        applySectionVisibility()
        applyCurrentWallpaper(notify: false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFavoritesOrHistoryImported),
            name: .safariumFavoritesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFavoritesOrHistoryImported),
            name: .safariumHistoryDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrivacyReportOrSettingsChanged),
            name: .safariumPrivacyReportDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrivacyReportOrSettingsChanged),
            name: .safariumSettingsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleFavoritesOrHistoryImported() {
        // Hidden (a web page is showing): don't rebuild every tile on the main thread in the middle of that page's
        // navigation; do it when the Start Page is shown again.
        if isHiddenOrHasHiddenAncestor {
            needsFavoritesRebuild = true
            return
        }
        needsFavoritesRebuild = false
        if !isPrivateMode { loadInitialRecentFromHistory() }  // private windows never re-seed from shared history
        rebuildFavorites()
        rebuildRecent()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        flushPendingUpdatesIfVisible()
    }

    @objc private func handlePrivacyReportOrSettingsChanged() {
        let apply = { [weak self] in
            guard let self, !self.isPrivateMode else { return }
            if self.isHiddenOrHasHiddenAncestor {
                self.needsPrivacyRefresh = true
            } else {
                self.needsPrivacyRefresh = false
                self.refreshPrivacyReport()
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func loadInitialRecentFromHistory() {
        let history = AssetLoader.shared.browsingHistory()
        guard !history.isEmpty else { return }
        var seenDomains = Set<String>()
        var importedRecents: [RecentEntry] = []
        for h in history {
            guard let u = URL(string: h.url) else { continue }
            let domain = URLInputNormalizer.displayDomain(for: u)
            let key = domain.lowercased()
            guard !seenDomains.contains(key) else { continue }
            seenDomains.insert(key)
            importedRecents.append(RecentEntry(title: h.title, domain: domain, url: u, favicon: nil))
            if importedRecents.count >= 4 { break }
        }
        if !importedRecents.isEmpty {
            recentEntries = importedRecents
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Minimum width that fits the 738 pt Start Page content + 48 pt side margins without shrinking or clipping.
    static let minWidth: CGFloat = 834

    var effectiveTopColor: NSColor {
        guard isBackgroundEnabled else {
            return NSColor(srgbRed: 0.875, green: 0.875, blue: 0.882, alpha: 1.0)
        }
        if let sampledWallpaperTopColor {
            return sampledWallpaperTopColor
        }
        return Self.fallbackTopColor(forWallpaperID: selectedWallpaperID)
    }

    static func fallbackTopColor(forWallpaperID id: String?) -> NSColor {
        switch id {
        case "safari-27-blue": return NSColor(srgbRed: 0.16, green: 0.36, blue: 0.64, alpha: 1.0)
        case "safari-27-orange": return NSColor(srgbRed: 0.78, green: 0.42, blue: 0.22, alpha: 1.0)
        case "safari-27-pink": return NSColor(srgbRed: 0.76, green: 0.38, blue: 0.56, alpha: 1.0)
        case "california-grizzly-bear": return NSColor(srgbRed: 0.22, green: 0.26, blue: 0.24, alpha: 1.0)
        default: return NSColor(srgbRed: 0.24, green: 0.34, blue: 0.44, alpha: 1.0)
        }
    }

    private func loadPreferences() {
        let ud = UserDefaults.standard
        isBackgroundEnabled = ud.bool(forKey: PrefKey.bgEnabled)
        selectedWallpaperID = ud.string(forKey: PrefKey.wallpaperID)
        customWallpaperPath = ud.string(forKey: PrefKey.customPath)
        showFavoritesSection = ud.object(forKey: PrefKey.showFavorites) as? Bool ?? true
        showRecentlyViewedSection = ud.object(forKey: PrefKey.showRecent) as? Bool ?? true
        showPrivacyReportSection = ud.object(forKey: PrefKey.showPrivacy) as? Bool ?? true
    }

    private func savePreferences() {
        let ud = UserDefaults.standard
        ud.set(isBackgroundEnabled, forKey: PrefKey.bgEnabled)
        ud.set(selectedWallpaperID, forKey: PrefKey.wallpaperID)
        ud.set(customWallpaperPath, forKey: PrefKey.customPath)
        ud.set(showFavoritesSection, forKey: PrefKey.showFavorites)
        ud.set(showRecentlyViewedSection, forKey: PrefKey.showRecent)
        ud.set(showPrivacyReportSection, forKey: PrefKey.showPrivacy)
    }

    private func applySectionVisibility() {
        privateBannerCard.isHidden = !isPrivateMode
        favoritesHeaderRow.isHidden = !showFavoritesSection
        favoritesGrid.isHidden = !showFavoritesSection
        let showRecent = showRecentlyViewedSection && (!isPrivateMode || !recentEntries.isEmpty)
        recentHeaderLabel?.isHidden = !showRecent
        recentRowStack.isHidden = !showRecent
        let showPrivacy = !isPrivateMode && showPrivacyReportSection
        privacyHeaderLabel?.isHidden = !showPrivacy
        privacyCardView?.isHidden = !showPrivacy
    }

    func configurePrivateMode(_ enabled: Bool) {
        guard isPrivateMode != enabled else { return }
        isPrivateMode = enabled
        privateBannerCard.isHidden = !enabled
        if enabled {
            // Private windows must never surface persisted browsing history as "Recently Viewed".
            recentEntries.removeAll()
            rebuildRecent()
        }
        refreshPrivacyReport()
        applySectionVisibility()
        rebuildFavorites()
    }

    /// Returns true when the Start Page still has room to scroll in `direction` (`< 0` = down, `> 0` = up).
    func canScrollVertically(direction: Int) -> Bool {
        guard let doc = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let curY = clip.bounds.origin.y
        let maxY = max(0.0, doc.bounds.height - clip.bounds.height)
        return direction > 0 ? (curY > 0.5) : (curY < maxY - 0.5)
    }

    /// Scrolls the Start Page vertically by a precise trackpad-style pixel delta (`deltaY < 0` scrolls down).
    func scrollByDeltaY(_ deltaY: CGFloat) {
        guard let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let curY = clip.bounds.origin.y
        let maxY = max(0.0, doc.bounds.height - clip.bounds.height)
        let nextY = max(0.0, min(maxY, curY - deltaY / max(scrollView.magnification, 0.1)))
        if abs(nextY - curY) > 0.05 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: nextY))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func scrollToEdge(top: Bool) {
        guard let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let targetY = top ? 0.0 : max(0.0, doc.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clip)
    }

    func recordRecentVisit(title: String, url: URL, favicon: NSImage?) {
        guard url.isWebURL,
              let host = url.host, !host.isEmpty else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.lowercased() == "about:blank" { return }
        let domain = URLInputNormalizer.displayDomain(for: url)
        let resolvedTitle = cleanTitle.isEmpty ? domain : cleanTitle
        if let favicon {
            FaviconCache.shared.store(favicon, forURL: url)
        }
        recentEntries.removeAll { $0.domain == domain }
        recentEntries.insert(RecentEntry(title: resolvedTitle, domain: domain, url: url, favicon: favicon), at: 0)
        if recentEntries.count > 4 {
            recentEntries = Array(recentEntries.prefix(4))
        }
        if isHidden {
            needsRecentRebuild = true
        } else {
            needsRecentRebuild = false
            rebuildRecent()
        }
    }

    func flushPendingUpdatesIfVisible() {
        guard !isHidden else { return }
        if needsFavoritesRebuild {
            handleFavoritesOrHistoryImported()
        }
        if needsRecentRebuild {
            needsRecentRebuild = false
            rebuildRecent()
        }
        if needsPrivacyRefresh {
            needsPrivacyRefresh = false
            refreshPrivacyReport()
        }
    }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.875, green: 0.875, blue: 0.882, alpha: 1.0).cgColor

        wallpaperView.translatesAutoresizingMaskIntoConstraints = false
        wallpaperView.isHidden = true
        addSubview(wallpaperView)

        wallpaperTintOverlay.translatesAutoresizingMaskIntoConstraints = false
        wallpaperTintOverlay.wantsLayer = true
        wallpaperTintOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        wallpaperTintOverlay.isHidden = true
        addSubview(wallpaperTintOverlay)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 1.0
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 24
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        // Favorites header row: left "Favorites" + right "Show All >" / "Show Less" toggle
        setupPrivateBannerCard()
        privateBannerCard.isHidden = true
        contentStack.addArrangedSubview(privateBannerCard)

        favoritesHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        favoritesHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        favoritesHeaderLabel.font = NSFont.systemFont(ofSize: 20.0, weight: .bold)
        favoritesHeaderLabel.textColor = NSColor(srgbRed: 0.220, green: 0.239, blue: 0.259, alpha: 1.0)
        favoritesHeaderLabel.tag = 901
        favoritesHeaderRow.addSubview(favoritesHeaderLabel)

        showAllButton.translatesAutoresizingMaskIntoConstraints = false
        showAllButton.isBordered = false
        showAllButton.imagePosition = .imageTrailing
        showAllButton.target = self
        showAllButton.action = #selector(toggleShowAllFavoritesClicked)
        favoritesHeaderRow.addSubview(showAllButton)

        NSLayoutConstraint.activate([
            favoritesHeaderRow.widthAnchor.constraint(equalToConstant: 738),
            favoritesHeaderRow.heightAnchor.constraint(equalToConstant: 26),
            favoritesHeaderLabel.leadingAnchor.constraint(equalTo: favoritesHeaderRow.leadingAnchor),
            favoritesHeaderLabel.centerYAnchor.constraint(equalTo: favoritesHeaderRow.centerYAnchor),
            showAllButton.trailingAnchor.constraint(equalTo: favoritesHeaderRow.trailingAnchor),
            showAllButton.centerYAnchor.constraint(equalTo: favoritesHeaderRow.centerYAnchor)
        ])
        contentStack.addArrangedSubview(favoritesHeaderRow)

        favoritesGrid.translatesAutoresizingMaskIntoConstraints = false
        favoritesGrid.onSelectURL = { [weak self] url in
            self?.onSelectURL?(url)
        }
        favoritesGrid.onHoverURL = { [weak self] url in
            self?.onHoverURL?(url)
        }
        favoritesGrid.onOpenInNewTab = { [weak self] url in
            self?.onOpenInNewTab?(url)
        }
        favoritesGrid.onOpenInNewWindow = { [weak self] url in
            self?.onOpenInNewWindow?(url)
        }
        favoritesGrid.onOpenInNewTabGroup = { [weak self] url in
            self?.onOpenInNewTabGroup?(url)
        }
        favoritesGrid.onReorderCommit = { [weak self] entries in
            AssetLoader.shared.saveFavoritesOrder(entries)
            self?.showAllButton.isHidden = entries.count <= FavoritesReorderGridView.collapsedMaxCount
            self?.updateShowAllButtonStyle()
        }
        favoritesGrid.onExpandStateChanged = { [weak self] in
            self?.updateShowAllButtonStyle()
        }
        contentStack.addArrangedSubview(favoritesGrid)

        let recentHeader = makeSectionHeader("Recently Viewed")
        self.recentHeaderLabel = recentHeader
        contentStack.addArrangedSubview(recentHeader)

        recentRowStack.orientation = .horizontal
        recentRowStack.alignment = .top
        recentRowStack.spacing = 15
        recentRowStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(recentRowStack)

        let privHeader = makeSectionHeader("Privacy Report")
        self.privacyHeaderLabel = privHeader
        contentStack.addArrangedSubview(privHeader)

        let privCard = makePrivacyReportCard()
        self.privacyCardView = privCard
        contentStack.addArrangedSubview(privCard)

        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.isBordered = false
        editButton.wantsLayer = true
        editButton.title = "Edit"
        editButton.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        editButton.contentTintColor = .white
        editButton.layer?.cornerRadius = 13
        editButton.layer?.cornerCurve = .continuous
        editButton.layer?.backgroundColor = NSColor(srgbRed: 0.44, green: 0.44, blue: 0.47, alpha: 0.86).cgColor
        editButton.target = self
        editButton.action = #selector(editWallpaperClicked)
        addSubview(editButton)

        let topC = contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: SafariMetrics.toolbarHeight + 42)
        self.contentTopConstraint = topC
        // Keep StartPage's 834pt minimum below NSLayoutPriority.windowSizeStayPut (500) so opening the
        // 240pt sidebar in a 1024pt window never auto-widens the window, while window.minSize (834pt)
        // still prevents drag-resizing the window narrower than StartPage.
        let minStartWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth)
        minStartWidth.priority = .init(495)
        let docMinWidth = documentView.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth)
        docMinWidth.priority = .init(495)
        let docTrailing = documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor)
        docTrailing.priority = .init(490)
        let stackLead = contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 48)
        stackLead.priority = .init(495)
        let stackTrail = contentStack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -48)
        stackTrail.priority = .init(495)

        NSLayoutConstraint.activate([
            minStartWidth,

            wallpaperView.leadingAnchor.constraint(equalTo: leadingAnchor),
            wallpaperView.trailingAnchor.constraint(equalTo: trailingAnchor),
            wallpaperView.topAnchor.constraint(equalTo: topAnchor),
            wallpaperView.bottomAnchor.constraint(equalTo: bottomAnchor),

            wallpaperTintOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            wallpaperTintOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            wallpaperTintOverlay.topAnchor.constraint(equalTo: topAnchor),
            wallpaperTintOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docTrailing,
            docMinWidth,
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            contentStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 744),
            stackLead,
            stackTrail,
            topC,
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -64),

            editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            editButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            editButton.widthAnchor.constraint(equalToConstant: 54),
            editButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    func setExtraTopInset(_ extra: CGFloat, animated: Bool) {
        let target = SafariMetrics.toolbarHeight + 42 + extra
        guard abs((contentTopConstraint?.constant ?? 0) - target) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                contentTopConstraint?.animator().constant = target
                layoutSubtreeIfNeeded()
            }
        } else {
            contentTopConstraint?.constant = target
        }
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: title)
        lbl.font = NSFont.systemFont(ofSize: 20.0, weight: .bold)
        lbl.textColor = NSColor(srgbRed: 0.220, green: 0.239, blue: 0.259, alpha: 1.0)
        lbl.tag = 901
        return lbl
    }

    private func setupPrivateBannerCard() {
        privateBannerCard.translatesAutoresizingMaskIntoConstraints = false
        privateBannerCard.wantsLayer = true
        privateBannerCard.layer?.cornerRadius = 18
        privateBannerCard.layer?.cornerCurve = .continuous
        privateBannerCard.layer?.backgroundColor = NSColor(srgbRed: 0.133, green: 0.133, blue: 0.137, alpha: 0.96).cgColor
        privateBannerCard.layer?.borderWidth = 0.0

        let heading = NSTextField(labelWithString: "Private Browsing")
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.alignment = .center
        heading.font = NSFont.systemFont(ofSize: 20.0, weight: .bold)
        heading.textColor = NSColor.white.withAlphaComponent(0.95)
        privateBannerCard.addSubview(heading)

        let body = NSTextField(wrappingLabelWithString: "Safarium is designed with privacy in mind by preventing tracking by default. Private Browsing adds additional privacy protections for all tabs in this window. After you close this window, Safarium won’t remember the pages you visited, your search history, or your AutoFill information.")
        body.translatesAutoresizingMaskIntoConstraints = false
        body.alignment = .center
        body.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        body.textColor = NSColor.white.withAlphaComponent(0.70)
        body.maximumNumberOfLines = 4
        privateBannerCard.addSubview(body)

        NSLayoutConstraint.activate([
            privateBannerCard.widthAnchor.constraint(equalToConstant: 738),
            privateBannerCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 118),

            heading.centerXAnchor.constraint(equalTo: privateBannerCard.centerXAnchor),
            heading.topAnchor.constraint(equalTo: privateBannerCard.topAnchor, constant: 22),

            body.centerXAnchor.constraint(equalTo: privateBannerCard.centerXAnchor),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            body.leadingAnchor.constraint(greaterThanOrEqualTo: privateBannerCard.leadingAnchor, constant: 40),
            body.trailingAnchor.constraint(lessThanOrEqualTo: privateBannerCard.trailingAnchor, constant: -40),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            body.bottomAnchor.constraint(equalTo: privateBannerCard.bottomAnchor, constant: -22)
        ])
    }

    /// True only when a wallpaper is configured AND its image could actually be loaded (a deleted file must not
    /// leave white tile titles on the light fallback background).
    private var wallpaperImageLoaded = false
    var hasActiveWallpaper: Bool {
        isBackgroundEnabled && (selectedWallpaperID != nil || customWallpaperPath != nil) && wallpaperImageLoaded
    }

    private func rebuildFavorites() {
        let entries = AssetLoader.shared.favorites()
        let lightInk = hasActiveWallpaper
        let titleCol: NSColor = lightInk ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.20, alpha: 1.0)
        favoritesGrid.configure(
            entries: entries,
            titleColor: titleCol,
            isDarkBackdrop: lightInk,
            expanded: isFavoritesManuallyExpanded
        )
        showAllButton.isHidden = entries.count <= FavoritesReorderGridView.collapsedMaxCount
        updateShowAllButtonStyle()
    }

    @objc private func toggleShowAllFavoritesClicked() {
        isFavoritesManuallyExpanded.toggle()
        favoritesGrid.setExpanded(isFavoritesManuallyExpanded, animated: true)
        updateShowAllButtonStyle()
    }

    private func updateShowAllButtonStyle() {
        let lightInk = hasActiveWallpaper
        let tint: NSColor = lightInk
            ? NSColor.white.withAlphaComponent(0.88)
            : NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
        let title = isFavoritesManuallyExpanded ? "Show Less" : "Show All"
        let symbolName = isFavoritesManuallyExpanded ? "chevron.up" : "chevron.right"
        showAllButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13.0, weight: .regular),
            .foregroundColor: tint
        ])
        showAllButton.image = AssetLoader.shared.symbol(named: symbolName, pointSize: 10.0, weight: .semibold)
        showAllButton.contentTintColor = tint
    }

    private func rebuildRecent() {
        for v in recentRowStack.arrangedSubviews {
            recentRowStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for entry in recentEntries.prefix(3) {
            let card = RecentSiteCardView(entry: entry) { [weak self] in
                self?.onSelectURL?(entry.url)
            }
            recentRowStack.addArrangedSubview(card)
        }
        applySectionVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPrivacyCardAppearance()
    }

    func refreshPrivacyReport(summary providedSummary: PrivacyReportSummary? = nil) {
        needsPrivacyRefresh = false
        let summary = providedSummary ?? (isPrivateMode ? .empty : PrivacyReportStore.shared.summary(days: 30))
        let trackingOn = BrowserSettings.shared.preventCrossSiteTracking

        privacyShieldImageView?.contentTintColor = trackingOn
            ? NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
            : .secondaryLabelColor
        privacyStatusLabel?.stringValue = trackingOn
            ? "Safarium prevents trackers from profiling you."
            : "Cross-site tracking prevention is turned off."
        privacyPeriodLabel?.stringValue = summary.windowDays == 1
            ? "Last 24 hours"
            : "Last \(summary.windowDays) days"

        privacyTrackersValueLabel?.stringValue = "\(summary.uniqueTrackersPrevented)"
        privacyPercentValueLabel?.stringValue = "\(summary.websitesContactingTrackersPercent)%"

        if let top = summary.mostContactedTracker {
            if top.websiteCount > 0 {
                let noun = top.websiteCount == 1 ? "website" : "websites"
                privacyMostNarrativeLabel?.stringValue = "\(top.entityDomain) was prevented from profiling you across \(top.websiteCount) \(noun)"
            } else {
                let reqNoun = top.totalBlockedRequests == 1 ? "request" : "requests"
                privacyMostNarrativeLabel?.stringValue = "\(top.entityDomain) was prevented from profiling you (\(top.totalBlockedRequests) blocked \(reqNoun))"
            }
        } else {
            let windowText = summary.windowDays == 1 ? "24 hours" : "\(summary.windowDays) days"
            privacyMostNarrativeLabel?.stringValue = "No trackers prevented in the last \(windowText)"
        }
    }

    @objc private func showMorePrivacyClicked() {
        onOpenPrivacyReport?()
    }

    private func applyPrivacyCardAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        privacyCardVisualEffect?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        privacyCardVisualEffect?.material = isDark ? .hudWindow : .popover
        privacyCardTintView?.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.16, green: 0.165, blue: 0.18, alpha: 0.84)
            : NSColor.white.withAlphaComponent(0.84)).cgColor
        privacyCardView?.layer?.borderWidth = 0.5
        privacyCardView?.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.11)
            : NSColor.black.withAlphaComponent(0.06)).cgColor

        let primaryInk = isDark ? NSColor.white.withAlphaComponent(0.94) : NSColor(white: 0.133, alpha: 1.0)
        let secondaryInk = isDark ? NSColor.white.withAlphaComponent(0.62) : NSColor(srgbRed: 0.44, green: 0.45, blue: 0.47, alpha: 1.0)
        let tileBg = (isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.035)).cgColor

        privacyStatusLabel?.textColor = primaryInk
        privacyPeriodLabel?.textColor = secondaryInk
        privacyTrackersValueLabel?.textColor = primaryInk
        privacyPercentValueLabel?.textColor = primaryInk
        privacyMostTitleLabel?.textColor = secondaryInk
        privacyMostNarrativeLabel?.textColor = primaryInk
        for box in privacyStatBoxes {
            box.layer?.backgroundColor = tileBg
        }
        for title in privacyStatTitles {
            title.textColor = secondaryInk
        }

        let linkColor: NSColor = isDark ? NSColor.systemBlue : NSColor.controlAccentColor
        privacyShowMoreButton?.attributedTitle = NSAttributedString(
            string: "Show More",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.0, weight: .regular),
                .foregroundColor: linkColor
            ]
        )
    }

    private func makePrivacyReportCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true

        let frost = NSVisualEffectView()
        frost.translatesAutoresizingMaskIntoConstraints = false
        frost.material = .popover
        frost.blendingMode = .withinWindow
        frost.state = .active
        card.addSubview(frost)
        self.privacyCardVisualEffect = frost

        let tint = NSView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true
        frost.addSubview(tint)
        self.privacyCardTintView = tint

        let shield = NSImageView()
        shield.translatesAutoresizingMaskIntoConstraints = false
        shield.image = AssetLoader.shared.symbol(named: "shield.lefthalf.filled", pointSize: 34, weight: .regular)
        shield.imageScaling = .scaleProportionallyDown
        card.addSubview(shield)
        self.privacyShieldImageView = shield

        let desc = NSTextField(wrappingLabelWithString: "Safarium prevents trackers from profiling you.")
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        desc.maximumNumberOfLines = 3
        card.addSubview(desc)
        self.privacyStatusLabel = desc

        let showMore = NSButton()
        showMore.translatesAutoresizingMaskIntoConstraints = false
        showMore.isBordered = false
        showMore.bezelStyle = .inline
        showMore.alignment = .left
        showMore.target = self
        showMore.action = #selector(showMorePrivacyClicked)
        card.addSubview(showMore)
        self.privacyShowMoreButton = showMore

        let period = NSTextField(labelWithString: "Last 30 days")
        period.translatesAutoresizingMaskIntoConstraints = false
        period.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
        card.addSubview(period)
        self.privacyPeriodLabel = period

        privacyStatBoxes.removeAll()
        privacyStatTitles.removeAll()

        let (trackersBox, trackersTitle, trackersValue) = makeStatTile(
            title: "Trackers prevented from profiling you",
            value: "0"
        )
        let (websitesBox, websitesTitle, websitesValue) = makeStatTile(
            title: "Websites that contacted trackers",
            value: "0%"
        )
        self.privacyTrackersValueLabel = trackersValue
        self.privacyPercentValueLabel = websitesValue

        let topRow = NSStackView(views: [trackersBox, websitesBox])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.orientation = .horizontal
        topRow.distribution = .fillEqually
        topRow.alignment = .top
        topRow.spacing = 10
        card.addSubview(topRow)

        let mostBox = NSView()
        mostBox.translatesAutoresizingMaskIntoConstraints = false
        mostBox.wantsLayer = true
        mostBox.layer?.cornerRadius = 12
        mostBox.layer?.cornerCurve = .continuous
        card.addSubview(mostBox)

        let mostTitle = NSTextField(labelWithString: "Most contacted tracker")
        mostTitle.translatesAutoresizingMaskIntoConstraints = false
        mostTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        mostBox.addSubview(mostTitle)
        self.privacyMostTitleLabel = mostTitle

        let mostNarrative = NSTextField(wrappingLabelWithString: "No trackers prevented in the last 30 days")
        mostNarrative.translatesAutoresizingMaskIntoConstraints = false
        mostNarrative.font = NSFont.systemFont(ofSize: 15.0, weight: .bold)
        mostNarrative.maximumNumberOfLines = 3
        mostBox.addSubview(mostNarrative)
        self.privacyMostNarrativeLabel = mostNarrative

        privacyStatBoxes.append(contentsOf: [trackersBox, websitesBox, mostBox])
        privacyStatTitles.append(contentsOf: [trackersTitle, websitesTitle])

        let rightLeading: CGFloat = 308
        let rightTrailing: CGFloat = -20

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 738),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 198),

            frost.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            frost.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            frost.topAnchor.constraint(equalTo: card.topAnchor),
            frost.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            tint.leadingAnchor.constraint(equalTo: frost.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: frost.trailingAnchor),
            tint.topAnchor.constraint(equalTo: frost.topAnchor),
            tint.bottomAnchor.constraint(equalTo: frost.bottomAnchor),

            shield.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            shield.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            shield.widthAnchor.constraint(equalToConstant: 36),
            shield.heightAnchor.constraint(equalToConstant: 36),

            desc.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            desc.topAnchor.constraint(equalTo: shield.bottomAnchor, constant: 20),
            desc.widthAnchor.constraint(equalToConstant: 252),

            showMore.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            showMore.topAnchor.constraint(greaterThanOrEqualTo: desc.bottomAnchor, constant: 12),
            showMore.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            period.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: rightLeading),
            period.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: rightTrailing),
            period.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),

            topRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: rightLeading),
            topRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: rightTrailing),
            topRow.topAnchor.constraint(equalTo: period.bottomAnchor, constant: 8),
            topRow.heightAnchor.constraint(equalToConstant: 86),

            trackersBox.heightAnchor.constraint(equalToConstant: 86),
            websitesBox.heightAnchor.constraint(equalToConstant: 86),

            mostBox.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: rightLeading),
            mostBox.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: rightTrailing),
            mostBox.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            mostBox.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            mostBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            mostTitle.leadingAnchor.constraint(equalTo: mostBox.leadingAnchor, constant: 12),
            mostTitle.trailingAnchor.constraint(equalTo: mostBox.trailingAnchor, constant: -12),
            mostTitle.topAnchor.constraint(equalTo: mostBox.topAnchor, constant: 10),

            mostNarrative.leadingAnchor.constraint(equalTo: mostBox.leadingAnchor, constant: 12),
            mostNarrative.trailingAnchor.constraint(equalTo: mostBox.trailingAnchor, constant: -12),
            mostNarrative.topAnchor.constraint(equalTo: mostTitle.bottomAnchor, constant: 4),
            mostNarrative.bottomAnchor.constraint(equalTo: mostBox.bottomAnchor, constant: -10)
        ])

        applyPrivacyCardAppearance()
        return card
    }

    private func makeStatTile(title: String, value: String) -> (NSView, NSTextField, NSTextField) {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.cornerCurve = .continuous

        let t = NSTextField(wrappingLabelWithString: title)
        t.translatesAutoresizingMaskIntoConstraints = false
        t.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        t.maximumNumberOfLines = 2
        box.addSubview(t)

        let v = NSTextField(labelWithString: value)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.font = NSFont.monospacedDigitSystemFont(ofSize: 22.0, weight: .bold)
        box.addSubview(v)

        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            t.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            t.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            v.topAnchor.constraint(greaterThanOrEqualTo: t.bottomAnchor, constant: 4),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)
        ])
        return (box, t, v)
    }

    @objc private func editWallpaperClicked() {
        if let existing = activeEditPopover, existing.isShown {
            existing.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let popW: CGFloat = 278
        let showRecentToggle = !isPrivateMode || !recentEntries.isEmpty
        let showPrivacyToggle = !isPrivateMode
        let popH: CGFloat = 198 + (showRecentToggle ? 26 : 0) + (showPrivacyToggle ? 26 : 0)
        let container = FlippedStartDocView(frame: NSRect(x: 0, y: 0, width: popW, height: popH))

        var y: CGFloat = 14

        func addDivider(at dy: CGFloat) {
            let line = NSView(frame: NSRect(x: 16, y: dy, width: popW - 32, height: 1))
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
            container.addSubview(line)
        }

        func addSectionHeader(_ text: String, at dy: CGFloat) {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
            lbl.textColor = NSColor.secondaryLabelColor
            lbl.frame = NSRect(x: 16, y: dy, width: popW - 32, height: 16)
            container.addSubview(lbl)
        }

        func addCheckRow(title: String, symbol: String?, checked: Bool, enabled: Bool = true, tag: Int, action: Selector?, at dy: CGFloat) {
            let check = NSButton(checkboxWithTitle: "", target: self, action: action)
            check.state = checked ? .on : .off
            check.isEnabled = enabled
            check.tag = tag
            check.frame = NSRect(x: 16, y: dy + 1, width: 18, height: 18)
            container.addSubview(check)

            var labelX: CGFloat = 40
            if let symbol {
                let iv = NSImageView(frame: NSRect(x: 40, y: dy + 2, width: 16, height: 16))
                iv.image = AssetLoader.shared.symbol(named: symbol, pointSize: 13.0, weight: .regular)
                iv.contentTintColor = enabled ? NSColor.labelColor.withAlphaComponent(0.84) : NSColor.tertiaryLabelColor
                container.addSubview(iv)
                labelX = 63
            }

            let lbl = NSTextField(labelWithString: title)
            lbl.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
            lbl.textColor = enabled ? NSColor.labelColor : NSColor.secondaryLabelColor
            lbl.frame = NSRect(x: labelX, y: dy + 2, width: popW - labelX - 16, height: 17)
            container.addSubview(lbl)
        }

        addSectionHeader("Sections", at: y)
        y += 22
        addCheckRow(title: "Favorites", symbol: "star", checked: showFavoritesSection, tag: 101, action: #selector(toggleSectionCheckbox(_:)), at: y)
        if showRecentToggle {
            y += 26
            addCheckRow(title: "Recently Viewed", symbol: "rectangle.stack", checked: showRecentlyViewedSection, tag: 102, action: #selector(toggleSectionCheckbox(_:)), at: y)
        }
        if showPrivacyToggle {
            y += 26
            addCheckRow(title: "Privacy Report", symbol: "shield.lefthalf.filled", checked: showPrivacyReportSection, tag: 104, action: #selector(toggleSectionCheckbox(_:)), at: y)
        }
        y += 28
        addDivider(at: y)
        y += 10

        addCheckRow(title: "Background Image", symbol: "photo", checked: isBackgroundEnabled, tag: 200, action: #selector(toggleBackgroundImageCheckbox(_:)), at: y)
        y += 30

        // Bottom horizontal wallpaper gallery: "+" custom image picker + built-in Safari wallpapers
        let stripScroll = NSScrollView(frame: NSRect(x: 16, y: y, width: popW - 32, height: 68))
        stripScroll.drawsBackground = false
        stripScroll.hasHorizontalScroller = false
        stripScroll.hasVerticalScroller = false

        let wallIDs = AssetLoader.shared.availableWallpaperIDs()
        let tileW: CGFloat = 104
        let tileH: CGFloat = 64
        let tileGap: CGFloat = 10
        let totalTiles = 1 + wallIDs.count
        let docW = max(popW - 32, CGFloat(totalTiles) * tileW + CGFloat(max(0, totalTiles - 1)) * tileGap)
        let stripDoc = FlippedStartDocView(frame: NSRect(x: 0, y: 0, width: docW, height: tileH))

        // "+" Custom image picker tile
        let addBtn = NSButton(frame: NSRect(x: 0, y: 0, width: tileW, height: tileH))
        addBtn.isBordered = false
        addBtn.title = ""
        addBtn.wantsLayer = true
        addBtn.layer?.cornerRadius = 11
        addBtn.layer?.cornerCurve = .continuous
        addBtn.layer?.masksToBounds = true
        let isCustomActive = isBackgroundEnabled && customWallpaperPath != nil && selectedWallpaperID == nil
        addBtn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        addBtn.layer?.borderWidth = isCustomActive ? 2.5 : 1.0
        addBtn.layer?.borderColor = isCustomActive ? NSColor.controlAccentColor.cgColor : NSColor.black.withAlphaComponent(0.10).cgColor
        addBtn.image = AssetLoader.shared.symbol(named: "plus", pointSize: 18, weight: .medium)
        addBtn.contentTintColor = NSColor.labelColor.withAlphaComponent(0.70)
        addBtn.target = self
        addBtn.action = #selector(chooseCustomWallpaperClicked)
        stripDoc.addSubview(addBtn)

        // Built-in Safari wallpaper tiles (GPU aspect-fill layer so tiles never stretch or distort)
        for (idx, wallID) in wallIDs.enumerated() {
            let x = CGFloat(idx + 1) * (tileW + tileGap)
            let isSelected = isBackgroundEnabled && selectedWallpaperID == wallID
            let tile = WallpaperThumbnailButton(
                frame: NSRect(x: x, y: 0, width: tileW, height: tileH),
                image: AssetLoader.shared.wallpaper(named: wallID, thumbnail: true),
                selected: isSelected
            )
            tile.tag = idx
            tile.target = self
            tile.action = #selector(selectWallpaperButton(_:))
            stripDoc.addSubview(tile)
        }

        stripScroll.documentView = stripDoc
        container.addSubview(stripScroll)

        vc.view = container
        popover.contentViewController = vc
        activeEditPopover = popover
        popover.show(relativeTo: editButton.bounds, of: editButton, preferredEdge: .maxY)
    }

    @objc private func toggleSectionCheckbox(_ sender: NSButton) {
        let on = (sender.state == .on)
        switch sender.tag {
        case 101: showFavoritesSection = on
        case 102: showRecentlyViewedSection = on
        case 104: showPrivacyReportSection = on
        default: break
        }
        savePreferences()
        applySectionVisibility()
    }

    @objc private func toggleBackgroundImageCheckbox(_ sender: NSButton) {
        let enabled = (sender.state == .on)
        isBackgroundEnabled = enabled
        if enabled && selectedWallpaperID == nil && customWallpaperPath == nil {
            selectedWallpaperID = AssetLoader.shared.availableWallpaperIDs().first
        }
        savePreferences()
        applyCurrentWallpaper(notify: true)
    }

    @objc private func chooseCustomWallpaperClicked() {
        let panel = NSOpenPanel()
        panel.title = "Choose Start Page Background"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        let handleSelection: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.customWallpaperPath = url.path
            self.selectedWallpaperID = nil
            self.isBackgroundEnabled = true
            self.savePreferences()
            self.applyCurrentWallpaper(notify: true)
        }
        if let win = self.window {
            activeEditPopover?.performClose(nil)
            panel.beginSheetModal(for: win, completionHandler: handleSelection)
        } else {
            handleSelection(panel.runModal())
        }
    }

    @objc private func selectWallpaperButton(_ sender: NSButton) {
        let wallIDs = AssetLoader.shared.availableWallpaperIDs()
        guard sender.tag >= 0 && sender.tag < wallIDs.count else { return }
        selectedWallpaperID = wallIDs[sender.tag]
        customWallpaperPath = nil
        isBackgroundEnabled = true
        savePreferences()
        applyCurrentWallpaper(notify: true)
        // Refresh selection rings in open popover
        if let content = activeEditPopover?.contentViewController?.view {
            for sv in content.subviews {
                if let scroll = sv as? NSScrollView, let doc = scroll.documentView {
                    for child in doc.subviews {
                        if let tile = child as? WallpaperThumbnailButton {
                            tile.setSelected(tile.tag == sender.tag)
                        } else if let btn = child as? NSButton {
                            btn.layer?.borderWidth = 1.0
                            btn.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
                        }
                    }
                }
            }
        }
    }

    private func applyCurrentWallpaper(notify: Bool) {
        var resolvedImage: NSImage? = nil
        if isBackgroundEnabled {
            if let id = selectedWallpaperID {
                resolvedImage = AssetLoader.shared.wallpaper(named: id, thumbnail: false)
                    ?? AssetLoader.shared.wallpaper(named: id, thumbnail: true)
            } else if let path = customWallpaperPath {
                resolvedImage = NSImage(contentsOfFile: path)
            }
        }

        if let img = resolvedImage {
            wallpaperView.setImage(img)
            wallpaperView.isHidden = false
            wallpaperTintOverlay.isHidden = false
            sampledWallpaperTopColor = Self.sampleTopStripColor(from: img)
            wallpaperImageLoaded = true
            updateHeaderTextColor(.white)
        } else {
            wallpaperView.setImage(nil)
            wallpaperView.isHidden = true
            wallpaperTintOverlay.isHidden = true
            sampledWallpaperTopColor = nil
            wallpaperImageLoaded = false
            updateHeaderTextColor(NSColor(srgbRed: 0.220, green: 0.239, blue: 0.259, alpha: 1.0))
        }
        let savedOrigin = scrollView.contentView.bounds.origin
        rebuildFavorites()
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: savedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if notify {
            onBackdropColorChanged?(effectiveTopColor)
        }
    }

    /// Samples the average top-edge color of a wallpaper image safely (tiny 16×4 downscale, zero UI hitch).
    static func sampleTopStripColor(from image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 16
        let h = 4
        let cropH = max(1, Int(Double(cg.height) * 0.08))
        guard let topSlice = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: cropH)) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(topSlice, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rSum: Double = 0, gSum: Double = 0, bSum: Double = 0
        let count = Double(w * h)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            rSum += Double(pixels[i])
            gSum += Double(pixels[i + 1])
            bSum += Double(pixels[i + 2])
        }
        return NSColor(
            srgbRed: CGFloat(rSum / (count * 255.0)),
            green: CGFloat(gSum / (count * 255.0)),
            blue: CGFloat(bSum / (count * 255.0)),
            alpha: 1.0
        )
    }

    private func updateHeaderTextColor(_ color: NSColor) {
        favoritesHeaderLabel.textColor = color
        for view in contentStack.arrangedSubviews {
            if let lbl = view as? NSTextField, lbl.tag == 901 {
                lbl.textColor = color
            }
        }
        updateShowAllButtonStyle()
    }
}

/// Zero-intrinsic-size GPU aspect-fill wallpaper layer.
/// Never expands Auto Layout or resizes the NSWindow regardless of image pixel dimensions (e.g. 6016×3384).
private final class StartPageWallpaperView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer?.contents = cg
        } else {
            layer?.contents = nil
        }
        CATransaction.commit()
    }
}

/// Rounded aspect-fill wallpaper thumbnail button inside the Start Page Edit popover.
private final class WallpaperThumbnailButton: NSButton {
    private let thumbLayer = CALayer()

    init(frame: NSRect, image: NSImage?, selected: Bool) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        thumbLayer.frame = bounds
        thumbLayer.contentsGravity = .resizeAspectFill
        thumbLayer.masksToBounds = true
        if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            thumbLayer.contents = cg
        }
        layer?.addSublayer(thumbLayer)
        setSelected(selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        thumbLayer.frame = bounds
    }

    func setSelected(_ selected: Bool) {
        layer?.borderWidth = selected ? 2.5 : 1.0
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.black.withAlphaComponent(0.12).cgColor
    }
}

private final class FlippedStartDocView: NSView {
    override var isFlipped: Bool { true }
}

/// Interactive macOS 27.3 Safari Favorites 8-column grid matching `Screen_Recording_2026-11-25_at_07.16.47.mov`:
/// - Smooth live drag-and-drop reordering across rows & columns with fluid cubic ease-out neighbor reflow
/// - Collapsed 2-row (`16` tiles) view that smoothly auto-expands on drag start (or manual `Show All >`)
///   and smoothly collapses rows 3+ with opacity fade-out while sliding `Recently Viewed` & `Privacy Report` back up
final class FavoritesReorderGridView: NSView {
    static let columns: Int = 8
    static let collapsedMaxRows: Int = 2
    static let collapsedMaxCount: Int = columns * collapsedMaxRows
    static let tileSize: CGFloat = 72.0
    static let tileWidth: CGFloat = 80.0
    static let tileHeight: CGFloat = 108.0
    static let columnSpacing: CGFloat = 14.0
    static let rowSpacing: CGFloat = 16.0
    static let colPitch: CGFloat = tileWidth + columnSpacing // 94 pt -> 8*80 + 7*14 = 738 pt
    static let rowPitch: CGFloat = tileHeight + rowSpacing   // 124 pt
    static let gridWidth: CGFloat = CGFloat(columns) * tileWidth + CGFloat(columns - 1) * columnSpacing

    var onSelectURL: ((URL) -> Void)?
    var onHoverURL: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onOpenInNewTabGroup: ((URL) -> Void)?
    var onReorderCommit: (([AssetLoader.BookmarkEntry]) -> Void)?
    var onExpandStateChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    private var entries: [AssetLoader.BookmarkEntry] = []
    private var tileViews: [FavoriteTileView] = []
    private var isExpanded: Bool = false
    private var heightConstraint: NSLayoutConstraint?
    private var contextMenuEntryID: String?
    private var prewarmTrackingArea: NSTrackingArea?
    private var hoveredTileIndex: Int?
    private var hoverPrewarmWorkItem: DispatchWorkItem?

    // Live drag state
    private var pressedTile: FavoriteTileView?
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        let hc = heightAnchor.constraint(equalToConstant: Self.height(forVisibleRows: 2))
        self.heightConstraint = hc
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.gridWidth),
            hc
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    static func height(forVisibleRows rows: Int) -> CGFloat {
        let r = max(1, rows)
        return CGFloat(r) * tileHeight + CGFloat(r - 1) * rowSpacing
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
            x: CGFloat(col) * Self.colPitch,
            y: CGFloat(row) * Self.rowPitch,
            width: Self.tileWidth,
            height: Self.tileHeight
        )
    }

    func configure(entries: [AssetLoader.BookmarkEntry], titleColor: NSColor, isDarkBackdrop: Bool = false, expanded: Bool) {
        self.entries = entries
        self.isExpanded = expanded
        for tile in tileViews {
            tile.removeFromSuperview()
        }
        tileViews.removeAll()

        for (idx, entry) in entries.enumerated() {
            let tile = FavoriteTileView(
                title: entry.title,
                urlString: entry.url,
                size: Self.tileSize,
                titleColor: titleColor,
                isDarkBackdrop: isDarkBackdrop,
                onClick: {}
            )
            tile.translatesAutoresizingMaskIntoConstraints = true
            tile.handlesOwnClick = false
            tile.frame = slotRect(for: idx)
            let isOverflow = idx >= Self.collapsedMaxCount
            tile.alphaValue = (!expanded && isOverflow) ? 0.0 : 1.0
            tile.isHidden = (!expanded && isOverflow)
            addSubview(tile)
            tileViews.append(tile)
            if isOptionJiggling {
                tile.setJiggling(true, phaseSeed: idx, animated: false)
            }
        }

        heightConstraint?.constant = Self.height(forVisibleRows: visibleRowCount(expanded: expanded))
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        let targetH = Self.height(forVisibleRows: visibleRowCount(expanded: expanded))

        if !animated {
            heightConstraint?.constant = targetH
            for (idx, tile) in tileViews.enumerated() {
                let hide = !expanded && idx >= Self.collapsedMaxCount
                tile.isHidden = hide
                tile.alphaValue = hide ? 0.0 : 1.0
            }
            return
        }

        if expanded {
            for (idx, tile) in tileViews.enumerated() where idx >= Self.collapsedMaxCount {
                tile.isHidden = false
                tile.alphaValue = 0.0
            }
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            self.heightConstraint?.animator().constant = targetH
            for (idx, tile) in self.tileViews.enumerated() where idx >= Self.collapsedMaxCount {
                tile.animator().alphaValue = expanded ? 1.0 : 0.0
            }
            self.superview?.layoutSubtreeIfNeeded()
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let prewarmTrackingArea {
            removeTrackingArea(prewarmTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        prewarmTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isDragging, !isOptionJiggling else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let idx = tileIndex(at: pt)
        guard idx != hoveredTileIndex else { return }
        hoveredTileIndex = idx
        hoverPrewarmWorkItem?.cancel()
        hoverPrewarmWorkItem = nil
        guard let idx, idx < entries.count, let url = URL(string: entries[idx].url) else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.onHoverURL?(url)
        }
        hoverPrewarmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredTileIndex = nil
        hoverPrewarmWorkItem?.cancel()
        hoverPrewarmWorkItem = nil
    }

    private var middlePressedIndex: Int?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        middlePressedIndex = tileIndex(at: pt)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        let idx = middlePressedIndex
        middlePressedIndex = nil
        let pt = convert(event.locationInWindow, from: nil)
        if let idx, tileIndex(at: pt) == idx, idx < entries.count, let url = URL(string: entries[idx].url) {
            onOpenInNewTab?(url)
        }
    }

    override func mouseDown(with event: NSEvent) {
        hoverPrewarmWorkItem?.cancel()
        hoverPrewarmWorkItem = nil
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
        if idx < entries.count, let prewarmURL = URL(string: entries[idx].url) {
            onHoverURL?(prewarmURL)
        }
        pressedIndex = idx
        pressedTile = tileViews[idx]
        mouseDownPoint = pt
        grabOffset = NSPoint(x: pt.x - tileViews[idx].frame.origin.x, y: pt.y - tileViews[idx].frame.origin.y)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tile = pressedTile, let startIdx = pressedIndex else { return }
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
        let col = max(0, min(Self.columns - 1, Int(floor(center.x / Self.colPitch))))
        let maxRows = visibleRowCount(expanded: isExpanded)
        let row = max(0, min(maxRows - 1, Int(floor(center.y / Self.rowPitch))))
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
                if event.modifierFlags.contains(.command) {
                    onOpenInNewTab?(url)
                } else {
                    onSelectURL?(url)
                }
            }
            return
        }

        endDrag(tile: tile)
    }

    private func beginDrag(tile: FavoriteTileView, index: Int) {
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

        // Auto-expand collapsed Favorites grid during drag (matching real macOS 27.3 Safari!)
        if !isExpanded && entries.count > Self.collapsedMaxCount {
            didAutoExpandForDrag = true
            setExpanded(true, animated: true)
        }
    }

    private func movePlaceholder(from oldIdx: Int, to newIdx: Int, draggedTile: FavoriteTileView) {
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

    private func endDrag(tile: FavoriteTileView) {
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

    // MARK: - Native Right-Click Context Menu (macOS 27 Safari)

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
        let alert = NSAlert()
        alert.messageText = "Rename Favorite"
        alert.informativeText = "Enter a new name for this favorite."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = entry.title
        alert.accessoryView = input

        let applyRename: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newTitle = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newTitle.isEmpty, idx < self.entries.count, self.entries[idx].id == entry.id else { return }
            self.entries[idx].title = newTitle
            self.tileViews[idx].update(title: newTitle, urlString: self.entries[idx].url)
            self.onReorderCommit?(self.entries)
        }

        if let win = self.window {
            alert.beginSheetModal(for: win) { response in
                applyRename(response)
            }
            win.makeFirstResponder(input)
        } else {
            applyRename(alert.runModal())
        }
    }

    @objc private func contextEditAddress() {
        guard let (idx, entry) = currentContextEntry() else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Address"
        alert.informativeText = "Enter the web address for “\(entry.title)”."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = entry.url
        alert.accessoryView = input

        let applyEdit: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, idx < self.entries.count, self.entries[idx].id == entry.id else { return }
            let normalized = URLInputNormalizer.normalize(raw).absoluteString
            self.entries[idx].url = normalized
            self.tileViews[idx].update(title: self.entries[idx].title, urlString: normalized)
            self.onReorderCommit?(self.entries)
        }

        if let win = self.window {
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

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            removedTile.animator().alphaValue = 0.0
            self.heightConstraint?.animator().constant = targetH
            for (i, tile) in self.tileViews.enumerated() {
                let shouldHide = !self.isExpanded && i >= Self.collapsedMaxCount
                if !shouldHide && tile.isHidden {
                    tile.isHidden = false
                    tile.alphaValue = 0.0
                }
                tile.animator().frame = self.slotRect(for: i)
                tile.animator().alphaValue = shouldHide ? 0.0 : 1.0
            }
            self.superview?.layoutSubtreeIfNeeded()
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

/// Exact 1:1 macOS 27 Safari `72×72 pt` uniform continuous rounded-square Favorites tile (`cornerRadius = 16 pt`,
/// `layer.cornerCurve = .continuous`, uniform elevation shadow, zero circles or inconsistent silhouettes!).
final class FavoriteTileView: NSView {
    private var title: String
    private var urlString: String
    private let tileSize: CGFloat
    private let titleColor: NSColor
    private let onClick: () -> Void
    private var touchIcon: FaviconCache.TouchIconResult?

    private let jiggleHost = FlippedStartDocView()
    private let shadowHost = NSView()
    private let squircleArtworkView = SquircleArtworkCanvasView()
    private let deleteBadgeView = NSView()
    private let deleteBadgeIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isJiggling: Bool = false

    override var isFlipped: Bool { true }

    init(title: String, urlString: String, size: CGFloat = 72.0, titleColor: NSColor? = nil, isDarkBackdrop: Bool = false, onClick: @escaping () -> Void) {
        self.title = title
        self.urlString = urlString
        self.tileSize = size
        self.titleColor = titleColor ?? NSColor(white: 0.20, alpha: 1.0)
        self.onClick = onClick
        self.touchIcon = FaviconCache.shared.cachedTouchIcon(forURLString: urlString)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false

        let cornerRadius: CGFloat = round(size * (16.0 / 72.0)) // exact 16pt at 72x72

        clipsToBounds = false
        jiggleHost.translatesAutoresizingMaskIntoConstraints = false
        jiggleHost.wantsLayer = true
        jiggleHost.clipsToBounds = false
        jiggleHost.layer?.masksToBounds = false
        addSubview(jiggleHost)

        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.wantsLayer = true
        shadowHost.clipsToBounds = false
        shadowHost.layer?.masksToBounds = false
        shadowHost.layer?.cornerRadius = cornerRadius
        shadowHost.layer?.cornerCurve = .continuous
        shadowHost.layer?.backgroundColor = NSColor.clear.cgColor
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.08
        shadowHost.layer?.shadowRadius = 6.0
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadowHost.layer?.shadowPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        jiggleHost.addSubview(shadowHost)

        squircleArtworkView.translatesAutoresizingMaskIntoConstraints = false
        squircleArtworkView.wantsLayer = true
        squircleArtworkView.layer?.cornerRadius = cornerRadius
        squircleArtworkView.layer?.cornerCurve = .continuous
        squircleArtworkView.layer?.masksToBounds = true
        squircleArtworkView.title = title
        squircleArtworkView.urlString = urlString
        squircleArtworkView.touchIcon = touchIcon
        shadowHost.addSubview(squircleArtworkView)

        deleteBadgeView.translatesAutoresizingMaskIntoConstraints = false
        deleteBadgeView.wantsLayer = true
        deleteBadgeView.layer?.cornerRadius = 10.0
        deleteBadgeView.layer?.backgroundColor = (isDarkBackdrop
            ? NSColor(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 0.96)
            : NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 0.90)).cgColor
        deleteBadgeView.layer?.borderWidth = 0.5
        deleteBadgeView.layer?.borderColor = (isDarkBackdrop
            ? NSColor.black.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.22)).cgColor
        deleteBadgeView.layer?.shadowColor = NSColor.black.cgColor
        deleteBadgeView.layer?.shadowOpacity = 0.28
        deleteBadgeView.layer?.shadowRadius = 2.5
        deleteBadgeView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        deleteBadgeView.alphaValue = 0.0
        deleteBadgeView.isHidden = true
        jiggleHost.addSubview(deleteBadgeView)

        deleteBadgeIcon.translatesAutoresizingMaskIntoConstraints = false
        deleteBadgeIcon.image = AssetLoader.shared.symbol(named: "xmark", pointSize: 9.0, weight: .bold)
        deleteBadgeIcon.contentTintColor = isDarkBackdrop
            ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 0.95)
            : NSColor.white.withAlphaComponent(0.96)
        deleteBadgeView.addSubview(deleteBadgeIcon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11.0, weight: .regular)
        titleLabel.textColor = self.titleColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size + 8),
            heightAnchor.constraint(equalToConstant: size + 36),

            jiggleHost.topAnchor.constraint(equalTo: topAnchor),
            jiggleHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            jiggleHost.widthAnchor.constraint(equalToConstant: size + 8),
            jiggleHost.heightAnchor.constraint(equalToConstant: size + 8),

            shadowHost.centerXAnchor.constraint(equalTo: jiggleHost.centerXAnchor),
            shadowHost.centerYAnchor.constraint(equalTo: jiggleHost.centerYAnchor),
            shadowHost.widthAnchor.constraint(equalToConstant: size),
            shadowHost.heightAnchor.constraint(equalToConstant: size),

            squircleArtworkView.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            squircleArtworkView.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            squircleArtworkView.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            squircleArtworkView.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            deleteBadgeView.widthAnchor.constraint(equalToConstant: 20),
            deleteBadgeView.heightAnchor.constraint(equalToConstant: 20),
            deleteBadgeView.leadingAnchor.constraint(equalTo: jiggleHost.leadingAnchor, constant: 0),
            deleteBadgeView.topAnchor.constraint(equalTo: jiggleHost.topAnchor, constant: 0),

            deleteBadgeIcon.centerXAnchor.constraint(equalTo: deleteBadgeView.centerXAnchor),
            deleteBadgeIcon.centerYAnchor.constraint(equalTo: deleteBadgeView.centerYAnchor),
            deleteBadgeIcon.widthAnchor.constraint(equalToConstant: 10),
            deleteBadgeIcon.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.topAnchor.constraint(equalTo: shadowHost.bottomAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        if touchIcon == nil {
            FaviconCache.shared.fetchTouchIcon(forURLString: urlString) { [weak self] res in
                guard let self else { return }
                self.touchIcon = res
                self.squircleArtworkView.touchIcon = res
                self.squircleArtworkView.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    var handlesOwnClick: Bool = true

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
                let cx = (tileSize + 8) * 0.5
                let cy = (tileSize + 8) * 0.5
                func wobbleTransform(angle: CGFloat, dx: CGFloat, dy: CGFloat) -> NSValue {
                    var t = CATransform3DIdentity
                    t = CATransform3DTranslate(t, cx + dx, cy + dy, 0)
                    t = CATransform3DRotate(t, angle, 0, 0, 1)
                    t = CATransform3DTranslate(t, -cx, -cy, 0)
                    return NSValue(caTransform3D: t)
                }
                let dir: CGFloat = (phaseSeed % 2 == 0) ? 1.0 : -1.0
                let angle: CGFloat = 0.038 * dir // ~2.2 degrees, classic iOS SpringBoard wobble
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
        titleLabel.stringValue = newTitle
        squircleArtworkView.title = newTitle
        squircleArtworkView.urlString = newURL
        let cached = FaviconCache.shared.cachedTouchIcon(forURLString: newURL)
        touchIcon = cached
        squircleArtworkView.touchIcon = cached
        squircleArtworkView.needsDisplay = true
        if cached == nil {
            FaviconCache.shared.fetchTouchIcon(forURLString: newURL) { [weak self] res in
                guard let self, self.urlString == newURL else { return }
                self.touchIcon = res
                self.squircleArtworkView.touchIcon = res
                self.squircleArtworkView.needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard handlesOwnClick else {
            super.mouseUp(with: event)
            return
        }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }

    override func layout() {
        super.layout()
        let cornerRadius: CGFloat = round(tileSize * (16.0 / 72.0))
        if shadowHost.bounds.width > 0 && shadowHost.bounds.height > 0 {
            shadowHost.layer?.shadowPath = CGPath(
                roundedRect: shadowHost.bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }
    }

    func setDragElevated(_ elevated: Bool, animated: Bool) {
        wantsLayer = true
        layer?.masksToBounds = false
        shadowHost.layer?.masksToBounds = false

        let targetScale: CGFloat = elevated ? 1.06 : 1.0
        let targetShadowOpacity: Float = elevated ? 0.36 : 0.08
        let targetShadowRadius: CGFloat = elevated ? 18.0 : 6.0
        let targetShadowOffset = elevated ? CGSize(width: 0, height: -9) : CGSize(width: 0, height: -2)
        let targetAlpha: CGFloat = elevated ? 0.96 : 1.0

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0.0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0))
        if let l = shadowHost.layer {
            let cornerRadius: CGFloat = round(tileSize * (16.0 / 72.0))
            if l.bounds.width > 0 && l.bounds.height > 0 {
                l.shadowPath = CGPath(roundedRect: l.bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
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
}

private final class SquircleArtworkCanvasView: NSView {
    var title: String = ""
    var urlString: String = ""
    var touchIcon: FaviconCache.TouchIconResult?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        PopoverBrandArtwork.drawFavoriteSquircle(
            in: bounds,
            title: title,
            urlString: urlString,
            touchIcon: touchIcon,
            isDark: false
        )
    }
}

/// Exact 1:1 Safarium tall frosted Recently Viewed card (`236 × 156 pt`, `r = 14 pt`, clock + relative time + `"1 Tab ›"` pill)
private final class RecentSiteCardView: NSView {
    private let entry: StartPageView.RecentEntry
    private let onClick: () -> Void
    private var iconImage: NSImage?

    override var isFlipped: Bool { true }

    init(entry: StartPageView.RecentEntry, onClick: @escaping () -> Void) {
        self.entry = entry
        self.onClick = onClick
        self.iconImage = entry.favicon ?? FaviconCache.shared.cachedImage(forURLString: entry.url.absoluteString)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 236),
            heightAnchor.constraint(equalToConstant: 156)
        ])

        if iconImage == nil {
            FaviconCache.shared.fetchFavicon(forURLString: entry.url.absoluteString) { [weak self] img in
                guard let self, let img else { return }
                self.iconImage = img
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor(white: 1.0, alpha: 0.78).setFill()
        path.fill()

        let padX: CGFloat = 14.5
        let iconSize: CGFloat = 33
        let iconRect = NSRect(x: padX, y: 14.5, width: iconSize, height: iconSize)
        let iconClip = NSBezierPath(roundedRect: iconRect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        iconClip.addClip()
        PopoverBrandArtwork.drawSiteBadge(in: iconRect, urlString: entry.url.absoluteString, favicon: iconImage, isDark: false)
        NSGraphicsContext.restoreGraphicsState()

        let domAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.0, weight: .semibold),
            .foregroundColor: NSColor(white: 0.133, alpha: 1.0)
        ]
        NSString(string: entry.domain).draw(in: NSRect(x: padX, y: 56.5, width: bounds.width - padX * 2, height: 18), withAttributes: domAttrs)

        let secColor = NSColor(srgbRed: 0.478, green: 0.490, blue: 0.510, alpha: 1.0)
        if let clock = tintedSymbol("clock", pointSize: 11.0, weight: .regular, color: secColor) {
            clock.draw(in: NSRect(x: padX, y: 95.5, width: clock.size.width, height: clock.size.height))
        }
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: secColor
        ]
        NSString(string: "Just now").draw(at: CGPoint(x: padX + 16, y: 94.5), withAttributes: timeAttrs)

        let pillText = "1 Tab"
        let pillTextColor = NSColor(white: 0.20, alpha: 1.0)
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
        NSColor(white: 0.0, alpha: 0.045).setFill()
        pillPath.fill()
        NSString(string: pillText).draw(at: CGPoint(x: pillRect.minX + 9, y: pillRect.midY - tSz.height * 0.5), withAttributes: pillAttrs)
        if let chev {
            chev.draw(in: NSRect(x: pillRect.minX + 12 + tSz.width, y: pillRect.midY - chev.size.height * 0.5, width: chev.size.width, height: chev.size.height))
        }
    }
}


/// Magnification is driven only by the Start Page's fit-to-width logic; user pinch and smart-magnify are ignored.
private final class StartPageScrollView: NSScrollView {
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
}
