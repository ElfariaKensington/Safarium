import AppKit

/// Rich interactive native AppKit MockBrowserEngine for Phase 1 UI verification.
/// Renders realistic scrollable pages with distinct top-edge surface colors (dark navy, vibrant red,
/// pure white, warm cream, purple-cyan gradient, Safari 27 Start Page wallpaper) and performs
/// TRUE 3pt top-strip bitmap pixel sampling from the rendered view (never reading `<meta theme-color>`).
final class MockBrowserEngine: BrowserEngine {
    let engineName = "MockBrowserEngine (Phase 1 Interactive)"
    let isRealChromium = false

    var syncedPrivacyPolicies: [[String: Any]] = []
    var allowedInsecureHTTPHosts: [String] = []
    var mockWebsiteDataRecords: [WebsiteDataRecord] = []
    var removedWebsiteDataDomains: [[String]] = []

    func start() throws {}
    func shutdown() {}

    func syncPrivacyPolicy(_ policy: [String: Any]) {
        syncedPrivacyPolicies.append(policy)
    }

    func allowInsecureHTTP(forHost host: String) {
        allowedInsecureHTTPHosts.append(host)
    }

    func fetchWebsiteDataRecords(completion: @escaping ([WebsiteDataRecord]) -> Void) {
        completion(mockWebsiteDataRecords)
    }

    func removeWebsiteData(forDomains domains: [String], completion: @escaping (Bool) -> Void) {
        removedWebsiteDataDomains.append(domains)
        let normalizedSet = Set(domains.map { PrivacyDomainClassifier.normalizedHost($0) }.filter { !$0.isEmpty })
        let rawSet = Set(domains.map { $0.lowercased() })
        mockWebsiteDataRecords.removeAll { record in
            let norm = PrivacyDomainClassifier.normalizedHost(record.domain)
            return normalizedSet.contains(norm) || rawSet.contains(record.domain.lowercased())
        }
        completion(true)
    }

    func clearWebsiteData(completion: @escaping (Bool) -> Void) {
        mockWebsiteDataRecords.removeAll()
        completion(true)
    }

    func createTab(initialURL: URL?, parentView: NSView?, isPrivate: Bool = false) -> BrowserTabEngine {
        let tab = MockBrowserTab()
        tab.isPrivate = isPrivate
        if let parentView {
            tab.attach(to: parentView)
        }
        if let url = initialURL {
            tab.loadURL(url)
        } else {
            tab.loadURL(URL(string: "https://gemini.google.com")!)
        }
        return tab
    }
}

// MARK: - Demo Page Catalogue

struct MockPagePreset {
    enum SurfaceStyle {
        case solid(NSColor)
        case horizontalGradient(NSColor, NSColor)
        case verticalGradient(NSColor, NSColor)
        case wallpaper(String, fallback: NSColor)
    }

    let urlString: String
    let title: String
    let badgeLetter: String
    let badgeColor: NSColor
    let heroTitle: String
    let heroSubtitle: String
    let heroHeight: CGFloat
    let heroStyle: SurfaceStyle
    let heroTextLight: Bool
    let bodyBackground: NSColor
    let bodyTextColor: NSColor
    let cardBackground: NSColor
    let accentColor: NSColor
    let sections: [(heading: String, body: String, tag: String)]
    let quickLinks: [(label: String, url: String)]

