import AppKit
import XCTest
@testable import Safarium

/// Pixel analysis used to classify favicon and touch-icon images: size, squareness, opaque corners,
/// tight edges, dominant colour and monogram suitability. Fixtures are rendered into real CGImages.
final class FaviconPixelAnalysisTests: HermeticTestCase {
    private func solid(_ size: Int, r: CGFloat = 1, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1) -> NSImage {
        FaviconFixtures.solid(size, r: r, g: g, b: b, a: a)
    }

    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, r: CGFloat = 1, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1) -> (CGContext) -> Void {
        { ctx in FaviconFixtures.fill(ctx, rect: CGRect(x: x, y: y, width: w, height: h), r: r, g: g, b: b, a: a) }
    }

    // MARK: - pixelSize and squareness

    func testPixelSizeReadsBackingPixelsNotPoints() {
        let image = FaviconFixtures.image(width: 40, height: 30, pointSize: NSSize(width: 10, height: 10))
        let px = FaviconCache.pixelSize(of: image)
        XCTAssertEqual(px?.width, 40)
        XCTAssertEqual(px?.height, 30)
    }

    func testPixelSizeFallsBackToRoundedPointSizeWithoutBitmap() {
        let px = FaviconCache.pixelSize(of: NSImage(size: NSSize(width: 12.4, height: 7.6)))
        XCTAssertEqual(px?.width, 12)
        XCTAssertEqual(px?.height, 8)
    }

    func testPixelSizeIsNilForEmptyImage() {
        XCTAssertNil(FaviconCache.pixelSize(of: NSImage(size: .zero)))
    }

    func testRoughlySquareAcceptsRatiosInsideInclusiveBounds() {
        XCTAssertTrue(FaviconCache.isRoughlySquare((100, 100)))
        XCTAssertTrue(FaviconCache.isRoughlySquare((78, 100)), "0.78 is the inclusive lower bound")
        XCTAssertTrue(FaviconCache.isRoughlySquare((128, 100)), "1.28 is the inclusive upper bound")
    }

    func testRoughlySquareRejectsRatiosJustOutsideBounds() {
        XCTAssertFalse(FaviconCache.isRoughlySquare((77, 100)))
        XCTAssertFalse(FaviconCache.isRoughlySquare((129, 100)))
        XCTAssertFalse(FaviconCache.isRoughlySquare((200, 80)))
    }

    func testRoughlySquareRejectsZeroDimensions() {
        XCTAssertFalse(FaviconCache.isRoughlySquare((100, 0)))
        XCTAssertFalse(FaviconCache.isRoughlySquare((0, 0)))
    }

    // MARK: - hasOpaqueCorners

    func testOpaqueCornersTrueForSolidSquare() {
        XCTAssertTrue(FaviconCache.hasOpaqueCorners(solid(32)))
    }

    func testOpaqueCornersTrueForBitmapWithoutAlphaChannel() {
        let image = FaviconFixtures.image(width: 32, height: 32, alpha: .noneSkipLast)
        XCTAssertTrue(FaviconCache.hasOpaqueCorners(image))
    }

    func testOpaqueCornersFalseForRoundedBadgeWithTransparentCorners() {
        XCTAssertFalse(FaviconCache.hasOpaqueCorners(FaviconFixtures.image(width: 32, height: 32, draw: rect(4, 4, 24, 24))))
    }

    func testOpaqueCornersFalseForFullyTransparentImage() {
        XCTAssertFalse(FaviconCache.hasOpaqueCorners(FaviconFixtures.image(width: 32, height: 32)))
    }

    func testOpaqueCornerAlphaThresholdSitsNearTwoThirdsOpacity() {
        XCTAssertFalse(FaviconCache.hasOpaqueCorners(solid(32, a: 0.90)), "alpha about 229 is below the 235 bar")
        XCTAssertTrue(FaviconCache.hasOpaqueCorners(solid(32, a: 0.95)), "alpha about 242 clears the 235 bar")
    }

    func testOpaqueCornersRequireAtLeastEightPixelsPerSide() {
        XCTAssertFalse(FaviconCache.hasOpaqueCorners(solid(7)))
        XCTAssertTrue(FaviconCache.hasOpaqueCorners(solid(8)))
    }

    func testOpaqueCornersFalseWithoutBitmapRepresentation() {
        XCTAssertFalse(FaviconCache.hasOpaqueCorners(NSImage(size: NSSize(width: 32, height: 32))))
    }

    // MARK: - hasTightOpaqueEdges

    func testTightEdgesFalseForBlankImage() {
        XCTAssertFalse(FaviconCache.hasTightOpaqueEdges(FaviconFixtures.image(width: 32, height: 32)))
    }

    func testTightEdgesFalseForFullyFilledBadge() {
        XCTAssertFalse(FaviconCache.hasTightOpaqueEdges(solid(32)), "fill fraction >= 0.65 means a pre-rounded badge")
    }

    func testTightEdgesTrueWhenInkTouchesAnEdge() {
        XCTAssertTrue(FaviconCache.hasTightOpaqueEdges(FaviconFixtures.image(width: 32, height: 32, draw: rect(0, 12, 8, 8))))
    }

    func testTightEdgesFalseForCenteredMark() {
        XCTAssertFalse(FaviconCache.hasTightOpaqueEdges(FaviconFixtures.image(width: 32, height: 32, draw: rect(13, 13, 6, 6))))
    }

    func testTightEdgeMarginBoundaryIsTwoPixels() {
        XCTAssertTrue(FaviconCache.hasTightOpaqueEdges(FaviconFixtures.image(width: 32, height: 32, draw: rect(2, 14, 28, 4))), "margin 2 counts as tight")
        XCTAssertFalse(FaviconCache.hasTightOpaqueEdges(FaviconFixtures.image(width: 32, height: 32, draw: rect(3, 14, 26, 4))), "margin 3 does not")
    }

    func testTightEdgesIgnoreNearWhiteInk() {
        XCTAssertFalse(FaviconCache.hasTightOpaqueEdges(FaviconFixtures.image(width: 32, height: 32, draw: rect(0, 0, 32, 32, r: 1, g: 1, b: 1))))
    }

    func testTightEdgesIgnoreFaintInk() {
        XCTAssertFalse(FaviconCache.hasTightOpaqueEdges(FaviconFixtures.image(width: 32, height: 32, draw: rect(0, 12, 8, 8, a: 0.1))))
    }

    // MARK: - extractDominantVibrantColor

    func testDominantColorOfSolidRedAndGreen() {
        PersistenceTestSupport.assertSRGB(FaviconCache.extractDominantVibrantColor(from: solid(24)), 1, 0, 0, accuracy: 0.01)
        PersistenceTestSupport.assertSRGB(FaviconCache.extractDominantVibrantColor(from: solid(24, r: 0, g: 1, b: 0)), 0, 1, 0, accuracy: 0.01)
    }

    func testDominantColorRejectsGreysBlackAndWhite() {
        XCTAssertNil(FaviconCache.extractDominantVibrantColor(from: solid(24, r: 0.5, g: 0.5, b: 0.5)))
        XCTAssertNil(FaviconCache.extractDominantVibrantColor(from: solid(24, r: 1, g: 1, b: 1)))
        XCTAssertNil(FaviconCache.extractDominantVibrantColor(from: solid(24, r: 0, g: 0, b: 0)))
    }

    func testDominantColorIgnoresPixelsBelowFortyFivePercentAlpha() {
        XCTAssertNil(FaviconCache.extractDominantVibrantColor(from: solid(24, a: 0.4)))
        XCTAssertNil(FaviconCache.extractDominantVibrantColor(from: FaviconFixtures.image(width: 24, height: 24)))
        PersistenceTestSupport.assertSRGB(FaviconCache.extractDominantVibrantColor(from: solid(24, a: 0.5)), 1, 0, 0, accuracy: 0.02)
    }

    func testDominantColorPicksTheHeaviestHueBucket() {
        let image = FaviconFixtures.image(width: 24, height: 24) { ctx in
            FaviconFixtures.fill(ctx, rect: CGRect(x: 0, y: 0, width: 16, height: 24), r: 1, g: 0, b: 0)
            FaviconFixtures.fill(ctx, rect: CGRect(x: 16, y: 0, width: 8, height: 24), r: 0, g: 1, b: 0)
        }
        PersistenceTestSupport.assertSRGB(FaviconCache.extractDominantVibrantColor(from: image), 1, 0, 0, accuracy: 0.01)
    }

    func testDominantColorNeedsWeightOfAtLeastFourSaturatedPixels() {
        PersistenceTestSupport.assertSRGB(
            FaviconCache.extractDominantVibrantColor(from: FaviconFixtures.image(width: 24, height: 24, draw: rect(0, 0, 2, 2))),
            1, 0, 0, accuracy: 0.01)
        XCTAssertNil(FaviconCache.extractDominantVibrantColor(from: FaviconFixtures.image(width: 24, height: 24, draw: rect(0, 0, 2, 1))))
    }

    func testDominantColorClampsOverlyLightColorsToSixtyFourPercentLuma() throws {
        let color = try XCTUnwrap(FaviconCache.extractDominantVibrantColor(from: solid(24, r: 1.0, g: 0.7, b: 0.6)).flatMap { $0.usingColorSpace(.sRGB) })
        let luma = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
        XCTAssertEqual(luma, 0.64, accuracy: 0.01)
    }

    func testDominantColorLeavesModeratePastelsUnscaled() {
        PersistenceTestSupport.assertSRGB(FaviconCache.extractDominantVibrantColor(from: solid(24, r: 0.8, g: 0.5, b: 0.5)), 0.8, 0.5, 0.5, accuracy: 0.01)
    }

    func testDominantColorKeepsMidBlue() {
        PersistenceTestSupport.assertSRGB(FaviconCache.extractDominantVibrantColor(from: solid(24, r: 0.2, g: 0.3, b: 0.9)), 0.2, 0.3, 0.9, accuracy: 0.01)
    }

    func testDominantColorOfPureBlueIsDiscardedByLumaGate() {
        XCTAssertNotNil(FaviconCache.extractDominantVibrantColor(from: self.solid(24, r: 0, g: 0, b: 1)))
    
    }

    func testDominantColorIsNilWithoutBitmapRepresentation() {
        XCTAssertNil(FaviconCache.extractDominantVibrantColor(from: NSImage(size: NSSize(width: 24, height: 24))))
    }

    // MARK: - isSuitableMonogramColor

    func testMonogramSuitabilityAcceptsSaturatedMidtones() {
        XCTAssertTrue(FaviconCache.isSuitableMonogramColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        XCTAssertTrue(FaviconCache.isSuitableMonogramColor(NSColor(srgbRed: 0.2, green: 0.3, blue: 0.9, alpha: 1)))
    }

    func testMonogramSuitabilityRejectsGreysPalesDarksAndDesaturatedColors() {
        XCTAssertFalse(FaviconCache.isSuitableMonogramColor(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)), "grey has no saturation")
        XCTAssertFalse(FaviconCache.isSuitableMonogramColor(NSColor(srgbRed: 0.9, green: 0.85, blue: 0.85, alpha: 1)), "too light")
        XCTAssertFalse(FaviconCache.isSuitableMonogramColor(NSColor(srgbRed: 0.05, green: 0.05, blue: 0.4, alpha: 1)), "too dark")
        XCTAssertFalse(FaviconCache.isSuitableMonogramColor(NSColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1)), "saturation under 0.20")
    }
}
