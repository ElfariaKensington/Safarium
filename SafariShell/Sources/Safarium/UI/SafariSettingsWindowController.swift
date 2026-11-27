import AppKit
import QuartzCore

/// Native macOS 27 Tahoe Safari Settings window (`⌘,` and `Manage Extensions…`).
/// Preserves Safari's exact horizontal `.preference` toolbar, smooth per-pane window resizing,
/// two-column right-aligned form geometry, and master-detail split panes for Websites & Extensions,
/// modernized with native macOS 27 Liquid Glass AppKit controls (`bezelStyle = .glass`,
/// `NSGlassEffectView`, capsule popups, continuous-corner cards, and rounded selection highlights).
final class SafariSettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    enum Pane: String, CaseIterable {
        case general = "General"
        case tabs = "Tabs"
        case autoFill = "AutoFill"
        case search = "Search"
        case security = "Security"
        case privacy = "Privacy"
        case websites = "Websites"
        case profiles = "Profiles"
        case extensions = "Extensions"
        case advanced = "Advanced"
        case developer = "Developer"

        var toolbarID: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("com.safarium.settings.\(rawValue)")
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .tabs: return "square.on.square"
            case .autoFill: return "rectangle.and.pencil.and.ellipsis"
            case .search: return "magnifyingglass"
            case .security: return "lock"
            case .privacy: return "hand.raised"
            case .websites: return "globe"
            case .profiles: return "person"
            case .extensions: return "puzzlepiece.extension"
            case .advanced: return "gearshape.2"
            case .developer: return "wrench.and.screwdriver"
            }
        }

        var preferredContentHeight: CGFloat {
            switch self {
            case .general: return 468
            case .tabs: return 444
            case .autoFill: return 206
            case .search: return 318
            case .security: return 256
            case .privacy: return 384
            case .websites: return 456
            case .profiles: return 296
            case .extensions: return 468
            case .advanced: return 436
            case .developer: return 238
            }
        }
    }

    enum WebsiteCategory: String, CaseIterable {
        case contentBlockers = "Content Blockers"
        case autoPlay = "Auto-Play"
        case pageZoom = "Page Zoom"
        case camera = "Camera"
        case microphone = "Microphone"
        case screenSharing = "Screen Sharing"
        case location = "Location"
        case downloads = "Downloads"
        case popups = "Pop-up Windows"
        case notifications = "Notifications"
        case extensionAccess = "Extension Access"

        var symbolName: String {
            switch self {
            case .contentBlockers: return "checkmark.shield.fill"
            case .autoPlay: return "play.fill"
            case .pageZoom: return "plus.magnifyingglass"
            case .camera: return "video.fill"
            case .microphone: return "mic.fill"
            case .screenSharing: return "rectangle.on.rectangle"
            case .location: return "location.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .popups: return "macwindow.on.rectangle"
            case .notifications: return "bell.badge.fill"
            case .extensionAccess: return "puzzlepiece.extension.fill"
            }
        }

        var badgeColor: NSColor {
            switch self {
            case .contentBlockers: return NSColor(srgbRed: 0.22, green: 0.78, blue: 0.36, alpha: 1.0)
            case .autoPlay: return NSColor(srgbRed: 0.98, green: 0.62, blue: 0.12, alpha: 1.0)
            case .pageZoom: return NSColor(srgbRed: 0.95, green: 0.66, blue: 0.14, alpha: 1.0)
            case .camera: return NSColor(srgbRed: 0.44, green: 0.46, blue: 0.50, alpha: 1.0)
            case .microphone: return NSColor(srgbRed: 0.52, green: 0.54, blue: 0.58, alpha: 1.0)
            case .screenSharing: return NSColor(srgbRed: 0.20, green: 0.69, blue: 0.95, alpha: 1.0)
            case .location: return NSColor(srgbRed: 0.10, green: 0.50, blue: 0.98, alpha: 1.0)
            case .downloads: return NSColor(srgbRed: 0.52, green: 0.42, blue: 0.96, alpha: 1.0)
            case .popups: return NSColor(srgbRed: 0.92, green: 0.34, blue: 0.38, alpha: 1.0)
            case .notifications: return NSColor(srgbRed: 0.94, green: 0.32, blue: 0.28, alpha: 1.0)
            case .extensionAccess: return NSColor(srgbRed: 0.25, green: 0.45, blue: 0.96, alpha: 1.0)
            }
        }

        var policyPrompt: String {
            switch self {
            case .contentBlockers: return "Enable content blockers on the websites below:"
            case .autoPlay: return "Allow websites below to automatically play media:"
            case .pageZoom: return "Set page zoom for the websites below:"
            case .camera: return "Allow websites below to use your camera:"
            case .microphone: return "Allow websites below to use your microphone:"
            case .screenSharing: return "Allow websites below to share your screen:"
            case .location: return "Allow websites below to request your location:"
            case .downloads: return "Allow websites below to download files:"
            case .popups: return "Configure pop-up windows for the websites below:"
            case .notifications: return "Allow websites below to send notifications:"
            case .extensionAccess: return "Website access granted to installed extensions:"
            }
        }

        var options: [String] {
            switch self {
            case .contentBlockers: return ["On", "Off"]
            case .autoPlay: return ["Allow All Auto-Play", "Stop Media with Sound", "Never Auto-Play"]
            case .pageZoom: return ["50%", "75%", "85%", "100%", "115%", "125%", "150%", "175%", "200%", "250%", "300%"]
            case .camera, .microphone, .screenSharing, .location, .downloads, .notifications:
                return ["Ask", "Deny", "Allow"]
            case .popups: return ["Block and Notify", "Block", "Allow"]
            case .extensionAccess: return ["Allow", "Ask", "Deny"]
            }
        }

        var defaultOptionIndex: Int {
            switch self {
            case .contentBlockers: return 0
            case .autoPlay: return 1
            case .pageZoom: return 3
            case .camera, .microphone, .screenSharing, .location, .downloads, .notifications: return 0
            case .popups: return 0
            case .extensionAccess: return 0
            }
        }
    }

    // MARK: - Callbacks

    var onOpenChromeWebStore: (() -> Void)?
    var onLoadUnpackedExtension: (() -> Void)?
    var onInstallCRXExtension: (() -> Void)?
    var onExtensionsChanged: (() -> Void)?
    var activePageURLProvider: (() -> String?)?
    var openWebsitesProvider: (() -> [(host: String, favicon: NSImage?)])?
    var onOpenURL: ((URL) -> Void)?
    var onOpenPrivacyReport: (() -> Void)?

    // MARK: - Constants & State

    private static let windowWidth: CGFloat = 820
    /// Classic Safari two-column spine (right-aligned label ends here; controls start +12pt to the right).
    private static let labelSpineX: CGFloat = 336

    private let engine: BrowserEngine
    private var selectedPane: Pane = .general
    private var extensions: [BrowserExtensionItem] = []
    private var selectedExtensionID: String?
    var selectedWebsiteCategory: WebsiteCategory = .autoPlay
    var selectedWebsiteHost: String?
    private var extensionsObserver: NSObjectProtocol?
    private var keyDownMonitor: Any?
    private var websiteDataSheetController: WebsiteDataSheetController?
    private var websiteDataSheetEndObserver: NSObjectProtocol?

    private let rootContainer = NSView()
    private var activePaneView: NSView?

    // Extensions pane subviews
    private var extensionsListStack: NSStackView?
    private var extensionDetailContainer: NSView?

    // Dynamic control references
    private weak var homepageField: NSTextField?
    private weak var privateSearchPopup: NSPopUpButton?
    private weak var minFontSizePopup: NSPopUpButton?
    private weak var trackingScopePopup: NSPopUpButton?
    private var tabLayoutCards: [String: TabLayoutPreviewCard] = [:]

    private enum PrefKey {
        static let opensWith = "Safarium.Pref.OpensWith"
        static let newWindowOpensWith = "Safarium.Pref.NewWindowOpensWith"
        static let newTabOpensWith = "Safarium.Pref.NewTabOpensWith"
        static let homepage = "Safarium.Pref.Homepage"
        static let removeHistory = "Safarium.Pref.RemoveHistory"
        static let startPageFavorites = "Safarium.Pref.StartPageFavorites"
        static let downloadLocation = "Safarium.Pref.DownloadLocation"
        static let removeDownloads = "Safarium.Pref.RemoveDownloads"
        static let openSafeFiles = "Safarium.Pref.OpenSafeFiles"

        static let openPagesInTabs = "Safarium.Pref.OpenPagesInTabs"
        static let autoCloseTabs = "Safarium.Pref.AutoCloseTabs"
        static let tabLayout = "Safarium.Pref.TabLayout"
        static let showWebsiteColor = "Safarium.Pref.ShowWebsiteColorInToolbar"
        static let refractiveGlassToolbar = "Safarium.Pref.RefractiveGlassToolbar"
        static let refractiveGlassFrost = "Safarium.Pref.RefractiveGlassFrost"
        static let alwaysShowTabTitles = "Safarium.Pref.AlwaysShowTabTitles"
        static let cmdClickNewTab = "Safarium.Pref.CmdClickNewTab"
        static let activateNewTabs = "Safarium.Pref.ActivateNewTabs"
        static let cmdNumberSwitch = "Safarium.Pref.CmdNumberSwitch"

        static let searchEngine = "Safarium.Pref.SearchEngine"
        static let samePrivateSearch = "Safarium.Pref.SamePrivateSearch"
        static let privateSearchEngine = "Safarium.Pref.PrivateSearchEngine"
        static let searchSuggestions = "Safarium.Pref.SearchSuggestions"
        static let quickWebsiteSearch = "Safarium.Pref.QuickWebsiteSearch"
        static let preloadTopHit = "Safarium.Pref.PreloadTopHit"
        static let showFavoritesInSearch = "Safarium.Pref.ShowFavoritesInSearch"

        static let autofillPasswords = "Safarium.Pref.AutoFillPasswords"
        static let autofillAddresses = "Safarium.Pref.AutoFillAddresses"
        static let autofillCards = "Safarium.Pref.AutoFillCards"
        static let autofillOther = "Safarium.Pref.AutoFillOther"

        static let warnFraudulent = "Safarium.Pref.WarnFraudulent"
        static let enableJavaScript = "Safarium.Pref.EnableJavaScript"
        static let warnHTTP = "Safarium.Pref.WarnHTTP"

        static let preventTracking = "Safarium.Pref.PreventCrossSiteTracking"
        static let touchIDLockedPrivate = "Safarium.Pref.TouchIDLockedPrivate"

        static let showFullAddress = "Safarium.Pref.ShowFullAddress"
        static let minFontEnabled = "Safarium.Pref.MinFontEnabled"
        static let minFontSize = "Safarium.Pref.MinFontSize"
        static let tabHighlightsAll = "Safarium.Pref.TabHighlightsAll"
        static let advancedFingerprint = "Safarium.Pref.AdvancedFingerprint"
        static let advancedFingerprintScope = "Safarium.Pref.AdvancedFingerprintScope"
        static let globalPrivacyControl = "Safarium.Pref.GlobalPrivacyControl"
        static let blockAllCookies = "Safarium.Pref.BlockAllCookies"
        static let customStyleSheet = "Safarium.Pref.CustomStyleSheet"
        static let defaultEncoding = "Safarium.Pref.DefaultEncoding"
        static let showDeveloperFeatures = "Safarium.Pref.ShowDeveloperFeatures"

        static let devAllowUnsigned = "Safarium.Pref.DevAllowUnsigned"
        static let devSeparateDevTools = "Safarium.Pref.DevSeparateDevTools"
        static let devDisableCache = "Safarium.Pref.DevDisableCache"

        static let profilesEnabled = "Safarium.Pref.ProfilesEnabled"
        static let profileNames = "Safarium.Pref.ProfileNames"
        static let clearedShortcuts = "Safarium.Extensions.ClearedShortcuts"
    }

    // MARK: - Init

    init(engine: BrowserEngine, initialPane: Pane = .general) {
        self.engine = engine
        self.selectedPane = initialPane

        let rect = NSRect(x: 0, y: 0, width: Self.windowWidth, height: initialPane.preferredContentHeight)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let win = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        win.title = initialPane.rawValue
        win.toolbarStyle = .preference
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)
        win.delegate = self

        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("com.safarium.settings.preference.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = initialPane.toolbarID
        win.toolbar = toolbar

        // Subtle modern window-surface material behind glass controls
        let surface = NSVisualEffectView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.material = .windowBackground
        surface.blendingMode = .behindWindow
        surface.state = .followsWindowActiveState

        rootContainer.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.wantsLayer = true
        surface.addSubview(rootContainer)
        NSLayoutConstraint.activate([
            rootContainer.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            rootContainer.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            rootContainer.topAnchor.constraint(equalTo: surface.topAnchor),
            rootContainer.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        win.contentView = surface

        extensionsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("SXEngineRuntimeDidUpdateExtensionsNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadExtensions()
        }

        // Keyboard navigation inside Settings window: Esc/⌘W closes, ⌃Tab / ⌃⇧Tab cycles panes, ⌘1..⌘9 jumps to pane.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let win = self.window, event.window === win, win.isVisible else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isEditingText = (win.firstResponder is NSTextView)

            if event.keyCode == 53 && !isEditingText { // Escape
                win.performClose(nil)
                return nil
            }
            if event.keyCode == 48 && mods.contains(.control) && !mods.contains(.command) { // Ctrl+Tab / Ctrl+Shift+Tab
                let panes = self.toolbarPanes
                if let idx = panes.firstIndex(of: self.selectedPane), !panes.isEmpty {
                    let step = mods.contains(.shift) ? -1 : 1
                    let next = panes[(idx + step + panes.count) % panes.count]
                    self.selectPane(next, animated: true)
                    return nil
                }
            }
            if mods == [.command], let chars = event.charactersIgnoringModifiers, let digit = Int(chars), digit >= 1 && digit <= 9 {
                let panes = self.toolbarPanes
                if digit - 1 < panes.count {
                    self.selectPane(panes[digit - 1], animated: true)
                    return nil
                }
            }
            return event
        }

        reloadExtensions(selectID: nil)
        selectPane(initialPane, animated: false)
    }

    deinit {
        if let extensionsObserver {
            NotificationCenter.default.removeObserver(extensionsObserver)
        }
        if let websiteDataSheetEndObserver {
            NotificationCenter.default.removeObserver(websiteDataSheetEndObserver)
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Public Presentation

    func show(pane: Pane, selectingExtensionID extID: String? = nil) {
        if let extID {
            selectedExtensionID = extID
        }
        reloadExtensions(selectID: extID ?? selectedExtensionID)
        selectPane(pane, animated: window?.isVisible == true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reloadExtensions(selectID: String? = nil) {
        let fetched = engine.installedExtensions()
        self.extensions = fetched
        if let explicit = selectID, fetched.contains(where: { $0.id == explicit }) {
            selectedExtensionID = explicit
        } else if let current = selectedExtensionID, fetched.contains(where: { $0.id == current }) {
            // keep current selection
        } else {
            selectedExtensionID = fetched.first?.id
        }

        if selectedPane == .extensions {
            rebuildExtensionsList()
            rebuildExtensionDetail()
        } else if selectedPane == .websites && selectedWebsiteCategory == .extensionAccess {
            selectPane(.websites, animated: false)
        }
    }

    // MARK: - NSToolbarDelegate

    private var toolbarPanes: [Pane] {
        let showDev = prefBool(PrefKey.showDeveloperFeatures, default: true)
        return Pane.allCases.filter { $0 != .developer || showDev }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarID)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarPanes.map(\.toolbarID)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarID)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: { $0.toolbarID == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.rawValue
        item.paletteLabel = pane.rawValue
        item.toolTip = pane.rawValue
        let cfg = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.rawValue)?
            .withSymbolConfiguration(cfg)
        item.target = self
        item.action = #selector(toolbarPaneClicked(_:))
        return item
    }

    @objc private func toolbarPaneClicked(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: { $0.toolbarID == sender.itemIdentifier }) else { return }
        selectPane(pane, animated: true)
    }

    private func syncDeveloperToolbarItemVisibility() {
        guard let toolbar = window?.toolbar else { return }
        let showDev = prefBool(PrefKey.showDeveloperFeatures, default: true)
        let devID = Pane.developer.toolbarID
        let existingIdx = toolbar.items.firstIndex(where: { $0.itemIdentifier == devID })
        if showDev && existingIdx == nil {
            toolbar.insertItem(withItemIdentifier: devID, at: toolbar.items.count)
        } else if !showDev, let idx = existingIdx {
            toolbar.removeItem(at: idx)
            if selectedPane == .developer {
                selectPane(.advanced, animated: true)
            }
        }
    }

    // MARK: - Pane Switching & Smooth Top-Anchored Window Resize

    func selectPane(_ pane: Pane, animated: Bool = true) {
        selectedPane = pane
        window?.title = pane.rawValue
        window?.toolbar?.selectedItemIdentifier = pane.toolbarID

        activePaneView?.removeFromSuperview()
        activePaneView = nil

        let view: NSView
        switch pane {
        case .general: view = buildGeneralPane()
        case .tabs: view = buildTabsPane()
        case .autoFill: view = buildAutoFillPane()
        case .search: view = buildSearchPane()
        case .security: view = buildSecurityPane()
        case .privacy: view = buildPrivacyPane()
        case .websites: view = buildWebsitesPane()
        case .profiles: view = buildProfilesPane()
        case .extensions:
            view = buildExtensionsPane()
            rebuildExtensionsList()
            rebuildExtensionDetail()
        case .advanced: view = buildAdvancedPane()
        case .developer: view = buildDeveloperPane()
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor)
        ])
        activePaneView = view

        // Auto-measure form stack height so controls & captions NEVER clip at the bottom edge.
        var targetHeight = pane.preferredContentHeight
        if pane != .websites && pane != .extensions && pane != .profiles {
            view.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: max(targetHeight, 600))
            view.layoutSubtreeIfNeeded()
            if let stack = view.subviews.first(where: { $0 is NSStackView }) {
                let topInset = max(16, view.bounds.maxY - stack.frame.maxY)
                let needed = ceil(topInset + stack.fittingSize.height + 34)
                targetHeight = max(targetHeight, needed)
            }
        }
        resizeWindowContent(height: targetHeight, animated: animated)

        if animated {
            view.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1.0
            }
        }
    }

    private func resizeWindowContent(height targetContentHeight: CGFloat, animated: Bool) {
        guard let win = window else { return }
        let targetContentRect = NSRect(x: 0, y: 0, width: Self.windowWidth, height: targetContentHeight)
        let newFrameSize = win.frameRect(forContentRect: targetContentRect).size
        let currentFrame = win.frame
        let newOriginY = currentFrame.maxY - newFrameSize.height
        let newFrame = NSRect(x: currentFrame.origin.x, y: newOriginY, width: newFrameSize.width, height: newFrameSize.height)
        if abs(currentFrame.height - newFrame.height) < 0.5 && abs(currentFrame.width - newFrame.width) < 0.5 {
            return
        }
        win.setFrame(newFrame, display: true, animate: animated)
    }

    // MARK: - 1. General Pane (Exact Safari Two-Column Layout + Tahoe Glass Controls)

    private func buildGeneralPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "General Settings")
        let stack = makeFormStack(in: pane, topInset: 18)

        // Centered default-browser banner row
        let defaultRow = NSView()
        defaultRow.translatesAutoresizingMaskIntoConstraints = false
        let isDefault = BrowserSettings.shared.isDefaultBrowser()
        let defLabel = NSTextField(labelWithString: isDefault ? "Safarium is your default web browser." : "Safarium is not your default web browser.")
        defLabel.translatesAutoresizingMaskIntoConstraints = false
        defLabel.font = NSFont.systemFont(ofSize: 13.0)
        defLabel.textColor = .labelColor
        let defBtn = makeGlassButton(title: "Set Default…", target: self, action: #selector(setDefaultBrowserClicked))
        defBtn.isHidden = isDefault

        let defGroup = NSStackView(views: [defLabel, defBtn])
        defGroup.orientation = .horizontal
        defGroup.alignment = .centerY
        defGroup.spacing = 12
        defGroup.translatesAutoresizingMaskIntoConstraints = false
        defaultRow.addSubview(defGroup)
        NSLayoutConstraint.activate([
            defaultRow.heightAnchor.constraint(equalToConstant: 32),
            defGroup.centerXAnchor.constraint(equalTo: defaultRow.centerXAnchor),
            defGroup.centerYAnchor.constraint(equalTo: defaultRow.centerYAnchor)
        ])
        addFormRow(defaultRow, to: stack, spacingAfter: 16)

        // Startup & Homepage
        addFormRow(makeFormPopupRow(
            label: "Safarium opens with:",
            options: [
                "All windows from last session",
                "All non-private windows from last session",
                "A new window",
                "A new private window"
            ],
            key: PrefKey.opensWith,
            defaultIndex: 0
        ), to: stack, spacingAfter: 10)

        addFormRow(makeFormPopupRow(
            label: "New windows open with:",
            options: ["Start Page", "Homepage", "Empty Page", "Same Page"],
            key: PrefKey.newWindowOpensWith,
            defaultIndex: 0
        ), to: stack, spacingAfter: 10)

        addFormRow(makeFormPopupRow(
            label: "New tabs open with:",
            options: ["Start Page", "Homepage", "Empty Page", "Same Page"],
            key: PrefKey.newTabOpensWith,
            defaultIndex: 0
        ), to: stack, spacingAfter: 10)

        // Homepage text field
        let hpField = NSTextField()
        hpField.translatesAutoresizingMaskIntoConstraints = false
        hpField.placeholderString = "https://example.com"
        hpField.stringValue = UserDefaults.standard.string(forKey: PrefKey.homepage) ?? ""
        hpField.font = NSFont.systemFont(ofSize: 13.0)
        hpField.target = self
        hpField.action = #selector(homepageFieldCommitted(_:))
        if #available(macOS 26.0, *) {
            hpField.borderShape = .roundedRectangle
        }
        hpField.widthAnchor.constraint(equalToConstant: 296).isActive = true
        self.homepageField = hpField
        addFormRow(makeTwoColumnRow(label: "Homepage:", control: hpField), to: stack, spacingAfter: 8)

        let setCurBtn = makeGlassButton(title: "Set to Current Page", target: self, action: #selector(setHomepageToCurrentPage))
        addFormRow(makeTwoColumnRow(label: nil, control: setCurBtn), to: stack, spacingAfter: 20)

        // History
        addFormRow(makeFormPopupRow(
            label: "Remove history items:",
            options: ["After one day", "After one week", "After two weeks", "After one month", "After one year", "Manually"],
            key: PrefKey.removeHistory,
            defaultIndex: 4
        ), to: stack, spacingAfter: 20)

        // Downloads
        let customDir = BrowserSettings.shared.string(BrowserSettings.Key.customDownloadDir)
        let customLabel = customDir.isEmpty ? "Other…" : URL(fileURLWithPath: customDir).lastPathComponent
        let (dlRow, dlPop) = makeFormPopupRowWithControl(
            label: "File download location:",
            options: ["Downloads", "Desktop", "Ask for each download", customLabel],
            key: PrefKey.downloadLocation,
            defaultIndex: 0
        ) { [weak self] idx in
            guard let self else { return }
            if idx == 3 {
                self.promptCustomDownloadDirectory()
            }
        }
        let dlDirPath = BrowserSettings.shared.resolvedDownloadDirectoryPath
        let folderIcon = NSWorkspace.shared.icon(forFile: dlDirPath)
        folderIcon.size = NSSize(width: 16, height: 16)
        dlPop.item(at: 0)?.image = folderIcon
        dlPop.item(at: 1)?.image = folderIcon
        addFormRow(dlRow, to: stack, spacingAfter: 10)

        addFormRow(makeFormPopupRow(
            label: "Remove download list items:",
            options: ["After one day", "When Safarium quits", "Upon successful download", "Manually"],
            key: PrefKey.removeDownloads,
            defaultIndex: 0
        ), to: stack, spacingAfter: 10)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Open “safe” files after downloading",
            caption: "“Safe” files include movies, pictures, sounds, text documents, and archives.",
            key: PrefKey.openSafeFiles,
            defaultValue: false
        ), to: stack, spacingAfter: 0)

        return pane
    }

    @objc private func setDefaultBrowserClicked() {
        BrowserSettings.shared.setAsDefaultBrowser { [weak self] ok, err in
            guard let self else { return }
            if ok {
                self.selectPane(.general, animated: false)
            } else {
                let msg = err?.localizedDescription ?? "Choose Safarium under System Settings → Desktop & Dock → Default web browser."
                self.presentInfoSheet(title: "Set Safarium as Default Browser", message: msg)
            }
        }
    }

    private func promptCustomDownloadDirectory() {
        guard let win = window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard let self else { return }
            if resp == .OK, let url = panel.url {
                BrowserSettings.shared.set(url.path, forKey: BrowserSettings.Key.customDownloadDir)
                BrowserSettings.shared.set(3, forKey: PrefKey.downloadLocation)
            } else {
                BrowserSettings.shared.set(0, forKey: PrefKey.downloadLocation)
            }
            self.selectPane(.general, animated: false)
        }
    }

    @objc private func homepageFieldCommitted(_ sender: NSTextField) {
        BrowserSettings.shared.set(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: PrefKey.homepage)
    }

    @objc private func setHomepageToCurrentPage() {
        if let urlStr = activePageURLProvider?(), !urlStr.isEmpty {
            homepageField?.stringValue = urlStr
            BrowserSettings.shared.set(urlStr, forKey: PrefKey.homepage)
        } else {
            presentInfoSheet(title: "No Webpage Open", message: "Open a webpage in the active tab to set it as your homepage.")
        }
    }

    // MARK: - 2. Tabs Pane (Exact Safari Tabs Layout + Modern Glass Thumbnails)

    private func buildTabsPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "Tabs Settings")
        let stack = makeFormStack(in: pane, topInset: 20)

        addFormRow(makeFormPopupRow(
            label: "Open pages in tabs instead of windows:",
            options: ["Automatically", "Always", "Never"],
            key: PrefKey.openPagesInTabs,
            defaultIndex: 0,
            popupWidth: 210
        ), to: stack, spacingAfter: 12)

        addFormRow(makeFormPopupRow(
            label: "Automatically close tabs:",
            options: ["Manually", "After one day", "After one week", "After one month"],
            key: PrefKey.autoCloseTabs,
            defaultIndex: 0,
            popupWidth: 164
        ), to: stack, spacingAfter: 16)

        // Tab layout: 3 visual cards directly aligned with control spine
        let selectedLayout = UserDefaults.standard.string(forKey: PrefKey.tabLayout) ?? "compact"
        tabLayoutCards.removeAll()
        let cardsRow = NSStackView()
        cardsRow.orientation = .horizontal
        cardsRow.spacing = 14
        cardsRow.translatesAutoresizingMaskIntoConstraints = false

        let specs: [(String, String, TabLayoutPreviewCard.LayoutStyle)] = [
            ("separate", "Separate", .separate),
            ("compact", "Compact", .compact),
            ("vertical", "Vertical", .vertical)
        ]
        for (id, title, style) in specs {
            let card = TabLayoutPreviewCard(title: title, style: style, isSelected: selectedLayout == id) { [weak self] in
                guard let self else { return }
                BrowserSettings.shared.set(id, forKey: PrefKey.tabLayout)
                for (k, c) in self.tabLayoutCards { c.isSelected = (k == id) }
            }
            tabLayoutCards[id] = card
            cardsRow.addArrangedSubview(card)
        }
        addFormRow(makeTwoColumnRow(label: "Tab layout:", control: cardsRow, labelAlignTop: false), to: stack, spacingAfter: 12)


        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Show website color in toolbar",
            caption: nil,
            key: PrefKey.showWebsiteColor,
            defaultValue: true
        ), to: stack, spacingAfter: 7)

        // Toolbar glass: 2 visual cards matching Tab layout (Default vs Liquid Glass)
        let isGlassSelected = BrowserSettings.shared.refractiveGlassToolbar
        toolbarGlassCards.removeAll()
        let glassCardsRow = NSStackView()
        glassCardsRow.orientation = .horizontal
        glassCardsRow.spacing = 14
        glassCardsRow.translatesAutoresizingMaskIntoConstraints = false

        let frostRow = NSStackView()
        frostRow.orientation = .horizontal
        frostRow.alignment = .centerY
        frostRow.spacing = 10
        frostRow.translatesAutoresizingMaskIntoConstraints = false

        let frostSlider = NSSlider(
            value: BrowserSettings.shared.refractiveGlassFrost,
            minValue: 0.0,
            maxValue: 24.0,
            target: self,
            action: #selector(refractiveGlassFrostSliderChanged(_:))
        )
        frostSlider.isContinuous = true
        frostSlider.controlSize = .small
        frostSlider.translatesAutoresizingMaskIntoConstraints = false
        frostSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let frostValLabel = NSTextField(labelWithString: String(format: "%.0f pt", BrowserSettings.shared.refractiveGlassFrost))
        frostValLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        frostValLabel.textColor = .secondaryLabelColor
        frostValLabel.translatesAutoresizingMaskIntoConstraints = false
        frostValLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        self.refractiveFrostValueLabel = frostValLabel

        frostRow.addArrangedSubview(frostSlider)
        frostRow.addArrangedSubview(frostValLabel)
        let frostRowContainer = makeTwoColumnRow(label: "Glass frost:", control: frostRow)
        frostRowContainer.isHidden = !isGlassSelected
        self.refractiveFrostRowContainer = frostRowContainer

        let glassSpecs: [(String, String, TabLayoutPreviewCard.LayoutStyle, Bool)] = [
            ("default", "Default", .toolbarDefault, false),
            ("glass", "Liquid Glass", .toolbarLiquidGlass, true)
        ]
        for (id, title, style, enablesGlass) in glassSpecs {
            let card = TabLayoutPreviewCard(title: title, style: style, isSelected: isGlassSelected == enablesGlass) { [weak self] in
                guard let self else { return }
                BrowserSettings.shared.refractiveGlassToolbar = enablesGlass
                for (k, c) in self.toolbarGlassCards { c.isSelected = (k == id) }
                self.refractiveFrostRowContainer?.isHidden = !enablesGlass
            }
            toolbarGlassCards[id] = card
            glassCardsRow.addArrangedSubview(card)
        }
        addFormRow(makeTwoColumnRow(label: "Toolbar glass:", control: glassCardsRow, labelAlignTop: false), to: stack, spacingAfter: 10)
        addFormRow(frostRowContainer, to: stack, spacingAfter: 9)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Always show website titles in tabs",
            caption: nil,
            key: PrefKey.alwaysShowTabTitles,
            defaultValue: false
        ), to: stack, spacingAfter: 16)

        addFormRow(makeFormCheckboxRow(
            label: "Navigation:",
            title: "⌘-click opens a link in a new tab",
            caption: nil,
            key: PrefKey.cmdClickNewTab,
            defaultValue: true
        ), to: stack, spacingAfter: 7)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "When a new tab or window opens, make it active",
            caption: nil,
            key: PrefKey.activateNewTabs,
            defaultValue: false
        ), to: stack, spacingAfter: 7)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Use ⌘-1 through ⌘-9 to switch tabs",
            caption: nil,
            key: PrefKey.cmdNumberSwitch,
            defaultValue: true
        ), to: stack, spacingAfter: 10)

        // Classic right-aligned Safari shortcut legend
        let shortcuts: [(String, String)] = [
            ("⌘-click:", "Opens a link in a new tab."),
            ("⌘-Shift-click:", "Opens a link in a new tab, and makes it the active tab."),
            ("⌘-Option-click:", "Opens a link in a new window."),
            ("⌘-Option-Shift-click:", "Opens a link in a new window, and makes it the active window.")
        ]
        for (combo, desc) in shortcuts {
            let descLbl = NSTextField(labelWithString: desc)
            descLbl.translatesAutoresizingMaskIntoConstraints = false
            descLbl.font = NSFont.systemFont(ofSize: 11.5)
            descLbl.textColor = .secondaryLabelColor
            addFormRow(makeTwoColumnRow(label: combo, control: descLbl, labelFont: NSFont.systemFont(ofSize: 11.5), labelColor: .secondaryLabelColor, minHeight: 17), to: stack, spacingAfter: 3)
        }

        return pane
    }

    // MARK: - 3. AutoFill Pane (Exact Safari AutoFill Layout)

    private func buildAutoFillPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "AutoFill Settings")
        let stack = makeFormStack(in: pane, topInset: 24)

        let items: [(label: String?, title: String, key: String, placeholder: String)] = [
            ("AutoFill web forms:", "User names and passwords", PrefKey.autofillPasswords, "site.com — user@example.com"),
            (nil, "Addresses and contact info", PrefKey.autofillAddresses, "Jane Doe, 1 Infinite Loop, Cupertino CA"),
            (nil, "Credit cards", PrefKey.autofillCards, "Personal Visa •••• 4242 (08/29)"),
            (nil, "Other forms", PrefKey.autofillOther, "Company Name / Tax ID")
        ]

        for (idx, item) in items.enumerated() {
            let row = makeCheckboxWithTrailingGlassButtonRow(
                label: item.label,
                title: item.title,
                key: item.key,
                defaultValue: true,
                buttonTitle: "Edit…",
                buttonLeadingOffset: 248
            ) { [weak self] in
                guard let self else { return }
                if item.key == PrefKey.autofillPasswords {
                    self.presentPasswordsEditorSheet()
                } else {
                    self.presentAutoFillListSheet(title: item.title, categoryKey: item.key, placeholder: item.placeholder)
                }
            }
            addFormRow(row, to: stack, spacingAfter: idx == items.count - 1 ? 0 : 12)
        }

        return pane
    }

    private func presentPasswordsEditorSheet() {
        guard let win = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "User Names and Passwords"
        alert.informativeText = "Open the Passwords app to inspect, edit, or export saved credentials, or manage local entries below."
        alert.addButton(withTitle: "Open Passwords…")
        alert.addButton(withTitle: "Edit Local Entries…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard let self else { return }
            if resp == .alertFirstButtonReturn {
                let passwordsApp = URL(fileURLWithPath: "/System/Applications/Passwords.app")
                NSWorkspace.shared.open(passwordsApp)
            } else if resp == .alertSecondButtonReturn {
                self.presentAutoFillListSheet(
                    title: "Saved Credentials",
                    categoryKey: PrefKey.autofillPasswords,
                    placeholder: "example.com — username"
                )
            }
        }
    }

    private func presentAutoFillListSheet(title: String, categoryKey: String, placeholder: String) {
        guard let win = window else { return }
        let entries = BrowserSettings.shared.autoFillEntries(categoryKey: categoryKey)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "One entry per line. Changes are saved to your local Safarium profile."

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 364, height: 140))
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.string = entries.isEmpty ? "" : entries.joined(separator: "\n")
        tv.isRichText = false
        scroll.documentView = tv

        let hint = NSTextField(labelWithString: "Example: \(placeholder)")
        hint.font = NSFont.systemFont(ofSize: 11.0)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 0, width: 380, height: 16)

        let acc = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 164))
        scroll.frame = NSRect(x: 0, y: 22, width: 380, height: 142)
        acc.addSubview(scroll)
        acc.addSubview(hint)
        alert.accessoryView = acc

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn {
                let lines = tv.string
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                BrowserSettings.shared.saveAutoFillEntries(lines, categoryKey: categoryKey)
            } else if resp == .alertSecondButtonReturn {
                BrowserSettings.shared.saveAutoFillEntries([], categoryKey: categoryKey)
            }
        }
    }

    // MARK: - 4. Search Pane (Exact Safari Search Layout)

    private func buildSearchPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "Search Settings")
        let stack = makeFormStack(in: pane, topInset: 22)

        let engines = ["Google", "DuckDuckGo", "Bing", "Yahoo", "Ecosia", "Perplexity", "Kagi"]

        addFormRow(makeFormPopupRow(
            label: "Search engine:",
            options: engines,
            key: PrefKey.searchEngine,
            defaultIndex: 0,
            popupWidth: 148
        ), to: stack, spacingAfter: 10)

        let samePrivate = prefBool(PrefKey.samePrivateSearch, default: true)
        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Also use in Private Browsing",
            caption: nil,
            key: PrefKey.samePrivateSearch,
            defaultValue: true
        ) { [weak self] checked in
            self?.privateSearchPopup?.isEnabled = !checked
        }, to: stack, spacingAfter: 14)

        let (privRow, privPopup) = makeFormPopupRowWithControl(
            label: "Private Browsing search engine:",
            options: engines,
            key: PrefKey.privateSearchEngine,
            defaultIndex: 1,
            popupWidth: 148
        )
        privPopup.isEnabled = !samePrivate
        self.privateSearchPopup = privPopup
        addFormRow(privRow, to: stack, spacingAfter: 18)

        addFormRow(makeFormCheckboxRow(
            label: "Smart Search field:",
            title: "Include search engine suggestions",
            caption: "Private Browsing uses on-device information to provide search suggestions. No data is shared with the service provider.",
            key: PrefKey.searchSuggestions,
            defaultValue: true
        ), to: stack, spacingAfter: 8)

        addFormRow(makeCheckboxWithTrailingGlassButtonRow(
            label: nil,
            title: "Enable Quick Website Search",
            key: PrefKey.quickWebsiteSearch,
            defaultValue: true,
            buttonTitle: "Manage Websites…",
            buttonLeadingOffset: 212
        ) { [weak self] in
            self?.presentQuickWebsiteSearchSheet()
        }, to: stack, spacingAfter: 8)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Show Start Page Favorites",
            caption: nil,
            key: PrefKey.showFavoritesInSearch,
            defaultValue: true
        ), to: stack, spacingAfter: 0)

        return pane
    }

    private func presentQuickWebsiteSearchSheet() {
        guard let win = window else { return }
        let sites = BrowserSettings.shared.quickSearchSites()
        let alert = NSAlert()
        alert.messageText = "Quick Website Search"
        alert.informativeText = "Type a keyword followed by a space in the address bar (e.g. “youtube shader”). Format: keyword | domain | templateURL (with %@)."

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 424, height: 150))
        tv.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.isRichText = false
        tv.string = sites.map { "\($0.keyword) | \($0.domain) | \($0.templateURL)" }.joined(separator: "\n")
        scroll.documentView = tv
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn {
                let parsed: [BrowserSettings.QuickSearchSite] = tv.string
                    .components(separatedBy: .newlines)
                    .compactMap { line in
                        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        guard parts.count >= 3, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
                        return BrowserSettings.QuickSearchSite(keyword: parts[0], domain: parts[1], templateURL: parts[2])
                    }
                BrowserSettings.shared.saveQuickSearchSites(parsed)
            } else if resp == .alertSecondButtonReturn {
                BrowserSettings.shared.saveQuickSearchSites(BrowserSettings.defaultQuickSearchSites)
            }
        }
    }

    // MARK: - 5. Security Pane (Exact Safari Security Layout)

    private func buildSecurityPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "Security Settings")
        let stack = makeFormStack(in: pane, topInset: 24)

        addFormRow(makeFormCheckboxRow(
            label: "Fraudulent sites:",
            title: "Warn when visiting a fraudulent website",
            caption: "Safarium uses Google Safe Browsing to identify fraudulent websites.",
            key: PrefKey.warnFraudulent,
            defaultValue: true
        ), to: stack, spacingAfter: 16)

        addFormRow(makeFormCheckboxRow(
            label: "Web content:",
            title: "Enable JavaScript",
            caption: nil,
            key: PrefKey.enableJavaScript,
            defaultValue: true
        ), to: stack, spacingAfter: 16)

        addFormRow(makeFormCheckboxRow(
            label: "HTTPS connections:",
            title: "Automatically upgrade connections to HTTPS",
            caption: "Safarium automatically switches HTTP links to secure HTTPS when available.",
            key: BrowserSettings.Key.httpsOnlyMode,
            defaultValue: true
        ), to: stack, spacingAfter: 14)

        addFormRow(makeFormCheckboxRow(
            label: "Non-secure site connections:",
            title: "Warn before connecting to a website over HTTP",
            caption: nil,
            key: PrefKey.warnHTTP,
            defaultValue: false
        ), to: stack, spacingAfter: 0)

        return pane
    }

    // MARK: - 6. Privacy Pane (Exact Safari Privacy Layout)

    private func buildPrivacyPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "Privacy Settings")
        let stack = makeFormStack(in: pane, topInset: 20)

        addFormRow(makeFormCheckboxRow(
            label: "Website tracking:",
            title: "Prevent cross-site tracking",
            caption: nil,
            key: PrefKey.preventTracking,
            defaultValue: true
        ), to: stack, spacingAfter: 12)

        addFormRow(makeFormPopupRow(
            label: "Protection level:",
            options: ["Standard (Recommended)", "Strict"],
            key: BrowserSettings.Key.privacyProtectionLevel,
            defaultIndex: 0,
            popupWidth: 230
        ), to: stack, spacingAfter: 14)

        addFormRow(makeFormCheckboxRow(
            label: "Link & referrer privacy:",
            title: "Strip tracking parameters from links",
            caption: nil,
            key: BrowserSettings.Key.stripTrackingParams,
            defaultValue: true
        ), to: stack, spacingAfter: 7)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Trim cross-origin referrers",
            caption: nil,
            key: BrowserSettings.Key.referrerTrimming,
            defaultValue: true
        ), to: stack, spacingAfter: 7)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Protect local IP address from WebRTC leaks",
            caption: nil,
            key: BrowserSettings.Key.webrtcIPProtection,
            defaultValue: true
        ), to: stack, spacingAfter: 16)

        let dataBtn = makeGlassButton(title: "Manage Website Data…", target: self, action: #selector(manageWebsiteDataClicked))
        addFormRow(makeTwoColumnRow(label: "Website data:", control: dataBtn), to: stack, spacingAfter: 12)

        let clearAllBtn = makeGlassButton(title: "Clear All Data…", target: self, action: #selector(clearAllDataClicked))
        addFormRow(makeTwoColumnRow(label: "Reset profile:", control: clearAllBtn), to: stack, spacingAfter: 12)

        let reportBtn = makeGlassButton(title: "View Privacy Report…", target: self, action: #selector(openPrivacyReportClicked))
        addFormRow(makeTwoColumnRow(label: "Privacy Report:", control: reportBtn), to: stack, spacingAfter: 14)

        addFormRow(makeFormCheckboxRow(
            label: "Private Browsing:",
            title: "Require Touch ID to view locked tabs",
            caption: nil,
            key: PrefKey.touchIDLockedPrivate,
            defaultValue: true
        ), to: stack, spacingAfter: 0)

        // Bottom-left Advanced Settings glass button (exact Safari Privacy placement)
        let advBtn = makeGlassButton(title: "Advanced Settings", target: self, action: #selector(openAdvancedFromPrivacy))
        pane.addSubview(advBtn)
        NSLayoutConstraint.activate([
            advBtn.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            advBtn.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16)
        ])

        return pane
    }

    @objc private func manageWebsiteDataClicked() {
        guard let win = window else { return }
        let sheet = WebsiteDataSheetController(
            fetchRecords: { [weak self] completion in
                guard let self else {
                    completion([])
                    return
                }
                self.engine.fetchWebsiteDataRecords(completion: completion)
            },
            removeDomains: { [weak self] domains, completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.engine.removeWebsiteData(forDomains: domains, completion: completion)
            },
            removeAll: { [weak self] completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.engine.clearWebsiteData(completion: completion)
            }
        )
        self.websiteDataSheetController = sheet
        if let existingObserver = websiteDataSheetEndObserver {
            NotificationCenter.default.removeObserver(existingObserver)
            websiteDataSheetEndObserver = nil
        }
        websiteDataSheetEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification,
            object: win,
            queue: .main
        ) { [weak self, weak sheet] _ in
            guard let self else { return }
            if let obs = self.websiteDataSheetEndObserver {
                NotificationCenter.default.removeObserver(obs)
                self.websiteDataSheetEndObserver = nil
            }
            if let sheet, self.websiteDataSheetController === sheet {
                self.websiteDataSheetController = nil
            }
        }
        sheet.beginSheet(for: win)
    }

    @objc private func openPrivacyReportClicked() {
        onOpenPrivacyReport?()
    }

    @objc private func clearAllDataClicked() {
        (NSApp.delegate as? AppDelegate)?.presentClearAllDataConfirmation(over: window)
    }

    @objc private func openAdvancedFromPrivacy() {
        selectPane(.advanced, animated: true)
    }

    // MARK: - 7. Websites Pane (Exact Safari Split Layout + Modern Glass Cards)

    private func buildWebsitesPane() -> NSView {
        let container = makeFormPaneBase(helpTopic: "Websites Settings")

        let leftCard = ModernGlassPanelBox(cornerRadius: 14)
        leftCard.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftCard)

        let catScroll = NSScrollView()
        catScroll.translatesAutoresizingMaskIntoConstraints = false
        catScroll.drawsBackground = false
        catScroll.hasVerticalScroller = true
        catScroll.autohidesScrollers = true
        catScroll.borderType = .noBorder

        let catClip = SettingsFlippedClipView()
        catClip.drawsBackground = false
        catScroll.contentView = catClip

        let catDoc = SettingsFlippedView()
        catDoc.translatesAutoresizingMaskIntoConstraints = false

        let catStack = NSStackView()
        catStack.orientation = .vertical
        catStack.alignment = .leading
        catStack.spacing = 2
        catStack.translatesAutoresizingMaskIntoConstraints = false
        catDoc.addSubview(catStack)
        catScroll.documentView = catDoc
        leftCard.bodyView.addSubview(catScroll)

        let genHdr = makeSidebarSectionHeader("General", topPad: 8)
        catStack.addArrangedSubview(genHdr)
        genHdr.widthAnchor.constraint(equalTo: catStack.widthAnchor).isActive = true

        for cat in WebsiteCategory.allCases {
            let row = WebsiteCategoryRowView(category: cat, isSelected: cat == selectedWebsiteCategory) { [weak self] chosen in
                self?.selectedWebsiteCategory = chosen
                self?.selectedWebsiteHost = nil
                self?.selectPane(.websites, animated: false)
            }
            catStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: catStack.widthAnchor).isActive = true
        }

        // Right region
        let rightArea = NSView()
        rightArea.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rightArea)

        let promptLbl = NSTextField(labelWithString: selectedWebsiteCategory.policyPrompt)
        promptLbl.translatesAutoresizingMaskIntoConstraints = false
        promptLbl.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        promptLbl.textColor = .labelColor
        rightArea.addSubview(promptLbl)

        let listCard = ModernGlassPanelBox(cornerRadius: 14)
        listCard.translatesAutoresizingMaskIntoConstraints = false
        rightArea.addSubview(listCard)

        let sitesScroll = NSScrollView()
        sitesScroll.translatesAutoresizingMaskIntoConstraints = false
        sitesScroll.drawsBackground = false
        sitesScroll.hasVerticalScroller = true
        sitesScroll.autohidesScrollers = true
        sitesScroll.borderType = .noBorder

        let sitesClip = SettingsFlippedClipView()
        sitesClip.drawsBackground = false
        sitesScroll.contentView = sitesClip

        let sitesDoc = SettingsFlippedView()
        sitesDoc.translatesAutoresizingMaskIntoConstraints = false

        let sitesStack = NSStackView()
        sitesStack.orientation = .vertical
        sitesStack.alignment = .leading
        sitesStack.spacing = 2
        sitesStack.translatesAutoresizingMaskIntoConstraints = false
        sitesDoc.addSubview(sitesStack)
        sitesScroll.documentView = sitesDoc
        listCard.bodyView.addSubview(sitesScroll)

        if selectedWebsiteCategory == .extensionAccess {
            let hdr = makeSidebarSectionHeader("Installed Extensions", topPad: 8)
            sitesStack.addArrangedSubview(hdr)
            hdr.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true

            if extensions.isEmpty {
                let empty = makeMutedRowLabel("No extensions installed.")
                sitesStack.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true
            } else {
                for ext in extensions {
                    let meta = ExtensionManifestMetadata.parse(fromInstallPath: ext.installPath)
                    let key = "Safarium.SitePolicy.ext.\(ext.id)"
                    let row = makeWebsitePermissionRow(
                        title: ext.name,
                        icon: ext.icon,
                        fallbackSymbol: "puzzlepiece.extension.fill",
                        options: selectedWebsiteCategory.options,
                        selectedIndex: prefInt(key, default: meta.hasBroadWebAccess ? 0 : 1),
                        prefKey: key
                    )
                    sitesStack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true
                }
            }
        } else {
            let openSites = openWebsitesProvider?() ?? []
            let openHostSet = Set(openSites.map(\.host))
            let configuredHosts = BrowserSettings.shared.configuredHosts(for: selectedWebsiteCategory.rawValue)
                .filter { !openHostSet.contains($0) }

            let hdr = makeSidebarSectionHeader("Currently Open Websites", topPad: 8)
            sitesStack.addArrangedSubview(hdr)
            hdr.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true

            if openSites.isEmpty {
                let empty = makeMutedRowLabel("No websites are currently open.")
                sitesStack.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true
            } else {
                for site in openSites {
                    let key = "Safarium.SitePolicy.\(selectedWebsiteCategory.rawValue).\(site.host)"
                    let idx = BrowserSettings.shared.websitePolicyIndex(
                        category: selectedWebsiteCategory.rawValue,
                        host: site.host,
                        defaultIndex: selectedWebsiteCategory.defaultOptionIndex
                    )
                    let row = makeWebsitePermissionRow(
                        title: site.host,
                        icon: site.favicon,
                        fallbackSymbol: "globe",
                        options: selectedWebsiteCategory.options,
                        selectedIndex: idx,
                        prefKey: key,
                        isSelected: selectedWebsiteHost == site.host
                    )
                    sitesStack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true
                }
            }

            if !configuredHosts.isEmpty {
                let cfgHdr = makeSidebarSectionHeader("Configured Websites", topPad: 12)
                sitesStack.addArrangedSubview(cfgHdr)
                cfgHdr.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true
                for host in configuredHosts {
                    let key = "Safarium.SitePolicy.\(selectedWebsiteCategory.rawValue).\(host)"
                    let idx = BrowserSettings.shared.websitePolicyIndex(
                        category: selectedWebsiteCategory.rawValue,
                        host: host,
                        defaultIndex: selectedWebsiteCategory.defaultOptionIndex
                    )
                    let row = makeWebsitePermissionRow(
                        title: host,
                        icon: FaviconCache.shared.cachedImage(forURLString: "https://\(host)/"),
                        fallbackSymbol: "globe",
                        options: selectedWebsiteCategory.options,
                        selectedIndex: idx,
                        prefKey: key,
                        isSelected: selectedWebsiteHost == host
                    )
                    sitesStack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: sitesStack.widthAnchor).isActive = true
                }
            }
        }

        let removeBtn = makeGlassButton(title: "Remove", target: self, action: #selector(removeSelectedSiteRule))
        removeBtn.isEnabled = (selectedWebsiteHost != nil)
        rightArea.addSubview(removeBtn)

        let otherLbl = NSTextField(labelWithString: "When visiting other websites:")
        otherLbl.translatesAutoresizingMaskIntoConstraints = false
        otherLbl.font = NSFont.systemFont(ofSize: 13.0)
        otherLbl.textColor = .labelColor
        rightArea.addSubview(otherLbl)

        let globalKey = "Safarium.SiteDefault.\(selectedWebsiteCategory.rawValue)"
        let categoryName = selectedWebsiteCategory.rawValue
        let otherPopup = makeCapsulePopup(
            options: selectedWebsiteCategory.options,
            selectedIndex: prefInt(globalKey, default: selectedWebsiteCategory.defaultOptionIndex)
        ) { idx in
            BrowserSettings.shared.setWebsiteDefaultPolicy(category: categoryName, index: idx)
        }
        rightArea.addSubview(otherPopup)

        NSLayoutConstraint.activate([
            leftCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            leftCard.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftCard.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -46),
            leftCard.widthAnchor.constraint(equalToConstant: 206),

            catScroll.leadingAnchor.constraint(equalTo: leftCard.bodyView.leadingAnchor, constant: 6),
            catScroll.trailingAnchor.constraint(equalTo: leftCard.bodyView.trailingAnchor, constant: -6),
            catScroll.topAnchor.constraint(equalTo: leftCard.bodyView.topAnchor, constant: 4),
            catScroll.bottomAnchor.constraint(equalTo: leftCard.bodyView.bottomAnchor, constant: -6),

            catDoc.leadingAnchor.constraint(equalTo: catClip.leadingAnchor),
            catDoc.trailingAnchor.constraint(equalTo: catClip.trailingAnchor),
            catDoc.topAnchor.constraint(equalTo: catClip.topAnchor),
            catDoc.widthAnchor.constraint(equalTo: catClip.widthAnchor),

            catStack.leadingAnchor.constraint(equalTo: catDoc.leadingAnchor),
            catStack.trailingAnchor.constraint(equalTo: catDoc.trailingAnchor),
            catStack.topAnchor.constraint(equalTo: catDoc.topAnchor),
            catStack.bottomAnchor.constraint(equalTo: catDoc.bottomAnchor, constant: -6),

            rightArea.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 16),
            rightArea.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            rightArea.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightArea.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),

            promptLbl.leadingAnchor.constraint(equalTo: rightArea.leadingAnchor, constant: 2),
            promptLbl.trailingAnchor.constraint(equalTo: rightArea.trailingAnchor),
            promptLbl.topAnchor.constraint(equalTo: rightArea.topAnchor, constant: 4),

            listCard.leadingAnchor.constraint(equalTo: rightArea.leadingAnchor),
            listCard.trailingAnchor.constraint(equalTo: rightArea.trailingAnchor),
            listCard.topAnchor.constraint(equalTo: promptLbl.bottomAnchor, constant: 10),
            listCard.bottomAnchor.constraint(equalTo: removeBtn.topAnchor, constant: -12),

            sitesScroll.leadingAnchor.constraint(equalTo: listCard.bodyView.leadingAnchor, constant: 6),
            sitesScroll.trailingAnchor.constraint(equalTo: listCard.bodyView.trailingAnchor, constant: -6),
            sitesScroll.topAnchor.constraint(equalTo: listCard.bodyView.topAnchor, constant: 4),
            sitesScroll.bottomAnchor.constraint(equalTo: listCard.bodyView.bottomAnchor, constant: -6),

            sitesDoc.leadingAnchor.constraint(equalTo: sitesClip.leadingAnchor),
            sitesDoc.trailingAnchor.constraint(equalTo: sitesClip.trailingAnchor),
            sitesDoc.topAnchor.constraint(equalTo: sitesClip.topAnchor),
            sitesDoc.widthAnchor.constraint(equalTo: sitesClip.widthAnchor),

            sitesStack.leadingAnchor.constraint(equalTo: sitesDoc.leadingAnchor),
            sitesStack.trailingAnchor.constraint(equalTo: sitesDoc.trailingAnchor),
            sitesStack.topAnchor.constraint(equalTo: sitesDoc.topAnchor),
            sitesStack.bottomAnchor.constraint(equalTo: sitesDoc.bottomAnchor, constant: -6),

            removeBtn.leadingAnchor.constraint(equalTo: rightArea.leadingAnchor),
            removeBtn.bottomAnchor.constraint(equalTo: rightArea.bottomAnchor),

            otherPopup.trailingAnchor.constraint(equalTo: rightArea.trailingAnchor),
            otherPopup.centerYAnchor.constraint(equalTo: removeBtn.centerYAnchor),

            otherLbl.trailingAnchor.constraint(equalTo: otherPopup.leadingAnchor, constant: -10),
            otherLbl.centerYAnchor.constraint(equalTo: removeBtn.centerYAnchor)
        ])

        return container
    }

    private func makeWebsitePermissionRow(
        title: String,
        icon: NSImage?,
        fallbackSymbol: String,
        options: [String],
        selectedIndex: Int,
        prefKey: String,
        isSelected: Bool = false
    ) -> NSView {
        let row = SelectableSettingsRowView(isSelected: isSelected) { [weak self] in
            guard let self, self.selectedWebsiteCategory != .extensionAccess else { return }
            self.selectedWebsiteHost = title
            self.selectPane(.websites, animated: false)
        }
        row.translatesAutoresizingMaskIntoConstraints = false

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        if let icon {
            iv.image = icon
        } else {
            iv.image = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: title)
            iv.contentTintColor = isSelected ? .white : .secondaryLabelColor
        }

        let lbl = NSTextField(labelWithString: title)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: 13.0)
        lbl.textColor = isSelected ? .white : .labelColor
        lbl.lineBreakMode = .byTruncatingTail

        let categoryName = selectedWebsiteCategory.rawValue
        let popup = makeCapsulePopup(options: options, selectedIndex: selectedIndex) { idx in
            UserDefaults.standard.set(idx, forKey: prefKey)
            NotificationCenter.default.post(
                name: .safariumWebsitePoliciesDidChange,
                object: BrowserSettings.shared,
                userInfo: ["category": categoryName, "host": title, "index": idx]
            )
        }

        row.addSubview(iv)
        row.addSubview(lbl)
        row.addSubview(popup)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 36),
            iv.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            iv.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),

            lbl.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 9),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -10),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            popup.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            popup.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    @objc private func removeSelectedSiteRule() {
        if let host = selectedWebsiteHost {
            BrowserSettings.shared.removeWebsitePolicy(category: selectedWebsiteCategory.rawValue, host: host)
        }
        selectedWebsiteHost = nil
        selectPane(.websites, animated: false)
    }

    // MARK: - 8. Profiles Pane (Exact Safari Centered Profiles Layout + Glass Pill)

    private func buildProfilesPane() -> NSView {
        let container = makeFormPaneBase(helpTopic: "Profiles Settings", showHelp: false)
        let enabled = prefBool(PrefKey.profilesEnabled, default: false)

        if !enabled {
            let icons = NSStackView()
            icons.orientation = .horizontal
            icons.spacing = 24
            icons.translatesAutoresizingMaskIntoConstraints = false

            for sym in ["person.fill", "briefcase.fill", "graduationcap.fill"] {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
                iv.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
                iv.contentTintColor = .tertiaryLabelColor
                icons.addArrangedSubview(iv)
            }
            container.addSubview(icons)

            let copy = NSTextField(wrappingLabelWithString:
                "Profiles allow you to keep your personal browsing separate from your work or school browsing.\n\n" +
                "Your history, cookies, and website data will be separated based on which profile you are using. You can also manage your extensions independently per profile.\n\n" +
                "When you start using Profiles, a Personal profile will be automatically created for you based on your current settings. You can name your second profile, give it an icon, and set custom Favorites."
            )
            copy.translatesAutoresizingMaskIntoConstraints = false
            copy.font = NSFont.systemFont(ofSize: 12.5)
            copy.textColor = .secondaryLabelColor
            container.addSubview(copy)

            let startBtn = makeGlassButton(title: "Start Using Profiles", target: self, action: #selector(enableProfilesClicked))
            container.addSubview(startBtn)

            NSLayoutConstraint.activate([
                icons.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                icons.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),

                copy.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                copy.topAnchor.constraint(equalTo: icons.bottomAnchor, constant: 22),
                copy.widthAnchor.constraint(equalToConstant: 470),

                startBtn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                startBtn.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 22)
            ])
        } else {
            let names = UserDefaults.standard.stringArray(forKey: PrefKey.profileNames) ?? ["Personal", "Work"]
            let activeName = BrowserSettings.shared.string(BrowserSettings.Key.activeProfileName, default: names.first ?? "Personal")
            let card = ModernGlassPanelBox(cornerRadius: 14)
            card.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(card)

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.bodyView.addSubview(stack)

            for (idx, name) in names.enumerated() {
                let isActive = (name == activeName)
                let row = NSView()
                row.translatesAutoresizingMaskIntoConstraints = false
                let lbl = NSTextField(labelWithString: isActive ? "\(name)  •  Active" : name)
                lbl.translatesAutoresizingMaskIntoConstraints = false
                lbl.font = NSFont.systemFont(ofSize: 13.0, weight: isActive ? .semibold : .regular)
                row.addSubview(lbl)

                let actionBtn = TahoeActionGlassButton(title: isActive ? "Active" : "Switch") { [weak self] in
                    guard let self, !isActive else { return }
                    BrowserSettings.shared.set(name, forKey: BrowserSettings.Key.activeProfileName)
                    self.selectPane(.profiles, animated: false)
                }
                actionBtn.isEnabled = !isActive
                row.addSubview(actionBtn)

                if idx > 0 {
                    let delBtn = TahoeActionGlassButton(title: "Remove") { [weak self] in
                        guard let self else { return }
                        var updated = UserDefaults.standard.stringArray(forKey: PrefKey.profileNames) ?? ["Personal"]
                        updated.removeAll { $0 == name }
                        if updated.isEmpty { updated = ["Personal"] }
                        UserDefaults.standard.set(updated, forKey: PrefKey.profileNames)
                        if BrowserSettings.shared.string(BrowserSettings.Key.activeProfileName) == name {
                            BrowserSettings.shared.set(updated.first ?? "Personal", forKey: BrowserSettings.Key.activeProfileName)
                        }
                        self.selectPane(.profiles, animated: false)
                    }
                    row.addSubview(delBtn)
                    NSLayoutConstraint.activate([
                        delBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                        delBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                        actionBtn.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor, constant: -8),
                        actionBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor)
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        actionBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                        actionBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor)
                    ])
                }

                NSLayoutConstraint.activate([
                    row.heightAnchor.constraint(equalToConstant: 36),
                    lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                    lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor)
                ])
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }

            let addBtn = makeGlassButton(title: "New Profile…", target: self, action: #selector(promptNewProfile))
            container.addSubview(addBtn)

            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                card.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
                card.widthAnchor.constraint(equalToConstant: 460),
                card.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -16),

                stack.leadingAnchor.constraint(equalTo: card.bodyView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: card.bodyView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: card.bodyView.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bodyView.bottomAnchor, constant: -10),

                addBtn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                addBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22)
            ])
        }

        return container
    }

    @objc private func enableProfilesClicked() {
        UserDefaults.standard.set(true, forKey: PrefKey.profilesEnabled)
        if UserDefaults.standard.stringArray(forKey: PrefKey.profileNames) == nil {
            UserDefaults.standard.set(["Personal", "Work"], forKey: PrefKey.profileNames)
        }
        selectPane(.profiles, animated: false)
    }

    @objc private func promptNewProfile() {
        guard let win = window else { return }
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Enter a name for the new Safarium profile."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "School, Dev, Research…"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            var current = UserDefaults.standard.stringArray(forKey: PrefKey.profileNames) ?? ["Personal"]
            guard !current.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            current.append(name)
            UserDefaults.standard.set(current, forKey: PrefKey.profileNames)
            self.selectPane(.profiles, animated: false)
        }
    }

    // MARK: - 9. Extensions Pane (Exact Safari Extensions Layout + Modern Glass Cards & Controls)

    private func buildExtensionsPane() -> NSView {
        let container = makeFormPaneBase(helpTopic: "Extensions Settings")

        let leftCard = ModernGlassPanelBox(cornerRadius: 14)
        leftCard.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftCard)

        let addRow = AddExtensionsHeaderRow()
        addRow.translatesAutoresizingMaskIntoConstraints = false
        addRow.onClick = { [weak self, weak addRow] in
            guard let self, let anchor = addRow else { return }
            self.presentAddExtensionsMenu(relativeTo: anchor)
        }
        leftCard.bodyView.addSubview(addRow)

        let addSep = SettingsHairlineView()
        addSep.translatesAutoresizingMaskIntoConstraints = false
        leftCard.bodyView.addSubview(addSep)

        let listScroll = NSScrollView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder

        let clip = SettingsFlippedClipView()
        clip.drawsBackground = false
        listScroll.contentView = clip

        let listDoc = SettingsFlippedView()
        listDoc.translatesAutoresizingMaskIntoConstraints = false

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listDoc.addSubview(listStack)
        self.extensionsListStack = listStack

        listScroll.documentView = listDoc
        leftCard.bodyView.addSubview(listScroll)

        let rightCard = ModernGlassPanelBox(cornerRadius: 14)
        rightCard.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rightCard)
        self.extensionDetailContainer = rightCard.bodyView

        NSLayoutConstraint.activate([
            leftCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            leftCard.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            leftCard.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -46),
            leftCard.widthAnchor.constraint(equalToConstant: 218),

            addRow.leadingAnchor.constraint(equalTo: leftCard.bodyView.leadingAnchor, constant: 6),
            addRow.trailingAnchor.constraint(equalTo: leftCard.bodyView.trailingAnchor, constant: -6),
            addRow.topAnchor.constraint(equalTo: leftCard.bodyView.topAnchor, constant: 6),
            addRow.heightAnchor.constraint(equalToConstant: 36),

            addSep.leadingAnchor.constraint(equalTo: leftCard.bodyView.leadingAnchor, constant: 10),
            addSep.trailingAnchor.constraint(equalTo: leftCard.bodyView.trailingAnchor, constant: -10),
            addSep.topAnchor.constraint(equalTo: addRow.bottomAnchor, constant: 4),
            addSep.heightAnchor.constraint(equalToConstant: 1),

            listScroll.leadingAnchor.constraint(equalTo: leftCard.bodyView.leadingAnchor, constant: 6),
            listScroll.trailingAnchor.constraint(equalTo: leftCard.bodyView.trailingAnchor, constant: -6),
            listScroll.topAnchor.constraint(equalTo: addSep.bottomAnchor, constant: 4),
            listScroll.bottomAnchor.constraint(equalTo: leftCard.bodyView.bottomAnchor, constant: -6),

            listDoc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            listDoc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            listDoc.topAnchor.constraint(equalTo: clip.topAnchor),
            listDoc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            listStack.leadingAnchor.constraint(equalTo: listDoc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDoc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listDoc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDoc.bottomAnchor, constant: -6),

            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 14),
            rightCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor)
        ])

        return container
    }

    private func rebuildExtensionsList() {
        guard let stack = extensionsListStack else { return }
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        if extensions.isEmpty {
            let empty = makeMutedRowLabel("No extensions installed.\nClick “Add Extensions” above.")
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }

        let unpacked = extensions.filter { isUnpackedLocalExtension($0) }
        let installed = extensions.filter { !isUnpackedLocalExtension($0) }

        if !unpacked.isEmpty {
            let hdr = makeSidebarSectionHeader("Your Extensions", topPad: 6)
            stack.addArrangedSubview(hdr)
            hdr.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for ext in unpacked {
                let row = makeExtensionRow(ext)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        if !installed.isEmpty {
            let hdr = makeSidebarSectionHeader("Installed", topPad: unpacked.isEmpty ? 6 : 12)
            stack.addArrangedSubview(hdr)
            hdr.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for ext in installed {
                let row = makeExtensionRow(ext)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    func isUnpackedLocalExtension(_ ext: BrowserExtensionItem) -> Bool {
        if ext.storeID != nil && !(ext.storeID?.isEmpty ?? true) { return false }
        let lower = ext.installPath.lowercased()
        return !lower.contains("/cws-") && !lower.contains("/crx-")
    }

    private func makeExtensionRow(_ ext: BrowserExtensionItem) -> ExtensionSidebarRowView {
        let row = ExtensionSidebarRowView(item: ext, isSelected: ext.id == selectedExtensionID)
        row.onSelect = { [weak self] id in
            guard let self else { return }
            self.selectedExtensionID = id
            self.rebuildExtensionsList()
            self.rebuildExtensionDetail()
        }
        row.onToggleEnabled = { [weak self] id, enabled in
            guard let self else { return }
            self.engine.setExtensionEnabled(enabled, forID: id) { [weak self] _ in
                self?.reloadExtensions(selectID: id)
                self?.onExtensionsChanged?()
            }
        }
        return row
    }

    private func rebuildExtensionDetail() {
        guard let container = extensionDetailContainer else { return }
        for sub in container.subviews { sub.removeFromSuperview() }

        guard let ext = extensions.first(where: { $0.id == selectedExtensionID }) ?? extensions.first else {
            let emptyLabel = NSTextField(labelWithString: "Select an extension to view details and permissions.")
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyLabel.font = NSFont.systemFont(ofSize: 13.0)
            emptyLabel.textColor = .secondaryLabelColor
            container.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            return
        }

        let meta = ExtensionManifestMetadata.parse(fromInstallPath: ext.installPath)

        // Header
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerView)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 11.0
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        if let icon = ext.icon {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: ext.name)
            iconView.contentTintColor = .secondaryLabelColor
        }
        headerView.addSubview(iconView)

        let titleAttributed = NSMutableAttributedString(
            string: ext.name,
            attributes: [.font: NSFont.systemFont(ofSize: 14.0, weight: .bold), .foregroundColor: NSColor.labelColor]
        )
        var ver = "  \(ext.version)"
        if let author = meta.author, !author.isEmpty { ver += " from \(author)" }
        titleAttributed.append(NSAttributedString(
            string: ver,
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor]
        ))

        let titleLabel = NSTextField(labelWithAttributedString: titleAttributed)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(titleLabel)

        let descText = (ext.extensionDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? ext.extensionDescription!
            : "Installed Manifest V3 Chromium extension."
        let descLabel = NSTextField(wrappingLabelWithString: descText)
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = NSFont.systemFont(ofSize: 12.5)
        descLabel.textColor = .labelColor
        descLabel.maximumNumberOfLines = 3
        headerView.addSubview(descLabel)

        let uninstallBtn = makeGlassButton(title: "Uninstall", target: self, action: #selector(uninstallSelectedExtension))
        let clearBtn = makeGlassButton(title: "Clear Storage…", target: self, action: #selector(clearStorageForSelectedExtension))
        let btnRow = NSStackView(views: [uninstallBtn, clearBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(btnRow)

        let divider = SettingsHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        // Scrollable detail body
        let bodyScroll = NSScrollView()
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .noBorder

        let clip = SettingsFlippedClipView()
        clip.drawsBackground = false
        bodyScroll.contentView = clip

        let bodyDoc = SettingsFlippedView()
        bodyDoc.translatesAutoresizingMaskIntoConstraints = false

        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 10
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyDoc.addSubview(bodyStack)
        bodyScroll.documentView = bodyDoc
        container.addSubview(bodyScroll)

        // Private Browsing
        let privHdr = NSTextField(labelWithString: "Private Browsing:")
        privHdr.font = NSFont.systemFont(ofSize: 12.5)
        privHdr.textColor = .labelColor
        bodyStack.addArrangedSubview(privHdr)

        let privWrap = NSView()
        privWrap.translatesAutoresizingMaskIntoConstraints = false
        let privCheck = NSButton(checkboxWithTitle: "Allow in Private Browsing", target: self, action: #selector(toggleAllowInPrivate(_:)))
        privCheck.translatesAutoresizingMaskIntoConstraints = false
        privCheck.font = NSFont.systemFont(ofSize: 12.5)
        privCheck.state = ext.allowInPrivate ? .on : .off
        privWrap.addSubview(privCheck)
        NSLayoutConstraint.activate([
            privCheck.leadingAnchor.constraint(equalTo: privWrap.leadingAnchor, constant: 16),
            privCheck.topAnchor.constraint(equalTo: privWrap.topAnchor),
            privCheck.bottomAnchor.constraint(equalTo: privWrap.bottomAnchor),
            privCheck.trailingAnchor.constraint(lessThanOrEqualTo: privWrap.trailingAnchor)
        ])
        bodyStack.addArrangedSubview(privWrap)
        bodyStack.setCustomSpacing(14, after: privWrap)

        // Permissions
        let permHdr = NSTextField(labelWithString: "Permissions:")
        permHdr.font = NSFont.systemFont(ofSize: 12.5)
        permHdr.textColor = .labelColor
        bodyStack.addArrangedSubview(permHdr)

        let warningCard = PermissionWarningCardView(
            headline: meta.permissionHeadline,
            detail: meta.permissionDetail,
            isBroadAccess: meta.hasBroadWebAccess
        )
        bodyStack.addArrangedSubview(warningCard)
        warningCard.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        bodyStack.setCustomSpacing(12, after: warningCard)

        let webHint = NSTextField(wrappingLabelWithString: "You can change this in the Websites section of Safarium Settings.")
        webHint.font = NSFont.systemFont(ofSize: 12.5)
        webHint.textColor = .labelColor
        bodyStack.addArrangedSubview(webHint)
        bodyStack.setCustomSpacing(8, after: webHint)

        let editWebBtn = makeGlassButton(title: "Edit Websites…", target: self, action: #selector(openWebsitesSettings))
        bodyStack.addArrangedSubview(editWebBtn)

        // Shortcuts
        if !meta.shortcuts.isEmpty {
            bodyStack.setCustomSpacing(16, after: editWebBtn)

            let scHdr = NSTextField(labelWithString: "•  Shortcuts")
            scHdr.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            scHdr.textColor = .labelColor
            bodyStack.addArrangedSubview(scHdr)
            bodyStack.setCustomSpacing(4, after: scHdr)

            let offersLbl = NSTextField(labelWithString: "Offers keyboard shortcuts:")
            offersLbl.font = NSFont.systemFont(ofSize: 12.0)
            offersLbl.textColor = .secondaryLabelColor
            bodyStack.addArrangedSubview(offersLbl)
            bodyStack.setCustomSpacing(6, after: offersLbl)

            let clearedSet = Set(UserDefaults.standard.stringArray(forKey: PrefKey.clearedShortcuts) ?? [])
            for sc in meta.shortcuts {
                let scKey = "\(ext.id)::\(sc.commandName)"
                let displayedKey = clearedSet.contains(scKey) ? nil : sc.formattedShortcut
                let row = ExtensionShortcutRowView(descriptionText: sc.descriptionText, shortcutText: displayedKey) { [weak self] in
                    guard let self else { return }
                    var list = Set(UserDefaults.standard.stringArray(forKey: PrefKey.clearedShortcuts) ?? [])
                    list.insert(scKey)
                    UserDefaults.standard.set(Array(list), forKey: PrefKey.clearedShortcuts)
                    self.rebuildExtensionDetail()
                }
                bodyStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: container.topAnchor),

            iconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 18),
            iconView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 46),
            iconView.heightAnchor.constraint(equalToConstant: 46),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 15),

            descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            btnRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            btnRow.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 10),
            btnRow.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -14),

            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            bodyScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bodyScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            bodyDoc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            bodyDoc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            bodyDoc.topAnchor.constraint(equalTo: clip.topAnchor),
            bodyDoc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            bodyStack.leadingAnchor.constraint(equalTo: bodyDoc.leadingAnchor, constant: 18),
            bodyStack.trailingAnchor.constraint(equalTo: bodyDoc.trailingAnchor, constant: -18),
            bodyStack.topAnchor.constraint(equalTo: bodyDoc.topAnchor, constant: 14),
            bodyStack.bottomAnchor.constraint(equalTo: bodyDoc.bottomAnchor, constant: -16)
        ])
    }

    private func presentAddExtensionsMenu(relativeTo anchor: NSView) {
        let menu = NSMenu()
        let store = NSMenuItem(title: "Chrome Web Store…", action: #selector(handleAddFromWebStore), keyEquivalent: "")
        store.target = self
        menu.addItem(store)
        menu.addItem(.separator())

        let unpacked = NSMenuItem(title: "Load Unpacked Extension…", action: #selector(handleAddUnpacked), keyEquivalent: "")
        unpacked.target = self
        menu.addItem(unpacked)

        let crx = NSMenuItem(title: "Install .crx / .zip Extension…", action: #selector(handleAddCRX), keyEquivalent: "")
        crx.target = self
        menu.addItem(crx)

        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func handleAddFromWebStore() { onOpenChromeWebStore?() }
    @objc private func handleAddUnpacked() { onLoadUnpackedExtension?() }
    @objc private func handleAddCRX() { onInstallCRXExtension?() }

    @objc private func uninstallSelectedExtension() {
        guard let ext = extensions.first(where: { $0.id == selectedExtensionID }),
              let win = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall “\(ext.name)”?"
        alert.informativeText = "This will remove the extension and its local files from Safarium."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            _ = self.engine.uninstallExtension(withID: ext.id)
            self.selectedExtensionID = nil
            self.reloadExtensions()
            self.onExtensionsChanged?()
        }
    }

    @objc private func clearStorageForSelectedExtension() {
        guard let ext = extensions.first(where: { $0.id == selectedExtensionID }),
              let win = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Clear Storage for “\(ext.name)”?"
        alert.informativeText = "All locally stored preferences, cached data, and IndexedDB storage for this extension will be removed."
        alert.addButton(withTitle: "Clear Storage")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.engine.clearExtensionStorage(forID: ext.id) { [weak self] _ in
                self?.onExtensionsChanged?()
            }
        }
    }

    @objc private func toggleAllowInPrivate(_ sender: NSButton) {
        guard let ext = extensions.first(where: { $0.id == selectedExtensionID }) else { return }
        engine.setExtensionAllowInPrivate(sender.state == .on, forID: ext.id) { [weak self] _ in
            self?.reloadExtensions(selectID: ext.id)
            self?.onExtensionsChanged?()
        }
    }

    @objc private func openWebsitesSettings() {
        selectedWebsiteCategory = .extensionAccess
        selectedWebsiteHost = nil
        selectPane(.websites, animated: true)
    }

    // MARK: - 10. Advanced Pane (Exact Safari Advanced Layout)

    private func buildAdvancedPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "Advanced Settings")
        let stack = makeFormStack(in: pane, topInset: 20)

        addFormRow(makeFormCheckboxRow(
            label: "Smart Search field:",
            title: "Show full website address",
            caption: nil,
            key: PrefKey.showFullAddress,
            defaultValue: false
        ), to: stack, spacingAfter: 16)

        let minFontEnabled = prefBool(PrefKey.minFontEnabled, default: false)
        let (minFontRow, fontPop) = makeCheckboxWithInlinePopupRow(
            label: "Accessibility:",
            title: "Never use font sizes smaller than",
            switchKey: PrefKey.minFontEnabled,
            switchDefault: false,
            popupOptions: ["9", "10", "11", "12", "14", "16", "18", "24"],
            popupKey: PrefKey.minFontSize,
            popupDefaultIndex: 0
        ) { [weak self] checked in
            self?.minFontSizePopup?.isEnabled = checked
        }
        fontPop.isEnabled = minFontEnabled
        self.minFontSizePopup = fontPop
        addFormRow(minFontRow, to: stack, spacingAfter: 8)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Press Tab to highlight each item on a webpage",
            caption: "Option-Tab highlights each item.",
            key: PrefKey.tabHighlightsAll,
            defaultValue: false
        ), to: stack, spacingAfter: 16)

        let fpEnabled = prefBool(PrefKey.advancedFingerprint, default: true)
        let (fpRow, fpPop) = makeCheckboxWithInlinePopupRow(
            label: "Privacy:",
            title: "Use advanced tracking and fingerprinting protection",
            switchKey: PrefKey.advancedFingerprint,
            switchDefault: true,
            popupOptions: ["in Private Browsing", "in all browsing"],
            popupKey: PrefKey.advancedFingerprintScope,
            popupDefaultIndex: 1
        ) { [weak self] checked in
            self?.trackingScopePopup?.isEnabled = checked
        }
        fpPop.isEnabled = fpEnabled
        self.trackingScopePopup = fpPop
        addFormRow(fpRow, to: stack, spacingAfter: 8)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Use Global Privacy Control",
            caption: "Safarium can ask websites to not sell or share your data. This may cause some websites to not function properly or work at all.",
            key: PrefKey.globalPrivacyControl,
            defaultValue: false
        ), to: stack, spacingAfter: 8)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Block all cookies",
            caption: nil,
            key: PrefKey.blockAllCookies,
            defaultValue: false
        ), to: stack, spacingAfter: 18)

        let customCSSPath = BrowserSettings.shared.string(BrowserSettings.Key.customStyleSheetPath)
        let cssLabel = customCSSPath.isEmpty ? "Other…" : URL(fileURLWithPath: customCSSPath).lastPathComponent
        let (cssRow, _) = makeFormPopupRowWithControl(
            label: "Style sheet:",
            options: ["None Selected", cssLabel],
            key: PrefKey.customStyleSheet,
            defaultIndex: 0,
            popupWidth: 236
        ) { [weak self] idx in
            guard let self else { return }
            if idx == 1 {
                self.promptCustomStyleSheet()
            } else {
                BrowserSettings.shared.set("", forKey: BrowserSettings.Key.customStyleSheetPath)
            }
        }
        addFormRow(cssRow, to: stack, spacingAfter: 10)

        addFormRow(makeFormPopupRow(
            label: "Default encoding:",
            options: ["Unicode (UTF-8)", "Western (ISO Latin 1)", "Western (Windows Latin 1)", "Turkish (ISO Latin 5)", "Japanese (Shift JIS)"],
            key: PrefKey.defaultEncoding,
            defaultIndex: 0,
            popupWidth: 236
        ), to: stack, spacingAfter: 12)

        let proxyBtn = makeGlassButton(title: "Change Settings…", target: self, action: #selector(openSystemProxies))
        addFormRow(makeTwoColumnRow(label: "Proxies:", control: proxyBtn), to: stack, spacingAfter: 18)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Show features for web developers",
            caption: nil,
            key: PrefKey.showDeveloperFeatures,
            defaultValue: true
        ) { [weak self] _ in
            self?.syncDeveloperToolbarItemVisibility()
        }, to: stack, spacingAfter: 0)

        return pane
    }

    @objc private func openSystemProxies() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func promptCustomStyleSheet() {
        guard let win = window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Custom Style Sheet (.css)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard let self else { return }
            if resp == .OK, let url = panel.url {
                BrowserSettings.shared.set(url.path, forKey: BrowserSettings.Key.customStyleSheetPath)
                BrowserSettings.shared.set(1, forKey: PrefKey.customStyleSheet)
            } else {
                // Cancelling the picker is "no change": keep any previously chosen sheet.
                let existing = BrowserSettings.shared.string(BrowserSettings.Key.customStyleSheetPath)
                BrowserSettings.shared.set(existing.isEmpty ? 0 : 1, forKey: PrefKey.customStyleSheet)
            }
            self.selectPane(.advanced, animated: false)
        }
    }

    // MARK: - 11. Developer Pane (Classic Safari Form Layout + Glass Buttons)

    private func buildDeveloperPane() -> NSView {
        let pane = makeFormPaneBase(helpTopic: "Developer Settings")
        let stack = makeFormStack(in: pane, topInset: 24)

        addFormRow(makeFormCheckboxRow(
            label: "Extensions:",
            title: "Allow unsigned and unpacked extensions",
            caption: "Enables Chromium developer mode for local MV3 extension folders.",
            key: PrefKey.devAllowUnsigned,
            defaultValue: true
        ), to: stack, spacingAfter: 14)

        addFormRow(makeFormCheckboxRow(
            label: "Web Inspector:",
            title: "Open Web Inspector in separate window",
            caption: nil,
            key: PrefKey.devSeparateDevTools,
            defaultValue: false
        ), to: stack, spacingAfter: 8)

        addFormRow(makeFormCheckboxRow(
            label: nil,
            title: "Disable caches while Web Inspector is open",
            caption: nil,
            key: PrefKey.devDisableCache,
            defaultValue: false
        ), to: stack, spacingAfter: 18)

        let inspectBtn = makeGlassButton(title: "Inspect…", target: self, action: #selector(openSafariumInspect))
        let remoteDebugBtn = makeGlassButton(title: "Remote Debugging…", target: self, action: #selector(openSafariumRemoteDebugging))
        let diagStack = NSStackView(views: [inspectBtn, remoteDebugBtn])
        diagStack.orientation = .horizontal
        diagStack.spacing = 10
        diagStack.translatesAutoresizingMaskIntoConstraints = false
        addFormRow(makeTwoColumnRow(label: "Developer tools:", control: diagStack), to: stack, spacingAfter: 0)

        return pane
    }

    private var toolbarGlassCards: [String: TabLayoutPreviewCard] = [:]
    private weak var refractiveFrostRowContainer: NSView?
    private weak var refractiveFrostValueLabel: NSTextField?

    @objc private func refractiveGlassFrostSliderChanged(_ sender: NSSlider) {
        let val = sender.doubleValue.rounded()
        BrowserSettings.shared.refractiveGlassFrost = val
        refractiveFrostValueLabel?.stringValue = String(format: "%.0f pt", val)
    }

    @objc private func openSafariumInspect() {
        onOpenURL?(InspectPageURL.rootURL)
    }

    @objc private func openSafariumRemoteDebugging() {
        onOpenURL?(InspectPageURL.remoteDebuggingURL)
    }

    // MARK: - Classic Safari Two-Column Form Builders (Modernized with macOS 27 Glass Controls)

    private func makeFormPaneBase(helpTopic: String, showHelp: Bool = true) -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        if showHelp {
            let helpBtn = TahoeHelpButton(topic: helpTopic) { [weak self] topic in
                self?.presentInfoSheet(
                    title: topic,
                    message: "Configure \(topic.lowercased()) for Safarium. Changes are saved automatically to your local profile."
                )
            }
            pane.addSubview(helpBtn)
            NSLayoutConstraint.activate([
                helpBtn.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -18),
                helpBtn.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -14)
            ])
        }
        return pane
    }

    private func makeFormStack(in pane: NSView, topInset: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: topInset)
        ])
        return stack
    }

    private func addFormRow(_ row: NSView, to stack: NSStackView, spacingAfter: CGFloat) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if spacingAfter > 0 {
            stack.setCustomSpacing(spacingAfter, after: row)
        }
    }

    private func makeTwoColumnRow(
        label: String?,
        control: NSView,
        labelFont: NSFont = NSFont.systemFont(ofSize: 13.0),
        labelColor: NSColor = .labelColor,
        labelAlignTop: Bool = false,
        minHeight: CGFloat = 24
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)

        if let label, !label.isEmpty {
            let lbl = NSTextField(labelWithString: label)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.font = labelFont
            lbl.textColor = labelColor
            lbl.alignment = .right
            row.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.trailingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.labelSpineX),
                lbl.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 16),
                labelAlignTop
                    ? lbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 2)
                    : lbl.centerYAnchor.constraint(equalTo: control.centerYAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Self.labelSpineX + 12),
            control.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -24),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        return row
    }

    private func makeFormPopupRow(
        label: String,
        options: [String],
        key: String,
        defaultIndex: Int,
        popupWidth: CGFloat = 296,
        leadingSymbol: String? = nil
    ) -> NSView {
        makeFormPopupRowWithControl(
            label: label,
            options: options,
            key: key,
            defaultIndex: defaultIndex,
            popupWidth: popupWidth,
            leadingSymbol: leadingSymbol
        ).0
    }

    private func makeFormPopupRowWithControl(
        label: String,
        options: [String],
        key: String,
        defaultIndex: Int,
        popupWidth: CGFloat = 296,
        leadingSymbol: String? = nil,
        onChange: ((Int) -> Void)? = nil
    ) -> (NSView, NSPopUpButton) {
        let popup = makeCapsulePopup(options: options, selectedIndex: prefInt(key, default: defaultIndex)) { idx in
            BrowserSettings.shared.set(idx, forKey: key)
            onChange?(idx)
        }
        if let sym = leadingSymbol, let firstItem = popup.item(at: 0) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            firstItem.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }
        popup.widthAnchor.constraint(equalToConstant: popupWidth).isActive = true
        return (makeTwoColumnRow(label: label, control: popup, minHeight: 26), popup)
    }

    private func makeFormCheckboxRow(
        label: String?,
        title: String,
        caption: String?,
        key: String,
        defaultValue: Bool,
        onChange: ((Bool) -> Void)? = nil
    ) -> NSView {
        let check = TahoeBoundCheckbox(title: title, initialValue: prefBool(key, default: defaultValue)) { checked in
            BrowserSettings.shared.set(checked, forKey: key)
            onChange?(checked)
        }

        if let caption, !caption.isEmpty {
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(check)

            let cap = NSTextField(wrappingLabelWithString: caption)
            cap.translatesAutoresizingMaskIntoConstraints = false
            cap.font = NSFont.systemFont(ofSize: 11.5)
            cap.textColor = .secondaryLabelColor
            wrap.addSubview(cap)

            NSLayoutConstraint.activate([
                check.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                check.topAnchor.constraint(equalTo: wrap.topAnchor),
                check.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),

                cap.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 20),
                cap.topAnchor.constraint(equalTo: check.bottomAnchor, constant: 3),
                cap.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                cap.widthAnchor.constraint(lessThanOrEqualToConstant: 410),
                cap.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
            ])
            return makeTwoColumnRow(label: label, control: wrap, labelAlignTop: true, minHeight: 20)
        }

        return makeTwoColumnRow(label: label, control: check, minHeight: 20)
    }

    private func makeCheckboxWithTrailingGlassButtonRow(
        label: String?,
        title: String,
        key: String,
        defaultValue: Bool,
        buttonTitle: String,
        buttonLeadingOffset: CGFloat,
        onAction: @escaping () -> Void
    ) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let check = TahoeBoundCheckbox(title: title, initialValue: prefBool(key, default: defaultValue)) { checked in
            BrowserSettings.shared.set(checked, forKey: key)
        }
        let btn = TahoeActionGlassButton(title: buttonTitle, onClick: onAction)

        wrap.addSubview(check)
        wrap.addSubview(btn)

        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            check.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            check.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),

            btn.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: buttonLeadingOffset),
            btn.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            btn.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor)
        ])

        return makeTwoColumnRow(label: label, control: wrap, minHeight: 24)
    }

    private func makeCheckboxWithInlinePopupRow(
        label: String?,
        title: String,
        switchKey: String,
        switchDefault: Bool,
        popupOptions: [String],
        popupKey: String,
        popupDefaultIndex: Int,
        onToggle: @escaping (Bool) -> Void
    ) -> (NSView, NSPopUpButton) {
        let check = TahoeBoundCheckbox(title: title, initialValue: prefBool(switchKey, default: switchDefault)) { checked in
            BrowserSettings.shared.set(checked, forKey: switchKey)
            onToggle(checked)
        }
        let pop = makeCapsulePopup(options: popupOptions, selectedIndex: prefInt(popupKey, default: popupDefaultIndex)) { idx in
            BrowserSettings.shared.set(idx, forKey: popupKey)
        }
        let hStack = NSStackView(views: [check, pop])
        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 10
        hStack.translatesAutoresizingMaskIntoConstraints = false
        return (makeTwoColumnRow(label: label, control: hStack, minHeight: 24), pop)
    }

    private func makeGlassButton(title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let btn = NSButton(title: title, target: target, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        if #available(macOS 26.0, *) {
            btn.bezelStyle = .glass
            btn.borderShape = .capsule
        } else {
            btn.bezelStyle = .rounded
        }
        return btn
    }

    private func makeCapsulePopup(
        options: [String],
        selectedIndex: Int,
        onChange: @escaping (Int) -> Void
    ) -> NSPopUpButton {
        let pop = TahoeBoundPopUpButton(options: options, selectedIndex: selectedIndex, onChange: onChange)
        pop.translatesAutoresizingMaskIntoConstraints = false
        pop.font = NSFont.systemFont(ofSize: 13.0)
        if #available(macOS 26.0, *) {
            pop.borderShape = .capsule
        }
        return pop
    }

    private func makeSidebarSectionHeader(_ title: String, topPad: CGFloat) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let lbl = NSTextField(labelWithString: title)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        wrap.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            lbl.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -8),
            lbl.topAnchor.constraint(equalTo: wrap.topAnchor, constant: topPad),
            lbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4)
        ])
        return wrap
    }

    private func makeMutedRowLabel(_ text: String) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let lbl = NSTextField(wrappingLabelWithString: text)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: 12.0)
        lbl.textColor = .secondaryLabelColor
        wrap.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            lbl.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -10),
            lbl.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 12),
            lbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10)
        ])
        return wrap
    }

    private func presentInfoSheet(title: String, message: String) {
        guard let win = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: win)
    }

    // MARK: - UserDefaults Helpers

    func prefBool(_ key: String, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    func prefInt(_ key: String, default defaultValue: Int) -> Int {
        if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
        return UserDefaults.standard.integer(forKey: key)
    }
}