    static let allPresets: [MockPagePreset] = [
        MockPagePreset(
            urlString: "https://gemini.google.com",
            title: "Gemini",
            badgeLetter: "G",
            badgeColor: NSColor(srgbRed: 0.28, green: 0.56, blue: 0.99, alpha: 1.0),
            heroTitle: "Deep Midnight Navy Surface",
            heroSubtitle: "Scroll down to watch the Liquid Glass toolbar adapt live as the top 3pt surface transitions from deep navy (#0B1026) into softer slate.",
            heroHeight: 400,
            heroStyle: .verticalGradient(
                NSColor(srgbRed: 0.043, green: 0.063, blue: 0.149, alpha: 1.0),
                NSColor(srgbRed: 0.09, green: 0.13, blue: 0.27, alpha: 1.0)
            ),
            heroTextLight: true,
            bodyBackground: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1.0),
            bodyTextColor: NSColor(srgbRed: 0.09, green: 0.11, blue: 0.16, alpha: 1.0),
            cardBackground: .white,
            accentColor: NSColor(srgbRed: 0.30, green: 0.56, blue: 1.0, alpha: 1.0),
            sections: [
                ("True Pixel Top-Edge Sampling", "Safarium samples a 3pt strip from the top of the rendered engine surface—never <meta name=\"theme-color\">—so scrolling from this deep navy header into the light body smoothly flips toolbar tint and icon contrast with hysteresis.", "Adaptive Chrome"),
                ("Native macOS 27 Liquid Glass", "Toolbar clusters use real NSGlassEffectView(effectIsInteractive = true) inside NSGlassEffectContainerView with NSBackgroundExtensionView extending the page behind the 52pt titlebar.", "AppKit 27.3"),
                ("HDR Active Tab Luminous Highlight", "The active unified tab pill applies linearExposure > 1.0 via NSColor + CALayer.preferredDynamicRange(.constrainedHigh) and an EDR CAMetalLayer specular rim scaled to your display's headroom.", "XDR / EDR")
            ],
            quickLinks: [
                ("Apple (White)", "https://apple.com"),
                ("YouTube (Red)", "https://youtube.com"),
                ("Stripe (Gradient)", "https://stripe.com"),
                ("Hacker News (Cream)", "https://news.ycombinator.com"),
                ("Start Page", "safarium://start")
            ]
        ),
        MockPagePreset(
            urlString: "https://apple.com",
            title: "Apple",
            badgeLetter: "A",
            badgeColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0),
            heroTitle: "Pure White Editorial Canvas",
            heroSubtitle: "High-luminance white top surface (#FFFFFF) triggers crisp dark toolbar glyphs, subtle translucent glass frost, and HDR white active tab illumination.",
            heroHeight: 360,
            heroStyle: .solid(.white),
            heroTextLight: false,
            bodyBackground: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0),
            bodyTextColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0),
            cardBackground: .white,
            accentColor: NSColor(srgbRed: 0.0, green: 0.44, blue: 0.89, alpha: 1.0),
            sections: [
                ("MacBook Pro — XDR Display", "Extended Dynamic Range headroom up to 16x lets active Safari 27 tabs lift gently above SDR paper white without harsh glare.", "Hardware"),
                ("Zero-Flicker Hysteresis", "Relative luminance uses a 0.42 / 0.52 hysteresis band so scrolling across product imagery never causes toolbar icons to strobe.", "Contrast"),
                ("Background Extension Bleed", "Page content extends seamlessly behind the 52pt toolbar and collapsible 260pt sidebar using macOS 27 NSBackgroundExtensionView.", "Layout")
            ],
            quickLinks: [
                ("Gemini (Navy)", "https://gemini.google.com"),
                ("YouTube (Red)", "https://youtube.com"),
                ("Stripe (Gradient)", "https://stripe.com"),
                ("Hacker News (Cream)", "https://news.ycombinator.com"),
                ("Start Page", "safarium://start")
            ]
        ),
        MockPagePreset(
            urlString: "https://youtube.com",
            title: "YouTube",
            badgeLetter: "Y",
            badgeColor: NSColor(srgbRed: 0.84, green: 0.07, blue: 0.10, alpha: 1.0),
            heroTitle: "Vibrant Crimson Red Hero",
            heroSubtitle: "Saturated crimson (#CC1116) tints the Liquid Glass toolbar red with crisp white icons. Scroll down into the dark theater feed (#0F0F12) to see smooth tint interpolation!",
            heroHeight: 380,
            heroStyle: .verticalGradient(
                NSColor(srgbRed: 0.80, green: 0.06, blue: 0.09, alpha: 1.0),
                NSColor(srgbRed: 0.55, green: 0.03, blue: 0.07, alpha: 1.0)
            ),
            heroTextLight: true,
            bodyBackground: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1.0),
            bodyTextColor: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.96, alpha: 1.0),
            cardBackground: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0),
            accentColor: NSColor(srgbRed: 1.0, green: 0.22, blue: 0.25, alpha: 1.0),
            sections: [
                ("4K HDR Playback Pipeline", "Built for real Chromium chrome/ runtime integration with native hardware decode and zero anti-bot flags.", "Media"),
                ("Scroll-Driven Surface Shift", "As the crimson masthead scrolls past y = 380pt, the top 3pt sampler reads the dark theater canvas and cross-fades the toolbar tint smoothly.", "Live Sample"),
                ("Compact Unified Pill", "36pt capsule height, 18pt corner radius, and 38x38pt interactive glass controls matching measured macOS 27.3 Safari metrics.", "1:1 Metrics")
            ],
            quickLinks: [
                ("Gemini (Navy)", "https://gemini.google.com"),
                ("Apple (White)", "https://apple.com"),
                ("Stripe (Gradient)", "https://stripe.com"),
                ("Hacker News (Cream)", "https://news.ycombinator.com"),
                ("Start Page", "safarium://start")
            ]
        ),
        MockPagePreset(
            urlString: "https://stripe.com",
            title: "Stripe",
            badgeLetter: "S",
            badgeColor: NSColor(srgbRed: 0.39, green: 0.36, blue: 1.0, alpha: 1.0),
            heroTitle: "Prismatic Gradient Masthead",
            heroSubtitle: "Horizontal violet-to-cyan gradient (#5B35F5 -> #00C6FF) averages across the top 3pt strip and transitions cleanly to crisp white below the fold.",
            heroHeight: 400,
            heroStyle: .horizontalGradient(
                NSColor(srgbRed: 0.36, green: 0.21, blue: 0.96, alpha: 1.0),
                NSColor(srgbRed: 0.0, green: 0.78, blue: 1.0, alpha: 1.0)
            ),
            heroTextLight: true,
            bodyBackground: .white,
            bodyTextColor: NSColor(srgbRed: 0.07, green: 0.11, blue: 0.22, alpha: 1.0),
            cardBackground: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1.0),
            accentColor: NSColor(srgbRed: 0.39, green: 0.36, blue: 1.0, alpha: 1.0),
            sections: [
                ("Gradient Average Sampling", "Multi-column sampling across the 3pt top strip computes a balanced representative tint without oversaturating glass refraction.", "Sampling"),
                ("Scroll Contrast Flip", "Scroll past this purple-cyan banner to watch toolbar buttons and URL text switch cleanly from light ink to dark ink.", "Hysteresis"),
                ("Engine-Agnostic Architecture", "Swap MockBrowserEngine for ChromiumBrowserEngine with zero UI changes via BrowserEngine protocol.", "Modular")
            ],
            quickLinks: [
                ("Gemini (Navy)", "https://gemini.google.com"),
                ("Apple (White)", "https://apple.com"),
                ("YouTube (Red)", "https://youtube.com"),
                ("Hacker News (Cream)", "https://news.ycombinator.com"),
                ("Start Page", "safarium://start")
            ]
        ),
        MockPagePreset(
            urlString: "https://news.ycombinator.com",
            title: "Hacker News",
            badgeLetter: "Y",
            badgeColor: NSColor(srgbRed: 1.0, green: 0.40, blue: 0.0, alpha: 1.0),
            heroTitle: "Warm Cream Editorial Surface",
            heroSubtitle: "Warm parchment cream (#F6F6EF) with bright orange accents—testing subtle warm tinting over light glass with dark high-contrast icons.",
            heroHeight: 330,
            heroStyle: .solid(NSColor(srgbRed: 0.965, green: 0.965, blue: 0.937, alpha: 1.0)),
            heroTextLight: false,
            bodyBackground: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.937, alpha: 1.0),
            bodyTextColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.11, alpha: 1.0),
            cardBackground: NSColor(srgbRed: 0.99, green: 0.99, blue: 0.97, alpha: 1.0),
            accentColor: NSColor(srgbRed: 1.0, green: 0.40, blue: 0.0, alpha: 1.0),
            sections: [
                ("1. Show HN: Safarium — macOS 27 Native AppKit Shell over Chromium", "428 points by safarium 2 hours ago | 137 comments", "Top Story"),
                ("2. Measuring NSGlassEffectView & EDR Headroom on macOS 27.3", "312 points by inspector 4 hours ago | 89 comments", "Systems"),
                ("3. Why Top-Edge Pixel Sampling Beats <meta theme-color>", "264 points by shellbuilder 5 hours ago | 112 comments", "Design")
            ],
            quickLinks: [
                ("Gemini (Navy)", "https://gemini.google.com"),
                ("Apple (White)", "https://apple.com"),
                ("YouTube (Red)", "https://youtube.com"),
                ("Stripe (Gradient)", "https://stripe.com"),
                ("Start Page", "safarium://start")
            ]
        ),
        MockPagePreset(
            urlString: "safarium://start",
            title: "Start Page",
            badgeLetter: "★",
            badgeColor: NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),
            heroTitle: "Favorites",
            heroSubtitle: "Safarium Start Page with macOS 27.3 wallpaper & extracted Safari bookmarks.",
            heroHeight: 960,
            heroStyle: .wallpaper("safari-27-blue", fallback: NSColor(srgbRed: 0.14, green: 0.32, blue: 0.62, alpha: 1.0)),
            heroTextLight: true,
            bodyBackground: NSColor(srgbRed: 0.14, green: 0.32, blue: 0.62, alpha: 1.0),
            bodyTextColor: .white,
            cardBackground: NSColor.white.withAlphaComponent(0.18),
            accentColor: NSColor(srgbRed: 0.35, green: 0.72, blue: 1.0, alpha: 1.0),
            sections: [],
            quickLinks: [
                ("Gemini (Navy)", "https://gemini.google.com"),
                ("Apple (White)", "https://apple.com"),
                ("YouTube (Red)", "https://youtube.com"),
                ("Stripe (Gradient)", "https://stripe.com"),
                ("Hacker News (Cream)", "https://news.ycombinator.com")
            ]
        )
    ]

    static func preset(for url: URL) -> MockPagePreset {
        let lower = url.absoluteString.lowercased()
        if lower.contains("safarium://start") { return allPresets[5] }
        if lower.contains("gemini") { return allPresets[0] }
        if lower.contains("apple.com") { return allPresets[1] }
        if lower.contains("youtube") { return allPresets[2] }
        if lower.contains("stripe") { return allPresets[3] }
        if (url.host ?? "").lowercased().contains("ycombinator") { return allPresets[4] }

        // Dynamic generated preset for arbitrary URLs entered by the user
        let host = URLInputNormalizer.displayDomain(for: url)
        let hash = abs(host.hashValue)
        let hue = CGFloat(hash % 360) / 360.0
        let heroColor = NSColor(hue: hue, saturation: 0.62, brightness: 0.36, alpha: 1.0)
        return MockPagePreset(
            urlString: url.absoluteString,
            title: host.capitalized,
            badgeLetter: String(host.prefix(1)).uppercased(),
            badgeColor: heroColor,
            heroTitle: host,
            heroSubtitle: "Loaded \(url.absoluteString) in Phase 1 MockBrowserEngine. Ready for live Chromium swap via BrowserCore.",
            heroHeight: 360,
            heroStyle: .verticalGradient(heroColor, heroColor.blended(withFraction: 0.28, of: .black) ?? heroColor),
            heroTextLight: true,
            bodyBackground: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1.0),
            bodyTextColor: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1.0),
            cardBackground: .white,
            accentColor: heroColor,
            sections: [
                ("Interactive Navigation", "Back, Forward, Reload, URL bar editing, and real top-edge 3pt pixel sampling all run live on this tab.", "Phase 1"),
                ("Switch Test Surfaces", "Use the quick pills above or the Sidebar to test Dark Navy, Pure White, Crimson Red, Warm Cream, Gradient, and Start Page.", "Demo")
            ],
            quickLinks: [
                ("Gemini (Navy)", "https://gemini.google.com"),
                ("Apple (White)", "https://apple.com"),
                ("YouTube (Red)", "https://youtube.com"),
                ("Stripe (Gradient)", "https://stripe.com"),
                ("Hacker News (Cream)", "https://news.ycombinator.com")
            ]
        )
    }
}

