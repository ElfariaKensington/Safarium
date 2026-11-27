import AppKit
import Darwin
import LocalAuthentication
import UniformTypeIdentifiers

/// Native macOS 27.3 Safari `NSWindow` with attached unified `NSToolbar` (`toolbarStyle = .unified`)
/// so AppKit natively renders macOS 27 Tahoe's glossy 3D 16pt traffic light orbs at `(18, 18), (41, 18), (64, 18)`
/// (`23 pt` pitch), exact `52.0 pt` unified titlebar chrome, and artifact-free `26 pt` continuous corners.
final class SafariWindow: NSWindow, NSDraggingDestination {
    var onDropURL: ((URL, Bool) -> Void)?
    var onPerformKeyEquivalent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onPerformKeyEquivalent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.extractDroppedURL(from: sender.draggingPasteboard) else { return false }
        let openInNewTab = NSEvent.modifierFlags.contains(.command)
        onDropURL?(url, openInNewTab)
        return true
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
}

/// Optional Desktop 2 placement helper (`SAFARIUM_DESKTOP=2`) using SkyLight private APIs when explicitly requested.
enum DesktopSpacePlacer {
    typealias MainConnectionIDFunc = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> CFArray?
    typealias MoveWindowsToManagedSpaceFunc = @convention(c) (Int32, CFArray, UInt64) -> Void

    static func moveWindowToDesktopIfRequested(_ window: NSWindow) {
        guard let targetStr = ProcessInfo.processInfo.environment["SAFARIUM_DESKTOP"],
              let targetIndex = Int(targetStr),
              targetIndex >= 2 else {
            return
        }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return
        }
        defer { dlclose(handle) }

        guard let pMainConn = dlsym(handle, "CGSMainConnectionID"),
              let pCopySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
              let pMoveWindows = dlsym(handle, "CGSMoveWindowsToManagedSpace") else {
            return
        }

        let mainConn = unsafeBitCast(pMainConn, to: MainConnectionIDFunc.self)()
        let copySpaces = unsafeBitCast(pCopySpaces, to: CopyManagedDisplaySpacesFunc.self)
        let moveWindows = unsafeBitCast(pMoveWindows, to: MoveWindowsToManagedSpaceFunc.self)

        guard let displays = copySpaces(mainConn) as? [[String: Any]] else { return }
        for display in displays {
            if let spaces = display["Spaces"] as? [[String: Any]], spaces.count >= targetIndex {
                let targetSpace = spaces[targetIndex - 1]
                if let spaceID = (targetSpace["id64"] as? NSNumber)?.uint64Value
                    ?? (targetSpace["ManagedSpaceID"] as? NSNumber)?.uint64Value {
                    let windowIDs = [NSNumber(value: window.windowNumber)] as CFArray
                    moveWindows(mainConn, windowIDs, spaceID)
                    return
                }
            }
        }
    }
}

/// Main macOS 27.3 Safari window controller calibrated 1:1 to `Reference/VisualDiffAudit.md`:
/// - Real unified `NSToolbar` (`52 pt`, Tahoe glossy 3D traffic lights, `window.isOpaque = true`, zero corner artifacts)
/// - Crisp `0.5 pt` horizontal bottom hairline at `y = 52.0 pt` (`#EAEAEA` light / `white 0.08` dark)
/// - `38 pt` concentric Liquid Glass capsules (`19 pt` radius + `7 pt` top inset = `26 pt` concentric) with `16–17 pt` SF Symbols
/// - Separate `sidebarCluster` & `backForwardCluster` so toggling sidebar NEVER merges glass into a blob
/// - `36 pt` unified address bar / equal-width continuous multi-tab track with subtle refined dark mode
/// - `240 pt` vibrant system-appearance split sidebar with `0.5 pt` vertical separator and `32 pt` rows
final class SafariWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, BrowserTabEngineDelegate {
    private let engine: BrowserEngine
    let isPrivate: Bool
    var onOpenPrivacyReport: (() -> Void)?
    private var tabs: [BrowserTabEngine] = []
    private var activeTabIndex: Int = 0
    private var preTearOffActiveTabID: String?
    private var tornOffTabID: String?
    private var closedTabURLs: [URL] = []
    private var didOpenInitialTabs = false
    private var pendingMockColorSampleWorkItem: DispatchWorkItem?

    private let chromeController = AdaptiveChromeController()

    // Root split layout: [sidebarView (fixed 240pt, slides -240..0)] | [mainPaneView]
    private let rootView = NSView()
    private let sidebarView = SafariSidebarView()
    private var mainPaneLeadingConstraint: NSLayoutConstraint?
    private var isSidebarOpen = false
    private var sidebarProgress: CGFloat = 0.0
    private var sidebarAnimStartProgress: CGFloat = 0.0
    private var sidebarAnimTargetProgress: CGFloat = 0.0
    private var sidebarAnimStartTime: CFTimeInterval = 0.0
    private var sidebarDisplayLink: CADisplayLink?
    private var sidebarAnimating: Bool = false

    private let mainPaneView = NSView()
    private let contentStageView = NSView()
    private let extensionBackdropFill = NSView()
    private let pullToRefreshView = PullToRefreshView()
    private let elasticScrollEngine = ElasticScrollEngine()
    private var pendingAdaptiveTheme: (theme: AdaptiveChromeTheme, animated: Bool)?
    private var isTrackpadScrollActive: Bool = false
    private var scrollIdleWorkItem: DispatchWorkItem?
    private let webContentHost = WebContentHostView()
    private let nativeVideoOverlay = NativeVideoOverlayContainerView()
    private var webContentTopConstraint: NSLayoutConstraint?
    private let startPageView = StartPageView()
    private let historyPageView = HistoryPageView()
    private let inspectPageView = InspectPageView()
    private let pageLoadErrorView = PageLoadErrorView()
    private var tabLoadErrors: [String: BrowserPageLoadError] = [:]
    private var reloadingErrorTabIDs: Set<String> = []
    private let swipeNavigationController = SwipeNavigationController()
    let navigationTransitionCoordinator = NavigationTransitionCoordinator()
    private var tabLastBackgroundedAt: [String: CFTimeInterval] = [:]
    /// Tabs switched away from whose Chromium view is hidden only once the new tab is on screen (see `selectTab`).
    private var deferredHiddenTabIDs: Set<String> = []
    private var deferredTabHideGeneration: Int = 0
    private var deferredRevealWebToolbarSyncTabID: String?
    private let tabOverviewView = TabOverviewView()
    private var tabOverviewTopConstraint: NSLayoutConstraint?
    private var isOverviewToolbarActive: Bool = false
    private var pendingOverviewOpenToken: Int = 0
    private let tabHoverPreviewController = TabHoverPreviewController()
    private let addressBarPopover = AddressBarPopoverController()
    private let pageMenuPopover = PageMenuPopoverController()
    private let websiteSettingsPopover = WebsiteSettingsPopoverController()
    private let privacyPopover = PrivacyPopoverController()
    private var cachedPrivacySummary: PrivacyReportSummary = .empty
    private var privacySummaryWorkItem: DispatchWorkItem?
    private var lastPrivacySummaryRefreshTime: CFTimeInterval = 0
    private let findBarView = PageFindBarView()
    private let customizeToolbarSheet = CustomizeToolbarSheetView()
    private let downloadController = DownloadAnimationController()
    private var passwordsPasskeyManager: ApplePasswordsPasskeyManager?

    private let toolbarFrostView = ToolbarGlassView()
    private var toolbarFrostHeightConstraint: NSLayoutConstraint?
    private var toolbarFrostBottomConstraint: NSLayoutConstraint?
    private let toolbarBarView = NSView()
    private let separateTabStripView = SeparateTabStripView()
    private var separateTabStripHeightConstraint: NSLayoutConstraint?
    private let verticalTabRailView = VerticalTabRailView()
    private var verticalTabRailWidthConstraint: NSLayoutConstraint?
    private let toolbarBottomHairline = NSView()
    private let privateLockOverlay = PrivateWindowLockOverlayView()
    private var isPrivateWindowLocked: Bool = false
    private var privateResignTime: Date?
    private var allowedHTTPHosts: Set<String> = []
    private var tabLastActiveAt: [String: Date] = [:]
    private var pinnedTabIDs: Set<String> = []
    var contextMenuTabID: String? = nil
    private var autoCloseTimer: Timer?

    // Gesture & input monitors (ported verbatim from Safarium's native AppKit state machine)
    private var magnifyMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var mouseDownMonitor: Any?
    private var rightClickMonitor: Any?
    private var middleClickMonitor: Any?
    private var keyDownMonitor: Any?
    private var engineNewTabObserver: NSObjectProtocol?
    private var spaceScrollObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var websitePolicyObserver: NSObjectProtocol?
    private var toolbarCustomizationObserver: NSObjectProtocol?
    private var autoOpenedDownloadIDs: Set<UInt32> = []
    private var middleClickPressedTabID: String?
    private var lastMouseDownInWindow: NSPoint?

    private let pinchCoordinator = PinchGestureCoordinator()
    private var overviewOpenTarget: Bool {
        get { pinchCoordinator.overviewOpenTarget }
        set { pinchCoordinator.overviewOpenTarget = newValue }
    }
    private var cachedStartPageSnapshot: NSImage?
    private var cachedStartPageSnapshotSize: NSSize = .zero

    private var recentSites: [StartPageView.RecentEntry] = [
        .init(title: "Apple", domain: "apple.com", url: URL(string: "https://www.apple.com/")!, favicon: nil),
        .init(title: "GitHub", domain: "github.com", url: URL(string: "https://github.com/")!, favicon: nil)
    ]

    // All toolbar capsules strictly equalized to 36 pt height (y = 8..44), matching the 36 pt tab track 1:1
    private var effectiveSidebarCapsuleWidth: CGFloat {
        let sidebarEnabled = ToolbarCustomizationStore.shared.isVisibleInToolbar(.sidebar)
        if !sidebarEnabled && !sidebarCapsule.hasMergedExtensions && !sidebarCapsule.hasPlaceholder {
            return 0.0
        }
        let base: CGFloat = sidebarEnabled ? (isPrivate ? 104.0 : SafariMetrics.sidebarCapsuleWidth) : 0.0
        return max(base, sidebarCapsule.currentRequiredWidth)
    }

    private let sidebarCluster = GlassToolbarClusterView(spacing: 0, mergeSpacing: 0)
    private lazy var sidebarCapsule: GlassActionCapsule = {
        if isPrivate {
            return GlassActionCapsule(specs: [
                .init(id: "sidebar", symbolName: "sidebar.left", tooltip: "Show or Hide Sidebar (⌘⇧L)", width: 34, pointSize: 16.0, weight: .regular, onClick: { [weak self] in self?.toggleSidebar() }),
                .init(id: "privateLabel", title: "Private", tooltip: "Private Browsing", width: 58, pointSize: 13.5, weight: .semibold, onClick: { [weak self] in self?.toggleSidebar() })
            ], horizontalPadding: 6)
        }
        return GlassActionCapsule(specs: [
            .init(id: "sidebar", symbolName: "sidebar.left", tooltip: "Show or Hide Sidebar (⌘⇧L)", width: 36, pointSize: 16.0, weight: .regular, onClick: { [weak self] in self?.toggleSidebar() }),
            .init(id: "tabGroups", symbolName: "chevron.down", tooltip: "Tab Groups", width: 20, pointSize: 10.5, weight: .medium, onClick: { [weak self] in self?.showTabGroupsMenu() })
        ], horizontalPadding: 3)
    }()

    private let backForwardCluster = GlassToolbarClusterView(spacing: 0, mergeSpacing: 0)
    private var backForwardWidthConstraint: NSLayoutConstraint?
    private var lastAnimatedBackForwardState: (canBack: Bool, canForward: Bool)?
    private lazy var backForwardCapsule: GlassActionCapsule = GlassActionCapsule(specs: [
        .init(id: "back", symbolName: "chevron.backward", tooltip: "Back (⌘[)", width: 36, pointSize: 15.5, weight: .regular, onClick: { [weak self] in self?.navigateBackInActiveTab() }),
        .init(id: "forward", symbolName: "chevron.forward", tooltip: "Forward (⌘])", width: 36, pointSize: 15.5, weight: .regular, onClick: { [weak self] in self?.navigateForwardInActiveTab() })
    ], horizontalPadding: 0, fullSlotHover: true)

    private let extensionsCoordinator = ExtensionsToolbarCoordinator()
    private let extensionPopoverController = ExtensionPopoverController()
    // Toolbar chain (see `rebuildToolbarChain`): clusters can sit on either side of the address bar.
    private let sidebarSlotGuide = NSLayoutGuide()
    private var sidebarSlotWidthConstraint: NSLayoutConstraint?
    private var toolbarChainConstraints: [NSLayoutConstraint] = []
    private var chainLeftOriginConstraint: NSLayoutConstraint?
    private var chainLeftGapConstraints: [NSLayoutConstraint] = []
    private var chainRightGapConstraints: [NSLayoutConstraint] = []
    private var chainRightEdgeConstraint: NSLayoutConstraint?
    private var chainLeftNodes: [ToolbarChainNode] = []
    private var chainRightNodes: [ToolbarChainNode] = []
    private var chainSignature = ""
    private var chainWidths: [ObjectIdentifier: CGFloat] = [:]
    /// True only while the sidebar pane is fully open (toolbar chain starts at the pane edge, sidebar toggle hidden).
    private var toolbarChainSidebarOpen = false
    private var afterSidebarExtWidthConstraint: NSLayoutConstraint?
    private var privacyShieldWidthConstraint: NSLayoutConstraint?
    private var leftCustomActionWidthConstraint: NSLayoutConstraint?
    private var leftExtWidthConstraint: NSLayoutConstraint?
    private var tabAddressBarLeadingConstraint: NSLayoutConstraint?
    private var tabAddressBarTrailingConstraint: NSLayoutConstraint?
    private var rightExtWidthConstraint: NSLayoutConstraint?
    private var trailingExtWidthConstraint: NSLayoutConstraint?

    private let privacyShieldCluster = GlassToolbarClusterView(spacing: 0, mergeSpacing: 0)
    private lazy var privacyShieldCapsule: GlassActionCapsule = GlassActionCapsule(specs: [
        .init(id: "privacyShield", symbolName: "shield.lefthalf.filled", tooltip: "Privacy Report", width: 30, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
            self?.showPrivacyPopover()
        })
    ], horizontalPadding: 3)

    private let leftCustomActionCluster = GlassToolbarClusterView(spacing: 0, mergeSpacing: 0)
    private lazy var leftCustomActionCapsule: GlassActionCapsule = GlassActionCapsule(
        specs: makeMovableActionSpecs(),
        horizontalPadding: 3
    )

    private let tabAddressBar = CompactTabAddressBar()

    private let rightGlassContainer = GlassToolbarClusterView(spacing: 0, mergeSpacing: 0)
    private lazy var rightActionCapsule: GlassActionCapsule = GlassActionCapsule(
        specs: makeMovableActionSpecs(),
        horizontalPadding: 3
    )

    private struct NativeToolbarDragSession {
        let itemID: CustomizableToolbarItemID
        let originSide: ToolbarActionSide?
        let sourceCapsule: GlassActionCapsule?
        let sourceButtonID: String?
        let startWindowPoint: NSPoint
        var hasStartedDragging: Bool
        var ghostView: NSView?
    }
    private var nativeToolbarDrag: NativeToolbarDragSession?

    private func makeMovableActionSpecs() -> [GlassActionCapsule.ActionSpec] {
        [
            .init(id: "startPage", symbolName: "square.grid.2x2", tooltip: "Show Start Page", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                self?.navigateActiveTab(to: URL(string: "safarium://start")!)
            }),
            .init(id: "home", symbolName: "house", tooltip: "Home (⌘⇧H)", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                self?.goToHomepage()
            }),
            .init(id: "history", symbolName: "clock.arrow.circlepath", tooltip: "History", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                guard let self else { return }
                if !self.isSidebarOpen { self.toggleSidebar() }
            }),
            .init(id: "bookmarks", symbolName: "book", tooltip: "Add to Favorites (⌘D)", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                self?.bookmarkCurrentPage()
            }),
            .init(id: "zoom", symbolName: "textformat.size", tooltip: "Zoom In / Reset", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                guard let self, let tab = self.activeTab, !tab.isStartPage else { return }
                if abs(tab.pageZoomFactor - 1.0) > 0.05 {
                    self.resetZoomActiveTab()
                } else {
                    self.zoomInActiveTab()
                }
            }),
            .init(id: "reload", symbolName: "arrow.clockwise", tooltip: "Reload Page (⌘R)", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                self?.reloadActiveTab()
            }),
            .init(id: "settings", symbolName: "gearshape", tooltip: "Settings (⌘,)", width: 34, pointSize: 15.0, weight: .regular, onClick: {
                (NSApp.delegate as? AppDelegate)?.showSettingsWindow(pane: .general)
            }),
            .init(id: "print", symbolName: "printer", tooltip: "Print (⌘P)", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                guard let win = self?.window else { return }
                win.printWindow(nil)
            }),
            .init(id: "webInspector", symbolName: "ladybug", tooltip: "Show Web Inspector (⌥⌘I)", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                self?.showDevToolsForActiveTab()
            }),
            .init(id: "privacyReport", symbolName: "shield.lefthalf.filled", tooltip: "Privacy Report", width: 34, pointSize: 15.0, weight: .regular, onClick: { [weak self] in
                self?.showPrivacyPopover()
            }),
            .init(id: "downloads", symbolName: "arrow.down.circle", tooltip: "Show Downloads", width: 36, pointSize: 16.0, weight: .regular, onClick: { [weak self] in self?.showDownloadsPopover() }),
            .init(id: "share", symbolName: "square.and.arrow.up", tooltip: "Share", width: 35, pointSize: 15.5, weight: .regular, onClick: { [weak self] in self?.showShareMenu() }),
            .init(id: "newTab", symbolName: "plus", tooltip: "New Tab (⌘T)", width: 35, pointSize: 16.5, weight: .regular, onClick: { [weak self] in
                guard let self else { return }
                let target = BrowserSettings.shared.resolvedNewTabURL(activeTabURL: self.activeTab?.currentURL)
                self.createNewTab(url: target, activate: true)
            }),
            .init(id: "tabOverview", symbolName: "square.on.square", tooltip: "Show Tab Overview (⇧⌘\\)", width: 36, pointSize: 15.5, weight: .regular, onClick: { [weak self] in self?.toggleTabOverview() })
        ]
    }

    private var activeTab: BrowserTabEngine? {
        guard activeTabIndex >= 0 && activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var activeWebPageURLString: String? {
        guard let url = activeTab?.currentURL,
              url.isWebURL else { return nil }
        return url.absoluteString
    }

    var canSaveActiveTab: Bool {
        guard let tab = activeTab else { return false }
        return !tab.isNativeInternalPage && tabLoadErrors[tab.tabID] == nil
    }

    func dismissExtensionPopover(restoreParentKey: Bool = true) {
        extensionPopoverController.close(restoreParentKey: restoreParentKey)
    }

    private func visibleExtensionsForWindow(_ extensions: [BrowserExtensionItem]) -> [BrowserExtensionItem] {
        isPrivate ? extensions.filter(\.allowInPrivate) : extensions
    }

    func openWebsitesSummary() -> [(host: String, favicon: NSImage?)] {
        var seen = Set<String>()
        var result: [(String, NSImage?)] = []
        for tab in tabs {
            guard let url = tab.currentURL,
                  url.isWebURL,
                  let host = url.host?.lowercased(), !host.isEmpty else { continue }
            let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if seen.insert(clean).inserted {
                result.append((clean, tab.favicon))
            }
        }
        return result
    }

    init(engine: BrowserEngine, isPrivate: Bool = false) {
        self.engine = engine
        self.isPrivate = isPrivate

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 944)
        let winW = min(SafariMetrics.defaultWindowWidth, screenFrame.width - 80)
        let winH = min(SafariMetrics.defaultWindowHeight, screenFrame.height - 60)
        let origin = NSPoint(
            x: screenFrame.midX - winW / 2.0,
            y: screenFrame.midY - winH / 2.0
        )

        let window = SafariWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: winW, height: winH)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = isPrivate ? "Safarium — Private" : "Safarium"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: SafariMetrics.minWindowWidth, height: SafariMetrics.minWindowHeight)
        window.contentMinSize = NSSize(width: SafariMetrics.minWindowWidth, height: SafariMetrics.minWindowHeight)
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .white
        // Native opaque window prevents corner pixel clipping artifacts around the 26pt macOS 27 window curve!
        window.isOpaque = true
        // Disable macOS AppKit WindowTab state restoration to avoid CoreSpotlight/Biome XPC spam on ad-hoc builds.
        window.isRestorable = false
        window.registerForDraggedTypes([.URL, .fileURL, .string])

        super.init(window: window)
        window.delegate = self

        // Attach real unified NSToolbar so macOS 27 Tahoe natively renders glossy 3D 16pt traffic lights
        // at exact (18, 18), (41, 18), (64, 18) (23pt pitch) + exact 52pt unified titlebar height!
        let nativeToolbar = NSToolbar(identifier: "SafariumUnifiedToolbar")
        nativeToolbar.delegate = self
        nativeToolbar.displayMode = .iconOnly
        nativeToolbar.allowsUserCustomization = false
        window.toolbar = nativeToolbar
        window.toolbarStyle = .unified

        setupUI()
        if isPrivate {
            startPageView.configurePrivateMode(true)
            tabAddressBar.isPrivateMode = true
        }
        wireCallbacks()
        installEventMonitors()
    }

    func markInitialTabsHandled() {
        didOpenInitialTabs = true
    }

    deinit {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        privacySummaryWorkItem?.cancel()
        privacySummaryWorkItem = nil
        sidebarDisplayLink?.invalidate()
        sidebarDisplayLink = nil
        navigationTransitionCoordinator.cancelImmediately()
        elasticScrollEngine.invalidate()
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        if let scrollWheelMonitor { NSEvent.removeMonitor(scrollWheelMonitor) }
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        if let middleClickMonitor { NSEvent.removeMonitor(middleClickMonitor) }
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let engineNewTabObserver { NotificationCenter.default.removeObserver(engineNewTabObserver) }
        if let spaceScrollObserver { NotificationCenter.default.removeObserver(spaceScrollObserver) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let websitePolicyObserver { NotificationCenter.default.removeObserver(websitePolicyObserver) }
        if let toolbarCustomizationObserver { NotificationCenter.default.removeObserver(toolbarCustomizationObserver) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - NSToolbarDelegate (non-empty unified bar with .flexibleSpace so macOS 27 Tahoe activates native 52pt titlebar + glossy 3D 16pt traffic lights)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }

    func openInitialTabsIfNeeded() {
        if !didOpenInitialTabs {
            didOpenInitialTabs = true
            window?.layoutIfNeeded()
            openInitialTabs()
        } else if let tab = activeTab {
            if tab.contentView.superview !== webContentHost {
                tab.attach(to: webContentHost)
            }
            tab.contentView.isHidden = false
            refreshToolbarUI()
        }
    }

    private func setupUI() {
        guard let window else { return }

        rootView.wantsLayer = true
        rootView.layer?.masksToBounds = true
        window.contentView = rootView

        // 1. Main content pane (spans full width during GPU sidebar slide; settles at leading = 0 or 240)
        mainPaneView.translatesAutoresizingMaskIntoConstraints = false
        mainPaneView.wantsLayer = true
        mainPaneView.layer?.masksToBounds = true
        rootView.addSubview(mainPaneView)

        let mplc = mainPaneView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 0)
        self.mainPaneLeadingConstraint = mplc

        // 2. Vibrant 240pt split Sidebar above mainPaneView so pure-GPU CATransform3D sliding requires
        //    ZERO Auto Layout solves and ZERO Chromium resizes across all 120Hz frames!
        sidebarView.isHidden = true
        sidebarView.wantsLayer = true
        sidebarView.layer?.masksToBounds = true
        rootView.addSubview(sidebarView)

        NSLayoutConstraint.activate([
            rootView.widthAnchor.constraint(greaterThanOrEqualToConstant: SafariMetrics.minWindowWidth),
            mplc,
            mainPaneView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            mainPaneView.topAnchor.constraint(equalTo: rootView.topAnchor),
            mainPaneView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: SafariMetrics.sidebarDefaultWidth),
            sidebarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        // 2b. Narrow 44pt Vertical Tab Icon Rail (full-height on left edge so glass is seamless with top toolbar)
        verticalTabRailView.translatesAutoresizingMaskIntoConstraints = false
        verticalTabRailView.isHidden = true
        mainPaneView.addSubview(verticalTabRailView)
        let railW = verticalTabRailView.widthAnchor.constraint(equalToConstant: 0)
        self.verticalTabRailWidthConstraint = railW
        NSLayoutConstraint.activate([
            verticalTabRailView.leadingAnchor.constraint(equalTo: mainPaneView.leadingAnchor),
            verticalTabRailView.topAnchor.constraint(equalTo: mainPaneView.topAnchor),
            verticalTabRailView.bottomAnchor.constraint(equalTo: mainPaneView.bottomAnchor),
            railW
        ])

        // 3. Full-bleed content stage starting cleanly beside the vertical tab rail (zero webpage clipping)
        //    while extending behind the 52pt top toolbar for live 120Hz glass refraction.
        contentStageView.translatesAutoresizingMaskIntoConstraints = false
        contentStageView.wantsLayer = true
        contentStageView.layer?.masksToBounds = true
        mainPaneView.addSubview(contentStageView)
        NSLayoutConstraint.activate([
            contentStageView.leadingAnchor.constraint(equalTo: verticalTabRailView.trailingAnchor),
            contentStageView.trailingAnchor.constraint(equalTo: mainPaneView.trailingAnchor),
            contentStageView.topAnchor.constraint(equalTo: mainPaneView.topAnchor),
            contentStageView.bottomAnchor.constraint(equalTo: mainPaneView.bottomAnchor)
        ])

        extensionBackdropFill.translatesAutoresizingMaskIntoConstraints = false
        extensionBackdropFill.wantsLayer = true
        extensionBackdropFill.layer?.backgroundColor = NSColor.white.cgColor
        contentStageView.addSubview(extensionBackdropFill)
        NSLayoutConstraint.activate([
            extensionBackdropFill.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            extensionBackdropFill.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            extensionBackdropFill.topAnchor.constraint(equalTo: contentStageView.topAnchor),
            extensionBackdropFill.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        // 4a. Web content host. It runs behind the translucent toolbar, like Safari: the page carries a matching top
        //     inset (BrowserCore `installUnderToolbarInset`, fed by `syncPageTopInset`), so nothing is hidden at the
        //     top and scrolled content slides under the glass.
        webContentHost.translatesAutoresizingMaskIntoConstraints = false
        webContentHost.wantsLayer = true
        contentStageView.addSubview(webContentHost)

        let wtc = webContentHost.topAnchor.constraint(equalTo: contentStageView.topAnchor, constant: 0)
        self.webContentTopConstraint = wtc
        NSLayoutConstraint.activate([
            webContentHost.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            webContentHost.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            wtc,
            webContentHost.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        // 4a-2. Video controls are embedded directly inside the webpage DOM (static position; no AppKit overlay).

        // 4b. Transparent 120Hz pull-to-refresh spinner overlay pinned directly below the 52pt toolbar
        //     so it sits cleanly in the rubber-band reveal gap (y = 52..52+offset).
        contentStageView.addSubview(pullToRefreshView)
        NSLayoutConstraint.activate([
            pullToRefreshView.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            pullToRefreshView.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            pullToRefreshView.topAnchor.constraint(equalTo: contentStageView.topAnchor, constant: SafariMetrics.toolbarHeight),
            pullToRefreshView.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        elasticScrollEngine.attach(targetView: webContentHost, spinnerView: pullToRefreshView)
        let authMgr = ApplePasswordsPasskeyManager(
            window: self.window,
            webContentHost: webContentHost,
            sheetContainerView: contentStageView
        )
        authMgr.onToolbarPresentationOverrideChanged = { [weak self] in
            self?.refreshToolbarUI()
        }
        self.passwordsPasskeyManager = authMgr

        // 4c. Native Start Page (`safarium://start`) full-bleed behind the 52pt frosted toolbar so its color & wallpaper match seamlessly
        startPageView.isHidden = true
        contentStageView.addSubview(startPageView)
        NSLayoutConstraint.activate([
            startPageView.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            startPageView.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            startPageView.topAnchor.constraint(equalTo: contentStageView.topAnchor),
            startPageView.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        // 4c-1b. Native Safari History Page (`safarium://history`) full-bleed behind the 52pt frosted toolbar
        historyPageView.isHidden = true
        contentStageView.addSubview(historyPageView)
        NSLayoutConstraint.activate([
            historyPageView.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            historyPageView.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            historyPageView.topAnchor.constraint(equalTo: contentStageView.topAnchor),
            historyPageView.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        // 4c-1c. Native Inspect & Remote Debugging Page (`chrome://inspect` & `chrome://inspect/#remote-debugging`)
        inspectPageView.isHidden = true
        contentStageView.addSubview(inspectPageView)
        NSLayoutConstraint.activate([
            inspectPageView.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            inspectPageView.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            inspectPageView.topAnchor.constraint(equalTo: contentStageView.topAnchor),
            inspectPageView.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        // 4c-2. Native Safari page load error view full-bleed behind the 52pt frosted toolbar
        pageLoadErrorView.isHidden = true
        contentStageView.addSubview(pageLoadErrorView)
        NSLayoutConstraint.activate([
            pageLoadErrorView.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            pageLoadErrorView.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            pageLoadErrorView.topAnchor.constraint(equalTo: contentStageView.topAnchor),
            pageLoadErrorView.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        swipeNavigationController.attach(stageView: contentStageView, targetPageView: webContentHost)
        swipeNavigationController.topContentInsetProvider = { [weak self] in
            self?.toolbarStackHeight ?? SafariMetrics.toolbarHeight
        }
        navigationTransitionCoordinator.attach(stageView: contentStageView, anchorAbove: pageLoadErrorView)
        navigationTransitionCoordinator.topContentInsetProvider = { [weak self] in
            self?.toolbarStackHeight ?? SafariMetrics.toolbarHeight
        }
        navigationTransitionCoordinator.onWillRevealTransition = { [weak self] tabID in
            guard let self, let tab = self.activeTab, tab.tabID == tabID else { return }
            if self.deferredRevealWebToolbarSyncTabID == tabID {
                self.deferredRevealWebToolbarSyncTabID = nil
                self.applyActiveWebToolbarChrome(for: tab, animated: true)
            }
        }

        // 4d. Scrubbable Pinch-to-Tab-Overview grid overlay below the 52pt toolbar (+ Separate tab strip when active)
        tabOverviewView.isHidden = true
        contentStageView.addSubview(tabOverviewView)
        let ovTop = tabOverviewView.topAnchor.constraint(equalTo: contentStageView.topAnchor, constant: SafariMetrics.toolbarHeight)
        self.tabOverviewTopConstraint = ovTop
        NSLayoutConstraint.activate([
            tabOverviewView.leadingAnchor.constraint(equalTo: contentStageView.leadingAnchor),
            tabOverviewView.trailingAnchor.constraint(equalTo: contentStageView.trailingAnchor),
            ovTop,
            tabOverviewView.bottomAnchor.constraint(equalTo: contentStageView.bottomAnchor)
        ])

        // 5. Progressive macOS 27 frosted / Liquid Glass backdrop in `mainPaneView` beneath `toolbarBarView`.
        //    In Vertical tab layout, expands full-height and masks to a single seamless L-shape covering both
        //    the top toolbar and the left vertical tab rail.
        mainPaneView.addSubview(toolbarFrostView)
        let frostH = toolbarFrostView.heightAnchor.constraint(equalToConstant: ToolbarGlassView.activeTotalHeight)
        let frostBottom = toolbarFrostView.bottomAnchor.constraint(equalTo: mainPaneView.bottomAnchor)
        frostBottom.isActive = false
        self.toolbarFrostHeightConstraint = frostH
        self.toolbarFrostBottomConstraint = frostBottom
        NSLayoutConstraint.activate([
            toolbarFrostView.leadingAnchor.constraint(equalTo: mainPaneView.leadingAnchor),
            toolbarFrostView.trailingAnchor.constraint(equalTo: mainPaneView.trailingAnchor),
            toolbarFrostView.topAnchor.constraint(equalTo: mainPaneView.topAnchor),
            frostH
        ])

        // 6. Exact 52pt unified toolbar
        toolbarBarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarBarView.wantsLayer = true
        toolbarBarView.layer?.masksToBounds = false
        mainPaneView.addSubview(toolbarBarView)
        // Float the vertical Liquid Glass tab capsule cleanly above toolbarFrostView on the left edge.
        mainPaneView.addSubview(verticalTabRailView, positioned: .above, relativeTo: toolbarFrostView)
        NSLayoutConstraint.activate([
            toolbarBarView.leadingAnchor.constraint(equalTo: mainPaneView.leadingAnchor),
            toolbarBarView.trailingAnchor.constraint(equalTo: mainPaneView.trailingAnchor),
            toolbarBarView.topAnchor.constraint(equalTo: mainPaneView.topAnchor),
            toolbarBarView.heightAnchor.constraint(equalToConstant: SafariMetrics.toolbarHeight)
        ])

        // 6b. Separate Tab Strip (shown directly beneath the 52pt toolbar when Tab Layout == "separate")
        separateTabStripView.translatesAutoresizingMaskIntoConstraints = false
        separateTabStripView.isHidden = true
        mainPaneView.addSubview(separateTabStripView)
        let sepH = separateTabStripView.heightAnchor.constraint(equalToConstant: 0)
        self.separateTabStripHeightConstraint = sepH
        NSLayoutConstraint.activate([
            separateTabStripView.leadingAnchor.constraint(equalTo: mainPaneView.leadingAnchor),
            separateTabStripView.trailingAnchor.constraint(equalTo: mainPaneView.trailingAnchor),
            separateTabStripView.topAnchor.constraint(equalTo: toolbarBarView.bottomAnchor),
            sepH
        ])

        toolbarBottomHairline.translatesAutoresizingMaskIntoConstraints = false
        toolbarBottomHairline.wantsLayer = true
        toolbarBottomHairline.isHidden = true
        mainPaneView.addSubview(toolbarBottomHairline)
        NSLayoutConstraint.activate([
            toolbarBottomHairline.leadingAnchor.constraint(equalTo: mainPaneView.leadingAnchor),
            toolbarBottomHairline.trailingAnchor.constraint(equalTo: mainPaneView.trailingAnchor),
            toolbarBottomHairline.topAnchor.constraint(equalTo: separateTabStripView.bottomAnchor, constant: -0.5),
            toolbarBottomHairline.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        // 6c. Liquid Glass Find-on-Page Bar (`⌘F` / `⌘G` / `⌘⇧G`)
        findBarView.translatesAutoresizingMaskIntoConstraints = false
        findBarView.isHidden = true
        mainPaneView.addSubview(findBarView)
        NSLayoutConstraint.activate([
            findBarView.trailingAnchor.constraint(equalTo: mainPaneView.trailingAnchor, constant: -14),
            findBarView.topAnchor.constraint(equalTo: separateTabStripView.bottomAnchor, constant: 8),
            findBarView.widthAnchor.constraint(equalToConstant: 312),
            findBarView.heightAnchor.constraint(equalToConstant: 36)
        ])

        // 6d. Native Tahoe Liquid Glass "Customize Toolbar…" Sheet (slides beneath the 52pt toolbar)
        customizeToolbarSheet.translatesAutoresizingMaskIntoConstraints = false
        customizeToolbarSheet.isHidden = true
        mainPaneView.addSubview(customizeToolbarSheet)
        NSLayoutConstraint.activate([
            customizeToolbarSheet.leadingAnchor.constraint(equalTo: mainPaneView.leadingAnchor),
            customizeToolbarSheet.trailingAnchor.constraint(equalTo: mainPaneView.trailingAnchor),
            customizeToolbarSheet.topAnchor.constraint(equalTo: toolbarBarView.bottomAnchor),
            customizeToolbarSheet.bottomAnchor.constraint(equalTo: mainPaneView.bottomAnchor)
        ])

        // Left Group 1: `[sidebar | v]` (`64 × 38 pt` at `x = 95, y = 7`) in its own independent container
        sidebarCluster.addArrangedView(sidebarCapsule)
        toolbarBarView.addSubview(sidebarCluster)

        // Extension Zone 0 (afterSidebar): between Sidebar and Back/Forward
        let afterSidebarExt = extensionsCoordinator.capsule(for: .afterSidebar)
        toolbarBarView.addSubview(afterSidebarExt)

        // Left Group 2: `[ < ]` / `[ < | > ]` — completely hidden (width 0) when no Back/Forward history (`#56`)
        backForwardCluster.addArrangedView(backForwardCapsule)
        backForwardCluster.isHidden = true
        backForwardCluster.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        backForwardCapsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarBarView.addSubview(backForwardCluster)
        backForwardCapsule.setHidden(true, for: "back", animated: false)
        backForwardCapsule.setHidden(true, for: "forward", animated: false)

        // Left Privacy Shield button (shows live per-site Privacy Popover)
        privacyShieldCluster.addArrangedView(privacyShieldCapsule)
        privacyShieldCluster.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        privacyShieldCapsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarBarView.addSubview(privacyShieldCluster)

        // Left Custom Actions Group (optional/moved buttons placed on the left side via Customize Toolbar…)
        leftCustomActionCluster.addArrangedView(leftCustomActionCapsule)
        leftCustomActionCluster.isHidden = true
        leftCustomActionCluster.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftCustomActionCapsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for actionID in CustomizableToolbarItemID.allMovableActions {
            leftCustomActionCapsule.setHidden(true, for: actionID.rawValue, animated: false)
        }
        toolbarBarView.addSubview(leftCustomActionCluster)

        // Extension Zone 1 (leftOfAddressBar): default zone between Back/Forward and Address/Tab bar
        let leftExt = extensionsCoordinator.capsule(for: .leftOfAddressBar)
        toolbarBarView.addSubview(leftExt)

        // Center: Unified 36pt address bar / continuous multi-tab track
        toolbarBarView.addSubview(tabAddressBar)

        // Extension Zone 2 (rightOfAddressBar): between Address/Tab bar and Right Actions capsule
        let rightExt = extensionsCoordinator.capsule(for: .rightOfAddressBar)
        toolbarBarView.addSubview(rightExt)

        // Right Group: Unified 4-icon Liquid Glass capsule (`155 × 36 pt`)
        rightGlassContainer.addArrangedView(rightActionCapsule)
        toolbarBarView.addSubview(rightGlassContainer)

        // Extension Zone 3 (trailing): far right edge of toolbar after Right Actions capsule
        let trailingExt = extensionsCoordinator.capsule(for: .trailing)
        toolbarBarView.addSubview(trailingExt)

        // Everything between the window edges is one chain; `rebuildToolbarChain()` links the views in the order the user
        // chose and `applyToolbarChainConstants` supplies the gaps. Only widths and vertical metrics live here.
        toolbarBarView.addLayoutGuide(sidebarSlotGuide)
        let sidebarSlotWidth = sidebarSlotGuide.widthAnchor.constraint(equalToConstant: effectiveSidebarCapsuleWidth)
        self.sidebarSlotWidthConstraint = sidebarSlotWidth

        let afterSidebarWidth = afterSidebarExt.widthAnchor.constraint(equalToConstant: 0)
        self.afterSidebarExtWidthConstraint = afterSidebarWidth
        let bfWidth = backForwardCluster.widthAnchor.constraint(equalToConstant: 0)
        self.backForwardWidthConstraint = bfWidth
        let shieldWidth = privacyShieldCluster.widthAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize)
        self.privacyShieldWidthConstraint = shieldWidth
        let leftCustomWidth = leftCustomActionCluster.widthAnchor.constraint(equalToConstant: 0)
        self.leftCustomActionWidthConstraint = leftCustomWidth
        let leftExtWidth = leftExt.widthAnchor.constraint(equalToConstant: 0)
        self.leftExtWidthConstraint = leftExtWidth
        let rightExtWidth = rightExt.widthAnchor.constraint(equalToConstant: 0)
        self.rightExtWidthConstraint = rightExtWidth
        let trailingExtWidth = trailingExt.widthAnchor.constraint(equalToConstant: 0)
        self.trailingExtWidthConstraint = trailingExtWidth

        NSLayoutConstraint.activate([
            sidebarSlotWidth,
            sidebarCluster.leadingAnchor.constraint(equalTo: sidebarSlotGuide.leadingAnchor),
            sidebarCluster.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            sidebarCluster.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            afterSidebarExt.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            afterSidebarWidth,
            afterSidebarExt.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            backForwardCluster.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            bfWidth,
            backForwardCluster.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            privacyShieldCluster.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            shieldWidth,
            privacyShieldCluster.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            leftCustomActionCluster.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            leftCustomWidth,
            leftCustomActionCluster.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            leftExt.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            leftExtWidth,
            leftExt.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            trailingExt.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            trailingExtWidth,
            trailingExt.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            rightGlassContainer.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            rightGlassContainer.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            rightExt.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.glassButtonTopInset),
            rightExtWidth,
            rightExt.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize),

            tabAddressBar.topAnchor.constraint(equalTo: toolbarBarView.topAnchor, constant: SafariMetrics.tabBarTopInset),
            tabAddressBar.heightAnchor.constraint(equalToConstant: SafariMetrics.tabPillHeight)
        ])
        rebuildToolbarChain()

        let dragView = ToolbarWindowDragView()
        dragView.translatesAutoresizingMaskIntoConstraints = false
        toolbarBarView.addSubview(dragView, positioned: .below, relativeTo: sidebarCluster)
        NSLayoutConstraint.activate([
            dragView.leadingAnchor.constraint(equalTo: toolbarBarView.leadingAnchor),
            dragView.trailingAnchor.constraint(equalTo: toolbarBarView.trailingAnchor),
            dragView.topAnchor.constraint(equalTo: toolbarBarView.topAnchor),
            dragView.heightAnchor.constraint(equalToConstant: SafariMetrics.toolbarHeight)
        ])

        if let downloadsBtn = rightActionCapsule.button(for: "downloads") {
            downloadController.attach(window: window, downloadsButton: downloadsBtn, capsule: rightActionCapsule)
            downloadController.onCancelDownload = { [weak self] downloadID in
                self?.engine.cancelDownload(id: downloadID)
            }
            downloadController.onPauseDownload = { [weak self] downloadID in
                self?.engine.pauseDownload(id: downloadID)
            }
            downloadController.onResumeDownload = { [weak self] downloadID in
                self?.engine.resumeDownload(id: downloadID) ?? false
            }
            downloadController.onRetryDownload = { [weak self] url in
                self?.activeTab?.startDownload(at: url)
            }
            downloadController.onToolbarVisibilityChanged = { [weak self] animated in
                self?.applyToolbarCustomization(animated: animated, refreshSheet: false)
            }
        }

        // Private Browsing Touch ID lock overlay (hidden unless Private window locks)
        privateLockOverlay.translatesAutoresizingMaskIntoConstraints = false
        privateLockOverlay.isHidden = true
        rootView.addSubview(privateLockOverlay)
        NSLayoutConstraint.activate([
            privateLockOverlay.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            privateLockOverlay.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            privateLockOverlay.topAnchor.constraint(equalTo: rootView.topAnchor),
            privateLockOverlay.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        applyAdaptiveTheme(.defaultLight, animated: false)
        applyTabLayoutPreference(animated: false)
    }

    private func wireCallbacks() {
        chromeController.onThemeDidChange = { [weak self] theme, animated in
            self?.applyAdaptiveTheme(theme, animated: animated)
        }

        if let safariWin = window as? SafariWindow {
            safariWin.onDropURL = { [weak self] url, openInNewTab in
                guard let self else { return }
                self.openURLInActiveOrNewTab(url, newTab: openInNewTab)
            }
            safariWin.onPerformKeyEquivalent = { [weak self] event in
                self?.handleWindowKeyEquivalent(event) ?? false
            }
        }
        tabAddressBar.onDropURL = { [weak self] url, targetTabID, openInNewTab in
            guard let self else { return }
            self.openURL(url, inTabID: targetTabID, newTab: openInNewTab)
        }
        nativeVideoOverlay.scrollForwardTarget = webContentHost
        nativeVideoOverlay.onVideoCommand = { [weak self] tabID, videoID, cmd, val in
            guard let self, let tab = self.tabs.first(where: { $0.tabID == tabID }) else { return }
            let valStr = val.map { String($0) } ?? "null"
            tab.executeJavaScript("window.__safariumVideoCmd && window.__safariumVideoCmd(\(JSStringLiteral.make(videoID)), \(JSStringLiteral.make(cmd)), \(valStr));")
        }

        tabAddressBar.onSelectTab = { [weak self] id in
            self?.tabHoverPreviewController.dismiss(animated: false)
            self?.dismissAddressBarPopover()
            if let idx = self?.tabs.firstIndex(where: { $0.tabID == id }) {
                self?.selectTab(at: idx)
            }
        }
        tabAddressBar.onCloseTab = { [weak self] id in
            self?.tabHoverPreviewController.dismiss(animated: false)
            if let idx = self?.tabs.firstIndex(where: { $0.tabID == id }) {
                self?.closeTab(at: idx)
            }
        }
        tabAddressBar.onTabHoverChanged = { [weak self] id, anchorView, hovered in
            self?.handleTabHoverPreview(tabID: id, anchorView: anchorView, hovered: hovered, isVertical: false)
        }
        tabHoverPreviewController.onSelectTab = { [weak self] id in
            guard let self, let idx = self.tabs.firstIndex(where: { $0.tabID == id }) else { return }
            self.selectTab(at: idx)
        }
        tabHoverPreviewController.onCloseTab = { [weak self] id in
            guard let self, self.tabs.count > 1, let idx = self.tabs.firstIndex(where: { $0.tabID == id }) else { return }
            self.closeTab(at: idx)
        }
        tabAddressBar.onReorderTabs = { [weak self] orderedIDs in
            self?.reorderTabs(matchingOrder: orderedIDs)
        }
        tabAddressBar.canTearOffSingleTab = { true }
        tabAddressBar.onBeginTabTearOff = { [weak self] tabID, pillRectInScreen, cursorOffsetInPill, mouseScreen in
            self?.beginTabTearOff(
                tabID: tabID,
                pillRectInScreen: pillRectInScreen,
                cursorOffsetInPill: cursorOffsetInPill,
                mouseScreen: mouseScreen
            )
        }
        tabAddressBar.onSubmitURLString = { [weak self] input in
            guard let self else { return }
            self.dismissAddressBarPopover()
            let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedInput.isEmpty && !self.isPrivate {
                let normalized = URLInputNormalizer.normalize(trimmedInput, isPrivate: false)
                let lower = trimmedInput.lowercased()
                let isDirectURL = !trimmedInput.contains(where: { $0.isWhitespace }) && (
                    lower.contains("://") || lower.contains(".") || lower == "localhost" || lower.hasPrefix("localhost:")
                )
                if isDirectURL {
                    SuggestionUsageStore.shared.recordURLSelection(
                        query: trimmedInput,
                        url: normalized,
                        title: "",
                        isPrivate: false
                    )
                } else {
                    SuggestionUsageStore.shared.recordSearchSelection(
                        query: trimmedInput,
                        searchQuery: trimmedInput,
                        isPrivate: false
                    )
                }
            }
            let wasInOverview = self.tabOverviewView.isPresented || self.overviewOpenTarget
            if wasInOverview {
                self.overviewOpenTarget = false
                self.updateToolbarForTabOverview(false)
                self.tabOverviewView.closeAnimated()
                let url = URLInputNormalizer.normalize(input, isPrivate: self.isPrivate)
                self.createNewTab(url: url, activate: true)
                return
            }
            if let tab = self.activeTab {
                self.snapshotBeforeLeavingCurrentPage(for: tab)
                self.tabLoadErrors.removeValue(forKey: tab.tabID)
            }
            self.activeTab?.loadInput(input)
            self.updateStartPageVisibility()
            self.activeTab?.focusWebContent()
        }
        tabAddressBar.onReloadOrStop = { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            if tab.isLoading {
                tab.stopLoading()
            } else if let err = self.tabLoadErrors[tab.tabID] {
                self.reloadingErrorTabIDs.insert(tab.tabID)
                self.resetTabPrivacyStatsBeforeReload(for: tab)
                self.refreshPrivacyShieldUI()
                tab.loadURL(err.failedURL)
            } else {
                self.resetTabPrivacyStatsBeforeReload(for: tab)
                self.refreshPrivacyShieldUI()
                tab.reload()
            }
        }

        swipeNavigationController.canGoBack = { [weak self] in
            guard let tab = self?.activeTab, tab.canGoBack else { return false }
            if !tab.isNativeInternalPage && tab.canScrollLeft { return false }
            return true
        }
        swipeNavigationController.canGoForward = { [weak self] in
            guard let tab = self?.activeTab, tab.canGoForward else { return false }
            if !tab.isNativeInternalPage && tab.canScrollRight { return false }
            return true
        }
        swipeNavigationController.snapshotForDirection = { [weak self] direction in
            self?.resolveSwipeSnapshot(for: direction)
        }
        swipeNavigationController.onCommitNavigation = { [weak self] direction in
            switch direction {
            case .back: self?.navigateBackInActiveTab()
            case .forward: self?.navigateForwardInActiveTab()
            }
        }
        tabAddressBar.onShowPageMenu = { [weak self] anchor in
            self?.showPageMenu(relativeTo: anchor)
        }
        tabAddressBar.onAddressFocusChanged = { [weak self] focused in
            guard let self else { return }
            if focused {
                // On Start Page, Favorites are already shown full-screen; show popover over loaded webpages (05_addressbar_popover_top.png).
                // Defer briefly so Core Animation commits frame 0 of focus-glide & ring animations to the render server before the popover opens.
                if self.activeTab?.isStartPage != true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                        guard let self, self.tabAddressBar.isAddressBarEditing, self.activeTab?.isStartPage != true else { return }
                        self.showAddressBarPopover()
                    }
                } else {
                    self.dismissAddressBarPopover()
                }
            } else {
                self.dismissAddressBarPopover()
            }
        }
        tabAddressBar.onAddressQueryChanged = { [weak self] query in
            guard let self else { return }
            if !self.addressBarPopover.isShown && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.showAddressBarPopover(initialQuery: query)
            } else {
                self.addressBarPopover.update(
                    query: query,
                    isDark: self.chromeController.currentTheme.prefersLightInk,
                    isPrivate: self.isPrivate,
                    recentGroups: self.buildPopoverRecentGroups(),
                    openTabs: self.buildPopoverOpenTabs(),
                    activeDomain: self.activeTabDomain()
                )
            }
        }
        tabAddressBar.onActivePillLayoutChanged = { [weak self] in
            self?.addressBarPopover.repositionIfShown()
        }
        tabAddressBar.onMoveSelection = { [weak self] delta in
            self?.addressBarPopover.moveSelection(delta: delta)
        }
        tabAddressBar.onCommitSelectedSuggestion = { [weak self] in
            self?.addressBarPopover.commitSelectedSuggestionIfAny() ?? false
        }

        sidebarView.onSelectTab = { [weak self] id in
            if let idx = self?.tabs.firstIndex(where: { $0.tabID == id }) {
                self?.selectTab(at: idx)
            }
        }
        sidebarView.onCloseTab = { [weak self] id in
            if let idx = self?.tabs.firstIndex(where: { $0.tabID == id }) {
                self?.closeTab(at: idx)
            }
        }
        sidebarView.onNewTab = { [weak self] in
            guard let self else { return }
            let target = BrowserSettings.shared.resolvedNewTabURL(activeTabURL: self.activeTab?.currentURL)
            self.createNewTab(url: target, activate: true)
        }
        sidebarView.onToggleSidebar = { [weak self] in
            self?.toggleSidebar()
        }
        sidebarView.onSelectURL = { [weak self] urlString in
            if let url = URL(string: urlString) {
                self?.navigateActiveTab(to: url)
            }
        }
        sidebarView.onDropURL = { [weak self] url, targetTabID, openInNewTab in
            guard let self else { return }
            self.openURL(url, inTabID: targetTabID, newTab: openInNewTab)
        }

        startPageView.onSelectURL = { [weak self] url in
            self?.navigateActiveTab(to: url)
        }
        startPageView.onHoverURL = { [weak self] url in
            guard let self, !self.isPrivate else { return }
            self.activeTab?.prewarmOrigin(url)
        }
        startPageView.onOpenInNewTab = { [weak self] url in
            self?.createNewTab(url: url, activate: true)
        }
        startPageView.onOpenInNewWindow = { [weak self] url in
            (NSApp.delegate as? AppDelegate)?.openNewWindow(url: url, isPrivate: self?.isPrivate ?? false)
        }
        startPageView.onOpenInNewTabGroup = { [weak self] url in
            self?.createNewTab(url: url, activate: true)
        }
        startPageView.onBackdropColorChanged = { [weak self] color in
            guard let self, self.activeTab?.isStartPage == true else { return }
            self.chromeController.apply(sample: TopEdgeColorSample(color: color), animated: true)
        }
        startPageView.onOpenPrivacyReport = { [weak self] in
            self?.onOpenPrivacyReport?()
        }

        privacyPopover.onToggleSiteProtection = { [weak self] host, enabled in
            guard let self, !host.isEmpty else { return }
            BrowserSettings.shared.setContentBlockersEnabled(enabled, forHost: host)
            let effective = BrowserSettings.shared.preventCrossSiteTracking && enabled
            if let tab = self.activeTab {
                self.resetTabPrivacyStatsBeforeReload(for: tab, overrideProtectionsEnabled: effective)
            }
            self.engine.syncPrivacyPolicy(BrowserSettings.shared.privacyPolicyDictionary())
            self.refreshPrivacyShieldUI()
            self.activeTab?.reload()
        }
        privacyPopover.onOpenPrivacyReport = { [weak self] in
            self?.onOpenPrivacyReport?()
        }
        privacyPopover.onOpenWebsiteSettings = { [weak self] _ in
            self?.showWebsiteSettingsPopoverForActiveTab()
        }

        addressBarPopover.onSelectURL = { [weak self] url in
            self?.tabAddressBar.endAddressEditing(restoreURL: false)
            self?.dismissAddressBarPopover()
            self?.navigateActiveTab(to: url)
        }
        addressBarPopover.onOpenInNewTab = { [weak self] url in
            self?.tabAddressBar.endAddressEditing(restoreURL: true)
            self?.dismissAddressBarPopover()
            self?.createNewTab(url: url, activate: true)
        }
        addressBarPopover.onOpenInNewWindow = { [weak self] url in
            self?.tabAddressBar.endAddressEditing(restoreURL: true)
            self?.dismissAddressBarPopover()
            (NSApp.delegate as? AppDelegate)?.openNewWindow(url: url, isPrivate: self?.isPrivate ?? false)
        }
        addressBarPopover.onOpenInNewTabGroup = { [weak self] url in
            self?.tabAddressBar.endAddressEditing(restoreURL: true)
            self?.dismissAddressBarPopover()
            self?.createNewTab(url: url, activate: true)
        }
        addressBarPopover.onSelectSearch = { [weak self] query in
            guard let self else { return }
            self.tabAddressBar.endAddressEditing(restoreURL: false)
            self.dismissAddressBarPopover()
            self.navigateActiveTab(to: URLInputNormalizer.normalize(query, isPrivate: self.isPrivate))
        }
        addressBarPopover.onSwitchToTab = { [weak self] id in
            self?.tabAddressBar.endAddressEditing(restoreURL: true)
            self?.dismissAddressBarPopover()
            if let idx = self?.tabs.firstIndex(where: { $0.tabID == id }) {
                self?.selectTab(at: idx)
            }
        }
        addressBarPopover.onDismissRequested = { [weak self] in
            self?.tabAddressBar.endAddressEditing(restoreURL: true)
            self?.dismissAddressBarPopover()
            self?.window?.makeFirstResponder(nil)
        }

        elasticScrollEngine.onTriggerRefresh = { [weak self] in
            self?.activeTab?.reload()
        }
        elasticScrollEngine.onSyntheticScrollDelta = { [weak self] deltaY in
            self?.dispatchSyntheticTouchpadScrollDelta(deltaY)
        }
        elasticScrollEngine.onElasticInteractionChanged = { [weak self] active in
            guard let self else { return }
            self.activeTab?.setScrollInteractionActive(active || self.isTrackpadScrollActive)
            if !active && !self.isTrackpadScrollActive, let pending = self.pendingAdaptiveTheme {
                self.pendingAdaptiveTheme = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.elasticScrollEngine.isElasticInteractionActive, !self.isTrackpadScrollActive else { return }
                    self.applyAdaptiveTheme(pending.theme, animated: pending.animated)
                }
            }
        }

        historyPageView.onOpenURL = { [weak self] url, openInNewTab in
            guard let self else { return }
            if openInNewTab {
                self.createNewTab(url: url, activate: true)
            } else {
                self.navigateActiveTab(to: url)
            }
        }
        historyPageView.onClearHistory = { [weak self] in
            guard let self else { return }
            ClearHistorySheetController.present(over: self.window) { [weak self] range in
                AssetLoader.shared.clearHistory(range: range)
                self?.engine.clearWebsiteData { _ in }
            }
        }

        inspectPageView.onSelectSection = { [weak self] section in
            self?.activeTab?.loadURL(section.canonicalURL)
        }
        inspectPageView.onOpenURL = { [weak self] url, openInNewTab in
            guard let self else { return }
            if openInNewTab {
                self.createNewTab(url: url, activate: true)
            } else {
                self.navigateActiveTab(to: url)
            }
        }
        inspectPageView.localTabsProvider = { [weak self] in
            guard let self else { return [] }
            let controllers = NSApp?.windows.compactMap { $0.windowController as? SafariWindowController } ?? []
            let allControllers = controllers.contains(where: { $0 === self }) ? controllers : [self] + controllers
            var snapshots: [InspectLocalTabSnapshot] = []
            for (winIdx, wc) in allControllers.enumerated() {
                for (tabIdx, t) in wc.tabs.enumerated() {
                    snapshots.append(InspectLocalTabSnapshot(
                        tabID: t.tabID,
                        windowIndex: winIdx,
                        title: t.title,
                        urlString: t.currentURL?.absoluteString ?? "about:blank",
                        isPrivate: wc.isPrivate,
                        isActive: wc === self && tabIdx == wc.activeTabIndex
                    ))
                }
            }
            return snapshots
        }
        inspectPageView.extensionsProvider = { [weak self] in
            self?.engine.installedExtensions() ?? []
        }
        inspectPageView.remoteDebuggingStatusProvider = { [weak self] in
            guard let eng = self?.engine else {
                return InspectRemoteDebuggingStatus(activePort: 0, isActive: false, webSocketURL: nil, activePortFilePath: nil)
            }
            return InspectRemoteDebuggingStatus(
                activePort: eng.activeRemoteDebuggingPort,
                isActive: eng.isRemoteDebuggingActive,
                webSocketURL: eng.remoteDebuggingWebSocketURL,
                activePortFilePath: eng.devToolsActivePortFilePath
            )
        }
        inspectPageView.onInspectLocalTab = { [weak self] tabID in
            self?.performActionOnLocalTab(id: tabID) { wc, idx, tab in
                wc.window?.makeKeyAndOrderFront(nil)
                wc.selectTab(at: idx)
                tab.showDevTools()
            }
        }
        inspectPageView.onFocusLocalTab = { [weak self] tabID in
            self?.performActionOnLocalTab(id: tabID) { wc, idx, _ in
                wc.window?.makeKeyAndOrderFront(nil)
                wc.selectTab(at: idx)
            }
        }
        inspectPageView.onReloadLocalTab = { [weak self] tabID in
            self?.performActionOnLocalTab(id: tabID) { _, _, tab in
                tab.reload()
            }
        }
        inspectPageView.onCloseLocalTab = { [weak self] tabID in
            self?.performActionOnLocalTab(id: tabID) { wc, idx, _ in
                wc.closeTab(at: idx)
            }
        }
        inspectPageView.onInspectRemoteTarget = { [weak self] wsURL in
            self?.engine.openDevToolsForRemoteTarget(wsURL: wsURL)
        }
        inspectPageView.onOpenExtensionsSettings = { extID in
            if let appDel = NSApp?.delegate as? AppDelegate {
                appDel.showSettingsWindow(pane: .extensions, selectingExtensionID: extID)
            }
        }
        inspectPageView.onRelaunchApp = {
            if let appDel = NSApp?.delegate as? AppDelegate {
                appDel.relaunchApplication()
            }
        }

        tabOverviewView.onSelectTab = { [weak self] id in
            guard let self else { return }
            self.overviewOpenTarget = false
            self.updateToolbarForTabOverview(false)
            if let idx = self.tabs.firstIndex(where: { $0.tabID == id }) {
                self.selectTab(at: idx)
            }
        }
        tabOverviewView.onCloseTab = { [weak self] id in
            guard let self else { return }
            if let idx = self.tabs.firstIndex(where: { $0.tabID == id }) {
                self.closeTab(at: idx, keepOverviewOpen: true)
                if self.tabOverviewView.isPresented {
                    self.tabOverviewView.update(cards: self.buildOverviewCardModels())
                }
            }
        }
        tabOverviewView.onNewTab = { [weak self] in
            guard let self else { return }
            let target = BrowserSettings.shared.resolvedNewTabURL(activeTabURL: self.activeTab?.currentURL)
            self.createNewTab(url: target, activate: true)
        }
        tabOverviewView.onDismiss = { [weak self] in
            self?.overviewOpenTarget = false
            self?.updateToolbarForTabOverview(false)
        }
        tabOverviewView.onPresentationStateChanged = { [weak self] active in
            guard let self else { return }
            self.updateToolbarForTabOverview(active)
            self.setOverviewSnapshotCapturePaused(active)
            if !active {
                self.pruneOrphanedTabSnapshots()
            }
        }

        // Liquid Glass Extensions Coordinator & Popover Callbacks (Free Drag & Drop Across All Toolbar Zones & Button Groups)
        extensionsCoordinator.registerMergedGroup(sidebarCapsule, for: .inSidebarGroup)
        extensionsCoordinator.registerMergedGroup(backForwardCapsule, for: .inBackForwardGroup)
        extensionsCoordinator.registerMergedGroup(rightActionCapsule, for: .inRightActionsGroup)

        extensionsCoordinator.onClickExtension = { [weak self] item, anchor in
            guard let self else { return }
            self.dismissAddressBarPopover()
            // Match macOS system appearance (same as Chromium's `prefers-color-scheme`) so extension HTML text
            // NEVER renders dark text on dark glass when viewing a dark-header website in Light Mode.
            let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            self.extensionPopoverController.toggleExtensionPopup(
                for: item,
                relativeTo: anchor,
                isDark: systemIsDark
            ) { [weak self] width, height, host in
                self?.engine.createExtensionPopupView(forExtensionID: item.id, width: width, height: height, parentView: host)
            }
        }
        extensionsCoordinator.onManageExtension = { [weak self] item, anchor in
            self?.showManageExtensionsPopover(relativeTo: anchor, selectingExtensionID: item.id)
        }
        extensionsCoordinator.onRemoveExtension = { [weak self] extID in
            self?.removeExtension(withID: extID)
        }
        extensionsCoordinator.onOpenChromeWebStore = { [weak self] in
            self?.openChromeWebStore()
        }
        extensionsCoordinator.onCustomizeToolbar = { [weak self] in
            self?.toggleCustomizeToolbarSheet()
        }
        extensionsCoordinator.contextMenuProvider = { [weak self] extID in
            self?.engine.extensionContextMenuItems(forExtensionID: extID) ?? []
        }
        extensionsCoordinator.onTriggerContextMenuItem = { [weak self] extID, menuItemID in
            guard let self else { return }
            self.engine.triggerExtensionContextMenuItem(
                itemID: menuItemID,
                forExtensionID: extID,
                pageURL: self.activeTab?.currentURL
            )
        }
        extensionsCoordinator.onDragWillBegin = { [weak self] in
            self?.dismissAddressBarPopover()
            self?.extensionPopoverController.close()
        }

        customizeToolbarSheet.toolbarRectInWindowProvider = { [weak self] in
            guard let self else { return .zero }
            return self.toolbarBarView.convert(self.toolbarBarView.bounds, to: nil)
        }
        customizeToolbarSheet.onToggleNativeItem = { [weak self] id, visible in
            ToolbarCustomizationStore.shared.setVisible(visible, for: id)
            self?.applyToolbarCustomization(animated: true)
        }
        customizeToolbarSheet.onDropNativeItem = { [weak self] id, ptInWindow in
            self?.handleDropNativeToolbarItem(id, atWindowPoint: ptInWindow)
        }
        customizeToolbarSheet.onToggleExtension = { [weak self] ext, visible in
            guard let self else { return }
            self.extensionsCoordinator.setHiddenFromToolbar(!visible, forExtensionID: ext.id)
            if self.customizeToolbarSheet.isPresented {
                self.setToolbarCustomizeWobble(true)
            }
        }
        customizeToolbarSheet.onDropExtension = { [weak self] ext, ptInWindow in
            guard let self else { return }
            self.extensionsCoordinator.placeExtensionFromSheet(ext, atWindowPoint: ptInWindow)
            if self.customizeToolbarSheet.isPresented {
                self.setToolbarCustomizeWobble(true)
            }
        }
        customizeToolbarSheet.onResetDefaultSet = { [weak self] in
            ToolbarCustomizationStore.shared.resetToDefaults()
            self?.extensionsCoordinator.resetLayoutToDefault()
            self?.applyToolbarCustomization(animated: true)
        }
        customizeToolbarSheet.onDismiss = { [weak self] in
            self?.cancelNativeToolbarDrag()
            self?.setToolbarCustomizeWobble(false)
            self?.applyToolbarCustomization(animated: true, refreshSheet: false)
        }
        extensionsCoordinator.onToolbarItemsDidChange = { [weak self] in
            guard let self, self.customizeToolbarSheet.isPresented else { return }
            let installed = self.engine.installedExtensions()
            let hiddenIDs = Set(installed.map(\.id).filter { self.extensionsCoordinator.isHiddenFromToolbar($0) })
            self.customizeToolbarSheet.refreshState(
                extensions: installed,
                hiddenExtensionIDs: hiddenIDs,
                isDark: self.chromeController.currentTheme.prefersLightInk
            )
            self.setToolbarCustomizeWobble(true)
        }
        toolbarCustomizationObserver = NotificationCenter.default.addObserver(
            forName: ToolbarCustomizationStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyToolbarCustomization(animated: true)
        }
        applyToolbarCustomization(animated: false)
        extensionsCoordinator.onLayoutNeedsUpdate = { [weak self] animated in
            self?.updateToolbarExtensionConstraints(animated: animated)
        }
        extensionsCoordinator.landmarkProvider = { [weak self] in
            guard let self else {
                let dummy = NSView()
                return ToolbarExtensionLandmarks(
                    toolbarView: dummy,
                    overlayHostView: dummy,
                    sidebarView: dummy,
                    backForwardView: dummy,
                    addressBarView: dummy,
                    rightActionsView: dummy
                )
            }
            // Zone hit-testing assumes sidebar / back-forward sit left of the address bar; once the user moves them
            // behind it they are replaced by hidden stand-ins so extension drags keep resolving sensibly.
            let store = ToolbarCustomizationStore.shared
            let hiddenStandIn = NSView()
            hiddenStandIn.isHidden = true
            return ToolbarExtensionLandmarks(
                toolbarView: self.toolbarBarView,
                overlayHostView: self.rootView,
                sidebarView: store.clusterSide(.sidebar) == .left ? self.sidebarCluster : hiddenStandIn,
                backForwardView: store.clusterSide(.backForward) == .left ? self.backForwardCluster : hiddenStandIn,
                addressBarView: self.tabAddressBar,
                rightActionsView: self.rightGlassContainer
            )
        }

        extensionPopoverController.onCloseExtensionPopup = { [weak self] extID in
            self?.engine.closeExtensionPopupView(forExtensionID: extID)
        }
        extensionPopoverController.onLoadUnpackedRequested = { [weak self] in
            self?.promptLoadUnpackedExtension()
        }
        extensionPopoverController.onInstallCRXRequested = { [weak self] in
            self?.promptInstallCRXExtension()
        }
        extensionPopoverController.onOpenChromeWebStore = { [weak self] in
            self?.openChromeWebStore()
        }
        extensionPopoverController.onRemoveExtension = { [weak self] extID in
            self?.removeExtension(withID: extID)
        }
        extensionPopoverController.onToggleToolbarPin = { [weak self] extID, showInToolbar in
            self?.extensionsCoordinator.setHiddenFromToolbar(!showInToolbar, forExtensionID: extID)
        }

        engine.onExtensionsDidUpdate = { [weak self] exts in
            DispatchQueue.main.async {
                self?.refreshExtensionsUI(exts)
            }
        }
        refreshExtensionsUI(engine.installedExtensions(), animated: false)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .safariumSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let key = note.userInfo?["key"] as? String ?? ""
            if key == BrowserSettings.Key.showFullAddress || key == BrowserSettings.Key.alwaysShowTabTitles {
                self.refreshToolbarUI()
            } else if key == BrowserSettings.Key.showWebsiteColor || key == BrowserSettings.Key.refractiveGlassToolbar || key == BrowserSettings.Key.refractiveGlassFrost {
                let stripH = self.separateTabStripHeightConstraint?.constant ?? 0
                self.toolbarFrostHeightConstraint?.constant = ToolbarGlassView.activeTotalHeight + stripH
                self.updateVerticalTabRailVisibility(animated: false)
                self.applyAdaptiveTheme(self.chromeController.currentTheme, animated: key != BrowserSettings.Key.refractiveGlassFrost)

            } else if key == BrowserSettings.Key.tabLayout {
                self.applyTabLayoutPreference(animated: true)
            } else if key == BrowserSettings.Key.autoCloseTabs {
                self.pruneExpiredInactiveTabs()
            } else if key == BrowserSettings.Key.touchIDLockedPrivate && !BrowserSettings.shared.requireTouchIDForPrivate {
                self.unlockPrivateWindowImmediately()
            } else if key == BrowserSettings.Key.preventTracking {
                for tab in self.tabs {
                    let rawHost = tab.currentURL?.isWebURL == true ? (tab.currentURL?.host ?? "") : ""
                    let cleanHost = rawHost.isEmpty ? "" : PrivacyDomainClassifier.sanitizeHostForStorage(rawHost)
                    let effective = self.effectiveProtectionsEnabled(forHost: cleanHost)
                    PrivacyReportStore.shared.updateProtectionsEnabled(effective, forTabID: tab.tabID, isPrivate: self.isPrivate)
                }
                self.refreshPrivacyShieldUI()
            } else if key == BrowserSettings.Key.httpsOnlyMode {
                self.refreshPrivacyShieldUI()
            }
        }

        separateTabStripView.onSelectTab = { [weak self] id in
            guard let self, let idx = self.tabs.firstIndex(where: { $0.tabID == id }) else { return }
            self.tabHoverPreviewController.dismiss(animated: false)
            self.selectTab(at: idx)
        }
        separateTabStripView.onCloseTab = { [weak self] id in
            guard let self, self.tabs.count > 1, let idx = self.tabs.firstIndex(where: { $0.tabID == id }) else { return }
            self.tabHoverPreviewController.dismiss(animated: false)
            self.closeTab(at: idx)
        }
        separateTabStripView.onReorderTabs = { [weak self] orderedIDs in
            self?.reorderTabs(matchingOrder: orderedIDs)
        }
        separateTabStripView.canTearOffSingleTab = { true }
        separateTabStripView.onBeginTabTearOff = { [weak self] tabID, pillRectInScreen, cursorOffsetInPill, mouseScreen in
            self?.tabHoverPreviewController.dismiss(animated: false)
            self?.beginTabTearOff(
                tabID: tabID,
                pillRectInScreen: pillRectInScreen,
                cursorOffsetInPill: cursorOffsetInPill,
                mouseScreen: mouseScreen
            )
        }
        separateTabStripView.onTabHoverChanged = { [weak self] id, anchorView, hovered in
            self?.handleTabHoverPreview(tabID: id, anchorView: anchorView, hovered: hovered, isVertical: false)
        }
        separateTabStripView.onDropURL = { [weak self] url, targetTabID, openInNewTab in
            guard let self else { return }
            self.openURL(url, inTabID: targetTabID, newTab: openInNewTab)
        }
        verticalTabRailView.onSelectTab = { [weak self] id in
            guard let self, let idx = self.tabs.firstIndex(where: { $0.tabID == id }) else { return }
            self.tabHoverPreviewController.dismiss(animated: false)
            self.selectTab(at: idx)
        }
        verticalTabRailView.onCloseTab = { [weak self] id in
            guard let self, self.tabs.count > 1, let idx = self.tabs.firstIndex(where: { $0.tabID == id }) else { return }
            self.tabHoverPreviewController.dismiss(animated: false)
            self.closeTab(at: idx)
        }
        verticalTabRailView.onReorderTabs = { [weak self] orderedIDs in
            self?.reorderTabs(matchingOrder: orderedIDs)
        }
        verticalTabRailView.canTearOffSingleTab = { true }
        verticalTabRailView.onBeginTabTearOff = { [weak self] tabID, pillRectInScreen, cursorOffsetInPill, mouseScreen in
            self?.tabHoverPreviewController.dismiss(animated: false)
            self?.beginTabTearOff(
                tabID: tabID,
                pillRectInScreen: pillRectInScreen,
                cursorOffsetInPill: cursorOffsetInPill,
                mouseScreen: mouseScreen
            )
        }
        verticalTabRailView.onDropURL = { [weak self] url, targetTabID, openInNewTab in
            guard let self else { return }
            self.openURL(url, inTabID: targetTabID, newTab: openInNewTab)
        }
        verticalTabRailView.onTabHoverChanged = { [weak self] id, anchorView, hovered in
            self?.handleTabHoverPreview(tabID: id, anchorView: anchorView, hovered: hovered, isVertical: true)
        }
        privateLockOverlay.onUnlockRequested = { [weak self] in
            self?.authenticateAndUnlockPrivateWindow()
        }

        findBarView.onSearchChanged = { [weak self] query in
            guard let self, let tab = self.activeTab, !tab.isStartPage else { return }
            if query.isEmpty {
                tab.stopFinding(clearSelection: true)
            } else {
                tab.findText(query, forward: true, matchCase: false, findNext: false)
            }
        }
        findBarView.onFindNext = { [weak self] in
            self?.findNextMatch()
        }
        findBarView.onFindPrevious = { [weak self] in
            self?.findPreviousMatch()
        }
        findBarView.onDismiss = { [weak self] in
            self?.hideFindBar()
        }

        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.pruneExpiredInactiveTabs()
        }

        websitePolicyObserver = NotificationCenter.default.addObserver(
            forName: .safariumWebsitePoliciesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let cat = note.userInfo?["category"] as? String
            if cat == nil || cat == "Page Zoom" {
                self.applySavedZoomPolicyToOpenTabs()
            }
            if cat == nil || cat == "Content Blockers" {
                for tab in self.tabs {
                    guard let url = tab.currentURL, url.isWebURL, let host = url.host, !host.isEmpty else { continue }
                    let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(host)
                    let enabled = self.effectiveProtectionsEnabled(forHost: cleanHost)
                    PrivacyReportStore.shared.updateProtectionsEnabled(enabled, forTabID: tab.tabID, isPrivate: self.isPrivate)
                }
                self.refreshPrivacyShieldUI()
            }
        }
    }

    private func installEventMonitors() {
        // 1. Track last click origin for Download fly-in + Command+Drag extension reordering (before NSThemeFrame/WindowServer!)
        //    + click outside ANYWHERE unfocuses address bar immediately (including live Chromium webview, Start Page, sidebar, toolbar)
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .flagsChanged, .mouseMoved]) { [weak self] event in
            guard let self, let win = self.window else { return event }

            // Dynamically suppress WindowServer's native titlebar drag hijack while hovering over
            // any extensions capsule, the tab track, or while Command is held in the active Safarium window.
            if event.type == .flagsChanged || event.type == .mouseMoved {
                guard event.window === win else { return event }
                if !self.extensionsCoordinator.isDragSessionActive && !self.isAnyTabDragActive && self.nativeToolbarDrag == nil {
                    let cmdDown = event.modifierFlags.contains(.command)
                    let winPt = event.locationInWindow
                    let overExt = self.extensionsCoordinator.containsWindowPoint(winPt)
                    let overTabs = self.isPointInAnyTabTrack(winPt)
                    let isCustomizing = self.customizeToolbarSheet.isPresented
                    let shouldBeMovable = !(isCustomizing || cmdDown || overExt || overTabs)
                    if win.isMovable != shouldBeMovable {
                        win.isMovable = shouldBeMovable
                    }
                }
                return event
            }

            guard event.window === win else { return event }

            if event.type == .leftMouseDragged {
                if self.nativeToolbarDrag != nil {
                    self.continueNativeToolbarDrag(event)
                    return nil
                }
                if self.extensionsCoordinator.isDragSessionActive {
                    self.extensionsCoordinator.continueDrag(event)
                    return nil
                }
                return event
            }
            if event.type == .leftMouseUp {
                if self.nativeToolbarDrag != nil {
                    self.endNativeToolbarDrag(event)
                    win.isMovable = !self.customizeToolbarSheet.isPresented
                    return nil
                }
                if self.extensionsCoordinator.isDragSessionActive {
                    self.extensionsCoordinator.endDrag(event)
                    let cmdDown = event.modifierFlags.contains(.command)
                    let overExt = self.extensionsCoordinator.containsWindowPoint(event.locationInWindow)
                    let overTabs = self.isPointInAnyTabTrack(event.locationInWindow)
                    win.isMovable = !(self.customizeToolbarSheet.isPresented || cmdDown || overExt || overTabs)
                    return nil
                }
                if !self.isAnyTabDragActive {
                    let cmdDown = event.modifierFlags.contains(.command)
                    let overExt = self.extensionsCoordinator.containsWindowPoint(event.locationInWindow)
                    let overTabs = self.isPointInAnyTabTrack(event.locationInWindow)
                    win.isMovable = !(self.customizeToolbarSheet.isPresented || cmdDown || overExt || overTabs)
                }
                return event
            }

            if event.type == .leftMouseDown {
                self.lastMouseDownInWindow = event.locationInWindow
                if self.extensionsCoordinator.beginDragIfHit(event) {
                    win.isMovable = false
                    return nil
                }
                if self.customizeToolbarSheet.isPresented && self.beginNativeToolbarDragIfHit(event) {
                    win.isMovable = false
                    return nil
                }
                let overTabs = self.isPointInAnyTabTrack(event.locationInWindow)
                if overTabs || self.customizeToolbarSheet.isPresented {
                    win.isMovable = false
                } else if !win.isMovable && !event.modifierFlags.contains(.command) {
                    win.isMovable = true
                }
            }
            if self.tabAddressBar.isAddressBarEditing {
                let anchor = self.tabAddressBar.activePillAnchorView
                let ptInPill = anchor.convert(event.locationInWindow, from: nil)
                if !anchor.bounds.contains(ptInPill) {
                    self.tabAddressBar.endAddressEditing(restoreURL: true)
                    self.dismissAddressBarPopover()
                    win.makeFirstResponder(nil)
                }
            }
            return event
        }

        // 2. Middle-click (`buttonNumber == 2`) on ANY tab slot closes that tab (disabled when only 1 tab is open).
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, event.buttonNumber == 2 else { return event }
            if event.type == .otherMouseDown {
                let hitID = self.tabIDAtWindowPoint(event.locationInWindow)
                guard let hitID else {
                    self.middleClickPressedTabID = nil
                    return event
                }
                if self.tabs.count <= 1 {
                    self.middleClickPressedTabID = nil
                    return nil
                }
                self.middleClickPressedTabID = hitID
                return nil
            }
            if event.type == .otherMouseUp {
                let pressedID = self.middleClickPressedTabID
                self.middleClickPressedTabID = nil
                if let pressedID,
                   self.tabs.count > 1,
                   self.tabIDAtWindowPoint(event.locationInWindow) == pressedID,
                   let idx = self.tabs.firstIndex(where: { $0.tabID == pressedID }) {
                    self.closeTab(at: idx)
                    return nil
                }
            }
            return event
        }

        // 2b. Native macOS right-click on toolbar background / native toolbar buttons -> "Customize Toolbar…"
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let ptInToolbar = self.toolbarBarView.convert(event.locationInWindow, from: nil)
            guard self.toolbarBarView.bounds.contains(ptInToolbar) else { return event }

            // Let extension icon buttons open their own rich context menu (<Extension Name> > + Manage + Customize)
            if self.extensionsCoordinator.containsWindowPoint(event.locationInWindow) {
                return event
            }
            // Let address bar text field open standard Cut/Copy/Paste when editing
            if self.window?.firstResponder is NSTextView {
                let ptInAddr = self.tabAddressBar.convert(event.locationInWindow, from: nil)
                if self.tabAddressBar.bounds.contains(ptInAddr) {
                    return event
                }
            }

            // Native Safari tab right-click menu when clicking on any tab pill (active or inactive)
            if let hitTabID = self.tabAddressBar.tabID(atWindowPoint: event.locationInWindow),
               let tabIdx = self.tabs.firstIndex(where: { $0.tabID == hitTabID }) {
                let menu = self.buildTabContextMenu(forTabAt: tabIdx)
                NSMenu.popUpContextMenu(menu, with: event, for: self.tabAddressBar)
                return nil
            }

            let menu = NSMenu(title: "Toolbar")
            let customizeItem = NSMenuItem(
                title: "Customize Toolbar…",
                action: #selector(self.menuCustomizeToolbarAction),
                keyEquivalent: ""
            )
            customizeItem.target = self
            menu.addItem(customizeItem)
            NSMenu.popUpContextMenu(menu, with: event, for: self.toolbarBarView)
            return nil
        }

        // 3. Full keyboard navigation: Tab Overview arrows/Return/Delete/Esc, Ctrl+Tab / Ctrl+Shift+Tab,
        //    Cmd+Opt+Left/Right tab cycling, Cmd+Left/Right Back/Forward, Cmd+= Zoom In, Esc dismissal,
        //    and Start Page Space/Arrow/PageUp/PageDown/Home/End scrolling.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let win = self.window else { return event }
            let isSameOrChildWindow = (event.window === win)
                || (event.window == nil && win.isKeyWindow)
                || (win.childWindows?.contains(where: { $0 === event.window }) == true)
            guard isSameOrChildWindow else { return event }
            // Strip `.numericPad` & `.function` (always set on macOS arrow/page/home/end keys!)
            let primaryMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let isEditingAppKitText = (win.firstResponder is NSTextView)
            let frClassName = win.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? ""
            let isWebViewFocused = frClassName.contains("RenderWidgetHostView")

            if self.tabOverviewView.isPresented && !self.tabAddressBar.isCurrentlyEditingAddress {
                if self.tabOverviewView.handleKeyDown(event) {
                    return nil
                }
            }

            if event.keyCode == 53, primaryMods.isEmpty { // Escape
                let hasOverlay = (self.passwordsPasskeyManager?.hasActiveBiometricSheet == true)
                    || self.customizeToolbarSheet.isPresented
                    || !self.findBarView.isHidden
                    || self.pageMenuPopover.isShown
                    || self.addressBarPopover.isShown
                    || self.tabOverviewView.isPresented
                    || self.extensionsCoordinator.isDragSessionActive
                if hasOverlay {
                    self.handleEscapeOrStop()
                    return nil
                }
            }

            // Ctrl+Tab / Ctrl+Shift+Tab -> Next / Previous Tab
            if event.keyCode == 48 {
                if primaryMods == .control {
                    self.cycleNextTab()
                    return nil
                } else if primaryMods == [.control, .shift] {
                    self.cyclePreviousTab()
                    return nil
                }
            }

            // Cmd+Opt+Left / Cmd+Opt+Right -> Previous / Next Tab (standard macOS Safari)
            if primaryMods == [.command, .option] {
                if event.keyCode == 123 { // Left arrow
                    self.cyclePreviousTab()
                    return nil
                } else if event.keyCode == 124 { // Right arrow
                    self.cycleNextTab()
                    return nil
                }
            }

            // Keyboard Zoom shortcuts (layout-aware for Turkish Q + US + Numpad):
            // - Turkish Q: `-` (kc=24) zooms OUT, `*`/`?` (kc=27) zooms IN, `Shift+4` (`+`) / `Shift+0` (`=`) zoom IN
            // - US / ISO: `-` (kc=27) zooms OUT, `=`/`+` (kc=24) zooms IN
            // - Numpad: `+` (kc=69) zooms IN, `-` (kc=78) zooms OUT, `0` (kc=82) resets zoom
            if primaryMods == .command || primaryMods == [.command, .shift] {
                let ch = event.characters ?? ""
                let chIgn = event.charactersIgnoringModifiers ?? ""

                let isZoomOut = (ch == "-" || chIgn == "-" || ch == "_" || event.keyCode == 78)
                let isTurkishQuestionZoomIn = (event.keyCode == 27 && (ch == "*" || ch == "?" || chIgn == "*" || chIgn == "?"))
                let isZoomIn = (ch == "+" || ch == "=" || chIgn == "+" || chIgn == "=" || event.keyCode == 69 || isTurkishQuestionZoomIn)

                if isZoomOut {
                    self.zoomOutActiveTab()
                    return nil
                }
                if isZoomIn {
                    self.zoomInActiveTab()
                    return nil
                }
                if primaryMods == .command && (chIgn == "0" || event.keyCode == 82) {
                    self.resetZoomActiveTab()
                    return nil
                }
            }

            if self.handleWindowKeyEquivalent(event) {
                return nil
            }

            // Cmd+Shift+[ / Cmd+Shift+] (also `{` / `}` on US, `Ğ` / `Ü` physical keys kc=33/30) -> Prev / Next Tab
            if primaryMods == [.command, .shift] {
                let ch = event.characters ?? ""
                let chIgn = event.charactersIgnoringModifiers ?? ""
                if ch == "{" || chIgn == "[" || event.keyCode == 33 {
                    self.cyclePreviousTab()
                    return nil
                }
                if ch == "}" || chIgn == "]" || event.keyCode == 30 {
                    self.cycleNextTab()
                    return nil
                }
            }

            // F5 / Cmd+F5 -> Reload / Hard Reload, F12 -> Web Inspector (universal browser shortcuts)
            if event.keyCode == 96 { // F5
                if primaryMods == .command || primaryMods == .shift {
                    self.reloadActiveTabIgnoringCache()
                    return nil
                } else if primaryMods.isEmpty {
                    self.reloadActiveTab()
                    return nil
                }
            }
            if event.keyCode == 111 && primaryMods.isEmpty { // F12
                self.showDevToolsForActiveTab()
                return nil
            }

            // Cmd+Opt+J (Chrome Console) / Cmd+Shift+C (Inspect Element) -> Web Inspector
            if primaryMods == [.command, .option],
               (event.charactersIgnoringModifiers?.lowercased() == "j") {
                self.showDevToolsForActiveTab()
                return nil
            }
            if primaryMods == [.command, .shift],
               (event.charactersIgnoringModifiers?.lowercased() == "j") {
                self.toggleDownloadsPopover()
                return nil
            }

            // Cmd+Left / Cmd+Right -> History Back / Forward
            // When Chromium's web view is focused, SXBrowserClient::OnPreKeyEvent handles Cmd+Left/Right
            // so editable webpage inputs still jump to line start/end while non-editable pages navigate.
            // When Start Page, Error Page, or non-text AppKit views are focused, handle immediately here.
            if primaryMods == .command && (event.keyCode == 123 || event.keyCode == 124) {
                if !isEditingAppKitText && !isWebViewFocused {
                    if event.keyCode == 123 {
                        self.navigateBackInActiveTab()
                    } else {
                        self.navigateForwardInActiveTab()
                    }
                    return nil
                }
                return event
            }

            // Native Start Page keyboard scrolling (Space, Shift+Space, Up/Down, PageUp/PageDown, Home/End, Cmd+Up/Down)
            if let tab = self.activeTab, tab.isStartPage,
               !self.tabOverviewView.isPresented,
               !self.addressBarPopover.isShown,
               !isEditingAppKitText {
                if event.keyCode == 49 && (primaryMods.isEmpty || primaryMods == .shift) { // Space / Shift+Space
                    let dir = primaryMods == .shift ? 1 : -1
                    self.elasticScrollEngine.triggerSpaceScroll(direction: dir, isRepeat: event.isARepeat, isStartPage: true)
                    return nil
                }
                if primaryMods.isEmpty {
                    switch event.keyCode {
                    case 126: // Up arrow
                        self.startPageView.scrollByDeltaY(64)
                        return nil
                    case 125: // Down arrow
                        self.startPageView.scrollByDeltaY(-64)
                        return nil
                    case 116: // Page Up
                        self.startPageView.scrollByDeltaY(max(240, self.startPageView.bounds.height * 0.85))
                        return nil
                    case 121: // Page Down
                        self.startPageView.scrollByDeltaY(-max(240, self.startPageView.bounds.height * 0.85))
                        return nil
                    case 115: // Home
                        self.startPageView.scrollToEdge(top: true)
                        return nil
                    case 119: // End
                        self.startPageView.scrollToEdge(top: false)
                        return nil
                    default:
                        break
                    }
                } else if primaryMods == .command {
                    if event.keyCode == 126 { // Cmd+Up
                        self.startPageView.scrollToEdge(top: true)
                        return nil
                    } else if event.keyCode == 125 { // Cmd+Down
                        self.startPageView.scrollToEdge(top: false)
                        return nil
                    }
                }
            }
            return event
        }

        // 4. Native 120fps Pinch-to-Zoom + Page Overshoot + GPU-Camera Pinch-to-Tab-Overview:
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if self.elasticScrollEngine.isOverscrolling {
                self.elasticScrollEngine.resetImmediately()
            }
            return self.handleMagnify(event) ? nil : event
        }

        // 4b. Native 120Hz Trackpad Back/Forward Swipe Navigation + Elastic Scrolling & Pull-to-Refresh Engine:
        //     Horizontal two-finger trackpad swipes reveal the previous/next page snapshot underneath;
        //     vertical boundary scrolling drives crisp GPU rubber-band + pull-to-refresh.
        //     Also consume `.swipe` (3-finger trackpad swipe) natively so Chromium never spawns a back/forward arrow overlay.
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  let tab = self.activeTab,
                  !self.tabOverviewView.isPresented,
                  !self.addressBarPopover.isShown,
                  !self.pinchCoordinator.isActive else {
                return event
            }
            if event.type == .swipe {
                if event.deltaX > 0 && tab.canGoBack {
                    self.navigateBackInActiveTab()
                } else if event.deltaX < 0 && tab.canGoForward {
                    self.navigateForwardInActiveTab()
                }
                return nil
            }
            let ptInStage = self.contentStageView.convert(event.locationInWindow, from: nil)
            let pointerOverStage = self.contentStageView.bounds.contains(ptInStage)
            guard pointerOverStage || self.elasticScrollEngine.isOverscrolling || self.swipeNavigationController.isTrackingOrAnimating else {
                return event
            }

            if !self.elasticScrollEngine.isOverscrolling {
                if self.swipeNavigationController.handleScrollWheel(event) {
                    return nil
                }
            }

            guard !tab.isStartPage, self.tabLoadErrors[tab.tabID] == nil else {
                return event
            }
            self.syncElasticMetrics(for: tab)
            let phase = event.phase
            let momPhase = event.momentumPhase
            let trackpadActive =
                phase.contains(.began) || phase.contains(.changed) || phase.contains(.mayBegin) ||
                momPhase.contains(.began) || momPhase.contains(.changed)
            let momentumEnded = momPhase.contains(.ended) || momPhase.contains(.cancelled)
            let fingersEnded = phase.contains(.ended) || phase.contains(.cancelled)
            if trackpadActive {
                self.scrollIdleWorkItem?.cancel()
                self.scrollIdleWorkItem = nil
                if !self.isTrackpadScrollActive {
                    self.isTrackpadScrollActive = true
                    tab.setScrollInteractionActive(true)
                }
            } else if momentumEnded || fingersEnded {
                // Bridge the 1-frame gap between finger lift (`phase == .ended`) and momentum start
                // (`momentumPhase == .began`) so top-edge color readbacks NEVER fire mid-fling or mid-bounce.
                self.scrollIdleWorkItem?.cancel()
                let settleDelay: TimeInterval = momentumEnded ? 0.06 : 0.14
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.scrollIdleWorkItem = nil
                    self.isTrackpadScrollActive = false
                    if !self.elasticScrollEngine.isElasticInteractionActive {
                        self.activeTab?.setScrollInteractionActive(false)
                        if let pending = self.pendingAdaptiveTheme {
                            self.pendingAdaptiveTheme = nil
                            self.applyAdaptiveTheme(pending.theme, animated: pending.animated)
                        }
                    }
                }
                self.scrollIdleWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
            }
            let consumed = self.elasticScrollEngine.handleScrollWheel(event)
            if consumed { return nil }
            if let residual = self.elasticScrollEngine.takeResidualForwardDeltaY() {
                return Self.scrollEvent(event, withVerticalPointDelta: residual)
            }
            return event
        }

        // 5. Route extension/engine new-tab requests (e.g., chrome.runtime.openOptionsPage / chrome.tabs.create)
        //    strictly into native Safarium tabs — never raw Chrome windows!
        engineNewTabObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("SXEngineRuntimeRequestNewTabNotification"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let appDel = NSApp.delegate as? AppDelegate,
               let activeWC = appDel.activeWindowController,
               activeWC !== self {
                return
            }
            let url: URL? = (note.userInfo?["url"] as? URL)
                ?? (note.userInfo?["url"] as? String).flatMap { URL(string: $0) }
            guard let url else { return }
            self.extensionPopoverController.close()
            self.dismissAddressBarPopover()
            self.createNewTab(url: url, activate: true)
            self.window?.makeKeyAndOrderFront(nil)
        }

        // 5b. Route renderer Space / Shift+Space scrolls into 120Hz touchpad-inertia scrolling
        spaceScrollObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("SXBrowserTabRequestSpaceScrollNotification"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let window = self.window, window.isKeyWindow,
                  let tab = self.activeTab, !tab.isStartPage,
                  self.tabLoadErrors[tab.tabID] == nil,
                  !self.tabOverviewView.isPresented,
                  !self.addressBarPopover.isShown else { return }
            let dir = (note.userInfo?["direction"] as? NSNumber)?.intValue ?? -1
            let isRepeat = (note.userInfo?["isRepeat"] as? NSNumber)?.boolValue ?? false
            self.syncElasticMetrics(for: tab)
            self.elasticScrollEngine.triggerSpaceScroll(direction: dir, isRepeat: isRepeat, isStartPage: false)
        }
    }

    private static func tabShortcutDigit(for event: NSEvent) -> Int? {
        if let chIgn = event.charactersIgnoringModifiers, let digit = Int(chIgn), (1...9).contains(digit) {
            return digit
        }
        switch event.keyCode {
        case 18, 83: return 1
        case 19, 84: return 2
        case 20, 85: return 3
        case 21, 86: return 4
        case 23, 87: return 5
        case 22, 88: return 6
        case 26, 89: return 7
        case 28, 91: return 8
        case 25, 92: return 9
        default: return nil
        }
    }

    private func handleWindowKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let primaryMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard primaryMods == .command else { return false }

        if BrowserSettings.shared.cmdNumberSwitchesTabs, let digit = Self.tabShortcutDigit(for: event) {
            selectTabShortcut(tag: digit - 1)
            return true
        }
        let chIgn = (event.charactersIgnoringModifiers ?? "").lowercased()
        let isCmdS = (chIgn == "s")
            || (event.keyCode == 1 && (chIgn.isEmpty || !chIgn.unicodeScalars.allSatisfy(\.isASCII)))
        if isCmdS {
            saveActiveTab()
            return true
        }
        return false
    }

    private func findRenderWidgetHostView(in root: NSView) -> NSView? {
        for sub in root.subviews {
            let name = NSStringFromClass(type(of: sub))
            if name.contains("RenderWidgetHostView") {
                return sub
            }
            if let nested = findRenderWidgetHostView(in: sub) {
                return nested
            }
        }
        return nil
    }

    private func dispatchSyntheticTouchpadScrollDelta(_ deltaY: CGFloat) {
        guard let tab = activeTab else { return }
        if tab.isStartPage {
            startPageView.scrollByDeltaY(deltaY)
            return
        }
        guard let window else { return }
        let targetView = findRenderWidgetHostView(in: tab.contentView) ?? tab.contentView
        let intDelta = Int32(deltaY.rounded())
        guard intDelta != 0 || abs(deltaY) >= 0.25 else { return }
        let pxDelta: Int32 = intDelta != 0 ? intDelta : (deltaY > 0 ? 1 : -1)

        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: pxDelta,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        // Place synthetic scroll event at current mouse position if over web content (so hovered inner scrollers
        // like Gemini chat scroll naturally), otherwise center of the web viewport.
        let mouseScreen = NSEvent.mouseLocation
        let mouseWin = window.convertPoint(fromScreen: mouseScreen)
        let mouseInStage = contentStageView.convert(mouseWin, from: nil)
        let targetScreenPt: NSPoint
        if contentStageView.bounds.contains(mouseInStage) {
            targetScreenPt = mouseScreen
        } else {
            let centerInWin = webContentHost.convert(NSPoint(x: webContentHost.bounds.midX, y: webContentHost.bounds.midY), to: nil)
            targetScreenPt = window.convertPoint(toScreen: centerInWin)
        }
        let primaryH = NSScreen.screens.first?.frame.height ?? 900.0
        cg.location = CGPoint(x: targetScreenPt.x, y: primaryH - targetScreenPt.y)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pxDelta))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(deltaY))

        if let scrollEvent = NSEvent(cgEvent: cg) {
            targetView.scrollWheel(with: scrollEvent)
        }
    }

    // MARK: - Safarium Native 120Hz Pinch State Machine (Delegated to PinchGestureCoordinator)

    /// Returns true when the event is consumed (the webpage must not see it).
    private func handleMagnify(_ e: NSEvent) -> Bool {
        guard let tab = activeTab else { return false }
        let ctx = PinchGestureCoordinator.Context(
            activeTab: tab,
            mainPaneView: mainPaneView,
            tabOverviewView: tabOverviewView,
            currentTheme: chromeController.currentTheme,
            buildOverviewCards: { [weak self] in self?.buildOverviewCardModels() ?? [] },
            onDismissAddressBarPopover: { [weak self] in self?.dismissAddressBarPopover() },
            onSetOverviewSnapshotCapturePaused: { [weak self] paused in self?.setOverviewSnapshotCapturePaused(paused) },
            onUpdateToolbarForOverview: { [weak self] active in self?.updateToolbarForTabOverview(active) },
            onSelectTabByID: { [weak self] tid in
                guard let self, let idx = self.tabs.firstIndex(where: { $0.tabID == tid }) else { return }
                self.selectTab(at: idx)
            }
        )
        return pinchCoordinator.handleMagnify(e, context: ctx)
    }

    private func navigateActiveTab(to url: URL) {
        if url.scheme?.lowercased() == "http",
           BrowserSettings.shared.warnBeforeHTTP,
           let host = url.host?.lowercased(), !host.isEmpty,
           !allowedHTTPHosts.contains(host),
           let win = window {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Not Secure Connection"
            alert.informativeText = "“\(host)” does not use HTTPS encryption. Information you send or view on this website could be seen by others."
            alert.addButton(withTitle: "Try HTTPS")
            alert.addButton(withTitle: "Continue Over HTTP")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: win) { [weak self] resp in
                guard let self else { return }
                if resp == .alertFirstButtonReturn {
                    var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    comps?.scheme = "https"
                    if let upgraded = comps?.url {
                        self.performActiveTabNavigation(to: upgraded)
                    }
                } else if resp == .alertSecondButtonReturn {
                    self.allowedHTTPHosts.insert(host)
                    self.engine.allowInsecureHTTP(forHost: host)
                    self.performActiveTabNavigation(to: url)
                }
            }
            return
        }
        performActiveTabNavigation(to: url)
    }

    private func performActiveTabNavigation(to url: URL) {
        extensionPopoverController.close()
        if tabOverviewView.isPresented || overviewOpenTarget {
            overviewOpenTarget = false
            tabOverviewView.closeAnimated()
        }
        swipeNavigationController.cancelImmediately()
        let targetIsNative = (url.scheme?.lowercased() == "safarium") || InspectPageURL.isInspectURL(url)
        if let tab = activeTab {
            let outgoingPayload = (tab.isNativeInternalPage && !targetIsNative)
                ? captureOutgoingTransitionPayload(for: tab)
                : nil
            snapshotBeforeLeavingCurrentPage(for: tab)
            if let outgoingPayload {
                navigationTransitionCoordinator.beginNativeToWebTransition(
                    tabID: tab.tabID,
                    outgoingPayload: outgoingPayload
                )
            } else {
                navigationTransitionCoordinator.cancelImmediately()
                deferredRevealWebToolbarSyncTabID = nil
            }
            tabLoadErrors.removeValue(forKey: tab.tabID)
            reloadingErrorTabIDs.remove(tab.tabID)
            tabLastActiveAt[tab.tabID] = Date()
        }
        activeTab?.loadURL(url)
        updateStartPageVisibility()
        activeTab?.focusWebContent()
    }

    private func openInitialTabs() {
        if engine.isRealChromium {
            if let overrideStr = ProcessInfo.processInfo.environment["SAFARIUM_INITIAL_URL"],
               let overrideURL = URL(string: overrideStr) {
                createNewTab(url: overrideURL, activate: true)
                return
            }
            let opensMode = BrowserSettings.shared.opensWithIndex
            if !isPrivate && (opensMode == 0 || opensMode == 1) {
                let saved = BrowserSettings.shared.savedSession()
                if !saved.urls.isEmpty {
                    for (idx, u) in saved.urls.enumerated() {
                        createNewTab(url: u, activate: idx == saved.activeIndex)
                    }
                    return
                }
            }
            let target = BrowserSettings.shared.resolvedNewWindowURL(activeTabURL: nil)
            createNewTab(url: target, activate: true)
        } else {
            createNewTab(url: URL(string: "https://apple.com"), activate: true)
        }
    }

    /// Copy of a scroll-wheel event whose vertical delta is replaced by `dy` (used to forward only the part of a
    /// gesture step that is left after the elastic overscroll was unwound). Falls back to the original event.
    static func scrollEvent(_ event: NSEvent, withVerticalPointDelta dy: CGFloat) -> NSEvent {
        guard abs(dy) > 0.01, let cg = event.cgEvent?.copy() else { return event }
        // Scale every vertical delta field by the same factor so point/fixed/line views of the event stay consistent.
        // Order matters: writing the integer line delta recomputes the point delta (line * 8), so set the point delta last.
        let p0 = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let k = abs(p0) > 0.01 ? Double(dy) / p0 : nil
        let fixed = k.map { cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * $0 } ?? Double(dy) / 10.0
        let line = k.map { Int64((Double(cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * $0).rounded()) } ?? Int64((dy / 10.0).rounded())
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: line)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        return NSEvent(cgEvent: cg) ?? event
    }

    func persistCurrentSession() {
        guard !isPrivate else { return }
        var urls: [String] = []
        var savedActive = 0  // index of the active tab *within the saved list* (local/unsaveable tabs are skipped)
        for (i, tab) in tabs.enumerated() {
            if i == activeTabIndex { savedActive = urls.count }
            if tab.isStartPage { urls.append("safarium://start"); continue }
            guard let u = tab.currentURL, u.isWebURL else { continue }
            urls.append(u.absoluteString)
        }
        BrowserSettings.shared.saveSession(urls: urls, activeIndex: savedActive)
    }

    func showDevToolsForActiveTab() {
        activeTab?.showDevTools()
    }

    private func applySavedZoomPolicyToOpenTabs() {
        for tab in tabs where !tab.isStartPage {
            guard let url = tab.currentURL, url.isWebURL else { continue }
            let desired = BrowserSettings.shared.pageZoomFactor(for: url)
            if abs(tab.pageZoomFactor - desired) > 0.01 {
                tab.setPageZoomFactor(desired)
            }
        }
    }

    // MARK: - Tab Lifecycle

    @discardableResult
    func createNewTab(url: URL? = nil, activate: Bool = true) -> BrowserTabEngine {
        let tab = engine.createTab(initialURL: url, parentView: webContentHost, isPrivate: isPrivate)
        tab.delegate = self
        if let url, url.isWebURL, let rawHost = url.host, !rawHost.isEmpty {
            let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(rawHost)
            let sec = resolvedSecurityState(for: tab, url: url, cleanHost: cleanHost)
            let prot = effectiveProtectionsEnabled(forHost: cleanHost)
            PrivacyReportStore.shared.resetTabStats(
                forTabID: tab.tabID,
                host: cleanHost,
                isPrivate: isPrivate,
                securityState: sec,
                protectionsEnabled: prot
            )
        } else {
            PrivacyReportStore.shared.resetTabStats(
                forTabID: tab.tabID,
                host: "",
                isPrivate: isPrivate,
                securityState: .internalPage,
                protectionsEnabled: BrowserSettings.shared.preventCrossSiteTracking
            )
        }
        tabs.append(tab)
        if activate {
            let newIndex = tabs.count - 1
            if tabOverviewView.isPresented || overviewOpenTarget {
                setTabViewVisible(tab, visible: false)
                overviewOpenTarget = false
                let snap: NSImage?
                if tab.isStartPage {
                    snap = captureStartPageSnapshot(allowCached: true)
                } else if tab.isHistoryPage {
                    snap = captureHistoryPageSnapshot()
                } else {
                    snap = tab.cachedSnapshot
                }
                let cardModel = TabOverviewView.CardModel(
                    id: tab.tabID,
                    title: tab.title,
                    url: tab.currentURL,
                    favicon: tab.favicon,
                    snapshot: snap,
                    isActive: true
                )
                tabOverviewView.closeAnimatedIntoNewCard(
                    cardModel,
                    beforeHide: { [weak self] in
                        guard let self, let idx = self.tabs.firstIndex(where: { $0.tabID == tab.tabID }) else { return }
                        self.selectTab(at: idx, skipOverviewClose: true)
                    },
                    completion: { [weak self] in
                        if tab.isStartPage {
                            self?.tabAddressBar.focusAddressBar()
                        }
                    }
                )
                return tab
            }
            selectTab(at: newIndex)
            if tab.isStartPage {
                DispatchQueue.main.async { [weak self, weak tab] in
                    guard let self, let tab, self.activeTab === tab else { return }
                    self.tabAddressBar.focusAddressBar()
                }
            }
        } else {
            setTabViewVisible(tab, visible: false)
            refreshToolbarUI()
        }
        return tab
    }

    var webContentHostSubviewsForTesting: [NSView] { webContentHost.subviews }

    /// Hides the Chromium views of tabs switched away from, once the active tab has had time to reach the screen.
    private func scheduleDeferredTabHides(fallbackDelay: TimeInterval) {
        guard !deferredHiddenTabIDs.isEmpty else { return }
        deferredTabHideGeneration &+= 1
        let gen = deferredTabHideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [weak self] in
            guard let self, self.deferredTabHideGeneration == gen else { return }
            self.flushDeferredTabHides()
        }
    }

    private func flushDeferredTabHides() {
        let ids = deferredHiddenTabIDs
        deferredHiddenTabIDs.removeAll()
        let activeID = activeTab?.tabID
        for tab in tabs where ids.contains(tab.tabID) && tab.tabID != activeID {
            setTabViewVisible(tab, visible: false)
        }
    }

    private func setTabViewVisible(_ tab: BrowserTabEngine, visible: Bool) {
        let shouldShowChromium = visible && !tab.isNativeInternalPage
        let view = tab.contentView
        let targetHidden = !shouldShowChromium
        let targetAlpha: CGFloat = shouldShowChromium ? 1.0 : 0.0
        let subviewsMatch = view.subviews.allSatisfy {
            $0.isHidden == targetHidden && abs($0.alphaValue - targetAlpha) < 0.01 && ($0.layer?.isHidden ?? targetHidden) == targetHidden
        }
        if view.isHidden == targetHidden && abs(view.alphaValue - targetAlpha) < 0.01 && (view.layer?.isHidden ?? targetHidden) == targetHidden && subviewsMatch {
            // Already in the desired visibility state — avoid redundant setTabActive/layer thrash on link clicks.
            return
        }
        tab.setTabActive(shouldShowChromium)
        view.isHidden = targetHidden
        view.alphaValue = targetAlpha
        view.layer?.isHidden = targetHidden
        for sub in view.subviews {
            sub.isHidden = targetHidden
            sub.alphaValue = targetAlpha
            sub.layer?.isHidden = targetHidden
        }
    }

    private func performActionOnLocalTab(
        id tabID: String,
        action: (SafariWindowController, Int, BrowserTabEngine) -> Void
    ) {
        let controllers = NSApp?.windows.compactMap { $0.windowController as? SafariWindowController } ?? []
        let allControllers = controllers.contains(where: { $0 === self }) ? controllers : [self] + controllers
        for wc in allControllers {
            if let idx = wc.tabs.firstIndex(where: { $0.tabID == tabID }) {
                action(wc, idx, wc.tabs[idx])
                return
            }
        }
    }

    private func updateStartPageVisibility() {
        guard let tab = activeTab else {
            startPageView.isHidden = true
            historyPageView.isHidden = true
            inspectPageView.isHidden = true
            pageLoadErrorView.isHidden = true
            return
        }
        let isStart = tab.isStartPage
        let isHistory = tab.isHistoryPage
        let isInspect = tab.isInspectPage
        let isNative = isStart || isHistory || isInspect
        let loadError = isNative ? nil : tabLoadErrors[tab.tabID]
        let wasShowingStart = !startPageView.isHidden
        let wasShowingHistory = !historyPageView.isHidden
        let wasShowingInspect = !inspectPageView.isHidden
        let wasShowingError = !pageLoadErrorView.isHidden

        // Fast-path for normal webpage-to-webpage link clicks: Start/History/Inspect/Error views are already hidden
        // and the tab's Chromium view is already visible. Touching frost/chrome/subview visibility here
        // triggers a visible flicker while Chromium commits the next document.
        if !isNative && loadError == nil && !wasShowingStart && !wasShowingHistory && !wasShowingInspect && !wasShowingError && !tab.contentView.isHidden {
            return
        }

        startPageView.isHidden = !isStart
        historyPageView.isHidden = !isHistory
        inspectPageView.isHidden = !isInspect
        if isStart {
            startPageView.flushPendingUpdatesIfVisible()
        } else if isHistory {
            historyPageView.reloadIfVisible()
        } else if isInspect {
            inspectPageView.setSection(tab.inspectPageSection, notifyOwner: false)
            inspectPageView.reloadIfVisible()
        }
        if let loadError {
            pageLoadErrorView.configure(error: loadError)
            pageLoadErrorView.isHidden = false
            setTabViewVisible(tab, visible: false)
            swipeNavigationController.setActiveTargetView(pageLoadErrorView)
            let errColor = PageLoadErrorView.backdropColor
            chromeController.apply(sample: TopEdgeColorSample(color: errColor), animated: true)
            toolbarFrostView.apply(prefersLightInk: false, customVeilColor: errColor, animated: true)
        } else {
            pageLoadErrorView.isHidden = true
            setTabViewVisible(tab, visible: true)
            let targetView: NSView = isStart ? startPageView : (isHistory ? historyPageView : (isInspect ? inspectPageView : webContentHost))
            swipeNavigationController.setActiveTargetView(targetView)
            if isStart {
                let startColor = startPageView.effectiveTopColor
                chromeController.apply(sample: TopEdgeColorSample(color: startColor), animated: true)
                toolbarFrostView.apply(prefersLightInk: chromeController.currentTheme.prefersLightInk, customVeilColor: startColor, animated: true)
            } else if isHistory {
                let histColor = historyPageView.effectiveTopColor
                chromeController.apply(sample: TopEdgeColorSample(color: histColor), animated: true)
                toolbarFrostView.apply(prefersLightInk: historyPageView.prefersDarkAppearance, customVeilColor: histColor, animated: true)
            } else if isInspect {
                let inspectColor = inspectPageView.effectiveTopColor
                chromeController.apply(sample: TopEdgeColorSample(color: inspectColor), animated: true)
                toolbarFrostView.apply(prefersLightInk: inspectPageView.prefersDarkAppearance, customVeilColor: inspectColor, animated: true)
            } else {
                if navigationTransitionCoordinator.isHoldingNativeToWebVeil,
                   navigationTransitionCoordinator.activeTabID == tab.tabID {
                    // Hold toolbar frost harmonious with the visible native freeze-frame veil until
                    // the incoming webpage paints (or veil reveal begins), preventing a premature tint snap.
                    deferredRevealWebToolbarSyncTabID = tab.tabID
                } else {
                    deferredRevealWebToolbarSyncTabID = nil
                    applyActiveWebToolbarChrome(for: tab, animated: true)
                }
            }
        }
    }

    private var defaultWebPrepaintCanvasColor: NSColor {
        if isPrivate {
            return NSColor(srgbRed: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0, alpha: 1.0)
        }
        let app = window?.effectiveAppearance ?? NSApp?.effectiveAppearance
        let isDark = app?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    }

    private func applyActiveWebToolbarChrome(for tab: BrowserTabEngine, animated: Bool) {
        let fixedColor = BrowserSettings.shared.showWebsiteColorInToolbar ? tab.fixedHeaderColor : nil
        if let fixedColor {
            chromeController.apply(sample: TopEdgeColorSample(color: fixedColor), animated: animated)
        } else if let cachedSample = tab.lastTopEdgeColorSample {
            chromeController.apply(sample: cachedSample, animated: animated)
        } else {
            chromeController.apply(sample: TopEdgeColorSample(color: defaultWebPrepaintCanvasColor), animated: animated)
        }
        toolbarFrostView.apply(
            prefersLightInk: chromeController.currentTheme.prefersLightInk,
            sampledColor: fixedColor ?? chromeController.currentTheme.sampledColor,
            customVeilColor: nil,
            fixedHeaderColor: fixedColor,
            animated: animated
        )
    }

    // MARK: - Navigation History Snapshots & Trackpad Swipe Helpers

    private func captureViewBitmap(_ view: NSView) -> NSImage? {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: view.bounds.size)
        img.addRepresentation(rep)
        return img
    }

    private func captureCurrentDisplaySnapshot(for tab: BrowserTabEngine) -> NSImage? {
        if tab.isStartPage {
            return captureViewBitmap(startPageView)
        }
        if tab.isHistoryPage {
            return captureViewBitmap(historyPageView)
        }
        if tab.isInspectPage {
            return captureViewBitmap(inspectPageView)
        }
        if tabLoadErrors[tab.tabID] != nil {
            return captureViewBitmap(pageLoadErrorView)
        }
        return tab.cachedSnapshot ?? NavigationSnapshotStore.shared.snapshot(tabID: tab.tabID, entryID: tab.currentNavigationEntryID)?.image
    }

    private func snapshotBeforeLeavingCurrentPage(for tab: BrowserTabEngine) {
        // Web pages are already captured in settled JPEG form by BrowserCore keyed by exact CefNavigationEntry ID.
        // Only native AppKit surfaces (Start Page / History / Inspect / Error) need a synchronous bitmap capture on leave.
        let entryID = tab.currentNavigationEntryID
        guard entryID != 0 else { return }
        if tab.isStartPage {
            if let img = captureViewBitmap(startPageView) {
                NavigationSnapshotStore.shared.storeImage(
                    img,
                    tabID: tab.tabID,
                    entryID: NavigationSnapshotStore.startPageEntryID,
                    logicalSize: startPageView.bounds.size,
                    backgroundColor: startPageView.effectiveTopColor
                )
            }
        } else if tab.isHistoryPage {
            if let img = captureViewBitmap(historyPageView) {
                NavigationSnapshotStore.shared.storeImage(
                    img,
                    tabID: tab.tabID,
                    entryID: NavigationSnapshotStore.historyPageEntryID,
                    logicalSize: historyPageView.bounds.size,
                    backgroundColor: historyPageView.effectiveTopColor
                )
            }
        } else if tab.isInspectPage {
            if let img = captureViewBitmap(inspectPageView) {
                NavigationSnapshotStore.shared.storeImage(
                    img,
                    tabID: tab.tabID,
                    entryID: NavigationSnapshotStore.inspectPageEntryID,
                    logicalSize: inspectPageView.bounds.size,
                    backgroundColor: inspectPageView.effectiveTopColor
                )
            }
        } else if tabLoadErrors[tab.tabID] != nil {
            if let img = captureViewBitmap(pageLoadErrorView) {
                NavigationSnapshotStore.shared.storeImage(
                    img,
                    tabID: tab.tabID,
                    entryID: entryID,
                    logicalSize: pageLoadErrorView.bounds.size,
                    backgroundColor: PageLoadErrorView.backdropColor
                )
            }
        }
    }

    private func resolveSwipeSnapshot(for direction: SwipeNavigationController.Direction) -> NavigationSnapshotPayload? {
        guard let tab = activeTab else { return nil }
        let targetEntryID = (direction == .back) ? tab.previousNavigationEntryID : tab.nextNavigationEntryID
        if let payload = NavigationSnapshotStore.shared.snapshot(tabID: tab.tabID, entryID: targetEntryID) {
            return payload
        }
        // Lazy fallback for native Start Page if navigating back before a snapshot was stored
        if targetEntryID == NavigationSnapshotStore.startPageEntryID {
            let wasHidden = startPageView.isHidden
            startPageView.isHidden = false
            startPageView.layoutSubtreeIfNeeded()
            let snap = captureViewBitmap(startPageView)
            startPageView.isHidden = wasHidden
            if let snap {
                let payload = NavigationSnapshotPayload(
                    image: snap,
                    logicalSize: startPageView.bounds.size,
                    backgroundColor: startPageView.effectiveTopColor,
                    isFullBleedBehindToolbar: true
                )
                NavigationSnapshotStore.shared.storeImage(
                    snap,
                    tabID: tab.tabID,
                    entryID: NavigationSnapshotStore.startPageEntryID,
                    logicalSize: startPageView.bounds.size,
                    backgroundColor: startPageView.effectiveTopColor,
                    isFullBleedBehindToolbar: true
                )
                return payload
            }
        }
        return nil
    }

    private func captureOutgoingTransitionPayload(for tab: BrowserTabEngine) -> NavigationSnapshotPayload? {
        if tab.isStartPage {
            guard let img = captureViewBitmap(startPageView) else { return nil }
            return NavigationSnapshotPayload(
                image: img,
                logicalSize: startPageView.bounds.size,
                backgroundColor: startPageView.effectiveTopColor,
                isFullBleedBehindToolbar: true
            )
        }
        if tab.isHistoryPage {
            guard let img = captureViewBitmap(historyPageView) else { return nil }
            return NavigationSnapshotPayload(
                image: img,
                logicalSize: historyPageView.bounds.size,
                backgroundColor: historyPageView.effectiveTopColor,
                isFullBleedBehindToolbar: true
            )
        }
        if tab.isInspectPage {
            guard let img = captureViewBitmap(inspectPageView) else { return nil }
            return NavigationSnapshotPayload(
                image: img,
                logicalSize: inspectPageView.bounds.size,
                backgroundColor: inspectPageView.effectiveTopColor,
                isFullBleedBehindToolbar: true
            )
        }
        if tabLoadErrors[tab.tabID] != nil {
            guard let img = captureViewBitmap(pageLoadErrorView) else { return nil }
            return NavigationSnapshotPayload(
                image: img,
                logicalSize: pageLoadErrorView.bounds.size,
                backgroundColor: PageLoadErrorView.backdropColor,
                isFullBleedBehindToolbar: true
            )
        }
        if let stored = NavigationSnapshotStore.shared.snapshot(tabID: tab.tabID, entryID: tab.currentNavigationEntryID) {
            return stored
        }
        if let cached = tab.cachedSnapshot {
            let bg = tab.pageBackgroundColor ?? tab.lastTopEdgeColorSample?.color ?? defaultWebPrepaintCanvasColor
            return NavigationSnapshotPayload(
                image: cached,
                logicalSize: webContentHost.bounds.size,
                backgroundColor: bg,
                isFullBleedBehindToolbar: true
            )
        }
        if let liveWeb = captureViewBitmap(webContentHost) {
            let bg = tab.pageBackgroundColor ?? tab.lastTopEdgeColorSample?.color ?? defaultWebPrepaintCanvasColor
            return NavigationSnapshotPayload(
                image: liveWeb,
                logicalSize: webContentHost.bounds.size,
                backgroundColor: bg,
                isFullBleedBehindToolbar: true
            )
        }
        return nil
    }

    func navigateBackInActiveTab() {
        extensionPopoverController.close()
        guard let tab = activeTab, tab.canGoBack else { return }
        let fromSwipeCommit = swipeNavigationController.isHoldingCommittedSnapshot
        let outgoing = fromSwipeCommit ? nil : captureOutgoingTransitionPayload(for: tab)
        snapshotBeforeLeavingCurrentPage(for: tab)
        // Web -> web: BrowserCore keeps the current page frozen until the destination has painted (like Safari's
        // instant back/forward). Only a native page (Start Page, History...) needs holding here, because its web
        // view is hidden and BrowserCore has nothing on screen to copy. No crossfade with an old stored snapshot:
        // it never matches the live page and reads as ghosting.
        if !fromSwipeCommit && tab.isNativeInternalPage {
            navigationTransitionCoordinator.beginProgrammaticHistoryTransition(
                tabID: tab.tabID,
                direction: .back,
                outgoingPayload: outgoing,
                destinationPayload: nil
            )
        }
        tabLoadErrors.removeValue(forKey: tab.tabID)
        tab.goBack()
    }

    func navigateForwardInActiveTab() {
        extensionPopoverController.close()
        guard let tab = activeTab, tab.canGoForward else { return }
        let fromSwipeCommit = swipeNavigationController.isHoldingCommittedSnapshot
        let outgoing = fromSwipeCommit ? nil : captureOutgoingTransitionPayload(for: tab)
        snapshotBeforeLeavingCurrentPage(for: tab)
        // Web -> web: BrowserCore keeps the current page frozen until the destination has painted (like Safari's
        // instant back/forward). Only a native page (Start Page, History...) needs holding here, because its web
        // view is hidden and BrowserCore has nothing on screen to copy. No crossfade with an old stored snapshot:
        // it never matches the live page and reads as ghosting.
        if !fromSwipeCommit && tab.isNativeInternalPage {
            navigationTransitionCoordinator.beginProgrammaticHistoryTransition(
                tabID: tab.tabID,
                direction: .forward,
                outgoingPayload: outgoing,
                destinationPayload: nil
            )
        }
        tabLoadErrors.removeValue(forKey: tab.tabID)
        tab.goForward()
    }

    func selectTab(at index: Int, animatedTabBar: Bool? = nil, skipOverviewClose: Bool = false) {
        guard index >= 0 && index < tabs.count else { return }
        extensionPopoverController.close()
        if !skipOverviewClose && (tabOverviewView.isPresented || overviewOpenTarget) {
            overviewOpenTarget = false
            tabOverviewView.closeAnimated()
        }
        let now = CACurrentMediaTime()
        let onScreenTabID = activeTab?.tabID
        if let outgoingTab = activeTab, outgoingTab.tabID != tabs[index].tabID {
            tabLastBackgroundedAt[outgoingTab.tabID] = now
        }
        elasticScrollEngine.resetImmediately()
        swipeNavigationController.cancelImmediately()
        navigationTransitionCoordinator.cancelImmediately()
        deferredRevealWebToolbarSyncTabID = nil
        pinchCoordinator.reset()
        dismissAddressBarPopover()
        if tabAddressBar.isAddressBarEditing {
            tabAddressBar.endAddressEditing(restoreURL: true)
            if let win = window, win.firstResponder is NSTextView {
                win.makeFirstResponder(win)
            }
        }
        activeTabIndex = index
        syncElasticMetrics(for: tabs[index])

        deferredHiddenTabIDs.remove(tabs[index].tabID)
        // Only the tab that is on screen right now needs to stay under the incoming one; tabs deferred by an earlier,
        // already-superseded switch are hidden now (rapid switching would otherwise keep many views visible).
        let previouslyDeferred = deferredHiddenTabIDs
        deferredHiddenTabIDs.removeAll()
        for tab in tabs where previouslyDeferred.contains(tab.tabID) && tab.tabID != onScreenTabID && tab.tabID != tabs[index].tabID {
            setTabViewVisible(tab, visible: false)
        }
        for (idx, tab) in tabs.enumerated() {
            if tab.contentView.superview !== webContentHost {
                tab.attach(to: webContentHost)
            }
            let isActive = (idx == index)
            if !isActive && !tab.contentView.isHidden && !tab.isNativeInternalPage {
                // Hiding a Chromium view makes the GPU process drop its picture at once, while this switch reaches
                // the screen only when the main thread finishes the frame (~100+ ms on a busy switch): the gap showed
                // as a blank page. The new tab is ordered in front below, so this one stays visible underneath
                // until the new one is on screen.
                deferredHiddenTabIDs.insert(tab.tabID)
                continue
            }
            setTabViewVisible(tab, visible: isActive)
            if isActive {
                tab.contentView.frame = webContentHost.bounds
                tab.contentView.needsLayout = true
            }
        }
        // Ensure active tab's hostView is ordered frontmost inside webContentHost
        let activeView = tabs[index].contentView
        webContentHost.sortSubviews({ v1, v2, ctx in
            let target = Unmanaged<NSView>.fromOpaque(ctx!).takeUnretainedValue()
            if v1 === target { return .orderedDescending }
            if v2 === target { return .orderedAscending }
            return .orderedSame
        }, context: Unmanaged.passUnretained(activeView).toOpaque())
        webContentHost.needsLayout = true
        scheduleDeferredTabHides(fallbackDelay: 0.5)

        let tab = tabs[index]
        nativeVideoOverlay.setActiveTab(id: tab.tabID)
        passwordsPasskeyManager?.dismissAllPopovers()
        websiteSettingsPopover.close()
        privacyPopover.close()
        privacySummaryWorkItem?.cancel()
        privacySummaryWorkItem = nil
        syncPageTopInset(for: tab)
        hideFindBar()
        let tabLoadError = tab.isNativeInternalPage ? nil : tabLoadErrors[tab.tabID]
        startPageView.isHidden = !tab.isStartPage
        historyPageView.isHidden = !tab.isHistoryPage
        inspectPageView.isHidden = !tab.isInspectPage
        if let tabLoadError {
            pageLoadErrorView.configure(error: tabLoadError)
            pageLoadErrorView.isHidden = false
            setTabViewVisible(tab, visible: false)
            swipeNavigationController.setActiveTargetView(pageLoadErrorView)
        } else {
            pageLoadErrorView.isHidden = true
            let targetView: NSView = tab.isStartPage ? startPageView : (tab.isHistoryPage ? historyPageView : (tab.isInspectPage ? inspectPageView : webContentHost))
            swipeNavigationController.setActiveTargetView(targetView)
        }
        if tab.isStartPage {
            startPageView.flushPendingUpdatesIfVisible()
        } else if tab.isHistoryPage {
            historyPageView.reloadIfVisible()
        } else if tab.isInspectPage {
            inspectPageView.setSection(tab.inspectPageSection, notifyOwner: false)
            inspectPageView.reloadIfVisible()
        }
        NavigationSnapshotStore.shared.prewarm(
            tabID: tab.tabID,
            entryIDs: [tab.previousNavigationEntryID, tab.nextNavigationEntryID]
        )
        refreshToolbarUI(animatedTabBar: animatedTabBar)
        refreshPrivacyShieldUI()
        if let _ = tabLoadError {
            let errColor = PageLoadErrorView.backdropColor
            chromeController.apply(sample: TopEdgeColorSample(color: errColor), animated: false)
            toolbarFrostView.apply(prefersLightInk: false, customVeilColor: errColor, animated: false)
        } else if tab.isStartPage {
            let startColor = startPageView.effectiveTopColor
            chromeController.apply(sample: TopEdgeColorSample(color: startColor), animated: false)
            toolbarFrostView.apply(prefersLightInk: chromeController.currentTheme.prefersLightInk, customVeilColor: startColor, animated: false)
            if let win = window, let frView = win.firstResponder as? NSView, frView.isDescendant(of: webContentHost) {
                win.makeFirstResponder(win)
            }
        } else if tab.isHistoryPage {
            let histColor = historyPageView.effectiveTopColor
            chromeController.apply(sample: TopEdgeColorSample(color: histColor), animated: false)
            toolbarFrostView.apply(prefersLightInk: historyPageView.prefersDarkAppearance, customVeilColor: histColor, animated: false)
            if let win = window, let frView = win.firstResponder as? NSView, frView.isDescendant(of: webContentHost) {
                win.makeFirstResponder(win)
            }
        } else if tab.isInspectPage {
            let inspectColor = inspectPageView.effectiveTopColor
            chromeController.apply(sample: TopEdgeColorSample(color: inspectColor), animated: false)
            toolbarFrostView.apply(prefersLightInk: inspectPageView.prefersDarkAppearance, customVeilColor: inspectColor, animated: false)
            if let win = window, let frView = win.firstResponder as? NSView, frView.isDescendant(of: webContentHost) {
                win.makeFirstResponder(win)
            }
        } else {
            let fixedColor = BrowserSettings.shared.showWebsiteColorInToolbar ? tab.fixedHeaderColor : nil
            if let fixedColor {
                chromeController.apply(sample: TopEdgeColorSample(color: fixedColor), animated: false)
            } else if let cachedSample = tab.lastTopEdgeColorSample {
                chromeController.apply(sample: cachedSample, animated: false)
            } else if !engine.isRealChromium {
                scheduleMockTabColorSample(delay: 0.05)
            }
            toolbarFrostView.apply(
                prefersLightInk: chromeController.currentTheme.prefersLightInk,
                sampledColor: fixedColor ?? chromeController.currentTheme.sampledColor,
                customVeilColor: nil,
                fixedHeaderColor: fixedColor,
                animated: false
            )
            // A tab coming back is covered by BrowserCore with the exact copy taken when it was last on screen
            // until it has repainted (no dissolve: blending a stale snapshot with the live page reads as ghosting).
            tabLastBackgroundedAt.removeValue(forKey: tab.tabID)
            tab.focusWebContent()
        }
    }

    func closeTab(at index: Int, keepOverviewOpen: Bool = false) {
        guard index >= 0 && index < tabs.count else { return }
        let wasActive = (index == activeTabIndex)
        let removed = tabs.remove(at: index)
        if navigationTransitionCoordinator.activeTabID == removed.tabID {
            navigationTransitionCoordinator.cancelImmediately()
        }
        if deferredRevealWebToolbarSyncTabID == removed.tabID {
            deferredRevealWebToolbarSyncTabID = nil
        }
        nativeVideoOverlay.clearTab(id: removed.tabID)
        tabLoadErrors.removeValue(forKey: removed.tabID)
        tabLastActiveAt.removeValue(forKey: removed.tabID)
        tabLastBackgroundedAt.removeValue(forKey: removed.tabID)
        reloadingErrorTabIDs.remove(removed.tabID)
        NavigationSnapshotStore.shared.removeTab(removed.tabID)
        pinnedTabIDs.remove(removed.tabID)
        PrivacyReportStore.shared.removeTabStats(forTabID: removed.tabID)
        if !isPrivate, let url = removed.currentURL, !removed.isStartPage, url.isWebURL {
            closedTabURLs.append(url)
            if closedTabURLs.count > 50 { closedTabURLs.removeFirst(closedTabURLs.count - 50) }
        }
        if let win = window, let frView = win.firstResponder as? NSView, frView.isDescendant(of: removed.contentView) {
            win.makeFirstResponder(win)
        }
        removed.closeTab()
        pruneOrphanedTabSnapshots()

        if tabs.isEmpty {
            window?.close()
            return
        }
        if keepOverviewOpen {
            if wasActive {
                let nextIndex = min(index, tabs.count - 1)
                selectTab(at: nextIndex, skipOverviewClose: true)
            } else {
                if index < activeTabIndex {
                    activeTabIndex -= 1
                }
                refreshToolbarUI(animatedTabBar: true)
            }
            return
        }
        if !wasActive {
            if index < activeTabIndex {
                activeTabIndex -= 1
            }
            refreshToolbarUI(animatedTabBar: true)
            return
        }
        let nextIndex = min(index, tabs.count - 1)
        selectTab(at: nextIndex)
    }

    func closeActiveTab() { closeTab(at: activeTabIndex) }

    func reorderTabs(matchingOrder orderedIDs: [String]) {
        guard orderedIDs.count == tabs.count, Set(orderedIDs).count == orderedIDs.count else { return }
        let currentActiveID = activeTab?.tabID
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabID, $0) })
        let reordered = orderedIDs.compactMap { byID[$0] }
        guard reordered.count == tabs.count else { return }
        tabs = reordered
        if let currentActiveID, let newIdx = tabs.firstIndex(where: { $0.tabID == currentActiveID }) {
            activeTabIndex = newIdx
        }
        refreshToolbarUI()
    }

    // MARK: - 1:1 macOS 27 Safari Tab Drag-and-Drop & Cross-Window Reparenting

    private func beginTabTearOff(
        tabID: String,
        pillRectInScreen: NSRect,
        cursorOffsetInPill: NSPoint,
        mouseScreen: NSPoint
    ) {
        guard let idx = tabs.firstIndex(where: { $0.tabID == tabID }),
              let win = window else { return }
        let tab = tabs[idx]
        let isActive = (idx == activeTabIndex)
        let isSingleTab = (tabs.count == 1)

        dismissAddressBarPopover()
        extensionPopoverController.close()

        let liveSurface = tab.isStartPage ? nil : tab.currentFrameSurface
        let hasOtherWindows = (NSApp.delegate as? AppDelegate)?.hasOtherCompatibleWindow(besides: self) ?? false

        let initialSnap: NSImage?
        if tab.isStartPage {
            initialSnap = captureStartPageSnapshot(allowCached: true)
        } else if liveSurface != nil {
            initialSnap = nil
        } else {
            initialSnap = captureCurrentDisplaySnapshot(for: tab) ?? tab.cachedSnapshot
        }

        let displayDomain: String
        if tab.currentURL?.scheme == "chrome-extension" && !tab.title.isEmpty {
            displayDomain = tab.title
        } else {
            displayDomain = URLInputNormalizer.displayDomain(for: tab.currentURL)
        }

        let visualSnapshot = TabDragVisualSnapshot(
            tabID: tab.tabID,
            title: tab.title,
            displayDomain: displayDomain,
            url: tab.currentURL,
            favicon: tab.favicon,
            pageSnapshot: initialSnap,
            isActiveTab: isActive,
            isStartPage: tab.isStartPage,
            isPrivate: isPrivate,
            isSingleTabSourceWindow: isSingleTab,
            theme: chromeController.currentTheme,
            initialPillRectInScreen: pillRectInScreen,
            cursorOffsetInPill: cursorOffsetInPill,
            sourceWindowSize: win.frame.size,
            liveFrameSurface: liveSurface,
            hasOtherCompatibleWindows: hasOtherWindows
        )

        let liveProvider: ((@escaping (NSImage?) -> Void) -> Void)? = (tab.isStartPage || liveSurface != nil || (isSingleTab && !hasOtherWindows && initialSnap != nil))
            ? nil
            : { [weak tab] completion in
                tab?.captureSnapshot(completion: completion)
            }

        SafariTabDragCoordinator.shared.runTearOffSession(
            from: self,
            snapshot: visualSnapshot,
            initialMouseScreen: mouseScreen,
            liveSnapshotProvider: liveProvider
        )
    }

    func setTearOffHiddenTab(id: String?) {
        if let id {
            if let draggedIdx = tabs.firstIndex(where: { $0.tabID == id }),
               draggedIdx == activeTabIndex,
               tabs.count > 1 {
                preTearOffActiveTabID = id
                // Immediately promote adjacent tab in source window (1:1 macOS 27 Safari)
                let fallbackIdx = (draggedIdx + 1 < tabs.count) ? (draggedIdx + 1) : (draggedIdx - 1)
                tabAddressBar.setTearOffHiddenTab(id: id, animated: false)
                separateTabStripView.setTearOffHiddenTab(id: id, animated: false)
                verticalTabRailView.setTearOffHiddenTab(id: id, animated: false)
                selectTab(at: fallbackIdx, animatedTabBar: true)
                return
            }
            tabAddressBar.setTearOffHiddenTab(id: id, animated: true)
            separateTabStripView.setTearOffHiddenTab(id: id, animated: true)
            verticalTabRailView.setTearOffHiddenTab(id: id, animated: true)
        } else {
            let restoreID = preTearOffActiveTabID
            preTearOffActiveTabID = nil
            tabAddressBar.setTearOffHiddenTab(id: nil, animated: true)
            separateTabStripView.setTearOffHiddenTab(id: nil, animated: true)
            verticalTabRailView.setTearOffHiddenTab(id: nil, animated: true)
            if let restoreID, let idx = tabs.firstIndex(where: { $0.tabID == restoreID }) {
                selectTab(at: idx, animatedTabBar: false)
            }
        }
    }

    private var isAnyTabDragActive: Bool {
        tabAddressBar.isTabDragActive || separateTabStripView.isTabDragActive || verticalTabRailView.isTabDragActive
    }

    private func isPointInAnyTabTrack(_ ptInWindow: NSPoint) -> Bool {
        if tabAddressBar.isPointInTabTrack(ptInWindow) { return true }
        if !separateTabStripView.isHidden && separateTabStripView.isPointInTabTrack(ptInWindow) { return true }
        if !verticalTabRailView.isHidden && verticalTabRailView.isPointInTabTrack(ptInWindow) { return true }
        return false
    }

    private func tabIDAtWindowPoint(_ ptInWindow: NSPoint) -> String? {
        if !separateTabStripView.isHidden, let id = separateTabStripView.tabID(atWindowPoint: ptInWindow) { return id }
        if !verticalTabRailView.isHidden, let id = verticalTabRailView.tabID(atWindowPoint: ptInWindow) { return id }
        return tabAddressBar.tabID(atWindowPoint: ptInWindow)
    }

    func setSingleTabTearOffGhosted(_ ghosted: Bool) {
        guard let win = window else { return }
        win.ignoresMouseEvents = ghosted
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = ghosted ? 0.0 : 1.0
        }
    }

    func tabBarDropTarget(
        atScreenPoint screenPoint: NSPoint,
        draggedTabID: String,
        extraVerticalHysteresis: CGFloat = 0.0
    ) -> TabBarDropTarget? {
        let hit: (insertionIndex: Int, slotRectInScreen: NSRect)?
        if !verticalTabRailView.isHidden {
            hit = verticalTabRailView.dropHitTest(
                atScreenPoint: screenPoint,
                extraVerticalHysteresis: extraVerticalHysteresis
            ) ?? tabAddressBar.dropHitTest(
                atScreenPoint: screenPoint,
                extraVerticalHysteresis: extraVerticalHysteresis
            )
        } else if !separateTabStripView.isHidden {
            hit = separateTabStripView.dropHitTest(
                atScreenPoint: screenPoint,
                extraVerticalHysteresis: extraVerticalHysteresis
            )
        } else {
            hit = tabAddressBar.dropHitTest(
                atScreenPoint: screenPoint,
                extraVerticalHysteresis: extraVerticalHysteresis
            )
        }
        guard let hit else { return nil }
        return TabBarDropTarget(
            windowController: self,
            insertionIndex: hit.insertionIndex,
            slotRectInScreen: hit.slotRectInScreen,
            theme: chromeController.currentTheme
        )
    }

    func updateExternalTabDropPlaceholder(tabID: String, insertionIndex: Int) {
        if !verticalTabRailView.isHidden {
            verticalTabRailView.updateExternalDropPlaceholder(tabID: tabID, insertionIndex: insertionIndex)
        } else if !separateTabStripView.isHidden {
            separateTabStripView.updateExternalDropPlaceholder(tabID: tabID, insertionIndex: insertionIndex)
        } else {
            tabAddressBar.updateExternalDropPlaceholder(tabID: tabID, insertionIndex: insertionIndex)
        }
    }

    func clearExternalTabDropPlaceholder(animated: Bool = true) {
        tabAddressBar.clearExternalTabDropPlaceholder(animated: animated)
        separateTabStripView.clearExternalTabDropPlaceholder(animated: animated)
        verticalTabRailView.clearExternalTabDropPlaceholder(animated: animated)
    }

    func resolvedExternalDropSlotRectInScreen() -> NSRect? {
        if !verticalTabRailView.isHidden, let r = verticalTabRailView.resolvedDropSlotRectInScreen() { return r }
        if !separateTabStripView.isHidden, let r = separateTabStripView.resolvedDropSlotRectInScreen() { return r }
        return tabAddressBar.resolvedDropSlotRectInScreen()
    }

    func screenRectForTabOrDefault(tabID: String, fallback: NSRect) -> NSRect {
        let rect: NSRect
        if !verticalTabRailView.isHidden, let r = verticalTabRailView.screenRectForTab(id: tabID), r.width > 10 {
            rect = r
        } else if !separateTabStripView.isHidden, let r = separateTabStripView.screenRectForTab(id: tabID), r.width > 10 {
            rect = r
        } else {
            rect = tabAddressBar.screenRectForTab(id: tabID) ?? fallback
        }
        return rect.width > 10 ? rect : fallback
    }

    func commitSameWindowTabDrop(tabID: String, insertionIndex: Int) {
        preTearOffActiveTabID = nil
        tabAddressBar.setTearOffHiddenTab(id: nil, animated: false)
        separateTabStripView.setTearOffHiddenTab(id: nil, animated: false)
        verticalTabRailView.setTearOffHiddenTab(id: nil, animated: false)
        guard let oldIdx = tabs.firstIndex(where: { $0.tabID == tabID }) else {
            refreshToolbarUI(animatedTabBar: false)
            return
        }
        let moved = tabs.remove(at: oldIdx)
        let clamped = max(0, min(tabs.count, insertionIndex))
        tabs.insert(moved, at: clamped)
        selectTab(at: clamped, animatedTabBar: false)
    }

    /// Detaches a live tab from this window without destroying Chromium WebContents (closes source window if it became empty).
    func detachTabForTransfer(tabID: String) -> DetachedTabTransfer? {
        guard let idx = tabs.firstIndex(where: { $0.tabID == tabID }) else { return nil }
        let wasActive = (idx == activeTabIndex)
        let currentActiveID = activeTab?.tabID
        preTearOffActiveTabID = nil
        let tab = tabs.remove(at: idx)
        tab.delegate = nil
        tab.detachFromParentView()

        let loadErr = tabLoadErrors.removeValue(forKey: tabID)
        let currentTheme = chromeController.currentTheme

        tabAddressBar.setTearOffHiddenTab(id: nil, animated: false)
        tabAddressBar.clearExternalTabDropPlaceholder(animated: false)
        separateTabStripView.setTearOffHiddenTab(id: nil, animated: false)
        separateTabStripView.clearExternalTabDropPlaceholder(animated: false)
        verticalTabRailView.setTearOffHiddenTab(id: nil, animated: false)
        verticalTabRailView.clearExternalTabDropPlaceholder(animated: false)

        if tabs.isEmpty {
            window?.orderOut(nil)
            window?.close()
        } else if !wasActive, let currentActiveID, let keptIdx = tabs.firstIndex(where: { $0.tabID == currentActiveID }) {
            // Adjacent tab was already promoted cleanly when tear-off began — just sync index without re-animating!
            activeTabIndex = keptIdx
            refreshToolbarUI(animatedTabBar: false)
        } else {
            let nextIndex = min(idx, tabs.count - 1)
            selectTab(at: nextIndex, animatedTabBar: true)
        }

        return DetachedTabTransfer(
            tab: tab,
            loadError: loadErr,
            theme: currentTheme
        )
    }

    /// Adopts a live detached tab at `insertionIndex` in this window without reloading Chromium WebContents.
    func acceptTransferredTab(
        _ transfer: DetachedTabTransfer,
        atIndex insertionIndex: Int,
        activate: Bool = true,
        animatedTabBar: Bool? = false
    ) {
        let tab = transfer.tab
        tab.delegate = self
        tab.attach(to: webContentHost)

        let clamped = max(0, min(tabs.count, insertionIndex))
        tabs.insert(tab, at: clamped)
        // Inserting before the active tab shifts it right; keep the selection on the same tab.
        if !tabs.isEmpty, clamped <= activeTabIndex, tabs.count > 1 { activeTabIndex += 1 }
        if let err = transfer.loadError {
            tabLoadErrors[tab.tabID] = err
        }

        if activate {
            selectTab(at: clamped, animatedTabBar: animatedTabBar)
            updateStartPageVisibility()
            if !tab.isStartPage && tabLoadErrors[tab.tabID] == nil {
                if let sample = tab.lastTopEdgeColorSample {
                    chromeController.apply(sample: sample, animated: false)
                } else {
                    chromeController.apply(sample: TopEdgeColorSample(color: transfer.theme.sampledColor), animated: false)
                }
            }
        } else {
            setTabViewVisible(tab, visible: false)
            refreshToolbarUI(animatedTabBar: animatedTabBar)
        refreshPrivacyShieldUI()
        }
    }

    func reopenLastClosedTab() {
        guard let url = closedTabURLs.popLast() else { return }
        createNewTab(url: url, activate: true)
    }

    func cycleNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex + 1) % tabs.count)
    }

    func cyclePreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    func focusAddressBar() {
        extensionPopoverController.close()
        tabAddressBar.focusAddressBar()
    }
    func reloadActiveTab() {
        extensionPopoverController.close()
        if let tab = activeTab {
            resetTabPrivacyStatsBeforeReload(for: tab)
            refreshPrivacyShieldUI()
            if let err = tabLoadErrors[tab.tabID] {
                reloadingErrorTabIDs.insert(tab.tabID)
                tab.loadURL(err.failedURL)
            } else {
                tab.reload()
            }
        }
    }

    func reloadActiveTabIgnoringCache() {
        extensionPopoverController.close()
        if let tab = activeTab {
            resetTabPrivacyStatsBeforeReload(for: tab)
            refreshPrivacyShieldUI()
            if let err = tabLoadErrors[tab.tabID] {
                reloadingErrorTabIDs.insert(tab.tabID)
                tab.loadURL(err.failedURL)
            } else {
                tab.reloadIgnoringCache()
            }
        }
    }

    func navigateBack() { navigateBackInActiveTab() }
    func navigateForward() { navigateForwardInActiveTab() }

    func selectTabShortcut(tag: Int) {
        guard !tabs.isEmpty else { return }
        if tag == 8 { // ⌘9 selects the last tab
            selectTab(at: tabs.count - 1)
        } else if tag >= 0 && tag < tabs.count {
            selectTab(at: tag)
        }
    }

    func showFindBar() {
        guard let tab = activeTab, !tab.isStartPage else { return }
        findBarView.apply(isDark: chromeController.currentTheme.prefersLightInk)
        findBarView.isHidden = false
        findBarView.focusSearchField()
        let q = findBarView.queryText
        if !q.isEmpty {
            tab.findText(q, forward: true, matchCase: false, findNext: false)
        }
    }

    func findNextMatch() {
        if findBarView.isHidden {
            showFindBar()
            return
        }
        let q = findBarView.queryText
        if !q.isEmpty {
            activeTab?.findText(q, forward: true, matchCase: false, findNext: true)
        }
    }

    func findPreviousMatch() {
        if findBarView.isHidden {
            showFindBar()
            return
        }
        let q = findBarView.queryText
        if !q.isEmpty {
            activeTab?.findText(q, forward: false, matchCase: false, findNext: true)
        }
    }

    func hideFindBar() {
        guard !findBarView.isHidden else { return }
        findBarView.isHidden = true
        activeTab?.stopFinding(clearSelection: true)
        activeTab?.focusWebContent()
    }

    func copyCurrentPageURL() {
        guard let urlStr = activeWebPageURLString, !urlStr.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urlStr, forType: .string)
    }

    func goToHomepage() {
        let target = BrowserSettings.shared.homepageURL ?? URL(string: "safarium://start")!
        navigateActiveTab(to: target)
    }

    func bookmarkCurrentPage() {
        guard let tab = activeTab,
              !tab.isStartPage,
              let url = tab.currentURL,
              url.isWebURL else { return }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = AssetLoader.BookmarkEntry(
            id: UUID().uuidString,
            title: title.isEmpty ? URLInputNormalizer.displayDomain(for: url) : title,
            url: url.absoluteString,
            color: nil
        )
        _ = AssetLoader.shared.mergeImportedFavorites([entry], prepend: false)
    }

    func bookmarkAllOpenTabs() {
        let entries: [AssetLoader.BookmarkEntry] = tabs.compactMap { tab in
            guard !tab.isStartPage,
                  let url = tab.currentURL,
                  url.isWebURL else { return nil }
            let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return AssetLoader.BookmarkEntry(
                id: UUID().uuidString,
                title: title.isEmpty ? URLInputNormalizer.displayDomain(for: url) : title,
                url: url.absoluteString,
                color: nil
            )
        }
        guard !entries.isEmpty else { return }
        _ = AssetLoader.shared.mergeImportedFavorites(entries, prepend: false)
    }

    func addCurrentPageToReadingList() {
        guard let tab = activeTab,
              !tab.isStartPage,
              let url = tab.currentURL,
              url.isWebURL else { return }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = AssetLoader.ReadingListItem(
            id: UUID().uuidString,
            title: title.isEmpty ? URLInputNormalizer.displayDomain(for: url) : title,
            url: url.absoluteString,
            addedAt: Date()
        )
        _ = AssetLoader.shared.mergeImportedReadingList([item])
    }

    func addOpenTabsToReadingList() {
        let items: [AssetLoader.ReadingListItem] = tabs.compactMap { tab in
            guard !tab.isStartPage,
                  let url = tab.currentURL,
                  url.isWebURL else { return nil }
            let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return AssetLoader.ReadingListItem(
                id: UUID().uuidString,
                title: title.isEmpty ? URLInputNormalizer.displayDomain(for: url) : title,
                url: url.absoluteString,
                addedAt: Date()
            )
        }
        guard !items.isEmpty else { return }
        _ = AssetLoader.shared.mergeImportedReadingList(items)
    }

    func showStartPageInActiveTab() {
        navigateActiveTab(to: URL(string: "safarium://start")!)
    }

    func openURLInActiveOrNewTab(_ url: URL, newTab: Bool = false) {
        openURL(url, inTabID: nil, newTab: newTab)
    }

    func openURL(_ url: URL, inTabID targetTabID: String?, newTab: Bool = false) {
        if newTab || tabs.isEmpty {
            createNewTab(url: url, activate: true)
            return
        }
        if let targetTabID, let idx = tabs.firstIndex(where: { $0.tabID == targetTabID }) {
            if idx != activeTabIndex {
                selectTab(at: idx)
            }
            navigateActiveTab(to: url)
        } else {
            navigateActiveTab(to: url)
        }
    }

    func openLocalFileDialog() {
        let panel = NSOpenPanel()
        panel.title = "Open File in Safarium"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.createNewTab(url: url, activate: true)
        }
    }

    func shareActivePageFromMenu() {
        showShareMenu()
    }

    func printActiveTab() {
        guard let tab = activeTab, !tab.isStartPage else { return }
        tab.printPage()
    }

    func saveActiveTab() {
        extensionPopoverController.close()
        dismissAddressBarPopover()
        pageMenuPopover.close()
        guard let tab = activeTab,
              !tab.isNativeInternalPage,
              tabLoadErrors[tab.tabID] == nil else {
            return
        }
        tab.savePageWithPanel(for: window, completion: nil)
    }

    func exportActiveTabAsPDF() {
        guard let tab = activeTab, !tab.isStartPage, let win = window else { return }
        let panel = NSSavePanel()
        panel.title = "Export as PDF"
        let rawName = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (rawName.isEmpty ? activeTabDomain() : rawName)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName.isEmpty ? "Page" : safeName).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: win) { response in
            guard response == .OK, let url = panel.url else { return }
            tab.exportToPDF(atPath: url.path) { _ in }
        }
    }

    func viewSourceOfActiveTab() {
        guard let urlStr = activeWebPageURLString,
              urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://"),
              let srcURL = URL(string: "view-source:\(urlStr)") else { return }
        createNewTab(url: srcURL, activate: true)
    }

    func duplicateActiveTab() {
        let target = activeTab?.currentURL ?? URL(string: "safarium://start")!
        createNewTab(url: target, activate: true)
    }

    func moveActiveTabToNewWindow() {
        guard tabs.count > 1,
              let tab = activeTab,
              let win = window,
              let appDelegate = NSApp.delegate as? AppDelegate,
              let transfer = detachTabForTransfer(tabID: tab.tabID) else { return }
        let nextFrame = win.frame.offsetBy(dx: 28, dy: -28)
        appDelegate.openWindow(withTransferredTab: transfer, frame: nextFrame, isPrivate: isPrivate)
    }

    // MARK: - Native Safari Tab Context Menu

    private func buildTabContextMenu(forTabAt index: Int) -> NSMenu {
        let tab = tabs[index]
        let isActiveTab = (index == activeTabIndex)
        let isWebURL: Bool = {
            guard let u = tab.currentURL, !tab.isNativeInternalPage else { return false }
            return u.isWebURL
        }()
        let isPinned = pinnedTabIDs.contains(tab.tabID)
        contextMenuTabID = tab.tabID

        let menu = NSMenu(title: "Tab")
        menu.autoenablesItems = false

        func addItem(_ title: String, action: Selector, symbol: String? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            if let symbol {
                item.image = AssetLoader.shared.symbol(named: symbol, pointSize: 13.0, weight: .regular)
            }
            menu.addItem(item)
        }

        // Active tab shows Copy Link & Paste and Search / Go at top (matching Safari)
        if isActiveTab {
            addItem("Copy Link", action: #selector(tabCtxCopyLink), symbol: "link", enabled: isWebURL)
            let clipText = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clipIsURL = clipText.hasPrefix("http://") || clipText.hasPrefix("https://")
            addItem(
                clipIsURL ? "Paste and Go" : "Paste and Search",
                action: #selector(tabCtxPasteAndSearch),
                symbol: "magnifyingglass",
                enabled: !clipText.isEmpty
            )
            menu.addItem(.separator())
        }

        addItem(isPinned ? "Unpin Tab" : "Pin Tab", action: #selector(tabCtxTogglePin), enabled: isWebURL || isPinned)
        addItem("Duplicate Tab", action: #selector(tabCtxDuplicateTab))

        if tabs.count > 1 {
            menu.addItem(.separator())
            addItem("Close Tab", action: #selector(tabCtxCloseTab))
            addItem("Close Other Tabs", action: #selector(tabCtxCloseOtherTabs))
            if index > 0 {
                addItem("Close Tabs to the Left", action: #selector(tabCtxCloseTabsToLeft))
            }
            if index < tabs.count - 1 {
                addItem("Close Tabs to the Right", action: #selector(tabCtxCloseTabsToRight))
            }
            addItem("Move Tab to New Window", action: #selector(tabCtxMoveToNewWindow))
        }

        menu.addItem(.separator())
        let arrangeItem = NSMenuItem(title: "Arrange Tabs By", action: nil, keyEquivalent: "")
        let arrangeSub = NSMenu(title: "Arrange Tabs By")
        let byTitle = NSMenuItem(title: "Title", action: #selector(tabCtxArrangeByTitle), keyEquivalent: "")
        byTitle.target = self
        let bySite = NSMenuItem(title: "Website", action: #selector(tabCtxArrangeByWebsite), keyEquivalent: "")
        bySite.target = self
        arrangeSub.addItem(byTitle)
        arrangeSub.addItem(bySite)
        arrangeItem.submenu = arrangeSub
        menu.addItem(arrangeItem)

        if isActiveTab, isWebURL, let host = tab.currentURL?.host, !host.isEmpty {
            menu.addItem(.separator())
            let displayHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            addItem("Settings for \(displayHost)…", action: #selector(tabCtxWebsiteSettings))
        }

        return menu
    }

    private func contextTargetTabIndex() -> Int? {
        guard let tid = contextMenuTabID else { return nil }
        return tabs.firstIndex(where: { $0.tabID == tid })
    }

    @objc private func tabCtxCopyLink() {
        guard let idx = contextTargetTabIndex(), let url = tabs[idx].currentURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
        pb.writeObjects([url as NSURL])
    }

    @objc private func tabCtxPasteAndSearch() {
        guard let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty else { return }
        if let idx = contextTargetTabIndex(), idx != activeTabIndex {
            selectTab(at: idx)
        }
        let targetURL = URLInputNormalizer.normalize(clip, isPrivate: isPrivate)
        performActiveTabNavigation(to: targetURL)
    }

    @objc private func tabCtxTogglePin() {
        guard let idx = contextTargetTabIndex() else { return }
        let tab = tabs[idx]
        if pinnedTabIDs.contains(tab.tabID) {
            pinnedTabIDs.remove(tab.tabID)
            // Move unpinned tab right after all remaining pinned tabs
            let remainingPinned = tabs.filter { pinnedTabIDs.contains($0.tabID) }.count
            let destIdx = max(0, min(tabs.count - 1, remainingPinned))
            if destIdx != idx {
                let moved = tabs.remove(at: idx)
                tabs.insert(moved, at: destIdx)
                if activeTabIndex == idx {
                    activeTabIndex = destIdx
                } else if idx < activeTabIndex && destIdx >= activeTabIndex {
                    activeTabIndex -= 1
                } else if idx > activeTabIndex && destIdx <= activeTabIndex {
                    activeTabIndex += 1
                }
            }
        } else {
            pinnedTabIDs.insert(tab.tabID)
            let destIdx = tabs.prefix(idx).filter { pinnedTabIDs.contains($0.tabID) }.count
            if destIdx != idx {
                let moved = tabs.remove(at: idx)
                tabs.insert(moved, at: destIdx)
                if activeTabIndex == idx {
                    activeTabIndex = destIdx
                } else if idx > activeTabIndex && destIdx <= activeTabIndex {
                    activeTabIndex += 1
                }
            }
            // Match Safari (video_1.mov): if every tab is now pinned, open a Start Page tab on the right while keeping the pinned tab active
            let hasUnpinned = tabs.contains { !pinnedTabIDs.contains($0.tabID) }
            if !hasUnpinned {
                createNewTab(url: URL(string: "safarium://start")!, activate: false)
            }
        }
        refreshToolbarUI(animatedTabBar: true)
    }

    @objc private func tabCtxDuplicateTab() {
        guard let idx = contextTargetTabIndex() else { return }
        let target = tabs[idx].currentURL ?? URL(string: "safarium://start")!
        createNewTab(url: target, activate: true)
    }

    @objc private func tabCtxCloseTab() {
        guard let idx = contextTargetTabIndex() else { return }
        closeTab(at: idx)
    }

    @objc private func tabCtxCloseOtherTabs() {
        guard let keepID = contextMenuTabID else { return }
        for i in stride(from: tabs.count - 1, through: 0, by: -1) {
            if tabs[i].tabID != keepID && !pinnedTabIDs.contains(tabs[i].tabID) {
                closeTab(at: i)
            }
        }
    }

    @objc private func tabCtxCloseTabsToLeft() {
        guard let idx = contextTargetTabIndex(), idx > 0 else { return }
        for i in stride(from: idx - 1, through: 0, by: -1) {
            if !pinnedTabIDs.contains(tabs[i].tabID) { closeTab(at: i) }
        }
    }

    @objc private func tabCtxCloseTabsToRight() {
        guard let idx = contextTargetTabIndex(), idx < tabs.count - 1 else { return }
        for i in stride(from: tabs.count - 1, through: idx + 1, by: -1) {
            if !pinnedTabIDs.contains(tabs[i].tabID) { closeTab(at: i) }
        }
    }

    @objc private func tabCtxMoveToNewWindow() {
        guard tabs.count > 1,
              let idx = contextTargetTabIndex(),
              let win = window,
              let appDelegate = NSApp.delegate as? AppDelegate,
              let transfer = detachTabForTransfer(tabID: tabs[idx].tabID) else { return }
        let nextFrame = win.frame.offsetBy(dx: 28, dy: -28)
        appDelegate.openWindow(withTransferredTab: transfer, frame: nextFrame, isPrivate: isPrivate)
    }

    @objc private func tabCtxArrangeByTitle() {
        guard tabs.count > 1 else { return }
        let activeID = activeTab?.tabID
        tabs.sort { a, b in
            let pa = pinnedTabIDs.contains(a.tabID)
            let pb = pinnedTabIDs.contains(b.tabID)
            if pa != pb { return pa }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        if let activeID, let newIdx = tabs.firstIndex(where: { $0.tabID == activeID }) {
            activeTabIndex = newIdx
        }
        refreshToolbarUI(animatedTabBar: true)
    }

    @objc private func tabCtxArrangeByWebsite() {
        guard tabs.count > 1 else { return }
        let activeID = activeTab?.tabID
        tabs.sort { a, b in
            let pa = pinnedTabIDs.contains(a.tabID)
            let pb = pinnedTabIDs.contains(b.tabID)
            if pa != pb { return pa }
            let ha = a.currentURL?.host ?? a.title
            let hb = b.currentURL?.host ?? b.title
            return ha.localizedCaseInsensitiveCompare(hb) == .orderedAscending
        }
        if let activeID, let newIdx = tabs.firstIndex(where: { $0.tabID == activeID }) {
            activeTabIndex = newIdx
        }
        refreshToolbarUI(animatedTabBar: true)
    }

    @objc private func tabCtxWebsiteSettings() {
        showWebsiteSettingsPopoverForActiveTab()
    }

    private func showWebsiteSettingsPopoverForActiveTab() {
        guard let tab = activeTab,
              let host = BrowserSettings.normalizedHost(from: tab.currentURL),
              !host.isEmpty else {
            (NSApp.delegate as? AppDelegate)?.showSettingsWindow(pane: .websites)
            return
        }
        websiteSettingsPopover.onPageZoomChanged = { [weak tab] factor in
            tab?.setPageZoomFactor(factor)
        }
        websiteSettingsPopover.onAdaptiveDarkModeChanged = { [weak tab] enabled in
            guard let tab else { return }
            let js = enabled
                ? "(function(){if(!document.getElementById('sx-adaptive-dark')){var s=document.createElement('style');s.id='sx-adaptive-dark';s.textContent='html{filter:invert(0.92) hue-rotate(180deg)!important;background:#111!important;}img,video,picture,canvas,svg{filter:invert(1) hue-rotate(180deg)!important;}';(document.head||document.documentElement).appendChild(s);}})();"
                : "(function(){var el=document.getElementById('sx-adaptive-dark');if(el)el.remove();})();"
            tab.executeJavaScript(js)
        }
        websiteSettingsPopover.onContentBlockersChanged = { [weak self, weak tab] enabled in
            guard let self else { return }
            let effective = BrowserSettings.shared.preventCrossSiteTracking && enabled
            if let tab {
                self.resetTabPrivacyStatsBeforeReload(for: tab, overrideProtectionsEnabled: effective)
            }
            self.engine.syncPrivacyPolicy(BrowserSettings.shared.privacyPolicyDictionary())
            self.refreshPrivacyShieldUI()
            tab?.reload()
        }
        websiteSettingsPopover.show(forHost: host, relativeTo: tabAddressBar.activePillAnchorView)
    }

    func arrangeTabsByTitle() {
        guard tabs.count > 1 else { return }
        let ordered = tabs.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }.map(\.tabID)
        reorderTabs(matchingOrder: ordered)
    }

    func arrangeTabsByWebsite() {
        guard tabs.count > 1 else { return }
        let ordered = tabs.sorted {
            let h0 = URLInputNormalizer.displayDomain(for: $0.currentURL)
            let h1 = URLInputNormalizer.displayDomain(for: $1.currentURL)
            if h0.caseInsensitiveCompare(h1) == .orderedSame {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return h0.localizedCaseInsensitiveCompare(h1) == .orderedAscending
        }.map(\.tabID)
        reorderTabs(matchingOrder: ordered)
    }

    func toggleMuteActiveTab() {
        guard let tab = activeTab, !tab.isStartPage else { return }
        tab.setAudioMuted(!tab.isAudioMuted)
    }

    func muteOtherTabs() {
        guard let currentID = activeTab?.tabID else { return }
        for tab in tabs where tab.tabID != currentID && !tab.isStartPage {
            tab.setAudioMuted(true)
        }
    }

    var isActiveTabMuted: Bool {
        activeTab?.isAudioMuted ?? false
    }

    var openTabCount: Int { tabs.count }

    var activeHostDisplayName: String? {
        guard let tab = activeTab, !tab.isStartPage else { return nil }
        return BrowserSettings.normalizedHost(from: tab.currentURL)
    }

    var isSidebarCurrentlyOpen: Bool { isSidebarOpen }

    var isTabOverviewCurrentlyOpen: Bool { tabOverviewView.isPresented }

    var hasRecentlyClosedTabs: Bool { !closedTabURLs.isEmpty }

    var recentClosedURLsForMenu: [URL] { Array(closedTabURLs.reversed().prefix(10)) }

    func reopenClosedTab(atReversedIndex idx: Int) {
        let actualIdx = closedTabURLs.count - 1 - idx
        guard actualIdx >= 0 && actualIdx < closedTabURLs.count else { return }
        let url = closedTabURLs.remove(at: actualIdx)
        createNewTab(url: url, activate: true)
    }

    func showBookmarksSidebar() {
        sidebarView.showBookmarksSection()
        if !isSidebarOpen {
            toggleSidebar()
        }
    }

    func showReadingListSidebar() {
        sidebarView.showReadingListSection()
        if !isSidebarOpen {
            toggleSidebar()
        }
    }

    func showTabsSidebar() {
        sidebarView.showTabsSection()
        if !isSidebarOpen {
            toggleSidebar()
        }
    }

    func toggleDownloadsPopover() {
        downloadController.togglePopover()
    }

    func handleEscapeOrStop() {
        if passwordsPasskeyManager?.hasActiveBiometricSheet == true {
            passwordsPasskeyManager?.cancelActiveBiometricSheet()
        } else if extensionsCoordinator.isDragSessionActive {
            extensionsCoordinator.cancelDrag()
        } else if customizeToolbarSheet.isPresented {
            customizeToolbarSheet.dismiss(animated: true)
        } else if !findBarView.isHidden {
            hideFindBar()
        } else if pageMenuPopover.isShown {
            pageMenuPopover.close()
        } else if tabOverviewView.isPresented {
            toggleTabOverview()
        } else if addressBarPopover.isShown {
            tabAddressBar.endAddressEditing(restoreURL: true)
            dismissAddressBarPopover()
        } else {
            activeTab?.stopLoading()
        }
    }

    func zoomInActiveTab() {
        guard let tab = activeTab, !tab.isStartPage else { return }
        let current = tab.pageZoomFactor
        let next = BrowserSettings.pageZoomValues.first(where: { $0 > current + 0.01 }) ?? BrowserSettings.pageZoomValues.last ?? 3.0
        tab.setPageZoomFactor(next)
        BrowserSettings.shared.setPageZoomFactor(next, for: tab.currentURL)
        syncPageTopInset(for: tab, zoomOverride: next)
    }

    func zoomOutActiveTab() {
        guard let tab = activeTab, !tab.isStartPage else { return }
        let current = tab.pageZoomFactor
        let prev = BrowserSettings.pageZoomValues.last(where: { $0 < current - 0.01 }) ?? BrowserSettings.pageZoomValues.first ?? 0.5
        tab.setPageZoomFactor(prev)
        BrowserSettings.shared.setPageZoomFactor(prev, for: tab.currentURL)
        syncPageTopInset(for: tab, zoomOverride: prev)
    }

    func resetZoomActiveTab() {
        guard let tab = activeTab, !tab.isStartPage else { return }
        tab.setPageZoomFactor(1.0)
        tab.resetPageScale()
        BrowserSettings.shared.setPageZoomFactor(1.0, for: tab.currentURL)
        syncPageTopInset(for: tab, zoomOverride: 1.0)
    }

    func openHistoryPage() {
        if let existingIdx = tabs.firstIndex(where: { $0.isHistoryPage }) {
            selectTab(at: existingIdx)
            historyPageView.reloadIfVisible()
            return
        }
        let historyURL = URL(string: "safarium://history")!
        if let active = activeTab, active.isStartPage {
            navigateActiveTab(to: historyURL)
        } else {
            createNewTab(url: historyURL, activate: true)
        }
    }

    private func updateToolbarForTabOverview(_ active: Bool) {
        guard isOverviewToolbarActive != active else { return }
        isOverviewToolbarActive = active
        tabAddressBar.isTabOverviewActive = active
        refreshToolbarUI(animatedTabBar: true)
    }

    func toggleTabOverview() {
        dismissAddressBarPopover()
        if tabOverviewView.isPresented || overviewOpenTarget {
            pendingOverviewOpenToken += 1
            overviewOpenTarget = false
            tabOverviewView.closeAnimated(selectingTabID: activeTab?.tabID)
            return
        }

        overviewOpenTarget = true
        pendingOverviewOpenToken += 1
        let openToken = pendingOverviewOpenToken

        // Launch the overview zoom-out animation immediately on frame 0 using only
        // the pre-cached in-RAM preview snapshots (zero live captures during animation).
        if self.overviewOpenTarget, self.pendingOverviewOpenToken == openToken {
            self.setOverviewSnapshotCapturePaused(true)
            self.updateToolbarForTabOverview(true)
            self.tabOverviewView.apply(theme: self.chromeController.currentTheme)
            self.tabOverviewView.openAnimated(cards: self.buildOverviewCardModels()) { [weak self] in
                self?.fillMissingOverviewSnapshotsIfNeeded()
            }
        }
    }

    private func fillMissingOverviewSnapshotsIfNeeded() {
        guard tabOverviewView.isPresented else { return }
        for tab in tabs where !tab.isNativeInternalPage {
            guard tab.cachedSnapshot == nil else { continue }
            let tabID = tab.tabID
            tab.captureSnapshot { [weak self] image in
                guard let self, let image, self.tabOverviewView.isPresented else { return }
                self.tabOverviewView.updateSnapshot(image, forTabID: tabID)
            }
        }
    }

    private func setOverviewSnapshotCapturePaused(_ paused: Bool) {
        for tab in tabs {
            tab.setPreviewSnapshotPaused(paused)
        }
    }

    private func pruneOrphanedTabSnapshots() {
        // History snapshots are pruned automatically per-tab via NavigationSnapshotStore.prune(tabID:keepingEntryIDs:).
    }

    /// Opening the overview: re-take the active tab's exact frame and swap it into its card (~90 ms, during the zoom),
    /// in case the page changed since its last copy (animations, video, live content).
    private func refreshActiveOverviewCardFrame() {
        guard let tab = activeTab, !tab.isNativeInternalPage else { return }
        let tabID = tab.tabID
        tab.refreshCurrentFrame { [weak self] surface, size in
            guard let self, let surface, size.width > 1, !self.tabOverviewView.isHidden else { return }
            self.tabOverviewView.updateFrameSurface(surface, size: size, forTabID: tabID)
        }
    }

    private func buildOverviewCardModels() -> [TabOverviewView.CardModel] {
        if !tabOverviewView.isPresented && tabOverviewView.isHidden {
            refreshActiveOverviewCardFrame()
        }
        // Avoid synchronous Retina rasterization of hidden startPageView unless a Start Page tab actually exists
        let needsStartSnap = tabs.contains(where: { $0.isStartPage })
        let startSnap: NSImage? = needsStartSnap ? captureStartPageSnapshot(allowCached: true) : nil
        let needsHistorySnap = tabs.contains(where: { $0.isHistoryPage })
        let historySnap: NSImage? = needsHistorySnap ? captureHistoryPageSnapshot() : nil
        return tabs.enumerated().map { idx, tab in
            let snap: NSImage?
            if tab.isStartPage {
                snap = startSnap
            } else if tab.isHistoryPage {
                snap = historySnap
            } else {
                snap = tab.cachedSnapshot ?? NavigationSnapshotStore.shared.snapshot(tabID: tab.tabID, entryID: tab.currentNavigationEntryID)?.image
            }
            return TabOverviewView.CardModel(
                id: tab.tabID,
                title: tab.title,
                url: tab.currentURL,
                favicon: tab.favicon,
                snapshot: snap,
                isActive: idx == activeTabIndex,
                frameSurface: tab.isNativeInternalPage ? nil : tab.currentFrameSurface,
                frameSize: tab.currentFrameSize,
                liveLayer: (idx == activeTabIndex && !tab.isNativeInternalPage) ? tab.makeLiveContentMirrorLayer() : nil
            )
        }
    }

    private func captureHistoryPageSnapshot() -> NSImage? {
        let wasHidden = historyPageView.isHidden
        if wasHidden {
            historyPageView.isHidden = false
            historyPageView.layoutSubtreeIfNeeded()
        }
        defer { historyPageView.isHidden = wasHidden }
        return captureViewBitmap(historyPageView)
    }

    private func captureStartPageSnapshot(allowCached: Bool = false) -> NSImage? {
        let size = startPageView.bounds.size
        if allowCached,
           let cached = cachedStartPageSnapshot,
           abs(cachedStartPageSnapshotSize.width - size.width) < 1.0,
           abs(cachedStartPageSnapshotSize.height - size.height) < 1.0 {
            return cached
        }
        let wasHidden = startPageView.isHidden
        if wasHidden {
            startPageView.isHidden = false
            startPageView.layoutSubtreeIfNeeded()
        }
        defer { startPageView.isHidden = wasHidden }
        guard startPageView.bounds.width > 10, startPageView.bounds.height > 10,
              let rep = startPageView.bitmapImageRepForCachingDisplay(in: startPageView.bounds) else {
            return nil
        }
        startPageView.cacheDisplay(in: startPageView.bounds, to: rep)
        let img = NSImage(size: startPageView.bounds.size)
        img.addRepresentation(rep)
        cachedStartPageSnapshot = img
        cachedStartPageSnapshotSize = startPageView.bounds.size
        return img
    }

    func toggleSidebar() {
        isSidebarOpen.toggle()
        tabAddressBar.isSidebarOpen = isSidebarOpen

        if !sidebarAnimating {
            sidebarAnimating = true
            tabAddressBar.beginExternalAnimation()
            // Keep mainPaneView at full window width (`leading = 0`) across the entire 120Hz slide
            // so ZERO Auto Layout solves and ZERO Chromium IPC resizes happen on any animation frame!
            // When closing from settled open state, expand mainPaneView ONCE at frame 0 while applying
            // the matching `p = 1.0` GPU transforms in the exact same transaction (zero visual jump).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if (mainPaneLeadingConstraint?.constant ?? 0) > 0.5 {
                mainPaneLeadingConstraint?.constant = 0.0
                toolbarChainSidebarOpen = false
                applyToolbarChainConstants(animated: false)
                rootView.layoutSubtreeIfNeeded()
                for tab in tabs {
                    tab.contentView.frame = webContentHost.bounds
                }
            }
            sidebarView.isHidden = false
            applySidebarGPUTransforms(progress: sidebarProgress)
            CATransaction.commit()
        }

        if isSidebarOpen {
            sidebarView.isHidden = false
            sidebarView.flushPendingRebuildIfNeeded()
            sidebarCluster.isHidden = true
            updateVerticalTabRailVisibility(animated: false)
        }

        sidebarAnimStartProgress = sidebarProgress
        sidebarAnimTargetProgress = isSidebarOpen ? 1.0 : 0.0
        sidebarAnimStartTime = CACurrentMediaTime()

        if sidebarDisplayLink == nil {
            let link = rootView.displayLink(target: self, selector: #selector(handleSidebarDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            sidebarDisplayLink = link
        }
    }

    private func applySidebarGPUTransforms(progress p: CGFloat) {
        let sidebarW = SafariMetrics.sidebarDefaultWidth
        let leftGroupDelta = (sidebarW + 8.0) - closedLeftChainLeading
        let tabCenterDelta = sidebarW * 0.5

        sidebarView.layer?.transform = CATransform3DMakeTranslation(-sidebarW * (1.0 - p), 0.0, 0.0)
        contentStageView.layer?.transform = CATransform3DMakeTranslation(sidebarW * p, 0.0, 0.0)
        for v in chainLeftSlidingViews {
            v.layer?.transform = CATransform3DMakeTranslation(leftGroupDelta * p, 0.0, 0.0)
        }
        tabAddressBar.layer?.transform = CATransform3DMakeTranslation(tabCenterDelta * p, 0.0, 0.0)
    }

    private func resetSidebarGPUTransforms() {
        sidebarView.layer?.transform = CATransform3DIdentity
        contentStageView.layer?.transform = CATransform3DIdentity
        for v in [extensionsCoordinator.capsule(for: .afterSidebar), backForwardCluster, privacyShieldCluster,
                  leftCustomActionCluster, extensionsCoordinator.capsule(for: .leftOfAddressBar)] as [NSView] {
            v.layer?.transform = CATransform3DIdentity
        }
        tabAddressBar.layer?.transform = CATransform3DIdentity
    }

    @objc private func handleSidebarDisplayLink(_ link: CADisplayLink) {
        let duration: CFTimeInterval = 0.24
        let elapsed = max(0.0, CACurrentMediaTime() - sidebarAnimStartTime)
        let rawT = min(1.0, elapsed / duration)

        // Silky quartic ease-out driven purely on GPU layer transforms at 120Hz (0 Auto Layout calls!)
        let inv = 1.0 - rawT
        let eased = CGFloat(1.0 - inv * inv * inv * inv)
        let progress = sidebarAnimStartProgress + (sidebarAnimTargetProgress - sidebarAnimStartProgress) * eased
        sidebarProgress = progress

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applySidebarGPUTransforms(progress: progress)
        CATransaction.commit()

        if rawT >= 1.0 {
            finishSidebarAnimation()
        }
    }

    private func finishSidebarAnimation() {
        sidebarDisplayLink?.invalidate()
        sidebarDisplayLink = nil
        sidebarProgress = sidebarAnimTargetProgress


        CATransaction.begin()
        CATransaction.setDisableActions(true)
        resetSidebarGPUTransforms()
        if isSidebarOpen {
            mainPaneLeadingConstraint?.constant = SafariMetrics.sidebarDefaultWidth
            toolbarChainSidebarOpen = true
            applyToolbarChainConstants(animated: false)
            rootView.layoutSubtreeIfNeeded()
            for tab in tabs {
                tab.contentView.frame = webContentHost.bounds
            }
        } else {
            mainPaneLeadingConstraint?.constant = 0.0
            toolbarChainSidebarOpen = false
            applyToolbarChainConstants(animated: false)
            sidebarView.isHidden = true
            sidebarCluster.isHidden = false
            rootView.layoutSubtreeIfNeeded()
        }
        CATransaction.commit()

        if sidebarAnimating {
            sidebarAnimating = false
            tabAddressBar.endExternalAnimation()
        }
        updateVerticalTabRailVisibility(animated: false)
    }

    // MARK: - Popovers & Auxiliary Actions

    private func showShareMenu() {
        guard let url = activeTab?.currentURL,
              let anchor = rightActionCapsule.button(for: "share") else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func showDownloadsPopover() {
        downloadController.togglePopover()
    }

    private func effectiveProtectionsEnabled(forHost cleanHost: String) -> Bool {
        guard BrowserSettings.shared.preventCrossSiteTracking else { return false }
        return cleanHost.isEmpty ? true : BrowserSettings.shared.isContentBlockersEnabled(forHost: cleanHost)
    }

    private func resolvedSecurityState(for tab: BrowserTabEngine, url: URL?, cleanHost: String) -> ConnectionSecurityState {
        if tab.connectionSecurityState != .internalPage,
           let rawSecHost = tab.connectionSecurityHost, !rawSecHost.isEmpty,
           PrivacyDomainClassifier.sanitizeHostForStorage(rawSecHost) == cleanHost {
            return tab.connectionSecurityState
        }
        if let url, url.isWebURL {
            return url.scheme?.lowercased() == "https" ? .secureHTTPS : .insecureHTTP
        }
        return .internalPage
    }

    private func resetTabPrivacyStatsBeforeReload(for tab: BrowserTabEngine, overrideProtectionsEnabled: Bool? = nil) {
        let rawHost = tab.currentURL?.isWebURL == true ? (tab.currentURL?.host ?? "") : ""
        let cleanHost = rawHost.isEmpty ? "" : PrivacyDomainClassifier.sanitizeHostForStorage(rawHost)
        let prot = overrideProtectionsEnabled ?? effectiveProtectionsEnabled(forHost: cleanHost)
        let sec = resolvedSecurityState(for: tab, url: tab.currentURL, cleanHost: cleanHost)
        PrivacyReportStore.shared.resetTabStats(
            forTabID: tab.tabID,
            host: cleanHost,
            isPrivate: isPrivate,
            securityState: sec,
            protectionsEnabled: prot,
            preserveMatchingHostEvents: false
        )
    }

    func showPrivacyPopover() {
        if privacyPopover.isShown {
            privacyPopover.close()
            privacySummaryWorkItem?.cancel()
            privacySummaryWorkItem = nil
            return
        }
        dismissAddressBarPopover()
        pageMenuPopover.close()
        websiteSettingsPopover.close()

        let snapshot = currentActiveTabPrivacySnapshot()
        let summary: PrivacyReportSummary
        if isPrivate {
            summary = .empty
        } else {
            summary = PrivacyReportStore.shared.summary(days: 30)
            cachedPrivacySummary = summary
            lastPrivacySummaryRefreshTime = CACurrentMediaTime()
        }
        let anchor = privacyPopoverAnchorView()
        privacyPopover.show(snapshot: snapshot, summary: summary, relativeTo: anchor)
    }

    private func privacyPopoverAnchorView() -> NSView {
        if ToolbarCustomizationStore.shared.side(for: .privacyReport) != nil {
            if !leftCustomActionCluster.isHidden,
               let leftBtn = leftCustomActionCapsule.button(for: "privacyReport"),
               !leftBtn.isHidden {
                return leftBtn
            }
            if !rightGlassContainer.isHidden,
               let rightBtn = rightActionCapsule.button(for: "privacyReport"),
               !rightBtn.isHidden {
                return rightBtn
            }
        }
        if !privacyShieldCluster.isHidden,
           let btn = privacyShieldCapsule.button(for: "privacyShield"),
           !btn.isHidden {
            return btn
        }
        return tabAddressBar.activePillAnchorView
    }

    private func currentActiveTabPrivacySnapshot() -> TabPrivacySnapshot {
        guard let tab = activeTab else {
            return .empty(tabID: "", isPrivate: isPrivate, protectionsEnabled: BrowserSettings.shared.preventCrossSiteTracking)
        }
        if let existing = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID) {
            return existing
        }
        let rawHost = tab.currentURL?.isWebURL == true ? (tab.currentURL?.host ?? "") : ""
        let cleanHost = rawHost.isEmpty ? "" : PrivacyDomainClassifier.sanitizeHostForStorage(rawHost)
        let prot = effectiveProtectionsEnabled(forHost: cleanHost)
        let sec = resolvedSecurityState(for: tab, url: tab.currentURL, cleanHost: cleanHost)
        return .empty(
            tabID: tab.tabID,
            host: cleanHost,
            isPrivate: isPrivate,
            securityState: sec,
            protectionsEnabled: prot
        )
    }

    private func scheduleDebouncedPopoverSummaryRefresh() {
        guard !isPrivate, privacyPopover.isShown else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastPrivacySummaryRefreshTime
        if elapsed >= 0.35 {
            privacySummaryWorkItem?.cancel()
            privacySummaryWorkItem = nil
            lastPrivacySummaryRefreshTime = now
            let fresh = PrivacyReportStore.shared.summary(days: 30)
            cachedPrivacySummary = fresh
            privacyPopover.update(snapshot: currentActiveTabPrivacySnapshot(), summary: fresh)
            return
        }
        guard privacySummaryWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.privacySummaryWorkItem = nil
            guard !self.isPrivate, self.privacyPopover.isShown else { return }
            self.lastPrivacySummaryRefreshTime = CACurrentMediaTime()
            let fresh = PrivacyReportStore.shared.summary(days: 30)
            self.cachedPrivacySummary = fresh
            self.privacyPopover.update(snapshot: self.currentActiveTabPrivacySnapshot(), summary: fresh)
        }
        privacySummaryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (0.35 - elapsed), execute: item)
    }

    private func refreshPrivacyShieldUI() {
        let snapshot = currentActiveTabPrivacySnapshot()
        let effectiveTheme = chromeController.currentTheme
        let tint: NSColor
        switch snapshot.securityState {
        case .certificateError:
            tint = .systemRed
        case .insecureHTTP:
            tint = .systemOrange
        case .secureHTTPS, .upgradedHTTPS:
            tint = snapshot.protectionsEnabled
                ? NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
                : effectiveTheme.disabledInkColor
        case .internalPage:
            tint = snapshot.protectionsEnabled
                ? effectiveTheme.primaryInkColor
                : effectiveTheme.disabledInkColor
        }

        let tooltip: String
        if !snapshot.protectionsEnabled {
            tooltip = snapshot.host.isEmpty
                ? "Privacy Report — Protections turned off"
                : "Privacy Report — Protections paused for \(snapshot.host)"
        } else if snapshot.totalTrackersBlocked > 0 {
            let noun = snapshot.totalTrackersBlocked == 1 ? "tracker" : "trackers"
            tooltip = "Privacy Report — \(snapshot.totalTrackersBlocked) \(noun) prevented"
        } else if snapshot.securityState == .insecureHTTP {
            tooltip = "Privacy Report — Not Secure (HTTP)"
        } else if snapshot.securityState == .certificateError {
            tooltip = "Privacy Report — Certificate Warning"
        } else {
            tooltip = "Privacy Report"
        }

        privacyShieldCapsule.setTintColorOverride(tint, for: "privacyShield")
        leftCustomActionCapsule.setTintColorOverride(tint, for: "privacyReport")
        rightActionCapsule.setTintColorOverride(tint, for: "privacyReport")

        let shieldButtons = [
            privacyShieldCapsule.button(for: "privacyShield"),
            leftCustomActionCapsule.button(for: "privacyReport"),
            rightActionCapsule.button(for: "privacyReport")
        ].compactMap { $0 }

        for btn in shieldButtons {
            btn.toolTip = tooltip
        }

        if privacyPopover.isShown {
            privacyPopover.update(snapshot: snapshot, summary: isPrivate ? .empty : cachedPrivacySummary)
            scheduleDebouncedPopoverSummaryRefresh()
        }
    }

    private func activeTabDomain() -> String {
        guard let tab = activeTab, !tab.isStartPage else { return "" }
        return URLInputNormalizer.displayDomain(for: tab.currentURL)
    }

    private func buildPopoverRecentGroups() -> [AddressBarPopoverController.RecentGroup] {
        let history = AssetLoader.shared.browsingHistory()
        var historyByDomain: [String: (visitCount: Int, lastVisited: Date, title: String, url: URL)] = [:]
        for hist in history {
            guard let url = URL(string: hist.url) else { continue }
            let domKey = URLInputNormalizer.displayDomain(for: url).lowercased()
            let visits = max(1, hist.visitCount)
            if let existing = historyByDomain[domKey] {
                historyByDomain[domKey] = (
                    visitCount: existing.visitCount + visits,
                    lastVisited: max(existing.lastVisited, hist.lastVisited),
                    title: existing.title,
                    url: existing.url
                )
            } else {
                historyByDomain[domKey] = (visits, hist.lastVisited, hist.title, url)
            }
        }

        var groups: [AddressBarPopoverController.RecentGroup] = []
        var seenDomains = Set<String>()
        for entry in recentSites {
            let key = entry.domain.lowercased()
            seenDomains.insert(key)
            let openCount = tabs.filter {
                !$0.isStartPage && URLInputNormalizer.displayDomain(for: $0.currentURL).lowercased() == key
            }.count
            let histInfo = historyByDomain[key]
            groups.append(.init(
                domain: entry.domain,
                latestURL: entry.url,
                title: entry.title,
                count: max(1, max(openCount, histInfo?.visitCount ?? 0)),
                visitedAt: histInfo?.lastVisited ?? Date(),
                favicon: entry.favicon ?? FaviconCache.shared.memoryCachedIcon(forURLString: entry.url.absoluteString)
            ))
        }
        for hist in history {
            if groups.count >= 8 { break }
            guard let url = URL(string: hist.url) else { continue }
            let domain = URLInputNormalizer.displayDomain(for: url)
            let key = domain.lowercased()
            guard !seenDomains.contains(key) else { continue }
            seenDomains.insert(key)
            let aggVisits = historyByDomain[key]?.visitCount ?? max(1, hist.visitCount)
            groups.append(.init(
                domain: domain,
                latestURL: url,
                title: hist.title,
                count: max(1, aggVisits),
                visitedAt: hist.lastVisited,
                favicon: FaviconCache.shared.memoryCachedIcon(forURLString: hist.url)
            ))
        }
        return groups
    }

    private func buildPopoverOpenTabs() -> [AddressBarPopoverController.OpenTabInfo] {
        tabs.enumerated().compactMap { idx, tab in
            guard let url = tab.currentURL else { return nil }
            return .init(
                id: tab.tabID,
                title: tab.title,
                url: url,
                favicon: tab.favicon,
                isActive: idx == activeTabIndex,
                isStartPage: tab.isStartPage
            )
        }
    }

    private func showAddressBarPopover(initialQuery: String = "") {
        guard let window else { return }
        if initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !BrowserSettings.shared.showFavoritesInSearch {
            dismissAddressBarPopover()
            return
        }
        addressBarPopover.show(
            below: tabAddressBar.activePillAnchorView,
            in: window,
            query: initialQuery,
            isDark: chromeController.currentTheme.prefersLightInk,
            isPrivate: isPrivate,
            recentGroups: buildPopoverRecentGroups(),
            openTabs: buildPopoverOpenTabs(),
            activeDomain: activeTabDomain()
        )
    }

    func dismissAddressBarPopover(animated: Bool = true) {
        addressBarPopover.close(animated: animated)
    }

    private func showPageMenu(relativeTo anchor: NSButton) {
        let tab = activeTab
        let domain = activeTabDomain()
        let zoom = tab?.pageZoomFactor ?? 1.0
        let isDarkAppearance = chromeController.currentTheme.prefersLightInk

        pageMenuPopover.onSelectZoom = { [weak self] factor in
            self?.activeTab?.setPageZoomFactor(factor)
        }
        pageMenuPopover.onFindOnPage = { [weak self] in
            self?.showFindBar()
        }
        pageMenuPopover.onReloadPage = { [weak self] in
            self?.reloadActiveTab()
        }
        pageMenuPopover.onWebsiteSettings = { [weak self] in
            self?.showWebsiteSettingsPopoverForActiveTab()
        }

        pageMenuPopover.toggle(
            relativeTo: anchor,
            state: .init(
                domain: domain,
                zoomFactor: zoom,
                isDarkAppearance: isDarkAppearance
            )
        )
    }

    @objc private func menuCustomizeToolbarAction() { toggleCustomizeToolbarSheet() }

    // MARK: - Customize Toolbar Sheet

    func toggleCustomizeToolbarSheet() {
        if customizeToolbarSheet.isPresented {
            customizeToolbarSheet.dismiss(animated: true)
            return
        }
        dismissAddressBarPopover()
        extensionPopoverController.close()
        pageMenuPopover.close()

        let installed = visibleExtensionsForWindow(engine.installedExtensions())
        let hiddenIDs = Set(installed.map(\.id).filter { extensionsCoordinator.isHiddenFromToolbar($0) })
        let isDark = chromeController.currentTheme.prefersLightInk
        // Update toolbar slots FIRST (without refreshing the sheet) so the sheet's opening animation is never interrupted.
        applyToolbarCustomization(animated: false, isCustomizingOverride: true, refreshSheet: false)
        customizeToolbarSheet.present(extensions: installed, hiddenExtensionIDs: hiddenIDs, isDark: isDark)
        setToolbarCustomizeWobble(true)
    }

    private func setToolbarCustomizeWobble(_ active: Bool) {
        // Animate ONLY individual toolbar icon buttons/elements with slow horizontal left-right sway;
        // glass pill group containers stay completely static.
        sidebarCapsule.setCustomizeWiggle(active, basePhase: 0.00)
        backForwardCapsule.setCustomizeWiggle(active, basePhase: 0.14)
        leftCustomActionCapsule.setCustomizeWiggle(active, basePhase: 0.22)
        extensionsCoordinator.setCustomizeJiggle(active)
        rightActionCapsule.setCustomizeWiggle(active, basePhase: 0.30)
    }

    private func resolvedToolbarSide(forWindowPoint ptInWindow: NSPoint) -> ToolbarActionSide {
        let ptInToolbar = toolbarBarView.convert(ptInWindow, from: nil)
        let midX = tabAddressBar.isHidden ? toolbarBarView.bounds.midX : tabAddressBar.frame.midX
        return ptInToolbar.x < midX ? .left : .right
    }

    private func clusterView(_ cluster: ToolbarCluster) -> NSView {
        switch cluster {
        case .sidebar: return sidebarCluster
        case .backForward: return backForwardCluster
        case .privacyShield: return privacyShieldCluster
        }
    }

    private func isShowingCluster(_ cluster: ToolbarCluster) -> Bool {
        let v = clusterView(cluster)
        return !v.isHidden && v.frame.width > 1.0
    }

    /// True when the point is over one of the two action capsules (where actions are reordered, not clusters).
    private func isPointOverActionCapsule(_ ptInWindow: NSPoint) -> Bool {
        let pt = toolbarBarView.convert(ptInWindow, from: nil)
        for v in [leftCustomActionCluster, rightGlassContainer] where !v.isHidden {
            if v.frame.insetBy(dx: -6, dy: -12).contains(pt) { return true }
        }
        return false
    }

    /// Side (in front of / behind the address bar) and slot among that side's clusters for a drop at `ptInWindow`.
    private func clusterDropPlacement(forWindowPoint ptInWindow: NSPoint, moving cluster: ToolbarCluster) -> (side: ToolbarActionSide, index: Int) {
        let store = ToolbarCustomizationStore.shared
        let side = resolvedToolbarSide(forWindowPoint: ptInWindow)
        let x = toolbarBarView.convert(ptInWindow, from: nil).x
        let others = (side == .left ? store.leftClusters : store.rightClusters).filter { $0 != cluster }
        var insertAt = 0
        for (i, other) in others.enumerated() where isShowingCluster(other) && clusterView(other).frame.midX < x {
            insertAt = i + 1
        }
        return (side, insertAt)
    }

    /// Dropping the address bar re-splits the clusters around it: everything whose centre lies behind the drop point
    /// goes behind the address bar, the rest stays in front, each keeping its order.
    private func repositionAddressBar(atWindowPoint ptInWindow: NSPoint) {
        let store = ToolbarCustomizationStore.shared
        let x = toolbarBarView.convert(ptInWindow, from: nil).x
        var toRight = Set(store.rightClusters)
        for cluster in ToolbarCluster.allCases where isShowingCluster(cluster) {
            if clusterView(cluster).frame.midX > x { toRight.insert(cluster) } else { toRight.remove(cluster) }
        }
        store.splitClusters(movingToRight: toRight)
    }

    private func handleDropNativeToolbarItem(_ id: CustomizableToolbarItemID, atWindowPoint ptInWindow: NSPoint) {
        let store = ToolbarCustomizationStore.shared
        if id == .addressBar {
            repositionAddressBar(atWindowPoint: ptInWindow)
            applyToolbarCustomization(animated: true)
            return
        }
        if let cluster = ToolbarCluster(itemID: id), !(id == .privacyReport && isPointOverActionCapsule(ptInWindow)) {
            store.setVisible(true, for: id)
            let target = clusterDropPlacement(forWindowPoint: ptInWindow, moving: cluster)
            store.placeCluster(cluster, on: target.side, at: target.index)
            applyToolbarCustomization(animated: true)
            return
        }
        let side = resolvedToolbarSide(forWindowPoint: ptInWindow)
        if id.isMovableAction {
            let targetCapsule = (side == .left) ? leftCustomActionCapsule : rightActionCapsule
            let idx = targetCapsule.nativeInsertionIndex(forWindowPoint: ptInWindow, excludingID: id.rawValue)
            store.placeAction(id, on: side, at: idx)
        } else if id.isSpacer {
            store.addSpacer(id, on: side)
        } else {
            store.setVisible(true, for: id)
        }
        applyToolbarCustomization(animated: true)
    }

    private func beginNativeToolbarDragIfHit(_ event: NSEvent) -> Bool {
        let ptWin = event.locationInWindow
        let ptInToolbar = toolbarBarView.convert(ptWin, from: nil)
        guard toolbarBarView.bounds.contains(ptInToolbar) else { return false }

        // 1. Movable native buttons on Right Actions capsule
        if !rightGlassContainer.isHidden,
           let hit = rightActionCapsule.hitNativeButton(atWindowPoint: ptWin),
           let itemID = CustomizableToolbarItemID(rawValue: hit.id) {
            nativeToolbarDrag = NativeToolbarDragSession(
                itemID: itemID,
                originSide: .right,
                sourceCapsule: rightActionCapsule,
                sourceButtonID: hit.id,
                startWindowPoint: ptWin,
                hasStartedDragging: false,
                ghostView: nil
            )
            return true
        }

        // 2. Movable native buttons on Left Custom Actions capsule
        if !leftCustomActionCluster.isHidden,
           let hit = leftCustomActionCapsule.hitNativeButton(atWindowPoint: ptWin),
           let itemID = CustomizableToolbarItemID(rawValue: hit.id) {
            nativeToolbarDrag = NativeToolbarDragSession(
                itemID: itemID,
                originSide: .left,
                sourceCapsule: leftCustomActionCapsule,
                sourceButtonID: hit.id,
                startWindowPoint: ptWin,
                hasStartedDragging: false,
                ghostView: nil
            )
            return true
        }

        // 2b. Default standalone Privacy Report shield (draggable/removable like the other items)
        if !privacyShieldCluster.isHidden,
           privacyShieldCapsule.hitNativeButton(atWindowPoint: ptWin) != nil {
            nativeToolbarDrag = NativeToolbarDragSession(
                itemID: .privacyReport,
                originSide: nil,
                sourceCapsule: privacyShieldCapsule,
                sourceButtonID: "privacyShield",
                startWindowPoint: ptWin,
                hasStartedDragging: false,
                ghostView: nil
            )
            return true
        }

        // 3. Sidebar group
        if !sidebarCluster.isHidden,
           sidebarCapsule.hitNativeButton(atWindowPoint: ptWin) != nil {
            nativeToolbarDrag = NativeToolbarDragSession(
                itemID: .sidebar,
                originSide: nil,
                sourceCapsule: sidebarCapsule,
                sourceButtonID: "sidebar",
                startWindowPoint: ptWin,
                hasStartedDragging: false,
                ghostView: nil
            )
            return true
        }

        // 4. Back/Forward group
        if !backForwardCluster.isHidden,
           backForwardCapsule.hitNativeButton(atWindowPoint: ptWin) != nil {
            nativeToolbarDrag = NativeToolbarDragSession(
                itemID: .backForward,
                originSide: nil,
                sourceCapsule: backForwardCapsule,
                sourceButtonID: "back",
                startWindowPoint: ptWin,
                hasStartedDragging: false,
                ghostView: nil
            )
            return true
        }

        // 5. Address and Search bar
        if !tabAddressBar.isHidden {
            let ptAddr = tabAddressBar.convert(ptWin, from: nil)
            if tabAddressBar.bounds.contains(ptAddr) {
                nativeToolbarDrag = NativeToolbarDragSession(
                    itemID: .addressBar,
                    originSide: nil,
                    sourceCapsule: nil,
                    sourceButtonID: nil,
                    startWindowPoint: ptWin,
                    hasStartedDragging: false,
                    ghostView: nil
                )
                return true
            }
        }

        return false
    }

    private func makeGhostSnapshot(for itemID: CustomizableToolbarItemID) -> NSView {
        let isDark = chromeController.currentTheme.prefersLightInk
        if itemID == .addressBar {
            let pill = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 16
            pill.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.10)).cgColor
            let lbl = NSTextField(labelWithString: "Address and Search")
            lbl.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            lbl.textColor = isDark ? .white : NSColor(white: 0.14, alpha: 1.0)
            lbl.sizeToFit()
            lbl.frame.origin = NSPoint(x: round((220 - lbl.bounds.width) * 0.5), y: round((32 - lbl.bounds.height) * 0.5))
            pill.addSubview(lbl)
            return pill
        }
        let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        iv.wantsLayer = true
        iv.imageScaling = .scaleProportionallyDown
        let sym = (itemID == .backForward) ? "chevron.left.chevron.right" : itemID.symbolName
        iv.image = AssetLoader.shared.symbol(named: sym, pointSize: 18.0, weight: .medium)
        iv.contentTintColor = isDark ? .white : NSColor(white: 0.14, alpha: 1.0)
        return iv
    }

    private func continueNativeToolbarDrag(_ event: NSEvent) {
        guard var session = nativeToolbarDrag, let contentView = window?.contentView else { return }
        let ptWin = event.locationInWindow
        if !session.hasStartedDragging {
            let dist = hypot(ptWin.x - session.startWindowPoint.x, ptWin.y - session.startWindowPoint.y)
            guard dist > 5.0 else { return }
            session.hasStartedDragging = true
            let ghost = makeGhostSnapshot(for: session.itemID)
            let ptInContent = contentView.convert(ptWin, from: nil)
            ghost.frame.origin = NSPoint(
                x: round(ptInContent.x - ghost.bounds.width * 0.5),
                y: round(ptInContent.y - ghost.bounds.height * 0.5)
            )
            contentView.addSubview(ghost)
            session.ghostView = ghost
            if let cap = session.sourceCapsule, let bid = session.sourceButtonID {
                cap.setNativeButtonDragging(true, for: bid)
            } else if session.itemID == .addressBar {
                tabAddressBar.alphaValue = 0.25
            }
            NSCursor.closedHand.push()
            nativeToolbarDrag = session
        }

        guard let ghost = session.ghostView else { return }
        let ptInContent = contentView.convert(ptWin, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.frame.origin = NSPoint(
            x: round(ptInContent.x - ghost.bounds.width * 0.5),
            y: round(ptInContent.y - ghost.bounds.height * 0.5)
        )
        let toolbarRect = toolbarBarView.convert(toolbarBarView.bounds, to: nil)
        let outside = !toolbarRect.insetBy(dx: -24, dy: -26).contains(ptWin)
        ghost.alphaValue = outside ? 0.55 : 0.95
        CATransaction.commit()
    }

    private func endNativeToolbarDrag(_ event: NSEvent) {
        guard let session = nativeToolbarDrag else { return }
        nativeToolbarDrag = nil
        if let cap = session.sourceCapsule, let bid = session.sourceButtonID {
            cap.setNativeButtonDragging(false, for: bid)
        }
        if session.itemID == .addressBar {
            tabAddressBar.alphaValue = 1.0
        }
        if session.hasStartedDragging {
            session.ghostView?.removeFromSuperview()
            NSCursor.pop()
        } else {
            return
        }

        let ptWin = event.locationInWindow
        let toolbarRect = toolbarBarView.convert(toolbarBarView.bounds, to: nil)
        let insideToolbar = toolbarRect.insetBy(dx: -24, dy: -26).contains(ptWin)
        let store = ToolbarCustomizationStore.shared

        if !insideToolbar {
            // Dragged off the toolbar -> remove item cleanly (poof/haptic) and un-dim it in the sheet!
            store.setVisible(false, for: session.itemID)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            applyToolbarCustomization(animated: true)
            return
        }

        if session.itemID == .addressBar {
            repositionAddressBar(atWindowPoint: ptWin)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            applyToolbarCustomization(animated: true)
            return
        }
        if let cluster = ToolbarCluster(itemID: session.itemID),
           !(session.itemID == .privacyReport && isPointOverActionCapsule(ptWin)) {
            let target = clusterDropPlacement(forWindowPoint: ptWin, moving: cluster)
            store.placeCluster(cluster, on: target.side, at: target.index)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            applyToolbarCustomization(animated: true)
            return
        }

        // Released inside toolbar -> reorder or move movable actions across left/right sides
        if session.itemID.isMovableAction {
            let targetSide = resolvedToolbarSide(forWindowPoint: ptWin)
            let targetCapsule = (targetSide == .left) ? leftCustomActionCapsule : rightActionCapsule
            let targetIndex = targetCapsule.nativeInsertionIndex(forWindowPoint: ptWin, excludingID: session.itemID.rawValue)
            store.placeAction(session.itemID, on: targetSide, at: targetIndex)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            applyToolbarCustomization(animated: true)
        }
    }

    private func cancelNativeToolbarDrag() {
        guard let session = nativeToolbarDrag else { return }
        nativeToolbarDrag = nil
        if let cap = session.sourceCapsule, let bid = session.sourceButtonID {
            cap.setNativeButtonDragging(false, for: bid)
        }
        if session.itemID == .addressBar {
            tabAddressBar.alphaValue = 1.0
        }
        if session.hasStartedDragging {
            session.ghostView?.removeFromSuperview()
            NSCursor.pop()
        }
    }

    private func applyToolbarCustomization(
        animated: Bool,
        isCustomizingOverride: Bool? = nil,
        refreshSheet: Bool = true
    ) {
        let store = ToolbarCustomizationStore.shared
        let isCustomizing = isCustomizingOverride ?? customizeToolbarSheet.isPresented

        // 1. Sidebar group
        let showSidebar = store.isVisibleInToolbar(.sidebar)
        sidebarCapsule.setHidden(!showSidebar, for: "sidebar", animated: animated)
        if isPrivate {
            sidebarCapsule.setHidden(!showSidebar, for: "privateLabel", animated: animated)
        } else {
            sidebarCapsule.setHidden(!showSidebar, for: "tabGroups", animated: animated)
        }
        let sidebarHasContent = showSidebar || sidebarCapsule.hasMergedExtensions || sidebarCapsule.hasPlaceholder
        sidebarCluster.isHidden = !sidebarHasContent

        // 2. Address and Search bar
        tabAddressBar.isHidden = !store.isVisibleInToolbar(.addressBar)

        // 3. Left & Right movable action capsules (exact user-defined side + slot ordering!)
        let leftOrder = store.leftActionOrder
        let rightOrder = store.rightActionOrder
        leftCustomActionCapsule.applyNativeButtonOrder(leftOrder.map(\.rawValue))
        rightActionCapsule.applyNativeButtonOrder(rightOrder.map(\.rawValue))

        for actionID in CustomizableToolbarItemID.allMovableActions {
            let onLeft = leftOrder.contains(actionID)
            let onRight = rightOrder.contains(actionID)
            if actionID == .downloads {
                // Downloads is always visible when placed in the toolbar (left or right).
                // If the user removed it from the toolbar, show it temporarily on the right capsule
                // while a download is active or finished-but-unviewed (or while the popover is open).
                let showTempRight = !onLeft && !onRight && downloadController.needsTemporaryToolbarButton
                let showLeft = onLeft
                let showRight = onRight || showTempRight
                leftCustomActionCapsule.setHidden(!showLeft, for: actionID.rawValue, animated: animated)
                rightActionCapsule.setHidden(!showRight, for: actionID.rawValue, animated: animated)
                if showLeft, let leftBtn = leftCustomActionCapsule.button(for: "downloads") {
                    downloadController.updateAnchorButton(leftBtn, capsule: leftCustomActionCapsule)
                } else if let rightBtn = rightActionCapsule.button(for: "downloads") {
                    downloadController.updateAnchorButton(rightBtn, capsule: rightActionCapsule)
                }
            } else {
                leftCustomActionCapsule.setHidden(!onLeft, for: actionID.rawValue, animated: animated)
                rightActionCapsule.setHidden(!onRight, for: actionID.rawValue, animated: animated)
            }
        }

        let leftHasContent = leftCustomActionCapsule.currentRequiredWidth > 0.5
        leftCustomActionCluster.isHidden = !leftHasContent
        rightGlassContainer.isHidden = (rightActionCapsule.currentRequiredWidth <= 0.5)

        updateToolbarExtensionConstraints(animated: animated)

        if isCustomizing && refreshSheet {
            let installed = visibleExtensionsForWindow(engine.installedExtensions())
            let hiddenIDs = Set(installed.map(\.id).filter { extensionsCoordinator.isHiddenFromToolbar($0) })
            customizeToolbarSheet.refreshState(
                extensions: installed,
                hiddenExtensionIDs: hiddenIDs,
                isDark: chromeController.currentTheme.prefersLightInk
            )
            setToolbarCustomizeWobble(true)
        }
    }

    // MARK: - Adaptive Theme & Toolbar Refresh

    private func refreshToolbarUI(animatedTabBar: Bool? = nil) {
        let activeOverride = passwordsPasskeyManager?.activeOriginatingTabPresentation
        let items = tabs.enumerated().map { idx, tab -> TabPresentationItem in
            let isAct = (idx == activeTabIndex)
            let ov = isAct ? activeOverride : nil
            return TabPresentationItem(
                id: tab.tabID,
                title: ov?.title ?? tab.title,
                url: ov?.url ?? tab.currentURL,
                favicon: ov?.favicon ?? tab.favicon,
                isLoading: ov != nil ? false : tab.isLoading,
                progress: ov != nil ? 1.0 : tab.estimatedProgress,
                isActive: isAct,
                isPinned: pinnedTabIDs.contains(tab.tabID)
            )
        }
        let layout = BrowserSettings.shared.tabLayout
        tabAddressBar.update(items: items, animated: animatedTabBar)
        sidebarView.update(tabs: items)
        if layout == "separate" {
            separateTabStripView.update(items: items, animated: animatedTabBar ?? true)
        }
        if layout == "vertical" {
            verticalTabRailView.update(items: items)
        }
        updateSeparateTabStripVisibility(animated: false)
        updateVerticalTabRailVisibility(animated: false)
        if let active = activeTab {
            tabLastActiveAt[active.tabID] = Date()
            let cleanTitle = active.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseTitle = cleanTitle.isEmpty ? (isPrivate ? "Safarium — Private" : "Safarium") : cleanTitle
            let winTitle = isPrivate && !baseTitle.contains("Private") ? "\(baseTitle) — Private" : baseTitle
            if window?.title != winTitle {
                window?.title = winTitle
            }
        }

        var animateBackForwardPop = false
        if isOverviewToolbarActive {
            backForwardCapsule.setEnabled(false, for: "back")
            backForwardCapsule.setEnabled(false, for: "forward")
            rightActionCapsule.setEnabled(false, for: "share")
        } else {
            let canBack = activeTab?.canGoBack ?? false
            let canFwd = activeTab?.canGoForward ?? false
            if let prev = lastAnimatedBackForwardState,
               (prev.canBack != canBack || prev.canForward != canFwd),
               window?.isVisible == true {
                animateBackForwardPop = true
            }
            lastAnimatedBackForwardState = (canBack, canFwd)
            backForwardCapsule.setEnabled(canBack, for: "back")
            backForwardCapsule.setEnabled(canFwd, for: "forward")
            let canShare = !(activeTab?.isNativeInternalPage ?? true)
            rightActionCapsule.setEnabled(canShare, for: "share")
        }
        updateToolbarExtensionConstraints(animated: animateBackForwardPop)
    }

    // MARK: - Chrome Web Store Extensions UI

    private func updateToolbarExtensionConstraints(animated rawAnimated: Bool) {
        let animated = rawAnimated && (window?.isVisible == true) && toolbarBarView.bounds.width > 1.0
        let store = ToolbarCustomizationStore.shared
        let canBack = activeTab?.canGoBack ?? false
        let canFwd = activeTab?.canGoForward ?? false
        let backFwdEnabled = store.isVisibleInToolbar(.backForward)
        let forceShowDisabledArrows = isOverviewToolbarActive || customizeToolbarSheet.isPresented
        let hasHistory = backFwdEnabled && (canBack || canFwd || forceShowDisabledArrows)
        let hasBackForwardContent = hasHistory || backForwardCapsule.hasMergedExtensions || backForwardCapsule.hasPlaceholder
        let wasBackForwardClusterHidden = backForwardCluster.isHidden

        let animateButtonsInsideCluster = animated && !wasBackForwardClusterHidden && hasBackForwardContent
        if backFwdEnabled && forceShowDisabledArrows {
            backForwardCapsule.setHidden(false, for: "back", animated: false)
            backForwardCapsule.setHidden(false, for: "forward", animated: false)
        } else if !backFwdEnabled {
            backForwardCapsule.setHidden(true, for: "back", animated: animateButtonsInsideCluster)
            backForwardCapsule.setHidden(true, for: "forward", animated: animateButtonsInsideCluster)
        } else {
            backForwardCapsule.setHidden(!canBack, for: "back", animated: animateButtonsInsideCluster)
            backForwardCapsule.setHidden(!canFwd, for: "forward", animated: animateButtonsInsideCluster)
        }
        let targetBackW: CGFloat = hasBackForwardContent ? backForwardCapsule.currentRequiredWidth : 0.0
        if hasBackForwardContent {
            backForwardCluster.isHidden = false
            if animated && wasBackForwardClusterHidden {
                backForwardCluster.wantsLayer = true
                backForwardCluster.alphaValue = 0.0
            } else {
                backForwardCluster.alphaValue = 1.0
            }
        } else if !animated {
            backForwardCluster.isHidden = true
            backForwardCluster.alphaValue = 1.0
        }

        let w0 = extensionsCoordinator.requiredWidth(for: .afterSidebar)
        let showStandaloneShield = store.showsStandalonePrivacyShield
        privacyShieldCluster.isHidden = !showStandaloneShield
        let shieldW: CGFloat = showStandaloneShield ? SafariMetrics.glassButtonSize : 0.0
        let leftCustomW: CGFloat = leftCustomActionCluster.isHidden ? 0.0 : leftCustomActionCapsule.currentRequiredWidth
        let w1 = extensionsCoordinator.requiredWidth(for: .leftOfAddressBar)
        let w2 = extensionsCoordinator.requiredWidth(for: .rightOfAddressBar)
        let w3 = extensionsCoordinator.requiredWidth(for: .trailing)

        if !sidebarAnimating { toolbarChainSidebarOpen = isSidebarOpen }
        rebuildToolbarChain()

        var widths: [ObjectIdentifier: CGFloat] = [:]
        widths[ObjectIdentifier(extensionsCoordinator.capsule(for: .afterSidebar))] = w0
        widths[ObjectIdentifier(backForwardCluster)] = targetBackW
        widths[ObjectIdentifier(privacyShieldCluster)] = shieldW
        widths[ObjectIdentifier(leftCustomActionCluster)] = leftCustomW
        widths[ObjectIdentifier(extensionsCoordinator.capsule(for: .leftOfAddressBar))] = w1
        widths[ObjectIdentifier(extensionsCoordinator.capsule(for: .rightOfAddressBar))] = w2
        widths[ObjectIdentifier(rightGlassContainer)] = rightGlassContainer.isHidden ? 0.0 : 1.0
        widths[ObjectIdentifier(extensionsCoordinator.capsule(for: .trailing))] = w3
        chainWidths.merge(widths) { _, new in new }

        let addrLeading: CGFloat = 10.0 + store.leftSpacerExtraWidth
        let addrTrailing: CGFloat = -(10.0 + store.rightSpacerExtraWidth)

        let apply = { [self] (animator: Bool) in
            func set(_ c: NSLayoutConstraint?, _ v: CGFloat) {
                if animator { c?.animator().constant = v } else { c?.constant = v }
            }
            set(afterSidebarExtWidthConstraint, w0)
            set(backForwardWidthConstraint, targetBackW)
            set(privacyShieldWidthConstraint, shieldW)
            set(leftCustomActionWidthConstraint, leftCustomW)
            set(leftExtWidthConstraint, w1)
            set(tabAddressBarLeadingConstraint, addrLeading)
            set(tabAddressBarTrailingConstraint, addrTrailing)
            set(rightExtWidthConstraint, w2)
            set(trailingExtWidthConstraint, w3)
            applyToolbarChainConstants(animated: animator)
        }
        if animated {
            let isHidingCluster = !hasBackForwardContent && !wasBackForwardClusterHidden
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = isHidingCluster ? 0.16 : 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 1.0, 0.32, 1.0)
                ctx.allowsImplicitAnimation = true
                apply(true)
                self.toolbarBarView.layoutSubtreeIfNeeded()
                if hasBackForwardContent && wasBackForwardClusterHidden {
                    self.backForwardCluster.animator().alphaValue = 1.0
                } else if isHidingCluster {
                    self.backForwardCluster.animator().alphaValue = 0.0
                }
            }, completionHandler: { [weak self] in
                guard let self else { return }
                if (self.backForwardWidthConstraint?.constant ?? 0) <= 0.5 {
                    self.backForwardCluster.isHidden = true
                    self.backForwardCluster.alphaValue = 1.0
                }
            })
            if hasBackForwardContent && wasBackForwardClusterHidden, let layer = backForwardCluster.layer {
                let cx = max(18.0, backForwardCluster.bounds.midX)
                let cy = max(18.0, backForwardCluster.bounds.midY)
                var fromT = CATransform3DIdentity
                fromT = CATransform3DTranslate(fromT, cx, cy, 0)
                fromT = CATransform3DScale(fromT, 0.55, 0.55, 1.0)
                fromT = CATransform3DTranslate(fromT, -cx, -cy, 0)
                let spring = CASpringAnimation(keyPath: "transform")
                spring.mass = 1.0
                spring.stiffness = 460.0
                spring.damping = 28.0
                spring.initialVelocity = 0.0
                spring.fromValue = NSValue(caTransform3D: fromT)
                spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                spring.duration = spring.settlingDuration
                layer.add(spring, forKey: "backForwardClusterPopIn")
            } else if isHidingCluster, let layer = backForwardCluster.layer {
                let cx = max(18.0, backForwardCluster.bounds.midX)
                let cy = max(18.0, backForwardCluster.bounds.midY)
                var toT = CATransform3DIdentity
                toT = CATransform3DTranslate(toT, cx, cy, 0)
                toT = CATransform3DScale(toT, 0.65, 0.65, 1.0)
                toT = CATransform3DTranslate(toT, -cx, -cy, 0)
                let shrink = CABasicAnimation(keyPath: "transform")
                shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
                shrink.toValue = NSValue(caTransform3D: toT)
                shrink.duration = 0.16
                shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                layer.add(shrink, forKey: "backForwardClusterPopOut")
            }
        } else {
            apply(false)
        }
    }

    // MARK: - Toolbar chain (clusters on either side of the address bar)

    private func chainNode(_ view: NSView) -> ToolbarChainNode {
        ToolbarChainNode(key: ObjectIdentifier(view), leading: view.leadingAnchor, trailing: view.trailingAnchor)
    }

    private func chainNodes(for cluster: ToolbarCluster) -> [ToolbarChainNode] {
        switch cluster {
        case .sidebar:
            return [
                ToolbarChainNode(key: ObjectIdentifier(sidebarSlotGuide), leading: sidebarSlotGuide.leadingAnchor, trailing: sidebarSlotGuide.trailingAnchor),
                chainNode(extensionsCoordinator.capsule(for: .afterSidebar))
            ]
        case .backForward: return [chainNode(backForwardCluster)]
        case .privacyShield: return [chainNode(privacyShieldCluster)]
        }
    }

    /// Re-links the toolbar as `[left clusters][left actions][left ext] ADDRESS [right ext][right actions][trailing
    /// ext][right clusters]`. Cheap no-op unless the user's cluster placement changed.
    private func rebuildToolbarChain() {
        let store = ToolbarCustomizationStore.shared
        let signature = (store.leftClusters.map(\.rawValue) + ["|"] + store.rightClusters.map(\.rawValue)).joined(separator: ",")
        guard signature != chainSignature else { return }
        chainSignature = signature

        NSLayoutConstraint.deactivate(toolbarChainConstraints)
        toolbarChainConstraints.removeAll()

        let left = store.leftClusters.flatMap { chainNodes(for: $0) }
            + [chainNode(leftCustomActionCluster), chainNode(extensionsCoordinator.capsule(for: .leftOfAddressBar))]
        let right = [
            chainNode(extensionsCoordinator.capsule(for: .rightOfAddressBar)),
            chainNode(rightGlassContainer),
            chainNode(extensionsCoordinator.capsule(for: .trailing))
        ] + store.rightClusters.flatMap { chainNodes(for: $0) }
        chainLeftNodes = left
        chainRightNodes = right

        var constraints: [NSLayoutConstraint] = []
        let origin = left[0].leading.constraint(equalTo: toolbarBarView.leadingAnchor, constant: SafariMetrics.leftGroup1StartX)
        chainLeftOriginConstraint = origin
        constraints.append(origin)

        chainLeftGapConstraints = (1..<left.count).map { left[$0].leading.constraint(equalTo: left[$0 - 1].trailing, constant: 0) }
        constraints += chainLeftGapConstraints

        let addrLeading = tabAddressBar.leadingAnchor.constraint(equalTo: left[left.count - 1].trailing, constant: tabAddressBarLeadingConstraint?.constant ?? 10)
        let addrTrailing = tabAddressBar.trailingAnchor.constraint(equalTo: right[0].leading, constant: tabAddressBarTrailingConstraint?.constant ?? -10)
        tabAddressBarLeadingConstraint = addrLeading
        tabAddressBarTrailingConstraint = addrTrailing
        constraints += [addrLeading, addrTrailing]

        chainRightGapConstraints = (0..<(right.count - 1)).map { right[$0].trailing.constraint(equalTo: right[$0 + 1].leading, constant: 0) }
        constraints += chainRightGapConstraints

        let edge = right[right.count - 1].trailing.constraint(equalTo: toolbarBarView.trailingAnchor, constant: -SafariMetrics.rightGroupTrailingMargin)
        chainRightEdgeConstraint = edge
        constraints.append(edge)

        toolbarChainConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        applyToolbarChainConstants(animated: false)
    }

    /// Writes the gap constants of the current chain from the last known item widths.
    private func applyToolbarChainConstants(animated: Bool) {
        let gap = SafariMetrics.leftGroupInterGap
        let sidebarW: CGFloat = toolbarChainSidebarOpen ? 0.0 : effectiveSidebarCapsuleWidth
        chainWidths[ObjectIdentifier(sidebarSlotGuide)] = sidebarW
        func set(_ c: NSLayoutConstraint?, _ v: CGFloat) {
            guard let c, abs(c.constant - v) > 0.001 else { return }
            if animated { c.animator().constant = v } else { c.constant = v }
        }
        func width(_ n: ToolbarChainNode) -> CGFloat { chainWidths[n.key] ?? 0.0 }

        set(sidebarSlotWidthConstraint, sidebarW)
        set(chainLeftOriginConstraint, toolbarChainSidebarOpen ? 8.0 : SafariMetrics.leftGroup1StartX)
        var anyVisibleBefore = false
        for (i, node) in chainLeftNodes.enumerated() {
            let visible = width(node) > 0.5
            if i >= 1, i - 1 < chainLeftGapConstraints.count {
                set(chainLeftGapConstraints[i - 1], (visible && anyVisibleBefore) ? gap : 0.0)
            }
            if visible { anyVisibleBefore = true }
        }
        for k in 0..<chainRightGapConstraints.count {
            let visible = width(chainRightNodes[k]) > 0.5
            let anyVisibleAfter = chainRightNodes[(k + 1)...].contains { width($0) > 0.5 }
            set(chainRightGapConstraints[k], (visible && anyVisibleAfter) ? -gap : 0.0)
        }
    }

    /// Where the first non-sidebar item on the left sits while the sidebar pane is closed.
    private var closedLeftChainLeading: CGFloat {
        let sidebarOnLeft = ToolbarCustomizationStore.shared.clusterSide(.sidebar) == .left
        return SafariMetrics.leftGroup1StartX + (sidebarOnLeft ? effectiveSidebarCapsuleWidth + SafariMetrics.leftGroupInterGap : 0.0)
    }

    /// Left-chain views that slide with the sidebar pane (everything except the sidebar toggle itself).
    private var chainLeftSlidingViews: [NSView] {
        var views: [NSView] = []
        for cluster in ToolbarCustomizationStore.shared.leftClusters {
            switch cluster {
            case .sidebar: views.append(extensionsCoordinator.capsule(for: .afterSidebar))
            case .backForward: views.append(backForwardCluster)
            case .privacyShield: views.append(privacyShieldCluster)
            }
        }
        views.append(leftCustomActionCluster)
        views.append(extensionsCoordinator.capsule(for: .leftOfAddressBar))
        return views
    }

    func refreshExtensionsUI(_ extensions: [BrowserExtensionItem], animated: Bool = true) {
        let prevWidths = ExtensionToolbarZone.allCases.map { extensionsCoordinator.requiredWidth(for: $0) }
        let visibleExtensions = visibleExtensionsForWindow(extensions)
        extensionsCoordinator.update(extensions: visibleExtensions)
        extensionsCoordinator.apply(theme: chromeController.currentTheme, animated: false)
        let newWidths = ExtensionToolbarZone.allCases.map { extensionsCoordinator.requiredWidth(for: $0) }
        if prevWidths != newWidths {
            updateToolbarExtensionConstraints(animated: animated)
        }
        if customizeToolbarSheet.isPresented {
            let hiddenIDs = Set(visibleExtensions.map(\.id).filter { extensionsCoordinator.isHiddenFromToolbar($0) })
            customizeToolbarSheet.refreshState(
                extensions: visibleExtensions,
                hiddenExtensionIDs: hiddenIDs,
                isDark: chromeController.currentTheme.prefersLightInk
            )
        }
    }

    func openChromeWebStore() {
        guard let url = URL(string: "https://chromewebstore.google.com") else { return }
        if activeTab?.isStartPage == true {
            navigateActiveTab(to: url)
        } else {
            createNewTab(url: url, activate: true)
        }
    }

    func showManageExtensionsPopover(relativeTo anchor: NSView? = nil, selectingExtensionID: String? = nil) {
        extensionPopoverController.close()
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showSettingsWindow(pane: .extensions, selectingExtensionID: selectingExtensionID)
            return
        }
        let targetAnchor: NSView = anchor
            ?? extensionsCoordinator.firstVisibleCapsule()
            ?? sidebarCluster
        extensionPopoverController.showManageExtensionsPopover(
            relativeTo: targetAnchor,
            extensions: visibleExtensionsForWindow(engine.installedExtensions()),
            isDark: chromeController.currentTheme.prefersLightInk,
            isHiddenInToolbar: { [weak self] id in
                self?.extensionsCoordinator.isHiddenFromToolbar(id) ?? false
            }
        )
    }

    func promptLoadUnpackedExtension() {
        let panel = NSOpenPanel()
        panel.title = "Load Unpacked MV3 Extension"
        panel.message = "Select an unpacked Chrome extension folder containing manifest.json."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard let self, response == .OK, let dirURL = panel.url else { return }
            _ = self.engine.loadUnpackedExtension(atPath: dirURL.path)
            self.refreshExtensionsUI(self.engine.installedExtensions())
        }
    }

    func promptInstallCRXExtension() {
        let panel = NSOpenPanel()
        panel.title = "Install Chrome Extension (.crx / .zip)"
        panel.message = "Select a Chrome extension .crx or .zip package to install into Safarium."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard let self, response == .OK, let fileURL = panel.url else { return }
            self.engine.installExtensionFromCRX(atPath: fileURL.path) { [weak self] success, errorMessage in
                guard let self else { return }
                self.refreshExtensionsUI(self.engine.installedExtensions())
                if !success, let win = self.window {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Could Not Install Extension"
                    alert.informativeText = errorMessage ?? "The selected archive could not be unpacked or is missing manifest.json."
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: win)
                }
            }
        }
    }

    func removeExtension(withID extensionID: String) {
        extensionPopoverController.close()
        _ = engine.uninstallExtension(withID: extensionID)
        refreshExtensionsUI(engine.installedExtensions(), animated: false)
    }

    private func applyAdaptiveTheme(_ theme: AdaptiveChromeTheme, animated: Bool) {
        // Never stall active trackpad scroll, momentum glide, or 120Hz rubber-band spring with a
        // synchronous NSWindow.appearance / AppKit re-theme pass; defer until motion settles.
        if isTrackpadScrollActive || elasticScrollEngine.isElasticInteractionActive {
            pendingAdaptiveTheme = (theme, animated)
            return
        }
        let isWebpage = (activeTab?.isNativeInternalPage == false)
        let effectiveTheme: AdaptiveChromeTheme
        if isWebpage && !BrowserSettings.shared.showWebsiteColorInToolbar {
            let sysDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            effectiveTheme = sysDark ? .defaultDark : .defaultLight
        } else {
            effectiveTheme = theme
        }

        // Sync NSWindow appearance so macOS 27 Tahoe renders authentic dark/light Liquid Glass
        // traffic lights (including unfocused glass rims) matching the live toolbar theme.
        if let win = window, win.appearance?.name != effectiveTheme.preferredAppearance?.name {
            win.appearance = effectiveTheme.preferredAppearance
        }

        sidebarCapsule.apply(theme: effectiveTheme, animated: animated)
        backForwardCapsule.apply(theme: effectiveTheme, animated: animated)
        privacyShieldCapsule.apply(theme: effectiveTheme, animated: animated)
        leftCustomActionCapsule.apply(theme: effectiveTheme, animated: animated)
        extensionsCoordinator.apply(theme: effectiveTheme, animated: animated)
        rightActionCapsule.apply(theme: effectiveTheme, animated: animated)
        refreshPrivacyShieldUI()
        tabAddressBar.apply(theme: effectiveTheme, animated: animated)
        if !separateTabStripView.isHidden {
            separateTabStripView.apply(theme: effectiveTheme)
        }
        if !verticalTabRailView.isHidden {
            verticalTabRailView.apply(theme: effectiveTheme)
        }
        if !sidebarView.isHidden {
            sidebarView.apply(theme: effectiveTheme, animated: animated)
        }
        pullToRefreshView.apply(theme: effectiveTheme)
        if tabOverviewView.isPresented {
            tabOverviewView.apply(theme: effectiveTheme)
        }
        addressBarPopover.applyTheme(isDark: effectiveTheme.prefersLightInk)
        if pageMenuPopover.isShown {
            pageMenuPopover.applyTheme(isDark: effectiveTheme.prefersLightInk)
        }
        if !findBarView.isHidden {
            findBarView.apply(isDark: effectiveTheme.prefersLightInk)
        }
        if customizeToolbarSheet.isPresented {
            let installed = visibleExtensionsForWindow(engine.installedExtensions())
            let hiddenIDs = Set(installed.map(\.id).filter { extensionsCoordinator.isHiddenFromToolbar($0) })
            customizeToolbarSheet.refreshState(
                extensions: installed,
                hiddenExtensionIDs: hiddenIDs,
                isDark: effectiveTheme.prefersLightInk
            )
        }

        let activeFixedHeader: NSColor? = (isWebpage && BrowserSettings.shared.showWebsiteColorInToolbar)
            ? activeTab?.fixedHeaderColor
            : nil
        let startVeilColor: NSColor? = (activeTab?.isStartPage == true)
            ? startPageView.effectiveTopColor
            : ((activeTab?.isHistoryPage == true)
                ? historyPageView.effectiveTopColor
                : ((activeTab?.isInspectPage == true) ? inspectPageView.effectiveTopColor : nil))
        toolbarFrostView.apply(
            prefersLightInk: effectiveTheme.prefersLightInk,
            sampledColor: effectiveTheme.sampledColor,
            customVeilColor: startVeilColor,
            fixedHeaderColor: activeFixedHeader,
            animated: animated
        )
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? SafariMetrics.topEdgeTintAnimationDuration : 0.0)
        mainPaneView.layer?.backgroundColor = effectiveTheme.sampledColor.cgColor
        extensionBackdropFill.layer?.backgroundColor = effectiveTheme.sampledColor.cgColor
        toolbarBottomHairline.layer?.backgroundColor = effectiveTheme.toolbarBottomHairlineColor.cgColor
        CATransaction.commit()

        window?.backgroundColor = effectiveTheme.sampledColor
    }

    // MARK: - NSWindowDelegate

    /// Enforce the declared minimum window size. AppKit derives the window's minimum from Auto Layout once the toolbar
    /// no longer forces a wide fitting size, which would otherwise let the window shrink far below `SafariMetrics`.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, SafariMetrics.minWindowWidth),
               height: max(frameSize.height, SafariMetrics.minWindowHeight))
    }

    func windowDidResize(_ notification: Notification) {
        for tab in tabs {
            tab.contentView.frame = webContentHost.bounds
        }
        if let tab = activeTab {
            syncElasticMetrics(for: tab)
        }
        addressBarPopover.repositionIfShown()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if tabs.isEmpty {
            openInitialTabsIfNeeded()
        }
        if isPrivate && BrowserSettings.shared.requireTouchIDForPrivate {
            if let resignedAt = privateResignTime, Date().timeIntervalSince(resignedAt) >= 60.0 {
                lockPrivateWindow()
            }
            privateResignTime = nil
            if isPrivateWindowLocked {
                authenticateAndUnlockPrivateWindow()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.isMovable = true
        verticalTabRailView.dismissHoverPill()
        tabHoverPreviewController.dismiss(animated: false)
        if isPrivate && BrowserSettings.shared.requireTouchIDForPrivate && !tabs.isEmpty {
            privateResignTime = Date()
        }
    }

    private func handleTabHoverPreview(tabID: String, anchorView: NSView, hovered: Bool, isVertical: Bool) {
        guard hovered else {
            tabHoverPreviewController.hoverExited(tabID: tabID)
            return
        }
        guard let window,
              window.isVisible,
              !tabOverviewView.isPresented,
              !addressBarPopover.isShown,
              let tab = tabs.first(where: { $0.tabID == tabID }),
              (isVertical || tab.tabID != activeTab?.tabID) else {
            tabHoverPreviewController.dismiss(animated: false)
            return
        }

        let snap: NSImage?
        if tab.isStartPage {
            snap = cachedStartPageSnapshot ?? captureStartPageSnapshot()
        } else {
            snap = tab.cachedSnapshot ?? NavigationSnapshotStore.shared.snapshot(tabID: tab.tabID, entryID: tab.currentNavigationEntryID)?.image
        }

        let item = TabHoverPreviewController.PreviewItem(
            tabID: tab.tabID,
            title: tab.title,
            domain: URLInputNormalizer.displayDomain(for: tab.currentURL),
            favicon: tab.favicon,
            snapshot: snap,
            isStartPage: tab.isStartPage,
            canClose: tabs.count > 1
        )

        let placement: TabHoverPreviewController.Placement
        if isVertical {
            let railRightInWin = verticalTabRailView.convert(NSPoint(x: verticalTabRailView.bounds.maxX, y: 0), to: nil).x
            placement = .belowVerticalPill(anchorView: anchorView, railRightXInWindow: railRightInWin)
        } else {
            placement = .below(anchorView: anchorView)
        }

        tabHoverPreviewController.hoverEntered(
            item: item,
            placement: placement,
            in: window,
            isDark: chromeController.currentTheme.prefersLightInk
        )
    }

    // MARK: - Tab Layout (`Compact` / `Separate` / `Vertical`), Auto-Close, & Private Touch ID Lock

    private func applyTabLayoutPreference(animated: Bool) {
        let layout = BrowserSettings.shared.tabLayout
        tabAddressBar.singleAddressOnlyMode = (layout == "separate" || layout == "vertical")
        updateSeparateTabStripVisibility(animated: animated)
        updateVerticalTabRailVisibility(animated: animated)
        applyAdaptiveTheme(chromeController.currentTheme, animated: false)
        refreshToolbarUI(animatedTabBar: animated)
    }

    private func updateSeparateTabStripVisibility(animated: Bool) {
        let showSeparate = (BrowserSettings.shared.tabLayout == "separate") && (tabs.count > 1)
        let stripH: CGFloat = showSeparate ? SeparateTabStripView.barHeight : 0.0
        separateTabStripView.isHidden = !showSeparate
        if separateTabStripHeightConstraint?.constant != stripH {
            separateTabStripHeightConstraint?.constant = stripH
            toolbarFrostView.topBarHeight = SafariMetrics.toolbarHeight + stripH
            toolbarFrostHeightConstraint?.constant = ToolbarGlassView.activeTotalHeight + stripH
            for tab in tabs { syncPageTopInset(for: tab) }
            tabOverviewTopConstraint?.constant = SafariMetrics.toolbarHeight + stripH
            startPageView.setExtraTopInset(stripH, animated: animated)
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    mainPaneView.layoutSubtreeIfNeeded()
                }
            }
            for tab in tabs {
                tab.contentView.frame = webContentHost.bounds
            }
        }
    }

    private func updateVerticalTabRailVisibility(animated: Bool) {
        let showRail = (BrowserSettings.shared.tabLayout == "vertical") && !isSidebarOpen
        let railW: CGFloat = showRail ? VerticalTabRailView.railWidth : 0.0
        verticalTabRailView.isHidden = !showRail
        if !showRail {
            verticalTabRailView.dismissHoverPill()
        }
        // Switch toolbarFrostView between top-only and unified L-shape (top toolbar + vertical rail as ONE glass surface).
        toolbarFrostHeightConstraint?.isActive = !showRail
        toolbarFrostBottomConstraint?.isActive = showRail
        toolbarFrostView.topBarHeight = SafariMetrics.toolbarHeight + (separateTabStripHeightConstraint?.constant ?? 0)
        toolbarFrostView.verticalRailWidth = railW

        if verticalTabRailWidthConstraint?.constant != railW {
            verticalTabRailWidthConstraint?.constant = railW
            for tab in tabs { syncPageTopInset(for: tab) }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    mainPaneView.layoutSubtreeIfNeeded()
                }
            } else {
                mainPaneView.layoutSubtreeIfNeeded()
            }
            for tab in tabs {
                tab.contentView.frame = webContentHost.bounds
            }
        }
    }

    private func showTabGroupsMenu() {
        let menu = NSMenu(title: "Tab Groups")
        let count = max(1, tabs.count)
        let currentTitle = count == 1 ? "1 Tab" : "\(count) Tabs"
        let currentItem = NSMenuItem(title: currentTitle, action: #selector(handleTabGroupsShowCurrent), keyEquivalent: "")
        currentItem.target = self
        currentItem.state = .on
        menu.addItem(currentItem)
        menu.addItem(.separator())

        let emptyGroupItem = NSMenuItem(title: "New Empty Tab Group", action: #selector(handleNewEmptyTabGroup), keyEquivalent: "")
        emptyGroupItem.target = self
        menu.addItem(emptyGroupItem)

        let withThisTabTitle = count == 1 ? "New Tab Group with This Tab" : "New Tab Group with \(count) Tabs"
        let withTabItem = NSMenuItem(title: withThisTabTitle, action: #selector(handleNewTabGroupWithCurrentTab), keyEquivalent: "")
        withTabItem.target = self
        menu.addItem(withTabItem)

        let anchor: NSView = sidebarCapsule.button(for: "tabGroups") ?? sidebarCapsule
        let pt = NSPoint(x: 0, y: anchor.bounds.height + 6)
        menu.popUp(positioning: nil, at: pt, in: anchor)
    }

    @objc private func handleTabGroupsShowCurrent() {
        if !isSidebarOpen {
            toggleSidebar()
        }
    }

    @objc private func handleNewEmptyTabGroup() {
        _ = (NSApp.delegate as? AppDelegate)?.openNewWindow(url: nil, isPrivate: isPrivate)
    }

    @objc private func handleNewTabGroupWithCurrentTab() {
        let url = activeTab?.currentURL
        _ = (NSApp.delegate as? AppDelegate)?.openNewWindow(url: url, isPrivate: isPrivate)
    }

    private func pruneExpiredInactiveTabs() {
        guard let maxAge = BrowserSettings.shared.autoCloseTabInterval, tabs.count > 1 else { return }
        let now = Date()
        let activeID = activeTab?.tabID
        let expiredIndices = tabs.enumerated().compactMap { idx, tab -> Int? in
            guard tab.tabID != activeID else { return nil }
            let lastSeen = tabLastActiveAt[tab.tabID] ?? now
            return now.timeIntervalSince(lastSeen) >= maxAge ? idx : nil
        }
        for idx in expiredIndices.reversed() where tabs.count > 1 {
            closeTab(at: idx)
        }
    }

    private func lockPrivateWindow() {
        isPrivateWindowLocked = true
        privateLockOverlay.resetScannerState()
        privateLockOverlay.isHidden = false
        privateLockOverlay.alphaValue = 1.0
    }

    private func unlockPrivateWindowImmediately() {
        privateLockOverlay.cancelPendingAuthentication()
        isPrivateWindowLocked = false
        privateLockOverlay.isHidden = true
    }

    private func authenticateAndUnlockPrivateWindow() {
        privateLockOverlay.beginBiometricUnlock(
            reason: "Unlock Private Browsing in Safarium",
            onUnlocked: { [weak self] in
                self?.unlockPrivateWindowImmediately()
            }
        )
    }

    func windowWillClose(_ notification: Notification) {
        // CADisplayLink retains its target: invalidate so a close during the sidebar slide cannot leak the controller.
        sidebarDisplayLink?.invalidate()
        sidebarDisplayLink = nil
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        persistCurrentSession()
        dismissAddressBarPopover(animated: false)
        extensionPopoverController.close()
        verticalTabRailView.dismissHoverPill()
        tabHoverPreviewController.dismiss(animated: false)
        tabOverviewView.releaseCachedCards()
        cachedStartPageSnapshot = nil
        cachedStartPageSnapshotSize = .zero
        let toClose = tabs
        tabs.removeAll()
        for tab in toClose {
            NavigationSnapshotStore.shared.removeTab(tab.tabID)
            PrivacyReportStore.shared.removeTabStats(forTabID: tab.tabID)
            tab.closeTab()
        }
        privacyPopover.close()
        privacySummaryWorkItem?.cancel()
        privacySummaryWorkItem = nil
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }

    // MARK: - BrowserTabEngineDelegate

    func tabEngine(_ tab: BrowserTabEngine, didUpdateNavigationEntryIDs currentID: Int, previousID: Int, nextID: Int, validEntryIDs: [Int]) {
        NavigationSnapshotStore.shared.prune(tabID: tab.tabID, keepingEntryIDs: Set(validEntryIDs))
        if tab === activeTab {
            NavigationSnapshotStore.shared.prewarm(tabID: tab.tabID, entryIDs: [previousID, nextID])
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateNavigationSnapshotData jpegData: Data, entryID: Int, logicalSize: CGSize, backingScale: CGFloat, backgroundColor: NSColor?) {
        NavigationSnapshotStore.shared.storeJPEG(
            jpegData,
            tabID: tab.tabID,
            entryID: entryID,
            logicalSize: logicalSize,
            backingScale: backingScale,
            backgroundColor: backgroundColor
        )
    }

    func tabEngine(_ tab: BrowserTabEngine, didBecomeVisuallyReadyForNavigation fromBFCache: Bool) {
        guard tab === activeTab else { return }
        if !deferredHiddenTabIDs.isEmpty { scheduleDeferredTabHides(fallbackDelay: 0.05) }
        swipeNavigationController.finishTransitionRevealIfNeeded(fromBFCache: fromBFCache)
        navigationTransitionCoordinator.completeTransitionIfNeeded(tabID: tab.tabID, fromBFCache: fromBFCache)
    }

    func tabEngine(_ tab: BrowserTabEngine, didChangeURL url: URL?) {
        if tab === activeTab, url != nil {
            extensionPopoverController.close()
        }
        if url?.scheme != "chrome-error" && url != tabLoadErrors[tab.tabID]?.failedURL {
            tabLoadErrors.removeValue(forKey: tab.tabID)
            reloadingErrorTabIDs.remove(tab.tabID)
        }

        if tab === activeTab && !tab.isNativeInternalPage {
            passwordsPasskeyManager?.handleTabURLChanged(url: url, tab: tab)
        }
        refreshToolbarUI()
        if let url, url.isWebURL, let rawHost = url.host, !rawHost.isEmpty {
            let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(rawHost)
            let protectionsEnabled = effectiveProtectionsEnabled(forHost: cleanHost)
            let inferredSecurity = resolvedSecurityState(for: tab, url: url, cleanHost: cleanHost)
            let existingSnap = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID)
            if existingSnap == nil || existingSnap?.host != cleanHost {
                PrivacyReportStore.shared.resetTabStats(
                    forTabID: tab.tabID,
                    host: cleanHost,
                    isPrivate: isPrivate,
                    securityState: inferredSecurity,
                    protectionsEnabled: protectionsEnabled,
                    preserveMatchingHostEvents: true
                )
            } else if let existingSnap {
                let nextSecurity: ConnectionSecurityState
                if tab.connectionSecurityState != .internalPage,
                   let rawSecHost = tab.connectionSecurityHost, !rawSecHost.isEmpty,
                   PrivacyDomainClassifier.sanitizeHostForStorage(rawSecHost) == cleanHost {
                    nextSecurity = tab.connectionSecurityState
                } else if existingSnap.securityState == .upgradedHTTPS || existingSnap.securityState == .certificateError {
                    nextSecurity = existingSnap.securityState
                } else {
                    nextSecurity = inferredSecurity
                }
                PrivacyReportStore.shared.updateConnectionSecurity(nextSecurity, host: cleanHost, forTabID: tab.tabID, isPrivate: isPrivate)
                PrivacyReportStore.shared.updateProtectionsEnabled(protectionsEnabled, forTabID: tab.tabID, isPrivate: isPrivate)
            }
            if !engine.isRealChromium {
                PrivacyReportStore.shared.recordPageVisit(host: cleanHost, tabID: tab.tabID, isPrivate: isPrivate)
            }
        } else {
            PrivacyReportStore.shared.resetTabStats(
                forTabID: tab.tabID,
                host: "",
                isPrivate: isPrivate,
                securityState: .internalPage,
                protectionsEnabled: BrowserSettings.shared.preventCrossSiteTracking
            )
        }
        if !isPrivate, let url, url.isWebURL,
           let host = url.host, !host.isEmpty {
            let domain = URLInputNormalizer.displayDomain(for: url)
            let rawTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle = (rawTitle.isEmpty || rawTitle.lowercased() == "about:blank") ? domain : rawTitle
            recentSites.removeAll { $0.domain == domain }
            recentSites.insert(.init(title: cleanTitle, domain: domain, url: url, favicon: tab.favicon), at: 0)
            if recentSites.count > 6 { recentSites = Array(recentSites.prefix(6)) }
            startPageView.recordRecentVisit(title: cleanTitle, url: url, favicon: tab.favicon)
            AssetLoader.shared.recordHistoryVisit(url: url, title: cleanTitle)
        }
        if tab === activeTab {
            refreshPrivacyShieldUI()
            updateStartPageVisibility()
            if tab.isNativeInternalPage {
                swipeNavigationController.finishTransitionRevealIfNeeded(fromBFCache: true)
                navigationTransitionCoordinator.completeTransitionIfNeeded(tabID: tab.tabID, fromBFCache: true)
            }
            elasticScrollEngine.setReloadableWebPage(!tab.isStartPage)
            syncElasticMetrics(for: tab)
            if !tab.isStartPage && !engine.isRealChromium {
                scheduleMockTabColorSample(delay: 0.15)
            }
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didChangeTitle title: String) {
        refreshToolbarUI()
        if !isPrivate, let url = tab.currentURL, url.isWebURL,
           !title.isEmpty, title.lowercased() != "about:blank" {
            let domain = URLInputNormalizer.displayDomain(for: url)
            if let idx = recentSites.firstIndex(where: { $0.domain == domain }) {
                let prev = recentSites[idx]
                recentSites[idx] = .init(title: title, domain: domain, url: prev.url, favicon: tab.favicon ?? prev.favicon)
            }
            startPageView.recordRecentVisit(title: title, url: url, favicon: tab.favicon)
            AssetLoader.shared.updateHistoryTitle(url: url, title: title)
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if !isLoading && tab === activeTab && separateTabStripHeightConstraint?.constant ?? 0 > 0 {
            syncPageTopInset(for: tab)
        }
        refreshToolbarUI()
        if tab === activeTab {
            elasticScrollEngine.notifyPageLoadingStateChanged(isLoading: isLoading)
            syncElasticMetrics(for: tab)
        }
        if !isLoading && reloadingErrorTabIDs.remove(tab.tabID) != nil {
            tabLoadErrors.removeValue(forKey: tab.tabID)
            if tab === activeTab {
                updateStartPageVisibility()
            }
        }
        if tab === activeTab && !isLoading {
            swipeNavigationController.finishTransitionRevealIfNeeded()
            navigationTransitionCoordinator.completeTransitionIfNeeded(tabID: tab.tabID, fromBFCache: false)
            if !tab.isStartPage && tabLoadErrors[tab.tabID] == nil {
                if let url = tab.currentURL, url.isWebURL {
                    let desiredZoom = BrowserSettings.shared.pageZoomFactor(for: url)
                    if abs(tab.pageZoomFactor - desiredZoom) > 0.01 {
                        tab.setPageZoomFactor(desiredZoom)
                    }
                    syncPageTopInset(for: tab, zoomOverride: desiredZoom)
                }
                // On real Chromium, BrowserCore's rewritten zero-jank SXTopEdgeColorSampler pushes `didSampleTopEdgeColor:`
                // automatically with zero Swift-side polling/timers. Only MockBrowserEngine needs a manual sample tick.
                if !engine.isRealChromium {
                    scheduleMockTabColorSample(delay: 0.10)
                }
            }
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didFailLoad error: BrowserPageLoadError) {
        reloadingErrorTabIDs.remove(tab.tabID)
        tabLoadErrors[tab.tabID] = error
        if tab === activeTab {
            deferredRevealWebToolbarSyncTabID = nil
            navigationTransitionCoordinator.cancelImmediately()
            updateStartPageVisibility()
            swipeNavigationController.finishTransitionRevealIfNeeded()
            refreshToolbarUI()
        }
    }

    func tabEngineDidRequestNavigateBack(_ tab: BrowserTabEngine) {
        guard tab === activeTab else { return }
        navigateBackInActiveTab()
    }

    func tabEngineDidRequestNavigateForward(_ tab: BrowserTabEngine) {
        guard tab === activeTab else { return }
        navigateForwardInActiveTab()
    }

    func tabEngine(_ tab: BrowserTabEngine, didRecordPrivacyEvent event: PrivacyEvent) {
        let effectiveEvent: PrivacyEvent
        if isPrivate && !event.isPrivate {
            effectiveEvent = PrivacyEvent(
                id: event.id,
                eventType: event.eventType,
                pageHost: event.pageHost,
                trackerHost: event.trackerHost,
                entityDomain: event.entityDomain,
                ownerName: event.ownerName,
                category: event.category,
                detail: event.detail,
                count: event.count,
                isPrivate: true,
                timestamp: event.timestamp
            )
        } else {
            effectiveEvent = event
        }
        PrivacyReportStore.shared.record(effectiveEvent, forTabID: tab.tabID)
        if tab === activeTab {
            refreshPrivacyShieldUI()
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateConnectionSecurity state: ConnectionSecurityState, host: String) {
        let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(host)
        let prot = effectiveProtectionsEnabled(forHost: cleanHost)
        if let existing = PrivacyReportStore.shared.tabSnapshot(forTabID: tab.tabID) {
            PrivacyReportStore.shared.updateConnectionSecurity(state, host: cleanHost, forTabID: tab.tabID, isPrivate: isPrivate)
            if existing.host != cleanHost {
                PrivacyReportStore.shared.updateProtectionsEnabled(prot, forTabID: tab.tabID, isPrivate: isPrivate)
            }
        } else {
            PrivacyReportStore.shared.resetTabStats(
                forTabID: tab.tabID,
                host: cleanHost,
                isPrivate: isPrivate,
                securityState: state,
                protectionsEnabled: prot
            )
        }
        if tab === activeTab {
            refreshPrivacyShieldUI()
        }
    }

    private func scheduleMockTabColorSample(delay: TimeInterval) {
        guard !engine.isRealChromium else { return }
        pendingMockColorSampleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            tab.sampleTopEdgeColor(stripHeight: SafariMetrics.topEdgeStripHeight) { [weak self] sample in
                if let sample {
                    self?.chromeController.apply(sample: sample, animated: true)
                }
            }
        }
        pendingMockColorSampleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func syncElasticMetrics(for tab: BrowserTabEngine) {
        let vh = tab.viewportHeight > 1.0 ? tab.viewportHeight : webContentHost.bounds.height
        elasticScrollEngine.updateMetrics(
            scrollY: tab.scrollY,
            contentHeight: tab.contentHeight,
            viewportHeight: vh,
            canInnerScrollUp: tab.canInnerScrollUp,
            canInnerScrollDown: tab.canInnerScrollDown,
            isReloadableWebPage: !tab.isStartPage,
            isPageLoading: tab.isLoading
        )
    }

    /// How far page content has moved under the toolbar: the page's scroll offset plus any rubber-band shift
    /// that pushes the web view up (bottom overscroll, or a page shorter than the window). Without the
    /// rubber-band part, a bouncing page slid under the toolbar while the edge still thought it was at the top.
    /// Height of everything above the page (toolbar + separate tab strip). The web view runs behind it and the
    /// page gets this as its top inset (`__sxSetTopInset`, BrowserCore `installUnderToolbarInset`).
    private var toolbarStackHeight: CGFloat {
        SafariMetrics.toolbarHeight + (separateTabStripHeightConstraint?.constant ?? 0)
    }

    private func syncPageTopInset(for tab: BrowserTabEngine, zoomOverride: Double? = nil) {
        // The inset is in CSS px of the page, so page zoom must not scale it.
        let zoom = max(0.25, zoomOverride ?? tab.pageZoomFactor)
        tab.setPageTopInset((toolbarStackHeight / CGFloat(zoom)).rounded())
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateScrollY scrollY: CGFloat, contentHeight: CGFloat) {
        if tab === activeTab {
            syncElasticMetrics(for: tab)
        }
        // Real Chromium's SXTopEdgeColorSampler handles scroll-settle sampling cleanly off the main thread
        // with zero work during active scrolling. Only MockBrowserEngine triggers a sample here.
        guard tab === activeTab, !engine.isRealChromium else { return }
        scheduleMockTabColorSample(delay: 0.18)
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateProgress progress: Double) {
        guard tab === activeTab else { return }
        if passwordsPasskeyManager?.activeOriginatingTabPresentation != nil {
            return
        }
        tabAddressBar.updateActiveProgress(
            progress,
            isLoading: tab.isLoading,
            url: tab.currentURL,
            tabID: tab.tabID
        )
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateFavicon favicon: NSImage?) {
        if !isPrivate, let favicon, let url = tab.currentURL {
            FaviconCache.shared.store(favicon, forURL: url)
        }
        if tab === activeTab && !tab.isNativeInternalPage {
            passwordsPasskeyManager?.handleTabFaviconUpdated(favicon, tab: tab)
        }
        refreshToolbarUI()
    }

    func tabEngine(_ tab: BrowserTabEngine, didSampleTopEdgeColor sample: TopEdgeColorSample) {
        guard tab === activeTab else { return }
        if deferredRevealWebToolbarSyncTabID == tab.tabID {
            deferredRevealWebToolbarSyncTabID = nil
        }
        if navigationTransitionCoordinator.activeKind == .coldTabSwitch,
           navigationTransitionCoordinator.activeTabID == tab.tabID {
            navigationTransitionCoordinator.completeTransitionIfNeeded(tabID: tab.tabID, fromBFCache: true)
        }
        if passwordsPasskeyManager?.activeOriginatingTabPresentation != nil {
            return
        }
        // The sampler reads the strip right under the toolbar. With a fixed bar docked there that strip *is* the bar as
        // rendered (translucent bars like apple.com's nav show the page through them), which matches it far better
        // than the bar's CSS colour.
        if let fixed = tab.fixedHeaderColor, BrowserSettings.shared.showWebsiteColorInToolbar {
            let effectiveFixed = (fixed.alphaComponent >= 0.98) ? fixed : sample.color.withAlphaComponent(fixed.alphaComponent)
            chromeController.apply(sample: TopEdgeColorSample(color: effectiveFixed), animated: true)
            toolbarFrostView.apply(
                prefersLightInk: chromeController.currentTheme.prefersLightInk,
                sampledColor: effectiveFixed,
                customVeilColor: nil,
                fixedHeaderColor: effectiveFixed,
                animated: true
            )
            return
        }
        chromeController.apply(sample: sample, animated: true)
        toolbarFrostView.apply(
            prefersLightInk: chromeController.currentTheme.prefersLightInk,
            sampledColor: chromeController.currentTheme.sampledColor,
            customVeilColor: nil,
            fixedHeaderColor: nil,
            animated: true
        )
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateFixedHeaderColor color: NSColor?) {
        guard tab === activeTab, !tab.isNativeInternalPage else { return }
        if deferredRevealWebToolbarSyncTabID == tab.tabID {
            deferredRevealWebToolbarSyncTabID = nil
        }
        if passwordsPasskeyManager?.activeOriginatingTabPresentation != nil {
            return
        }
        if let color, BrowserSettings.shared.showWebsiteColorInToolbar {
            let sample = TopEdgeColorSample(color: color)
            chromeController.apply(sample: sample, animated: true)
            toolbarFrostView.apply(
                prefersLightInk: chromeController.currentTheme.prefersLightInk,
                sampledColor: color,
                customVeilColor: nil,
                fixedHeaderColor: color,
                animated: true
            )
        } else {
            if let cachedSample = tab.lastTopEdgeColorSample {
                chromeController.apply(sample: cachedSample, animated: true)
            }
            toolbarFrostView.apply(
                prefersLightInk: chromeController.currentTheme.prefersLightInk,
                sampledColor: chromeController.currentTheme.sampledColor,
                customVeilColor: nil,
                fixedHeaderColor: nil,
                animated: true
            )
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateNativeVideo id: String, srcURL: String, rect: NSRect, visible: Bool, autoplay: Bool) {
        // Video player controls are now embedded directly in the DOM at static position.
    }

    func tabEngine(_ tab: BrowserTabEngine, didReceiveAuthEventJSON jsonString: String) {
        guard tab === activeTab, !tab.isNativeInternalPage else { return }
        passwordsPasskeyManager?.handleAuthEventJSON(jsonString, tab: tab)
    }

    func tabEngine(_ tab: BrowserTabEngine, didOpenAuthPopupWithURL url: URL) {
        guard tab === activeTab, !tab.isNativeInternalPage else { return }
        passwordsPasskeyManager?.handleAuthPopupOpened(url: url, tab: tab)
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateAuthPopupURL url: URL) {
        guard tab === activeTab, !tab.isNativeInternalPage else { return }
        passwordsPasskeyManager?.handleAuthPopupURLChanged(url: url, tab: tab)
    }

    func tabEngineDidCloseAuthPopup(_ tab: BrowserTabEngine) {
        guard tab === activeTab else { return }
        passwordsPasskeyManager?.handleAuthPopupClosed(tab: tab)
    }

    func tabEngine(_ tab: BrowserTabEngine, didRequestNewTabWithURL url: URL) {
        extensionPopoverController.close()
        let activate = BrowserSettings.shared.activateNewTabsOnOpen
        if BrowserSettings.shared.openPagesInTabsMode == 2 {
            (NSApp.delegate as? AppDelegate)?.openNewWindow(url: url, isPrivate: isPrivate)
        } else {
            createNewTab(url: url, activate: activate)
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didStartDownload item: BrowserDownloadItem) {
        downloadController.handleDownloadStarted(item, fromOriginInWindow: lastMouseDownInWindow)
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateDownload item: BrowserDownloadItem) {
        downloadController.handleDownloadUpdated(item)
        if item.isComplete,
           !item.isCanceled,
           BrowserSettings.shared.openSafeFilesAfterDownloading,
           let path = item.fullPath, !path.isEmpty,
           BrowserSettings.shared.isSafeDownloadFile(atPath: path),
           autoOpenedDownloadIDs.insert(item.id).inserted {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func tabEngine(_ tab: BrowserTabEngine, didUpdateOverscrollY overscrollY: CGFloat, armed: Bool) {
        // No-op: handled natively at 120Hz by ElasticScrollEngine.
    }

    func tabEngineDidTriggerPullToRefresh(_ tab: BrowserTabEngine) {
        // No-op: handled natively at 120Hz by ElasticScrollEngine.
    }
}

// MARK: - Native macOS 27 Tahoe Separate Tab Bar (1:1 Liquid Glass Capsule Track)

private final class SeparateTabStripView: NSView {
    static let barHeight: CGFloat = 34.0
    private static let trackHeight: CGFloat = 28.0
    private static let trackHorizontalInset: CGFloat = 10.0

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onReorderTabs: (([String]) -> Void)?
    var canTearOffSingleTab: (() -> Bool)?
    var onBeginTabTearOff: ((String, NSRect, NSPoint, NSPoint) -> Void)?
    var onTabHoverChanged: ((String, NSView, Bool) -> Void)?
    var onDropURL: ((URL, String?, Bool) -> Void)?

    var isTabDragActive: Bool { draggingTabID != nil || SafariTabDragCoordinator.shared.isDragging }

    private let trackView = NSView()
    private var trackGlassView: NSView?
    private let activePillSurface = NSView()
    private let activePillGlassHost = NSView()
    private var activePillGlassView: NSView?
    private let hdrHighlightView = HDRPillHighlightView()
    private var lastTrackBgColor: CGColor?

    private var slotViews: [SeparateTabSlotView] = []
    private var dividerLayers: [CALayer] = []
    private var items: [TabPresentationItem] = []
    private var lastSlotCount: Int = 0
    private var theme: AdaptiveChromeTheme = .defaultLight
    private var hoveredTabID: String?

    private var draggingTabID: String?
    private var hiddenDraggedTabID: String?
    private var externalDropPlaceholder: (tabID: String, index: Int)?
    private var lastExternalPlaceholderRectInTrack: NSRect = .zero

    private var displayedItems: [TabPresentationItem] {
        guard let hiddenID = hiddenDraggedTabID else { return items }
        return items.filter { $0.id != hiddenID }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        trackView.wantsLayer = true
        trackView.layer?.cornerRadius = Self.trackHeight * 0.5
        trackView.layer?.cornerCurve = .continuous
        trackView.layer?.masksToBounds = false
        if #available(macOS 26.0, *) {
            let tgv = NSGlassEffectView()
            tgv.style = .regular
            tgv.cornerRadius = Self.trackHeight * 0.5
            tgv.translatesAutoresizingMaskIntoConstraints = false
            tgv.isHidden = !BrowserSettings.shared.refractiveGlassToolbar
            trackView.addSubview(tgv)
            NSLayoutConstraint.activate([
                tgv.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
                tgv.trailingAnchor.constraint(equalTo: trackView.trailingAnchor),
                tgv.topAnchor.constraint(equalTo: trackView.topAnchor),
                tgv.bottomAnchor.constraint(equalTo: trackView.bottomAnchor)
            ])
            self.trackGlassView = tgv
        }
        addSubview(trackView)

        let pillRadius = Self.trackHeight * 0.5
        activePillSurface.wantsLayer = true
        activePillSurface.layer?.cornerRadius = pillRadius
        activePillSurface.layer?.cornerCurve = .continuous
        activePillSurface.layer?.masksToBounds = false
        activePillSurface.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 26.0, *) {
            activePillSurface.layer?.preferredDynamicRange = .constrainedHigh
        }

        activePillGlassHost.translatesAutoresizingMaskIntoConstraints = false
        activePillGlassHost.wantsLayer = true
        activePillGlassHost.layer?.masksToBounds = false
        activePillSurface.addSubview(activePillGlassHost)
        NSLayoutConstraint.activate([
            activePillGlassHost.leadingAnchor.constraint(equalTo: activePillSurface.leadingAnchor),
            activePillGlassHost.trailingAnchor.constraint(equalTo: activePillSurface.trailingAnchor),
            activePillGlassHost.topAnchor.constraint(equalTo: activePillSurface.topAnchor),
            activePillGlassHost.bottomAnchor.constraint(equalTo: activePillSurface.bottomAnchor)
        ])

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .regular
            gv.cornerRadius = pillRadius
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

        hdrHighlightView.translatesAutoresizingMaskIntoConstraints = false
        hdrHighlightView.cornerRadius = pillRadius
        activePillSurface.addSubview(hdrHighlightView)
        NSLayoutConstraint.activate([
            hdrHighlightView.leadingAnchor.constraint(equalTo: activePillSurface.leadingAnchor),
            hdrHighlightView.trailingAnchor.constraint(equalTo: activePillSurface.trailingAnchor),
            hdrHighlightView.topAnchor.constraint(equalTo: activePillSurface.topAnchor),
            hdrHighlightView.bottomAnchor.constraint(equalTo: activePillSurface.bottomAnchor)
        ])

        trackView.addSubview(activePillSurface)
        applyAppearance(animated: false)
        registerForDraggedTypes([.URL, .fileURL, .string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return SafariWindow.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return SafariWindow.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = SafariWindow.extractDroppedURL(from: sender.draggingPasteboard) else { return false }
        let ptInTrack = trackView.convert(sender.draggingLocation, from: nil)
        let cmdHeld = NSEvent.modifierFlags.contains(.command)
        let hitSlot = slotViews.first(where: { $0.frame.contains(ptInTrack) })
            ?? (trackView.bounds.contains(ptInTrack)
                ? slotViews.min(by: { abs($0.frame.midX - ptInTrack.x) < abs($1.frame.midX - ptInTrack.x) })
                : nil)
        onDropURL?(url, hitSlot?.tabID, cmdHeld || hitSlot == nil)
        return true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func isPointInTabTrack(_ ptInWindow: NSPoint) -> Bool {
        guard !isHidden else { return false }
        let pt = trackView.convert(ptInWindow, from: nil)
        return trackView.bounds.insetBy(dx: -4, dy: -4).contains(pt)
    }

    func tabID(atWindowPoint ptInWindow: NSPoint) -> String? {
        guard !isHidden else { return nil }
        let pt = trackView.convert(ptInWindow, from: nil)
        return slotViews.first(where: { $0.frame.contains(pt) })?.tabID
    }

    func update(items newItems: [TabPresentationItem], animated: Bool = true) {
        guard draggingTabID == nil else { return }
        self.items = newItems
        rebuildSlots(animated: animated)
    }

    func apply(theme: AdaptiveChromeTheme) {
        self.theme = theme
        applyAppearance(animated: true)
        for slot in slotViews {
            slot.apply(isDark: theme.prefersLightInk)
        }
    }

    override func layout() {
        super.layout()
        guard draggingTabID == nil else { return }
        layoutTrackAndSlots(animated: false)
    }

    func setTearOffHiddenTab(id: String?, animated: Bool = true) {
        guard hiddenDraggedTabID != id else { return }
        hiddenDraggedTabID = id
        rebuildSlots(animated: animated)
    }

    func updateExternalDropPlaceholder(tabID: String, insertionIndex: Int) {
        let clamped = max(0, min(displayedItems.count, insertionIndex))
        if let existing = externalDropPlaceholder, existing.tabID == tabID && existing.index == clamped {
            return
        }
        externalDropPlaceholder = (tabID, clamped)
        layoutTrackAndSlots(animated: true)
    }

    func clearExternalTabDropPlaceholder(animated: Bool = true) {
        guard externalDropPlaceholder != nil else { return }
        externalDropPlaceholder = nil
        lastExternalPlaceholderRectInTrack = .zero
        layoutTrackAndSlots(animated: animated)
    }

    func resolvedDropSlotRectInScreen() -> NSRect? {
        guard let win = window, lastExternalPlaceholderRectInTrack.width > 10 else { return nil }
        let rectInWin = trackView.convert(lastExternalPlaceholderRectInTrack, to: nil)
        return win.convertToScreen(rectInWin)
    }

    func screenRectForTab(id: String) -> NSRect? {
        guard let win = window else { return nil }
        if let slot = slotViews.first(where: { $0.tabID == id }) {
            let rectInWin = slot.convert(slot.bounds, to: nil)
            return win.convertToScreen(rectInWin)
        }
        if let dropRect = resolvedDropSlotRectInScreen() {
            return dropRect
        }
        return nil
    }

    func dropHitTest(
        atScreenPoint screenPt: NSPoint,
        extraVerticalHysteresis: CGFloat = 0.0
    ) -> (insertionIndex: Int, slotRectInScreen: NSRect)? {
        guard !isHidden, let win = window else { return nil }
        let ptInWin = win.convertPoint(fromScreen: screenPt)
        let ptInSelf = convert(ptInWin, from: nil)
        let hitRect = NSRect(
            x: bounds.minX - 24.0,
            y: bounds.minY - (28.0 + extraVerticalHysteresis),
            width: bounds.width + 48.0,
            height: bounds.height + 52.0 + extraVerticalHysteresis * 2.0
        )
        guard hitRect.contains(ptInSelf) else { return nil }

        let visible = displayedItems
        let totalSlots = visible.count + 1
        let trackW = max(40.0, bounds.width - Self.trackHorizontalInset * 2.0)
        let slotW = trackW / CGFloat(max(1, totalSlots))
        let relX = ptInSelf.x - Self.trackHorizontalInset
        let rawIdx = Int(floor(relX / max(1.0, slotW)))
        let insertionIndex = max(0, min(visible.count, rawIdx))

        if let currentPH = externalDropPlaceholder, currentPH.index == insertionIndex, lastExternalPlaceholderRectInTrack.width > 10 {
            let rectInWin = trackView.convert(lastExternalPlaceholderRectInTrack, to: nil)
            return (insertionIndex, win.convertToScreen(rectInWin))
        }
        let trackY = floor((bounds.height - Self.trackHeight) * 0.5)
        let rectInSelf = NSRect(
            x: Self.trackHorizontalInset + CGFloat(insertionIndex) * slotW,
            y: trackY,
            width: max(40.0, slotW),
            height: Self.trackHeight
        )
        let rectInWin = convert(rectInSelf, to: nil)
        return (insertionIndex, win.convertToScreen(rectInWin))
    }

    private func handleSlotMouseDown(slot: SeparateTabSlotView, tabID: String, event: NSEvent) {
        guard let win = window else {
            onSelectTab?(tabID)
            return
        }
        let start = event.locationInWindow
        win.isMovable = false
        while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                let pt = slot.convert(next.locationInWindow, from: nil)
                if slot.bounds.contains(pt) {
                    onSelectTab?(tabID)
                }
                return
            }
            let dx = next.locationInWindow.x - start.x
            let dy = next.locationInWindow.y - start.y
            if hypot(dx, dy) > 5.0 {
                onTabHoverChanged?(tabID, slot, false)
                if items.count >= 2 {
                    runSeparateTabDragLoop(tabID: tabID, initialEvent: event, triggerEvent: next, draggedSlot: slot)
                    return
                }
                if items.count == 1 && canTearOffSingleTab?() == true {
                    triggerSeparateTearOff(tabID: tabID, draggedSlot: slot)
                    return
                }
                while let drain = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    if drain.type == .leftMouseUp { break }
                }
                return
            }
        }
    }

    private func runSeparateTabDragLoop(
        tabID: String,
        initialEvent: NSEvent,
        triggerEvent: NSEvent,
        draggedSlot: SeparateTabSlotView
    ) {
        guard let win = window, items.count >= 2 else { return }
        win.isMovable = false
        draggingTabID = tabID
        let isActive = items.first(where: { $0.id == tabID })?.isActive ?? false
        let startX = initialEvent.locationInWindow.x
        let startOriginX = draggedSlot.frame.origin.x
        let initialOrder = items.map(\.id)

        draggedSlot.layer?.zPosition = 25
        if isActive {
            activePillSurface.layer?.zPosition = 20
        } else {
            draggedSlot.isDraggingElevated = true
            trackView.addSubview(draggedSlot, positioned: .above, relativeTo: activePillSurface)
        }

        let minXBound: CGFloat = 0.0
        let maxXBound: CGFloat = max(0.0, trackView.bounds.width - draggedSlot.frame.width)
        let tearOffVertPad: CGFloat = 18.0
        let tearOffHorizPad: CGFloat = 28.0
        var toreOff = false

        func processDragEvent(_ ev: NSEvent) -> Bool {
            let ptInTrack = trackView.convert(ev.locationInWindow, from: nil)
            let outsideVert = (ptInTrack.y < -tearOffVertPad || ptInTrack.y > Self.trackHeight + tearOffVertPad)
            let outsideHoriz = (ptInTrack.x < -tearOffHorizPad || ptInTrack.x > trackView.bounds.width + tearOffHorizPad)
            if outsideVert || outsideHoriz {
                toreOff = true
                return false
            }
            let dx = ev.locationInWindow.x - startX
            let targetX = max(minXBound, min(maxXBound, startOriginX + dx))
            draggedSlot.layer?.removeAllAnimations()
            draggedSlot.frame.origin.x = targetX
            if isActive {
                activePillSurface.layer?.removeAllAnimations()
                activePillSurface.frame.origin.x = targetX
            }
            checkSeparateDragSwap(draggedId: tabID, draggedFrame: draggedSlot.frame)
            return true
        }

        if processDragEvent(triggerEvent) {
            while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                if !processDragEvent(next) { break }
            }
        }

        let finalOrder = items.map(\.id)
        let pillRect = win.convertToScreen(draggedSlot.convert(draggedSlot.bounds, to: nil))
        draggedSlot.isDraggingElevated = false
        draggedSlot.layer?.zPosition = 0
        activePillSurface.layer?.zPosition = 0
        draggingTabID = nil

        if toreOff {
            if finalOrder != initialOrder {
                onReorderTabs?(finalOrder)
            }
            triggerSeparateTearOff(tabID: tabID, explicitPillRectInScreen: pillRect)
            return
        }

        layoutTrackAndSlots(animated: true)
        if finalOrder != initialOrder {
            onReorderTabs?(finalOrder)
        }
    }

    private func checkSeparateDragSwap(draggedId: String, draggedFrame: NSRect) {
        guard let fromIdx = items.firstIndex(where: { $0.id == draggedId }) else { return }
        let draggedPinned = items[fromIdx].isPinned
        var targetIdx: Int? = nil
        if fromIdx > 0 {
            for idx in stride(from: fromIdx - 1, through: 0, by: -1) {
                let other = items[idx]
                guard other.isPinned == draggedPinned, idx < slotViews.count else { continue }
                if draggedFrame.minX < slotViews[idx].frame.midX - 2.0 {
                    targetIdx = idx
                } else {
                    break
                }
            }
        }
        if targetIdx == nil && fromIdx + 1 < items.count {
            for idx in (fromIdx + 1)..<items.count {
                let other = items[idx]
                guard other.isPinned == draggedPinned, idx < slotViews.count else { continue }
                if draggedFrame.maxX > slotViews[idx].frame.midX + 2.0 {
                    targetIdx = idx
                } else {
                    break
                }
            }
        }
        guard let newIdx = targetIdx, newIdx != fromIdx else { return }
        let moved = items.remove(at: fromIdx)
        items.insert(moved, at: newIdx)
        let movedSlot = slotViews.remove(at: fromIdx)
        slotViews.insert(movedSlot, at: newIdx)
        layoutTrackAndSlots(animated: true)
    }

    private func triggerSeparateTearOff(tabID: String, draggedSlot: SeparateTabSlotView? = nil, explicitPillRectInScreen: NSRect? = nil) {
        let pillRect: NSRect
        if let explicitPillRectInScreen {
            pillRect = explicitPillRectInScreen
        } else if let draggedSlot, let win = window {
            pillRect = win.convertToScreen(draggedSlot.convert(draggedSlot.bounds, to: nil))
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

    private func rebuildSlots(animated: Bool) {
        var existingByID: [String: SeparateTabSlotView] = [:]
        for v in slotViews { existingByID[v.tabID] = v }

        let visible = displayedItems
        let validIDs = Set(visible.map(\.id))
        for (id, view) in existingByID where !validIDs.contains(id) {
            view.removeFromSuperview()
        }

        var nextSlots: [SeparateTabSlotView] = []
        for item in visible {
            let slot: SeparateTabSlotView
            if let reused = existingByID[item.id] {
                slot = reused
            } else {
                slot = SeparateTabSlotView(tabID: item.id)
                slot.onSelect = { [weak self] id in self?.onSelectTab?(id) }
                slot.onClose = { [weak self] id in self?.onCloseTab?(id) }
                slot.onMouseDownTrack = { [weak self, weak slot] event in
                    guard let self, let slot else { return }
                    self.handleSlotMouseDown(slot: slot, tabID: slot.tabID, event: event)
                }
                slot.onHoverChanged = { [weak self, weak slot] id, hovered in
                    guard let self else { return }
                    self.hoveredTabID = hovered ? id : (self.hoveredTabID == id ? nil : self.hoveredTabID)
                    self.updateDividersVisibility()
                    if let slot {
                        self.onTabHoverChanged?(id, slot, hovered)
                    }
                }
                trackView.addSubview(slot, positioned: .above, relativeTo: activePillSurface)
            }
            slot.configure(item: item, isDark: theme.prefersLightInk)
            nextSlots.append(slot)
        }
        slotViews = nextSlots

        let neededDividers = max(0, visible.count - 1)
        while dividerLayers.count < neededDividers {
            let l = CALayer()
            trackView.layer?.insertSublayer(l, below: activePillSurface.layer)
            dividerLayers.append(l)
        }
        while dividerLayers.count > neededDividers {
            dividerLayers.removeLast().removeFromSuperlayer()
        }

        layoutTrackAndSlots(animated: animated)
        applyAppearance(animated: false)
    }

    private func layoutTrackAndSlots(animated: Bool) {
        let trackW = max(40.0, bounds.width - Self.trackHorizontalInset * 2.0)
        let trackY = floor((bounds.height - Self.trackHeight) * 0.5)
        trackView.frame = NSRect(x: Self.trackHorizontalInset, y: trackY, width: trackW, height: Self.trackHeight)

        lastExternalPlaceholderRectInTrack = .zero
        let visible = displayedItems
        let phIndex: Int? = externalDropPlaceholder.map { max(0, min(visible.count, $0.index)) }
        let totalSlots = visible.count + (phIndex != nil ? 1 : 0)
        guard totalSlots > 0 else {
            activePillSurface.isHidden = true
            return
        }

        let slotW = trackW / CGFloat(totalSlots)
        let activeVisualIdx = visible.firstIndex(where: \.isActive)
        let activeSlotPos: Int?
        if let aIdx = activeVisualIdx {
            if let ph = phIndex, ph <= aIdx {
                activeSlotPos = aIdx + 1
            } else {
                activeSlotPos = aIdx
            }
        } else {
            activeSlotPos = nil
        }

        let structureChanged = (lastSlotCount != 0 && lastSlotCount != totalSlots) || draggingTabID != nil || phIndex != nil
        lastSlotCount = totalSlots

        var animatedFrames: [(NSView, NSRect)] = []
        if let aPos = activeSlotPos {
            activePillSurface.isHidden = false
            let targetPillFrame = NSRect(x: CGFloat(aPos) * slotW, y: 0.0, width: slotW, height: Self.trackHeight)
            let activeID = visible[activeVisualIdx!].id
            if draggingTabID != activeID {
                if animated && structureChanged && activePillSurface.frame.width > 1 {
                    animatedFrames.append((activePillSurface, targetPillFrame))
                } else {
                    activePillSurface.frame = targetPillFrame
                }
            }
        } else {
            activePillSurface.isHidden = true
        }

        if let ph = phIndex {
            lastExternalPlaceholderRectInTrack = NSRect(x: CGFloat(ph) * slotW, y: 0.0, width: slotW, height: Self.trackHeight)
        }

        for (idx, slot) in slotViews.enumerated() {
            let visualPos = (phIndex != nil && idx >= phIndex!) ? (idx + 1) : idx
            let targetFrame = NSRect(x: CGFloat(visualPos) * slotW, y: 0.0, width: slotW, height: Self.trackHeight)
            if draggingTabID != slot.tabID {
                if animated && structureChanged && slot.frame.width > 1 {
                    animatedFrames.append((slot, targetFrame))
                } else {
                    slot.frame = targetFrame
                }
            }
        }

        if !animatedFrames.isEmpty {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                for (v, f) in animatedFrames {
                    v.animator().frame = f
                }
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let divH: CGFloat = 14.0
        let divY = floor((Self.trackHeight - divH) * 0.5)
        for (i, div) in dividerLayers.enumerated() {
            let pos = (phIndex != nil && i >= phIndex!) ? (i + 1) : i
            let x = round(CGFloat(pos + 1) * slotW)
            div.frame = CGRect(x: x, y: divY, width: 1.0, height: divH)
        }
        CATransaction.commit()
        updateDividersVisibility()
    }

    private func updateDividersVisibility() {
        let visible = displayedItems
        let activeIdx = visible.firstIndex(where: \.isActive) ?? -1
        let hoverIdx = hoveredTabID.flatMap { hid in visible.firstIndex(where: { $0.id == hid }) } ?? -1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, div) in dividerLayers.enumerated() {
            let touchesActive = (i == activeIdx) || (i + 1 == activeIdx)
            let touchesHover = (i == hoverIdx) || (i + 1 == hoverIdx)
            div.isHidden = touchesActive || touchesHover
        }
        CATransaction.commit()
    }

    private func applyAppearance(animated: Bool) {
        let isDark = theme.prefersLightInk
        let useGlassTrack = BrowserSettings.shared.refractiveGlassToolbar
        if #available(macOS 26.0, *), let tgv = trackGlassView as? NSGlassEffectView {
            tgv.isHidden = !useGlassTrack
            if useGlassTrack {
                tgv.style = .regular
                tgv.appearance = theme.preferredAppearance
                tgv.tintColor = isDark
                    ? NSColor.black.withAlphaComponent(0.22)
                    : NSColor.black.withAlphaComponent(0.06)
            }
        }
        let targetTrackCg = useGlassTrack ? NSColor.clear.cgColor : theme.tabTrackBackgroundColor.cgColor
        if lastTrackBgColor != targetTrackCg {
            if animated, !useGlassTrack, let prev = lastTrackBgColor, let layer = trackView.layer {
                let anim = CABasicAnimation(keyPath: "backgroundColor")
                anim.fromValue = prev
                anim.toValue = targetTrackCg
                anim.duration = 0.22
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(anim, forKey: "sepTrackBgFade")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trackView.layer?.backgroundColor = targetTrackCg
            trackView.layer?.borderWidth = 0.0
            CATransaction.commit()
            lastTrackBgColor = targetTrackCg
        }

        let screen = window?.screen ?? NSScreen.main
        let exposure = SafariMetrics.activeTabLinearExposure(for: screen)
        let fill = theme.activeTabFillColor.usingColorSpace(.sRGB) ?? theme.activeTabFillColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if #available(macOS 26.0, *), let gv = activePillGlassView as? NSGlassEffectView {
            activePillSurface.layer?.preferredDynamicRange = isDark ? .standard : .constrainedHigh
            gv.appearance = theme.preferredAppearance
            gv.cornerRadius = Self.trackHeight * 0.5
            if isDark {
                gv.tintColor = NSColor(
                    srgbRed: fill.redComponent,
                    green: fill.greenComponent,
                    blue: fill.blueComponent,
                    alpha: 0.12
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
            activePillSurface.layer?.backgroundColor = NSColor.clear.cgColor
            activePillSurface.layer?.borderWidth = isDark ? 0.5 : 0.0
            activePillSurface.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        } else {
            activePillSurface.layer?.backgroundColor = fill.withAlphaComponent(0.92).cgColor
            activePillSurface.layer?.borderWidth = 0.5
            activePillSurface.layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.08)).cgColor
        }
        hdrHighlightView.isLightInkOnDark = isDark
        hdrHighlightView.accentTintColor = theme.sampledColor
        hdrHighlightView.updateHDRColors()

        let divColor = (isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.12)).cgColor
        for div in dividerLayers {
            div.backgroundColor = divColor
        }
        CATransaction.commit()
    }
}

private final class SeparateTabSlotView: NSView {
    let tabID: String
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMouseDownTrack: ((NSEvent) -> Void)?
    var onHoverChanged: ((String, Bool) -> Void)?
    var isDraggingElevated: Bool = false {
        didSet {
            guard oldValue != isDraggingElevated else { return }
            updateHoverVisuals(animated: false)
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let hoverFillView = NSView()
    private let centerStack = NSStackView()
    private let faviconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closePlateView = NSView()
    private let closeGlyphView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isCloseHovered = false
    private var isActive = false
    private var isDark = false
    private var hasCustomFavicon = false

    private var closeHitRect: NSRect {
        let s: CGFloat = 18.0
        return NSRect(x: 6.0, y: floor((bounds.height - s) * 0.5), width: s, height: s)
    }

    init(tabID: String) {
        self.tabID = tabID
        super.init(frame: .zero)
        wantsLayer = true

        hoverFillView.wantsLayer = true
        hoverFillView.layer?.cornerRadius = 14.0
        hoverFillView.layer?.cornerCurve = .continuous
        hoverFillView.alphaValue = 0.0
        addSubview(hoverFillView)

        closePlateView.wantsLayer = true
        closePlateView.layer?.cornerRadius = 9.0
        closePlateView.layer?.cornerCurve = .continuous
        closePlateView.alphaValue = 0.0
        addSubview(closePlateView)

        closeGlyphView.imageScaling = .scaleNone
        closeGlyphView.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
        closeGlyphView.alphaValue = 0.0
        addSubview(closeGlyphView)

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyDown
        NSLayoutConstraint.activate([
            faviconView.widthAnchor.constraint(equalToConstant: 14),
            faviconView.heightAnchor.constraint(equalToConstant: 14)
        ])

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        centerStack.orientation = .horizontal
        centerStack.alignment = .centerY
        centerStack.spacing = 6.0
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.addArrangedSubview(faviconView)
        centerStack.addArrangedSubview(titleLabel)
        addSubview(centerStack)

        NSLayoutConstraint.activate([
            centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        hoverFillView.frame = bounds
        hoverFillView.layer?.cornerRadius = bounds.height * 0.5
        let cr = closeHitRect
        closePlateView.frame = cr
        closeGlyphView.frame = cr
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        tracking = ta
    }

    func configure(item: TabPresentationItem, isDark: Bool) {
        self.isActive = item.isActive
        self.isDark = isDark
        let isStart = (item.url == nil || item.url?.scheme == "safarium")
        let text = isStart ? "Start Page" : (item.title.isEmpty ? URLInputNormalizer.displayDomain(for: item.url) : item.title)
        titleLabel.stringValue = text
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: item.isActive ? .medium : .regular)

        if let fav = item.favicon, !isStart {
            hasCustomFavicon = true
            faviconView.image = fav
            faviconView.contentTintColor = nil
        } else {
            hasCustomFavicon = false
            faviconView.image = NSImage(
                systemSymbolName: isStart ? "star" : "globe",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 12.0, weight: .regular))
        }
        apply(isDark: isDark)
    }

    func apply(isDark: Bool) {
        self.isDark = isDark
        let primary = isDark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.88)
        let secondary = isDark ? NSColor.white.withAlphaComponent(0.68) : NSColor.black.withAlphaComponent(0.60)
        titleLabel.textColor = isActive ? primary : secondary
        if !hasCustomFavicon {
            faviconView.contentTintColor = isActive ? primary.withAlphaComponent(0.75) : secondary.withAlphaComponent(0.75)
        }
        let hoverAlpha: CGFloat = isActive ? (isDark ? 0.04 : 0.025) : (isDark ? 0.08 : 0.048)
        hoverFillView.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(hoverAlpha)
            : NSColor.black.withAlphaComponent(hoverAlpha)).cgColor
        closePlateView.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.085)).cgColor
        updateHoverVisuals(animated: false)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateCloseHover(event)
        onHoverChanged?(tabID, true)
        updateHoverVisuals(animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        let prev = isCloseHovered
        updateCloseHover(event)
        if prev != isCloseHovered {
            updateHoverVisuals(animated: true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isCloseHovered = false
        onHoverChanged?(tabID, false)
        updateHoverVisuals(animated: true)
    }

    private func updateCloseHover(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        isCloseHovered = isHovered && closeHitRect.insetBy(dx: -2, dy: -2).contains(pt)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if isHovered && closeHitRect.insetBy(dx: -2, dy: -2).contains(pt) {
            onClose?(tabID)
            return
        }
        if let onMouseDownTrack {
            onMouseDownTrack(event)
        } else {
            onSelect?(tabID)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onClose?(tabID)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    private func updateHoverVisuals(animated: Bool) {
        let glyphColor: NSColor
        if isCloseHovered {
            glyphColor = isDark ? NSColor.white.withAlphaComponent(0.94) : NSColor.black.withAlphaComponent(0.84)
        } else {
            glyphColor = isDark ? NSColor.white.withAlphaComponent(0.56) : NSColor.black.withAlphaComponent(0.46)
        }
        closeGlyphView.contentTintColor = glyphColor

        if isDraggingElevated {
            hoverFillView.layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.white.withAlphaComponent(0.88)).cgColor
        } else {
            hoverFillView.layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.055)).cgColor
        }

        let applyState = {
            self.hoverFillView.alphaValue = (self.isHovered || self.isDraggingElevated) ? 1.0 : 0.0
            self.closeGlyphView.alphaValue = (self.isHovered && !self.isDraggingElevated) ? 1.0 : 0.0
            self.closePlateView.alphaValue = (self.isCloseHovered && !self.isDraggingElevated) ? 1.0 : 0.0
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                applyState()
            }
        } else {
            applyState()
        }
    }
}

// MARK: - Native macOS 27 Tahoe Vertical Tab Icon Rail + Interactive Floating Glass Hover Pill

private final class VerticalTabRailView: NSView {
    static let railWidth: CGFloat = 44.0

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onReorderTabs: (([String]) -> Void)?
    var canTearOffSingleTab: (() -> Bool)?
    var onBeginTabTearOff: ((String, NSRect, NSPoint, NSPoint) -> Void)?
    var onTabHoverChanged: ((String, NSView, Bool) -> Void)?
    var onDropURL: ((URL, String?, Bool) -> Void)?

    var isTabDragActive: Bool { draggingTabID != nil || SafariTabDragCoordinator.shared.isDragging }

    private let scrollView = NSScrollView()
    private let capsuleHostView = NSView()
    private var capsuleGlassView: NSView?
    private let stackView = NSStackView()
    private let trailingHairline = NSView()
    private var rowViews: [VerticalTabIconRowView] = []
    private var items: [TabPresentationItem] = []
    private var theme: AdaptiveChromeTheme = .defaultLight
    private var hoverPopoverPanel: NSPanel?
    private var hoveredTabID: String?
    private var activePillTabID: String?
    private var isPointerInPill: Bool = false
    private var dismissWorkItem: DispatchWorkItem?

    private var draggingTabID: String?
    private var hiddenDraggedTabID: String?
    private var externalDropPlaceholder: (tabID: String, index: Int)?
    private var placeholderSpacerView: NSView?

    private var displayedItems: [TabPresentationItem] {
        guard let hiddenID = hiddenDraggedTabID else { return items }
        return items.filter { $0.id != hiddenID }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return SafariWindow.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return SafariWindow.extractDroppedURL(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = SafariWindow.extractDroppedURL(from: sender.draggingPasteboard) else { return false }
        let cmdHeld = NSEvent.modifierFlags.contains(.command)
        let hitRow = rowViews.first(where: { row in
            let pt = row.convert(sender.draggingLocation, from: nil)
            return row.bounds.contains(pt)
        })
        onDropURL?(url, hitRow?.tabID, cmdHeld || hitRow == nil)
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.URL, .fileURL, .string])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder

        let clip = VerticalFlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip

        let doc = VerticalFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        // Floating 36pt-wide Liquid Glass pill capsule hugging the vertical tab icons (matches top toolbar capsules 1:1)
        capsuleHostView.translatesAutoresizingMaskIntoConstraints = false
        capsuleHostView.wantsLayer = true
        capsuleHostView.layer?.cornerRadius = 18.0
        capsuleHostView.layer?.cornerCurve = .continuous
        capsuleHostView.layer?.masksToBounds = false
        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .regular
            gv.cornerRadius = 18.0
            gv.translatesAutoresizingMaskIntoConstraints = false
            capsuleHostView.addSubview(gv)
            NSLayoutConstraint.activate([
                gv.leadingAnchor.constraint(equalTo: capsuleHostView.leadingAnchor),
                gv.trailingAnchor.constraint(equalTo: capsuleHostView.trailingAnchor),
                gv.topAnchor.constraint(equalTo: capsuleHostView.topAnchor),
                gv.bottomAnchor.constraint(equalTo: capsuleHostView.bottomAnchor)
            ])
            self.capsuleGlassView = gv
        }

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 4.0
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        capsuleHostView.addSubview(stackView)
        doc.addSubview(capsuleHostView)
        scrollView.documentView = doc
        addSubview(scrollView)

        trailingHairline.translatesAutoresizingMaskIntoConstraints = false
        trailingHairline.wantsLayer = true
        trailingHairline.isHidden = true
        addSubview(trailingHairline)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            {
                let c = scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
                c.priority = .init(999)  // the rail collapses to width 0; give way quietly instead of an unsatisfiable-constraint break
                return c
            }(),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: SafariMetrics.toolbarHeight),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),

            capsuleHostView.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            capsuleHostView.widthAnchor.constraint(equalToConstant: 36),
            capsuleHostView.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            capsuleHostView.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -10),

            stackView.leadingAnchor.constraint(equalTo: capsuleHostView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: capsuleHostView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: capsuleHostView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: capsuleHostView.bottomAnchor),

            trailingHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingHairline.topAnchor.constraint(equalTo: topAnchor),
            trailingHairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingHairline.widthAnchor.constraint(equalToConstant: 0.5)
        ])

        apply(theme: .defaultLight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        dismissHoverPill()
    }

    func isPointInTabTrack(_ ptInWindow: NSPoint) -> Bool {
        guard !isHidden else { return false }
        let pt = convert(ptInWindow, from: nil)
        return bounds.contains(pt)
    }

    func tabID(atWindowPoint ptInWindow: NSPoint) -> String? {
        guard !isHidden else { return nil }
        for row in rowViews {
            let pt = row.convert(ptInWindow, from: nil)
            if row.bounds.contains(pt) { return row.tabID }
        }
        return nil
    }

    func setTearOffHiddenTab(id: String?, animated: Bool = true) {
        guard hiddenDraggedTabID != id else { return }
        hiddenDraggedTabID = id
        rebuildRows()
    }

    func updateExternalDropPlaceholder(tabID: String, insertionIndex: Int) {
        let clamped = max(0, min(displayedItems.count, insertionIndex))
        if let existing = externalDropPlaceholder, existing.tabID == tabID && existing.index == clamped {
            return
        }
        externalDropPlaceholder = (tabID, clamped)
        rebuildRows()
    }

    func clearExternalTabDropPlaceholder(animated: Bool = true) {
        guard externalDropPlaceholder != nil else { return }
        externalDropPlaceholder = nil
        if let spacer = placeholderSpacerView {
            stackView.removeArrangedSubview(spacer)
            spacer.removeFromSuperview()
            placeholderSpacerView = nil
        }
        rebuildRows()
    }

    func resolvedDropSlotRectInScreen() -> NSRect? {
        guard let win = window, let spacer = placeholderSpacerView, spacer.superview != nil else { return nil }
        capsuleHostView.layoutSubtreeIfNeeded()
        let rectInWin = spacer.convert(spacer.bounds, to: nil)
        let r = win.convertToScreen(rectInWin)
        return r.width > 4 ? r : nil
    }

    func screenRectForTab(id: String) -> NSRect? {
        guard let win = window else { return nil }
        if let row = rowViews.first(where: { $0.tabID == id }) {
            let rectInWin = row.convert(row.bounds, to: nil)
            return win.convertToScreen(rectInWin)
        }
        if let dropRect = resolvedDropSlotRectInScreen() {
            return dropRect
        }
        return nil
    }

    func dropHitTest(
        atScreenPoint screenPt: NSPoint,
        extraVerticalHysteresis: CGFloat = 0.0
    ) -> (insertionIndex: Int, slotRectInScreen: NSRect)? {
        guard !isHidden, let win = window else { return nil }
        let ptInWin = win.convertPoint(fromScreen: screenPt)
        let ptInSelf = convert(ptInWin, from: nil)
        let hitRect = NSRect(
            x: bounds.minX - 24.0,
            y: bounds.minY - (24.0 + extraVerticalHysteresis),
            width: bounds.width + 52.0,
            height: bounds.height + 48.0 + extraVerticalHysteresis * 2.0
        )
        guard hitRect.contains(ptInSelf) else { return nil }

        let visible = displayedItems
        let ptInStack = stackView.convert(ptInWin, from: nil)
        // `stackView` is unflipped (`isFlipped == false`), so index 0 sits at the top (highest Y)
        // and higher indices sit progressively lower (smaller Y).
        var insertionIndex = visible.count
        for (idx, row) in rowViews.enumerated() {
            if ptInStack.y > row.frame.midY {
                insertionIndex = idx
                break
            }
        }
        insertionIndex = max(0, min(visible.count, insertionIndex))

        if let currentPH = externalDropPlaceholder, currentPH.index == insertionIndex, let resolved = resolvedDropSlotRectInScreen() {
            return (insertionIndex, resolved)
        }
        let slotYInStack: CGFloat
        if insertionIndex < rowViews.count {
            slotYInStack = rowViews[insertionIndex].frame.minY
        } else if let last = rowViews.last {
            slotYInStack = last.frame.minY - 36.0
        } else {
            slotYInStack = 4.0
        }
        let slotInStack = NSRect(x: 2.0, y: slotYInStack, width: 32.0, height: 32.0)
        let rectInWin = stackView.convert(slotInStack, to: nil)
        return (insertionIndex, win.convertToScreen(rectInWin))
    }

    private func handleRowMouseDown(row: VerticalTabIconRowView, tabID: String, event: NSEvent) {
        guard let win = window else {
            dismissHoverPill()
            onSelectTab?(tabID)
            return
        }
        let start = event.locationInWindow
        win.isMovable = false
        while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                let pt = row.convert(next.locationInWindow, from: nil)
                if row.bounds.contains(pt) {
                    dismissHoverPill()
                    onSelectTab?(tabID)
                }
                return
            }
            let dx = next.locationInWindow.x - start.x
            let dy = next.locationInWindow.y - start.y
            if hypot(dx, dy) > 5.0 {
                dismissHoverPill()
                if items.count >= 2 {
                    runVerticalDragLoop(tabID: tabID, initialEvent: event, triggerEvent: next, draggedRow: row)
                    return
                }
                if items.count == 1 && canTearOffSingleTab?() == true {
                    triggerVerticalTearOff(tabID: tabID, draggedRow: row)
                    return
                }
                while let drain = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    if drain.type == .leftMouseUp { break }
                }
                return
            }
        }
    }

    private func runVerticalDragLoop(
        tabID: String,
        initialEvent: NSEvent,
        triggerEvent: NSEvent,
        draggedRow: VerticalTabIconRowView
    ) {
        guard let win = window, items.count >= 2 else { return }
        win.isMovable = false
        draggingTabID = tabID
        let initialOrder = items.map(\.id)

        let startPtInStack = stackView.convert(initialEvent.locationInWindow, from: nil)
        let startOriginY = draggedRow.frame.origin.y
        let minYBound: CGFloat = 4.0
        let maxYBound: CGFloat = max(minYBound, stackView.bounds.height - draggedRow.frame.height - 4.0)

        draggedRow.isDraggingElevated = true
        draggedRow.layer?.zPosition = 25

        var toreOff = false

        func processDragEvent(_ ev: NSEvent) -> Bool {
            let ptInSelf = convert(ev.locationInWindow, from: nil)
            let outsideHoriz = (ptInSelf.x < -22.0 || ptInSelf.x > bounds.width + 26.0)
            let outsideVert = (ptInSelf.y < -28.0 || ptInSelf.y > bounds.height + 28.0)
            if outsideHoriz || outsideVert {
                toreOff = true
                return false
            }

            let ptInStack = stackView.convert(ev.locationInWindow, from: nil)
            let dy = ptInStack.y - startPtInStack.y
            let desiredOriginY = max(minYBound, min(maxYBound, startOriginY + dy))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            draggedRow.layer?.transform = CATransform3DMakeTranslation(0, desiredOriginY - draggedRow.frame.origin.y, 0)
            CATransaction.commit()

            let draggedFrame = NSRect(x: draggedRow.frame.minX, y: desiredOriginY, width: draggedRow.frame.width, height: draggedRow.frame.height)
            if checkVerticalDragSwap(draggedId: tabID, draggedRow: draggedRow, draggedFrame: draggedFrame) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                draggedRow.layer?.transform = CATransform3DMakeTranslation(0, desiredOriginY - draggedRow.frame.origin.y, 0)
                CATransaction.commit()
            }
            return true
        }

        if processDragEvent(triggerEvent) {
            while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                if !processDragEvent(next) { break }
            }
        }

        let finalOrder = items.map(\.id)
        draggedRow.isDraggingElevated = false
        draggedRow.layer?.zPosition = 0

        if toreOff {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            draggedRow.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
            draggingTabID = nil
            if finalOrder != initialOrder {
                onReorderTabs?(finalOrder)
            }
            triggerVerticalTearOff(tabID: tabID, draggedRow: draggedRow)
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        draggedRow.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        draggingTabID = nil
        if finalOrder != initialOrder {
            onReorderTabs?(finalOrder)
        }
    }

    private func checkVerticalDragSwap(draggedId: String, draggedRow: VerticalTabIconRowView, draggedFrame: NSRect) -> Bool {
        guard let fromIdx = items.firstIndex(where: { $0.id == draggedId }) else { return false }
        let draggedPinned = items[fromIdx].isPinned
        // `stackView` is unflipped (`isFlipped == false`), so index 0 is at the TOP (highest Y)
        // and index `count - 1` is at the BOTTOM (lowest Y).
        var targetIdx: Int? = nil
        if fromIdx > 0 {
            // Moving UP in the rail -> higher Y
            for idx in stride(from: fromIdx - 1, through: 0, by: -1) {
                let other = items[idx]
                guard other.isPinned == draggedPinned, idx < rowViews.count else { continue }
                if draggedFrame.maxY > rowViews[idx].frame.midY + 2.0 {
                    targetIdx = idx
                } else {
                    break
                }
            }
        }
        if targetIdx == nil && fromIdx + 1 < items.count {
            // Moving DOWN in the rail -> lower Y
            for idx in (fromIdx + 1)..<items.count {
                let other = items[idx]
                guard other.isPinned == draggedPinned, idx < rowViews.count else { continue }
                if draggedFrame.minY < rowViews[idx].frame.midY - 2.0 {
                    targetIdx = idx
                } else {
                    break
                }
            }
        }
        guard let newIdx = targetIdx, newIdx != fromIdx else { return false }

        var oldYByID: [String: CGFloat] = [:]
        for r in rowViews where r.tabID != draggedId {
            oldYByID[r.tabID] = r.frame.origin.y
        }

        let moved = items.remove(at: fromIdx)
        items.insert(moved, at: newIdx)
        let movedRow = rowViews.remove(at: fromIdx)
        rowViews.insert(movedRow, at: newIdx)
        stackView.removeArrangedSubview(movedRow)
        stackView.insertArrangedSubview(movedRow, at: newIdx)
        capsuleHostView.layoutSubtreeIfNeeded()

        for r in rowViews where r.tabID != draggedId {
            if let oldY = oldYByID[r.tabID] {
                let deltaY = oldY - r.frame.origin.y
                if abs(deltaY) > 0.5, let layer = r.layer {
                    let anim = CABasicAnimation(keyPath: "transform.translation.y")
                    anim.fromValue = deltaY
                    anim.toValue = 0.0
                    anim.duration = 0.16
                    anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    layer.add(anim, forKey: "verticalTabSlide")
                }
            }
        }
        return true
    }

    private func triggerVerticalTearOff(tabID: String, draggedRow: VerticalTabIconRowView) {
        let mouseScreen = NSEvent.mouseLocation
        let pillW: CGFloat = 170.0
        let pillH: CGFloat = SafariMetrics.tabInnerHeight
        let pillRect = NSRect(
            x: mouseScreen.x - pillW * 0.5,
            y: mouseScreen.y - pillH * 0.5,
            width: pillW,
            height: pillH
        )
        let cursorOffset = NSPoint(x: pillW * 0.5, y: pillH * 0.5)
        onBeginTabTearOff?(tabID, pillRect, cursorOffset, mouseScreen)
    }

    func update(items newItems: [TabPresentationItem]) {
        guard draggingTabID == nil else { return }
        self.items = newItems
        let validIDs = Set(newItems.map(\.id))
        if let hid = hoveredTabID, !validIDs.contains(hid) {
            dismissHoverPill()
        }
        rebuildRows()
    }

    private func rebuildRows() {
        let visible = displayedItems
        let validIDs = Set(visible.map(\.id))
        var existingByID: [String: VerticalTabIconRowView] = [:]
        for row in rowViews { existingByID[row.tabID] = row }

        let oldOrder = rowViews.map(\.tabID)
        let newOrder = visible.map(\.id)
        if oldOrder == newOrder && externalDropPlaceholder == nil && placeholderSpacerView == nil {
            for (idx, item) in visible.enumerated() {
                rowViews[idx].configure(item: item, isDark: theme.prefersLightInk)
            }
            return
        }

        for v in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(v)
            if let row = v as? VerticalTabIconRowView, !validIDs.contains(row.tabID) {
                row.removeFromSuperview()
            } else if v === placeholderSpacerView {
                v.removeFromSuperview()
            }
        }
        placeholderSpacerView = nil

        var nextRows: [VerticalTabIconRowView] = []
        for item in visible {
            let row: VerticalTabIconRowView
            if let reused = existingByID[item.id] {
                row = reused
                row.configure(item: item, isDark: theme.prefersLightInk)
            } else {
                row = VerticalTabIconRowView(item: item, isDark: theme.prefersLightInk)
                row.onSelect = { [weak self] id in
                    self?.dismissHoverPill()
                    self?.onSelectTab?(id)
                }
                row.onClose = { [weak self] id in
                    self?.dismissHoverPill()
                    self?.onCloseTab?(id)
                }
                row.onMouseDownTrack = { [weak self, weak row] event in
                    guard let self, let row else { return }
                    self.handleRowMouseDown(row: row, tabID: row.tabID, event: event)
                }
                row.onHover = { [weak self, weak row] hovered in
                    guard let self, let row else { return }
                    let currentItem = self.items.first(where: { $0.id == row.tabID }) ?? row.currentItem
                    if hovered {
                        self.hoveredTabID = currentItem.id
                        self.onTabHoverChanged?(currentItem.id, row, true)
                    } else if self.hoveredTabID == currentItem.id {
                        self.hoveredTabID = nil
                        self.onTabHoverChanged?(currentItem.id, row, false)
                    }
                }
            }
            stackView.addArrangedSubview(row)
            nextRows.append(row)
        }
        rowViews = nextRows

        if let ph = externalDropPlaceholder {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.wantsLayer = true
            spacer.layer?.cornerRadius = 15.0
            spacer.layer?.backgroundColor = (theme.prefersLightInk
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.06)).cgColor
            NSLayoutConstraint.activate([
                spacer.widthAnchor.constraint(equalToConstant: 32),
                spacer.heightAnchor.constraint(equalToConstant: 32)
            ])
            let idx = max(0, min(stackView.arrangedSubviews.count, ph.index))
            stackView.insertArrangedSubview(spacer, at: idx)
            placeholderSpacerView = spacer
        }
    }

    func apply(theme: AdaptiveChromeTheme) {
        self.theme = theme
        let isDark = theme.prefersLightInk
        // The unified L-shaped ToolbarGlassView renders the continuous glass/frosted surface behind both
        // the top toolbar and this vertical rail, so the rail itself stays transparent with no separate box.
        capsuleGlassView?.isHidden = true
        capsuleHostView.layer?.backgroundColor = NSColor.clear.cgColor
        layer?.backgroundColor = NSColor.clear.cgColor
        trailingHairline.isHidden = true
        for row in rowViews {
            row.apply(isDark: isDark)
        }
    }

    func dismissHoverPill() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        let prevID = hoveredTabID ?? activePillTabID
        isPointerInPill = false
        hoveredTabID = nil
        activePillTabID = nil
        if let prevID {
            onTabHoverChanged?(prevID, self, false)
        }
        guard let panel = hoverPopoverPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hoverPopoverPanel = nil
    }

    private func scheduleDismissIfPointerOutside() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hoveredTabID == nil && !self.isPointerInPill {
                self.dismissHoverPill()
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
    }

    private func presentHoverPill(for item: TabPresentationItem, anchoredTo row: NSView) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if let existing = hoverPopoverPanel {
            existing.parent?.removeChildWindow(existing)
            existing.orderOut(nil)
            hoverPopoverPanel = nil
        }
        guard let parentWin = window else { return }

        let canClose = items.count > 1
        let isStart = (item.url == nil || item.url?.scheme == "safarium")
        let titleText = isStart ? "Start Page" : (item.title.isEmpty ? URLInputNormalizer.displayDomain(for: item.url) : item.title)
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let textW = ceil((titleText as NSString).size(withAttributes: [.font: font]).width)
        let bridgeLead: CGFloat = 6.0
        let pillW = min(224.0, max(96.0, textW + (canClose ? 48.0 : 28.0)))
        let pillH: CGFloat = 28.0

        let rowRectInWin = row.convert(row.bounds, to: nil)
        let rowScreenRect = parentWin.convertToScreen(rowRectInWin)
        let railRightInWin = convert(NSPoint(x: bounds.maxX, y: 0), to: nil)
        let railRightScreenX = parentWin.convertToScreen(NSRect(origin: railRightInWin, size: .zero)).origin.x

        let panelRect = NSRect(
            x: railRightScreenX,
            y: round(rowScreenRect.midY - pillH * 0.5),
            width: bridgeLead + pillW,
            height: pillH
        )

        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.level = .floating
        panel.alphaValue = 0.0

        let host = VerticalHoverPillHostView(
            frame: NSRect(origin: .zero, size: panelRect.size),
            pillOriginX: bridgeLead,
            pillSize: NSSize(width: pillW, height: pillH),
            titleText: titleText,
            canClose: canClose,
            theme: theme
        )
        host.onHoverChanged = { [weak self] inside in
            guard let self else { return }
            self.isPointerInPill = inside
            if inside {
                self.dismissWorkItem?.cancel()
                self.dismissWorkItem = nil
            } else {
                self.scheduleDismissIfPointerOutside()
            }
        }
        host.onSelect = { [weak self] in
            self?.dismissHoverPill()
            self?.onSelectTab?(item.id)
        }
        host.onClose = { [weak self] in
            self?.dismissHoverPill()
            self?.onCloseTab?(item.id)
        }

        panel.contentView = host
        parentWin.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1.0
        }
        self.activePillTabID = item.id
        self.hoverPopoverPanel = panel
    }
}

private final class VerticalHoverPillHostView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let canClose: Bool
    private let isDark: Bool
    private let pillFrame: NSRect
    private let closeHitRect: NSRect
    private let closeButtonView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isCloseHovered = false

    init(
        frame frameRect: NSRect,
        pillOriginX: CGFloat,
        pillSize: NSSize,
        titleText: String,
        canClose: Bool,
        theme: AdaptiveChromeTheme
    ) {
        self.canClose = canClose
        self.isDark = theme.prefersLightInk
        self.pillFrame = NSRect(x: pillOriginX, y: 0, width: pillSize.width, height: pillSize.height)
        self.closeHitRect = NSRect(x: pillOriginX + 5, y: 4, width: 20, height: 20)
        super.init(frame: frameRect)
        wantsLayer = true

        let content = NSView(frame: NSRect(origin: .zero, size: pillSize))
        content.wantsLayer = true

        let lbl = NSTextField(labelWithString: titleText)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        lbl.textColor = isDark ? NSColor.white.withAlphaComponent(0.94) : NSColor.black.withAlphaComponent(0.86)
        lbl.lineBreakMode = .byTruncatingTail
        content.addSubview(lbl)

        if canClose {
            closeButtonView.translatesAutoresizingMaskIntoConstraints = false
            closeButtonView.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")?
                .withSymbolConfiguration(.init(pointSize: 13.5, weight: .regular))
            closeButtonView.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.56) : NSColor.black.withAlphaComponent(0.42)
            content.addSubview(closeButtonView)

            NSLayoutConstraint.activate([
                closeButtonView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                closeButtonView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                closeButtonView.widthAnchor.constraint(equalToConstant: 15),
                closeButtonView.heightAnchor.constraint(equalToConstant: 15),

                lbl.leadingAnchor.constraint(equalTo: closeButtonView.trailingAnchor, constant: 6),
                lbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                lbl.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                lbl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                lbl.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: pillFrame)
            glass.style = .regular
            glass.appearance = theme.preferredAppearance
            glass.cornerRadius = pillSize.height * 0.5
            glass.contentView = content
            addSubview(glass)
        } else {
            content.frame = pillFrame
            content.layer?.cornerRadius = pillSize.height * 0.5
            content.layer?.cornerCurve = .continuous
            content.layer?.backgroundColor = (isDark ? NSColor(white: 0.16, alpha: 0.94) : NSColor.white.withAlphaComponent(0.95)).cgColor
            addSubview(content)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        updateCloseHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCloseHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        isCloseHovered = false
        applyCloseTint()
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if canClose && closeHitRect.contains(pt) {
            onClose?()
        } else if pillFrame.contains(pt) {
            onSelect?()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            if canClose { onClose?() }
        } else {
            super.otherMouseDown(with: event)
        }
    }

    private func updateCloseHover(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let nowHovered = canClose && closeHitRect.contains(pt)
        if nowHovered != isCloseHovered {
            isCloseHovered = nowHovered
            applyCloseTint()
        }
    }

    private func applyCloseTint() {
        if isCloseHovered {
            closeButtonView.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.94) : NSColor(white: 0.12, alpha: 0.90)
        } else {
            closeButtonView.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.56) : NSColor.black.withAlphaComponent(0.42)
        }
    }
}

private final class VerticalTabIconRowView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onMouseDownTrack: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var isDraggingElevated: Bool = false {
        didSet {
            guard oldValue != isDraggingElevated else { return }
            apply(isDark: isDark)
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var tabID: String { item.id }
    var currentItem: TabPresentationItem { item }
    private var item: TabPresentationItem
    private let circleFill = NSView()
    private let iconView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isDark: Bool

    func configure(item: TabPresentationItem, isDark: Bool) {
        self.item = item
        apply(isDark: isDark)
    }

    init(item: TabPresentationItem, isDark: Bool) {
        self.item = item
        self.isDark = isDark
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        circleFill.translatesAutoresizingMaskIntoConstraints = false
        circleFill.wantsLayer = true
        circleFill.layer?.cornerRadius = 15.0
        addSubview(circleFill)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),

            circleFill.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleFill.centerYAnchor.constraint(equalTo: centerYAnchor),
            circleFill.widthAnchor.constraint(equalToConstant: 30),
            circleFill.heightAnchor.constraint(equalToConstant: 30),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16)
        ])

        apply(isDark: isDark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
        tracking = ta
    }

    func apply(isDark: Bool) {
        self.isDark = isDark
        let isStart = (item.url == nil || item.url?.scheme == "safarium")
        if let fav = item.favicon, !isStart {
            iconView.image = fav
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(
                systemSymbolName: isStart ? "star" : "globe",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 14.0, weight: .regular))
            iconView.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.75) : NSColor.black.withAlphaComponent(0.62)
        }

        if isDraggingElevated {
            circleFill.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.24) : NSColor.black.withAlphaComponent(0.14)).cgColor
        } else if item.isActive {
            circleFill.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.075)).cgColor
        } else if isHovered {
            circleFill.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.045)).cgColor
        } else {
            circleFill.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        apply(isDark: isDark)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        apply(isDark: isDark)
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if let onMouseDownTrack {
            onMouseDownTrack(event)
        } else {
            onSelect?(item.id)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onClose?(item.id)
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

private final class VerticalFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class VerticalFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Private Browsing Native Safari Biometric Touch ID Lock Overlay

final class PrivateWindowLockOverlayView: NSView {
    var onUnlockRequested: (() -> Void)?
    var authenticatorFactory: () -> BiometricAuthEvaluating = {
        SystemBiometricAuthenticator()
    }

    let scannerView = SafariBiometricScannerView()
    private var activeAuthenticator: BiometricAuthEvaluating?
    private var evaluationInFlight = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let vev = NSVisualEffectView()
        vev.translatesAutoresizingMaskIntoConstraints = false
        vev.material = .hudWindow
        vev.blendingMode = .withinWindow
        vev.state = .active
        addSubview(vev)

        let lockIcon = NSImageView()
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        lockIcon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Private Browsing Is Locked")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "Use Touch ID or enter your password to view your Private Browsing tabs.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        scannerView.defaultPromptText = "Unlock with Touch ID"
        scannerView.onActivateScanner = { [weak self] in
            self?.onUnlockRequested?()
        }

        let stack = NSStackView(views: [lockIcon, title, subtitle, scannerView])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            vev.leadingAnchor.constraint(equalTo: leadingAnchor),
            vev.trailingAnchor.constraint(equalTo: trailingAnchor),
            vev.topAnchor.constraint(equalTo: topAnchor),
            vev.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func resetScannerState() {
        cancelPendingAuthentication()
        scannerView.setState(.idle, animated: false)
    }

    func cancelPendingAuthentication() {
        evaluationInFlight = false
        activeAuthenticator?.invalidate()
        activeAuthenticator = nil
    }

    func beginBiometricUnlock(reason: String, onUnlocked: @escaping () -> Void) {
        guard !evaluationInFlight else { return }
        let auth = authenticatorFactory()
        guard auth.canEvaluateDeviceOwnerAuth || auth.canEvaluateBiometricsOrWatch else {
            onUnlocked()
            return
        }
        evaluationInFlight = true
        activeAuthenticator?.invalidate()
        activeAuthenticator = auth
        if let laView = auth.makeEmbeddedAuthView(controlSize: .regular) {
            scannerView.attachEmbeddedAuthenticationView(laView)
        }
        let allowPw: Bool
        switch scannerView.state {
        case .failed, .fallbackPassword:
            allowPw = true
        default:
            allowPw = !auth.canEvaluateBiometricsOrWatch
        }
        scannerView.setState(.scanning)
        auth.evaluate(reason: reason, allowPasswordFallback: allowPw) { [weak self] outcome in
            guard let self else { return }
            self.evaluationInFlight = false
            switch outcome {
            case .matched:
                self.scannerView.setState(.matched)
                onUnlocked()
            case .fallbackRequested:
                self.scannerView.setState(.fallbackPassword)
                self.beginBiometricUnlock(reason: reason, onUnlocked: onUnlocked)
            case .failed(let msg):
                self.scannerView.setState(.failed(msg))
            case .unavailable:
                self.scannerView.setState(.fallbackPassword)
            case .cancelled:
                self.scannerView.setState(.idle)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

// MARK: - Native macOS 27 Tahoe Liquid Glass Find-on-Page Bar (`⌘F` / `⌘G` / `⌘⇧G`)

private final class PageFindBarView: NSView, NSTextFieldDelegate {
    var onSearchChanged: ((String) -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onDismiss: (() -> Void)?

    var queryText: String { searchField.stringValue }

    private let contentHost = NSView()
    private var glassView: NSView?
    private let searchIcon = NSImageView()
    private let searchField = NSTextField()
    private let prevBtn = NSButton()
    private let nextBtn = NSButton()
    private let closeBtn = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.translatesAutoresizingMaskIntoConstraints = false
            gv.style = .regular
            gv.cornerRadius = 18.0
            gv.contentView = contentHost
            addSubview(gv)
            NSLayoutConstraint.activate([
                gv.leadingAnchor.constraint(equalTo: leadingAnchor),
                gv.trailingAnchor.constraint(equalTo: trailingAnchor),
                gv.topAnchor.constraint(equalTo: topAnchor),
                gv.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            self.glassView = gv
        } else {
            let vev = NSVisualEffectView()
            vev.translatesAutoresizingMaskIntoConstraints = false
            vev.material = .popover
            vev.blendingMode = .withinWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = 18.0
            vev.layer?.cornerCurve = .continuous
            vev.layer?.masksToBounds = true
            addSubview(vev)
            vev.addSubview(contentHost)
            NSLayoutConstraint.activate([
                vev.leadingAnchor.constraint(equalTo: leadingAnchor),
                vev.trailingAnchor.constraint(equalTo: trailingAnchor),
                vev.topAnchor.constraint(equalTo: topAnchor),
                vev.bottomAnchor.constraint(equalTo: bottomAnchor),
                contentHost.leadingAnchor.constraint(equalTo: vev.leadingAnchor),
                contentHost.trailingAnchor.constraint(equalTo: vev.trailingAnchor),
                contentHost.topAnchor.constraint(equalTo: vev.topAnchor),
                contentHost.bottomAnchor.constraint(equalTo: vev.bottomAnchor)
            ])
            self.glassView = vev
        }

        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = AssetLoader.shared.symbol(named: "magnifyingglass", pointSize: 12.5, weight: .medium)
        contentHost.addSubview(searchIcon)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 13.0)
        searchField.placeholderString = "Find on Page"
        searchField.delegate = self
        contentHost.addSubview(searchField)

        for (btn, sym, tip, action) in [
            (prevBtn, "chevron.up", "Previous Match (⇧⌘G)", #selector(prevClicked)),
            (nextBtn, "chevron.down", "Next Match (⌘G)", #selector(nextClicked)),
            (closeBtn, "xmark", "Done (Esc)", #selector(closeClicked))
        ] as [(NSButton, String, String, Selector)] {
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.isBordered = false
            btn.image = AssetLoader.shared.symbol(named: sym, pointSize: 11.5, weight: .semibold)
            btn.toolTip = tip
            btn.target = self
            btn.action = action
            contentHost.addSubview(btn)
        }

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 12),
            searchIcon.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: prevBtn.leadingAnchor, constant: -4),
            searchField.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 24),
            closeBtn.heightAnchor.constraint(equalToConstant: 24),

            nextBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -2),
            nextBtn.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            nextBtn.widthAnchor.constraint(equalToConstant: 24),
            nextBtn.heightAnchor.constraint(equalToConstant: 24),

            prevBtn.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor, constant: -2),
            prevBtn.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            prevBtn.widthAnchor.constraint(equalToConstant: 24),
            prevBtn.heightAnchor.constraint(equalToConstant: 24)
        ])

        apply(isDark: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (searchField.stringValue as NSString).length)
        }
    }

    func apply(isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        glassView?.appearance = appearance
        let primary = isDark ? NSColor.white.withAlphaComponent(0.94) : NSColor.black.withAlphaComponent(0.88)
        let secondary = isDark ? NSColor.white.withAlphaComponent(0.62) : NSColor.black.withAlphaComponent(0.54)
        searchField.textColor = primary
        searchIcon.contentTintColor = secondary
        prevBtn.contentTintColor = primary
        nextBtn.contentTintColor = primary
        closeBtn.contentTintColor = secondary
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift { onFindPrevious?() } else { onFindNext?() }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onDismiss?()
            return true
        }
        return false
    }

    @objc private func prevClicked() { onFindPrevious?() }
    @objc private func nextClicked() { onFindNext?() }
    @objc private func closeClicked() { onDismiss?() }
}

private final class ToolbarWindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class WebContentHostView: NSView {
    override func layout() {
        super.layout()
        syncChildFrames()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncChildFrames()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.frame = bounds
    }

    private func syncChildFrames() {
        let target = bounds
        guard target.width > 1, target.height > 1 else { return }
        for subview in subviews {
            if !NSEqualRects(subview.frame, target) {
                subview.frame = target
            }
        }
    }
}

/// One link of the toolbar chain: a view (or layout guide) with its leading/trailing anchors.
private struct ToolbarChainNode {
    let key: ObjectIdentifier
    let leading: NSLayoutXAxisAnchor
    let trailing: NSLayoutXAxisAnchor
}
