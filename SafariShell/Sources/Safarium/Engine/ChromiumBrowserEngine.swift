import AppKit
import Foundation

#if SAFARIUM_CHROMIUM_CORE
import BrowserCore

enum ChromiumRuntimeBootstrap {
    static func installHooksIfAvailable() {
        SXEngineRuntime.installApplicationProtocolHooks()
    }
}

/// Production BrowserEngine adapter wired directly to `@chromium-core`'s `SXEngineRuntime` / `SXBrowserTab`
/// (`BrowserCore/include/SafariumEngineBridge.h`).
final class ChromiumBrowserEngine: NSObject, BrowserEngine, SXEngineExtensionDelegate {
    let engineName = "Chromium 156 (Chrome Runtime)"
    let isRealChromium = true
    var onExtensionsDidUpdate: (([BrowserExtensionItem]) -> Void)?

    private let runtime = SXEngineRuntime.shared()

    func start() throws {
        SXEngineRuntime.installApplicationProtocolHooks()
        let config = SXEngineConfiguration.default()
        config.defaultNewTabURL = URL(string: "https://www.google.com")!
        if BrowserSettings.shared.remoteDebuggingEnabled {
            config.remoteDebuggingPort = BrowserSettings.shared.remoteDebuggingPort
        }
        try runtime.initialize(with: config)
        runtime.extensionDelegate = self
        runtime.applyPreferences(BrowserSettings.shared.enginePreferencesDictionary())
        runtime.syncPrivacyPolicy(BrowserSettings.shared.privacyPolicyDictionary())
        NSLog("[Safarium] Initialized real Chromium %@ (profile: %@)", runtime.chromiumVersion, runtime.profileDirectory)
    }

    var activeRemoteDebuggingPort: Int {
        Int(runtime.activeRemoteDebuggingPort)
    }

    var isRemoteDebuggingActive: Bool {
        runtime.isRemoteDebuggingActive
    }

    var devToolsActivePortFilePath: String? {
        runtime.devToolsActivePortFilePath
    }

    var remoteDebuggingWebSocketURL: String? {
        runtime.remoteDebuggingWebSocketURL
    }

    func openDevToolsForRemoteTarget(wsURL: String) {
        runtime.openDevTools(forRemoteWebSocketURL: wsURL)
    }

    func shutdown() {
        runtime.extensionDelegate = nil
        runtime.shutdown()
    }

    func createTab(initialURL: URL?, parentView: NSView?, isPrivate: Bool = false) -> BrowserTabEngine {
        let adapter = ChromiumTabAdapter(isPrivate: isPrivate)
        let inspectSection = InspectPageURL.parse(initialURL)
        let wantsHistory = (initialURL?.scheme == "safarium" && initialURL?.host == "history")
        let wantsStartPage = inspectSection == nil && !wantsHistory && (initialURL == nil || initialURL?.scheme == "safarium")
        if let inspectSection {
            adapter.setNativePageMode(.inspect(inspectSection))
        } else if wantsHistory {
            adapter.setNativePageMode(.history)
        } else {
            adapter.setStartPageMode(wantsStartPage)
        }
        let resolvedURL: URL = (wantsStartPage || wantsHistory || inspectSection != nil)
            ? URL(string: "about:blank")!
            : (initialURL ?? URL(string: "https://www.google.com")!)
        let tab = runtime.createTab(withInitialURL: resolvedURL, parentView: parentView, delegate: adapter, incognito: isPrivate)
        adapter.bind(tab: tab)
        return adapter
    }

    func resetPrivateSession() {
        runtime.resetIncognitoSession()
    }

    func applySettings(_ preferences: [String: Any]) {
        runtime.applyPreferences(preferences)
    }

    func cancelDownload(id: UInt32) {
        runtime.cancelDownload(withID: id)
    }

    func pauseDownload(id: UInt32) {
        runtime.pauseDownload(withID: id)
    }

    func resumeDownload(id: UInt32) -> Bool {
        runtime.resumeDownload(withID: id)
    }

    func clearWebsiteData(completion: @escaping (Bool) -> Void) {
        runtime.clearWebsiteData { ok in
            completion(ok)
        }
    }

    func syncPrivacyPolicy(_ policy: [String: Any]) {
        runtime.syncPrivacyPolicy(policy)
    }

    func allowInsecureHTTP(forHost host: String) {
        runtime.allowInsecureHTTP(forHost: host)
    }

    func fetchWebsiteDataRecords(completion: @escaping ([WebsiteDataRecord]) -> Void) {
        runtime.fetchWebsiteDataRecords { sxRecords in
            let records = sxRecords.map { rec in
                WebsiteDataRecord(
                    domain: rec.domain,
                    cookieCount: rec.cookieCount,
                    hasCookies: rec.hasCookies,
                    hasCache: rec.hasCache
                )
            }
            completion(records)
        }
    }

    func removeWebsiteData(forDomains domains: [String], completion: @escaping (Bool) -> Void) {
        runtime.removeWebsiteData(forDomains: domains) { ok in
            completion(ok)
        }
    }

    // MARK: - Chrome Web Store MV3 Extensions

    func installedExtensions() -> [BrowserExtensionItem] {
        runtime.installedExtensions().map(Self.mapExtension)
    }

