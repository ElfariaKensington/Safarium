import AppKit
import QuartzCore

/// Native macOS Tahoe Liquid Glass Privacy Report window displaying 30-day cross-site tracker
/// prevention metrics, HTTPS upgrades, link-tracking cleaning, anti-fingerprinting stats, and
/// interactive Websites / Trackers master-detail breakdown.
final class PrivacyReportWindowController: NSWindowController {

    enum DisplayMode: Int {
        case websites = 0
        case trackers = 1
    }

    // MARK: - Callbacks

    var onOpenPrivacySettings: (() -> Void)?
    var onClearReport: (() -> Void)?

    // MARK: - Public State

    var displayMode: DisplayMode = .websites {
        didSet {
            guard oldValue != displayMode else { return }
            if segmentedControl.selectedSegment != displayMode.rawValue {
                segmentedControl.selectedSegment = displayMode.rawValue
            }
            refreshMasterAndDetail()
        }
    }

    var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            if searchField.stringValue != searchQuery {
                searchField.stringValue = searchQuery
            }
            refreshMasterAndDetail()
        }
    }

    private(set) var currentSummary: PrivacyReportSummary = .empty
    private(set) var selectedWebsiteHost: String?
    private(set) var selectedTrackerDomain: String?

    // MARK: - Dependencies & Observers

    private let store: PrivacyReportStore
    private var reportObserver: NSObjectProtocol?

    // MARK: - UI Elements

    private let surfaceView = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let settingsButton = NSButton(title: "Privacy Settings…", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear Report", target: nil, action: nil)

    private let trackersCard = PrivacyMetricCardView(title: "Trackers Prevented", symbolName: "shield.lefthalf.filled", accentColor: PrivacyUIStyle.safariumGreen)
    private let websitesCard = PrivacyMetricCardView(title: "Websites Contacting Trackers", symbolName: "globe", accentColor: .systemBlue)
    private let cleaningCard = PrivacyMetricCardView(title: "HTTPS & Link Cleaning", symbolName: "lock.shield.fill", accentColor: .systemTeal)
    private let protectionCard = PrivacyMetricCardView(title: "Anti-Fingerprinting & Cookies", symbolName: "hand.raised.shield.fill", accentColor: .systemIndigo)

    private let highlightBanner = PrivacyGlassCardView(cornerRadius: 12)
    private let highlightLabel = NSTextField(wrappingLabelWithString: "")
    private let categoryChipsStack = NSStackView()

    private let segmentedControl = NSSegmentedControl(labels: ["Websites", "Trackers"], trackingMode: .selectOne, target: nil, action: nil)
    private let countStatusLabel = NSTextField(labelWithString: "")

    private let splitContainer = NSView()
    private let masterCard = PrivacyGlassCardView(cornerRadius: 14)
    private let masterScrollView = NSScrollView()
    private let masterStack = NSStackView()
    private var masterRowViews: [(key: String, view: PrivacyMasterBarRowView)] = []

    private let detailCard = PrivacyGlassCardView(cornerRadius: 14)
    private let detailScrollView = NSScrollView()
    private let detailStack = NSStackView()

    private let emptyStateCard = PrivacyGlassCardView(cornerRadius: 14)
    private let emptyShieldView = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "No Trackers Prevented Yet")
    private let emptySubtitleLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: - Init / Deinit

    init(store: PrivacyReportStore = .shared) {
        self.store = store
        let rect = NSRect(x: 0, y: 0, width: 820, height: 580)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let win = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        win.title = "Privacy Report"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 680, height: 460)
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)
        buildUI()

        reportObserver = NotificationCenter.default.addObserver(
            forName: .safariumPrivacyReportDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.reloadData()
        }

        reloadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let reportObserver {
            NotificationCenter.default.removeObserver(reportObserver)
        }
    }

    // MARK: - Public Methods

    func showReport() {
        reloadData()
        guard let win = window else { return }
        if !win.isVisible {
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reloadData() {
        currentSummary = store.summary(days: 30)
        updateMetricsStrip()
        updateHighlightBanner()
        refreshMasterAndDetail()
    }

    func selectWebsite(host: String) {
        selectedWebsiteHost = host
        if displayMode == .websites {
            updateSelectionInPlace()
        }
    }

    func selectTracker(entityDomain: String) {
        selectedTrackerDomain = entityDomain
        if displayMode == .trackers {
            updateSelectionInPlace()
        }
    }

    // MARK: - Layout Construction

    private func buildUI() {
        guard let win = window else { return }

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.material = .windowBackground
        surfaceView.blendingMode = .behindWindow
        surfaceView.state = .followsWindowActiveState
        win.contentView = surfaceView

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: 34),
            mainStack.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -20),
            mainStack.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor, constant: -18)
        ])

        // 1. Top Header
        let headerRow = buildHeaderRow()
        mainStack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // 2. Metrics Summary Strip (4 equal translucent glass cards)
        let metricsRow = NSStackView(views: [trackersCard, websitesCard, cleaningCard, protectionCard])
        metricsRow.orientation = .horizontal
        metricsRow.distribution = .fillEqually
        metricsRow.alignment = .top
        metricsRow.spacing = 10
        metricsRow.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(metricsRow)
        metricsRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // 3. Most Contacted Highlight Banner
        buildHighlightBanner()
        mainStack.addArrangedSubview(highlightBanner)
        highlightBanner.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // 4. Mode Segmented Control + Count Status
        let modeRow = buildModeRow()
        mainStack.addArrangedSubview(modeRow)
        modeRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        // 5. Master-Detail Content Area + Empty State Area
        let bodyHolder = NSView()
        bodyHolder.translatesAutoresizingMaskIntoConstraints = false
        bodyHolder.setContentHuggingPriority(.defaultLow, for: .vertical)
        mainStack.addArrangedSubview(bodyHolder)
        bodyHolder.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        bodyHolder.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true

        buildSplitContent(inside: bodyHolder)
        buildEmptyState(inside: bodyHolder)
    }

    private func buildHeaderRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let shieldIcon = NSImageView()
        shieldIcon.translatesAutoresizingMaskIntoConstraints = false
        let shieldCfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        shieldIcon.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Privacy Report")?
            .withSymbolConfiguration(shieldCfg)
        shieldIcon.contentTintColor = PrivacyUIStyle.safariumGreen
        row.addSubview(shieldIcon)

        let titleLabel = NSTextField(labelWithString: "Privacy Report")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let subtitleLabel = NSTextField(labelWithString: "Last 30 Days")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addSubview(titleStack)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter websites or trackers"
        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addSubview(searchField)

        PrivacyUIStyle.configureGlassButton(settingsButton)
        settingsButton.target = self
        settingsButton.action = #selector(openPrivacySettingsTapped)
        row.addSubview(settingsButton)

        PrivacyUIStyle.configureGlassButton(clearButton)
        clearButton.target = self
        clearButton.action = #selector(clearReportTapped)
        row.addSubview(clearButton)

        let preferredSearchWidth = searchField.widthAnchor.constraint(equalToConstant: 210)
        preferredSearchWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),

            shieldIcon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            shieldIcon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            shieldIcon.widthAnchor.constraint(equalToConstant: 32),
            shieldIcon.heightAnchor.constraint(equalToConstant: 32),

            titleStack.leadingAnchor.constraint(equalTo: shieldIcon.trailingAnchor, constant: 10),
            titleStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: searchField.leadingAnchor, constant: -12),

            clearButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            settingsButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            searchField.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            preferredSearchWidth
        ])

        return row
    }

    private func buildHighlightBanner() {
        highlightBanner.translatesAutoresizingMaskIntoConstraints = false

        let body = highlightBanner.bodyView
        let starIcon = NSImageView()
        starIcon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        starIcon.image = NSImage(systemSymbolName: "eye.slash.circle.fill", accessibilityDescription: "Most Contacted Tracker")?
            .withSymbolConfiguration(cfg)
        starIcon.contentTintColor = PrivacyUIStyle.safariumGreen
        body.addSubview(starIcon)

        highlightLabel.translatesAutoresizingMaskIntoConstraints = false
        highlightLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        highlightLabel.textColor = .labelColor
        highlightLabel.lineBreakMode = .byWordWrapping
        highlightLabel.maximumNumberOfLines = 2
        highlightLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.addSubview(highlightLabel)

        categoryChipsStack.orientation = .horizontal
        categoryChipsStack.alignment = .centerY
        categoryChipsStack.spacing = 6
        categoryChipsStack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(categoryChipsStack)

        NSLayoutConstraint.activate([
            starIcon.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            starIcon.topAnchor.constraint(equalTo: body.topAnchor, constant: 10),
            starIcon.widthAnchor.constraint(equalToConstant: 20),
            starIcon.heightAnchor.constraint(equalToConstant: 20),

            highlightLabel.leadingAnchor.constraint(equalTo: starIcon.trailingAnchor, constant: 8),
            highlightLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
            highlightLabel.topAnchor.constraint(equalTo: body.topAnchor, constant: 10),

            categoryChipsStack.leadingAnchor.constraint(equalTo: highlightLabel.leadingAnchor),
            categoryChipsStack.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -12),
            categoryChipsStack.topAnchor.constraint(equalTo: highlightLabel.bottomAnchor, constant: 6),
            categoryChipsStack.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10)
        ])
    }

    private func buildModeRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.segmentStyle = .automatic
        segmentedControl.selectedSegment = displayMode.rawValue
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        row.addSubview(segmentedControl)

        countStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        countStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        countStatusLabel.textColor = .secondaryLabelColor
        countStatusLabel.alignment = .right
        row.addSubview(countStatusLabel)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            segmentedControl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            segmentedControl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            segmentedControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),

            countStatusLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            countStatusLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            countStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: segmentedControl.trailingAnchor, constant: 12)
        ])

        return row
    }

    private func buildSplitContent(inside container: NSView) {
        splitContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitContainer)

        NSLayoutConstraint.activate([
            splitContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitContainer.topAnchor.constraint(equalTo: container.topAnchor),
            splitContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        splitContainer.addSubview(masterCard)
        splitContainer.addSubview(detailCard)

        NSLayoutConstraint.activate([
            masterCard.leadingAnchor.constraint(equalTo: splitContainer.leadingAnchor),
            masterCard.topAnchor.constraint(equalTo: splitContainer.topAnchor),
            masterCard.bottomAnchor.constraint(equalTo: splitContainer.bottomAnchor),
            masterCard.widthAnchor.constraint(equalToConstant: 320),

            detailCard.leadingAnchor.constraint(equalTo: masterCard.trailingAnchor, constant: 12),
            detailCard.trailingAnchor.constraint(equalTo: splitContainer.trailingAnchor),
            detailCard.topAnchor.constraint(equalTo: splitContainer.topAnchor),
            detailCard.bottomAnchor.constraint(equalTo: splitContainer.bottomAnchor)
        ])

        PrivacyUIStyle.configureVerticalScrollStack(
            scrollView: masterScrollView,
            stackView: masterStack,
            inside: masterCard.bodyView,
            edgeInsets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
            spacing: 4
        )

        PrivacyUIStyle.configureVerticalScrollStack(
            scrollView: detailScrollView,
            stackView: detailStack,
            inside: detailCard.bodyView,
            edgeInsets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16),
            spacing: 10
        )
    }

    private func buildEmptyState(inside container: NSView) {
        emptyStateCard.translatesAutoresizingMaskIntoConstraints = false
        emptyStateCard.isHidden = true
        container.addSubview(emptyStateCard)

        NSLayoutConstraint.activate([
            emptyStateCard.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyStateCard.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyStateCard.topAnchor.constraint(equalTo: container.topAnchor),
            emptyStateCard.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let body = emptyStateCard.bodyView
        emptyShieldView.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        emptyShieldView.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        emptyShieldView.contentTintColor = PrivacyUIStyle.safariumGreen

        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyTitleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        emptyTitleLabel.textColor = .labelColor
        emptyTitleLabel.alignment = .center

        emptySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptySubtitleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        emptySubtitleLabel.textColor = .secondaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.maximumNumberOfLines = 3

        let stack = NSStackView(views: [emptyShieldView, emptyTitleLabel, emptySubtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -48)
        ])
    }

    // MARK: - Data Binding

    private func updateMetricsStrip() {
        let s = currentSummary
        trackersCard.update(
            value: "\(s.uniqueTrackersPrevented)",
            subtitle: "\(s.totalBlockedRequests) requests blocked"
        )
        websitesCard.update(
            value: "\(s.websitesContactingTrackersPercent)%",
            subtitle: "\(s.websitesContactingTrackersCount) of \(s.totalWebsitesVisited) sites"
        )
        cleaningCard.update(
            value: "\(s.httpsUpgradesCount + s.trackingParamsStrippedCount)",
            subtitle: "\(s.httpsUpgradesCount) upgrades · \(s.trackingParamsStrippedCount) links"
        )
        protectionCard.update(
            value: "\(s.fingerprintingAttemptsBlocked + s.cookiesBlockedCount)",
            subtitle: "\(s.fingerprintingAttemptsBlocked) probes · \(s.cookiesBlockedCount) cookies"
        )
    }

    private func updateHighlightBanner() {
        guard let top = currentSummary.mostContactedTracker else {
            highlightBanner.isHidden = true
            return
        }
        highlightBanner.isHidden = false
        let owner = top.ownerName.isEmpty ? top.entityDomain : top.ownerName
        let siteWord = top.websiteCount == 1 ? "website" : "websites"
        highlightLabel.stringValue = "Most contacted tracker: \(top.entityDomain) (\(owner)) was prevented from profiling you across \(top.websiteCount) \(siteWord)."

        for view in categoryChipsStack.arrangedSubviews {
            categoryChipsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let sortedCategories = currentSummary.categoryBreakdown
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.displayName < rhs.key.displayName
            }
            .prefix(4)

        for (category, count) in sortedCategories {
            let chip = PrivacyCategoryPillView(
                title: "\(category.displayName) · \(count)",
                symbolName: category.symbolName,
                color: category.badgeColor
            )
            categoryChipsStack.addArrangedSubview(chip)
        }
        categoryChipsStack.isHidden = sortedCategories.isEmpty
    }

    private func filteredWebsites() -> [PrivacyReportWebsiteEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let relevantWebsites = currentSummary.websites.filter {
            !$0.trackers.isEmpty ||
            $0.totalBlockedRequests > 0 ||
            $0.httpsUpgrades > 0 ||
            $0.paramsStripped > 0 ||
            $0.bounceTrackersMitigated > 0
        }
        guard !trimmed.isEmpty else { return relevantWebsites }
        return relevantWebsites.filter { site in
            if site.host.lowercased().contains(trimmed) { return true }
            return site.trackers.contains { detail in
                detail.entityDomain.lowercased().contains(trimmed) ||
                detail.ownerName.lowercased().contains(trimmed) ||
                detail.trackerDomains.contains(where: { $0.lowercased().contains(trimmed) })
            }
        }
    }

    private func filteredTrackers() -> [PrivacyReportTrackerEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return currentSummary.trackers }
        return currentSummary.trackers.filter { entry in
            entry.entityDomain.lowercased().contains(trimmed) ||
            entry.ownerName.lowercased().contains(trimmed) ||
            entry.category.displayName.lowercased().contains(trimmed) ||
            entry.trackerDomains.contains(where: { $0.lowercased().contains(trimmed) }) ||
            entry.websites.contains(where: { $0.lowercased().contains(trimmed) })
        }
    }

    private func refreshMasterAndDetail() {
        for v in masterStack.arrangedSubviews {
            masterStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        masterRowViews.removeAll()

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        switch displayMode {
        case .websites:
            let websites = filteredWebsites()
            countStatusLabel.stringValue = "\(websites.count) \(websites.count == 1 ? "website" : "websites")"
            if websites.isEmpty {
                clearDetailStack()
                showEmptyState(query: trimmedQuery, mode: .websites)
                return
            }
            splitContainer.isHidden = false
            emptyStateCard.isHidden = true

            if selectedWebsiteHost == nil || !websites.contains(where: { $0.host == selectedWebsiteHost }) {
                selectedWebsiteHost = websites.first?.host
            }
            let maxCount = max(1, websites.map(\.totalBlockedRequests).max() ?? 1)
            for site in websites {
                let isSelected = (site.host == selectedWebsiteHost)
                let subtitle: String
                if site.uniqueTrackerCount > 0 {
                    subtitle = "\(site.uniqueTrackerCount) \(site.uniqueTrackerCount == 1 ? "tracker" : "trackers")"
                } else if site.httpsUpgrades > 0 {
                    subtitle = "Upgraded to HTTPS"
                } else {
                    subtitle = "Protections active"
                }
                let row = PrivacyMasterBarRowView(
                    title: site.host,
                    subtitle: subtitle,
                    badgeText: "\(site.totalBlockedRequests)",
                    proportion: CGFloat(site.totalBlockedRequests) / CGFloat(maxCount),
                    barColor: PrivacyUIStyle.safariumGreen,
                    dotColor: nil,
                    isSelected: isSelected
                ) { [weak self] in
                    self?.selectedWebsiteHost = site.host
                    self?.updateSelectionInPlace()
                }
                masterStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: masterStack.widthAnchor).isActive = true
                masterRowViews.append((site.host, row))
            }

            refreshDetailPane(websites: websites, trackers: [])

        case .trackers:
            let trackers = filteredTrackers()
            countStatusLabel.stringValue = "\(trackers.count) \(trackers.count == 1 ? "tracker" : "trackers")"
            if trackers.isEmpty {
                clearDetailStack()
                showEmptyState(query: trimmedQuery, mode: .trackers)
                return
            }
            splitContainer.isHidden = false
            emptyStateCard.isHidden = true

            if selectedTrackerDomain == nil || !trackers.contains(where: { $0.entityDomain == selectedTrackerDomain }) {
                selectedTrackerDomain = trackers.first?.entityDomain
            }
            let maxSites = max(1, trackers.map(\.websiteCount).max() ?? 1)
            for tracker in trackers {
                let isSelected = (tracker.entityDomain == selectedTrackerDomain)
                let owner = tracker.ownerName.isEmpty ? tracker.entityDomain : tracker.ownerName
                let row = PrivacyMasterBarRowView(
                    title: tracker.entityDomain,
                    subtitle: "\(owner) · Across \(tracker.websiteCount) \(tracker.websiteCount == 1 ? "website" : "websites")",
                    badgeText: "\(tracker.totalBlockedRequests)",
                    proportion: CGFloat(tracker.websiteCount) / CGFloat(maxSites),
                    barColor: .systemBlue,
                    dotColor: tracker.category.badgeColor,
                    isSelected: isSelected
                ) { [weak self] in
                    self?.selectedTrackerDomain = tracker.entityDomain
                    self?.updateSelectionInPlace()
                }
                masterStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: masterStack.widthAnchor).isActive = true
                masterRowViews.append((tracker.entityDomain, row))
            }

            refreshDetailPane(websites: [], trackers: trackers)
        }
    }

    private func updateSelectionInPlace() {
        switch displayMode {
        case .websites:
            let websites = filteredWebsites()
            guard !websites.isEmpty else {
                refreshMasterAndDetail()
                return
            }
            if selectedWebsiteHost == nil || !websites.contains(where: { $0.host == selectedWebsiteHost }) {
                selectedWebsiteHost = websites.first?.host
            }
            for item in masterRowViews {
                item.view.isSelected = (item.key == selectedWebsiteHost)
            }
            refreshDetailPane(websites: websites, trackers: [])

        case .trackers:
            let trackers = filteredTrackers()
            guard !trackers.isEmpty else {
                refreshMasterAndDetail()
                return
            }
            if selectedTrackerDomain == nil || !trackers.contains(where: { $0.entityDomain == selectedTrackerDomain }) {
                selectedTrackerDomain = trackers.first?.entityDomain
            }
            for item in masterRowViews {
                item.view.isSelected = (item.key == selectedTrackerDomain)
            }
            refreshDetailPane(websites: [], trackers: trackers)
        }
    }

    private func clearDetailStack() {
        for v in detailStack.arrangedSubviews {
            detailStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func refreshDetailPane(websites: [PrivacyReportWebsiteEntry], trackers: [PrivacyReportTrackerEntry]) {
        clearDetailStack()
        switch displayMode {
        case .websites:
            if let selected = websites.first(where: { $0.host == selectedWebsiteHost }) ?? websites.first {
                populateWebsiteDetail(selected)
            }
        case .trackers:
            if let selected = trackers.first(where: { $0.entityDomain == selectedTrackerDomain }) ?? trackers.first {
                populateTrackerDetail(selected)
            }
        }
    }

    private func showEmptyState(query: String, mode: DisplayMode) {
        splitContainer.isHidden = true
        emptyStateCard.isHidden = false

        if !query.isEmpty {
            emptyTitleLabel.stringValue = "No Matches for \"\(query)\""
            emptySubtitleLabel.stringValue = "Try a different website domain, tracker name, or clear the search filter."
        } else {
            emptyTitleLabel.stringValue = "No Trackers Prevented Yet"
            emptySubtitleLabel.stringValue = mode == .websites
                ? "As you browse in non-private windows, Safarium will list websites and the trackers prevented from profiling you."
                : "Prevented tracker entities and the websites contacting them over the last 30 days will appear here."
        }
    }

    private func populateWebsiteDetail(_ site: PrivacyReportWebsiteEntry) {
        let headerTitle = NSTextField(labelWithString: site.host)
        headerTitle.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        headerTitle.textColor = .labelColor
        headerTitle.lineBreakMode = .byTruncatingMiddle

        let headerSubtitle = NSTextField(labelWithString: "\(site.uniqueTrackerCount) unique trackers · \(site.totalBlockedRequests) requests blocked")
        headerSubtitle.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        headerSubtitle.textColor = .secondaryLabelColor

        detailStack.addArrangedSubview(headerTitle)
        detailStack.addArrangedSubview(headerSubtitle)

        // Site-level protection badges
        let badges: [(String, Int, NSColor)] = [
            ("Cookies Blocked", site.cookiesBlocked, .systemOrange),
            ("Links Cleaned", site.paramsStripped, .systemTeal),
            ("Fingerprinting Neutralized", site.fingerprintsBlocked, .systemPurple),
            ("HTTPS Upgrades", site.httpsUpgrades, PrivacyUIStyle.safariumGreen),
            ("Bounce Trackers", site.bounceTrackersMitigated, .systemBlue)
        ].filter { $0.1 > 0 }

        if !badges.isEmpty {
            let wrap = PrivacyWrapChipsView(chips: badges.map { ("\($0.0): \($0.1)", $0.2) })
            detailStack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }

        let sep = PrivacyHairlineView()
        detailStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let sectionLabel = NSTextField(labelWithString: "Trackers Prevented on \(site.host)")
        sectionLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(sectionLabel)

        if site.trackers.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No third-party trackers contacted on \(site.host).")
            emptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            emptyLabel.textColor = .secondaryLabelColor
            detailStack.addArrangedSubview(emptyLabel)
        } else {
            for tracker in site.trackers {
                let card = makeSiteTrackerDetailRow(tracker)
                detailStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            }
        }
    }

    private func makeSiteTrackerDetailRow(_ tracker: PrivacyReportSiteTrackerDetail) -> NSView {
        let card = PrivacySubtleRowBox()
        let owner = tracker.ownerName.isEmpty ? tracker.entityDomain : tracker.ownerName

        let domainLabel = NSTextField(labelWithString: tracker.entityDomain)
        domainLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        domainLabel.textColor = .labelColor
        domainLabel.lineBreakMode = .byTruncatingTail

        let pill = PrivacyCategoryPillView(
            title: tracker.category.displayName,
            symbolName: tracker.category.symbolName,
            color: tracker.category.badgeColor
        )

        let countLabel = NSTextField(labelWithString: "\(tracker.blockedCount) blocked")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        let topRow = NSView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        for v in [domainLabel, pill, countLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topRow.addSubview(v)
        }
        domainLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            topRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            domainLabel.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            domainLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),

            pill.leadingAnchor.constraint(equalTo: domainLabel.trailingAnchor, constant: 8),
            pill.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pill.trailingAnchor, constant: 8)
        ])

        let subInfo = NSTextField(wrappingLabelWithString: owner + (tracker.trackerDomains.isEmpty ? "" : " · Hosts: " + tracker.trackerDomains.joined(separator: ", ")))
        subInfo.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subInfo.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [topRow, subInfo])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return card
    }

    private func populateTrackerDetail(_ tracker: PrivacyReportTrackerEntry) {
        let owner = tracker.ownerName.isEmpty ? tracker.entityDomain : tracker.ownerName

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let headerTitle = NSTextField(labelWithString: tracker.entityDomain)
        headerTitle.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        headerTitle.textColor = .labelColor

        let pill = PrivacyCategoryPillView(
            title: tracker.category.displayName,
            symbolName: tracker.category.symbolName,
            color: tracker.category.badgeColor
        )
        titleRow.addArrangedSubview(headerTitle)
        titleRow.addArrangedSubview(pill)
        detailStack.addArrangedSubview(titleRow)

        let siteWord = tracker.websiteCount == 1 ? "website" : "websites"
        let ownerSubtitle = NSTextField(labelWithString: "Owner: \(owner) · \(tracker.totalBlockedRequests) requests blocked across \(tracker.websiteCount) \(siteWord)")
        ownerSubtitle.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        ownerSubtitle.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(ownerSubtitle)

        if !tracker.trackerDomains.isEmpty {
            let domainsTitle = NSTextField(labelWithString: "Observed Tracker Hosts")
            domainsTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            domainsTitle.textColor = .secondaryLabelColor
            detailStack.addArrangedSubview(domainsTitle)

            let domainsLabel = NSTextField(wrappingLabelWithString: tracker.trackerDomains.joined(separator: ", "))
            domainsLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            domainsLabel.textColor = .labelColor
            detailStack.addArrangedSubview(domainsLabel)
        }

        let sep = PrivacyHairlineView()
        detailStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let sitesHeader = NSTextField(labelWithString: "Websites Contacting \(tracker.entityDomain)")
        sitesHeader.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        sitesHeader.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(sitesHeader)

        for siteHost in tracker.websites {
            let row = PrivacySubtleRowBox()
            let globe = NSImageView()
            globe.translatesAutoresizingMaskIntoConstraints = false
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            globe.contentTintColor = .secondaryLabelColor

            let lbl = NSTextField(labelWithString: siteHost)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            lbl.textColor = .labelColor
            lbl.lineBreakMode = .byTruncatingMiddle

            row.addSubview(globe)
            row.addSubview(lbl)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 30),
                globe.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                globe.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                globe.widthAnchor.constraint(equalToConstant: 16),
                globe.heightAnchor.constraint(equalToConstant: 16),
                lbl.leadingAnchor.constraint(equalTo: globe.trailingAnchor, constant: 8),
                lbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            detailStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
    }

    // MARK: - Actions

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        if let mode = DisplayMode(rawValue: sender.selectedSegment) {
            displayMode = mode
        }
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
    }

    @objc private func openPrivacySettingsTapped() {
        onOpenPrivacySettings?()
    }

    @objc private func clearReportTapped() {
        onClearReport?()
    }
}

