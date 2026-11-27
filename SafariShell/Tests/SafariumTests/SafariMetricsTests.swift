import XCTest
import AppKit
@testable import Safarium

final class SafariMetricsTests: HermeticTestCase {
    // MARK: - Window and toolbar

    func testWindowConstants() {
        XCTAssertEqual(SafariMetrics.windowCornerRadius, 26)
        XCTAssertEqual(SafariMetrics.defaultWindowWidth, 1200)
        XCTAssertEqual(SafariMetrics.defaultWindowHeight, 800)
        XCTAssertEqual(SafariMetrics.minWindowWidth, 680)
        XCTAssertEqual(SafariMetrics.minWindowHeight, 460)
    }

    func testToolbarConstants() {
        XCTAssertEqual(SafariMetrics.toolbarHeight, 48)
        XCTAssertEqual(SafariMetrics.backgroundExtensionBleedHeight, 52)
        XCTAssertEqual(SafariMetrics.trafficLightTrailingEdge, 80)
    }

    func testDefaultWindowIsLargerThanMinimum() {
        XCTAssertGreaterThan(SafariMetrics.defaultWindowWidth, SafariMetrics.minWindowWidth)
        XCTAssertGreaterThan(SafariMetrics.defaultWindowHeight, SafariMetrics.minWindowHeight)
    }

    func testBleedMatchesToolbarHeight() {
        XCTAssertEqual(SafariMetrics.backgroundExtensionBleedHeight, SafariMetrics.toolbarHeight)
    }

    // MARK: - Glass capsules and groups

    func testGlassConstants() {
        XCTAssertEqual(SafariMetrics.glassButtonSize, 36)
        XCTAssertEqual(SafariMetrics.glassButtonCornerRadius, 18)
        XCTAssertEqual(SafariMetrics.glassButtonTopInset, 8)
        XCTAssertEqual(SafariMetrics.glassContainerMergeSpacing, 0)
    }

    func testGlassCapsuleIsFullyRounded() {
        XCTAssertEqual(SafariMetrics.glassButtonCornerRadius * 2, SafariMetrics.glassButtonSize)
    }

    func testLeftGroupConstants() {
        XCTAssertEqual(SafariMetrics.leftGroup1StartX, 95)
        XCTAssertEqual(SafariMetrics.sidebarCapsuleWidth, 62)
        XCTAssertEqual(SafariMetrics.backButtonWidth, 36)
        XCTAssertEqual(SafariMetrics.backForwardCapsuleWidth, 72)
        XCTAssertEqual(SafariMetrics.leftGroupInterGap, 7)
    }

    func testBackForwardCapsuleIsTwoButtonsWide() {
        XCTAssertEqual(SafariMetrics.backButtonWidth * 2, SafariMetrics.backForwardCapsuleWidth)
    }

    func testRightGroupConstants() {
        XCTAssertEqual(SafariMetrics.rightCapsuleWidth, 148)
        XCTAssertEqual(SafariMetrics.rightGroupTrailingMargin, 8)
    }

    func testLeftGroupStartsAfterTrafficLights() {
        XCTAssertGreaterThan(SafariMetrics.leftGroup1StartX, SafariMetrics.trafficLightTrailingEdge)
    }

    // MARK: - Tab track and address bar

    func testTabTrackConstants() {
        XCTAssertEqual(SafariMetrics.tabBarTopInset, 8)
        XCTAssertEqual(SafariMetrics.tabPillHeight, 36)
        XCTAssertEqual(SafariMetrics.tabPillCornerRadius, 18)
        XCTAssertEqual(SafariMetrics.tabInnerInset, 2.5)
        XCTAssertEqual(SafariMetrics.tabInnerHeight, 31)
        XCTAssertEqual(SafariMetrics.tabInnerCornerRadius, 15.5)
        XCTAssertEqual(SafariMetrics.tabPillSpacing, 0)
    }

    func testInnerPillFitsInsideOuterTrack() {
        XCTAssertEqual(SafariMetrics.tabInnerHeight + 2 * SafariMetrics.tabInnerInset, SafariMetrics.tabPillHeight)
    }

    func testInnerCornerIsHalfInnerHeight() {
        XCTAssertEqual(SafariMetrics.tabInnerCornerRadius * 2, SafariMetrics.tabInnerHeight)
    }