// MARK: - Mock Browser Tab

final class MockBrowserTab: NSObject, BrowserTabEngine {
    let tabID: String = UUID().uuidString
    weak var delegate: BrowserTabEngineDelegate?
    var isPrivate = false

    let contentView: NSView
    private let scrollView: NSScrollView
    private let documentView: MockPageDocumentView

    private(set) var currentURL: URL?
    private(set) var title: String = "Start Page"
    private(set) var isLoading: Bool = false
    private(set) var estimatedProgress: Double = 1.0
    private(set) var favicon: NSImage?
    private(set) var scrollY: CGFloat = 0
    private(set) var contentHeight: CGFloat = 1400
    private(set) var pageScale: CGFloat = 1.0
    private(set) var lastTopEdgeColorSample: TopEdgeColorSample?
    private(set) var connectionSecurityState: ConnectionSecurityState = .internalPage
    private(set) var connectionSecurityHost: String?

    private var history: [URL] = []
    private var historyIndex: Int = -1
    private var sampleDebounceWorkItem: DispatchWorkItem?
    private var loadWorkItem: DispatchWorkItem?
    var simulatedLoadDelay: TimeInterval = 0.12
    var mockCachedSnapshot: NSImage?
    private(set) var recordedPrewarmedURLs: [URL] = []

