import XCTest
import AppKit
@testable import Safarium

/// Regression: the window used to widen by itself as tabs were opened / the sidebar toggled (live test drive:
/// 1200 -> 1272 -> 1356 -> 1392 pt) because toolbar constraints above the window-size priority demanded more width.
@MainActor
final class WindowGrowthTests: HermeticTestCase {
    func make() -> (SafariWindowController, NSWindow) {
        _ = NSApplication.shared
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let w = wc.window!
        w.setContentSize(NSSize(width: 1200, height: 800))
        // Constraint-driven window sizing only happens for windows that are on a screen; park it far off-screen.
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderBack(nil)
        w.contentView?.layoutSubtreeIfNeeded()
        print("GROWTH visible", w.isVisible, w.frame.origin)
        return (wc, w)
    }

    func testOpeningTabsDoesNotWidenTheWindow() {
        let (wc, w) = make()
        let start = w.frame.width
        print("GROWTH start", start)
        for i in 0..<8 {
            _ = wc.createNewTab(url: URL(string: "https://site\(i).example.com/")!)
            w.contentView?.layoutSubtreeIfNeeded(); spinRunLoop(0.05)
            print("GROWTH tabs", i + 1, w.frame.width, w.contentMinSize.width)
        }
        XCTAssertEqual(w.frame.width, start, accuracy: 0.5, "window widened while opening tabs")
        w.close()
    }

    func testSidebarToggleDoesNotWidenTheWindow() {
        let (wc, w) = make()
        for i in 0..<4 { _ = wc.createNewTab(url: URL(string: "https://site\(i).example.com/")!) }
        w.contentView?.layoutSubtreeIfNeeded()
        let start = w.frame.width
        wc.toggleSidebar(); spinRunLoop(0.5); w.contentView?.layoutSubtreeIfNeeded()
        print("GROWTH sidebar open", w.frame.width)
        wc.toggleSidebar(); spinRunLoop(0.5); w.contentView?.layoutSubtreeIfNeeded()
        print("GROWTH sidebar closed", w.frame.width)
        XCTAssertEqual(w.frame.width, start, accuracy: 0.5, "window widened across a sidebar open/close")
        w.close()
    }

    func testTabStripNeverOverlapsRightActionsWhenSidebarIsOpen() {
        let (wc, w) = make()
        for i in 0..<4 { _ = wc.createNewTab(url: URL(string: "https://site\(i).example.com/")!) }
        wc.toggleSidebar(); spinRunLoop(0.6); w.contentView?.layoutSubtreeIfNeeded(); spinRunLoop(0.2)
        wc.focusAddressBar(); spinRunLoop(0.4); w.contentView?.layoutSubtreeIfNeeded()
        var bars: [CompactTabAddressBar] = []
        var capsules: [GlassActionCapsule] = []
        func walk(_ v: NSView) {
            if let b = v as? CompactTabAddressBar { bars.append(b) }
            if let c = v as? GlassActionCapsule { capsules.append(c) }
            v.subviews.forEach(walk)
        }
        walk(w.contentView!)
        let bar = bars.first!
        let barRect = bar.convert(bar.bounds, to: nil)
        var rightmost: CGFloat = 0
        func scan(_ v: NSView) {
            guard !v.isHidden, v.alphaValue > 0.01 else { return }
            let r = v.convert(v.bounds, to: nil)
            if r.width > 1 { rightmost = max(rightmost, r.maxX) }
            v.subviews.forEach(scan)
        }
        scan(bar)
        XCTAssertLessThanOrEqual(rightmost, barRect.maxX + 0.5, "tab strip content overflows the tab bar (pill at \(rightmost), bar ends at \(barRect.maxX))")
        let rightCapsule = capsules.map { $0.convert($0.bounds, to: nil) }.filter { $0.minX > barRect.midX }.min { $0.minX < $1.minX }
        if let rightCapsule { XCTAssertLessThanOrEqual(rightmost, rightCapsule.minX + 0.5, "tab strip overlaps the right action capsule") }
        w.close()
    }
}

@MainActor
final class WindowMinimumSizeTests: HermeticTestCase {
    func testUserResizeIsClampedToDeclaredMinimum() {
        _ = NSApplication.shared
        let wc = SafariWindowController(engine: MockBrowserEngine())
        let w = wc.window!
        let tiny = wc.windowWillResize(w, to: NSSize(width: 100, height: 100))
        XCTAssertEqual(tiny.width, SafariMetrics.minWindowWidth)
        XCTAssertEqual(tiny.height, SafariMetrics.minWindowHeight)
        XCTAssertEqual(wc.windowWillResize(w, to: NSSize(width: 1500, height: 900)), NSSize(width: 1500, height: 900))
        w.close()
    }
}
