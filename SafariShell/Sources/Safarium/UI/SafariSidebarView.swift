import AppKit

/// Exact 1:1 macOS 27.3 Safari split Sidebar calibrated live against `Reference/VisualDiffAudit.md`
/// & `Reference/Screenshots/comparisons/strip_04_sidebar_clean.png`:
/// - **`240 pt` wide** with **`0.5 pt` (1 Retina px)** full-height vertical separator at `x = 239.5 pt`.
/// - **Pure native `.sidebar` vibrancy** (`NSVisualEffectView(material: .sidebar, blendingMode: .behindWindow)`
///   with ZERO hardcoded opaque gray `layer.backgroundColor` override!).
/// - **Follows macOS System Appearance** (stays crisp light even when viewing dark webpages, matching Real Safari 1:1!).
/// - **Top-right `76 × 38 pt` (`19 pt` radius, `y = 7..45`, `4.5 pt` from divider) crisp white Liquid Glass capsule**
///   `[plus.square.on.square | sidebar.left]` with `16.5 pt` crisp black SF Symbols.
/// - **All rows `32 pt` tall**: `1 Tab` (`laptopcomputer` `16 pt` `#007AFF` + `13.5 pt` semibold `#000000`),
///   indented tabs (`18×18 pt` favicon at `x = 41` + `13.5 pt` `#000000` at `x = 65`), `iCloud Tabs` & `Saved`
///   (`13 pt` gap, `12 pt` semibold secondary at `x = 17`), and `16.5 pt` `#007AFF` rows (`iphone`, `book`,
///   `eyeglasses`, `shared.with.you`) + interactive `Bookmarks` drill-down from `bookmarks.json`.
final class SafariSidebarView: NSView, NSSearchFieldDelegate {
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onSelectURL: ((String) -> Void)?
    var onDropURL: ((URL, String?, Bool) -> Void)?

    enum Mode {
        case tabs
        case bookmarks
        case favoritesFolder
        case readingList
    }

    var mode: Mode = .tabs
    var tabItems: [TabPresentationItem] = []
    var bookmarkSearchQuery: String = ""
    private var currentTheme: AdaptiveChromeTheme = .defaultLight
    private var isDarkMode: Bool { currentTheme.prefersLightInk }

    private let visualEffectView = NSVisualEffectView()
    private let darkTintOverlay = NSView()
    private let separatorLine = NSView()

    // 52pt top header with 76x38 Liquid Glass capsule [plus.square.on.square | sidebar.left]
    private let headerBar = NSView()
    private let headerGlassCluster = GlassToolbarClusterView(spacing: 0, mergeSpacing: 0)
    private lazy var headerCapsule: GlassActionCapsule = GlassActionCapsule(specs: [
        .init(id: "newTabGroup", symbolName: "plus.square.on.square", tooltip: "New Tab (⌘T)", width: 33, pointSize: 16.0, weight: .regular, onClick: { [weak self] in self?.onNewTab?() }),
        .init(id: "hideSidebar", symbolName: "sidebar.left", tooltip: "Hide Sidebar (⌘⇧L)", width: 33, pointSize: 16.0, weight: .regular, onClick: { [weak self] in self?.onToggleSidebar?() })
    ], horizontalPadding: 3)

