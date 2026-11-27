import XCTest
import AppKit
import IOSurface
@testable import Safarium

/// Regression suite locking down production bug fixes:
/// 1. Command+S Save Page action & zero download animation triggered
/// 2. Closing & opening a new tab then Command+1..9 switching tabs reliably
/// 3. Download animation NOT starting when Save dialog opens or cancels, starting only on confirmed download
/// 4. Single-tab single-window drag & drop fast path / frame budget / invariants
/// 5. Extension popover dismissal on navigation / shortcut / focus change & private-mode filtering
/// 6. Zero AutoLayout constraint breaks on window layout
@MainActor
final class ProductionRegressionTests: T8WindowTestCase {

    private var savedCmdNumberPref: Any?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            savedCmdNumberPref = UserDefaults.standard.object(forKey: BrowserSettings.Key.cmdNumberSwitch)
            UserDefaults.standard.removeObject(forKey: BrowserSettings.Key.cmdNumberSwitch)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let savedCmdNumberPref {
                UserDefaults.standard.set(savedCmdNumberPref, forKey: BrowserSettings.Key.cmdNumberSwitch)
            } else {
                UserDefaults.standard.removeObject(forKey: BrowserSettings.Key.cmdNumberSwitch)
            }
        }
        super.tearDown()
    }

    private func makeKeyEquivalentEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [.command],
        window: NSWindow? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: - 1. Command+S Save Page & Zero Download Animation

    func testCmdSSaveActiveTabDisabledOnInternalAndErrorPages() {
        let (wc, eng) = makeWindow()
        XCTAssertFalse(wc.canSaveActiveTab, "empty window cannot save")

        _ = wc.createNewTab(url: url("safarium://start"))
        XCTAssertFalse(wc.canSaveActiveTab, "Start Page cannot be saved")
        wc.saveActiveTab()

        _ = wc.createNewTab(url: url("safarium://history"))
        XCTAssertFalse(wc.canSaveActiveTab, "History page cannot be saved")
        wc.saveActiveTab()

        _ = wc.createNewTab(url: url("safarium://inspect"))
        XCTAssertFalse(wc.canSaveActiveTab, "Inspect page cannot be saved")
        wc.saveActiveTab()

        let webTab = wc.createNewTab(url: url("https://broken.example/"))
        wc.tabEngine(webTab, didFailLoad: BrowserPageLoadError(failedURL: url("https://broken.example/"), errorCode: -1009, errorText: "Offline"))
        XCTAssertFalse(wc.canSaveActiveTab, "Error page cannot be saved")
        wc.saveActiveTab()

        XCTAssertTrue(eng.created.allSatisfy { $0.savePageWithPanelCallCount == 0 })
        let dl = t8Mirror(wc, "downloadController") as? DownloadAnimationController
        XCTAssertEqual(dl?.hasDownloads, false)
    }

    func testCmdSPerformKeyEquivalentTriggersSaveWithoutDownloadAnimation() throws {
        let (wc, eng) = makeWindow()
        let tab = try XCTUnwrap(wc.createNewTab(url: url("https://article.example/post")) as? T8SpyTab)
        let win = try XCTUnwrap(wc.window as? SafariWindow)
        XCTAssertTrue(wc.canSaveActiveTab)

        let dl = try XCTUnwrap(t8Mirror(wc, "downloadController") as? DownloadAnimationController)
        var visibilityChanges: [Bool] = []
        dl.onToolbarVisibilityChanged = { visibilityChanges.append($0) }

        // Plain 's', Cmd+Shift+S, or Dvorak Cmd+O (keyCode 1 with ASCII 'o') must NOT trigger Save As
        XCTAssertFalse(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "s", keyCode: 1, modifiers: [], window: win)))
        XCTAssertFalse(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "s", keyCode: 1, modifiers: [.command, .shift], window: win)))
        XCTAssertFalse(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "o", keyCode: 1, modifiers: [.command], window: win)))
        XCTAssertEqual(tab.savePageWithPanelCallCount, 0)

        // Cmd+S must route directly to saveActiveTab -> tab.savePageWithPanel
        XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "s", keyCode: 1, modifiers: [.command], window: win)))
        XCTAssertEqual(tab.savePageWithPanelCallCount, 1)
        XCTAssertTrue(tab.lastSavedFromWindow === win)
        XCTAssertEqual(eng.created.count, 1)

        // Saving a webpage must NEVER trigger download ring or toolbar download reveal
        XCTAssertFalse(dl.hasDownloads)
        XCTAssertFalse(dl.needsTemporaryToolbarButton)
        XCTAssertTrue(visibilityChanges.isEmpty)
    }

    func testMockBrowserTabGetPageSourceAndExportToPDFWithoutDownloads() throws {
        let engine = MockBrowserEngine()
        let tab = engine.createTab(initialURL: url("https://docs.example/guide"), parentView: nil, isPrivate: false)
        let expSource = expectation(description: "getPageSource")
        var capturedHTML: String?
        tab.getPageSource { html in
            capturedHTML = html
            expSource.fulfill()
        }
        wait(for: [expSource], timeout: 2.0)
        let html = try XCTUnwrap(capturedHTML)
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("https://docs.example/guide"))

        let pdfURL = Self.sandboxRoot.appendingPathComponent("saved-page-\(UUID().uuidString).pdf")
        let expPDF = expectation(description: "exportToPDF")
        var pdfOK = false
        tab.exportToPDF(atPath: pdfURL.path) { ok in
            pdfOK = ok
            expPDF.fulfill()
        }
        wait(for: [expPDF], timeout: 2.0)
        XCTAssertTrue(pdfOK)
        let pdfData = try Data(contentsOf: pdfURL)
        XCTAssertTrue(pdfData.starts(with: Data("%PDF-".utf8)))

        let startTab = engine.createTab(initialURL: url("safarium://start"), parentView: nil, isPrivate: false)
        let expStart = expectation(description: "startPageSource")
        var startHTML: String? = "non-nil"
        startTab.getPageSource { html in
            startHTML = html
            expStart.fulfill()
        }
        wait(for: [expStart], timeout: 2.0)
        XCTAssertNil(startHTML)
    }

    // MARK: - 2. Closing & Opening New Tab -> Command+1..9 Tab Switching

    func testCmdNumberSwitchesTabsReliablyAcrossCloseAndNewTabCycles() throws {
        let (wc, _) = makeWindow()
        let win = try XCTUnwrap(wc.window as? SafariWindow)
        let tabs = openTabs(wc, count: 4, activateLast: true)
        XCTAssertEqual(t8ActiveIndex(wc), 3)

        // KeyCode mapping on macOS for digits 1..9
        let digitEvents: [(Int, String, UInt16)] = [
            (1, "1", 18), (2, "2", 19), (3, "3", 20), (4, "4", 21), (9, "9", 25)
        ]

        // Initial Cmd+1 / Cmd+2 / Cmd+9 via SafariWindow.performKeyEquivalent
        XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: digitEvents[0].1, keyCode: digitEvents[0].2, window: win)))
        XCTAssertEqual(t8ActiveIndex(wc), 0)
        XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: digitEvents[4].1, keyCode: digitEvents[4].2, window: win)))
        XCTAssertEqual(t8ActiveIndex(wc), 3)

        // Focus a subview inside tab 1's contentView, then close that tab and open a new tab (Start Page + web page)
        let innerField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        tabs[1].contentView.addSubview(innerField)
        wc.selectTab(at: 1)
        win.makeFirstResponder(innerField)

        wc.closeActiveTab()
        XCTAssertEqual(wc.openTabCount, 3)
        XCTAssertFalse((win.firstResponder as? NSView)?.isDescendant(of: tabs[1].contentView) ?? false)

        // Open a new Start Page tab (which normally schedules address bar focus) and a web tab, then switch with Cmd+1..9
        _ = wc.createNewTab(url: url("safarium://start"), activate: true)
        _ = wc.createNewTab(url: url("https://fresh.example/"), activate: true)
        spinRunLoop(0.05)
        XCTAssertEqual(wc.openTabCount, 5)
        XCTAssertEqual(t8ActiveIndex(wc), 4)

        for (targetIdx, ev) in [(0, digitEvents[0]), (1, digitEvents[1]), (2, digitEvents[2]), (3, digitEvents[3]), (4, digitEvents[4])] {
            XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: ev.1, keyCode: ev.2, window: win)))
            XCTAssertEqual(t8ActiveIndex(wc), targetIdx, "Cmd+\(ev.0) must switch to tab \(targetIdx)")
        }

        // Second cycle: close tab 0, open a new tab, repeat Cmd+1 / Cmd+9
        wc.selectTab(at: 0)
        wc.closeActiveTab()
        _ = wc.createNewTab(url: url("https://cycle2.example/"), activate: true)
        XCTAssertEqual(wc.openTabCount, 5)

        XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "1", keyCode: 18, window: win)))
        XCTAssertEqual(t8ActiveIndex(wc), 0)
        XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "9", keyCode: 25, window: win)))
        XCTAssertEqual(t8ActiveIndex(wc), 4)
        XCTAssertEqual(wc.activeWebPageURLString, "https://cycle2.example/")
    }

    func testSelectingTabEndsAddressBarEditingSoCmdNumbersKeepWorking() throws {
        let (wc, _) = makeWindow()
        let win = try XCTUnwrap(wc.window as? SafariWindow)
        _ = openTabs(wc, count: 3, activateLast: false)
        let bar = try XCTUnwrap(t8Mirror(wc, "tabAddressBar") as? CompactTabAddressBar)

        wc.focusAddressBar()
        XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "2", keyCode: 19, window: win)))
        XCTAssertEqual(t8ActiveIndex(wc), 1)
        XCTAssertFalse(bar.isAddressBarEditing)

        XCTAssertTrue(win.performKeyEquivalent(with: makeKeyEquivalentEvent(characters: "1", keyCode: 18, window: win)))
        XCTAssertEqual(t8ActiveIndex(wc), 0)
    }

    // MARK: - 3. Download Animation Gating (Save Dialog Open / Cancel vs Confirmed)

    func testDownloadControllerIgnoresSaveDialogOpenAndCancelStates() {
        let dl = DownloadAnimationController()
        var visibilityEvents: [Bool] = []
        dl.onToolbarVisibilityChanged = { visibilityEvents.append($0) }

        // 1) Save dialog just opened: no fullPath yet, 0 received bytes
        let pendingDialog = BrowserDownloadItem(
            id: 101,
            suggestedFileName: "installer.dmg",
            fullPath: nil,
            url: URL(string: "https://cdn.example/installer.dmg"),
            totalBytes: 10_000,
            receivedBytes: 0,
            percentComplete: 0,
            isInProgress: true,
            isComplete: false,
            isCanceled: false,
            isPaused: false
        )
        dl.handleDownloadStarted(pendingDialog, fromOriginInWindow: NSPoint(x: 200, y: 200))
        XCTAssertFalse(dl.hasDownloads)
        XCTAssertFalse(dl.needsTemporaryToolbarButton)
        XCTAssertTrue(visibilityEvents.isEmpty)

        // 2) Empty fullPath while still unconfirmed
        let emptyPath = BrowserDownloadItem(
            id: 102,
            suggestedFileName: "installer.dmg",
            fullPath: "",
            url: URL(string: "https://cdn.example/installer.dmg"),
            totalBytes: 10_000,
            receivedBytes: 0,
            percentComplete: 0,
            isInProgress: true,
            isComplete: false,
            isCanceled: false,
            isPaused: false
        )
        dl.handleDownloadStarted(emptyPath)
        dl.handleDownloadUpdated(emptyPath)
        XCTAssertFalse(dl.hasDownloads)

        // 3) User cancels the Save dialog
        let canceledDialog = BrowserDownloadItem(
            id: 101,
            suggestedFileName: "installer.dmg",
            fullPath: nil,
            url: URL(string: "https://cdn.example/installer.dmg"),
            totalBytes: 10_000,
            receivedBytes: 0,
            percentComplete: 0,
            isInProgress: false,
            isComplete: false,
            isCanceled: true,
            isPaused: false
        )
        dl.handleDownloadUpdated(canceledDialog)
        dl.handleDownloadStarted(canceledDialog)
        XCTAssertFalse(dl.hasDownloads)
        XCTAssertFalse(dl.needsTemporaryToolbarButton)
        XCTAssertTrue(visibilityEvents.isEmpty)

        // 4) Real confirmed download starts after user picks destination
        let dest = Self.sandboxRoot.appendingPathComponent("Downloads/installer.dmg").path
        let confirmed = BrowserDownloadItem(
            id: 103,
            suggestedFileName: "installer.dmg",
            fullPath: dest,
            url: URL(string: "https://cdn.example/installer.dmg"),
            totalBytes: 10_000,
            receivedBytes: 0,
            percentComplete: 0,
            isInProgress: true,
            isComplete: false,
            isCanceled: false,
            isPaused: false
        )
        dl.handleDownloadStarted(confirmed, fromOriginInWindow: NSPoint(x: 200, y: 200))
        XCTAssertTrue(dl.hasDownloads)
        XCTAssertTrue(dl.needsTemporaryToolbarButton)
        XCTAssertEqual(visibilityEvents, [true])
    }

    func testWindowControllerGatingIgnoresUnconfirmedDownloadEvents() throws {
        let (wc, _) = makeWindow()
        let tab = wc.createNewTab(url: url("https://dl.example/"))
        let dl = try XCTUnwrap(t8Mirror(wc, "downloadController") as? DownloadAnimationController)

        let unconfirmed = BrowserDownloadItem(
            id: 201,
            suggestedFileName: "archive.zip",
            fullPath: nil,
            url: URL(string: "https://dl.example/archive.zip"),
            totalBytes: 4096,
            receivedBytes: 0,
            percentComplete: 0,
            isInProgress: true,
            isComplete: false,
            isCanceled: false,
            isPaused: false
        )
        wc.tabEngine(tab, didStartDownload: unconfirmed)
        XCTAssertFalse(dl.hasDownloads)

        let canceled = BrowserDownloadItem(
            id: 201,
            suggestedFileName: "archive.zip",
            fullPath: nil,
            url: URL(string: "https://dl.example/archive.zip"),
            totalBytes: 4096,
            receivedBytes: 0,
            percentComplete: 0,
            isInProgress: false,
            isComplete: false,
            isCanceled: true,
            isPaused: false
        )
        wc.tabEngine(tab, didUpdateDownload: canceled)
        XCTAssertFalse(dl.hasDownloads)

        let confirmed = BrowserDownloadItem(
            id: 202,
            suggestedFileName: "archive.zip",
            fullPath: Self.sandboxRoot.appendingPathComponent("Downloads/archive.zip").path,
            url: URL(string: "https://dl.example/archive.zip"),
            totalBytes: 4096,
            receivedBytes: 512,
            percentComplete: 12,
            isInProgress: true,
            isComplete: false,
            isCanceled: false,
            isPaused: false
        )
        wc.tabEngine(tab, didStartDownload: confirmed)
        XCTAssertTrue(dl.hasDownloads)
    }

    // MARK: - 4. Single-Tab Single-Window Drag & Drop Fast Path / Frame Budget

    func testTabDragVisualSnapshotCarriesSingleWindowFastPathMetadata() {
        let surface = IOSurfaceCreate([
            kIOSurfaceWidth as String: 64,
            kIOSurfaceHeight as String: 64,
            kIOSurfaceBytesPerElement as String: 4
        ] as CFDictionary)
        let snap = TabDragVisualSnapshot(
            tabID: "solo-tab",
            title: "Solo",
            displayDomain: "solo.example",
            url: url("https://solo.example/"),
            favicon: nil,
            pageSnapshot: nil,
            isActiveTab: true,
            isStartPage: false,
            isPrivate: false,
            isSingleTabSourceWindow: true,
            theme: .defaultLight,
            initialPillRectInScreen: NSRect(x: 400, y: 700, width: 280, height: 31),
            cursorOffsetInPill: NSPoint(x: 140, y: 15),
            sourceWindowSize: NSSize(width: 1200, height: 800),
            liveFrameSurface: surface,
            hasOtherCompatibleWindows: false
        )
        XCTAssertTrue(snap.isSingleTabSourceWindow)
        XCTAssertFalse(snap.hasOtherCompatibleWindows)
        XCTAssertNotNil(snap.liveFrameSurface)
    }

    func testSingleTabDragFastPathInvariantsAndFrameBudget() {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 1)
        XCTAssertEqual(wc.openTabCount, 1)

        // Ghosting a single-tab window preserves tab ownership and toggles mouse/alpha cleanly
        wc.setSingleTabTearOffGhosted(true)
        XCTAssertEqual(wc.window?.ignoresMouseEvents, true)
        XCTAssertEqual(wc.openTabCount, 1)
        wc.setSingleTabTearOffGhosted(false)
        XCTAssertEqual(wc.window?.ignoresMouseEvents, false)
        XCTAssertEqual(wc.openTabCount, 1)

        // Benchmark pure card geometry + pixelSnap across 240 frames (2 full seconds at 120Hz)
        let coord = SafariTabDragCoordinator.shared
        coord.activeSnapshot = TabDragVisualSnapshot(
            tabID: "t0",
            title: "Bench",
            displayDomain: "bench.example",
            url: url("https://bench.example/"),
            favicon: nil,
            pageSnapshot: nil,
            isActiveTab: true,
            isStartPage: false,
            isPrivate: false,
            isSingleTabSourceWindow: true,
            theme: .defaultLight,
            initialPillRectInScreen: NSRect(x: 420, y: 740, width: 290, height: 31),
            cursorOffsetInPill: NSPoint(x: 145, y: 15),
            sourceWindowSize: NSSize(width: 1200, height: 800),
            liveFrameSurface: nil,
            hasOtherCompatibleWindows: false
        )
        coord.morphProgress = 1.0
        coord.morphTarget = 1.0
        coord.currentPillWidth = 290
        coord.targetPillWidth = 290
        coord.trackMagnetAmount = 0.0
        coord.trackMagnetTarget = 0.0
        coord.previewSize = NSSize(width: 288, height: 192)
        defer { coord.activeSnapshot = nil }

        let t0 = CFAbsoluteTimeGetCurrent()
        var lastRect = NSRect.zero
        for frame in 0..<240 {
            coord.currentCursorScreen = NSPoint(x: 500 + CGFloat(frame), y: 600 - CGFloat(frame) * 0.5)
            lastRect = coord.computeCurrentCardScreenRect()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertEqual(lastRect.size, NSSize(width: 288, height: 192))
        XCTAssertLessThan(elapsed, 0.05, "240 frames of drag geometry should take < 50ms total")
    }

    // MARK: - 5. Extension Popover Dismissal & Private Mode Filtering

    func testExtensionPopoverDismissesOnShortcutsNavigationTabSwitchAndFocusLoss() throws {
        let (wc, _) = makeWindow()
        _ = openTabs(wc, count: 2, activateLast: false)
        let extController = try XCTUnwrap(t8Mirror(wc, "extensionPopoverController") as? ExtensionPopoverController)
        let win = try XCTUnwrap(wc.window)
        let anchor = NSView(frame: NSRect(x: 100, y: 740, width: 32, height: 32))
        win.contentView?.addSubview(anchor)

        let ext = BrowserExtensionItem(
            id: "ext-1",
            name: "Test Ext",
            version: "1.0",
            icon: nil,
            badgeText: nil,
            badgeColor: nil,
            popupURL: URL(string: "chrome-extension://ext-1/popup.html"),
            enabled: true,
            allowInPrivate: true
        )

        func openMockHTMLPopup() {
            extController.toggleExtensionPopup(for: ext, relativeTo: anchor, isDark: false) { w, h, _ in
                NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            }
            // Keep test completely offscreen while preserving activePanel state
            let panel = t8Mirror(extController, "activePanel") as? NSPanel
            panel?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            XCTAssertTrue(extController.isShown)
        }

        // 1. Focus address bar (Cmd+L)
        openMockHTMLPopup()
        wc.focusAddressBar()
        XCTAssertFalse(extController.isShown)

        // 2. Navigate active tab & back/forward
        openMockHTMLPopup()
        wc.openURLInActiveOrNewTab(url("https://navigated.example/"), newTab: false)
        XCTAssertFalse(extController.isShown)

        openMockHTMLPopup()
        wc.navigateBackInActiveTab()
        XCTAssertFalse(extController.isShown)

        openMockHTMLPopup()
        wc.navigateForwardInActiveTab()
        XCTAssertFalse(extController.isShown)

        // 3. Tab switch
        openMockHTMLPopup()
        wc.selectTab(at: 1)
        XCTAssertFalse(extController.isShown)

        // 4. Reload active tab
        openMockHTMLPopup()
        wc.reloadActiveTab()
        XCTAssertFalse(extController.isShown)

        // 5. Cmd+S Save active tab
        _ = wc.createNewTab(url: url("safarium://start"), activate: true)
        openMockHTMLPopup()
        wc.saveActiveTab()
        XCTAssertFalse(extController.isShown)

        // 6. Parent window resigns main (focus loss)
        openMockHTMLPopup()
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: win)
        XCTAssertFalse(extController.isShown)

        // 7. Explicit SXExtensionPopupShouldCloseNotification
        openMockHTMLPopup()
        NotificationCenter.default.post(name: Notification.Name("SXExtensionPopupShouldCloseNotification"), object: nil)
        spinRunLoop(0.02)
        XCTAssertFalse(extController.isShown)
    }

    func testPrivateWindowFiltersDisallowedExtensionIcons() throws {
        let normalExt = BrowserExtensionItem(
            id: "ext-normal-only",
            name: "Normal Only",
            version: "1.0",
            icon: nil,
            badgeText: nil,
            badgeColor: nil,
            popupURL: nil,
            enabled: true,
            allowInPrivate: false
        )
        let privateAllowedExt = BrowserExtensionItem(
            id: "ext-private-ok",
            name: "Private Allowed",
            version: "1.0",
            icon: nil,
            badgeText: nil,
            badgeColor: nil,
            popupURL: nil,
            enabled: true,
            allowInPrivate: true
        )

        let (normalWC, _) = makeWindow(isPrivate: false)
        normalWC.refreshExtensionsUI([normalExt, privateAllowedExt])
        let normalCoord = try XCTUnwrap(t8Mirror(normalWC, "extensionsCoordinator") as? ExtensionsToolbarCoordinator)
        let normalVisibleIDs = Set(normalCoord.allCapsules.flatMap { $0.extensions.map(\.id) })
        XCTAssertEqual(normalVisibleIDs, Set(["ext-normal-only", "ext-private-ok"]))

        let (privateWC, _) = makeWindow(isPrivate: true)
        privateWC.refreshExtensionsUI([normalExt, privateAllowedExt])
        let privateCoord = try XCTUnwrap(t8Mirror(privateWC, "extensionsCoordinator") as? ExtensionsToolbarCoordinator)
        let privateVisibleIDs = Set(privateCoord.allCapsules.flatMap { $0.extensions.map(\.id) })
        XCTAssertEqual(privateVisibleIDs, Set(["ext-private-ok"]))
    }

    // MARK: - 6. Zero AutoLayout Constraint Breaks on Window Layout

    func testWindowCreationTabsSidebarLayoutAndResizeProduceZeroConstraintBreaks() {
        let stderrLog = t8CaptureStderr("autolayout-zero-breaks") {
            let (wc, _) = makeWindow()
            let win = wc.window!
            _ = openTabs(wc, count: 3, activateLast: true)
            wc.selectTab(at: 0)
            wc.toggleSidebar()
            win.contentView?.layoutSubtreeIfNeeded()
            wc.toggleSidebar()
            win.contentView?.layoutSubtreeIfNeeded()

            for width in [680, 900, 1200] as [CGFloat] {
                win.setContentSize(NSSize(width: width, height: 600))
                win.contentView?.layoutSubtreeIfNeeded()
            }
            wc.closeTab(at: 1)
            win.contentView?.layoutSubtreeIfNeeded()
        }
        XCTAssertFalse(
            stderrLog.contains("Conflicting constraints") || stderrLog.contains("Unable to simultaneously satisfy constraints"),
            "Expected zero AutoLayout constraint conflicts, got:\n\(stderrLog)"
        )
    }
}
