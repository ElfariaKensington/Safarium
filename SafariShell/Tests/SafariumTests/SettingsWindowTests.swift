import XCTest
import AppKit
@testable import Safarium

/// Unit tests for `SafariSettingsWindowController`: pane/category metadata, every pane's construction at several
/// widths, preference round-trips through `BrowserSettings`, website-policy host selection, profile seeding,
/// and extension manifest parsing (`ExtensionManifestMetadata`) against real temp fixtures.
@MainActor
final class SettingsWindowTests: HermeticTestCase {
    private typealias Pane = SafariSettingsWindowController.Pane

    private var savedDefaults: [String: Any] = [:]
    private var controller: SafariSettingsWindowController!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            savedDefaults = UIDefaultsSandbox.snapshot()
            UIDefaultsSandbox.clear()
            controller = SafariSettingsWindowController(engine: MockBrowserEngine())
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            controller?.close()
            controller = nil
            UIDefaultsSandbox.restore(savedDefaults)
        }
        super.tearDown()
    }

    private var contentRoot: NSView { controller.window!.contentView! }

    private func popup(titledFirstItem title: String) -> NSPopUpButton? {
        uiDescendants(of: contentRoot, as: NSPopUpButton.self).first { $0.itemTitle(at: 0) == title }
    }

    private func button(titled title: String) -> NSButton? {
        uiDescendants(of: contentRoot, as: NSButton.self).first { $0.title == title }
    }

    // MARK: - Pane metadata

    func testEveryPaneHasUniqueStableToolbarIdentifier() {
        let ids = Pane.allCases.map { $0.toolbarID.rawValue }
        XCTAssertEqual(Set(ids).count, Pane.allCases.count)
        XCTAssertEqual(Pane.allCases.count, 11)
        for pane in Pane.allCases {
            XCTAssertEqual(pane.toolbarID.rawValue, "com.safarium.settings.\(pane.rawValue)")
        }
    }

    func testPaneSymbolNamesAreNonEmptyAndUnique() {
        let symbols = Pane.allCases.map(\.symbolName)
        XCTAssertTrue(symbols.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertEqual(Pane.general.symbolName, "gearshape")
        XCTAssertEqual(Pane.developer.symbolName, "wrench.and.screwdriver")
    }

    func testPanePreferredHeightsMatchTable() {
        let expected: [Pane: CGFloat] = [
            .general: 468, .tabs: 444, .autoFill: 206, .search: 318, .security: 256, .privacy: 384,
            .websites: 456, .profiles: 296, .extensions: 468, .advanced: 436, .developer: 238
        ]
        for pane in Pane.allCases {
            XCTAssertEqual(pane.preferredContentHeight, expected[pane], "height for \(pane)")
            XCTAssertGreaterThan(pane.preferredContentHeight, 0)
        }
    }

    func testPaneRawValuesRoundTripThroughInit() {
        for pane in Pane.allCases {
            XCTAssertEqual(Pane(rawValue: pane.rawValue), pane)
        }
        XCTAssertNil(Pane(rawValue: "Nope"))
    }

    // MARK: - Website categories

    func testEveryWebsiteCategoryHasPromptSymbolColorAndOptions() {
        for category in SafariSettingsWindowController.WebsiteCategory.allCases {
            XCTAssertFalse(category.policyPrompt.isEmpty, "\(category)")
            XCTAssertFalse(category.symbolName.isEmpty, "\(category)")
            XCTAssertFalse(category.options.isEmpty, "\(category)")
            XCTAssertTrue(category.options.allSatisfy { !$0.isEmpty }, "\(category)")
            XCTAssertTrue(category.options.indices.contains(category.defaultOptionIndex), "\(category)")
            XCTAssertGreaterThan(category.badgeColor.alphaComponent, 0.99)
        }
        XCTAssertEqual(SafariSettingsWindowController.WebsiteCategory.allCases.count, 11)
    }

    func testWebsiteCategoryRawValuesAreUnique() {
        let raws = SafariSettingsWindowController.WebsiteCategory.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }

    func testWebsiteCategoryOptionsAndDefaultsMatchPolicy() {
        typealias Cat = SafariSettingsWindowController.WebsiteCategory
        XCTAssertEqual(Cat.contentBlockers.options, ["On", "Off"])
        XCTAssertEqual(Cat.contentBlockers.defaultOptionIndex, 0)
        XCTAssertEqual(Cat.autoPlay.options, ["Allow All Auto-Play", "Stop Media with Sound", "Never Auto-Play"])
        XCTAssertEqual(Cat.autoPlay.defaultOptionIndex, 1)
        XCTAssertEqual(Cat.popups.options, ["Block and Notify", "Block", "Allow"])
        XCTAssertEqual(Cat.popups.defaultOptionIndex, 0)
        XCTAssertEqual(Cat.extensionAccess.options, ["Allow", "Ask", "Deny"])
        XCTAssertEqual(Cat.extensionAccess.defaultOptionIndex, 0)
        for permission in [Cat.camera, .microphone, .screenSharing, .location, .downloads, .notifications] {
            XCTAssertEqual(permission.options, ["Ask", "Deny", "Allow"], "\(permission)")
            XCTAssertEqual(permission.defaultOptionIndex, 0, "\(permission)")
        }
    }

    func testPageZoomCategoryMatchesEngineZoomLevels() {
        let cat = SafariSettingsWindowController.WebsiteCategory.pageZoom
        XCTAssertEqual(cat.options.count, BrowserSettings.pageZoomValues.count)
        for (index, value) in BrowserSettings.pageZoomValues.enumerated() {
            XCTAssertEqual(cat.options[index], "\(Int((value * 100).rounded()))%", "index \(index)")
        }
        XCTAssertEqual(cat.options[cat.defaultOptionIndex], "100%")
    }

    // MARK: - Private helpers exposed for testing

    func testIsUnpackedLocalExtensionClassifiesInstallSources() {
        XCTAssertFalse(controller.isUnpackedLocalExtension(uiExtension("a", storeID: "abcdefghijklmnop", installPath: "/x/y")))
        XCTAssertFalse(controller.isUnpackedLocalExtension(uiExtension("b", installPath: "/Users/u/Library/cws-abc123")))
        XCTAssertFalse(controller.isUnpackedLocalExtension(uiExtension("c", installPath: "/Users/u/Library/CRX-Extract/x")))
        XCTAssertTrue(controller.isUnpackedLocalExtension(uiExtension("d", installPath: "/Users/u/dev/my-extension")))
        XCTAssertTrue(controller.isUnpackedLocalExtension(uiExtension("e", storeID: "", installPath: "/Users/u/dev/ext")))
    }

    func testPrefBoolAndIntReturnDefaultsWhenMissingAndStoredValuesWhenPresent() {
        let key = "Safarium.Test.UISuite.Flag"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertTrue(controller.prefBool(key, default: true))
        XCTAssertFalse(controller.prefBool(key, default: false))
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(controller.prefBool(key, default: true), "stored false must win over default true")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(controller.prefBool(key, default: false))

        let intKey = "Safarium.Test.UISuite.Count"
        defer { UserDefaults.standard.removeObject(forKey: intKey) }
        XCTAssertEqual(controller.prefInt(intKey, default: 7), 7)
        UserDefaults.standard.set(0, forKey: intKey)
        XCTAssertEqual(controller.prefInt(intKey, default: 7), 0, "stored zero must win over default")
        UserDefaults.standard.set(-3, forKey: intKey)
        XCTAssertEqual(controller.prefInt(intKey, default: 7), -3)
    }

    // MARK: - Pane construction

    func testEveryPaneBuildsAtSeveralWindowWidths() {
        let widths: [CGFloat] = [480, 820, 1100]
        for pane in Pane.allCases {
            controller.selectPane(pane, animated: false)
            XCTAssertEqual(controller.window?.title, pane.rawValue)
            for width in widths {
                controller.window?.setContentSize(NSSize(width: width, height: pane.preferredContentHeight))
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                let root = contentRoot
                XCTAssertFalse(root.subviews.isEmpty, "\(pane) has no content")
                for view in uiDescendants(of: root, as: NSView.self) {
                    let f = view.frame
                    XCTAssertFalse(f.origin.x.isNaN || f.origin.y.isNaN || f.size.width.isNaN || f.size.height.isNaN,
                                   "\(pane) @\(width): NaN frame in \(type(of: view))")
                    XCTAssertGreaterThanOrEqual(f.size.width, 0, "\(pane) @\(width): negative width")
                    XCTAssertGreaterThanOrEqual(f.size.height, 0, "\(pane) @\(width): negative height")
                }
            }
        }
    }

    func testEveryPaneRebuildsWithoutLeakingPreviousPaneContent() {
        controller.selectPane(.general, animated: false)
        XCTAssertTrue(uiAllStrings(in: contentRoot).contains("Safarium opens with:"))
        controller.selectPane(.security, animated: false)
        XCTAssertFalse(uiAllStrings(in: contentRoot).contains("Safarium opens with:"))
        controller.selectPane(.general, animated: false)
        XCTAssertTrue(uiAllStrings(in: contentRoot).contains("Safarium opens with:"))
    }

    func testExtensionsPaneWithNoInstalledExtensionsBuilds() {
        controller.selectPane(.extensions, animated: false)
        controller.reloadExtensions(selectID: nil)
        XCTAssertEqual(controller.window?.title, "Extensions")
        XCTAssertFalse(contentRoot.subviews.isEmpty)
    }

    // MARK: - Preference round-trips

    func testOpensWithPopupWritesPreferenceAndReadsBack() throws {
        controller.selectPane(.general, animated: false)
        let pop = try XCTUnwrap(popup(titledFirstItem: "All windows from last session"))
        pop.selectItem(at: 2)
        _ = pop.sendAction(pop.action, to: pop.target)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "Safarium.Pref.OpensWith"), 2)
        XCTAssertEqual(BrowserSettings.shared.opensWithIndex, 2)
    }

    func testHomepageFieldCommitsTrimmedValue() throws {
        controller.selectPane(.general, animated: false)
        let field = try XCTUnwrap(uiDescendants(of: contentRoot, as: NSTextField.self).first { $0.placeholderString == "https://example.com" })
        field.stringValue = "   https://home.example/start  \n"
        _ = field.sendAction(field.action, to: field.target)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "Safarium.Pref.Homepage"), "https://home.example/start")
    }

    func testSetHomepageToCurrentPageUsesActivePageProvider() {
        controller.selectPane(.general, animated: false)
        controller.activePageURLProvider = { "https://current.example/page" }
        _ = controller.perform(NSSelectorFromString("setHomepageToCurrentPage"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "Safarium.Pref.Homepage"), "https://current.example/page")
    }

    func testOpenSafeFilesCheckboxTogglesPreference() throws {
        controller.selectPane(.general, animated: false)
        let box = try XCTUnwrap(button(titled: "Open “safe” files after downloading"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "Safarium.Pref.OpenSafeFiles"))
        box.performClick(nil)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "Safarium.Pref.OpenSafeFiles"), true)
        box.performClick(nil)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "Safarium.Pref.OpenSafeFiles"), false)
    }

    func testSecurityPaneHTTPSOnlyCheckboxTogglesPreference() throws {
        controller.selectPane(.security, animated: false)
        let box = try XCTUnwrap(button(titled: "Automatically upgrade connections to HTTPS"))
        XCTAssertEqual(box.state, .on)
        XCTAssertTrue(BrowserSettings.shared.httpsOnlyMode)
        box.performClick(nil)
        XCTAssertFalse(BrowserSettings.shared.httpsOnlyMode)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: BrowserSettings.Key.httpsOnlyMode), false)
        box.performClick(nil)
        XCTAssertTrue(BrowserSettings.shared.httpsOnlyMode)
    }

    func testPrivacyPaneControlsAndOpenPrivacyReportCallback() throws {
        controller.selectPane(.privacy, animated: false)
        let strings = uiAllStrings(in: contentRoot)
        XCTAssertTrue(strings.contains("Prevent cross-site tracking"))
        XCTAssertTrue(strings.contains("Protection level:"))
        XCTAssertTrue(strings.contains("Manage Website Data…"))
        XCTAssertTrue(strings.contains("Clear All Data…"))
        XCTAssertTrue(strings.contains("Require Touch ID to view locked tabs"))
        XCTAssertTrue(strings.contains("Advanced Settings"))

        let levelPop = try XCTUnwrap(popup(titledFirstItem: "Standard (Recommended)"))
        XCTAssertEqual(levelPop.itemTitles, ["Standard (Recommended)", "Strict"])
        levelPop.selectItem(at: 1)
        _ = levelPop.sendAction(levelPop.action, to: levelPop.target)
        XCTAssertEqual(BrowserSettings.shared.privacyProtectionLevel, .strict)

        let stripBox = try XCTUnwrap(button(titled: "Strip tracking parameters from links"))
        XCTAssertEqual(stripBox.state, .on)
        stripBox.performClick(nil)
        XCTAssertFalse(BrowserSettings.shared.stripTrackingParams)

        let refBox = try XCTUnwrap(button(titled: "Trim cross-origin referrers"))
        XCTAssertEqual(refBox.state, .on)
        refBox.performClick(nil)
        XCTAssertFalse(BrowserSettings.shared.referrerTrimming)

        let webrtcBox = try XCTUnwrap(button(titled: "Protect local IP address from WebRTC leaks"))
        XCTAssertEqual(webrtcBox.state, .on)
        webrtcBox.performClick(nil)
        XCTAssertFalse(BrowserSettings.shared.webrtcIPProtection)

        var openedReport = false
        controller.onOpenPrivacyReport = { openedReport = true }
        let reportBtn = try XCTUnwrap(button(titled: "View Privacy Report…"))
        reportBtn.performClick(nil)
        XCTAssertTrue(openedReport)
    }

    // MARK: - Website policy host selection

    func testWebsitesPaneListsConfiguredHostsForSelectedCategory() {
        BrowserSettings.shared.setWebsitePolicy(category: "Auto-Play", host: "alpha.example", index: 2)
        BrowserSettings.shared.setWebsitePolicy(category: "Auto-Play", host: "beta.example", index: 0)
        BrowserSettings.shared.setWebsitePolicy(category: "Camera", host: "camera-only.example", index: 1)
        controller.selectedWebsiteCategory = .autoPlay
        controller.selectPane(.websites, animated: false)
        let strings = uiAllStrings(in: contentRoot)
        XCTAssertTrue(strings.contains("alpha.example"))
        XCTAssertTrue(strings.contains("beta.example"))
        XCTAssertFalse(strings.contains("camera-only.example"), "hosts of other categories must not be listed")
    }

    func testRemoveSelectedSiteRuleDeletesOnlyThatHostPolicy() {
        BrowserSettings.shared.setWebsitePolicy(category: "Auto-Play", host: "remove-me.example", index: 2)
        BrowserSettings.shared.setWebsitePolicy(category: "Auto-Play", host: "keep-me.example", index: 0)
        controller.selectedWebsiteCategory = .autoPlay
        controller.selectedWebsiteHost = "remove-me.example"
        controller.selectPane(.websites, animated: false)

        _ = controller.perform(NSSelectorFromString("removeSelectedSiteRule"))

        XCTAssertNil(controller.selectedWebsiteHost)
        let hosts = BrowserSettings.shared.configuredHosts(for: "Auto-Play")
        XCTAssertEqual(hosts, ["keep-me.example"])
    }

    func testRemoveSelectedSiteRuleWithoutSelectionIsNoOp() {
        BrowserSettings.shared.setWebsitePolicy(category: "Auto-Play", host: "stay.example", index: 2)
        controller.selectedWebsiteCategory = .autoPlay
        controller.selectedWebsiteHost = nil
        controller.selectPane(.websites, animated: false)
        _ = controller.perform(NSSelectorFromString("removeSelectedSiteRule"))
        XCTAssertEqual(BrowserSettings.shared.configuredHosts(for: "Auto-Play"), ["stay.example"])
    }

    func testOpenWebsiteSettingsFromExtensionsSwitchesCategoryAndClearsStaleHost() {
        controller.selectedWebsiteCategory = .autoPlay
        controller.selectedWebsiteHost = "stale.example"
        _ = controller.perform(NSSelectorFromString("openWebsitesSettings"))
        XCTAssertEqual(controller.selectedWebsiteCategory, .extensionAccess)
        XCTAssertNil(controller.selectedWebsiteHost, "a host selected in another category must not survive")
        XCTAssertEqual(controller.window?.title, "Websites")
    }

    func testOpenWebsitesWithoutPerHostRuleInheritGlobalDefaultPolicy() throws {
        BrowserSettings.shared.setWebsiteDefaultPolicy(category: "Content Blockers", index: 1) // Off
        BrowserSettings.shared.setWebsitePolicy(category: "Content Blockers", host: "override.example", index: 0) // On
        controller.openWebsitesProvider = {
            [
                (host: "unconfigured.example", favicon: nil),
                (host: "override.example", favicon: nil)
            ]
        }
        controller.selectedWebsiteCategory = .contentBlockers
        controller.selectPane(.websites, animated: false)

        let popups = uiDescendants(of: contentRoot, as: NSPopUpButton.self).filter { $0.itemTitles == ["On", "Off"] }
        // First two rows in the right-hand list are unconfigured.example and override.example; the bottom-right popup is global default.
        XCTAssertGreaterThanOrEqual(popups.count, 3)
        XCTAssertEqual(popups[0].indexOfSelectedItem, 1, "open website without per-host override must inherit global Off default")
        XCTAssertEqual(popups[1].indexOfSelectedItem, 0, "open website with per-host override must keep On")
        XCTAssertEqual(popups.last?.indexOfSelectedItem, 1, "global default popup reflects Off")
    }

    // MARK: - Profiles

    func testEnableProfilesSeedsDefaultNamesWhenNoneStored() {
        _ = controller.perform(NSSelectorFromString("enableProfilesClicked"))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "Safarium.Pref.ProfilesEnabled"))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "Safarium.Pref.ProfileNames"), ["Personal", "Work"])
        XCTAssertEqual(controller.window?.title, "Profiles")
    }

    func testEnableProfilesKeepsExistingNames() {
        UserDefaults.standard.set(["Solo"], forKey: "Safarium.Pref.ProfileNames")
        _ = controller.perform(NSSelectorFromString("enableProfilesClicked"))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "Safarium.Pref.ProfileNames"), ["Solo"])
    }

    // MARK: - Extension manifest metadata

    private let fallbackHeadline = "This extension has limited webpage access."

    func testManifestMissingOrEmptyPathReturnsFallback() {
        for path in ["", "/definitely/not/here/\(UUID().uuidString)"] {
            let meta = ExtensionManifestMetadata.parse(fromInstallPath: path)
            XCTAssertNil(meta.author)
            XCTAssertFalse(meta.hasBroadWebAccess)
            XCTAssertEqual(meta.permissionHeadline, fallbackHeadline)
            XCTAssertEqual(meta.shortScopeLabel, "When clicked")
            XCTAssertTrue(meta.shortcuts.isEmpty)
        }
    }

    func testManifestMalformedJSONReturnsFallback() throws {
        let dir = try uiWriteExtensionFixture(["manifest.json": "{ this is not json"])
        let meta = ExtensionManifestMetadata.parse(fromInstallPath: dir)
        XCTAssertFalse(meta.hasBroadWebAccess)
        XCTAssertEqual(meta.permissionHeadline, fallbackHeadline)
    }

    func testManifestAuthorStringAndEmailObject() throws {
        let plain = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "author": "  Ada Lovelace  "]])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: plain).author, "Ada Lovelace")

        let emailDict = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "author": ["email": "dev@example.org"]]])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: emailDict).author, "dev@example.org")

        let blank = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "author": "   "]])
        XCTAssertNil(ExtensionManifestMetadata.parse(fromInstallPath: blank).author)
    }

    func testManifestAuthorResolvesLocalizedMessageAndKeepsUnknownKeys() throws {
        let dir = try uiWriteExtensionFixture([
            "manifest.json": ["name": "x", "default_locale": "en", "author": "__MSG_appAuthor__"],
            "_locales/en/messages.json": ["appAuthor": ["message": "Grace Hopper"]]
        ])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: dir).author, "Grace Hopper")

        let unknown = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "author": "__MSG_missing__"]])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: unknown).author, "__MSG_missing__")
    }

    func testManifestLocalizationFallsBackToEnUSWhenDefaultLocaleMissing() throws {
        let dir = try uiWriteExtensionFixture([
            "manifest.json": ["name": "x", "default_locale": "fr", "author": "__MSG_who__"],
            "_locales/en_US/messages.json": ["who": ["message": "Linus"]]
        ])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: dir).author, "Linus")
    }

    func testManifestAllUrlsIsBroadAndLabelledAllWebsites() throws {
        let dir = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "permissions": ["<all_urls>"]]])
        let meta = ExtensionManifestMetadata.parse(fromInstallPath: dir)
        XCTAssertTrue(meta.hasBroadWebAccess)
        XCTAssertEqual(meta.shortScopeLabel, "All Websites (Allow)")
        XCTAssertTrue(meta.permissionHeadline.contains("all websites"))
    }

    func testManifestWildcardSchemeInContentScriptCountsAsAllUrls() throws {
        let dir = try uiWriteExtensionFixture(["manifest.json": [
            "name": "x",
            "content_scripts": [["matches": ["*://*/*"], "js": ["a.js"]]]
        ]])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: dir).shortScopeLabel, "All Websites (Allow)")
    }

    func testManifestHostPermissionsAreDedupedSortedAndCounted() throws {
        let dir = try uiWriteExtensionFixture(["manifest.json": [
            "name": "x",
            "host_permissions": ["https://b.example/*", "https://*.a.example/*", "https://a.example/*"],
            "content_scripts": [["matches": ["https://a.example/*"], "js": ["a.js"]]]
        ]])
        let meta = ExtensionManifestMetadata.parse(fromInstallPath: dir)
        XCTAssertTrue(meta.hasBroadWebAccess)
        XCTAssertEqual(meta.shortScopeLabel, "2 Website(s)")
        XCTAssertEqual(meta.permissionHeadline, "This extension can read and alter webpages on a.example, b.example.")
    }

    func testManifestMoreThanThreeDomainsAreSummarised() throws {
        let hosts = ["https://a.one/*", "https://b.two/*", "https://c.three/*", "https://d.four/*", "https://e.five/*"]
        let dir = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "host_permissions": hosts]])
        let meta = ExtensionManifestMetadata.parse(fromInstallPath: dir)
        XCTAssertEqual(meta.shortScopeLabel, "5 Website(s)")
        XCTAssertEqual(meta.permissionHeadline, "This extension can read and alter webpages on a.one, b.two, c.three and 2 more.")
    }

    func testManifestTabsAndScriptingPermissionsGiveActiveTabScope() throws {
        let tabs = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "permissions": ["tabs"]]])
        let tabsMeta = ExtensionManifestMetadata.parse(fromInstallPath: tabs)
        XCTAssertTrue(tabsMeta.hasBroadWebAccess)
        XCTAssertEqual(tabsMeta.shortScopeLabel, "Active Tab")

        let scripting = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "permissions": ["scripting"]]])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: scripting).shortScopeLabel, "Active Tab")
    }

    func testManifestWithoutBroadPermissionsIsNotBroad() throws {
        let dir = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "permissions": ["storage", "alarms"]]])
        let meta = ExtensionManifestMetadata.parse(fromInstallPath: dir)
        XCTAssertFalse(meta.hasBroadWebAccess)
        XCTAssertEqual(meta.shortScopeLabel, "When Clicked")
        XCTAssertEqual(meta.permissionHeadline, "This extension does not require broad access to your webpages.")
    }

    func testManifestShortcutsAreSortedFormattedAndUseFallbackDescriptions() throws {
        let dir = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "commands": [
            "zoom": ["suggested_key": ["mac": "Command+Shift+Y"], "description": "Zoom it"],
            "_execute_action": ["suggested_key": ["default": "Ctrl+Shift+E"]],
            "no_key_command": ["description": "Never bound"]
        ]]])
        let items = ExtensionManifestMetadata.parse(fromInstallPath: dir).shortcuts
        XCTAssertEqual(items.map(\.commandName), ["_execute_action", "zoom"], "commands without a key are omitted")
        XCTAssertEqual(items[0].descriptionText, "Open extension popup")
        XCTAssertEqual(items[0].formattedShortcut, "⌃⇧E")
        XCTAssertEqual(items[1].descriptionText, "Zoom it")
        XCTAssertEqual(items[1].formattedShortcut, "⌘⇧Y")
    }

    func testManifestShortcutFallbackDescriptionIsTitleCasedCommandName() throws {
        let dir = try uiWriteExtensionFixture(["manifest.json": ["name": "x", "commands": [
            "toggle_dark_mode": ["suggested_key": ["mac": "Alt+D"]]
        ]]])
        let item = try XCTUnwrap(ExtensionManifestMetadata.parse(fromInstallPath: dir).shortcuts.first)
        XCTAssertEqual(item.descriptionText, "Toggle Dark Mode")
        XCTAssertEqual(item.formattedShortcut, "⌥D")
    }

    func testManifestLocalizedShortcutDescriptionResolves() throws {
        let dir = try uiWriteExtensionFixture([
            "manifest.json": ["name": "x", "default_locale": "en", "commands": [
                "go": ["suggested_key": ["mac": "Command+G"], "description": "__MSG_goDesc__"]
            ]],
            "_locales/en/messages.json": ["goDesc": ["message": "Go somewhere"]]
        ])
        XCTAssertEqual(ExtensionManifestMetadata.parse(fromInstallPath: dir).shortcuts.first?.descriptionText, "Go somewhere")
    }

    func testFormatMacShortcutOrdersModifiersAsWritten() {
        XCTAssertEqual(ExtensionManifestMetadata.formatMacShortcut("Ctrl+Alt+Shift+Command+K"), "⌃⌥⇧⌘K")
        XCTAssertEqual(ExtensionManifestMetadata.formatMacShortcut("cmd+k"), "⌘K")
        XCTAssertEqual(ExtensionManifestMetadata.formatMacShortcut(" Option + j "), "⌥J")
        XCTAssertEqual(ExtensionManifestMetadata.formatMacShortcut(""), "")
    }

    func testFormatMacShortcutMapsMacCtrlToControlGlyph() {
        // BUG SET-1: Chrome's "MacCtrl" names the Control key on macOS, but the switch maps it to Command (⌘).
        XCTAssertEqual(ExtensionManifestMetadata.formatMacShortcut("MacCtrl+Shift+K"), "⌃⇧K")
    
    }

    func testExtractHostLabelHandlesWildcardsPortsAndPlaceholders() {
        XCTAssertEqual(ExtensionManifestMetadata.extractHostLabel("https://*.example.com/*"), "example.com")
        XCTAssertEqual(ExtensionManifestMetadata.extractHostLabel("http://localhost:8080/x"), "localhost:8080")
        XCTAssertNil(ExtensionManifestMetadata.extractHostLabel("*://*/*"), "a bare wildcard host has no label")
        XCTAssertNil(ExtensionManifestMetadata.extractHostLabel("<all_urls>"), "patterns without a scheme have no label")
        XCTAssertNil(ExtensionManifestMetadata.extractHostLabel("https://"))
    }
}
