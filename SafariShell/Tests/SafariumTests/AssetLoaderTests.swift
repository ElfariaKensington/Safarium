import AppKit
import XCTest
@testable import Safarium

/// Favorites, reading list, URL identity keys, wallpapers, symbols, spinner frames and hex colors.
final class AssetLoaderTests: HermeticTestCase {
    override func setUp() {
        super.setUp()
        PersistenceTestSupport.resetPersistence()
    }

    override func tearDown() {
        PersistenceTestSupport.resetPersistence()
        super.tearDown()
    }

    private var loader: AssetLoader { AssetLoader.shared }

    // MARK: - normalizedURLKey

    func testNormalizedKeyEmptyAndWhitespaceInputsReturnEmpty() {
        XCTAssertEqual(AssetLoader.normalizedURLKey(""), "")
        XCTAssertEqual(AssetLoader.normalizedURLKey("   \n\t "), "")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://"), "")
        XCTAssertEqual(AssetLoader.normalizedURLKey("HTTP://"), "")
    }

    func testNormalizedKeyStripsSchemeWwwAndTrailingSlashes() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://www.example.com/"), "example.com")
        XCTAssertEqual(AssetLoader.normalizedURLKey("http://example.com"), "example.com")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://www.example.com///"), "example.com")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://example.com/a/b/"), "example.com/a/b")
    }

    func testNormalizedKeyLowercasesHostAndStripsWwwPrefixOnce() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("HTTPS://WWW.Example.COM"), "example.com")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://www.www.example.com/"), "www.example.com")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://www.example.com"), AssetLoader.normalizedURLKey("https://example.com"))
    }

    func testNormalizedKeyDropsPortOnlyWhenItIsTheDefaultForTheScheme() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://example.com:443/a"), "example.com/a")
        XCTAssertEqual(AssetLoader.normalizedURLKey("http://example.com:80/a"), "example.com/a")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://example.com:80/a"), "example.com:80/a")
        XCTAssertEqual(AssetLoader.normalizedURLKey("http://example.com:443/a"), "example.com:443/a")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://example.com:8443/a"), "example.com:8443/a")
        XCTAssertEqual(AssetLoader.normalizedURLKey("ftp://example.com:21/a"), "example.com:21/a")
    }

    func testNormalizedKeyKeepsNonDefaultPortDistinctFromPlainHost() {
        XCTAssertNotEqual(AssetLoader.normalizedURLKey("https://example.com:80/"),
                          AssetLoader.normalizedURLKey("https://example.com/"))
    }

    func testNormalizedKeyKeepsQueryAndDropsFragmentAndEmptyQuery() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://a.example/search?q=Swift&page=2"), "a.example/search?q=Swift&page=2")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://a.example/?Q=AbC"), "a.example?Q=AbC")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://a.example/x?"), "a.example/x")
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://a.example/x#Top"), "a.example/x")
    }

    func testNormalizedKeyEquivalentSpellingsCollapseToOneKey() {
        let a = AssetLoader.normalizedURLKey("https://www.Example.com:443/docs/?a=1")
        let b = AssetLoader.normalizedURLKey("https://example.com/docs?a=1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "example.com/docs?a=1")
    }

    func testNormalizedKeySchemeLessInputUsesFallbackRules() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("example.com/"), "example.com")
        XCTAssertEqual(AssetLoader.normalizedURLKey("WWW.Example.com"), "example.com")
        XCTAssertEqual(AssetLoader.normalizedURLKey("  www.example.com/x/  "), "example.com/x")
        XCTAssertEqual(AssetLoader.normalizedURLKey("www."), "www.", "a bare www. prefix is not stripped")
    }

    func testNormalizedKeyLowercasesUnicodeHost() {
        XCTAssertEqual(AssetLoader.normalizedURLKey("https://B\u{00DC}CHER.de/x"), "b\u{00FC}cher.de/x")
    }

    func testNormalizedKeyPathCaseIsSignificant() {
        XCTAssertNotEqual(AssetLoader.normalizedURLKey("https://example.com/Docs"),
                          AssetLoader.normalizedURLKey("https://example.com/docs"))
    
        XCTAssertEqual(AssetLoader.normalizedURLKey("example.com/Docs/Page"), "example.com/Docs/Page")
    
    }

    // MARK: - Favorites

    func testDefaultFavoritesContainEveryExtraDefaultByURLIdentity() {
        let keys = loader.favorites().map { AssetLoader.normalizedURLKey($0.url) }
        for extra in AssetLoader.extraDefaultFavorites {
            XCTAssertTrue(keys.contains(AssetLoader.normalizedURLKey(extra.url)), "missing default favorite \(extra.title)")
        }
        XCTAssertGreaterThanOrEqual(keys.count, AssetLoader.extraDefaultFavorites.count)
    }

    func testFavoritesAreStableAcrossRepeatedCalls() {
        XCTAssertEqual(loader.favorites(), loader.favorites())
    }

    func testSaveFavoritesOrderPersistsEntriesAndURLOrder() {
        let entries = [
            AssetLoader.BookmarkEntry(id: "f1", title: "One", url: "https://one.example/", color: "#112233"),
            AssetLoader.BookmarkEntry(id: "f2", title: "Two", url: "https://two.example/", color: nil),
            AssetLoader.BookmarkEntry(id: "f3", title: "Three", url: "https://three.example/", color: "#ABCDEF")
        ]
        loader.saveFavoritesOrder(entries)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AssetLoader.favoritesOrderDefaultsKey),
                       ["https://one.example/", "https://two.example/", "https://three.example/"])
        loader.invalidateCachesForTesting()
        XCTAssertEqual(loader.favorites(), entries)
    }

    func testSaveFavoritesOrderPostsDidChangeNotification() {
        let counter = NotificationCounter(.safariumFavoritesDidChange)
        loader.saveFavoritesOrder([])
        XCTAssertEqual(counter.count, 1)
    }

    func testSavedURLOrderReordersDefaultFavorites() {
        let base = loader.favorites()
        let first = base[0].url, second = base[1].url
        UserDefaults.standard.set([second, first], forKey: AssetLoader.favoritesOrderDefaultsKey)
        loader.invalidateCachesForTesting()
        let reordered = loader.favorites()
        XCTAssertEqual(reordered.count, base.count)
        XCTAssertEqual(reordered[0].url, second)
        XCTAssertEqual(reordered[1].url, first)
    }

    func testSavedURLOrderIgnoresUnknownAndDuplicateURLs() {
        let base = loader.favorites()
        let a = base[2].url, b = base[0].url
        UserDefaults.standard.set(["https://nope.example/", a, a, b], forKey: AssetLoader.favoritesOrderDefaultsKey)
        loader.invalidateCachesForTesting()
        let result = loader.favorites()
        XCTAssertEqual(result.count, base.count, "unknown and duplicate URLs must not add or drop entries")
        XCTAssertEqual(result[0].url, a)
        XCTAssertEqual(result[1].url, b)
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
    }

    func testCustomFavoritesDataOverridesDefaults() {
        let custom = [AssetLoader.BookmarkEntry(id: "only", title: "Only", url: "https://only.example/", color: nil)]
        loader.saveFavoritesOrder(custom)
        loader.invalidateCachesForTesting()
        XCTAssertEqual(loader.favorites(), custom)
    }

    func testCorruptCustomFavoritesDataFallsBackToDefaults() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: AssetLoader.customFavoritesDefaultsKey)
        loader.invalidateCachesForTesting()
        XCTAssertGreaterThanOrEqual(loader.favorites().count, AssetLoader.extraDefaultFavorites.count)
    }

    func testUpdateFavoriteTrimsTitleAndURL() {
        let target = loader.favorites()[0]
        loader.updateFavorite(id: target.id, title: "  New Name \n", url: " https://new.example/ ")
        let updated = loader.favorites().first { $0.id == target.id }
        XCTAssertEqual(updated?.title, "New Name")
        XCTAssertEqual(updated?.url, "https://new.example/")
        XCTAssertEqual(updated?.color, target.color, "colour is not editable")
    }

    func testUpdateFavoriteIgnoresBlankFields() {
        let target = loader.favorites()[0]
        loader.updateFavorite(id: target.id, title: "   ", url: "")
        let after = loader.favorites().first { $0.id == target.id }
        XCTAssertEqual(after?.title, target.title)
        XCTAssertEqual(after?.url, target.url)
    }

    func testUpdateFavoriteWithUnknownIDIsNoOp() {
        let before = loader.favorites()
        let counter = NotificationCounter(.safariumFavoritesDidChange)
        loader.updateFavorite(id: "missing-id", title: "X", url: "https://x.example/")
        XCTAssertEqual(loader.favorites(), before)
        XCTAssertEqual(counter.count, 0)
    }

    func testDeleteFavoriteRemovesOnlyTheMatchingEntry() {
        let before = loader.favorites()
        let victim = before[1]
        loader.deleteFavorite(id: victim.id)
        let after = loader.favorites()
        XCTAssertEqual(after.count, before.count - 1)
        XCTAssertFalse(after.contains { $0.id == victim.id })
        XCTAssertEqual(after.map(\.id), before.filter { $0.id != victim.id }.map(\.id))
    }

    func testDeleteUnknownFavoriteDoesNotNotify() {
        let counter = NotificationCounter(.safariumFavoritesDidChange)
        loader.deleteFavorite(id: "missing-id")
        XCTAssertEqual(counter.count, 0)
    }

    func testMergeImportedFavoritesEmptyInputReturnsZero() {
        let counter = NotificationCounter(.safariumFavoritesDidChange)
        XCTAssertEqual(loader.mergeImportedFavorites([]), 0)
        XCTAssertEqual(counter.count, 0)
    }

    func testMergeImportedFavoritesPrependsNewURLsOnlyOnce() {
        let before = loader.favorites()
        let duplicateOfExisting = AssetLoader.BookmarkEntry(id: "dupe", title: "Dupe", url: before[0].url, color: nil)
        let newA = AssetLoader.BookmarkEntry(id: "new-a", title: "A", url: "https://a-new.example/", color: nil)
        let newAAgain = AssetLoader.BookmarkEntry(id: "new-a2", title: "A2", url: "https://a-new.example/", color: nil)
        let blank = AssetLoader.BookmarkEntry(id: "blank", title: "Blank", url: "   ", color: nil)

        let added = loader.mergeImportedFavorites([duplicateOfExisting, newA, newAAgain, blank])
        XCTAssertEqual(added, 1)
        let after = loader.favorites()
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.first?.id, "new-a")
    }

    func testMergeImportedFavoritesAppendsWhenPrependIsFalse() {
        let before = loader.favorites()
        let added = loader.mergeImportedFavorites(
            [AssetLoader.BookmarkEntry(id: "tail", title: "Tail", url: "https://tail.example/", color: nil)],
            prepend: false
        )
        XCTAssertEqual(added, 1)
        XCTAssertEqual(loader.favorites().last?.id, "tail")
        XCTAssertEqual(loader.favorites().count, before.count + 1)
    }

    func testMergeImportedFavoritesWithOnlyDuplicatesReturnsZeroWithoutSaving() {
        let counter = NotificationCounter(.safariumFavoritesDidChange)
        let before = loader.favorites()
        let added = loader.mergeImportedFavorites([AssetLoader.BookmarkEntry(id: "d", title: "D", url: before[0].url, color: nil)])
        XCTAssertEqual(added, 0)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(loader.favorites(), before)
    }

    // MARK: - Reading list

    func testDefaultReadingListHasSeededItemsInOrder() {
        XCTAssertEqual(loader.readingList().map(\.id), ["rl-apple", "rl-github", "rl-webkit"])
    }

    func testMergeReadingListPrependsUniqueItemsAndSkipsBlankOrDuplicateURLs() {
        let before = loader.readingList()
        let now = Date()
        let imported = [
            AssetLoader.ReadingListItem(id: "dup", title: "Dup", url: "https://www.apple.com/macbook-pro", addedAt: now),
            AssetLoader.ReadingListItem(id: "n1", title: "New one", url: "https://new.example/read", addedAt: now),
            AssetLoader.ReadingListItem(id: "blank", title: "Blank", url: "  ", addedAt: now),
            AssetLoader.ReadingListItem(id: "n2", title: "New two", url: "https://new.example/read/", addedAt: now)
        ]
        XCTAssertEqual(loader.mergeImportedReadingList(imported), 1)
        let after = loader.readingList()
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.first?.id, "n1")
        XCTAssertEqual(after.dropFirst().map(\.id), before.map(\.id))
    }

    func testMergeReadingListPersistsAcrossCacheReset() {
        let item = AssetLoader.ReadingListItem(id: "p1", title: "Persist", url: "https://persist.example/", addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        loader.mergeImportedReadingList([item])
        let inMemory = loader.readingList()
        loader.invalidateCachesForTesting()
        XCTAssertEqual(loader.readingList(), inMemory)
        XCTAssertEqual(loader.readingList().first, item)
    }

    func testMergeReadingListEmptyInputReturnsZeroWithoutNotification() {
        let counter = NotificationCounter(.safariumReadingListDidChange)
        XCTAssertEqual(loader.mergeImportedReadingList([]), 0)
        XCTAssertEqual(counter.count, 0)
    }

    func testMergeReadingListPostsNotificationOnlyWhenItemsAdded() {
        let counter = NotificationCounter(.safariumReadingListDidChange)
        let item = AssetLoader.ReadingListItem(id: "x", title: "X", url: "https://x.example/", addedAt: Date())
        XCTAssertEqual(loader.mergeImportedReadingList([item]), 1)
        XCTAssertEqual(loader.mergeImportedReadingList([item]), 0)
        XCTAssertEqual(counter.count, 1)
    }

    func testCorruptReadingListDataFallsBackToSeededItems() {
        UserDefaults.standard.set(Data("{".utf8), forKey: AssetLoader.readingListDefaultsKey)
        loader.invalidateCachesForTesting()
        XCTAssertEqual(loader.readingList().map(\.id), ["rl-apple", "rl-github", "rl-webkit"])
    }

    // MARK: - Wallpapers

    func testAvailableWallpaperIDsAreUniqueAndWellFormed() {
        let ids = loader.availableWallpaperIDs()
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertNil(id.rangeOfCharacter(from: .whitespacesAndNewlines))
            XCTAssertNil(id.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\.")), "IDs are used as file stems: \(id)")
        }
    }

    func testWallpaperUnknownIDReturnsNilInBothSizes() {
        let missing = "missing-wallpaper-\(UUID().uuidString)"
        XCTAssertNil(loader.wallpaper(named: missing, thumbnail: true))
        XCTAssertNil(loader.wallpaper(named: missing, thumbnail: false))
    }

    func testWallpaperLoadsKnownImageAndCachesPerSize() throws {
        let file = loader.referenceRootURL.appendingPathComponent("Components/wallpapers/safari-27-blue.jpg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "Reference wallpapers not present")
        let thumb = loader.wallpaper(named: "safari-27-blue", thumbnail: true)
        XCTAssertNotNil(thumb)
        XCTAssertTrue(loader.wallpaper(named: "safari-27-blue", thumbnail: true) === thumb, "second call must come from cache")
        let full = loader.wallpaper(named: "safari-27-blue", thumbnail: false)
        XCTAssertNotNil(full)
    }

    // MARK: - Symbols and spinner frames

    func testSymbolReturnsTemplateImageAndCachesPerSizeAndWeight() {
        let a = loader.symbol(named: "star", pointSize: 16, weight: .regular)
        XCTAssertTrue(a.isTemplate)
        XCTAssertTrue(loader.symbol(named: "star", pointSize: 16, weight: .regular) === a)
        XCTAssertFalse(loader.symbol(named: "star", pointSize: 24, weight: .regular) === a)
        XCTAssertFalse(loader.symbol(named: "star", pointSize: 16, weight: .bold) === a)
    }

    func testSymbolUnknownNameFallsBackToBlankTemplateOfRequestedSize() {
        let image = loader.symbol(named: "no-such-symbol-\(UUID().uuidString)", pointSize: 20)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 20)
        XCTAssertEqual(image.size.height, 20)
    }

    func testSpinnerFramesLoadExpectedCountsAndSize() throws {
        let dir = loader.referenceRootURL.appendingPathComponent("Animations/spinner")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "Reference spinner frames not present")
        let pull = loader.spinnerFrames(phase: "pull")
        XCTAssertEqual(pull.count, 24)
        XCTAssertTrue(pull.allSatisfy { $0.size == NSSize(width: 22, height: 22) })
        XCTAssertEqual(loader.spinnerFrames(phase: "spin").count, 16)
    }

    func testSpinnerFramesForUnknownPhaseAreEmpty() {
        XCTAssertEqual(loader.spinnerFrames(phase: "no-such-phase-\(UUID().uuidString)"), [])
    }

    // MARK: - Hex colors

    func testHexColorParsesSixDigitRGB() {
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "#FF0000"), 1, 0, 0)
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "00FF00"), 0, 1, 0)
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "#0000FF"), 0, 0, 1)
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "#1DB954"), 0x1D / 255.0, 0xB9 / 255.0, 0x54 / 255.0)
    }

    func testHexColorAcceptsLowercaseAndBoundaryValues() {
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "#abcdef"), 0xAB / 255.0, 0xCD / 255.0, 0xEF / 255.0)
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "#000000"), 0, 0, 0)
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "#FFFFFF"), 1, 1, 1)
    }

    func testHexColorOptionalHashAndSurroundingWhitespace() {
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "123456"), 0x12 / 255.0, 0x34 / 255.0, 0x56 / 255.0)
        PersistenceTestSupport.assertSRGB(NSColor(hexString: "  #123456 \n"), 0x12 / 255.0, 0x34 / 255.0, 0x56 / 255.0)
    }

    func testHexColorRejectsWrongLengthAndNonHexCharacters() {
        for bad in ["", "#", "#12345", "#1234567", "#ABC", "#GG0000", "#12 456", "0x123456", "##123456", "#FF00 0"] {
            XCTAssertNil(NSColor(hexString: bad), "expected nil for \(bad.debugDescription)")
        }
    }

    func testHexColorRejectsSignPrefixedDigits() {
        XCTAssertNil(NSColor(hexString: "+12345"))
    
    }
}
