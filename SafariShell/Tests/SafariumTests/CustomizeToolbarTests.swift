import XCTest
import AppKit
@testable import Safarium

/// Unit tests for `CustomizeToolbarSheetView.swift`: the item-ID model (partitions, labels, Codable), the
/// persisted `ToolbarCustomizationStore` (placement, clamping, spacer caps, visibility, reset, legacy v1
/// migration, malformed-data filtering), and the customize sheet's palette (tile widths, wrapping, clicks).
@MainActor
final class CustomizeToolbarTests: HermeticTestCase {
    private var savedDefaults: [String: Any] = [:]
    private var store: ToolbarCustomizationStore { ToolbarCustomizationStore.shared }
    private typealias Item = CustomizableToolbarItemID

    private final class Counter { var count = 0; var last: [String] = [] }

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            savedDefaults = UIDefaultsSandbox.snapshot()
            UIDefaultsSandbox.clear()
            store.resetToDefaults()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            store.resetToDefaults()
            UIDefaultsSandbox.restore(savedDefaults)
        }
        super.tearDown()
    }

    // MARK: - Item model

    func testToolbarActionSideCodableRoundTripsBothCases() throws {
        for side in [ToolbarActionSide.left, .right] {
            let data = try JSONEncoder().encode(side)
            XCTAssertEqual(try JSONDecoder().decode(ToolbarActionSide.self, from: data), side)
        }
        XCTAssertEqual(String(data: try JSONEncoder().encode(ToolbarActionSide.left), encoding: .utf8), "\"left\"")
    }

    func testEveryItemIDCodableRoundTripsAndKeepsRawValue() throws {
        XCTAssertEqual(Item.allCases.count, 19)
        for id in Item.allCases {
            let data = try JSONEncoder().encode(id)
            XCTAssertEqual(try JSONDecoder().decode(Item.self, from: data), id)
            XCTAssertEqual(Item(rawValue: id.rawValue), id)
        }
        XCTAssertNil(Item(rawValue: "notAnItem"))
    }

    func testItemLabelsAreNonEmptyAndUnique() {
        let labels = Item.allCases.map(\.label)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertEqual(Item.fixedSpace.label, "Space")
        XCTAssertEqual(Item.addressBar.label, "Address and Search")
    }

    func testSymbolNamesExistForEveryNonSpacerItem() {
        for id in Item.allCases where !id.isSpacer {
            XCTAssertFalse(id.symbolName.isEmpty, "\(id)")
        }
        XCTAssertEqual(Item.flexibleSpace.symbolName, "")
        XCTAssertEqual(Item.fixedSpace.symbolName, "")
        XCTAssertEqual(Item.reload.symbolName, "arrow.clockwise")
    }

    func testDefaultVisibleSetIsExactlyTheCoreItems() {
        let visible = Set(Item.allCases.filter(\.isDefaultVisible))
        XCTAssertEqual(visible, [.sidebar, .backForward, .downloads, .share, .newTab, .tabOverview, .addressBar])
        XCTAssertFalse(Item.zoom.isDefaultVisible)
        XCTAssertFalse(Item.flexibleSpace.isDefaultVisible)
    }

    func testMovableSetIsExactlyTheFourteenOptionalAndRightActions() {
        let movable = Set(Item.allCases.filter(\.isMovableAction))
        XCTAssertEqual(movable, [.startPage, .home, .history, .bookmarks, .zoom, .reload, .settings, .print,
                                 .webInspector, .privacyReport, .downloads, .share, .newTab, .tabOverview])
        XCTAssertFalse(Item.sidebar.isMovableAction)
        XCTAssertFalse(Item.addressBar.isMovableAction)
    }

    func testSpacersAreExactlyFlexibleAndFixed() {
        XCTAssertEqual(Set(Item.allCases.filter(\.isSpacer)), [.flexibleSpace, .fixedSpace])
    }

    func testAllMovableActionsHasNoDuplicatesAndMatchesMovableSet() {
        XCTAssertEqual(Item.allMovableActions.count, Set(Item.allMovableActions).count)
        XCTAssertEqual(Set(Item.allMovableActions), Set(Item.allCases.filter(\.isMovableAction)))
    }

    func testOptionalItemsAreMovableMinusTheDefaultRightFour() {
        XCTAssertEqual(Item.optionalActionItems.count, 10)
        XCTAssertEqual(Set(Item.optionalActionItems),
                       Set(Item.allCases.filter(\.isMovableAction)).subtracting(Item.defaultRightActionOrder))
    }

    func testDefaultRightActionOrderIsDownloadsShareNewTabOverview() {
        XCTAssertEqual(Item.defaultRightActionOrder, [.downloads, .share, .newTab, .tabOverview])
    }

    func testRowOrdersCoverEveryMovableActionAndSidebarOnceWithoutDuplicates() {
        let rows = Item.row1Order + Item.row2LeadingOrder
        XCTAssertEqual(rows.count, Set(rows).count, "a row lists an item twice")
        XCTAssertEqual(Set(rows), Set(Item.allCases.filter { $0 != .addressBar && !$0.isSpacer }))
        XCTAssertEqual(Item.row1Order.first, .sidebar)
    }

    // MARK: - Store: placement

    func testPlaceActionMovesItemFromRightToLeftAndRemovesOldSide() {
        store.placeAction(.share, on: .right)
        XCTAssertEqual(store.side(for: .share), .right)
        store.placeAction(.share, on: .left)
        XCTAssertEqual(store.side(for: .share), .left)
        XCTAssertFalse(store.rightActionOrder.contains(.share))
        XCTAssertEqual(store.leftActionOrder.filter { $0 == .share }.count, 1)
    }

    func testPlaceActionClampsIndexToBounds() {
        store.placeAction(.zoom, on: .left, at: 99)
        store.placeAction(.reload, on: .left, at: -5)
        XCTAssertEqual(store.leftActionOrder, [.reload, .zoom], "negative index clamps to 0, oversized to end")
    }

    func testPlaceActionAtIndexInsertsIntoTheMiddle() {
        store.placeAction(.zoom, on: .left)
        store.placeAction(.history, on: .left)
        store.placeAction(.reload, on: .left, at: 1)
        XCTAssertEqual(store.leftActionOrder, [.zoom, .reload, .history], "no index appends; index 1 inserts in the middle")
    }

    func testPlaceActionIgnoresNonMovableItems() {
        store.placeAction(.sidebar, on: .left)
        store.placeAction(.flexibleSpace, on: .right)
        XCTAssertNil(store.side(for: .sidebar))
        XCTAssertTrue(store.leftActionOrder.isEmpty)
        XCTAssertTrue(store.rightActionOrder == Item.defaultRightActionOrder)
    }

    func testRemoveActionHidesMovableItemEverywhere() {
        store.placeAction(.print, on: .right)
        XCTAssertTrue(store.isVisibleInToolbar(.print))
        store.removeAction(.print)
        XCTAssertFalse(store.isVisibleInToolbar(.print))
        XCTAssertNil(store.side(for: .print))
    }

    // MARK: - Store: visibility

    func testCoreItemVisibilityTogglesWithoutTouchingActionOrder() {
        XCTAssertTrue(store.isVisibleInToolbar(.sidebar))
        store.setVisible(false, for: .sidebar)
        XCTAssertFalse(store.isVisibleInToolbar(.sidebar))
        XCTAssertTrue(store.hiddenDefaultIDs.contains(.sidebar))
        store.toggle(.sidebar)
        XCTAssertTrue(store.isVisibleInToolbar(.sidebar))
        XCTAssertFalse(store.hiddenDefaultIDs.contains(.sidebar))
        XCTAssertEqual(store.rightActionOrder, Item.defaultRightActionOrder)
    }

    func testShowingDefaultMovableItemRestoresItsDefaultRightPosition() {
        store.removeAction(.share)
        XCTAssertFalse(store.isVisibleInToolbar(.share))
        store.setVisible(true, for: .share)
        XCTAssertEqual(store.rightActionOrder, [.downloads, .share, .newTab, .tabOverview])
    }

    func testShowingNonDefaultMovableItemAppendsItToRightEdgeFirst() {
        store.setVisible(true, for: .zoom)
        XCTAssertEqual(store.side(for: .zoom), .right)
        XCTAssertEqual(store.rightActionOrder.first, .zoom)
    }

    func testSetVisibleTrueOnAlreadyVisibleItemKeepsPosition() {
        store.placeAction(.zoom, on: .left)
        store.placeAction(.reload, on: .left)
        store.setVisible(true, for: .zoom)
        XCTAssertEqual(store.leftActionOrder, [.zoom, .reload])
    }

    func testToggleFlipsMovableItemVisibility() {
        XCTAssertFalse(store.isVisibleInToolbar(.bookmarks))
        store.toggle(.bookmarks)
        XCTAssertTrue(store.isVisibleInToolbar(.bookmarks))
        store.toggle(.bookmarks)
        XCTAssertFalse(store.isVisibleInToolbar(.bookmarks))
    }

    // MARK: - Store: spacers

    func testSpacerWidthsUseFiftySixAndTwentyFourPoints() {
        store.addSpacer(.flexibleSpace, on: .left)
        store.addSpacer(.fixedSpace, on: .left)
        store.addSpacer(.fixedSpace, on: .right)
        XCTAssertEqual(store.leftSpacerExtraWidth, 56 + 24)
        XCTAssertEqual(store.rightSpacerExtraWidth, 24)
    }

    func testSpacersAreCappedAtThreePerSide() {
        for _ in 0..<5 { store.addSpacer(.fixedSpace, on: .left) }
        XCTAssertEqual(store.leftSpacers.count, 3)
        XCTAssertEqual(store.leftSpacerExtraWidth, 72)
    }

    func testAddSpacerRejectsNonSpacerItems() {
        store.addSpacer(.zoom, on: .left)
        XCTAssertTrue(store.leftSpacers.isEmpty)
        XCTAssertFalse(store.isVisibleInToolbar(.zoom))
    }

    func testRemoveSpacersDeletesEveryInstanceOfThatSpacerOnBothSides() {
        store.addSpacer(.flexibleSpace, on: .left)
        store.addSpacer(.flexibleSpace, on: .right)
        store.addSpacer(.fixedSpace, on: .right)
        store.removeSpacers(of: .flexibleSpace)
        XCTAssertFalse(store.leftSpacers.contains(.flexibleSpace))
        XCTAssertFalse(store.rightSpacers.contains(.flexibleSpace))
        XCTAssertEqual(store.rightSpacers, [.fixedSpace])
    }

    func testSettingSpacerVisibilityAddsToLeftAndRemovesFromBothSides() {
        store.setVisible(true, for: .flexibleSpace)
        XCTAssertEqual(store.leftSpacers, [.flexibleSpace])
        XCTAssertTrue(store.isVisibleInToolbar(.flexibleSpace))
        store.setVisible(false, for: .flexibleSpace)
        XCTAssertFalse(store.isVisibleInToolbar(.flexibleSpace))
    }

    // MARK: - Store: reset, notifications, persistence

    func testResetToDefaultsRestoresFactoryLayout() {
        store.setVisible(false, for: .sidebar)
        store.placeAction(.zoom, on: .left)
        store.addSpacer(.fixedSpace, on: .right)
        store.resetToDefaults()
        XCTAssertTrue(store.hiddenDefaultIDs.isEmpty)
        XCTAssertTrue(store.leftActionOrder.isEmpty)
        XCTAssertEqual(store.rightActionOrder, Item.defaultRightActionOrder)
        XCTAssertTrue(store.leftSpacers.isEmpty && store.rightSpacers.isEmpty)
    }

    func testMutationsPostOneChangeNotificationEach() {
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: ToolbarCustomizationStore.didChangeNotification, object: nil, queue: nil) { _ in
            counter.count += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.placeAction(.print, on: .left)
        store.removeAction(.print)
        store.setVisible(false, for: .sidebar)
        XCTAssertEqual(counter.count, 3)
    }

    func testPersistedLayoutIsReadBackByAFreshStore() {
        store.placeAction(.history, on: .left)
        store.placeAction(.zoom, on: .right, at: 0)
        store.setVisible(false, for: .addressBar)
        store.addSpacer(.flexibleSpace, on: .right)

        let reloaded = ToolbarCustomizationStore()
        XCTAssertEqual(reloaded.leftActionOrder, [.history])
        XCTAssertEqual(reloaded.rightActionOrder, [.zoom, .downloads, .share, .newTab, .tabOverview])
        XCTAssertTrue(reloaded.hiddenDefaultIDs.contains(.addressBar))
        XCTAssertEqual(reloaded.rightSpacers, [.flexibleSpace])
    }

    func testDefaultPrivacyShieldIsShownAndCanBeRemovedAndRestored() {
        XCTAssertTrue(store.showsStandalonePrivacyShield)
        XCTAssertTrue(store.isVisibleInToolbar(.privacyReport))

        store.setVisible(false, for: .privacyReport)
        XCTAssertFalse(store.showsStandalonePrivacyShield)
        XCTAssertFalse(store.isVisibleInToolbar(.privacyReport))
        XCTAssertNil(store.side(for: .privacyReport))
        XCTAssertFalse(ToolbarCustomizationStore().showsStandalonePrivacyShield, "removal must persist")

        store.setVisible(true, for: .privacyReport)
        XCTAssertTrue(store.showsStandalonePrivacyShield)
    }

    func testPrivacyShieldMovedIntoCapsuleThenRemovedStaysRemoved() {
        store.placeAction(.privacyReport, on: .right, at: 0)
        XCTAssertFalse(store.showsStandalonePrivacyShield)
        XCTAssertTrue(store.isVisibleInToolbar(.privacyReport))

        store.removeAction(.privacyReport)
        XCTAssertFalse(store.showsStandalonePrivacyShield, "dragging it off must not resurrect the default shield")
        XCTAssertFalse(store.isVisibleInToolbar(.privacyReport))

        store.resetToDefaults()
        XCTAssertTrue(store.showsStandalonePrivacyShield)
    }

    func testClustersDefaultToTheLeftInOriginalOrder() {
        XCTAssertEqual(store.leftClusters, [.sidebar, .backForward, .privacyShield])
        XCTAssertTrue(store.rightClusters.isEmpty)
        XCTAssertEqual(store.clusterSide(.backForward), .left)
    }

    func testClusterCanMoveBehindTheAddressBarAndKeepsOrder() {
        store.placeCluster(.backForward, on: .right)
        store.placeCluster(.privacyShield, on: .right, at: 0)
        XCTAssertEqual(store.leftClusters, [.sidebar])
        XCTAssertEqual(store.rightClusters, [.privacyShield, .backForward])
        XCTAssertEqual(store.clusterSide(.privacyShield), .right)

        let reloaded = ToolbarCustomizationStore()
        XCTAssertEqual(reloaded.leftClusters, [.sidebar])
        XCTAssertEqual(reloaded.rightClusters, [.privacyShield, .backForward])
    }

    func testSidebarStaysOutermostOnTheLeft() {
        store.placeCluster(.sidebar, on: .left, at: 2)
        XCTAssertEqual(store.leftClusters.first, .sidebar)
        store.placeCluster(.sidebar, on: .right)
        store.placeCluster(.backForward, on: .left, at: 0)
        store.placeCluster(.sidebar, on: .left, at: 5)
        XCTAssertEqual(store.leftClusters.first, .sidebar)
    }

    func testSplitClustersAroundAddressBarKeepsRelativeOrder() {
        store.splitClusters(movingToRight: [.backForward, .privacyShield])
        XCTAssertEqual(store.leftClusters, [.sidebar])
        XCTAssertEqual(store.rightClusters, [.backForward, .privacyShield])
        store.splitClusters(movingToRight: [.sidebar, .backForward, .privacyShield])
        XCTAssertTrue(store.leftClusters.isEmpty)
        XCTAssertEqual(store.rightClusters, [.sidebar, .backForward, .privacyShield])
        store.resetToDefaults()
        XCTAssertEqual(store.leftClusters, [.sidebar, .backForward, .privacyShield])
    }

    func testPlacingShieldAsClusterPullsItOutOfActionCapsules() {
        store.placeAction(.privacyReport, on: .right, at: 0)
        store.placeCluster(.privacyShield, on: .right)
        XCTAssertNil(store.side(for: .privacyReport))
        XCTAssertTrue(store.showsStandalonePrivacyShield)
    }

    func testMalformedClusterValuesFallBackToDefaults() {
        UserDefaults.standard.set(["bogus", "backForward", "backForward"], forKey: "Safarium.Toolbar.LeftClusters.v1")
        UserDefaults.standard.set(["sidebar", "nope"], forKey: "Safarium.Toolbar.RightClusters.v1")
        UserDefaults.standard.set(["x"], forKey: "Safarium.Toolbar.RightActionOrder.v2")
        let loaded = ToolbarCustomizationStore()
        XCTAssertEqual(Set(loaded.leftClusters + loaded.rightClusters), Set(ToolbarCluster.allCases))
        XCTAssertEqual((loaded.leftClusters + loaded.rightClusters).count, 3)
    }

    func testMalformedPersistedValuesAreFilteredOnLoad() {
        UserDefaults.standard.set(["zoom", "sidebar", "bogus", "flexibleSpace"], forKey: "Safarium.Toolbar.RightActionOrder.v2")
        UserDefaults.standard.set(["fixedSpace", "zoom", "nope"], forKey: "Safarium.Toolbar.RightSpacers.v2")
        UserDefaults.standard.set(["notAnID"], forKey: "Safarium.Toolbar.HiddenNativeIDs.v2")
        let loaded = ToolbarCustomizationStore()
        XCTAssertEqual(loaded.rightActionOrder, [.zoom], "non-movable and unknown raw values must be dropped")
        XCTAssertEqual(loaded.rightSpacers, [.fixedSpace], "non-spacer entries must be dropped")
        XCTAssertTrue(loaded.hiddenDefaultIDs.isEmpty, "unknown hidden raw values are discarded")
    }

    func testLegacyV1LayoutMigratesHiddenDefaultsAndExtras() {
        UserDefaults.standard.removeObject(forKey: "Safarium.Toolbar.RightActionOrder.v2")
        UserDefaults.standard.set(["sidebar", "share"], forKey: "Safarium.Toolbar.HiddenNativeIDs.v1")
        UserDefaults.standard.set(["zoom", "reload"], forKey: "Safarium.Toolbar.EnabledExtraIDs.v1")
        let migrated = ToolbarCustomizationStore()
        XCTAssertEqual(migrated.hiddenDefaultIDs, [.sidebar], "movable IDs are not default-hidden in v2")
        XCTAssertEqual(migrated.rightActionOrder, [.zoom, .reload, .downloads, .newTab, .tabOverview],
                       "v1 extras first, then defaults that were not hidden")
        XCTAssertTrue(migrated.leftActionOrder.isEmpty)
    }

    func testLegacyV1ExtrasWithoutAnyHiddenKeyKeepDefaultRightItems() {
        UserDefaults.standard.removeObject(forKey: "Safarium.Toolbar.RightActionOrder.v2")
        UserDefaults.standard.removeObject(forKey: "Safarium.Toolbar.HiddenNativeIDs.v1")
        UserDefaults.standard.removeObject(forKey: "Safarium.Toolbar.EnabledExtraIDs.v1")
        let migrated = ToolbarCustomizationStore()
        XCTAssertEqual(migrated.rightActionOrder, Item.defaultRightActionOrder)
        XCTAssertTrue(migrated.hiddenDefaultIDs.isEmpty)
    }

    // MARK: - Sheet: transform & palette geometry

    private func makeSheet(width: CGFloat, height: CGFloat = 520) -> CustomizeToolbarSheetView {
        let sheet = CustomizeToolbarSheetView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        sheet.layoutSubtreeIfNeeded()
        return sheet
    }

    private func tiles(of sheet: CustomizeToolbarSheetView) -> [CustomizePaletteTileView] {
        uiPrivate(sheet, "tileViews", as: [CustomizePaletteTileView].self) ?? []
    }

    func testTopCenteredScaleTransformIsIdentityAtScaleOneAndNoTranslation() {
        let sheet = makeSheet(width: 800)
        let card: NSView = uiPrivate(sheet, "sheetCard", as: NSView.self)!
        card.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let t = sheet.topCenteredScaleTransform(scale: 1, translateY: 0)
        XCTAssertTrue(CATransform3DIsIdentity(t))
    }

    func testTopCenteredScalePinsTopCenterAndScalesAroundIt() {
        let sheet = makeSheet(width: 800)
        let card: NSView = uiPrivate(sheet, "sheetCard", as: NSView.self)!
        card.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        // Pivot is top-center (200, 300). x' = s*(x-200)+200, y' = s*(y-300)+300+ty.
        let half = sheet.topCenteredScaleTransform(scale: 0.5, translateY: 0)
        XCTAssertEqual(half.m11, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.m22, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.m41, 100, accuracy: 1e-9)
        XCTAssertEqual(half.m42, 150, accuracy: 1e-9)

        let dropped = sheet.topCenteredScaleTransform(scale: 1, translateY: -10)
        XCTAssertEqual(dropped.m11, 1, accuracy: 1e-9)
        XCTAssertEqual(dropped.m41, 0, accuracy: 1e-9)
        XCTAssertEqual(dropped.m42, -10, accuracy: 1e-9)
    }

    func testPaletteTileWidthsFollowTheirKind() {
        let cases: [(CustomizePaletteTileView.Kind, CGFloat)] = [
            (.addressAndSearch, 248), (.backForwardPair, 86), (.flexibleSpace, 88),
            (.fixedSpace, 64), (.symbol("gear"), 82), (.extensionIcon(nil), 82)
        ]
        for (kind, width) in cases {
            let tile = CustomizePaletteTileView(kind: kind, title: "T", isInToolbar: false, isDark: false)
            XCTAssertEqual(tile.preferredTileWidth, width, "\(kind)")
        }
    }

    func testPresentBuildsOneTilePerNativeItemExtensionAndSpacer() {
        let sheet = makeSheet(width: 900)
        sheet.present(extensions: [uiExtension("ext-a"), uiExtension("ext-b")], hiddenExtensionIDs: [], isDark: false)
        // row1 (11) + row2 (5) + address bar (1) + extensions (2) + flexible & fixed spacers (2)
        XCTAssertEqual(tiles(of: sheet).count, 21)
    }

    func testPresentDropsDisabledExtensionsFromPalette() {
        let sheet = makeSheet(width: 900)
        sheet.present(extensions: [uiExtension("on"), uiExtension("off", enabled: false)], hiddenExtensionIDs: [], isDark: false)
        XCTAssertEqual(tiles(of: sheet).count, 11 + 5 + 1 + 1 + 2)
    }

    func testTileInToolbarStateMirrorsStoreAndHiddenExtensions() {
        store.placeAction(.zoom, on: .left)
        let sheet = makeSheet(width: 900)
        sheet.present(extensions: [uiExtension("ext-a"), uiExtension("ext-b")], hiddenExtensionIDs: ["ext-b"], isDark: true)
        let all = tiles(of: sheet)
        let zoomIndex = Item.row1Order.firstIndex(of: .zoom)!
        let extStart = Item.row1Order.count + Item.row2LeadingOrder.count + 1
        XCTAssertTrue(uiPrivate(all[zoomIndex], "isInToolbar", as: Bool.self)!)
        XCTAssertFalse(uiPrivate(all[Item.row1Order.firstIndex(of: .reload)!], "isInToolbar", as: Bool.self)!)
        XCTAssertTrue(uiPrivate(all[extStart], "isInToolbar", as: Bool.self)!)
        XCTAssertFalse(uiPrivate(all[extStart + 1], "isInToolbar", as: Bool.self)!)
        XCTAssertFalse(uiPrivate(all[all.count - 1], "isInToolbar", as: Bool.self)!, "spacers are never shown as active")
    }

    func testClickingNativeTileReportsDesiredVisibilityAndRebuilds() {
        let sheet = makeSheet(width: 900)
        let received = Counter()
        sheet.onToggleNativeItem = { id, visible in received.last = [id.rawValue, visible ? "1" : "0"] }
        sheet.present(extensions: [], hiddenExtensionIDs: [], isDark: false)
        let zoomTile = tiles(of: sheet)[Item.row1Order.firstIndex(of: .zoom)!]
        zoomTile.onClick?()
        XCTAssertEqual(received.last, ["zoom", "1"], "a hidden item is requested visible")
        XCTAssertEqual(tiles(of: sheet).count, 11 + 5 + 1 + 2, "palette is rebuilt after a click")
    }

    func testClickingExtensionTileTogglesHiddenStateAndReportsIt() {
        let sheet = makeSheet(width: 900)
        let received = Counter()
        sheet.onToggleExtension = { ext, visible in received.last = [ext.id, visible ? "1" : "0"] }
        let ext = uiExtension("ext-z")
        sheet.present(extensions: [ext], hiddenExtensionIDs: [], isDark: false)
        let extTile = tiles(of: sheet)[Item.row1Order.count + Item.row2LeadingOrder.count + 1]
        extTile.onClick?()
        XCTAssertEqual(received.last, ["ext-z", "0"], "an in-toolbar extension is requested hidden")
        let hiddenNow: Set<String> = uiPrivate(sheet, "hiddenExtensionIDs", as: Set<String>.self) ?? []
        XCTAssertTrue(hiddenNow.contains("ext-z"))
    }

    func testWrappingMovesTilesToNewRowsWhenNarrow() {
        let sheet = makeSheet(width: 600, height: 700)
        sheet.present(extensions: [], hiddenExtensionIDs: [], isDark: false)
        let rowsNarrow = Set(tiles(of: sheet).map { $0.frame.minY }).count
        sheet.setFrameSize(NSSize(width: 1400, height: 700))
        sheet.layoutSubtreeIfNeeded()
        sheet.layoutPaletteTiles()
        let rowsWide = Set(tiles(of: sheet).map { $0.frame.minY }).count
        XCTAssertGreaterThan(rowsNarrow, rowsWide, "a wider palette must pack tiles into fewer rows")
    }

    func testFirstTileStartsAtPaddingAndRowsAreSpacedByTheGap() {
        let sheet = makeSheet(width: 900, height: 700)
        sheet.present(extensions: [uiExtension("e1")], hiddenExtensionIDs: [], isDark: false)
        let all = tiles(of: sheet)
        XCTAssertEqual(all[0].frame.origin.x, 8, accuracy: 1e-9)
        XCTAssertEqual(all[0].frame.origin.y, 4, accuracy: 1e-9)
        XCTAssertEqual(all[0].frame.height, 66, accuracy: 1e-9)

        var pairsChecked = 0
        for i in all.indices.dropFirst() where all[i].frame.minY == all[i - 1].frame.minY {
            XCTAssertEqual(all[i].frame.minX, all[i - 1].frame.maxX + 14, accuracy: 1e-9, "tiles in one row are 14 pt apart")
            pairsChecked += 1
        }
        XCTAssertGreaterThan(pairsChecked, 3, "the first rows must hold several tiles at 900 pt")
    }

    func testEveryRowFitsInsideCanvasExceptSingleOversizedTiles() {
        let sheet = makeSheet(width: 760, height: 700)
        sheet.present(extensions: (0..<6).map { uiExtension("ext-\($0)") }, hiddenExtensionIDs: [], isDark: false)
        let canvas: NSView = uiPrivate(sheet, "paletteCanvas", as: NSView.self)!
        let availW = max(560, canvas.bounds.width)
        for tile in tiles(of: sheet) where tile.frame.minX > 8 {
            XCTAssertLessThanOrEqual(tile.frame.maxX, availW - 8 + 0.5, "tile overflows the palette width")
        }
    }

    func testPaletteHeightIsAtLeastMinimumAndGrowsWithRows() {
        let sheet = makeSheet(width: 600, height: 900)
        sheet.present(extensions: [], hiddenExtensionIDs: [], isDark: false)
        let narrowHeight = (uiPrivate(sheet, "paletteHeightConstraint", as: NSLayoutConstraint.self)?.constant) ?? 0
        XCTAssertGreaterThanOrEqual(narrowHeight, 144)

        sheet.setFrameSize(NSSize(width: 2000, height: 900))
        sheet.layoutSubtreeIfNeeded()
        sheet.layoutPaletteTiles()
        let wideHeight = (uiPrivate(sheet, "paletteHeightConstraint", as: NSLayoutConstraint.self)?.constant) ?? 0
        XCTAssertLessThan(wideHeight, narrowHeight)
    }

    func testDismissWithoutAnimationHidesSheetAndFiresCallback() {
        let sheet = makeSheet(width: 900)
        let dismissed = Counter()
        sheet.onDismiss = { dismissed.count += 1 }
        sheet.present(extensions: [], hiddenExtensionIDs: [], isDark: false)
        sheet.dismiss(animated: false)
        XCTAssertTrue(sheet.isHidden)
        XCTAssertEqual(dismissed.count, 1)
    }
}
