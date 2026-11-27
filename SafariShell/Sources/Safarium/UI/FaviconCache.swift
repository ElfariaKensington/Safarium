import AppKit

/// Authentic macOS Safari Touch Icon & Favicon cache (`~/Library/Caches/Safarium/TouchIcons/` & `Favicons/`):
/// - Fetches real website touch icons directly from the web using Safari's exact discovery protocol:
///   `<link rel="apple-touch-icon-precomposed">`, `<link rel="apple-touch-icon">`, `<base href>`,
///   standard root probes (`/apple-touch-icon-precomposed.png`, `/apple-touch-icon.png`, etc.),
///   `<link rel="fluid-icon">`, high-res `<link rel="icon">`, square `<meta itemprop="image">`, and Web App Manifest icons.
/// - Enforces Safari's Retina touch-icon quality bar (`>= 72×72 px` square). When a site has no high-res touch icon,
///   extracts the dominant vibrant color from the site's real favicon pixels or `<meta name="theme-color">` so tiles
///   render Safari's native monogram fallback with zero hardcoded brand artwork.
final class FaviconCache {
    static let shared = FaviconCache()

    struct TouchIconResult {
        let image: NSImage?
        let isOpaque: Bool
        let hasTightEdges: Bool
        let accentColor: NSColor?
    }

    struct DiskTouchMeta: Codable {
        let version: Int
        let hasTouchIcon: Bool
        let isOpaque: Bool
        let hasTightEdges: Bool
        let r: Double?
        let g: Double?
        let b: Double?
    }

    static let metaVersion = 3
    private static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let cacheDir: URL
    private let touchCacheDir: URL
    private let lock = NSLock()
    static let maxFaviconMemoryEntries = 200
    static let maxTouchMemoryEntries = 100
    private(set) var memoryCache: [String: NSImage] = [:]
    private(set) var memoryOrder: [String] = []
    private var inFlightCallbacks: [String: [(NSImage?) -> Void]] = [:]

    private(set) var touchMemoryCache: [String: TouchIconResult] = [:]
    private(set) var touchMemoryOrder: [String] = []
    private var touchInFlightCallbacks: [String: [(TouchIconResult) -> Void]] = [:]