// MARK: - Bound Controls

private final class TahoeBoundCheckbox: NSButton {
    private let onChange: (Bool) -> Void

    init(title: String, initialValue: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        setButtonType(.switch)
        translatesAutoresizingMaskIntoConstraints = false
        self.title = title
        font = NSFont.systemFont(ofSize: 13.0)
        state = initialValue ? .on : .off
        target = self
        action = #selector(toggled)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func toggled() {
        onChange(state == .on)
    }
}

private final class TahoeBoundPopUpButton: NSPopUpButton {
    private let onChange: (Int) -> Void

    init(options: [String], selectedIndex: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: options)
        selectItem(at: max(0, min(options.count - 1, selectedIndex)))
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func changed() {
        onChange(indexOfSelectedItem)
    }
}

private final class TahoeActionGlassButton: NSButton {
    private let onClick: () -> Void

    init(title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.title = title
        font = NSFont.systemFont(ofSize: 13.0)
        if #available(macOS 26.0, *) {
            bezelStyle = .glass
            borderShape = .capsule
        } else {
            bezelStyle = .rounded
        }
        target = self
        action = #selector(tapped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func tapped() { onClick() }
}

private final class TahoeHelpButton: NSButton {
    private let topic: String
    private let onHelp: (String) -> Void

    init(topic: String, onHelp: @escaping (String) -> Void) {
        self.topic = topic
        self.onHelp = onHelp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .helpButton
        title = ""
        target = self
        action = #selector(tapped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func tapped() { onHelp(topic) }
}

// MARK: - Modern macOS 27 Glass Surfaces & Subviews

private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class SelectableSettingsRowView: NSView {
    private let isSelected: Bool
    private let onSelect: () -> Void

    init(isSelected: Bool, onSelect: @escaping () -> Void) {
        self.isSelected = isSelected
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8.0
        layer?.cornerCurve = .continuous
        applyBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        for sub in subviews where sub is NSPopUpButton || sub is NSButton {
            if sub.frame.contains(pt) {
                super.mouseDown(with: event)
                return
            }
        }
        onSelect()
    }
}

private final class SettingsHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.08)).cgColor
    }
}

