import AppKit
import XCTest
@testable import Safarium

/// Image fixtures and HTML/favicon helpers for FaviconCache. Pixel fixtures are rendered into real CGImages.
enum FaviconFixtures {
    static func image(width: Int, height: Int, alpha: CGImageAlphaInfo = .premultipliedLast,
                      pointSize: NSSize? = nil, draw: (CGContext) -> Void = { _ in }) -> NSImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue)!
        draw(ctx)
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: pointSize ?? NSSize(width: width, height: height))
    }

    static func solid(_ size: Int, r: CGFloat = 1, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1) -> NSImage {
        image(width: size, height: size) { ctx in
            ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    static func fill(_ ctx: CGContext, rect: CGRect, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        ctx.setFillColor(red: r, green: g, blue: b, alpha: a)
        ctx.fill(rect)
    }

    static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

final class FaviconCacheTests: HermeticTestCase {
    private var hosts: [String] = []
    // Lazy on purpose: XCTest builds test instances before setUp installs the sandbox, so an eager
    // `FaviconCache.shared` would create its cache folders in the real home.
    private var cache: FaviconCache { FaviconCache.shared }

    override func tearDown() {
        for host in hosts {
            try? FileManager.default.removeItem(at: cache.diskURL(forHost: host))
            try? FileManager.default.removeItem(at: cache.touchImageDiskURL(forHost: host))
            try? FileManager.default.removeItem(at: cache.touchMetaDiskURL(forHost: host))
        }
        hosts = []
        super.tearDown()
    }

    /// Returns a fresh host name so tests never share in-memory or on-disk cache entries.
    private func freshHost(_ label: String = "fav") -> String {
        let host = "\(label)-\(UUID().uuidString.prefix(8).lowercased()).test"
        hosts.append(host)
        return host
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        let data = try XCTUnwrap(FaviconFixtures.pngData(of: image))
        try data.write(to: url, options: .atomic)
    }

    private func writeMeta(_ json: String, host: String) throws {
        try Data(json.utf8).write(to: cache.touchMetaDiskURL(forHost: host), options: .atomic)
    }

    // MARK: - Host normalisation

    func testNormalizedHostLowercasesAndStripsOneWww() {
        XCTAssertEqual(cache.normalizedHost(for: "https://WWW.Example.com/a"), "example.com")
        XCTAssertEqual(cache.normalizedHost(for: "https://www.www.x.test"), "www.x.test")
        XCTAssertEqual(cache.normalizedHost(for: "https://sub.example.com"), "sub.example.com")
        XCTAssertEqual(cache.normalizedHost(for: "http://localhost:8080/x"), "localhost")
    }

    func testNormalizedHostIsNilWithoutAUsableHost() {
        for raw in ["", "example.com", "not a url", "file:///tmp/a.html", "mailto:someone@example.com"] {
            XCTAssertNil(cache.normalizedHost(for: raw), "expected nil for \(raw.debugDescription)")
        }
    }

    func testRawHostKeepsWwwButStillLowercases() {
        XCTAssertEqual(cache.rawHost(for: "https://WWW.Example.com"), "www.example.com")
        XCTAssertNil(cache.rawHost(for: "example.com"))
        XCTAssertNil(cache.rawHost(for: ""))
    }

    // MARK: - Disk paths

    func testDiskPathsSanitizeSlashesAndColonsAndLiveInTheirCacheFolders() {
        let host = "a/b:c.test"
        XCTAssertEqual(cache.diskURL(forHost: host).lastPathComponent, "a_b_c.test.png")
        XCTAssertEqual(cache.touchImageDiskURL(forHost: host).lastPathComponent, "a_b_c.test.png")
        XCTAssertEqual(cache.touchMetaDiskURL(forHost: host).lastPathComponent, "a_b_c.test.meta.json")
        XCTAssertEqual(cache.diskURL(forHost: host).deletingLastPathComponent().lastPathComponent, "Favicons")
        XCTAssertEqual(cache.touchImageDiskURL(forHost: host).deletingLastPathComponent().lastPathComponent, "TouchIcons")
        XCTAssertEqual(cache.touchMetaDiskURL(forHost: host).deletingLastPathComponent().lastPathComponent, "TouchIcons")
    }

    func testDiskPathsResideInsideTheHermeticSandbox() {
        XCTAssertTrue(cache.diskURL(forHost: "x.test").path.hasPrefix(Self.sandboxRoot.path), cache.diskURL(forHost: "x.test").path + " vs " + Self.sandboxRoot.path)
        XCTAssertTrue(cache.touchImageDiskURL(forHost: "x.test").path.hasPrefix(Self.sandboxRoot.path))
    }

    // MARK: - Small favicon memory and disk cache

    func testStoredImageIsReturnedFromMemoryForAnyPathOnTheHost() {
        let host = freshHost()
        let image = FaviconFixtures.solid(16)
        cache.store(image, forURL: URL(string: "https://www.\(host)/")!)
        XCTAssertTrue(cache.cachedImage(forURLString: "https://\(host)/some/page") === image)
    }

    func testStoreWithNilURLIsIgnored() {
        let before = cache.memoryCache.count
        cache.store(FaviconFixtures.solid(16), forURL: nil)
        XCTAssertEqual(cache.memoryCache.count, before)
    }

    func testStoreWritesPNGToTheDiskCache() throws {
        let host = freshHost()
        cache.store(FaviconFixtures.solid(20), forURL: URL(string: "https://\(host)/")!)
        let written = try XCTUnwrap(NSImage(contentsOf: cache.diskURL(forHost: host)))
        XCTAssertEqual(FaviconCache.pixelSize(of: written)?.width, 20)
    }

    func testCachedImageLoadsFromDiskWhenNotInMemoryAndKeepsItForLater() throws {
        let host = freshHost()
        try writePNG(FaviconFixtures.solid(20, r: 0, g: 1, b: 0), to: cache.diskURL(forHost: host))
        let first = try XCTUnwrap(cache.cachedImage(forURLString: "https://\(host)/"))
        XCTAssertEqual(FaviconCache.pixelSize(of: first)?.width, 20)
        XCTAssertTrue(cache.cachedImage(forURLString: "https://\(host)/") === first)
    }

    func testCachedImageRejectsDiskIconsSmallerThanSixteenPoints() throws {
        let host = freshHost()
        try writePNG(FaviconFixtures.solid(8), to: cache.diskURL(forHost: host))
        XCTAssertNil(cache.cachedImage(forURLString: "https://\(host)/"))
    }

    func testCachedImageIsNilForUnknownOrInvalidURLs() {
        XCTAssertNil(cache.cachedImage(forURLString: "https://never-stored-\(UUID().uuidString.prefix(8)).test/"))
        XCTAssertNil(cache.cachedImage(forURLString: "not a url"))
    }

    func testMemoryFaviconCacheEvictsOldestEntriesBeyondLimit() {
        let limit = FaviconCache.maxFaviconMemoryEntries
        let hostsToStore = (0...limit).map { _ in freshHost("lru") }
        for host in hostsToStore {
            cache.store(FaviconFixtures.solid(16), forURL: URL(string: "https://\(host)/")!)
        }
        XCTAssertEqual(cache.memoryOrder.count, limit)
        XCTAssertNil(cache.memoryCache[hostsToStore[0]], "the first host must have been evicted")
        XCTAssertNotNil(cache.memoryCache[hostsToStore[limit]], "the newest host must stay resident")
    }

    // MARK: - Touch icon promotion on store

    func testStoreOfLargeSquareImagePromotesTouchIcon() {
        let host = freshHost()
        cache.store(FaviconFixtures.solid(80), forURL: URL(string: "https://\(host)/")!)
        let touch = cache.cachedTouchIcon(forURLString: "https://\(host)/")
        XCTAssertNotNil(touch?.image)
        XCTAssertEqual(FaviconCache.pixelSize(of: touch!.image!)?.width, 80)
    }

    func testStorePromotionBoundaryIsSeventyTwoPixels() {
        let small = freshHost("small"), edge = freshHost("edge")
        cache.store(FaviconFixtures.solid(71), forURL: URL(string: "https://\(small)/")!)
        cache.store(FaviconFixtures.solid(72), forURL: URL(string: "https://\(edge)/")!)
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(small)/")?.image)
        XCTAssertNotNil(cache.cachedTouchIcon(forURLString: "https://\(edge)/")?.image)
    }

    func testStoreDoesNotPromoteWideOrSmallImages() {
        let wide = freshHost("wide")
        let tiny = freshHost("tiny")
        cache.store(FaviconFixtures.image(width: 200, height: 80) { ctx in
            FaviconFixtures.fill(ctx, rect: CGRect(x: 0, y: 0, width: 200, height: 80), r: 1, g: 0, b: 0)
        }, forURL: URL(string: "https://\(wide)/")!)
        cache.store(FaviconFixtures.solid(40), forURL: URL(string: "https://\(tiny)/")!)
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(wide)/"))
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(tiny)/"))
    }

    func testStoreDoesNotReplaceAnExistingTouchIcon() {
        let host = freshHost()
        cache.store(FaviconFixtures.solid(80), forURL: URL(string: "https://\(host)/")!)
        cache.store(FaviconFixtures.solid(100, r: 0, g: 0, b: 1), forURL: URL(string: "https://\(host)/")!)
        XCTAssertEqual(FaviconCache.pixelSize(of: cache.cachedTouchIcon(forURLString: "https://\(host)/")!.image!)?.width, 80)
    }

    func testPromotedTouchIconIsWrittenWithCurrentMetaVersion() throws {
        let host = freshHost()
        cache.store(FaviconFixtures.solid(80), forURL: URL(string: "https://\(host)/")!)
        let data = try Data(contentsOf: cache.touchMetaDiskURL(forHost: host))
        let meta = try JSONDecoder().decode(FaviconCache.DiskTouchMeta.self, from: data)
        XCTAssertEqual(meta.version, FaviconCache.metaVersion)
        XCTAssertTrue(meta.hasTouchIcon)
        XCTAssertTrue(meta.isOpaque, "a solid square has opaque corners")
    }

    func testTouchMemoryCacheEvictsOldestBeyondLimit() {
        let limit = FaviconCache.maxTouchMemoryEntries
        let hostsToStore = (0...limit).map { _ in freshHost("touch") }
        for host in hostsToStore {
            cache.store(FaviconFixtures.solid(72), forURL: URL(string: "https://\(host)/")!)
        }
        XCTAssertEqual(cache.touchMemoryOrder.count, limit)
        XCTAssertNil(cache.touchMemoryCache[hostsToStore[0]])
        XCTAssertNotNil(cache.touchMemoryCache[hostsToStore[limit]])
    }

    // MARK: - cachedTouchIcon from disk metadata

    func testCachedTouchIconWithoutMetaFileIsNil() {
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(freshHost())/"))
    }

    func testCachedTouchIconWithCorruptMetaIsNil() throws {
        let host = freshHost()
        try writeMeta("{not json", host: host)
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(host)/"))
    }

    func testCachedTouchIconRejectsMetaWithAnotherVersion() throws {
        let older = freshHost("older"), newer = freshHost("newer"), current = freshHost("current")
        let body = #""hasTouchIcon":false,"isOpaque":true,"hasTightEdges":false,"r":0.2,"g":0.4,"b":0.6"#
        try writeMeta("{\"version\":2,\(body)}", host: older)
        try writeMeta("{\"version\":4,\(body)}", host: newer)
        try writeMeta("{\"version\":3,\(body)}", host: current)
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(older)/"))
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(newer)/"))
        XCTAssertNotNil(cache.cachedTouchIcon(forURLString: "https://\(current)/"))
    }

    func testCachedTouchIconWithoutIconKeepsAccentColorAndFlags() throws {
        let host = freshHost()
        try writeMeta(#"{"version":3,"hasTouchIcon":false,"isOpaque":true,"hasTightEdges":false,"r":0.2,"g":0.4,"b":0.6}"#, host: host)
        let result = try XCTUnwrap(cache.cachedTouchIcon(forURLString: "https://\(host)/"))
        XCTAssertNil(result.image)
        XCTAssertTrue(result.isOpaque)
        XCTAssertFalse(result.hasTightEdges)
        PersistenceTestSupport.assertSRGB(result.accentColor, 0.2, 0.4, 0.6, accuracy: 0.0001)
    }

    func testCachedTouchIconWithIconRestoresImageAndFlags() throws {
        let host = freshHost()
        try writePNG(FaviconFixtures.solid(80), to: cache.touchImageDiskURL(forHost: host))
        try writeMeta(#"{"version":3,"hasTouchIcon":true,"isOpaque":false,"hasTightEdges":true}"#, host: host)
        let result = try XCTUnwrap(cache.cachedTouchIcon(forURLString: "https://\(host)/"))
        XCTAssertEqual(FaviconCache.pixelSize(of: try XCTUnwrap(result.image))?.width, 80)
        XCTAssertFalse(result.isOpaque)
        XCTAssertTrue(result.hasTightEdges)
        XCTAssertNil(result.accentColor)
    }

    func testCachedTouchIconWithMissingImageFileIsNil() throws {
        let host = freshHost()
        try writeMeta(#"{"version":3,"hasTouchIcon":true,"isOpaque":true,"hasTightEdges":false}"#, host: host)
        XCTAssertNil(cache.cachedTouchIcon(forURLString: "https://\(host)/"))
    }

    func testCachedTouchIconWithPartialColorDropsAccent() throws {
        let host = freshHost()
        try writeMeta(#"{"version":3,"hasTouchIcon":false,"isOpaque":true,"hasTightEdges":false,"r":0.2,"g":0.4}"#, host: host)
        XCTAssertNil(try XCTUnwrap(cache.cachedTouchIcon(forURLString: "https://\(host)/")).accentColor)
    }

    func testCachedTouchIconServesMemoryAfterDiskIsRemoved() throws {
        let host = freshHost()
        try writePNG(FaviconFixtures.solid(80), to: cache.touchImageDiskURL(forHost: host))
        try writeMeta(#"{"version":3,"hasTouchIcon":true,"isOpaque":true,"hasTightEdges":false}"#, host: host)
        let first = try XCTUnwrap(cache.cachedTouchIcon(forURLString: "https://\(host)/"))
        try FileManager.default.removeItem(at: cache.touchMetaDiskURL(forHost: host))
        let second = try XCTUnwrap(cache.cachedTouchIcon(forURLString: "https://\(host)/"))
        XCTAssertTrue(first.image === second.image)
    }

    func testDiskTouchMetaRoundTripsAndRejectsMissingVersion() throws {
        let meta = FaviconCache.DiskTouchMeta(version: 3, hasTouchIcon: true, isOpaque: false, hasTightEdges: true, r: 0.5, g: nil, b: 1)
        let decoded = try JSONDecoder().decode(FaviconCache.DiskTouchMeta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(decoded.version, 3)
        XCTAssertTrue(decoded.hasTouchIcon)
        XCTAssertFalse(decoded.isOpaque)
        XCTAssertTrue(decoded.hasTightEdges)
        XCTAssertEqual(decoded.r, 0.5)
        XCTAssertNil(decoded.g)
        XCTAssertEqual(decoded.b, 1)
        XCTAssertThrowsError(try JSONDecoder().decode(FaviconCache.DiskTouchMeta.self, from: Data(#"{"hasTouchIcon":true,"isOpaque":true,"hasTightEdges":true}"#.utf8)))
    }

    func testTouchIconResultPreservesFields() {
        let image = FaviconFixtures.solid(8)
        let color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let result = FaviconCache.TouchIconResult(image: image, isOpaque: true, hasTightEdges: false, accentColor: color)
        XCTAssertTrue(result.image === image)
        XCTAssertTrue(result.isOpaque)
        XCTAssertFalse(result.hasTightEdges)
        XCTAssertTrue(result.accentColor === color)
    }

    // MARK: - Async entry points served from cache

    func testFetchFaviconServesCachedImageWithoutNetwork() {
        let host = freshHost()
        let stored = FaviconFixtures.solid(16)
        cache.store(stored, forURL: URL(string: "https://\(host)/")!)
        let done = expectation(description: "completion")
        cache.fetchFavicon(forURLString: "https://\(host)/page") { image in
            XCTAssertTrue(image === stored)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testFetchFaviconWithInvalidURLCompletesWithNil() {
        let done = expectation(description: "completion")
        cache.fetchFavicon(forURLString: "not a url") { image in
            XCTAssertNil(image)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testFetchTouchIconWithInvalidURLCompletesWithEmptyOpaqueResult() {
        let done = expectation(description: "completion")
        cache.fetchTouchIcon(forURLString: "not a url") { result in
            XCTAssertNil(result.image)
            XCTAssertTrue(result.isOpaque)
            XCTAssertFalse(result.hasTightEdges)
            XCTAssertNil(result.accentColor)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testFetchTouchIconServesCachedResultWithoutNetwork() {
        let host = freshHost()
        cache.store(FaviconFixtures.solid(80), forURL: URL(string: "https://\(host)/")!)
        let done = expectation(description: "completion")
        cache.fetchTouchIcon(forURLString: "https://\(host)/") { result in
            XCTAssertNotNil(result.image)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: - HTML helpers: attributes and regex

    func testParseAttributesHandlesDoubleSingleAndUnquotedValues() {
        let attrs = cache.parseHTMLAttributes(#"<link rel="icon" href='/a b.png' sizes=32x32 data-x_y="1">"#)
        XCTAssertEqual(attrs["rel"], "icon")
        XCTAssertEqual(attrs["href"], "/a b.png")
        XCTAssertEqual(attrs["sizes"], "32x32")
        XCTAssertEqual(attrs["data-x_y"], "1")
    }

    func testParseAttributesLowercasesNames() {
        let attrs = cache.parseHTMLAttributes(#"<A HREF="x" Rel="y">"#)
        XCTAssertEqual(attrs["href"], "x")
        XCTAssertEqual(attrs["rel"], "y")
        XCTAssertNil(attrs["HREF"])
    }

    func testParseAttributesKeepsLastDuplicate() {
        XCTAssertEqual(cache.parseHTMLAttributes(#"<a href="one" href="two">"#)["href"], "two")
    }

    func testParseAttributesIgnoresValuelessAttributes() {
        let attrs = cache.parseHTMLAttributes(#"<input disabled checked type="text">"#)
        XCTAssertNil(attrs["disabled"])
        XCTAssertNil(attrs["checked"])
        XCTAssertEqual(attrs["type"], "text")
    }

    func testParseAttributesAllowsWhitespaceAroundEquals() {
        XCTAssertEqual(cache.parseHTMLAttributes(#"<a title = "Hello World">"#)["title"], "Hello World")
    }

    func testParseAttributesKeepsGreaterThanInsideQuotedValues() {
        XCTAssertEqual(cache.parseHTMLAttributes(#"<meta content="a>b">"#)["content"], "a>b")
    }

    func testParseAttributesKeepsEmptyQuotedValueAsEmptyString() {
        XCTAssertEqual(cache.parseHTMLAttributes(#"<img alt="">"#)["alt"], "")
    }

    func testParseAttributesOfEmptyInputIsEmpty() {
        XCTAssertEqual(cache.parseHTMLAttributes(""), [:])
    }

    func testFirstMatchReturnsFirstOccurrenceCaseInsensitively() {
        XCTAssertEqual(cache.firstMatch(in: "abcabc", pattern: "b"), "b")
        XCTAssertEqual(cache.firstMatch(in: "xx <Link rel=\"a\"> <link>", pattern: #"<link\b[^>]*>"#), "<Link rel=\"a\">")
        XCTAssertNil(cache.firstMatch(in: "abc", pattern: "z"))
        XCTAssertNil(cache.firstMatch(in: "", pattern: "a"))
    }

    func testFirstMatchWithInvalidPatternIsNil() {
        XCTAssertNil(cache.firstMatch(in: "anything (", pattern: "("))
    }

    func testAllMatchesReturnsEveryOccurrence() {
        XCTAssertEqual(cache.allMatches(in: "<a><b><a>", pattern: "<a>"), ["<a>", "<a>"])
        XCTAssertEqual(cache.allMatches(in: "none here", pattern: "<a>"), [])
        XCTAssertEqual(cache.allMatches(in: "", pattern: "x"), [])
        XCTAssertEqual(cache.allMatches(in: "x", pattern: "("), [])
    }

    func testAllMatchesUsesUTF16RangesForNonASCIIText() {
        let text = "h\u{00E9}llo \u{1F600} w\u{00F6}rld \u{1F600}"
        XCTAssertEqual(cache.allMatches(in: text, pattern: "\u{1F600}").count, 2)
        XCTAssertEqual(cache.allMatches(in: text, pattern: "\u{00F6}"), ["\u{00F6}"])
        XCTAssertEqual(cache.allMatches(in: text, pattern: "w.rld"), ["w\u{00F6}rld"])
    }

    func testParseDeclaredIconSizeChoosesLargestSquareDimension() {
        XCTAssertEqual(cache.parseDeclaredIconSize("32x32"), 32)
        XCTAssertEqual(cache.parseDeclaredIconSize("16x16 48x48"), 48)
        XCTAssertEqual(cache.parseDeclaredIconSize("48X48"), 48)
        XCTAssertEqual(cache.parseDeclaredIconSize("180x180 any"), 180)
    }

    func testParseDeclaredIconSizeRejectsUnsuitableValues() {
        XCTAssertEqual(cache.parseDeclaredIconSize(nil), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize(""), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize("32x48"), 0, "unequal dimensions are not square")
        XCTAssertEqual(cache.parseDeclaredIconSize("any"), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize("32x32x32"), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize("x32"), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize("32x"), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize("-16x-16"), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize("0x0"), 0)
        XCTAssertEqual(cache.parseDeclaredIconSize("99999999999999999999x99999999999999999999"), 0, "overflowing sizes must not crash")
    }

    // MARK: - Icon discovery from HTML

    private let pageBase = URL(string: "https://example.com/blog/post")!

    func testDiscoverEmptyOrLinklessHTMLReturnsNothing() {
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: "", baseURL: pageBase), [])
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: "<html><body>no links</body></html>", baseURL: pageBase), [])
    }

    func testDiscoverResolvesRelativeHrefAgainstPage() {
        let urls = cache.discoverTabFaviconURLs(in: #"<link rel="icon" href="icons/a.png">"#, baseURL: pageBase)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/blog/icons/a.png"])
    }

    func testDiscoverHonorsBaseHrefAbsoluteAndRooted() {
        let absolute = cache.discoverTabFaviconURLs(in: #"<base href="https://cdn.example.net/assets/"><link rel="icon" href="fav.png">"#, baseURL: pageBase)
        XCTAssertEqual(absolute.map(\.absoluteString), ["https://cdn.example.net/assets/fav.png"])
        let rooted = cache.discoverTabFaviconURLs(in: #"<base href="/static/"><link rel="icon" href="fav.png">"#, baseURL: pageBase)
        XCTAssertEqual(rooted.map(\.absoluteString), ["https://example.com/static/fav.png"])
    }

    func testDiscoverAcceptsIconRelVariants() {
        let html = #"<link rel="shortcut icon" href="/s.ico"><link rel="ICON" href="/u.png"><link rel="alternate icon" href="/alt.png">"#
        let urls = Set(cache.discoverTabFaviconURLs(in: html, baseURL: pageBase).map(\.absoluteString))
        XCTAssertEqual(urls, ["https://example.com/s.ico", "https://example.com/u.png", "https://example.com/alt.png"])
    }

    func testDiscoverSkipsTouchMaskStylesheetDataAndEmptyLinks() {
        let html = """
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="apple-touch-icon-precomposed" href="/touch2.png">
        <link rel="mask-icon" href="/mask.svg">
        <link rel="stylesheet" href="/site.css">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="   ">
        <link rel="icon">
        <link href="/no-rel.png">
        """
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: html, baseURL: pageBase), [])
    }

    func testDiscoverIgnoresNonLinkTags() {
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: #"<meta rel="icon" href="/x.png">"#, baseURL: pageBase), [])
    }

    func testDiscoverIsCaseAndWhitespaceTolerant() {
        let urls = cache.discoverTabFaviconURLs(in: "<LINK REL = \"Icon\" HREF=' /up.PNG '>", baseURL: pageBase)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/up.PNG"])
    }

    func testDiscoverSpansMultilineTags() {
        let urls = cache.discoverTabFaviconURLs(in: "<link\n  rel=\"icon\"\n  href=\"/multi.png\"\n>", baseURL: pageBase)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/multi.png"])
    }

    func testDiscoverRanksPNGOverICOOverSVG() {
        let html = #"<link rel="icon" href="/a.svg"><link rel="icon" href="/b.ico"><link rel="icon" href="/c.png">"#
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: html, baseURL: pageBase).map(\.lastPathComponent), ["c.png", "b.ico", "a.svg"])
    }

    func testDiscoverBoostsMidSizedDeclarationsAndDemotesHuge() {
        let html = #"<link rel="icon" href="/x.png" sizes="16x16"><link rel="icon" href="/y.png" sizes="48x48"><link rel="icon" href="/z.png" sizes="192x192">"#
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: html, baseURL: pageBase).map(\.lastPathComponent), ["y.png", "z.png", "x.png"])
    }

    func testDiscoverDeduplicatesResolvedURLs() {
        let html = #"<link rel="icon" href="/a.png"><link rel="icon" href="https://example.com/a.png">"#
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: html, baseURL: pageBase).count, 1)
    }

    func testDiscoverSkipsHrefsThatCannotBeResolved() {
        let html = #"<link rel="icon" href="http://[bad"><link rel="icon" href="/ok.png">"#
        XCTAssertEqual(cache.discoverTabFaviconURLs(in: html, baseURL: pageBase).map(\.lastPathComponent), ["ok.png"])
    }
}
