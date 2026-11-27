import AppKit
import Foundation

struct InspectLocalTabSnapshot: Equatable {
    let tabID: String
    let windowIndex: Int
    let title: String
    let urlString: String
    let isPrivate: Bool
    let isActive: Bool
}

struct InspectRemoteDebuggingStatus: Equatable {
    let activePort: Int
    let isActive: Bool
    let webSocketURL: String?
    let activePortFilePath: String?
}

struct InspectCDPTarget: Decodable, Equatable {
    let id: String
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerUrl: String?
    let devtoolsFrontendUrl: String?
}

struct InspectCDPVersionInfo: Decodable, Equatable {
    let browser: String?
    let protocolVersion: String?
    let webSocketDebuggerUrl: String?

    enum CodingKeys: String, CodingKey {
        case browser = "Browser"
        case protocolVersion = "Protocol-Version"
        case webSocketDebuggerUrl
    }
}

struct InspectEndpointDiscoveryResult: Equatable {
    let endpoint: String
    let browserName: String?
    let protocolVersion: String?
    let browserWebSocketURL: String?
    let targets: [InspectCDPTarget]
    let isReachable: Bool
}

/// Native macOS AppKit implementation of `safarium://inspect` and `safarium://inspect/#remote-debugging`
/// hosted directly inside a Safarium tab (matching Chromium 156's Inspect UI & Remote Debugging workflow).
final class InspectPageView: NSView, NSTextFieldDelegate {

    // MARK: - Callbacks & Data Providers

    var onSelectSection: ((InspectPageSection) -> Void)?
    var onOpenURL: ((URL, Bool) -> Void)?
    var onInspectLocalTab: ((String) -> Void)?
    var onFocusLocalTab: ((String) -> Void)?
    var onReloadLocalTab: ((String) -> Void)?
    var onCloseLocalTab: ((String) -> Void)?
    var onInspectRemoteTarget: ((String) -> Void)?
    var onOpenExtensionsSettings: ((String?) -> Void)?
    var onRelaunchApp: (() -> Void)?

    var localTabsProvider: (() -> [InspectLocalTabSnapshot])?
    var extensionsProvider: (() -> [BrowserExtensionItem])?
    var remoteDebuggingStatusProvider: (() -> InspectRemoteDebuggingStatus)?

    // MARK: - State

    private(set) var currentSection: InspectPageSection = .devices
    private var localCDPTargets: [InspectCDPTarget] = []
    private var discoveredEndpoints: [InspectEndpointDiscoveryResult] = []
    private var isRefreshingNetwork: Bool = false
    private var refreshGeneration: Int = 0

    // MARK: - Views

    private let sidebarContainer = NSView()
    private let sidebarTitleLabel = NSTextField(labelWithString: "Inspect")
    private let sidebarStack = NSStackView()
    private let sidebarDivider = NSBox()
    private var sidebarButtons: [InspectPageSection: NSButton] = [:]
    private let remoteStatusDot = NSView()

    private let contentScrollView = NSScrollView()
    private let contentDocView = FlippedContentView()
    private let contentStack = NSStackView()

    private weak var portTextField: NSTextField?
    private weak var newTargetTextField: NSTextField?

    private static let cdpSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 2.0
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Appearance