    /// Must be called while holding `lock`.
    private func insertMemoryFaviconLocked(_ image: NSImage, forKey key: String) {
        if memoryCache[key] == nil {
            memoryOrder.append(key)
        }
        memoryCache[key] = image
        while memoryOrder.count > Self.maxFaviconMemoryEntries {
            let oldest = memoryOrder.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    /// Must be called while holding `lock`.
    private func insertTouchMemoryLocked(_ result: TouchIconResult, forKey key: String) {
        if touchMemoryCache[key] == nil {
            touchMemoryOrder.append(key)
        }
        touchMemoryCache[key] = result
        while touchMemoryOrder.count > Self.maxTouchMemoryEntries {
            let oldest = touchMemoryOrder.removeFirst()
            touchMemoryCache.removeValue(forKey: oldest)
        }
    }

    private let fetchQueue = DispatchQueue(label: "com.safarium.touchicon.fetch", qos: .userInitiated, attributes: .concurrent)
    private lazy var urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 6.0
        cfg.timeoutIntervalForResource = 12.0
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = caches.appendingPathComponent("Safarium/Favicons", isDirectory: true)
        self.touchCacheDir = caches.appendingPathComponent("Safarium/TouchIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: touchCacheDir, withIntermediateDirectories: true)
    }

    func normalizedHost(for urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func rawHost(for urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }

    /// Stores a live tab favicon obtained from Chromium so Start Page, Sidebar, and Popover can reuse it.
    func store(_ image: NSImage, forURL url: URL?) {
        guard let url, let host = normalizedHost(for: url.absoluteString) else { return }
        lock.lock()
        insertMemoryFaviconLocked(image, forKey: host)
        lock.unlock()
        saveToDisk(image: image, host: host)

        // If Chromium delivered a real high-res touch icon (>= 72px square) and we don't already have one cached, promote it.
        if let px = Self.pixelSize(of: image), min(px.width, px.height) >= 72, Self.isRoughlySquare(px) {
            let existing = cachedTouchIcon(forURLString: url.absoluteString)
            if existing?.image == nil {
                let opaque = Self.hasOpaqueCorners(image)
                let tight = !opaque && Self.hasTightOpaqueEdges(image)
                let result = TouchIconResult(image: image, isOpaque: opaque, hasTightEdges: tight, accentColor: nil)
                lock.lock()
                insertTouchMemoryLocked(result, forKey: host)
                lock.unlock()
                saveTouchIconToDisk(result, host: host)
            }
        }
    }

    // MARK: - Small Favicons (Tabs & inline indicators)

    func cachedImage(forURLString urlString: String) -> NSImage? {
        guard let host = normalizedHost(for: urlString) else { return nil }
        lock.lock()
        if let mem = memoryCache[host] {
            lock.unlock()
            return mem
        }
        lock.unlock()

        let fileURL = diskURL(forHost: host)
        if let diskImg = NSImage(contentsOf: fileURL), diskImg.size.width >= 16 {
            lock.lock()
            insertMemoryFaviconLocked(diskImg, forKey: host)
            lock.unlock()
            return diskImg
        }
        return nil
    }

    /// Memory-only fast lookup (zero disk I/O) for hot UI paths like address bar focus animations.
    func memoryCachedIcon(forURLString urlString: String) -> NSImage? {
        guard let host = normalizedHost(for: urlString) else { return nil }
        lock.lock()
        let img = memoryCache[host] ?? touchMemoryCache[host]?.image
        lock.unlock()
        return img
    }

    /// Returns the best already-cached icon for a URL: small tab favicon first, then cached high-res touch icon.
    func bestCachedIcon(forURLString urlString: String) -> NSImage? {
        if let small = cachedImage(forURLString: urlString) {
            return small
        }
        if let touchImg = cachedTouchIcon(forURLString: urlString)?.image {
            return touchImg
        }
        return nil
    }

    func fetchFavicon(forURLString urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard let host = normalizedHost(for: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if let cached = bestCachedIcon(forURLString: urlString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        if inFlightCallbacks[host] != nil {
            inFlightCallbacks[host]?.append(completion)
            lock.unlock()
            return
        }
        inFlightCallbacks[host] = [completion]
        lock.unlock()

        let requestHost = rawHost(for: urlString) ?? host
        let pageURL = URL(string: urlString)
        let rootURL = URL(string: "https://\(requestHost)/")
        fetchQueue.async { [weak self] in
            guard let self else { return }

            // 1. Discover `<link rel="icon">` / `<link rel="shortcut icon">` from HTML `<head>`
            //    (preferring crisp transparent PNG/ICO over opaque touch icons, matching Safari).
            //    If a deep page URL fails or lacks icon links, also probe the site's root page.
            var pagesToProbe: [URL] = []
            if let pageURL { pagesToProbe.append(pageURL) }
            if let rootURL, rootURL.absoluteString != pageURL?.absoluteString {
                pagesToProbe.append(rootURL)
            }

            var touchIconFallbackURLs: [URL] = []
            for targetPage in pagesToProbe {
                if let (htmlData, finalURL) = Optional(self.syncFetchData(url: targetPage, maxBytes: 120_000, acceptHTML: true)),
                   let htmlData,
                   let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) {
                    let baseURL = finalURL ?? targetPage
                    let candidates = self.discoverTabFaviconURLs(in: html, baseURL: baseURL)
                    for iconURL in candidates {
                        if let data = self.syncFetchData(url: iconURL, maxBytes: 256_000).data,
                           let img = NSImage(data: data), img.size.width >= 16 {
                            self.saveToDisk(image: img, host: host)
                            self.finishFavicon(host: host, image: img)
                            return
                        }
                    }
                    // Collect any declared apple-touch-icon as a fallback if `/favicon.ico` fails
                    if touchIconFallbackURLs.isEmpty {
                        for tag in self.allMatches(in: html, pattern: #"<link\b[^>]*>"#) {
                            let attrs = self.parseHTMLAttributes(tag)
                            guard let relRaw = attrs["rel"]?.lowercased(),
                                  let href = attrs["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !href.isEmpty, !href.hasPrefix("data:") else { continue }
                            let tokens = Set(relRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init))
                            if tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed"),
                               let u = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                                touchIconFallbackURLs.append(u)
                            }
                        }
                    }
                    if !candidates.isEmpty { break }
                }
            }

            // 2. Fallback to root `/favicon.ico`
            if let probe = URL(string: "https://\(requestHost)/favicon.ico"),
               let data = self.syncFetchData(url: probe, maxBytes: 256_000).data,
               let img = NSImage(data: data), img.size.width >= 16 {
                self.saveToDisk(image: img, host: host)
                self.finishFavicon(host: host, image: img)
                return
            }

            // 3. Fallback to declared or root `apple-touch-icon` PNGs (many modern sites omit `.ico` or serve SVG-only icons)
            var fallbackProbes = touchIconFallbackURLs
            if let rootTouch1 = URL(string: "https://\(requestHost)/apple-touch-icon.png") {
                fallbackProbes.append(rootTouch1)
            }
            if let rootTouch2 = URL(string: "https://\(requestHost)/apple-touch-icon-precomposed.png") {
                fallbackProbes.append(rootTouch2)
            }
            var seenFallback = Set<String>()
            for fallbackURL in fallbackProbes {
                guard seenFallback.insert(fallbackURL.absoluteString).inserted else { continue }
                if let data = self.syncFetchData(url: fallbackURL, maxBytes: 512_000).data,
                   let img = NSImage(data: data), img.size.width >= 16 {
                    self.saveToDisk(image: img, host: host)
                    self.finishFavicon(host: host, image: img)
                    return
                }
            }

            self.finishFavicon(host: host, image: nil)
        }
    }

    func discoverTabFaviconURLs(in html: String, baseURL: URL) -> [URL] {
        var resolvedBase = baseURL
        if let baseTag = firstMatch(in: html, pattern: #"<base\b[^>]*>"#) {
            let attrs = parseHTMLAttributes(baseTag)
            if let href = attrs["href"], let u = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                resolvedBase = u
            }
        }

        var scored: [(Int, URL)] = []
        var seen = Set<String>()
        for tag in allMatches(in: html, pattern: #"<link\b[^>]*>"#) {
            let attrs = parseHTMLAttributes(tag)
            guard let relRaw = attrs["rel"]?.lowercased(),
                  let href = attrs["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty, !href.hasPrefix("data:") else { continue }
            let tokens = Set(relRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            guard tokens.contains("icon") || tokens.contains("shortcut") else { continue }
            guard !tokens.contains("apple-touch-icon"), !tokens.contains("apple-touch-icon-precomposed"), !tokens.contains("mask-icon") else { continue }
            guard let u = URL(string: href, relativeTo: resolvedBase)?.absoluteURL else { continue }
            let key = u.absoluteString.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let type = attrs["type"]?.lowercased() ?? ""
            let sz = parseDeclaredIconSize(attrs["sizes"])
            var score = 40
            if type.contains("png") || key.hasSuffix(".png") {
                score += 24
            } else if type.contains("x-icon") || type.contains("vnd.microsoft.icon") || key.hasSuffix(".ico") {
                score += 18
            } else if type.contains("svg") || key.hasSuffix(".svg") {
                // AppKit NSImage(data:) cannot natively decode raw SVG; keep lower priority for URLSession fallback
                score -= 25
            }
            if sz >= 32 && sz <= 96 {
                score += 16
            } else if sz > 96 {
                score += 8
            }
            scored.append((score, u))
        }
        scored.sort { $0.0 > $1.0 }
        return scored.map(\.1)
    }

    private func finishFavicon(host: String, image: NSImage?) {
        lock.lock()
        if let image {
            insertMemoryFaviconLocked(image, forKey: host)
        }
        let callbacks = inFlightCallbacks.removeValue(forKey: host) ?? []
        lock.unlock()

        DispatchQueue.main.async {
            for cb in callbacks {
                cb(image)
            }
        }
    }

    // MARK: - Real Safari Touch Icons (Start Page Favorites, Address Bar Popover, Bookmarks)

    func cachedTouchIcon(forURLString urlString: String) -> TouchIconResult? {
        guard let host = normalizedHost(for: urlString) else { return nil }
        lock.lock()
        if let mem = touchMemoryCache[host] {
            lock.unlock()
            return mem
        }
        lock.unlock()

        let metaURL = touchMetaDiskURL(forHost: host)
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(DiskTouchMeta.self, from: metaData),
              meta.version == Self.metaVersion else {
            return nil
        }

        var loadedImage: NSImage?
        if meta.hasTouchIcon {
            let imgURL = touchImageDiskURL(forHost: host)
            loadedImage = NSImage(contentsOf: imgURL)
            if loadedImage == nil { return nil }
        }
        var color: NSColor?
        if let r = meta.r, let g = meta.g, let b = meta.b {
            color = NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
        }
        let res = TouchIconResult(
            image: loadedImage,
            isOpaque: meta.isOpaque,
            hasTightEdges: meta.hasTightEdges,
            accentColor: color
        )
        lock.lock()
        insertTouchMemoryLocked(res, forKey: host)
        lock.unlock()
        return res
    }

    func fetchTouchIcon(forURLString urlString: String, completion: @escaping (TouchIconResult) -> Void) {
        guard let host = normalizedHost(for: urlString) else {
            DispatchQueue.main.async {
                completion(TouchIconResult(image: nil, isOpaque: true, hasTightEdges: false, accentColor: nil))
            }
            return
        }

        if let cached = cachedTouchIcon(forURLString: urlString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        if touchInFlightCallbacks[host] != nil {
            touchInFlightCallbacks[host]?.append(completion)
            lock.unlock()
            return
        }
        touchInFlightCallbacks[host] = [completion]
        lock.unlock()

        let targetHost = rawHost(for: urlString) ?? host
        fetchQueue.async { [weak self] in
            guard let self else { return }
            let result = self.discoverRealTouchIcon(originalURLString: urlString, requestHost: targetHost, normalizedHost: host)
            self.saveTouchIconToDisk(result, host: host)
            self.finishTouchIcon(host: host, result: result)
        }
    }

    private func finishTouchIcon(host: String, result: TouchIconResult) {
        lock.lock()
        insertTouchMemoryLocked(result, forKey: host)
        let callbacks = touchInFlightCallbacks.removeValue(forKey: host) ?? []
        lock.unlock()

        DispatchQueue.main.async {
            for cb in callbacks {
                cb(result)
            }
        }
    }

    /// Runs Safari's authentic web touch-icon discovery (`<base>`, `<link rel="apple-touch-icon*">`,
    /// standard root `/apple-touch-icon*.png`, `fluid-icon`, high-res `<link rel="icon">`, square
    /// `<meta itemprop="image">`/`msapplication-TileImage`, manifest icons, and dominant color extraction from small favicons).
    private func discoverRealTouchIcon(originalURLString: String, requestHost: String, normalizedHost: String) -> TouchIconResult {
        let baseOrigin = URL(string: "https://\(requestHost)/")!
        let htmlRes = syncFetchData(url: baseOrigin, maxBytes: 220_000, acceptHTML: true)
        let finalPageURL = htmlRes.finalURL ?? baseOrigin
        let finalOrigin: URL = {
            var comps = URLComponents()
            comps.scheme = finalPageURL.scheme ?? "https"
            comps.host = finalPageURL.host ?? requestHost
            comps.path = "/"
            return comps.url ?? baseOrigin
        }()

        var appleTouchCandidates: [(Int, URL)] = []
        var standardIconCandidates: [(Int, URL)] = []
        var squareMetaCandidates: [URL] = []
        var manifestURL: URL?
        var themeColorHex: String?

        if let data = htmlRes.data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let headSlice: String
            if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
                headSlice = String(html[..<headEnd.upperBound])
            } else {
                headSlice = String(html.prefix(120_000))
            }

            // Respect HTML <base href="..."> (critical for sites like iCloud!)
            var resolveBase = finalPageURL
            if let baseTag = firstMatch(in: headSlice, pattern: #"<base\b[^>]*>"#),
               let baseHref = parseHTMLAttributes(baseTag)["href"],
               let resolved = URL(string: baseHref, relativeTo: finalPageURL)?.absoluteURL {
                resolveBase = resolved
            }

            // Parse <link ...> tags
            for linkTag in allMatches(in: headSlice, pattern: #"<link\b[^>]*>"#) {
                let attrs = parseHTMLAttributes(linkTag)
                guard let relRaw = attrs["rel"]?.lowercased(), let href = attrs["href"], !href.isEmpty else { continue }
                let relTokens = Set(relRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init))
                guard let resolved = URL(string: href, relativeTo: resolveBase)?.absoluteURL else { continue }

                if relTokens.contains("manifest") && manifestURL == nil {
                    manifestURL = resolved
                    continue
                }
                if relTokens.contains("mask-icon") { continue }

                let declaredSize = parseDeclaredIconSize(attrs["sizes"])
                if relTokens.contains("apple-touch-icon") || relTokens.contains("apple-touch-icon-precomposed") {
                    let boost = relTokens.contains("apple-touch-icon-precomposed") ? 1 : 0
                    appleTouchCandidates.append((declaredSize * 2 + boost, resolved))
                } else if relTokens.contains("fluid-icon") {
                    standardIconCandidates.append((max(declaredSize, 256), resolved))
                } else if relTokens.contains("icon") {
                    standardIconCandidates.append((declaredSize, resolved))
                }
            }

            // Parse <meta ...> tags for theme-color, msapplication-TileImage, and square itemprop="image"
            for metaTag in allMatches(in: headSlice, pattern: #"<meta\b[^>]*>"#) {
                let attrs = parseHTMLAttributes(metaTag)
                guard let content = attrs["content"], !content.isEmpty else { continue }
                let name = attrs["name"]?.lowercased() ?? ""
                let itemprop = attrs["itemprop"]?.lowercased() ?? ""
                if name == "theme-color" && themeColorHex == nil {
                    themeColorHex = content
                } else if name == "msapplication-tileimage" || itemprop == "image" {
                    if let resolved = URL(string: content, relativeTo: resolveBase)?.absoluteURL {
                        squareMetaCandidates.append(resolved)
                    }
                }
            }
        }

        appleTouchCandidates.sort { $0.0 > $1.0 }
        standardIconCandidates.sort { $0.0 > $1.0 }

        // Build deduplicated Safari candidate probe list in strict priority order
        var seen = Set<String>()
        var orderedProbes: [(url: URL, requireStrictSquare: Bool)] = []
        func appendProbe(_ url: URL, strictSquare: Bool = false) {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                orderedProbes.append((url, strictSquare))
            }
        }

        // Priority 1: Declared apple-touch-icon* from HTML
        for (_, u) in appleTouchCandidates.prefix(5) { appendProbe(u) }

        // Priority 2: Standard Safari root probes on both final origin and requested origin
        let rootPaths = [
            "/apple-touch-icon-precomposed.png",
            "/apple-touch-icon.png",
            "/apple-touch-icon-180x180.png",
            "/apple-touch-icon-152x152.png",
            "/apple-touch-icon-120x120.png"
        ]
        for origin in [finalOrigin, baseOrigin] {
            for p in rootPaths {
                if let u = URL(string: p, relativeTo: origin)?.absoluteURL {
                    appendProbe(u)
                }
            }
        }

        // Priority 3: fluid-icon and declared <link rel="icon">
        for (_, u) in standardIconCandidates.prefix(5) { appendProbe(u) }

        // Priority 4: Square <meta itemprop="image"> / msapplication-TileImage
        for u in squareMetaCandidates.prefix(2) { appendProbe(u, strictSquare: true) }

        // Priority 5: Web App Manifest icons (only fetched if above didn't already include high-res candidates)
        if appleTouchCandidates.isEmpty, let manifestURL {
            for u in fetchManifestIconURLs(manifestURL: manifestURL).prefix(3) {
                appendProbe(u)
            }
        }

        var bestSmallFavicon: NSImage?
        var bestSmallArea = 0

        for probe in orderedProbes {
            let resp = syncFetchData(url: probe.url, maxBytes: 1_200_000, acceptHTML: false)
            guard let data = resp.data, !data.isEmpty,
                  let img = NSImage(data: data),
                  let px = Self.pixelSize(of: img),
                  px.width >= 16, px.height >= 16 else {
                continue
            }

            let ratio = Double(px.width) / Double(max(1, px.height))
            let squareOK = probe.requireStrictSquare
                ? (ratio >= 0.88 && ratio <= 1.14)
                : (ratio >= 0.78 && ratio <= 1.28)
            guard squareOK else { continue }

            // Safari's Retina touch-icon bar: >= 72×72 px real image
            if min(px.width, px.height) >= 72 {
                let opaque = Self.hasOpaqueCorners(img)
                let tight = !opaque && Self.hasTightOpaqueEdges(img)
                // Also populate small favicon cache if empty
                if cachedImage(forURLString: originalURLString) == nil {
                    saveToDisk(image: img, host: normalizedHost)
                    lock.lock()
                    insertMemoryFaviconLocked(img, forKey: normalizedHost)
                    lock.unlock()
                }
                return TouchIconResult(image: img, isOpaque: opaque, hasTightEdges: tight, accentColor: nil)
            }

            let area = px.width * px.height
            if area > bestSmallArea {
                bestSmallArea = area
                bestSmallFavicon = img
            }
        }

        // Fallback: probe /favicon.ico strictly for dominant color extraction (never upscaled!)
        if bestSmallFavicon == nil {
            if let cachedSmall = cachedImage(forURLString: originalURLString) {
                bestSmallFavicon = cachedSmall
            } else {
                for origin in [finalOrigin, baseOrigin] {
                    if let favURL = URL(string: "/favicon.ico", relativeTo: origin)?.absoluteURL,
                       let data = syncFetchData(url: favURL, maxBytes: 256_000, acceptHTML: false).data,
                       let img = NSImage(data: data), img.size.width >= 16 {
                        bestSmallFavicon = img
                        saveToDisk(image: img, host: normalizedHost)
                        lock.lock()
                        insertMemoryFaviconLocked(img, forKey: normalizedHost)
                        lock.unlock()
                        break
                    }
                }
            }
        }

        // Extract dominant vibrant color from the real favicon pixels, or <meta name="theme-color">
        var accent: NSColor? = nil
        if let small = bestSmallFavicon {
            accent = Self.extractDominantVibrantColor(from: small)
        }
        if accent == nil, let hex = themeColorHex, let parsed = NSColor(hexString: hex), Self.isSuitableMonogramColor(parsed) {
            accent = parsed
        }
        return TouchIconResult(image: nil, isOpaque: true, hasTightEdges: false, accentColor: accent)
    }

    private func fetchManifestIconURLs(manifestURL: URL) -> [URL] {
        guard let data = syncFetchData(url: manifestURL, maxBytes: 120_000, acceptHTML: false).data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = json["icons"] as? [[String: Any]] else {
            return []
        }
        var items: [(Int, URL)] = []
        for entry in icons {
            guard let src = entry["src"] as? String,
                  let resolved = URL(string: src, relativeTo: manifestURL)?.absoluteURL else { continue }
            let sz = parseDeclaredIconSize(entry["sizes"] as? String)
            if sz >= 72 || sz == 0 {
                items.append((sz, resolved))
            }
        }
        items.sort { $0.0 > $1.0 }
        return items.map(\.1)
    }

    private func syncFetchData(url: URL, maxBytes: Int, acceptHTML: Bool = false) -> (data: Data?, finalURL: URL?) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.5
        req.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        if acceptHTML {
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        } else {
            req.setValue("image/png,image/webp,image/jpeg,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        }

        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        var outURL: URL?
        let task = urlSession.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            outURL = http.url
            if let data {
                outData = data.count > maxBytes ? Data(data.prefix(maxBytes)) : data
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 6.0)
        return (outData, outURL)
    }

    // MARK: - HTML Parsing Helpers

    func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    func allMatches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    func parseHTMLAttributes(_ tag: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: #"([a-zA-Z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else {
            return [:]
        }
        let ns = tag as NSString
        var attrs: [String: String] = [:]
        for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let valRange = m.range(at: 2).location != NSNotFound ? m.range(at: 2)
                : (m.range(at: 3).location != NSNotFound ? m.range(at: 3) : m.range(at: 4))
            if valRange.location != NSNotFound {
                attrs[key] = ns.substring(with: valRange)
            }
        }
        return attrs
    }

    func parseDeclaredIconSize(_ sizes: String?) -> Int {
        guard let sizes, !sizes.isEmpty else { return 0 }
        var best = 0
        for part in sizes.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            let dims = part.split(separator: "x")
            if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]), w == h {
                best = max(best, w)
            }
        }
        return best
    }

    // MARK: - Pixel Analysis (Transparency & Safari Dominant Color Extraction)

    static func pixelSize(of image: NSImage) -> (width: Int, height: Int)? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (cg.width, cg.height)
        }
        let w = Int(image.size.width.rounded())
        let h = Int(image.size.height.rounded())
        return (w > 0 && h > 0) ? (w, h) : nil
    }

    static func isRoughlySquare(_ px: (width: Int, height: Int)) -> Bool {
        let ratio = Double(px.width) / Double(max(1, px.height))
        return ratio >= 0.78 && ratio <= 1.28
    }

    static func hasOpaqueCorners(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width >= 8, cg.height >= 8 else { return false }
        let alphaInfo = cg.alphaInfo
        if alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast {
            return true
        }
        // Render into canonical 32x32 RGBA bitmap for rock-solid pixel inspection across all color spaces
        var buf = [UInt8](repeating: 0, count: 32 * 32 * 4)
        guard let ctx = CGContext(
            data: &buf,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 32 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))

        let corners = [(1, 1), (30, 1), (1, 30), (30, 30)]
        for (x, y) in corners {
            let a = buf[(y * 32 + x) * 4 + 3]
            if a < 235 { return false }
        }
        return true
    }

    /// Returns true when a transparent-corner icon is a floating logo (not a pre-rounded full square badge)
    /// whose ink reaches near the outer edge and needs Safari's gentle breathing inset on a white card.
    static func hasTightOpaqueEdges(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        var buf = [UInt8](repeating: 0, count: 32 * 32 * 4)
        guard let ctx = CGContext(
            data: &buf,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 32 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))

        var minX = 32, maxX = -1, minY = 32, maxY = -1
        var filledPixels = 0
        for y in 0..<32 {
            for x in 0..<32 {
                let idx = (y * 32 + x) * 4
                let a = buf[idx + 3]
                if a > 30 {
                    let r = buf[idx], g = buf[idx + 1], b = buf[idx + 2]
                    if !(r > 246 && g > 246 && b > 246 && a > 240) {
                        filledPixels += 1
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                    }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return false }
        let fillFraction = Double(filledPixels) / (32.0 * 32.0)
        // Pre-rounded square badges (high fill density >= 0.65) should fill the squircle edge-to-edge without an extra white frame
        if fillFraction >= 0.65 {
            return false
        }
        let margin = min(minX, 31 - maxX, minY, 31 - maxY)
        return margin <= 2
    }

    /// Extracts the dominant vibrant color from real favicon pixels (matching Safari's `extracted_color` for monogram tiles).
    static func extractDominantVibrantColor(from image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let dim = 24
        var buf = [UInt8](repeating: 0, count: dim * dim * 4)
        guard let ctx = CGContext(
            data: &buf,
            width: dim,
            height: dim,
            bitsPerComponent: 8,
            bytesPerRow: dim * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        // Quantize into 18 hue buckets and accumulate saturation-weighted RGB
        struct Bucket {
            var weight: Double = 0
            var r: Double = 0
            var g: Double = 0
            var b: Double = 0
        }
        var buckets = [Bucket](repeating: Bucket(), count: 18)

        for i in 0..<(dim * dim) {
            let idx = i * 4
            let a = Double(buf[idx + 3]) / 255.0
            guard a >= 0.45 else { continue }
            let r = min(1.0, (Double(buf[idx]) / 255.0) / a)
            let g = min(1.0, (Double(buf[idx + 1]) / 255.0) / a)
            let b = min(1.0, (Double(buf[idx + 2]) / 255.0) / a)

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            let sat = maxC > 0.001 ? delta / maxC : 0.0
            let luma = 0.299 * r + 0.587 * g + 0.114 * b

            // Skip near-white, near-black, and neutral gray pixels
            guard sat >= 0.24, max(r, g, b) >= 0.30, luma <= 0.86 else { continue }

            var hue: Double = 0
            if delta > 0.0001 {
                if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0) }
                else if maxC == g { hue = (b - r) / delta + 2.0 }
                else { hue = (r - g) / delta + 4.0 }
                hue /= 6.0
                if hue < 0 { hue += 1.0 }
            }
            let bIdx = min(17, max(0, Int(hue * 18.0)))
            let w = sat * a
            buckets[bIdx].weight += w
            buckets[bIdx].r += r * w
            buckets[bIdx].g += g * w
            buckets[bIdx].b += b * w
        }

        guard let best = buckets.max(by: { $0.weight < $1.weight }), best.weight >= 4.0 else {
            return nil
        }
        let r = best.r / best.weight
        let g = best.g / best.weight
        let b = best.b / best.weight
        // Ensure white monogram text always has crisp contrast (clamp extreme lightness)
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        let scale = luma > 0.68 ? (0.64 / luma) : 1.0
        return NSColor(srgbRed: CGFloat(r * scale), green: CGFloat(g * scale), blue: CGFloat(b * scale), alpha: 1.0)
    }

    static func isSuitableMonogramColor(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        let maxC = max(r, g, b), minC = min(r, g, b)
        let sat = maxC > 0.001 ? (maxC - minC) / maxC : 0.0
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        return sat >= 0.20 && luma >= 0.15 && luma <= 0.78
    }

    // MARK: - Disk Persistence

    func safeFilename(_ host: String) -> String {
        host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    func diskURL(forHost host: String) -> URL {
        cacheDir.appendingPathComponent("\(safeFilename(host)).png")
    }

    func touchImageDiskURL(forHost host: String) -> URL {
        touchCacheDir.appendingPathComponent("\(safeFilename(host)).png")
    }

    func touchMetaDiskURL(forHost host: String) -> URL {
        touchCacheDir.appendingPathComponent("\(safeFilename(host)).meta.json")
    }

    private func saveToDisk(image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: diskURL(forHost: host), options: .atomic)
    }

    private func saveTouchIconToDisk(_ result: TouchIconResult, host: String) {
        if let img = result.image,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: touchImageDiskURL(forHost: host), options: .atomic)
        }
        let srgb = result.accentColor?.usingColorSpace(.sRGB)
        let meta = DiskTouchMeta(
            version: Self.metaVersion,
            hasTouchIcon: result.image != nil,
            isOpaque: result.isOpaque,
            hasTightEdges: result.hasTightEdges,
            r: srgb.map { Double($0.redComponent) },
            g: srgb.map { Double($0.greenComponent) },
            b: srgb.map { Double($0.blueComponent) }
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: touchMetaDiskURL(forHost: host), options: .atomic)
        }
    }
}
