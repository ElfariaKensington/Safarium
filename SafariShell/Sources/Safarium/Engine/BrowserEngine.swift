import AppKit

/// Top-edge sampled surface color & computed WCAG relative luminance.
struct TopEdgeColorSample: Equatable {
    let color: NSColor
    let relativeLuminance: Double

    static func computeRelativeLuminance(for color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linearize(_ c: CGFloat) -> Double {
            let v = max(0.0, min(1.0, Double(c)))
            return (v <= 0.04045) ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linearize(srgb.redComponent)
        let g = linearize(srgb.greenComponent)
        let b = linearize(srgb.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    init(color: NSColor, relativeLuminance: Double? = nil) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        self.color = srgb
        self.relativeLuminance = relativeLuminance ?? Self.computeRelativeLuminance(for: srgb)
    }
}

/// Download item surfaced to the Safarium Downloads pill & popover.
struct BrowserDownloadItem: Identifiable {
    let id: UInt32
    let suggestedFileName: String
    let fullPath: String?
    let url: URL?
    let totalBytes: Int64
    let receivedBytes: Int64
    let percentComplete: Int32
    let isInProgress: Bool
    let isComplete: Bool
    let isCanceled: Bool
    let isPaused: Bool

    init(id: UInt32, suggestedFileName: String, fullPath: String?, url: URL?, totalBytes: Int64, receivedBytes: Int64, percentComplete: Int32, isInProgress: Bool, isComplete: Bool, isCanceled: Bool, isPaused: Bool = false) {
        self.id = id
        self.suggestedFileName = suggestedFileName
        self.fullPath = fullPath
        self.url = url
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.percentComplete = percentComplete
        self.isInProgress = isInProgress
        self.isComplete = isComplete
        self.isCanceled = isCanceled
        self.isPaused = isPaused
    }
}

/// Delegate callbacks from a single browser tab engine instance (delivered on main thread).
protocol BrowserTabEngineDelegate: AnyObject {
    func tabEngine(_ tab: BrowserTabEngine, didChangeURL url: URL?)
    func tabEngine(_ tab: BrowserTabEngine, didChangeTitle title: String)
    func tabEngine(_ tab: BrowserTabEngine, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateProgress progress: Double)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateFavicon favicon: NSImage?)
    func tabEngine(_ tab: BrowserTabEngine, didSampleTopEdgeColor sample: TopEdgeColorSample)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateFixedHeaderColor color: NSColor?)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateNativeVideo id: String, srcURL: String, rect: NSRect, visible: Bool, autoplay: Bool)
    func tabEngine(_ tab: BrowserTabEngine, didReceiveAuthEventJSON jsonString: String)
    func tabEngine(_ tab: BrowserTabEngine, didOpenAuthPopupWithURL url: URL)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateAuthPopupURL url: URL)
    func tabEngineDidCloseAuthPopup(_ tab: BrowserTabEngine)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateScrollY scrollY: CGFloat, contentHeight: CGFloat)
    func tabEngine(_ tab: BrowserTabEngine, didUpdatePageScale pageScale: CGFloat, isPinching: Bool)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateOverscrollY overscrollY: CGFloat, armed: Bool)
    func tabEngineDidTriggerPullToRefresh(_ tab: BrowserTabEngine)
    func tabEngine(_ tab: BrowserTabEngine, didRequestNewTabWithURL url: URL)
    func tabEngine(_ tab: BrowserTabEngine, didStartDownload item: BrowserDownloadItem)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateDownload item: BrowserDownloadItem)
    func tabEngine(_ tab: BrowserTabEngine, didFailLoad error: BrowserPageLoadError)
    func tabEngineDidRequestNavigateBack(_ tab: BrowserTabEngine)
    func tabEngineDidRequestNavigateForward(_ tab: BrowserTabEngine)
    func tabEngine(_ tab: BrowserTabEngine, didRecordPrivacyEvent event: PrivacyEvent)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateConnectionSecurity state: ConnectionSecurityState, host: String)
    func tabEngine(_ tab: BrowserTabEngine, didUpdateNavigationEntryIDs currentID: Int, previousID: Int, nextID: Int, validEntryIDs: [Int])
    func tabEngine(_ tab: BrowserTabEngine, didUpdateNavigationSnapshotData jpegData: Data, entryID: Int, logicalSize: CGSize, backingScale: CGFloat, backgroundColor: NSColor?)
    func tabEngine(_ tab: BrowserTabEngine, didBecomeVisuallyReadyForNavigation fromBFCache: Bool)
}