    var cachedSnapshot: NSImage? { mockCachedSnapshot }

    private func entryID(forHistorySlot slot: Int) -> Int {
        guard slot >= 0, slot < history.count else { return 0 }
        let u = history[slot]
        if InspectPageURL.isInspectURL(u) { return NavigationSnapshotStore.inspectPageEntryID }
        if u.scheme?.lowercased() == "safarium" {
            return u.host?.lowercased() == "history"
                ? NavigationSnapshotStore.historyPageEntryID
                : NavigationSnapshotStore.startPageEntryID
        }
        var hasher = Hasher()
        hasher.combine(slot)
        hasher.combine(u.absoluteString)
        return abs(hasher.finalize() | 1)
    }

    var currentNavigationEntryID: Int { entryID(forHistorySlot: historyIndex) }
    var previousNavigationEntryID: Int { entryID(forHistorySlot: historyIndex - 1) }
    var nextNavigationEntryID: Int { entryID(forHistorySlot: historyIndex + 1) }
    var validNavigationEntryIDs: [Int] {
        (0..<history.count).map { entryID(forHistorySlot: $0) }.filter { $0 > 0 }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    override init() {
        self.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760))
        self.scrollView = NSScrollView(frame: contentView.bounds)
        self.documentView = MockPageDocumentView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        super.init()

