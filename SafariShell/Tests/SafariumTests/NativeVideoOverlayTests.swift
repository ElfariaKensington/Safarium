import XCTest
import AppKit
@testable import Safarium

/// Tests for the native video overlay's pure models (`VideoState.parse`, time formatting) and the
/// container's per-tab HUD bookkeeping. HUDs are checked as plain NSViews, no window is ordered.
@MainActor
final class NativeVideoOverlayTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private typealias State = NativeVideoOverlayContainerView.VideoState

    private func makeContainer() -> NativeVideoOverlayContainerView {
        NativeVideoOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    private let rect = NSRect(x: 10, y: 20, width: 320, height: 180)

    // MARK: VideoState.parse

    func testParsesFullStateJSON() throws {
        let json = #"{"cur":12.5,"dur":300,"paused":false,"muted":true,"vol":0.4,"radius":8,"clipTop":3,"clipBottom":5}"#
        let st = try XCTUnwrap(State.parse(jsonString: json))
        XCTAssertEqual(st.currentTime, 12.5, accuracy: 1e-12)
        XCTAssertEqual(st.duration, 300, accuracy: 1e-12)
        XCTAssertFalse(st.paused)
        XCTAssertTrue(st.muted)
        XCTAssertEqual(st.volume, 0.4, accuracy: 1e-12)
        XCTAssertEqual(st.cornerRadius, 8, accuracy: 1e-12)
        XCTAssertEqual(st.clipTop, 3, accuracy: 1e-12)
        XCTAssertEqual(st.clipBottom, 5, accuracy: 1e-12)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let st = try XCTUnwrap(State.parse(jsonString: "{}"))
        XCTAssertEqual(st.currentTime, 0)
        XCTAssertEqual(st.duration, 0)
        XCTAssertTrue(st.paused, "a video with no state is treated as paused")
        XCTAssertFalse(st.muted)
        XCTAssertEqual(st.volume, 1.0)
        XCTAssertEqual(st.cornerRadius, 0)
        XCTAssertEqual(st.clipTop, 0)
        XCTAssertEqual(st.clipBottom, 0)
    }

    func testIntegerJSONNumbersAreAcceptedAsDoubles() throws {
        let st = try XCTUnwrap(State.parse(jsonString: #"{"cur":4,"dur":60,"vol":1}"#))
        XCTAssertEqual(st.currentTime, 4, accuracy: 1e-12)
        XCTAssertEqual(st.duration, 60, accuracy: 1e-12)
        XCTAssertEqual(st.volume, 1, accuracy: 1e-12)
    }

    func testWrongTypedFieldsFallBackToDefaults() throws {
        let st = try XCTUnwrap(State.parse(jsonString: #"{"cur":"9","paused":"yes","muted":"yes","vol":null}"#))
        XCTAssertEqual(st.currentTime, 0)
        XCTAssertTrue(st.paused)
        XCTAssertFalse(st.muted)
        XCTAssertEqual(st.volume, 1.0)
    }

    func testMalformedOrNonObjectJSONReturnsNil() {
        XCTAssertNil(State.parse(jsonString: ""))
        XCTAssertNil(State.parse(jsonString: "{not json"))
        XCTAssertNil(State.parse(jsonString: "[1,2,3]"))
        XCTAssertNil(State.parse(jsonString: "\"just a string\""))
    }

    func testNegativeGeometryIsPassedThroughUnchanged() throws {
        let st = try XCTUnwrap(State.parse(jsonString: #"{"radius":-4,"clipTop":-1}"#))
        XCTAssertEqual(st.cornerRadius, -4, accuracy: 1e-12)
        XCTAssertEqual(st.clipTop, -1, accuracy: 1e-12)
    }

    func testDefaultVideoStateValues() {
        let st = State()
        XCTAssertEqual(st.currentTime, 0)
        XCTAssertEqual(st.duration, 0)
        XCTAssertTrue(st.paused)
        XCTAssertFalse(st.muted)
        XCTAssertEqual(st.volume, 1.0)
    }

    // MARK: Time formatting

    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(0), "0:00")
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(5), "0:05")
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(65), "1:05")
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(3599), "59:59")
    }

    func testFormatsHoursOnceAnHourIsReached() {
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(3600), "1:00:00")
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(3661), "1:01:01")
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(36000), "10:00:00")
    }

    func testFormatTruncatesFractionalSeconds() {
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(59.99), "0:59")
    }

    func testFormatRejectsInvalidDurations() {
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(.nan), "0:00")
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(.infinity), "0:00")
        XCTAssertEqual(LiquidGlassBottomPill.formatTime(-5), "0:00")
    }

    // MARK: Container HUD bookkeeping

    func testEmptyVideoIDIsIgnored() {
        let container = makeContainer()
        container.updateVideo(tabID: "t1", videoID: "", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        XCTAssertTrue(container.subviews.isEmpty)
    }

    func testFirstUpdateCreatesOneHUDPerVideo() {
        let container = makeContainer()
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        container.updateVideo(tabID: "t1", videoID: "v2", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        XCTAssertEqual(container.subviews.count, 2)
    }

    func testRepeatedUpdateReusesHUDAndAppliesFrame() {
        let container = makeContainer()
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        let newRect = NSRect(x: 0, y: 0, width: 400, height: 225)
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":2}"#, rect: newRect, visible: true)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertEqual(container.subviews.first?.frame, newRect)
    }

    func testHUDStaysHiddenUntilItsTabBecomesActive() {
        let container = makeContainer()
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        XCTAssertTrue(container.subviews.first?.isHidden == true, "no tab is active yet")
        container.setActiveTab(id: "t1")
        XCTAssertFalse(container.subviews.first?.isHidden ?? true)
    }

    func testSwitchingTabsHidesOtherTabsHUDs() {
        let container = makeContainer()
        container.setActiveTab(id: "t1")
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        container.updateVideo(tabID: "t2", videoID: "v9", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        let byTab = container.subviews.map { $0.isHidden }
        XCTAssertEqual(byTab.filter { !$0 }.count, 1, "only the active tab's HUD is shown")
        container.setActiveTab(id: "t2")
        XCTAssertEqual(container.subviews.filter { !$0.isHidden }.count, 1)
        XCTAssertEqual(container.subviews.filter { !$0.isHidden }.first?.frame, rect)
    }

    func testInvisibleUpdateHidesWithoutRemoving() {
        let container = makeContainer()
        container.setActiveTab(id: "t1")
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":1}"#, rect: rect, visible: false)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews.first?.isHidden == true)
    }

    func testEmptyStateJSONTearsDownHUD() {
        let container = makeContainer()
        container.setActiveTab(id: "t1")
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        container.updateVideo(tabID: "t1", videoID: "v1", stateJSON: "", rect: rect, visible: true)
        XCTAssertTrue(container.subviews.isEmpty)
    }

    func testEmptyStateForUnknownVideoDoesNothing() {
        let container = makeContainer()
        container.updateVideo(tabID: "t1", videoID: "ghost", stateJSON: "", rect: rect, visible: false)
        XCTAssertTrue(container.subviews.isEmpty)
    }

    func testClearTabRemovesOnlyThatTabsHUDs() {
        let container = makeContainer()
        container.updateVideo(tabID: "t1", videoID: "a", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        container.updateVideo(tabID: "t1", videoID: "b", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        container.updateVideo(tabID: "t2", videoID: "c", stateJSON: #"{"cur":1}"#, rect: rect, visible: true)
        container.clearTab(id: "t1")
        XCTAssertEqual(container.subviews.count, 1)
    }

    func testClearingUnknownTabIsHarmless() {
        let container = makeContainer()
        container.clearTab(id: "nope")
        XCTAssertTrue(container.subviews.isEmpty)
    }
}