extension BrowserTabEngineDelegate {
    func tabEngine(_ tab: BrowserTabEngine, didUpdateFavicon favicon: NSImage?) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateFixedHeaderColor color: NSColor?) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateNativeVideo id: String, srcURL: String, rect: NSRect, visible: Bool, autoplay: Bool) {}
    func tabEngine(_ tab: BrowserTabEngine, didReceiveAuthEventJSON jsonString: String) {}
    func tabEngine(_ tab: BrowserTabEngine, didOpenAuthPopupWithURL url: URL) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateAuthPopupURL url: URL) {}
    func tabEngineDidCloseAuthPopup(_ tab: BrowserTabEngine) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateScrollY scrollY: CGFloat, contentHeight: CGFloat) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdatePageScale pageScale: CGFloat, isPinching: Bool) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateOverscrollY overscrollY: CGFloat, armed: Bool) {}
    func tabEngineDidTriggerPullToRefresh(_ tab: BrowserTabEngine) {}
    func tabEngine(_ tab: BrowserTabEngine, didRequestNewTabWithURL url: URL) {}
    func tabEngine(_ tab: BrowserTabEngine, didStartDownload item: BrowserDownloadItem) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateDownload item: BrowserDownloadItem) {}
    func tabEngine(_ tab: BrowserTabEngine, didFailLoad error: BrowserPageLoadError) {}
    func tabEngineDidRequestNavigateBack(_ tab: BrowserTabEngine) {}
    func tabEngineDidRequestNavigateForward(_ tab: BrowserTabEngine) {}
    func tabEngine(_ tab: BrowserTabEngine, didRecordPrivacyEvent event: PrivacyEvent) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateConnectionSecurity state: ConnectionSecurityState, host: String) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateNavigationEntryIDs currentID: Int, previousID: Int, nextID: Int, validEntryIDs: [Int]) {}
    func tabEngine(_ tab: BrowserTabEngine, didUpdateNavigationSnapshotData jpegData: Data, entryID: Int, logicalSize: CGSize, backingScale: CGFloat, backgroundColor: NSColor?) {}
    func tabEngine(_ tab: BrowserTabEngine, didBecomeVisuallyReadyForNavigation fromBFCache: Bool) {}
}

/// Sections inside `chrome://inspect` (matching Chromium 146+/156's `chrome://inspect` & `chrome://inspect/#remote-debugging`).
enum InspectPageSection: String, CaseIterable, Equatable {
    case devices = "devices"
    case pages = "pages"
    case extensions = "extensions"
    case serviceWorkers = "service-workers"
    case workers = "workers"
    case other = "other"
    case remoteDebugging = "remote-debugging"

    var sidebarTitle: String {
        switch self {
        case .devices: return "Devices"
        case .pages: return "Pages"
        case .extensions: return "Extensions"
        case .serviceWorkers: return "Service workers"
        case .workers: return "Shared workers"
        case .other: return "Other"
        case .remoteDebugging: return "Remote debugging"
        }
    }

    var pageTitle: String {
        switch self {
        case .remoteDebugging: return "Inspect — Remote Debugging"
        default: return "Inspect"
        }
    }

    var canonicalURL: URL {
        URL(string: "safarium://inspect/#\(rawValue)")!
    }
}

enum InspectPageURL {
    static let rootURL = URL(string: "safarium://inspect")!
    static let remoteDebuggingURL = URL(string: "safarium://inspect/#remote-debugging")!