    func testOuterTrackHeightMatchesGlassButtonHeight() {
        XCTAssertEqual(SafariMetrics.tabPillHeight, SafariMetrics.glassButtonSize)
        XCTAssertEqual(SafariMetrics.tabPillCornerRadius, SafariMetrics.glassButtonCornerRadius)
    }

    func testActivePillWidthOrdering() {
        XCTAssertEqual(SafariMetrics.activePillMinWidth, 220)
        XCTAssertEqual(SafariMetrics.activePillSingleTabWidth, 290)
        XCTAssertEqual(SafariMetrics.activePillSingleTabSidebarWidth, 280)
        XCTAssertEqual(SafariMetrics.activePillFocusedMinWidth, 360)
        XCTAssertEqual(SafariMetrics.activePillFocusedMaxWidth, 520)
        XCTAssertLessThan(SafariMetrics.activePillMinWidth, SafariMetrics.activePillSingleTabWidth)
        XCTAssertLessThan(SafariMetrics.activePillFocusedMinWidth, SafariMetrics.activePillFocusedMaxWidth)
        XCTAssertLessThan(SafariMetrics.activePillSingleTabSidebarWidth, SafariMetrics.activePillSingleTabWidth)
    }

    func testInactiveTabAndFieldConstants() {
        XCTAssertEqual(SafariMetrics.inactiveTabMinWidth, 80)
        XCTAssertEqual(SafariMetrics.fieldIconSize, 16)
        XCTAssertEqual(SafariMetrics.fieldIconBadgeSize, 20)
        XCTAssertEqual(SafariMetrics.addressFieldHeight, 28)
        XCTAssertEqual(SafariMetrics.assistantButtonWidth, 22)
        XCTAssertEqual(SafariMetrics.assistantButtonHeight, 28)
    }

    func testBadgeIsLargerThanIcon() {
        XCTAssertGreaterThan(SafariMetrics.fieldIconBadgeSize, SafariMetrics.fieldIconSize)
    }

    // MARK: - Sidebar

    func testSidebarConstants() {
        XCTAssertEqual(SafariMetrics.sidebarDefaultWidth, 240)
        XCTAssertEqual(SafariMetrics.sidebarMinWidth, 200)
        XCTAssertEqual(SafariMetrics.sidebarMaxWidth, 320)
        XCTAssertEqual(SafariMetrics.sidebarHeaderCapsuleWidth, 72)
        XCTAssertEqual(SafariMetrics.sidebarRowHeight, 32)
    }

    func testSidebarDefaultIsWithinBounds() {
        XCTAssertGreaterThanOrEqual(SafariMetrics.sidebarDefaultWidth, SafariMetrics.sidebarMinWidth)
        XCTAssertLessThanOrEqual(SafariMetrics.sidebarDefaultWidth, SafariMetrics.sidebarMaxWidth)
    }

    func testSidebarHeaderCapsuleFitsInsideDefaultSidebar() {
        XCTAssertLessThan(SafariMetrics.sidebarHeaderCapsuleWidth, SafariMetrics.sidebarDefaultWidth)
    }

    // MARK: - Sampling and hysteresis

    func testSamplingConstants() {
        XCTAssertEqual(SafariMetrics.topEdgeStripHeight, 3)
        XCTAssertEqual(SafariMetrics.luminanceSwitchToLightInkThreshold, 0.42, accuracy: 1e-12)
        XCTAssertEqual(SafariMetrics.luminanceSwitchToDarkInkThreshold, 0.52, accuracy: 1e-12)
        XCTAssertEqual(SafariMetrics.topEdgeSampleDebounceInterval, 0.045, accuracy: 1e-12)
        XCTAssertEqual(SafariMetrics.topEdgeTintAnimationDuration, 0.22, accuracy: 1e-12)
    }

    func testStripHeightIsWithinSamplerRange() {
        // BrowserEngine clamps the sampled strip to 2...4pt; the metric must sit inside that range.
        XCTAssertTrue((2.0...4.0).contains(SafariMetrics.topEdgeStripHeight))
    }

    func testHysteresisBandIsOrderedAndNonEmpty() {
        XCTAssertLessThan(SafariMetrics.luminanceSwitchToLightInkThreshold, SafariMetrics.luminanceSwitchToDarkInkThreshold)
        XCTAssertTrue((0.0...1.0).contains(SafariMetrics.luminanceSwitchToLightInkThreshold))
        XCTAssertTrue((0.0...1.0).contains(SafariMetrics.luminanceSwitchToDarkInkThreshold))
    }

