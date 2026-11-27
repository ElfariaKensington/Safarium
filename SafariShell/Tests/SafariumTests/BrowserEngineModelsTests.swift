import XCTest
import AppKit
@testable import Safarium

/// Covers the value types and protocol-extension defaults in `Engine/BrowserEngine.swift`.
/// Defaults are exercised through `MockBrowserTab` / `MockBrowserEngine`, which do not override them.
@MainActor
final class BrowserEngineModelsTests: HermeticTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: tol, file: file, line: line)
    }

    private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    // MARK: - TopEdgeColorSample luminance

    func testLuminanceOfBlackIsZero() {
        approx(TopEdgeColorSample.computeRelativeLuminance(for: .black), 0)
    }

    func testLuminanceOfWhiteIsOne() {
        approx(TopEdgeColorSample.computeRelativeLuminance(for: srgb(1, 1, 1)), 1)
    }

    func testLuminanceOfPureChannelsUsesWCAGWeights() {
        approx(TopEdgeColorSample.computeRelativeLuminance(for: srgb(1, 0, 0)), 0.2126)
        approx(TopEdgeColorSample.computeRelativeLuminance(for: srgb(0, 1, 0)), 0.7152)
        approx(TopEdgeColorSample.computeRelativeLuminance(for: srgb(0, 0, 1)), 0.0722)
    }

    func testLuminanceOfMidGrayUsesGammaCurve() {
        // sRGB 0.5 linearises to ((0.5 + 0.055) / 1.055)^2.4 = 0.214041...
        approx(TopEdgeColorSample.computeRelativeLuminance(for: srgb(0.5, 0.5, 0.5)), 0.214041, 1e-5)
    }

    func testLuminanceUsesLinearSegmentNearBlack() {
        // 0.03 is at/below the 0.04045 knee, so it is divided by 12.92.
        approx(TopEdgeColorSample.computeRelativeLuminance(for: srgb(0.03, 0.03, 0.03)), 0.03 / 12.92, 1e-6)
    }

    func testLuminanceClampsOutOfRangeChannels() {
        // r clamps to 1, g clamps to 0, b stays 0.5 -> 0.2126 + 0.0722 * 0.214041
        approx(TopEdgeColorSample.computeRelativeLuminance(for: srgb(1.5, -0.2, 0.5)), 0.2126 + 0.0722 * 0.214041, 1e-4)
    }

    func testLuminanceOfGrayscaleColorIsConvertedToSRGB() {
        let gray = NSColor(white: 1.0, alpha: 1.0)
        approx(TopEdgeColorSample.computeRelativeLuminance(for: gray), 1.0, 1e-3)
    }

    // MARK: - TopEdgeColorSample init

    func testInitComputesLuminanceWhenNotProvided() {
        let sample = TopEdgeColorSample(color: srgb(1, 0, 0))
        approx(sample.relativeLuminance, 0.2126)
        approx(sample.color.redComponent, 1)
    }

    func testInitHonorsExplicitLuminance() {
        let sample = TopEdgeColorSample(color: .white, relativeLuminance: 0.33)
        approx(sample.relativeLuminance, 0.33)
    }

    func testInitHonorsExplicitZeroLuminance() {
        let sample = TopEdgeColorSample(color: .white, relativeLuminance: 0)
        approx(sample.relativeLuminance, 0)
    }

    func testInitStoresSRGBColor() {
        let sample = TopEdgeColorSample(color: NSColor.systemBlue)
        XCTAssertNotNil(sample.color.usingColorSpace(.sRGB))
        XCTAssertEqual(sample.color.colorSpace.colorSpaceModel, .rgb)
    }

    func testEqualityComparesColorAndLuminance() {
        let a = TopEdgeColorSample(color: srgb(1, 0, 0), relativeLuminance: 0.5)
        let b = TopEdgeColorSample(color: srgb(1, 0, 0), relativeLuminance: 0.5)
        let c = TopEdgeColorSample(color: srgb(1, 0, 0), relativeLuminance: 0.6)
        let d = TopEdgeColorSample(color: srgb(0, 1, 0), relativeLuminance: 0.5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    // MARK: - BrowserDownloadItem

    func testDownloadItemStoresAllFields() {
        let url = URL(string: "https://files.example/a.zip")
        let item = BrowserDownloadItem(id: 42, suggestedFileName: "a.zip", fullPath: "/Users/me/Downloads/a.zip",
                                       url: url, totalBytes: 2_000, receivedBytes: 500, percentComplete: 25,
                                       isInProgress: true, isComplete: false, isCanceled: false)
        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.suggestedFileName, "a.zip")
        XCTAssertEqual(item.fullPath, "/Users/me/Downloads/a.zip")
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.totalBytes, 2_000)
        XCTAssertEqual(item.receivedBytes, 500)
        XCTAssertEqual(item.percentComplete, 25)
        XCTAssertTrue(item.isInProgress)
        XCTAssertFalse(item.isComplete)
        XCTAssertFalse(item.isCanceled)
        XCTAssertFalse(item.isPaused, "isPaused defaults to false")
    }

    func testDownloadItemPausedFlagAndNilOptionals() {
        let item = BrowserDownloadItem(id: 1, suggestedFileName: "", fullPath: nil, url: nil,
                                       totalBytes: -1, receivedBytes: 0, percentComplete: 0,
                                       isInProgress: true, isComplete: false, isCanceled: false, isPaused: true)
        XCTAssertTrue(item.isPaused)
        XCTAssertNil(item.fullPath)
        XCTAssertNil(item.url)
        XCTAssertEqual(item.totalBytes, -1, "unknown size is passed through unchanged")
    }

    func testDownloadItemCompleteAndCanceledStates() {
        let done = BrowserDownloadItem(id: 2, suggestedFileName: "x", fullPath: nil, url: nil, totalBytes: 10,
                                       receivedBytes: 10, percentComplete: 100, isInProgress: false, isComplete: true, isCanceled: false)
        XCTAssertTrue(done.isComplete)
        XCTAssertFalse(done.isInProgress)
        let canceled = BrowserDownloadItem(id: 3, suggestedFileName: "x", fullPath: nil, url: nil, totalBytes: 10,
                                           receivedBytes: 1, percentComplete: 10, isInProgress: false, isComplete: false, isCanceled: true)
        XCTAssertTrue(canceled.isCanceled)
        XCTAssertFalse(canceled.isComplete)
    }

    func testDownloadItemIdentifiableUsesID() {
        let item = BrowserDownloadItem(id: UInt32.max, suggestedFileName: "", fullPath: nil, url: nil, totalBytes: 0,
                                       receivedBytes: 0, percentComplete: 0, isInProgress: false, isComplete: false, isCanceled: false)
        XCTAssertEqual(item.id, UInt32.max)
    }

    // MARK: - BrowserExtensionContextMenuItem

    private func menu(id: String = "m1", title: String = "Open", checked: Bool = false,
                      children: [BrowserExtensionContextMenuItem] = []) -> BrowserExtensionContextMenuItem {
        BrowserExtensionContextMenuItem(id: id, parentID: nil, title: title, isSeparator: false,
                                        isEnabled: true, isChecked: checked, children: children)
    }

    func testContextMenuItemEqualityIsSynthesized() {
        XCTAssertEqual(menu(), menu())
        XCTAssertNotEqual(menu(), menu(id: "m2"))
        XCTAssertNotEqual(menu(), menu(title: "Close"))
        XCTAssertNotEqual(menu(), menu(checked: true))
    }

    func testContextMenuItemNestedChildrenAffectEquality() {
        let child = menu(id: "c1", title: "Child")
        XCTAssertEqual(menu(children: [child]), menu(children: [child]))
        XCTAssertNotEqual(menu(children: [child]), menu(children: []))
        XCTAssertNotEqual(menu(children: [child]), menu(children: [menu(id: "c1", title: "Other")]))
    }

    func testContextMenuSeparatorAndDisabledFlagsParticipateInEquality() {
        let a = BrowserExtensionContextMenuItem(id: "s", parentID: "p", title: "", isSeparator: true,
                                                isEnabled: true, isChecked: false, children: [])
        let b = BrowserExtensionContextMenuItem(id: "s", parentID: "p", title: "", isSeparator: false,
                                                isEnabled: true, isChecked: false, children: [])
        let c = BrowserExtensionContextMenuItem(id: "s", parentID: "p", title: "", isSeparator: true,
                                                isEnabled: false, isChecked: false, children: [])
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, BrowserExtensionContextMenuItem(id: "s", parentID: nil, title: "", isSeparator: true,
                                                             isEnabled: true, isChecked: false, children: []))
    }

    // MARK: - BrowserExtensionItem

    private func makeExtension(icon: NSImage? = nil, badge: String? = "3", badgeColor: NSColor? = nil,
                               enabled: Bool = true, allowInPrivate: Bool = false,
                               name: String = "Ad Blocker", version: String = "1.0",
                               storeID: String? = "abc", installPath: String = "/ext/a",
                               description: String? = "Blocks ads", popup: URL? = URL(string: "chrome-extension://id/popup.html"),
                               id: String = "ext-1") -> BrowserExtensionItem {
        BrowserExtensionItem(id: id, storeID: storeID, name: name, version: version, extensionDescription: description,
                             installPath: installPath, icon: icon, badgeText: badge, badgeColor: badgeColor,
                             popupURL: popup, enabled: enabled, allowInPrivate: allowInPrivate)
    }

    func testExtensionInitDefaults() {
        let item = BrowserExtensionItem(id: "e", name: "N", version: "1", icon: nil, badgeText: nil,
                                        badgeColor: nil, popupURL: nil, enabled: false)
        XCTAssertNil(item.storeID)
        XCTAssertNil(item.extensionDescription)
        XCTAssertEqual(item.installPath, "")
        XCTAssertFalse(item.allowInPrivate)
        XCTAssertFalse(item.enabled)
        XCTAssertNil(item.icon)
    }

    func testExtensionInitStoresFields() {
        let item = makeExtension(badge: "9+", enabled: false, allowInPrivate: true)
        XCTAssertEqual(item.id, "ext-1")
        XCTAssertEqual(item.storeID, "abc")
        XCTAssertEqual(item.name, "Ad Blocker")
        XCTAssertEqual(item.version, "1.0")
        XCTAssertEqual(item.extensionDescription, "Blocks ads")
        XCTAssertEqual(item.installPath, "/ext/a")
        XCTAssertEqual(item.badgeText, "9+")
        XCTAssertEqual(item.popupURL?.absoluteString, "chrome-extension://id/popup.html")
        XCTAssertFalse(item.enabled)
        XCTAssertTrue(item.allowInPrivate)
    }

    func testExtensionEqualityWithSameFieldsAndSameIconInstance() {
        let icon = NSImage(size: NSSize(width: 4, height: 4))
        XCTAssertEqual(makeExtension(icon: icon), makeExtension(icon: icon))
    }

    func testExtensionEqualityWithNilIcons() {
        XCTAssertEqual(makeExtension(icon: nil), makeExtension(icon: nil))
    }

    func testExtensionEqualityIsIconIdentityNotContent() {
        let a = NSImage(size: NSSize(width: 4, height: 4))
        let b = NSImage(size: NSSize(width: 4, height: 4))
        XCTAssertNotEqual(makeExtension(icon: a), makeExtension(icon: b), "same pixels, different instance must differ")
        XCTAssertNotEqual(makeExtension(icon: a), makeExtension(icon: nil))
    }

    func testExtensionEqualityDetectsEachDifferingField() {
        let base = makeExtension()
        XCTAssertNotEqual(base, makeExtension(id: "ext-2"))
        XCTAssertNotEqual(base, makeExtension(storeID: "xyz"))
        XCTAssertNotEqual(base, makeExtension(storeID: nil))
        XCTAssertNotEqual(base, makeExtension(name: "Other"))
        XCTAssertNotEqual(base, makeExtension(version: "2.0"))
        XCTAssertNotEqual(base, makeExtension(installPath: "/ext/b"))
        XCTAssertNotEqual(base, makeExtension(description: nil))
        XCTAssertNotEqual(base, makeExtension(badge: nil))
        XCTAssertNotEqual(base, makeExtension(badge: "4"))
        XCTAssertNotEqual(base, makeExtension(popup: nil))
        XCTAssertNotEqual(base, makeExtension(enabled: false))
        XCTAssertNotEqual(base, makeExtension(allowInPrivate: true))
    }

    func testExtensionEqualityComparesBadgeColorValues() {
        XCTAssertNotEqual(makeExtension(badgeColor: .red), makeExtension(badgeColor: .blue))
        XCTAssertEqual(makeExtension(badgeColor: .red), makeExtension(badgeColor: .red))
        XCTAssertNotEqual(makeExtension(badgeColor: nil), makeExtension(badgeColor: .red))
    }

    // MARK: - BrowserTabEngine protocol defaults (via MockBrowserTab)

    func testDefaultStartAndHistoryPageClassification() {
        let tab = MockBrowserTab()
        XCTAssertFalse(tab.isStartPage, "no URL yet")
        XCTAssertFalse(tab.isHistoryPage)
        tab.loadURL(URL(string: "safarium://start")!)
        XCTAssertTrue(tab.isStartPage)
        XCTAssertFalse(tab.isHistoryPage)
        XCTAssertTrue(tab.isNativeInternalPage)
        tab.loadURL(URL(string: "safarium://history")!)
        XCTAssertFalse(tab.isStartPage)
        XCTAssertTrue(tab.isHistoryPage)
        XCTAssertTrue(tab.isNativeInternalPage)
    }

    func testWebPagesAreNotNativeInternalPages() {
        let tab = MockBrowserTab()
        tab.loadURL(URL(string: "https://safarium.example/start")!)
        XCTAssertFalse(tab.isStartPage)
        XCTAssertFalse(tab.isHistoryPage)
        XCTAssertFalse(tab.isNativeInternalPage)
        tab.loadURL(URL(string: "about:blank")!)
        XCTAssertFalse(tab.isNativeInternalPage)
    }

    func testIsScrolledToTopBoundaryAtOnePoint() {
        let tab = MockBrowserTab()
        tab.loadURL(URL(string: "https://apple.com")!)
        XCTAssertTrue(tab.isScrolledToTop, "scrollY 0 is top")
        scroll(tab, to: 1.0)
        XCTAssertEqual(tab.scrollY, 1.0)
        XCTAssertTrue(tab.isScrolledToTop, "exactly 1pt still counts as top")
        scroll(tab, to: 1.5)
        XCTAssertFalse(tab.isScrolledToTop)
        scroll(tab, to: 300)
        XCTAssertFalse(tab.isScrolledToTop)
        scroll(tab, to: 0)
        XCTAssertTrue(tab.isScrolledToTop)
    }

    private func scroll(_ tab: MockBrowserTab, to y: CGFloat) {
        guard let sv = tab.contentView.subviews.compactMap({ $0 as? NSScrollView }).first else {
            return XCTFail("mock tab has no scroll view")
        }
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    func testDefaultViewportAndZoomAndLayers() {
        let tab = MockBrowserTab()
        XCTAssertEqual(tab.viewportHeight, 760, "mock content view is 1000x760")
        XCTAssertFalse(tab.canInnerScrollUp)
        XCTAssertFalse(tab.canInnerScrollDown)
        XCTAssertEqual(tab.pageZoomFactor, 1.0)
        XCTAssertNil(tab.cachedSnapshot)
        XCTAssertNil(tab.fixedHeaderColor)
        XCTAssertFalse(tab.isAudioMuted)
    }

    func testSetTabActiveTogglesContentVisibility() {
        let tab = MockBrowserTab()
        tab.setTabActive(false)
        XCTAssertTrue(tab.contentView.isHidden)
        tab.setTabActive(true)
        XCTAssertFalse(tab.contentView.isHidden)
    }

    func testApplyPinchMagnificationReturnsCurrentPageScale() {
        let tab = MockBrowserTab()
        XCTAssertEqual(tab.applyPinchMagnification(0.5, atPoint: .zero, isPinching: true), 1.0)
        XCTAssertEqual(tab.pageScale, 1.0, "default implementation does not change scale")
    }

    func testAttachAddsContentViewOnceAndDetachRemovesIt() {
        let tab = MockBrowserTab()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        tab.attach(to: parent)
        XCTAssertTrue(tab.contentView.superview === parent)
        tab.attach(to: parent)
        XCTAssertEqual(parent.subviews.filter { $0 === tab.contentView }.count, 1)
        tab.detachFromParentView()
        XCTAssertNil(tab.contentView.superview)
    }

    func testAttachToDifferentParentMovesContentView() {
        let tab = MockBrowserTab()
        let first = NSView(frame: .zero)
        let second = NSView(frame: .zero)
        tab.attach(to: first)
        tab.attach(to: second)
        XCTAssertTrue(tab.contentView.superview === second)
        XCTAssertFalse(first.subviews.contains { $0 === tab.contentView })
    }

    func testCaptureSnapshotProducesImageOfContentSize() {
        let tab = MockBrowserTab()
        tab.loadURL(URL(string: "https://apple.com")!)
        let exp = expectation(description: "snapshot")
        var image: NSImage?
        tab.captureSnapshot { img in
            image = img
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size, NSSize(width: 1000, height: 760))
    }

    func testDefaultNoOpsDoNotCrashAndReportFailure() {
        let tab = MockBrowserTab()
        tab.findText("needle", forward: true, matchCase: false, findNext: false)
        tab.stopFinding(clearSelection: true)
        tab.showDevTools()
        tab.executeJavaScript("1+1")
        tab.executeJavaScriptInAllFrames("1+1")
        tab.printPage()
        tab.setAudioMuted(true)
        tab.setPageZoomFactor(2.0)
        tab.resetPageScale()
        tab.setPageOvershootScale(1.2)
        tab.endPageOvershoot()
        tab.resetOverscroll()
        tab.startDownload(at: URL(string: "https://example.com/a.pdf")!)
        tab.setPreviewSnapshotPaused(true)
        tab.focusWebContent()
        let exp = expectation(description: "pdf")
        tab.exportToPDF(atPath: "/tmp/ignored.pdf") { ok in
            XCTAssertFalse(ok)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testReloadIgnoringCacheRepeatsCurrentNavigation() {
        let tab = MockBrowserTab()
        tab.loadURL(URL(string: "https://stripe.com")!)
        tab.reloadIgnoringCache()
        XCTAssertEqual(tab.currentURL?.absoluteString, "https://stripe.com")
        XCTAssertFalse(tab.canGoBack, "reload does not add a history entry")
    }

    // MARK: - BrowserEngine protocol defaults (via MockBrowserEngine)

    func testEngineDefaultsForExtensionsAndDownloads() {
        let engine = MockBrowserEngine()
        XCTAssertTrue(engine.installedExtensions().isEmpty)
        XCTAssertFalse(engine.loadUnpackedExtension(atPath: "/x"))
        XCTAssertFalse(engine.installExtensionFromCRX(atPath: "/x.crx"))
        XCTAssertFalse(engine.uninstallExtension(withID: "id"))
        XCTAssertFalse(engine.resumeDownload(id: 1))
        XCTAssertNil(engine.onExtensionsDidUpdate)
        XCTAssertTrue(engine.extensionContextMenuItems(forExtensionID: "id").isEmpty)
        XCTAssertNil(engine.createExtensionPopupView(forExtensionID: "id", width: 100, height: 100, parentView: NSView()))
        engine.cancelDownload(id: 1)
        engine.pauseDownload(id: 1)
        engine.closeExtensionPopupView(forExtensionID: "id")
        engine.triggerExtensionContextMenuItem(itemID: "i", forExtensionID: "id", pageURL: nil)
        engine.applySettings(["a": 1])
        engine.resetPrivateSession()
    }

    func testEngineDefaultCompletionsReportFailure() {
        let engine = MockBrowserEngine()
        let loadExp = expectation(description: "load")
        engine.loadUnpackedExtension(atPath: "/x") { ok in
            XCTAssertFalse(ok)
            loadExp.fulfill()
        }
        let crxExp = expectation(description: "crx")
        engine.installExtensionFromCRX(atPath: "/x.crx") { ok, message in
            XCTAssertFalse(ok)
            XCTAssertEqual(message, "Extensions are unavailable.")
            crxExp.fulfill()
        }
        let storeExp = expectation(description: "store")
        engine.installExtensionFromChromeWebStoreID("abcdef") { ok in
            XCTAssertFalse(ok)
            storeExp.fulfill()
        }
        let enableExp = expectation(description: "enable")
        engine.setExtensionEnabled(true, forID: "id") { ok in
            XCTAssertFalse(ok)
            enableExp.fulfill()
        }
        let privateExp = expectation(description: "private")
        engine.setExtensionAllowInPrivate(true, forID: "id") { ok in
            XCTAssertFalse(ok)
            privateExp.fulfill()
        }
        let storageExp = expectation(description: "storage")
        engine.clearExtensionStorage(forID: "id") { ok in
            XCTAssertFalse(ok)
            storageExp.fulfill()
        }
        let wipeExp = expectation(description: "wipe")
        engine.clearWebsiteData { ok in
            XCTAssertTrue(ok, "clearing nothing succeeds by default")
            wipeExp.fulfill()
        }
        wait(for: [loadExp, crxExp, storeExp, enableExp, privateExp, storageExp, wipeExp], timeout: 1)
    }

    func testCreateTabOverloadsForwardParameters() {
        let engine = MockBrowserEngine()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let tab = engine.createTab(initialURL: URL(string: "https://apple.com")!, parentView: parent) as? MockBrowserTab
        XCTAssertNotNil(tab)
        XCTAssertTrue(tab?.contentView.superview === parent, "parentView overload attaches the tab")
        XCTAssertEqual(tab?.currentURL?.absoluteString, "https://apple.com")

        let plain = engine.createTab(initialURL: URL(string: "https://youtube.com")!) as? MockBrowserTab
        XCTAssertNil(plain?.contentView.superview, "no parent means no attachment")
        XCTAssertEqual(plain?.currentURL?.absoluteString, "https://youtube.com")
    }

    func testEngineIdentityProperties() {
        let engine = MockBrowserEngine()
        XCTAssertFalse(engine.isRealChromium)
        XCTAssertTrue(engine.engineName.hasPrefix("MockBrowserEngine"))
        XCTAssertNoThrow(try engine.start())
        engine.shutdown()
    }

    func testCreateTabWithoutInitialURLLoadsGemini() {
        let tab = MockBrowserEngine().createTab(initialURL: nil, parentView: nil, isPrivate: false) as? MockBrowserTab
        XCTAssertEqual(tab?.currentURL?.absoluteString, "https://gemini.google.com")
        XCTAssertEqual(tab?.title, "Gemini")
    }

    func testCreatedTabsHaveUniqueIdentifiers() {
        let engine = MockBrowserEngine()
        let a = engine.createTab(initialURL: nil, parentView: nil, isPrivate: false)
        let b = engine.createTab(initialURL: nil, parentView: nil, isPrivate: false)
        XCTAssertNotEqual(a.tabID, b.tabID)
        XCTAssertFalse(a.tabID.isEmpty)
    }
}
