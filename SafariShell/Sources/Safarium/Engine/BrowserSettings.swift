import AppKit
import Foundation

extension Notification.Name {
    static let safariumSettingsDidChange = Notification.Name("SafariumSettingsDidChangeNotification")
    static let safariumWebsitePoliciesDidChange = Notification.Name("SafariumWebsitePoliciesDidChangeNotification")
}

/// Centralized, persistent, reactive settings store backing every pane of `SafariSettingsWindowController`,
/// Swift UI behavior (`SafariWindowController`, `CompactTabAddressBar`, `AddressBarPopoverView`, `AssetLoader`),
/// and Chromium `BrowserCore` preferences.
final class BrowserSettings {
    static let shared = BrowserSettings()

    private let defaults: UserDefaults

    // MARK: - Keys (shared with NSUserDefaults read by BrowserCore)

    enum Key {
        static let opensWith = "Safarium.Pref.OpensWith"
        static let newWindowOpensWith = "Safarium.Pref.NewWindowOpensWith"
        static let newTabOpensWith = "Safarium.Pref.NewTabOpensWith"
        static let homepage = "Safarium.Pref.Homepage"
        static let removeHistory = "Safarium.Pref.RemoveHistory"
        static let startPageFavorites = "Safarium.Pref.StartPageFavorites"
        static let downloadLocation = "Safarium.Pref.DownloadLocation"
        static let customDownloadDir = "Safarium.Pref.CustomDownloadDir"
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
        static let httpsOnlyMode = "Safarium.Pref.HTTPSOnlyMode"

        static let preventTracking = "Safarium.Pref.PreventCrossSiteTracking"
        static let stripTrackingParams = "Safarium.Pref.StripTrackingParams"
        static let referrerTrimming = "Safarium.Pref.ReferrerTrimming"
        static let webrtcIPProtection = "Safarium.Pref.WebRTCIPProtection"
        static let privacyProtectionLevel = "Safarium.Pref.PrivacyProtectionLevel"
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
        static let customStyleSheetPath = "Safarium.Pref.CustomStyleSheetPath"
        static let defaultEncoding = "Safarium.Pref.DefaultEncoding"
        static let showDeveloperFeatures = "Safarium.Pref.ShowDeveloperFeatures"

        static let devAllowUnsigned = "Safarium.Pref.DevAllowUnsigned"
        static let devSeparateDevTools = "Safarium.Pref.DevSeparateDevTools"
        static let devDisableCache = "Safarium.Pref.DevDisableCache"
        static let remoteDebuggingEnabled = "Safarium.Pref.RemoteDebuggingEnabled"
        static let remoteDebuggingPort = "Safarium.Pref.RemoteDebuggingPort"
        static let inspectDiscoverNetworkTargets = "Safarium.Pref.InspectDiscoverNetworkTargets"
        static let inspectNetworkTargets = "Safarium.Pref.InspectNetworkTargets"

        static let profilesEnabled = "Safarium.Pref.ProfilesEnabled"
        static let profileNames = "Safarium.Pref.ProfileNames"
        static let activeProfileName = "Safarium.Pref.ActiveProfileName"
        static let clearedShortcuts = "Safarium.Extensions.ClearedShortcuts"

        static let savedSessionTabs = "Safarium.Session.SavedTabs.v1"
        static let savedSessionActiveIndex = "Safarium.Session.ActiveIndex.v1"
    }

    // MARK: - Search Engines

    enum SearchEngine: Int, CaseIterable {
        case google = 0
        case duckDuckGo = 1
        case bing = 2
        case yahoo = 3
        case ecosia = 4
        case perplexity = 5
        case kagi = 6

        var displayName: String {
            switch self {
            case .google: return "Google"
            case .duckDuckGo: return "DuckDuckGo"
            case .bing: return "Bing"
            case .yahoo: return "Yahoo"
            case .ecosia: return "Ecosia"
            case .perplexity: return "Perplexity"
            case .kagi: return "Kagi"
            }
        }

