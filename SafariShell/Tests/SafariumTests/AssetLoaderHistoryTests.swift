import XCTest
@testable import Safarium

/// Browsing history persistence, visit recording, title updates, merge, clear ranges, pruning and disk ordering.
final class AssetLoaderHistoryTests: HermeticTestCase {
    private typealias Entry = AssetLoader.HistoryEntry

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        PersistenceTestSupport.resetPersistence()
    }

    override func tearDown() {
        PersistenceTestSupport.resetPersistence()
        super.tearDown()
    }

    private var loader: AssetLoader { AssetLoader.shared }

    private func entry(_ url: String, title: String = "Title", count: Int = 1, at date: Date) -> Entry {
        PersistenceTestSupport.historyEntry(url, title: title, count: count, at: date)
    }

    // MARK: - Codable models

    func testHistoryEntryRoundTripsThroughJSONIncludingExtremeCountAndUnicode() throws {
        let original = Entry(title: "\u{00DC}ber \u{65E5}\u{672C}\u{8A9E} \u{1F389}", url: "https://a.example/x?q=1",
                             visitCount: Int.max, lastVisited: Date(timeIntervalSince1970: 1_700_000_000.25))
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testHistoryEntryDecodeRejectsMissingOrMistypedRequiredFields() {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(Entry.self, from: Data(#"{"title":"x"}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(Entry.self, from: Data(#"{"title":"x","url":"https://a.example/","visitCount":1}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(Entry.self, from: Data(#"{"title":"x","url":"https://a.example/","visitCount":"many","lastVisited":0}"#.utf8)))
    }

    func testHistoryEntryDecodesMaximumCountAndReferenceDate() throws {
        let json = #"{"title":"","url":"https://a.example/","visitCount":9223372036854775807,"lastVisited":0}"#
        let decoded = try JSONDecoder().decode(Entry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.visitCount, Int.max)
        XCTAssertEqual(decoded.lastVisited, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(decoded.title, "")
    }

    func testBookmarkEntryDecodesWithoutOptionalColor() throws {
        let decoded = try JSONDecoder().decode(AssetLoader.BookmarkEntry.self, from: Data(#"{"id":"b1","title":"T","url":"https://b.example/"}"#.utf8))
        XCTAssertNil(decoded.color)
        XCTAssertEqual(decoded.id, "b1")
    }

    func testReadingListItemRoundTripsThroughJSON() throws {
        let item = AssetLoader.ReadingListItem(id: "r1", title: "Read me", url: "https://r.example/", addedAt: Date(timeIntervalSince1970: 1_650_000_000))
        XCTAssertEqual(try JSONDecoder().decode(AssetLoader.ReadingListItem.self, from: JSONEncoder().encode(item)), item)
    }

    // MARK: - Reading persisted history

    func testBrowsingHistoryIsEmptyWhenNoFileExists() {
        XCTAssertEqual(loader.browsingHistory(), [])
    }

    func testBrowsingHistoryReloadsPersistedFileAfterCacheReset() throws {
        let entries = [entry("https://one.example/", at: base), entry("https://two.example/", count: 4, at: base.addingTimeInterval(-60))]
        try PersistenceTestSupport.writeHistoryFile(entries)
        XCTAssertEqual(loader.browsingHistory(), entries)
    }

    func testCorruptHistoryFileReadsAsEmptyHistory() throws {
        try FileManager.default.createDirectory(at: loader.historyStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[{\"title\":".utf8).write(to: loader.historyStoreURL)
        loader.invalidateCachesForTesting()
        XCTAssertEqual(loader.browsingHistory(), [])
    }

    func testHistoryStoreLivesInsideApplicationSupportSandbox() {
        XCTAssertTrue(loader.historyStoreURL.path.hasPrefix(Self.sandboxRoot.path))
        XCTAssertTrue(loader.historyStoreURL.path.hasSuffix("Safarium/browsing-history.json"))
    }

    // MARK: - recordHistoryVisit

    func testRecordVisitInsertsNewEntryAtFrontWithCountOne() {
        loader.recordHistoryVisit(url: URL(string: "https://first.example/a")!, title: "First", visitedAt: base)
        loader.recordHistoryVisit(url: URL(string: "https://second.example/b")!, title: "Second", visitedAt: base.addingTimeInterval(10))
        let list = loader.browsingHistory()
        XCTAssertEqual(list.map(\.url), ["https://second.example/b", "https://first.example/a"])
        XCTAssertEqual(list[0].visitCount, 1)
        XCTAssertEqual(list[0].title, "Second")
        XCTAssertEqual(list[0].lastVisited, base.addingTimeInterval(10))
    }

    func testRepeatVisitIncrementsCountMovesToFrontAndUpdatesDate() {
        let url = URL(string: "https://repeat.example/page")!
        loader.recordHistoryVisit(url: url, title: "Repeat", visitedAt: base)
        loader.recordHistoryVisit(url: URL(string: "https://other.example/")!, title: "Other", visitedAt: base.addingTimeInterval(5))
        loader.recordHistoryVisit(url: url, title: "Repeat", visitedAt: base.addingTimeInterval(20))
        let list = loader.browsingHistory()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].url, "https://repeat.example/page")
        XCTAssertEqual(list[0].visitCount, 2)
        XCTAssertEqual(list[0].lastVisited, base.addingTimeInterval(20))
    }

    func testRepeatVisitWithNewTitleReplacesTitle() {
        let url = URL(string: "https://title.example/")!
        loader.recordHistoryVisit(url: url, title: "Old", visitedAt: base)
        loader.recordHistoryVisit(url: url, title: "  New  ", visitedAt: base.addingTimeInterval(1))
        XCTAssertEqual(loader.browsingHistory().first?.title, "New")
    }

    func testRepeatVisitWithEmptyTitleKeepsPreviousTitle() {
        let url = URL(string: "https://keep.example/")!
        loader.recordHistoryVisit(url: url, title: "Real Title", visitedAt: base)
        loader.recordHistoryVisit(url: url, title: "   ", visitedAt: base.addingTimeInterval(1))
        XCTAssertEqual(self.loader.browsingHistory().first?.title, "Real Title")
    
    }

    func testNewEntryWithEmptyTitleUsesDomainWithoutWww() {
        loader.recordHistoryVisit(url: URL(string: "https://www.domain.example/some/path")!, title: "", visitedAt: base)
        XCTAssertEqual(loader.browsingHistory().first?.title, "domain.example")
    }

    func testNewEntryTitleIsTrimmed() {
        loader.recordHistoryVisit(url: URL(string: "https://trim.example/")!, title: "\n  Padded Title \t", visitedAt: base)
        XCTAssertEqual(loader.browsingHistory().first?.title, "Padded Title")
    }

    func testRecordVisitIgnoresNonWebSchemes() {
        let counter = NotificationCounter(.safariumHistoryDidChange)
        for raw in ["file:///tmp/a.html", "safarium://start", "about:blank", "chrome://settings", "ftp://files.example/x", "view-source:https://a.example/"] {
            loader.recordHistoryVisit(url: URL(string: raw)!, title: "X", visitedAt: base)
        }
        XCTAssertEqual(loader.browsingHistory(), [])
        XCTAssertEqual(counter.count, 0)
    }

    func testRecordVisitAcceptsUppercaseHTTPScheme() {
        self.loader.recordHistoryVisit(url: URL(string: "HTTPS://Upper.example/")!, title: "Upper", visitedAt: self.base)
        XCTAssertEqual(self.loader.browsingHistory().count, 1)
    
    }

    func testRecordVisitStoresAbsoluteStringVerbatim() {
        loader.recordHistoryVisit(url: URL(string: "https://Verbatim.example/Path?q=1#frag")!, title: "V", visitedAt: base)
        XCTAssertEqual(loader.browsingHistory().first?.url, "https://Verbatim.example/Path?q=1#frag")
    }

    func testVisitsDifferingByPathOrNonDefaultPortStayDistinct() {
        loader.recordHistoryVisit(url: URL(string: "https://a.example/x")!, title: "X", visitedAt: base)
        loader.recordHistoryVisit(url: URL(string: "https://a.example/y")!, title: "Y", visitedAt: base)
        loader.recordHistoryVisit(url: URL(string: "https://a.example:8443/x")!, title: "Z", visitedAt: base)
        XCTAssertEqual(loader.browsingHistory().count, 3)
    }

    func testVisitsDifferingOnlyByWwwOrDefaultPortMergeIntoOneEntry() {
        loader.recordHistoryVisit(url: URL(string: "https://www.a.example/x")!, title: "First", visitedAt: base)
        loader.recordHistoryVisit(url: URL(string: "https://a.example:443/x")!, title: "Second", visitedAt: base.addingTimeInterval(1))
        let list = loader.browsingHistory()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].visitCount, 2)
        XCTAssertEqual(list[0].url, "https://a.example:443/x", "the most recent spelling of the URL is kept")
    }

    func testRecordVisitSaturatesVisitCountAtIntMax() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://sat.example/", count: Int.max, at: base)])
        loader.recordHistoryVisit(url: URL(string: "https://sat.example/")!, title: "Sat", visitedAt: base.addingTimeInterval(1))
        XCTAssertEqual(loader.browsingHistory().first?.visitCount, Int.max)
    }

    func testRecordVisitPostsHistoryChangeNotification() {
        let counter = NotificationCounter(.safariumHistoryDidChange)
        loader.recordHistoryVisit(url: URL(string: "https://notify.example/")!, title: "N", visitedAt: base)
        XCTAssertEqual(counter.count, 1)
    }

    func testRecordVisitCapsHistoryAt2500DroppingOldest() throws {
        let seeds = (0..<2500).map { i in entry("https://site\(i).example/", at: base.addingTimeInterval(-Double(i) * 60)) }
        loader.mergeImportedHistory(seeds)
        XCTAssertEqual(loader.browsingHistory().count, 2500)

        loader.recordHistoryVisit(url: URL(string: "https://fresh.example/")!, title: "Fresh", visitedAt: base.addingTimeInterval(3600))
        let list = loader.browsingHistory()
        XCTAssertEqual(list.count, 2500)
        XCTAssertEqual(list.first?.url, "https://fresh.example/")
        XCTAssertTrue(list.contains { $0.url == "https://site0.example/" })
        XCTAssertFalse(list.contains { $0.url == "https://site2499.example/" }, "the oldest entry must be evicted")
    }

    func testRecordVisitPersistsToDiskAfterWritesFlush() throws {
        loader.recordHistoryVisit(url: URL(string: "https://disk.example/p")!, title: "Disk", visitedAt: base)
        let onDisk = try PersistenceTestSupport.readHistoryFile()
        XCTAssertEqual(onDisk.map(\.url), ["https://disk.example/p"])
        XCTAssertEqual(onDisk.first?.title, "Disk")
    }

    func testFiftyRapidVisitsLandOnDiskInOrder() throws {
        for i in 0..<50 {
            loader.recordHistoryVisit(url: URL(string: "https://n\(i).example/")!, title: "N\(i)", visitedAt: base.addingTimeInterval(Double(i)))
        }
        let onDisk = try PersistenceTestSupport.readHistoryFile()
        XCTAssertEqual(onDisk.count, 50)
        XCTAssertEqual(onDisk.first?.url, "https://n49.example/")
        XCTAssertEqual(onDisk.last?.url, "https://n0.example/")
    }

    func testClearingAfterQueuedSavesWinsOnDisk() throws {
        for i in 0..<20 {
            loader.recordHistoryVisit(url: URL(string: "https://queued\(i).example/")!, title: "Q", visitedAt: base)
        }
        loader.clearHistory(range: .allHistory)
        XCTAssertEqual(try PersistenceTestSupport.readHistoryFile(), [])
        XCTAssertEqual(loader.browsingHistory(), [])
    }

    // MARK: - updateHistoryTitle

    func testUpdateHistoryTitleChangesStoredTitle() {
        loader.recordHistoryVisit(url: URL(string: "https://upd.example/page")!, title: "Loading", visitedAt: base)
        loader.updateHistoryTitle(url: URL(string: "https://upd.example/page")!, title: "Real Page Title")
        XCTAssertEqual(loader.browsingHistory().first?.title, "Real Page Title")
    }

    func testUpdateHistoryTitleTrimsAndIgnoresBlankAndAboutBlank() {
        let url = URL(string: "https://blank.example/")!
        loader.recordHistoryVisit(url: url, title: "Kept", visitedAt: base)
        for junk in ["", "   \n", "about:blank", "ABOUT:BLANK", "  about:blank  "] {
            loader.updateHistoryTitle(url: url, title: junk)
            XCTAssertEqual(loader.browsingHistory().first?.title, "Kept", "title \(junk.debugDescription) must be ignored")
        }
        loader.updateHistoryTitle(url: url, title: "  Spaced  ")
        XCTAssertEqual(loader.browsingHistory().first?.title, "Spaced")
    }

    func testUpdateHistoryTitleIgnoresNonWebURLsAndUnknownPages() {
        loader.recordHistoryVisit(url: URL(string: "https://known.example/")!, title: "Known", visitedAt: base)
        loader.updateHistoryTitle(url: URL(string: "file:///tmp/a.html")!, title: "File")
        loader.updateHistoryTitle(url: URL(string: "https://unknown.example/")!, title: "Unknown")
        XCTAssertEqual(loader.browsingHistory().map(\.title), ["Known"])
    }

    func testUpdateHistoryTitleMatchesAcrossNormalizedSpellings() {
        loader.recordHistoryVisit(url: URL(string: "https://www.spell.example/x/")!, title: "Old", visitedAt: base)
        loader.updateHistoryTitle(url: URL(string: "https://spell.example/x")!, title: "Matched")
        XCTAssertEqual(loader.browsingHistory().first?.title, "Matched")
    }

    func testUpdateHistoryTitleDoesNotPostNotification() {
        loader.recordHistoryVisit(url: URL(string: "https://quiet.example/")!, title: "Q", visitedAt: base)
        let counter = NotificationCounter(.safariumHistoryDidChange)
        loader.updateHistoryTitle(url: URL(string: "https://quiet.example/")!, title: "Changed")
        loader.updateHistoryTitle(url: URL(string: "https://quiet.example/")!, title: "Changed")
        XCTAssertEqual(counter.count, 0)
    }

    // MARK: - mergeImportedHistory

    func testMergeEmptyInputReturnsZero() {
        let counter = NotificationCounter(.safariumHistoryDidChange)
        XCTAssertEqual(loader.mergeImportedHistory([]), 0)
        XCTAssertEqual(counter.count, 0)
    }

    func testMergeAddsNewEntriesAndReportsCount() {
        let added = loader.mergeImportedHistory([
            entry("https://m1.example/", at: base),
            entry("https://m2.example/", at: base.addingTimeInterval(1))
        ])
        XCTAssertEqual(added, 2)
        XCTAssertEqual(loader.browsingHistory().count, 2)
    }

    func testMergeNewerImportUpdatesDateTitleAndKeepsHigherCount() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://merge.example/", title: "Old", count: 2, at: base)])
        let added = loader.mergeImportedHistory([entry("https://merge.example/", title: "New", count: 1, at: base.addingTimeInterval(100))])
        let merged = try XCTUnwrap(loader.browsingHistory().first)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(merged.lastVisited, base.addingTimeInterval(100))
        XCTAssertEqual(merged.title, "New")
        XCTAssertEqual(merged.visitCount, 2, "visit count is the maximum of both sides")
    }

    func testMergeOlderImportKeepsExistingDateAndTitleButRaisesCount() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://older.example/", title: "Current", count: 3, at: base)])
        _ = loader.mergeImportedHistory([entry("https://older.example/", title: "Ancient", count: 9, at: base.addingTimeInterval(-500))])
        let merged = try XCTUnwrap(loader.browsingHistory().first)
        XCTAssertEqual(merged.lastVisited, base)
        XCTAssertEqual(merged.title, "Current")
        XCTAssertEqual(merged.visitCount, 9)
    }

    func testMergeNewerImportWithEmptyTitleKeepsExistingTitle() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://blanktitle.example/", title: "Keep Me", count: 1, at: base)])
        _ = loader.mergeImportedHistory([entry("https://blanktitle.example/", title: "", count: 1, at: base.addingTimeInterval(5))])
        XCTAssertEqual(loader.browsingHistory().first?.title, "Keep Me")
    }

    func testMergeDeduplicatesWithinImportAndCountsNewURLOnce() {
        let added = loader.mergeImportedHistory([
            entry("https://dup.example/", title: "A", count: 2, at: base),
            entry("https://dup.example/", title: "B", count: 5, at: base.addingTimeInterval(1))
        ])
        let list = loader.browsingHistory()
        XCTAssertEqual(added, 1)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.visitCount, 5)
        XCTAssertEqual(list.first?.title, "B")
    }

    func testMergeSkipsBlankURLs() {
        let added = loader.mergeImportedHistory([entry("", at: base), entry("   ", at: base)])
        XCTAssertEqual(added, 0)
        XCTAssertEqual(loader.browsingHistory(), [])
    }

    func testMergeMatchesNormalizedSpellingsOfExistingEntries() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://www.norm.example/x/", count: 1, at: base)])
        let added = loader.mergeImportedHistory([entry("https://norm.example/x", count: 4, at: base.addingTimeInterval(1))])
        XCTAssertEqual(added, 0)
        XCTAssertEqual(loader.browsingHistory().count, 1)
        XCTAssertEqual(loader.browsingHistory().first?.visitCount, 4)
    }

    func testMergeResultIsSortedNewestFirst() {
        loader.mergeImportedHistory([
            entry("https://s1.example/", at: base.addingTimeInterval(-300)),
            entry("https://s2.example/", at: base.addingTimeInterval(300)),
            entry("https://s3.example/", at: base)
        ])
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://s2.example/", "https://s3.example/", "https://s1.example/"])
    }

    func testMergeCapsHistoryAt3000KeepingNewestEntries() {
        let items = (0..<3005).map { i in entry("https://cap\(i).example/", at: base.addingTimeInterval(Double(i))) }
        let added = loader.mergeImportedHistory(items)
        let list = loader.browsingHistory()
        XCTAssertEqual(added, 3005)
        XCTAssertEqual(list.count, 3000)
        XCTAssertEqual(list.first?.url, "https://cap3004.example/")
        XCTAssertFalse(list.contains { $0.url == "https://cap0.example/" })
        XCTAssertFalse(list.contains { $0.url == "https://cap4.example/" })
        XCTAssertTrue(list.contains { $0.url == "https://cap5.example/" })
    }

    func testMergePostsHistoryChangeNotification() {
        let counter = NotificationCounter(.safariumHistoryDidChange)
        loader.mergeImportedHistory([entry("https://ntf.example/", at: base)])
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - clearHistory

    func testClearHistoryDefaultRangeClearsEverything() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://old.example/", at: base.addingTimeInterval(-86_400 * 400)), entry("https://new.example/", at: Date())])
        loader.clearHistory()
        XCTAssertEqual(loader.browsingHistory(), [])
    }

    func testClearLastHourRemovesOnlyEntriesFromTheLastHour() throws {
        let now = Date()
        try PersistenceTestSupport.writeHistoryFile([
            entry("https://recent.example/", at: now.addingTimeInterval(-600)),
            entry("https://two-hours.example/", at: now.addingTimeInterval(-7_200)),
            entry("https://day.example/", at: now.addingTimeInterval(-86_400))
        ])
        loader.clearHistory(range: .lastHour)
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://two-hours.example/", "https://day.example/"])
    }

    func testClearTodayKeepsEverythingBeforeTodayStart() throws {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        try PersistenceTestSupport.writeHistoryFile([
            entry("https://yesterday-late.example/", at: todayStart.addingTimeInterval(-60)),
            entry("https://long-ago.example/", at: todayStart.addingTimeInterval(-86_400 * 3)),
            entry("https://now.example/", at: Date())
        ])
        loader.clearHistory(range: .today)
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://yesterday-late.example/", "https://long-ago.example/"])
    }

    func testClearTodayAndYesterdayKeepsEntriesBeforeYesterdayStart() throws {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        try PersistenceTestSupport.writeHistoryFile([
            entry("https://day-before.example/", at: yesterdayStart.addingTimeInterval(-3_600)),
            entry("https://yesterday.example/", at: yesterdayStart.addingTimeInterval(3_600)),
            entry("https://today.example/", at: Date())
        ])
        loader.clearHistory(range: .todayAndYesterday)
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://day-before.example/"])
    }

    func testClearHistoryPostsNotificationForEveryRange() {
        for range in AssetLoader.HistoryClearRange.allCases {
            let counter = NotificationCounter(.safariumHistoryDidChange)
            loader.clearHistory(range: range)
            XCTAssertEqual(counter.count, 1, "range \(range)")
        }
    }

    func testHistoryClearRangeRawValuesAndTitles() {
        XCTAssertEqual(AssetLoader.HistoryClearRange.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(AssetLoader.HistoryClearRange.lastHour.title, "Last Hour")
        XCTAssertEqual(AssetLoader.HistoryClearRange.today.title, "Today")
        XCTAssertEqual(AssetLoader.HistoryClearRange.todayAndYesterday.title, "Today and Yesterday")
        XCTAssertEqual(AssetLoader.HistoryClearRange.allHistory.title, "All History")
    }

    // MARK: - removeHistoryEntries

    func testRemoveEntriesMatchesNormalizedVariantsOnly() throws {
        try PersistenceTestSupport.writeHistoryFile([
            entry("https://www.a.example/x", at: base),
            entry("https://b.example/", at: base)
        ])
        loader.removeHistoryEntries(urls: ["https://a.example/x/"])
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://b.example/"])
    }

    func testRemoveEntriesWithEmptySetOrNoMatchDoesNothing() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://keep.example/", at: base)])
        let counter = NotificationCounter(.safariumHistoryDidChange)
        loader.removeHistoryEntries(urls: [])
        loader.removeHistoryEntries(urls: ["https://absent.example/"])
        XCTAssertEqual(loader.browsingHistory().count, 1)
        XCTAssertEqual(counter.count, 0)
    }

    func testRemoveEntriesPostsNotificationWhenSomethingWasRemoved() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://gone.example/", at: base)])
        let counter = NotificationCounter(.safariumHistoryDidChange)
        loader.removeHistoryEntries(urls: ["https://gone.example/"])
        XCTAssertEqual(loader.browsingHistory(), [])
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - pruneHistoryIfNeeded and retention

    func testHistoryRetentionSecondsMapsEverySelectionAndUnknownToForever() {
        let defaults = UserDefaults.standard
        let expected: [(Int, TimeInterval?)] = [(0, 86_400), (1, 86_400 * 7), (2, 86_400 * 14), (3, 86_400 * 30), (4, 86_400 * 365), (5, nil), (-1, nil)]
        for (selection, seconds) in expected {
            defaults.set(selection, forKey: BrowserSettings.Key.removeHistory)
            XCTAssertEqual(BrowserSettings.shared.historyRetentionSeconds, seconds, "selection \(selection)")
        }
    }

    func testPruneWithDefaultRetentionRemovesEntriesOlderThanAYear() throws {
        let now = Date()
        try PersistenceTestSupport.writeHistoryFile([
            entry("https://ten-days.example/", at: now.addingTimeInterval(-86_400 * 10)),
            entry("https://400-days.example/", at: now.addingTimeInterval(-86_400 * 400))
        ])
        loader.pruneHistoryIfNeeded()
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://ten-days.example/"])
    }

    func testPruneWithOneDayRetentionKeepsOnlyLastDay() throws {
        UserDefaults.standard.set(0, forKey: BrowserSettings.Key.removeHistory)
        let now = Date()
        try PersistenceTestSupport.writeHistoryFile([
            entry("https://12h.example/", at: now.addingTimeInterval(-43_200)),
            entry("https://2d.example/", at: now.addingTimeInterval(-172_800))
        ])
        loader.pruneHistoryIfNeeded()
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://12h.example/"])
    }

    func testPruneBoundaryAroundSevenDayRetention() throws {
        UserDefaults.standard.set(1, forKey: BrowserSettings.Key.removeHistory)
        let now = Date()
        try PersistenceTestSupport.writeHistoryFile([
            entry("https://inside.example/", at: now.addingTimeInterval(-(86_400 * 7 - 3_600))),
            entry("https://outside.example/", at: now.addingTimeInterval(-(86_400 * 7 + 3_600)))
        ])
        loader.pruneHistoryIfNeeded()
        XCTAssertEqual(loader.browsingHistory().map(\.url), ["https://inside.example/"])
    }

    func testPruneForeverKeepsEverythingAndDoesNotWrite() throws {
        UserDefaults.standard.set(5, forKey: BrowserSettings.Key.removeHistory)
        try PersistenceTestSupport.writeHistoryFile([entry("https://ancient.example/", at: Date(timeIntervalSince1970: 1_000_000))])
        let counter = NotificationCounter(.safariumHistoryDidChange)
        loader.pruneHistoryIfNeeded()
        XCTAssertEqual(loader.browsingHistory().count, 1)
        XCTAssertEqual(counter.count, 0)
    }

    func testPruneWithNothingExpiredDoesNotNotify() throws {
        try PersistenceTestSupport.writeHistoryFile([entry("https://fresh.example/", at: Date())])
        let counter = NotificationCounter(.safariumHistoryDidChange)
        loader.pruneHistoryIfNeeded()
        XCTAssertEqual(counter.count, 0)
    }
}