    func testDebounceIsShorterThanAnimation() {
        XCTAssertLessThan(SafariMetrics.topEdgeSampleDebounceInterval, SafariMetrics.topEdgeTintAnimationDuration)
    }

    // MARK: - EDR exposure with nil screen

    func testExposureIsUnityWithoutScreen() {
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(for: nil), 1.0)
        XCTAssertEqual(SafariMetrics.accentLinearExposure(for: nil), 1.0)
    }

    // MARK: - EDR exposure by headroom

    func testActiveExposureIsUnityAtOrBelowThreshold() {
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 1.0), 1.0)
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 1.02), 1.0, "guard is strictly greater than 1.02")
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 0.3), 1.0, "headroom below 1 is clamped")
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: -4), 1.0)
    }

    func testActiveExposureFormulaAtSampleHeadroom() {
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 1.021), 1.0 + 0.042 * 0.021, accuracy: 1e-6)
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 2.0), 1.042, accuracy: 1e-6)
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 2.6), 1.0 + 0.042 * 1.6, accuracy: 1e-6)
    }

    func testActiveExposureSaturatesAtLargeHeadroom() {
        let cap = 1.0 + 0.042 * 1.6
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 3.0), cap, accuracy: 1e-6)
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(headroom: 16.0), cap, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(SafariMetrics.activeTabLinearExposure(headroom: 1000), 1.07)
    }

    func testAccentExposureIsUnityAtOrBelowThreshold() {
        XCTAssertEqual(SafariMetrics.accentLinearExposure(headroom: 1.0), 1.0)
        XCTAssertEqual(SafariMetrics.accentLinearExposure(headroom: 1.02), 1.0)
        XCTAssertEqual(SafariMetrics.accentLinearExposure(headroom: 0), 1.0)
    }

    func testAccentExposureFormulaAndSaturation() {
        XCTAssertEqual(SafariMetrics.accentLinearExposure(headroom: 2.0), 1.06, accuracy: 1e-6)
        XCTAssertEqual(SafariMetrics.accentLinearExposure(headroom: 2.5), 1.09, accuracy: 1e-6)
        XCTAssertEqual(SafariMetrics.accentLinearExposure(headroom: 100), 1.09, accuracy: 1e-6)
    }

    func testExposureIsMonotonicInHeadroom() {
        let sweep = stride(from: 1.0, through: 5.0, by: 0.05).map { CGFloat($0) }
        let active = sweep.map { SafariMetrics.activeTabLinearExposure(headroom: $0) }
        let accent = sweep.map { SafariMetrics.accentLinearExposure(headroom: $0) }
        for i in 1..<sweep.count {
            XCTAssertGreaterThanOrEqual(active[i], active[i - 1], "active exposure dropped at headroom \(sweep[i])")
            XCTAssertGreaterThanOrEqual(accent[i], accent[i - 1], "accent exposure dropped at headroom \(sweep[i])")
        }
    }

    func testAccentLiftsMoreThanActiveForSameHeadroomAboveFactor() {
        // Accent slope (0.06 per stop) is steeper than active (0.042) until each saturates.
        XCTAssertGreaterThan(SafariMetrics.accentLinearExposure(headroom: 1.5), SafariMetrics.activeTabLinearExposure(headroom: 1.5))
    }

    func testExposureStaysAboveUnity() {
        for h in [CGFloat(1.0), 1.5, 2.0, 4.0, 8.0] {
            XCTAssertGreaterThanOrEqual(SafariMetrics.activeTabLinearExposure(headroom: h), 1.0)
            XCTAssertGreaterThanOrEqual(SafariMetrics.accentLinearExposure(headroom: h), 1.0)
        }
    }

    func testScreenOverloadsMatchHeadroomOverloads() {
        XCTAssertEqual(SafariMetrics.activeTabLinearExposure(for: nil), SafariMetrics.activeTabLinearExposure(headroom: 1.0))
        XCTAssertEqual(SafariMetrics.accentLinearExposure(for: nil), SafariMetrics.accentLinearExposure(headroom: 1.0))
    }
}
