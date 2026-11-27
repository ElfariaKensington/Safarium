import AppKit

/// Native macOS Tahoe toolbar/address-bar Privacy Shield popover controller.
/// Presents current-site connection security, per-site protection switch, blocked trackers,
/// Private Browsing isolation badge, and quick actions to open the full Privacy Report or Website Settings.
final class PrivacyPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var contentViewController: PrivacyPopoverViewController?

    var onToggleSiteProtection: ((String, Bool) -> Void)?
    var onOpenPrivacyReport: (() -> Void)?
    var onOpenWebsiteSettings: ((String) -> Void)?

    var isShown: Bool { popover?.isShown ?? false }

    func show(snapshot: TabPrivacySnapshot, summary: PrivacyReportSummary, relativeTo anchorView: NSView) {
        if let existing = popover, existing.isShown {
            existing.close()
            popover = nil
        }

        let vc = PrivacyPopoverViewController(snapshot: snapshot, summary: summary)
        vc.onToggleSiteProtection = { [weak self] host, enabled in
            self?.onToggleSiteProtection?(host, enabled)
        }
        vc.onOpenPrivacyReport = { [weak self] in
            self?.close()
            self?.onOpenPrivacyReport?()
        }
        vc.onOpenWebsiteSettings = { [weak self] host in
            self?.close()
            self?.onOpenWebsiteSettings?(host)
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.appearance = anchorView.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        pop.contentViewController = vc
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: anchorView.isFlipped ? .maxY : .minY)

        self.popover = pop
        self.contentViewController = vc
    }

    func update(snapshot: TabPrivacySnapshot, summary: PrivacyReportSummary) {
        contentViewController?.apply(snapshot: snapshot, summary: summary)
    }

    func close() {
        popover?.close()
        popover = nil
        contentViewController = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        contentViewController = nil
    }
}

/// Content view controller for the Privacy Shield popover (`336pt` wide).
/// Exposed cleanly for hermetic offscreen instantiation and unit testing.
final class PrivacyPopoverViewController: NSViewController {
    static let popoverWidth: CGFloat = 336

    var onToggleSiteProtection: ((String, Bool) -> Void)?
    var onOpenPrivacyReport: (() -> Void)?
    var onOpenWebsiteSettings: ((String) -> Void)?

    private(set) var snapshot: TabPrivacySnapshot
    private(set) var summary: PrivacyReportSummary

    // Controls
    private let rootStack = NSStackView()
    private let shieldImageView = NSImageView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let securitySubtitleLabel = NSTextField(labelWithString: "")
    private let privateBadgeContainer = NSView()
    private let privateBadgeLabel = NSTextField(labelWithString: "Private Browsing — Never Logged")

    private let toggleRow = NSView()
    private let toggleLabel = NSTextField(labelWithString: "Privacy Protections")
    private let protectionSwitch = NSSwitch()

    private let summaryLineLabel = NSTextField(wrappingLabelWithString: "")
    private let statChipsRow = NSStackView()
    private let trackersScrollView = NSScrollView()
    private let trackersStack = NSStackView()
    private var trackersHeightConstraint: NSLayoutConstraint?

    private let footerDivider = PrivacyHairlineView()
    private let footerTotalLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyReportButton = NSButton(title: "Privacy Report…", target: nil, action: nil)
    private let websiteSettingsButton = NSButton(title: "Website Settings…", target: nil, action: nil)

