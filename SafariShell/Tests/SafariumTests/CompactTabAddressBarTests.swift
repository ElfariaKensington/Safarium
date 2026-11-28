import XCTest
import AppKit
@testable import Safarium

/// Shared offscreen hosting helpers for the T4 UI suites. Windows are never ordered on screen.
enum TabUIHost {
    /// Builds a borderless, never-ordered window whose content view is `container` sized to `size`.
    @MainActor
    static func window(containing container: NSView, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        container.frame = NSRect(origin: .zero, size: size)
        w.contentView = container
        container.layoutSubtreeIfNeeded()
        return w
    }

    /// Unique named pasteboard so tests never touch the general clipboard.
    static func uniquePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("SafariumT4-\(UUID().uuidString)"))
    }

    static func solidImage(width: Int, height: Int) -> NSImage {
        guard width > 0, height > 0 else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        return img
    }
}

@MainActor
final class CompactTabAddressBarTests: HermeticTestCase {
    private var container: NSView!
    private var bar: CompactTabAddressBar!
    private var window: NSWindow!
    private var pasteboards: [NSPasteboard] = []
    private var leadingConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.makeFixture() }
    }

    private func makeFixture() {
        _ = NSApplication.shared
        container = NSView()
        bar = CompactTabAddressBar(frame: .zero)
        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        leadingConstraint = bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 100)
        widthConstraint = bar.widthAnchor.constraint(equalToConstant: 760)
        NSLayoutConstraint.activate([
            leadingConstraint,
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            widthConstraint,
            bar.heightAnchor.constraint(equalToConstant: 36)
        ])
        window = TabUIHost.window(containing: container, size: NSSize(width: 1000, height: 120))
        bar.apply(theme: .defaultLight, animated: false)
        container.layoutSubtreeIfNeeded()
    }

    /// Applies items and forces the constraint/frame pass that real windows perform before hit-testing.
    private func load(_ items: [TabPresentationItem]) {
        bar.update(items: items)
        container.layoutSubtreeIfNeeded()
    }

    /// Resizes/moves the bar through its Auto Layout constraints (the bar ignores direct frame writes).
    private func place(x: CGFloat = 100, width: CGFloat) {
        leadingConstraint.constant = x
        widthConstraint.constant = width
        container.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        MainActor.assumeIsolated { self.dropFixture() }
        super.tearDown()
    }

    private func dropFixture() {
        for pb in pasteboards { pb.releaseGlobally() }
        pasteboards = []
        window.close()
        bar = nil
        container = nil
        window = nil
    }

    // MARK: - helpers

    private func item(_ id: String, active: Bool = false, pinned: Bool = false, url: String? = nil,
                      title: String? = nil) -> TabPresentationItem {
        TabPresentationItem(id: id, title: title ?? id, url: url.flatMap { URL(string: $0) }, favicon: nil,
                            isLoading: false, progress: 0, isActive: active, isPinned: pinned)
    }

    private func pasteboard() -> NSPasteboard {
        let pb = TabUIHost.uniquePasteboard()
        pasteboards.append(pb)
        pb.clearContents()
        return pb
    }

    private func dropURL(fromString s: String) -> URL? {
        let pb = pasteboard()
        pb.setString(s, forType: .string)
        return CompactTabAddressBar.extractDroppedURL(from: pb)
    }

    private func dropURL(fromNSURL u: URL) -> URL? {
        let pb = pasteboard()
        pb.writeObjects([u as NSURL])
        return CompactTabAddressBar.extractDroppedURL(from: pb)
    }

    /// Converts a screen point to the pasteboard-free drop hit-test input for the bar.
    private func screenPoint(forBarPoint p: NSPoint) -> NSPoint {
        let inWin = bar.convert(p, to: nil)
        return window.convertToScreen(NSRect(origin: inWin, size: .zero)).origin
    }

    // MARK: - TabPresentationItem

    func testPresentationItemRetainsEveryField() {
        let fav = TabUIHost.solidImage(width: 4, height: 4)
        let url = URL(string: "https://example.com/a?b=1#c")
        let it = TabPresentationItem(id: "tab-1", title: "Example", url: url, favicon: fav,
                                     isLoading: true, progress: 0.42, isActive: true, isPinned: true)
        XCTAssertEqual(it.id, "tab-1")
        XCTAssertEqual(it.title, "Example")
        XCTAssertEqual(it.url, url)
        XCTAssertTrue(it.favicon === fav)
        XCTAssertTrue(it.isLoading)
        XCTAssertEqual(it.progress, 0.42)
        XCTAssertTrue(it.isActive)
        XCTAssertTrue(it.isPinned)
    }

    func testPresentationItemIsPinnedDefaultsToFalse() {
        let it = TabPresentationItem(id: "x", title: "", url: nil, favicon: nil,
                                     isLoading: false, progress: 0, isActive: false)
        XCTAssertFalse(it.isPinned)
        XCTAssertNil(it.url)
        XCTAssertNil(it.favicon)
        XCTAssertFalse(it.isActive)
    }

    func testPresentationItemKeepsEmptyTitleAndOutOfRangeProgressUnchanged() {
        let low = TabPresentationItem(id: "", title: "", url: nil, favicon: nil, isLoading: false, progress: -1, isActive: false)
        let high = TabPresentationItem(id: "u", title: "", url: nil, favicon: nil, isLoading: true, progress: 5.0, isActive: true)
        XCTAssertEqual(low.id, "")
        XCTAssertEqual(low.title, "")
        XCTAssertEqual(low.progress, -1)
        XCTAssertEqual(high.progress, 5.0)
    }

    func testPresentationItemPreservesUnicodeTitleAndURLWithPort() {
        let url = URL(string: "https://例子.测试:8443/路径?q=é")
        let it = TabPresentationItem(id: "u1", title: "🙂 Café — 日本語", url: url, favicon: nil,
                                     isLoading: false, progress: 1, isActive: false)
        XCTAssertEqual(it.title, "🙂 Café — 日本語")
        XCTAssertEqual(it.url?.port, 8443)
    }

    // MARK: - extractDroppedURL (string payloads)

    func testDropStringAcceptsHTTPS() {
        XCTAssertEqual(dropURL(fromString: "https://example.com/path?x=1")?.absoluteString, "https://example.com/path?x=1")
    }

    func testDropStringAcceptsHTTP() {
        XCTAssertEqual(dropURL(fromString: "http://example.org")?.absoluteString, "http://example.org")
    }

    func testDropStringTrimsSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(dropURL(fromString: "  \n https://example.com \t\n")?.absoluteString, "https://example.com")
    }

    func testDropStringBareDomainGetsHTTPSPrefix() {
        XCTAssertEqual(dropURL(fromString: "example.com")?.absoluteString, "https://example.com")
    }

    func testDropStringBareDomainWithPathGetsHTTPSPrefix() {
        XCTAssertEqual(dropURL(fromString: "news.ycombinator.com/item?id=1")?.absoluteString,
                       "https://news.ycombinator.com/item?id=1")
    }

    func testDropStringWithSpaceAndDotIsRejected() {
        XCTAssertNil(dropURL(fromString: "example com.net"))
    }

    func testDropStringPlainWordIsRejected() {
        XCTAssertNil(dropURL(fromString: "hello"))
    }

    func testDropStringEmptyAndWhitespaceOnlyAreRejected() {
        XCTAssertNil(dropURL(fromString: ""))
        XCTAssertNil(dropURL(fromString: "   \n\t "))
    }

    func testDropStringAcceptsLocalAndInternalSchemes() {
        XCTAssertEqual(dropURL(fromString: "file:///tmp/report.txt")?.scheme, "file")
        XCTAssertEqual(dropURL(fromString: "safarium://start")?.scheme, "safarium")
        XCTAssertEqual(dropURL(fromString: "chrome://settings")?.scheme, "chrome")
        XCTAssertEqual(dropURL(fromString: "view-source:https://example.com")?.scheme, "view-source")
    }

    func testDropStringSchemeMatchIsCaseInsensitive() {
        XCTAssertEqual(dropURL(fromString: "HTTPS://Example.com/Ab")?.scheme?.lowercased(), "https")
    }

    func testDropStringPlainJavascriptURLWithoutDotIsRejected() {
        XCTAssertNil(dropURL(fromString: "javascript:alert(1)"))
    }

    func testDropStringDataURLWithoutDotIsRejected() {
        XCTAssertNil(dropURL(fromString: "data:text/html,hi"))
    }

    func testDropStringUnsupportedSchemeIsNotPassedThroughAsItself() {
        // ftp:// is not on the allowlist, so it must not come back as an ftp URL.
        let u = dropURL(fromString: "ftp://example.com/file")
        XCTAssertNotEqual(u?.scheme?.lowercased(), "ftp")
    }

    func testDropStringJavascriptWithDotIsNotReturnedAsJavascriptScheme() {
        // The bare-domain fallback must never turn a javascript: payload into a javascript: URL.
        let u = dropURL(fromString: "javascript:alert('a.b')")
        XCTAssertNotEqual(u?.scheme?.lowercased(), "javascript")
    }

    func testDropStringJavascriptWithDotIsRejectedOutright() {
        // The bare-domain fallback yields nil here because "https://javascript:alert('a.b')" is not a valid URL.
        XCTAssertNil(dropURL(fromString: "javascript:alert('a.b')"))
    }

    // MARK: - extractDroppedURL (NSURL payloads)

    func testDropNSURLHTTPSIsAccepted() {
        XCTAssertEqual(dropURL(fromNSURL: URL(string: "https://apple.com/mac")!)?.absoluteString, "https://apple.com/mac")
    }

    func testDropNSURLJavascriptIsRejected() {
        XCTAssertNil(dropURL(fromNSURL: URL(string: "javascript:alert(document.cookie)")!))
    }

    func testDropNSURLDataIsRejected() {
        XCTAssertNil(dropURL(fromNSURL: URL(string: "data:text/html;base64,PHNjcmlwdD4=")!))
    }

    func testDropNSURLFileURLIsAccepted() {
        let u = dropURL(fromNSURL: URL(fileURLWithPath: "/tmp/file name.pdf"))
        XCTAssertEqual(u?.scheme, "file")
        XCTAssertEqual(u?.lastPathComponent, "file name.pdf")
    }

    func testDropNSURLWinsOverStringWhenBothPresent() {
        let pb = pasteboard()
        pb.writeObjects([URL(string: "https://first.example")! as NSURL])
        pb.setString("https://second.example", forType: .string)
        XCTAssertEqual(CompactTabAddressBar.extractDroppedURL(from: pb)?.host, "first.example")
    }

    func testDropEmptyPasteboardReturnsNil() {
        XCTAssertNil(CompactTabAddressBar.extractDroppedURL(from: pasteboard()))
    }

    // MARK: - editableURLString

    func testEditableURLNilAndSafariumSchemeYieldEmptyText() {
        XCTAssertEqual(bar.editableURLString(for: nil), "")
        XCTAssertEqual(bar.editableURLString(for: URL(string: "safarium://start")), "")
    }

    func testEditableURLStripsRootSlashOnly() {
        XCTAssertEqual(bar.editableURLString(for: URL(string: "https://example.com/")), "https://example.com")
    }

    func testEditableURLKeepsRootSlashWhenQueryPresent() {
        XCTAssertEqual(bar.editableURLString(for: URL(string: "https://example.com/?q=1")), "https://example.com/?q=1")
    }

    func testEditableURLKeepsRootSlashWhenFragmentPresent() {
        XCTAssertEqual(bar.editableURLString(for: URL(string: "https://example.com/#top")), "https://example.com/#top")
    }

    func testEditableURLKeepsTrailingSlashOnNonRootPath() {
        XCTAssertEqual(bar.editableURLString(for: URL(string: "https://example.com/a/")), "https://example.com/a/")
    }

    func testEditableURLLeavesPathWithoutTrailingSlashUnchanged() {
        XCTAssertEqual(bar.editableURLString(for: URL(string: "https://example.com/a/b?c=d")), "https://example.com/a/b?c=d")
    }

    func testEditableURLPreservesPercentEncodedUnicodePath() {
        let url = URL(string: "https://example.com/%E4%BD%A0%E5%A5%BD/")
        XCTAssertEqual(bar.editableURLString(for: url), "https://example.com/%E4%BD%A0%E5%A5%BD/")
    }

    func testEditableURLFileDirectoryKeepsSlash() {
        XCTAssertEqual(bar.editableURLString(for: URL(fileURLWithPath: "/tmp/", isDirectory: true)), "file:///tmp/")
    }

    // MARK: - focusRingGeometry

    func testFocusRingSingleSlotUsesTrackInsetAndThreePointFourStroke() {
        load([item("a", active: true, url: "https://example.com")])
        window.contentView?.layoutSubtreeIfNeeded()
        let geom = bar.focusRingGeometry(forPillFrame: NSRect(x: 2.5, y: 2.5, width: 200, height: 31))
        XCTAssertEqual(geom.lineWidth, 3.4, accuracy: 0.0001)
        XCTAssertEqual(geom.rect.origin.x, 1.7, accuracy: 0.0001)
        XCTAssertEqual(geom.rect.origin.y, 1.7, accuracy: 0.0001)
        XCTAssertEqual(geom.rect.height, SafariMetrics.tabPillHeight - 3.4, accuracy: 0.0001)
    }

    func testFocusRingMultiSlotOutsetsPillFrame() {
        load([item("a", active: true), item("b")])
        let pill = NSRect(x: 10, y: 2.5, width: 100, height: 31)
        let geom = bar.focusRingGeometry(forPillFrame: pill)
        XCTAssertEqual(geom.lineWidth, 3.1, accuracy: 0.0001)
        XCTAssertEqual(geom.rect, pill.insetBy(dx: -0.75, dy: -0.75))
    }

    func testFocusRingWithDropPlaceholderUsesMultiSlotGeometryEvenForSingleTab() {
        load([item("a", active: true)])
        bar.updateExternalDropPlaceholder(tabID: "ext", insertionIndex: 1)
        let pill = NSRect(x: 2.5, y: 2.5, width: 120, height: 31)
        let geom = bar.focusRingGeometry(forPillFrame: pill)
        XCTAssertEqual(geom.lineWidth, 3.1, accuracy: 0.0001)
        XCTAssertEqual(geom.rect, pill.insetBy(dx: -0.75, dy: -0.75))
    }

    func testFocusRingMultiSlotZeroSizeFrameStillInsetsByStrokeHalf() {
        load([item("a", active: true), item("b")])
        let geom = bar.focusRingGeometry(forPillFrame: .zero)
        XCTAssertEqual(geom.rect.size.width, 1.5, accuracy: 0.0001)
        XCTAssertEqual(geom.rect.size.height, 1.5, accuracy: 0.0001)
    }

    // MARK: - slot counts, fill width, centering

    func testEffectiveSlotCountIsAtLeastOneWhenEmpty() {
        load([])
        XCTAssertEqual(bar.effectiveSlotCount, 1)
    }

    func testEffectiveSlotCountCountsVisibleTabs() {
        load([item("a", active: true), item("b"), item("c")])
        XCTAssertEqual(bar.effectiveSlotCount, 3)
    }

    func testEffectiveSlotCountAddsOneForExternalPlaceholder() {
        load([item("a", active: true), item("b")])
        bar.updateExternalDropPlaceholder(tabID: "ext", insertionIndex: 0)
        XCTAssertEqual(bar.effectiveSlotCount, 3)
    }

    func testFillWidthSingleTabIsSingleTabPillWidth() {
        load([item("a", active: true)])
        XCTAssertEqual(bar.computeFillWidth(), SafariMetrics.activePillSingleTabWidth)
    }

    func testFillWidthSingleTabWithSidebarOpenUsesSidebarWidth() {
        bar.isSidebarOpen = true
        load([item("a", active: true)])
        XCTAssertEqual(bar.computeFillWidth(), SafariMetrics.activePillSingleTabSidebarWidth)
    }

    func testFillWidthGrowsWithEachRegularTabUntilAvailableWidth() {
        load([item("a", active: true), item("b"), item("c")])
        XCTAssertEqual(bar.computeFillWidth(), 760.0, accuracy: 0.0001)
        load([item("a", active: true), item("b")])
        XCTAssertEqual(bar.computeFillWidth(), 2 * SafariMetrics.activePillSingleTabWidth, accuracy: 0.0001)
    }

    func testFillWidthForSlotCountOverridesDisplayedCount() {
        load([item("a", active: true)])
        XCTAssertEqual(bar.computeFillWidth(forSlotCount: 2), 2 * SafariMetrics.activePillSingleTabWidth, accuracy: 0.0001)
    }

    func testFillWidthNeverExceedsBarBoundsOnNarrowTrack() {
        place(x: 100, width: 100)
        load([item("a", active: true), item("b")])
        // The track is never wider than the bar, otherwise its slots spill into the right-hand capsule.
        XCTAssertEqual(bar.computeFillWidth(), 100.0, accuracy: 0.0001)
    }

    func testFillWidthUsesDefaultTrackWhenBoundsTooSmall() {
        place(x: 100, width: 30)
        load([item("a", active: true), item("b")])
        // bounds.width <= 40 falls back to 760 as the available width.
        XCTAssertEqual(bar.computeFillWidth(), 580.0, accuracy: 0.0001)
    }

    func testFillWidthCountsInactivePinnedTabsAsThirtySixPoints() {
        load([item("a", active: true), item("p", pinned: true), item("b")])
        XCTAssertEqual(bar.computeFillWidth(), 36.0 + 2 * SafariMetrics.activePillSingleTabWidth, accuracy: 0.0001)
    }

    func testFillWidthPinnedOnlyTabsKeepActivePinnedAtFullWidth() {
        load([item("a", active: true, pinned: true)])
        // An active pinned tab is not an inactive pinned slot: it still takes a full slot.
        XCTAssertEqual(bar.computeFillWidth(), SafariMetrics.activePillSingleTabWidth, accuracy: 0.0001)
    }

    func testFillWidthSingleAddressOnlyModeClampsToCompactRange() {
        bar.singleAddressOnlyMode = true
        load([item("a", active: true), item("b")])
        // round(760 * 0.72) = 547 -> capped at 520.
        XCTAssertEqual(bar.computeFillWidth(), 520.0, accuracy: 0.0001)
    }

    func testFillWidthSingleAddressOnlyModeFloorsAtThreeEighty() {
        place(x: 100, width: 500)
        bar.singleAddressOnlyMode = true
        load([item("a", active: true)])
        // round(500 * 0.72) = 360 -> floored at 380, then limited by 500 available.
        XCTAssertEqual(bar.computeFillWidth(), 380.0, accuracy: 0.0001)
    }

    func testTrackCenterOffsetIsZeroForMultipleSlots() {
        load([item("a", active: true), item("b")])
        XCTAssertEqual(bar.computeTrackCenterOffset(slotCount: 2, trackWidth: 580), 0)
    }

    func testTrackCenterOffsetIsZeroWithoutSuperviewOrTinyParent() {
        let lone = CompactTabAddressBar(frame: NSRect(x: 0, y: 0, width: 760, height: 36))
        XCTAssertEqual(lone.computeTrackCenterOffset(slotCount: 1, trackWidth: 290), 0)
        let tinyParent = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        let inTiny = CompactTabAddressBar(frame: NSRect(x: 0, y: 0, width: 760, height: 36))
        tinyParent.addSubview(inTiny)
        XCTAssertEqual(inTiny.computeTrackCenterOffset(slotCount: 1, trackWidth: 290), 0)
    }

    func testTrackCenterOffsetCentersSingleSlotOnParentMidX() {
        // Parent (container) midX = 500; bar frame midX = 100 + 380 = 480 -> offset +20.
        load([item("a", active: true)])
        XCTAssertEqual(bar.computeTrackCenterOffset(slotCount: 1, trackWidth: 290), 20, accuracy: 0.0001)
    }

    func testTrackCenterOffsetClampsToAvailableHalfTravel() {
        place(x: 600, width: 760)
        load([item("a", active: true)])
        // desired = 500 - 980 = -480; max half travel = floor((760 - 290) / 2) = 235.
        XCTAssertEqual(bar.computeTrackCenterOffset(slotCount: 1, trackWidth: 290), -235, accuracy: 0.0001)
    }

    func testTrackCenterOffsetClampsPositiveSideToo() {
        place(x: -400, width: 760)
        load([item("a", active: true)])
        // desired = 500 - (-400 + 380) = 520 -> clamped to +235.
        XCTAssertEqual(bar.computeTrackCenterOffset(slotCount: 1, trackWidth: 290), 235, accuracy: 0.0001)
    }

    // MARK: - hypothetical placeholder geometry (drop preview math)

    func testPlaceholderGeometryAllRegularNoActiveSplitsEvenly() {
        let items = [item("a"), item("b")]
        let first = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 3, trackWidth: 600, insertionIndex: 0, visibleItems: items)
        let mid = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 3, trackWidth: 600, insertionIndex: 1, visibleItems: items)
        let last = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 3, trackWidth: 600, insertionIndex: 2, visibleItems: items)
        XCTAssertEqual(first.x, 0, accuracy: 0.0001)
        XCTAssertEqual(first.width, 200, accuracy: 0.0001)
        XCTAssertEqual(mid.x, 200, accuracy: 0.0001)
        XCTAssertEqual(last.x, 400, accuracy: 0.0001)
        XCTAssertEqual(last.width, 200, accuracy: 0.0001)
    }

    func testPlaceholderGeometryWithActiveTabGivesActiveWiderSlot() {
        let items = [item("a", active: true), item("b")]
        let at0 = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 3, trackWidth: 600, insertionIndex: 0, visibleItems: items)
        let at1 = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 3, trackWidth: 600, insertionIndex: 1, visibleItems: items)
        let at2 = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 3, trackWidth: 600, insertionIndex: 2, visibleItems: items)
        XCTAssertEqual(at0.x, 0, accuracy: 0.0001)
        XCTAssertEqual(at0.width, 176, accuracy: 0.0001)
        XCTAssertEqual(at1.x, 248, accuracy: 0.0001)
        XCTAssertEqual(at1.width, 176, accuracy: 0.0001)
        XCTAssertEqual(at2.x, 424, accuracy: 0.0001)
    }

    func testPlaceholderGeometrySingleSlotTakesWholeTrack() {
        let g = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 1, trackWidth: 290, insertionIndex: 0, visibleItems: [])
        XCTAssertEqual(g.x, 0)
        XCTAssertEqual(g.width, 290)
    }

    func testPlaceholderGeometryNarrowTrackStillCoversWidth() {
        let items = [item("a"), item("b")]
        let g = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 3, trackWidth: 100, insertionIndex: 2, visibleItems: items)
        // No active tab: slots are exact thirds of the 100 pt track (no floor applied on this branch).
        XCTAssertEqual(g.x, 200.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(g.width, 100.0 / 3.0, accuracy: 0.0001)
    }

    func testPlaceholderGeometryActiveSlotNeverShrinksBelowFloorWhenAvailable() {
        let items = [item("a", active: true), item("b"), item("c")]
        let g = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 4, trackWidth: 760, insertionIndex: 0, visibleItems: items)
        // equal = floor(760/4) = 190 < 248 floor, so the active slot is 248 and others share the rest.
        XCTAssertEqual(g.width, 170, accuracy: 0.0001)
    }

    func testPlaceholderGeometryPinnedMixMatchesDrawnSlotsWhenNotCrowded() {
        // Two regular tabs plus one pinned inactive tab in a roomy track: the hypothetical slot should
        // be the same width as a regular slot in the real layout (no pinned distortion).
        let items = [item("a", active: true), item("p", pinned: true), item("b")]
        let g = bar.computeHypotheticalPlaceholderGeometry(totalSlots: 4, trackWidth: 760, insertionIndex: 3, visibleItems: items)
        XCTAssertGreaterThan(g.width, 36)
    }

    // MARK: - drop hit testing

    func testDropHitTestOutsideHitZoneReturnsNil() {
        load([item("a", active: true)])
        let far = window.convertToScreen(NSRect(x: 0, y: 0, width: 1, height: 1)).origin
        XCTAssertNil(bar.dropHitTest(atScreenPoint: NSPoint(x: far.x - 500, y: far.y)))
    }

    func testDropHitTestOnEmptyTrackInsertsAtIndexZero() {
        load([])
        let p = screenPoint(forBarPoint: NSPoint(x: 10, y: 18))
        let hit = bar.dropHitTest(atScreenPoint: p)
        XCTAssertEqual(hit?.insertionIndex, 0)
    }

    func testDropHitTestOnRegularTrackMapsLeftHalfToFirstSlot() {
        load([item("a", active: true), item("b")])
        let p = screenPoint(forBarPoint: NSPoint(x: 120, y: 18))
        XCTAssertEqual(bar.dropHitTest(atScreenPoint: p)?.insertionIndex, 0)
    }

    func testDropHitTestAtTrailingEdgeInsertsAtEnd() {
        load([item("a", active: true), item("b")])
        let p = screenPoint(forBarPoint: NSPoint(x: 740, y: 18))
        XCTAssertEqual(bar.dropHitTest(atScreenPoint: p)?.insertionIndex, 2)
    }

    func testDropHitTestSlotRectHasTabInnerHeightAndPositiveWidth() {
        load([item("a", active: true), item("b")])
        let p = screenPoint(forBarPoint: NSPoint(x: 400, y: 18))
        guard let hit = bar.dropHitTest(atScreenPoint: p) else { return XCTFail("expected a drop target") }
        XCTAssertEqual(hit.slotRectInScreen.height, SafariMetrics.tabInnerHeight, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(hit.slotRectInScreen.width, 40)
    }

    func testDropHitTestInsertionIndexIsClampedToVisibleCount() {
        load([item("a", active: true)])
        let p = screenPoint(forBarPoint: NSPoint(x: 759, y: 18))
        let hit = bar.dropHitTest(atScreenPoint: p)
        XCTAssertNotNil(hit)
        XCTAssertLessThanOrEqual(hit?.insertionIndex ?? 99, 1)
    }

    func testDropHitTestRegularTabsInsertionIndexMatchesPlaceholderSlots() {
        // Each sample point is the centre of the hypothetical slot for index k; the bar must report k.
        load([item("a", active: true), item("b"), item("c")])
        let fill = bar.computeFillWidth(forSlotCount: 4)
        let stride = fill / 4
        let originX = (bar.bounds.width - fill) * 0.5 + bar.computeTrackCenterOffset(slotCount: 4, trackWidth: fill)
        for k in 0..<3 {
            let x = originX + stride * (CGFloat(k) + 0.5)
            let hit = bar.dropHitTest(atScreenPoint: screenPoint(forBarPoint: NSPoint(x: x, y: 18)))
            XCTAssertEqual(hit?.insertionIndex, k, "centre of hypothetical slot \(k)")
        }
    }

    func testDropHitTestWithPinnedTabsSlotCentersMatchInsertionIndex() {
        // Regression for audit P05-2: pinned tabs are drawn at a fixed 36 pt. The hit test must agree
        // with where a placeholder would actually be laid out.
        load([item("a", active: true), item("p", pinned: true), item("b")])
        let total = 4
        _ = bar.computeFillWidth(forSlotCount: total)
        bar.updateExternalDropPlaceholder(tabID: "ext", insertionIndex: 1)
        spinRunLoop(0.4) // let the 0.28 s track-width animation finish before reading geometry
        container.layoutSubtreeIfNeeded()
        guard let actual = bar.resolvedDropSlotRectInScreen() else { return XCTFail("placeholder not laid out") }
        let actualCenter = NSPoint(x: actual.midX, y: actual.midY)
        bar.clearExternalTabDropPlaceholder(animated: false)
        spinRunLoop(0.4)
        container.layoutSubtreeIfNeeded()
        let hit = bar.dropHitTest(atScreenPoint: actualCenter)
        XCTAssertEqual(hit?.insertionIndex, 1)
    }

    /// For each insertion index k, places the external drop placeholder at k, reads the laid-out slot centre,
    /// then asks the bar which insertion index that point maps to. Returns the (expected, actual) mismatches.
    private func placeholderRoundTripMismatches(items: [TabPresentationItem]) -> [(expected: Int, actual: Int?)] {
        load(items)
        var mismatches: [(expected: Int, actual: Int?)] = []
        for k in 0...items.count {
            bar.updateExternalDropPlaceholder(tabID: "ext", insertionIndex: k)
            spinRunLoop(0.4)
            container.layoutSubtreeIfNeeded()
            guard let slot = bar.resolvedDropSlotRectInScreen() else {
                mismatches.append((k, nil))
                continue
            }
            let centre = NSPoint(x: slot.midX, y: slot.midY)
            bar.clearExternalTabDropPlaceholder(animated: false)
            spinRunLoop(0.4)
            container.layoutSubtreeIfNeeded()
            let actual = bar.dropHitTest(atScreenPoint: centre)?.insertionIndex
            if actual != k { mismatches.append((k, actual)) }
        }
        return mismatches
    }

    func testPlaceholderRoundTripRegularTabs() {
        let mismatches = placeholderRoundTripMismatches(items: [item("a", active: true), item("b"), item("c")])
        XCTAssertTrue(mismatches.isEmpty, "mismatches: \(mismatches)")
    }

    func testPlaceholderRoundTripActiveOnlyTab() {
        let mismatches = placeholderRoundTripMismatches(items: [item("a", active: true)])
        XCTAssertTrue(mismatches.isEmpty, "mismatches: \(mismatches)")
    }

    func testPlaceholderRoundTripActiveThenPinnedMatchesSlots() {
        // Audit P05-2 scenario: active tab plus one inactive pinned tab. Drop slots must round-trip.
        let mismatches = placeholderRoundTripMismatches(items: [item("a", active: true), item("p", pinned: true)])
        XCTAssertTrue(mismatches.isEmpty, "mismatches: \(mismatches)")
    
    }

    // MARK: - layout: pinned slots and track sizing

    /// Sum of the widths of the laid-out tab slots (inactive views + active pill) inside the track host.
    private func laidOutSlotWidthSum() -> (sum: CGFloat, trackWidth: CGFloat) {
        guard let host = bar.subviews.first(where: { String(describing: type(of: $0)) == "FlippedTrackHostView" }) else {
            return (0, 0)
        }
        let slotTypes: Set<String> = ["CompactInactiveTabView", "FlippedActivePillView"]
        let sum = host.subviews
            .filter { slotTypes.contains(String(describing: type(of: $0))) && !$0.isHidden }
            .reduce(CGFloat(0)) { $0 + $1.frame.width }
        return (sum, host.bounds.width)
    }

    func testTwoPinnedTabsFitInsideTrack() {
        load([item("a", active: true), item("p1", pinned: true), item("p2", pinned: true), item("b")])
        spinRunLoop(0.4)
        let (sum, track) = laidOutSlotWidthSum()
        XCTAssertGreaterThan(sum, 0)
        XCTAssertLessThanOrEqual(sum, track + 0.0001)
    }

    func testEighteenPinnedTabsOverflowTrackWidth() {
        // Regression for audit P05-3: 18 inactive pinned tabs (648 pt) plus an active tab in a 760 pt
        // track. The 120 pt regular floor forces the slots to 768 pt, which exceeds the track.
        var items = [item("a", active: true)]
        for i in 0..<18 { items.append(item("p\(i)", pinned: true)) }
        load(items)
        spinRunLoop(0.4)
        let (sum, track) = laidOutSlotWidthSum()
        XCTAssertLessThanOrEqual(sum, track + 0.0001)
    
    }

    func testFillWidthNeverExceedsTheTrackAvailableWidth() {
        var items = [item("a", active: true)]
        for i in 0..<40 { items.append(item("t\(i)")) }
        load(items)
        XCTAssertLessThanOrEqual(bar.computeFillWidth(), 760.0 + 0.0001)
    }

    func testScreenRectForUnknownTabFallsBackToActivePill() {
        load([item("a", active: true), item("b")])
        let fallback = bar.screenRectForTab(id: "does-not-exist")
        XCTAssertNotNil(fallback)
        XCTAssertEqual(fallback?.height ?? 0, SafariMetrics.tabPillHeight - 5, accuracy: 0.5)
    }

    func testScreenRectForInactiveTabIsAdjacentToActivePill() {
        load([item("a", active: true), item("b")])
        guard let active = bar.screenRectForTab(id: "a"), let inactive = bar.screenRectForTab(id: "b") else {
            return XCTFail("expected rects")
        }
        XCTAssertGreaterThan(inactive.minX, active.minX)
        XCTAssertEqual(inactive.minY, active.minY, accuracy: 0.5)
    }

    func testTabIDAtWindowPointFindsInactiveTabByItsScreenRect() {
        load([item("a", active: true), item("b")])
        guard let rect = bar.screenRectForTab(id: "b") else { return XCTFail("no rect") }
        let winPoint = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(bar.tabID(atWindowPoint: winPoint), "b")
    }

    func testTabIDAtWindowPointFindsActiveTab() {
        load([item("a", active: true), item("b")])
        guard let rect = bar.screenRectForTab(id: "a") else { return XCTFail("no rect") }
        let winPoint = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(bar.tabID(atWindowPoint: winPoint), "a")
    }

    func testTabIDAtWindowPointOutsideTrackIsNil() {
        load([item("a", active: true), item("b")])
        XCTAssertNil(bar.tabID(atWindowPoint: NSPoint(x: 1, y: 1)))
        XCTAssertFalse(bar.isPointInTabTrack(NSPoint(x: 1, y: 1)))
    }

    func testIsPointInTabTrackTrueInsideTrack() {
        load([item("a", active: true), item("b")])
        guard let rect = bar.screenRectForTab(id: "b") else { return XCTFail("no rect") }
        XCTAssertTrue(bar.isPointInTabTrack(window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))))
    }

    // MARK: - update(items:) state

    func testUpdateWithDifferentActiveTabKeepsTrackConsistent() {
        load([item("a", active: true), item("b")])
        let before = bar.computeFillWidth()
        load([item("a"), item("b", active: true)])
        XCTAssertEqual(bar.computeFillWidth(), before, accuracy: 0.0001)
    }

    func testUpdateWithEmptyItemsClearsHitTargets() {
        load([item("a", active: true), item("b")])
        guard let rect = bar.screenRectForTab(id: "b") else { return XCTFail("no rect") }
        load([])
        XCTAssertEqual(bar.effectiveSlotCount, 1)
        let winPoint = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
        XCTAssertNil(bar.tabID(atWindowPoint: winPoint))
    }

    func testUpdateAddsExternalPlaceholderRectInScreenSpace() {
        load([item("a", active: true), item("b")])
        bar.updateExternalDropPlaceholder(tabID: "ext", insertionIndex: 2)
        let rect = bar.resolvedDropSlotRectInScreen()
        XCTAssertNotNil(rect)
        XCTAssertGreaterThan(rect?.width ?? 0, 10)
        bar.clearExternalTabDropPlaceholder(animated: false)
        XCTAssertNil(bar.resolvedDropSlotRectInScreen())
    }

    func testUpdateExternalPlaceholderClampsIndexToVisibleCount() {
        load([item("a", active: true)])
        bar.updateExternalDropPlaceholder(tabID: "ext", insertionIndex: 99)
        XCTAssertEqual(bar.effectiveSlotCount, 2)
        bar.updateExternalDropPlaceholder(tabID: "ext", insertionIndex: -5)
        XCTAssertEqual(bar.effectiveSlotCount, 2)
    }

    func testHiddenTearOffTabIsRemovedFromDisplayedSlots() {
        load([item("a", active: true), item("b"), item("c")])
        bar.setTearOffHiddenTab(id: "b", animated: false)
        XCTAssertEqual(bar.effectiveSlotCount, 2)
        bar.setTearOffHiddenTab(id: nil, animated: false)
        XCTAssertEqual(bar.effectiveSlotCount, 3)
    }

    func testSingleAddressOnlyModeShowsOnlyActiveTabInSlots() {
        bar.singleAddressOnlyMode = true
        load([item("a"), item("b", active: true), item("c")])
        XCTAssertEqual(bar.effectiveSlotCount, 1)
        XCTAssertEqual(bar.displayedItems.map(\.id), ["b"])
    }


    func testSettingSameSidebarStateDoesNotRelayout() {
        load([item("a", active: true)])
        let before = bar.computeFillWidth()
        bar.isSidebarOpen = false
        XCTAssertEqual(bar.computeFillWidth(), before)
        bar.isSidebarOpen = true
        XCTAssertEqual(bar.computeFillWidth(), SafariMetrics.activePillSingleTabSidebarWidth)
        bar.isSidebarOpen = false
    }

    func testFocusRingRemainsHiddenDuringTabAnimationAndDelaysTransitionAfterCompletion() {
        load([item("a", active: true)])
        bar.beginExternalAnimation()
        bar.focusAddressBar()

        XCTAssertTrue(bar.isDeferringFocusRingForTesting)
        XCTAssertEqual(bar.focusRingModelOpacityForTesting, 0.0, accuracy: 0.001)
        XCTAssertNil(bar.focusRingScheduledDelayForTesting)

        bar.endExternalAnimation()
        XCTAssertFalse(bar.isDeferringFocusRingForTesting)
        XCTAssertEqual(bar.focusRingModelOpacityForTesting, 1.0, accuracy: 0.001)
        guard let scheduledDelay = bar.focusRingScheduledDelayForTesting else {
            return XCTFail("Expected delayed safariFocusRing animation after tab animation completion")
        }
        XCTAssertGreaterThan(scheduledDelay, 0.06)
        XCTAssertLessThanOrEqual(scheduledDelay, 0.16)
    }

    func testStartingNewTabAnimationCancelsPendingDelayedFocusRing() {
        load([item("a", active: true)])
        bar.beginExternalAnimation()
        bar.focusAddressBar()
        bar.endExternalAnimation()
        XCTAssertNotNil(bar.focusRingScheduledDelayForTesting)

        bar.beginExternalAnimation()
        XCTAssertEqual(bar.focusRingModelOpacityForTesting, 0.0, accuracy: 0.001)
        XCTAssertNil(bar.focusRingScheduledDelayForTesting)
        bar.endExternalAnimation()
    }

    func testOffscreenAnimatedUpdateNeverLeavesStuckFocusRingDeferral() {
        load([item("a", active: true)])
        bar.update(items: [item("a"), item("b", active: true)], animated: true)
        XCTAssertFalse(bar.isDeferringFocusRingForTesting)
        bar.focusAddressBar()
        XCTAssertEqual(bar.focusRingModelOpacityForTesting, 1.0, accuracy: 0.001)
        XCTAssertNotNil(bar.focusRingScheduledDelayForTesting)
    }
}
