import XCTest
import AppKit
@testable import Safarium

/// Tests for `AdaptiveChromeTheme` colour derivation, `TopEdgeColorSample` luminance and the
/// `AdaptiveChromeController` luminance hysteresis (0.42 to light ink, 0.52 back to dark ink).
@MainActor
final class TopEdgeColorSamplerTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func srgb(_ c: NSColor) -> NSColor {
        c.usingColorSpace(.sRGB) ?? c
    }

    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private func theme(_ c: NSColor, lightInk: Bool) -> AdaptiveChromeTheme {
        AdaptiveChromeTheme(sampledColor: c, relativeLuminance: 0, prefersLightInk: lightInk)
    }

    private func sample(_ c: NSColor, luminance: Double) -> TopEdgeColorSample {
        TopEdgeColorSample(color: c, relativeLuminance: luminance)
    }

    // MARK: Luminance of sampled pixels

    func testRelativeLuminanceOfWhiteAndBlack() {
        XCTAssertEqual(TopEdgeColorSample.computeRelativeLuminance(for: .white), 1.0, accuracy: 1e-6)
        XCTAssertEqual(TopEdgeColorSample.computeRelativeLuminance(for: .black), 0.0, accuracy: 1e-9)
    }

    func testRelativeLuminanceOfMidGreyUsesLinearisedSRGB() {
        // sRGB 0.5 -> linear ((0.5 + 0.055) / 1.055)^2.4 = 0.2140
        XCTAssertEqual(TopEdgeColorSample.computeRelativeLuminance(for: color(0.5, 0.5, 0.5)), 0.2140, accuracy: 1e-4)
    }

    func testRelativeLuminanceWeightsGreenMostHeavily() {
        XCTAssertEqual(TopEdgeColorSample.computeRelativeLuminance(for: color(1, 0, 0)), 0.2126, accuracy: 1e-6)
        XCTAssertEqual(TopEdgeColorSample.computeRelativeLuminance(for: color(0, 1, 0)), 0.7152, accuracy: 1e-6)
        XCTAssertEqual(TopEdgeColorSample.computeRelativeLuminance(for: color(0, 0, 1)), 0.0722, accuracy: 1e-6)
    }

    func testSampleInitComputesLuminanceUnlessProvided() {
        let computed = TopEdgeColorSample(color: .white)
        XCTAssertEqual(computed.relativeLuminance, 1.0, accuracy: 1e-6)
        let explicit = TopEdgeColorSample(color: .white, relativeLuminance: 0.3)
        XCTAssertEqual(explicit.relativeLuminance, 0.3, accuracy: 1e-12)
    }

    // MARK: Theme ink choices

    func testLightInkUsesWhiteInk() {
        let t = theme(.black, lightInk: true)
        XCTAssertEqual(srgb(t.primaryInkColor).alphaComponent, 0.94, accuracy: 1e-6)
        XCTAssertEqual(srgb(t.primaryInkColor).redComponent, 1.0, accuracy: 1e-6)
        XCTAssertEqual(srgb(t.secondaryInkColor).alphaComponent, 0.76, accuracy: 1e-6)
        XCTAssertEqual(srgb(t.disabledInkColor).alphaComponent, 0.30, accuracy: 1e-6)
    }

    func testDarkInkUsesBlackInk() {
        let t = theme(.white, lightInk: false)
        XCTAssertEqual(srgb(t.primaryInkColor).alphaComponent, 0.88, accuracy: 1e-6)
        XCTAssertEqual(srgb(t.primaryInkColor).redComponent, 0.0, accuracy: 1e-6)
        XCTAssertEqual(srgb(t.secondaryInkColor).alphaComponent, 0.72, accuracy: 1e-6)
        XCTAssertEqual(srgb(t.disabledInkColor).alphaComponent, 0.28, accuracy: 1e-6)
    }

    // MARK: Glass tint boundaries

    func testGlassTintIsNilForNearBlackWithLightInk() {
        XCTAssertNil(theme(color(0.05, 0.05, 0.05), lightInk: true).glassTintColor)
        XCTAssertNil(theme(.black, lightInk: true).glassTintColor)
    }

    func testGlassTintAtBlackBoundaryIsKept() throws {
        let tint = try XCTUnwrap(theme(color(0.06, 0.06, 0.06), lightInk: true).glassTintColor)
        XCTAssertEqual(tint.alphaComponent, 0.24, accuracy: 1e-6)
    }

    func testGlassTintIsNilForNearWhiteWithDarkInk() {
        XCTAssertNil(theme(color(0.95, 0.95, 0.95), lightInk: false).glassTintColor)
        XCTAssertNil(theme(.white, lightInk: false).glassTintColor)
    }

    func testGlassTintAtWhiteBoundaryIsKept() throws {
        let tint = try XCTUnwrap(theme(color(0.94, 0.94, 0.94), lightInk: false).glassTintColor)
        XCTAssertEqual(tint.alphaComponent, 0.16, accuracy: 1e-6)
    }

    func testGlassTintRequiresAllChannelsNearWhite() throws {
        // Only red is near white, so the tint is kept.
        let tint = try XCTUnwrap(theme(color(0.99, 0.5, 0.5), lightInk: false).glassTintColor)
        XCTAssertEqual(srgb(tint).redComponent, 0.99, accuracy: 0.005)
    }

    // MARK: Fills, tracks and wash

    func testActiveTabFillOnLightInkBlendsSixPercentWhite() {
        let fill = srgb(theme(.black, lightInk: true).activeTabFillColor)
        // NSColor.blended(withFraction:of:) blends in the colour space of the operands; the result is a light grey just above black.
        XCTAssertTrue((0.05...0.09).contains(fill.redComponent), "got \(fill.redComponent)")
        XCTAssertEqual(fill.redComponent, fill.greenComponent, accuracy: 1e-6)
    }

    func testActiveTabFillOnNearWhiteDarkInkIsPureWhite() {
        let fill = srgb(theme(color(0.96, 0.96, 0.96), lightInk: false).activeTabFillColor)
        XCTAssertEqual(fill.redComponent, 1.0, accuracy: 1e-6)
        XCTAssertEqual(fill.blueComponent, 1.0, accuracy: 1e-6)
    }

    func testActiveTabFillOnMidGreyDarkInkBlendsEightyTwoPercentWhite() {
        let fill = srgb(theme(color(0.5, 0.5, 0.5), lightInk: false).activeTabFillColor)
        // 0.5 * 0.18 + 0.82 = 0.91
        XCTAssertTrue((0.89...0.93).contains(fill.redComponent), "got \(fill.redComponent)")
    }

    func testTabTrackAndBorderAlphasDifferByInk() {
        let light = theme(.black, lightInk: true)
        let dark = theme(.white, lightInk: false)
        XCTAssertEqual(srgb(light.tabTrackBackgroundColor).alphaComponent, 0.10, accuracy: 1e-6)
        XCTAssertEqual(srgb(light.tabTrackBorderColor).alphaComponent, 0.08, accuracy: 1e-6)
        XCTAssertEqual(srgb(dark.tabTrackBackgroundColor).alphaComponent, 0.055, accuracy: 1e-6)
        XCTAssertEqual(srgb(dark.tabTrackBorderColor).alphaComponent, 0.055, accuracy: 1e-6)
    }

    func testTabDividerAndHairlineFollowInk() {
        let light = theme(.black, lightInk: true)
        let dark = theme(.white, lightInk: false)
        XCTAssertEqual(srgb(light.tabDividerColor).alphaComponent, 0.18, accuracy: 1e-6)
        XCTAssertEqual(srgb(dark.tabDividerColor).alphaComponent, 0.16, accuracy: 1e-6)
        XCTAssertEqual(light.toolbarBottomHairlineColor.alphaComponent, 0, accuracy: 1e-9)
        XCTAssertEqual(srgb(dark.toolbarBottomHairlineColor).alphaComponent, 0.06, accuracy: 1e-6)
    }

    func testTopChromeWashIsClearOnNearWhiteWithDarkInk() {
        XCTAssertEqual(theme(color(0.96, 0.96, 0.96), lightInk: false).topChromeWashColor.alphaComponent, 0)
    }

    func testTopChromeWashUsesSampledColorWithInkDependentAlpha() {
        let dark = srgb(theme(color(0.2, 0.4, 0.6), lightInk: false).topChromeWashColor)
        XCTAssertEqual(dark.alphaComponent, 0.10, accuracy: 1e-6)
        XCTAssertEqual(dark.greenComponent, 0.4, accuracy: 0.005)
        let light = srgb(theme(color(0.96, 0.96, 0.96), lightInk: true).topChromeWashColor)
        XCTAssertEqual(light.alphaComponent, 0.16, accuracy: 1e-6, "near-white is only clear for dark ink")
    }

    func testPreferredAppearanceMatchesInk() {
        XCTAssertEqual(theme(.black, lightInk: true).preferredAppearance?.name, .darkAqua)
        XCTAssertEqual(theme(.white, lightInk: false).preferredAppearance?.name, .aqua)
    }

    func testDefaultThemesHaveExpectedInk() {
        XCTAssertTrue(AdaptiveChromeTheme.defaultDark.prefersLightInk)
        XCTAssertFalse(AdaptiveChromeTheme.defaultLight.prefersLightInk)
        XCTAssertEqual(AdaptiveChromeTheme.defaultDark.relativeLuminance, 0)
        XCTAssertEqual(AdaptiveChromeTheme.defaultLight.relativeLuminance, 1)
    }

    func testThemeEqualityIsValueBased() {
        XCTAssertEqual(theme(.black, lightInk: true), theme(.black, lightInk: true))
        XCTAssertNotEqual(theme(.black, lightInk: true), theme(.black, lightInk: false))
    }

    // MARK: Controller hysteresis

    func testControllerStartsOnDefaultLightTheme() {
        XCTAssertEqual(AdaptiveChromeController().currentTheme, .defaultLight)
    }

    func testFirstSampleAlwaysNotifiesEvenWhenInkUnchanged() {
        let controller = AdaptiveChromeController()
        var calls = 0
        controller.onThemeDidChange = { _, _ in calls += 1 }
        controller.apply(sample: sample(.white, luminance: 1.0))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(controller.currentTheme.prefersLightInk)
    }

    func testDarkPageSwitchesToLightInkBelowFortyTwoPercent() {
        let controller = AdaptiveChromeController()
        controller.apply(sample: sample(.black, luminance: 0.10))
        XCTAssertTrue(controller.currentTheme.prefersLightInk)
    }

    func testLightPageStaysDarkInkAtFortyTwoPercent() {
        let controller = AdaptiveChromeController()
        controller.apply(sample: sample(color(0.6, 0.6, 0.6), luminance: 0.42))
        XCTAssertFalse(controller.currentTheme.prefersLightInk, "0.42 itself is not below the threshold")
    }

    func testDarkInkSwitchesToLightJustBelowFortyTwoPercent() {
        let controller = AdaptiveChromeController()
        controller.apply(sample: sample(color(0.6, 0.6, 0.6), luminance: 0.4199))
        XCTAssertTrue(controller.currentTheme.prefersLightInk)
    }

    func testLightInkHoldsWithinHysteresisBand() {
        let controller = AdaptiveChromeController()
        controller.apply(sample: sample(.black, luminance: 0.10))
        controller.apply(sample: sample(color(0.2, 0.2, 0.2), luminance: 0.50))
        XCTAssertTrue(controller.currentTheme.prefersLightInk, "0.50 is inside the 0.42 - 0.52 band")
        controller.apply(sample: sample(color(0.2, 0.2, 0.2), luminance: 0.52))
        XCTAssertTrue(controller.currentTheme.prefersLightInk, "0.52 itself still keeps light ink")
    }

    func testLightInkFlipsToDarkAboveFiftyTwoPercent() {
        let controller = AdaptiveChromeController()
        controller.apply(sample: sample(.black, luminance: 0.10))
        controller.apply(sample: sample(color(0.8, 0.8, 0.8), luminance: 0.5201))
        XCTAssertFalse(controller.currentTheme.prefersLightInk)
    }

    func testDarkInkHoldsInsideHysteresisBand() {
        let controller = AdaptiveChromeController()
        controller.apply(sample: sample(.white, luminance: 0.9))
        controller.apply(sample: sample(color(0.5, 0.5, 0.5), luminance: 0.45))
        XCTAssertFalse(controller.currentTheme.prefersLightInk, "0.45 is inside the band; dark ink persists")
    }

    func testSameInkSmallColourChangeIsSuppressed() {
        let controller = AdaptiveChromeController()
        var calls = 0
        controller.onThemeDidChange = { _, _ in calls += 1 }
        controller.apply(sample: sample(color(0.5, 0.5, 0.5), luminance: 0.2))
        controller.apply(sample: sample(color(0.503, 0.5, 0.5), luminance: 0.2))
        XCTAssertEqual(calls, 1, "a 0.003 channel change is below the 0.004 threshold")
    }

    func testSuppressedSampleKeepsPreviousColour() {
        let controller = AdaptiveChromeController()
        controller.apply(sample: sample(color(0.5, 0.5, 0.5), luminance: 0.2))
        controller.apply(sample: sample(color(0.502, 0.5, 0.5), luminance: 0.2))
        XCTAssertEqual(srgb(controller.currentTheme.sampledColor).redComponent, 0.5, accuracy: 1e-6)
    }

    func testMeaningfulColourChangeNotifiesWithSameInk() {
        let controller = AdaptiveChromeController()
        var calls = 0
        controller.onThemeDidChange = { _, _ in calls += 1 }
        controller.apply(sample: sample(color(0.5, 0.5, 0.5), luminance: 0.2))
        controller.apply(sample: sample(color(0.51, 0.5, 0.5), luminance: 0.2))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(srgb(controller.currentTheme.sampledColor).redComponent, 0.51, accuracy: 1e-6)
    }

    func testInkFlipNotifiesEvenWithoutColourChange() {
        let controller = AdaptiveChromeController()
        var calls = 0
        controller.onThemeDidChange = { _, _ in calls += 1 }
        controller.apply(sample: sample(.black, luminance: 0.1))
        controller.apply(sample: sample(.black, luminance: 0.9))
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(controller.currentTheme.prefersLightInk)
    }

    func testCallbackReceivesThemeAndAnimationFlag() {
        let controller = AdaptiveChromeController()
        var received: (AdaptiveChromeTheme, Bool)?
        controller.onThemeDidChange = { theme, animated in received = (theme, animated) }
        controller.apply(sample: sample(.black, luminance: 0.1), animated: false)
        let (theme, animated) = try! XCTUnwrap(received)
        XCTAssertFalse(animated)
        XCTAssertTrue(theme.prefersLightInk)
        XCTAssertEqual(theme.relativeLuminance, 0.1, accuracy: 1e-12)
        XCTAssertEqual(theme, controller.currentTheme)
    }

    func testCallbackAnimatesByDefault() {
        let controller = AdaptiveChromeController()
        var animatedFlag: Bool?
        controller.onThemeDidChange = { _, animated in animatedFlag = animated }
        controller.apply(sample: sample(.black, luminance: 0.1))
        XCTAssertEqual(animatedFlag, true)
    }
}