    private let scrollView = NSScrollView()
    let contentStack = NSStackView()
    private var bookmarkSearchField: NSSearchField?
    var bookmarksListStack: NSStackView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
        rebuildContent()
        registerForDraggedTypes([.URL, .fileURL, .string])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(favoritesDidChange),
            name: .safariumFavoritesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readingListDidChange),
            name: .safariumReadingListDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return CompactTabAddressBar.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return CompactTabAddressBar.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = CompactTabAddressBar.extractDroppedURL(from: sender.draggingPasteboard) else { return false }
        let cmdHeld = NSEvent.modifierFlags.contains(.command)
        let hitRow = contentStack.arrangedSubviews
            .compactMap { $0 as? SidebarLiveTabRowView }
            .first { row in
                let pt = row.convert(sender.draggingLocation, from: nil)
                return row.bounds.contains(pt)
            }
        onDropURL?(url, hitRow?.tabID, cmdHeld || hitRow == nil)
        return true
    }

    @objc private func favoritesDidChange() {
        if mode == .bookmarks || mode == .favoritesFolder {
            rebuildContent()
        }
    }

    @objc private func readingListDidChange() {
        if mode == .readingList {
            rebuildContent()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Native macOS 27 `.sidebar` vibrancy + adaptive dark mode tint overlay
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .aqua)
        addSubview(visualEffectView)

        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        darkTintOverlay.translatesAutoresizingMaskIntoConstraints = false
        darkTintOverlay.wantsLayer = true
        darkTintOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        visualEffectView.addSubview(darkTintOverlay)
        NSLayoutConstraint.activate([
            darkTintOverlay.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            darkTintOverlay.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            darkTintOverlay.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            darkTintOverlay.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        // Crisp 0.5pt (1 Retina px) full-height vertical separator at x = 239.5pt
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        visualEffectView.addSubview(separatorLine)
        NSLayoutConstraint.activate([
            separatorLine.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            separatorLine.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            separatorLine.widthAnchor.constraint(equalToConstant: 0.5)
        ])

        // 52pt top header bar aligned cleanly with unified NSToolbar
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(headerBar)
        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -0.5),
            headerBar.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: SafariMetrics.toolbarHeight)
        ])

        headerGlassCluster.addArrangedView(headerCapsule)
        headerBar.addSubview(headerGlassCluster)
        NSLayoutConstraint.activate([
            headerGlassCluster.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -4.5),
            headerGlassCluster.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            headerGlassCluster.widthAnchor.constraint(equalToConstant: SafariMetrics.sidebarHeaderCapsuleWidth),
            headerGlassCluster.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize)
        ])

        // Scrollable sidebar body starting right at y = 52pt
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        visualEffectView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -0.5),
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let docView = FlippedSidebarContainer(frame: NSRect(x: 0, y: 0, width: SafariMetrics.sidebarDefaultWidth - 0.5, height: 600))
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: docView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor)
        ])

        scrollView.documentView = docView
        NSLayoutConstraint.activate([
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])
    }

    // MARK: - Public Updates

    var lastRenderedTabsSig: String = ""
    var needsDeferredRebuild: Bool = false

    /// Render signature: every text field is length-prefixed so distinct tab lists can never serialise to the same string
    /// (the previous "|" join collided for titles/ids containing "|").
    static func signature(of tabs: [TabPresentationItem]) -> String {
        func field(_ s: String) -> String { "\(s.utf16.count):\(s)" }
        return tabs.map { t in
            [field(t.id), t.isActive ? "1" : "0", field(t.title), field(t.url?.absoluteString ?? ""),
             "\(t.favicon.map { ObjectIdentifier($0).hashValue } ?? 0)"].joined(separator: "|")
        }.joined(separator: "\n")
    }

    func update(tabs: [TabPresentationItem]) {
        self.tabItems = tabs
        guard mode == .tabs else { return }
        let sig = Self.signature(of: tabs)
        if isHidden {
            if sig != lastRenderedTabsSig {
                needsDeferredRebuild = true
            }
            return
        }
        if sig == lastRenderedTabsSig && !needsDeferredRebuild {
            return
        }
        lastRenderedTabsSig = sig
        needsDeferredRebuild = false
        rebuildContent()
    }

    func flushPendingRebuildIfNeeded() {
        guard mode == .tabs, needsDeferredRebuild else { return }
        lastRenderedTabsSig = Self.signature(of: tabItems)
        needsDeferredRebuild = false
        rebuildContent()
    }

    func showTabsSection() {
        if mode != .tabs {
            mode = .tabs
            bookmarkSearchQuery = ""
            lastRenderedTabsSig = Self.signature(of: tabItems)  // keep the signature in step with the rows we are about to draw
            needsDeferredRebuild = false
            rebuildContent()
        } else {
            flushPendingRebuildIfNeeded()
        }
    }

    func showBookmarksSection() {
        if mode != .bookmarks {
            mode = .bookmarks
            rebuildContent()
        }
    }

    func showReadingListSection() {
        if mode != .readingList {
            mode = .readingList
            rebuildContent()
        }
    }

    func apply(theme: AdaptiveChromeTheme, animated: Bool) {
        let wasDark = currentTheme.prefersLightInk
        currentTheme = theme
        let dark = theme.prefersLightInk

        visualEffectView.appearance = theme.preferredAppearance
        headerCapsule.apply(theme: theme, animated: animated)

        let tintColor: NSColor
        if dark {
            let srgb = theme.sampledColor.usingColorSpace(.sRGB) ?? theme.sampledColor
            let base = srgb.blended(withFraction: 0.55, of: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0))
                ?? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
            tintColor = base.withAlphaComponent(0.36)
        } else {
            tintColor = .clear
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? SafariMetrics.topEdgeTintAnimationDuration : 0.0)
        darkTintOverlay.layer?.backgroundColor = tintColor.cgColor
        separatorLine.layer?.backgroundColor = dark
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent(0.14).cgColor
        CATransaction.commit()

        if wasDark != dark {
            rebuildContent()
        }
    }

    // MARK: - Content Builders

    private func rebuildContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        bookmarkSearchField = nil
        bookmarksListStack = nil

        switch mode {
        case .tabs:
            buildTabsSection()
        case .bookmarks:
            buildBookmarksSection()
        case .favoritesFolder:
            buildFavoritesFolderSection()
        case .readingList:
            buildReadingListSection()
        }
    }

    private var sidebarAccentBlue: NSColor {
        isDarkMode
            ? NSColor(srgbRed: 0.04, green: 0.518, blue: 1.0, alpha: 1.0)
            : NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
    }

    private func buildTabsSection() {
        let count = tabItems.count
        let tabHeaderTitle = count == 1 ? "1 Tab" : "\(count) Tabs"

        // 1. Selected `1 Tab` row (`y = 52..84`, 32pt tall, 10pt pill inset, radius 10pt, laptopcomputer 16pt)
        let headerRow = SidebarSelectableRowView(
            title: tabHeaderTitle,
            icon: AssetLoader.shared.symbol(named: "laptopcomputer", pointSize: 16.0, weight: .medium),
            iconTint: sidebarAccentBlue,
            isSelected: true,
            isBold: true,
            isDarkMode: isDarkMode,
            iconX: 19,
            labelX: 49,
            height: SafariMetrics.sidebarRowHeight
        )
        contentStack.addArrangedSubview(headerRow)
        pinFullWidth(headerRow)

        // 2. Indented live tab rows (`32pt` tall, `18×18pt` favicon at x = 41, `13.5pt` at x = 65)
        for item in tabItems {
            let row = SidebarLiveTabRowView(
                item: item,
                isDarkMode: isDarkMode,
                onSelect: { [weak self] in self?.onSelectTab?(item.id) },
                onClose: { [weak self] in self?.onCloseTab?(item.id) }
            )
            contentStack.addArrangedSubview(row)
            pinFullWidth(row)
        }

        // 3. `Saved` section (`13pt` gap, 32pt rows, vibrant 16.5pt SF Symbols)
        addSectionHeader("Saved", topGap: 13)

        let bookmarksRow = SidebarSelectableRowView(
            title: "Bookmarks",
            icon: AssetLoader.shared.symbol(named: "book", pointSize: 16.5, weight: .regular),
            iconTint: sidebarAccentBlue,
            isSelected: false,
            isBold: false,
            isDarkMode: isDarkMode,
            iconX: 19,
            labelX: 49,
            height: SafariMetrics.sidebarRowHeight,
            onClick: { [weak self] in
                self?.mode = .bookmarks
                self?.rebuildContent()
            }
        )
        contentStack.addArrangedSubview(bookmarksRow)
        pinFullWidth(bookmarksRow)

        let readingListRow = SidebarSelectableRowView(
            title: "Reading List",
            icon: AssetLoader.shared.symbol(named: "eyeglasses", pointSize: 16.5, weight: .regular),
            iconTint: sidebarAccentBlue,
            isSelected: false,
            isBold: false,
            isDarkMode: isDarkMode,
            iconX: 19,
            labelX: 49,
            height: SafariMetrics.sidebarRowHeight,
            onClick: { [weak self] in
                self?.mode = .readingList
                self?.rebuildContent()
            }
        )
        contentStack.addArrangedSubview(readingListRow)
        pinFullWidth(readingListRow)
    }

    private func buildBookmarksSection() {
        let navRow = NSView()
        navRow.translatesAutoresizingMaskIntoConstraints = false
        navRow.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let btnBg = isDarkMode ? NSColor.white.withAlphaComponent(0.11).cgColor : NSColor.black.withAlphaComponent(0.07).cgColor
        let primaryInk: NSColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : .black

        let backBtn = NSButton()
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        backBtn.isBordered = false
        backBtn.wantsLayer = true
        backBtn.layer?.cornerRadius = 13
        backBtn.layer?.backgroundColor = btnBg
        backBtn.image = AssetLoader.shared.symbol(named: "chevron.backward", pointSize: 12.5, weight: .semibold)
        backBtn.contentTintColor = primaryInk
        backBtn.target = self
        backBtn.action = #selector(backToTabsClicked)
        navRow.addSubview(backBtn)

        let titleLbl = NSTextField(labelWithString: "Bookmarks")
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 15.0, weight: .bold)
        titleLbl.textColor = primaryInk
        navRow.addSubview(titleLbl)

        let moreBtn = NSButton()
        moreBtn.translatesAutoresizingMaskIntoConstraints = false
        moreBtn.isBordered = false
        moreBtn.wantsLayer = true
        moreBtn.layer?.cornerRadius = 13
        moreBtn.layer?.backgroundColor = btnBg
        moreBtn.image = AssetLoader.shared.symbol(named: "ellipsis", pointSize: 13.0, weight: .medium)
        moreBtn.contentTintColor = primaryInk
        moreBtn.target = self
        moreBtn.action = #selector(bookmarksMoreClicked(_:))
        navRow.addSubview(moreBtn)

        NSLayoutConstraint.activate([
            backBtn.leadingAnchor.constraint(equalTo: navRow.leadingAnchor, constant: 12),
            backBtn.centerYAnchor.constraint(equalTo: navRow.centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: 26),
            backBtn.heightAnchor.constraint(equalToConstant: 26),

            titleLbl.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            titleLbl.centerYAnchor.constraint(equalTo: navRow.centerYAnchor),

            moreBtn.trailingAnchor.constraint(equalTo: navRow.trailingAnchor, constant: -12),
            moreBtn.centerYAnchor.constraint(equalTo: navRow.centerYAnchor),
            moreBtn.widthAnchor.constraint(equalToConstant: 26),
            moreBtn.heightAnchor.constraint(equalToConstant: 26)
        ])
        contentStack.addArrangedSubview(navRow)
        pinFullWidth(navRow)

        addSpacer(6)

        // Pill-rounded Search Bookmarks field matching macOS 27 Safari
        let searchWrap = NSView()
        searchWrap.translatesAutoresizingMaskIntoConstraints = false
        searchWrap.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let searchPill = NSView()
        searchPill.translatesAutoresizingMaskIntoConstraints = false
        searchPill.wantsLayer = true
        searchPill.layer?.cornerRadius = 13.5
        searchPill.layer?.cornerCurve = .continuous
        searchPill.layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.black.withAlphaComponent(0.06).cgColor
        searchWrap.addSubview(searchPill)

        let searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search Bookmarks"
        searchField.stringValue = bookmarkSearchQuery
        searchField.font = NSFont.systemFont(ofSize: 12.5)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchPill.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchPill.leadingAnchor.constraint(equalTo: searchWrap.leadingAnchor, constant: 12),
            searchPill.trailingAnchor.constraint(equalTo: searchWrap.trailingAnchor, constant: -12),
            searchPill.centerYAnchor.constraint(equalTo: searchWrap.centerYAnchor),
            searchPill.heightAnchor.constraint(equalToConstant: 27),

            searchField.leadingAnchor.constraint(equalTo: searchPill.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchPill.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 22)
        ])
        contentStack.addArrangedSubview(searchWrap)
        pinFullWidth(searchWrap)
        self.bookmarkSearchField = searchField

        let allFavorites = AssetLoader.shared.favorites()

        // 1. Topics > horizontal pill strip
        addSectionHeader("Topics", topGap: 12, showChevron: true)
        addSpacer(5)
        let topicsItems: [(String, String, [String])] = [
            ("reddit.com", "https://www.reddit.com/", ["https://www.reddit.com/", "https://www.youtube.com/", "https://news.ycombinator.com/"]),
            ("github.com", "https://github.com/", ["https://github.com/", "https://stackoverflow.com/", "https://www.notion.so/"]),
            ("apple.com", "https://www.apple.com/", ["https://www.apple.com/", "https://www.icloud.com/"]),
            ("wikipedia.org", "https://www.wikipedia.org/", ["https://www.wikipedia.org/", "https://www.google.com/"])
        ]
        let topicsStrip = makeHorizontalCarousel(height: 40) { stack in
            for (domain, urlStr, badgeURLs) in topicsItems {
                let pill = SidebarTopicPillView(
                    domain: domain,
                    badgeURLs: badgeURLs,
                    isDarkMode: self.isDarkMode,
                    onClick: { [weak self] in self?.onSelectURL?(urlStr) }
                )
                stack.addArrangedSubview(pill)
            }
        }
        contentStack.addArrangedSubview(topicsStrip)
        pinFullWidth(topicsStrip)

        // 2. Recently Saved > horizontal preview card strip
        addSectionHeader("Recently Saved", topGap: 12, showChevron: true)
        addSpacer(5)
        let recentlySaved: [(String, String, String, NSColor)] = [
            ("r/macapps — Safari extensions", "reddit.com", "https://www.reddit.com/", NSColor(srgbRed: 1.0, green: 0.91, blue: 0.84, alpha: 1.0)),
            ("apple/swift — Swift Language", "github.com", "https://github.com/", NSColor(srgbRed: 0.14, green: 0.16, blue: 0.19, alpha: 1.0)),
            ("MacBook Pro — Apple", "apple.com", "https://www.apple.com/", NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1.0)),
            ("WebKit Open Source", "wikipedia.org", "https://www.wikipedia.org/", NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1.0))
        ]
        let recentStrip = makeHorizontalCarousel(height: 102) { stack in
            for (title, domain, urlStr, bannerTint) in recentlySaved {
                let card = SidebarRecentlySavedCardView(
                    title: title,
                    domain: domain,
                    urlString: urlStr,
                    bannerColor: bannerTint,
                    isDarkMode: self.isDarkMode,
                    onClick: { [weak self] in self?.onSelectURL?(urlStr) }
                )
                stack.addArrangedSubview(card)
            }
        }
        contentStack.addArrangedSubview(recentStrip)
        pinFullWidth(recentStrip)

        // 3. Folders (Favorites with interactive drill-down)
        addSectionHeader("Folders", topGap: 12)
        let favFolder = SidebarSelectableRowView(
            title: "Favorites",
            icon: AssetLoader.shared.symbol(named: "star.fill", pointSize: 15.0, weight: .medium),
            iconTint: sidebarAccentBlue,
            trailingCount: "\(allFavorites.count) ›",
            isSelected: false,
            isBold: false,
            isDarkMode: isDarkMode,
            iconX: 19,
            labelX: 47,
            height: SafariMetrics.sidebarRowHeight,
            onClick: { [weak self] in
                self?.mode = .favoritesFolder
                self?.rebuildContent()
            }
        )
        contentStack.addArrangedSubview(favFolder)
        pinFullWidth(favFolder)

        // 4. Rich Bookmarks list
        addSectionHeader("Bookmarks", topGap: 12)
        addSpacer(2)
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(listStack)
        pinFullWidth(listStack)
        self.bookmarksListStack = listStack
        populateBookmarkRows()
    }

    private func buildFavoritesFolderSection() {
        let navRow = NSView()
        navRow.translatesAutoresizingMaskIntoConstraints = false
        navRow.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let btnBg = isDarkMode ? NSColor.white.withAlphaComponent(0.11).cgColor : NSColor.black.withAlphaComponent(0.07).cgColor
        let primaryInk: NSColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : .black

        let backBtn = NSButton()
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        backBtn.isBordered = false
        backBtn.wantsLayer = true
        backBtn.layer?.cornerRadius = 13
        backBtn.layer?.backgroundColor = btnBg
        backBtn.image = AssetLoader.shared.symbol(named: "chevron.backward", pointSize: 12.5, weight: .semibold)
        backBtn.contentTintColor = primaryInk
        backBtn.target = self
        backBtn.action = #selector(backToBookmarksClicked)
        navRow.addSubview(backBtn)

        let titleLbl = NSTextField(labelWithString: "Favorites")
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 15.0, weight: .bold)
        titleLbl.textColor = primaryInk
        navRow.addSubview(titleLbl)

        NSLayoutConstraint.activate([
            backBtn.leadingAnchor.constraint(equalTo: navRow.leadingAnchor, constant: 12),
            backBtn.centerYAnchor.constraint(equalTo: navRow.centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: 26),
            backBtn.heightAnchor.constraint(equalToConstant: 26),

            titleLbl.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            titleLbl.centerYAnchor.constraint(equalTo: navRow.centerYAnchor)
        ])
        contentStack.addArrangedSubview(navRow)
        pinFullWidth(navRow)

        addSpacer(6)
        for entry in AssetLoader.shared.favorites() {
            let domain = URLInputNormalizer.displayDomain(for: URL(string: entry.url))
            let row = SidebarRichBookmarkRowView(
                title: entry.title,
                domain: domain,
                snippet: nil,
                urlString: entry.url,
                isDarkMode: isDarkMode,
                onClick: { [weak self] in
                    self?.onSelectURL?(entry.url)
                }
            )
            contentStack.addArrangedSubview(row)
            pinFullWidth(row)
        }
    }

    private func populateBookmarkRows() {
        guard let listStack = bookmarksListStack else { return }
        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let snippetsByHost: [String: String] = [
            "apple.com": "Discover the innovative world of Apple and shop everything iPhone, iPad, Apple Watch, Mac, and more.",
            "github.com": "Build and ship software on a single, collaborative platform.",
            "wikipedia.org": "The Free Encyclopedia that anyone can edit.",
            "reddit.com": "Dive into anything — communities, discussions, and news.",
            "news.ycombinator.com": "Social news focusing on computer science and entrepreneurship."
        ]

        let allFavorites = AssetLoader.shared.favorites()
        let q = bookmarkSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = q.isEmpty
            ? allFavorites
            : allFavorites.filter {
                $0.title.localizedCaseInsensitiveContains(q) ||
                $0.url.localizedCaseInsensitiveContains(q)
            }

        for entry in filtered {
            let domain = URLInputNormalizer.displayDomain(for: URL(string: entry.url))
            let snippet = snippetsByHost.first(where: { domain.lowercased().contains($0.key) })?.value
            let row = SidebarRichBookmarkRowView(
                title: entry.title,
                domain: domain,
                snippet: snippet,
                urlString: entry.url,
                isDarkMode: isDarkMode,
                onClick: { [weak self] in
                    self?.onSelectURL?(entry.url)
                }
            )
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func makeHorizontalCarousel(height: CGFloat, populate: (NSStackView) -> Void) -> NSView {
        let stripScroll = NSScrollView()
        stripScroll.translatesAutoresizingMaskIntoConstraints = false
        stripScroll.drawsBackground = false
        stripScroll.hasHorizontalScroller = false
        stripScroll.hasVerticalScroller = false
        stripScroll.borderType = .noBorder
        stripScroll.heightAnchor.constraint(equalToConstant: height).isActive = true

        let doc = FlippedSidebarContainer()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let hStack = NSStackView()
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 8
        hStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        hStack.translatesAutoresizingMaskIntoConstraints = false
        populate(hStack)

        doc.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            hStack.topAnchor.constraint(equalTo: doc.topAnchor),
            hStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalToConstant: height)
        ])
        stripScroll.documentView = doc
        return stripScroll
    }

    private func buildReadingListSection() {
        let navRow = NSView()
        navRow.translatesAutoresizingMaskIntoConstraints = false
        navRow.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let btnBg = isDarkMode ? NSColor.white.withAlphaComponent(0.11).cgColor : NSColor.black.withAlphaComponent(0.07).cgColor
        let primaryInk: NSColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : .black

        let backBtn = NSButton()
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        backBtn.isBordered = false
        backBtn.wantsLayer = true
        backBtn.layer?.cornerRadius = 13
        backBtn.layer?.backgroundColor = btnBg
        backBtn.image = AssetLoader.shared.symbol(named: "chevron.backward", pointSize: 12.5, weight: .semibold)
        backBtn.contentTintColor = primaryInk
        backBtn.target = self
        backBtn.action = #selector(backToTabsClicked)
        navRow.addSubview(backBtn)

        let titleLbl = NSTextField(labelWithString: "Reading List")
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 15.0, weight: .bold)
        titleLbl.textColor = primaryInk
        navRow.addSubview(titleLbl)

        NSLayoutConstraint.activate([
            backBtn.leadingAnchor.constraint(equalTo: navRow.leadingAnchor, constant: 12),
            backBtn.centerYAnchor.constraint(equalTo: navRow.centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: 26),
            backBtn.heightAnchor.constraint(equalToConstant: 26),
            titleLbl.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            titleLbl.centerYAnchor.constraint(equalTo: navRow.centerYAnchor)
        ])
        contentStack.addArrangedSubview(navRow)
        pinFullWidth(navRow)

        addSectionHeader("Unread", topGap: 10)
        for item in AssetLoader.shared.readingList() {
            let urlStr = item.url
            let cachedIcon = FaviconCache.shared.cachedImage(forURLString: urlStr)
                ?? AssetLoader.shared.symbol(named: "globe", pointSize: 15.0, weight: .regular)
            let domain = URLInputNormalizer.displayDomain(for: URL(string: urlStr))
            let row = SidebarBookmarkRowView(title: item.title, subtitle: domain, icon: cachedIcon, urlString: urlStr, isDarkMode: isDarkMode) { [weak self] in
                self?.onSelectURL?(urlStr)
            }
            contentStack.addArrangedSubview(row)
            pinFullWidth(row)
        }
    }

    // MARK: - Helpers

    private func addSectionHeader(_ text: String, topGap: CGFloat, showChevron: Bool = false) {
        addSpacer(topGap)
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let ink = isDarkMode
            ? NSColor.white.withAlphaComponent(0.56)
            : NSColor(srgbRed: 0.38, green: 0.38, blue: 0.40, alpha: 0.92)

        let lbl = NSTextField(labelWithString: text)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        lbl.textColor = ink
        wrapper.addSubview(lbl)

        var constraints: [NSLayoutConstraint] = [
            lbl.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            lbl.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ]

        if showChevron {
            let chev = NSImageView()
            chev.translatesAutoresizingMaskIntoConstraints = false
            chev.image = AssetLoader.shared.symbol(named: "chevron.right", pointSize: 9.0, weight: .semibold)
            chev.contentTintColor = ink
            wrapper.addSubview(chev)
            constraints.append(contentsOf: [
                chev.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 4),
                chev.centerYAnchor.constraint(equalTo: lbl.centerYAnchor, constant: 0.5),
                chev.widthAnchor.constraint(equalToConstant: 8),
                chev.heightAnchor.constraint(equalToConstant: 10)
            ])
        }

        NSLayoutConstraint.activate(constraints)
        contentStack.addArrangedSubview(wrapper)
        pinFullWidth(wrapper)
    }

    private func addSpacer(_ height: CGFloat) {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        contentStack.addArrangedSubview(v)
    }

    private func pinFullWidth(_ view: NSView) {
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func makeColorBadge(letter: String, hex: String?) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size)
        img.lockFocus()
        let color = NSColor(hexString: hex ?? "#007AFF") ?? .systemBlue
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 5.5, yRadius: 5.5)
        color.setFill()
        path.fill()
        let str = NSAttributedString(string: letter, attributes: [
            .font: NSFont.systemFont(ofSize: 12.0, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        let s = str.size()
        str.draw(at: NSPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2))
        img.unlockFocus()
        return img
    }

    @objc private func backToTabsClicked() {
        mode = .tabs
        bookmarkSearchQuery = ""
        rebuildContent()
    }

    @objc private func backToBookmarksClicked() {
        mode = .bookmarks
        rebuildContent()
    }

    @objc private func bookmarksMoreClicked(_ sender: NSButton) {
        let menu = NSMenu()
        let openFav = NSMenuItem(title: "Show Favorites", action: #selector(openFavoritesFolderMenuAction), keyEquivalent: "")
        openFav.target = self
        menu.addItem(openFav)
        if !bookmarkSearchQuery.isEmpty {
            let clearSearch = NSMenuItem(title: "Clear Search", action: #selector(clearBookmarkSearchAction), keyEquivalent: "")
            clearSearch.target = self
            menu.addItem(clearSearch)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openFavoritesFolderMenuAction() {
        mode = .favoritesFolder
        rebuildContent()
    }

    @objc private func clearBookmarkSearchAction() {
        bookmarkSearchQuery = ""
        bookmarkSearchField?.stringValue = ""
        populateBookmarkRows()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField {
            bookmarkSearchQuery = field.stringValue
            populateBookmarkRows()
        }
    }
}

// MARK: - Sidebar Row Views (`32 pt` exact height, crisp `#000000` text, `#007AFF` icons)

private final class SidebarSelectableRowView: NSView {
    private var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private let isSelected: Bool
    private let isDarkMode: Bool
    private let pillView = NSView()

    init(
        title: String,
        icon: NSImage,
        iconTint: NSColor,
        trailingCount: String? = nil,
        isSelected: Bool,
        isBold: Bool,
        isDarkMode: Bool,
        iconX: CGFloat,
        labelX: CGFloat,
        height: CGFloat,
        onClick: (() -> Void)? = nil
    ) {
        self.isSelected = isSelected
        self.isDarkMode = isDarkMode
        self.onClick = onClick
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true

        // Rounded capsule pill inset 10pt from sidebar edges (`cornerRadius = 10 pt`, matching strip_04_sidebar_clean.png)
        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius = 10.0
        pillView.layer?.cornerCurve = .continuous
        addSubview(pillView)
        NSLayoutConstraint.activate([
            pillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pillView.topAnchor.constraint(equalTo: topAnchor),
            pillView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = icon
        iconView.contentTintColor = iconTint
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13.5, weight: isBold ? .semibold : .regular)
        label.textColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : .black
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: iconX),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: labelX),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if let trailingCount {
            let countLbl = NSTextField(labelWithString: trailingCount)
            countLbl.translatesAutoresizingMaskIntoConstraints = false
            countLbl.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
            countLbl.textColor = isDarkMode
                ? NSColor.white.withAlphaComponent(0.55)
                : NSColor(srgbRed: 0.44, green: 0.44, blue: 0.46, alpha: 0.92)
            addSubview(countLbl)
            NSLayoutConstraint.activate([
                countLbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                countLbl.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: countLbl.leadingAnchor, constant: -6)
            ])
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14).isActive = true
        }

        updateBackground(hovered: false)

        if onClick != nil {
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
            addGestureRecognizer(click)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func updateBackground(hovered: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            pillView.layer?.backgroundColor = isDarkMode
                ? NSColor.white.withAlphaComponent(0.13).cgColor
                : NSColor.black.withAlphaComponent(0.085).cgColor
        } else if hovered && onClick != nil {
            pillView.layer?.backgroundColor = isDarkMode
                ? NSColor.white.withAlphaComponent(0.07).cgColor
                : NSColor.black.withAlphaComponent(0.05).cgColor
        } else {
            pillView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateBackground(hovered: true) }
    override func mouseExited(with event: NSEvent) { updateBackground(hovered: false) }

    @objc private func handleTap() { onClick?() }
}

private final class SidebarLiveTabRowView: NSView, NSGestureRecognizerDelegate {
    let tabID: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let isDarkMode: Bool
    private let pillView = NSView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?

    init(item: TabPresentationItem, isDarkMode: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.tabID = item.id
        self.isDarkMode = isDarkMode
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: SafariMetrics.sidebarRowHeight).isActive = true

        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius = 8.0
        pillView.layer?.cornerCurve = .continuous
        addSubview(pillView)
        NSLayoutConstraint.activate([
            pillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pillView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            pillView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = item.favicon ?? AssetLoader.shared.symbol(named: "globe", pointSize: 15.0, weight: .regular)
        iconView.contentTintColor = (item.favicon == nil)
            ? (isDarkMode ? NSColor.white.withAlphaComponent(0.60) : NSColor.secondaryLabelColor)
            : nil
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4.0
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        let titleLbl = NSTextField(labelWithString: item.title.isEmpty ? URLInputNormalizer.displayDomain(for: item.url) : item.title)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        titleLbl.textColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : .black
        titleLbl.lineBreakMode = .byTruncatingTail
        addSubview(titleLbl)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = AssetLoader.shared.symbol(named: "xmark", pointSize: 10.0, weight: .medium)
        closeButton.contentTintColor = isDarkMode ? NSColor.white.withAlphaComponent(0.65) : NSColor.secondaryLabelColor
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // Exact Real Safari metrics (`ax_real_04_sidebar_root.txt`): 18x18 favicon at x = 41, text at x = 65
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 41),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            titleLbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 65),
            titleLbl.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            titleLbl.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(rowTapped))
        click.delegate = self
        addGestureRecognizer(click)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let pt = convert(event.locationInWindow, from: nil)
        if !closeButton.isHidden && closeButton.frame.insetBy(dx: -4, dy: -4).contains(pt) {
            return false
        }
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.05).cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.layer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClose()
            return
        }
        super.otherMouseUp(with: event)
    }

    @objc private func rowTapped() { onSelect() }
    @objc private func closeTapped() { onClose() }
}

