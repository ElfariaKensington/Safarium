import XCTest
import AppKit
@testable import Safarium

/// `DesktopSpacePlacer.moveWindowToDesktopIfRequested` reads `SAFARIUM_DESKTOP`.
///
/// Only values that the function rejects before it touches the private SkyLight framework are exercised here:
/// a valid target (>= 2) would dlopen SkyLight and move a real window between Spaces, so that path is NOT tested.
@MainActor
final class DesktopSpacePlacerTests: T8WindowTestCase {

    private static let key = "SAFARIUM_DESKTOP"

    override func setUp() {
        super.setUp()
        unsetenv(Self.key)
    }

    override func tearDown() {
        unsetenv(Self.key)
        super.tearDown()
    }

    private func offscreenWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    /// Runs the placer with `value` and returns the window frame before and after; a rejected value must leave it untouched.
    private func place(with value: String?) -> (before: NSRect, after: NSRect, number: Int) {
        if let value { setenv(Self.key, value, 1) } else { unsetenv(Self.key) }
        let w = offscreenWindow()
        let before = w.frame
        DesktopSpacePlacer.moveWindowToDesktopIfRequested(w)
        let result = (before: before, after: w.frame, number: w.windowNumber)
        w.close()
        return result
    }

    private func assertRejected(_ value: String?, file: StaticString = #filePath, line: UInt = #line) {
        let r = place(with: value)
        XCTAssertEqual(r.before, r.after, "rejected SAFARIUM_DESKTOP must not move the window", file: file, line: line)
    }

    func testEnvironmentWriteIsVisibleToProcessInfo() {
        setenv(Self.key, "3", 1)
        XCTAssertEqual(ProcessInfo.processInfo.environment[Self.key], "3")
    }

    func testUnsetVariableIsNoop() {
        assertRejected(nil)
    }

    func testEmptyValueIsNoop() {
        assertRejected("")
    }

    func testDesktopOneIsNoop() {
        assertRejected("1")
    }

    func testZeroIsNoop() {
        assertRejected("0")
    }

    func testNegativeIsNoop() {
        assertRejected("-3")
    }

    func testNonNumericIsNoop() {
        assertRejected("desktop2")
    }

    func testFractionalValueIsRejectedByIntParsing() {
        assertRejected("2.5")
    }

    func testLeadingWhitespaceValueIsRejectedByIntParsing() {
        assertRejected(" 3")
    }

    func testRepeatedCallsWithRejectedValueAreSafe() {
        setenv(Self.key, "1", 1)
        let w = offscreenWindow()
        for _ in 0..<50 {
            DesktopSpacePlacer.moveWindowToDesktopIfRequested(w)
        }
        w.close()
        XCTAssertEqual(ProcessInfo.processInfo.environment[Self.key], "1")
    }
}
