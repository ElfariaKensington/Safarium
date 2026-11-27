import XCTest
import AppKit
@testable import Safarium

@MainActor
final class ScrollResidualAndMotionTests: HermeticTestCase {
    private func wheelEvent(deltaY: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)  // what a trackpad produces (precise point deltas)
        return NSEvent(cgEvent: cg)
    }

    func testResidualScrollEventCarriesOnlyTheRemainder() throws {
        let original = try XCTUnwrap(wheelEvent(deltaY: -90))
        XCTAssertEqual(original.scrollingDeltaY, -90, accuracy: 0.5)
        let residual = SafariWindowController.scrollEvent(original, withVerticalPointDelta: -22)
        XCTAssertEqual(residual.scrollingDeltaY, -22, accuracy: 0.5)
        XCTAssertEqual(original.scrollingDeltaY, -90, accuracy: 0.5, "the original event must not be mutated")
    }

    func testResidualScrollEventWithNegligibleDeltaReturnsOriginal() throws {
        let original = try XCTUnwrap(wheelEvent(deltaY: -40))
        XCTAssertTrue(SafariWindowController.scrollEvent(original, withVerticalPointDelta: 0.001) === original)
    }

    func testEngineExposesAndClearsResidualAfterCrossingZero() {
        let engine = ElasticScrollEngine()
        engine.updateMetrics(scrollY: 0, contentHeight: 2000, viewportHeight: 800, canInnerScrollUp: false, canInnerScrollDown: false, isReloadableWebPage: true, isPageLoading: false)
        XCTAssertTrue(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: 30))
        XCTAssertFalse(engine.handleDirectTouchEvent(phase: .changed, deltaX: 0, deltaY: -50))
        XCTAssertEqual(engine.takeResidualForwardDeltaY() ?? 0, -20, accuracy: 0.01)
        XCTAssertNil(engine.takeResidualForwardDeltaY(), "the residual is consumed exactly once")
    }

    func testReduceMotionOverrideIsHonoured() {
        MotionPreference.overrideForTesting = true
        XCTAssertTrue(MotionPreference.reduced)
        MotionPreference.overrideForTesting = false
        XCTAssertFalse(MotionPreference.reduced)
        MotionPreference.overrideForTesting = nil
    }

    func testCustomizeSheetPresentsInFinalStateUnderReduceMotion() {
        MotionPreference.overrideForTesting = true
        defer { MotionPreference.overrideForTesting = nil }
        let sheet = CustomizeToolbarSheetView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        sheet.present(extensions: [], hiddenExtensionIDs: [], isDark: false)
        spinRunLoop(0.1)  // no 0.36 s animation to wait for
        XCTAssertEqual(sheet.subviews.first?.alphaValue ?? 1, 1, accuracy: 0.01)
        sheet.dismiss(animated: true)
        XCTAssertTrue(sheet.isHidden, "dismiss must be immediate under Reduce Motion")
    }
}