private final class SidebarBookmarkRowView: NSView {
    private let onClick: () -> Void
    private let isDarkMode: Bool
    private let pillView = NSView()
    private var trackingArea: NSTrackingArea?

    init(title: String, subtitle: String, icon: NSImage, urlString: String? = nil, isDarkMode: Bool, onClick: @escaping () -> Void) {
        self.isDarkMode = isDarkMode
        self.onClick = onClick
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true

        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius = 8.0
        pillView.layer?.cornerCurve = .continuous
        addSubview(pillView)
        NSLayoutConstraint.activate([
            pillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pillView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            pillView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 5.0
        iconView.layer?.masksToBounds = true
        addSubview(iconView)
        if let urlString, FaviconCache.shared.cachedImage(forURLString: urlString) == nil {
            FaviconCache.shared.fetchFavicon(forURLString: urlString) { [weak iconView] img in
                if let img { iconView?.image = img }
            }
        }

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        titleLbl.textColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : .black
        titleLbl.lineBreakMode = .byTruncatingTail
        addSubview(titleLbl)

        let subLbl = NSTextField(labelWithString: subtitle)
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        subLbl.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subLbl.textColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.54)
            : NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 0.90)
        subLbl.lineBreakMode = .byTruncatingTail
        addSubview(subLbl)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLbl.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLbl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            titleLbl.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            subLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            subLbl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 1)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.05).cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.layer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
    }

    @objc private func tapped() { onClick() }
}

