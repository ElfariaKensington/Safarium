import AppKit
import XCTest
@testable import Safarium

/// Shared helpers for AssetLoader / FaviconCache tests. Everything they touch lives inside the
/// `HermeticTestCase` sandbox home, and `resetPersistence()` must run in setUp and tearDown.
enum PersistenceTestSupport {
    static let persistedDefaultsKeys: [String] = [
        AssetLoader.favoritesOrderDefaultsKey,
        AssetLoader.customFavoritesDefaultsKey,
        AssetLoader.readingListDefaultsKey,
        BrowserSettings.Key.removeHistory,
        BrowserSettings.Key.showFullAddress,
        BrowserSettings.Key.quickWebsiteSearch,
    ]

    static func resetPersistence() {
        let defaults = UserDefaults.standard
        for key in persistedDefaultsKeys { defaults.removeObject(forKey: key) }
        flushHistoryWrites()
        try? FileManager.default.removeItem(at: AssetLoader.shared.historyStoreURL)
        AssetLoader.shared.invalidateCachesForTesting()
    }

    /// Waits until every queued history snapshot has reached disk (the writer is a serial queue).
    static func flushHistoryWrites() {
        AssetLoader.historyWriteQueue.sync {}
    }

    static func writeHistoryFile(_ entries: [AssetLoader.HistoryEntry]) throws {
        let url = AssetLoader.shared.historyStoreURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        AssetLoader.shared.invalidateCachesForTesting()
    }

    static func readHistoryFile() throws -> [AssetLoader.HistoryEntry] {
        flushHistoryWrites()
        let data = try Data(contentsOf: AssetLoader.shared.historyStoreURL)
        return try JSONDecoder().decode([AssetLoader.HistoryEntry].self, from: data)
    }

    static func historyEntry(_ url: String, title: String = "Title", count: Int = 1, at date: Date) -> AssetLoader.HistoryEntry {
        AssetLoader.HistoryEntry(title: title, url: url, visitCount: count, lastVisited: date)
    }

    static func assertSRGB(_ color: NSColor?, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, accuracy: CGFloat = 0.002,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let c = color?.usingColorSpace(.sRGB) else {
            XCTFail("expected an sRGB color", file: file, line: line)
            return
        }
        XCTAssertEqual(c.redComponent, r, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.greenComponent, g, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.blueComponent, b, accuracy: accuracy, file: file, line: line)
    }
}

/// Counts posts of one notification name while alive.
final class NotificationCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.count += 1
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