    init(
        snapshot: TabPrivacySnapshot = .empty(tabID: ""),
        summary: PrivacyReportSummary = .empty
    ) {
        self.snapshot = snapshot
        self.summary = summary
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let root = PrivacyFlippedView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 320))
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root

        let backdrop = NSVisualEffectView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        root.addSubview(backdrop)

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rootStack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.popoverWidth),

            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            rootStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            rootStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        buildHeaderSection()
        buildToggleSection()
        buildBreakdownSection()
        buildFooterSection()

        apply(snapshot: snapshot, summary: summary)
    }

    // MARK: - Section Builders

    private func buildHeaderSection() {
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        shieldImageView.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(shieldImageView)

        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        hostLabel.textColor = .labelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        securitySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        securitySubtitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        securitySubtitleLabel.textColor = .secondaryLabelColor
        securitySubtitleLabel.lineBreakMode = .byTruncatingTail
        securitySubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [hostLabel, securitySubtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(textStack)

        NSLayoutConstraint.activate([
            headerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            shieldImageView.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            shieldImageView.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            shieldImageView.widthAnchor.constraint(equalToConstant: 26),
            shieldImageView.heightAnchor.constraint(equalToConstant: 26),

            textStack.leadingAnchor.constraint(equalTo: shieldImageView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: headerRow.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor)
        ])

        rootStack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // Private Browsing Badge
        let badgeBox = PrivacyDynamicTintedView {
            NSColor.systemPurple.withAlphaComponent(0.14)
        }
        badgeBox.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.layer?.cornerRadius = 8
        badgeBox.layer?.cornerCurve = .continuous

        let lockIcon = NSImageView()
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        let lockCfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        lockIcon.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(lockCfg)
        lockIcon.contentTintColor = .systemPurple

        privateBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        privateBadgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        privateBadgeLabel.textColor = .systemPurple

        badgeBox.addSubview(lockIcon)
        badgeBox.addSubview(privateBadgeLabel)
        NSLayoutConstraint.activate([
            badgeBox.heightAnchor.constraint(equalToConstant: 24),
            lockIcon.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 8),
            lockIcon.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor),
            privateBadgeLabel.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 6),
            privateBadgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeBox.trailingAnchor, constant: -8),
            privateBadgeLabel.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor)
        ])

        privateBadgeContainer.translatesAutoresizingMaskIntoConstraints = false
        privateBadgeContainer.addSubview(badgeBox)
        NSLayoutConstraint.activate([
            badgeBox.leadingAnchor.constraint(equalTo: privateBadgeContainer.leadingAnchor),
            badgeBox.trailingAnchor.constraint(equalTo: privateBadgeContainer.trailingAnchor),
            badgeBox.topAnchor.constraint(equalTo: privateBadgeContainer.topAnchor),
            badgeBox.bottomAnchor.constraint(equalTo: privateBadgeContainer.bottomAnchor)
        ])

        rootStack.addArrangedSubview(privateBadgeContainer)
        privateBadgeContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    private func buildToggleSection() {
        toggleRow.translatesAutoresizingMaskIntoConstraints = false

        toggleLabel.translatesAutoresizingMaskIntoConstraints = false
        toggleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        toggleLabel.textColor = .labelColor
        toggleRow.addSubview(toggleLabel)

        protectionSwitch.translatesAutoresizingMaskIntoConstraints = false
        protectionSwitch.controlSize = .small
        protectionSwitch.target = self
        protectionSwitch.action = #selector(protectionSwitchChanged(_:))
        toggleRow.addSubview(protectionSwitch)

        NSLayoutConstraint.activate([
            toggleRow.heightAnchor.constraint(equalToConstant: 26),
            toggleLabel.leadingAnchor.constraint(equalTo: toggleRow.leadingAnchor),
            toggleLabel.centerYAnchor.constraint(equalTo: toggleRow.centerYAnchor),
            protectionSwitch.trailingAnchor.constraint(equalTo: toggleRow.trailingAnchor),
            protectionSwitch.centerYAnchor.constraint(equalTo: toggleRow.centerYAnchor),
            toggleLabel.trailingAnchor.constraint(lessThanOrEqualTo: protectionSwitch.leadingAnchor, constant: -8)
        ])

        rootStack.addArrangedSubview(toggleRow)
        toggleRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    private func buildBreakdownSection() {
        let div = PrivacyHairlineView()
        rootStack.addArrangedSubview(div)
        div.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        div.heightAnchor.constraint(equalToConstant: 1).isActive = true

        summaryLineLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLineLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        summaryLineLabel.textColor = .labelColor
        summaryLineLabel.maximumNumberOfLines = 2
        rootStack.addArrangedSubview(summaryLineLabel)
        summaryLineLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        statChipsRow.orientation = .vertical
        statChipsRow.alignment = .leading
        statChipsRow.spacing = 4
        statChipsRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(statChipsRow)
        statChipsRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        PrivacyUIStyle.configureVerticalScrollStack(
            scrollView: trackersScrollView,
            stackView: trackersStack,
            inside: listContainer,
            edgeInsets: NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0),
            spacing: 5
        )
        let hConstraint = listContainer.heightAnchor.constraint(equalToConstant: 0)
        hConstraint.isActive = true
        trackersHeightConstraint = hConstraint

        rootStack.addArrangedSubview(listContainer)
        listContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    private func buildFooterSection() {
        rootStack.addArrangedSubview(footerDivider)
        footerDivider.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        footerDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        footerTotalLabel.translatesAutoresizingMaskIntoConstraints = false
        footerTotalLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        footerTotalLabel.textColor = .secondaryLabelColor
        footerTotalLabel.maximumNumberOfLines = 2
        rootStack.addArrangedSubview(footerTotalLabel)
        footerTotalLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        PrivacyUIStyle.configureGlassButton(privacyReportButton)
        privacyReportButton.target = self
        privacyReportButton.action = #selector(openPrivacyReportTapped)

        PrivacyUIStyle.configureGlassButton(websiteSettingsButton)
        websiteSettingsButton.target = self
        websiteSettingsButton.action = #selector(openWebsiteSettingsTapped)

        let actionsRow = NSStackView(views: [privacyReportButton, websiteSettingsButton])
        actionsRow.orientation = .horizontal
        actionsRow.distribution = .fillEqually
        actionsRow.spacing = 8
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(actionsRow)
        actionsRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    // MARK: - State Application

    func apply(snapshot: TabPrivacySnapshot, summary: PrivacyReportSummary) {
        self.snapshot = snapshot
        self.summary = summary

        // Host & security state
        if snapshot.host.isEmpty {
            hostLabel.stringValue = snapshot.isPrivate ? "Private Window" : "Start Page"
        } else {
            hostLabel.stringValue = snapshot.host
        }
        securitySubtitleLabel.stringValue = securitySubtitle(for: snapshot.securityState)

        // Shield icon & color
        let shieldCfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let (symbolName, tintColor) = shieldAppearance(for: snapshot)
        shieldImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Privacy Shield")?
            .withSymbolConfiguration(shieldCfg)
        shieldImageView.contentTintColor = tintColor

        // Private Browsing badge & strict 30-day isolation
        privateBadgeContainer.isHidden = !snapshot.isPrivate
        if snapshot.isPrivate {
            footerDivider.isHidden = true
            footerTotalLabel.isHidden = true
            footerTotalLabel.stringValue = ""
        } else {
            footerDivider.isHidden = false
            footerTotalLabel.isHidden = false
            footerTotalLabel.stringValue = "30-Day Total: \(summary.uniqueTrackersPrevented) trackers prevented across \(summary.websitesContactingTrackersPercent)% of sites"
        }

        // Per-site toggle visibility for real HTTP/HTTPS hosts
        let isRealWebHost = !snapshot.host.isEmpty && snapshot.securityState != .internalPage
        toggleRow.isHidden = !isRealWebHost
        protectionSwitch.state = snapshot.protectionsEnabled ? .on : .off
        websiteSettingsButton.isEnabled = !snapshot.host.isEmpty

        refreshSummaryAndTrackersList()
        recalculatePreferredSize()
    }

    private func refreshSummaryAndTrackersList() {
        for v in statChipsRow.arrangedSubviews {
            statChipsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for v in trackersStack.arrangedSubviews {
            trackersStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        if !snapshot.protectionsEnabled {
            summaryLineLabel.stringValue = "Protections paused for this website"
            statChipsRow.isHidden = true
            trackersHeightConstraint?.constant = 0
            trackersScrollView.superview?.isHidden = true
            return
        }

        if snapshot.totalTrackersBlocked > 0 {
            let noun = snapshot.totalTrackersBlocked == 1 ? "tracker" : "trackers"
            summaryLineLabel.stringValue = "\(snapshot.totalTrackersBlocked) \(noun) prevented from profiling you"
        } else {
            summaryLineLabel.stringValue = "No known trackers found on this webpage"
        }

        var chips: [(String, NSColor)] = []
        if snapshot.cookiesBlocked > 0 {
            chips.append(("\(snapshot.cookiesBlocked) cookies", .systemOrange))
        }
        if snapshot.paramsStripped > 0 {
            chips.append(("\(snapshot.paramsStripped) links", .systemTeal))
        }
        if snapshot.fingerprintsBlocked > 0 {
            chips.append(("\(snapshot.fingerprintsBlocked) probes", .systemPurple))
        }
        if snapshot.bounceTrackersMitigated > 0 {
            chips.append(("\(snapshot.bounceTrackersMitigated) bounce", .systemBlue))
        }
        if snapshot.httpsUpgraded {
            chips.append(("HTTPS", PrivacyUIStyle.safariumGreen))
        }

        let maxRowWidth: CGFloat = Self.popoverWidth - 32
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
                statChipsRow.addArrangedSubview(currentRow)
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
            statChipsRow.addArrangedSubview(currentRow)
        }
        statChipsRow.isHidden = chips.isEmpty

        for entry in snapshot.trackers {
            let row = makeTrackerRow(entry)
            trackersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: trackersStack.widthAnchor).isActive = true
        }

        let count = snapshot.trackers.count
        let listHeight: CGFloat = count == 0 ? 0 : min(176, CGFloat(count) * 40 + 6)
        trackersHeightConstraint?.constant = listHeight
        trackersScrollView.superview?.isHidden = (count == 0)
    }

    private func makeTrackerRow(_ entry: PrivacyReportTrackerEntry) -> NSView {
        let row = PrivacyDynamicTintedView {
            NSColor.labelColor.withAlphaComponent(0.05)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.layer?.cornerRadius = 8
        row.layer?.cornerCurve = .continuous

        let entityLabel = NSTextField(labelWithString: entry.entityDomain)
        entityLabel.translatesAutoresizingMaskIntoConstraints = false
        entityLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        entityLabel.textColor = .labelColor
        entityLabel.lineBreakMode = .byTruncatingTail
        entityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let owner = entry.ownerName.isEmpty ? entry.entityDomain : entry.ownerName
        let ownerLabel = NSTextField(labelWithString: owner)
        ownerLabel.translatesAutoresizingMaskIntoConstraints = false
        ownerLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        ownerLabel.textColor = .secondaryLabelColor
        ownerLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [entityLabel, ownerLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let pill = PrivacyCategoryPillView(
            title: entry.category.displayName,
            color: entry.category.badgeColor
        )

        let countLabel = NSTextField(labelWithString: "\(entry.totalBlockedRequests)")
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        row.addSubview(textStack)
        row.addSubview(pill)
        row.addSubview(countLabel)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 36),

            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -6),

            pill.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),
            pill.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16)
        ])

        return row
    }

    private func recalculatePreferredSize() {
        view.layoutSubtreeIfNeeded()
        let fitting = rootStack.fittingSize
        let totalHeight = max(180, min(520, fitting.height + 28))
        preferredContentSize = NSSize(width: Self.popoverWidth, height: totalHeight)
        view.frame = NSRect(x: 0, y: 0, width: Self.popoverWidth, height: totalHeight)
    }

    private func securitySubtitle(for state: ConnectionSecurityState) -> String {
        switch state {
        case .internalPage:
            return state.displayTitle
        case .secureHTTPS:
            return "Connection is Secure (HTTPS)"
        case .upgradedHTTPS:
            return "Automatically Upgraded to HTTPS"
        case .insecureHTTP:
            return "Not Secure (HTTP)"
        case .certificateError:
            return "Certificate Warning"
        }
    }

    private func shieldAppearance(for snapshot: TabPrivacySnapshot) -> (String, NSColor) {
        switch snapshot.securityState {
        case .certificateError:
            return ("exclamationmark.shield.fill", .systemRed)
        case .insecureHTTP:
            return ("exclamationmark.triangle.fill", .systemOrange)
        case .internalPage, .secureHTTPS, .upgradedHTTPS:
            if !snapshot.protectionsEnabled {
                return ("shield.slash.fill", .secondaryLabelColor)
            }
            return ("shield.lefthalf.filled", PrivacyUIStyle.safariumGreen)
        }
    }

    // MARK: - Actions

    @objc private func protectionSwitchChanged(_ sender: NSSwitch) {
        let isOn = (sender.state == .on)
        snapshot.protectionsEnabled = isOn
        let (symbolName, tintColor) = shieldAppearance(for: snapshot)
        let shieldCfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        shieldImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Privacy Shield")?
            .withSymbolConfiguration(shieldCfg)
        shieldImageView.contentTintColor = tintColor

        refreshSummaryAndTrackersList()
        recalculatePreferredSize()
        onToggleSiteProtection?(snapshot.host, isOn)
    }

    @objc private func openPrivacyReportTapped() {
        onOpenPrivacyReport?()
    }

    @objc private func openWebsiteSettingsTapped() {
        guard !snapshot.host.isEmpty else { return }
        onOpenWebsiteSettings?(snapshot.host)
    }
}

private final class PrivacyDynamicTintedView: NSView {
    private let colorProvider: () -> NSColor

    init(colorProvider: @escaping () -> NSColor) {
        self.colorProvider = colorProvider
        super.init(frame: .zero)
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = colorProvider().cgColor
        }
    }
}