// MARK: - Shared Tahoe Liquid Glass Helpers & Subviews

enum PrivacyUIStyle {
    static let safariumGreen = NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1.0) // #34C759

    static func configureGlassButton(_ button: NSButton, accent: Bool = false) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.font = NSFont.systemFont(ofSize: 12.5, weight: accent ? .medium : .regular)
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .capsule
        } else {
            button.bezelStyle = .rounded
        }
        if accent {
            button.bezelColor = .controlAccentColor
        }
    }

    static func configureVerticalScrollStack(
        scrollView: NSScrollView,
        stackView: NSStackView,
        inside container: NSView,
        edgeInsets: NSEdgeInsets,
        spacing: CGFloat
    ) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let clip = PrivacyFlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip

        let doc = PrivacyFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = doc

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = spacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stackView)

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            stackView.topAnchor.constraint(equalTo: doc.topAnchor, constant: edgeInsets.top),
            stackView.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: edgeInsets.left),
            stackView.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -edgeInsets.right),
            stackView.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -edgeInsets.bottom)
        ])
    }
}

final class PrivacyFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PrivacyFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

final class PrivacyGlassCardView: NSView {
    let bodyView = NSView()

    init(cornerRadius: CGFloat = 14) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        bodyView.translatesAutoresizingMaskIntoConstraints = false
        bodyView.wantsLayer = true

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = bodyView
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0.5
            layer?.masksToBounds = true
            addSubview(bodyView)
            NSLayoutConstraint.activate([
                bodyView.leadingAnchor.constraint(equalTo: leadingAnchor),
                bodyView.trailingAnchor.constraint(equalTo: trailingAnchor),
                bodyView.topAnchor.constraint(equalTo: topAnchor),
                bodyView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            updateFallbackAppearance()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if #unavailable(macOS 26.0) {
            updateFallbackAppearance()
        }
    }