        contentView.wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.documentView = documentView

        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: contentView
        )
        contentView.postsFrameChangedNotifications = true

        documentView.onNavigate = { [weak self] urlString in
            if let url = URL(string: urlString) {
                self?.loadURL(url)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func loadInput(_ input: String) {
        loadURL(URLInputNormalizer.normalize(input, isPrivate: isPrivate))
    }

    func prewarmOrigin(_ url: URL) {
        guard !isPrivate else { return }
        recordedPrewarmedURLs.append(url)
    }

    func loadURL(_ url: URL) {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        if history.last != url {
            history.append(url)
            historyIndex = history.count - 1
        }
        navigateToCurrent(url: url, fromHistory: false)
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigateToCurrent(url: history[historyIndex], fromHistory: true)
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigateToCurrent(url: history[historyIndex], fromHistory: true)
    }

    func reload() {
        guard let url = currentURL else { return }
        navigateToCurrent(url: url)
    }

    func stopLoading() {
        loadWorkItem?.cancel()
        isLoading = false
        estimatedProgress = 1.0
        delegate?.tabEngine(self, didChangeLoading: false, canGoBack: canGoBack, canGoForward: canGoForward)
        delegate?.tabEngine(self, didUpdateProgress: 1.0)
    }

    let mockAuthPopupView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 500))
    var mockHasActiveAuthPopup: Bool = false
    var mockActiveAuthPopupURL: URL? = nil
    private(set) var recordedScripts: [String] = []
    private(set) var recordedAuthPopupCloseCount: Int = 0

    var authPopupContainerView: NSView? { mockAuthPopupView }
    var hasActiveAuthPopup: Bool { mockHasActiveAuthPopup }
    var activeAuthPopupURL: URL? { mockActiveAuthPopupURL }

    func executeJavaScript(_ script: String) {
        recordedScripts.append(script)
    }

    func executeJavaScriptInAllFrames(_ script: String) {
        recordedScripts.append(script)
    }

    func executeJavaScriptInAuthPopup(_ script: String) {
        recordedScripts.append(script)
    }

    func closeAuthPopup() {
        mockHasActiveAuthPopup = false
        mockActiveAuthPopupURL = nil
        recordedAuthPopupCloseCount += 1
    }

    func clearRecordedScripts() {
        recordedScripts.removeAll()
    }

    func closeTab() {
        loadWorkItem?.cancel()
        sampleDebounceWorkItem?.cancel()
        contentView.removeFromSuperview()
    }

    func simulatePrivacyEvent(_ event: PrivacyEvent) {
        let effective = PrivacyEvent(
            id: event.id,
            eventType: event.eventType,
            pageHost: event.pageHost,
            trackerHost: event.trackerHost,
            entityDomain: event.entityDomain,
            ownerName: event.ownerName,
            category: event.category,
            detail: event.detail,
            count: event.count,
            isPrivate: isPrivate || event.isPrivate,
            timestamp: event.timestamp
        )
        delegate?.tabEngine(self, didRecordPrivacyEvent: effective)
    }

    func simulateConnectionSecurity(_ state: ConnectionSecurityState, host: String) {
        let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(host)
        connectionSecurityState = state
        connectionSecurityHost = cleanHost.isEmpty ? nil : cleanHost
        delegate?.tabEngine(self, didUpdateConnectionSecurity: state, host: cleanHost)
    }

    private func navigateToCurrent(url: URL, fromHistory: Bool = false) {
        loadWorkItem?.cancel()
        currentURL = url
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "https" {
            let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(url.host ?? "")
            connectionSecurityState = .secureHTTPS
            connectionSecurityHost = cleanHost.isEmpty ? nil : cleanHost
        } else if scheme == "http" {
            let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(url.host ?? "")
            connectionSecurityState = .insecureHTTP
            connectionSecurityHost = cleanHost.isEmpty ? nil : cleanHost
        } else {
            connectionSecurityState = .internalPage
            connectionSecurityHost = nil
        }
        let preset = MockPagePreset.preset(for: url)
        title = preset.title
        favicon = Self.makeFavicon(letter: preset.badgeLetter, color: preset.badgeColor)
        isLoading = !isNativeInternalPage
        estimatedProgress = isNativeInternalPage ? 1.0 : 0.25

        delegate?.tabEngine(
            self,
            didUpdateNavigationEntryIDs: currentNavigationEntryID,
            previousID: previousNavigationEntryID,
            nextID: nextNavigationEntryID,
            validEntryIDs: validNavigationEntryIDs
        )
        delegate?.tabEngine(self, didChangeURL: url)
        delegate?.tabEngine(self, didUpdateConnectionSecurity: connectionSecurityState, host: connectionSecurityHost ?? "")
        delegate?.tabEngine(self, didChangeTitle: title)
        delegate?.tabEngine(self, didUpdateFavicon: favicon)
        delegate?.tabEngine(self, didChangeLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
        delegate?.tabEngine(self, didUpdateProgress: estimatedProgress)

        scrollView.backgroundColor = preset.bodyBackground
        documentView.configure(with: preset, viewportWidth: max(contentView.bounds.width, 820))
        contentHeight = documentView.frame.height
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollY = 0

        if isNativeInternalPage {
            delegate?.tabEngine(self, didBecomeVisuallyReadyForNavigation: true)
            return
        }

        let delay = max(0.01, simulatedLoadDelay)
        let finishItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.estimatedProgress = 1.0
            self.scheduleTopEdgeSample(immediate: true)
            self.delegate?.tabEngine(self, didBecomeVisuallyReadyForNavigation: fromHistory)
            self.delegate?.tabEngine(self, didUpdateProgress: 1.0)
            self.delegate?.tabEngine(self, didChangeLoading: false, canGoBack: self.canGoBack, canGoForward: self.canGoForward)
        }
        loadWorkItem = finishItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: finishItem)
    }

    @objc private func handleScrollBoundsDidChange() {
        let offsetY = scrollView.contentView.bounds.origin.y
        scrollY = offsetY
        contentHeight = documentView.frame.height
        delegate?.tabEngine(self, didUpdateScrollY: scrollY, contentHeight: contentHeight)
        scheduleTopEdgeSample(immediate: false)
    }

    @objc private func handleFrameDidChange() {
        let width = max(contentView.bounds.width, 400)
        if abs(documentView.frame.width - width) > 1.0 {
            documentView.updateWidth(width)
            contentHeight = documentView.frame.height
        }
        scheduleTopEdgeSample(immediate: false)
    }

    private func scheduleTopEdgeSample(immediate: Bool) {
        sampleDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sampleTopEdgeColor(stripHeight: SafariMetrics.topEdgeStripHeight) { [weak self] sample in
                guard let self, let sample else { return }
                self.lastTopEdgeColorSample = sample
                self.delegate?.tabEngine(self, didSampleTopEdgeColor: sample)
            }
        }
        sampleDebounceWorkItem = work
        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + SafariMetrics.topEdgeSampleDebounceInterval, execute: work)
        }
    }

    /// Performs true rendered pixel readback of a 2–4pt strip from the top of `scrollView.contentView`.
    /// Strictly ignores any page metadata (`<meta name="theme-color">`).
    func sampleTopEdgeColor(stripHeight: CGFloat, completion: @escaping (TopEdgeColorSample?) -> Void) {
        let clampedStrip = max(2.0, min(4.0, stripHeight))
        let bounds = scrollView.bounds
        guard bounds.width > 8, bounds.height > clampedStrip else {
            // View not laid out yet; return deterministic top surface color from layout
            if let fallback = documentView.topSurfaceFallbackColor(atScrollY: scrollY) {
                completion(TopEdgeColorSample(color: fallback))
            } else {
                completion(nil)
            }
            return
        }

        // Flipped clipView: top strip in scrollView coordinates
        let sampleRect = scrollView.isFlipped
            ? NSRect(x: 0, y: 0, width: bounds.width, height: clampedStrip)
            : NSRect(x: 0, y: bounds.height - clampedStrip, width: bounds.width, height: clampedStrip)

        guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: sampleRect) else {
            if let fallback = documentView.topSurfaceFallbackColor(atScrollY: scrollY) {
                completion(TopEdgeColorSample(color: fallback))
            } else {
                completion(nil)
            }
            return
        }

        scrollView.cacheDisplay(in: sampleRect, to: rep)

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else {
            completion(nil)
            return
        }

        // Sample 24 evenly spaced horizontal columns across the strip for fast, accurate average sRGB
        let cols = min(24, width)
        let stepX = max(1, width / cols)
        var rSum: Double = 0
        var gSum: Double = 0
        var bSum: Double = 0
        var count: Double = 0

        for y in 0..<height {
            var x = stepX / 2
            while x < width {
                if let pixelColor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    rSum += Double(pixelColor.redComponent)
                    gSum += Double(pixelColor.greenComponent)
                    bSum += Double(pixelColor.blueComponent)
                    count += 1
                }
                x += stepX
            }
        }

        guard count > 0 else {
            completion(nil)
            return
        }

        let avgColor = NSColor(
            srgbRed: CGFloat(rSum / count),
            green: CGFloat(gSum / count),
            blue: CGFloat(bSum / count),
            alpha: 1.0
        )
        completion(TopEdgeColorSample(color: avgColor))
    }

    private static func makeFavicon(letter: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        color.setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: letter, attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(x: (size.width - strSize.width) / 2, y: (size.height - strSize.height) / 2))
        img.unlockFocus()
        return img
    }
}

