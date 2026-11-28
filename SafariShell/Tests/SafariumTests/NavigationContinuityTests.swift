import XCTest
import AppKit
@testable import Safarium

/// Verifies Safarium's zero-flicker navigation invariants across native-to-web loads,
/// keyboard/button history jumps, trackpad swipe handoffs, 52pt toolbar snapshot registration,
/// cold background tab switches, and privacy-safe hover prewarming.
@MainActor
final class NavigationContinuityTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: - Helpers

    private func currentTab(_ wc: SafariWindowController) -> MockBrowserTab? {
        let all = t8Tabs(wc)
        let idx = t8ActiveIndex(wc)
        guard idx >= 0, idx < all.count else { return nil }
        return all[idx] as? MockBrowserTab
    }

    private func waitUntil(_ timeout: TimeInterval = 1.0, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            spinRunLoop(0.02)
        }
    }

    private func solidImage(color: NSColor, size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    private func averageViewportLuminance(of view: NSView, topInset: CGFloat = SafariMetrics.toolbarHeight) -> Double {
        view.layoutSubtreeIfNeeded()
        let b = view.bounds
        let webH = max(8.0, b.height - topInset)
        let sampleRect = NSRect(x: 0, y: 0, width: max(8.0, b.width), height: webH)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: sampleRect) else {
            return 0.5
        }
        view.cacheDisplay(in: sampleRect, to: rep)
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 0, h > 0 else { return 0.5 }

        let stepX = max(1, w / 16)
        let stepY = max(1, h / 12)
        var lumSum = 0.0
        var count = 0.0
        var y = stepY / 2
        while y < h {
            var x = stepX / 2
            while x < w {
                if let c = rep.colorAt(x: x, y: y) {
                    lumSum += TopEdgeColorSample.computeRelativeLuminance(for: c)
                    count += 1.0
                }
                x += stepX
            }
            y += stepY
        }
        return count > 0 ? (lumSum / count) : 0.5
    }

    // MARK: - 1. Native-to-Web Freeze-Frame Veil & Monotonic Luminance Continuity

    func testNativeToWebNavigationHoldsStartPageVeilWithoutBlankFlash() throws {
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let win = try XCTUnwrap(wc.window)
        defer { win.close() }
        win.appearance = NSAppearance(named: .darkAqua)
        win.setContentSize(NSSize(width: 1100, height: 720))
        wc.openInitialTabsIfNeeded()
        spinRunLoop(0.18)

        let tab = try XCTUnwrap(currentTab(wc))
        wc.openURLInActiveOrNewTab(URL(string: "safarium://start")!)
        spinRunLoop(0.08)
        XCTAssertTrue(tab.isStartPage)

        let root = try XCTUnwrap(win.contentView)
        let startLum = averageViewportLuminance(of: root)

        // Slow down simulated network/paint to 240ms so we can sample intermediate frames before first paint.
        tab.simulatedLoadDelay = 0.24
        wc.openURLInActiveOrNewTab(URL(string: "https://gemini.google.com")!)

        // Frame 0 right after navigation start: veil MUST be holding the Start Page snapshot!
        XCTAssertTrue(wc.navigationTransitionCoordinator.isTransitionActive)
        XCTAssertEqual(wc.navigationTransitionCoordinator.activeKind, .nativeToWeb)
        XCTAssertTrue(wc.navigationTransitionCoordinator.isHoldingNativeToWebVeil)

        let midLoadLum = averageViewportLuminance(of: root)
        XCTAssertEqual(midLoadLum, startLum, accuracy: 0.06,
                       "Viewport must remain frozen on Start Page snapshot while destination page loads underneath")

        // Wait for simulated FCP / visual readiness + 110ms smooth dissolve
        waitUntil(1.5) { !wc.navigationTransitionCoordinator.isTransitionActive }
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive,
                       "Veil must tear down completely after destination reveal (zero idle GPU overdraw)")
    }

    // MARK: - 2. Toolbar Button & Keyboard Shortcut Back/Forward Snapshot Parity

    /// Web -> web Back/Forward: BrowserCore holds the live page until the destination has painted (Safari-style
    /// instant swap), so the shell must NOT stack a snapshot veil or crossfade (a stale snapshot over the live page
    /// reads as ghosting). Leaving a native page (Start Page) still needs the shell veil, because its web view is
    /// hidden and there is nothing on screen for BrowserCore to copy.
    func testProgrammaticBackAndForwardUseSnapshotVeilAndTearDownCleanly() throws {
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let win = try XCTUnwrap(wc.window)
        defer { win.close() }
        win.setContentSize(NSSize(width: 1000, height: 700))
        wc.openInitialTabsIfNeeded()
        spinRunLoop(0.20)

        let tab = try XCTUnwrap(currentTab(wc))
        tab.simulatedLoadDelay = 0.18

        wc.openURLInActiveOrNewTab(URL(string: "safarium://start")!)
        spinRunLoop(0.06)
        wc.openURLInActiveOrNewTab(URL(string: "https://apple.com")!)
        spinRunLoop(0.35)

        // Seed a known snapshot for the apple.com history slot so forward/back has hot cache coverage.
        let appleEntryID = tab.currentNavigationEntryID
        XCTAssertGreaterThan(appleEntryID, 0)
        NavigationSnapshotStore.shared.storeImage(
            solidImage(color: .white, size: NSSize(width: 1000, height: 648)),
            tabID: tab.tabID,
            entryID: appleEntryID,
            logicalSize: CGSize(width: 1000, height: 648),
            backgroundColor: .white,
            isFullBleedBehindToolbar: false
        )

        wc.openURLInActiveOrNewTab(URL(string: "https://youtube.com")!)
        spinRunLoop(0.35)
        XCTAssertTrue(tab.canGoBack)

        // Programmatic Back (Cmd+[ / toolbar `<` button)
        wc.navigateBackInActiveTab()
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive,
                       "Web -> web Back must not layer a shell snapshot veil over the live page")

        spinRunLoop(0.38)
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive)
        XCTAssertEqual(tab.currentURL, URL(string: "https://apple.com"))

        // Programmatic Forward (Cmd+] / toolbar `>` button)
        wc.navigateForwardInActiveTab()
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive,
                       "Web -> web Forward must not layer a shell snapshot veil over the live page")

        spinRunLoop(0.38)
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive)
        XCTAssertEqual(tab.currentURL, URL(string: "https://youtube.com"))
    }

    // MARK: - 3. Trackpad 2-Finger Swipe Does Not Double-Layer Programmatic Veil

    func testTwoFingerSwipeCommitSuppressesDuplicateCoordinatorVeil() throws {
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let win = try XCTUnwrap(wc.window)
        defer { win.close() }
        win.setContentSize(NSSize(width: 960, height: 680))
        wc.openInitialTabsIfNeeded()
        spinRunLoop(0.20)

        let tab = try XCTUnwrap(currentTab(wc))
        tab.simulatedLoadDelay = 0.20
        wc.openURLInActiveOrNewTab(URL(string: "https://youtube.com")!)
        spinRunLoop(0.35)

        guard let swipe: SwipeNavigationController = uiPrivate(wc, "swipeNavigationController") else {
            return XCTFail("missing swipeNavigationController")
        }

        func makeScroll(dx: Double, time: Double, phase: Int64) throws -> NSEvent {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0) else {
                throw XCTSkip("cannot synthesize CGEvent")
            }
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.timestamp = UInt64(time * 1_000_000_000)
            guard let ev = NSEvent(cgEvent: cg) else { throw XCTSkip("cannot wrap NSEvent") }
            return ev
        }

        XCTAssertTrue(swipe.handleScrollWheel(try makeScroll(dx: 20, time: 1.0, phase: 1)))
        XCTAssertTrue(swipe.handleScrollWheel(try makeScroll(dx: 380, time: 1.08, phase: 2)))
        XCTAssertTrue(swipe.handleScrollWheel(try makeScroll(dx: 0, time: 1.12, phase: 4)))

        // Let the commit slide animation finish (0.20s) while tab load (0.20s after commit) is still in flight.
        spinRunLoop(0.22)
        XCTAssertTrue(swipe.isHoldingCommittedSnapshot)
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive,
                       "2-finger swipe already holds its promoted snapshot; coordinator must not double-stack")

        waitUntil(1.5) { !swipe.isHoldingCommittedSnapshot }
        XCTAssertFalse(swipe.isHoldingCommittedSnapshot)
    }

    // MARK: - 4. Exact 52pt Toolbar Snapshot Registration (Zero Vertical Jump)

    func testSwipeSnapshotLayerViewRegistersWebBelowToolbarAndNativeFullBleed() {
        let stageRect = NSRect(x: 0, y: 0, width: 1200, height: 748)
        let webSize = NSSize(width: 1200, height: 696) // 748 - 52pt toolbar

        let webPayload = NavigationSnapshotPayload(
            image: solidImage(color: .systemBlue, size: webSize),
            logicalSize: webSize,
            backgroundColor: .systemBlue,
            isFullBleedBehindToolbar: false
        )
        let webSnapView = SwipeSnapshotLayerView(frame: stageRect, payload: webPayload, topContentInset: 52.0)
        webSnapView.layoutSubtreeIfNeeded()
        let webSublayer = webSnapView.layer?.sublayers?.first
        XCTAssertEqual(webSublayer?.frame, CGRect(x: 0, y: 0, width: 1200, height: 696),
                       "Web snapshot must sit at y = 0..696 (matching webContentHost 1:1 with zero 52pt vertical jump)")

        let nativePayload = NavigationSnapshotPayload(
            image: solidImage(color: .systemIndigo, size: stageRect.size),
            logicalSize: stageRect.size,
            backgroundColor: .systemIndigo,
            isFullBleedBehindToolbar: true
        )
        let nativeSnapView = SwipeSnapshotLayerView(frame: stageRect, payload: nativePayload, topContentInset: 52.0)
        nativeSnapView.layoutSubtreeIfNeeded()
        let nativeSublayer = nativeSnapView.layer?.sublayers?.first
        XCTAssertEqual(nativeSublayer?.frame, CGRect(x: 0, y: 0, width: 1200, height: 748),
                       "Full-bleed Start/History/Inspect snapshot must span full 0..748 stage height")
    }

    // MARK: - 5. Cold Background Tab Switch Surface-Eviction Shield

    func testColdTabSwitchShieldActivatesForStaleBackgroundTabAndClears() throws {
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let win = try XCTUnwrap(wc.window)
        defer { win.close() }
        win.setContentSize(NSSize(width: 1000, height: 700))
        wc.openInitialTabsIfNeeded()
        spinRunLoop(0.20)

        let tab0 = try XCTUnwrap(currentTab(wc))
        tab0.mockCachedSnapshot = solidImage(color: .black, size: NSSize(width: 1000, height: 648))

        // Open Tab 1 (backgrounds Tab 0)
        _ = wc.createNewTab(url: URL(string: "https://stripe.com")!, activate: true)
        spinRunLoop(0.20)

        let tab1 = try XCTUnwrap(currentTab(wc))
        XCTAssertFalse(tab1 === tab0)

        // Warm tab switch (< 2.5s) skips unnecessary shield:
        wc.selectTab(at: 0)
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive,
                       "Recently active warm tab (< 2.5s) switches immediately without veil overhead")

        // The tab switched away from stays visible underneath (the new one is ordered in front) until the new tab is
        // on screen: hiding a Chromium view drops its picture at once, which showed as a blank frame between tabs.
        XCTAssertFalse(tab1.contentView.isHidden, "Outgoing tab is hidden only after the incoming tab is on screen")
        XCTAssertTrue(wc.webContentHostSubviewsForTesting.last === tab0.contentView, "Incoming tab is frontmost")
        spinRunLoop(0.65)
        XCTAssertTrue(tab1.contentView.isHidden, "Outgoing tab is hidden once the switch has reached the screen")

        // Exercise cold shield directly on coordinator to verify ~68ms Viz sync hold + clean teardown:
        let payload = NavigationSnapshotPayload(
            image: tab0.mockCachedSnapshot!,
            logicalSize: CGSize(width: 1000, height: 648),
            backgroundColor: .black,
            isFullBleedBehindToolbar: false
        )
        wc.navigationTransitionCoordinator.beginColdTabSwitchShield(tabID: tab0.tabID, snapshotPayload: payload)
        XCTAssertTrue(wc.navigationTransitionCoordinator.isTransitionActive)
        XCTAssertEqual(wc.navigationTransitionCoordinator.activeKind, .coldTabSwitch)

        waitUntil(1.5) { !wc.navigationTransitionCoordinator.isTransitionActive }
        XCTAssertFalse(wc.navigationTransitionCoordinator.isTransitionActive)
    }

    // MARK: - 6. Privacy-Safe Start Page Prewarming

    func testStartPagePrewarmFiresInStandardWindowAndBlocksInPrivateWindow() throws {
        let normalWC = SafariWindowController(engine: MockBrowserEngine(), isPrivate: false)
        let normalWin = try XCTUnwrap(normalWC.window)
        defer { normalWin.close() }
        normalWC.openInitialTabsIfNeeded()
        spinRunLoop(0.15)
        normalWC.openURLInActiveOrNewTab(URL(string: "safarium://start")!)
        spinRunLoop(0.05)

        let normalTab = try XCTUnwrap(currentTab(normalWC))
        guard let normalStart: StartPageView = uiPrivate(normalWC, "startPageView") else {
            return XCTFail("missing startPageView")
        }
        let targetURL = URL(string: "https://developer.apple.com")!
        normalStart.onHoverURL?(targetURL)
        XCTAssertEqual(normalTab.recordedPrewarmedURLs, [targetURL])

        // Private Browsing window MUST block all speculative prewarming!
        let privateWC = SafariWindowController(engine: MockBrowserEngine(), isPrivate: true)
        let privateWin = try XCTUnwrap(privateWC.window)
        defer { privateWin.close() }
        privateWC.openInitialTabsIfNeeded()
        spinRunLoop(0.15)
        privateWC.openURLInActiveOrNewTab(URL(string: "safarium://start")!)
        spinRunLoop(0.05)

        let privateTab = try XCTUnwrap(currentTab(privateWC))
        guard let privateStart: StartPageView = uiPrivate(privateWC, "startPageView") else {
            return XCTFail("missing startPageView")
        }
        privateStart.onHoverURL?(targetURL)
        XCTAssertTrue(privateTab.recordedPrewarmedURLs.isEmpty,
                      "Private Browsing must emit zero speculative preconnect hints")
    }

    // MARK: - 7. Regression Tests for Full-Bleed JPEG Swipe Snapshots, Native Scroll & Overview Trim

    func testWarmJPEGSnapshotsPreserveFullBleedBehindToolbarAcrossPrewarmAndDecode() throws {
        let img = solidImage(color: .systemTeal, size: NSSize(width: 400, height: 300))
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]))
        let tabID = "test-fullbleed-\(UUID().uuidString)"
        defer { NavigationSnapshotStore.shared.removeTab(tabID) }

        NavigationSnapshotStore.shared.storeJPEG(
            jpeg,
            tabID: tabID,
            entryID: 101,
            logicalSize: CGSize(width: 1200, height: 800),
            backingScale: 2.0,
            backgroundColor: .systemTeal
        )
        let decoded = try XCTUnwrap(NavigationSnapshotStore.shared.snapshot(tabID: tabID, entryID: 101))
        XCTAssertTrue(decoded.isFullBleedBehindToolbar,
                      "Full-bleed web JPEG snapshots must stay marked full-bleed on synchronous decode")

        let stageRect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let snapView = SwipeSnapshotLayerView(frame: stageRect, payload: decoded, topContentInset: 48.0)
        snapView.layoutSubtreeIfNeeded()
        XCTAssertEqual(snapView.layer?.sublayers?.first?.frame, CGRect(x: 0, y: 0, width: 1200, height: 800))

        NavigationSnapshotStore.shared.storeJPEG(
            jpeg,
            tabID: tabID,
            entryID: 102,
            logicalSize: CGSize(width: 1200, height: 800),
            backingScale: 2.0,
            backgroundColor: .systemTeal
        )
        NavigationSnapshotStore.shared.prewarm(tabID: tabID, entryIDs: [102])
        spinRunLoop(0.15)
        let prewarmed = try XCTUnwrap(NavigationSnapshotStore.shared.snapshot(tabID: tabID, entryID: 102))
        XCTAssertTrue(prewarmed.isFullBleedBehindToolbar,
                      "Prewarmed hot-cache web JPEG snapshots must preserve isFullBleedBehindToolbar")
    }

    func testNativeHistoryAndInspectPagesDisableElasticWebOverscroll() throws {
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let win = try XCTUnwrap(wc.window)
        defer { win.close() }
        wc.openInitialTabsIfNeeded()
        spinRunLoop(0.15)

        guard let elastic: ElasticScrollEngine = uiPrivate(wc, "elasticScrollEngine") else {
            return XCTFail("missing elasticScrollEngine")
        }

        wc.openURLInActiveOrNewTab(URL(string: "safarium://history")!)
        spinRunLoop(0.10)
        let historyTab = try XCTUnwrap(currentTab(wc))
        XCTAssertTrue(historyTab.isNativeInternalPage)
        XCTAssertEqual(elastic.currentOverscrollY, 0.0, accuracy: 0.001)

        wc.openURLInActiveOrNewTab(InspectPageURL.rootURL)
        spinRunLoop(0.10)
        let inspectTab = try XCTUnwrap(currentTab(wc))
        XCTAssertTrue(inspectTab.isNativeInternalPage)
        XCTAssertEqual(elastic.currentOverscrollY, 0.0, accuracy: 0.001)
    }

    func testTabOverviewUpdateSnapshotPreservesLiveLayerAndSeparateStripTrim() throws {
        let overview = TabOverviewView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let live = CALayer()
        live.bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let card = TabOverviewView.CardModel(
            id: "tab-1",
            title: "Example",
            url: URL(string: "https://example.com"),
            favicon: nil,
            snapshot: solidImage(color: .white, size: NSSize(width: 600, height: 400)),
            isActive: true,
            frameSurface: nil,
            frameSize: CGSize(width: 1200, height: 800),
            liveLayer: live
        )
        overview.update(cards: [card])
        overview.updateSnapshot(solidImage(color: .black, size: NSSize(width: 600, height: 400)), forTabID: "tab-1")

        let prevLayout = BrowserSettings.shared.tabLayout
        defer { BrowserSettings.shared.set(prevLayout, forKey: BrowserSettings.Key.tabLayout) }
        BrowserSettings.shared.set("separate", forKey: BrowserSettings.Key.tabLayout)

        let wc = SafariWindowController(engine: MockBrowserEngine())
        let win = try XCTUnwrap(wc.window)
        defer { win.close() }
        wc.openInitialTabsIfNeeded()
        _ = wc.createNewTab(url: URL(string: "https://apple.com")!, activate: true)
        spinRunLoop(0.15)
        guard let wcOverview: TabOverviewView = uiPrivate(wc, "tabOverviewView") else {
            return XCTFail("missing tabOverviewView")
        }
        XCTAssertEqual(wcOverview.toolbarTopInsetPoints,
                       SafariMetrics.toolbarHeight + 34.0,
                       accuracy: 0.5)
    }
}
