import XCTest
import AppKit
import QuartzCore
@testable import Safarium

/// Tests for `HDRColorFactory` (accent and active-tab tints) and the pure helpers of
/// `ToolbarGlassView` (quintic falloff, glass profile, blur mask pixels).
@MainActor
final class HDRAndBackdropTests: HermeticTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func srgb(_ c: NSColor) -> NSColor {
        c.usingColorSpace(.sRGB) ?? c
    }

    // MARK: HDRColorFactory.accentColor

    func testAccentColorKeepsRequestedAlpha() {
        XCTAssertEqual(HDRColorFactory.accentColor(for: nil, alpha: 0.5).alphaComponent, 0.5, accuracy: 1e-6)
    }

    func testAccentColorDefaultsToOpaque() {
        XCTAssertEqual(HDRColorFactory.accentColor(for: nil).alphaComponent, 1.0, accuracy: 1e-6)
    }

    func testAccentColorIsBlueDominant() {
        let c = srgb(HDRColorFactory.accentColor(for: nil))
        XCTAssertGreaterThan(c.blueComponent, c.greenComponent)
        XCTAssertGreaterThan(c.greenComponent, c.redComponent)
    }

    // MARK: HDRColorFactory.activeTabTint

    func testActiveTabTintIsNilWithoutBase() {
        XCTAssertNil(HDRColorFactory.activeTabTint(base: nil, lightOnDark: true, screen: nil))
        XCTAssertNil(HDRColorFactory.activeTabTint(base: nil, lightOnDark: false, screen: nil))
    }

    func testLightOnDarkTintLiftsBlackToSubtleGrey() throws {
        let tint = try XCTUnwrap(HDRColorFactory.activeTabTint(base: .black, lightOnDark: true, screen: nil))
        let c = srgb(tint)
        XCTAssertEqual(c.redComponent, 0.12, accuracy: 0.01)
        XCTAssertEqual(c.greenComponent, 0.12, accuracy: 0.01)
        XCTAssertEqual(c.blueComponent, 0.13, accuracy: 0.01)
        XCTAssertEqual(c.alphaComponent, 0.10, accuracy: 1e-6)
    }

    func testLightOnDarkTintClampsToOneForWhite() throws {
        let tint = try XCTUnwrap(HDRColorFactory.activeTabTint(base: .white, lightOnDark: true, screen: nil))
        let c = srgb(tint)
        XCTAssertEqual(c.redComponent, 0.72, accuracy: 0.01)
        XCTAssertEqual(c.blueComponent, 0.73, accuracy: 0.01)
        XCTAssertEqual(c.alphaComponent, 0.10, accuracy: 1e-6)
    }

    func testLightOnDarkTintScalesMidGreyWithSixtyPercentGain() throws {
        let base = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let tint = try XCTUnwrap(HDRColorFactory.activeTabTint(base: base, lightOnDark: true, screen: nil))
        XCTAssertEqual(srgb(tint).redComponent, 0.42, accuracy: 0.01)
    }

    func testNearWhiteLightPageReturnsNilForNativeGlass() {
        let base = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        XCTAssertNil(HDRColorFactory.activeTabTint(base: base, lightOnDark: false, screen: nil))
        XCTAssertNil(HDRColorFactory.activeTabTint(base: .white, lightOnDark: false, screen: nil))
    }

    func testLightPageTintUsesBaseAtSixPercentAlpha() throws {
        let base = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let tint = try XCTUnwrap(HDRColorFactory.activeTabTint(base: base, lightOnDark: false, screen: nil))
        let c = srgb(tint)
        XCTAssertEqual(c.redComponent, 0.2, accuracy: 0.005)
        XCTAssertEqual(c.greenComponent, 0.4, accuracy: 0.005)
        XCTAssertEqual(c.blueComponent, 0.6, accuracy: 0.005)
        XCTAssertEqual(c.alphaComponent, 0.06, accuracy: 1e-6)
    }

    func testLightPageNotNearWhiteIfOneChannelIsBelowThreshold() throws {
        let base = NSColor(srgbRed: 1, green: 0.5, blue: 0.95, alpha: 1)
        XCTAssertNotNil(HDRColorFactory.activeTabTint(base: base, lightOnDark: false, screen: nil))
    }

    // MARK: ToolbarGlassView shape

    func testGlassCoversToolbarPlusSoftEdge() {
        XCTAssertEqual(ToolbarGlassView.edgeHeight, 18)
        XCTAssertEqual(ToolbarGlassView.totalHeight, SafariMetrics.toolbarHeight + 18)
    }

    func testQuinticFalloffEndpoints() {
        XCTAssertEqual(ToolbarGlassView.quinticFalloff(0), 1, accuracy: 1e-12)
        XCTAssertEqual(ToolbarGlassView.quinticFalloff(1), 0, accuracy: 1e-12)
    }

    func testQuinticFalloffMidpointIsHalf() {
        XCTAssertEqual(ToolbarGlassView.quinticFalloff(0.5), 0.5, accuracy: 1e-12)
    }

    func testQuinticFalloffClampsOutOfRangeInputs() {
        XCTAssertEqual(ToolbarGlassView.quinticFalloff(-3), 1, accuracy: 1e-12)
        XCTAssertEqual(ToolbarGlassView.quinticFalloff(2.5), 0, accuracy: 1e-12)
    }

    func testQuinticFalloffIsPointSymmetricAroundHalf() {
        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(ToolbarGlassView.quinticFalloff(u) + ToolbarGlassView.quinticFalloff(1 - u),
                           1, accuracy: 1e-12)
        }
    }

    func testQuinticFalloffIsMonotonicDecreasing() {
        var previous = ToolbarGlassView.quinticFalloff(0)
        for u in stride(from: 0.01, through: 1.0, by: 0.01) {
            let v = ToolbarGlassView.quinticFalloff(u)
            XCTAssertLessThanOrEqual(v, previous + 1e-12)
            previous = v
        }
    }

    func testQuinticFalloffHasFlatShoulders() {
        // C2 smoothstep: the first derivative is ~0 near both endpoints.
        XCTAssertGreaterThan(ToolbarGlassView.quinticFalloff(0.001), 0.9999999)
        XCTAssertLessThan(ToolbarGlassView.quinticFalloff(0.999), 0.0000001 + 1e-9 + 1e-6)
    }

    // MARK: Glass profile and blur mask

    func testProfileIsSolidThroughToolbarAndFadesToZero() {
        let h = Double(ToolbarGlassView.totalHeight)
        let toolbar = Double(SafariMetrics.toolbarHeight)
        for y in stride(from: 0.0, through: toolbar, by: 4) {
            XCTAssertEqual(ToolbarGlassView.profile(atY: y, viewHeight: h), 1, "y \(y) is inside the toolbar")
        }
        XCTAssertEqual(ToolbarGlassView.profile(atY: h, viewHeight: h), 0, accuracy: 1e-12)
        var previous = 1.0
        for y in stride(from: toolbar, through: h, by: 0.5) {
            let v = ToolbarGlassView.profile(atY: y, viewHeight: h)
            XCTAssertLessThanOrEqual(v, previous + 1e-12)
            previous = v
        }
    }

    private func maskBytes(_ image: CGImage) -> [UInt8] {
        [UInt8](image.dataProvider!.data! as Data)
    }

    func testMaskImageMatchesProfile() throws {
        let h = Double(ToolbarGlassView.totalHeight)
        let image = try XCTUnwrap(ToolbarGlassView.makeMaskImage(viewHeight: h, rows: 64))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 64)
        let bytes = maskBytes(image)
        XCTAssertEqual(bytes[0], 255, "top row is full blur")
        XCTAssertEqual(bytes[63 * 4], 0, "bottom row has no blur")
        for row in 0..<64 {
            let i = row * 4
            XCTAssertEqual(bytes[i], bytes[i + 3], "grey equals alpha")
            let expected = UInt8((ToolbarGlassView.profile(atY: Double(row) / 63 * h, viewHeight: h) * 255).rounded())
            XCTAssertEqual(bytes[i], expected, "row \(row)")
        }
    }

    func testGlassViewBuildsAndAppliesColours() {
        let view = ToolbarGlassView(frame: NSRect(x: 0, y: 0, width: 400, height: ToolbarGlassView.totalHeight))
        view.layoutSubtreeIfNeeded()
        view.apply(prefersLightInk: true, sampledColor: .systemRed, animated: false)
        view.apply(prefersLightInk: false, customVeilColor: .white, animated: false)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)), "the glass never takes clicks")
    }
}