// MARK: - Scrollable Interactive Mock Document View

final class MockPageDocumentView: NSView {
    override var isFlipped: Bool { true }

    var onNavigate: ((String) -> Void)?
    private var preset: MockPagePreset = MockPagePreset.allPresets[0]
    private var wallpaperImage: NSImage?
    private var linkButtons: [NSButton] = []

    func configure(with preset: MockPagePreset, viewportWidth: CGFloat) {
        self.preset = preset
        if case let .wallpaper(name, _) = preset.heroStyle {
            wallpaperImage = AssetLoader.shared.wallpaper(named: name, thumbnail: true)
        } else {
            wallpaperImage = nil
        }
        rebuildContent(width: viewportWidth)
    }

    func updateWidth(_ width: CGFloat) {
        rebuildContent(width: width)
    }

    func topSurfaceFallbackColor(atScrollY scrollY: CGFloat) -> NSColor? {
        if scrollY >= preset.heroHeight {
            return preset.bodyBackground
        }
        switch preset.heroStyle {
        case .solid(let c): return c
        case .verticalGradient(let top, _): return top
        case .horizontalGradient(let left, let right): return left.blended(withFraction: 0.5, of: right) ?? left
        case .wallpaper(_, let fallback): return fallback
        }
    }

    private func rebuildContent(width: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        linkButtons.removeAll()

        let isStartPage = preset.urlString == "safarium://start"
        let totalHeight: CGFloat = isStartPage ? max(860, preset.heroHeight) : (preset.heroHeight + 920)
        frame = NSRect(x: 0, y: 0, width: width, height: totalHeight)

        let maxContentW = min(width - 96, 860)
        let originX = (width - maxContentW) / 2

        if isStartPage {
            buildStartPage(originX: originX, contentWidth: maxContentW)
        } else {
            buildArticlePage(originX: originX, contentWidth: maxContentW)
        }
        needsDisplay = true
    }

