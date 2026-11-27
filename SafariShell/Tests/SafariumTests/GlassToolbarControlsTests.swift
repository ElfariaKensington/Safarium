import XCTest
import AppKit
@testable import Safarium

/// Unit tests for `GlassToolbarControls.swift`: `ActionSpec` defaults, the capsule's required-width model,
/// native button ordering, hidden and placeholder slots, merged extension slots inside a native group, and the
/// hosted insertion / hit-testing geometry. Capsules are hosted in offscreen borderless windows only.
@MainActor
final class GlassToolbarControlsTests: HermeticTestCase {
    private var hosts: [NSWindow] = []

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            hosts.forEach { $0.close() }
            hosts.removeAll()
        }
        super.tearDown()
    }

    private func spec(_ id: String, width: CGFloat, onClick: @escaping () -> Void = {}) -> GlassActionCapsule.ActionSpec {
        GlassActionCapsule.ActionSpec(id: id, symbolName: "circle", tooltip: id, width: width, onClick: onClick)
    }

    /// Places the capsule at the origin of an offscreen window and lays it out.
    private func host(_ capsule: GlassActionCapsule, width: CGFloat) {
        let size = NSSize(width: max(width, 400), height: 80)
        let window = uiHostWindow(size: size)
        hosts.append(window)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        root.addSubview(capsule)
        capsule.frame = NSRect(x: 0, y: 0, width: width, height: SafariMetrics.glassButtonSize)
        capsule.layoutSubtreeIfNeeded()
    }

    private func stack(of capsule: GlassActionCapsule) -> NSStackView {
        uiPrivate(capsule, "stackView", as: NSStackView.self)!
    }

    // MARK: - ActionSpec

    func testActionSpecDefaultsAreRegularWeightSixteenPointFiveGlyph() {
        let s = GlassActionCapsule.ActionSpec(id: "x", tooltip: "X", width: 30, onClick: {})
        XCTAssertEqual(s.symbolName, "")
        XCTAssertNil(s.title)
        XCTAssertEqual(s.pointSize, 16.5)
        XCTAssertEqual(s.weight, .regular)
        XCTAssertEqual(s.width, 30)
        XCTAssertEqual(s.tooltip, "X")
    }

    func testActionSpecStoresTitleAndCustomStyling() {
        let s = GlassActionCapsule.ActionSpec(id: "t", title: "Back", tooltip: "Go back", width: 60, pointSize: 13, weight: .semibold, onClick: {})
        XCTAssertEqual(s.title, "Back")
        XCTAssertEqual(s.pointSize, 13)
        XCTAssertEqual(s.weight, .semibold)
    }

    func testActionSpecOnClickIsTheStoredClosure() {
        var fired = 0
        let s = spec("a", width: 30) { fired += 1 }
        s.onClick()
        s.onClick()
        XCTAssertEqual(fired, 2)
    }

    // MARK: - Width model

    func testInitialFrameWidthIsPaddingOnBothSidesPlusSpecWidths() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 75)], horizontalPadding: 3)
        XCTAssertEqual(capsule.frame.width, 3 * 2 + 38 + 75)
        XCTAssertEqual(capsule.frame.height, SafariMetrics.glassButtonSize)
    }

    func testExtensionSlotWidthDependsOnPadding() {
        let padded = GlassActionCapsule(specs: [], horizontalPadding: 3)
        let flush = GlassActionCapsule(specs: [], horizontalPadding: 0)
        XCTAssertEqual(padded.extensionSlotWidth, 32)
        XCTAssertEqual(flush.extensionSlotWidth, 34)
    }

    func testCurrentRequiredWidthSumsVisibleSpecsWithPadding() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 75)], horizontalPadding: 3)
        XCTAssertEqual(capsule.currentRequiredWidth, 6 + 113)
    }

    func testCurrentRequiredWidthHasMinimumOfButtonSize() {
        let capsule = GlassActionCapsule(specs: [spec("tiny", width: 10)], horizontalPadding: 3)
        XCTAssertEqual(capsule.currentRequiredWidth, SafariMetrics.glassButtonSize)
    }

    func testCurrentRequiredWidthIsZeroWithoutAnyContent() {
        XCTAssertEqual(GlassActionCapsule(specs: [], horizontalPadding: 3).currentRequiredWidth, 0)
        XCTAssertFalse(GlassActionCapsule(specs: [], horizontalPadding: 3).hasPlaceholder)
        XCTAssertFalse(GlassActionCapsule(specs: [], horizontalPadding: 3).hasMergedExtensions)
    }

    func testHidingNativeButtonRemovesItsWidthAndRestoresIt() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 75)], horizontalPadding: 3)
        capsule.setHidden(true, for: "b", animated: false)
        XCTAssertEqual(capsule.currentRequiredWidth, 6 + 38)
        XCTAssertEqual(capsule.visibleNativeIDsInOrder(), ["a"])
        XCTAssertTrue(capsule.button(for: "b")?.isHidden == true)

        capsule.setHidden(true, for: "b", animated: false)
        XCTAssertEqual(capsule.currentRequiredWidth, 6 + 38, "hiding twice must not change the width again")

        capsule.setHidden(false, for: "b", animated: false)
        XCTAssertEqual(capsule.currentRequiredWidth, 6 + 113)
        XCTAssertEqual(capsule.visibleNativeIDsInOrder(), ["a", "b"])
    }

    // MARK: - Buttons, ordering and tokens

    func testButtonLookupKnowsOnlyDeclaredIDs() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 30), spec("b", width: 30)])
        XCTAssertNotNil(capsule.button(for: "a"))
        XCTAssertEqual(capsule.button(for: "b")?.identifier?.rawValue, "b")
        XCTAssertNil(capsule.button(for: "missing"))
    }

    func testOrderedSlotTokensStartInDeclaredOrder() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 30), spec("b", width: 30), spec("c", width: 30)])
        XCTAssertEqual(capsule.orderedSlotTokens(), ["native:a", "native:b", "native:c"])
    }

    func testApplyNativeButtonOrderReordersAndAppendsMissingIDs() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 30), spec("b", width: 30), spec("c", width: 30)])
        host(capsule, width: 120)
        capsule.applyNativeButtonOrder(["c", "a", "b"])
        XCTAssertEqual(capsule.visibleNativeIDsInOrder(), ["c", "a", "b"])
        XCTAssertEqual(capsule.orderedSlotTokens(), ["native:c", "native:a", "native:b"])
    }

    func testApplyNativeButtonOrderIgnoresDuplicatesAndUnknownIDs() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 30), spec("b", width: 30), spec("c", width: 30)])
        host(capsule, width: 120)
        capsule.applyNativeButtonOrder(["b", "b", "zzz", "a"])
        XCTAssertEqual(capsule.visibleNativeIDsInOrder(), ["b", "a", "c"])
    }

    func testApplyNativeButtonOrderWithEmptyListKeepsDeclaredOrder() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 30), spec("b", width: 30)])
        host(capsule, width: 80)
        capsule.applyNativeButtonOrder([])
        XCTAssertEqual(capsule.visibleNativeIDsInOrder(), ["a", "b"])
    }

    func testDisabledButtonDoesNotFireItsAction() throws {
        var fired = 0
        let capsule = GlassActionCapsule(specs: [spec("a", width: 30) { fired += 1 }])
        let btn = try XCTUnwrap(capsule.button(for: "a"))
        capsule.setEnabled(false, for: "a")
        XCTAssertFalse(btn.isEnabled)
        btn.sendAction(btn.action, to: btn.target)
        XCTAssertEqual(fired, 0)

        capsule.setEnabled(true, for: "a")
        btn.sendAction(btn.action, to: btn.target)
        XCTAssertEqual(fired, 1)
    }

    func testCustomizeWiggleAddsAndRemovesAnimationOnNativeButtons() throws {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 30), spec("b", width: 30)])
        host(capsule, width: 80)
        capsule.setCustomizeWiggle(true)
        let layer = try XCTUnwrap(capsule.button(for: "a")?.layer)
        XCTAssertNotNil(layer.animation(forKey: "sxCustomizeWiggleX"))
        capsule.setCustomizeWiggle(false)
        XCTAssertNil(layer.animation(forKey: "sxCustomizeWiggleX"))
    }

    // MARK: - Insertion and hit geometry (hosted)

    func testNativeInsertionIndexCountsButtonsLeftOfCursorAndHonoursExclusion() throws {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 38), spec("c", width: 38)])
        host(capsule, width: 150)
        let b = try XCTUnwrap(capsule.button(for: "b"))
        let pointRightOfB = b.superview!.convert(NSPoint(x: b.frame.midX + 1, y: b.frame.midY), to: nil)
        XCTAssertEqual(capsule.nativeInsertionIndex(forWindowPoint: pointRightOfB), 2)
        XCTAssertEqual(capsule.nativeInsertionIndex(forWindowPoint: pointRightOfB, excludingID: "b"), 1,
                       "the dragged button must not count itself")
    }

    func testInsertionVisibleIndexWithoutCurrentIndexFollowsMidpoints() throws {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 38), spec("c", width: 38)])
        host(capsule, width: 150)
        let s = stack(of: capsule)
        let a = try XCTUnwrap(capsule.button(for: "a")), c = try XCTUnwrap(capsule.button(for: "c"))
        func winPoint(x: CGFloat) -> NSPoint { s.convert(NSPoint(x: x, y: s.bounds.midY), to: nil) }
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: winPoint(x: a.frame.midX - 5), currentVisibleIndex: nil), 0)
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: winPoint(x: a.frame.midX + 5), currentVisibleIndex: nil), 1)
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: winPoint(x: c.frame.midX + 5), currentVisibleIndex: nil), 3)
    }

    func testInsertionVisibleIndexOnEmptyCapsuleIsZero() {
        let capsule = GlassActionCapsule(specs: [])
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: .zero, currentVisibleIndex: nil), 0)
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: .zero, currentVisibleIndex: 0), 0)
    }

    func testInsertionVisibleIndexWithCurrentGapHasHysteresis() throws {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 38), spec("c", width: 38)])
        host(capsule, width: 150)
        let s = stack(of: capsule)
        let a = try XCTUnwrap(capsule.button(for: "a")), b = try XCTUnwrap(capsule.button(for: "b"))
        let c = try XCTUnwrap(capsule.button(for: "c"))
        func winPoint(x: CGFloat) -> NSPoint { s.convert(NSPoint(x: x, y: s.bounds.midY), to: nil) }

        // Gap open at visible index 1 (between a and b).
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: winPoint(x: b.frame.midX), currentVisibleIndex: 1), 1)
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: winPoint(x: a.frame.midX - 10), currentVisibleIndex: 1), 0)
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: winPoint(x: b.frame.midX + 10), currentVisibleIndex: 1), 2)
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: winPoint(x: c.frame.midX + 10), currentVisibleIndex: 1), 3)
    }

    func testInsertionVisibleIndexAtEndGapIsClampedBySliderLogic() {
        // currentVisibleIndex == count is the last valid gap; a far-left cursor returns the gap before it.
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38)])
        host(capsule, width: 80)
        XCTAssertEqual(capsule.insertionVisibleIndex(forWindowPoint: .zero, currentVisibleIndex: 1), 0)
    }

    func testPlaceholderSlotAddsExtensionWidthAndIsSkippedInTokens() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 75)], horizontalPadding: 3)
        host(capsule, width: 119)
        capsule.setPlaceholderVisibleIndex(1, animated: false)
        XCTAssertTrue(capsule.hasPlaceholder)
        XCTAssertEqual(capsule.currentRequiredWidth, 119 + 32)
        XCTAssertEqual(capsule.orderedSlotTokens(), ["native:a", "native:b"], "placeholder is not a slot token")
        XCTAssertEqual(capsule.visibleNativeIDsInOrder(), ["a", "b"])

        capsule.setPlaceholderVisibleIndex(nil, animated: false)
        XCTAssertFalse(capsule.hasPlaceholder)
        XCTAssertEqual(capsule.currentRequiredWidth, 119)
    }

    func testHitNativeButtonReturnsIDAndVisibleIndexForPointsInsideButton() throws {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 38)])
        host(capsule, width: 90)
        let b = try XCTUnwrap(capsule.button(for: "b"))
        let inside = b.superview!.convert(NSPoint(x: b.frame.midX, y: b.frame.midY), to: nil)
        let hit = capsule.hitNativeButton(atWindowPoint: inside)
        XCTAssertEqual(hit?.id, "b")
        XCTAssertEqual(hit?.visibleIndex, 1)
        XCTAssertNil(capsule.hitNativeButton(atWindowPoint: NSPoint(x: 5000, y: 5000)))
    }

    // MARK: - Merged extension slots

    private func extButton(_ id: String) -> ExtensionToolbarIconButton {
        ExtensionToolbarIconButton(item: uiExtension(id), isDark: false)
    }

    func testSetMergedExtensionsFollowsTokenOrderAndAppendsMissingSlots() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 75), spec("c", width: 38)])
        host(capsule, width: 300)
        capsule.setMergedExtensions([extButton("x"), extButton("y")], tokenOrder: ["native:b", "ext:x", "native:a"])
        XCTAssertEqual(capsule.orderedSlotTokens(), ["native:b", "ext:x", "native:a", "native:c", "ext:y"])
        XCTAssertTrue(capsule.hasMergedExtensions)
        XCTAssertNotNil(capsule.anchorExtensionButton(forExtensionID: "y"))
        let expectedWidth: CGFloat = 6 + 38 + 75 + 38 + 64
        XCTAssertEqual(capsule.currentRequiredWidth, expectedWidth)
    }

    func testDuplicateTokensAreIgnoredWhenPlacingMergedSlots() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 38), spec("c", width: 38)])
        host(capsule, width: 200)
        capsule.setMergedExtensions([extButton("x")], tokenOrder: ["native:a", "native:a", "ext:x", "ext:x"])
        XCTAssertEqual(capsule.orderedSlotTokens(), ["native:a", "ext:x", "native:b", "native:c"])
    }

    func testDetachMergedExtensionReturnsVisibleIndexAndRemovesSlot() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 38)])
        host(capsule, width: 200)
        capsule.setMergedExtensions([extButton("x")], tokenOrder: ["native:a", "ext:x", "native:b"])
        let btn = capsule.anchorExtensionButton(forExtensionID: "x") as! ExtensionToolbarIconButton
        XCTAssertEqual(capsule.detachMergedExtensionButton(btn), 1)
        XCTAssertFalse(capsule.hasMergedExtensions)
        XCTAssertEqual(capsule.orderedSlotTokens(), ["native:a", "native:b"])
    }

    func testInsertMergedExtensionAtVisibleIndexZeroLeadsTheCapsule() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38)])
        host(capsule, width: 120)
        capsule.insertMergedExtensionButton(extButton("x"), atVisibleIndex: 0)
        XCTAssertEqual(capsule.orderedSlotTokens(), ["ext:x", "native:a"])
        XCTAssertTrue(capsule.hasMergedExtensions)
    }

    func testMergedExtensionHitTestingAndRectMapping() throws {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38)])
        host(capsule, width: 150)
        capsule.insertMergedExtensionButton(extButton("x"), atVisibleIndex: 0)
        capsule.layoutSubtreeIfNeeded()
        let btn = try XCTUnwrap(capsule.anchorExtensionButton(forExtensionID: "x"))
        let center = btn.convert(NSPoint(x: btn.bounds.midX, y: btn.bounds.midY), to: nil)
        XCTAssertTrue(capsule.containsMergedExtension(atWindowPoint: center))
        XCTAssertEqual(capsule.hitMergedExtensionButton(atWindowPoint: center)?.visibleIndex, 0)

        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let rect = try XCTUnwrap(capsule.mergedExtensionRect(forExtensionID: "x", in: overlay))
        XCTAssertEqual(rect.size, btn.bounds.size)
        XCTAssertNil(capsule.mergedExtensionRect(forExtensionID: "nope", in: overlay))
        XCTAssertFalse(capsule.containsMergedExtension(atWindowPoint: NSPoint(x: 9000, y: 9000)))
    }

    func testPlaceholderAndMergedExtensionCoexistWithoutLosingNativeOrder() {
        let capsule = GlassActionCapsule(specs: [spec("a", width: 38), spec("b", width: 38)])
        host(capsule, width: 200)
        capsule.setMergedExtensions([extButton("x")], tokenOrder: ["native:b", "ext:x", "native:a"])
        capsule.setPlaceholderVisibleIndex(0, animated: false)
        XCTAssertEqual(capsule.visibleNativeIDsInOrder(), ["b", "a"])
        XCTAssertEqual(capsule.orderedSlotTokens(), ["native:b", "ext:x", "native:a"])
        XCTAssertEqual(capsule.currentRequiredWidth, 6 + 76 + 32 + 32)
    }

    // MARK: - Cluster container

    func testClusterViewAcceptsArrangedViews() {
        let cluster = GlassToolbarClusterView(spacing: 0, mergeSpacing: 0)
        let child = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        cluster.addArrangedView(child)
        XCTAssertFalse(cluster.translatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(cluster.subviews.count >= 1)
        XCTAssertTrue(uiDescendants(of: cluster, as: NSView.self).contains { $0 === child })
    }
}
