import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class PrivacyReportStore {
    static let shared = PrivacyReportStore()
    static let defaultRetentionDays: Int = 30

    private let databaseURL: URL
    private let retentionDays: Int
    private let debounceNotifications: Bool
    private let dbQueue = DispatchQueue(label: "com.safarium.privacy.store", qos: .utility)
    private let snapshotLock = NSLock()
    private let notificationLock = NSLock()

    private var db: OpaquePointer?
    private var tabSnapshots: [String: TabPrivacySnapshot] = [:]
    private var lastRecordedVisitHostByTab: [String: String] = [:]
    private var pendingNotificationWorkItem: DispatchWorkItem?

    init(databaseURL: URL? = nil, retentionDays: Int = PrivacyReportStore.defaultRetentionDays, debounceNotifications: Bool = true) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.databaseURL = appSupport
                .appendingPathComponent("Safarium", isDirectory: true)
                .appendingPathComponent("privacy-report.sqlite", isDirectory: false)
        }
        self.retentionDays = max(1, retentionDays)
        self.debounceNotifications = debounceNotifications

        dbQueue.sync {
            openAndInitializeDatabaseLocked()
            pruneExpiredLocked(olderThanDays: self.retentionDays, now: Date())
        }
    }

    deinit {
        notificationLock.lock()
        pendingNotificationWorkItem?.cancel()
        pendingNotificationWorkItem = nil
        notificationLock.unlock()

        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    // MARK: - Recording Events & Page Visits

    func record(_ event: PrivacyEvent, forTabID tabID: String? = nil) {
        let sanitized = sanitizeEvent(event)

        var isPrivateTab = sanitized.isPrivate
        var shouldPersistPageVisit = true

        if let tabID {
            snapshotLock.lock()
            var snapshot = tabSnapshots[tabID] ?? TabPrivacySnapshot.empty(
                tabID: tabID,
                host: sanitized.pageHost,
                isPrivate: sanitized.isPrivate
            )
            snapshot.isPrivate = snapshot.isPrivate || sanitized.isPrivate
            isPrivateTab = snapshot.isPrivate

            if sanitized.eventType == .pageVisited, !sanitized.pageHost.isEmpty {
                if lastRecordedVisitHostByTab[tabID] == sanitized.pageHost {
                    shouldPersistPageVisit = false
                } else {
                    lastRecordedVisitHostByTab[tabID] = sanitized.pageHost
                }
            }

            applyEvent(sanitized, to: &snapshot)
            tabSnapshots[tabID] = snapshot
            snapshotLock.unlock()
        }

        // Strict Private Browsing isolation: never persist anything to SQLite.
        guard !isPrivateTab else { return }

        if sanitized.eventType == .pageVisited {
            guard shouldPersistPageVisit, !sanitized.pageHost.isEmpty else { return }
            let host = sanitized.pageHost
            let timestamp = sanitized.timestamp.timeIntervalSince1970
            dbQueue.async { [weak self] in
                guard let self else { return }
                self.insertPageVisitLocked(host: host, timestamp: timestamp)
                self.scheduleReportNotification()
            }
            return
        }

        dbQueue.async { [weak self] in
            guard let self else { return }
            self.insertEventLocked(sanitized)
            self.scheduleReportNotification()
        }
    }

    func recordPageVisit(host: String, tabID: String? = nil, isPrivate: Bool, timestamp: Date = Date()) {
        let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(host)
        var effectivePrivate = isPrivate
        var shouldPersist = true

        if let tabID {
            snapshotLock.lock()
            var snapshot = tabSnapshots[tabID] ?? TabPrivacySnapshot.empty(
                tabID: tabID,
                host: cleanHost,
                isPrivate: isPrivate
            )
            snapshot.isPrivate = snapshot.isPrivate || isPrivate
            effectivePrivate = snapshot.isPrivate

            if !cleanHost.isEmpty {
                if !snapshot.host.isEmpty, snapshot.host != cleanHost {
                    transitionSnapshotHost(&snapshot, to: cleanHost, preserveMatchingHostEvents: true)
                } else {
                    snapshot.host = cleanHost
                }

                if lastRecordedVisitHostByTab[tabID] == cleanHost {
                    shouldPersist = false
                } else {
                    lastRecordedVisitHostByTab[tabID] = cleanHost
                }
            }
            tabSnapshots[tabID] = snapshot
            snapshotLock.unlock()
        }

        guard !effectivePrivate, shouldPersist, !cleanHost.isEmpty else { return }
        let ts = timestamp.timeIntervalSince1970
        dbQueue.async { [weak self] in
            guard let self else { return }
            self.insertPageVisitLocked(host: cleanHost, timestamp: ts)
            self.scheduleReportNotification()
        }
    }

    // MARK: - Live Per-Tab State

    func updateConnectionSecurity(
        _ state: ConnectionSecurityState,
        host: String,
        forTabID tabID: String,
        isPrivate: Bool? = nil
    ) {
        let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(host)
        snapshotLock.lock()
        var snapshot = tabSnapshots[tabID] ?? TabPrivacySnapshot.empty(
            tabID: tabID,
            host: cleanHost,
            isPrivate: isPrivate ?? false,
            securityState: state
        )
        if let isPrivate, isPrivate {
            snapshot.isPrivate = true
        }
        snapshot.securityState = state
        if !cleanHost.isEmpty {
            if !snapshot.host.isEmpty, snapshot.host != cleanHost {
                transitionSnapshotHost(&snapshot, to: cleanHost, preserveMatchingHostEvents: true)
            } else {
                snapshot.host = cleanHost
            }
        }
        if state == .upgradedHTTPS {
            snapshot.httpsUpgraded = true
        }
        tabSnapshots[tabID] = snapshot
        snapshotLock.unlock()
    }

    func updateProtectionsEnabled(_ enabled: Bool, forTabID tabID: String, isPrivate: Bool? = nil) {
        snapshotLock.lock()
        var snapshot = tabSnapshots[tabID] ?? TabPrivacySnapshot.empty(
            tabID: tabID,
            isPrivate: isPrivate ?? false,
            protectionsEnabled: enabled
        )
        if let isPrivate, isPrivate {
            snapshot.isPrivate = true
        }
        snapshot.protectionsEnabled = enabled
        tabSnapshots[tabID] = snapshot
        snapshotLock.unlock()
    }

    func resetTabStats(
        forTabID tabID: String,
        host: String,
        isPrivate: Bool,
        securityState: ConnectionSecurityState = .internalPage,
        protectionsEnabled: Bool = true,
        preserveMatchingHostEvents: Bool = false
    ) {
        let cleanHost = PrivacyDomainClassifier.sanitizeHostForStorage(host)
        snapshotLock.lock()
        let preservedEvents: [PrivacyEvent]
        if preserveMatchingHostEvents, !cleanHost.isEmpty, let existing = tabSnapshots[tabID] {
            preservedEvents = existing.recentEvents.filter { $0.pageHost == cleanHost }
        } else {
            preservedEvents = []
        }

        var nextSnapshot = TabPrivacySnapshot.empty(
            tabID: tabID,
            host: cleanHost,
            isPrivate: isPrivate,
            securityState: securityState,
            protectionsEnabled: protectionsEnabled
        )
        for event in preservedEvents {
            applyEvent(event, to: &nextSnapshot)
        }
        tabSnapshots[tabID] = nextSnapshot
        snapshotLock.unlock()
    }

    func removeTabStats(forTabID tabID: String) {
        snapshotLock.lock()
        tabSnapshots.removeValue(forKey: tabID)
        lastRecordedVisitHostByTab.removeValue(forKey: tabID)
        snapshotLock.unlock()
    }

    func tabSnapshot(forTabID tabID: String) -> TabPrivacySnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return tabSnapshots[tabID]
    }

    // MARK: - Aggregation & Maintenance

    func summary(days: Int = 30, now: Date = Date()) -> PrivacyReportSummary {
        let windowDays = max(1, days)
        let cutoff = now.timeIntervalSince1970 - TimeInterval(windowDays) * 86_400.0
        return dbQueue.sync {
            computeSummaryLocked(windowDays: windowDays, cutoffTimestamp: cutoff)
        }
    }

    func pruneExpired(olderThanDays days: Int? = nil, now: Date = Date()) {
        let targetDays = max(1, days ?? retentionDays)
        dbQueue.async { [weak self] in
            self?.pruneExpiredLocked(olderThanDays: targetDays, now: now)
        }
    }

    func clearEvents(since cutoff: Date) {
        let cutoffTs = cutoff.timeIntervalSince1970
        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            self.executeDelete(sql: "DELETE FROM privacy_events WHERE timestamp >= ?;", bindTimestamp: cutoffTs, db: db)
            self.executeDelete(sql: "DELETE FROM page_visits WHERE timestamp >= ?;", bindTimestamp: cutoffTs, db: db)
            self.postReportDidChangeImmediately()
        }
    }

    func clearAll() {
        snapshotLock.lock()
        lastRecordedVisitHostByTab.removeAll()
        snapshotLock.unlock()

        dbQueue.async { [weak self] in
            guard let self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM privacy_events;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM page_visits;", nil, nil, nil)
            self.postReportDidChangeImmediately()
        }
    }

    func flushSync() {
        dbQueue.sync {}
    }

    func closeForReset() {
        notificationLock.lock()
        pendingNotificationWorkItem?.cancel()
        pendingNotificationWorkItem = nil
        notificationLock.unlock()

        snapshotLock.lock()
        tabSnapshots.removeAll()
        lastRecordedVisitHostByTab.removeAll()
        snapshotLock.unlock()

        dbQueue.sync {
            if let db = self.db {
                sqlite3_exec(db, "DELETE FROM privacy_events;", nil, nil, nil)
                sqlite3_exec(db, "DELETE FROM page_visits;", nil, nil, nil)
                sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
                sqlite3_close_v2(db)
                self.db = nil
            }
        }
    }

    // MARK: - Private Event Normalization & Snapshot Updates

    private func sanitizeEvent(_ event: PrivacyEvent) -> PrivacyEvent {
        let cleanPageHost = PrivacyDomainClassifier.sanitizeHostForStorage(event.pageHost)
        let cleanTrackerHost = PrivacyDomainClassifier.sanitizeHostForStorage(event.trackerHost)
        var resolvedEntity = PrivacyDomainClassifier.sanitizeHostForStorage(event.entityDomain)
        var resolvedOwner = event.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedCategory = event.category

        if resolvedEntity.isEmpty, !cleanTrackerHost.isEmpty {
            if let meta = PrivacyDomainClassifier.trackerMetadata(forHost: cleanTrackerHost) {
                resolvedEntity = meta.entityDomain
                if resolvedOwner.isEmpty {
                    resolvedOwner = meta.ownerName
                }
                if resolvedCategory == .other {
                    resolvedCategory = meta.category
                }
            } else {
                resolvedEntity = PrivacyDomainClassifier.registrableDomain(for: cleanTrackerHost)
            }
        } else if resolvedOwner.isEmpty, !resolvedEntity.isEmpty {
            if let meta = PrivacyDomainClassifier.trackerMetadata(forHost: resolvedEntity) {
                resolvedOwner = meta.ownerName
                if resolvedCategory == .other {
                    resolvedCategory = meta.category
                }
            }
        }

        if !resolvedEntity.isEmpty {
            resolvedOwner = PrivacyDomainClassifier.displayOwner(entityDomain: resolvedEntity, rawOwner: resolvedOwner)
        }

        return PrivacyEvent(
            id: event.id,
            eventType: event.eventType,
            pageHost: cleanPageHost,
            trackerHost: cleanTrackerHost,
            entityDomain: resolvedEntity,
            ownerName: resolvedOwner,
            category: resolvedCategory,
            detail: event.detail,
            count: max(1, event.count),
            isPrivate: event.isPrivate,
            timestamp: event.timestamp
        )
    }

    private func applyEvent(_ event: PrivacyEvent, to snapshot: inout TabPrivacySnapshot) {
        if snapshot.host.isEmpty, !event.pageHost.isEmpty {
            snapshot.host = event.pageHost
        }

        switch event.eventType {
        case .trackerBlocked, .cookieBlocked, .fingerprintBlocked, .bounceTrackerMitigated:
            snapshot.totalTrackersBlocked += event.count
            if event.eventType == .cookieBlocked {
                snapshot.cookiesBlocked += event.count
            } else if event.eventType == .fingerprintBlocked {
                snapshot.fingerprintsBlocked += event.count
            } else if event.eventType == .bounceTrackerMitigated {
                snapshot.bounceTrackersMitigated += event.count
            }

            if !event.entityDomain.isEmpty {
                if let existingIndex = snapshot.trackers.firstIndex(where: { $0.entityDomain == event.entityDomain }) {
                    let existing = snapshot.trackers[existingIndex]
                    var domains = Set(existing.trackerDomains)
                    if !event.trackerHost.isEmpty {
                        domains.insert(event.trackerHost)
                    }
                    var sites = Set(existing.websites)
                    if !snapshot.host.isEmpty {
                        sites.insert(snapshot.host)
                    }
                    let updatedCategory = existing.category == .other ? event.category : existing.category
                    let updatedOwner = existing.ownerName.isEmpty ? event.ownerName : existing.ownerName
                    snapshot.trackers[existingIndex] = PrivacyReportTrackerEntry(
                        entityDomain: existing.entityDomain,
                        ownerName: updatedOwner,
                        category: updatedCategory,
                        trackerDomains: domains.sorted(),
                        websites: sites.sorted(),
                        totalBlockedRequests: existing.totalBlockedRequests + event.count,
                        lastSeen: max(existing.lastSeen, event.timestamp)
                    )
                } else {
                    let domains = event.trackerHost.isEmpty ? [] : [event.trackerHost]
                    let sites = snapshot.host.isEmpty ? [] : [snapshot.host]
                    snapshot.trackers.append(
                        PrivacyReportTrackerEntry(
                            entityDomain: event.entityDomain,
                            ownerName: event.ownerName,
                            category: event.category,
                            trackerDomains: domains,
                            websites: sites,
                            totalBlockedRequests: event.count,
                            lastSeen: event.timestamp
                        )
                    )
                }
                snapshot.trackers.sort { lhs, rhs in
                    if lhs.totalBlockedRequests != rhs.totalBlockedRequests {
                        return lhs.totalBlockedRequests > rhs.totalBlockedRequests
                    }
                    return lhs.entityDomain < rhs.entityDomain
                }
                snapshot.uniqueTrackerEntitiesCount = snapshot.trackers.count
            }

        case .trackingParamStripped:
            snapshot.paramsStripped += event.count

        case .httpsUpgraded:
            snapshot.httpsUpgraded = true

        case .pageVisited:
            if !event.pageHost.isEmpty {
                if !snapshot.host.isEmpty, snapshot.host != event.pageHost {
                    transitionSnapshotHost(&snapshot, to: event.pageHost, preserveMatchingHostEvents: true)
                } else {
                    snapshot.host = event.pageHost
                }
            }
        }

        if event.eventType != .pageVisited {
            snapshot.recentEvents.append(event)
            if snapshot.recentEvents.count > 100 {
                snapshot.recentEvents.removeFirst(snapshot.recentEvents.count - 100)
            }
        }
    }

    private func transitionSnapshotHost(
        _ snapshot: inout TabPrivacySnapshot,
        to newHost: String,
        preserveMatchingHostEvents: Bool
    ) {
        let preservedEvents: [PrivacyEvent]
        if preserveMatchingHostEvents, !newHost.isEmpty {
            preservedEvents = snapshot.recentEvents.filter { $0.pageHost == newHost }
        } else {
            preservedEvents = []
        }

        snapshot.host = newHost
        snapshot.trackers = []
        snapshot.totalTrackersBlocked = 0
        snapshot.uniqueTrackerEntitiesCount = 0
        snapshot.cookiesBlocked = 0
        snapshot.paramsStripped = 0
        snapshot.fingerprintsBlocked = 0
        snapshot.httpsUpgraded = false
        snapshot.bounceTrackersMitigated = 0
        snapshot.recentEvents = []

        for event in preservedEvents {
            applyEvent(event, to: &snapshot)
        }
    }

    // MARK: - SQLite Helpers (dbQueue only)

    private func openAndInitializeDatabaseLocked() {
        let dir = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close_v2(handle)
            }
            return
        }
        db = handle

        sqlite3_exec(handle, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA busy_timeout = 3000;", nil, nil, nil)

        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS privacy_events (
            id TEXT PRIMARY KEY,
            event_type TEXT NOT NULL,
            page_host TEXT NOT NULL,
            tracker_host TEXT NOT NULL,
            entity_domain TEXT NOT NULL,
            owner_name TEXT NOT NULL,
            category TEXT NOT NULL,
            detail TEXT NOT NULL,
            count INTEGER NOT NULL,
            timestamp REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_privacy_events_timestamp ON privacy_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_privacy_events_page_host ON privacy_events(page_host);
        CREATE INDEX IF NOT EXISTS idx_privacy_events_entity_domain ON privacy_events(entity_domain);

        CREATE TABLE IF NOT EXISTS page_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            page_host TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_page_visits_timestamp ON page_visits(timestamp);
        CREATE INDEX IF NOT EXISTS idx_page_visits_page_host ON page_visits(page_host);
        """
        sqlite3_exec(handle, schemaSQL, nil, nil, nil)
    }

    private func insertEventLocked(_ event: PrivacyEvent) {
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO privacy_events
        (id, event_type, page_host, tracker_host, entity_domain, owner_name, category, detail, count, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(event.id.uuidString, at: 1, in: stmt)
        bindText(event.eventType.rawValue, at: 2, in: stmt)
        bindText(event.pageHost, at: 3, in: stmt)
        bindText(event.trackerHost, at: 4, in: stmt)
        bindText(event.entityDomain, at: 5, in: stmt)
        bindText(event.ownerName, at: 6, in: stmt)
        bindText(event.category.rawValue, at: 7, in: stmt)
        bindText(event.detail, at: 8, in: stmt)
        sqlite3_bind_int(stmt, 9, Int32(event.count))
        sqlite3_bind_double(stmt, 10, event.timestamp.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func insertPageVisitLocked(host: String, timestamp: Double) {
        guard let db else { return }
        let sql = "INSERT INTO page_visits (page_host, timestamp) VALUES (?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(host, at: 1, in: stmt)
        sqlite3_bind_double(stmt, 2, timestamp)
        sqlite3_step(stmt)
    }

    private func pruneExpiredLocked(olderThanDays days: Int, now: Date) {
        guard let db else { return }
        let cutoff = now.timeIntervalSince1970 - TimeInterval(days) * 86_400.0
        executeDelete(sql: "DELETE FROM privacy_events WHERE timestamp < ?;", bindTimestamp: cutoff, db: db)
        executeDelete(sql: "DELETE FROM page_visits WHERE timestamp < ?;", bindTimestamp: cutoff, db: db)
    }

    private func executeDelete(sql: String, bindTimestamp: Double, db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, bindTimestamp)
        sqlite3_step(stmt)
    }

    private func bindText(_ string: String, at index: Int32, in stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, index, string, -1, sqliteTransientDestructor)
    }

    private func computeSummaryLocked(windowDays: Int, cutoffTimestamp: Double) -> PrivacyReportSummary {
        guard let db else {
            return PrivacyReportSummary(
                uniqueTrackersPrevented: 0,
                totalBlockedRequests: 0,
                totalWebsitesVisited: 0,
                websitesContactingTrackersCount: 0,
                websitesContactingTrackersPercent: 0,
                mostContactedTracker: nil,
                httpsUpgradesCount: 0,
                trackingParamsStrippedCount: 0,
                fingerprintingAttemptsBlocked: 0,
                cookiesBlockedCount: 0,
                bounceTrackersMitigatedCount: 0,
                categoryBreakdown: [:],
                websites: [],
                trackers: [],
                windowDays: windowDays
            )
        }

        var visitedHosts = Set<String>()
        var lastVisitedByHost: [String: Date] = [:]

        // 1. Read page visits in window.
        let visitSQL = "SELECT page_host, MAX(timestamp) FROM page_visits WHERE timestamp >= ? GROUP BY page_host;"
        var visitStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, visitSQL, -1, &visitStmt, nil) == SQLITE_OK, let visitStmt {
            defer { sqlite3_finalize(visitStmt) }
            sqlite3_bind_double(visitStmt, 1, cutoffTimestamp)
            while sqlite3_step(visitStmt) == SQLITE_ROW {
                guard let hostC = sqlite3_column_text(visitStmt, 0) else { continue }
                let host = String(cString: hostC)
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(visitStmt, 1))
                if !host.isEmpty {
                    visitedHosts.insert(host)
                    if let existing = lastVisitedByHost[host] {
                        lastVisitedByHost[host] = max(existing, ts)
                    } else {
                        lastVisitedByHost[host] = ts
                    }
                }
            }
        }

        // 2. Read privacy events in window and aggregate.
        struct SiteTrackerAccumulator {
            var ownerName: String = ""
            var categoryCounts: [PrivacyTrackerCategory: Int] = [:]
            var trackerDomains: Set<String> = []
            var blockedCount: Int = 0
            var eventTypes: Set<PrivacyEventType> = []
            var lastSeen: Date = .distantPast
        }

        struct WebsiteAccumulator {
            var trackers: [String: SiteTrackerAccumulator] = [:]
            var totalBlockedRequests: Int = 0
            var cookiesBlocked: Int = 0
            var paramsStripped: Int = 0
            var fingerprintsBlocked: Int = 0
            var httpsUpgrades: Int = 0
            var bounceTrackersMitigated: Int = 0
            var lastVisited: Date = .distantPast
        }

        struct TrackerAccumulator {
            var ownerName: String = ""
            var categoryCounts: [PrivacyTrackerCategory: Int] = [:]
            var trackerDomains: Set<String> = []
            var websites: Set<String> = []
            var totalBlockedRequests: Int = 0
            var lastSeen: Date = .distantPast
        }

        var totalBlockedRequests = 0
        var httpsUpgradesCount = 0
        var trackingParamsStrippedCount = 0
        var fingerprintingAttemptsBlocked = 0
        var cookiesBlockedCount = 0
        var bounceTrackersMitigatedCount = 0
        var categoryBreakdown: [PrivacyTrackerCategory: Int] = [:]
        var uniqueEntityDomains = Set<String>()
        var websitesContactingTrackers = Set<String>()

        var siteAccMap: [String: WebsiteAccumulator] = [:]
        var trackerAccMap: [String: TrackerAccumulator] = [:]

        let eventsSQL = """
        SELECT event_type, page_host, tracker_host, entity_domain, owner_name, category, count, timestamp
        FROM privacy_events
        WHERE timestamp >= ?;
        """
        var eventsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, eventsSQL, -1, &eventsStmt, nil) == SQLITE_OK, let eventsStmt {
            defer { sqlite3_finalize(eventsStmt) }
            sqlite3_bind_double(eventsStmt, 1, cutoffTimestamp)
            while sqlite3_step(eventsStmt) == SQLITE_ROW {
                guard let typeC = sqlite3_column_text(eventsStmt, 0) else { continue }
                guard let eventType = PrivacyEventType(rawValue: String(cString: typeC)) else { continue }
                let pageHost = sqlite3_column_text(eventsStmt, 1).map { String(cString: $0) } ?? ""
                let trackerHost = sqlite3_column_text(eventsStmt, 2).map { String(cString: $0) } ?? ""
                let rawEntityDomain = sqlite3_column_text(eventsStmt, 3).map { String(cString: $0) } ?? ""
                let rawOwner = sqlite3_column_text(eventsStmt, 4).map { String(cString: $0) } ?? ""
                let categoryStr = sqlite3_column_text(eventsStmt, 5).map { String(cString: $0) } ?? "other"
                let category = PrivacyTrackerCategory(rawValue: categoryStr) ?? .other
                let count = max(1, Int(sqlite3_column_int(eventsStmt, 6)))
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(eventsStmt, 7))

                if !pageHost.isEmpty {
                    visitedHosts.insert(pageHost)
                    if let existing = lastVisitedByHost[pageHost] {
                        lastVisitedByHost[pageHost] = max(existing, timestamp)
                    } else {
                        lastVisitedByHost[pageHost] = timestamp
                    }
                }

                switch eventType {
                case .trackerBlocked, .cookieBlocked, .fingerprintBlocked, .bounceTrackerMitigated:
                    totalBlockedRequests += count
                    if eventType == .cookieBlocked {
                        cookiesBlockedCount += count
                    } else if eventType == .fingerprintBlocked {
                        fingerprintingAttemptsBlocked += count
                    } else if eventType == .bounceTrackerMitigated {
                        bounceTrackersMitigatedCount += count
                    }
                    categoryBreakdown[category, default: 0] += count

                    let entityDomain: String
                    if !rawEntityDomain.isEmpty {
                        entityDomain = rawEntityDomain
                    } else if !trackerHost.isEmpty {
                        entityDomain = PrivacyDomainClassifier.registrableDomain(for: trackerHost)
                    } else {
                        entityDomain = ""
                    }
                    let ownerName = entityDomain.isEmpty
                        ? rawOwner
                        : PrivacyDomainClassifier.displayOwner(entityDomain: entityDomain, rawOwner: rawOwner)

                    if !entityDomain.isEmpty {
                        uniqueEntityDomains.insert(entityDomain)
                        var tAcc = trackerAccMap[entityDomain] ?? TrackerAccumulator()
                        if tAcc.ownerName.isEmpty, !ownerName.isEmpty {
                            tAcc.ownerName = ownerName
                        }
                        tAcc.categoryCounts[category, default: 0] += count
                        if !trackerHost.isEmpty {
                            tAcc.trackerDomains.insert(trackerHost)
                        }
                        if !pageHost.isEmpty {
                            tAcc.websites.insert(pageHost)
                        }
                        tAcc.totalBlockedRequests += count
                        tAcc.lastSeen = max(tAcc.lastSeen, timestamp)
                        trackerAccMap[entityDomain] = tAcc
                    }

                    if !pageHost.isEmpty {
                        websitesContactingTrackers.insert(pageHost)
                        var wAcc = siteAccMap[pageHost] ?? WebsiteAccumulator()
                        wAcc.totalBlockedRequests += count
                        if eventType == .cookieBlocked {
                            wAcc.cookiesBlocked += count
                        } else if eventType == .fingerprintBlocked {
                            wAcc.fingerprintsBlocked += count
                        } else if eventType == .bounceTrackerMitigated {
                            wAcc.bounceTrackersMitigated += count
                        }
                        wAcc.lastVisited = max(wAcc.lastVisited, timestamp)

                        if !entityDomain.isEmpty {
                            var stAcc = wAcc.trackers[entityDomain] ?? SiteTrackerAccumulator()
                            if stAcc.ownerName.isEmpty, !ownerName.isEmpty {
                                stAcc.ownerName = ownerName
                            }
                            stAcc.categoryCounts[category, default: 0] += count
                            if !trackerHost.isEmpty {
                                stAcc.trackerDomains.insert(trackerHost)
                            }
                            stAcc.blockedCount += count
                            stAcc.eventTypes.insert(eventType)
                            stAcc.lastSeen = max(stAcc.lastSeen, timestamp)
                            wAcc.trackers[entityDomain] = stAcc
                        }
                        siteAccMap[pageHost] = wAcc
                    }

                case .trackingParamStripped:
                    trackingParamsStrippedCount += count
                    if !pageHost.isEmpty {
                        var wAcc = siteAccMap[pageHost] ?? WebsiteAccumulator()
                        wAcc.paramsStripped += count
                        wAcc.lastVisited = max(wAcc.lastVisited, timestamp)
                        siteAccMap[pageHost] = wAcc
                    }

                case .httpsUpgraded:
                    httpsUpgradesCount += count
                    if !pageHost.isEmpty {
                        var wAcc = siteAccMap[pageHost] ?? WebsiteAccumulator()
                        wAcc.httpsUpgrades += count
                        wAcc.lastVisited = max(wAcc.lastVisited, timestamp)
                        siteAccMap[pageHost] = wAcc
                    }

                case .pageVisited:
                    break
                }
            }
        }

        let trackers: [PrivacyReportTrackerEntry] = trackerAccMap.map { entityDomain, acc in
            let primaryCategory = primaryCategory(from: acc.categoryCounts)
            return PrivacyReportTrackerEntry(
                entityDomain: entityDomain,
                ownerName: PrivacyDomainClassifier.displayOwner(entityDomain: entityDomain, rawOwner: acc.ownerName),
                category: primaryCategory,
                trackerDomains: acc.trackerDomains.sorted(),
                websites: acc.websites.sorted(),
                totalBlockedRequests: acc.totalBlockedRequests,
                lastSeen: acc.lastSeen
            )
        }.sorted { lhs, rhs in
            if lhs.websiteCount != rhs.websiteCount {
                return lhs.websiteCount > rhs.websiteCount
            }
            if lhs.totalBlockedRequests != rhs.totalBlockedRequests {
                return lhs.totalBlockedRequests > rhs.totalBlockedRequests
            }
            return lhs.entityDomain < rhs.entityDomain
        }

        let websites: [PrivacyReportWebsiteEntry] = siteAccMap.compactMap { host, acc in
            let hasActivity = acc.totalBlockedRequests > 0 || acc.paramsStripped > 0 || acc.httpsUpgrades > 0
            guard hasActivity else { return nil }

            let trackerDetails: [PrivacyReportSiteTrackerDetail] = acc.trackers.map { entityDomain, stAcc in
                PrivacyReportSiteTrackerDetail(
                    entityDomain: entityDomain,
                    ownerName: PrivacyDomainClassifier.displayOwner(entityDomain: entityDomain, rawOwner: stAcc.ownerName),
                    category: primaryCategory(from: stAcc.categoryCounts),
                    trackerDomains: stAcc.trackerDomains.sorted(),
                    blockedCount: stAcc.blockedCount,
                    eventTypes: stAcc.eventTypes,
                    lastSeen: stAcc.lastSeen
                )
            }.sorted { lhs, rhs in
                if lhs.blockedCount != rhs.blockedCount {
                    return lhs.blockedCount > rhs.blockedCount
                }
                return lhs.entityDomain < rhs.entityDomain
            }

            let resolvedLastVisited = max(acc.lastVisited, lastVisitedByHost[host] ?? .distantPast)
            return PrivacyReportWebsiteEntry(
                host: host,
                trackers: trackerDetails,
                totalBlockedRequests: acc.totalBlockedRequests,
                uniqueTrackerCount: trackerDetails.count,
                cookiesBlocked: acc.cookiesBlocked,
                paramsStripped: acc.paramsStripped,
                fingerprintsBlocked: acc.fingerprintsBlocked,
                httpsUpgrades: acc.httpsUpgrades,
                bounceTrackersMitigated: acc.bounceTrackersMitigated,
                lastVisited: resolvedLastVisited
            )
        }.sorted { lhs, rhs in
            if lhs.uniqueTrackerCount != rhs.uniqueTrackerCount {
                return lhs.uniqueTrackerCount > rhs.uniqueTrackerCount
            }
            if lhs.totalBlockedRequests != rhs.totalBlockedRequests {
                return lhs.totalBlockedRequests > rhs.totalBlockedRequests
            }
            return lhs.host < rhs.host
        }

        let totalWebsitesVisited = visitedHosts.count
        let contactingCount = websitesContactingTrackers.count
        let percent = totalWebsitesVisited > 0
            ? min(100, max(0, Int((Double(contactingCount) * 100.0 / Double(totalWebsitesVisited)).rounded())))
            : 0

        return PrivacyReportSummary(
            uniqueTrackersPrevented: uniqueEntityDomains.count,
            totalBlockedRequests: totalBlockedRequests,
            totalWebsitesVisited: totalWebsitesVisited,
            websitesContactingTrackersCount: contactingCount,
            websitesContactingTrackersPercent: percent,
            mostContactedTracker: trackers.first,
            httpsUpgradesCount: httpsUpgradesCount,
            trackingParamsStrippedCount: trackingParamsStrippedCount,
            fingerprintingAttemptsBlocked: fingerprintingAttemptsBlocked,
            cookiesBlockedCount: cookiesBlockedCount,
            bounceTrackersMitigatedCount: bounceTrackersMitigatedCount,
            categoryBreakdown: categoryBreakdown,
            websites: websites,
            trackers: trackers,
            windowDays: windowDays
        )
    }

    private func primaryCategory(from counts: [PrivacyTrackerCategory: Int]) -> PrivacyTrackerCategory {
        guard !counts.isEmpty else { return .other }
        return counts.max { lhs, rhs in
            let lhsNonGeneric = lhs.key != .other && lhs.key != .cookie
            let rhsNonGeneric = rhs.key != .other && rhs.key != .cookie
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            if lhsNonGeneric != rhsNonGeneric {
                return !lhsNonGeneric && rhsNonGeneric
            }
            return lhs.key.rawValue > rhs.key.rawValue
        }?.key ?? .other
    }

    // MARK: - Notifications

    private func scheduleReportNotification() {
        guard debounceNotifications else {
            postReportDidChangeImmediately()
            return
        }

        notificationLock.lock()
        pendingNotificationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.notificationLock.lock()
            self.pendingNotificationWorkItem = nil
            self.notificationLock.unlock()
            NotificationCenter.default.post(name: .safariumPrivacyReportDidChange, object: self)
        }
        pendingNotificationWorkItem = item
        notificationLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func postReportDidChangeImmediately() {
        notificationLock.lock()
        pendingNotificationWorkItem?.cancel()
        pendingNotificationWorkItem = nil
        notificationLock.unlock()

        if Thread.isMainThread {
            NotificationCenter.default.post(name: .safariumPrivacyReportDidChange, object: self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: .safariumPrivacyReportDidChange, object: self)
            }
        }
    }
}
