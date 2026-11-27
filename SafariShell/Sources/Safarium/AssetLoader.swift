import AppKit

extension Notification.Name {
    static let safariumFavoritesDidChange = Notification.Name("Safarium.FavoritesDidChange")
    static let safariumReadingListDidChange = Notification.Name("Safarium.ReadingListDidChange")
    static let safariumHistoryDidChange = Notification.Name("Safarium.HistoryDidChange")
}

/// Cleanly loads pre-extracted Safari 27 assets from `Reference/Components/` and `Reference/Animations/`
/// (both when bundled inside `Safarium.app/Contents/Resources/Reference` and during local workspace runs).
final class AssetLoader {
    static let shared = AssetLoader()

    struct BookmarkEntry: Codable, Equatable {
        let id: String
        var title: String
        var url: String
        let color: String?
    }

    struct ReadingListItem: Codable, Equatable {
        let id: String
        var title: String
        var url: String
        var addedAt: Date
    }

    struct HistoryEntry: Codable, Equatable {
        var title: String
        var url: String
        var visitCount: Int
        var lastVisited: Date
    }

    private struct BookmarkRoot: Decodable {
        struct Folder: Decodable {
            let title: String?
            let children: [BookmarkEntry]?
        }
        let bookmarks: [Folder]?
    }

    private var symbolCache: [String: NSImage] = [:]
    private var wallpaperCache: [String: NSImage] = [:]
    private var cachedFavorites: [BookmarkEntry]?
    private var cachedReadingList: [ReadingListItem]?
    private var cachedHistory: [HistoryEntry]?

    let referenceRootURL: URL

    private init() {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let resURL = Bundle.main.resourceURL {
            candidates.append(resURL.appendingPathComponent("Reference", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Reference", isDirectory: true))
        candidates.append(cwd.deletingLastPathComponent().appendingPathComponent("Reference", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/Users/elfaria/Safarium/Reference", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/Users/elfaria/SafariX/Reference", isDirectory: true))

        if let found = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("Components").path) }) {
            self.referenceRootURL = found
        } else {
            self.referenceRootURL = URL(fileURLWithPath: "/Users/elfaria/SafariX/Reference", isDirectory: true)
        }
    }

    /// Loads a crisp native Retina vector SF Symbol matching macOS 27.3 Safari's exact glyph geometry
    /// and stroke weight, falling back to pre-extracted PNG symbols under `Reference/Components/symbols/`.
    func symbol(named name: String, pointSize: CGFloat = 16.0, weight: NSFont.Weight = .regular) -> NSImage {
        let cacheKey = "\(name)_\(Int(pointSize * 10))_\(weight.rawValue)"
        if let cached = symbolCache[cacheKey] {
            return cached
        }

        // Prefer native macOS 27 SF Symbol vectors so 16–17pt toolbar & sidebar icons render razor-sharp at 2x Retina
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let sf = NSImage(systemSymbolName: name, accessibilityDescription: name)?.withSymbolConfiguration(config) {
            sf.isTemplate = true
            symbolCache[cacheKey] = sf
            return sf
        }

        // Fallback to extracted Safari symbols in Reference/Components/symbols/
        let symbolsDir = referenceRootURL
            .appendingPathComponent("Components/symbols", isDirectory: true)
            .resolvingSymlinksInPath()

        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
        let candidateFilenames = scale >= 3
            ? ["\(name)@3x.png", "\(name)@2x.png", "\(name).png"]
            : ["\(name)@2x.png", "\(name)@3x.png", "\(name).png"]

        for filename in candidateFilenames {
            let fileURL = symbolsDir.appendingPathComponent(filename)
            if let rep = NSBitmapImageRep(data: (try? Data(contentsOf: fileURL)) ?? Data()) {
                let fileScale: CGFloat = filename.contains("@3x") ? 3.0 : (filename.contains("@2x") ? 2.0 : 1.0)
                let naturalSize = NSSize(
                    width: CGFloat(rep.pixelsWide) / fileScale,
                    height: CGFloat(rep.pixelsHigh) / fileScale
                )
                let maxDim = max(naturalSize.width, naturalSize.height, 1.0)
                let scaleFactor = min(1.0, (pointSize + 2.0) / maxDim)
                let targetSize = NSSize(
                    width: (naturalSize.width * scaleFactor).rounded(.toNearestOrAwayFromZero),
                    height: (naturalSize.height * scaleFactor).rounded(.toNearestOrAwayFromZero)
                )
                let image = NSImage(size: targetSize)
                image.addRepresentation(rep)
                image.size = targetSize
                image.isTemplate = true
                symbolCache[cacheKey] = image
                return image
            }
        }

        let empty = NSImage(size: NSSize(width: pointSize, height: pointSize))
        empty.isTemplate = true
        return empty
    }

