import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: BrowserEngine!
    private var windowControllers: [SafariWindowController] = []
    private var importWindowController: ImportDataWindowController?
    private var settingsWindowController: SafariSettingsWindowController?
    private var privacyReportWindowController: PrivacyReportWindowController?

    private var appMenuRef: NSMenu?
    private var settingsForDomainMenuItem: NSMenuItem?
    private var importFromBrowserSubmenu: NSMenu?
    private var viewMenuRef: NSMenu?
    private var toggleSidebarMenuItem: NSMenuItem?
    private var toggleOverviewMenuItem: NSMenuItem?
    private var tabLayoutSubmenu: NSMenu?
    private var textEncodingSubmenu: NSMenu?
    private var historyMenuRef: NSMenu?
    private var recentlyClosedSubmenu: NSMenu?
    private var bookmarksMenuRef: NSMenu?
    private var favoritesSubmenu: NSMenu?
    private var windowMenuRef: NSMenu?
    private var muteTabMenuItem: NSMenuItem?
    private var muteOtherTabsMenuItem: NSMenuItem?
    private var moveTabToNewWindowMenuItem: NSMenuItem?
    private var developMenuItem: NSMenuItem?
    private var settingsObserver: NSObjectProtocol?
    private var websitePolicyObserver: NSObjectProtocol?
    private var isWipingAllData: Bool = false

    var activeWindowController: SafariWindowController? {
        if let key = NSApp.keyWindow?.windowController as? SafariWindowController {
            return key
        }
        if let main = NSApp.mainWindow?.windowController as? SafariWindowController {
            return main
        }
        return windowControllers.last
    }

    var openWindowCount: Int { windowControllers.count }

    /// Returns true if another open Safarium window with matching privacy mode exists besides `controller`.
    func hasOtherCompatibleWindow(besides controller: SafariWindowController) -> Bool {
        windowControllers.contains { other in
            other !== controller &&
            other.isPrivate == controller.isPrivate &&
            (other.window?.isVisible ?? false) &&
            !(other.window?.isMiniaturized ?? false)
        }
    }

    /// Finds the frontmost compatible Safarium window whose tab bar drop zone contains `screenPoint`.
    func tabBarDropTarget(
        atScreenPoint screenPoint: NSPoint,
        isPrivate: Bool,
        draggedTabID: String,
        excludingWindowController: SafariWindowController? = nil,
        extraVerticalHysteresis: CGFloat = 0.0
    ) -> TabBarDropTarget? {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? SafariWindowController }
        let candidates = ordered.isEmpty ? Array(windowControllers.reversed()) : ordered
        for controller in candidates {
            guard controller !== excludingWindowController,
                  controller.isPrivate == isPrivate,
                  let win = controller.window,
                  win.isVisible,
                  win.alphaValue > 0.05,
                  !win.isMiniaturized else { continue }
            if let target = controller.tabBarDropTarget(
                atScreenPoint: screenPoint,
                draggedTabID: draggedTabID,
                extraVerticalHysteresis: extraVerticalHysteresis
            ) {
                return target
            }
        }
        return nil
    }

    private func configureWindowController(_ controller: SafariWindowController) {
        controller.onOpenPrivacyReport = { [weak self] in
            self?.openPrivacyReportAction()
        }
    }

    /// Spawns a new `SafariWindowController` at `frame` and adopts a detached live tab without reloading.
    @discardableResult
    func openWindow(
        withTransferredTab transfer: DetachedTabTransfer,
        frame: NSRect,
        isPrivate: Bool,
        initialAlpha: CGFloat = 1.0
    ) -> SafariWindowController? {
        guard let engine else { return nil }
        let controller = SafariWindowController(engine: engine, isPrivate: isPrivate)
        configureWindowController(controller)
        controller.markInitialTabsHandled()
        windowControllers.append(controller)
        if let window = controller.window {
            window.alphaValue = initialAlpha
            window.setFrame(frame, display: false)
            window.layoutIfNeeded()
        }
        controller.acceptTransferredTab(transfer, atIndex: 0, activate: true, animatedTabBar: false)
        controller.showWindow(nil)
        return controller
    }

    @discardableResult
    func openNewWindow(url: URL? = nil, isPrivate: Bool = false) -> SafariWindowController? {
        guard let engine else { return nil }
        let controller = SafariWindowController(engine: engine, isPrivate: isPrivate)
        configureWindowController(controller)
        controller.markInitialTabsHandled()
        windowControllers.append(controller)
        controller.showWindow(nil)
        if let window = controller.window {
            if let refFrame = NSApp.keyWindow?.frame ?? windowControllers.dropLast().last?.window?.frame {
                let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let nextX = min(screen.maxX - window.frame.width - 12, refFrame.origin.x + 28)
                let nextY = max(screen.minY + 12, refFrame.origin.y - 28)
                window.setFrameOrigin(NSPoint(x: nextX, y: nextY))
            }
            window.makeKeyAndOrderFront(nil)
        }
        let targetURL = url ?? URL(string: "safarium://start")!
        controller.createNewTab(url: targetURL, activate: true)
        return controller
    }

    func windowControllerDidClose(_ controller: SafariWindowController) {
        windowControllers.removeAll { $0 === controller }
        let hasAnyPrivateOpen = windowControllers.contains { $0.isPrivate }
        if !hasAnyPrivateOpen {
            engine?.resetPrivateSession()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable macOS/Chromium built-in HistorySwiper circular Back/Forward arrow overlay;
        // Safarium's native SwipeNavigationController owns 120Hz Safari page-slide gestures exclusively.
        UserDefaults.standard.set(false, forKey: "AppleEnableSwipeNavigateWithScrolls")
        setupMainMenu()
        if ProcessInfo.processInfo.environment["SAFARIUM_FREEZE_DEBUG"] != nil {
            // Debug-only hook for automated animation measurements (scripts/flicker): toggles Tab Overview through the
            // same path as the toolbar button while the app stays in the background.
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("SafariumDebugToggleTabOverview"), object: nil, queue: .main
            ) { [weak self] _ in
                self?.activeWindowController?.toggleTabOverview()
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("SXEngineRuntimeRequestNewWindowNotification"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let url = note.userInfo?["url"] as? URL else { return }
            self.openNewWindow(url: url, isPrivate: false)
        }

        // Prefer real ChromiumBrowserEngine when linked & ready; cleanly fall back to MockBrowserEngine if unavailable.
        let chromium = ChromiumBrowserEngine()
        do {
            try chromium.start()
            self.engine = chromium
            NSLog("[Safarium] Running with engine: %@", chromium.engineName)
        } catch {
            NSLog("[Safarium] ChromiumBrowserEngine failed to start (%@); falling back to MockBrowserEngine", error.localizedDescription)
            let mock = MockBrowserEngine()
            try? mock.start()
            self.engine = mock
        }

        AssetLoader.shared.pruneHistoryIfNeeded()
        engine.applySettings(BrowserSettings.shared.enginePreferencesDictionary())
        engine.syncPrivacyPolicy(BrowserSettings.shared.privacyPolicyDictionary())

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .safariumSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.engine?.applySettings(BrowserSettings.shared.enginePreferencesDictionary())
            self.engine?.syncPrivacyPolicy(BrowserSettings.shared.privacyPolicyDictionary())
            let key = note.userInfo?["key"] as? String ?? ""
            if key == BrowserSettings.Key.removeHistory {
                AssetLoader.shared.pruneHistoryIfNeeded()
            } else if key == BrowserSettings.Key.showDeveloperFeatures {
                self.developMenuItem?.isHidden = !BrowserSettings.shared.showDeveloperFeatures
            }
        }

        websitePolicyObserver = NotificationCenter.default.addObserver(
            forName: .safariumWebsitePoliciesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.engine?.syncPrivacyPolicy(BrowserSettings.shared.privacyPolicyDictionary())
        }

        let startPrivate = (ProcessInfo.processInfo.environment["SAFARIUM_INITIAL_URL"] == nil) &&
                           (BrowserSettings.shared.opensWithIndex == 3)
        let controller = SafariWindowController(engine: engine, isPrivate: startPrivate)
        configureWindowController(controller)
        self.windowControllers.append(controller)
        controller.showWindow(nil)
        if let window = controller.window {
            DesktopSpacePlacer.moveWindowToDesktopIfRequested(window)
            window.makeKeyAndOrderFront(nil)
        }
        controller.openInitialTabsIfNeeded()

        // Only activate onto foreground if not explicitly targeting background Desktop 2
        if ProcessInfo.processInfo.environment["SAFARIUM_DESKTOP"] == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let websitePolicyObserver {
            NotificationCenter.default.removeObserver(websitePolicyObserver)
            self.websitePolicyObserver = nil
        }
        guard !isWipingAllData else { return }
        if let primary = windowControllers.first(where: { !$0.isPrivate }) {
            primary.persistCurrentSession()
        }
        engine?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let existing = windowControllers.first {
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
                existing.openInitialTabsIfNeeded()
            } else {
                openNewWindow(url: nil, isPrivate: false)
            }
        }
        return true
    }

    // MARK: - Menu Bar & Keyboard Shortcuts

    private func menuIcon(_ symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func makeMenuItem(
        _ title: String,
        action: Selector?,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags? = nil,
        symbol: String? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if let modifiers {
            item.keyEquivalentModifierMask = modifiers
        }
        if let symbol {
            item.image = menuIcon(symbol)
        }
        item.tag = tag
        return item
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. Safarium (App Menu)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Safarium")
        appMenu.delegate = self
        self.appMenuRef = appMenu

        appMenu.addItem(makeMenuItem("About Safarium", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(makeMenuItem("Safarium Extensions…", action: #selector(manageExtensionsAction)))
        appMenu.addItem(.separator())
        appMenu.addItem(makeMenuItem("Settings…", action: #selector(openSettingsAction), keyEquivalent: ",", symbol: "gearshape"))
        appMenu.addItem(makeMenuItem("Privacy Report…", action: #selector(openPrivacyReportAction), symbol: "shield.lefthalf.filled"))
        appMenu.addItem(makeMenuItem("Privacy Settings…", action: #selector(openPrivacySettingsAction), symbol: "shield.lefthalf.filled"))
        appMenu.addItem(.separator())

        let siteSettingsItem = makeMenuItem("Settings for This Website…", action: #selector(openWebsiteSettingsAction))
        self.settingsForDomainMenuItem = siteSettingsItem
        appMenu.addItem(siteSettingsItem)
        appMenu.addItem(makeMenuItem("Clear History…", action: #selector(clearHistoryAction)))
        appMenu.addItem(makeMenuItem("Clear All Data…", action: #selector(clearAllDataAction)))
        appMenu.addItem(makeMenuItem("Manage Profiles…", action: #selector(openProfilesSettingsAction)))
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())

        appMenu.addItem(makeMenuItem("Hide Safarium", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(makeMenuItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h", modifiers: [.command, .option]))
        appMenu.addItem(makeMenuItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(makeMenuItem("Quit Safarium", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        fileMenu.addItem(makeMenuItem("New Window", action: #selector(newWindowAction), keyEquivalent: "n"))
        fileMenu.addItem(makeMenuItem("New Private Window", action: #selector(newPrivateWindowAction), keyEquivalent: "N", modifiers: [.command, .shift]))
        fileMenu.addItem(makeMenuItem("New Tab", action: #selector(newTabAction), keyEquivalent: "t"))
        fileMenu.addItem(makeMenuItem("Reopen Last Closed Tab", action: #selector(reopenClosedTabAction), keyEquivalent: "T", modifiers: [.command, .shift]))
        fileMenu.addItem(makeMenuItem("Open File…", action: #selector(openFileAction), keyEquivalent: "o"))
        fileMenu.addItem(makeMenuItem("Open Location…", action: #selector(focusAddressBarAction), keyEquivalent: "l"))
        fileMenu.addItem(.separator())

        fileMenu.addItem(makeMenuItem("Close Tab", action: #selector(closeTabAction), keyEquivalent: "w"))
        fileMenu.addItem(makeMenuItem("Close Window", action: #selector(closeWindowAction), keyEquivalent: "W", modifiers: [.command, .shift]))
        fileMenu.addItem(makeMenuItem("Close All Windows", action: #selector(closeAllWindowsAction), keyEquivalent: "W", modifiers: [.command, .option, .shift]))
        fileMenu.addItem(.separator())

        fileMenu.addItem(makeMenuItem("Share…", action: #selector(sharePageAction), symbol: "square.and.arrow.up"))
        fileMenu.addItem(makeMenuItem("Export as PDF…", action: #selector(exportAsPDFAction)))
        fileMenu.addItem(.separator())

        fileMenu.addItem(makeMenuItem("Import Browsing Data from File or Folder…", action: #selector(importFromFileOrFolderAction)))
        fileMenu.addItem(makeMenuItem("Export Bookmarks to HTML…", action: #selector(exportBookmarksHTMLAction)))
        let importBrowserMenuItem = NSMenuItem(title: "Import from Browser", action: nil, keyEquivalent: "")
        let importBrowserMenu = NSMenu(title: "Import from Browser")
        importBrowserMenu.delegate = self
        importBrowserMenuItem.submenu = importBrowserMenu
        self.importFromBrowserSubmenu = importBrowserMenu
        fileMenu.addItem(importBrowserMenuItem)
        fileMenu.addItem(.separator())

        fileMenu.addItem(makeMenuItem("Print…", action: #selector(printPageAction), keyEquivalent: "p", symbol: "printer"))

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 3. Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(makeMenuItem("Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(makeMenuItem("Redo", action: Selector(("redo:")), keyEquivalent: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(makeMenuItem("Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(makeMenuItem("Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(makeMenuItem("Copy Page Address", action: #selector(copyPageURLAction), keyEquivalent: "C", modifiers: [.command, .shift]))
        editMenu.addItem(makeMenuItem("Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(makeMenuItem("Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V", modifiers: [.command, .option, .shift]))
        editMenu.addItem(makeMenuItem("Delete", action: #selector(NSText.delete(_:))))
        editMenu.addItem(makeMenuItem("Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())

        let findSubmenuItem = makeMenuItem("Find", action: nil, symbol: "magnifyingglass")
        let findSubmenu = NSMenu(title: "Find")
        findSubmenu.addItem(makeMenuItem("Find…", action: #selector(findOnPageAction), keyEquivalent: "f"))
        findSubmenu.addItem(makeMenuItem("Find Next", action: #selector(findNextAction), keyEquivalent: "g"))
        findSubmenu.addItem(makeMenuItem("Find Previous", action: #selector(findPreviousAction), keyEquivalent: "G", modifiers: [.command, .shift]))
        findSubmenu.addItem(.separator())
        findSubmenu.addItem(makeMenuItem("Search Web…", action: #selector(focusAddressBarAction), keyEquivalent: "f", modifiers: [.command, .option]))
        findSubmenuItem.submenu = findSubmenu
        editMenu.addItem(findSubmenuItem)

        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        spellingMenu.addItem(makeMenuItem("Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":"))
        spellingMenu.addItem(makeMenuItem("Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";"))
        spellingMenu.addItem(.separator())
        spellingMenu.addItem(makeMenuItem("Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spellingMenu.addItem(makeMenuItem("Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:))))
        spellingMenu.addItem(makeMenuItem("Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        spellingItem.submenu = spellingMenu
        editMenu.addItem(spellingItem)

        let substitutionsItem = NSMenuItem(title: "Substitutions", action: nil, keyEquivalent: "")
        let substitutionsMenu = NSMenu(title: "Substitutions")
        substitutionsMenu.addItem(makeMenuItem("Show Substitutions", action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        substitutionsMenu.addItem(.separator())
        substitutionsMenu.addItem(makeMenuItem("Smart Copy/Paste", action: #selector(NSTextView.toggleSmartInsertDelete(_:))))
        substitutionsMenu.addItem(makeMenuItem("Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        substitutionsMenu.addItem(makeMenuItem("Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        substitutionsMenu.addItem(makeMenuItem("Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        substitutionsItem.submenu = substitutionsMenu
        editMenu.addItem(substitutionsItem)

        let transformItem = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        let transformMenu = NSMenu(title: "Transformations")
        transformMenu.addItem(makeMenuItem("Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:))))
        transformMenu.addItem(makeMenuItem("Make Lower Case", action: #selector(NSResponder.lowercaseWord(_:))))
        transformMenu.addItem(makeMenuItem("Capitalize", action: #selector(NSResponder.capitalizeWord(_:))))
        transformItem.submenu = transformMenu
        editMenu.addItem(transformItem)

        let speechItem = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        let speechMenu = NSMenu(title: "Speech")
        speechMenu.addItem(makeMenuItem("Start Speaking", action: #selector(NSTextView.startSpeaking(_:))))
        speechMenu.addItem(makeMenuItem("Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:))))
        speechItem.submenu = speechMenu
        editMenu.addItem(speechItem)
        editMenu.addItem(.separator())

        editMenu.addItem(makeMenuItem("AutoFill Settings…", action: #selector(openAutoFillSettingsAction), symbol: "rectangle.and.pencil.and.ellipsis"))

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 4. View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self
        self.viewMenuRef = viewMenu

        viewMenu.addItem(makeMenuItem("Customize Toolbar…", action: #selector(customizeToolbarAction)))
        viewMenu.addItem(.separator())

        let tabLayoutItem = NSMenuItem(title: "Tab Layout", action: nil, keyEquivalent: "")
        let tabLayoutMenu = NSMenu(title: "Tab Layout")
        tabLayoutMenu.delegate = self
        self.tabLayoutSubmenu = tabLayoutMenu
        tabLayoutItem.submenu = tabLayoutMenu
        viewMenu.addItem(tabLayoutItem)
        viewMenu.addItem(.separator())

        let sidebarItem = makeMenuItem("Show Sidebar", action: #selector(toggleSidebarAction), keyEquivalent: "L", modifiers: [.command, .shift])
        self.toggleSidebarMenuItem = sidebarItem
        viewMenu.addItem(sidebarItem)
        viewMenu.addItem(makeMenuItem("Show Bookmarks Sidebar", action: #selector(showBookmarksSidebarAction), keyEquivalent: "1", modifiers: [.control, .command]))
        viewMenu.addItem(makeMenuItem("Show Reading List Sidebar", action: #selector(showReadingListSidebarAction), keyEquivalent: "2", modifiers: [.control, .command]))
        viewMenu.addItem(.separator())

        let overviewItem = makeMenuItem("Show Tab Overview", action: #selector(toggleTabOverviewAction), keyEquivalent: "\\", modifiers: [.command, .shift], symbol: "square.grid.2x2")
        self.toggleOverviewMenuItem = overviewItem
        viewMenu.addItem(overviewItem)
        viewMenu.addItem(makeMenuItem("Show Downloads", action: #selector(toggleDownloadsAction), keyEquivalent: "l", modifiers: [.command, .option], symbol: "arrow.down.circle"))
        viewMenu.addItem(.separator())

        viewMenu.addItem(makeMenuItem("Stop", action: #selector(stopOrEscapeAction), keyEquivalent: "."))
        viewMenu.addItem(makeMenuItem("Reload Page", action: #selector(reloadAction), keyEquivalent: "r"))
        viewMenu.addItem(makeMenuItem("Reload Page From Origin", action: #selector(reloadIgnoringCacheAction), keyEquivalent: "R", modifiers: [.command, .shift]))
        viewMenu.addItem(.separator())

        viewMenu.addItem(makeMenuItem("Actual Size", action: #selector(zoomResetAction), keyEquivalent: "0"))
        viewMenu.addItem(makeMenuItem("Zoom In", action: #selector(zoomInAction), keyEquivalent: "+"))
        viewMenu.addItem(makeMenuItem("Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-"))
        viewMenu.addItem(.separator())

        let encodingItem = NSMenuItem(title: "Text Encoding", action: nil, keyEquivalent: "")
        let encodingMenu = NSMenu(title: "Text Encoding")
        encodingMenu.delegate = self
        self.textEncodingSubmenu = encodingMenu
        encodingItem.submenu = encodingMenu
        viewMenu.addItem(encodingItem)
        viewMenu.addItem(.separator())

        viewMenu.addItem(makeMenuItem("Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f", modifiers: [.control, .command]))

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 5. History Menu (dynamically populated via NSMenuDelegate)
        let historyMenuItem = NSMenuItem()
        let historyMenu = NSMenu(title: "History")
        historyMenu.delegate = self
        self.historyMenuRef = historyMenu
        populateHistoryMenu(historyMenu)
        historyMenuItem.submenu = historyMenu
        mainMenu.addItem(historyMenuItem)

        // 6. Bookmarks Menu (dynamically populated via NSMenuDelegate)
        let bookmarksMenuItem = NSMenuItem()
        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksMenu.delegate = self
        self.bookmarksMenuRef = bookmarksMenu
        populateBookmarksMenu(bookmarksMenu)
        bookmarksMenuItem.submenu = bookmarksMenu
        mainMenu.addItem(bookmarksMenuItem)

        // 7. Extensions Menu
        let extMenuItem = NSMenuItem()
        let extMenu = NSMenu(title: "Extensions")
        extMenu.addItem(makeMenuItem("Chrome Web Store…", action: #selector(openChromeWebStoreAction), symbol: "bag"))
        extMenu.addItem(makeMenuItem("Manage Extensions…", action: #selector(manageExtensionsAction), symbol: "puzzlepiece.extension"))
        extMenu.addItem(.separator())
        extMenu.addItem(makeMenuItem("Load Unpacked Extension…", action: #selector(loadUnpackedExtensionAction)))
        extMenu.addItem(makeMenuItem("Install .crx Extension…", action: #selector(installCRXExtensionAction)))
        extMenuItem.submenu = extMenu
        mainMenu.addItem(extMenuItem)

        // 8. Develop Menu (controlled by Settings -> Advanced -> Show features for web developers)
        let devMenuItem = NSMenuItem()
        let devMenu = NSMenu(title: "Develop")
        devMenu.addItem(makeMenuItem("Show Web Inspector", action: #selector(showWebInspectorAction), keyEquivalent: "i", modifiers: [.command, .option]))
        devMenu.addItem(makeMenuItem("Show JavaScript Console", action: #selector(showWebInspectorAction), keyEquivalent: "c", modifiers: [.command, .option]))
        devMenu.addItem(makeMenuItem("Show Page Source", action: #selector(showPageSourceAction), keyEquivalent: "u", modifiers: [.command, .option]))
        devMenu.addItem(.separator())
        devMenu.addItem(makeMenuItem("Service Workers", action: #selector(openServiceWorkersAction)))
        devMenu.addItem(makeMenuItem("Inspect Devices & Targets", action: #selector(openSafariumInspectAction)))
        devMenu.addItem(makeMenuItem("Remote Debugging", action: #selector(openSafariumRemoteDebuggingAction)))
        devMenu.addItem(.separator())
        devMenu.addItem(makeMenuItem("Empty Caches", action: #selector(emptyCachesAction), keyEquivalent: "e", modifiers: [.command, .option]))
        devMenu.addItem(.separator())
        devMenu.addItem(makeMenuItem("Developer Settings…", action: #selector(openDeveloperSettingsAction), symbol: "wrench.and.screwdriver"))
        devMenuItem.submenu = devMenu
        devMenuItem.isHidden = !BrowserSettings.shared.showDeveloperFeatures
        self.developMenuItem = devMenuItem
        mainMenu.addItem(devMenuItem)

        // 9. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.delegate = self
        self.windowMenuRef = windowMenu

        windowMenu.addItem(makeMenuItem("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(makeMenuItem("Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())

        let arrangeItem = NSMenuItem(title: "Arrange Tabs By", action: nil, keyEquivalent: "")
        let arrangeMenu = NSMenu(title: "Arrange Tabs By")
        arrangeMenu.addItem(makeMenuItem("Title", action: #selector(arrangeTabsByTitleAction)))
        arrangeMenu.addItem(makeMenuItem("Website", action: #selector(arrangeTabsByWebsiteAction)))
        arrangeItem.submenu = arrangeMenu
        windowMenu.addItem(arrangeItem)

        windowMenu.addItem(makeMenuItem("Show Previous Tab", action: #selector(previousTabAction), keyEquivalent: "\u{19}", modifiers: [.control, .shift]))
        windowMenu.addItem(makeMenuItem("Show Next Tab", action: #selector(nextTabAction), keyEquivalent: "\t", modifiers: [.control]))
        windowMenu.addItem(.separator())

        windowMenu.addItem(makeMenuItem("Duplicate Tab", action: #selector(duplicateTabAction)))
        let moveTabItem = makeMenuItem("Move Tab to New Window", action: #selector(moveTabToNewWindowAction))
        self.moveTabToNewWindowMenuItem = moveTabItem
        windowMenu.addItem(moveTabItem)
        windowMenu.addItem(makeMenuItem("Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:))))
        windowMenu.addItem(.separator())

        let muteThisItem = makeMenuItem("Mute This Tab", action: #selector(toggleMuteTabAction), symbol: "speaker.slash")
        self.muteTabMenuItem = muteThisItem
        windowMenu.addItem(muteThisItem)
        let muteOthersItem = makeMenuItem("Mute Other Tabs", action: #selector(muteOtherTabsAction), symbol: "speaker.slash")
        self.muteOtherTabsMenuItem = muteOthersItem
        windowMenu.addItem(muteOthersItem)
        windowMenu.addItem(.separator())

        for num in 1...9 {
            let title = (num == 9) ? "Select Last Tab" : "Select Tab \(num)"
            windowMenu.addItem(makeMenuItem(title, action: #selector(selectTabByNumberAction(_:)), keyEquivalent: "\(num)", tag: num - 1))
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeMenuItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:))))

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // 10. Help Menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(makeMenuItem("Safarium Settings…", action: #selector(openSettingsAction)))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - Dynamic Menu Population

    private func populateHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(makeMenuItem("Show All History", action: #selector(openHistoryPageAction), keyEquivalent: "y"))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Back", action: #selector(goBackAction), keyEquivalent: "["))
        menu.addItem(makeMenuItem("Forward", action: #selector(goForwardAction), keyEquivalent: "]"))
        menu.addItem(makeMenuItem("Home", action: #selector(goHomeAction), keyEquivalent: "H", modifiers: [.command, .shift]))
        menu.addItem(.separator())

        let reopenItem = makeMenuItem("Reopen Last Closed Tab", action: #selector(reopenClosedTabAction), keyEquivalent: "T", modifiers: [.command, .shift])
        reopenItem.isEnabled = activeWindowController?.hasRecentlyClosedTabs ?? false
        menu.addItem(reopenItem)

        let recentClosedMenuItem = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        let closedSub = NSMenu(title: "Recently Closed")
        let closedURLs = activeWindowController?.recentClosedURLsForMenu ?? []
        if closedURLs.isEmpty {
            let none = NSMenuItem(title: "No Recently Closed Tabs", action: nil, keyEquivalent: "")
            none.isEnabled = false
            closedSub.addItem(none)
        } else {
            for (idx, url) in closedURLs.enumerated() {
                let label = URLInputNormalizer.displayDomain(for: url)
                let item = makeMenuItem(label, action: #selector(reopenSpecificClosedTabAction(_:)), tag: idx)
                item.image = FaviconCache.shared.cachedImage(forURLString: url.absoluteString) ?? menuIcon("globe")
                item.image?.size = NSSize(width: 16, height: 16)
                closedSub.addItem(item)
            }
        }
        recentClosedMenuItem.submenu = closedSub
        self.recentlyClosedSubmenu = closedSub
        menu.addItem(recentClosedMenuItem)

        let recentHistory = Array(AssetLoader.shared.browsingHistory().prefix(15))
        if !recentHistory.isEmpty {
            menu.addItem(.separator())
            for entry in recentHistory {
                let rawTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty ? URLInputNormalizer.displayDomain(for: URL(string: entry.url)) : rawTitle
                let truncated = title.count > 56 ? String(title.prefix(55)) + "…" : title
                let item = makeMenuItem(truncated, action: #selector(openMenuURLAction(_:)))
                item.representedObject = entry.url
                let icon = FaviconCache.shared.cachedImage(forURLString: entry.url) ?? menuIcon("globe")
                icon?.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Clear History…", action: #selector(clearHistoryAction)))
        menu.addItem(makeMenuItem("Clear All Data…", action: #selector(clearAllDataAction)))
    }

    private func populateBookmarksMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(makeMenuItem("Show Start Page", action: #selector(showStartPageAction), symbol: "square.grid.3x3"))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Show Bookmarks", action: #selector(showBookmarksSidebarAction), keyEquivalent: "b", modifiers: [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Add Bookmark…", action: #selector(bookmarkPageAction), keyEquivalent: "d"))
        let addAllItem = makeMenuItem("Add Bookmarks for Open Tabs…", action: #selector(bookmarkAllTabsAction))
        addAllItem.isEnabled = (activeWindowController?.openTabCount ?? 0) > 0
        menu.addItem(addAllItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Add to Reading List", action: #selector(addToReadingListAction), keyEquivalent: "D", modifiers: [.command, .shift]))
        let addAllRLItem = makeMenuItem("Add Open Tabs to Reading List", action: #selector(addOpenTabsToReadingListAction))
        addAllRLItem.isEnabled = (activeWindowController?.openTabCount ?? 0) > 1
        menu.addItem(addAllRLItem)
        menu.addItem(.separator())

        let favorites = AssetLoader.shared.favorites()
        let favItem = makeMenuItem("Favorites", action: nil, symbol: "star")
        let favMenu = NSMenu(title: "Favorites")
        if favorites.isEmpty {
            let empty = NSMenuItem(title: "No Favorites", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            favMenu.addItem(empty)
        } else {
            for entry in favorites {
                let title = entry.title.count > 56 ? String(entry.title.prefix(55)) + "…" : entry.title
                let item = makeMenuItem(title, action: #selector(openMenuURLAction(_:)))
                item.representedObject = entry.url
                let icon = FaviconCache.shared.cachedImage(forURLString: entry.url) ?? menuIcon("globe")
                icon?.size = NSSize(width: 16, height: 16)
                item.image = icon
                favMenu.addItem(item)
            }
        }
        favItem.submenu = favMenu
        self.favoritesSubmenu = favMenu
        menu.addItem(favItem)

        for entry in favorites.prefix(12) {
            let title = entry.title.count > 56 ? String(entry.title.prefix(55)) + "…" : entry.title
            let item = makeMenuItem(title, action: #selector(openMenuURLAction(_:)))
            item.representedObject = entry.url
            let icon = FaviconCache.shared.cachedImage(forURLString: entry.url) ?? menuIcon("globe")
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === appMenuRef {
            if let host = activeWindowController?.activeHostDisplayName, !host.isEmpty {
                settingsForDomainMenuItem?.title = "Settings for \(host)…"
                settingsForDomainMenuItem?.isEnabled = true
            } else {
                settingsForDomainMenuItem?.title = "Settings for This Website…"
                settingsForDomainMenuItem?.isEnabled = false
            }
            return
        }

        if menu === viewMenuRef {
            let sidebarOpen = activeWindowController?.isSidebarCurrentlyOpen ?? false
            toggleSidebarMenuItem?.title = sidebarOpen ? "Hide Sidebar" : "Show Sidebar"
            let overviewOpen = activeWindowController?.isTabOverviewCurrentlyOpen ?? false
            toggleOverviewMenuItem?.title = overviewOpen ? "Hide Tab Overview" : "Show Tab Overview"
            return
        }

        if menu === tabLayoutSubmenu {
            menu.removeAllItems()
            let current = BrowserSettings.shared.tabLayout
            let layouts: [(id: String, title: String)] = [
                ("compact", "Compact"),
                ("separate", "Separate"),
                ("vertical", "Vertical")
            ]
            for layout in layouts {
                let item = makeMenuItem(layout.title, action: #selector(selectTabLayoutAction(_:)))
                item.representedObject = layout.id
                item.state = (current == layout.id) ? .on : .off
                menu.addItem(item)
            }
            return
        }

        if menu === textEncodingSubmenu {
            menu.removeAllItems()
            let currentIdx = BrowserSettings.shared.int(BrowserSettings.Key.defaultEncoding, default: 0)
            for (idx, name) in BrowserSettings.encodingNames.enumerated() {
                let item = makeMenuItem(name, action: #selector(selectTextEncodingAction(_:)), tag: idx)
                item.state = (idx == currentIdx) ? .on : .off
                menu.addItem(item)
            }
            return
        }

        if menu === historyMenuRef {
            populateHistoryMenu(menu)
            return
        }

        if menu === bookmarksMenuRef {
            populateBookmarksMenu(menu)
            return
        }

        if menu === windowMenuRef {
            let muted = activeWindowController?.isActiveTabMuted ?? false
            muteTabMenuItem?.title = muted ? "Unmute This Tab" : "Mute This Tab"
            muteTabMenuItem?.image = menuIcon(muted ? "speaker.wave.2" : "speaker.slash")
            let tabCount = activeWindowController?.openTabCount ?? 0
            muteOtherTabsMenuItem?.isEnabled = tabCount > 1
            moveTabToNewWindowMenuItem?.isEnabled = tabCount > 1
            return
        }

        if menu === importFromBrowserSubmenu {
            menu.removeAllItems()
            let browsers = BrowserDataImporter.shared.detectInstalledBrowsers()
            if browsers.isEmpty {
                let empty = NSMenuItem(title: "No Supported Browsers Installed", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for kind in browsers {
                let item = NSMenuItem(
                    title: "\(kind.rawValue)…",
                    action: #selector(importFromSpecificBrowserAction(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = kind.rawValue
                item.image = kind.appIcon(size: 16)
                menu.addItem(item)
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func newWindowAction() {
        let target = BrowserSettings.shared.resolvedNewWindowURL(activeTabURL: activeWindowController?.activeWebPageURLString.flatMap { URL(string: $0) })
        openNewWindow(url: target, isPrivate: false)
    }

    @objc private func newPrivateWindowAction() {
        openNewWindow(url: URL(string: "safarium://start"), isPrivate: true)
    }

    @objc private func closeWindowAction() {
        activeWindowController?.window?.performClose(nil)
    }

    @objc private func closeAllWindowsAction() {
        for wc in Array(windowControllers) {
            wc.window?.performClose(nil)
        }
    }

    @objc private func newTabAction() {
        if let ctrl = activeWindowController {
            let target = BrowserSettings.shared.resolvedNewTabURL(activeTabURL: ctrl.activeWebPageURLString.flatMap { URL(string: $0) })
            ctrl.createNewTab(url: target, activate: true)
        } else {
            let target = BrowserSettings.shared.resolvedNewWindowURL(activeTabURL: nil)
            openNewWindow(url: target, isPrivate: false)
        }
    }

    @objc private func reopenClosedTabAction() {
        activeWindowController?.reopenLastClosedTab()
    }

    @objc private func reopenSpecificClosedTabAction(_ sender: NSMenuItem) {
        activeWindowController?.reopenClosedTab(atReversedIndex: sender.tag)
    }

    @objc private func openFileAction() {
        let target = activeWindowController ?? openNewWindow()
        target?.openLocalFileDialog()
    }

    @objc private func focusAddressBarAction() {
        activeWindowController?.focusAddressBar()
    }

    @objc private func closeTabAction() {
        if let keyWin = NSApp.keyWindow,
           !windowControllers.contains(where: { $0.window === keyWin }) {
            keyWin.performClose(nil)
            return
        }
        activeWindowController?.closeActiveTab()
    }

    @objc private func sharePageAction() {
        activeWindowController?.shareActivePageFromMenu()
    }

    @objc private func exportAsPDFAction() {
        activeWindowController?.exportActiveTabAsPDF()
    }

    @objc private func printPageAction() {
        activeWindowController?.printActiveTab()
    }

    @objc private func toggleSidebarAction() {
        activeWindowController?.toggleSidebar()
    }

    @objc private func showBookmarksSidebarAction() {
        activeWindowController?.showBookmarksSidebar()
    }

    @objc private func showReadingListSidebarAction() {
        activeWindowController?.showReadingListSidebar()
    }

    @objc private func toggleTabOverviewAction() {
        activeWindowController?.toggleTabOverview()
    }

    @objc private func selectTabLayoutAction(_ sender: NSMenuItem) {
        guard let layoutID = sender.representedObject as? String else { return }
        BrowserSettings.shared.set(layoutID, forKey: BrowserSettings.Key.tabLayout)
    }

    @objc private func selectTextEncodingAction(_ sender: NSMenuItem) {
        BrowserSettings.shared.set(sender.tag, forKey: BrowserSettings.Key.defaultEncoding)
        activeWindowController?.reloadActiveTab()
    }

    @objc private func reloadAction() {
        activeWindowController?.reloadActiveTab()
    }

    @objc private func reloadIgnoringCacheAction() {
        activeWindowController?.reloadActiveTabIgnoringCache()
    }

    @objc private func copyPageURLAction() {
        activeWindowController?.copyCurrentPageURL()
    }

    @objc private func findOnPageAction() {
        activeWindowController?.showFindBar()
    }

    @objc private func findNextAction() {
        activeWindowController?.findNextMatch()
    }

    @objc private func findPreviousAction() {
        activeWindowController?.findPreviousMatch()
    }

    @objc private func toggleDownloadsAction() {
        activeWindowController?.toggleDownloadsPopover()
    }

    @objc private func goHomeAction() {
        activeWindowController?.goToHomepage()
    }

    @objc private func showStartPageAction() {
        activeWindowController?.showStartPageInActiveTab()
    }

    @objc private func bookmarkPageAction() {
        activeWindowController?.bookmarkCurrentPage()
    }

    @objc private func bookmarkAllTabsAction() {
        activeWindowController?.bookmarkAllOpenTabs()
    }

    @objc private func addToReadingListAction() {
        activeWindowController?.addCurrentPageToReadingList()
    }

    @objc private func addOpenTabsToReadingListAction() {
        activeWindowController?.addOpenTabsToReadingList()
    }

    @objc private func openMenuURLAction(_ sender: NSMenuItem) {
        guard let urlStr = sender.representedObject as? String,
              let url = URL(string: urlStr) else { return }
        let target = activeWindowController ?? openNewWindow()
        target?.openURLInActiveOrNewTab(url, newTab: false)
    }

    @objc private func openHistoryPageAction() {
        let target = activeWindowController ?? openNewWindow()
        target?.openHistoryPage()
    }

    @objc private func clearHistoryAction() {
        ClearHistorySheetController.present(over: activeWindowController?.window) { [weak self] range in
            AssetLoader.shared.clearHistory(range: range)
            self?.engine?.clearWebsiteData { _ in }
        }
    }

    @objc private func clearAllDataAction() {
        presentClearAllDataConfirmation(over: activeWindowController?.window)
    }

    func presentClearAllDataConfirmation(over hostWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clear All Data and Reset Profile?"
        alert.informativeText = "This permanently erases the entire Safarium profile—cookies, website data, browsing history, bookmarks, favorites, extensions, caches, and all settings—then relaunches Safarium cleanly. This cannot be undone."
        let clearBtn = alert.addButton(withTitle: "Clear All Data & Relaunch")
        if #available(macOS 11.0, *) {
            clearBtn.hasDestructiveAction = true
        }
        alert.addButton(withTitle: "Cancel")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.wipeEntireProfileAndRelaunch()
        }

        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func wipeEntireProfileAndRelaunch() {
        isWipingAllData = true

        // 1. Close all windows & shut down Chromium so all SQLite/LevelDB file handles release cleanly.
        privacyReportWindowController?.close()
        PrivacyReportStore.shared.closeForReset()
        settingsWindowController?.close()
        importWindowController?.close()
        let controllers = windowControllers
        windowControllers.removeAll()
        for wc in controllers {
            wc.window?.orderOut(nil)
            wc.close()
        }
        engine?.shutdown()
        engine = nil

        // 2. Wipe ~/Library/Application Support/Safarium and all Safarium caches.
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let appSupportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let cachesRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.safarium.browser"

        let dirsToDelete: [URL] = [
            appSupportRoot.appendingPathComponent("Safarium", isDirectory: true),
            cachesRoot.appendingPathComponent("Safarium", isDirectory: true),
            cachesRoot.appendingPathComponent(bundleID, isDirectory: true)
        ]
        for dir in dirsToDelete {
            if fm.fileExists(atPath: dir.path) {
                try? fm.removeItem(at: dir)
            }
        }

        // 3. Wipe UserDefaults persistent domain for Safarium so all preferences & favorites reset.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        CFPreferencesAppSynchronize(bundleID as CFString)

        // 4. Relaunch Safarium.app cleanly after exit and terminate immediately without rewriting state.
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 0.4; open -n \"$1\"", "_", bundlePath]
            try? task.run()
        }
        _exit(0)
    }

    @objc private func stopOrEscapeAction() {
        activeWindowController?.handleEscapeOrStop()
    }

    @objc private func zoomInAction() {
        activeWindowController?.zoomInActiveTab()
    }

    @objc private func zoomOutAction() {
        activeWindowController?.zoomOutActiveTab()
    }

    @objc private func zoomResetAction() {
        activeWindowController?.resetZoomActiveTab()
    }

    @objc private func customizeToolbarAction() {
        activeWindowController?.toggleCustomizeToolbarSheet()
    }

    @objc private func goBackAction() {
        activeWindowController?.navigateBack()
    }

    @objc private func goForwardAction() {
        activeWindowController?.navigateForward()
    }

    @objc private func previousTabAction() {
        activeWindowController?.cyclePreviousTab()
    }

    @objc private func nextTabAction() {
        activeWindowController?.cycleNextTab()
    }

    @objc private func duplicateTabAction() {
        activeWindowController?.duplicateActiveTab()
    }

    @objc private func moveTabToNewWindowAction() {
        activeWindowController?.moveActiveTabToNewWindow()
    }

    @objc private func arrangeTabsByTitleAction() {
        activeWindowController?.arrangeTabsByTitle()
    }

    @objc private func arrangeTabsByWebsiteAction() {
        activeWindowController?.arrangeTabsByWebsite()
    }

    @objc private func toggleMuteTabAction() {
        activeWindowController?.toggleMuteActiveTab()
    }

    @objc private func muteOtherTabsAction() {
        activeWindowController?.muteOtherTabs()
    }

    @objc private func selectTabByNumberAction(_ sender: NSMenuItem) {
        guard BrowserSettings.shared.cmdNumberSwitchesTabs else { return }
        activeWindowController?.selectTabShortcut(tag: sender.tag)
    }

    @objc private func showWebInspectorAction() {
        activeWindowController?.showDevToolsForActiveTab()
    }

    @objc private func showPageSourceAction() {
        activeWindowController?.viewSourceOfActiveTab()
    }

    @objc private func openSafariumInspectAction() {
        let target = activeWindowController ?? openNewWindow()
        target?.createNewTab(url: InspectPageURL.rootURL, activate: true)
    }

    @objc private func openSafariumRemoteDebuggingAction() {
        let target = activeWindowController ?? openNewWindow()
        target?.createNewTab(url: InspectPageURL.remoteDebuggingURL, activate: true)
    }

    func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func openServiceWorkersAction() {
        let target = activeWindowController ?? openNewWindow()
        target?.createNewTab(url: InspectPageSection.serviceWorkers.canonicalURL, activate: true)
    }

    @objc private func emptyCachesAction() {
        engine?.clearWebsiteData { _ in }
    }

    func showSettingsWindow(
        pane: SafariSettingsWindowController.Pane = .extensions,
        selectingExtensionID: String? = nil
    ) {
        guard let engine else { return }
        if settingsWindowController == nil {
            let vc = SafariSettingsWindowController(engine: engine, initialPane: pane)
            vc.onOpenChromeWebStore = { [weak self] in
                guard let self else { return }
                let target = self.activeWindowController ?? self.openNewWindow()
                target?.openChromeWebStore()
                target?.window?.makeKeyAndOrderFront(nil)
            }
            vc.onLoadUnpackedExtension = { [weak self] in
                guard let self else { return }
                let target = self.activeWindowController ?? self.openNewWindow()
                target?.promptLoadUnpackedExtension()
            }
            vc.onInstallCRXExtension = { [weak self] in
                guard let self else { return }
                let target = self.activeWindowController ?? self.openNewWindow()
                target?.promptInstallCRXExtension()
            }
            vc.onExtensionsChanged = { [weak self] in
                guard let self else { return }
                let exts = self.engine.installedExtensions()
                for wc in self.windowControllers {
                    wc.refreshExtensionsUI(exts)
                }
            }
            vc.activePageURLProvider = { [weak self] in
                guard let active = self?.activeWindowController, !active.isPrivate else { return nil }
                return active.activeWebPageURLString
            }
            vc.openWebsitesProvider = { [weak self] in
                guard let self else { return [] }
                var seen = Set<String>()
                var out: [(host: String, favicon: NSImage?)] = []
                for wc in self.windowControllers where !wc.isPrivate {
                    for entry in wc.openWebsitesSummary() where seen.insert(entry.host).inserted {
                        out.append(entry)
                    }
                }
                return out
            }
            vc.onOpenURL = { [weak self] url in
                guard let self else { return }
                let target = self.activeWindowController ?? self.openNewWindow()
                target?.createNewTab(url: url, activate: true)
                target?.window?.makeKeyAndOrderFront(nil)
            }
            vc.onOpenPrivacyReport = { [weak self] in
                self?.openPrivacyReportAction()
            }
            self.settingsWindowController = vc
        }
        settingsWindowController?.show(pane: pane, selectingExtensionID: selectingExtensionID)
    }

    @objc private func openSettingsAction() {
        showSettingsWindow(pane: .general)
    }

    @objc private func openPrivacySettingsAction() {
        showSettingsWindow(pane: .privacy)
    }

    @objc func openPrivacyReportAction() {
        if privacyReportWindowController == nil {
            let ctrl = PrivacyReportWindowController(store: .shared)
            ctrl.onOpenPrivacySettings = { [weak self] in
                self?.openPrivacySettingsAction()
            }
            ctrl.onClearReport = {
                PrivacyReportStore.shared.clearAll()
            }
            self.privacyReportWindowController = ctrl
        }
        privacyReportWindowController?.showReport()
    }

    @objc private func openWebsiteSettingsAction() {
        showSettingsWindow(pane: .websites)
    }

    @objc private func openProfilesSettingsAction() {
        showSettingsWindow(pane: .profiles)
    }

    @objc private func openAutoFillSettingsAction() {
        showSettingsWindow(pane: .autoFill)
    }

    @objc private func openDeveloperSettingsAction() {
        showSettingsWindow(pane: .developer)
    }

    @objc private func openChromeWebStoreAction() {
        activeWindowController?.openChromeWebStore()
    }

    @objc private func manageExtensionsAction() {
        showSettingsWindow(pane: .extensions)
    }

    @objc private func loadUnpackedExtensionAction() {
        activeWindowController?.promptLoadUnpackedExtension()
    }

    @objc private func installCRXExtensionAction() {
        activeWindowController?.promptInstallCRXExtension()
    }

    @objc private func importFromSpecificBrowserAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let browser = SupportedBrowserKind(rawValue: raw) else { return }
        presentImportSheet(for: browser)
    }

    @objc private func importFromFileOrFolderAction() {
        let panel = NSOpenPanel()
        panel.title = "Import Browsing Data"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.html]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let parsed = BrowserDataImporter.shared.parseNetscapeBookmarksHTML(at: url)
            _ = AssetLoader.shared.mergeImportedFavorites(parsed, prepend: true)
        }
        if let win = activeWindowController?.window {
            panel.beginSheetModal(for: win, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Serializes bookmarks as a Netscape bookmark file (the format Chrome/Safari/Firefox import).
    /// Titles escape `&`, `<`, `>`; HREF values escape `&` and `"`.
    static func netscapeBookmarksHTML(for entries: [AssetLoader.BookmarkEntry]) -> String {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Safarium Bookmarks</TITLE>",
            "<H1>Safarium Bookmarks</H1>",
            "<DL><p>"
        ]
        for entry in entries {
            let escTitle = entry.title
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let escURL = entry.url
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            lines.append("    <DT><A HREF=\"\(escURL)\">\(escTitle)</A>")
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n")
    }

    @objc private func exportBookmarksHTMLAction() {
        let panel = NSSavePanel()
        panel.title = "Export Safarium Bookmarks"
        panel.nameFieldStringValue = "Safarium Bookmarks.html"
        panel.allowedContentTypes = [.html]
        let writeHTML: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let html = Self.netscapeBookmarksHTML(for: AssetLoader.shared.favorites())
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
        if let win = activeWindowController?.window {
            panel.beginSheetModal(for: win, completionHandler: writeHTML)
        } else {
            writeHTML(panel.runModal())
        }
    }

    func presentImportSheet(for browser: SupportedBrowserKind) {
        guard let engine else { return }
        let ctrl = ImportDataWindowController(engine: engine, browser: browser)
        importWindowController = ctrl
        ctrl.presentSheet(on: activeWindowController?.window)
    }
}