        func searchURL(for query: String) -> URL {
            var comps = URLComponents()
            comps.scheme = "https"
            switch self {
            case .google:
                comps.host = "www.google.com"
                comps.path = "/search"
                comps.queryItems = [URLQueryItem(name: "q", value: query)]
            case .duckDuckGo:
                comps.host = "duckduckgo.com"
                comps.path = "/"
                comps.queryItems = [URLQueryItem(name: "q", value: query)]
            case .bing:
                comps.host = "www.bing.com"
                comps.path = "/search"
                comps.queryItems = [URLQueryItem(name: "q", value: query)]
            case .yahoo:
                comps.host = "search.yahoo.com"
                comps.path = "/search"
                comps.queryItems = [URLQueryItem(name: "p", value: query)]
            case .ecosia:
                comps.host = "www.ecosia.org"
                comps.path = "/search"
                comps.queryItems = [URLQueryItem(name: "q", value: query)]
            case .perplexity:
                comps.host = "www.perplexity.ai"
                comps.path = "/search"
                comps.queryItems = [URLQueryItem(name: "q", value: query)]
            case .kagi:
                comps.host = "kagi.com"
                comps.path = "/search"
                comps.queryItems = [URLQueryItem(name: "q", value: query)]
            }
            // URLQueryItem leaves "+" raw, which servers decode as a space ("c++" -> "c  "): encode it explicitly.
            if let q = comps.percentEncodedQuery { comps.percentEncodedQuery = q.replacingOccurrences(of: "+", with: "%2B") }
            return comps.url ?? URL(string: "about:blank")!
        }