/// Modern macOS 27 continuous-corner glass container box replacing Safari's legacy flat sharp-corner boxes.
private final class ModernGlassPanelBox: NSView {
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
        layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.white.withAlphaComponent(0.75)).cgColor
        layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.09)).cgColor
    }
}

private final class AddExtensionsHeaderRow: NSView {
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9.0
        layer?.cornerCurve = .continuous

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.image = NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: "Add Extensions")?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: "Add Extensions")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

private final class ExtensionSidebarRowView: NSView {
    var onSelect: ((String) -> Void)?
    var onToggleEnabled: ((String, Bool) -> Void)?

    private let item: BrowserExtensionItem
    private let isSelected: Bool
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(item: BrowserExtensionItem, isSelected: Bool) {
        self.item = item
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8.5
        layer?.cornerCurve = .continuous

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.state = item.enabled ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(checkboxChanged(_:))
        addSubview(checkbox)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 5.5
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        if let icon = item.icon {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: item.name)
            iconView.contentTintColor = isSelected ? .white : .secondaryLabelColor
        }
        iconView.alphaValue = item.enabled ? 1.0 : 0.45
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = item.name
        nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: isSelected ? .medium : .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),

            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 18),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 21),
            iconView.heightAnchor.constraint(equalToConstant: 21),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                nameLabel.textColor = .white
            } else if isHovered {
                layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)).cgColor
                nameLabel.textColor = .labelColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                nameLabel.textColor = .labelColor
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if checkbox.frame.insetBy(dx: -4, dy: -4).contains(pt) {
            super.mouseDown(with: event)
            return
        }
        onSelect?(item.id)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        onToggleEnabled?(item.id, sender.state == .on)
    }
}

