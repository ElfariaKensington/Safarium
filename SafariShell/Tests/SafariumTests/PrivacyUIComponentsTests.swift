import XCTest
import AppKit
@testable import Safarium

/// Hermetic unit tests for `PrivacyReportWindowController`, `PrivacyPopoverController` /
/// `PrivacyPopoverViewController`, and `WebsiteDataSheetController`.
/// No window or popover is ever ordered on screen.
@MainActor
final class PrivacyUIComponentsTests: HermeticTestCase {
    private var tempDBURL: URL!
    private var store: PrivacyReportStore!

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            tempDBURL = HermeticTestCase.sandboxRoot
                .appendingPathComponent("privacy-ui-tests-\(UUID().uuidString).sqlite")
            store = PrivacyReportStore(databaseURL: tempDBURL, retentionDays: 30, debounceNotifications: false)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            store = nil
            if let tempDBURL {
                try? FileManager.default.removeItem(at: tempDBURL)
            }
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func seedSampleStore() {
        store.recordPageVisit(host: "nytimes.com", isPrivate: false)
        store.recordPageVisit(host: "theverge.com", isPrivate: false)
        store.recordPageVisit(host: "apple.com", isPrivate: false)

        store.record(PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: "nytimes.com",
            trackerHost: "pagead2.googlesyndication.com",
            entityDomain: "doubleclick.net",
            ownerName: "Google",
            category: .advertising,
            count: 4
        ))
        store.record(PrivacyEvent(
            eventType: .cookieBlocked,
            pageHost: "nytimes.com",
            trackerHost: "pixel.facebook.com",
            entityDomain: "facebook.com",
            ownerName: "Meta",
            category: .social,
            count: 2
        ))
        store.record(PrivacyEvent(
            eventType: .trackerBlocked,
            pageHost: "theverge.com",
            trackerHost: "securepubads.g.doubleclick.net",
            entityDomain: "doubleclick.net",
            ownerName: "Google",
            category: .advertising,
            count: 3
        ))
        store.record(PrivacyEvent(
            eventType: .httpsUpgraded,
            pageHost: "apple.com",
            detail: "http->https",
            count: 1
        ))
        store.record(PrivacyEvent(
            eventType: .httpsUpgraded,
            pageHost: "theverge.com",
            detail: "http->https",
            count: 1
        ))
        store.record(PrivacyEvent(
            eventType: .trackingParamStripped,
            pageHost: "nytimes.com",
            detail: "fbclid,utm_source",
            count: 2
        ))
        store.record(PrivacyEvent(
            eventType: .fingerprintBlocked,
            pageHost: "theverge.com",
            trackerHost: "fp.example.net",
            entityDomain: "fingerprintjs.com",
            ownerName: "Fingerprint",
            category: .fingerprinting,
            detail: "canvas",
            count: 1
        ))
        store.flushSync()
    }

    private func assertValidLayout(in root: NSView, maxWidth: CGFloat? = nil) {
        root.layoutSubtreeIfNeeded()
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            let f = v.frame
            XCTAssertTrue(f.origin.x.isFinite && f.origin.y.isFinite, "non-finite origin on \(type(of: v))")
            XCTAssertTrue(f.size.width.isFinite && f.size.height.isFinite, "non-finite size on \(type(of: v))")
            XCTAssertGreaterThanOrEqual(f.size.width, 0, "negative width on \(type(of: v))")
            XCTAssertGreaterThanOrEqual(f.size.height, 0, "negative height on \(type(of: v))")
            if let maxWidth, v === root {
                XCTAssertLessThanOrEqual(f.size.width, maxWidth + 0.5)
            }
            stack.append(contentsOf: v.subviews)
        }
    }

    // MARK: - PrivacyReportWindowController

    func testPrivacyReportEmptyStateAndMetrics() {
        let wc = PrivacyReportWindowController(store: store)
        defer { wc.close() }
        let root = wc.window!.contentView!
        let texts = uiAllStrings(in: root)

        XCTAssertTrue(texts.contains("Privacy Report"))
        XCTAssertTrue(texts.contains("Last 30 Days"))
        XCTAssertTrue(texts.contains("No Trackers Prevented Yet"))
        XCTAssertTrue(texts.contains("0 requests blocked"))
        XCTAssertTrue(texts.contains("0%"))
    }

    func testPrivacyReportPopulatedSummaryModeSwitchingAndSearch() {
        seedSampleStore()
        let wc = PrivacyReportWindowController(store: store)
        defer { wc.close() }
        let root = wc.window!.contentView!

        var texts = uiAllStrings(in: root)
        XCTAssertTrue(texts.contains("3"), "3 unique trackers prevented")
        XCTAssertTrue(texts.contains("10 requests blocked"), "4 + 2 + 3 + 1 = 10 requests blocked")
        XCTAssertTrue(texts.contains("67%"), "2 of 3 sites = 67%")
        XCTAssertTrue(texts.contains("2 of 3 sites"))
        XCTAssertTrue(texts.contains("2 upgrades · 2 links"))
        XCTAssertTrue(texts.contains("1 probes · 2 cookies"))
        XCTAssertTrue(texts.contains(where: { $0.contains("Most contacted tracker: doubleclick.net (Google)") && $0.contains("2 websites") }))
        XCTAssertFalse(texts.contains(where: { $0.contains("website(s)") }))

        // Websites mode shows nytimes.com, theverge.com, and apple.com (HTTPS upgrade only)
        XCTAssertTrue(texts.contains("nytimes.com"))
        XCTAssertTrue(texts.contains("theverge.com"))
        XCTAssertTrue(texts.contains("apple.com"))

        // Select second website updates detail pane in-place
        wc.selectWebsite(host: "theverge.com")
        texts = uiAllStrings(in: root)
        XCTAssertTrue(texts.contains("Trackers Prevented on theverge.com"))
        XCTAssertTrue(texts.contains("fingerprintjs.com"))

        // Switch to Trackers mode — check singular "1 website" and plural "2 websites"
        wc.displayMode = .trackers
        texts = uiAllStrings(in: root)
        XCTAssertTrue(texts.contains(where: { $0.contains("Across 2 websites") }))
        XCTAssertTrue(texts.contains(where: { $0.contains("Across 1 website") && !$0.contains("Across 1 websites") }))
        XCTAssertTrue(texts.contains("Websites Contacting doubleclick.net"))

        // Select another tracker updates detail pane
        wc.selectTracker(entityDomain: "facebook.com")
        texts = uiAllStrings(in: root)
        XCTAssertTrue(texts.contains("Websites Contacting facebook.com"))
        XCTAssertTrue(texts.contains(where: { $0.contains("across 1 website") && !$0.contains("1 websites") }))

        // Live search filtering
        wc.searchQuery = "fingerprint"
        texts = uiAllStrings(in: root)
        XCTAssertTrue(texts.contains("fingerprintjs.com"))
        XCTAssertFalse(texts.contains("Websites Contacting facebook.net"))

        // Non-matching search shows empty match message
        wc.searchQuery = "nonexistent-tracker-xyz"
        texts = uiAllStrings(in: root)
        XCTAssertTrue(texts.contains("No Matches for \"nonexistent-tracker-xyz\""))
    }

    func testPrivacyReportCallbacksAndLayoutAcrossWidthsAndAppearances() {
        seedSampleStore()
        let wc = PrivacyReportWindowController(store: store)
        defer { wc.close() }

        var openedSettings = 0
        var cleared = 0
        wc.onOpenPrivacySettings = { openedSettings += 1 }
        wc.onClearReport = { cleared += 1 }

        let root = wc.window!.contentView!
        let buttons = uiDescendants(of: root, as: NSButton.self)
        let settingsBtn = buttons.first { $0.title == "Privacy Settings…" }
        let clearBtn = buttons.first { $0.title == "Clear Report" }
        XCTAssertNotNil(settingsBtn)
        XCTAssertNotNil(clearBtn)

        _ = settingsBtn?.target?.perform(settingsBtn?.action, with: settingsBtn)
        _ = clearBtn?.target?.perform(clearBtn?.action, with: clearBtn)
        XCTAssertEqual(openedSettings, 1)
        XCTAssertEqual(cleared, 1)

        for width in [CGFloat(680), 820, 1000] {
            wc.window?.setContentSize(NSSize(width: width, height: 580))
            assertValidLayout(in: root)
        }

        // At 680pt width, verify "Privacy Report" header never truncates and wrapped detail chips fit within detail pane
        wc.window?.setContentSize(NSSize(width: 680, height: 580))
        root.layoutSubtreeIfNeeded()
        let titleField = uiDescendants(of: root, as: NSTextField.self).first { $0.stringValue == "Privacy Report" }
        XCTAssertNotNil(titleField)
        if let titleField {
            XCTAssertGreaterThanOrEqual(titleField.frame.width + 0.5, titleField.intrinsicContentSize.width)
        }
        wc.selectWebsite(host: "theverge.com")
        root.layoutSubtreeIfNeeded()
        for pill in uiDescendants(of: root, as: PrivacyCategoryPillView.self) {
            if let superview = pill.superview {
                XCTAssertLessThanOrEqual(pill.frame.maxX, superview.bounds.width + 0.5)
            }
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            wc.window?.appearance = NSAppearance(named: appearanceName)
            assertValidLayout(in: root)
        }

        // Closed window (isVisible == false) must ignore .safariumPrivacyReportDidChange notifications
        XCTAssertFalse(wc.window?.isVisible ?? true)
        guard let emptyCard = uiPrivate(wc, "emptyStateCard", as: NSView.self) else {
            XCTFail("missing emptyStateCard")
            return
        }
        XCTAssertTrue(emptyCard.isHidden, "populated report keeps empty-state card hidden")
        store.clearAll()
        store.flushSync()
        NotificationCenter.default.post(name: .safariumPrivacyReportDidChange, object: nil)
        spinRunLoop(0.05)
        XCTAssertTrue(emptyCard.isHidden, "closed window must ignore change notification")

        // Explicit reloadData() reflects cleared store
        wc.reloadData()
        XCTAssertFalse(emptyCard.isHidden)
        XCTAssertTrue(uiAllStrings(in: root).contains("No Trackers Prevented Yet"))
    }

    func testPrivacyPopoverInternalPageDisablesSiteToggleAndWebsiteSettings() {
        let internalSnap = TabPrivacySnapshot.empty(
            tabID: "start-1",
            host: "",
            isPrivate: false,
            securityState: .internalPage,
            protectionsEnabled: true
        )
        let vc = PrivacyPopoverViewController(snapshot: internalSnap, summary: .empty)
        _ = vc.view
        assertValidLayout(in: vc.view, maxWidth: 336)

        let texts = uiAllStrings(in: vc.view)
        XCTAssertTrue(texts.contains("Start Page"))
        XCTAssertTrue(texts.contains("No known trackers found on this webpage"))

        let settingsBtn = uiDescendants(of: vc.view, as: NSButton.self).first { $0.title == "Website Settings…" }
        XCTAssertEqual(settingsBtn?.isEnabled, false)
        let sw = uiDescendants(of: vc.view, as: NSSwitch.self).first
        XCTAssertEqual(sw?.superview?.isHidden, true)
    }

    // MARK: - PrivacyPopoverController & PrivacyPopoverViewController

    func testPrivacyPopoverSecurityStatesAndWidthInvariant() {
        let states: [(ConnectionSecurityState, String)] = [
            (.secureHTTPS, "Connection is Secure (HTTPS)"),
            (.upgradedHTTPS, "Automatically Upgraded to HTTPS"),
            (.insecureHTTP, "Not Secure (HTTP)"),
            (.certificateError, "Certificate Warning")
        ]

        let summary = PrivacyReportSummary(
            uniqueTrackersPrevented: 14,
            totalBlockedRequests: 42,
            totalWebsitesVisited: 10,
            websitesContactingTrackersCount: 6,
            websitesContactingTrackersPercent: 60,
            mostContactedTracker: nil,
            httpsUpgradesCount: 3,
            trackingParamsStrippedCount: 4,
            fingerprintingAttemptsBlocked: 2,
            cookiesBlockedCount: 5,
            bounceTrackersMitigatedCount: 0,
            categoryBreakdown: [:],
            websites: [],
            trackers: [],
            windowDays: 30
        )

        for (secState, expectedSubtitle) in states {
            let snap = TabPrivacySnapshot.empty(
                tabID: "t1",
                host: "example.com",
                isPrivate: false,
                securityState: secState,
                protectionsEnabled: true
            )
            let vc = PrivacyPopoverViewController(snapshot: snap, summary: summary)
            _ = vc.view
            assertValidLayout(in: vc.view, maxWidth: 336)
            XCTAssertLessThanOrEqual(vc.preferredContentSize.width, 336)

            let texts = uiAllStrings(in: vc.view)
            XCTAssertTrue(texts.contains("example.com"))
            XCTAssertTrue(texts.contains(expectedSubtitle))
            XCTAssertTrue(texts.contains("30-Day Total: 14 trackers prevented across 60% of sites"))
        }
    }

    func testPrivacyPopoverPrivateModeIsolationSwitchAndCallbacks() {
        let tracker = PrivacyReportTrackerEntry(
            entityDomain: "doubleclick.net",
            ownerName: "Google",
            category: .advertising,
            trackerDomains: ["ad.doubleclick.net"],
            websites: ["news.example"],
            totalBlockedRequests: 5,
            lastSeen: Date()
        )
        let privateSnap = TabPrivacySnapshot(
            tabID: "priv-1",
            host: "news.example",
            isPrivate: true,
            securityState: .upgradedHTTPS,
            protectionsEnabled: true,
            trackers: [tracker],
            totalTrackersBlocked: 5,
            uniqueTrackerEntitiesCount: 1,
            cookiesBlocked: 2,
            paramsStripped: 1,
            fingerprintsBlocked: 1,
            httpsUpgraded: true,
            bounceTrackersMitigated: 2,
            recentEvents: []
        )
        let summary = PrivacyReportSummary(
            uniqueTrackersPrevented: 99,
            totalBlockedRequests: 300,
            totalWebsitesVisited: 20,
            websitesContactingTrackersCount: 10,
            websitesContactingTrackersPercent: 50,
            mostContactedTracker: nil,
            httpsUpgradesCount: 1,
            trackingParamsStrippedCount: 2,
            fingerprintingAttemptsBlocked: 3,
            cookiesBlockedCount: 4,
            bounceTrackersMitigatedCount: 0,
            categoryBreakdown: [:],
            websites: [],
            trackers: [],
            windowDays: 30
        )

        let vc = PrivacyPopoverViewController(snapshot: privateSnap, summary: summary)
        _ = vc.view
        var texts = uiAllStrings(in: vc.view)

        XCTAssertTrue(texts.contains("Private Browsing — Never Logged"))
        XCTAssertFalse(texts.contains(where: { $0.contains("30-Day Total") }), "Private window must never leak 30-day totals")
        XCTAssertTrue(texts.contains("5 trackers prevented from profiling you"))
        XCTAssertTrue(texts.contains("doubleclick.net"))
        XCTAssertTrue(texts.contains("Google"))
        XCTAssertTrue(texts.contains("2 cookies"))
        XCTAssertTrue(texts.contains("1 links"))
        XCTAssertTrue(texts.contains("1 probes"))
        XCTAssertTrue(texts.contains("2 bounce"))

        var toggled: (String, Bool)?
        var openedReport = 0
        var openedSettingsHost: String?
        vc.onToggleSiteProtection = { host, enabled in toggled = (host, enabled) }
        vc.onOpenPrivacyReport = { openedReport += 1 }
        vc.onOpenWebsiteSettings = { host in openedSettingsHost = host }

        let sw = uiDescendants(of: vc.view, as: NSSwitch.self).first
        XCTAssertNotNil(sw)
        sw?.state = .off
        _ = sw?.target?.perform(sw?.action, with: sw)
        XCTAssertEqual(toggled?.0, "news.example")
        XCTAssertEqual(toggled?.1, false)

        texts = uiAllStrings(in: vc.view)
        XCTAssertTrue(texts.contains("Protections paused for this website"))
        XCTAssertFalse(texts.contains("doubleclick.net"), "Paused popover must hide tracker list")
        XCTAssertFalse(texts.contains("2 cookies"), "Paused popover must hide stat chips")
        XCTAssertFalse(texts.contains("2 bounce"), "Paused popover must hide bounce chip")
        let scrollViews = uiDescendants(of: vc.view, as: NSScrollView.self)
        XCTAssertTrue(scrollViews.allSatisfy { $0.superview?.isHidden == true })

        let buttons = uiDescendants(of: vc.view, as: NSButton.self)
        let reportBtn = buttons.first { $0.title == "Privacy Report…" }
        let settingsBtn = buttons.first { $0.title == "Website Settings…" }
        _ = reportBtn?.target?.perform(reportBtn?.action, with: reportBtn)
        _ = settingsBtn?.target?.perform(settingsBtn?.action, with: settingsBtn)
        XCTAssertEqual(openedReport, 1)
        XCTAssertEqual(openedSettingsHost, "news.example")

        let controller = PrivacyPopoverController()
        XCTAssertFalse(controller.isShown)
        controller.close()
        XCTAssertFalse(controller.isShown)
    }

    // MARK: - WebsiteDataSheetController

    func testWebsiteDataSheetLoadFilterSelectiveRemoveAndRemoveAll() {
        let initialRecords = [
            WebsiteDataRecord(domain: "alpha.com", cookieCount: 14, hasCookies: true, hasCache: false),
            WebsiteDataRecord(domain: "beta.org", cookieCount: 2, hasCookies: true, hasCache: true),
            WebsiteDataRecord(domain: "gamma.net", cookieCount: 0, hasCookies: false, hasCache: true)
        ]

        var fetchCount = 0
        var removedBatches: [[String]] = []
        var didRemoveAll = false

        let sheet = WebsiteDataSheetController(
            fetchRecords: { completion in
                fetchCount += 1
                completion(initialRecords)
            },
            removeDomains: { domains, completion in
                removedBatches.append(domains)
                completion(true)
            },
            removeAll: { completion in
                didRemoveAll = true
                completion(true)
            }
        )

        let vc = sheet.makeSheetContentViewController()
        _ = vc.view
        spinRunLoop(0.05)

        XCTAssertEqual(fetchCount, 1, "Initial load must fetch website data only once")
        XCTAssertEqual(vc.displayedRecords.count, 3)
        XCTAssertEqual(vc.tableView.numberOfRows, 3)
        XCTAssertFalse(vc.removeButton.isEnabled)
        XCTAssertTrue(vc.removeAllButton.isEnabled)
        XCTAssertTrue(vc.emptyStateLabel.isHidden)

        // Filter
        vc.searchQuery = "beta"
        XCTAssertEqual(vc.displayedRecords.map(\.domain), ["beta.org"])
        XCTAssertEqual(vc.tableView.numberOfRows, 1)

        vc.searchQuery = ""
        XCTAssertEqual(vc.displayedRecords.count, 3)

        // Multi-selection removal clears selection afterward
        vc.tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        XCTAssertTrue(vc.removeButton.isEnabled)
        vc.removeSelectedTapped()
        spinRunLoop(0.05)

        XCTAssertEqual(removedBatches.count, 1)
        XCTAssertEqual(Set(removedBatches[0]), Set(["alpha.com", "gamma.net"]))
        XCTAssertEqual(vc.displayedRecords.map(\.domain), ["beta.org"])
        XCTAssertEqual(vc.tableView.numberOfRows, 1)
        XCTAssertTrue(vc.tableView.selectedRowIndexes.isEmpty, "Selection must be cleared after selective removal")
        XCTAssertFalse(vc.removeButton.isEnabled)

        // Escape / cancelOperation dismisses sheet
        var doneCount = 0
        vc.onDone = { doneCount += 1 }
        vc.cancelOperation(nil)
        XCTAssertEqual(doneCount, 1)

        // Remove All
        vc.removeAllTapped()
        spinRunLoop(0.05)

        XCTAssertTrue(didRemoveAll)
        XCTAssertTrue(vc.displayedRecords.isEmpty)
        XCTAssertEqual(vc.tableView.numberOfRows, 0)
        XCTAssertFalse(vc.removeButton.isEnabled)
        XCTAssertFalse(vc.removeAllButton.isEnabled)
        XCTAssertFalse(vc.emptyStateLabel.isHidden)
        XCTAssertEqual(vc.emptyStateLabel.stringValue, "No stored website data")

        assertValidLayout(in: vc.view)
        XCTAssertEqual(sheet.sheetPanel.contentView?.frame.size ?? NSSize(width: 520, height: 440), NSSize(width: 520, height: 440))
    }

    func testWebsiteDataSheetInitialEmptyState() {
        let sheet = WebsiteDataSheetController(
            fetchRecords: { $0([]) },
            removeDomains: { _, done in done(true) },
            removeAll: { $0(true) }
        )
        let vc = sheet.makeSheetContentViewController()
        _ = vc.view
        spinRunLoop(0.05)

        XCTAssertTrue(vc.displayedRecords.isEmpty)
        XCTAssertFalse(vc.removeButton.isEnabled)
        XCTAssertFalse(vc.removeAllButton.isEnabled)
        XCTAssertFalse(vc.emptyStateLabel.isHidden)
        XCTAssertEqual(vc.emptyStateLabel.stringValue, "No stored website data")
    }
}