private final class FlippedSidebarContainer: NSView {
    override var isFlipped: Bool { true }
}

private final class SidebarMiniSquircleView: NSView {
    private let urlString: String
    private let isDarkMode: Bool
    private var touchIcon: FaviconCache.TouchIconResult?
    override var isFlipped: Bool { true }

    init(urlString: String, isDarkMode: Bool, cornerRadius: CGFloat) {
        self.urlString = urlString
        self.isDarkMode = isDarkMode
        self.touchIcon = FaviconCache.shared.cachedTouchIcon(forURLString: urlString)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        if touchIcon == nil {
            FaviconCache.shared.fetchTouchIcon(forURLString: urlString) { [weak self] res in
                guard let self else { return }
                self.touchIcon = res
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        PopoverBrandArtwork.drawFavoriteSquircle(
            in: bounds,
            urlString: urlString,
            touchIcon: touchIcon,
            isDark: isDarkMode
        )
    }
}

/// Horizontal rounded Topic pill matching macOS 27 Safari Bookmarks (`[overlapping badges] reddit.com`).
private final class SidebarTopicPillView: NSView {
    private let onClick: () -> Void
    private let isDarkMode: Bool
    private var trackingArea: NSTrackingArea?

    init(domain: String, badgeURLs: [String], isDarkMode: Bool, onClick: @escaping () -> Void) {
        self.isDarkMode = isDarkMode
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11.0
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.11).cgColor
            : NSColor.white.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.black.withAlphaComponent(0.08).cgColor

        let ringColor = isDarkMode
            ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1.0).cgColor
            : NSColor.white.cgColor

        let count = min(3, max(1, badgeURLs.count))
        let badgeSize: CGFloat = 20
        let overlapStep: CGFloat = 11
        let clusterWidth = badgeSize + CGFloat(count - 1) * overlapStep

        let cluster = NSView()
        cluster.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cluster)

