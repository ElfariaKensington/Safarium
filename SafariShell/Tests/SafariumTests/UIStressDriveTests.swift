import XCTest
import AppKit
@testable import Safarium

/// Human-style, headless (never ordered on screen) UI drive & stress tests against MockBrowserEngine.
@MainActor
final class UIStressDriveTests: HermeticTestCase {
    nonisolated var scratch: String { "/private/tmp/claude-501/-Users-elfaria-SafariX/9c5f1d60-0c86-4a5d-9a2e-23146ae56677/scratchpad/shots" }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }

    func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func make(isPrivate: Bool = false) -> SafariWindowController {
        let wc = SafariWindowController(engine: MockBrowserEngine(), isPrivate: isPrivate)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return wc
    }

    func snap(_ wc: SafariWindowController, _ name: String) {
        guard let v = wc.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(scratch)/\(name).png"))
    }

    // MARK: tab lifecycle

    func testRapidOpenCloseHundreds() {
        let wc = make()
        weak var weakTab: BrowserTabEngine?
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<300 {
            let t = wc.createNewTab(url: URL(string: "https://example.com/\(i)")!, activate: i % 3 != 0)
            if i == 0 { weakTab = t }
        }
        XCTAssertEqual(wc.openTabCount, 300)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        snap(wc, "stress_300_tabs")
        let mid = CFAbsoluteTimeGetCurrent()
        while wc.openTabCount > 1 { wc.closeTab(at: wc.openTabCount / 2) }
        XCTAssertEqual(wc.openTabCount, 1)
        spin(0.3)
        let t1 = CFAbsoluteTimeGetCurrent()
        print("PERF open300=\(mid - t0)s close299=\(t1 - mid)s")
        // Regression guard (PERF-1 reduced this from ~23 s): the tab strip now reuses its separator views instead of
        // allocating one NSView per slot per update; the rest of the time is MockBrowserTab building demo pages.
        XCTAssertLessThan(t1 - t0, 16, "300 tab open/close should stay interactive")
        _ = weakTab
    }

    func testOutOfRangeIndicesDoNotCrash() {
        let wc = make()
        wc.selectTab(at: 0); wc.selectTab(at: -1); wc.selectTab(at: 99)
        wc.closeTab(at: -5); wc.closeTab(at: 42)
        wc.cycleNextTab(); wc.cyclePreviousTab()
        wc.selectTabShortcut(tag: 0); wc.selectTabShortcut(tag: 9); wc.selectTabShortcut(tag: -1); wc.selectTabShortcut(tag: 1000)
        _ = wc.createNewTab(url: nil)
        wc.selectTabShortcut(tag: 9); wc.selectTabShortcut(tag: 5)
        wc.reopenClosedTab(atReversedIndex: 0); wc.reopenClosedTab(atReversedIndex: -1); wc.reopenClosedTab(atReversedIndex: 100)
        wc.reopenLastClosedTab()
        wc.reorderTabs(matchingOrder: []); wc.reorderTabs(matchingOrder: ["x", "y", "z"])
        XCTAssertGreaterThanOrEqual(wc.openTabCount, 1)
    }

    func testClosedTabHistoryBounds() {
        let wc = make()
        for i in 0..<120 {
            _ = wc.createNewTab(url: URL(string: "https://e\(i).example.com/")!)
            wc.closeTab(at: 0)
        }
        XCTAssertLessThanOrEqual(wc.recentClosedURLsForMenu.count, 10)
    }

    func testPrivateWindowNeverRecordsClosedTabs() {
        let wc = make(isPrivate: true)
        _ = wc.createNewTab(url: URL(string: "https://secret.example.com/a")!)
        _ = wc.createNewTab(url: URL(string: "https://secret.example.com/b")!)
        wc.closeTab(at: 0)
        XCTAssertFalse(wc.hasRecentlyClosedTabs, "private window must not remember closed tabs")
    }

    func testReopenRoundTrip() {
        let wc = make()
        _ = wc.createNewTab(url: URL(string: "https://a.example.com/")!)
        _ = wc.createNewTab(url: URL(string: "https://b.example.com/")!)
        wc.closeTab(at: 1)
        XCTAssertTrue(wc.hasRecentlyClosedTabs)
        let n = wc.openTabCount
        wc.reopenLastClosedTab()
        XCTAssertEqual(wc.openTabCount, n + 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://b.example.com/")
    }

    func testTabsDeallocateAfterClose() {
        let wc = make()
        var refs: [WeakBox] = []
        for i in 0..<40 {
            let t = wc.createNewTab(url: URL(string: "https://leak.example.com/\(i)")!)
            refs.append(WeakBox(t))
        }
        for _ in 0..<39 { wc.closeTab(at: 0) }
        spin(0.5)
        let alive = refs.filter { $0.value != nil }.count
        print("LEAK-CHECK tabs alive after close: \(alive) (expected 1)")
        XCTAssertLessThanOrEqual(alive, 1, "closed tabs are leaking (retain cycle)")
    }

    func testControllerDeallocates() {
        weak var weakWC: SafariWindowController?
        autoreleasepool {
            let wc = make()
            weakWC = wc
            for i in 0..<5 { _ = wc.createNewTab(url: URL(string: "https://x.example.com/\(i)")!) }
            wc.toggleSidebar(); wc.toggleTabOverview(); spin(0.4)
            wc.window?.close()
        }
        spin(1.0)
        print("LEAK-CHECK controller alive: \(weakWC != nil)")
        XCTAssertNil(weakWC, "SafariWindowController leaked after window close")
    }

    // MARK: layout / resize

    func testResizeExtremesKeepChromeSane() throws {
        let wc = make()
        _ = wc.createNewTab(url: URL(string: "https://example.com")!)
        _ = wc.createNewTab(url: URL(string: "https://apple.com")!)
        let w = try XCTUnwrap(wc.window)
        for size in [NSSize(width: 100, height: 100), NSSize(width: 680, height: 460), NSSize(width: 1200, height: 800), NSSize(width: 3000, height: 2000), NSSize(width: 681, height: 461)] {
            // A user drag goes through windowWillResize, which enforces the declared minimum.
            let proposed = wc.windowWillResize(w, to: w.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size)
            w.setContentSize(w.contentRect(forFrameRect: NSRect(origin: .zero, size: proposed)).size)
            w.contentView?.layoutSubtreeIfNeeded()
            spin(0.05)
            XCTAssertGreaterThanOrEqual(w.frame.width, SafariMetrics.minWindowWidth - 1, "min width not enforced at \(size)")
            snap(wc, "resize_\(Int(size.width))x\(Int(size.height))")
            assertNoNegativeOrNaNFrames(in: try XCTUnwrap(w.contentView), context: "\(size)")
        }
    }

    func testSidebarAndOverviewToggleStorm() throws {
        let wc = make()
        for i in 0..<8 { _ = wc.createNewTab(url: URL(string: "https://example.com/\(i)")!) }
        for _ in 0..<25 { wc.toggleSidebar() }
        for _ in 0..<25 { wc.toggleTabOverview() }
        wc.showBookmarksSidebar(); wc.showReadingListSidebar(); wc.showTabsSidebar()
        spin(0.8)
        snap(wc, "after_toggle_storm")
        assertNoNegativeOrNaNFrames(in: try XCTUnwrap(wc.window?.contentView), context: "after toggle storm")
        XCTAssertEqual(wc.openTabCount, 8)
    }

    func testMenuActionsOnEmptyAndStartPages() {
        let wc = make()
        _ = wc.createNewTab(url: nil)
        wc.showFindBar(); wc.findNextMatch(); wc.findPreviousMatch(); wc.hideFindBar()
        wc.zoomInActiveTab(); wc.zoomOutActiveTab(); wc.resetZoomActiveTab()
        for _ in 0..<40 { wc.zoomInActiveTab() }
        for _ in 0..<80 { wc.zoomOutActiveTab() }
        wc.reloadActiveTab(); wc.reloadActiveTabIgnoringCache(); wc.navigateBack(); wc.navigateForward()
        wc.goToHomepage(); wc.showStartPageInActiveTab(); wc.openHistoryPage()
        wc.toggleMuteActiveTab(); wc.muteOtherTabs(); wc.arrangeTabsByTitle(); wc.arrangeTabsByWebsite()
        wc.duplicateActiveTab(); wc.handleEscapeOrStop(); wc.copyCurrentPageURL()
        wc.bookmarkCurrentPage(); wc.addCurrentPageToReadingList(); wc.bookmarkAllOpenTabs(); wc.addOpenTabsToReadingList()
        spin(0.3)
        XCTAssertGreaterThanOrEqual(wc.openTabCount, 1)
    }

    func testHugeAndHostileURLs() {
        let wc = make()
        let hostile = [
            "javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "file:///etc/passwd",
            String(repeating: "a", count: 200_000), "http://", "https://", "://", " ", "\n", "\u{0000}",
            "http://[::1", "http://exa mple.com", "http://例え.テスト/パス?q=日本語", "http://user:pa%ss@host/",
            "about:blank", "chrome://settings", "ftp://example.com", "view-source:https://example.com",
        ]
        for s in hostile {
            if let u = URL(string: s) { _ = wc.createNewTab(url: u) }
            wc.activeWebPageURLString.map { _ in () }
        }
        spin(0.3)
        XCTAssertGreaterThanOrEqual(wc.openTabCount, 1)
    }

    // MARK: helpers

    func assertNoNegativeOrNaNFrames(in root: NSView, context: String, file: StaticString = #filePath, line: UInt = #line) {
        var bad: [String] = []
        func walk(_ v: NSView, _ depth: Int) {
            let f = v.frame
            if f.origin.x.isNaN || f.origin.y.isNaN || f.size.width.isNaN || f.size.height.isNaN
                || f.size.width < 0 || f.size.height < 0 || f.isInfinite {
                bad.append("\(type(of: v)) frame=\(f)")
            }
            if depth < 12 { v.subviews.forEach { walk($0, depth + 1) } }
        }
        walk(root, 0)
        XCTAssertTrue(bad.isEmpty, "[\(context)] invalid frames: \(bad.prefix(5))", file: file, line: line)
    }
}