    /// Parses `safarium://inspect`, `safarium://inspect/`, `safarium://inspect/#remote-debugging`, etc.
    static func parse(_ url: URL?) -> InspectPageSection? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "safarium",
              url.host?.lowercased() == "inspect" else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            return nil
        }
        guard let rawFrag = url.fragment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawFrag.isEmpty else {
            return .devices
        }
        if let exact = InspectPageSection(rawValue: rawFrag) {
            return exact
        }
        switch rawFrag {
        case "serviceworkers", "service_workers", "sw":
            return .serviceWorkers
        case "shared-workers", "sharedworkers", "shared_workers":
            return .workers
        case "remotedebugging", "remote_debugging", "remote":
            return .remoteDebugging
        default:
            return .devices
        }
    }

    static func isInspectURL(_ url: URL?) -> Bool {
        parse(url) != nil
    }
}

/// Narrow Swift protocol abstracting a single browser tab (implemented by MockBrowserEngine and ChromiumBrowserEngine).
protocol BrowserTabEngine: AnyObject {
    var tabID: String { get }
    var delegate: BrowserTabEngineDelegate? { get set }

    /// Host NSView displaying the rendered webpage (no engine-owned toolbar or chrome).
    var contentView: NSView { get }

    var currentURL: URL? { get }
    var isStartPage: Bool { get }
    var isHistoryPage: Bool { get }
    var isInspectPage: Bool { get }
    var inspectPageSection: InspectPageSection { get }
    var title: String { get }
    var isLoading: Bool { get }
    var estimatedProgress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var favicon: NSImage? { get }
    var scrollY: CGFloat { get }
    var isScrolledToTop: Bool { get }
    var contentHeight: CGFloat { get }
    var viewportHeight: CGFloat { get }
    var canInnerScrollUp: Bool { get }
    var canInnerScrollDown: Bool { get }
    var canScrollLeft: Bool { get }
    var canScrollRight: Bool { get }
    var pageConsumesPinchZoom: Bool { get }
    var pageScale: CGFloat { get }
    var pageZoomFactor: Double { get }
    var cachedSnapshot: NSImage? { get }
    /// Pixel-exact, full-resolution copy of what the web view shows (nil when it no longer matches the screen).
    var currentFrameSurface: IOSurface? { get }
    /// Size in points `currentFrameSurface` covers.
    var currentFrameSize: CGSize { get }
    /// Takes a fresh exact frame copy now and reports it on the main thread (nil when not possible).
    func refreshCurrentFrame(_ completion: @escaping (IOSurface?, CGSize) -> Void)
    /// A layer mirroring the web content live (GPU-composited, no copy); nil when the tab isn't rendering.
    func makeLiveContentMirrorLayer() -> CALayer?
    var currentNavigationEntryID: Int { get }
    var previousNavigationEntryID: Int { get }
    var nextNavigationEntryID: Int { get }
    var validNavigationEntryIDs: [Int] { get }
    var pageBackgroundColor: NSColor? { get }
    var lastTopEdgeColorSample: TopEdgeColorSample? { get }
    var fixedHeaderColor: NSColor? { get }
    var connectionSecurityState: ConnectionSecurityState { get }
    var connectionSecurityHost: String? { get }

