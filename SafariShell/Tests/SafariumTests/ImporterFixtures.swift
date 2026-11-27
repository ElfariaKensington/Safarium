import Foundation
import AppKit
import SQLite3
import XCTest
@testable import Safarium

/// Fixture builders for importer / converter tests. Everything is written under the hermetic sandbox root
/// (`HermeticTestCase.sandboxRoot`, which lives under NSTemporaryDirectory) and never under the real home.
enum ImporterFixtures {
    /// A fresh, empty fixture directory that is removed when the test finishes.
    static func makeRoot(_ test: XCTestCase) throws -> URL {
        let root = HermeticTestCase.sandboxRoot
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    /// Writes UTF-8 text, creating intermediate directories.
    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try write(data, to: url)
    }

    static func writePlist(_ object: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try write(data, to: url)
    }

    /// Creates an empty directory (and parents) at `url`.
    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Creates a SQLite database at `url` by running the given statements.
    static func makeSQLite(at url: URL, statements: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "ImporterFixtures", code: 1)
        }
        defer { sqlite3_close(db) }
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "ImporterFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
    }

    /// A tiny valid PNG file.
    static func writePNG(to url: URL) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImporterFixtures", code: 3)
        }
        try write(png, to: url)
    }

    /// A host that no other test uses, so AssetLoader dedupe state from other tests cannot interfere.
    static func uniqueHost() -> String {
        "h" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)) + ".example.test"
    }

    // MARK: Chromium Bookmarks JSON

    static func chromeURL(_ name: String, _ url: String) -> [String: Any] {
        ["type": "url", "name": name, "url": url]
    }

    static func chromeFolder(_ name: String, _ children: [[String: Any]]) -> [String: Any] {
        ["type": "folder", "name": name, "children": children]
    }

    static func chromeBookmarksFile(
        bar: [[String: Any]] = [],
        other: [[String: Any]] = [],
        synced: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "checksum": "",
            "version": 1,
            "roots": [
                "bookmark_bar": chromeFolder("Bookmarks bar", bar),
                "other": chromeFolder("Other bookmarks", other),
                "synced": chromeFolder("Mobile bookmarks", synced)
            ]
        ]
    }

    // MARK: Safari Bookmarks.plist

    static func safariLeaf(_ title: String, _ url: String, readingDate: Date? = nil) -> [String: Any] {
        var node: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "URLString": url,
            "URIDictionary": ["title": title]
        ]
        if let readingDate {
            node["ReadingList"] = ["DateAdded": readingDate]
        }
        return node
    }

    static func safariFolder(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children]
    }

    // MARK: Extensions

    /// Writes `<profile>/Extensions/<id>/<version>/manifest.json` and returns the version directory.
    @discardableResult
    static func writeChromiumExtension(
        profileDir: URL,
        id: String,
        version: String,
        manifest: [String: Any]
    ) throws -> URL {
        let dir = profileDir
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try writeJSON(manifest, to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    static let validID = "abcdefghijklmnopabcdefghijklmnop"
    static let otherValidID = "ponmlkjihgfedcbaponmlkjihgfedcba"
    static let ignoredComponentID = "nmmhkkegccagdldgiimedpiccmgmieda"
}

/// Records what the import pipeline asks of the engine; never touches a real browser.
final class ScriptedImportEngine: BrowserEngine {
    let engineName = "ScriptedImportEngine"
    let isRealChromium = false

    var installed: [BrowserExtensionItem] = []
    var loadResult = true
    var webStoreResult = true
    /// Paths for which `loadUnpackedExtension` reports failure regardless of `loadResult`.
    var failingPaths: Set<String> = []
    private(set) var loadedPaths: [String] = []
    private(set) var webStoreIDs: [String] = []

    func start() throws {}
    func shutdown() {}

    func createTab(initialURL: URL?, parentView: NSView?, isPrivate: Bool) -> BrowserTabEngine {
        MockBrowserEngine().createTab(initialURL: initialURL, parentView: parentView, isPrivate: isPrivate)
    }

    func installedExtensions() -> [BrowserExtensionItem] { installed }

    func loadUnpackedExtension(atPath path: String, completion: @escaping (Bool) -> Void) {
        loadedPaths.append(path)
        completion(loadResult && !failingPaths.contains(path))
    }

    func installExtensionFromChromeWebStoreID(_ storeID: String, completion: @escaping (Bool) -> Void) {
        webStoreIDs.append(storeID)
        completion(webStoreResult)
    }
}