private final class WebsiteCategoryRowView: NSView {
    private let category: SafariSettingsWindowController.WebsiteCategory
    private let isSelected: Bool
    private let onSelect: (SafariSettingsWindowController.WebsiteCategory) -> Void
    private var isHovered = false
    private var tracking: NSTrackingArea?
    private let label = NSTextField(labelWithString: "")

    init(
        category: SafariSettingsWindowController.WebsiteCategory,
        isSelected: Bool,
        onSelect: @escaping (SafariSettingsWindowController.WebsiteCategory) -> Void
    ) {
        self.category = category
        self.isSelected = isSelected
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8.5
        layer?.cornerCurve = .continuous

        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5.5
        badge.layer?.cornerCurve = .continuous
        badge.layer?.backgroundColor = category.badgeColor.cgColor
        addSubview(badge)

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        iv.image = NSImage(systemSymbolName: category.symbolName, accessibilityDescription: category.rawValue)?
            .withSymbolConfiguration(cfg)
        iv.contentTintColor = .white
        badge.addSubview(iv)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = category.rawValue
        label.font = NSFont.systemFont(ofSize: 12.5, weight: isSelected ? .medium : .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),

            iv.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
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
    override func mouseDown(with event: NSEvent) { onSelect(category) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                label.textColor = .white
            } else if isHovered {
                layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)).cgColor
                label.textColor = .labelColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                label.textColor = .labelColor
            }
        }
    }
}

