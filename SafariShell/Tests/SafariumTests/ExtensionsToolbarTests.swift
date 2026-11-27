import XCTest
import AppKit
@testable import Safarium

/// Unit tests for `ExtensionsToolbarView.swift`: zone partitions, the coordinator's persisted layout
/// (v3 / v2 / legacy resolution, sanitising, hidden IDs, round trips), placement from the customize sheet,
/// drag target-zone geometry with hysteresis, capsule slot math (insertion, hit-testing, placeholders),
/// bubble geometry, and popup-size persistence.
@MainActor
final class ExtensionsToolbarTests: HermeticTestCase {
    private typealias Layout = ExtensionsToolbarCoordinator.PersistedToolbarLayout
    private var savedDefaults: [String: Any] = [:]

    private static let v3Key = "Safarium.ExtensionToolbarLayout.v3"
    private static let v2Key = "Safarium.ExtensionToolbarLayout.v2"
    private static let legacyKey = "Safarium.ExtensionToolbarOrder"

    private final class Counter { var count = 0; var lastFlag: Bool?; var lastID: String? }

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            savedDefaults = UIDefaultsSandbox.snapshot()
            UIDefaultsSandbox.clear()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            UIDefaultsSandbox.restore(savedDefaults)
        }
        super.tearDown()
    }

    private func storeLayout(_ layout: Layout) {
        let data = try! JSONEncoder().encode(layout)
        UserDefaults.standard.set(data, forKey: Self.v3Key)
    }

    private func storedLayout() -> Layout? {
        guard let data = UserDefaults.standard.data(forKey: Self.v3Key) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: data)
    }

    private func ids(_ capsule: ExtensionsToolbarCapsuleView) -> [String] {
        capsule.extensions.map(\.id)
    }

    private func landmarks(sidebarHidden: Bool = false, backForwardHidden: Bool = false) -> ToolbarExtensionLandmarks {
        let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 38))
        let backForward = NSView(frame: NSRect(x: 70, y: 0, width: 70, height: 38))
        let address = NSView(frame: NSRect(x: 150, y: 0, width: 400, height: 38))
        let rightActions = NSView(frame: NSRect(x: 560, y: 0, width: 150, height: 38))
        sidebar.isHidden = sidebarHidden
        backForward.isHidden = backForwardHidden
        return ToolbarExtensionLandmarks(
            toolbarView: toolbar,
            overlayHostView: NSView(frame: toolbar.frame),
            sidebarView: sidebar,
            backForwardView: backForward,
            addressBarView: address,
            rightActionsView: rightActions
        )
    }

    // MARK: - Zones

    func testZonePartitionCoversEveryZoneExactlyOnce() {
        let standalone = ExtensionToolbarZone.standaloneZones
        let merged = ExtensionToolbarZone.mergedGroupZones
        XCTAssertEqual(standalone.count + merged.count, ExtensionToolbarZone.allCases.count)
        XCTAssertEqual(Set(standalone + merged), Set(ExtensionToolbarZone.allCases))
        XCTAssertTrue(Set(standalone).isDisjoint(with: Set(merged)))
    }

    func testIsMergedGroupAgreesWithTheMergedZoneList() {
        for zone in ExtensionToolbarZone.allCases {
            XCTAssertEqual(zone.isMergedGroup, ExtensionToolbarZone.mergedGroupZones.contains(zone), "\(zone)")
        }
        XCTAssertEqual(Set(ExtensionToolbarZone.mergedGroupZones), [.inSidebarGroup, .inBackForwardGroup, .inRightActionsGroup])
    }

    func testZoneRawValuesRoundTripCodable() throws {
        for zone in ExtensionToolbarZone.allCases {
            let data = try JSONEncoder().encode(zone)
            XCTAssertEqual(try JSONDecoder().decode(ExtensionToolbarZone.self, from: data), zone)
        }
        XCTAssertNil(ExtensionToolbarZone(rawValue: "nowhere"))
    }

    // MARK: - Coordinator: capsules and zone lookup

    func testCapsuleForStandaloneZoneReturnsMatchingCapsule() {
        let coordinator = ExtensionsToolbarCoordinator()
        for zone in ExtensionToolbarZone.standaloneZones {
            XCTAssertEqual(coordinator.capsule(for: zone).zone, zone)
        }
        XCTAssertEqual(coordinator.allCapsules.count, ExtensionToolbarZone.standaloneZones.count)
    }

    /// Regression lock for P09-5: merged zones have no standalone capsule and must not trap.
    func testCapsuleForMergedZoneFallsBackToLeftOfAddressBarInsteadOfCrashing() {
        let coordinator = ExtensionsToolbarCoordinator()
        for zone in ExtensionToolbarZone.mergedGroupZones {
            XCTAssertEqual(coordinator.capsule(for: zone).zone, .leftOfAddressBar, "\(zone)")
        }
    }

    func testRequiredWidthIsZeroForEmptyZoneAndCountsSlotsOtherwise() {
        let coordinator = ExtensionsToolbarCoordinator()
        XCTAssertEqual(coordinator.requiredWidth(for: .leftOfAddressBar), 0)
        XCTAssertEqual(coordinator.requiredWidth(for: .inSidebarGroup), 0, "unregistered merged zone has no width")
        coordinator.update(extensions: [uiExtension("a"), uiExtension("b")])
        XCTAssertEqual(coordinator.requiredWidth(for: .leftOfAddressBar), 2 * 4 + 2 * 32)
    }

    func testFirstVisibleCapsuleIsNilWhenEmptyAndLeftCapsuleWhenPopulated() {
        let coordinator = ExtensionsToolbarCoordinator()
        XCTAssertNil(coordinator.firstVisibleCapsule())
        coordinator.update(extensions: [uiExtension("a")])
        XCTAssertTrue(coordinator.firstVisibleCapsule() === coordinator.capsule(for: .leftOfAddressBar))
    }

    func testAnchorButtonFindsPlacedExtensionAndRejectsUnknownIDs() {
        let coordinator = ExtensionsToolbarCoordinator()
        coordinator.update(extensions: [uiExtension("a")])
        XCTAssertNotNil(coordinator.anchorButton(forExtensionID: "a"))
        XCTAssertNil(coordinator.anchorButton(forExtensionID: "missing"))
    }

    func testDragSessionIsInactiveByDefault() {
        XCTAssertFalse(ExtensionsToolbarCoordinator().isDragSessionActive)
    }

    // MARK: - Coordinator: default placement, hidden IDs, reset

    func testDefaultLayoutPlacesEnabledExtensionsInListOrderLeftOfAddressBar() {
        let coordinator = ExtensionsToolbarCoordinator()
        coordinator.update(extensions: [uiExtension("a"), uiExtension("b"), uiExtension("c", enabled: false)])
        XCTAssertEqual(ids(coordinator.capsule(for: .leftOfAddressBar)), ["a", "b"])
        for zone in ExtensionToolbarZone.standaloneZones where zone != .leftOfAddressBar {
            XCTAssertTrue(coordinator.capsule(for: zone).extensions.isEmpty, "\(zone)")
        }
    }

    func testHidingAnExtensionRemovesItFromToolbarAndPersistsIt() {
        let coordinator = ExtensionsToolbarCoordinator()
        let counter = Counter()
        coordinator.onLayoutNeedsUpdate = { counter.lastFlag = $0; counter.count += 1 }
        coordinator.update(extensions: [uiExtension("a"), uiExtension("b")])

        coordinator.setHiddenFromToolbar(true, forExtensionID: "b")

        XCTAssertTrue(coordinator.isHiddenFromToolbar("b"))
        XCTAssertEqual(ids(coordinator.capsule(for: .leftOfAddressBar)), ["a"])
        XCTAssertEqual(storedLayout()?.hidden, ["b"])
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.lastFlag, true)
    }

    func testUnhidingRestoresExtensionToToolbarAtEndOfItsZone() {
        let coordinator = ExtensionsToolbarCoordinator()
        coordinator.update(extensions: [uiExtension("a"), uiExtension("b")])
        coordinator.setHiddenFromToolbar(true, forExtensionID: "a")
        coordinator.setHiddenFromToolbar(false, forExtensionID: "a")
        XCTAssertFalse(coordinator.isHiddenFromToolbar("a"))
        XCTAssertEqual(storedLayout()?.hidden, [])
        // An unplaced extension is appended to leftOfAddressBar, so it returns after the remaining items.
        XCTAssertEqual(ids(coordinator.capsule(for: .leftOfAddressBar)), ["b", "a"])
    }

    func testResetLayoutToDefaultClearsHiddenAndLegacyKeys() {
        UserDefaults.standard.set(["a"], forKey: Self.legacyKey)
        let coordinator = ExtensionsToolbarCoordinator()
        coordinator.update(extensions: [uiExtension("a"), uiExtension("b")])
        coordinator.setHiddenFromToolbar(true, forExtensionID: "b")

        coordinator.resetLayoutToDefault()

        XCTAssertFalse(coordinator.isHiddenFromToolbar("b"))
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.legacyKey))
        XCTAssertEqual(storedLayout()?.hidden, [])
        XCTAssertEqual(ids(coordinator.capsule(for: .leftOfAddressBar)), ["a", "b"])
    }

    // MARK: - Coordinator: placement from the customize sheet

    func testPlaceExtensionFromSheetWithoutLandmarksInsertsAtFront() {
        let coordinator = ExtensionsToolbarCoordinator()
        let counter = Counter()
        coordinator.onToolbarItemsDidChange = { counter.count += 1 }
        coordinator.update(extensions: [uiExtension("a")])

        coordinator.placeExtensionFromSheet(uiExtension("b"), atWindowPoint: .zero)

        XCTAssertEqual(ids(coordinator.capsule(for: .leftOfAddressBar)), ["b", "a"])
        XCTAssertEqual(counter.count, 1)
    }

    func testPlacingTheSameExtensionTwiceDoesNotDuplicateIt() {
        let coordinator = ExtensionsToolbarCoordinator()
        coordinator.update(extensions: [uiExtension("a")])
        coordinator.placeExtensionFromSheet(uiExtension("a"), atWindowPoint: .zero)
        XCTAssertEqual(ids(coordinator.capsule(for: .leftOfAddressBar)), ["a"])
    }

    func testPlacingFromSheetRevealsPreviouslyHiddenExtension() {
        let coordinator = ExtensionsToolbarCoordinator()
        coordinator.update(extensions: [uiExtension("a")])
        coordinator.setHiddenFromToolbar(true, forExtensionID: "a")
        coordinator.placeExtensionFromSheet(uiExtension("a"), atWindowPoint: .zero)
        XCTAssertFalse(coordinator.isHiddenFromToolbar("a"))
        XCTAssertEqual(ids(coordinator.capsule(for: .leftOfAddressBar)), ["a"])
    }

    func testPlacedOrderSurvivesANewCoordinatorReadingPersistedLayout() {
        let first = ExtensionsToolbarCoordinator()
        first.update(extensions: [uiExtension("a")])
        first.placeExtensionFromSheet(uiExtension("b"), atWindowPoint: .zero)

        let second = ExtensionsToolbarCoordinator()
        second.update(extensions: [uiExtension("a"), uiExtension("b")])
        XCTAssertEqual(ids(second.capsule(for: .leftOfAddressBar)), ["b", "a"])
    }

    func testMergedGroupTokensArePersistedAndRestoredInOrder() {
        let coordinator = ExtensionsToolbarCoordinator()
        let group = GlassActionCapsule(specs: [
            GlassActionCapsule.ActionSpec(id: "sidebar", symbolName: "sidebar.left", tooltip: "Sidebar", width: 38, onClick: {})
        ])
        coordinator.registerMergedGroup(group, for: .inSidebarGroup)
        storeLayout(Layout(
            standalone: [:],
            mergedTokens: ["inSidebarGroup": ["native:sidebar", "ext:a"]],
            hidden: nil
        ))

        coordinator.update(extensions: [uiExtension("a")])

        XCTAssertEqual(group.orderedSlotTokens(), ["native:sidebar", "ext:a"])
        XCTAssertNotNil(coordinator.anchorButton(forExtensionID: "a"))
        XCTAssertTrue(ids(coordinator.capsule(for: .leftOfAddressBar)).isEmpty, "merged placement must not also show in a standalone capsule")

        coordinator.setHiddenFromToolbar(false, forExtensionID: "unused")
        XCTAssertEqual(storedLayout()?.mergedTokens["inSidebarGroup"], ["native:sidebar", "ext:a"])
    }

    // MARK: - Coordinator: persisted layout resolution

    func testResolveWithNothingStoredPutsEverythingLeftOfAddressBar() {
        let coordinator = ExtensionsToolbarCoordinator()
        let resolved = coordinator.resolvePersistedLayout(for: [uiExtension("x"), uiExtension("y")])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["x", "y"])
        XCTAssertEqual(resolved.standalone["trailing"], [])
        XCTAssertEqual(resolved.mergedTokens["inSidebarGroup"], [])
        XCTAssertEqual(resolved.hidden, [])
    }

    func testResolveWithNoExtensionsReturnsEmptyZonesAndNoHiddenIDs() {
        let coordinator = ExtensionsToolbarCoordinator()
        coordinator.setHiddenFromToolbar(true, forExtensionID: "gone")
        let resolved = coordinator.resolvePersistedLayout(for: [])
        XCTAssertTrue(resolved.standalone.values.allSatisfy(\.isEmpty))
        XCTAssertTrue(resolved.mergedTokens.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(resolved.hidden, [])
    }

    func testResolveHonoursStoredStandaloneZones() {
        storeLayout(Layout(standalone: ["trailing": ["b"], "leftOfAddressBar": ["a"]], mergedTokens: [:], hidden: nil))
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a"), uiExtension("b")])
        XCTAssertEqual(resolved.standalone["trailing"], ["b"])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["a"])
    }

    func testResolveDropsUnknownAndDuplicateIDs() {
        storeLayout(Layout(standalone: ["leftOfAddressBar": ["a", "a", "ghost"], "trailing": ["a"]], mergedTokens: [:], hidden: nil))
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a")])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["a"], "duplicate and unknown IDs must not survive")
        XCTAssertEqual(resolved.standalone["trailing"], [], "an ID already placed is not placed twice")
    }

    func testResolveNeverPlacesHiddenIDsButKeepsThemInHiddenList() {
        storeLayout(Layout(standalone: ["leftOfAddressBar": ["a", "b"]], mergedTokens: [:], hidden: ["a"]))
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a"), uiExtension("b")])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["b"])
        XCTAssertEqual(resolved.hidden, ["a"])
    }

    func testResolveSanitisesMergedTokens() {
        storeLayout(Layout(
            standalone: [:],
            mergedTokens: ["inSidebarGroup": ["native:sidebar", "ext:zz", "ext:a", "bogus", "ext:a"]],
            hidden: nil
        ))
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a")])
        XCTAssertEqual(resolved.mergedTokens["inSidebarGroup"], ["native:sidebar", "ext:a"])
        XCTAssertEqual(resolved.mergedTokens["inBackForwardGroup"], [])
    }

    func testResolveDecodesMissingHiddenKeyAsEmpty() throws {
        let json = #"{"standalone":{"leftOfAddressBar":["a"]},"mergedTokens":{}}"#
        UserDefaults.standard.set(Data(json.utf8), forKey: Self.v3Key)
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a")])
        XCTAssertEqual(resolved.hidden, [])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["a"])
    }

    func testCorruptV3DataFallsThroughToDefaults() {
        UserDefaults.standard.set(Data("not json at all".utf8), forKey: Self.v3Key)
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a")])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["a"])
    }

    func testUnknownStandaloneZoneKeysAreIgnored() {
        storeLayout(Layout(standalone: ["nowhere": ["a"]], mergedTokens: [:], hidden: nil))
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a")])
        XCTAssertNil(resolved.standalone["nowhere"])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["a"], "an unplaced extension falls back to leftOfAddressBar")
    }

    func testV2LayoutIsMigratedWhenV3IsAbsent() {
        UserDefaults.standard.removeObject(forKey: Self.v3Key)
        UserDefaults.standard.set(try! JSONEncoder().encode(["trailing": ["b"]]), forKey: Self.v2Key)
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a"), uiExtension("b")])
        XCTAssertEqual(resolved.standalone["trailing"], ["b"])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["a"])
    }

    func testLegacyOrderIsMigratedWhenNoNewerLayoutExists() {
        UserDefaults.standard.removeObject(forKey: Self.v3Key)
        UserDefaults.standard.removeObject(forKey: Self.v2Key)
        UserDefaults.standard.set(["b", "a"], forKey: Self.legacyKey)
        let resolved = ExtensionsToolbarCoordinator().resolvePersistedLayout(for: [uiExtension("a"), uiExtension("b")])
        XCTAssertEqual(resolved.standalone["leftOfAddressBar"], ["b", "a"])
    }

    // MARK: - Drag geometry

    func testIsPointOutsideToolbarUsesExactly28PointMargin() {
        let coordinator = ExtensionsToolbarCoordinator()
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 38)
        XCTAssertFalse(coordinator.isPointOutsideToolbar(NSPoint(x: 50, y: 66), toolbarBounds: bounds), "exactly 28 pt above is still inside")
        XCTAssertTrue(coordinator.isPointOutsideToolbar(NSPoint(x: 50, y: 66.5), toolbarBounds: bounds))
        XCTAssertFalse(coordinator.isPointOutsideToolbar(NSPoint(x: 50, y: -28), toolbarBounds: bounds))
        XCTAssertTrue(coordinator.isPointOutsideToolbar(NSPoint(x: 50, y: -28.5), toolbarBounds: bounds))
        XCTAssertFalse(coordinator.isPointOutsideToolbar(NSPoint(x: -28, y: 10), toolbarBounds: bounds))
        XCTAssertTrue(coordinator.isPointOutsideToolbar(NSPoint(x: -28.5, y: 10), toolbarBounds: bounds))
        XCTAssertFalse(coordinator.isPointOutsideToolbar(NSPoint(x: 128, y: 10), toolbarBounds: bounds))
        XCTAssertTrue(coordinator.isPointOutsideToolbar(NSPoint(x: 128.5, y: 10), toolbarBounds: bounds))
    }

    func testIsPointOutsideToolbarHandlesZeroSizeBounds() {
        let coordinator = ExtensionsToolbarCoordinator()
        let zero = NSRect.zero
        XCTAssertFalse(coordinator.isPointOutsideToolbar(.zero, toolbarBounds: zero))
        XCTAssertTrue(coordinator.isPointOutsideToolbar(NSPoint(x: 0, y: 40), toolbarBounds: zero))
    }

    func testResolveTargetZoneSelectsSegmentsFromColdStart() {
        let coordinator = ExtensionsToolbarCoordinator()
        let lm = landmarks()
        func zone(_ x: CGFloat, from current: ExtensionToolbarZone = .leftOfAddressBar) -> ExtensionToolbarZone {
            coordinator.resolveTargetZone(cursorX: x, currentZone: current, landmarks: lm)
        }
        XCTAssertEqual(zone(600), .inRightActionsGroup)
        XCTAssertEqual(zone(30), .inSidebarGroup)
        XCTAssertEqual(zone(68), .afterSidebar)
        XCTAssertEqual(zone(100), .inBackForwardGroup)
        XCTAssertEqual(zone(200), .leftOfAddressBar)
        XCTAssertEqual(zone(400), .rightOfAddressBar)
    }

    func testResolveTargetZoneHysteresisKeepsCurrentMergedGroup() {
        let coordinator = ExtensionsToolbarCoordinator()
        let lm = landmarks()
        // Sidebar ends at x=60. Entering from outside needs x <= 58; leaving the group needs x > 68.
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 63, currentZone: .inSidebarGroup, landmarks: lm), .inSidebarGroup)
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 63, currentZone: .leftOfAddressBar, landmarks: lm), .afterSidebar)
        // Right actions group is entered at minX-2 = 558 but kept until minX-8 = 552.
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 552, currentZone: .inRightActionsGroup, landmarks: lm), .inRightActionsGroup)
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 552, currentZone: .leftOfAddressBar, landmarks: lm), .rightOfAddressBar)
    }

    func testResolveTargetZoneAddressBarMidpointHasSixPointHysteresis() {
        let coordinator = ExtensionsToolbarCoordinator()
        let lm = landmarks()
        // Address bar midpoint is 350.
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 349, currentZone: .leftOfAddressBar, landmarks: lm), .leftOfAddressBar)
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 349, currentZone: .rightOfAddressBar, landmarks: lm), .rightOfAddressBar)
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 345, currentZone: .rightOfAddressBar, landmarks: lm), .rightOfAddressBar)
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 343, currentZone: .rightOfAddressBar, landmarks: lm), .leftOfAddressBar)
    }

    func testHiddenSidebarIsSkippedWhenResolvingZones() {
        let coordinator = ExtensionsToolbarCoordinator()
        let lm = landmarks(sidebarHidden: true)
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 30, currentZone: .leftOfAddressBar, landmarks: lm), .afterSidebar)
    }

    func testHiddenBackForwardIsSkippedWhenResolvingZones() {
        let coordinator = ExtensionsToolbarCoordinator()
        let lm = landmarks(backForwardHidden: true)
        XCTAssertEqual(coordinator.resolveTargetZone(cursorX: 100, currentZone: .leftOfAddressBar, landmarks: lm), .leftOfAddressBar)
    }

    // MARK: - Capsule slot math

    func testSlotFrameUsesFourPointPaddingAndThirtyTwoPointSlots() {
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        XCTAssertEqual(capsule.slotFrame(forIndex: 0), NSRect(x: 4, y: 0, width: 32, height: SafariMetrics.glassButtonSize))
        XCTAssertEqual(capsule.slotFrame(forIndex: 2).minX, 68)
    }

    func testRequiredWidthCountsPlaceholderSlotAndTracksItsRemoval() {
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.update(extensions: [uiExtension("a"), uiExtension("b")])
        XCTAssertEqual(capsule.requiredWidth, 72)
        capsule.setPlaceholderIndex(1, animated: false)
        XCTAssertEqual(capsule.placeholderIndex, 1)
        XCTAssertEqual(capsule.requiredWidth, 104)
        capsule.setPlaceholderIndex(nil, animated: false)
        XCTAssertEqual(capsule.requiredWidth, 72)
    }

    func testPlaceholderIndexIsClampedToSlotCount() {
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.update(extensions: [uiExtension("a")])
        capsule.setPlaceholderIndex(99, animated: false)
        XCTAssertEqual(capsule.placeholderIndex, 1)
        capsule.setPlaceholderIndex(-4, animated: false)
        XCTAssertEqual(capsule.placeholderIndex, 0)
    }

    func testInsertDetachedButtonClampsIndexAndKeepsOrder() {
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.update(extensions: [uiExtension("a"), uiExtension("b")])
        capsule.insertDetachedButton(ExtensionToolbarIconButton(item: uiExtension("c"), isDark: false), at: 99)
        XCTAssertEqual(ids(capsule), ["a", "b", "c"])
        capsule.insertDetachedButton(ExtensionToolbarIconButton(item: uiExtension("z"), isDark: false), at: -7)
        XCTAssertEqual(ids(capsule), ["z", "a", "b", "c"])
        XCTAssertTrue(capsule.anchorButton(forExtensionID: "z") != nil)
    }

    func testDetachButtonReturnsItemAndRejectsOutOfRangeIndices() {
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.update(extensions: [uiExtension("a"), uiExtension("b")])
        let detached = capsule.detachButton(at: 1)
        XCTAssertEqual(detached?.item.id, "b")
        XCTAssertEqual(ids(capsule), ["a"])
        XCTAssertNil(capsule.detachButton(at: 5))
        XCTAssertNil(capsule.detachButton(at: -1))
        XCTAssertEqual(ids(capsule), ["a"])
    }

    func testHitButtonMapsSlotCentersAndPaddingToIndices() {
        let host = uiHostWindow(size: NSSize(width: 300, height: 100))
        defer { host.close() }
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.translatesAutoresizingMaskIntoConstraints = true
        capsule.frame = NSRect(x: 0, y: 0, width: 200, height: SafariMetrics.glassButtonSize)
        host.contentView?.addSubview(capsule)
        capsule.update(extensions: [uiExtension("a"), uiExtension("b"), uiExtension("c")])
        capsule.layoutSubtreeIfNeeded()

        for index in 0..<3 {
            let center = capsule.convert(NSPoint(x: 4 + 32 * CGFloat(index) + 16, y: 18), to: nil)
            XCTAssertEqual(capsule.hitButton(atWindowPoint: center)?.index, index, "slot \(index)")
        }
        let leftPadding = capsule.convert(NSPoint(x: 1, y: 18), to: nil)
        XCTAssertEqual(capsule.hitButton(atWindowPoint: leftPadding)?.index, 0, "left padding maps to the first slot")
        let outside = capsule.convert(NSPoint(x: -5, y: 18), to: nil)
        XCTAssertNil(capsule.hitButton(atWindowPoint: outside))
    }

    func testInsertionIndexWithoutCurrentSlotRoundsToNearestGap() {
        let host = uiHostWindow(size: NSSize(width: 300, height: 100))
        defer { host.close() }
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.frame = NSRect(x: 0, y: 0, width: 200, height: SafariMetrics.glassButtonSize)
        host.contentView?.addSubview(capsule)
        capsule.update(extensions: [uiExtension("a"), uiExtension("b"), uiExtension("c")])
        capsule.layoutSubtreeIfNeeded()

        func index(atX x: CGFloat) -> Int {
            capsule.insertionIndex(forWindowPoint: capsule.convert(NSPoint(x: x, y: 18), to: nil), currentIndex: nil)
        }
        XCTAssertEqual(index(atX: 0), 0)
        XCTAssertEqual(index(atX: 20), 0, "centre of slot 0")
        XCTAssertEqual(index(atX: 52), 1, "centre of slot 1")
        XCTAssertEqual(index(atX: 84), 2, "centre of slot 2")
        XCTAssertEqual(index(atX: 190), 3, "beyond the last slot clamps to count")
    }

    func testInsertionIndexWithCurrentSlotHasHysteresisAroundIt() {
        let host = uiHostWindow(size: NSSize(width: 300, height: 100))
        defer { host.close() }
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.frame = NSRect(x: 0, y: 0, width: 200, height: SafariMetrics.glassButtonSize)
        host.contentView?.addSubview(capsule)
        capsule.update(extensions: [uiExtension("a"), uiExtension("b"), uiExtension("c")])
        capsule.layoutSubtreeIfNeeded()

        func index(atX x: CGFloat, current: Int) -> Int {
            capsule.insertionIndex(forWindowPoint: capsule.convert(NSPoint(x: x, y: 18), to: nil), currentIndex: current)
        }
        // Slot 1 spans x 36...68 in capsule coordinates; the gap only moves once the cursor clears it by 3 pt.
        XCTAssertEqual(index(atX: 40, current: 1), 1, "inside the current slot keeps it")
        XCTAssertEqual(index(atX: 30, current: 1), 0, "left of the slot by more than 3 pt moves left")
        XCTAssertEqual(index(atX: 72, current: 1), 2, "right of the slot by more than 3 pt moves right")
        XCTAssertEqual(index(atX: 160, current: 1), 3)
    }

    func testInsertionIndexIsSafeForOutOfRangeCurrentIndex() {
        let host = uiHostWindow(size: NSSize(width: 300, height: 100))
        defer { host.close() }
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        capsule.frame = NSRect(x: 0, y: 0, width: 200, height: SafariMetrics.glassButtonSize)
        host.contentView?.addSubview(capsule)
        capsule.update(extensions: [uiExtension("a"), uiExtension("b")])
        capsule.layoutSubtreeIfNeeded()
        let point = capsule.convert(NSPoint(x: 10, y: 18), to: nil)
        let result = capsule.insertionIndex(forWindowPoint: point, currentIndex: 7)
        XCTAssertTrue((0...2).contains(result), "result must stay a valid insertion index, got \(result)")
    }

    func testInsertionIndexOnEmptyCapsuleIsZero() {
        let capsule = ExtensionsToolbarCapsuleView(zone: .trailing)
        XCTAssertEqual(capsule.insertionIndex(forWindowPoint: .zero, currentIndex: nil), 0)
        XCTAssertEqual(capsule.insertionIndex(forWindowPoint: .zero, currentIndex: 3), 0)
    }

    // MARK: - Bubble geometry

    func testClampedAnchorXKeepsCaretInsideTheRoundedCorners() {
        let minX: CGFloat = 22 + 13.5 + 4
        XCTAssertEqual(ExtensionBubbleGeometry.clampedAnchorX(0, width: 380), minX, accuracy: 1e-9)
        XCTAssertEqual(ExtensionBubbleGeometry.clampedAnchorX(190, width: 380), 190, accuracy: 1e-9)
        XCTAssertEqual(ExtensionBubbleGeometry.clampedAnchorX(1000, width: 380), 380 - minX, accuracy: 1e-9)
        XCTAssertEqual(ExtensionBubbleGeometry.clampedAnchorX(20, width: 50), minX, accuracy: 1e-9, "degenerate width pins to the left bound")
    }

    func testBubblePathSpansFullWidthAndCaretRisesAboveBody() {
        let path = ExtensionBubbleGeometry.makeBubblePath(size: NSSize(width: 380, height: 520), anchorX: 190)
        let box = path.boundingBox
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 380, accuracy: 0.01)
        XCTAssertEqual(box.minY, 0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(box.maxY, 520)
        XCTAssertLessThan(box.maxY, 521)
        XCTAssertTrue(path.contains(NSPoint(x: 190, y: 100)))
        XCTAssertFalse(path.contains(NSPoint(x: -5, y: 100)))
    }

    func testBubblePathInsetShrinksTheBoundingBox() {
        let path = ExtensionBubbleGeometry.makeBubblePath(size: NSSize(width: 380, height: 520), anchorX: 190, inset: 2)
        XCTAssertEqual(path.boundingBox.minX, 2, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxX, 378, accuracy: 0.01)
    }

    func testBubblePathWithOutOfRangeAnchorEqualsPathAtClampedAnchor() {
        let far = ExtensionBubbleGeometry.makeBubblePath(size: NSSize(width: 380, height: 520), anchorX: 1000)
        let clamped = ExtensionBubbleGeometry.makeBubblePath(size: NSSize(width: 380, height: 520), anchorX: 380 - 39.5)
        XCTAssertEqual(far.boundingBox, clamped.boundingBox)
    }

    func testBubblePathAtMinimumPopupSizeStaysInsideItsBox() {
        // cachedPopupSize never yields less than 240 x 120, so that is the smallest bubble the app draws.
        let path = ExtensionBubbleGeometry.makeBubblePath(size: NSSize(width: 240, height: 120), anchorX: 120)
        XCTAssertEqual(path.boundingBox.minX, 0, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxX, 240, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(path.boundingBox.maxY, 120)
    }

    func testBubblePathBelowTwiceCornerRadiusDoesNotCrash() {
        // Not reachable through the app (see cachedPopupSize); only checks that construction completes.
        let tiny = ExtensionBubbleGeometry.makeBubblePath(size: NSSize(width: 10, height: 10), anchorX: 5)
        XCTAssertFalse(tiny.isEmpty)
        let zero = ExtensionBubbleGeometry.makeBubblePath(size: .zero, anchorX: 0)
        XCTAssertNotNil(zero)
    }

    func testMaskImageHasRequestedSize() {
        let image = ExtensionBubbleGeometry.makeMaskImage(size: NSSize(width: 380, height: 520), anchorX: 190)
        XCTAssertEqual(image.size, NSSize(width: 380, height: 520))
    }

    // MARK: - Popup size persistence

    func testCachedPopupSizeDefaultsWhenNothingStored() {
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "nobody"), NSSize(width: 380, height: 520))
    }

    func testSavedPopupSizeRoundsAndReadsBackCaseInsensitively() {
        ExtensionPopoverController.savePopupSize(NSSize(width: 300.4, height: 450.6), for: "ABC")
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "abc"), NSSize(width: 300, height: 451))
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "Abc"), NSSize(width: 300, height: 451))
    }

    func testSavingOneExtensionDoesNotEraseAnother() {
        ExtensionPopoverController.savePopupSize(NSSize(width: 400, height: 300), for: "one")
        ExtensionPopoverController.savePopupSize(NSSize(width: 500, height: 350), for: "two")
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "one"), NSSize(width: 400, height: 300))
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "two"), NSSize(width: 500, height: 350))
    }

    func testCachedPopupSizeRejectsTooSmallAndAcceptsMinimumAndClampsMaximum() {
        let key = "Safarium.ExtensionPopupSizes.v1"
        UserDefaults.standard.set(["small": [200.0, 500.0]], forKey: key)
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "small"), NSSize(width: 380, height: 520))
        UserDefaults.standard.set(["short": [300.0, 100.0]], forKey: key)
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "short"), NSSize(width: 380, height: 520))
        UserDefaults.standard.set(["edge": [240.0, 120.0]], forKey: key)
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "edge"), NSSize(width: 240, height: 120))
        UserDefaults.standard.set(["huge": [900.0, 700.0]], forKey: key)
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "huge"), NSSize(width: 600, height: 600))
    }

    func testCachedPopupSizeIgnoresMalformedEntries() {
        let key = "Safarium.ExtensionPopupSizes.v1"
        UserDefaults.standard.set(["three": [300.0, 400.0, 500.0]], forKey: key)
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "three"), NSSize(width: 380, height: 520))
        UserDefaults.standard.set(["text": "wide"], forKey: key)
        XCTAssertEqual(ExtensionPopoverController.cachedPopupSize(for: "text"), NSSize(width: 380, height: 520))
    }

    func testBadgeUpdateReusesExistingToolbarButtonsInPlaceWithoutViewChurn() {
        let cap = ExtensionsToolbarCapsuleView(zone: .leftOfAddressBar)
        let extA = BrowserExtensionItem(
            id: "ext-a",
            name: "uBlock",
            version: "1.0",
            icon: nil,
            badgeText: "4",
            badgeColor: .systemRed,
            popupURL: nil,
            enabled: true
        )
        let extB = BrowserExtensionItem(
            id: "ext-b",
            name: "Bitwarden",
            version: "1.0",
            icon: nil,
            badgeText: nil,
            badgeColor: nil,
            popupURL: nil,
            enabled: true
        )
        cap.update(extensions: [extA, extB])
        let btnABefore = cap.anchorButton(forExtensionID: "ext-a")
        let btnBBefore = cap.anchorButton(forExtensionID: "ext-b")
        XCTAssertNotNil(btnABefore)
        XCTAssertNotNil(btnBBefore)

        let extAUpdated = BrowserExtensionItem(
            id: "ext-a",
            name: "uBlock",
            version: "1.0",
            icon: nil,
            badgeText: "16",
            badgeColor: .systemRed,
            popupURL: nil,
            enabled: true
        )
        cap.update(extensions: [extAUpdated, extB])
        let btnAAfter = cap.anchorButton(forExtensionID: "ext-a")
        let btnBAfter = cap.anchorButton(forExtensionID: "ext-b")
        XCTAssertTrue(btnABefore === btnAAfter, "Badge update must reuse the existing button instance without teardown")
        XCTAssertTrue(btnBBefore === btnBAfter, "Sibling extension button must be reused in place")
    }
}