    @discardableResult
    /// Fire-and-forget variant. The return value means "the request was accepted", NOT "the extension loaded":
    /// it is false when the path is obviously unusable (missing, not a directory, no manifest.json); the real outcome
    /// is delivered by `onExtensionsDidUpdate` / the completion-based overload.
    func loadUnpackedExtension(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("manifest.json")) else {
            return false
        }
        loadUnpackedExtension(atPath: path) { _ in }
        return true
    }

    func loadUnpackedExtension(atPath path: String, completion: @escaping (Bool) -> Void) {
        runtime.loadUnpackedExtension(atPath: path) { [weak self] item, error in
            if let error {
                NSLog("[Safarium] loadUnpackedExtension error: %@", error.localizedDescription)
            }
            if let self {
                self.onExtensionsDidUpdate?(self.installedExtensions())
            }
            completion(item != nil && error == nil)
        }
    }

    @discardableResult
    func installExtensionFromCRX(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        installExtensionFromCRX(atPath: path) { _, _ in }
        return true
    }

    func installExtensionFromCRX(atPath path: String, completion: @escaping (Bool, String?) -> Void) {
        runtime.installExtensionFromCRX(atPath: path) { [weak self] item, error in
            if let error {
                NSLog("[Safarium] installExtensionFromCRX error: %@", error.localizedDescription)
            }
            if let self {
                self.onExtensionsDidUpdate?(self.installedExtensions())
            }
            completion(item != nil && error == nil, error?.localizedDescription)
        }
    }

    func installExtensionFromChromeWebStoreID(_ storeID: String, completion: @escaping (Bool) -> Void) {
        runtime.installExtension(fromChromeWebStoreID: storeID) { [weak self] item, error in
            if let error {
                NSLog("[Safarium] installExtensionFromChromeWebStoreID(%@) error: %@", storeID, error.localizedDescription)
            }
            if let self {
                self.onExtensionsDidUpdate?(self.installedExtensions())
            }
            completion(item != nil && error == nil)
        }
    }

    @discardableResult
    func uninstallExtension(withID extensionID: String) -> Bool {
        guard installedExtensions().contains(where: { $0.id == extensionID }) else { return false }
        runtime.uninstallExtension(withID: extensionID) { [weak self] _, error in
            if let error {
                NSLog("[Safarium] uninstallExtension error: %@", error.localizedDescription)
            }
            guard let self else { return }
            self.onExtensionsDidUpdate?(self.installedExtensions())
        }
        return true
    }

    func setExtensionEnabled(_ enabled: Bool, forID extensionID: String, completion: @escaping (Bool) -> Void) {
        runtime.setExtensionWithID(extensionID, enabled: enabled) { [weak self] ok, error in
            if let error {
                NSLog("[Safarium] setExtensionEnabled error: %@", error.localizedDescription)
            }
            if let self {
                self.onExtensionsDidUpdate?(self.installedExtensions())
            }
            completion(ok && error == nil)
        }
    }

    func setExtensionAllowInPrivate(_ allowed: Bool, forID extensionID: String, completion: @escaping (Bool) -> Void) {
        runtime.setExtensionWithID(extensionID, allowInPrivate: allowed) { [weak self] ok, error in
            if let error {
                NSLog("[Safarium] setExtensionAllowInPrivate error: %@", error.localizedDescription)
            }
            if let self {
                self.onExtensionsDidUpdate?(self.installedExtensions())
            }
            completion(ok && error == nil)
        }
    }

    func clearExtensionStorage(forID extensionID: String, completion: @escaping (Bool) -> Void) {
        runtime.clearStorageForExtension(withID: extensionID) { ok, error in
            if let error {
                NSLog("[Safarium] clearExtensionStorage error: %@", error.localizedDescription)
            }
            completion(ok && error == nil)
        }
    }

    func createExtensionPopupView(forExtensionID extensionID: String, width: CGFloat, height: CGFloat, parentView: NSView) -> NSView? {
        runtime.createExtensionPopupView(forExtensionID: extensionID, width: width, height: height, parentView: parentView)
    }

    func closeExtensionPopupView(forExtensionID extensionID: String) {
        runtime.closeExtensionPopup(forExtensionID: extensionID)
    }

    func extensionContextMenuItems(forExtensionID extensionID: String) -> [BrowserExtensionContextMenuItem] {
        runtime.contextMenuItems(forExtensionID: extensionID).map(Self.mapContextMenuItem)
    }

    func triggerExtensionContextMenuItem(itemID: String, forExtensionID extensionID: String, pageURL: URL?) {
        runtime.triggerContextMenuItem(withID: itemID, forExtensionID: extensionID, pageURL: pageURL)
    }

    func engineRuntime(_ runtime: SXEngineRuntime, didUpdateExtensions extensions: [SXExtensionItem]) {
        onExtensionsDidUpdate?(extensions.map(Self.mapExtension))
    }

    private static func mapContextMenuItem(_ item: SXExtensionContextMenuItem) -> BrowserExtensionContextMenuItem {
        BrowserExtensionContextMenuItem(
            id: item.itemID,
            parentID: item.parentID,
            title: item.title,
            isSeparator: item.isSeparator,
            isEnabled: item.isEnabled,
            isChecked: item.isChecked,
            children: item.children.map(Self.mapContextMenuItem)
        )
    }

    private static func mapExtension(_ ext: SXExtensionItem) -> BrowserExtensionItem {
        BrowserExtensionItem(
            id: ext.extensionID,
            storeID: ext.storeID,
            name: ext.name,
            version: ext.version,
            extensionDescription: ext.extensionDescription,
            installPath: ext.installPath,
            icon: ext.icon,
            badgeText: ext.badgeText,
            badgeColor: ext.badgeColor,
            popupURL: ext.popupURL,
            enabled: ext.isEnabled,
            allowInPrivate: ext.allowInPrivate
        )
    }
}