private final class TabLayoutPreviewCard: NSView {
    enum LayoutStyle { case separate, compact, vertical, toolbarDefault, toolbarLiquidGlass }

    private let onSelect: () -> Void
    private let previewFrame = NSView()
    private let titleLabel: NSTextField

    var isSelected: Bool { didSet { updateBorder() } }

    init(title: String, style: LayoutStyle, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        previewFrame.translatesAutoresizingMaskIntoConstraints = false
        previewFrame.wantsLayer = true
        previewFrame.layer?.cornerRadius = 10.0
        previewFrame.layer?.cornerCurve = .continuous
        previewFrame.layer?.masksToBounds = true
        addSubview(previewFrame)

        buildMiniatureArtwork(inside: previewFrame, style: style)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
        titleLabel.alignment = .center
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 88),
            previewFrame.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewFrame.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewFrame.topAnchor.constraint(equalTo: topAnchor),
            previewFrame.heightAnchor.constraint(equalToConstant: 62),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: previewFrame.bottomAnchor, constant: 5),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildMiniatureArtwork(inside host: NSView, style: LayoutStyle) {
        let wall = NSView()
        wall.translatesAutoresizingMaskIntoConstraints = false
        wall.wantsLayer = true
        let grad = CAGradientLayer()
        grad.colors = [
            NSColor(srgbRed: 0.25, green: 0.36, blue: 0.56, alpha: 1.0).cgColor,
            NSColor(srgbRed: 0.68, green: 0.50, blue: 0.44, alpha: 1.0).cgColor
        ]
        grad.startPoint = CGPoint(x: 0, y: 1)
        grad.endPoint = CGPoint(x: 1, y: 0)
        grad.frame = NSRect(x: 0, y: 0, width: 100, height: 70)
        wall.layer?.addSublayer(grad)
        host.addSubview(wall)

        let miniWin = NSView()
        miniWin.translatesAutoresizingMaskIntoConstraints = false
        miniWin.wantsLayer = true
        miniWin.layer?.backgroundColor = NSColor(white: 0.96, alpha: 0.96).cgColor
        miniWin.layer?.cornerRadius = 6.0
        miniWin.layer?.cornerCurve = .continuous
        miniWin.layer?.masksToBounds = true
        host.addSubview(miniWin)

        let dots = NSStackView()
        dots.orientation = .horizontal
        dots.spacing = 2.5
        dots.translatesAutoresizingMaskIntoConstraints = false
        for col in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen] {
            let d = NSView()
            d.translatesAutoresizingMaskIntoConstraints = false
            d.wantsLayer = true
            d.layer?.backgroundColor = col.withAlphaComponent(0.9).cgColor
            d.layer?.cornerRadius = 2.0
            d.widthAnchor.constraint(equalToConstant: 4).isActive = true
            d.heightAnchor.constraint(equalToConstant: 4).isActive = true
            dots.addArrangedSubview(d)
        }
        miniWin.addSubview(dots)

        let pageArea = NSView()
        pageArea.translatesAutoresizingMaskIntoConstraints = false
        pageArea.wantsLayer = true
        pageArea.layer?.backgroundColor = NSColor.white.cgColor
        miniWin.addSubview(pageArea)

        switch style {
        case .compact:
            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.white.cgColor
            pill.layer?.cornerRadius = 3.5
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
            miniWin.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: miniWin.centerXAnchor, constant: 6),
                pill.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 5),
                pill.widthAnchor.constraint(equalToConstant: 42),
                pill.heightAnchor.constraint(equalToConstant: 8),

                pageArea.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                pageArea.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                pageArea.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 18),
                pageArea.bottomAnchor.constraint(equalTo: miniWin.bottomAnchor)
            ])
        case .toolbarDefault:
            // Opaque solid toolbar clearly separated from colorful webpage content below
            let hero = NSView()
            hero.translatesAutoresizingMaskIntoConstraints = false
            hero.wantsLayer = true
            let heroGrad = CAGradientLayer()
            heroGrad.colors = [
                NSColor(srgbRed: 0.10, green: 0.24, blue: 0.52, alpha: 1.0).cgColor,
                NSColor(srgbRed: 0.22, green: 0.62, blue: 0.86, alpha: 1.0).cgColor,
                NSColor(srgbRed: 0.92, green: 0.44, blue: 0.28, alpha: 1.0).cgColor
            ]
            heroGrad.startPoint = CGPoint(x: 0, y: 1)
            heroGrad.endPoint = CGPoint(x: 1, y: 0)
            heroGrad.frame = NSRect(x: 0, y: 0, width: 88, height: 22)
            hero.layer?.addSublayer(heroGrad)
            pageArea.addSubview(hero)

            let hairline = NSView()
            hairline.translatesAutoresizingMaskIntoConstraints = false
            hairline.wantsLayer = true
            hairline.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
            miniWin.addSubview(hairline)

            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.white.cgColor
            pill.layer?.cornerRadius = 3.5
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
            miniWin.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: miniWin.centerXAnchor, constant: 6),
                pill.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 5),
                pill.widthAnchor.constraint(equalToConstant: 42),
                pill.heightAnchor.constraint(equalToConstant: 8),

                hairline.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                hairline.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 18),
                hairline.heightAnchor.constraint(equalToConstant: 0.5),

                pageArea.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                pageArea.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                pageArea.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 18.5),
                pageArea.bottomAnchor.constraint(equalTo: miniWin.bottomAnchor),

                hero.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
                hero.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
                hero.topAnchor.constraint(equalTo: pageArea.topAnchor),
                hero.heightAnchor.constraint(equalToConstant: 20)
            ])
        case .toolbarLiquidGlass:
            // Full-bleed vibrant webpage hero scrolling right behind a real NSGlassEffectView toolbar
            let hero = NSView()
            hero.translatesAutoresizingMaskIntoConstraints = false
            hero.wantsLayer = true
            let heroGrad = CAGradientLayer()
            heroGrad.colors = [
                NSColor(srgbRed: 0.08, green: 0.18, blue: 0.44, alpha: 1.0).cgColor,
                NSColor(srgbRed: 0.16, green: 0.58, blue: 0.88, alpha: 1.0).cgColor,
                NSColor(srgbRed: 0.94, green: 0.42, blue: 0.26, alpha: 1.0).cgColor
            ]
            heroGrad.startPoint = CGPoint(x: 0, y: 1)
            heroGrad.endPoint = CGPoint(x: 1, y: 0)
            heroGrad.frame = NSRect(x: 0, y: 0, width: 88, height: 34)
            hero.layer?.addSublayer(heroGrad)

            // High-contrast bright orb + dark band inside hero so real glass refraction is unmistakable
            let orb = NSView()
            orb.translatesAutoresizingMaskIntoConstraints = false
            orb.wantsLayer = true
            orb.layer?.backgroundColor = NSColor(srgbRed: 1.0, green: 0.86, blue: 0.42, alpha: 0.92).cgColor
            orb.layer?.cornerRadius = 7.0
            hero.addSubview(orb)

            let accentStripe = NSView()
            accentStripe.translatesAutoresizingMaskIntoConstraints = false
            accentStripe.wantsLayer = true
            accentStripe.layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.08, blue: 0.16, alpha: 0.55).cgColor
            accentStripe.layer?.cornerRadius = 2.0
            hero.addSubview(accentStripe)
            pageArea.addSubview(hero)

            let glassBar: NSView
            if #available(macOS 26.0, *) {
                let gv = NSGlassEffectView()
                gv.style = .clear
                gv.cornerRadius = 5.0
                glassBar = gv
            } else {
                let v = NSVisualEffectView()
                v.material = .hudWindow
                v.blendingMode = .withinWindow
                v.state = .active
                glassBar = v
            }
            glassBar.translatesAutoresizingMaskIntoConstraints = false
            glassBar.wantsLayer = true
            miniWin.addSubview(glassBar)

            // Subtle top specular glass rim
            let topRim = NSView()
            topRim.translatesAutoresizingMaskIntoConstraints = false
            topRim.wantsLayer = true
            topRim.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            miniWin.addSubview(topRim)

            miniWin.addSubview(dots, positioned: .above, relativeTo: topRim)

            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.36).cgColor
            pill.layer?.cornerRadius = 3.5
            pill.layer?.borderWidth = 0.6
            pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.75).cgColor
            miniWin.addSubview(pill)

            NSLayoutConstraint.activate([
                pageArea.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                pageArea.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                pageArea.topAnchor.constraint(equalTo: miniWin.topAnchor),
                pageArea.bottomAnchor.constraint(equalTo: miniWin.bottomAnchor),

                hero.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
                hero.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
                hero.topAnchor.constraint(equalTo: pageArea.topAnchor),
                hero.heightAnchor.constraint(equalToConstant: 34),

                orb.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -10),
                orb.topAnchor.constraint(equalTo: hero.topAnchor, constant: 6),
                orb.widthAnchor.constraint(equalToConstant: 14),
                orb.heightAnchor.constraint(equalToConstant: 14),

                accentStripe.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 10),
                accentStripe.topAnchor.constraint(equalTo: hero.topAnchor, constant: 14),
                accentStripe.widthAnchor.constraint(equalToConstant: 36),
                accentStripe.heightAnchor.constraint(equalToConstant: 4),

                glassBar.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor, constant: 1),
                glassBar.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor, constant: -1),
                glassBar.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 1),
                glassBar.heightAnchor.constraint(equalToConstant: 18),

                topRim.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                topRim.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                topRim.topAnchor.constraint(equalTo: miniWin.topAnchor),
                topRim.heightAnchor.constraint(equalToConstant: 0.75),

                pill.centerXAnchor.constraint(equalTo: miniWin.centerXAnchor, constant: 6),
                pill.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 5),
                pill.widthAnchor.constraint(equalToConstant: 42),
                pill.heightAnchor.constraint(equalToConstant: 8)
            ])
        case .separate:
            let addr = NSView()
            addr.translatesAutoresizingMaskIntoConstraints = false
            addr.wantsLayer = true
            addr.layer?.backgroundColor = NSColor.white.cgColor
            addr.layer?.cornerRadius = 3.5
            addr.layer?.borderWidth = 0.5
            addr.layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
            miniWin.addSubview(addr)

            let strip = NSView()
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.wantsLayer = true
            strip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
            miniWin.addSubview(strip)

            NSLayoutConstraint.activate([
                addr.centerXAnchor.constraint(equalTo: miniWin.centerXAnchor, constant: 5),
                addr.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 5),
                addr.widthAnchor.constraint(equalToConstant: 36),
                addr.heightAnchor.constraint(equalToConstant: 7),

                strip.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                strip.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 16),
                strip.heightAnchor.constraint(equalToConstant: 8),

                pageArea.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                pageArea.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                pageArea.topAnchor.constraint(equalTo: strip.bottomAnchor),
                pageArea.bottomAnchor.constraint(equalTo: miniWin.bottomAnchor)
            ])
        case .vertical:
            let side = NSView()
            side.translatesAutoresizingMaskIntoConstraints = false
            side.wantsLayer = true
            side.layer?.backgroundColor = NSColor(white: 0.90, alpha: 1.0).cgColor
            miniWin.addSubview(side)

            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.white.cgColor
            pill.layer?.cornerRadius = 3.5
            pill.layer?.borderWidth = 0.5
            pill.layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
            miniWin.addSubview(pill)

            NSLayoutConstraint.activate([
                side.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor),
                side.topAnchor.constraint(equalTo: miniWin.topAnchor),
                side.bottomAnchor.constraint(equalTo: miniWin.bottomAnchor),
                side.widthAnchor.constraint(equalToConstant: 24),

                pill.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 6),
                pill.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor, constant: -6),
                pill.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 5),
                pill.heightAnchor.constraint(equalToConstant: 7),

                pageArea.leadingAnchor.constraint(equalTo: side.trailingAnchor),
                pageArea.trailingAnchor.constraint(equalTo: miniWin.trailingAnchor),
                pageArea.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 16),
                pageArea.bottomAnchor.constraint(equalTo: miniWin.bottomAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            wall.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            wall.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            wall.topAnchor.constraint(equalTo: host.topAnchor),
            wall.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            miniWin.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 7),
            miniWin.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -4),
            miniWin.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            miniWin.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: 4),

            dots.leadingAnchor.constraint(equalTo: miniWin.leadingAnchor, constant: 5),
            dots.topAnchor.constraint(equalTo: miniWin.topAnchor, constant: 7)
        ])
    }

    override func mouseDown(with event: NSEvent) { onSelect() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                previewFrame.layer?.borderWidth = 2.5
                previewFrame.layer?.borderColor = NSColor.controlAccentColor.cgColor
                titleLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
                titleLabel.textColor = .labelColor
            } else {
                previewFrame.layer?.borderWidth = 0.75
                previewFrame.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
                titleLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
                titleLabel.textColor = .secondaryLabelColor
            }
        }
    }
}