    func loadURL(_ url: URL)
    func loadInput(_ input: String)
    func prewarmOrigin(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func reloadIgnoringCache()
    func stopLoading()
    func findText(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool)
    func stopFinding(clearSelection: Bool)
    func showDevTools()
    func executeJavaScript(_ script: String)
    func executeJavaScriptInAllFrames(_ script: String)
    var authPopupContainerView: NSView? { get }
    var hasActiveAuthPopup: Bool { get }
    var activeAuthPopupURL: URL? { get }
    func executeJavaScriptInAuthPopup(_ script: String)
    func closeAuthPopup()
    func printPage()
    func exportToPDF(atPath path: String, completion: @escaping (Bool) -> Void)
    func setAudioMuted(_ muted: Bool)
    var isAudioMuted: Bool { get }
    func closeTab()
    func attach(to parentView: NSView)
    func detachFromParentView()
    func setTabActive(_ active: Bool)
    func focusWebContent()
    func setPageZoomFactor(_ factor: Double)
    /// Height of the toolbar stack the page runs under; the page is inset by it (BrowserCore `installUnderToolbarInset`).
    func setPageTopInset(_ inset: CGFloat)
    @discardableResult
    func applyPinchMagnification(_ magnification: CGFloat, atPoint point: NSPoint, isPinching: Bool) -> CGFloat
    func resetPageScale()
    func setPageOvershootScale(_ scale: CGFloat)
    func setPageOvershootScale(_ scale: CGFloat, anchorPoint: NSPoint)
    func endPageOvershoot()
    func resetOverscroll()
    func setScrollInteractionActive(_ active: Bool)
    func startDownload(at url: URL)
    func captureSnapshot(completion: @escaping (NSImage?) -> Void)
    func setPreviewSnapshotPaused(_ paused: Bool)

    /// Samples a thin 2–4pt strip from the top of the rendered view surface (NEVER `<meta name="theme-color">`).
    func sampleTopEdgeColor(stripHeight: CGFloat, completion: @escaping (TopEdgeColorSample?) -> Void)
}

extension BrowserTabEngine {
    var isStartPage: Bool { currentURL?.scheme == "safarium" && currentURL?.host != "history" }
    var isHistoryPage: Bool { currentURL?.scheme == "safarium" && currentURL?.host == "history" }
    var isInspectPage: Bool { InspectPageURL.isInspectURL(currentURL) }
    var inspectPageSection: InspectPageSection { InspectPageURL.parse(currentURL) ?? .devices }
    var isNativeInternalPage: Bool { isStartPage || isHistoryPage || isInspectPage }
    var isScrolledToTop: Bool { scrollY <= 1.0 }
    var viewportHeight: CGFloat { contentView.bounds.height }
    var canInnerScrollUp: Bool { false }
    var canInnerScrollDown: Bool { false }
    var canScrollLeft: Bool { false }
    var canScrollRight: Bool { false }
    var pageConsumesPinchZoom: Bool { false }
    var pageZoomFactor: Double { 1.0 }
    var cachedSnapshot: NSImage? { nil }
    var currentFrameSurface: IOSurface? { nil }
    var currentFrameSize: CGSize { .zero }
    func refreshCurrentFrame(_ completion: @escaping (IOSurface?, CGSize) -> Void) { completion(nil, .zero) }
    func makeLiveContentMirrorLayer() -> CALayer? { nil }
    var currentNavigationEntryID: Int { 0 }
    var previousNavigationEntryID: Int { 0 }
    var nextNavigationEntryID: Int { 0 }
    var validNavigationEntryIDs: [Int] { [] }
    var pageBackgroundColor: NSColor? { nil }
    var fixedHeaderColor: NSColor? { nil }
    var connectionSecurityState: ConnectionSecurityState { .internalPage }
    var connectionSecurityHost: String? { nil }
    var authPopupContainerView: NSView? { nil }
    var hasActiveAuthPopup: Bool { false }
    var activeAuthPopupURL: URL? { nil }

    func setTabActive(_ active: Bool) {
        contentView.isHidden = !active
    }

    func focusWebContent() {}
    func setPageZoomFactor(_ factor: Double) {}
    func setPageTopInset(_ inset: CGFloat) {}

    @discardableResult
    func applyPinchMagnification(_ magnification: CGFloat, atPoint point: NSPoint, isPinching: Bool) -> CGFloat {
        return pageScale
    }

    func resetPageScale() {}
    func setPageOvershootScale(_ scale: CGFloat) {}
    func setPageOvershootScale(_ scale: CGFloat, anchorPoint: NSPoint) { setPageOvershootScale(scale) }
    func endPageOvershoot() {}
    func resetOverscroll() {}
    func setScrollInteractionActive(_ active: Bool) {}
    func startDownload(at url: URL) {}
    func setPreviewSnapshotPaused(_ paused: Bool) {}
    func prewarmOrigin(_ url: URL) {}

