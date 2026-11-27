import XCTest
import AppKit
@testable import Safarium

/// Unit tests for `PageMenuPopoverController.swift` and `WebsiteSettingsPopoverController.swift`.
/// Popovers are never shown (that would order a window on screen); the tests cover state, theme swapping,
/// keyboard dispatch, row callbacks, host normalisation and the settings controls' policy writes.
@MainActor
final class PopoverControllersTests: HermeticTestCase {
    private typealias PageState = PageMenuPopoverController.State
    private var savedDefaults: [String: Any] = [:]

    private final class Counter { var count = 0; var value: Double?; var flag: Bool? }

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            savedDefaults = UIDefaultsSandbox.snapshot()
            UIDefaultsSandbox.clear()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            UIDefaultsSandbox.restore(savedDefaults)
        }
        super.tearDown()
    }

    // MARK: - Page menu: state and theme

    func testPageMenuStateIsAValueType() {
        var state = PageState(domain: "example.com", zoomFactor: 1.0, isDarkAppearance: false)
        let snapshot = state
        state.zoomFactor = 1.5
        state.isDarkAppearance = true
        XCTAssertEqual(snapshot.zoomFactor, 1.0)
        XCTAssertFalse(snapshot.isDarkAppearance)
        XCTAssertEqual(state.domain, "example.com")
    }

    func testPageMenuIsNotShownAfterCreationAndCloseIsSafe() {
        let menu = PageMenuPopoverController()
        XCTAssertFalse(menu.isShown)
        menu.close()
        XCTAssertFalse(menu.isShown)
    }

    func testApplyThemeWhileHiddenRebuildsPopoverOnlyWhenAppearanceChanges() throws {
        let menu = PageMenuPopoverController()
        menu.applyTheme(isDark: true)
        let first = try XCTUnwrap(uiPrivate(menu, "popover", as: NSPopover.self))
        XCTAssertEqual(first.appearance?.name, .darkAqua)
        XCTAssertEqual(uiPrivate(menu, "lastPopoverDarkAppearance", as: Bool.self), true)

        menu.applyTheme(isDark: true)
        XCTAssertTrue(uiPrivate(menu, "popover", as: NSPopover.self) === first, "same appearance must not rebuild")

        menu.applyTheme(isDark: false)
        let second = try XCTUnwrap(uiPrivate(menu, "popover", as: NSPopover.self))
        XCTAssertFalse(second === first)
        XCTAssertEqual(second.appearance?.name, .aqua)
        XCTAssertEqual(uiPrivate(menu, "lastPopoverDarkAppearance", as: Bool.self), false)
    }

    // MARK: - Page menu: content rows

    private func makeContent(zoom: Double = 1.0) -> PageMenuContentViewController {
        let vc = PageMenuContentViewController()
        _ = vc.view
        vc.apply(state: PageState(domain: "example.com", zoomFactor: zoom, isDarkAppearance: false))
        return vc
    }

    private func trailingText(_ vc: PageMenuContentViewController) -> String? {
        uiPrivate(vc.zoomRow, "trailingLabel", as: NSTextField.self)?.stringValue
    }

    func testRowTitlesAreZoomFindReloadSettingsInOrder() {
        let vc = makeContent()
        let titles = vc.allRows.compactMap { uiPrivate($0, "titleLabel", as: NSTextField.self)?.stringValue }
        XCTAssertEqual(titles, ["Zoom", "Find on Page…", "Reload Page", "Website Settings…"])
    }

    func testZoomRowShowsRoundedPercentage() {
        XCTAssertEqual(trailingText(makeContent(zoom: 1.0)), "100%")
        XCTAssertEqual(trailingText(makeContent(zoom: 0.85)), "85%")
        XCTAssertEqual(trailingText(makeContent(zoom: 1.15)), "115%")
        XCTAssertEqual(trailingText(makeContent(zoom: 2.5)), "250%")
        XCTAssertEqual(trailingText(makeContent(zoom: 0.333)), "33%")
        XCTAssertEqual(trailingText(makeContent(zoom: 0.5)), "50%")
    }

    func testApplyStateUpdatesZoomLabelOnEveryCall() {
        let vc = makeContent(zoom: 1.0)
        vc.apply(state: PageState(domain: "example.com", zoomFactor: 1.75, isDarkAppearance: true))
        XCTAssertEqual(trailingText(vc), "175%")
        XCTAssertEqual(uiPrivate(vc, "currentZoomFactor", as: Double.self), 1.75)
    }

    func testResetKeyboardSelectionClearsIndexAndHighlight() {
        let vc = makeContent()
        vc.moveSelection(by: 1)
        vc.moveSelection(by: 1)
        XCTAssertEqual(vc.selectedRowIndex, 1)
        vc.resetKeyboardSelection()
        XCTAssertEqual(vc.selectedRowIndex, -1)
        XCTAssertTrue(vc.allRows.allSatisfy { uiPrivate($0, "isKeyboardSelected", as: Bool.self) == false })
    }

    func testMoveSelectionStartsAtTopOrBottomAndWrapsAround() {
        let down = makeContent()
        down.moveSelection(by: 1)
        XCTAssertEqual(down.selectedRowIndex, 0, "first Down selects the first row")
        down.moveSelection(by: 1)
        down.moveSelection(by: 1)
        down.moveSelection(by: 1)
        down.moveSelection(by: 1)
        XCTAssertEqual(down.selectedRowIndex, 0, "Down past the last row wraps to the first")

        let up = makeContent()
        up.moveSelection(by: -1)
        XCTAssertEqual(up.selectedRowIndex, 3, "first Up selects the last row")
        up.moveSelection(by: -1)
        XCTAssertEqual(up.selectedRowIndex, 2)
    }

    func testOnlyTheSelectedRowIsHighlighted() {
        let vc = makeContent()
        vc.moveSelection(by: 1)
        vc.moveSelection(by: 1)
        let flags = vc.allRows.map { uiPrivate($0, "isKeyboardSelected", as: Bool.self) ?? false }
        XCTAssertEqual(flags, [false, true, false, false])
    }

    func testActivatingWithoutSelectionDoesNothing() {
        let vc = makeContent()
        let counter = Counter()
        vc.onFindOnPage = { counter.count += 1 }
        vc.onReloadPage = { counter.count += 10 }
        vc.onWebsiteSettings = { counter.count += 100 }
        vc.activateSelectedRow()
        XCTAssertEqual(counter.count, 0)
    }

    func testActivatingSelectedRowsTriggersTheirActions() {
        let vc = makeContent()
        let counter = Counter()
        vc.onFindOnPage = { counter.count += 1 }
        vc.onReloadPage = { counter.count += 10 }
        vc.onWebsiteSettings = { counter.count += 100 }

        vc.moveSelection(by: 1); vc.moveSelection(by: 1)     // Find on Page
        vc.activateSelectedRow()
        XCTAssertEqual(counter.count, 1)

        vc.moveSelection(by: 1)                              // Reload Page
        vc.activateSelectedRow()
        XCTAssertEqual(counter.count, 11)

        vc.moveSelection(by: 1)                              // Website Settings
        vc.activateSelectedRow()
        XCTAssertEqual(counter.count, 111)
    }

    func testTriggeringRowClickRunsItsHandlerOnce() {
        let vc = makeContent()
        let counter = Counter()
        vc.onReloadPage = { counter.count += 1 }
        vc.reloadRow.triggerClick()
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - Page menu: keyboard dispatch

    func testKeyRootDispatchesArrowsReturnSpaceEscape() throws {
        let vc = makeContent()
        let root = try XCTUnwrap(vc.view as? PageMenuKeyRootView)
        let counter = Counter()
        vc.onFindOnPage = { counter.count += 1 }
        var dismissed = 0
        vc.onDismiss = { dismissed += 1 }

        root.keyDown(with: uiKeyEvent(125))           // Down
        XCTAssertEqual(vc.selectedRowIndex, 0)
        root.keyDown(with: uiKeyEvent(126))           // Up wraps back to the bottom
        XCTAssertEqual(vc.selectedRowIndex, 3)
        root.keyDown(with: uiKeyEvent(126))
        XCTAssertEqual(vc.selectedRowIndex, 2)
        root.keyDown(with: uiKeyEvent(126))          // now on Find on Page
        XCTAssertEqual(vc.selectedRowIndex, 1)

        for keyCode: UInt16 in [36, 76, 49] {         // Return, Enter, Space
            root.keyDown(with: uiKeyEvent(keyCode))
        }
        XCTAssertEqual(counter.count, 3)
        XCTAssertEqual(dismissed, 0)

        root.keyDown(with: uiKeyEvent(53))            // Escape
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(counter.count, 3)
    }

    func testUnmappedKeyDoesNotTriggerAnyHandler() throws {
        let vc = makeContent()
        let root = try XCTUnwrap(vc.view as? PageMenuKeyRootView)
        var fired = 0
        vc.onDismiss = { fired += 1 }
        vc.onFindOnPage = { fired += 1 }
        root.keyDown(with: uiKeyEvent(0))            // "a"
        XCTAssertEqual(vc.selectedRowIndex, -1)
        XCTAssertEqual(fired, 0)
    }

    // MARK: - Website settings: host normalisation and presentation guards

    func testNormalizedHostLowercasesAndDropsExactlyOneWww() {
        typealias Web = WebsiteSettingsPopoverController
        XCTAssertEqual(Web.normalizedHost("WWW.Example.COM"), "example.com")
        XCTAssertEqual(Web.normalizedHost("www.www.example.com"), "www.example.com")
        XCTAssertEqual(Web.normalizedHost("example.com"), "example.com")
        XCTAssertEqual(Web.normalizedHost("wwwexample.com"), "wwwexample.com", "no dot means no www prefix")
        XCTAssertEqual(Web.normalizedHost("www."), "")
        XCTAssertEqual(Web.normalizedHost(""), "")
        XCTAssertEqual(Web.normalizedHost("Sub.Www.Example.org"), "sub.www.example.org")
    }

    func testShowForEmptyHostDoesNotPresent() {
        let popover = WebsiteSettingsPopoverController()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        popover.show(forHost: "www.", relativeTo: anchor)
        XCTAssertFalse(popover.isShown)
        XCTAssertNil(uiPrivate(popover, "popover", as: NSPopover.self))
        popover.show(forHost: "", relativeTo: anchor)
        XCTAssertFalse(popover.isShown)
    }

    func testPopoverDidCloseClearsTheReference() {
        let popover = WebsiteSettingsPopoverController()
        popover.popoverDidClose(Notification(name: Notification.Name("test.close")))
        XCTAssertFalse(popover.isShown)
        popover.close()
    }

    // MARK: - Website settings: content

    private func makeWebsiteContent(host: String = "example.com") -> WebsiteSettingsPopoverViewController {
        let vc = WebsiteSettingsPopoverViewController(host: host)
        _ = vc.view
        return vc
    }

    private func popup(in view: NSView, firstItem: String) -> NSPopUpButton? {
        uiDescendants(of: view, as: NSPopUpButton.self).first { $0.itemTitle(at: 0) == firstItem }
    }

    private func checkbox(in view: NSView, titled title: String) -> NSButton? {
        uiDescendants(of: view, as: NSButton.self).first { $0.title == title }
    }

    func testHeaderNamesTheVisitedHost() {
        let vc = makeWebsiteContent(host: "news.example.org")
        XCTAssertTrue(uiAllStrings(in: vc.view).contains("When visiting news.example.org:"))
    }

    func testZoomOptionsMatchTheirPercentLabels() {
        XCTAssertEqual(WebsiteSettingsPopoverViewController.zoomOptions.first, "50%")
        XCTAssertEqual(WebsiteSettingsPopoverViewController.zoomOptions[3], "100%")
        XCTAssertEqual(WebsiteSettingsPopoverViewController.zoomOptions[8], "200%")
    }

    func testDefaultControlStatesFollowPolicyDefaults() throws {
        let vc = makeWebsiteContent()
        let blockers = try XCTUnwrap(checkbox(in: vc.view, titled: "Enable content blockers"))
        XCTAssertEqual(blockers.state, .on, "content blockers default on")
        let reader = try XCTUnwrap(checkbox(in: vc.view, titled: "Use Reader when available"))
        XCTAssertEqual(reader.state, .off)
        let zoom = try XCTUnwrap(popup(in: vc.view, firstItem: "50%"))
        XCTAssertEqual(zoom.indexOfSelectedItem, 3, "page zoom defaults to 100%")
        let autoPlay = try XCTUnwrap(popup(in: vc.view, firstItem: "Allow All Auto-Play"))
        XCTAssertEqual(autoPlay.indexOfSelectedItem, 1)
        let camera = try XCTUnwrap(popup(in: vc.view, firstItem: "Ask"))
        XCTAssertEqual(camera.indexOfSelectedItem, 0)
    }

    func testStoredHostPolicyIsReflectedInTheControls() throws {
        BrowserSettings.shared.setWebsitePolicy(category: "Page Zoom", host: "example.com", index: 5)
        BrowserSettings.shared.setWebsitePolicy(category: "Content Blockers", host: "example.com", index: 1)
        let vc = makeWebsiteContent()
        XCTAssertEqual(try XCTUnwrap(popup(in: vc.view, firstItem: "50%")).indexOfSelectedItem, 5)
        XCTAssertEqual(try XCTUnwrap(checkbox(in: vc.view, titled: "Enable content blockers")).state, .off, "index 1 means off")
        XCTAssertFalse(BrowserSettings.shared.isContentBlockersEnabled(forHost: "example.com"))
    }

    func testChangingZoomPopupWritesPolicyAndReportsEngineZoom() throws {
        let vc = makeWebsiteContent()
        let counter = Counter()
        vc.onPageZoomChanged = { counter.value = $0 }
        let zoom = try XCTUnwrap(popup(in: vc.view, firstItem: "50%"))
        zoom.selectItem(at: 5)
        _ = zoom.sendAction(zoom.action, to: zoom.target)
        XCTAssertEqual(counter.value, 1.25)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: "Page Zoom", host: "example.com", defaultIndex: 3), 5)
        XCTAssertEqual(BrowserSettings.shared.pageZoomFactor(for: URL(string: "https://www.example.com/a")), 1.25)
    }

    func testPageZoomPopupCoversEveryEngineZoomLevel() throws {
        let vc = makeWebsiteContent()
        let zoom = try XCTUnwrap(popup(in: vc.view, firstItem: "50%"))
        var reported: [Double] = []
        vc.onPageZoomChanged = { reported.append($0) }
        for index in 0..<BrowserSettings.pageZoomValues.count {
            zoom.selectItem(at: index)
            _ = zoom.sendAction(zoom.action, to: zoom.target)
        }
        XCTAssertEqual(reported, BrowserSettings.pageZoomValues)
    }

    /// BUG POP-1: the popup lists 250% and 300%, but `BrowserSettings.pageZoomValues` has only nine entries,
    /// so those choices are clamped and the page is zoomed to 200% while the policy stores index 9 or 10.
    func testZoomOptionsWithoutEngineLevelsAreRejectedOrMapped() throws {
        XCTAssertEqual(WebsiteSettingsPopoverViewController.zoomOptions.count, BrowserSettings.pageZoomValues.count)
        let vc = makeWebsiteContent()
        let zoom = try XCTUnwrap(popup(in: vc.view, firstItem: "50%"))
        var reported: Double?
        vc.onPageZoomChanged = { reported = $0 }
        zoom.selectItem(at: 9)
        _ = zoom.sendAction(zoom.action, to: zoom.target)
        XCTAssertEqual(reported, 2.5, "choosing 250% must zoom to 250%")
    
    }

    func testAutoPlayPopupWritesItsIndex() throws {
        let vc = makeWebsiteContent()
        let autoPlay = try XCTUnwrap(popup(in: vc.view, firstItem: "Allow All Auto-Play"))
        autoPlay.selectItem(at: 2)
        _ = autoPlay.sendAction(autoPlay.action, to: autoPlay.target)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: "Auto-Play", host: "example.com", defaultIndex: 1), 2)
    }

    func testPermissionPopupWritesIndexForItsCategory() throws {
        let vc = makeWebsiteContent()
        let camera = try XCTUnwrap(popup(in: vc.view, firstItem: "Ask"))
        camera.selectItem(at: 1)
        _ = camera.sendAction(camera.action, to: camera.target)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: "Camera", host: "example.com", defaultIndex: 0), 1)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: "Microphone", host: "example.com", defaultIndex: 0), 0,
                       "other categories are untouched")
    }

    func testAdaptiveDarkModeCheckboxTogglesPolicyAndNotifies() throws {
        let vc = makeWebsiteContent()
        let counter = Counter()
        vc.onAdaptiveDarkModeChanged = { counter.flag = $0 }
        let box = try XCTUnwrap(checkbox(in: vc.view, titled: "Adaptive Dark Mode"))
        box.performClick(nil)
        XCTAssertEqual(counter.flag, true)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: "Adaptive Dark Mode", host: "example.com", defaultIndex: 0), 1)
        box.performClick(nil)
        XCTAssertEqual(counter.flag, false)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: "Adaptive Dark Mode", host: "example.com", defaultIndex: 0), 0)
    }

    func testReaderAndContentBlockerCheckboxesNotifyTheirOwnCallbacks() throws {
        let vc = makeWebsiteContent()
        let reader = Counter(), blockers = Counter()
        vc.onReaderModeChanged = { reader.flag = $0 }
        vc.onContentBlockersChanged = { blockers.flag = $0 }

        try XCTUnwrap(checkbox(in: vc.view, titled: "Use Reader when available")).performClick(nil)
        XCTAssertEqual(reader.flag, true)
        XCTAssertNil(blockers.flag)

        try XCTUnwrap(checkbox(in: vc.view, titled: "Enable content blockers")).performClick(nil)
        XCTAssertEqual(blockers.flag, false, "content blockers start on, so one click turns them off")
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: "Content Blockers", host: "example.com", defaultIndex: 0), 1)
        XCTAssertFalse(BrowserSettings.shared.isContentBlockersEnabled(forHost: "example.com"))
    }

    func testContentBlockersParityWithWebsiteCategoryZeroOnOneOffConvention() throws {
        let cat = SafariSettingsWindowController.WebsiteCategory.contentBlockers
        XCTAssertEqual(cat.options, ["On", "Off"])
        XCTAssertEqual(cat.defaultOptionIndex, 0)

        let vc = makeWebsiteContent(host: "parity.example")
        let box = try XCTUnwrap(checkbox(in: vc.view, titled: "Enable content blockers"))
        XCTAssertEqual(box.state, .on)
        XCTAssertTrue(BrowserSettings.shared.isContentBlockersEnabled(forHost: "parity.example"))

        box.performClick(nil)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: cat.rawValue, host: "parity.example", defaultIndex: cat.defaultOptionIndex), 1)
        XCTAssertFalse(BrowserSettings.shared.isContentBlockersEnabled(forHost: "parity.example"))

        box.performClick(nil)
        XCTAssertEqual(BrowserSettings.shared.websitePolicyIndex(category: cat.rawValue, host: "parity.example", defaultIndex: cat.defaultOptionIndex), 0)
        XCTAssertTrue(BrowserSettings.shared.isContentBlockersEnabled(forHost: "parity.example"))
    }

    func testPopupRowsStackBelowTheHeaderWithinTheDeclaredWidth() {
        let vc = makeWebsiteContent()
        XCTAssertEqual(vc.preferredContentSize.width, 336)
        XCTAssertGreaterThan(vc.preferredContentSize.height, 300)
        for control in uiDescendants(of: vc.view, as: NSControl.self) {
            XCTAssertLessThanOrEqual(control.frame.maxX, 336 + 0.5, "\(control.frame)")
        }
    }
}
