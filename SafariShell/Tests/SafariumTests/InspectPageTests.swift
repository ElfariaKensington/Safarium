import XCTest
import AppKit
@testable import Safarium

final class InspectPageTests: HermeticTestCase {
    private let touchedKeys = [
        BrowserSettings.Key.remoteDebuggingEnabled,
        BrowserSettings.Key.remoteDebuggingPort,
        BrowserSettings.Key.inspectDiscoverNetworkTargets,
        BrowserSettings.Key.inspectNetworkTargets,
        BrowserSettings.Key.showFullAddress
    ]

    override func setUp() {
        super.setUp()
        for key in touchedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in touchedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - URL Parsing & Normalization

    func testInspectURLParsingAllVariants() {
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect")), .devices)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/")), .devices)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/#devices")), .devices)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/#pages")), .pages)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/#extensions")), .extensions)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/#service-workers")), .serviceWorkers)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/#workers")), .workers)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/#other")), .other)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect/#remote-debugging")), .remoteDebugging)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "chrome://inspect#remote-debugging")), .remoteDebugging)
        XCTAssertEqual(InspectPageURL.parse(URL(string: "CHROME://INSPECT/#REMOTE-DEBUGGING")), .remoteDebugging)

        XCTAssertNil(InspectPageURL.parse(URL(string: "chrome://gpu")))
        XCTAssertNil(InspectPageURL.parse(URL(string: "https://inspect")))
        XCTAssertNil(InspectPageURL.parse(URL(string: "safarium://start")))
        XCTAssertNil(InspectPageURL.parse(URL(string: "chrome://inspect/subpath")))
    }

    func testURLInputNormalizerAndDisplayDomainForInspectURLs() {
        let u1 = URLInputNormalizer.normalize("chrome://inspect")
        XCTAssertEqual(u1.absoluteString, "chrome://inspect")
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: u1), "chrome://inspect")

        let u2 = URLInputNormalizer.normalize("chrome://inspect/#remote-debugging")
        XCTAssertEqual(u2.absoluteString, "chrome://inspect/#remote-debugging")
        XCTAssertEqual(URLInputNormalizer.displayDomain(for: u2), "chrome://inspect/#remote-debugging")
    }

    // MARK: - Settings Persistence & Validation

    func testRemoteDebuggingSettingsDefaultsAndValidation() {
        let settings = BrowserSettings.shared
        XCTAssertFalse(settings.remoteDebuggingEnabled)
        XCTAssertEqual(settings.remoteDebuggingPort, 9222)
        XCTAssertTrue(settings.inspectDiscoverNetworkTargets)
        XCTAssertEqual(settings.inspectNetworkTargets, ["localhost:9222", "localhost:9229"])

        settings.remoteDebuggingEnabled = true
        XCTAssertTrue(settings.remoteDebuggingEnabled)

        settings.remoteDebuggingPort = 9333
        XCTAssertEqual(settings.remoteDebuggingPort, 9333)

        // Out-of-range ports clamp back to default 9222.
        settings.remoteDebuggingPort = 80
        XCTAssertEqual(settings.remoteDebuggingPort, 9222)
        settings.remoteDebuggingPort = 70000
        XCTAssertEqual(settings.remoteDebuggingPort, 9222)

        // Network targets deduplicate and trim whitespace.
        settings.inspectNetworkTargets = [" localhost:9222 ", "LOCALHOST:9222", "", "127.0.0.1:9229"]
        XCTAssertEqual(settings.inspectNetworkTargets, ["localhost:9222", "127.0.0.1:9229"])
    }

    // MARK: - InspectPageView Rendering & Section Switching

    func testInspectPageViewSwitchesToRemoteDebuggingAndNotifies() {
        let view = InspectPageView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        view.remoteDebuggingStatusProvider = {
            InspectRemoteDebuggingStatus(
                activePort: 9222,
                isActive: true,
                webSocketURL: "ws://127.0.0.1:9222/devtools/browser/test-guid",
                activePortFilePath: "/tmp/DevToolsActivePort"
            )
        }
        view.localTabsProvider = {
            [
                InspectLocalTabSnapshot(
                    tabID: "tab-1",
                    windowIndex: 0,
                    title: "Example Domain",
                    urlString: "https://example.com",
                    isPrivate: false,
                    isActive: true
                )
            ]
        }

        var selectedSections: [InspectPageSection] = []
        view.onSelectSection = { selectedSections.append($0) }

        view.setSection(.remoteDebugging, notifyOwner: true)
        XCTAssertEqual(view.currentSection, .remoteDebugging)
        XCTAssertEqual(selectedSections, [.remoteDebugging])

        view.setSection(.pages, notifyOwner: true)
        XCTAssertEqual(view.currentSection, .pages)
        XCTAssertEqual(selectedSections, [.remoteDebugging, .pages])
    }

    // MARK: - MockBrowserEngine Tab Integration

    func testMockBrowserTabRecognizesInspectAndRemoteDebugging() {
        let engine = MockBrowserEngine()
        let tab = engine.createTab(initialURL: URL(string: "chrome://inspect/#remote-debugging"))
        XCTAssertTrue(tab.isInspectPage)
        XCTAssertTrue(tab.isNativeInternalPage)
        XCTAssertEqual(tab.inspectPageSection, .remoteDebugging)

        tab.loadURL(URL(string: "chrome://inspect/#pages")!)
        XCTAssertTrue(tab.isInspectPage)
        XCTAssertEqual(tab.inspectPageSection, .pages)

        tab.loadURL(URL(string: "https://example.com")!)
        XCTAssertFalse(tab.isInspectPage)
    }
}