        for i in 0..<count {
            let badgeWrap = NSView()
            badgeWrap.translatesAutoresizingMaskIntoConstraints = false
            badgeWrap.wantsLayer = true
            badgeWrap.layer?.cornerRadius = badgeSize * 0.5
            badgeWrap.layer?.borderWidth = 1.5
            badgeWrap.layer?.borderColor = ringColor
            badgeWrap.layer?.masksToBounds = true
            cluster.addSubview(badgeWrap)

            let icon = SidebarMiniSquircleView(urlString: badgeURLs[i], isDarkMode: isDarkMode, cornerRadius: badgeSize * 0.5)
            badgeWrap.addSubview(icon)

            NSLayoutConstraint.activate([
                badgeWrap.leadingAnchor.constraint(equalTo: cluster.leadingAnchor, constant: CGFloat(i) * overlapStep),
                badgeWrap.centerYAnchor.constraint(equalTo: cluster.centerYAnchor),
                badgeWrap.widthAnchor.constraint(equalToConstant: badgeSize),
                badgeWrap.heightAnchor.constraint(equalToConstant: badgeSize),

                icon.leadingAnchor.constraint(equalTo: badgeWrap.leadingAnchor),
                icon.trailingAnchor.constraint(equalTo: badgeWrap.trailingAnchor),
                icon.topAnchor.constraint(equalTo: badgeWrap.topAnchor),
                icon.bottomAnchor.constraint(equalTo: badgeWrap.bottomAnchor)
            ])
        }

