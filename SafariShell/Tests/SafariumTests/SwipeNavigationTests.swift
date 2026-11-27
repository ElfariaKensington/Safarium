import XCTest
import AppKit
@testable import Safarium

/// Tests for the two-finger back/forward swipe state machine: gesture admission rules, commit thresholds
/// (30 % progress or a 520 pt/s flick above 6 %) and the commit callback. Events are synthesised from CGEvents with
/// explicit timestamps so velocity is deterministic.
@MainActor
final class SwipeNavigationTests: HermeticTestCase {

    nonisolated(unsafe) private var controller: SwipeNavigationController!
    nonisolated(unsafe) private var stage: NSView!
    nonisolated(unsafe) private var target: NSView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        stage = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        target = NSView(frame: stage.bounds)
        stage.addSubview(target)
        controller = SwipeNavigationController()
        controller.attach(stageView: stage, targetPageView: target)
        controller.canGoBack = { true }
        controller.canGoForward = { true }
        controller.snapshotForDirection = { _ in nil }
    }

    override func tearDown() {
        controller.cancelImmediately()
        controller = nil
        stage = nil
        target = nil
        super.tearDown()
    }

    /// Builds a trackpad scroll event. `phase` uses CoreGraphics scroll-phase values
    /// (began = 1, changed = 2, ended = 4, cancelled = 8); `momentum` uses momentum-phase values (began = 1, continue = 2, end = 3).
    private func scrollEvent(dx: Double, dy: Double = 0, time: Double, phase: Int64 = 0, momentum: Int64 = 0,
                             precise: Bool = true) throws -> NSEvent {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                               wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            throw XCTSkip("cannot synthesize scroll event")
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.timestamp = UInt64(time * 1_000_000_000)
        guard let event = NSEvent(cgEvent: cg) else { throw XCTSkip("cannot wrap CGEvent") }
        return event
    }

    // MARK: Admission

    func testIdleControllerIsNotTracking() {
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }

    func testDiscreteWheelNeverStartsSwipe() throws {
        let e = try scrollEvent(dx: 30, time: 1, phase: 1, precise: false)
        XCTAssertFalse(controller.handleScrollWheel(e))
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }

    func testVerticalDominantGestureIsNotASwipe() throws {
        let e = try scrollEvent(dx: 3, dy: 10, time: 1, phase: 1)
        XCTAssertFalse(controller.handleScrollWheel(e))
    }

    func testSmallHorizontalJitterIsNotASwipe() throws {
        let e = try scrollEvent(dx: 1.5, time: 1, phase: 1)
        XCTAssertFalse(controller.handleScrollWheel(e), "|dx| must exceed 1.5 pt")
    }

    func testBackSwipeBlockedWithoutHistory() throws {
        controller.canGoBack = { false }
        let e = try scrollEvent(dx: 30, time: 1, phase: 1)
        XCTAssertFalse(controller.handleScrollWheel(e))
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }

    func testForwardSwipeBlockedWithoutForwardHistory() throws {
        controller.canGoForward = { false }
        let e = try scrollEvent(dx: -30, time: 1, phase: 1)
        XCTAssertFalse(controller.handleScrollWheel(e))
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }

    func testRightwardSwipeWithHistoryStartsTracking() throws {
        let e = try scrollEvent(dx: 20, time: 1, phase: 1)
        XCTAssertTrue(controller.handleScrollWheel(e))
        XCTAssertTrue(controller.isTrackingOrAnimating)
    }

    func testMomentumEventCannotStartSwipe() throws {
        let e = try scrollEvent(dx: 30, time: 1, momentum: 2)
        XCTAssertFalse(controller.handleScrollWheel(e))
    }

    func testWithoutAttachedViewsSwipeIsRefused() throws {
        let bare = SwipeNavigationController()
        bare.canGoBack = { true }
        let e = try scrollEvent(dx: 30, time: 1, phase: 1)
        _ = bare.handleScrollWheel(e)
        XCTAssertFalse(bare.isTrackingOrAnimating)
    }

    // MARK: Commit rules

    func testFullDragPastThirtyPercentCommitsBack() throws {
        var committed: [SwipeNavigationController.Direction] = []
        controller.onCommitNavigation = { committed.append($0) }
        XCTAssertTrue(controller.handleScrollWheel(try scrollEvent(dx: 10, time: 1.0, phase: 1)))
        XCTAssertTrue(controller.handleScrollWheel(try scrollEvent(dx: 300, time: 1.1, phase: 2)))
        // 310 pt / 800 pt = 0.39 progress
        XCTAssertTrue(controller.handleScrollWheel(try scrollEvent(dx: 0, time: 1.2, phase: 4)))
        spinRunLoop(0.6)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first, .back)
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }

    func testSlowShortDragCancelsWithoutCommit() throws {
        var committed: [SwipeNavigationController.Direction] = []
        controller.onCommitNavigation = { committed.append($0) }
        _ = controller.handleScrollWheel(try scrollEvent(dx: 10, time: 1.0, phase: 1))
        // 70 pt / 800 = 0.0875 progress, velocity = (60 / 0.1) * 0.45 = 270 pt/s (< 520)
        _ = controller.handleScrollWheel(try scrollEvent(dx: 60, time: 1.1, phase: 2))
        _ = controller.handleScrollWheel(try scrollEvent(dx: 0, time: 1.2, phase: 4))
        spinRunLoop(0.6)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }

    func testFastFlickCommitsAboveSixPercentProgress() throws {
        var committed: [SwipeNavigationController.Direction] = []
        controller.onCommitNavigation = { committed.append($0) }
        _ = controller.handleScrollWheel(try scrollEvent(dx: 10, time: 1.0, phase: 1))
        // 50 pt / 800 = 0.0625 progress; velocity = (40 / 0.01) * 0.45 = 1800 pt/s (>= 520)
        _ = controller.handleScrollWheel(try scrollEvent(dx: 40, time: 1.01, phase: 2))
        _ = controller.handleScrollWheel(try scrollEvent(dx: 0, time: 1.02, phase: 4))
        spinRunLoop(0.6)
        XCTAssertEqual(committed, [.back])
    }

    func testFlickBelowSixPercentDoesNotCommitEvenWhenFast() throws {
        var committed: [SwipeNavigationController.Direction] = []
        controller.onCommitNavigation = { committed.append($0) }
        _ = controller.handleScrollWheel(try scrollEvent(dx: 2, time: 1.0, phase: 1))
        // 0.04 * 800 = 32 pt total: below 6 % progress
        _ = controller.handleScrollWheel(try scrollEvent(dx: 30, time: 1.01, phase: 2))
        _ = controller.handleScrollWheel(try scrollEvent(dx: 0, time: 1.02, phase: 4))
        spinRunLoop(0.6)
        XCTAssertTrue(committed.isEmpty)
    }

    func testForwardSwipeCommitsOnLeftwardDrag() throws {
        var committed: [SwipeNavigationController.Direction] = []
        controller.onCommitNavigation = { committed.append($0) }
        _ = controller.handleScrollWheel(try scrollEvent(dx: -10, time: 1.0, phase: 1))
        _ = controller.handleScrollWheel(try scrollEvent(dx: -300, time: 1.1, phase: 2))
        _ = controller.handleScrollWheel(try scrollEvent(dx: 0, time: 1.2, phase: 4))
        spinRunLoop(0.6)
        XCTAssertEqual(committed, [.forward])
    }

    func testMomentumAfterTrackingFinalisesSwipe() throws {
        XCTAssertTrue(controller.handleScrollWheel(try scrollEvent(dx: 20, time: 1.0, phase: 1)))
        XCTAssertTrue(controller.handleScrollWheel(try scrollEvent(dx: 0, time: 1.05, momentum: 2)))
        spinRunLoop(0.6)
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }

    func testResidualMomentumIsSwallowedWhileAnimating() throws {
        _ = controller.handleScrollWheel(try scrollEvent(dx: 20, time: 1.0, phase: 1))
        _ = controller.handleScrollWheel(try scrollEvent(dx: 0, time: 1.05, phase: 4))
        XCTAssertTrue(controller.isTrackingOrAnimating)
        XCTAssertTrue(controller.handleScrollWheel(try scrollEvent(dx: 50, time: 1.06, momentum: 2)),
                      "momentum from the committed gesture is consumed")
        spinRunLoop(0.6)
    }

    func testCancelImmediatelyReturnsToIdle() throws {
        _ = controller.handleScrollWheel(try scrollEvent(dx: 20, time: 1.0, phase: 1))
        XCTAssertTrue(controller.isTrackingOrAnimating)
        controller.cancelImmediately()
        XCTAssertFalse(controller.isTrackingOrAnimating)
    }
}