    private func updateFallbackAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.white.withAlphaComponent(0.76)).cgColor
            layer?.borderColor = (isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.09)).cgColor
        }
    }
}

private final class PrivacyMetricCardView: NSView {
    private let card = PrivacyGlassCardView(cornerRadius: 14)
    private let valueLabel = NSTextField(labelWithString: "0")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(title: String, symbolName: String, accentColor: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 78)
        ])

        let body = card.bodyView

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = accentColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: [iconView, titleLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 5
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [headerRow, valueLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: body.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10),
            headerRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(value: String, subtitle: String) {
        valueLabel.stringValue = value
        subtitleLabel.stringValue = subtitle
    }
}

private final class PrivacyMasterBarRowView: NSView {
    var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            applyColors()
        }
    }
    private let onSelect: () -> Void
    private var isHovered = false
    private var tracking: NSTrackingArea?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let barTrack = NSView()
    private let barFill = NSView()
    private let barColor: NSColor
    private let dotView: NSView?
    private let dotColor: NSColor?

    init(
        title: String,
        subtitle: String,
        badgeText: String,
        proportion: CGFloat,
        barColor: NSColor,
        dotColor: NSColor?,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.isSelected = isSelected
        self.barColor = barColor
        self.dotColor = dotColor
        self.onSelect = onSelect

        var createdDot: NSView?
        if dotColor != nil {
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            createdDot = dot
        }
        self.dotView = createdDot

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        let topRow = NSView()
        topRow.translatesAutoresizingMaskIntoConstraints = false

        var leadingAnchorTarget = topRow.leadingAnchor
        if let dot = dotView {
            topRow.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
                dot.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8)
            ])
            leadingAnchorTarget = dot.trailingAnchor
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topRow.addSubview(titleLabel)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.stringValue = badgeText
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        badgeLabel.alignment = .right
        topRow.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            topRow.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchorTarget, constant: dotView == nil ? 0 : 6),
            titleLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -8),
            badgeLabel.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor)
        ])

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = 2.5

        barFill.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 2.5
        barTrack.addSubview(barFill)

        let clamped = max(0.06, min(1.0, proportion))
        NSLayoutConstraint.activate([
            barTrack.heightAnchor.constraint(equalToConstant: 5),
            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
            barFill.widthAnchor.constraint(equalTo: barTrack.widthAnchor, multiplier: clamped)
        ])

        let stack = NSStackView(views: [topRow, subtitleLabel, barTrack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barTrack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; applyColors() }
    override func mouseExited(with event: NSEvent) { isHovered = false; applyColors() }
    override func mouseDown(with event: NSEvent) { onSelect() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .medium)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            barTrack.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
            barFill.layer?.backgroundColor = (isSelected ? NSColor.white.withAlphaComponent(0.9) : barColor).cgColor
            if let dotColor {
                dotView?.layer?.backgroundColor = (isSelected ? NSColor.white : dotColor).cgColor
            }
            if isSelected {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                titleLabel.textColor = .white
                subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.86)
                badgeLabel.textColor = .white
            } else if isHovered {
                layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)).cgColor
                titleLabel.textColor = .labelColor
                subtitleLabel.textColor = .secondaryLabelColor
                badgeLabel.textColor = .secondaryLabelColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                titleLabel.textColor = .labelColor
                subtitleLabel.textColor = .secondaryLabelColor
                badgeLabel.textColor = .secondaryLabelColor
            }
        }
    }
}