private final class PermissionWarningCardView: NSView {
    private let isBroadAccess: Bool
    private let handIcon = NSImageView()
    private let headlineLabel: NSTextField
    private let detailLabel: NSTextField

    init(headline: String, detail: String, isBroadAccess: Bool) {
        self.isBroadAccess = isBroadAccess
        self.headlineLabel = NSTextField(wrappingLabelWithString: headline)
        self.detailLabel = NSTextField(wrappingLabelWithString: detail)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11.0
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        handIcon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        handIcon.image = NSImage(
            systemSymbolName: isBroadAccess ? "hand.raised.fill" : "checkmark.shield.fill",
            accessibilityDescription: "Permissions"
        )?.withSymbolConfiguration(cfg)
        addSubview(handIcon)

        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        headlineLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        addSubview(headlineLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 12.0)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            handIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            handIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            handIcon.widthAnchor.constraint(equalToConstant: 30),
            handIcon.heightAnchor.constraint(equalToConstant: 30),

            headlineLabel.leadingAnchor.constraint(equalTo: handIcon.trailingAnchor, constant: 12),
            headlineLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            headlineLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            detailLabel.leadingAnchor.constraint(equalTo: headlineLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: headlineLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: 4),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isBroadAccess {
                if isDark {
                    layer?.backgroundColor = NSColor(srgbRed: 0.36, green: 0.28, blue: 0.08, alpha: 0.55).cgColor
                    layer?.borderColor = NSColor(srgbRed: 0.96, green: 0.80, blue: 0.36, alpha: 0.25).cgColor
                    let warm = NSColor(srgbRed: 0.98, green: 0.89, blue: 0.62, alpha: 1.0)
                    handIcon.contentTintColor = warm
                    headlineLabel.textColor = warm
                    detailLabel.textColor = warm.withAlphaComponent(0.84)
                } else {
                    layer?.backgroundColor = NSColor(srgbRed: 0.992, green: 0.945, blue: 0.776, alpha: 0.92).cgColor
                    layer?.borderColor = NSColor(srgbRed: 0.82, green: 0.68, blue: 0.24, alpha: 0.35).cgColor
                    let brown = NSColor(srgbRed: 0.345, green: 0.275, blue: 0.067, alpha: 1.0)
                    handIcon.contentTintColor = NSColor(srgbRed: 0.44, green: 0.34, blue: 0.08, alpha: 1.0)
                    headlineLabel.textColor = brown
                    detailLabel.textColor = brown.withAlphaComponent(0.90)
                }
            } else {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.07 : 0.04).cgColor
                layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
                handIcon.contentTintColor = .secondaryLabelColor
                headlineLabel.textColor = .labelColor
                detailLabel.textColor = .secondaryLabelColor
            }
        }
    }
}