        let lbl = NSTextField(labelWithString: domain)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        lbl.textColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.14, alpha: 1.0)
        lbl.lineBreakMode = .byTruncatingTail
        addSubview(lbl)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            cluster.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cluster.centerYAnchor.constraint(equalTo: centerYAnchor),
            cluster.widthAnchor.constraint(equalToConstant: clusterWidth),
            cluster.heightAnchor.constraint(equalToConstant: badgeSize),

            lbl.leadingAnchor.constraint(equalTo: cluster.trailingAnchor, constant: 7),
            lbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            lbl.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : NSColor.white.cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.11).cgColor
            : NSColor.white.withAlphaComponent(0.95).cgColor
        CATransaction.commit()
    }

    @objc private func tapped() { onClick() }
}

/// Vertical rounded card in `Recently Saved >` (`90 × 98 pt`, top preview banner + 2-line bold title + muted domain).
private final class SidebarRecentlySavedCardView: NSView {
    private let onClick: () -> Void
    private let isDarkMode: Bool

    init(title: String, domain: String, urlString: String, bannerColor: NSColor, isDarkMode: Bool, onClick: @escaping () -> Void) {
        self.isDarkMode = isDarkMode
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11.0
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.white.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.black.withAlphaComponent(0.08).cgColor

        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = isDarkMode
            ? bannerColor.blended(withFraction: 0.45, of: .black)?.cgColor ?? bannerColor.cgColor
            : bannerColor.cgColor
        addSubview(banner)

        let icon = SidebarMiniSquircleView(urlString: urlString, isDarkMode: isDarkMode, cornerRadius: 7.0)
        banner.addSubview(icon)

        let titleLbl = NSTextField(wrappingLabelWithString: title)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        titleLbl.textColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.12, alpha: 1.0)
        titleLbl.usesSingleLineMode = false
        titleLbl.cell?.wraps = true
        titleLbl.cell?.truncatesLastVisibleLine = true
        titleLbl.maximumNumberOfLines = 2
        titleLbl.preferredMaxLayoutWidth = 76
        addSubview(titleLbl)