    private func buildStartPage(originX: CGFloat, contentWidth: CGFloat) {
        let titleLabel = NSTextField(labelWithString: "Favorites")
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        titleLabel.frame = NSRect(x: originX, y: 108, width: contentWidth, height: 30)
        addSubview(titleLabel)

        let favorites = AssetLoader.shared.favorites()
        let cols = max(4, min(6, Int(contentWidth / 128)))
        let tileW: CGFloat = 104
        let tileH: CGFloat = 104
        let gapX: CGFloat = 20
        let gapY: CGFloat = 22

        for (idx, fav) in favorites.prefix(12).enumerated() {
            let row = idx / cols
            let col = idx % cols
            let x = originX + CGFloat(col) * (tileW + gapX)
            let y = 156 + CGFloat(row) * (tileH + gapY)

            let card = FlippedMockCardView(frame: NSRect(x: x, y: y, width: tileW, height: tileH))
            card.wantsLayer = true

            let tileBtn = NSButton(frame: NSRect(x: 16, y: 0, width: 72, height: 72))
            tileBtn.isBordered = false
            tileBtn.wantsLayer = true
            let bg = NSColor(hexString: fav.color ?? "#007AFF") ?? .systemBlue
            tileBtn.layer?.backgroundColor = bg.withAlphaComponent(0.88).cgColor
            tileBtn.layer?.cornerRadius = 18
            tileBtn.layer?.cornerCurve = .continuous
            tileBtn.layer?.borderWidth = 0.5
            tileBtn.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
            tileBtn.title = String(fav.title.prefix(1)).uppercased()
            tileBtn.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
            tileBtn.contentTintColor = .white
            tileBtn.toolTip = fav.url
            tileBtn.target = self
            tileBtn.action = #selector(linkButtonClicked(_:))
            card.addSubview(tileBtn)

            let lbl = NSTextField(labelWithString: fav.title)
            lbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            lbl.textColor = NSColor.white.withAlphaComponent(0.92)
            lbl.alignment = .center
            lbl.lineBreakMode = .byTruncatingTail
            lbl.frame = NSRect(x: 0, y: 78, width: tileW, height: 18)
            card.addSubview(lbl)

            addSubview(card)
        }

        let demoHeader = NSTextField(labelWithString: "Adaptive Top-Edge Color Test Pages")
        demoHeader.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        demoHeader.textColor = NSColor.white.withAlphaComponent(0.90)
        demoHeader.frame = NSRect(x: originX, y: 440, width: contentWidth, height: 24)
        addSubview(demoHeader)

        addQuickLinkRow(originX: originX, y: 478, maxWidth: contentWidth, lightOnDark: true)
    }

