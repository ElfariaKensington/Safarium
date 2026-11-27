import XCTest
import SQLite3
@testable import Safarium

final class PrivacyReportStoreTests: HermeticTestCase {

    private func makeTempStore(
        filename: String = "privacy-test-\(UUID().uuidString).sqlite",
        retentionDays: Int = 30,
        debounceNotifications: Bool = false
    ) -> (store: PrivacyReportStore, url: URL) {
        let dir = Self.sandboxRoot.appendingPathComponent("PrivacyStoreTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename, isDirectory: false)
        let store = PrivacyReportStore(
            databaseURL: url,
            retentionDays: retentionDays,
            debounceNotifications: debounceNotifications
        )
        return (store, url)
    }

    // MARK: - Domain Classifier

    func testNormalizedHostAndURLSanitization() {
        XCTAssertEqual(PrivacyDomainClassifier.normalizedHost("  WWW.Example.COM.  "), "example.com")
        XCTAssertEqual(
            PrivacyDomainClassifier.normalizedHost("https://user:secret@www.News.BBC.co.uk:8443/article/123?fbclid=abc#top"),
            "news.bbc.co.uk"
        )
        XCTAssertEqual(PrivacyDomainClassifier.normalizedHost("//cdn.tracker.net/pixel.gif?id=99"), "cdn.tracker.net")
        XCTAssertEqual(PrivacyDomainClassifier.normalizedHost("http://[::1]:8080/test"), "::1")
        XCTAssertEqual(PrivacyDomainClassifier.normalizedHost("about:blank"), "")
        XCTAssertEqual(PrivacyDomainClassifier.normalizedHost("safarium://start"), "")
        XCTAssertEqual(PrivacyDomainClassifier.normalizedHost("file:///Users/test/index.html"), "")
        XCTAssertEqual(PrivacyDomainClassifier.normalizedHost("javascript:alert(1)"), "")

        XCTAssertEqual(
            PrivacyDomainClassifier.sanitizeHostForStorage("https://alice:pw@www.example.com/private/path?token=xyz"),
            "example.com"
        )
    }

    func testRegistrableDomainMultiPartTLDsAndSpecialHosts() {
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "ads.doubleclick.net"), "doubleclick.net")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "shop.brand.com.au"), "brand.com.au")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "sub.example.co.jp"), "example.co.jp")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "portal.company.com.tr"), "company.com.tr")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "cdn.store.com.br"), "store.com.br")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "mail.agency.co.nz"), "agency.co.nz")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "app.corp.com.cn"), "corp.com.cn")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "m.site.co.kr"), "site.co.kr")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "api.svc.com.sg"), "svc.com.sg")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "pay.bank.com.in"), "bank.com.in")

        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "192.168.1.42"), "192.168.1.42")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "127.0.0.1:8080"), "127.0.0.1")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "[::1]:3000"), "::1")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "localhost"), "localhost")
        XCTAssertEqual(PrivacyDomainClassifier.registrableDomain(for: "printer.local"), "printer.local")
    }

    func testTrackerMetadataAndDisplayOwner() {
        let google = PrivacyDomainClassifier.trackerMetadata(forHost: "stats.g.doubleclick.net")
        XCTAssertEqual(google?.entityDomain, "google.com")
        XCTAssertEqual(google?.ownerName, "Google")
        XCTAssertEqual(google?.category, .advertising)

        let meta = PrivacyDomainClassifier.trackerMetadata(forHost: "connect.facebook.net")
        XCTAssertEqual(meta?.entityDomain, "facebook.com")
        XCTAssertEqual(meta?.ownerName, "Meta")
        XCTAssertEqual(meta?.category, .social)

        let fp = PrivacyDomainClassifier.trackerMetadata(forHost: "api.fpjs.io")
        XCTAssertEqual(fp?.entityDomain, "fingerprint.com")
        XCTAssertEqual(fp?.ownerName, "Fingerprint")
        XCTAssertEqual(fp?.category, .fingerprinting)

        XCTAssertEqual(PrivacyDomainClassifier.displayOwner(entityDomain: "doubleclick.net", rawOwner: ""), "Google")
        XCTAssertEqual(PrivacyDomainClassifier.displayOwner(entityDomain: "exampletracker.io", rawOwner: ""), "Exampletracker")
        XCTAssertEqual(PrivacyDomainClassifier.displayOwner(entityDomain: "exampletracker.io", rawOwner: "Custom Owner"), "Custom Owner")
    }

    // MARK: - Persistence Across Reopen & Host-Only Storage

    func testPersistenceAcrossReopenAndPathSanitization() throws {
        let filename = "persist-\(UUID().uuidString).sqlite"
        let now = Date()

        do {
            let (store, _) = makeTempStore(filename: filename)
            store.recordPageVisit(host: "https://user:pw@www.nytimes.com/world?secret=123", tabID: "t1", isPrivate: false, timestamp: now)
            store.record(
                PrivacyEvent(
                    eventType: .trackerBlocked,
                    pageHost: "https://www.nytimes.com/section/tech?q=hello",
                    trackerHost: "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?cb=1",
                    count: 3,
                    timestamp: now
                ),
                forTabID: "t1"
            )
            store.flushSync()
        }

        let (reopened, url) = makeTempStore(filename: filename)
        let summary = reopened.summary(days: 30, now: now)
        XCTAssertEqual(summary.uniqueTrackersPrevented, 1)
        XCTAssertEqual(summary.totalBlockedRequests, 3)
        XCTAssertEqual(summary.totalWebsitesVisited, 1)
        XCTAssertEqual(summary.websitesContactingTrackersCount, 1)
        XCTAssertEqual(summary.websitesContactingTrackersPercent, 100)
        XCTAssertEqual(summary.websites.first?.host, "nytimes.com")
        XCTAssertEqual(summary.trackers.first?.entityDomain, "google.com")
        XCTAssertEqual(summary.trackers.first?.trackerDomains, ["pagead2.googlesyndication.com"])

        // Ensure raw URL paths/queries/credentials never hit disk.
        let rawBytes = try Data(contentsOf: url)
        let rawString = String(decoding: rawBytes, as: UTF8.self)
        XCTAssertFalse(rawString.contains("secret=123"))
        XCTAssertFalse(rawString.contains("adsbygoogle.js"))
        XCTAssertFalse(rawString.contains("user:pw"))
    }

    // MARK: - Strict Private Browsing Isolation

    func testPrivateBrowsingIsolationWritesZeroSQLiteRows() {
        let (store, _) = makeTempStore()
        let now = Date()

        // Explicit private tab lifecycle + events.
        store.resetTabStats(forTabID: "priv-tab", host: "secret-health.org", isPrivate: true, securityState: .secureHTTPS)
        store.recordPageVisit(host: "secret-health.org", tabID: "priv-tab", isPrivate: true, timestamp: now)
        store.record(
            PrivacyEvent(
                eventType: .trackerBlocked,
                pageHost: "secret-health.org",
                trackerHost: "google-analytics.com",
                count: 4,
                isPrivate: true,
                timestamp: now
            ),
            forTabID: "priv-tab"
        )
        // Even if caller forgets isPrivate: true on a private tab, tab snapshot isolation still blocks SQLite persistence.
        store.record(
            PrivacyEvent(
                eventType: .fingerprintBlocked,
                pageHost: "secret-health.org",
                trackerHost: "fpjs.io",
                category: .fingerprinting,
                count: 2,
                isPrivate: false,
                timestamp: now
            ),
            forTabID: "priv-tab"
        )
        // Ephemeral tab snapshot has the live stats for secret-health.org before navigating away.
        let snap = store.tabSnapshot(forTabID: "priv-tab")
        XCTAssertNotNil(snap)
        XCTAssertTrue(snap?.isPrivate == true)
        XCTAssertEqual(snap?.host, "secret-health.org")
        XCTAssertEqual(snap?.totalTrackersBlocked, 6)
        XCTAssertEqual(snap?.fingerprintsBlocked, 2)
        XCTAssertEqual(snap?.uniqueTrackerEntitiesCount, 2)

        // Navigating to another host resets ephemeral per-host counts while keeping isPrivate latched.
        store.recordPageVisit(host: "another-private-site.com", tabID: "priv-tab", isPrivate: false, timestamp: now)
        store.flushSync()
        let nextSnap = store.tabSnapshot(forTabID: "priv-tab")
        XCTAssertTrue(nextSnap?.isPrivate == true)
        XCTAssertEqual(nextSnap?.host, "another-private-site.com")
        XCTAssertEqual(nextSnap?.totalTrackersBlocked, 0)

        // Persistent store and Privacy Report summary remain completely empty.
        let summary = store.summary(days: 30, now: now)
        XCTAssertEqual(summary, .empty)
    }

    // MARK: - 30-Day Rolling Retention & Clearing

    func testRollingRetentionPrunesOlderThan30DaysAndPreserves29Days() {
        let filename = "retention-\(UUID().uuidString).sqlite"
        let now = Date()
        let day: TimeInterval = 86_400
        let thirtyOneDaysAgo = now.addingTimeInterval(-31 * day)
        let twentyNineDaysAgo = now.addingTimeInterval(-29 * day)

        let (store, _) = makeTempStore(filename: filename)
        store.recordPageVisit(host: "old-site.com", isPrivate: false, timestamp: thirtyOneDaysAgo)
        store.record(
            PrivacyEvent(
                eventType: .trackerBlocked,
                pageHost: "old-site.com",
                trackerHost: "criteo.com",
                count: 5,
                timestamp: thirtyOneDaysAgo
            )
        )
        store.recordPageVisit(host: "recent-site.com", isPrivate: false, timestamp: twentyNineDaysAgo)
        store.record(
            PrivacyEvent(
                eventType: .trackerBlocked,
                pageHost: "recent-site.com",
                trackerHost: "doubleclick.net",
                count: 2,
                timestamp: twentyNineDaysAgo
            )
        )
        store.flushSync()

        store.pruneExpired(olderThanDays: 30, now: now)
        store.flushSync()

        let summary = store.summary(days: 30, now: now)
        XCTAssertEqual(summary.totalWebsitesVisited, 1)
        XCTAssertEqual(summary.totalBlockedRequests, 2)
        XCTAssertEqual(summary.websites.map(\.host), ["recent-site.com"])
        XCTAssertEqual(summary.trackers.map(\.entityDomain), ["google.com"])

        // Even querying a 60-day window confirms the 31-day-old rows were physically deleted from SQLite.
        let wideSummary = store.summary(days: 60, now: now)
        XCTAssertEqual(wideSummary.totalWebsitesVisited, 1)
        XCTAssertEqual(wideSummary.websites.map(\.host), ["recent-site.com"])
    }

    func testClearEventsSinceAndClearAll() {
        let (store, _) = makeTempStore()
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-7200)
        let tenMinutesAgo = now.addingTimeInterval(-600)
        let thirtyMinutesAgo = now.addingTimeInterval(-1800)

        store.recordPageVisit(host: "older.com", isPrivate: false, timestamp: twoHoursAgo)
        store.record(
            PrivacyEvent(
                eventType: .trackerBlocked,
                pageHost: "older.com",
                trackerHost: "taboola.com",
                count: 2,
                timestamp: twoHoursAgo
            )
        )
        store.recordPageVisit(host: "newer.com", isPrivate: false, timestamp: tenMinutesAgo)
        store.record(
            PrivacyEvent(
                eventType: .cookieBlocked,
                pageHost: "newer.com",
                trackerHost: "outbrain.com",
                category: .cookie,
                count: 3,
                timestamp: tenMinutesAgo
            )
        )
        store.flushSync()

        store.clearEvents(since: thirtyMinutesAgo)
        store.flushSync()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let afterPartialClear = store.summary(days: 30, now: now)
        XCTAssertEqual(afterPartialClear.totalWebsitesVisited, 1)
        XCTAssertEqual(afterPartialClear.totalBlockedRequests, 2)
        XCTAssertEqual(afterPartialClear.websites.map(\.host), ["older.com"])

        let expectation = expectation(description: "clearAll posts report change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .safariumPrivacyReportDidChange,
            object: store,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.clearAll()
        store.flushSync()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(store.summary(days: 30, now: now), .empty)
    }

    // MARK: - Summary Math & Tie-Breaking

    func testSummaryMathSortingAndTieBreaking() {
        let (store, _) = makeTempStore()
        let now = Date()

        // 4 visited sites: alpha.com, beta.com, gamma.com, clean.com (no trackers)
        store.recordPageVisit(host: "clean.com", isPrivate: false, timestamp: now)
        store.recordPageVisit(host: "alpha.com", isPrivate: false, timestamp: now)
        store.recordPageVisit(host: "beta.com", isPrivate: false, timestamp: now)
        store.recordPageVisit(host: "gamma.com", isPrivate: false, timestamp: now)

        // Tie test for trackers:
        // "zeta.io" seen on 2 sites (alpha, beta) with 5 requests total
        // "beta-ads.com" seen on 2 sites (alpha, beta) with 5 requests total -> beats "zeta.io" alphabetically
        // "alpha-metrics.com" seen on 2 sites (alpha, gamma) with 8 requests total -> beats both by requests
        store.record(PrivacyEvent(eventType: .trackerBlocked, pageHost: "alpha.com", trackerHost: "zeta.io", entityDomain: "zeta.io", ownerName: "Zeta", category: .advertising, count: 2, timestamp: now))
        store.record(PrivacyEvent(eventType: .trackerBlocked, pageHost: "beta.com", trackerHost: "zeta.io", entityDomain: "zeta.io", ownerName: "Zeta", category: .advertising, count: 3, timestamp: now))

        store.record(PrivacyEvent(eventType: .cookieBlocked, pageHost: "alpha.com", trackerHost: "beta-ads.com", entityDomain: "beta-ads.com", ownerName: "BetaAds", category: .cookie, count: 4, timestamp: now))
        store.record(PrivacyEvent(eventType: .trackerBlocked, pageHost: "beta.com", trackerHost: "beta-ads.com", entityDomain: "beta-ads.com", ownerName: "BetaAds", category: .advertising, count: 1, timestamp: now))

        store.record(PrivacyEvent(eventType: .fingerprintBlocked, pageHost: "alpha.com", trackerHost: "alpha-metrics.com", entityDomain: "alpha-metrics.com", ownerName: "AlphaMetrics", category: .fingerprinting, count: 5, timestamp: now))
        store.record(PrivacyEvent(eventType: .bounceTrackerMitigated, pageHost: "gamma.com", trackerHost: "alpha-metrics.com", entityDomain: "alpha-metrics.com", ownerName: "AlphaMetrics", category: .bounceTracking, count: 3, timestamp: now))

        // Non-prevention protection events
        store.record(PrivacyEvent(eventType: .httpsUpgraded, pageHost: "alpha.com", category: .httpsUpgrade, detail: "http -> https", count: 2, timestamp: now))
        store.record(PrivacyEvent(eventType: .trackingParamStripped, pageHost: "gamma.com", category: .linkTracking, detail: "fbclid,utm_source", count: 3, timestamp: now))
        store.flushSync()

        let summary = store.summary(days: 30, now: now)
        XCTAssertEqual(summary.uniqueTrackersPrevented, 3)
        XCTAssertEqual(summary.totalBlockedRequests, 18) // 2+3 + 4+1 + 5+3
        XCTAssertEqual(summary.totalWebsitesVisited, 4)
        XCTAssertEqual(summary.websitesContactingTrackersCount, 3) // alpha, beta, gamma
        XCTAssertEqual(summary.websitesContactingTrackersPercent, 75) // 3 / 4 = 75%
        XCTAssertEqual(summary.httpsUpgradesCount, 2)
        XCTAssertEqual(summary.trackingParamsStrippedCount, 3)
        XCTAssertEqual(summary.fingerprintingAttemptsBlocked, 5)
        XCTAssertEqual(summary.cookiesBlockedCount, 4)
        XCTAssertEqual(summary.bounceTrackersMitigatedCount, 3)

        XCTAssertEqual(summary.trackers.map(\.entityDomain), ["alpha-metrics.com", "beta-ads.com", "zeta.io"])
        XCTAssertEqual(summary.mostContactedTracker?.entityDomain, "alpha-metrics.com")

        // Websites: alpha.com (3 unique), beta.com (2 unique), gamma.com (1 unique)
        XCTAssertEqual(summary.websites.map(\.host), ["alpha.com", "beta.com", "gamma.com"])
        XCTAssertEqual(summary.websites.first?.httpsUpgrades, 2)
        XCTAssertEqual(summary.websites.first?.cookiesBlocked, 4)
        XCTAssertEqual(summary.websites.first?.fingerprintsBlocked, 5)
        XCTAssertEqual(summary.websites.last?.paramsStripped, 3)
        XCTAssertEqual(summary.websites.last?.bounceTrackersMitigated, 3)

        XCTAssertEqual(summary.categoryBreakdown[.advertising], 6) // 2 + 3 + 1
        XCTAssertEqual(summary.categoryBreakdown[.cookie], 4)
        XCTAssertEqual(summary.categoryBreakdown[.fingerprinting], 5)
        XCTAssertEqual(summary.categoryBreakdown[.bounceTracking], 3)
    }

    // MARK: - Live Per-Tab Snapshots

    func testPerTabLifecycleAndStateUpdates() {
        let (store, _) = makeTempStore()
        let tabID = "tab-1"

        store.resetTabStats(forTabID: tabID, host: "example.com", isPrivate: false, securityState: .secureHTTPS)
        store.updateConnectionSecurity(.upgradedHTTPS, host: "www.example.com", forTabID: tabID)
        store.record(PrivacyEvent(eventType: .trackerBlocked, pageHost: "example.com", trackerHost: "doubleclick.net", count: 2), forTabID: tabID)
        store.record(PrivacyEvent(eventType: .cookieBlocked, pageHost: "example.com", trackerHost: "doubleclick.net", category: .cookie, count: 1), forTabID: tabID)
        store.record(PrivacyEvent(eventType: .trackingParamStripped, pageHost: "example.com", category: .linkTracking, detail: "gclid", count: 2), forTabID: tabID)
        store.record(PrivacyEvent(eventType: .fingerprintBlocked, pageHost: "example.com", trackerHost: "fpjs.io", category: .fingerprinting, count: 1), forTabID: tabID)
        store.record(PrivacyEvent(eventType: .bounceTrackerMitigated, pageHost: "example.com", trackerHost: "t.co", category: .bounceTracking, count: 1), forTabID: tabID)

        var snap = store.tabSnapshot(forTabID: tabID)
        XCTAssertEqual(snap?.host, "example.com")
        XCTAssertEqual(snap?.securityState, .upgradedHTTPS)
        XCTAssertEqual(snap?.httpsUpgraded, true)
        XCTAssertEqual(snap?.protectionsEnabled, true)
        XCTAssertEqual(snap?.totalTrackersBlocked, 5)
        XCTAssertEqual(snap?.uniqueTrackerEntitiesCount, 3) // google.com, fingerprint.com, x.com
        XCTAssertEqual(snap?.cookiesBlocked, 1)
        XCTAssertEqual(snap?.paramsStripped, 2)
        XCTAssertEqual(snap?.fingerprintsBlocked, 1)
        XCTAssertEqual(snap?.bounceTrackersMitigated, 1)
        XCTAssertEqual(snap?.recentEvents.count, 5)

        store.updateProtectionsEnabled(false, forTabID: tabID)
        XCTAssertEqual(store.tabSnapshot(forTabID: tabID)?.protectionsEnabled, false)

        // Reset on navigation clears prior page counters.
        store.resetTabStats(forTabID: tabID, host: "other.org", isPrivate: false, securityState: .insecureHTTP, protectionsEnabled: true)
        snap = store.tabSnapshot(forTabID: tabID)
        XCTAssertEqual(snap?.host, "other.org")
        XCTAssertEqual(snap?.securityState, .insecureHTTP)
        XCTAssertEqual(snap?.totalTrackersBlocked, 0)
        XCTAssertEqual(snap?.recentEvents.count, 0)
        XCTAssertEqual(snap?.httpsUpgraded, false)

        store.removeTabStats(forTabID: tabID)
        XCTAssertNil(store.tabSnapshot(forTabID: tabID))
    }

    // MARK: - Concurrency & Model Helpers

    func testConcurrentWritesAreThreadSafe() {
        let (store, _) = makeTempStore()
        let now = Date()

        DispatchQueue.concurrentPerform(iterations: 40) { idx in
            let tabID = "tab-\(idx % 4)"
            store.recordPageVisit(host: "site-\(idx % 5).com", tabID: tabID, isPrivate: false, timestamp: now)
            store.record(
                PrivacyEvent(
                    eventType: .trackerBlocked,
                    pageHost: "site-\(idx % 5).com",
                    trackerHost: "tracker-\(idx % 3).com",
                    count: 1,
                    timestamp: now
                ),
                forTabID: tabID
            )
            _ = store.tabSnapshot(forTabID: tabID)
        }
        store.flushSync()

        let summary = store.summary(days: 30, now: now)
        XCTAssertEqual(summary.totalBlockedRequests, 40)
        XCTAssertEqual(summary.totalWebsitesVisited, 5)
        XCTAssertEqual(summary.uniqueTrackersPrevented, 3)
    }

    func testModelsDisplayPropertiesAndWebsiteDataSummary() {
        XCTAssertTrue(ConnectionSecurityState.secureHTTPS.isSecure)
        XCTAssertTrue(ConnectionSecurityState.upgradedHTTPS.isSecure)
        XCTAssertFalse(ConnectionSecurityState.insecureHTTP.isSecure)
        XCTAssertFalse(ConnectionSecurityState.certificateError.isSecure)
        XCTAssertFalse(ConnectionSecurityState.internalPage.isSecure)

        for level in PrivacyProtectionLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty)
            XCTAssertFalse(level.summaryDescription.isEmpty)
        }
        for category in PrivacyTrackerCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
            XCTAssertFalse(category.symbolName.isEmpty)
            _ = category.badgeColor
        }

        XCTAssertEqual(WebsiteDataRecord(domain: "a.com", cookieCount: 12, hasCookies: true, hasCache: false).detailSummary, "12 cookies")
        XCTAssertEqual(WebsiteDataRecord(domain: "b.com", cookieCount: 1, hasCookies: true, hasCache: true).detailSummary, "1 cookie, Cache")
        XCTAssertEqual(WebsiteDataRecord(domain: "c.com", cookieCount: 0, hasCookies: false, hasCache: true).detailSummary, "Cache")
    }

    // MARK: - Regression Tests (Cross-Host Reset, Private Latching, Dedup Visits, CloseForReset)

    func testCrossHostTransitionResetsOldTrackersAndPreservesEarlyIncomingEvents() {
        let (store, _) = makeTempStore()
        let tabID = "nav-tab"

        // Visit old.com and accumulate trackers & upgradedHTTPS.
        store.resetTabStats(forTabID: tabID, host: "old.com", isPrivate: false, securityState: .upgradedHTTPS)
        store.record(PrivacyEvent(eventType: .trackerBlocked, pageHost: "old.com", trackerHost: "doubleclick.net", count: 3), forTabID: tabID)
        store.record(PrivacyEvent(eventType: .cookieBlocked, pageHost: "old.com", trackerHost: "criteo.com", category: .cookie, count: 2), forTabID: tabID)
        XCTAssertEqual(store.tabSnapshot(forTabID: tabID)?.totalTrackersBlocked, 5)

        // Early network events for incoming new.com arrive BEFORE updateConnectionSecurity / didChangeURL.
        store.record(PrivacyEvent(eventType: .httpsUpgraded, pageHost: "new.com", category: .httpsUpgrade, detail: "http -> https", count: 1), forTabID: tabID)
        store.record(PrivacyEvent(eventType: .trackingParamStripped, pageHost: "new.com", category: .linkTracking, detail: "fbclid", count: 2), forTabID: tabID)

        // Now security state updates for new.com (cross-host transition).
        store.updateConnectionSecurity(.secureHTTPS, host: "new.com", forTabID: tabID, isPrivate: false)
        let snap = store.tabSnapshot(forTabID: tabID)
        XCTAssertEqual(snap?.host, "new.com")
        XCTAssertEqual(snap?.securityState, .secureHTTPS)
        XCTAssertEqual(snap?.totalTrackersBlocked, 0, "Old-host trackers must be cleared on cross-host transition")
        XCTAssertEqual(snap?.uniqueTrackerEntitiesCount, 0)
        XCTAssertEqual(snap?.cookiesBlocked, 0)
        XCTAssertEqual(snap?.httpsUpgraded, true, "Early incoming-host httpsUpgraded must be preserved")
        XCTAssertEqual(snap?.paramsStripped, 2, "Early incoming-host trackingParamStripped must be preserved")
        XCTAssertEqual(snap?.recentEvents.count, 2)

        // Explicit resetTabStats with preserveMatchingHostEvents: false clears everything (e.g. reload/pause).
        store.resetTabStats(forTabID: tabID, host: "new.com", isPrivate: false, securityState: .secureHTTPS)
        let afterReload = store.tabSnapshot(forTabID: tabID)
        XCTAssertEqual(afterReload?.paramsStripped, 0)
        XCTAssertEqual(afterReload?.httpsUpgraded, false)
        XCTAssertEqual(afterReload?.recentEvents.count, 0)
    }

    func testPrivateLatchingAcrossStateUpdatesPreventsPersistence() {
        let (store, _) = makeTempStore()
        let tabID = "latch-tab"

        store.updateConnectionSecurity(.secureHTTPS, host: "private-bank.com", forTabID: tabID, isPrivate: true)
        // Subsequent call passing isPrivate: false or nil must NEVER un-latch private mode.
        store.updateConnectionSecurity(.secureHTTPS, host: "private-other.com", forTabID: tabID, isPrivate: false)
        store.updateProtectionsEnabled(false, forTabID: tabID, isPrivate: nil)
        store.recordPageVisit(host: "private-other.com", tabID: tabID, isPrivate: false)
        store.record(PrivacyEvent(eventType: .trackerBlocked, pageHost: "private-other.com", trackerHost: "doubleclick.net", count: 2, isPrivate: false), forTabID: tabID)
        store.flushSync()

        XCTAssertEqual(store.tabSnapshot(forTabID: tabID)?.isPrivate, true)
        XCTAssertEqual(store.summary(days: 30), .empty)
    }

    func testBackToBackPageVisitsAreDeduplicatedPerTabAndHost() {
        let (store, dbURL) = makeTempStore()
        let now = Date()

        store.recordPageVisit(host: "example.com", tabID: "tab-a", isPrivate: false, timestamp: now)
        store.record(PrivacyEvent(eventType: .pageVisited, pageHost: "www.example.com", timestamp: now), forTabID: "tab-a")
        store.recordPageVisit(host: "https://example.com/subpage", tabID: "tab-a", isPrivate: false, timestamp: now)
        // Different host on same tab should record a new row, then navigating back to example.com records again.
        store.recordPageVisit(host: "another.org", tabID: "tab-a", isPrivate: false, timestamp: now)
        store.recordPageVisit(host: "example.com", tabID: "tab-a", isPrivate: false, timestamp: now)
        store.flushSync()

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let db { sqlite3_close_v2(db) } }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM page_visits;", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 3, "Back-to-back duplicate (tabID, host) visits should deduplicate to 3 rows")
    }

    func testCloseForResetFlushesDeletesAndClosesDatabaseHandle() throws {
        let (store, dbURL) = makeTempStore()
        let now = Date()

        store.recordPageVisit(host: "wipe-me.com", tabID: "t1", isPrivate: false, timestamp: now)
        store.record(PrivacyEvent(eventType: .trackerBlocked, pageHost: "wipe-me.com", trackerHost: "criteo.com", count: 4, timestamp: now), forTabID: "t1")
        store.flushSync()
        XCTAssertEqual(store.summary(days: 30, now: now).totalBlockedRequests, 4)

        store.closeForReset()
        XCTAssertNil(store.tabSnapshot(forTabID: "t1"))
        XCTAssertEqual(store.summary(days: 30, now: now), .empty)

        // Removing the SQLite file after closeForReset must succeed cleanly without open handle interference.
        try FileManager.default.removeItem(at: dbURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
    }
}