    /// Loads a Safari 27 Start Page wallpaper (uses fast 1024x1024 thumbnail when `thumbnail == true`).
    func wallpaper(named id: String = "safari-27-blue", thumbnail: Bool = true) -> NSImage? {
        let key = "\(id)_\(thumbnail ? "thumb" : "full")"
        if let cached = wallpaperCache[key] {
            return cached
        }
        let dir = referenceRootURL
            .appendingPathComponent("Components/wallpapers", isDirectory: true)
            .resolvingSymlinksInPath()

        let candidates: [URL] = thumbnail
            ? [
                dir.appendingPathComponent("thumbnails/\(id)-thumb.jpg"),
                dir.appendingPathComponent("thumbnails/\(id).jpg"),
                dir.appendingPathComponent("thumbnails/\(id).png"),
                dir.appendingPathComponent("\(id).jpg"),
                dir.appendingPathComponent("\(id).png")
            ]
            : [
                dir.appendingPathComponent("\(id).jpg"),
                dir.appendingPathComponent("\(id).png")
            ]

        for url in candidates {
            if let img = NSImage(contentsOf: url) {
                wallpaperCache[key] = img
                return img
            }
        }
        return nil
    }

    func availableWallpaperIDs() -> [String] {
        [
            "safari-27-blue",
            "safari-27-orange",
            "safari-27-pink",
            "california-quail",
            "california-grizzly-bear",
            "california-dogface-butterfly",
            "emoji-safari-animals",
            "emoji-vacation"
        ]
    }

    static let favoritesOrderDefaultsKey = "Safarium.FavoritesOrderURLs.v1"
    static let customFavoritesDefaultsKey = "Safarium.CustomFavoritesEntries.v1"

    /// Default extra favorites appended after `bookmarks.json` so Start Page demonstrates
    /// multi-row Favorites (`Show All >` expand/collapse + drag-reorder auto-expand) out of the box.
    static let extraDefaultFavorites: [BookmarkEntry] = [
        BookmarkEntry(id: "extra-github", title: "GitHub", url: "https://github.com/", color: "#24292F"),
        BookmarkEntry(id: "extra-youtube", title: "YouTube", url: "https://www.youtube.com/", color: "#FF0000"),
        BookmarkEntry(id: "extra-reddit", title: "Reddit", url: "https://www.reddit.com/", color: "#FF4500"),
        BookmarkEntry(id: "extra-amazon", title: "Amazon", url: "https://www.amazon.com/", color: "#FF9900"),
        BookmarkEntry(id: "extra-netflix", title: "Netflix", url: "https://www.netflix.com/", color: "#E50914"),
        BookmarkEntry(id: "extra-spotify", title: "Spotify", url: "https://open.spotify.com/", color: "#1DB954"),
        BookmarkEntry(id: "extra-discord", title: "Discord", url: "https://discord.com/", color: "#5865F2"),
        BookmarkEntry(id: "extra-notion", title: "Notion", url: "https://www.notion.so/", color: "#191919"),
        BookmarkEntry(id: "extra-stackoverflow", title: "Stack Overflow", url: "https://stackoverflow.com/", color: "#F48024"),
        BookmarkEntry(id: "extra-hn", title: "Hacker News", url: "https://news.ycombinator.com/", color: "#FF6600")
    ]