        let domainLbl = NSTextField(labelWithString: domain)
        domainLbl.translatesAutoresizingMaskIntoConstraints = false
        domainLbl.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        domainLbl.textColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor(srgbRed: 0.45, green: 0.45, blue: 0.49, alpha: 1.0)
        domainLbl.lineBreakMode = .byTruncatingTail
        addSubview(domainLbl)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 90),
            heightAnchor.constraint(equalToConstant: 98),

            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.topAnchor.constraint(equalTo: topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 42),

            icon.centerXAnchor.constraint(equalTo: banner.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            titleLbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            titleLbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            titleLbl.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 5),

            domainLbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            domainLbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            domainLbl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    @objc private func tapped() { onClick() }
}

/// Rich Bookmarks list row matching macOS 27 Safari (`28×28` squircle + bold title + inline mini favicon + domain + optional 2-line snippet).
private final class SidebarRichBookmarkRowView: NSView {
    private let onClick: () -> Void
    private let isDarkMode: Bool
    private let pillView = NSView()
    private var trackingArea: NSTrackingArea?

    init(title: String, domain: String, snippet: String?, urlString: String, isDarkMode: Bool, onClick: @escaping () -> Void) {
        self.isDarkMode = isDarkMode
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        pillView.translatesAutoresizingMaskIntoConstraints = false
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius = 8.0
        pillView.layer?.cornerCurve = .continuous
        addSubview(pillView)

        let thumb = SidebarMiniSquircleView(urlString: urlString, isDarkMode: isDarkMode, cornerRadius: 6.5)
        addSubview(thumb)

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLbl.textColor = isDarkMode ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.10, alpha: 1.0)
        titleLbl.lineBreakMode = .byTruncatingTail
        addSubview(titleLbl)