private final class ExtensionShortcutRowView: NSView {
    private let onClear: () -> Void
    private let badgeBox = NSView()

    init(descriptionText: String, shortcutText: String?, onClear: @escaping () -> Void) {
        self.onClear = onClear
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let descLbl = NSTextField(labelWithString: descriptionText)
        descLbl.translatesAutoresizingMaskIntoConstraints = false
        descLbl.font = NSFont.systemFont(ofSize: 12.5)
        descLbl.textColor = .labelColor
        descLbl.lineBreakMode = .byTruncatingTail
        addSubview(descLbl)

        badgeBox.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.wantsLayer = true
        badgeBox.layer?.cornerRadius = 6.0
        badgeBox.layer?.cornerCurve = .continuous
        badgeBox.layer?.borderWidth = 0.5
        addSubview(badgeBox)

        let keyLbl = NSTextField(labelWithString: shortcutText ?? "None")
        keyLbl.translatesAutoresizingMaskIntoConstraints = false
        keyLbl.font = NSFont.systemFont(ofSize: 12.0, weight: .medium)
        keyLbl.textColor = shortcutText != nil ? .labelColor : .tertiaryLabelColor
        badgeBox.addSubview(keyLbl)

        let clearBtn = NSButton()
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear Shortcut")?
            .withSymbolConfiguration(cfg)
        clearBtn.contentTintColor = .tertiaryLabelColor
        clearBtn.isHidden = (shortcutText == nil)
        clearBtn.target = self
        clearBtn.action = #selector(handleClear)
        addSubview(clearBtn)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            descLbl.leadingAnchor.constraint(equalTo: leadingAnchor),
            descLbl.centerYAnchor.constraint(equalTo: centerYAnchor),
            descLbl.trailingAnchor.constraint(lessThanOrEqualTo: badgeBox.leadingAnchor, constant: -12),

            clearBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -56),
            clearBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearBtn.widthAnchor.constraint(equalToConstant: 16),
            clearBtn.heightAnchor.constraint(equalToConstant: 16),