        func suggestURL(for query: String) -> URL? {
            var comps = URLComponents()
            comps.scheme = "https"
            switch self {
            case .google, .perplexity, .kagi:
                comps.host = "suggestqueries.google.com"
                comps.path = "/complete/search"
                comps.queryItems = [
                    URLQueryItem(name: "client", value: "firefox"),
                    URLQueryItem(name: "q", value: query)
                ]
            case .duckDuckGo:
                comps.host = "duckduckgo.com"
                comps.path = "/ac/"
                comps.queryItems = [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "type", value: "list")
                ]
            case .bing:
                comps.host = "api.bing.com"
                comps.path = "/osjson.aspx"
                comps.queryItems = [URLQueryItem(name: "query", value: query)]
            case .yahoo:
                comps.host = "search.yahoo.com"
                comps.path = "/sugg/ff"
                comps.queryItems = [
                    URLQueryItem(name: "output", value: "fxjson"),
                    URLQueryItem(name: "command", value: query)
                ]
            case .ecosia:
                comps.host = "ac.ecosia.org"
                comps.path = "/autocomplete"
                comps.queryItems = [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "type", value: "list")
                ]
            }
            return comps.url
        }
    }

    static let minFontSizes: [Int] = [9, 10, 11, 12, 14, 16, 18, 24]
    static let encodingNames: [String] = [
        "UTF-8",
        "ISO-8859-1",
        "windows-1252",
        "ISO-8859-9",
        "Shift_JIS"
    ]
    static let pageZoomValues: [Double] = [0.50, 0.75, 0.85, 1.0, 1.15, 1.25, 1.50, 1.75, 2.0, 2.5, 3.0]

    private static let safeFileExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg",
        "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac", "flac",
        "txt", "rtf", "md", "csv", "zip", "gz", "tar"
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Generic Typed Accessors

    func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.integer(forKey: key)
    }

    func string(_ key: String, default defaultValue: String = "") -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChanged(key: key)
    }

    func notifyChanged(key: String) {
        NotificationCenter.default.post(
            name: .safariumSettingsDidChange,
            object: self,
            userInfo: ["key": key]
        )
    }

    // MARK: - General

    /// 0 = All windows from last session, 1 = All non-private windows from last session, 2 = A new window, 3 = A new private window
    var opensWithIndex: Int { int(Key.opensWith, default: 0) }
    /// 0 = Start Page, 1 = Homepage, 2 = Empty Page, 3 = Same Page
    var newWindowOpensWithIndex: Int { int(Key.newWindowOpensWith, default: 0) }
    var newTabOpensWithIndex: Int { int(Key.newTabOpensWith, default: 0) }

    var homepageURL: URL? {
        let raw = string(Key.homepage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.contains("://") {
            return URL(string: raw)
        }
        return URL(string: "https://\(raw)")
    }

    func resolvedNewTabURL(activeTabURL: URL?) -> URL {
        switch newTabOpensWithIndex {
        case 1:
            return homepageURL ?? URL(string: "safarium://start")!
        case 2:
            return URL(string: "about:blank")!
        case 3:
            if let active = activeTabURL, active.isWebURL {
                return active
            }
            return URL(string: "safarium://start")!
        default:
            return URL(string: "safarium://start")!
        }
    }

    func resolvedNewWindowURL(activeTabURL: URL?) -> URL {
        switch newWindowOpensWithIndex {
        case 1:
            return homepageURL ?? URL(string: "safarium://start")!
        case 2:
            return URL(string: "about:blank")!
        case 3:
            if let active = activeTabURL, active.isWebURL {
                return active
            }
            return URL(string: "safarium://start")!
        default:
            return URL(string: "safarium://start")!
        }
    }

    var historyRetentionSeconds: TimeInterval? {
        switch int(Key.removeHistory, default: 4) {
        case 0: return 86_400
        case 1: return 86_400 * 7
        case 2: return 86_400 * 14
        case 3: return 86_400 * 30
        case 4: return 86_400 * 365
        default: return nil
        }
    }

    /// 0 = Downloads, 1 = Desktop, 2 = Ask for each download, 3 = Custom folder
    var downloadLocationMode: Int { int(Key.downloadLocation, default: 0) }

    var resolvedDownloadDirectoryPath: String {
        switch downloadLocationMode {
        case 1:
            return NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        case 3:
            let custom = string(Key.customDownloadDir)
            if !custom.isEmpty { return custom }
            fallthrough
        default:
            return NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
        }
    }

    var askForEachDownload: Bool { downloadLocationMode == 2 }
    var removeDownloadsMode: Int { int(Key.removeDownloads, default: 0) }
    var openSafeFilesAfterDownloading: Bool { bool(Key.openSafeFiles, default: false) }

    func isSafeDownloadFile(atPath path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return Self.safeFileExtensions.contains(ext)
    }

    func isDefaultBrowser() -> Bool {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "example.com"
        guard let testURL = comps.url,
              let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: testURL),
              let myBundleID = Bundle.main.bundleIdentifier,
              let handlerBundle = Bundle(url: handlerURL) else {
            return false
        }
        return handlerBundle.bundleIdentifier == myBundleID
    }

    func setAsDefaultBrowser(completion: @escaping (Bool, Error?) -> Void) {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            completion(false, nil)
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { err1 in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { err2 in
                DispatchQueue.main.async {
                    let err = err2 ?? err1
                    completion(err == nil, err)
                }
            }
        }
    }

    func saveSession(urls: [String], activeIndex: Int) {
        let filtered = urls.filter { !$0.isEmpty }
        // Remap the active index through the empty-URL filter so it still points at the same tab.
        let preceding = urls.prefix(max(0, min(activeIndex, urls.count))).filter { !$0.isEmpty }.count
        defaults.set(filtered, forKey: Key.savedSessionTabs)
        defaults.set(max(0, min(max(0, filtered.count - 1), preceding)), forKey: Key.savedSessionActiveIndex)
    }

    func savedSession() -> (urls: [URL], activeIndex: Int) {
        let raw = defaults.stringArray(forKey: Key.savedSessionTabs) ?? []
        let urls = raw.compactMap { URL(string: $0) }
        let storedIdx = max(0, defaults.integer(forKey: Key.savedSessionActiveIndex))
        // Remap through any malformed entries dropped by compactMap so the active tab stays the same.
        let idx = raw.prefix(min(storedIdx, raw.count)).filter { URL(string: $0) != nil }.count
        return (urls, max(0, min(max(0, urls.count - 1), idx)))
    }

    // MARK: - Tabs

    var openPagesInTabsMode: Int { int(Key.openPagesInTabs, default: 0) }
    /// 0 = Manually, 1 = After one day, 2 = After one week, 3 = After one month
    var autoCloseTabInterval: TimeInterval? {
        switch int(Key.autoCloseTabs, default: 0) {
        case 1: return 86_400
        case 2: return 86_400 * 7
        case 3: return 86_400 * 30
        default: return nil
        }
    }
    var tabLayout: String { string(Key.tabLayout, default: "compact") }
    var showWebsiteColorInToolbar: Bool { bool(Key.showWebsiteColor, default: true) }
    var refractiveGlassToolbar: Bool {
        get { bool(Key.refractiveGlassToolbar, default: false) }
        set { set(newValue, forKey: Key.refractiveGlassToolbar) }
    }
    var refractiveGlassFrost: Double {
        get {
            guard defaults.object(forKey: Key.refractiveGlassFrost) != nil else { return 0.0 }
            return max(0.0, min(24.0, defaults.double(forKey: Key.refractiveGlassFrost)))
        }
        set {
            let clamped = max(0.0, min(24.0, newValue))
            defaults.set(clamped, forKey: Key.refractiveGlassFrost)
            NotificationCenter.default.post(
                name: .safariumSettingsDidChange,
                object: self,
                userInfo: ["key": Key.refractiveGlassFrost]
            )
        }
    }
    var alwaysShowWebsiteTitles: Bool { bool(Key.alwaysShowTabTitles, default: false) }
    var cmdClickOpensInNewTab: Bool { bool(Key.cmdClickNewTab, default: true) }
    var activateNewTabsOnOpen: Bool { bool(Key.activateNewTabs, default: false) }
    var cmdNumberSwitchesTabs: Bool { bool(Key.cmdNumberSwitch, default: true) }

    // MARK: - Quick Website Search & Local AutoFill Stores

    struct QuickSearchSite: Codable, Equatable {
        var keyword: String
        var domain: String
        var templateURL: String // contains "%@" placeholder
    }

    static let defaultQuickSearchSites: [QuickSearchSite] = [
        .init(keyword: "youtube", domain: "youtube.com", templateURL: "https://www.youtube.com/results?search_query=%@"),
        .init(keyword: "github", domain: "github.com", templateURL: "https://github.com/search?q=%@"),
        .init(keyword: "wikipedia", domain: "wikipedia.org", templateURL: "https://en.wikipedia.org/w/index.php?search=%@"),
        .init(keyword: "reddit", domain: "reddit.com", templateURL: "https://www.reddit.com/search/?q=%@"),
        .init(keyword: "amazon", domain: "amazon.com", templateURL: "https://www.amazon.com/s?k=%@")
    ]

    private static let quickSearchDefaultsKey = "Safarium.QuickSearchSites.v1"

    func quickSearchSites() -> [QuickSearchSite] {
        if let data = defaults.data(forKey: Self.quickSearchDefaultsKey),
           let decoded = try? JSONDecoder().decode([QuickSearchSite].self, from: data) {
            return decoded
        }
        return Self.defaultQuickSearchSites
    }

    func saveQuickSearchSites(_ sites: [QuickSearchSite]) {
        if let data = try? JSONEncoder().encode(sites) {
            defaults.set(data, forKey: Self.quickSearchDefaultsKey)
            notifyChanged(key: Key.quickWebsiteSearch)
        }
    }

    func matchQuickWebsiteSearch(for rawInput: String) -> (site: QuickSearchSite, query: String, url: URL)? {
        guard enableQuickWebsiteSearch else { return nil }
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIdx = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let prefix = String(trimmed[..<spaceIdx]).lowercased()
        let rest = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !rest.isEmpty else { return nil }

        let sites = quickSearchSites()
        guard let matched = sites.first(where: {
            $0.keyword.lowercased() == prefix || $0.domain.lowercased() == prefix
        }) else { return nil }

        var queryValueAllowed = CharacterSet.urlQueryAllowed
        queryValueAllowed.remove(charactersIn: "&=+#;")
        let encoded = rest.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? rest
        let urlStr = matched.templateURL.replacingOccurrences(of: "%@", with: encoded)
        guard let url = URL(string: urlStr) else { return nil }
        return (matched, rest, url)
    }

    func autoFillEntries(categoryKey: String) -> [String] {
        defaults.stringArray(forKey: "Safarium.AutoFillStore.\(categoryKey)") ?? []
    }

    func saveAutoFillEntries(_ entries: [String], categoryKey: String) {
        defaults.set(entries, forKey: "Safarium.AutoFillStore.\(categoryKey)")
        notifyChanged(key: categoryKey)
    }

    // MARK: - Search

    var primarySearchEngine: SearchEngine {
        SearchEngine(rawValue: int(Key.searchEngine, default: 0)) ?? .google
    }

    var samePrivateSearchEngine: Bool { bool(Key.samePrivateSearch, default: true) }

    var privateSearchEngine: SearchEngine {
        SearchEngine(rawValue: int(Key.privateSearchEngine, default: 1)) ?? .duckDuckGo
    }

    func effectiveSearchEngine(isPrivate: Bool) -> SearchEngine {
        (isPrivate && !samePrivateSearchEngine) ? privateSearchEngine : primarySearchEngine
    }

    var includeSearchSuggestions: Bool { bool(Key.searchSuggestions, default: true) }
    var enableQuickWebsiteSearch: Bool { bool(Key.quickWebsiteSearch, default: true) }
    var preloadTopHit: Bool { bool(Key.preloadTopHit, default: true) }
    var showFavoritesInSearch: Bool { bool(Key.showFavoritesInSearch, default: true) }

    // MARK: - Security & Privacy

    var warnFraudulentWebsites: Bool { bool(Key.warnFraudulent, default: true) }
    var enableJavaScript: Bool { bool(Key.enableJavaScript, default: true) }
    var warnBeforeHTTP: Bool { bool(Key.warnHTTP, default: false) }
    var httpsOnlyMode: Bool { bool(Key.httpsOnlyMode, default: true) }
    var preventCrossSiteTracking: Bool { bool(Key.preventTracking, default: true) }
    var stripTrackingParams: Bool { bool(Key.stripTrackingParams, default: true) }
    var referrerTrimming: Bool { bool(Key.referrerTrimming, default: true) }
    var webrtcIPProtection: Bool { bool(Key.webrtcIPProtection, default: true) }
    var privacyProtectionLevel: PrivacyProtectionLevel {
        PrivacyProtectionLevel(rawValue: int(Key.privacyProtectionLevel, default: 0)) ?? .standard
    }
    var requireTouchIDForPrivate: Bool { bool(Key.touchIDLockedPrivate, default: true) }

    // MARK: - Advanced & Developer

    var showFullWebsiteAddress: Bool { bool(Key.showFullAddress, default: false) }
    var minFontEnabled: Bool { bool(Key.minFontEnabled, default: false) }
    var effectiveMinimumFontSize: Int {
        guard minFontEnabled else { return 0 }
        let idx = max(0, min(Self.minFontSizes.count - 1, int(Key.minFontSize, default: 0)))
        return Self.minFontSizes[idx]
    }
    var tabHighlightsAll: Bool { bool(Key.tabHighlightsAll, default: false) }
    var advancedFingerprintProtection: Bool { bool(Key.advancedFingerprint, default: true) }
    var advancedFingerprintScope: Int { int(Key.advancedFingerprintScope, default: 1) }
    var globalPrivacyControl: Bool { bool(Key.globalPrivacyControl, default: false) }
    var blockAllCookies: Bool { bool(Key.blockAllCookies, default: false) }
    var customStyleSheetPath: String {
        guard int(Key.customStyleSheet, default: 0) == 1 else { return "" }
        return string(Key.customStyleSheetPath)
    }
    var defaultEncodingCharset: String {
        let idx = max(0, min(Self.encodingNames.count - 1, int(Key.defaultEncoding, default: 0)))
        return Self.encodingNames[idx]
    }
    var showDeveloperFeatures: Bool { bool(Key.showDeveloperFeatures, default: true) }
    var devAllowUnsignedExtensions: Bool { bool(Key.devAllowUnsigned, default: true) }
    var devSeparateDevToolsWindow: Bool { bool(Key.devSeparateDevTools, default: false) }
    var devDisableCache: Bool { bool(Key.devDisableCache, default: false) }

    var remoteDebuggingEnabled: Bool {
        get { bool(Key.remoteDebuggingEnabled, default: false) }
        set { set(newValue, forKey: Key.remoteDebuggingEnabled) }
    }

    static let defaultRemoteDebuggingPort: Int = 9222

    var remoteDebuggingPort: Int {
        get {
            let stored = int(Key.remoteDebuggingPort, default: Self.defaultRemoteDebuggingPort)
            return (1024...65535).contains(stored) ? stored : Self.defaultRemoteDebuggingPort
        }
        set {
            let clamped = (1024...65535).contains(newValue) ? newValue : Self.defaultRemoteDebuggingPort
            set(clamped, forKey: Key.remoteDebuggingPort)
        }
    }

    var inspectDiscoverNetworkTargets: Bool {
        get { bool(Key.inspectDiscoverNetworkTargets, default: true) }
        set { set(newValue, forKey: Key.inspectDiscoverNetworkTargets) }
    }

    static let defaultInspectNetworkTargets: [String] = ["localhost:9222", "localhost:9229"]

    var inspectNetworkTargets: [String] {
        get {
            if let arr = defaults.stringArray(forKey: Key.inspectNetworkTargets) {
                return arr
            }
            return Self.defaultInspectNetworkTargets
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var deduped: [String] = []
            for item in cleaned where !deduped.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
                deduped.append(item)
            }
            defaults.set(deduped, forKey: Key.inspectNetworkTargets)
            NotificationCenter.default.post(
                name: .safariumSettingsDidChange,
                object: self,
                userInfo: ["key": Key.inspectNetworkTargets]
            )
        }
    }

    // MARK: - Websites Per-Host Policies

    static func normalizedHost(from url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func setWebsitePolicy(category: String, host: String, index: Int) {
        defaults.set(index, forKey: "Safarium.SitePolicy.\(category).\(host)")
        NotificationCenter.default.post(
            name: .safariumWebsitePoliciesDidChange,
            object: self,
            userInfo: ["category": category, "host": host, "index": index]
        )
    }

    func setWebsiteDefaultPolicy(category: String, index: Int) {
        defaults.set(index, forKey: "Safarium.SiteDefault.\(category)")
        NotificationCenter.default.post(
            name: .safariumWebsitePoliciesDidChange,
            object: self,
            userInfo: ["category": category, "index": index]
        )
    }

    func websitePolicyIndex(category: String, host: String?, defaultIndex: Int) -> Int {
        if let host, !host.isEmpty {
            let hostKey = "Safarium.SitePolicy.\(category).\(host)"
            if defaults.object(forKey: hostKey) != nil {
                return defaults.integer(forKey: hostKey)
            }
        }
        let globalKey = "Safarium.SiteDefault.\(category)"
        if defaults.object(forKey: globalKey) != nil {
            return defaults.integer(forKey: globalKey)
        }
        return defaultIndex
    }

    func configuredHosts(for category: String) -> [String] {
        let prefix = "Safarium.SitePolicy.\(category)."
        return defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    func removeWebsitePolicy(category: String, host: String) {
        defaults.removeObject(forKey: "Safarium.SitePolicy.\(category).\(host)")
        NotificationCenter.default.post(
            name: .safariumWebsitePoliciesDidChange,
            object: self,
            userInfo: ["category": category, "host": host]
        )
    }

    func websiteDefaultPolicyIndex(category: String, defaultIndex: Int) -> Int {
        websitePolicyIndex(category: category, host: nil, defaultIndex: defaultIndex)
    }

    /// Canonical Content Blockers helper (`0 = On`, `1 = Off`).
    func isContentBlockersEnabled(forHost rawHost: String) -> Bool {
        let host = PrivacyDomainClassifier.normalizedHost(rawHost)
        let hostArg: String? = host.isEmpty ? nil : host
        return websitePolicyIndex(category: "Content Blockers", host: hostArg, defaultIndex: 0) == 0
    }

    /// Canonical Content Blockers setter (`0 = On`, `1 = Off`).
    func setContentBlockersEnabled(_ enabled: Bool, forHost rawHost: String) {
        let host = PrivacyDomainClassifier.normalizedHost(rawHost)
        guard !host.isEmpty else { return }
        setWebsitePolicy(category: "Content Blockers", host: host, index: enabled ? 0 : 1)
    }

    func pageZoomFactor(for url: URL?) -> Double {
        let host = Self.normalizedHost(from: url)
        let idx = websitePolicyIndex(category: "Page Zoom", host: host, defaultIndex: 3)
        let clamped = max(0, min(Self.pageZoomValues.count - 1, idx))
        return Self.pageZoomValues[clamped]
    }

    func setPageZoomFactor(_ factor: Double, for url: URL?) {
        guard let host = Self.normalizedHost(from: url), !host.isEmpty else { return }
        var bestIdx = 3
        var bestDiff = Double.greatestFiniteMagnitude
        for (idx, val) in Self.pageZoomValues.enumerated() {
            let diff = abs(val - factor)
            if diff < bestDiff {
                bestDiff = diff
                bestIdx = idx
            }
        }
        setWebsitePolicy(category: "Page Zoom", host: host, index: bestIdx)
    }

    // MARK: - Snapshot Dictionary for BrowserCore Live Sync

    func privacyPolicyDictionary() -> [String: Any] {
        let cbHosts = configuredHosts(for: "Content Blockers")
        var disabledHosts: [String] = []
        var enabledHosts: [String] = []
        for host in cbHosts {
            let idx = websitePolicyIndex(category: "Content Blockers", host: host, defaultIndex: 0)
            if idx == 1 {
                disabledHosts.append(host)
            } else if idx == 0 {
                enabledHosts.append(host)
            }
        }
        let micAllowedHosts = configuredHosts(for: "Microphone").filter {
            websitePolicyIndex(category: "Microphone", host: $0, defaultIndex: 0) == 2
        }
        let camAllowedHosts = configuredHosts(for: "Camera").filter {
            websitePolicyIndex(category: "Camera", host: $0, defaultIndex: 0) == 2
        }
        return [
            "preventCrossSiteTracking": preventCrossSiteTracking,
            "blockAllCookies": blockAllCookies,
            "advancedFingerprint": advancedFingerprintProtection,
            "advancedFingerprintScope": advancedFingerprintScope,
            "globalPrivacyControl": globalPrivacyControl,
            "httpsOnlyMode": httpsOnlyMode,
            "warnHTTP": warnBeforeHTTP,
            "stripTrackingParams": stripTrackingParams,
            "referrerTrimming": referrerTrimming,
            "webrtcIPProtection": webrtcIPProtection,
            "protectionLevel": privacyProtectionLevel.rawValue,
            "contentBlockersDefault": websiteDefaultPolicyIndex(category: "Content Blockers", defaultIndex: 0),
            "contentBlockersDisabledHosts": disabledHosts.sorted(),
            "contentBlockersEnabledHosts": enabledHosts.sorted(),
            "microphoneDefault": websiteDefaultPolicyIndex(category: "Microphone", defaultIndex: 0),
            "cameraDefault": websiteDefaultPolicyIndex(category: "Camera", defaultIndex: 0),
            "microphoneAllowedHosts": micAllowedHosts.sorted(),
            "cameraAllowedHosts": camAllowedHosts.sorted()
        ]
    }

    func enginePreferencesDictionary() -> [String: Any] {
        [
            "enableJavaScript": enableJavaScript,
            "warnFraudulent": warnFraudulentWebsites,
            "preventCrossSiteTracking": preventCrossSiteTracking,
            "blockAllCookies": blockAllCookies,
            "globalPrivacyControl": globalPrivacyControl,
            "webrtcIPProtection": webrtcIPProtection,
            "minimumFontSize": effectiveMinimumFontSize,
            "defaultEncoding": defaultEncodingCharset,
            "downloadDirectory": resolvedDownloadDirectoryPath,
            "askForEachDownload": askForEachDownload,
            "allowUnsignedExtensions": devAllowUnsignedExtensions,
            "autofillPasswords": bool(Key.autofillPasswords, default: true),
            "autofillAddresses": bool(Key.autofillAddresses, default: true),
            "autofillCards": bool(Key.autofillCards, default: true),
            "customStyleSheetPath": customStyleSheetPath
        ]
    }
}