        let miniIcon = SidebarMiniSquircleView(urlString: urlString, isDarkMode: isDarkMode, cornerRadius: 3.0)
        addSubview(miniIcon)

        let domainLbl = NSTextField(labelWithString: domain)
        domainLbl.translatesAutoresizingMaskIntoConstraints = false
        domainLbl.font = NSFont.systemFont(ofSize: 11.0, weight: .regular)
        domainLbl.textColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.60)
            : NSColor(srgbRed: 0.36, green: 0.36, blue: 0.40, alpha: 0.95)
        domainLbl.lineBreakMode = .byTruncatingTail
        addSubview(domainLbl)

        var constraints: [NSLayoutConstraint] = [
            pillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pillView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            pillView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            thumb.widthAnchor.constraint(equalToConstant: 28),
            thumb.heightAnchor.constraint(equalToConstant: 28),

            titleLbl.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 9),
            titleLbl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            titleLbl.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            miniIcon.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            miniIcon.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3),
            miniIcon.widthAnchor.constraint(equalToConstant: 12),
            miniIcon.heightAnchor.constraint(equalToConstant: 12),

            domainLbl.leadingAnchor.constraint(equalTo: miniIcon.trailingAnchor, constant: 4),
            domainLbl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            domainLbl.centerYAnchor.constraint(equalTo: miniIcon.centerYAnchor)
        ]

        if let snippet, !snippet.isEmpty {
            let snipLbl = NSTextField(wrappingLabelWithString: snippet)
            snipLbl.translatesAutoresizingMaskIntoConstraints = false
            snipLbl.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
            snipLbl.textColor = isDarkMode
                ? NSColor.white.withAlphaComponent(0.46)
                : NSColor(srgbRed: 0.46, green: 0.46, blue: 0.50, alpha: 0.92)
            snipLbl.usesSingleLineMode = false
            snipLbl.cell?.wraps = true
            snipLbl.cell?.truncatesLastVisibleLine = true
            snipLbl.maximumNumberOfLines = 2
            snipLbl.preferredMaxLayoutWidth = 172
            addSubview(snipLbl)
            constraints.append(contentsOf: [
                snipLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
                snipLbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                snipLbl.topAnchor.constraint(equalTo: miniIcon.bottomAnchor, constant: 3),
                snipLbl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
            ])
        } else {
            constraints.append(
                miniIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
            )
        }

        NSLayoutConstraint.activate(constraints)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.05).cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.layer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
    }

    @objc private func tapped() { onClick() }
}
