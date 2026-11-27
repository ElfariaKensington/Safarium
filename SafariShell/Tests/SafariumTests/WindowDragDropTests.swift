import XCTest
import AppKit
@testable import Safarium

/// Drop-boundary policy (`SafariWindow.extractDroppedURL`) and the controller side of a drop
/// (`onDropURL` routing). Each case uses its own named pasteboard, never the general pasteboard.
@MainActor
final class WindowDragDropTests: T8WindowTestCase {

    private var boards: [NSPasteboard] = []

    override func tearDown() {
        for board in boards { board.releaseGlobally() }
        boards.removeAll()
        super.tearDown()
    }

    /// Pasteboard carrying only the `NSURL` representation.
    private func urlBoard(_ s: String) -> NSPasteboard {
        let pb = t8Pasteboard()
        boards.append(pb)
        pb.clearContents()
        pb.writeObjects([URL(string: s)! as NSURL])
        return pb
    }

    /// Pasteboard carrying only the plain-string representation.
    private func stringBoard(_ s: String) -> NSPasteboard {
        let pb = t8Pasteboard()
        boards.append(pb)
        pb.clearContents()
        pb.setString(s, forType: .string)
        return pb
    }

    private func dropped(_ pb: NSPasteboard) -> URL? {
        SafariWindow.extractDroppedURL(from: pb)
    }

    private func dropWindow(_ wc: SafariWindowController) -> SafariWindow {
        wc.window as! SafariWindow
    }

    // MARK: - URL-object representation: allowlist

    func testHTTPSURLObjectIsAccepted() {
        XCTAssertEqual(dropped(urlBoard("https://example.com/a?b=c")), url("https://example.com/a?b=c"))
    }

    func testHTTPURLObjectIsAccepted() {
        XCTAssertEqual(dropped(urlBoard("http://plain.example.com/")), url("http://plain.example.com/"))
    }

    func testFileURLObjectIsAccepted() {
        XCTAssertEqual(dropped(urlBoard("file:///tmp/t8-drop.html"))?.scheme, "file")
    }

    func testSafariumURLObjectIsAccepted() {
        XCTAssertEqual(dropped(urlBoard("safarium://start")), url("safarium://start"))
    }

    func testChromeURLObjectIsAccepted() {
        XCTAssertEqual(dropped(urlBoard("chrome://settings"))?.scheme, "chrome")
    }

    func testViewSourceURLObjectIsAccepted() {
        XCTAssertEqual(dropped(urlBoard("view-source:https://example.com/"))?.scheme, "view-source")
    }

    func testJavascriptURLObjectIsRejected() {
        XCTAssertNil(dropped(urlBoard("javascript:alert(1)")))
    }

    func testDataURLObjectIsRejected() {
        XCTAssertNil(dropped(urlBoard("data:text/html,hello")))
    }

    func testCustomSchemeURLObjectIsRejected() {
        XCTAssertNil(dropped(urlBoard("myapp://open/doc")))
    }

    func testURLObjectBeatsStringWhenBothPresent() {
        let pb = t8Pasteboard()
        boards.append(pb)
        pb.clearContents()
        pb.writeObjects([url("https://first.example.com/") as NSURL])
        pb.setString("https://second.example.com/", forType: .string)
        XCTAssertEqual(dropped(pb), url("https://first.example.com/"))
    }

    // MARK: - Plain-string representation

    func testHTTPSStringIsAccepted() {
        XCTAssertEqual(dropped(stringBoard("https://example.com/path?q=1#frag")), url("https://example.com/path?q=1#frag"))
    }

    func testHTTPStringIsAccepted() {
        XCTAssertEqual(dropped(stringBoard("http://example.com")), url("http://example.com"))
    }

    func testSafariumStringIsAccepted() {
        XCTAssertEqual(dropped(stringBoard("safarium://history")), url("safarium://history"))
    }

    func testStringIsTrimmedOfSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(dropped(stringBoard("  https://example.com/trim \n\t")), url("https://example.com/trim"))
    }

    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(dropped(stringBoard("example.com")), url("https://example.com"))
    }

    func testBareDomainWithPathGetsHTTPS() {
        XCTAssertEqual(dropped(stringBoard("docs.example.org/a/b")), url("https://docs.example.org/a/b"))
    }

    func testUppercaseSchemeIsAcceptedCaseInsensitively() {
        XCTAssertNotNil(dropped(stringBoard("HTTPS://EXAMPLE.COM/")))
    }

    func testUnicodeHostIsAccepted() {
        XCTAssertNotNil(dropped(stringBoard("https://münchen.de/")))
    }

    func testJavascriptStringWithoutDotIsRejected() {
        XCTAssertNil(dropped(stringBoard("javascript:alert(1)")))
    }

    func testStringWithSpacesAndNoSchemeIsRejected() {
        XCTAssertNil(dropped(stringBoard("hello world.com")))
    }

    func testHostlessWordIsRejected() {
        XCTAssertNil(dropped(stringBoard("localhost")))
    }

    func testEmptyStringIsRejected() {
        XCTAssertNil(dropped(stringBoard("")))
    }

    func testWhitespaceOnlyStringIsRejected() {
        XCTAssertNil(dropped(stringBoard("   \n\t  ")))
    }

    func testOversizedSchemelessStringWithoutDotIsRejected() {
        XCTAssertNil(dropped(stringBoard(String(repeating: "a", count: 200_000))))
    }

    func testOversizedDottedStringDoesNotCrashAndIsHTTPS() {
        let big = String(repeating: "a.", count: 50_000) + "com"
        let result = dropped(stringBoard(big))
        XCTAssertEqual(result?.scheme, "https")
    }

    func testFTPStringIsRejectedByAllowlist() {
        XCTAssertNil(dropped(stringBoard("ftp://example.com/pub")))
    
    }

    func testSSHStringIsRejectedByAllowlist() {
        XCTAssertNil(dropped(stringBoard("ssh://git.example.com")))
    
    }

    // MARK: - Controller side of a drop

    func testDropOnWindowWithActiveTabNavigatesActiveTab() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 2, activateLast: true)
        dropWindow(wc).onDropURL?(url("https://dropped.example.com/"), false)
        XCTAssertEqual(wc.openTabCount, 2, "plain drop reuses the active tab")
        XCTAssertEqual(eng.created.last?.loadedURLs.last, url("https://dropped.example.com/"))
        XCTAssertEqual(wc.activeWebPageURLString, "https://dropped.example.com/")
    }

    func testDropWithCommandModifierOpensNewActiveTab() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 1)
        dropWindow(wc).onDropURL?(url("https://new.example.com/"), true)
        XCTAssertEqual(wc.openTabCount, 2)
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://new.example.com/")
    }

    func testDropOntoEmptyWindowCreatesFirstTab() {
        let (wc, _) = makeWindow()
        dropWindow(wc).onDropURL?(url("https://first.example.com/"), false)
        XCTAssertEqual(wc.openTabCount, 1)
        XCTAssertEqual(wc.activeWebPageURLString, "https://first.example.com/")
    }

    func testDroppedFileURLNavigatesActiveTab() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 1)
        dropWindow(wc).onDropURL?(url("file:///tmp/t8-dropped.pdf"), false)
        XCTAssertEqual(eng.created.first?.loadedURLs.last, url("file:///tmp/t8-dropped.pdf"))
        XCTAssertEqual(wc.openTabCount, 1)
    }

    func testOpenURLInActiveOrNewTabNavigatesWhenNotNewTab() {
        let (wc, eng) = makeWindow()
        _ = openTabs(wc, count: 1)
        wc.openURLInActiveOrNewTab(url("https://same.example.com/"), newTab: false)
        XCTAssertEqual(wc.openTabCount, 1)
        XCTAssertEqual(eng.created.first?.loadedURLs.last, url("https://same.example.com/"))
    }

    func testOpenURLInActiveOrNewTabCreatesTabWhenNewTabRequested() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 1)
        wc.openURLInActiveOrNewTab(url("https://other.example.com/"), newTab: true)
        XCTAssertEqual(wc.openTabCount, 2)
        XCTAssertEqual(wc.activeWebPageURLString, "https://other.example.com/")
    }

    func testOpenURLInActiveOrNewTabCreatesTabWhenNoTabExists() {
        let (wc, _) = makeWindow()
        wc.openURLInActiveOrNewTab(url("https://solo.example.com/"))
        XCTAssertEqual(wc.openTabCount, 1)
    }

    func testDropIntoPrivateWindowCreatesPrivateEngineTab() {
        let (wc, eng) = makeWindow(isPrivate: true)
        dropWindow(wc).onDropURL?(url("https://private-drop.example.com/"), true)
        XCTAssertEqual(eng.privateFlags, [true])
    }

    func testDropDoesNotCreateClosedTabHistory() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2, activateLast: true)
        dropWindow(wc).onDropURL?(url("https://replaced.example.com/"), false)
        XCTAssertFalse(wc.hasRecentlyClosedTabs)
    }

    // MARK: - Window registration

    func testSafariWindowCanBecomeKeyAndMain() {
        let win = SafariWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        win.isReleasedWhenClosed = false
        XCTAssertTrue(win.canBecomeKey)
        XCTAssertTrue(win.canBecomeMain)
        win.close()
    }
}
