import XCTest
import AppKit
import ObjectiveC
@testable import Safarium

/// History page: day grouping, sort order, search filtering, date titles and keys, cell content,
/// favicon cell-reuse binding, clear-button behavior and appearance-based colors.
@MainActor
final class HistoryPageViewTests: HermeticTestCase {
    private typealias Node = HistoryPageView.HistoryItemNode

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { self.setUpIsolated() }
    }

    private func setUpIsolated() {
        _ = NSApplication.shared
        AssetLoader.shared.clearHistory()
    }

    override func tearDown() {
        MainActor.assumeIsolated { self.tearDownIsolated() }
        super.tearDown()
    }

    private func tearDownIsolated() {
        AssetLoader.shared.clearHistory()
    }

    // MARK: helpers

    private func makeView() -> HistoryPageView {
        HistoryPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    /// Local-time date (the same time zone the page uses for grouping and titles).
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return Calendar.current.date(from: c)!
    }

    /// Records visits so that the stored list keeps the given order (newest first).
    private func seed(_ entries: [(title: String, url: String, at: Date)]) {
        for e in entries.reversed() {
            AssetLoader.shared.recordHistoryVisit(url: URL(string: e.url)!, title: e.title, visitedAt: e.at)
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var out: [T] = []
        for v in root.subviews {
            if let t = v as? T { out.append(t) }
            out.append(contentsOf: descendants(type, in: v))
        }
        return out
    }

    private func outlineWithColumns() -> NSOutlineView {
        let ov = NSOutlineView()
        ov.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WebsiteColumn")))
        ov.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AddressColumn")))
        return ov
    }

    private func cell(_ view: HistoryPageView, column: String, item: Any) -> NSTableCellView? {
        let ov = outlineWithColumns()
        let col = ov.tableColumns.first { $0.identifier.rawValue == column }
        return view.outlineView(ov, viewFor: col, item: item) as? NSTableCellView
    }

    private func setSearch(_ view: HistoryPageView, _ text: String) {
        let field = NSSearchField()
        field.stringValue = text
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func solidImage(size: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    private func node(_ view: HistoryPageView, group: Int, item: Int) -> Node {
        view.groups[group].items[item]
    }

    // MARK: - Empty state

    func testEmptyHistoryHasNoGroupsAndDisabledClearButton() {
        let view = makeView()
        XCTAssertTrue(view.groups.isEmpty)
        let clear = descendants(NSButton.self, in: view).first { $0.title == "Clear History..." }
        XCTAssertEqual(clear?.isEnabled, false)
    }

    func testClearButtonEnabledWhenHistoryExists() {
        seed([(title: "One", url: "https://one.example/", at: Date())])
        let view = makeView()
        let clear = descendants(NSButton.self, in: view).first { $0.title == "Clear History..." }
        XCTAssertEqual(clear?.isEnabled, true)
    }

    func testClearButtonDisablesAfterHistoryIsCleared() {
        seed([(title: "One", url: "https://one.example/", at: Date())])
        let view = makeView()
        AssetLoader.shared.clearHistory()
        XCTAssertTrue(view.groups.isEmpty)
        let clear = descendants(NSButton.self, in: view).first { $0.title == "Clear History..." }
        XCTAssertEqual(clear?.isEnabled, false)
    }

    func testClearButtonInvokesClearCallback() {
        seed([(title: "One", url: "https://one.example/", at: Date())])
        let view = makeView()
        var calls = 0
        view.onClearHistory = { calls += 1 }
        let clear = descendants(NSButton.self, in: view).first { $0.title == "Clear History..." }
        clear?.performClick(nil)
        XCTAssertEqual(calls, 1)
    }

    func testHistoryChangeNotificationRefreshesGroups() {
        let view = makeView()
        XCTAssertTrue(view.groups.isEmpty)
        AssetLoader.shared.recordHistoryVisit(url: URL(string: "https://live.example/")!, title: "Live", visitedAt: Date())
        XCTAssertEqual(view.groups.count, 1)
        XCTAssertEqual(view.groups[0].items.first?.entry.title, "Live")
    }

    // MARK: - Grouping and titles

    func testTodayEntriesUseLastVisitedTodayTitle() {
        seed([(title: "Now", url: "https://now.example/", at: Date())])
        let view = makeView()
        XCTAssertEqual(view.groups.first?.title, "Last Visited Today")
    }

    func testPastDayUsesLongDateTitleWithWeekday() {
        seed([(title: "Past", url: "https://past.example/", at: date(2026, 11, 25))])
        let view = makeView()
        XCTAssertEqual(view.groups.first?.title, "25 November 2026 Wednesday")
    }

    func testLeapDayTitle() {
        seed([(title: "Leap", url: "https://leap.example/", at: date(2028, 2, 29))])
        let view = makeView()
        XCTAssertEqual(view.groups.first?.title, "29 February 2028 Tuesday")
    }

    func testYearBoundaryTitle() {
        seed([(title: "New Year", url: "https://ny.example/", at: date(2027, 1, 1))])
        let view = makeView()
        XCTAssertEqual(view.groups.first?.title, "1 January 2027 Friday")
    }

    func testDayKeyIsISODate() {
        seed([(title: "Key", url: "https://key.example/", at: date(2026, 11, 25))])
        let view = makeView()
        XCTAssertEqual(view.groups.first?.dayKey, "2026-11-25")
    }

    func testDayKeyAcrossYearEnd() {
        XCTAssertEqual(HistoryPageView.dayKeyFormatter.string(from: date(2026, 12, 31, 23, 59, 59)), "2026-12-31")
        XCTAssertEqual(HistoryPageView.dayKeyFormatter.string(from: date(2027, 1, 1, 0, 0, 0)), "2027-01-01")
    }

    func testDayHeaderFormatterFormatsWeekdayAndMonthName() {
        XCTAssertEqual(HistoryPageView.dayHeaderFormatter.string(from: date(2026, 11, 25)), "25 November 2026 Wednesday")
        XCTAssertEqual(HistoryPageView.dayHeaderFormatter.string(from: date(2027, 1, 1)), "1 January 2027 Friday")
    }

    func testEntriesOnSameDayShareOneGroupNewestFirst() {
        seed([
            (title: "Morning", url: "https://m.example/", at: date(2026, 11, 25, 9)),
            (title: "Noon", url: "https://n.example/", at: date(2026, 11, 25, 12)),
            (title: "Evening", url: "https://e.example/", at: date(2026, 11, 25, 20)),
        ])
        let view = makeView()
        XCTAssertEqual(view.groups.count, 1)
        XCTAssertEqual(view.groups[0].items.map(\.entry.title), ["Evening", "Noon", "Morning"])
    }

    func testMidnightBoundarySplitsGroups() {
        seed([
            (title: "After midnight", url: "https://a.example/", at: date(2026, 11, 25, 0, 0, 0)),
            (title: "Before midnight", url: "https://b.example/", at: date(2026, 11, 24, 23, 59, 59)),
        ])
        let view = makeView()
        XCTAssertEqual(view.groups.map(\.dayKey), ["2026-11-25", "2026-11-24"])
        XCTAssertEqual(view.groups.map(\.items.count), [1, 1])
    }

    func testGroupsFollowNewestFirstInputOrder() {
        seed([
            (title: "C", url: "https://c.example/", at: date(2026, 11, 26)),
            (title: "B", url: "https://b.example/", at: date(2026, 11, 25)),
            (title: "A", url: "https://a.example/", at: date(2026, 11, 20)),
        ])
        let view = makeView()
        XCTAssertEqual(view.groups.map(\.dayKey), ["2026-11-26", "2026-11-25", "2026-11-20"])
    }

    func testGroupDateMatchesItsDayStart() {
        seed([(title: "Start", url: "https://s.example/", at: date(2026, 11, 25, 15, 30))])
        let view = makeView()
        XCTAssertEqual(view.groups.first?.date, Calendar.current.startOfDay(for: date(2026, 11, 25)))
    }

    func testYesterdayBoundaryUsesYesterdayGroup() {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        seed([
            (title: "Today", url: "https://t.example/", at: startOfToday.addingTimeInterval(60)),
            (title: "Yesterday", url: "https://y.example/", at: startOfToday.addingTimeInterval(-1)),
        ])
        let view = makeView()
        XCTAssertEqual(view.groups.map(\.title), ["Last Visited Today", HistoryPageView.dayHeaderFormatter.string(from: startOfToday.addingTimeInterval(-1))])
    }

    // MARK: - Cell content

    func testGroupTitleCellShowsDayTitle() {
        seed([(title: "X", url: "https://x.example/", at: date(2026, 11, 25))])
        let view = makeView()
        let c = cell(view, column: "WebsiteColumn", item: view.groups[0])
        XCTAssertEqual(c?.textField?.stringValue, "25 November 2026 Wednesday")
    }

    func testGroupCountCellSingularAndPlural() {
        seed([
            (title: "A", url: "https://a.example/", at: date(2026, 11, 25, 10)),
            (title: "B", url: "https://b.example/", at: date(2026, 11, 25, 11)),
            (title: "C", url: "https://c.example/", at: date(2026, 11, 20)),
        ])
        let view = makeView()
        let two = cell(view, column: "AddressColumn", item: view.groups[0])
        let one = cell(view, column: "AddressColumn", item: view.groups[1])
        XCTAssertEqual(two?.textField?.stringValue, "2 items")
        XCTAssertEqual(one?.textField?.stringValue, "1 item")
    }

    func testItemCellShowsTrimmedTitle() {
        seed([(title: "  Trim me  ", url: "https://t.example/", at: Date())])
        let view = makeView()
        let c = cell(view, column: "WebsiteColumn", item: node(view, group: 0, item: 0))
        XCTAssertEqual(c?.textField?.stringValue, "Trim me")
    }

    func testItemCellPlaceholderForBlankTitle() {
        let view = makeView()
        // Blank titles are replaced by the domain when stored, so an empty stored title is built directly.
        let entry = AssetLoader.HistoryEntry(title: "\n  ", url: "https://blank.example/", visitCount: 1, lastVisited: Date())
        let c = cell(view, column: "WebsiteColumn", item: Node(entry: entry))
        XCTAssertEqual(c?.textField?.stringValue, "(no title)")
    }

    func testItemCellShowsUnicodeTitle() {
        seed([(title: "🍎 Äpfel 日本", url: "https://apfel.example/", at: Date())])
        let view = makeView()
        let c = cell(view, column: "WebsiteColumn", item: node(view, group: 0, item: 0))
        XCTAssertEqual(c?.textField?.stringValue, "🍎 Äpfel 日本")
    }

    func testAddressCellShowsFullURL() {
        seed([(title: "Addr", url: "https://addr.example/path?q=1", at: Date())])
        let view = makeView()
        let c = cell(view, column: "AddressColumn", item: node(view, group: 0, item: 0))
        XCTAssertEqual(c?.textField?.stringValue, "https://addr.example/path?q=1")
    }

    func testNilColumnReturnsNoCell() {
        seed([(title: "Z", url: "https://z.example/", at: Date())])
        let view = makeView()
        XCTAssertNil(view.outlineView(outlineWithColumns(), viewFor: nil, item: node(view, group: 0, item: 0)))
    }

    func testUnknownColumnFallsBackToAddressCell() {
        seed([(title: "Z", url: "https://z.example/", at: Date())])
        let view = makeView()
        let other = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Nope"))
        let c = view.outlineView(outlineWithColumns(), viewFor: other, item: node(view, group: 0, item: 0)) as? NSTableCellView
        XCTAssertEqual(c?.textField?.stringValue, "https://z.example/")
    }

    // MARK: - Outline data source

    func testChildCountsForRootGroupsAndItems() {
        seed([
            (title: "A", url: "https://a.example/", at: date(2026, 11, 25, 10)),
            (title: "B", url: "https://b.example/", at: date(2026, 11, 25, 11)),
            (title: "C", url: "https://c.example/", at: date(2026, 11, 20)),
        ])
        let view = makeView()
        let ov = outlineWithColumns()
        XCTAssertEqual(view.outlineView(ov, numberOfChildrenOfItem: nil), 2)
        XCTAssertEqual(view.outlineView(ov, numberOfChildrenOfItem: view.groups[0]), 2)
        XCTAssertEqual(view.outlineView(ov, numberOfChildrenOfItem: view.groups[1]), 1)
        XCTAssertEqual(view.outlineView(ov, numberOfChildrenOfItem: node(view, group: 0, item: 0)), 0)
    }

    func testChildAtIndexReturnsGroupsInOrder() {
        seed([
            (title: "A", url: "https://a.example/", at: date(2026, 11, 25)),
            (title: "B", url: "https://b.example/", at: date(2026, 11, 20)),
        ])
        let view = makeView()
        let ov = outlineWithColumns()
        let first = view.outlineView(ov, child: 0, ofItem: nil) as? HistoryPageView.HistoryGroupNode
        let second = view.outlineView(ov, child: 1, ofItem: nil) as? HistoryPageView.HistoryGroupNode
        XCTAssertEqual(first?.dayKey, "2026-11-25")
        XCTAssertEqual(second?.dayKey, "2026-11-20")
    }

    func testGroupsExpandableItemsAreNot() {
        seed([(title: "A", url: "https://a.example/", at: Date())])
        let view = makeView()
        let ov = outlineWithColumns()
        XCTAssertTrue(view.outlineView(ov, isItemExpandable: view.groups[0]))
        XCTAssertFalse(view.outlineView(ov, isItemExpandable: node(view, group: 0, item: 0)))
    }

    func testRowHeights() {
        seed([(title: "A", url: "https://a.example/", at: Date())])
        let view = makeView()
        let ov = outlineWithColumns()
        XCTAssertEqual(view.outlineView(ov, heightOfRowByItem: view.groups[0]), 26)
        XCTAssertEqual(view.outlineView(ov, heightOfRowByItem: node(view, group: 0, item: 0)), 24)
    }

    // MARK: - Search

    func testSearchMatchesTitleCaseInsensitively() {
        seed([
            (title: "Rust Book", url: "https://doc.example/", at: Date()),
            (title: "Swift", url: "https://swift.example/", at: Date()),
        ])
        let view = makeView()
        setSearch(view, "RUST")
        XCTAssertEqual(view.groups.first?.items.map(\.entry.title), ["Rust Book"])
    }

    func testSearchMatchesURL() {
        seed([
            (title: "Untitled", url: "https://rust-lang.example/", at: Date()),
            (title: "Swift", url: "https://swift.example/", at: Date()),
        ])
        let view = makeView()
        setSearch(view, "rust-lang")
        XCTAssertEqual(view.groups.first?.items.count, 1)
    }

    func testSearchWhitespaceOnlyShowsEverything() {
        seed([
            (title: "A", url: "https://a.example/", at: Date()),
            (title: "B", url: "https://b.example/", at: Date()),
        ])
        let view = makeView()
        setSearch(view, "   ")
        XCTAssertEqual(view.groups.first?.items.count, 2)
    }

    func testSearchWithNoMatchEmptiesGroups() {
        seed([(title: "A", url: "https://a.example/", at: Date())])
        let view = makeView()
        setSearch(view, "zzz-no-match")
        XCTAssertTrue(view.groups.isEmpty)
    }

    func testSearchDropsDaysWithoutMatches() {
        seed([
            (title: "Rust today", url: "https://r.example/", at: Date()),
            (title: "Swift old", url: "https://s.example/", at: date(2026, 11, 20)),
        ])
        let view = makeView()
        setSearch(view, "rust")
        XCTAssertEqual(view.groups.map(\.title), ["Last Visited Today"])
    }

    func testSearchThenClearRestoresAllGroups() {
        seed([
            (title: "Rust", url: "https://r.example/", at: Date()),
            (title: "Swift", url: "https://s.example/", at: date(2026, 11, 20)),
        ])
        let view = makeView()
        setSearch(view, "rust")
        XCTAssertEqual(view.groups.count, 1)
        setSearch(view, "")
        XCTAssertEqual(view.groups.count, 2)
    }

    func testSearchIgnoresNonSearchFieldNotifications() {
        seed([(title: "A", url: "https://a.example/", at: Date())])
        let view = makeView()
        let label = NSTextField(labelWithString: "zzz")
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: label))
        XCTAssertEqual(view.groups.first?.items.count, 1)
    }

    func testSearchUnicodeQuery() {
        seed([
            (title: "Ärger mit Äpfeln", url: "https://de.example/", at: Date()),
            (title: "Plain", url: "https://p.example/", at: Date()),
        ])
        let view = makeView()
        setSearch(view, "äpfeln")
        XCTAssertEqual(view.groups.first?.items.map(\.entry.title), ["Ärger mit Äpfeln"])
    }

    // MARK: - Favicon cell binding

    func testUncachedFaviconBindsRowURLToCell() {
        seed([(title: "No Icon", url: "https://uncached-binding.invalid/x", at: Date())])
        let view = makeView()
        let c = cell(view, column: "WebsiteColumn", item: node(view, group: 0, item: 0))
        let bound = objc_getAssociatedObject(c!, &HistoryPageView.boundFaviconURLKey) as? String
        XCTAssertEqual(bound, "https://uncached-binding.invalid/x")
        XCTAssertEqual(c?.imageView?.contentTintColor, .secondaryLabelColor)
    }

    func testCachedFaviconUsesCachedImageWithoutTint() throws {
        let cachedURL = URL(string: "https://cached-history-icon.example/")!
        let icon = solidImage(size: 16)
        FaviconCache.shared.store(icon, forURL: cachedURL)
        seed([(title: "Cached", url: cachedURL.absoluteString, at: Date())])
        let view = makeView()
        let c = cell(view, column: "WebsiteColumn", item: node(view, group: 0, item: 0))
        XCTAssertTrue(c?.imageView?.image === FaviconCache.shared.cachedImage(forURLString: cachedURL.absoluteString))
        XCTAssertNil(c?.imageView?.contentTintColor)
    }

    // MARK: - Appearance

    func testAquaAppearanceUsesWhiteTopColor() {
        let view = makeView()
        view.appearance = NSAppearance(named: .aqua)
        XCTAssertFalse(view.prefersDarkAppearance)
        let c = view.effectiveTopColor.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(c.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.001)
    }

    func testDarkAppearanceUsesDarkTopColor() {
        let view = makeView()
        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(view.prefersDarkAppearance)
        let c = view.effectiveTopColor.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(c.redComponent, 0.110, accuracy: 0.001)
        XCTAssertEqual(c.greenComponent, 0.110, accuracy: 0.001)
        XCTAssertEqual(c.blueComponent, 0.118, accuracy: 0.001)
    }

    func testReloadIfVisibleRefreshesFromStore() {
        let view = makeView()
        AssetLoader.shared.recordHistoryVisit(url: URL(string: "https://refresh.example/")!, title: "R", visitedAt: Date())
        view.reloadIfVisible()
        XCTAssertEqual(view.groups.first?.items.count, 1)
    }
}