    /// Loads Safari bookmarks from `Reference/Components/bookmarks.json`, applying any user edits, deletes, or custom order.
    func favorites() -> [BookmarkEntry] {
        if let cached = cachedFavorites {
            return cached
        }
        if let savedData = UserDefaults.standard.data(forKey: Self.customFavoritesDefaultsKey),
           let decoded = try? JSONDecoder().decode([BookmarkEntry].self, from: savedData) {
            let deduped = Self.deduplicateFavorites(decoded)
            cachedFavorites = deduped
            if deduped.count != decoded.count {
                UserDefaults.standard.set(deduped.map(\.url), forKey: Self.favoritesOrderDefaultsKey)
                if let encoded = try? JSONEncoder().encode(deduped) {
                    UserDefaults.standard.set(encoded, forKey: Self.customFavoritesDefaultsKey)
                }
            }
            return deduped
        }

        let fileURL = referenceRootURL
            .appendingPathComponent("Components/bookmarks.json")
            .resolvingSymlinksInPath()
        var base: [BookmarkEntry] = []
        if let data = try? Data(contentsOf: fileURL),
           let root = try? JSONDecoder().decode(BookmarkRoot.self, from: data),
           let first = root.bookmarks?.first?.children {
            base = first
        }
        var existingKeys = Set(base.map { Self.normalizedURLKey($0.url) })
        for extra in Self.extraDefaultFavorites {
            let k = Self.normalizedURLKey(extra.url)
            if !existingKeys.contains(k) {
                existingKeys.insert(k)
                base.append(extra)
            }
        }

        if let savedOrder = UserDefaults.standard.stringArray(forKey: Self.favoritesOrderDefaultsKey), !savedOrder.isEmpty {
            var byURL: [String: BookmarkEntry] = [:]
            for item in base { byURL[item.url] = item }
            var reordered: [BookmarkEntry] = []
            var used = Set<String>()
            for url in savedOrder {
                if let entry = byURL[url], !used.contains(url) {
                    reordered.append(entry)
                    used.insert(url)
                }
            }
            for item in base where !used.contains(item.url) {
                reordered.append(item)
            }
            base = reordered
        }

        cachedFavorites = base
        return base
    }