    func captureSnapshot(completion: @escaping (NSImage?) -> Void) {
        let view = contentView
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            completion(cachedSnapshot)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: view.bounds.size)
        img.addRepresentation(rep)
        completion(img)
    }

    func attach(to parentView: NSView) {
        let view = contentView
        if view.superview !== parentView {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            parentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
                view.topAnchor.constraint(equalTo: parentView.topAnchor),
                view.bottomAnchor.constraint(equalTo: parentView.bottomAnchor)
            ])
        }
    }

    func detachFromParentView() {
        contentView.removeFromSuperview()
    }

    func reloadIgnoringCache() { reload() }
    func findText(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {}
    func stopFinding(clearSelection: Bool) {}
    func showDevTools() {}
    func executeJavaScript(_ script: String) {}
    func executeJavaScriptInAllFrames(_ script: String) {}
    func executeJavaScriptInAuthPopup(_ script: String) {}
    func closeAuthPopup() {}
    func printPage() {}
    func exportToPDF(atPath path: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func setAudioMuted(_ muted: Bool) {}
    var isAudioMuted: Bool { false }
}

/// A live `chrome.contextMenus` item registered by an installed MV3 extension.
struct BrowserExtensionContextMenuItem: Equatable {
    let id: String
    let parentID: String?
    let title: String
    let isSeparator: Bool
    let isEnabled: Bool
    let isChecked: Bool
    let children: [BrowserExtensionContextMenuItem]
}

/// Installed MV3 Chrome Web Store / unpacked extension surfaced to the Safarium Liquid Glass toolbar capsule.
struct BrowserExtensionItem: Identifiable, Equatable {
    let id: String
    let storeID: String?
    let name: String
    let version: String
    let extensionDescription: String?
    let installPath: String
    let icon: NSImage?
    let badgeText: String?
    let badgeColor: NSColor?
    let popupURL: URL?
    let enabled: Bool
    let allowInPrivate: Bool

    init(
        id: String,
        storeID: String? = nil,
        name: String,
        version: String,
        extensionDescription: String? = nil,
        installPath: String = "",
        icon: NSImage?,
        badgeText: String?,
        badgeColor: NSColor?,
        popupURL: URL?,
        enabled: Bool,
        allowInPrivate: Bool = false
    ) {
        self.id = id
        self.storeID = storeID
        self.name = name
        self.version = version
        self.extensionDescription = extensionDescription
        self.installPath = installPath
        self.icon = icon
        self.badgeText = badgeText
        self.badgeColor = badgeColor
        self.popupURL = popupURL
        self.enabled = enabled
        self.allowInPrivate = allowInPrivate
    }

    static func == (lhs: BrowserExtensionItem, rhs: BrowserExtensionItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.storeID == rhs.storeID &&
        lhs.name == rhs.name &&
        lhs.version == rhs.version &&
        lhs.extensionDescription == rhs.extensionDescription &&
        lhs.installPath == rhs.installPath &&
        lhs.badgeText == rhs.badgeText &&
        lhs.badgeColor == rhs.badgeColor &&
        lhs.popupURL == rhs.popupURL &&
        lhs.enabled == rhs.enabled &&
        lhs.allowInPrivate == rhs.allowInPrivate &&
        (lhs.icon === rhs.icon)
    }
}

/// Top-level browser engine runtime protocol creating and managing tabs & extensions.
protocol BrowserEngine: AnyObject {
    var engineName: String { get }
    var isRealChromium: Bool { get }
    var onExtensionsDidUpdate: (([BrowserExtensionItem]) -> Void)? { get set }

    func start() throws
    func shutdown()
    func createTab(initialURL: URL?, parentView: NSView?, isPrivate: Bool) -> BrowserTabEngine
    func resetPrivateSession()
    func applySettings(_ preferences: [String: Any])
    func clearWebsiteData(completion: @escaping (Bool) -> Void)
    func syncPrivacyPolicy(_ policy: [String: Any])
    func allowInsecureHTTP(forHost host: String)
    func fetchWebsiteDataRecords(completion: @escaping ([WebsiteDataRecord]) -> Void)
    func removeWebsiteData(forDomains domains: [String], completion: @escaping (Bool) -> Void)
    func cancelDownload(id: UInt32)
    func pauseDownload(id: UInt32)
    func resumeDownload(id: UInt32) -> Bool

    // MV3 Chrome Web Store & unpacked extension hooks
    func installedExtensions() -> [BrowserExtensionItem]
    @discardableResult func loadUnpackedExtension(atPath path: String) -> Bool
    func loadUnpackedExtension(atPath path: String, completion: @escaping (Bool) -> Void)
    @discardableResult func installExtensionFromCRX(atPath path: String) -> Bool
    func installExtensionFromCRX(atPath path: String, completion: @escaping (Bool, String?) -> Void)
    func installExtensionFromChromeWebStoreID(_ storeID: String, completion: @escaping (Bool) -> Void)
    @discardableResult func uninstallExtension(withID extensionID: String) -> Bool
    func setExtensionEnabled(_ enabled: Bool, forID extensionID: String, completion: @escaping (Bool) -> Void)
    func setExtensionAllowInPrivate(_ allowed: Bool, forID extensionID: String, completion: @escaping (Bool) -> Void)
    func clearExtensionStorage(forID extensionID: String, completion: @escaping (Bool) -> Void)
    func createExtensionPopupView(forExtensionID extensionID: String, width: CGFloat, height: CGFloat, parentView: NSView) -> NSView?
    func closeExtensionPopupView(forExtensionID extensionID: String)
    func extensionContextMenuItems(forExtensionID extensionID: String) -> [BrowserExtensionContextMenuItem]
    func triggerExtensionContextMenuItem(itemID: String, forExtensionID extensionID: String, pageURL: URL?)

    // Remote debugging (`chrome://inspect` & `chrome://inspect/#remote-debugging`)
    var activeRemoteDebuggingPort: Int { get }
    var isRemoteDebuggingActive: Bool { get }
    var devToolsActivePortFilePath: String? { get }
    var remoteDebuggingWebSocketURL: String? { get }
    func openDevToolsForRemoteTarget(wsURL: String)
}

extension BrowserEngine {
    var activeRemoteDebuggingPort: Int { 0 }
    var isRemoteDebuggingActive: Bool { activeRemoteDebuggingPort >= 1024 && activeRemoteDebuggingPort <= 65535 }
    var devToolsActivePortFilePath: String? { nil }
    var remoteDebuggingWebSocketURL: String? { nil }
    func openDevToolsForRemoteTarget(wsURL: String) {}

    var onExtensionsDidUpdate: (([BrowserExtensionItem]) -> Void)? {
        get { nil }
        set {}
    }

    func createTab(initialURL: URL?) -> BrowserTabEngine {
        createTab(initialURL: initialURL, parentView: nil, isPrivate: false)
    }

    func createTab(initialURL: URL?, parentView: NSView?) -> BrowserTabEngine {
        createTab(initialURL: initialURL, parentView: parentView, isPrivate: false)
    }

    func resetPrivateSession() {}
    func applySettings(_ preferences: [String: Any]) {}
    func clearWebsiteData(completion: @escaping (Bool) -> Void) { completion(true) }
    func syncPrivacyPolicy(_ policy: [String: Any]) {}
    func allowInsecureHTTP(forHost host: String) {}
    func fetchWebsiteDataRecords(completion: @escaping ([WebsiteDataRecord]) -> Void) { completion([]) }
    func removeWebsiteData(forDomains domains: [String], completion: @escaping (Bool) -> Void) { completion(true) }
    func cancelDownload(id: UInt32) {}
    func pauseDownload(id: UInt32) {}
    func resumeDownload(id: UInt32) -> Bool { false }

    func installedExtensions() -> [BrowserExtensionItem] { [] }
    @discardableResult func loadUnpackedExtension(atPath path: String) -> Bool { false }
    func loadUnpackedExtension(atPath path: String, completion: @escaping (Bool) -> Void) { completion(false) }
    @discardableResult func installExtensionFromCRX(atPath path: String) -> Bool { false }
    func installExtensionFromCRX(atPath path: String, completion: @escaping (Bool, String?) -> Void) { completion(false, "Extensions are unavailable.") }
    func installExtensionFromChromeWebStoreID(_ storeID: String, completion: @escaping (Bool) -> Void) { completion(false) }
    @discardableResult func uninstallExtension(withID extensionID: String) -> Bool { false }
    func setExtensionEnabled(_ enabled: Bool, forID extensionID: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func setExtensionAllowInPrivate(_ allowed: Bool, forID extensionID: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearExtensionStorage(forID extensionID: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func createExtensionPopupView(forExtensionID extensionID: String, width: CGFloat, height: CGFloat, parentView: NSView) -> NSView? { nil }
    func closeExtensionPopupView(forExtensionID extensionID: String) {}
    func extensionContextMenuItems(forExtensionID extensionID: String) -> [BrowserExtensionContextMenuItem] { [] }
    func triggerExtensionContextMenuItem(itemID: String, forExtensionID extensionID: String, pageURL: URL?) {}
}

enum URLInputNormalizer {
    static func normalize(_ rawInput: String, isPrivate: Bool = false) -> URL {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return URL(string: "safarium://start")!
        }
        // URL schemes are case-insensitive ("HTTP://", "Safarium://", "ABOUT:blank"); any explicit "scheme://" is also kept as typed.
        let lowered = trimmed.lowercased()
        let knownPrefixes = ["safarium://", "http://", "https://", "about:", "chrome://", "chrome-extension://", "file://", "view-source:"]
        let hasExplicitScheme = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) != nil
        if knownPrefixes.contains(where: { lowered.hasPrefix($0) }) || hasExplicitScheme {
            if let url = URL(string: trimmed) {
                return url
            }
        }
        // Local development hosts (localhost, IP literals, *.local) have no TLS: default to http, like Safari/Chrome.
        if !trimmed.contains(" "), isLocalHostInput(trimmed), let url = URL(string: "http://\(trimmed)") {
            return url
        }
        // Check if it looks like a domain (contains a dot and no spaces)
        if !trimmed.contains(" ") && trimmed.contains(".") {
            if let url = URL(string: "https://\(trimmed)") {
                return url
            }
        }
        // Quick Website Search (e.g. "youtube rust tutorial", "github cef")
        if let quick = BrowserSettings.shared.matchQuickWebsiteSearch(for: trimmed) {
            return quick.url
        }
        return BrowserSettings.shared.effectiveSearchEngine(isPrivate: isPrivate).searchURL(for: trimmed)
    }

    /// True when the typed text's host part is `localhost`, `*.localhost`, `*.local`, an IPv4 literal or a bracketed IPv6 literal.
    static func isLocalHostInput(_ input: String) -> Bool {
        var authority = Substring(input)
        if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = authority[..<end]
        }
        if authority.hasPrefix("[") { return authority.contains("]") }
        var host = authority
        if let colon = authority.lastIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            host = authority[..<colon]
        }
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } && Int($0)! <= 255 }
    }

    static func displayDomain(for url: URL?) -> String {
        guard let url else { return "Start Page" }
        if InspectPageURL.isInspectURL(url) {
            return url.absoluteString
        }
        if url.scheme == "safarium" {
            return "Search or enter website name"
        }
        if BrowserSettings.shared.showFullWebsiteAddress {
            return url.absoluteString
        }
        if let rawHost = url.host, !rawHost.isEmpty {
            let host = rawHost.lowercased()
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }
}