    var effectiveTopColor: NSColor {
        isDarkMode
            ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1.0)
            : NSColor.white
    }

    var prefersDarkAppearance: Bool { isDarkMode }

    private var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var sidebarBackgroundColor: NSColor {
        isDarkMode
            ? NSColor(srgbRed: 0.135, green: 0.135, blue: 0.145, alpha: 1.0)
            : NSColor(srgbRed: 0.965, green: 0.968, blue: 0.976, alpha: 1.0)
    }

    private var cardBackgroundColor: NSColor {
        isDarkMode
            ? NSColor(srgbRed: 0.155, green: 0.157, blue: 0.168, alpha: 1.0)
            : NSColor(srgbRed: 0.975, green: 0.977, blue: 0.984, alpha: 1.0)
    }

    private var cardBorderColor: NSColor {
        isDarkMode
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.08)
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupLayout()
        applyColors()
        rebuildSectionContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        rebuildSectionContent()
    }

    // MARK: - Public API

    func setSection(_ section: InspectPageSection, notifyOwner: Bool = false) {
        let changed = (currentSection != section)
        currentSection = section
        updateSidebarSelection()
        rebuildSectionContent()
        if changed && notifyOwner {
            onSelectSection?(section)
        }
        if !isHidden {
            refreshLiveTargets()
        }
    }

    func reloadIfVisible() {
        guard !isHidden else { return }
        updateSidebarSelection()
        rebuildSectionContent()
        refreshLiveTargets()
    }

    func refreshLiveTargets() {
        refreshGeneration += 1
        let gen = refreshGeneration

        let status = currentRemoteStatus()
        var endpointsToQuery: [String] = []
        if status.isActive {
            endpointsToQuery.append("127.0.0.1:\(status.activePort)")
        }
        if BrowserSettings.shared.inspectDiscoverNetworkTargets {
            for target in BrowserSettings.shared.inspectNetworkTargets {
                let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !endpointsToQuery.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    endpointsToQuery.append(trimmed)
                }
            }
        }

        guard !endpointsToQuery.isEmpty else {
            localCDPTargets = []
            discoveredEndpoints = []
            isRefreshingNetwork = false
            rebuildSectionContent()
            return
        }

        isRefreshingNetwork = true
        let group = DispatchGroup()
        let lock = NSLock()
        var resultsByEndpoint: [String: InspectEndpointDiscoveryResult] = [:]

        for ep in endpointsToQuery {
            group.enter()
            Self.fetchEndpointDiscovery(endpoint: ep) { result in
                lock.lock()
                resultsByEndpoint[ep] = result
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.refreshGeneration == gen else { return }
            self.isRefreshingNetwork = false
            if status.isActive, let localRes = resultsByEndpoint["127.0.0.1:\(status.activePort)"] {
                self.localCDPTargets = localRes.targets
            } else {
                self.localCDPTargets = []
            }
            if BrowserSettings.shared.inspectDiscoverNetworkTargets {
                self.discoveredEndpoints = BrowserSettings.shared.inspectNetworkTargets.compactMap { ep in
                    let key = ep.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let direct = resultsByEndpoint[key] {
                        return direct
                    }
                    if status.isActive,
                       (key.lowercased() == "localhost:\(status.activePort)" || key == "127.0.0.1:\(status.activePort)"),
                       let local = resultsByEndpoint["127.0.0.1:\(status.activePort)"] {
                        return InspectEndpointDiscoveryResult(
                            endpoint: key,
                            browserName: local.browserName,
                            protocolVersion: local.protocolVersion,
                            browserWebSocketURL: local.browserWebSocketURL,
                            targets: local.targets,
                            isReachable: local.isReachable
                        )
                    }
                    return nil
                }
            } else {
                self.discoveredEndpoints = []
            }
            self.rebuildSectionContent()
        }
    }

    // MARK: - Layout Setup

    private func setupLayout() {
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.wantsLayer = true
        addSubview(sidebarContainer)

        sidebarTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebarTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        sidebarContainer.addSubview(sidebarTitleLabel)

        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 4
        sidebarContainer.addSubview(sidebarStack)

        for section in InspectPageSection.allCases {
            let btn = makeSidebarButton(for: section)
            sidebarButtons[section] = btn
            sidebarStack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }

        remoteStatusDot.translatesAutoresizingMaskIntoConstraints = false
        remoteStatusDot.wantsLayer = true
        remoteStatusDot.layer?.cornerRadius = 4
        if let remoteBtn = sidebarButtons[.remoteDebugging] {
            remoteBtn.addSubview(remoteStatusDot)
            NSLayoutConstraint.activate([
                remoteStatusDot.trailingAnchor.constraint(equalTo: remoteBtn.trailingAnchor, constant: -10),
                remoteStatusDot.centerYAnchor.constraint(equalTo: remoteBtn.centerYAnchor),
                remoteStatusDot.widthAnchor.constraint(equalToConstant: 8),
                remoteStatusDot.heightAnchor.constraint(equalToConstant: 8)
            ])
        }

        sidebarDivider.translatesAutoresizingMaskIntoConstraints = false
        sidebarDivider.boxType = .separator
        addSubview(sidebarDivider)

        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.drawsBackground = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.borderType = .noBorder
        addSubview(contentScrollView)

        contentDocView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.documentView = contentDocView

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentDocView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarContainer.widthAnchor.constraint(equalToConstant: 216),

            sidebarTitleLabel.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 20),
            sidebarTitleLabel.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 68),
            sidebarTitleLabel.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -16),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 12),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -12),
            sidebarStack.topAnchor.constraint(equalTo: sidebarTitleLabel.bottomAnchor, constant: 18),

            sidebarDivider.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarDivider.topAnchor.constraint(equalTo: topAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarDivider.widthAnchor.constraint(equalToConstant: 1),

            contentScrollView.leadingAnchor.constraint(equalTo: sidebarDivider.trailingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: topAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentDocView.leadingAnchor.constraint(equalTo: contentScrollView.contentView.leadingAnchor),
            contentDocView.trailingAnchor.constraint(equalTo: contentScrollView.contentView.trailingAnchor),
            contentDocView.topAnchor.constraint(equalTo: contentScrollView.contentView.topAnchor),
            contentDocView.widthAnchor.constraint(equalTo: contentScrollView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: contentDocView.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentDocView.trailingAnchor, constant: -32),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            contentStack.topAnchor.constraint(equalTo: contentDocView.topAnchor, constant: 68),
            contentStack.bottomAnchor.constraint(equalTo: contentDocView.bottomAnchor, constant: -40)
        ])

        // Stay below NSLayoutPriority.dragThatCannotResizeWindow (490) and .windowSizeStayPut (500):
        // above 500, combined with `contentStack.width <= 820`, this capped the entire browser window at 1101pt!
        let minWidth = contentStack.widthAnchor.constraint(equalTo: contentDocView.widthAnchor, constant: -64)
        minWidth.priority = .init(450)
        minWidth.isActive = true

        updateSidebarSelection()
    }

    private func makeSidebarButton(for section: InspectPageSection) -> NSButton {
        let btn = NSButton(title: section.sidebarTitle, target: self, action: #selector(sidebarButtonClicked(_:)))
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isBordered = false
        btn.alignment = .left
        btn.font = .systemFont(ofSize: 13, weight: .medium)
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 7
        btn.tag = InspectPageSection.allCases.firstIndex(of: section) ?? 0
        btn.heightAnchor.constraint(equalToConstant: 30).isActive = true
        btn.contentTintColor = .labelColor
        return btn
    }

    @objc private func sidebarButtonClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < InspectPageSection.allCases.count else { return }
        let section = InspectPageSection.allCases[idx]
        setSection(section, notifyOwner: true)
    }

    private func applyColors() {
        layer?.backgroundColor = effectiveTopColor.cgColor
        sidebarContainer.layer?.backgroundColor = sidebarBackgroundColor.cgColor
        updateSidebarSelection()
    }

    private func updateSidebarSelection() {
        let activeTint = NSColor.controlAccentColor
        let status = currentRemoteStatus()
        remoteStatusDot.layer?.backgroundColor = status.isActive
            ? NSColor.systemGreen.cgColor
            : NSColor.tertiaryLabelColor.withAlphaComponent(0.55).cgColor

        for (section, btn) in sidebarButtons {
            let selected = (section == currentSection)
            btn.layer?.backgroundColor = selected
                ? activeTint.withAlphaComponent(isDarkMode ? 0.24 : 0.14).cgColor
                : NSColor.clear.cgColor
            let titleColor: NSColor = selected ? activeTint : .labelColor
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = 10
            para.alignment = .left
            btn.attributedTitle = NSAttributedString(
                string: section.sidebarTitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
                    .foregroundColor: titleColor,
                    .paragraphStyle: para
                ]
            )
        }
    }

    private func currentRemoteStatus() -> InspectRemoteDebuggingStatus {
        remoteDebuggingStatusProvider?() ?? InspectRemoteDebuggingStatus(
            activePort: 0,
            isActive: false,
            webSocketURL: nil,
            activePortFilePath: nil
        )
    }

    // MARK: - Section Content Builders

    private func rebuildSectionContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        portTextField = nil
        newTargetTextField = nil

        switch currentSection {
        case .remoteDebugging:
            buildRemoteDebuggingSection()
        case .devices:
            buildDevicesSection()
        case .pages:
            buildPagesSection()
        case .extensions:
            buildExtensionsSection()
        case .serviceWorkers:
            buildWorkerTargetsSection(
                title: "Service workers",
                subtitle: "Active service worker targets exposed by Safarium's DevTools protocol.",
                targetTypes: ["service_worker"],
                extraActionTitle: nil,
                extraActionURL: nil
            )
        case .workers:
            buildWorkerTargetsSection(
                title: "Shared workers",
                subtitle: "Shared and dedicated worker targets running in this browser session.",
                targetTypes: ["shared_worker", "worker"],
                extraActionTitle: nil,
                extraActionURL: nil
            )
        case .other:
            buildWorkerTargetsSection(
                title: "Other",
                subtitle: "Additional inspectable targets (iframes, background targets, and auxiliary contexts).",
                targetTypes: ["iframe", "other", "browser"],
                extraActionTitle: nil,
                extraActionURL: nil
            )
        }
    }

    // MARK: - 1. Remote Debugging (`safarium://inspect/#remote-debugging`)

    private func buildRemoteDebuggingSection() {
        let settings = BrowserSettings.shared
        let status = currentRemoteStatus()
        let wantsEnabled = settings.remoteDebuggingEnabled
        let desiredPort = settings.remoteDebuggingPort
        let needsRelaunch = (wantsEnabled != status.isActive) || (wantsEnabled && status.activePort != desiredPort)

        addSectionHeader(
            title: "Remote debugging",
            subtitle: "Allow external developer tools (Chrome DevTools MCP, Playwright, Puppeteer, IDEs, or another browser) to inspect and control this Safarium instance over the Chrome DevTools Protocol (CDP).",
            showRefresh: true
        )

        // Control Card
        let controlCard = makeCardView()
        let controlStack = makeCardStack(in: controlCard)

        let checkbox = NSButton(
            checkboxWithTitle: "Allow remote debugging for this browser instance",
            target: self,
            action: #selector(remoteDebuggingCheckboxChanged(_:))
        )
        checkbox.state = wantsEnabled ? .on : .off
        checkbox.font = .systemFont(ofSize: 13.5, weight: .semibold)
        controlStack.addArrangedSubview(checkbox)

        let warningLabel = makeSecondaryLabel(
            "Only turn this on for development and only connect trusted local tools. Remote debugging exposes open tabs, cookies, storage, and page navigation on localhost."
        )
        controlStack.addArrangedSubview(warningLabel)

        // Port row
        let portRow = NSStackView()
        portRow.orientation = .horizontal
        portRow.alignment = .centerY
        portRow.spacing = 8

        let portLabel = NSTextField(labelWithString: "Localhost port:")
        portLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        portLabel.textColor = .secondaryLabelColor

        let prefixLabel = NSTextField(labelWithString: "127.0.0.1:")
        prefixLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        prefixLabel.textColor = .secondaryLabelColor

        let portField = NSTextField(string: "\(desiredPort)")
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        portField.delegate = self
        portField.widthAnchor.constraint(equalToConstant: 78).isActive = true
        self.portTextField = portField

        let applyPortBtn = NSButton(title: "Save Port", target: self, action: #selector(saveRemoteDebuggingPortClicked))
        applyPortBtn.bezelStyle = .rounded
        applyPortBtn.controlSize = .small

        portRow.addArrangedSubview(portLabel)
        portRow.addArrangedSubview(prefixLabel)
        portRow.addArrangedSubview(portField)
        portRow.addArrangedSubview(applyPortBtn)
        controlStack.addArrangedSubview(portRow)

        addCardToContent(controlCard)

        // Relaunch banner if needed
        if needsRelaunch {
            let banner = makeCardView(accentTint: NSColor.systemOrange)
            let bannerStack = makeCardStack(in: banner)

            let msg: String
            if wantsEnabled && !status.isActive {
                msg = "Relaunch Safarium to start the Chromium remote debugging server on 127.0.0.1:\(desiredPort)."
            } else if !wantsEnabled && status.isActive {
                msg = "Relaunch Safarium to stop the active remote debugging server on port \(status.activePort)."
            } else {
                msg = "Relaunch Safarium to move remote debugging from port \(status.activePort) to port \(desiredPort)."
            }
            let bannerText = NSTextField(wrappingLabelWithString: msg)
            bannerText.font = .systemFont(ofSize: 13, weight: .medium)
            bannerStack.addArrangedSubview(bannerText)

            let relaunchBtn = NSButton(title: "Relaunch Safarium Now", target: self, action: #selector(relaunchClicked))
            relaunchBtn.bezelStyle = .rounded
            relaunchBtn.keyEquivalent = ""
            bannerStack.addArrangedSubview(relaunchBtn)

            addCardToContent(banner)
        }

        // Live Server Status Card
        let statusCard = makeCardView(accentTint: status.isActive ? NSColor.systemGreen : nil)
        let statusStack = makeCardStack(in: statusCard)

        let badgeText = status.isActive
            ? "Server Status: Listening on 127.0.0.1:\(status.activePort)"
            : "Server Status: Off"
        let statusHeader = NSTextField(labelWithString: badgeText)
        statusHeader.font = .systemFont(ofSize: 14, weight: .semibold)
        statusHeader.textColor = status.isActive ? .systemGreen : .secondaryLabelColor
        statusStack.addArrangedSubview(statusHeader)

        if status.isActive {
            let httpBase = "http://127.0.0.1:\(status.activePort)"
            statusStack.addArrangedSubview(makeKeyValueCopyRow(label: "HTTP endpoint:", value: httpBase))

            if let ws = status.webSocketURL, !ws.isEmpty {
                statusStack.addArrangedSubview(makeKeyValueCopyRow(label: "Browser WebSocket:", value: ws))
            }
            if let portFile = status.activePortFilePath, !portFile.isEmpty {
                statusStack.addArrangedSubview(makeKeyValueCopyRow(label: "DevToolsActivePort:", value: portFile, revealInFinder: true))
            }

            let targetCountLabel = makeSecondaryLabel("Active CDP targets discovered on localhost:\(status.activePort): \(localCDPTargets.count)")
            statusStack.addArrangedSubview(targetCountLabel)

            let actionRow = NSStackView()
            actionRow.orientation = .horizontal
            actionRow.spacing = 8

            let listBtn = NSButton(title: "Open /json/list", target: self, action: #selector(openLocalJSONList))
            listBtn.bezelStyle = .rounded
            listBtn.controlSize = .small

            let versionBtn = NSButton(title: "Open /json/version", target: self, action: #selector(openLocalJSONVersion))
            versionBtn.bezelStyle = .rounded
            versionBtn.controlSize = .small

            actionRow.addArrangedSubview(listBtn)
            actionRow.addArrangedSubview(versionBtn)
            statusStack.addArrangedSubview(actionRow)
        } else {
            statusStack.addArrangedSubview(makeSecondaryLabel(
                "Remote debugging is currently off. Enable the option above (or launch with SAFARIUM_REMOTE_DEBUGGING_PORT=9222) to expose Chromium's CDP server and DevToolsActivePort."
            ))
        }

        addCardToContent(statusCard)
    }

    // MARK: - 2. Devices (`safarium://inspect` / `safarium://inspect/#devices`)

    private func buildDevicesSection() {
        addSectionHeader(
            title: "Devices",
            subtitle: "Discover and inspect remote Chromium, Node.js, Electron, or Safarium targets listening on local network ports.",
            showRefresh: true
        )

        let settings = BrowserSettings.shared
        let configCard = makeCardView()
        let configStack = makeCardStack(in: configCard)

        let discoverCheckbox = NSButton(
            checkboxWithTitle: "Discover network targets",
            target: self,
            action: #selector(discoverNetworkTargetsChanged(_:))
        )
        discoverCheckbox.state = settings.inspectDiscoverNetworkTargets ? .on : .off
        discoverCheckbox.font = .systemFont(ofSize: 13.5, weight: .semibold)
        configStack.addArrangedSubview(discoverCheckbox)

        // Configured endpoints list + add field
        let targetsLabel = makeSecondaryLabel("Configured target endpoints (host:port):")
        configStack.addArrangedSubview(targetsLabel)

        let chipsStack = NSStackView()
        chipsStack.orientation = .horizontal
        chipsStack.spacing = 8
        for (idx, ep) in settings.inspectNetworkTargets.enumerated() {
            let chip = NSButton(title: "\(ep)  ✕", target: self, action: #selector(removeNetworkTargetClicked(_:)))
            chip.bezelStyle = .rounded
            chip.controlSize = .small
            chip.tag = idx
            chip.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            chipsStack.addArrangedSubview(chip)
        }
        if !settings.inspectNetworkTargets.isEmpty {
            configStack.addArrangedSubview(chipsStack)
        }

        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.spacing = 8
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "localhost:9222"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        self.newTargetTextField = field

        let addBtn = NSButton(title: "Add Target", target: self, action: #selector(addNetworkTargetClicked))
        addBtn.bezelStyle = .rounded
        addBtn.controlSize = .small

        addRow.addArrangedSubview(field)
        addRow.addArrangedSubview(addBtn)
        configStack.addArrangedSubview(addRow)

        addCardToContent(configCard)

        // Remote Targets section
        let heading = NSTextField(labelWithString: "Remote Target")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        contentStack.addArrangedSubview(heading)

        if !settings.inspectDiscoverNetworkTargets {
            let offCard = makeCardView()
            let st = makeCardStack(in: offCard)
            st.addArrangedSubview(makeSecondaryLabel("Network target discovery is disabled. Enable \"Discover network targets\" above to scan configured localhost ports."))
            addCardToContent(offCard)
            return
        }

        let reachable = discoveredEndpoints.filter { $0.isReachable }
        if reachable.isEmpty {
            let emptyCard = makeCardView()
            let st = makeCardStack(in: emptyCard)
            let msg = isRefreshingNetwork
                ? "Scanning configured endpoints..."
                : "No remote targets detected on \(settings.inspectNetworkTargets.joined(separator: ", "))."
            st.addArrangedSubview(makeSecondaryLabel(msg))

            let goRemoteBtn = NSButton(title: "Configure Remote Debugging for This Browser →", target: self, action: #selector(jumpToRemoteDebugging))
            goRemoteBtn.bezelStyle = .rounded
            goRemoteBtn.controlSize = .small
            st.addArrangedSubview(goRemoteBtn)
            addCardToContent(emptyCard)
            return
        }

        for result in reachable {
            let card = makeCardView()
            let st = makeCardStack(in: card)

            let epTitle = NSTextField(labelWithString: "\(result.browserName ?? "Remote Target")  (\(result.endpoint))")
            epTitle.font = .systemFont(ofSize: 13.5, weight: .semibold)
            st.addArrangedSubview(epTitle)

            if result.targets.isEmpty {
                st.addArrangedSubview(makeSecondaryLabel("Connected, but no inspectable targets were reported."))
            } else {
                for target in result.targets {
                    st.addArrangedSubview(makeCDPTargetRow(target))
                }
            }
            addCardToContent(card)
        }
    }

    // MARK: - 3. Pages (`safarium://inspect/#pages`)

    private func buildPagesSection() {
        addSectionHeader(
            title: "Pages",
            subtitle: "Open tabs in Safarium and any additional page targets exposed via CDP.",
            showRefresh: true
        )

        let tabs = localTabsProvider?() ?? []
        if tabs.isEmpty {
            let card = makeCardView()
            let st = makeCardStack(in: card)
            st.addArrangedSubview(makeSecondaryLabel("No open pages."))
            addCardToContent(card)
            return
        }

        let card = makeCardView()
        let st = makeCardStack(in: card)

        for (index, tab) in tabs.enumerated() {
            if index > 0 {
                st.addArrangedSubview(makeThinSeparator())
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12

            let info = NSStackView()
            info.orientation = .vertical
            info.alignment = .leading
            info.spacing = 2

            var titleStr = tab.title.isEmpty ? tab.urlString : tab.title
            if tab.isPrivate { titleStr += "  [Private]" }
            if tab.isActive { titleStr += "  • Active" }

            let titleField = NSTextField(labelWithString: titleStr)
            titleField.font = .systemFont(ofSize: 13, weight: .semibold)
            titleField.lineBreakMode = .byTruncatingTail

            let urlField = NSTextField(labelWithString: tab.urlString)
            urlField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            urlField.textColor = .secondaryLabelColor
            urlField.lineBreakMode = .byTruncatingMiddle

            info.addArrangedSubview(titleField)
            info.addArrangedSubview(urlField)

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let actions = NSStackView()
            actions.orientation = .horizontal
            actions.spacing = 6

            let isInspectSelf = InspectPageURL.isInspectURL(URL(string: tab.urlString))
            if !isInspectSelf {
                let inspectBtn = makeActionButton(title: "inspect", identifier: tab.tabID, action: #selector(inspectLocalTabClicked(_:)))
                actions.addArrangedSubview(inspectBtn)
            }
            let focusBtn = makeActionButton(title: "focus", identifier: tab.tabID, action: #selector(focusLocalTabClicked(_:)))
            let reloadBtn = makeActionButton(title: "reload", identifier: tab.tabID, action: #selector(reloadLocalTabClicked(_:)))
            let closeBtn = makeActionButton(title: "close", identifier: tab.tabID, action: #selector(closeLocalTabClicked(_:)))

            actions.addArrangedSubview(focusBtn)
            actions.addArrangedSubview(reloadBtn)
            actions.addArrangedSubview(closeBtn)

            row.addArrangedSubview(info)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(actions)
            st.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true
        }

        addCardToContent(card)
    }

    // MARK: - 4. Extensions (`safarium://inspect/#extensions`)

    private func buildExtensionsSection() {
        addSectionHeader(
            title: "Extensions",
            subtitle: "Installed MV3 extensions and live extension background/service-worker targets.",
            showRefresh: true
        )

        let extensions = extensionsProvider?() ?? []
        let extTargets = localCDPTargets.filter { $0.url.hasPrefix("chrome-extension://") }

        if !extTargets.isEmpty {
            let liveCard = makeCardView()
            let st = makeCardStack(in: liveCard)
            let lbl = NSTextField(labelWithString: "Live Extension Targets (CDP)")
            lbl.font = .systemFont(ofSize: 13.5, weight: .semibold)
            st.addArrangedSubview(lbl)
            for t in extTargets {
                st.addArrangedSubview(makeCDPTargetRow(t))
            }
            addCardToContent(liveCard)
        }

        let card = makeCardView()
        let st = makeCardStack(in: card)

        if extensions.isEmpty {
            st.addArrangedSubview(makeSecondaryLabel("No MV3 extensions installed in this profile."))
        } else {
            for (idx, ext) in extensions.enumerated() {
                if idx > 0 { st.addArrangedSubview(makeThinSeparator()) }
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 12

                let info = NSStackView()
                info.orientation = .vertical
                info.alignment = .leading
                info.spacing = 2

                let titleField = NSTextField(labelWithString: "\(ext.name)  v\(ext.version)\(ext.enabled ? "" : " (Disabled)")")
                titleField.font = .systemFont(ofSize: 13, weight: .semibold)

                let idField = NSTextField(labelWithString: "chrome-extension://\(ext.id)/")
                idField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                idField.textColor = .secondaryLabelColor

                info.addArrangedSubview(titleField)
                info.addArrangedSubview(idField)

                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

                let manageBtn = makeActionButton(title: "Settings…", identifier: ext.id, action: #selector(openExtensionSettingsClicked(_:)))
                row.addArrangedSubview(info)
                row.addArrangedSubview(spacer)
                row.addArrangedSubview(manageBtn)
                st.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: st.widthAnchor).isActive = true
            }
        }
        addCardToContent(card)
    }

    // MARK: - 5. Workers / Other

    private func buildWorkerTargetsSection(
        title: String,
        subtitle: String,
        targetTypes: [String],
        extraActionTitle: String?,
        extraActionURL: URL?
    ) {
        addSectionHeader(title: title, subtitle: subtitle, showRefresh: true)

        let matching = localCDPTargets.filter { targetTypes.contains($0.type.lowercased()) }
        let card = makeCardView()
        let st = makeCardStack(in: card)

        if !matching.isEmpty {
            for (idx, target) in matching.enumerated() {
                if idx > 0 { st.addArrangedSubview(makeThinSeparator()) }
                st.addArrangedSubview(makeCDPTargetRow(target))
            }
        } else if !currentRemoteStatus().isActive {
            st.addArrangedSubview(makeSecondaryLabel(
                "Enable Remote Debugging to list and inspect live \(title.lowercased()) targets over CDP."
            ))
            let btnRow = NSStackView()
            btnRow.orientation = .horizontal
            btnRow.spacing = 8

            let goRemote = NSButton(title: "Open Remote Debugging", target: self, action: #selector(jumpToRemoteDebugging))
            goRemote.bezelStyle = .rounded
            goRemote.controlSize = .small
            btnRow.addArrangedSubview(goRemote)

            if let extraTitle = extraActionTitle, let extraURL = extraActionURL {
                let extraBtn = NSButton(title: extraTitle, target: self, action: #selector(openStoredURLClicked(_:)))
                extraBtn.bezelStyle = .rounded
                extraBtn.controlSize = .small
                extraBtn.identifier = NSUserInterfaceItemIdentifier(extraURL.absoluteString)
                btnRow.addArrangedSubview(extraBtn)
            }
            st.addArrangedSubview(btnRow)
        } else {
            st.addArrangedSubview(makeSecondaryLabel("No active \(title.lowercased()) targets found."))
        }

        addCardToContent(card)
    }

    // MARK: - Reusable UI Helpers

    private func addSectionHeader(title: String, subtitle: String, showRefresh: Bool) {
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 22, weight: .bold)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerRow.addArrangedSubview(titleField)
        headerRow.addArrangedSubview(spacer)

        if showRefresh {
            let refreshBtn = NSButton(title: isRefreshingNetwork ? "Refreshing…" : "Refresh", target: self, action: #selector(refreshClicked))
            refreshBtn.bezelStyle = .rounded
            refreshBtn.controlSize = .small
            refreshBtn.isEnabled = !isRefreshingNetwork
            headerRow.addArrangedSubview(refreshBtn)
        }

        contentStack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let subField = makeSecondaryLabel(subtitle)
        contentStack.addArrangedSubview(subField)
        subField.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func makeCardView(accentTint: NSColor? = nil) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        if let tint = accentTint {
            card.layer?.backgroundColor = tint.withAlphaComponent(isDarkMode ? 0.14 : 0.08).cgColor
            card.layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
        } else {
            card.layer?.backgroundColor = cardBackgroundColor.cgColor
            card.layer?.borderColor = cardBorderColor.cgColor
        }
        return card
    }

    private func makeCardStack(in card: NSView) -> NSStackView {
        let st = NSStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.orientation = .vertical
        st.alignment = .leading
        st.spacing = 10
        card.addSubview(st)
        NSLayoutConstraint.activate([
            st.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            st.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            st.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            st.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return st
    }

    private func addCardToContent(_ card: NSView) {
        contentStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func makeSecondaryLabel(_ text: String) -> NSTextField {
        let lbl = NSTextField(wrappingLabelWithString: text)
        lbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        lbl.textColor = .secondaryLabelColor
        return lbl
    }

    private func makeThinSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        return sep
    }

    private func makeActionButton(title: String, identifier: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.identifier = NSUserInterfaceItemIdentifier(identifier)
        return btn
    }

    private func makeKeyValueCopyRow(label: String, value: String, revealInFinder: Bool = false) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let keyField = NSTextField(labelWithString: label)
        keyField.font = .systemFont(ofSize: 12, weight: .medium)
        keyField.textColor = .secondaryLabelColor

        let valField = NSTextField(labelWithString: value)
        valField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valField.isSelectable = true
        valField.lineBreakMode = .byTruncatingMiddle

        let copyBtn = makeActionButton(title: "Copy", identifier: value, action: #selector(copyValueClicked(_:)))

        row.addArrangedSubview(keyField)
        row.addArrangedSubview(valField)
        row.addArrangedSubview(copyBtn)

        if revealInFinder {
            let revealBtn = makeActionButton(title: "Reveal", identifier: value, action: #selector(revealPathClicked(_:)))
            row.addArrangedSubview(revealBtn)
        }
        return row
    }

    private func makeCDPTargetRow(_ target: InspectCDPTarget) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let info = NSStackView()
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2

        let titleText = target.title.isEmpty ? target.url : target.title
        let titleField = NSTextField(labelWithString: "\(titleText)  [\(target.type)]")
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail

        let urlField = NSTextField(labelWithString: target.url)
        urlField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        urlField.textColor = .secondaryLabelColor
        urlField.lineBreakMode = .byTruncatingMiddle

        info.addArrangedSubview(titleField)
        info.addArrangedSubview(urlField)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(info)
        row.addArrangedSubview(spacer)

        if let ws = target.webSocketDebuggerUrl, !ws.isEmpty {
            let inspectBtn = makeActionButton(title: "inspect", identifier: ws, action: #selector(inspectRemoteTargetClicked(_:)))
            row.addArrangedSubview(inspectBtn)
        }
        return row
    }

    // MARK: - Actions

    @objc private func remoteDebuggingCheckboxChanged(_ sender: NSButton) {
        BrowserSettings.shared.remoteDebuggingEnabled = (sender.state == .on)
        updateSidebarSelection()
        rebuildSectionContent()
    }

    @objc private func saveRemoteDebuggingPortClicked() {
        guard let raw = portTextField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let port = Int(raw), (1024...65535).contains(port) else {
            NSSound.beep()
            portTextField?.stringValue = "\(BrowserSettings.shared.remoteDebuggingPort)"
            return
        }
        BrowserSettings.shared.remoteDebuggingPort = port
        rebuildSectionContent()
    }

    @objc private func relaunchClicked() {
        onRelaunchApp?()
    }

    @objc private func openLocalJSONList() {
        let port = currentRemoteStatus().activePort
        if port >= 1024, let u = URL(string: "http://127.0.0.1:\(port)/json/list") {
            onOpenURL?(u, true)
        }
    }

    @objc private func openLocalJSONVersion() {
        let port = currentRemoteStatus().activePort
        if port >= 1024, let u = URL(string: "http://127.0.0.1:\(port)/json/version") {
            onOpenURL?(u, true)
        }
    }

    @objc private func discoverNetworkTargetsChanged(_ sender: NSButton) {
        BrowserSettings.shared.inspectDiscoverNetworkTargets = (sender.state == .on)
        refreshLiveTargets()
    }

    @objc private func addNetworkTargetClicked() {
        guard let raw = newTargetTextField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        var list = BrowserSettings.shared.inspectNetworkTargets
        list.append(raw)
        BrowserSettings.shared.inspectNetworkTargets = list
        refreshLiveTargets()
    }

    @objc private func removeNetworkTargetClicked(_ sender: NSButton) {
        var list = BrowserSettings.shared.inspectNetworkTargets
        guard sender.tag >= 0 && sender.tag < list.count else { return }
        list.remove(at: sender.tag)
        BrowserSettings.shared.inspectNetworkTargets = list
        refreshLiveTargets()
    }

    @objc private func refreshClicked() {
        refreshLiveTargets()
    }

    @objc private func jumpToRemoteDebugging() {
        setSection(.remoteDebugging, notifyOwner: true)
    }

    @objc private func inspectLocalTabClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onInspectLocalTab?(id) }
    }

    @objc private func focusLocalTabClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onFocusLocalTab?(id) }
    }

    @objc private func reloadLocalTabClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onReloadLocalTab?(id) }
    }

    @objc private func closeLocalTabClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue {
            onCloseLocalTab?(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.rebuildSectionContent()
            }
        }
    }

    @objc private func inspectRemoteTargetClicked(_ sender: NSButton) {
        if let ws = sender.identifier?.rawValue { onInspectRemoteTarget?(ws) }
    }

    @objc private func openExtensionSettingsClicked(_ sender: NSButton) {
        onOpenExtensionsSettings?(sender.identifier?.rawValue)
    }

    @objc private func openStoredURLClicked(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let u = URL(string: raw) {
            onOpenURL?(u, true)
        }
    }

    @objc private func copyValueClicked(_ sender: NSButton) {
        guard let val = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(val, forType: .string)
    }

    @objc private func revealPathClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - CDP Network Target Discovery

    static func fetchEndpointDiscovery(
        endpoint: String,
        completion: @escaping (InspectEndpointDiscoveryResult) -> Void
    ) {
        let base = endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://")
            ? endpoint
            : "http://\(endpoint)"
        guard let listURL = URL(string: "\(base)/json/list"),
              let versionURL = URL(string: "\(base)/json/version") else {
            completion(InspectEndpointDiscoveryResult(
                endpoint: endpoint,
                browserName: nil,
                protocolVersion: nil,
                browserWebSocketURL: nil,
                targets: [],
                isReachable: false
            ))
            return
        }

        let group = DispatchGroup()
        var versionInfo: InspectCDPVersionInfo?
        var targets: [InspectCDPTarget] = []
        var reachable = false
        let lock = NSLock()

        group.enter()
        cdpSession.dataTask(with: versionURL) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data {
                let decoded = try? JSONDecoder().decode(InspectCDPVersionInfo.self, from: data)
                lock.lock()
                versionInfo = decoded
                reachable = true
                lock.unlock()
            }
            group.leave()
        }.resume()

        group.enter()
        cdpSession.dataTask(with: listURL) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data {
                let decoded = (try? JSONDecoder().decode([InspectCDPTarget].self, from: data)) ?? []
                lock.lock()
                targets = decoded
                reachable = true
                lock.unlock()
            }
            group.leave()
        }.resume()

        group.notify(queue: .global(qos: .userInitiated)) {
            completion(InspectEndpointDiscoveryResult(
                endpoint: endpoint,
                browserName: versionInfo?.browser,
                protocolVersion: versionInfo?.protocolVersion,
                browserWebSocketURL: versionInfo?.webSocketDebuggerUrl,
                targets: targets,
                isReachable: reachable
            ))
        }
    }
}

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}