    func saveFavoritesOrder(_ entries: [BookmarkEntry]) {
        cachedFavorites = entries
        UserDefaults.standard.set(entries.map(\.url), forKey: Self.favoritesOrderDefaultsKey)
        if let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: Self.customFavoritesDefaultsKey)
        }
        NotificationCenter.default.post(name: .safariumFavoritesDidChange, object: nil)
    }

    func updateFavorite(id: String, title: String? = nil, url: String? = nil) {
        var list = favorites()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                list[idx].title = trimmed
            }
        }
        if let url {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                list[idx].url = trimmed
            }
        }
        saveFavoritesOrder(list)
    }

    func deleteFavorite(id: String) {
        var list = favorites()
        let before = list.count
        list.removeAll { $0.id == id }
        guard list.count != before else { return }
        saveFavoritesOrder(list)
    }

    @discardableResult
    func mergeImportedFavorites(_ imported: [BookmarkEntry], prepend: Bool = false) -> Int {
        guard !imported.isEmpty else { return 0 }
        var existing = favorites()

        // Track exact URL keys and canonical homepage keys (e.g. apple.com/tr vs apple.com/,
        // google.com.tr/?client=safari&channel=iphone_bm vs google.com/?client=safari&channel=mac_bm).
        var existingExactKeys = Set(existing.map { Self.normalizedURLKey($0.url) })
        var seenImportKeys = Set<String>()
        var seenImportHomeKeys = Set<String>()
        var additions: [BookmarkEntry] = []
        var replacedCount = 0

        for entry in imported {
            let exactKey = Self.normalizedURLKey(entry.url)
            guard !exactKey.isEmpty, !seenImportKeys.contains(exactKey) else { continue }
            let homeKeys = Self.canonicalFavoriteHomepageKeys(url: entry.url, title: entry.title)
            if !homeKeys.isDisjoint(with: seenImportHomeKeys) {
                continue
            }
            if existingExactKeys.contains(exactKey) {
                seenImportKeys.insert(exactKey)
                seenImportHomeKeys.formUnion(homeKeys)
                continue
            }

            // If an existing built-in entry matches the same canonical homepage (e.g. built-in US
            // Apple/Google vs imported localized apple.com/tr or google.com.tr), replace it in place
            // so the user's localized bookmark wins without creating a duplicate or shifting order.
            if !homeKeys.isEmpty {
                let matchingIndices = existing.indices.filter { idx in
                    let existingHomeKeys = Self.canonicalFavoriteHomepageKeys(
                        url: existing[idx].url,
                        title: existing[idx].title
                    )
                    return !homeKeys.isDisjoint(with: existingHomeKeys)
                }
                if !matchingIndices.isEmpty {
                    let existingIsOnlyBuiltIn = matchingIndices.allSatisfy { idx in
                        !existing[idx].id.hasPrefix("imp-")
                    }
                    if existingIsOnlyBuiltIn {
                        let firstIdx = matchingIndices[0]
                        for idx in matchingIndices.reversed() {
                            existingExactKeys.remove(Self.normalizedURLKey(existing[idx].url))
                            if idx != firstIdx {
                                existing.remove(at: idx)
                            }
                        }
                        existing[firstIdx] = entry
                        existingExactKeys.insert(exactKey)
                        seenImportKeys.insert(exactKey)
                        seenImportHomeKeys.formUnion(homeKeys)
                        replacedCount += 1
                        continue
                    } else {
                        seenImportKeys.insert(exactKey)
                        seenImportHomeKeys.formUnion(homeKeys)
                        continue
                    }
                }
            }

            seenImportKeys.insert(exactKey)
            seenImportHomeKeys.formUnion(homeKeys)
            existingExactKeys.insert(exactKey)
            additions.append(entry)
        }

        guard !additions.isEmpty || replacedCount > 0 else { return 0 }
        if prepend {
            existing.insert(contentsOf: additions, at: 0)
        } else {
            existing.append(contentsOf: additions)
        }
        saveFavoritesOrder(Self.deduplicateFavorites(existing))
        return additions.count + replacedCount
    }

    static func deduplicateFavorites(_ entries: [BookmarkEntry]) -> [BookmarkEntry] {
        var result: [BookmarkEntry] = []
        var seenExact = Set<String>()
        var seenHome = Set<String>()
        for entry in entries {
            let exact = normalizedURLKey(entry.url)
            guard !exact.isEmpty, !seenExact.contains(exact) else { continue }
            let homeKeys = canonicalFavoriteHomepageKeys(url: entry.url, title: entry.title)
            if !homeKeys.isDisjoint(with: seenHome) {
                continue
            }
            seenExact.insert(exact)
            seenHome.formUnion(homeKeys)
            result.append(entry)
        }
        return result
    }

    /// Returns canonical deduplication keys for homepage / localized-root bookmarks so regional
    /// variants (`apple.com/tr` vs `apple.com/`, `google.com.tr/?client=safari&channel=iphone_bm`
    /// vs `google.com/?client=safari&channel=mac_bm`) never duplicate on the Start Page.
    /// Non-homepage deep links return an empty set so distinct pages on the same host stay separate.
    static func canonicalFavoriteHomepageKeys(url rawURL: String, title: String) -> Set<String> {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              var host = comps.host?.lowercased(), !host.isEmpty else {
            return []
        }
        if host.hasPrefix("www.") && host.count > 4 {
            host = String(host.dropFirst(4))
        } else if host.hasPrefix("m.") && host.count > 2 {
            host = String(host.dropFirst(2))
        }

        // Only treat empty path, "/", or a single locale segment ("/tr", "/en-us", "/uk") as a homepage.
        let pathSegments = comps.path.split(separator: "/").map(String.init)
        let isHomepagePath: Bool
        if pathSegments.isEmpty {
            isHomepagePath = true
        } else if pathSegments.count == 1 {
            let seg = pathSegments[0].lowercased()
            let parts = seg.split(separator: "-")
            let isLocaleSeg = (parts.count == 1 && seg.count == 2 && seg.allSatisfy(\.isLetter)) ||
                              (parts.count == 2 && parts[0].count == 2 && parts[1].count == 2 &&
                               parts[0].allSatisfy(\.isLetter) && parts[1].allSatisfy(\.isLetter))
            isHomepagePath = isLocaleSeg
        } else {
            isHomepagePath = false
        }
        guard isHomepagePath else { return [] }

        // Allow empty query or purely bookmark/referral/locale query parameters.
        let ignoredQueryKeys: Set<String> = [
            "client", "channel", "source", "ref", "hl", "gl",
            "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"
        ]
        if let queryItems = comps.queryItems, !queryItems.isEmpty {
            let hasMeaningfulQuery = queryItems.contains { !ignoredQueryKeys.contains($0.name.lowercased()) }
            if hasMeaningfulQuery { return [] }
        }

        var keys: Set<String> = ["host-home:\(host)"]

        // Extract brand label before TLD / multi-part ccTLD (e.g. google.com.tr -> google, yahoo.co.uk -> yahoo).
        let hostLabels = host.split(separator: ".").map(String.init)
        if hostLabels.count >= 2 {
            let last = hostLabels[hostLabels.count - 1]
            let secondLast = hostLabels[hostLabels.count - 2]
            let multiPartSecondLevels: Set<String> = ["com", "co", "org", "net", "gov", "edu"]
            let brandIndex: Int
            if hostLabels.count >= 3 && last.count == 2 && multiPartSecondLevels.contains(secondLast) {
                brandIndex = hostLabels.count - 3
            } else {
                brandIndex = hostLabels.count - 2
            }
            if brandIndex >= 0 {
                let brand = hostLabels[brandIndex]
                let normTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !brand.isEmpty && !normTitle.isEmpty {
                    keys.insert("brand-home:\(brand)|\(normTitle)")
                }
            }
        }
        return keys
    }

    // MARK: - Reading List Persistence

    static let readingListDefaultsKey = "Safarium.ReadingListEntries.v1"

    private static let defaultReadingListItems: [ReadingListItem] = [
        ReadingListItem(id: "rl-apple", title: "MacBook Pro - Apple", url: "https://www.apple.com/macbook-pro/", addedAt: Date()),
        ReadingListItem(id: "rl-github", title: "GitHub — Build and ship software", url: "https://github.com/", addedAt: Date()),
        ReadingListItem(id: "rl-webkit", title: "WebKit — Open Source Browser Engine", url: "https://webkit.org/", addedAt: Date())
    ]

    func readingList() -> [ReadingListItem] {
        if let cached = cachedReadingList {
            return cached
        }
        if let data = UserDefaults.standard.data(forKey: Self.readingListDefaultsKey),
           let decoded = try? JSONDecoder().decode([ReadingListItem].self, from: data) {
            cachedReadingList = decoded
            return decoded
        }
        cachedReadingList = Self.defaultReadingListItems
        return Self.defaultReadingListItems
    }

    @discardableResult
    func mergeImportedReadingList(_ imported: [ReadingListItem]) -> Int {
        guard !imported.isEmpty else { return 0 }
        var existing = readingList()
        var seen = Set(existing.map { Self.normalizedURLKey($0.url) })
        var additions: [ReadingListItem] = []
        for item in imported {
            let key = Self.normalizedURLKey(item.url)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            additions.append(item)
        }
        guard !additions.isEmpty else { return 0 }
        existing.insert(contentsOf: additions, at: 0)
        cachedReadingList = existing
        if let encoded = try? JSONEncoder().encode(existing) {
            UserDefaults.standard.set(encoded, forKey: Self.readingListDefaultsKey)
        }
        NotificationCenter.default.post(name: .safariumReadingListDidChange, object: nil)
        return additions.count
    }

    // MARK: - Browsing History Persistence

    var historyStoreURL: URL {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSup
            .appendingPathComponent("Safarium", isDirectory: true)
            .appendingPathComponent("browsing-history.json")
    }

    func browsingHistory() -> [HistoryEntry] {
        if let cached = cachedHistory {
            return cached
        }
        if let data = try? Data(contentsOf: historyStoreURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            cachedHistory = decoded
            return decoded
        }
        cachedHistory = []
        return []
    }

    func recordHistoryVisit(url: URL, title: String, visitedAt: Date = Date()) {
        guard url.isWebURL else { return }
        let urlStr = url.absoluteString
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? URLInputNormalizer.displayDomain(for: url) : cleanTitle
        var list = browsingHistory()
        let key = Self.normalizedURLKey(urlStr)
        if let idx = list.firstIndex(where: { Self.normalizedURLKey($0.url) == key }) {
            let prev = list.remove(at: idx)
            list.insert(
                HistoryEntry(
                    title: cleanTitle.isEmpty ? prev.title : cleanTitle,
                    url: urlStr,
                    visitCount: prev.visitCount == Int.max ? Int.max : prev.visitCount + 1,
                    lastVisited: visitedAt
                ),
                at: 0
            )
        } else {
            list.insert(
                HistoryEntry(title: resolvedTitle, url: urlStr, visitCount: 1, lastVisited: visitedAt),
                at: 0
            )
            if list.count > 2500 {
                list = Array(list.prefix(2500))
            }
        }
        saveHistory(list, notify: true)
    }

    /// Updates the stored title of an existing history entry once the page title arrives
    /// (the URL-change callback fires before the document title is known).
    func updateHistoryTitle(url: URL, title: String) {
        guard url.isWebURL else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.lowercased() != "about:blank" else { return }
        var list = browsingHistory()
        let key = Self.normalizedURLKey(url.absoluteString)
        guard let idx = list.firstIndex(where: { Self.normalizedURLKey($0.url) == key }),
              list[idx].title != clean else { return }
        list[idx].title = clean
        saveHistory(list, notify: false)
    }

    @discardableResult
    func mergeImportedHistory(_ imported: [HistoryEntry]) -> Int {
        guard !imported.isEmpty else { return 0 }
        var existing = browsingHistory()
        var indexByKey: [String: Int] = [:]
        for (idx, item) in existing.enumerated() {
            indexByKey[Self.normalizedURLKey(item.url)] = idx
        }
        var addedCount = 0
        for item in imported {
            let key = Self.normalizedURLKey(item.url)
            guard !key.isEmpty else { continue }
            if let existingIdx = indexByKey[key] {
                var current = existing[existingIdx]
                if item.lastVisited > current.lastVisited {
                    current.lastVisited = item.lastVisited
                    if !item.title.isEmpty { current.title = item.title }
                }
                current.visitCount = max(current.visitCount, item.visitCount)
                existing[existingIdx] = current
            } else {
                indexByKey[key] = existing.count
                existing.append(item)
                addedCount += 1
            }
        }
        existing.sort { $0.lastVisited > $1.lastVisited }
        if existing.count > 3000 {
            existing = Array(existing.prefix(3000))
        }
        saveHistory(existing, notify: true)
        return addedCount
    }

    enum HistoryClearRange: Int, CaseIterable {
        case lastHour = 0
        case today = 1
        case todayAndYesterday = 2
        case allHistory = 3

        var title: String {
            switch self {
            case .lastHour: return "Last Hour"
            case .today: return "Today"
            case .todayAndYesterday: return "Today and Yesterday"
            case .allHistory: return "All History"
            }
        }
    }

    func clearHistory(range: HistoryClearRange = .allHistory) {
        if range == .allHistory {
            saveHistory([], notify: true)
            SuggestionUsageStore.shared.clearAll()
            return
        }
        let now = Date()
        let cal = Calendar.current
        let cutoff: Date
        switch range {
        case .lastHour:
            cutoff = now.addingTimeInterval(-3600)
        case .today:
            cutoff = cal.startOfDay(for: now)
        case .todayAndYesterday:
            let todayStart = cal.startOfDay(for: now)
            cutoff = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-86400)
        case .allHistory:
            cutoff = .distantPast
        }
        let kept = browsingHistory().filter { $0.lastVisited < cutoff }
        saveHistory(kept, notify: true)
    }

    func removeHistoryEntries(urls: Set<String>) {
        guard !urls.isEmpty else { return }
        let normTargets = Set(urls.map { Self.normalizedURLKey($0) })
        let current = browsingHistory()
        let filtered = current.filter { !normTargets.contains(Self.normalizedURLKey($0.url)) }
        if filtered.count != current.count {
            saveHistory(filtered, notify: true)
        }
    }

    func pruneHistoryIfNeeded() {
        guard let maxAge = BrowserSettings.shared.historyRetentionSeconds else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let current = browsingHistory()
        let filtered = current.filter { $0.lastVisited >= cutoff }
        if filtered.count != current.count {
            saveHistory(filtered, notify: true)
        }
    }

    /// Serial so two quick saves can never land on disk out of order.
    static let historyWriteQueue = DispatchQueue(label: "com.safarium.history-writer", qos: .utility)

    private func saveHistory(_ entries: [HistoryEntry], notify: Bool) {
        cachedHistory = entries
        let fileURL = historyStoreURL
        let dirURL = fileURL.deletingLastPathComponent()
        Self.historyWriteQueue.async {
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        if notify {
            NotificationCenter.default.post(name: .safariumHistoryDidChange, object: nil)
        }
    }

    /// Test seam: drops the in-memory caches so the next read goes back to UserDefaults / disk.
    func invalidateCachesForTesting() {
        cachedFavorites = nil
        cachedReadingList = nil
        cachedHistory = nil
    }

    static func normalizedURLKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let comps = URLComponents(string: trimmed), let rawHost = comps.host, !rawHost.isEmpty {
            var host = rawHost.lowercased()
            if host.hasPrefix("www.") && host.count > 4 {
                host = String(host.dropFirst(4))
            }
            var portStr = ""
            let defaultPort: Int? = {
                switch comps.scheme?.lowercased() {
                case "http": return 80
                case "https": return 443
                default: return nil
                }
            }()
            if let port = comps.port, port != defaultPort {
                portStr = ":\(port)"
            }
            var path = comps.path
            while path.hasSuffix("/") {
                path.removeLast()
            }
            let query = (comps.query?.isEmpty == false) ? "?\(comps.query!)" : ""
            return "\(host)\(portStr)\(path)\(query)"  // URL paths are case-sensitive: only the host is lower-cased
        }
        var s = trimmed
        let lowerInput = s.lowercased()
        if lowerInput.hasPrefix("https://") { s.removeFirst(8) }
        else if lowerInput.hasPrefix("http://") { s.removeFirst(7) }
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = s[..<cut].lowercased() + s[cut...]
        } else {
            s = s.lowercased()
        }
        if s.lowercased().hasPrefix("www.") && s.count > 4 { s.removeFirst(4) }
        while s.hasSuffix("/") && s.count > 1 { s.removeLast() }
        return s
    }

    /// Loads pull-to-refresh spinner frames from `Reference/Animations/spinner/`.
    func spinnerFrames(phase: String) -> [NSImage] {
        let dir = referenceRootURL
            .appendingPathComponent("Animations/spinner", isDirectory: true)
            .resolvingSymlinksInPath()
        let count = (phase == "pull") ? 24 : 16
        let start = (phase == "pull") ? 1 : 0
        var frames: [NSImage] = []
        for idx in start..<(start + count) {
            let name = String(format: "%@-%02d@2x.png", phase, idx)
            if let img = NSImage(contentsOf: dir.appendingPathComponent(name)) {
                img.size = NSSize(width: 22, height: 22)
                frames.append(img)
            }
        }
        return frames
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }), let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
