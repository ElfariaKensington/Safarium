import XCTest
import AppKit
@testable import Safarium

// Shared headless helpers for the T8 window-controller suites.
// Nothing here orders a window on screen; every controller is closed in tearDown.

/// Recording test double for one tab. No timers, no WebKit/Chromium work.
final class T8SpyTab: NSObject, BrowserTabEngine {
    let tabID: String = UUID().uuidString
    weak var delegate: BrowserTabEngineDelegate?
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    var currentURL: URL?
    var title: String = ""
    var isLoading = false
    var estimatedProgress: Double = 1.0
    var canGoBack = false
    var canGoForward = false
    var favicon: NSImage?
    var scrollY: CGFloat = 0
    var contentHeight: CGFloat = 1000
    var pageScale: CGFloat = 1.0
    var lastTopEdgeColorSample: TopEdgeColorSample?

    private(set) var zoom: Double = 1.0
    private(set) var zoomCalls: [Double] = []
    private(set) var muted = false
    private(set) var loadedURLs: [URL] = []
    private(set) var findQueries: [String] = []
    private(set) var closed = false
    private(set) var resetPageScaleCount = 0
    private(set) var getPageSourceCallCount = 0
    private(set) var savePageWithPanelCallCount = 0
    private(set) var lastSavedFromWindow: NSWindow?
    var pageSourceToReturn: String? = "<html><body>Spy</body></html>"
    var savePageResult: (Bool, URL?) = (true, URL(fileURLWithPath: "/tmp/spy-saved.html"))

    var pageZoomFactor: Double { zoom }
    var isAudioMuted: Bool { muted }

    func loadURL(_ url: URL) {
        loadedURLs.append(url)
        currentURL = url
    }
    func loadInput(_ input: String) { loadURL(URLInputNormalizer.normalize(input)) }
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func findText(_ searchText: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        findQueries.append(searchText)
    }
    func stopFinding(clearSelection: Bool) {}
    func showDevTools() {}
    func executeJavaScript(_ script: String) {}
    func executeJavaScriptInAllFrames(_ script: String) {}
    func printPage() {}
    func exportToPDF(atPath path: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func getPageSource(completion: @escaping (String?) -> Void) {
        getPageSourceCallCount += 1
        completion(pageSourceToReturn)
    }
    func savePageWithPanel(for window: NSWindow?, completion: ((Bool, URL?) -> Void)?) {
        savePageWithPanelCallCount += 1
        lastSavedFromWindow = window
        completion?(savePageResult.0, savePageResult.1)
    }
    func setAudioMuted(_ muted: Bool) { self.muted = muted }
    func closeTab() { closed = true }
    func endPageOvershoot() {}
    func resetOverscroll() {}
    func startDownload(at url: URL) {}
    func setPageZoomFactor(_ factor: Double) {
        zoomCalls.append(factor)
        zoom = factor
    }
    func resetPageScale() { resetPageScaleCount += 1 }
    func sampleTopEdgeColor(stripHeight: CGFloat, completion: @escaping (TopEdgeColorSample?) -> Void) {
        completion(nil)
    }
}

/// Engine double: hands out `T8SpyTab`s and records the private flag of every tab it creates.
final class T8SpyEngine: BrowserEngine {
    let engineName = "T8Spy"
    let isRealChromium = false
    private(set) var created: [T8SpyTab] = []
    private(set) var privateFlags: [Bool] = []

    func start() throws {}
    func shutdown() {}
    func createTab(initialURL: URL?, parentView: NSView?, isPrivate: Bool) -> BrowserTabEngine {
        let tab = T8SpyTab()
        if let initialURL { tab.loadURL(initialURL) }
        created.append(tab)
        privateFlags.append(isPrivate)
        return tab
    }
}

/// Reads a private stored property of `object` through reflection (no visibility change needed).
func t8Mirror(_ object: AnyObject, _ name: String) -> Any? {
    Mirror(reflecting: object).children.first { $0.label == name }?.value
}

/// Tabs of a controller in strip order (private `tabs` read via reflection).
func t8Tabs(_ wc: SafariWindowController) -> [BrowserTabEngine] {
    (t8Mirror(wc, "tabs") as? [BrowserTabEngine]) ?? []
}

/// Private `activeTabIndex` read via reflection.
func t8ActiveIndex(_ wc: SafariWindowController) -> Int {
    (t8Mirror(wc, "activeTabIndex") as? Int) ?? -1
}

/// Private `pinnedTabIDs` read via reflection.
func t8PinnedIDs(_ wc: SafariWindowController) -> Set<String> {
    (t8Mirror(wc, "pinnedTabIDs") as? Set<String>) ?? []
}

/// Private `closedTabURLs` read via reflection.
func t8ClosedURLs(_ wc: SafariWindowController) -> [URL] {
    (t8Mirror(wc, "closedTabURLs") as? [URL]) ?? []
}

/// Runs `body` with fd 2 redirected to a temp file and returns what was written to stderr.
/// Used to observe AppKit constraint-conflict logging, which goes to stderr.
func t8CaptureStderr(_ name: String, _ body: () -> Void) -> String {
    let path = NSTemporaryDirectory() + "t8-stderr-\(name)-\(UUID().uuidString).log"
    let fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0o600)
    guard fd >= 0 else { return "" }
    let saved = dup(STDERR_FILENO)
    fflush(stderr)
    dup2(fd, STDERR_FILENO)
    body()
    fflush(stderr)
    dup2(saved, STDERR_FILENO)
    close(saved)
    close(fd)
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(atPath: path)
    return text
}

/// Unique, throw-away named pasteboard so drag tests never touch the general pasteboard.
func t8Pasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("t8.\(UUID().uuidString)"))
}

/// UserDefaults keys the controller writes through BrowserSettings (cleaned in tearDown).
let t8SessionKeys = ["Safarium.Session.SavedTabs.v1", "Safarium.Session.ActiveIndex.v1"]

/// Base for every T8 window test class: owns controllers, closes them and cleans defaults.
@MainActor
class T8WindowTestCase: HermeticTestCase {
    var made: [SafariWindowController] = []

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            for key in t8SessionKeys { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for wc in made {
                wc.window?.close()
            }
            made.removeAll()
            for key in t8SessionKeys { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    @discardableResult
    func makeWindow(isPrivate: Bool = false, engine: T8SpyEngine? = nil) -> (SafariWindowController, T8SpyEngine) {
        let eng = engine ?? T8SpyEngine()
        let wc = SafariWindowController(engine: eng, isPrivate: isPrivate)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        made.append(wc)
        return (wc, eng)
    }

    func url(_ s: String) -> URL { URL(string: s)! }

    /// Opens `count` http tabs named https://t<i>.example.com/ and returns them in strip order.
    func openTabs(_ wc: SafariWindowController, count: Int, activateLast: Bool = false) -> [BrowserTabEngine] {
        var out: [BrowserTabEngine] = []
        for i in 0..<count {
            out.append(wc.createNewTab(url: url("https://t\(i).example.com/"), activate: activateLast || i == 0))
        }
        return out
    }
}