final class ChromiumTabAdapter: NSObject, BrowserTabEngine, SXBrowserTabDelegate {
    enum NativePageMode: Equatable {
        case none
        case start
        case history
        case inspect(InspectPageSection)
    }

    private let isPrivate: Bool
    private var sxTab: SXBrowserTab?
    private let fallbackView = NSView()
    private var nativePageMode: NativePageMode = .none
    private var showingStartPage: Bool { nativePageMode != .none }
    private var hasStartPageBackEntry: Bool = false
    private var hasForwardFromStartPage: Bool = false
    private var backNativePageMode: NativePageMode = .start
    private var historyReturnToWeb: Bool = false
    /// True when the Start Page was opened on top of a loaded web page, so Back can return to that page.
    private var startReturnToWeb: Bool = false
    /// True when `chrome://inspect` was opened on top of a loaded web page, so Back can return to that page.
    private var inspectReturnToWeb: Bool = false
    private var fallbackFavicon: NSImage?
    private var lastFaviconHost: String = ""
    private var lastConnectionSecurityState: ConnectionSecurityState = .internalPage
    private var lastConnectionSecurityHost: String?

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        super.init()
    }

    let tabID: String = UUID().uuidString
    weak var delegate: BrowserTabEngineDelegate?
    private(set) var lastTopEdgeColorSample: TopEdgeColorSample?

    var contentView: NSView { sxTab?.contentView ?? fallbackView }
    var authPopupContainerView: NSView? { sxTab?.authPopupContainerView }
    var hasActiveAuthPopup: Bool { sxTab?.hasActiveAuthPopup ?? false }
    var activeAuthPopupURL: URL? { sxTab?.activeAuthPopupURL }
    var isStartPage: Bool { nativePageMode == .start }
    var isHistoryPage: Bool { nativePageMode == .history }
    var isInspectPage: Bool {
        if case .inspect = nativePageMode { return true }
        return false
    }
    var inspectPageSection: InspectPageSection {
        if case .inspect(let section) = nativePageMode { return section }
        return .devices
    }
    var currentURL: URL? {
        switch nativePageMode {
        case .start: return URL(string: "safarium://start")
        case .history: return URL(string: "safarium://history")
        case .inspect(let section): return section.canonicalURL
        case .none: return sxTab?.currentURL
        }
    }
    var title: String {
        switch nativePageMode {
        case .start: return "Start Page"
        case .history: return "History"
        case .inspect(let section): return section.pageTitle
        case .none:
            let t = sxTab?.title ?? ""
            if !t.isEmpty { return t }
            return URLInputNormalizer.displayDomain(for: sxTab?.currentURL)
        }
    }
    var isLoading: Bool { showingStartPage ? false : (sxTab?.isLoading ?? false) }
    var estimatedProgress: Double { showingStartPage ? 1.0 : (sxTab?.estimatedProgress ?? 0.0) }
    var canGoBack: Bool {
        if nativePageMode == .history { return hasStartPageBackEntry || (sxTab?.currentURL != nil && sxTab?.currentURL?.absoluteString != "about:blank") }
        if case .inspect = nativePageMode { return inspectReturnToWeb || hasStartPageBackEntry }
        if nativePageMode == .start { return startReturnToWeb }
        return (sxTab?.canGoBack ?? false) || hasStartPageBackEntry
    }
    var canGoForward: Bool {
        if showingStartPage {
            return (sxTab?.canGoForward ?? false) || hasForwardFromStartPage
        }
        return sxTab?.canGoForward ?? false
    }
    var favicon: NSImage? { showingStartPage ? nil : (sxTab?.favicon ?? fallbackFavicon) }
    var scrollY: CGFloat { showingStartPage ? 0 : (sxTab?.scrollY ?? 0) }
    var isScrolledToTop: Bool { showingStartPage ? true : (sxTab?.isScrolledToTop ?? (scrollY <= 1.0)) }
    var contentHeight: CGFloat { sxTab?.contentHeight ?? 0 }
    var viewportHeight: CGFloat {
        let vh = sxTab?.viewportHeight ?? 0
        return vh > 1.0 ? vh : contentView.bounds.height
    }
    var canInnerScrollUp: Bool { showingStartPage ? false : (sxTab?.canInnerScrollUp ?? false) }
    var canInnerScrollDown: Bool { showingStartPage ? false : (sxTab?.canInnerScrollDown ?? false) }
    var canScrollLeft: Bool { showingStartPage ? false : (sxTab?.canScrollLeft ?? false) }
    var canScrollRight: Bool { showingStartPage ? false : (sxTab?.canScrollRight ?? false) }
    var pageConsumesPinchZoom: Bool { showingStartPage ? false : (sxTab?.pageConsumesPinchZoom ?? false) }
    var pageScale: CGFloat { showingStartPage ? 1.0 : (sxTab?.pageScale ?? 1.0) }
    var pageZoomFactor: Double { sxTab?.pageZoomFactor() ?? 1.0 }
    var cachedSnapshot: NSImage? { sxTab?.cachedSnapshot }
    var currentFrameSurface: IOSurface? {
        guard !showingStartPage, let surface = sxTab?.currentFrameSurface else { return nil }
        return (surface as AnyObject) as? IOSurface
    }
    var currentFrameSize: CGSize { sxTab?.currentFrameSize ?? .zero }
    func makeLiveContentMirrorLayer() -> CALayer? {
        showingStartPage ? nil : sxTab?.makeLiveContentMirrorLayer()
    }

    func refreshCurrentFrame(_ completion: @escaping (IOSurface?, CGSize) -> Void) {
        guard !showingStartPage, let sxTab else { completion(nil, .zero); return }
        sxTab.refreshCurrentFrame { surface, size in
            completion((surface as AnyObject?) as? IOSurface, size)
        }
    }
    private func nativeEntryID(for mode: NativePageMode) -> Int {
        switch mode {
        case .start: return NavigationSnapshotStore.startPageEntryID
        case .history: return NavigationSnapshotStore.historyPageEntryID
        case .inspect: return NavigationSnapshotStore.inspectPageEntryID
        case .none: return 0
        }
    }
    var currentNavigationEntryID: Int {
        if nativePageMode != .none { return nativeEntryID(for: nativePageMode) }
        return sxTab?.currentNavigationEntryID ?? 0
    }
    var previousNavigationEntryID: Int {
        switch nativePageMode {
        case .inspect:
            if inspectReturnToWeb { return sxTab?.currentNavigationEntryID ?? 0 }
            return hasStartPageBackEntry ? NavigationSnapshotStore.startPageEntryID : 0
        case .history:
            if historyReturnToWeb { return sxTab?.currentNavigationEntryID ?? 0 }
            return hasStartPageBackEntry ? NavigationSnapshotStore.startPageEntryID : 0
        case .start:
            return startReturnToWeb ? (sxTab?.currentNavigationEntryID ?? 0) : 0
        case .none:
            if sxTab?.canGoBack == true { return sxTab?.previousNavigationEntryID ?? 0 }
            return hasStartPageBackEntry ? nativeEntryID(for: backNativePageMode) : 0
        }
    }
    var nextNavigationEntryID: Int {
        if showingStartPage {
            if sxTab?.canGoForward == true { return sxTab?.nextNavigationEntryID ?? 0 }
            if hasForwardFromStartPage { return sxTab?.currentNavigationEntryID ?? 0 }
            return 0
        }
        return sxTab?.nextNavigationEntryID ?? 0
    }
    var validNavigationEntryIDs: [Int] {
        sxTab?.validNavigationEntryIDs.map(\.intValue) ?? []
    }
    var pageBackgroundColor: NSColor? { showingStartPage ? nil : sxTab?.pageBackgroundColor }
    var fixedHeaderColor: NSColor? { showingStartPage ? nil : sxTab?.fixedHeaderColor }
    var connectionSecurityState: ConnectionSecurityState {
        if showingStartPage { return .internalPage }
        if let sxTab {
            return Self.mapConnectionSecurity(sxTab.connectionSecurityState)
        }
        return lastConnectionSecurityState
    }
    var connectionSecurityHost: String? {
        if showingStartPage { return nil }
        let raw = sxTab?.connectionSecurityHost ?? lastConnectionSecurityHost
        guard let raw, !raw.isEmpty else { return nil }
        let sanitized = PrivacyDomainClassifier.sanitizeHostForStorage(raw)
        return sanitized.isEmpty ? nil : sanitized
    }

    func setNativePageMode(_ mode: NativePageMode) {
        nativePageMode = mode
        if mode == .start {
            hasStartPageBackEntry = true
            hasForwardFromStartPage = false
        }
    }

    func setStartPageMode(_ enabled: Bool) {
        setNativePageMode(enabled ? .start : .none)
    }

    func bind(tab: SXBrowserTab?) {
        self.sxTab = tab
        tab?.automaticTopEdgeSamplingEnabled = true
        tab?.topEdgeSampleHeightPoints = SafariMetrics.topEdgeStripHeight
        if let tab {
            lastConnectionSecurityState = Self.mapConnectionSecurity(tab.connectionSecurityState)
            if let rawHost = tab.connectionSecurityHost {
                let sanitized = PrivacyDomainClassifier.sanitizeHostForStorage(rawHost)
                lastConnectionSecurityHost = sanitized.isEmpty ? nil : sanitized
            }
        }
    }

    func attach(to parentView: NSView) {
        if let sxTab {
            sxTab.attach(toParentView: parentView)
        } else {
            fallbackView.frame = parentView.bounds
            fallbackView.autoresizingMask = [.width, .height]
            parentView.addSubview(fallbackView)
        }
    }

    func detachFromParentView() {
        sxTab?.detachFromParentView()
    }

    func setTabActive(_ active: Bool) {
        sxTab?.setTabActive(active && !showingStartPage)
        contentView.isHidden = !(active && !showingStartPage)
    }

    func focusWebContent() {
        guard !showingStartPage else { return }
        sxTab?.focusWebContent()
    }

    func setPageTopInset(_ inset: CGFloat) {
        sxTab?.topContentInset = inset
    }

    func setPageZoomFactor(_ factor: Double) {
        sxTab?.setPageZoomFactor(factor)
    }

    @discardableResult
    func applyPinchMagnification(_ magnification: CGFloat, atPoint point: NSPoint, isPinching: Bool) -> CGFloat {
        guard !showingStartPage, let sxTab else { return 1.0 }
        return sxTab.applyPinchMagnification(magnification, at: point, isPinching: isPinching)
    }

    func resetPageScale() {
        sxTab?.resetPageScale()
    }

    func setPageOvershootScale(_ scale: CGFloat) {
        guard !showingStartPage else { return }
        sxTab?.setPageOvershootScale(scale)
    }

    func setPageOvershootScale(_ scale: CGFloat, anchorPoint: NSPoint) {
        guard !showingStartPage else { return }
        sxTab?.setPageOvershootScale(scale, anchorPoint: anchorPoint)
    }

    func endPageOvershoot() {
        sxTab?.endPageOvershoot()
    }

    func resetOverscroll() {
        sxTab?.resetOverscroll()
    }

    func setScrollInteractionActive(_ active: Bool) {
        sxTab?.setScrollInteractionActive(active)
    }

    func startDownload(at url: URL) {
        sxTab?.startDownload(at: url)
    }

    func captureSnapshot(completion: @escaping (NSImage?) -> Void) {
        guard let sxTab else {
            completion(nil)
            return
        }
        sxTab.captureSnapshot { image in
            completion(image ?? sxTab.cachedSnapshot)
        }
    }

    func setPreviewSnapshotPaused(_ paused: Bool) {
        sxTab?.isPreviewSnapshotPaused = paused
    }

    func loadURL(_ url: URL) {
        if let inspectSection = InspectPageURL.parse(url) {
            if case .inspect = nativePageMode {
                // Switching sections within chrome://inspect preserves existing back target.
            } else {
                inspectReturnToWeb = (nativePageMode == .none && sxTab?.currentURL != nil && sxTab?.currentURL?.absoluteString != "about:blank")
                if nativePageMode == .start {
                    hasStartPageBackEntry = true
                }
            }
            historyReturnToWeb = false
            startReturnToWeb = false
            nativePageMode = .inspect(inspectSection)
            hasForwardFromStartPage = false
            sxTab?.setTabActive(false)
            delegate?.tabEngine(self, didChangeURL: inspectSection.canonicalURL)
            delegate?.tabEngine(self, didChangeTitle: inspectSection.pageTitle)
            delegate?.tabEngine(self, didChangeLoading: false, canGoBack: canGoBack, canGoForward: canGoForward)
        } else if url.scheme == "safarium" {
            let isHist = (url.host == "history")
            if isHist {
                historyReturnToWeb = (nativePageMode == .none && sxTab?.currentURL != nil && sxTab?.currentURL?.absoluteString != "about:blank")
                if nativePageMode == .start {
                    hasStartPageBackEntry = true
                }
                nativePageMode = .history
            } else {
                historyReturnToWeb = false
                startReturnToWeb = (nativePageMode == .none && sxTab?.currentURL != nil && sxTab?.currentURL?.absoluteString != "about:blank")
                nativePageMode = .start
                hasStartPageBackEntry = true
            }
            inspectReturnToWeb = false
            hasForwardFromStartPage = false
            sxTab?.setTabActive(false)
            delegate?.tabEngine(self, didChangeURL: url)
            delegate?.tabEngine(self, didChangeTitle: isHist ? "History" : "Start Page")
            delegate?.tabEngine(self, didChangeLoading: false, canGoBack: canGoBack, canGoForward: canGoForward)
        } else {
            if nativePageMode != .none {
                hasStartPageBackEntry = true
                backNativePageMode = nativePageMode
            }
            historyReturnToWeb = false
            startReturnToWeb = false
            inspectReturnToWeb = false
            hasForwardFromStartPage = false
            nativePageMode = .none
            sxTab?.setTabActive(true)
            sxTab?.load(url)
            delegate?.tabEngine(self, didChangeURL: url)
            delegate?.tabEngine(self, didChangeLoading: true, canGoBack: canGoBack, canGoForward: canGoForward)
        }
    }

    func loadInput(_ input: String) {
        loadURL(URLInputNormalizer.normalize(input, isPrivate: isPrivate))
    }

    func prewarmOrigin(_ url: URL) {
        guard !isPrivate else { return }
        sxTab?.prewarmOrigin(url)
    }

    func goBack() {
        if case .inspect = nativePageMode {
            if inspectReturnToWeb {
                inspectReturnToWeb = false
                nativePageMode = .none
                hasForwardFromStartPage = false
                sxTab?.setTabActive(true)
                delegate?.tabEngine(self, didChangeURL: sxTab?.currentURL)
                delegate?.tabEngine(self, didChangeTitle: title)
                delegate?.tabEngine(self, didChangeLoading: sxTab?.isLoading ?? false, canGoBack: canGoBack, canGoForward: canGoForward)
                if let sample = lastTopEdgeColorSample {
                    delegate?.tabEngine(self, didSampleTopEdgeColor: sample)
                }
            } else if hasStartPageBackEntry {
                nativePageMode = .start
                hasForwardFromStartPage = false
                delegate?.tabEngine(self, didChangeURL: URL(string: "safarium://start"))
                delegate?.tabEngine(self, didChangeTitle: "Start Page")
                delegate?.tabEngine(self, didChangeLoading: false, canGoBack: canGoBack, canGoForward: canGoForward)
            }
            return
        }
        if nativePageMode == .history {
            if historyReturnToWeb {
                historyReturnToWeb = false
                nativePageMode = .none
                hasForwardFromStartPage = false
                sxTab?.setTabActive(true)
                delegate?.tabEngine(self, didChangeURL: sxTab?.currentURL)
                delegate?.tabEngine(self, didChangeTitle: title)
                delegate?.tabEngine(self, didChangeLoading: sxTab?.isLoading ?? false, canGoBack: canGoBack, canGoForward: canGoForward)
                if let sample = lastTopEdgeColorSample {
                    delegate?.tabEngine(self, didSampleTopEdgeColor: sample)
                }
            } else if hasStartPageBackEntry {
                nativePageMode = .start
                hasForwardFromStartPage = false
                delegate?.tabEngine(self, didChangeURL: URL(string: "safarium://start"))
                delegate?.tabEngine(self, didChangeTitle: "Start Page")
                delegate?.tabEngine(self, didChangeLoading: false, canGoBack: canGoBack, canGoForward: canGoForward)
            }
            return
        }
        if nativePageMode == .start, startReturnToWeb {
            startReturnToWeb = false
            nativePageMode = .none
            hasForwardFromStartPage = false
            sxTab?.setTabActive(true)
            delegate?.tabEngine(self, didChangeURL: sxTab?.currentURL)
            delegate?.tabEngine(self, didChangeTitle: title)
            delegate?.tabEngine(self, didChangeLoading: sxTab?.isLoading ?? false, canGoBack: canGoBack, canGoForward: canGoForward)
            if let sample = lastTopEdgeColorSample {
                delegate?.tabEngine(self, didSampleTopEdgeColor: sample)
            }
            return
        }
        guard !showingStartPage else { return }
        if sxTab?.canGoBack == true {
            sxTab?.goBack()
            return
        }
        if hasStartPageBackEntry {
            transitionBackToStartPage()
        }
    }

    func goForward() {
        if showingStartPage {
            if sxTab?.canGoForward == true {
                nativePageMode = .none
                hasForwardFromStartPage = false
                sxTab?.setTabActive(true)
                sxTab?.goForward()
                delegate?.tabEngine(self, didChangeURL: sxTab?.currentURL)
                delegate?.tabEngine(self, didChangeLoading: sxTab?.isLoading ?? false, canGoBack: canGoBack, canGoForward: canGoForward)
            } else if hasForwardFromStartPage {
                nativePageMode = .none
                hasForwardFromStartPage = false
                sxTab?.setTabActive(true)
                delegate?.tabEngine(self, didChangeURL: sxTab?.currentURL)
                delegate?.tabEngine(self, didChangeTitle: title)
                delegate?.tabEngine(self, didChangeLoading: sxTab?.isLoading ?? false, canGoBack: canGoBack, canGoForward: canGoForward)
                if let sample = lastTopEdgeColorSample {
                    delegate?.tabEngine(self, didSampleTopEdgeColor: sample)
                }
            }
            return
        }
        sxTab?.goForward()
    }

    private func transitionBackToStartPage() {
        let targetMode: NativePageMode
        switch backNativePageMode {
        case .history: targetMode = .history
        case .inspect(let sec): targetMode = .inspect(sec)
        default: targetMode = .start
        }
        nativePageMode = targetMode
        hasForwardFromStartPage = true
        sxTab?.setTabActive(false)
        let targetURL: URL?
        let targetTitle: String
        switch targetMode {
        case .history:
            targetURL = URL(string: "safarium://history")
            targetTitle = "History"
        case .inspect(let sec):
            targetURL = sec.canonicalURL
            targetTitle = sec.pageTitle
        default:
            targetURL = URL(string: "safarium://start")
            targetTitle = "Start Page"
        }
        delegate?.tabEngine(self, didChangeURL: targetURL)
        delegate?.tabEngine(self, didChangeTitle: targetTitle)
        delegate?.tabEngine(self, didChangeLoading: false, canGoBack: canGoBack, canGoForward: canGoForward)
    }
    func reload() {
        guard !showingStartPage else { return }
        sxTab?.reload()
    }
    func reloadIgnoringCache() {
        guard !showingStartPage else { return }
        sxTab?.reloadIgnoringCache()
    }
    func stopLoading() { sxTab?.stopLoading() }
    func findText(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        guard !showingStartPage else { return }
        sxTab?.findText(searchText, forward: forward, matchCase: matchCase, findNext: findNext)
    }
    func stopFinding(clearSelection: Bool) {
        sxTab?.stopFindingAndClearSelection(clearSelection)
    }
    func showDevTools() { sxTab?.showDevTools() }
    func executeJavaScript(_ script: String) {
        guard !showingStartPage else { return }
        sxTab?.executeJavaScript(script)
    }

    func executeJavaScriptInAllFrames(_ script: String) {
        guard !showingStartPage else { return }
        sxTab?.executeJavaScript(inAllFrames: script)
    }

    func executeJavaScriptInAuthPopup(_ script: String) {
        guard !showingStartPage else { return }
        sxTab?.executeJavaScript(inAuthPopup: script)
    }

    func closeAuthPopup() {
        sxTab?.closeAuthPopup()
    }
    func printPage() {
        guard !showingStartPage else { return }
        sxTab?.printPage()
    }
    func exportToPDF(atPath path: String, completion: @escaping (Bool) -> Void) {
        guard !showingStartPage, let sxTab else {
            completion(false)
            return
        }
        sxTab.exportToPDF(atPath: path) { ok in
            completion(ok)
        }
    }
    func getPageSource(completion: @escaping (String?) -> Void) {
        guard !showingStartPage, let sxTab else {
            completion(nil)
            return
        }
        sxTab.getPageSource { htmlSource in
            completion(htmlSource)
        }
    }
    func savePageWithPanel(for window: NSWindow?, completion: ((Bool, URL?) -> Void)? = nil) {
        guard !showingStartPage, let sxTab else {
            completion?(false, nil)
            return
        }
        sxTab.savePageWithPanel(for: window) { saved, savedURL in
            completion?(saved, savedURL)
        }
    }
    func setAudioMuted(_ muted: Bool) {
        sxTab?.setAudioMuted(muted)
    }
    var isAudioMuted: Bool {
        sxTab?.isAudioMuted() ?? false
    }
    func closeTab() { sxTab?.close() }

    func sampleTopEdgeColor(stripHeight: CGFloat, completion: @escaping (TopEdgeColorSample?) -> Void) {
        if showingStartPage {
            let sample = TopEdgeColorSample(color: NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1.0))
            lastTopEdgeColorSample = sample
            completion(sample)
            return
        }
        guard let sxTab else {
            completion(nil)
            return
        }
        sxTab.sampleTopEdgeColor(withStripHeightPoints: stripHeight) { [weak self] color, luminance in
            guard let color else {
                completion(nil)
                return
            }
            let sample = TopEdgeColorSample(color: color, relativeLuminance: luminance)
            self?.lastTopEdgeColorSample = sample
            completion(sample)
        }
    }

    // MARK: - SXBrowserTabDelegate

    func browserTab(_ tab: SXBrowserTab, didChange url: URL) {
        if url.absoluteString == "about:blank" {
            if showingStartPage { return }
            if hasStartPageBackEntry {
                transitionBackToStartPage()
                return
            }
        }
        if url.isWebURL || url.scheme == "chrome-extension" || url.scheme == "chrome" {
            nativePageMode = .none
            hasForwardFromStartPage = false
        }

        // Immediately sync tab icon on cross-host navigation (including BFCache back/forward where
        // Chromium may not re-emit OnFaviconURLChange): show cached icon for the new host right away
        // or clear to globe while fetching in background.
        let newHost = (url.host ?? "").lowercased()
        let isWebURL = (url.isWebURL) && !newHost.isEmpty
        if newHost != lastFaviconHost {
            lastFaviconHost = newHost
            if isWebURL && !self.isPrivate {
                let cached = FaviconCache.shared.cachedImage(forURLString: url.absoluteString)
                fallbackFavicon = cached
                if cached == nil {
                    let targetHost = newHost
                    FaviconCache.shared.fetchFavicon(forURLString: url.absoluteString) { [weak self] img in
                        guard let self,
                              !self.showingStartPage,
                              self.lastFaviconHost == targetHost,
                              self.sxTab?.favicon == nil,
                              let img else { return }
                        self.fallbackFavicon = img
                        self.delegate?.tabEngine(self, didUpdateFavicon: img)
                    }
                }
            } else {
                fallbackFavicon = nil
            }
        }

        delegate?.tabEngine(self, didChangeURL: url)
    }

    func browserTab(_ tab: SXBrowserTab, didChangeTitle title: String) {
        if showingStartPage { return }
        delegate?.tabEngine(self, didChangeTitle: title)
    }

    func browserTab(_ tab: SXBrowserTab, didChangeLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if showingStartPage {
            delegate?.tabEngine(self, didChangeLoading: false, canGoBack: self.canGoBack, canGoForward: self.canGoForward)
            return
        }
        delegate?.tabEngine(self, didChangeLoading: isLoading, canGoBack: self.canGoBack, canGoForward: self.canGoForward)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateProgress progress: Double) {
        if showingStartPage { return }
        delegate?.tabEngine(self, didUpdateProgress: progress)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateFavicon favicon: NSImage?) {
        if showingStartPage { return }
        if favicon != nil {
            fallbackFavicon = nil
        }
        delegate?.tabEngine(self, didUpdateFavicon: self.favicon)
    }

    func browserTab(_ tab: SXBrowserTab, didFailLoad failedURL: URL, errorCode: Int, errorText: String) {
        if showingStartPage { return }
        let err = BrowserPageLoadError(failedURL: failedURL, errorCode: errorCode, errorText: errorText)
        delegate?.tabEngine(self, didFailLoad: err)
    }

    func browserTab(_ tab: SXBrowserTab, didSampleTopEdgeColor color: NSColor, relativeLuminance: Double) {
        if showingStartPage { return }
        let sample = TopEdgeColorSample(color: color, relativeLuminance: relativeLuminance)
        lastTopEdgeColorSample = sample
        delegate?.tabEngine(self, didSampleTopEdgeColor: sample)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateFixedHeaderColor color: NSColor?) {
        if showingStartPage { return }
        delegate?.tabEngine(self, didUpdateFixedHeaderColor: color)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateNativeVideoID videoID: String, srcURL: String, rect: NSRect, visible: Bool, autoplay: Bool) {
        if showingStartPage { return }
        delegate?.tabEngine(self, didUpdateNativeVideo: videoID, srcURL: srcURL, rect: rect, visible: visible, autoplay: autoplay)
    }

    func browserTab(_ tab: SXBrowserTab, didReceiveAuthEventJSON jsonString: String) {
        if showingStartPage { return }
        delegate?.tabEngine(self, didReceiveAuthEventJSON: jsonString)
    }

    func browserTab(_ tab: SXBrowserTab, didOpenAuthPopupWith url: URL) {
        if showingStartPage { return }
        delegate?.tabEngine(self, didOpenAuthPopupWithURL: url)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateAuthPopupURL url: URL) {
        if showingStartPage { return }
        delegate?.tabEngine(self, didUpdateAuthPopupURL: url)
    }

    func browserTabDidCloseAuthPopup(_ tab: SXBrowserTab) {
        delegate?.tabEngineDidCloseAuthPopup(self)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateScrollY scrollY: CGFloat, contentHeight: CGFloat) {
        delegate?.tabEngine(self, didUpdateScrollY: scrollY, contentHeight: contentHeight)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdatePageScale pageScale: CGFloat, isPinching: Bool) {
        delegate?.tabEngine(self, didUpdatePageScale: pageScale, isPinching: isPinching)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateOverscrollY overscrollY: CGFloat, armed: Bool) {
        guard !showingStartPage else { return }
        delegate?.tabEngine(self, didUpdateOverscrollY: overscrollY, armed: armed)
    }

    func browserTabDidTriggerPullToRefresh(_ tab: SXBrowserTab) {
        guard !showingStartPage else { return }
        delegate?.tabEngineDidTriggerPullToRefresh(self)
    }

    func browserTab(_ tab: SXBrowserTab, didStartDownload download: SXDownloadItem) {
        delegate?.tabEngine(self, didStartDownload: Self.mapDownload(download))
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateDownload download: SXDownloadItem) {
        delegate?.tabEngine(self, didUpdateDownload: Self.mapDownload(download))
    }

    func browserTab(_ tab: SXBrowserTab, requestNewTabWith url: URL, userGesture: Bool) -> SXBrowserTab? {
        delegate?.tabEngine(self, didRequestNewTabWithURL: url)
        return nil
    }

    func browserTabDidRequestNavigateBack(_ tab: SXBrowserTab) {
        delegate?.tabEngineDidRequestNavigateBack(self)
    }

    func browserTabDidRequestNavigateForward(_ tab: SXBrowserTab) {
        delegate?.tabEngineDidRequestNavigateForward(self)
    }

    func browserTab(_ tab: SXBrowserTab, didRecord event: SXPrivacyEvent) {
        let eventType = PrivacyEventType(rawValue: event.eventType) ?? .trackerBlocked
        let category = PrivacyTrackerCategory(rawValue: event.category) ?? .other
        let pageHost = PrivacyDomainClassifier.sanitizeHostForStorage(event.pageHost)
        let trackerHost = PrivacyDomainClassifier.sanitizeHostForStorage(event.trackerHost)
        let entityDomain = PrivacyDomainClassifier.sanitizeHostForStorage(event.entityDomain)
        let ownerName = event.ownerName.isEmpty
            ? PrivacyDomainClassifier.displayOwner(entityDomain: entityDomain, rawOwner: "")
            : event.ownerName
        let mapped = PrivacyEvent(
            eventType: eventType,
            pageHost: pageHost,
            trackerHost: trackerHost,
            entityDomain: entityDomain,
            ownerName: ownerName,
            category: category,
            detail: event.detail,
            count: max(1, event.count),
            isPrivate: self.isPrivate || event.isPrivate,
            timestamp: event.timestamp > 0 ? Date(timeIntervalSince1970: event.timestamp) : Date()
        )
        delegate?.tabEngine(self, didRecordPrivacyEvent: mapped)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateNavigationEntryIDs currentID: Int, previousID: Int, nextID: Int, validEntryIDs validIDs: [NSNumber]) {
        let mappedValid = validIDs.map(\.intValue)
        delegate?.tabEngine(
            self,
            didUpdateNavigationEntryIDs: self.currentNavigationEntryID,
            previousID: self.previousNavigationEntryID,
            nextID: self.nextNavigationEntryID,
            validEntryIDs: mappedValid
        )
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateNavigationSnapshotData jpegData: Data, entryID: Int, logicalSize: NSSize, backingScale: CGFloat, backgroundColor: NSColor?) {
        guard !showingStartPage else { return }
        delegate?.tabEngine(
            self,
            didUpdateNavigationSnapshotData: jpegData,
            entryID: entryID,
            logicalSize: logicalSize,
            backingScale: backingScale,
            backgroundColor: backgroundColor
        )
    }

    func browserTab(_ tab: SXBrowserTab, didBecomeVisuallyReadyForNavigation fromBFCache: Bool) {
        guard !showingStartPage else { return }
        delegate?.tabEngine(self, didBecomeVisuallyReadyForNavigation: fromBFCache)
    }

    func browserTab(_ tab: SXBrowserTab, didUpdateConnectionSecurity state: SXConnectionSecurityState, host: String) {
        let mapped = Self.mapConnectionSecurity(state)
        let sanitizedHost = PrivacyDomainClassifier.sanitizeHostForStorage(host)
        lastConnectionSecurityState = mapped
        lastConnectionSecurityHost = sanitizedHost.isEmpty ? nil : sanitizedHost
        if showingStartPage { return }
        delegate?.tabEngine(self, didUpdateConnectionSecurity: mapped, host: sanitizedHost)
    }

    private static func mapConnectionSecurity(_ state: SXConnectionSecurityState) -> ConnectionSecurityState {
        switch state {
        case .internal: return .internalPage
        case .secureHTTPS: return .secureHTTPS
        case .upgradedHTTPS: return .upgradedHTTPS
        case .insecureHTTP: return .insecureHTTP
        case .certificateError: return .certificateError
        @unknown default: return .internalPage
        }
    }

    private static func mapDownload(_ d: SXDownloadItem) -> BrowserDownloadItem {
        BrowserDownloadItem(
            id: d.downloadID,
            suggestedFileName: d.suggestedFileName,
            fullPath: d.fullPath,
            url: d.url,
            totalBytes: d.totalBytes,
            receivedBytes: d.receivedBytes,
            percentComplete: d.percentComplete,
            isInProgress: d.isInProgress,
            isComplete: d.isComplete,
            isCanceled: d.isCanceled,
            isPaused: d.isPaused
        )
    }
}

#else

enum ChromiumRuntimeBootstrap {
    static func installHooksIfAvailable() {}
}

/// Ready-to-link ChromiumBrowserEngine placeholder compiled when `BrowserCore` dylib is not yet linked.
final class ChromiumBrowserEngine: BrowserEngine {
    let engineName = "Chromium (Pending BrowserCore Link)"
    let isRealChromium = false

    func start() throws {
        throw NSError(
            domain: "com.safarium.engine",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "BrowserCore dylib not linked yet; falling back to MockBrowserEngine."]
        )
    }

    func shutdown() {}

    func createTab(initialURL: URL?, parentView: NSView?, isPrivate: Bool = false) -> BrowserTabEngine {
        return MockBrowserEngine().createTab(initialURL: initialURL, parentView: parentView, isPrivate: isPrivate)
    }
}

#endif