            badgeBox.trailingAnchor.constraint(equalTo: clearBtn.leadingAnchor, constant: -8),
            badgeBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
            badgeBox.heightAnchor.constraint(equalToConstant: 22),

            keyLbl.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 8),
            keyLbl.trailingAnchor.constraint(equalTo: badgeBox.trailingAnchor, constant: -8),
            keyLbl.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        badgeBox.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.045)).cgColor
        badgeBox.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.10)).cgColor
    }

    @objc private func handleClear() { onClear() }
}

// MARK: - Manifest.json Metadata Parser (Author, Permissions, Shortcuts)

struct ExtensionManifestMetadata {
    struct ShortcutItem {
        let commandName: String
        let descriptionText: String
        let formattedShortcut: String
    }

    let author: String?
    let hasBroadWebAccess: Bool
    let permissionHeadline: String
    let permissionDetail: String
    let shortScopeLabel: String
    let shortcuts: [ShortcutItem]

    nonisolated(unsafe) private static var parseCache: [String: (stamp: Date?, meta: ExtensionManifestMetadata)] = [:]

    /// Cached per install path + manifest modification date, so reopening the Websites pane does not re-read every manifest.
    static func parse(fromInstallPath installPath: String) -> ExtensionManifestMetadata {
        let manifestPath = (installPath as NSString).appendingPathComponent("manifest.json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: manifestPath))?[.modificationDate] as? Date
        if let hit = parseCache[installPath], hit.stamp == stamp { return hit.meta }
        let meta = parseUncached(fromInstallPath: installPath)
        parseCache[installPath] = (stamp, meta)
        return meta
    }

    static func parseUncached(fromInstallPath installPath: String) -> ExtensionManifestMetadata {
        let fallback = ExtensionManifestMetadata(
            author: nil,
            hasBroadWebAccess: false,
            permissionHeadline: "This extension has limited webpage access.",
            permissionDetail: "It only interacts with webpages when you click its toolbar icon.",
            shortScopeLabel: "When clicked",
            shortcuts: []
        )
        guard !installPath.isEmpty else { return fallback }
        let manifestURL = URL(fileURLWithPath: installPath).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fallback
        }

        let messages = loadLocalizedMessages(installPath: installPath, manifest: json)

        func resolveMsg(_ raw: String?) -> String {
            guard let raw, !raw.isEmpty else { return "" }
            guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else { return raw }
            let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
            return messages[key] ?? raw
        }

        var author: String?
        if let aStr = json["author"] as? String {
            let resolved = resolveMsg(aStr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty { author = resolved }
        } else if let aDict = json["author"] as? [String: Any], let email = aDict["email"] as? String {
            author = email
        }

        var hosts: [String] = []
        if let hp = json["host_permissions"] as? [String] { hosts.append(contentsOf: hp) }
        if let cs = json["content_scripts"] as? [[String: Any]] {
            for entry in cs {
                if let matches = entry["matches"] as? [String] {
                    hosts.append(contentsOf: matches)
                }
            }
        }
        let perms = Set((json["permissions"] as? [String]) ?? [])
        for p in perms where p.contains("://") || p == "<all_urls>" {
            hosts.append(p)
        }

        let hasAllUrls = hosts.contains { h in
            h == "<all_urls>" || h.contains("*://*/*") || h.contains("http://*/*") || h.contains("https://*/*")
        }
        let hasTabsOrHistory = perms.contains("tabs") || perms.contains("history") || perms.contains("webNavigation") || perms.contains("webRequest")

        let headline: String
        let detail: String
        let scopeLabel: String
        let broad: Bool

        if hasAllUrls {
            broad = true
            headline = "This extension can read and alter webpages you visit and see your browsing history on all websites."
            detail = "This includes sensitive information from webpages, including passwords, phone numbers, and credit cards."
            scopeLabel = "All Websites (Allow)"
        } else if !hosts.isEmpty {
            broad = true
            let uniqueDomains = Array(Set(hosts.compactMap { extractHostLabel($0) })).sorted()
            let preview = uniqueDomains.prefix(3).joined(separator: ", ")
            let suffix = uniqueDomains.count > 3 ? " and \(uniqueDomains.count - 3) more" : ""
            headline = "This extension can read and alter webpages on \(preview.isEmpty ? "selected websites" : preview + suffix)."
            detail = "This includes sensitive information from those webpages, including passwords, phone numbers, and credit cards."
            scopeLabel = uniqueDomains.isEmpty ? "Selected Websites" : "\(uniqueDomains.count) Website(s)"
        } else if hasTabsOrHistory || perms.contains("scripting") {
            broad = true
            headline = "This extension can see your open tabs and interact with webpages you visit."
            detail = "This may include page titles, URLs, and content on the active tab when invoked."
            scopeLabel = "Active Tab"
        } else {
            broad = false
            headline = "This extension does not require broad access to your webpages."
            detail = "It only runs when you explicitly activate it from the Safarium toolbar."
            scopeLabel = "When Clicked"
        }

        var shortcuts: [ShortcutItem] = []
        if let commands = json["commands"] as? [String: Any] {
            for (cmdName, rawVal) in commands.sorted(by: { $0.key < $1.key }) {
                guard let dict = rawVal as? [String: Any] else { continue }
                let rawDesc = resolveMsg(dict["description"] as? String)
                let cleanDesc: String
                if !rawDesc.isEmpty {
                    cleanDesc = rawDesc
                } else if cmdName == "_execute_action" || cmdName == "_execute_browser_action" {
                    cleanDesc = "Open extension popup"
                } else {
                    cleanDesc = cmdName.replacingOccurrences(of: "_", with: " ").capitalized
                }
                let suggested = dict["suggested_key"] as? [String: Any]
                let rawKey = (suggested?["mac"] as? String) ?? (suggested?["default"] as? String) ?? ""
                if !rawKey.isEmpty {
                    shortcuts.append(ShortcutItem(
                        commandName: cmdName,
                        descriptionText: cleanDesc,
                        formattedShortcut: formatMacShortcut(rawKey)
                    ))
                }
            }
        }

        return ExtensionManifestMetadata(
            author: author,
            hasBroadWebAccess: broad,
            permissionHeadline: headline,
            permissionDetail: detail,
            shortScopeLabel: scopeLabel,
            shortcuts: shortcuts
        )
    }

    static func loadLocalizedMessages(installPath: String, manifest: [String: Any]) -> [String: String] {
        let defaultLocale = (manifest["default_locale"] as? String) ?? "en"
        for loc in [defaultLocale, "en", "en_US"] {
            let url = URL(fileURLWithPath: installPath).appendingPathComponent("_locales/\(loc)/messages.json")
            guard let data = try? Data(contentsOf: url),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            var out: [String: String] = [:]
            for (k, v) in dict {
                if let entry = v as? [String: Any], let msg = entry["message"] as? String {
                    out[k.lowercased()] = msg
                }
            }
            return out
        }
        return [:]
    }

    static func extractHostLabel(_ pattern: String) -> String? {
        if let idx = pattern.range(of: "://") {
            let hostPart = pattern[idx.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            let cleaned = hostPart.replacingOccurrences(of: "*.", with: "")
            return cleaned.isEmpty || cleaned == "*" ? nil : cleaned
        }
        return nil
    }

    static func formatMacShortcut(_ raw: String) -> String {
        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var mods = ""
        var key = ""
        for p in parts {
            switch p.lowercased() {
            case "ctrl", "control", "macctrl": mods += "⌃"
            case "alt", "option": mods += "⌥"
            case "shift": mods += "⇧"
            case "command", "cmd": mods += "⌘"
            default: key = p.uppercased()
            }
        }
        return mods + key
    }
}