final class PrivacyCategoryPillView: NSView {
    private let pillColor: NSColor

    init(title: String, symbolName: String? = nil, color: NSColor) {
        self.pillColor = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let symbolName, let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            let iv = NSImageView(image: img.withSymbolConfiguration(cfg) ?? img)
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.contentTintColor = color
            stack.addArrangedSubview(iv)
        }

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = color
        stack.addArrangedSubview(label)

        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = pillColor.withAlphaComponent(0.16).cgColor
        }
    }
}

private final class PrivacyWrapChipsView: NSView {
    init(chips: [(String, NSColor)], maxRowWidth: CGFloat = 260) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 5
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        var currentRow = NSStackView()
        currentRow.orientation = .horizontal
        currentRow.alignment = .centerY
        currentRow.spacing = 6
        currentRow.translatesAutoresizingMaskIntoConstraints = false
        var currentWidth: CGFloat = 0

        for (title, color) in chips {
            let pill = PrivacyCategoryPillView(title: title, color: color)
            let pillWidth = pill.fittingSize.width
            if !currentRow.arrangedSubviews.isEmpty && (currentWidth + 6 + pillWidth > maxRowWidth) {
                rowsStack.addArrangedSubview(currentRow)
                currentRow = NSStackView()
                currentRow.orientation = .horizontal
                currentRow.alignment = .centerY
                currentRow.spacing = 6
                currentRow.translatesAutoresizingMaskIntoConstraints = false
                currentWidth = 0
            }
            if !currentRow.arrangedSubviews.isEmpty { currentWidth += 6 }
            currentWidth += pillWidth
            currentRow.addArrangedSubview(pill)
        }
        if !currentRow.arrangedSubviews.isEmpty {
            rowsStack.addArrangedSubview(currentRow)
        }

        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

private final class PrivacySubtleRowBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.05)
                : NSColor.black.withAlphaComponent(0.035)).cgColor
        }
    }
}

final class PrivacyHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.08)).cgColor
        }
    }
}