    private func buildArticlePage(originX: CGFloat, contentWidth: CGFloat) {
        let heroTextColor: NSColor = preset.heroTextLight
            ? NSColor.white.withAlphaComponent(0.96)
            : NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
        let heroSubColor: NSColor = preset.heroTextLight
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor(srgbRed: 0.28, green: 0.30, blue: 0.34, alpha: 1.0)

        let badge = NSTextField(labelWithString: preset.title.uppercased())
        badge.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        badge.textColor = heroSubColor
        badge.frame = NSRect(x: originX, y: 92, width: contentWidth, height: 18)
        addSubview(badge)

        let titleLabel = NSTextField(labelWithString: preset.heroTitle)
        titleLabel.font = NSFont.systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = heroTextColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.frame = NSRect(x: originX, y: 118, width: contentWidth, height: 54)
        addSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: preset.heroSubtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        subtitleLabel.textColor = heroSubColor
        subtitleLabel.frame = NSRect(x: originX, y: 178, width: min(contentWidth, 680), height: 64)
        addSubview(subtitleLabel)

        addQuickLinkRow(originX: originX, y: 262, maxWidth: contentWidth, lightOnDark: preset.heroTextLight)

        // Scrollable editorial cards below hero fold
        var cursorY = preset.heroHeight + 42
        for item in preset.sections {
            let card = FlippedMockCardView(frame: NSRect(x: originX, y: cursorY, width: contentWidth, height: 156))
            card.wantsLayer = true
            card.layer?.backgroundColor = preset.cardBackground.cgColor
            card.layer?.cornerRadius = 18
            card.layer?.cornerCurve = .continuous
            card.layer?.borderWidth = 0.5
            card.layer?.borderColor = preset.bodyTextColor.withAlphaComponent(0.10).cgColor

            let tagLabel = NSTextField(labelWithString: item.tag.uppercased())
            tagLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            tagLabel.textColor = preset.accentColor
            tagLabel.frame = NSRect(x: 24, y: 20, width: contentWidth - 48, height: 16)
            card.addSubview(tagLabel)

            let headLabel = NSTextField(labelWithString: item.heading)
            headLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
            headLabel.textColor = preset.bodyTextColor
            headLabel.frame = NSRect(x: 24, y: 42, width: contentWidth - 48, height: 26)
            card.addSubview(headLabel)

            let bodyLabel = NSTextField(wrappingLabelWithString: item.body)
            bodyLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .regular)
            bodyLabel.textColor = preset.bodyTextColor.withAlphaComponent(0.78)
            bodyLabel.frame = NSRect(x: 24, y: 74, width: contentWidth - 48, height: 64)
            card.addSubview(bodyLabel)

            addSubview(card)
            cursorY += 178
        }
    }

    private func addQuickLinkRow(originX: CGFloat, y: CGFloat, maxWidth: CGFloat, lightOnDark: Bool) {
        var x = originX
        for link in preset.quickLinks {
            let btn = NSButton(title: link.label, target: self, action: #selector(linkButtonClicked(_:)))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            btn.contentTintColor = lightOnDark ? .white : NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)
            btn.toolTip = link.url
            btn.sizeToFit()
            let w = btn.frame.width + 26
            if x + w > originX + maxWidth { break }
            btn.frame = NSRect(x: x, y: y, width: w, height: 34)
            btn.layer?.cornerRadius = 17
            btn.layer?.cornerCurve = .continuous
            btn.layer?.backgroundColor = lightOnDark
                ? NSColor.white.withAlphaComponent(0.18).cgColor
                : NSColor.black.withAlphaComponent(0.07).cgColor
            btn.layer?.borderWidth = 0.5
            btn.layer?.borderColor = lightOnDark
                ? NSColor.white.withAlphaComponent(0.28).cgColor
                : NSColor.black.withAlphaComponent(0.10).cgColor
            addSubview(btn)
            linkButtons.append(btn)
            x += w + 10
        }
    }

    @objc private func linkButtonClicked(_ sender: NSButton) {
        if let urlString = sender.toolTip {
            onNavigate?(urlString)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw body background
        preset.bodyBackground.setFill()
        bounds.fill()

        // Draw hero surface at top of document
        let heroRect = NSRect(x: 0, y: 0, width: bounds.width, height: preset.heroHeight)
        switch preset.heroStyle {
        case .solid(let color):
            color.setFill()
            heroRect.fill()

        case .verticalGradient(let top, let bottom):
            NSGradient(starting: top, ending: bottom)?.draw(in: heroRect, angle: 90)

        case .horizontalGradient(let left, let right):
            NSGradient(starting: left, ending: right)?.draw(in: heroRect, angle: 0)

        case .wallpaper(_, let fallback):
            fallback.setFill()
            bounds.fill()
            if let img = wallpaperImage {
                // Aspect-fill wallpaper across the whole canvas
                let imgAspect = img.size.width / max(img.size.height, 1)
                let viewAspect = bounds.width / max(bounds.height, 1)
                var drawRect = bounds
                if viewAspect > imgAspect {
                    let h = bounds.width / imgAspect
                    drawRect = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
                } else {
                    let w = bounds.height * imgAspect
                    drawRect = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
                }
                img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }
    }
}

private final class FlippedMockCardView: NSView {
    override var isFlipped: Bool { true }
}

