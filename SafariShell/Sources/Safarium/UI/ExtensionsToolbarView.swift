import AppKit
import QuartzCore

/// Toolbar placement zones where extension icons can be freely dragged and dropped —
/// either as standalone Liquid Glass capsules or merged directly into native toolbar button groups.
enum ExtensionToolbarZone: String, CaseIterable, Codable {
    case inSidebarGroup
    case afterSidebar
    case inBackForwardGroup
    case leftOfAddressBar
    case rightOfAddressBar
    case inRightActionsGroup
    case trailing

    var isMergedGroup: Bool {
        switch self {
        case .inSidebarGroup, .inBackForwardGroup, .inRightActionsGroup:
            return true
        case .afterSidebar, .leftOfAddressBar, .rightOfAddressBar, .trailing:
            return false
        }
    }

    static let standaloneZones: [ExtensionToolbarZone] = [
        .afterSidebar, .leftOfAddressBar, .rightOfAddressBar, .trailing
    ]

    static let mergedGroupZones: [ExtensionToolbarZone] = [
        .inSidebarGroup, .inBackForwardGroup, .inRightActionsGroup
    ]
}

/// Live toolbar references captured for cross-toolbar zone hit-testing and floating drag overlay.
struct ToolbarExtensionLandmarks {
    let toolbarView: NSView
    let overlayHostView: NSView
    let sidebarView: NSView
    let backForwardView: NSView
    let addressBarView: NSView
    let rightActionsView: NSView
}

/// Coordinates free drag-and-drop reordering of extension icons across all toolbar zones AND directly
/// inside native Liquid Glass button groups (`sidebarCapsule`, `backForwardCapsule`, `rightActionCapsule`).
final class ExtensionsToolbarCoordinator {
    var onClickExtension: ((BrowserExtensionItem, NSView) -> Void)?
    var onManageExtension: ((BrowserExtensionItem, NSView) -> Void)?
    var onRemoveExtension: ((String) -> Void)?
    var onOpenChromeWebStore: (() -> Void)?
    var onCustomizeToolbar: (() -> Void)?
    var contextMenuProvider: ((String) -> [BrowserExtensionContextMenuItem])?
    var onTriggerContextMenuItem: ((String, String) -> Void)?
    var onDragWillBegin: (() -> Void)?
    var onLayoutNeedsUpdate: ((Bool) -> Void)?
    var onToolbarItemsDidChange: (() -> Void)?
    var landmarkProvider: (() -> ToolbarExtensionLandmarks)?

    private static let layoutDefaultsKey = "Safarium.ExtensionToolbarLayout.v3"
    private static let v2LayoutDefaultsKey = "Safarium.ExtensionToolbarLayout.v2"
    private static let legacyOrderDefaultsKey = "Safarium.ExtensionToolbarOrder"

    struct PersistedToolbarLayout: Codable {
        var standalone: [String: [String]]
        var mergedTokens: [String: [String]]
        var hidden: [String]?
    }

    private let capsules: [ExtensionToolbarZone: ExtensionsToolbarCapsuleView]
    private var mergedGroups: [ExtensionToolbarZone: GlassActionCapsule] = [:]
    private var allExtensionsByID: [String: BrowserExtensionItem] = [:]
    private var hiddenFromToolbarIDs = Set<String>()
    private var currentTheme: AdaptiveChromeTheme = .defaultLight

    private struct DragSession {
        let item: BrowserExtensionItem
        let originZone: ExtensionToolbarZone
        let originIndex: Int
        var currentZone: ExtensionToolbarZone
        var currentIndex: Int
        let startWindowPoint: NSPoint
        let cursorOffset: NSPoint
        var hasStartedDragging: Bool
        var isOutsideToolbar: Bool
        var isRemovalArmed: Bool
        var armRemovalWork: DispatchWorkItem?
        weak var candidateButton: ExtensionToolbarIconButton?
        var detachedButton: ExtensionToolbarIconButton?
        var floatingView: FloatingDraggedExtensionView?
        var landmarks: ToolbarExtensionLandmarks?
    }
    private var dragSession: DragSession?
    private var pendingDropCleanup: (() -> Void)?

    var isDragSessionActive: Bool { dragSession != nil }

    init() {
        var map: [ExtensionToolbarZone: ExtensionsToolbarCapsuleView] = [:]
        for zone in ExtensionToolbarZone.standaloneZones {
            map[zone] = ExtensionsToolbarCapsuleView(zone: zone)
        }
        self.capsules = map

        for zone in ExtensionToolbarZone.standaloneZones {
            guard let cap = map[zone] else { continue }
            cap.onClickExtension = { [weak self] item, anchor in
                self?.onClickExtension?(item, anchor)
            }
            cap.onManageExtension = { [weak self] item, anchor in
                self?.onManageExtension?(item, anchor)
            }
            cap.onRemoveExtension = { [weak self] id in
                self?.onRemoveExtension?(id)
            }
            cap.onOpenChromeWebStore = { [weak self] in
                self?.onOpenChromeWebStore?()
            }
            cap.onCustomizeToolbar = { [weak self] in
                self?.onCustomizeToolbar?()
            }
            cap.contextMenuProvider = { [weak self] extID in
                self?.contextMenuProvider?(extID) ?? []
            }
            cap.onTriggerContextMenuItem = { [weak self] extID, itemID in
                self?.onTriggerContextMenuItem?(extID, itemID)
            }
        }
    }

    func registerMergedGroup(_ group: GlassActionCapsule, for zone: ExtensionToolbarZone) {
        guard zone.isMergedGroup else { return }
        mergedGroups[zone] = group
    }

    func capsule(for zone: ExtensionToolbarZone) -> ExtensionsToolbarCapsuleView {
        // Merged-group zones have no standalone capsule; fall back instead of crashing.
        capsules[zone] ?? capsules[.leftOfAddressBar]!
    }

    var allCapsules: [ExtensionsToolbarCapsuleView] {
        ExtensionToolbarZone.standaloneZones.compactMap { capsules[$0] }
    }

    func requiredWidth(for zone: ExtensionToolbarZone) -> CGFloat {
        capsules[zone]?.requiredWidth ?? 0.0
    }

    func anchorButton(forExtensionID id: String) -> NSView? {
        for zone in ExtensionToolbarZone.standaloneZones {
            if let btn = capsules[zone]?.anchorButton(forExtensionID: id) {
                return btn
            }
        }
        for zone in ExtensionToolbarZone.mergedGroupZones {
            if let btn = mergedGroups[zone]?.anchorExtensionButton(forExtensionID: id) {
                return btn
            }
        }
        return nil
    }

    func firstVisibleCapsule() -> NSView? {
        for zone in [ExtensionToolbarZone.leftOfAddressBar, .rightOfAddressBar, .afterSidebar, .trailing] {
            if let cap = capsules[zone], !cap.isHidden, cap.requiredWidth > 0 {
                return cap
            }
        }
        for zone in [ExtensionToolbarZone.inRightActionsGroup, .inBackForwardGroup, .inSidebarGroup] {
            if let grp = mergedGroups[zone], !grp.isHidden, grp.hasMergedExtensions {
                return grp
            }
        }
        return nil
    }

    func containsWindowPoint(_ ptInWindow: NSPoint) -> Bool {
        for cap in allCapsules where !cap.isHidden {
            let local = cap.convert(ptInWindow, from: nil)
            if cap.bounds.contains(local) {
                return true
            }
        }
        for grp in mergedGroups.values where !grp.isHidden {
            if grp.containsMergedExtension(atWindowPoint: ptInWindow) {
                return true
            }
        }
        return false
    }

    private func makeWiredExtensionButton(for item: BrowserExtensionItem) -> ExtensionToolbarIconButton {
        let btn = ExtensionToolbarIconButton(item: item, isDark: currentTheme.prefersLightInk)
        wireCallbacks(on: btn)
        return btn
    }

    private func wireCallbacks(on btn: ExtensionToolbarIconButton) {
        let item = btn.item
        btn.onLeftClick = { [weak self, weak btn] in
            guard let self, let btn else { return }
            self.onClickExtension?(item, btn)
        }
        btn.onManage = { [weak self, weak btn] in
            guard let self, let btn else { return }
            self.onManageExtension?(item, btn)
        }
        btn.onRemove = { [weak self] in
            self?.onRemoveExtension?(item.id)
        }
        btn.onOpenStore = { [weak self] in
            self?.onOpenChromeWebStore?()
        }
        btn.onCustomizeToolbar = { [weak self] in
            self?.onCustomizeToolbar?()
        }
        btn.contextMenuProvider = { [weak self] in
            self?.contextMenuProvider?(item.id) ?? []
        }
        btn.onTriggerContextMenuItem = { [weak self] menuItemID in
            self?.onTriggerContextMenuItem?(item.id, menuItemID)
        }
    }

    func update(extensions newExtensions: [BrowserExtensionItem]) {
        guard dragSession == nil else { return }
        flushPendingDropCleanup()

        let enabled = newExtensions.filter { $0.enabled }
        allExtensionsByID = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        let resolved = resolvePersistedLayout(for: enabled)

        for zone in ExtensionToolbarZone.standaloneZones {
            let ids = resolved.standalone[zone.rawValue] ?? []
            let items = ids.compactMap { allExtensionsByID[$0] }
            capsules[zone]?.update(extensions: items)
            capsules[zone]?.apply(theme: currentTheme, animated: false)
        }

        for zone in ExtensionToolbarZone.mergedGroupZones {
            guard let grp = mergedGroups[zone] else { continue }
            let tokens = resolved.mergedTokens[zone.rawValue] ?? []
            if grp.updateMergedExtensionsInPlace(itemsByID: allExtensionsByID, tokenOrder: tokens) {
                continue
            }
            var extButtons: [ExtensionToolbarIconButton] = []
            for token in tokens where token.hasPrefix("ext:") {
                let id = String(token.dropFirst("ext:".count))
                if let item = allExtensionsByID[id] {
                    extButtons.append(makeWiredExtensionButton(for: item))
                }
            }
            grp.setMergedExtensions(extButtons, tokenOrder: tokens)
        }
    }

    func apply(theme: AdaptiveChromeTheme, animated: Bool) {
        currentTheme = theme
        for cap in allCapsules {
            cap.apply(theme: theme, animated: animated)
        }
        dragSession?.floatingView?.apply(theme: theme)
    }

    func isHiddenFromToolbar(_ id: String) -> Bool {
        hiddenFromToolbarIDs.contains(id)
    }

    func setHiddenFromToolbar(_ hidden: Bool, forExtensionID id: String) {
        if hidden {
            hiddenFromToolbarIDs.insert(id)
        } else {
            hiddenFromToolbarIDs.remove(id)
        }
        persistLayout()
        let items = Array(allExtensionsByID.values)
        update(extensions: items)
        onLayoutNeedsUpdate?(true)
    }

    func resetLayoutToDefault() {
        hiddenFromToolbarIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.layoutDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.v2LayoutDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyOrderDefaultsKey)
        let items = Array(allExtensionsByID.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        update(extensions: items)
        persistLayout()
        onLayoutNeedsUpdate?(true)
    }

    func setCustomizeJiggle(_ active: Bool) {
        var phaseOffset = 0.08
        for cap in allCapsules {
            cap.setCustomizeJiggle(active, basePhase: phaseOffset)
            phaseOffset += 0.14
        }
    }

    func placeExtensionFromSheet(_ item: BrowserExtensionItem, atWindowPoint ptInWindow: NSPoint) {
        allExtensionsByID[item.id] = item
        hiddenFromToolbarIDs.remove(item.id)

        // Remove from any previous standalone or merged slot first
        for zone in ExtensionToolbarZone.standaloneZones {
            if let cap = capsules[zone], cap.extensions.contains(where: { $0.id == item.id }) {
                cap.update(extensions: cap.extensions.filter { $0.id != item.id })
            }
        }
        for zone in ExtensionToolbarZone.mergedGroupZones {
            if let grp = mergedGroups[zone],
               let btn = grp.anchorExtensionButton(forExtensionID: item.id) as? ExtensionToolbarIconButton {
                _ = grp.detachMergedExtensionButton(btn)
            }
        }

        let targetZone: ExtensionToolbarZone
        let targetIndex: Int
        if let landmarks = landmarkProvider?() {
            let cursorInToolbar = landmarks.toolbarView.convert(ptInWindow, from: nil)
            targetZone = resolveTargetZone(cursorX: cursorInToolbar.x, currentZone: .leftOfAddressBar, landmarks: landmarks)
            targetIndex = insertionIndex(in: targetZone, atWindowPoint: ptInWindow, currentIndex: nil)
        } else {
            targetZone = .leftOfAddressBar
            targetIndex = 0
        }

        let btn = makeWiredExtensionButton(for: item)
        if targetZone.isMergedGroup, let grp = mergedGroups[targetZone] {
            grp.insertMergedExtensionButton(btn, atVisibleIndex: targetIndex)
        } else {
            let destCap = capsule(for: targetZone)
            destCap.insertDetachedButton(btn, at: targetIndex)
            destCap.apply(theme: currentTheme, animated: false)
        }

        persistLayout()
        onLayoutNeedsUpdate?(true)
        onToolbarItemsDidChange?()
    }

    // MARK: - Persistence (Standalone Zones + Interleaved Merged Group Slot Orders + Hidden IDs)

    func resolvePersistedLayout(for items: [BrowserExtensionItem]) -> PersistedToolbarLayout {
        var standalone: [String: [String]] = [:]
        var mergedTokens: [String: [String]] = [:]
        for zone in ExtensionToolbarZone.standaloneZones { standalone[zone.rawValue] = [] }
        for zone in ExtensionToolbarZone.mergedGroupZones { mergedTokens[zone.rawValue] = [] }

        guard !items.isEmpty else {
            hiddenFromToolbarIDs.removeAll()
            return PersistedToolbarLayout(standalone: standalone, mergedTokens: mergedTokens, hidden: [])
        }

        let validIDs = Set(items.map(\.id))
        var placed = Set<String>()
        var resolvedHidden = Set<String>()

        if let data = UserDefaults.standard.data(forKey: Self.layoutDefaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedToolbarLayout.self, from: data) {
            if let savedHidden = decoded.hidden {
                for id in savedHidden where validIDs.contains(id) {
                    resolvedHidden.insert(id)
                }
            }
            for zone in ExtensionToolbarZone.standaloneZones {
                let ids = decoded.standalone[zone.rawValue] ?? []
                for id in ids where validIDs.contains(id) && !resolvedHidden.contains(id) && !placed.contains(id) {
                    standalone[zone.rawValue, default: []].append(id)
                    placed.insert(id)
                }
            }
            for zone in ExtensionToolbarZone.mergedGroupZones {
                let rawTokens = decoded.mergedTokens[zone.rawValue] ?? []
                var cleanTokens: [String] = []
                for token in rawTokens {
                    if token.hasPrefix("native:") {
                        cleanTokens.append(token)
                    } else if token.hasPrefix("ext:") {
                        let id = String(token.dropFirst("ext:".count))
                        if validIDs.contains(id) && !resolvedHidden.contains(id) && !placed.contains(id) {
                            cleanTokens.append(token)
                            placed.insert(id)
                        }
                    }
                }
                mergedTokens[zone.rawValue] = cleanTokens
            }
        } else if let data = UserDefaults.standard.data(forKey: Self.v2LayoutDefaultsKey),
                  let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for zone in ExtensionToolbarZone.standaloneZones {
                let ids = decoded[zone.rawValue] ?? []
                for id in ids where validIDs.contains(id) && !placed.contains(id) {
                    standalone[zone.rawValue, default: []].append(id)
                    placed.insert(id)
                }
            }
        } else if let legacyOrder = UserDefaults.standard.stringArray(forKey: Self.legacyOrderDefaultsKey), !legacyOrder.isEmpty {
            for id in legacyOrder where validIDs.contains(id) && !placed.contains(id) {
                standalone[ExtensionToolbarZone.leftOfAddressBar.rawValue, default: []].append(id)
                placed.insert(id)
            }
        }

        hiddenFromToolbarIDs = resolvedHidden

        for item in items where !placed.contains(item.id) && !resolvedHidden.contains(item.id) {
            standalone[ExtensionToolbarZone.leftOfAddressBar.rawValue, default: []].append(item.id)
            placed.insert(item.id)
        }
        return PersistedToolbarLayout(
            standalone: standalone,
            mergedTokens: mergedTokens,
            hidden: Array(resolvedHidden).sorted()
        )
    }

    private func persistLayout() {
        var standalone: [String: [String]] = [:]
        var mergedTokens: [String: [String]] = [:]
        for zone in ExtensionToolbarZone.standaloneZones {
            standalone[zone.rawValue] = capsules[zone]?.extensions.map(\.id) ?? []
        }
        for zone in ExtensionToolbarZone.mergedGroupZones {
            mergedTokens[zone.rawValue] = mergedGroups[zone]?.orderedSlotTokens() ?? []
        }
        let payload = PersistedToolbarLayout(
            standalone: standalone,
            mergedTokens: mergedTokens,
            hidden: Array(hiddenFromToolbarIDs).sorted()
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.layoutDefaultsKey)
        }
    }

    // MARK: - Free Drag & Drop Across Standalone Zones & Merged Liquid Glass Button Groups

    func beginDragIfHit(_ event: NSEvent) -> Bool {
        flushPendingDropCleanup()
        let ptInWindow = event.locationInWindow

        // 1. Check standalone extension capsules
        for zone in ExtensionToolbarZone.standaloneZones {
            guard let cap = capsules[zone], !cap.isHidden,
                  let hit = cap.hitButton(atWindowPoint: ptInWindow) else { continue }
            startTrackingHit(button: hit.button, zone: zone, index: hit.index, ptInWindow: ptInWindow)
            return true
        }

        // 2. Check extensions merged inside native Liquid Glass button groups
        for zone in ExtensionToolbarZone.mergedGroupZones {
            guard let grp = mergedGroups[zone], !grp.isHidden,
                  let hit = grp.hitMergedExtensionButton(atWindowPoint: ptInWindow) else { continue }
            startTrackingHit(button: hit.button, zone: zone, index: hit.visibleIndex, ptInWindow: ptInWindow)
            return true
        }

        return false
    }

    private func startTrackingHit(
        button: ExtensionToolbarIconButton,
        zone: ExtensionToolbarZone,
        index: Int,
        ptInWindow: NSPoint
    ) {
        let btnFrameInWin = button.convert(button.bounds, to: nil)
        let cursorOffset = NSPoint(
            x: ptInWindow.x - btnFrameInWin.midX,
            y: ptInWindow.y - btnFrameInWin.midY
        )
        dragSession = DragSession(
            item: button.item,
            originZone: zone,
            originIndex: index,
            currentZone: zone,
            currentIndex: index,
            startWindowPoint: ptInWindow,
            cursorOffset: cursorOffset,
            hasStartedDragging: false,
            isOutsideToolbar: false,
            isRemovalArmed: false,
            armRemovalWork: nil,
            candidateButton: button,
            detachedButton: nil,
            floatingView: nil,
            landmarks: nil
        )
    }

    func isPointOutsideToolbar(_ cursorInToolbar: NSPoint, toolbarBounds: NSRect) -> Bool {
        let margin: CGFloat = 28.0
        return cursorInToolbar.y < (toolbarBounds.minY - margin) ||
               cursorInToolbar.y > (toolbarBounds.maxY + margin) ||
               cursorInToolbar.x < (toolbarBounds.minX - margin) ||
               cursorInToolbar.x > (toolbarBounds.maxX + margin)
    }

    private func cancelOutsideRemovalTimers(in session: inout DragSession) {
        session.armRemovalWork?.cancel()
        session.armRemovalWork = nil
    }

    private func scheduleOutsideRemovalTimers(for extensionID: String) {
        guard var session = dragSession, session.item.id == extensionID else { return }
        cancelOutsideRemovalTimers(in: &session)

        let armWork = DispatchWorkItem { [weak self] in
            guard let self, var active = self.dragSession,
                  active.item.id == extensionID,
                  active.hasStartedDragging,
                  active.isOutsideToolbar else { return }
            active.isRemovalArmed = true
            self.dragSession = active
            NSCursor.disappearingItem.set()
            active.floatingView?.setMarkedForRemoval(true)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }

        session.armRemovalWork = armWork
        dragSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: armWork)
    }

    private func performRemovalFromToolbar(session: DragSession) {
        var mutable = session
        cancelOutsideRemovalTimers(in: &mutable)
        dragSession = nil
        NSCursor.arrow.set()

        for zone in ExtensionToolbarZone.allCases {
            setPlaceholder(nil, in: zone, animated: true)
        }

        hiddenFromToolbarIDs.insert(session.item.id)
        persistLayout()
        onLayoutNeedsUpdate?(true)
        onToolbarItemsDidChange?()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        if let floating = session.floatingView {
            floating.animateRemovePoof { [weak floating] in
                floating?.removeFromSuperview()
            }
        }
    }

    private func setPlaceholder(_ index: Int?, in zone: ExtensionToolbarZone, animated: Bool) {
        if zone.isMergedGroup {
            mergedGroups[zone]?.setPlaceholderVisibleIndex(index, animated: animated)
        } else {
            capsules[zone]?.setPlaceholderIndex(index, animated: animated)
        }
    }

    private func insertionIndex(in zone: ExtensionToolbarZone, atWindowPoint ptInWindow: NSPoint, currentIndex: Int?) -> Int {
        if zone.isMergedGroup {
            return mergedGroups[zone]?.insertionVisibleIndex(forWindowPoint: ptInWindow, currentVisibleIndex: currentIndex) ?? 0
        } else {
            return capsules[zone]?.insertionIndex(forWindowPoint: ptInWindow, currentIndex: currentIndex) ?? 0
        }
    }

    func continueDrag(_ event: NSEvent) {
        guard var session = dragSession else { return }
        let ptInWindow = event.locationInWindow

        if !session.hasStartedDragging {
            let dist = hypot(ptInWindow.x - session.startWindowPoint.x, ptInWindow.y - session.startWindowPoint.y)
            guard dist > 4.0 else { return }

            guard let landmarks = landmarkProvider?() else { return }
            onDragWillBegin?()

            let detached: ExtensionToolbarIconButton?
            if session.originZone.isMergedGroup, let grp = mergedGroups[session.originZone], let cand = session.candidateButton {
                let detachedIdx = grp.detachMergedExtensionButton(cand) ?? session.originIndex
                session.currentIndex = detachedIdx
                grp.setPlaceholderVisibleIndex(detachedIdx, animated: false)
                detached = cand
            } else {
                let originCap = capsule(for: session.originZone)
                detached = originCap.detachButton(at: session.originIndex)
                originCap.setPlaceholderIndex(session.originIndex, animated: false)
            }

            let floating = FloatingDraggedExtensionView(item: session.item, theme: currentTheme)
            let overlay = landmarks.overlayHostView
            let centerInOverlay = overlay.convert(
                NSPoint(x: ptInWindow.x - session.cursorOffset.x, y: ptInWindow.y - session.cursorOffset.y),
                from: nil
            )
            floating.frame = NSRect(
                x: round(centerInOverlay.x - 18.0),
                y: round(centerInOverlay.y - 18.0),
                width: 36.0,
                height: 36.0
            )
            overlay.addSubview(floating)
            floating.animateLiftIn()

            session.hasStartedDragging = true
            session.detachedButton = detached
            session.floatingView = floating
            session.landmarks = landmarks
            dragSession = session

            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            onLayoutNeedsUpdate?(false)
        }

        guard var active = dragSession,
              let landmarks = active.landmarks,
              let floating = active.floatingView else { return }

        // Free 2D tracking across the window
        let overlay = landmarks.overlayHostView
        let rawCenter = overlay.convert(
            NSPoint(x: ptInWindow.x - active.cursorOffset.x, y: ptInWindow.y - active.cursorOffset.y),
            from: nil
        )
        let clampedCenterX = max(20.0, min(overlay.bounds.width - 20.0, rawCenter.x))
        let clampedCenterY = max(20.0, min(overlay.bounds.height - 20.0, rawCenter.y))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        floating.frame.origin = NSPoint(
            x: round(clampedCenterX - floating.bounds.width * 0.5),
            y: round(clampedCenterY - floating.bounds.height * 0.5)
        )
        CATransaction.commit()

        let cursorInToolbar = landmarks.toolbarView.convert(ptInWindow, from: nil)
        let outside = isPointOutsideToolbar(cursorInToolbar, toolbarBounds: landmarks.toolbarView.bounds)

        if outside {
            if !active.isOutsideToolbar {
                active.isOutsideToolbar = true
                active.isRemovalArmed = false
                dragSession = active
                setPlaceholder(nil, in: active.currentZone, animated: true)
                onLayoutNeedsUpdate?(true)
                scheduleOutsideRemovalTimers(for: active.item.id)
            }
            return
        }

        if active.isOutsideToolbar {
            cancelOutsideRemovalTimers(in: &active)
            active.isOutsideToolbar = false
            active.isRemovalArmed = false
            NSCursor.arrow.set()
            floating.setMarkedForRemoval(false)
            let targetZone = resolveTargetZone(cursorX: cursorInToolbar.x, currentZone: active.currentZone, landmarks: landmarks)
            let targetIndex = insertionIndex(in: targetZone, atWindowPoint: ptInWindow, currentIndex: nil)
            active.currentZone = targetZone
            active.currentIndex = targetIndex
            dragSession = active
            setPlaceholder(targetIndex, in: targetZone, animated: true)
            onLayoutNeedsUpdate?(true)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return
        }

        let targetZone = resolveTargetZone(cursorX: cursorInToolbar.x, currentZone: active.currentZone, landmarks: landmarks)
        let targetIndex = insertionIndex(
            in: targetZone,
            atWindowPoint: ptInWindow,
            currentIndex: (targetZone == active.currentZone) ? active.currentIndex : nil
        )

        if targetZone != active.currentZone || targetIndex != active.currentIndex {
            let prevZone = active.currentZone
            active.currentZone = targetZone
            active.currentIndex = targetIndex
            dragSession = active

            if prevZone != targetZone {
                setPlaceholder(nil, in: prevZone, animated: true)
            }
            setPlaceholder(targetIndex, in: targetZone, animated: true)
            onLayoutNeedsUpdate?(true)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func endDrag(_ event: NSEvent) {
        guard var session = dragSession else { return }
        cancelOutsideRemovalTimers(in: &session)
        dragSession = nil
        NSCursor.arrow.set()

        if !session.hasStartedDragging {
            if let candidate = session.candidateButton {
                let ptInBtn = candidate.convert(event.locationInWindow, from: nil)
                if candidate.bounds.contains(ptInBtn) {
                    onClickExtension?(session.item, candidate)
                }
            }
            return
        }

        if session.isOutsideToolbar {
            if session.isRemovalArmed {
                performRemovalFromToolbar(session: session)
            } else {
                session.floatingView?.setMarkedForRemoval(false)
                setPlaceholder(session.originIndex, in: session.originZone, animated: true)
                onLayoutNeedsUpdate?(true)
                commitDrop(session: session, targetZone: session.originZone, targetIndex: session.originIndex)
            }
            return
        }

        commitDrop(session: session, targetZone: session.currentZone, targetIndex: session.currentIndex)
    }

    func cancelDrag() {
        guard var session = dragSession else { return }
        cancelOutsideRemovalTimers(in: &session)
        dragSession = nil
        NSCursor.arrow.set()
        guard session.hasStartedDragging else { return }

        session.floatingView?.setMarkedForRemoval(false)
        if session.currentZone != session.originZone {
            setPlaceholder(nil, in: session.currentZone, animated: true)
        }
        setPlaceholder(session.originIndex, in: session.originZone, animated: true)
        onLayoutNeedsUpdate?(true)
        commitDrop(session: session, targetZone: session.originZone, targetIndex: session.originIndex)
    }

    private func commitDrop(session: DragSession, targetZone: ExtensionToolbarZone, targetIndex: Int) {
        for zone in ExtensionToolbarZone.allCases where zone != targetZone {
            setPlaceholder(nil, in: zone, animated: true)
        }

        let btn = session.detachedButton ?? makeWiredExtensionButton(for: session.item)
        wireCallbacks(on: btn)
        btn.isHidden = true

        if targetZone.isMergedGroup, let grp = mergedGroups[targetZone] {
            grp.insertMergedExtensionButton(btn, atVisibleIndex: targetIndex)
        } else {
            let destCap = capsule(for: targetZone)
            destCap.insertDetachedButton(btn, at: targetIndex)
            destCap.apply(theme: currentTheme, animated: false)
        }

        persistLayout()
        onLayoutNeedsUpdate?(true)

        // Force layout so we read the exact settled destination rect in overlay coordinates
        session.landmarks?.overlayHostView.layoutSubtreeIfNeeded()

        guard let floating = session.floatingView,
              let overlay = session.landmarks?.overlayHostView else {
            btn.isHidden = false
            return
        }

        let destRectInOverlay: NSRect
        if targetZone.isMergedGroup, let grp = mergedGroups[targetZone],
           let r = grp.mergedExtensionRect(forExtensionID: session.item.id, in: overlay) {
            destRectInOverlay = r
        } else {
            destRectInOverlay = capsule(for: targetZone).slotRect(in: overlay, forIndex: targetIndex)
        }

        let targetOrigin = NSPoint(
            x: round(destRectInOverlay.midX - floating.bounds.width * 0.5),
            y: round(destRectInOverlay.midY - floating.bounds.height * 0.5)
        )

        let finish: () -> Void = { [weak btn, weak floating] in
            btn?.isHidden = false
            floating?.removeFromSuperview()
        }
        pendingDropCleanup = finish

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            floating.animator().frame.origin = targetOrigin
            floating.animateSettleOut(duration: 0.18)
        }, completionHandler: { [weak self] in
            if self?.pendingDropCleanup != nil {
                self?.pendingDropCleanup = nil
                finish()
            }
        })
    }

    private func flushPendingDropCleanup() {
        if let cleanup = pendingDropCleanup {
            pendingDropCleanup = nil
            cleanup()
        }
    }

    func resolveTargetZone(
        cursorX: CGFloat,
        currentZone: ExtensionToolbarZone,
        landmarks: ToolbarExtensionLandmarks
    ) -> ExtensionToolbarZone {
        let sidebarVisible = !landmarks.sidebarView.isHidden && landmarks.sidebarView.frame.width > 1.0
        let bfVisible = !landmarks.backForwardView.isHidden && landmarks.backForwardView.frame.width > 1.0
        let rightFrame = landmarks.rightActionsView.frame
        let addrMidX = landmarks.addressBarView.frame.midX

        // 1. Right Actions Group (`[Downloads | Share | + | Tab Overview]`):
        //    Merges directly inside this Liquid Glass pill whenever cursor is over it (all the way to right edge).
        let rightEnterX = (currentZone == .inRightActionsGroup) ? (rightFrame.minX - 8.0) : (rightFrame.minX - 2.0)
        if cursorX >= rightEnterX {
            return .inRightActionsGroup
        }

        // 2. Sidebar Group (`[Sidebar | ⌄]`):
        if sidebarVisible {
            let sbFrame = landmarks.sidebarView.frame
            let sbExitX = (currentZone == .inSidebarGroup) ? (sbFrame.maxX + 8.0) : (sbFrame.maxX - 2.0)
            if cursorX <= sbExitX {
                return .inSidebarGroup
            }
        }

        // 3. Back/Forward Group (`[ < | > ]`) & standalone `afterSidebar` zone between Sidebar and Back/Forward:
        if bfVisible {
            let bfFrame = landmarks.backForwardView.frame
            let bfLeftCut = (currentZone == .inBackForwardGroup) ? (bfFrame.minX - 8.0) : (bfFrame.minX + 2.0)
            let bfRightCut = (currentZone == .inBackForwardGroup) ? (bfFrame.maxX + 8.0) : (bfFrame.maxX - 2.0)
            if cursorX < bfLeftCut {
                return .afterSidebar
            }
            if cursorX <= bfRightCut {
                return .inBackForwardGroup
            }
        }

        // 4. Standalone Left-of-Address-Bar vs Right-of-Address-Bar capsules (6pt hysteresis across address midpoint)
        let h: CGFloat = 6.0
        let addrCut = (currentZone == .rightOfAddressBar || currentZone == .inRightActionsGroup || currentZone == .trailing)
            ? (addrMidX - h)
            : (addrMidX + h)
        return cursorX < addrCut ? .leftOfAddressBar : .rightOfAddressBar
    }
}

/// Native macOS 27.3 Liquid Glass Extensions toolbar capsule (`36 pt` tall, `cornerRadius = 18 pt`),
/// representing one standalone placement zone on the toolbar (automatically hidden at width `0` when empty).
final class ExtensionsToolbarCapsuleView: NSView {
    let zone: ExtensionToolbarZone
    var onClickExtension: ((BrowserExtensionItem, NSView) -> Void)?
    var onManageExtension: ((BrowserExtensionItem, NSView) -> Void)?
    var onRemoveExtension: ((String) -> Void)?
    var onOpenChromeWebStore: (() -> Void)?
    var onCustomizeToolbar: (() -> Void)?
    var contextMenuProvider: ((String) -> [BrowserExtensionContextMenuItem])?
    var onTriggerContextMenuItem: ((String, String) -> Void)?

    private let glassView: NSView
    private let iconsHostView = FlippedExtensionsHostView()
    private var iconButtons: [ExtensionToolbarIconButton] = []
    private(set) var extensions: [BrowserExtensionItem] = []
    private(set) var placeholderIndex: Int?
    private var isDarkMode: Bool = false

    private let slotWidth: CGFloat = 32.0
    private let horizontalPadding: CGFloat = 4.0

    var requiredWidth: CGFloat {
        let totalSlots = iconButtons.count + (placeholderIndex != nil ? 1 : 0)
        guard totalSlots > 0 else { return 0.0 }
        return horizontalPadding * 2.0 + CGFloat(totalSlots) * slotWidth
    }

    override var mouseDownCanMoveWindow: Bool { false }

    init(zone: ExtensionToolbarZone = .leftOfAddressBar) {
        self.zone = zone
        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .regular
            gv.cornerRadius = SafariMetrics.glassButtonCornerRadius
            self.glassView = gv
        } else {
            let vev = NSVisualEffectView()
            vev.material = .hudWindow
            vev.blendingMode = .withinWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = SafariMetrics.glassButtonCornerRadius
            vev.layer?.cornerCurve = .continuous
            vev.layer?.masksToBounds = true
            self.glassView = vev
        }
        super.init(frame: .zero)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true

        glassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        iconsHostView.translatesAutoresizingMaskIntoConstraints = false
        iconsHostView.wantsLayer = true
        iconsHostView.layer?.masksToBounds = false
        // Place iconsHostView as an unclipped sibling ABOVE glassView so top-right notification badges
        // (e.g. Bitwarden's red "5" circle) never clip against NSGlassEffectView's 18pt corner mask.
        addSubview(iconsHostView)
        NSLayoutConstraint.activate([
            iconsHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconsHostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconsHostView.topAnchor.constraint(equalTo: topAnchor),
            iconsHostView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        layoutButtons(animated: false)
    }

    fileprivate func makeButton(for item: BrowserExtensionItem) -> ExtensionToolbarIconButton {
        let btn = ExtensionToolbarIconButton(item: item, isDark: isDarkMode)
        wireButtonCallbacks(btn)
        return btn
    }

    private func wireButtonCallbacks(_ btn: ExtensionToolbarIconButton) {
        let extID = btn.item.id
        btn.onLeftClick = { [weak self, weak btn] in
            guard let self, let btn else { return }
            self.onClickExtension?(btn.item, btn)
        }
        btn.onManage = { [weak self, weak btn] in
            guard let self, let btn else { return }
            self.onManageExtension?(btn.item, btn)
        }
        btn.onRemove = { [weak self] in
            self?.onRemoveExtension?(extID)
        }
        btn.onOpenStore = { [weak self] in
            self?.onOpenChromeWebStore?()
        }
        btn.onCustomizeToolbar = { [weak self] in
            self?.onCustomizeToolbar?()
        }
        btn.contextMenuProvider = { [weak self] in
            self?.contextMenuProvider?(extID) ?? []
        }
        btn.onTriggerContextMenuItem = { [weak self] menuItemID in
            self?.onTriggerContextMenuItem?(extID, menuItemID)
        }
    }

    func setCustomizeJiggle(_ active: Bool, basePhase: Double = 0.0) {
        for (idx, btn) in iconButtons.enumerated() {
            btn.setCustomizeWiggle(active, phase: basePhase + Double(idx) * 0.14)
        }
    }

    func update(extensions newExtensions: [BrowserExtensionItem]) {
        if placeholderIndex == nil,
           iconButtons.count == newExtensions.count,
           zip(iconButtons, newExtensions).allSatisfy({ $0.0.item.id == $0.1.id }) {
            self.extensions = newExtensions
            for (btn, item) in zip(iconButtons, newExtensions) {
                btn.update(item: item)
            }
            syncHiddenState()
            return
        }

        placeholderIndex = nil
        self.extensions = newExtensions

        for btn in iconButtons {
            btn.removeFromSuperview()
        }
        iconButtons.removeAll()

        for item in newExtensions {
            let btn = makeButton(for: item)
            iconsHostView.addSubview(btn)
            iconButtons.append(btn)
        }

        syncHiddenState()
        layoutButtons(animated: false)
    }

    private func syncHiddenState() {
        let totalSlots = iconButtons.count + (placeholderIndex != nil ? 1 : 0)
        isHidden = (totalSlots == 0)
    }

    func slotFrame(forIndex index: Int) -> NSRect {
        NSRect(
            x: horizontalPadding + CGFloat(index) * slotWidth,
            y: 0,
            width: slotWidth,
            height: SafariMetrics.glassButtonSize
        )
    }

    private func layoutButtons(animated: Bool) {
        let pIdx = placeholderIndex
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (idx, btn) in iconButtons.enumerated() {
                    let visualSlot = (pIdx != nil && idx >= pIdx!) ? (idx + 1) : idx
                    btn.animator().frame = slotFrame(forIndex: visualSlot)
                }
            }
        } else {
            for (idx, btn) in iconButtons.enumerated() {
                let visualSlot = (pIdx != nil && idx >= pIdx!) ? (idx + 1) : idx
                btn.frame = slotFrame(forIndex: visualSlot)
            }
        }
    }

    func hitButton(atWindowPoint ptInWindow: NSPoint) -> (button: ExtensionToolbarIconButton, index: Int)? {
        guard !isHidden, !iconButtons.isEmpty else { return nil }
        let ptInSelf = convert(ptInWindow, from: nil)
        guard bounds.contains(ptInSelf) else { return nil }
        let idx = max(0, min(iconButtons.count - 1, Int(floor((ptInSelf.x - horizontalPadding) / slotWidth))))
        return (iconButtons[idx], idx)
    }

    func detachButton(at index: Int) -> ExtensionToolbarIconButton? {
        guard iconButtons.indices.contains(index), extensions.indices.contains(index) else { return nil }
        let btn = iconButtons.remove(at: index)
        extensions.remove(at: index)
        btn.removeFromSuperview()
        syncHiddenState()
        return btn
    }

    func insertDetachedButton(_ button: ExtensionToolbarIconButton, at rawIndex: Int) {
        let clamped = max(0, min(iconButtons.count, rawIndex))
        placeholderIndex = nil
        button.translatesAutoresizingMaskIntoConstraints = true
        wireButtonCallbacks(button)
        iconsHostView.addSubview(button)
        iconButtons.insert(button, at: clamped)
        extensions.insert(button.item, at: clamped)
        syncHiddenState()
        layoutButtons(animated: false)
    }

    func setPlaceholderIndex(_ index: Int?, animated: Bool) {
        let clamped = index.map { max(0, min(iconButtons.count, $0)) }
        guard placeholderIndex != clamped else { return }
        placeholderIndex = clamped
        syncHiddenState()
        layoutButtons(animated: animated)
    }

    func insertionIndex(forWindowPoint ptInWindow: NSPoint, currentIndex: Int?) -> Int {
        let count = iconButtons.count
        guard count > 0 else { return 0 }
        let ptInHost = iconsHostView.convert(ptInWindow, from: nil)
        let localX = ptInHost.x - horizontalPadding

        if let cur = currentIndex {
            let curSlot = slotFrame(forIndex: cur)
            if cur > 0 && ptInHost.x < curSlot.minX - 3.0 {
                let candidate = max(0, min(count, Int(floor(localX / slotWidth))))
                return min(cur - 1, candidate)
            }
            if cur < count && ptInHost.x > curSlot.maxX + 3.0 {
                let candidate = max(0, min(count, Int(floor(localX / slotWidth))))
                return max(cur + 1, candidate)
            }
            return cur
        }

        let raw = Int(round((localX - slotWidth * 0.5) / slotWidth))
        return max(0, min(count, raw))
    }

    func slotRect(in overlay: NSView, forIndex index: Int) -> NSRect {
        let local = slotFrame(forIndex: index)
        return iconsHostView.convert(local, to: overlay)
    }

    func apply(theme: AdaptiveChromeTheme, animated: Bool) {
        self.isDarkMode = theme.prefersLightInk
        let appearanceName: NSAppearance.Name = theme.prefersLightInk ? .darkAqua : .aqua
        glassView.appearance = NSAppearance(named: appearanceName)
        if #available(macOS 26.0, *), let gv = glassView as? NSGlassEffectView {
            gv.tintColor = theme.glassTintColor
        }
        for btn in iconButtons {
            btn.applyDarkMode(isDarkMode)
        }
    }

    func anchorButton(forExtensionID id: String) -> NSView? {
        iconButtons.first(where: { $0.item.id == id })
    }
}

// MARK: - Bare Floating Icon While Dragging Freely Across Toolbar (No Background Pill)

private final class FloatingDraggedExtensionView: NSView {
    private let iconImageView = NSImageView()
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let item: BrowserExtensionItem
    private var isDarkMode: Bool = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(item: BrowserExtensionItem, theme: AdaptiveChromeTheme) {
        self.item = item
        self.isDarkMode = theme.prefersLightInk
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        setup()
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 500

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerRadius = 4.0
        iconImageView.layer?.cornerCurve = .continuous
        iconImageView.layer?.masksToBounds = true
        if let icon = item.icon {
            iconImageView.image = icon
        } else {
            iconImageView.image = AssetLoader.shared.symbol(named: "puzzlepiece.extension.fill", pointSize: 15.0, weight: .regular)
        }
        addSubview(iconImageView)

        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 6.5
        badgeContainer.layer?.cornerCurve = .continuous
        badgeContainer.layer?.masksToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeContainer.addSubview(badgeLabel)
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            badgeContainer.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            badgeContainer.heightAnchor.constraint(equalToConstant: 13),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 13),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 3),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -3),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor)
        ])

        if let text = item.badgeText, !text.isEmpty {
            badgeLabel.stringValue = text
            badgeContainer.layer?.backgroundColor = (item.badgeColor ?? NSColor.systemRed).cgColor
            badgeContainer.isHidden = false
        } else {
            badgeContainer.isHidden = true
        }
    }

    func apply(theme: AdaptiveChromeTheme) {
        isDarkMode = theme.prefersLightInk
        if item.icon == nil {
            iconImageView.contentTintColor = isDarkMode ? .white : NSColor(white: 0.16, alpha: 1.0)
        }
    }

    private func centeredScaleTransform(_ scale: CGFloat) -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1.0)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    func animateLiftIn() {
        guard let layer else { return }
        let t = centeredScaleTransform(1.12)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = CATransform3DIdentity
        anim.toValue = t
        anim.duration = 0.14
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = t
        layer.add(anim, forKey: "liftScale")
    }

    func setMarkedForRemoval(_ marked: Bool) {
        guard let layer else { return }
        let targetTransform = centeredScaleTransform(marked ? 0.90 : 1.12)
        let targetOpacity: Float = marked ? 0.62 : 1.0

        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = layer.presentation()?.transform ?? layer.transform
        scaleAnim.toValue = targetTransform
        scaleAnim.duration = 0.14
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = targetTransform
        layer.add(scaleAnim, forKey: "removeCueScale")

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fadeAnim.toValue = targetOpacity
        fadeAnim.duration = 0.14
        layer.opacity = targetOpacity
        layer.add(fadeAnim, forKey: "removeCueOpacity")
    }

    func animateRemovePoof(completion: @escaping () -> Void) {
        guard let layer else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)

        let targetTransform = centeredScaleTransform(0.25)
        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = layer.presentation()?.transform ?? layer.transform
        scaleAnim.toValue = targetTransform
        scaleAnim.duration = 0.16
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.transform = targetTransform
        layer.add(scaleAnim, forKey: "poofScale")

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fadeAnim.toValue = Float(0.0)
        fadeAnim.duration = 0.16
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0.0
        layer.add(fadeAnim, forKey: "poofOpacity")

        CATransaction.commit()
    }

    func animateSettleOut(duration: CFTimeInterval) {
        guard let layer else { return }
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer.presentation()?.transform ?? layer.transform
        anim.toValue = CATransform3DIdentity
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = CATransform3DIdentity
        layer.add(anim, forKey: "settleScale")

        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fadeAnim.toValue = Float(1.0)
        fadeAnim.duration = duration
        layer.opacity = 1.0
        layer.add(fadeAnim, forKey: "settleOpacity")
    }
}

// MARK: - Extension Icon Slot + Top-Right Count Badge + Native macOS Context Menu

private final class FlippedExtensionsHostView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ExtensionToolbarIconButton: NSView {
    private(set) var item: BrowserExtensionItem
    var onLeftClick: (() -> Void)?
    var onManage: (() -> Void)?
    var onRemove: (() -> Void)?
    var onOpenStore: (() -> Void)?
    var onCustomizeToolbar: (() -> Void)?
    var contextMenuProvider: (() -> [BrowserExtensionContextMenuItem])?
    var onTriggerContextMenuItem: ((String) -> Void)?

    private let hoverCircleLayer = CALayer()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPopupActive = false
    private let iconImageView = NSImageView()
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var isDarkMode: Bool
    private var isTrackingLeftClick = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sup = superview else { return nil }
        let local = convert(point, from: sup)
        return bounds.contains(local) ? self : nil
    }

    init(item: BrowserExtensionItem, isDark: Bool) {
        self.item = item
        self.isDarkMode = isDark
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        hoverCircleLayer.cornerRadius = 14.0
        hoverCircleLayer.cornerCurve = .continuous
        hoverCircleLayer.backgroundColor = NSColor.clear.cgColor
        hoverCircleLayer.zPosition = -1
        layer?.addSublayer(hoverCircleLayer)
        toolTip = "\(item.name) (Drag to move)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)
        setAccessibilityIdentifier("extension-\(item.id)")

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerRadius = 4.0
        iconImageView.layer?.cornerCurve = .continuous
        iconImageView.layer?.masksToBounds = true
        if let icon = item.icon {
            iconImageView.image = icon
            iconImageView.contentTintColor = nil
        } else {
            iconImageView.image = AssetLoader.shared.symbol(named: "puzzlepiece.extension.fill", pointSize: 15.0, weight: .regular)
            iconImageView.contentTintColor = isDarkMode ? .white : NSColor(white: 0.16, alpha: 1.0)
        }
        addSubview(iconImageView)

        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 7.5
        badgeContainer.layer?.cornerCurve = .continuous
        badgeContainer.layer?.masksToBounds = true
        badgeContainer.layer?.zPosition = 20

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeContainer.addSubview(badgeLabel)
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            // Match Safari Tahoe's exact top-right red notification dot perched on the icon shoulder
            badgeContainer.centerXAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 1.5),
            badgeContainer.centerYAnchor.constraint(equalTo: iconImageView.topAnchor, constant: -1.5),
            badgeContainer.heightAnchor.constraint(equalToConstant: 15),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 15),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 3.5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -3.5),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor)
        ])

        if let text = item.badgeText, !text.isEmpty {
            badgeLabel.stringValue = text
            // Native macOS Safari always renders extension notification badges in Safari notification red (#EE3E38)
            badgeContainer.layer?.backgroundColor = NSColor(srgbRed: 0.933, green: 0.243, blue: 0.220, alpha: 1.0).cgColor
            badgeContainer.isHidden = false
        } else {
            badgeContainer.isHidden = true
        }
    }

    /// Updates icon, badge, and accessibility metadata in place without tearing down the view or triggering animations.
    func update(item newItem: BrowserExtensionItem) {
        let prev = self.item
        self.item = newItem

        if newItem.name != prev.name {
            toolTip = "\(newItem.name) (Drag to move)"
            setAccessibilityLabel(newItem.name)
        }

        if newItem.icon !== prev.icon {
            if let icon = newItem.icon {
                iconImageView.image = icon
                iconImageView.contentTintColor = nil
            } else {
                iconImageView.image = AssetLoader.shared.symbol(named: "puzzlepiece.extension.fill", pointSize: 15.0, weight: .regular)
                iconImageView.contentTintColor = isDarkMode ? .white : NSColor(white: 0.16, alpha: 1.0)
            }
        }

        let newText = (newItem.badgeText?.isEmpty == false) ? newItem.badgeText : nil
        let oldText = (prev.badgeText?.isEmpty == false) ? prev.badgeText : nil
        if newText != oldText {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let text = newText {
                badgeLabel.stringValue = text
                badgeContainer.layer?.backgroundColor = (newItem.badgeColor ?? NSColor(srgbRed: 0.933, green: 0.243, blue: 0.220, alpha: 1.0)).cgColor
                badgeContainer.isHidden = false
            } else {
                badgeLabel.stringValue = ""
                badgeContainer.isHidden = true
            }
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let d: CGFloat = min(28.0, min(bounds.width, bounds.height) - 4.0)
        hoverCircleLayer.frame = CGRect(
            x: ((bounds.width - d) / 2.0).rounded(),
            y: ((bounds.height - d) / 2.0).rounded(),
            width: d,
            height: d
        )
        hoverCircleLayer.cornerRadius = d / 2.0
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    private var currentHoverColor: CGColor {
        let alpha: CGFloat = isPopupActive
            ? (isDarkMode ? 0.18 : 0.10)
            : (isDarkMode ? 0.12 : 0.06)
        return (isDarkMode
            ? NSColor.white.withAlphaComponent(alpha)
            : NSColor.black.withAlphaComponent(alpha)).cgColor
    }

    private func syncHighlightLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverCircleLayer.backgroundColor = (isHovered || isPopupActive) ? currentHoverColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    func setPopupActive(_ active: Bool) {
        guard isPopupActive != active else { return }
        isPopupActive = active
        toolTip = active ? nil : "\(item.name) (Drag to move)"
        syncHighlightLayer()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        syncHighlightLayer()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        syncHighlightLayer()
    }

    func applyDarkMode(_ dark: Bool) {
        self.isDarkMode = dark
        syncHighlightLayer()
        if item.icon == nil {
            iconImageView.contentTintColor = dark ? .white : NSColor(white: 0.16, alpha: 1.0)
        }
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingLeftClick = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFireClick = isTrackingLeftClick
        isTrackingLeftClick = false
        if shouldFireClick && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onLeftClick?()
        }
    }

    // Native macOS right-click context menu matching Safari:
    //   <Extension Name> >  (live chrome.contextMenus hierarchy)
    //   ---
    //   Manage Extension…
    //   ---
    //   Customize Toolbar…
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: item.name)
        menu.autoenablesItems = false

        let extSub = NSMenu(title: item.name)
        extSub.autoenablesItems = false

        let liveItems = contextMenuProvider?() ?? []
        if !liveItems.isEmpty {
            populateSubmenu(extSub, with: liveItems)
        } else {
            let openItem = NSMenuItem(title: "Open \(item.name)", action: #selector(ctxOpenPopup), keyEquivalent: "")
            openItem.target = self
            extSub.addItem(openItem)
            extSub.addItem(.separator())
            let versionItem = NSMenuItem(title: "Version \(item.version.isEmpty ? "1.0" : item.version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            extSub.addItem(versionItem)
        }

        let nameItem = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
        nameItem.submenu = extSub
        menu.addItem(nameItem)

        menu.addItem(.separator())

        let manageItem = NSMenuItem(title: "Manage Extension…", action: #selector(ctxManage), keyEquivalent: "")
        manageItem.target = self
        menu.addItem(manageItem)

        menu.addItem(.separator())

        let customizeItem = NSMenuItem(title: "Customize Toolbar…", action: #selector(ctxCustomizeToolbar), keyEquivalent: "")
        customizeItem.target = self
        menu.addItem(customizeItem)

        return menu
    }

    private func populateSubmenu(_ menu: NSMenu, with nodes: [BrowserExtensionContextMenuItem]) {
        for node in nodes {
            if node.isSeparator {
                if !menu.items.isEmpty && !(menu.items.last?.isSeparatorItem ?? false) {
                    menu.addItem(.separator())
                }
                continue
            }
            if !node.children.isEmpty {
                let sub = NSMenu(title: node.title)
                sub.autoenablesItems = false
                populateSubmenu(sub, with: node.children)
                let parentMenuItem = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                parentMenuItem.isEnabled = node.isEnabled
                parentMenuItem.submenu = sub
                menu.addItem(parentMenuItem)
            } else {
                let leaf = NSMenuItem(title: node.title, action: #selector(ctxExtensionMenuItemClicked(_:)), keyEquivalent: "")
                leaf.target = self
                leaf.representedObject = node.id
                leaf.isEnabled = node.isEnabled
                leaf.state = node.isChecked ? .on : .off
                menu.addItem(leaf)
            }
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }

    func setCustomizeWiggle(_ active: Bool, phase: Double = 0.0) {
        wantsLayer = true
        guard let layer else { return }
        layer.removeAnimation(forKey: "sxCustomizeWiggleX")
        guard active else { return }

        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0.0, -1.7, 1.7, 0.0]
        anim.keyTimes = [0.0, 0.25, 0.75, 1.0]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        anim.duration = 0.72
        anim.timeOffset = phase
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "sxCustomizeWiggleX")
    }

    @objc private func ctxOpenPopup() { onLeftClick?() }
    @objc private func ctxManage() { onManage?() }
    @objc private func ctxRemove() { onRemove?() }
    @objc private func ctxOpenStore() { onOpenStore?() }
    @objc private func ctxCustomizeToolbar() { onCustomizeToolbar?() }

    @objc private func ctxExtensionMenuItemClicked(_ sender: NSMenuItem) {
        guard let menuItemID = sender.representedObject as? String, !menuItemID.isEmpty else { return }
        onTriggerContextMenuItem?(menuItemID)
    }
}

// MARK: - Native macOS 27 Tahoe Extension Popup & Manage Extensions Controller

/// Generates macOS 27 Tahoe's exact extension popover bubble silhouette (22pt continuous rounded body
/// + smooth S-curved top caret centered at `anchorX`, in non-flipped AppKit coordinates where y = 0 is bottom).
enum ExtensionBubbleGeometry {
    static let cornerRadius: CGFloat = 22.0
    static let arrowHeight: CGFloat = 11.0
    static let arrowHalfWidth: CGFloat = 13.5

    static func clampedAnchorX(_ anchorX: CGFloat, width: CGFloat) -> CGFloat {
        let minX = cornerRadius + arrowHalfWidth + 4.0
        let maxX = max(minX, width - cornerRadius - arrowHalfWidth - 4.0)
        return max(minX, min(maxX, anchorX))
    }

    static func makeBubblePath(size: NSSize, anchorX: CGFloat, inset: CGFloat = 0.0) -> CGPath {
        let w = size.width
        let h = size.height
        let bodyTop = max(cornerRadius * 2.0, h - arrowHeight) - inset
        let left = inset
        let right = w - inset
        let bottom = inset
        let r = max(4.0, cornerRadius - inset)
        let ax = clampedAnchorX(anchorX, width: w)
        let hw = arrowHalfWidth
        let tipY = h - inset

        let p = CGMutablePath()
        // Bottom-left -> Bottom-right
        p.move(to: CGPoint(x: left + r, y: bottom))
        p.addLine(to: CGPoint(x: right - r, y: bottom))
        p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom + r), radius: r)

        // Right edge -> Top-right corner
        p.addLine(to: CGPoint(x: right, y: bodyTop - r))
        p.addArc(tangent1End: CGPoint(x: right, y: bodyTop), tangent2End: CGPoint(x: right - r, y: bodyTop), radius: r)

        // Top edge right of caret -> Smooth S-curved top caret
        p.addLine(to: CGPoint(x: ax + hw, y: bodyTop))
        p.addCurve(
            to: CGPoint(x: ax + 2.3, y: tipY - 1.3),
            control1: CGPoint(x: ax + hw * 0.56, y: bodyTop),
            control2: CGPoint(x: ax + 5.2, y: tipY - 3.8)
        )
        p.addCurve(
            to: CGPoint(x: ax - 2.3, y: tipY - 1.3),
            control1: CGPoint(x: ax + 0.85, y: tipY + 0.35),
            control2: CGPoint(x: ax - 0.85, y: tipY + 0.35)
        )
        p.addCurve(
            to: CGPoint(x: ax - hw, y: bodyTop),
            control1: CGPoint(x: ax - 5.2, y: tipY - 3.8),
            control2: CGPoint(x: ax - hw * 0.56, y: bodyTop)
        )

        // Top edge left of caret -> Top-left corner -> Left edge -> Bottom-left corner
        p.addLine(to: CGPoint(x: left + r, y: bodyTop))
        p.addArc(tangent1End: CGPoint(x: left, y: bodyTop), tangent2End: CGPoint(x: left, y: bodyTop - r), radius: r)
        p.addLine(to: CGPoint(x: left, y: bottom + r))
        p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + r, y: bottom), radius: r)
        p.closeSubpath()
        return p
    }

    static func makeMaskImage(size: NSSize, anchorX: CGFloat) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.clear(rect)
            ctx.addPath(makeBubblePath(size: rect.size, anchorX: anchorX, inset: 0.0))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        return img
    }
}

/// Single-window key-capable borderless floating NSPanel hosting Chromium's `RenderWidgetHostViewCocoa`
/// inside macOS 27 Tahoe's curved-caret popover bubble (`22 pt` corners + `11 pt` top caret).
private final class ExtensionPopupPanel: NSPanel {
    var onCancelRequested: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancelRequested?()
    }
}

/// Translucent curved-caret Liquid Glass backdrop drawn behind Chromium so extensions without
/// an opaque CSS background inherit native macOS 27 behind-window frosted glass (matching Safari).
private final class ExtensionBubbleFillView: NSView {
    var isDark: Bool = false { didSet { updatePathAndColors() } }
    var anchorX: CGFloat = 190.0 { didSet { updatePathAndColors() } }

    private let visualEffectView = NSVisualEffectView()
    private let maskLayer = CAShapeLayer()
    private let tintLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.mask = maskLayer

        visualEffectView.frame = bounds
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        addSubview(visualEffectView)

        layer?.addSublayer(tintLayer)
        updatePathAndColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updatePathAndColors()
    }

    func updatePathAndColors() {
        guard bounds.width > 2, bounds.height > 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = ExtensionBubbleGeometry.makeBubblePath(size: bounds.size, anchorX: anchorX, inset: 0.0)
        maskLayer.frame = bounds
        maskLayer.path = path

        visualEffectView.frame = bounds
        visualEffectView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        visualEffectView.maskImage = ExtensionBubbleGeometry.makeMaskImage(size: bounds.size, anchorX: anchorX)

        tintLayer.frame = bounds
        tintLayer.path = path
        tintLayer.fillColor = (isDark
            ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.80)
            : NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 0.80)).cgColor
        CATransaction.commit()
    }
}

/// Non-interactive continuous 0.5pt hairline rim tracing both the 22pt rounded body and curved top caret.
private final class ExtensionBubbleRimView: NSView {
    var isDark: Bool = false { didSet { updateStyle() } }
    var anchorX: CGFloat = 190.0 { didSet { updateStyle() } }

    private let strokeLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = 0.65
        highlightLayer.fillColor = nil
        highlightLayer.lineWidth = 0.65
        layer?.addSublayer(highlightLayer)
        layer?.addSublayer(strokeLayer)
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateStyle()
    }

    func updateStyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.frame = bounds
        strokeLayer.path = ExtensionBubbleGeometry.makeBubblePath(size: bounds.size, anchorX: anchorX, inset: 0.35)
        strokeLayer.strokeColor = (isDark
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor.black.withAlphaComponent(0.14)).cgColor

        highlightLayer.frame = bounds
        highlightLayer.path = ExtensionBubbleGeometry.makeBubblePath(size: bounds.size, anchorX: anchorX, inset: 1.0)
        highlightLayer.strokeColor = (isDark
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.white.withAlphaComponent(0.55)).cgColor
        CATransaction.commit()
    }
}

final class ExtensionPopoverController: NSObject, NSPopoverDelegate {
    var onCloseExtensionPopup: ((String) -> Void)?
    var onLoadUnpackedRequested: (() -> Void)?
    var onInstallCRXRequested: (() -> Void)?
    var onOpenChromeWebStore: (() -> Void)?
    var onRemoveExtension: ((String) -> Void)?
    var onToggleToolbarPin: ((String, Bool) -> Void)?

    private static let popupPreferredSizeNotification = Notification.Name("SXExtensionPopupPreferredSizeDidChangeNotification")
    private static let popupShouldCloseNotification = Notification.Name("SXExtensionPopupShouldCloseNotification")
    private static let persistedSizesDefaultsKey = "Safarium.ExtensionPopupSizes.v1"
    private static let bubbleCornerRadius: CGFloat = ExtensionBubbleGeometry.cornerRadius
    private static let arrowHeight: CGFloat = ExtensionBubbleGeometry.arrowHeight
    /// Transparent pad around the bubble inside the borderless NSPanel so spring overshoot never clips at panel edges.
    private static let springBleedPad: CGFloat = 18.0
    private static let openDuration: CFTimeInterval = 0.240
    private static let revealStartDelay: CFTimeInterval = 0.115
    private static let revealCrossfadeDuration: CFTimeInterval = 0.080
    private static let preloadMaxWaitDuration: CFTimeInterval = 0.340
    private static let closeDuration: CFTimeInterval = 0.155

    // Pure AppKit NSPopover (Manage Extensions / non-HTML fallback)
    private var activePopover: NSPopover?
    private var isManagePopover: Bool = false

    // Single-window NSPanel for live Chromium `chrome-extension://` popups
    private var activePanel: ExtensionPopupPanel?
    private weak var activeParentWindow: NSWindow?
    private weak var activeAnchorView: NSView?
    private weak var activeStageView: NSView?
    private weak var activeBloomShellView: NSView?
    private weak var activeBloomGlassView: NSVisualEffectView?
    private weak var activeBloomMaskLayer: CAShapeLayer?
    private weak var activeBloomTintLayer: CAShapeLayer?
    private weak var activeBloomRimView: ExtensionBubbleRimView?
    private weak var activeFillView: ExtensionBubbleFillView?
    private weak var activePopupContainer: NSView?
    private weak var activeRimView: ExtensionBubbleRimView?
    private var activeExtensionID: String?
    private var activeContentSize: NSSize = NSSize(width: 380, height: 520)
    private var activeAnchorXInPanel: CGFloat = 190.0
    private var activeIsDark: Bool = false

    private var isPreloadingBeforeBloom: Bool = false
    private var isOpeningBloomActive: Bool = false
    private var hasStartedVisibleBloom: Bool = false
    private var pendingPreloadSafetyWork: DispatchWorkItem?
    private var pendingRevealWork: DispatchWorkItem?
    private var pendingShadowWork: DispatchWorkItem?
    private var pendingFinishWork: DispatchWorkItem?
    private var pendingCloseTeardownWork: DispatchWorkItem?
    private var pendingCloseTeardown: (() -> Void)?
    private var deferredResizeSize: NSSize?

    static func cachedPopupSize(for extensionID: String) -> NSSize {
        guard let dict = UserDefaults.standard.dictionary(forKey: persistedSizesDefaultsKey) as? [String: [Double]],
              let pair = dict[extensionID.lowercased()],
              pair.count == 2,
              pair[0] >= 240, pair[1] >= 120 else {
            return NSSize(width: 380, height: 520)
        }
        return NSSize(width: round(min(600, pair[0])), height: round(min(600, pair[1])))
    }

    static func savePopupSize(_ size: NSSize, for extensionID: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: persistedSizesDefaultsKey) as? [String: [Double]]) ?? [:]
        dict[extensionID.lowercased()] = [Double(round(size.width)), Double(round(size.height))]
        UserDefaults.standard.set(dict, forKey: persistedSizesDefaultsKey)
    }

    private var popupSizeObserver: NSObjectProtocol?
    private var popupCloseObserver: NSObjectProtocol?
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var panelResignKeyObserver: NSObjectProtocol?
    private var parentResignMainObserver: NSObjectProtocol?
    private var parentMiniaturizeObserver: NSObjectProtocol?
    private var parentWillCloseObserver: NSObjectProtocol?

    deinit {
        removeDismissMonitors()
        if let popupSizeObserver {
            NotificationCenter.default.removeObserver(popupSizeObserver)
        }
        if let popupCloseObserver {
            NotificationCenter.default.removeObserver(popupCloseObserver)
        }
    }

    private func removeDismissMonitors() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let panelResignKeyObserver {
            NotificationCenter.default.removeObserver(panelResignKeyObserver)
            self.panelResignKeyObserver = nil
        }
        if let parentResignMainObserver {
            NotificationCenter.default.removeObserver(parentResignMainObserver)
            self.parentResignMainObserver = nil
        }
        if let parentMiniaturizeObserver {
            NotificationCenter.default.removeObserver(parentMiniaturizeObserver)
            self.parentMiniaturizeObserver = nil
        }
        if let parentWillCloseObserver {
            NotificationCenter.default.removeObserver(parentWillCloseObserver)
            self.parentWillCloseObserver = nil
        }
    }

    private func cancelPendingBloomTimers() {
        pendingPreloadSafetyWork?.cancel()
        pendingPreloadSafetyWork = nil
        pendingRevealWork?.cancel()
        pendingRevealWork = nil
        pendingShadowWork?.cancel()
        pendingShadowWork = nil
        pendingFinishWork?.cancel()
        pendingFinishWork = nil
        isPreloadingBeforeBloom = false
        isOpeningBloomActive = false
        hasStartedVisibleBloom = false
        deferredResizeSize = nil
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.activePanel, panel.isVisible else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape
                    self.closeActivePopover(animated: true)
                    return nil
                }
                let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if mods.contains(.command) {
                    let ch = (event.charactersIgnoringModifiers ?? "").lowercased()
                    let isTabNumber = (mods == .command) && ((Int(ch).map { (1...9).contains($0) } ?? false) || [18, 19, 20, 21, 23, 22, 26, 28, 25].contains(event.keyCode))
                    let isWindowOpeningShortcut = (mods == .command && (ch == "," || ch == "n" || ch == "q" || ch == "h"))
                        || (mods == [.command, .shift] && ch == "n")
                    let isBrowserCommand = isTabNumber || isWindowOpeningShortcut
                        || (mods == .command && ["l", "t", "w", "s", "o", "f", "r"].contains(ch))
                        || (mods == [.command, .shift] && ["t", "w", "[" , "]"].contains(ch))
                        || (mods == [.command, .option] && (event.keyCode == 123 || event.keyCode == 124 || ch == "f"))
                    if isBrowserCommand {
                        self.closeActivePopover(animated: false, restoreParentKey: !isWindowOpeningShortcut)
                    }
                }
                return event
            }
            if event.window === panel {
                return event
            }
            if let anchor = self.activeAnchorView,
               let anchorWin = anchor.window,
               event.window === anchorWin {
                let pt = anchor.convert(event.locationInWindow, from: nil)
                if anchor.bounds.contains(pt) {
                    if event.type == .leftMouseDown {
                        self.closeActivePopover(animated: true)
                        return nil
                    }
                    return event
                }
            }
            self.closeActivePopover(animated: true, restoreParentKey: false)
            return event
        }
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeActivePopover(animated: true, restoreParentKey: false)
            }
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closeActivePopover(animated: false, restoreParentKey: false)
        }
        if let panel = activePanel {
            panelResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self, weak panel] _ in
                DispatchQueue.main.async { [weak self, weak panel] in
                    guard let self,
                          let panel,
                          self.activePanel === panel,
                          !self.isPreloadingBeforeBloom,
                          !self.isOpeningBloomActive,
                          !panel.isKeyWindow else { return }
                    self.closeActivePopover(animated: false, restoreParentKey: false)
                }
            }
        }
        if let parentWin = activeParentWindow {
            parentResignMainObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignMainNotification,
                object: parentWin,
                queue: .main
            ) { [weak self] _ in
                self?.closeActivePopover(animated: false, restoreParentKey: false)
            }
            parentMiniaturizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: parentWin,
                queue: .main
            ) { [weak self] _ in
                self?.closeActivePopover(animated: false, restoreParentKey: false)
            }
            parentWillCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: parentWin,
                queue: .main
            ) { [weak self] _ in
                self?.closeActivePopover(animated: false, restoreParentKey: false)
            }
        }
    }

    private func findRenderWidgetHostView(in root: NSView?) -> NSView? {
        guard let root else { return nil }
        for sub in root.subviews {
            if NSStringFromClass(type(of: sub)).contains("RenderWidgetHostView") {
                return sub
            }
            if let nested = findRenderWidgetHostView(in: sub) {
                return nested
            }
        }
        return nil
    }

    private func focusChromiumInsidePanel(_ panel: ExtensionPopupPanel) {
        panel.makeKeyAndOrderFront(nil)
        if let rwhv = findRenderWidgetHostView(in: activePopupContainer) {
            panel.makeFirstResponder(rwhv)
        }
    }

    /// Positions the curved-caret bubble directly below the clicked toolbar icon (`2 pt` gap from capsule bottom to caret tip),
    /// horizontally centered on the icon and clamped cleanly to visible screen bounds (matching macOS 27 Safari `open_1to1.png`).
    private func computePanelLayout(
        contentSize: NSSize,
        anchorView: NSView,
        parentWindow: NSWindow
    ) -> (frame: NSRect, bubbleOriginInPanel: NSPoint, bubbleSize: NSSize, anchorXInBubble: CGFloat) {
        let w = round(contentSize.width)
        let totalH = round(contentSize.height + Self.arrowHeight)
        let pad = Self.springBleedPad
        let anchorInWin = anchorView.convert(anchorView.bounds, to: nil)
        let anchorOnScreen = parentWindow.convertToScreen(anchorInWin)
        let screenFrame = (parentWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let gapBelowToolbar: CGFloat = 2.0
        let screenMargin: CGFloat = 8.0

        let rawX = round(anchorOnScreen.midX - w * 0.5)
        let bx = max(screenFrame.minX + screenMargin, min(screenFrame.maxX - w - screenMargin, rawX))
        let by = max(screenFrame.minY + screenMargin, round(anchorOnScreen.minY - gapBelowToolbar - totalH))

        let anchorX = ExtensionBubbleGeometry.clampedAnchorX(anchorOnScreen.midX - bx, width: w)
        // Expand borderless panel by `pad` on left, right, and bottom so CASpringAnimation overshoot never clips!
        let panelFrame = NSRect(x: bx - pad, y: by - pad, width: w + pad * 2.0, height: totalH + pad)
        return (panelFrame, NSPoint(x: pad, y: pad), NSSize(width: w, height: totalH), anchorX)
    }

    private func flushPendingAnimatedCloseIfNeeded() {
        pendingCloseTeardownWork?.cancel()
        pendingCloseTeardownWork = nil
        if let teardown = pendingCloseTeardown {
            pendingCloseTeardown = nil
            teardown()
        }
    }

    private func closeActivePopover(animated: Bool, restoreParentKey: Bool = true) {
        flushPendingAnimatedCloseIfNeeded()
        cancelPendingBloomTimers()
        removeDismissMonitors()

        (activeAnchorView as? ExtensionToolbarIconButton)?.setPopupActive(false)

        let oldPop = activePopover
        let oldPanel = activePanel
        let oldParentWin = activeParentWindow
        let oldExtID = activeExtensionID
        let oldWasManage = isManagePopover
        let oldFill = activeFillView
        let oldContent = activePopupContainer
        let oldRim = activeRimView
        let oldStage = activeStageView
        let oldBloomShell = activeBloomShellView
        let oldAnchorX = activeAnchorXInPanel
        let oldIsDark = activeIsDark

        oldPop?.delegate = nil
        activePopover = nil
        activePanel = nil
        activeParentWindow = nil
        activeAnchorView = nil
        activeStageView = nil
        activeBloomShellView = nil
        activeBloomGlassView = nil
        activeBloomMaskLayer = nil
        activeBloomTintLayer = nil
        activeBloomRimView = nil
        activeFillView = nil
        activePopupContainer = nil
        activeRimView = nil
        activeExtensionID = nil
        isManagePopover = false

        var didTeardown = false
        let teardown = { [weak self] in
            guard !didTeardown else { return }
            didTeardown = true
            if let oldExtID, !oldWasManage {
                self?.onCloseExtensionPopup?(oldExtID)
            }
            if let oldPanel {
                oldParentWin?.removeChildWindow(oldPanel)
                oldPanel.orderOut(nil)
            }
            if restoreParentKey,
               let oldParentWin,
               oldParentWin.isVisible,
               self?.activePanel == nil,
               NSApp.isActive,
               (NSApp.keyWindow == nil || NSApp.keyWindow === oldPanel || NSApp.keyWindow === oldParentWin) {
                oldParentWin.makeKey()
            }
        }

        if let oldPanel {
            if animated && oldPanel.isVisible && oldPanel.alphaValue > 0.05, let stage = oldStage ?? oldPanel.contentView {
                let fullBounds = stage.bounds
                let appearance = NSAppearance(named: oldIsDark ? .darkAqua : .aqua)

                // Build or reuse a pure-AppKit curved-caret frosted glass shell for tear-free reverse bloom
                let closeShell: NSView
                if let existingBloom = oldBloomShell, existingBloom.superview === stage {
                    closeShell = existingBloom
                } else {
                    let cs = NSView(frame: fullBounds)
                    cs.wantsLayer = true
                    cs.layer?.masksToBounds = false
                    cs.layer?.backgroundColor = NSColor.clear.cgColor
                    cs.layer?.zPosition = 20

                    let maskPath = ExtensionBubbleGeometry.makeBubblePath(size: fullBounds.size, anchorX: oldAnchorX, inset: 0.0)
                    let maskLayer = CAShapeLayer()
                    maskLayer.frame = fullBounds
                    maskLayer.path = maskPath
                    cs.layer?.mask = maskLayer

                    let glass = NSVisualEffectView(frame: fullBounds)
                    glass.material = .popover
                    glass.blendingMode = .behindWindow
                    glass.state = .active
                    glass.appearance = appearance
                    glass.wantsLayer = true
                    glass.maskImage = ExtensionBubbleGeometry.makeMaskImage(size: fullBounds.size, anchorX: oldAnchorX)
                    cs.addSubview(glass)

                    let tint = CAShapeLayer()
                    tint.frame = fullBounds
                    tint.path = maskPath
                    tint.fillColor = (oldIsDark
                        ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.72)
                        : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.76)).cgColor
                    cs.layer?.addSublayer(tint)

                    let rim = ExtensionBubbleRimView(frame: fullBounds)
                    rim.isDark = oldIsDark
                    rim.anchorX = oldAnchorX
                    cs.addSubview(rim)

                    cs.alphaValue = 0.0
                    stage.addSubview(cs)
                    closeShell = cs
                }

                // 1. Melt live extension UI smoothly into the pure-glass shell (0..42ms), then hide Chromium
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.042
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    closeShell.animator().alphaValue = 1.0
                    oldContent?.animator().alphaValue = 0.0
                    oldFill?.animator().alphaValue = 0.0
                    oldRim?.animator().alphaValue = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.042) {
                    oldPanel.hasShadow = false
                    oldContent?.isHidden = true
                }

                // 2. Smooth 120Hz reverse-bloom shrinking back up into the clicked extension icon caret apex
                if let layer = closeShell.layer {
                    let ax = oldAnchorX
                    let apexY = fullBounds.height
                    var endT = CATransform3DIdentity
                    endT = CATransform3DTranslate(endT, ax, apexY, 0)
                    endT = CATransform3DScale(endT, 0.46, 0.30, 1.0)
                    endT = CATransform3DTranslate(endT, -ax, -apexY, 0)

                    let shrink = CABasicAnimation(keyPath: "transform")
                    shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
                    shrink.toValue = NSValue(caTransform3D: endT)
                    shrink.duration = Self.closeDuration
                    shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.78, 1.0)
                    shrink.fillMode = .forwards
                    shrink.isRemovedOnCompletion = false
                    layer.add(shrink, forKey: "sxCloseShrink")

                    let fadeOut = CABasicAnimation(keyPath: "opacity")
                    fadeOut.fromValue = 1.0
                    fadeOut.toValue = 0.0
                    fadeOut.beginTime = CACurrentMediaTime() + 0.042
                    fadeOut.duration = Self.closeDuration - 0.042
                    fadeOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    fadeOut.fillMode = .forwards
                    fadeOut.isRemovedOnCompletion = false
                    layer.add(fadeOut, forKey: "sxCloseFade")
                }

                pendingCloseTeardown = teardown
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingCloseTeardownWork = nil
                    self?.pendingCloseTeardown = nil
                    teardown()
                }
                pendingCloseTeardownWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration + 0.015, execute: work)
            } else {
                teardown()
            }
        } else {
            teardown()
        }
        if let oldPop {
            oldPop.close()
        }
    }

    private func closeActivePopoverImmediately() {
        closeActivePopover(animated: false)
    }

    var isShown: Bool {
        activePanel != nil || activePopover?.isShown == true
    }

    func close(restoreParentKey: Bool = true) {
        closeActivePopover(animated: false, restoreParentKey: restoreParentKey)
    }

    private func applyPanelResize(_ target: NSSize) {
        if let extID = activeExtensionID {
            Self.savePopupSize(target, for: extID)
        }
        guard let panel = activePanel, panel.isVisible else { return }
        if abs(activeContentSize.width - target.width) <= 3.0 &&
           abs(activeContentSize.height - target.height) <= 3.0 {
            return
        }
        activeContentSize = target

        let pad = Self.springBleedPad
        let nextFrame: NSRect
        let bubbleSize = NSSize(width: target.width, height: round(target.height + Self.arrowHeight))
        let nextAnchorX: CGFloat
        if let anchor = activeAnchorView, let parentWin = activeParentWindow {
            let layout = computePanelLayout(contentSize: target, anchorView: anchor, parentWindow: parentWin)
            nextFrame = layout.frame
            nextAnchorX = layout.anchorXInBubble
        } else {
            let topY = panel.frame.maxY
            let panelH = bubbleSize.height + pad
            nextFrame = NSRect(x: panel.frame.minX, y: round(topY - panelH), width: bubbleSize.width + pad * 2.0, height: panelH)
            nextAnchorX = ExtensionBubbleGeometry.clampedAnchorX(activeAnchorXInPanel, width: target.width)
        }
        activeAnchorXInPanel = nextAnchorX

        let stageFrame = NSRect(origin: NSPoint(x: pad, y: pad), size: bubbleSize)
        let fullBounds = NSRect(origin: .zero, size: bubbleSize)
        let bodyBounds = NSRect(x: 0, y: 0, width: target.width, height: target.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(nextFrame, display: true, animate: false)
        activeStageView?.frame = stageFrame
        activeBloomShellView?.frame = fullBounds
        let bubblePath = ExtensionBubbleGeometry.makeBubblePath(size: fullBounds.size, anchorX: nextAnchorX, inset: 0.0)
        if let mask = activeBloomMaskLayer {
            mask.frame = fullBounds
            mask.path = bubblePath
        }
        if let tint = activeBloomTintLayer {
            tint.frame = fullBounds
            tint.path = bubblePath
        }
        if let bloom = activeBloomGlassView {
            bloom.frame = fullBounds
            bloom.maskImage = ExtensionBubbleGeometry.makeMaskImage(size: fullBounds.size, anchorX: nextAnchorX)
        }
        if let bloomRim = activeBloomRimView {
            bloomRim.frame = fullBounds
            bloomRim.anchorX = nextAnchorX
            bloomRim.updateStyle()
        }
        if let fill = activeFillView {
            fill.frame = fullBounds
            fill.anchorX = nextAnchorX
            fill.updatePathAndColors()
        }
        if let container = activePopupContainer {
            container.frame = bodyBounds
            for sub in container.subviews {
                if !NSEqualRects(sub.frame, bodyBounds) {
                    sub.frame = bodyBounds
                }
            }
        }
        if let rim = activeRimView {
            rim.frame = fullBounds
            rim.anchorX = nextAnchorX
            rim.updateStyle()
        }
        CATransaction.commit()
        panel.invalidateShadow()
    }

    /// Launches the visible spring-bouncy pure-glass bloom ONLY after the inner Chromium extension page
    /// has already mounted its DOM (or hit the short preload safety cap), so the bloom crossfades
    /// directly into the ready UI with crisp macOS 27 spring overshoot, zero stall, and zero size jump!
    private func startVisibleBloomAnimation() {
        guard !hasStartedVisibleBloom,
              let panel = activePanel,
              let stage = activeStageView,
              let bloomShell = activeBloomShellView,
              let contentClip = activePopupContainer else {
            return
        }
        hasStartedVisibleBloom = true
        isPreloadingBeforeBloom = false
        isOpeningBloomActive = true
        pendingPreloadSafetyWork?.cancel()
        pendingPreloadSafetyWork = nil

        // Apply exact measured preferred size silently BEFORE making the panel visible!
        if let pendingSize = deferredResizeSize {
            deferredResizeSize = nil
            applyPanelResize(pendingSize)
        }

        let fullBounds = stage.bounds
        let ax = activeAnchorXInPanel

        // Keep Chromium cleanly hidden behind bloomShell for the first 115ms of the spring bloom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentClip.isHidden = true
        contentClip.alphaValue = 0.0
        activeFillView?.alphaValue = 0.0
        activeRimView?.alphaValue = 0.0
        bloomShell.alphaValue = 1.0
        CATransaction.commit()

        // Tactile macOS 27 Tahoe spring bounce from the curved caret apex (anchorX, totalH):
        // Overshoots smoothly ~4% past 1.0x into the transparent bleed margin and settles cleanly to 1.0x!
        if let stageLayer = stage.layer {
            let apexY = fullBounds.height
            var startT = CATransform3DIdentity
            startT = CATransform3DTranslate(startT, ax, apexY, 0)
            startT = CATransform3DScale(startT, 0.44, 0.28, 1.0)
            startT = CATransform3DTranslate(startT, -ax, -apexY, 0)

            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: startT)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.mass = 1.0
            spring.stiffness = 400.0
            spring.damping = 27.5
            spring.initialVelocity = 2.0
            spring.duration = spring.settlingDuration
            spring.isRemovedOnCompletion = true
            stageLayer.add(spring, forKey: "sxBloomSpring")

            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 0.0
            fadeAnim.toValue = 1.0
            fadeAnim.duration = 0.045
            fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fadeAnim.isRemovedOnCompletion = true
            stageLayer.add(fadeAnim, forKey: "sxBloomOpacity")
        }

        panel.alphaValue = 1.0
        panel.makeKeyAndOrderFront(nil)

        // t = 115ms (right as the spring reaches peak bounce): reveal ALREADY-LOADED Chromium underneath bloomShell
        // and crossfade bloomShell out smoothly over 80ms as the bubble finishes its gentle spring settle!
        let revealWork = DispatchWorkItem { [weak self, weak panel, weak bloomShell, weak contentClip] in
            guard let self, let panel, self.activePanel === panel, let bloomShell, let contentClip else { return }
            self.isOpeningBloomActive = false

            if let pendingSize = self.deferredResizeSize {
                self.deferredResizeSize = nil
                self.applyPanelResize(pendingSize)
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentClip.frame = NSRect(origin: .zero, size: self.activeContentSize)
            contentClip.isHidden = false
            contentClip.alphaValue = 1.0
            self.activeFillView?.alphaValue = 1.0
            self.activeRimView?.alphaValue = 1.0
            CATransaction.commit()

            panel.hasShadow = true
            panel.invalidateShadow()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.revealCrossfadeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bloomShell.animator().alphaValue = 0.0
            }
        }
        pendingRevealWork = revealWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealStartDelay, execute: revealWork)

        // t = 210ms: remove temporary bloomShell cleanly and focus Chromium
        let finishWork = DispatchWorkItem { [weak self, weak panel, weak bloomShell] in
            guard let self, let panel, self.activePanel === panel else { return }
            bloomShell?.removeFromSuperview()
            self.activeBloomShellView = nil
            self.activeBloomGlassView = nil
            self.activeBloomMaskLayer = nil
            self.activeBloomTintLayer = nil
            self.activeBloomRimView = nil
            panel.hasShadow = true
            panel.invalidateShadow()
            self.focusChromiumInsidePanel(panel)
        }
        pendingFinishWork = finishWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealStartDelay + Self.revealCrossfadeDuration + 0.02, execute: finishWork)
    }

    private func installPopupSizeObserverIfNeeded() {
        if popupCloseObserver == nil {
            popupCloseObserver = NotificationCenter.default.addObserver(
                forName: Self.popupShouldCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      !self.isManagePopover,
                      let panel = self.activePanel, panel.isVisible else { return }
                if let extID = note.userInfo?["extensionID"] as? String,
                   !extID.isEmpty,
                   let activeID = self.activeExtensionID,
                   extID.lowercased() != activeID.lowercased() {
                    return
                }
                self.closeActivePopover(animated: true)
            }
        }
        guard popupSizeObserver == nil else { return }
        popupSizeObserver = NotificationCenter.default.addObserver(
            forName: Self.popupPreferredSizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  !self.isManagePopover,
                  let panel = self.activePanel, panel.isVisible,
                  let info = note.userInfo else { return }
            if let extID = info["extensionID"] as? String,
               let activeID = self.activeExtensionID,
               extID.lowercased() != activeID.lowercased() {
                return
            }
            guard let w = (info["width"] as? NSNumber)?.doubleValue,
                  let h = (info["height"] as? NSNumber)?.doubleValue,
                  w >= 80, h >= 60 else { return }
            let target = NSSize(
                width: round(max(240.0, min(600.0, CGFloat(w)))),
                height: round(max(120.0, min(600.0, CGFloat(h))))
            )
            let isDomReady = (info["contentReady"] as? Bool) ?? false
            if self.isPreloadingBeforeBloom {
                Self.savePopupSize(target, for: self.activeExtensionID ?? "")
                self.deferredResizeSize = target
                if isDomReady {
                    // Wait 1 compositor paint frame (~24ms) so Chromium's GPU surface has painted the real DOM, then start the bloom!
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.024) { [weak self, weak panel] in
                        guard let self, let panel, self.activePanel === panel else { return }
                        self.startVisibleBloomAnimation()
                    }
                }
            } else if self.isOpeningBloomActive {
                Self.savePopupSize(target, for: self.activeExtensionID ?? "")
                self.deferredResizeSize = target
            } else {
                self.applyPanelResize(target)
            }
        }
    }

    func toggleExtensionPopup(
        for item: BrowserExtensionItem,
        relativeTo anchorView: NSView,
        isDark: Bool,
        createPopupView: (_ width: CGFloat, _ height: CGFloat, _ host: NSView) -> NSView?
    ) {
        let alreadyOpenSame =
            !isManagePopover &&
            activeExtensionID == item.id &&
            (activePanel?.isVisible == true || activePopover?.isShown == true)
        if alreadyOpenSame {
            closeActivePopover(animated: true)
            return
        }
        closeActivePopoverImmediately()
        installPopupSizeObserverIfNeeded()

        let hasHTMLPopup = (item.popupURL != nil)
        if hasHTMLPopup, let parentWin = anchorView.window {
            let initialContentSize = Self.cachedPopupSize(for: item.id)
            let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            let layout = computePanelLayout(contentSize: initialContentSize, anchorView: anchorView, parentWindow: parentWin)
            let panelBounds = NSRect(origin: .zero, size: layout.frame.size)
            let stageFrame = NSRect(origin: layout.bubbleOriginInPanel, size: layout.bubbleSize)
            let fullBounds = NSRect(origin: .zero, size: layout.bubbleSize)
            let bodyBounds = NSRect(x: 0, y: 0, width: initialContentSize.width, height: initialContentSize.height)

            let panel = ExtensionPopupPanel(
                contentRect: layout.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.appearance = appearance
            panel.onCancelRequested = { [weak self] in
                self?.closeActivePopover(animated: true)
            }

            // Transparent root with 18pt spring bleed margin so CASpringAnimation overshoot never clips!
            let root = NSView(frame: panelBounds)
            root.wantsLayer = true
            root.layer?.masksToBounds = false
            root.layer?.backgroundColor = NSColor.clear.cgColor

            let stage = NSView(frame: stageFrame)
            stage.wantsLayer = true
            stage.layer?.masksToBounds = false
            stage.layer?.backgroundColor = NSColor.clear.cgColor
            root.addSubview(stage)

            // 1. Settled opaque caret+body surface (revealed underneath bloomShell right when bloom lands).
            let fillView = ExtensionBubbleFillView(frame: fullBounds)
            fillView.isDark = isDark
            fillView.anchorX = layout.anchorXInBubble
            fillView.alphaValue = 0.0
            fillView.autoresizingMask = [.width, .height]
            stage.addSubview(fillView)

            // 2. Chromium popup container: transparent layer so extensions without an opaque CSS background
            //    composite directly over `ExtensionBubbleFillView`'s behind-window frosted glass.
            let contentClip = NSView(frame: bodyBounds)
            contentClip.wantsLayer = true
            contentClip.layer?.cornerRadius = Self.bubbleCornerRadius
            contentClip.layer?.cornerCurve = .continuous
            contentClip.layer?.masksToBounds = true
            contentClip.layer?.isOpaque = false
            contentClip.layer?.backgroundColor = NSColor.clear.cgColor
            contentClip.alphaValue = 1.0
            stage.addSubview(contentClip)

            // 3. Settled continuous hairline rim tracing both the 22pt corners and curved top caret.
            let rimView = ExtensionBubbleRimView(frame: fullBounds)
            rimView.isDark = isDark
            rimView.anchorX = layout.anchorXInBubble
            rimView.alphaValue = 0.0
            rimView.autoresizingMask = [.width, .height]
            stage.addSubview(rimView)

            // 4. Dedicated PURE-APPKIT bloom shell ON TOP of Chromium (zero remote CALayerHost inside!).
            //    Explicit CAShapeLayer mask guarantees crisp 22pt rounded corners + curved caret on EVERY single frame!
            let bloomShell = NSView(frame: fullBounds)
            bloomShell.wantsLayer = true
            bloomShell.layer?.masksToBounds = false
            bloomShell.layer?.backgroundColor = NSColor.clear.cgColor
            bloomShell.layer?.zPosition = 20
            bloomShell.autoresizingMask = [.width, .height]

            let bloomMaskPath = ExtensionBubbleGeometry.makeBubblePath(size: fullBounds.size, anchorX: layout.anchorXInBubble, inset: 0.0)
            let bloomMask = CAShapeLayer()
            bloomMask.frame = fullBounds
            bloomMask.path = bloomMaskPath
            bloomShell.layer?.mask = bloomMask

            let bloomGlass = NSVisualEffectView(frame: fullBounds)
            bloomGlass.material = .popover
            bloomGlass.blendingMode = .behindWindow
            bloomGlass.state = .active
            bloomGlass.appearance = appearance
            bloomGlass.wantsLayer = true
            bloomGlass.maskImage = ExtensionBubbleGeometry.makeMaskImage(size: fullBounds.size, anchorX: layout.anchorXInBubble)
            bloomGlass.autoresizingMask = [.width, .height]
            bloomShell.addSubview(bloomGlass)

            let bloomTintLayer = CAShapeLayer()
            bloomTintLayer.frame = fullBounds
            bloomTintLayer.path = bloomMaskPath
            bloomTintLayer.fillColor = (isDark
                ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.72)
                : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.76)).cgColor
            bloomShell.layer?.addSublayer(bloomTintLayer)

            let bloomRim = ExtensionBubbleRimView(frame: fullBounds)
            bloomRim.isDark = isDark
            bloomRim.anchorX = layout.anchorXInBubble
            bloomRim.autoresizingMask = [.width, .height]
            bloomShell.addSubview(bloomRim)
            stage.addSubview(bloomShell)

            // Keep panel completely invisible (`alphaValue = 0.0`) while ordered front so Chromium's GPU compositor
            // renders the real extension DOM right before the visible spring bloom animation begins!
            panel.alphaValue = 0.0
            panel.contentView = root
            parentWin.addChildWindow(panel, ordered: .above)
            (anchorView as? ExtensionToolbarIconButton)?.setPopupActive(true)

            activePanel = panel
            activeParentWindow = parentWin
            activeAnchorView = anchorView
            activeStageView = stage
            activeBloomShellView = bloomShell
            activeBloomGlassView = bloomGlass
            activeBloomMaskLayer = bloomMask
            activeBloomTintLayer = bloomTintLayer
            activeBloomRimView = bloomRim
            activeFillView = fillView
            activePopupContainer = contentClip
            activeRimView = rimView
            activeExtensionID = item.id
            activeContentSize = initialContentSize
            activeAnchorXInPanel = layout.anchorXInBubble
            activeIsDark = isDark
            isPreloadingBeforeBloom = true
            isOpeningBloomActive = false
            hasStartedVisibleBloom = false
            deferredResizeSize = nil
            isManagePopover = false
            installDismissMonitors()

            if let popupView = createPopupView(bodyBounds.width, bodyBounds.height, contentClip) {
                popupView.frame = NSRect(origin: .zero, size: bodyBounds.size)
                popupView.autoresizingMask = [.width, .height]
                if popupView.superview !== contentClip {
                    contentClip.addSubview(popupView)
                }

                // Order panel on screen at alpha 0.0 so Blink/Chromium immediately lays out and paints the inner page
                panel.orderFront(nil)

                // Safety cap (340ms): guarantee bloom launches promptly even for static pages without dynamic DOM signals
                let safetyWork = DispatchWorkItem { [weak self, weak panel] in
                    guard let self, let panel, self.activePanel === panel else { return }
                    self.startVisibleBloomAnimation()
                }
                pendingPreloadSafetyWork = safetyWork
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.preloadMaxWaitDuration, execute: safetyWork)
                return
            } else {
                closeActivePopoverImmediately()
            }
        }

        // Pure AppKit fallback when an extension has no HTML popup
        let fallback = buildNoPopupFallbackView(item: item, width: 280, isDark: isDark)
        let container = NSView(frame: fallback.bounds)
        container.wantsLayer = true
        container.addSubview(fallback)

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let vc = NSViewController()
        vc.view = container
        pop.contentViewController = vc
        pop.contentSize = fallback.bounds.size

        activePopover = pop
        activeExtensionID = item.id
        activePopupContainer = container
        isManagePopover = false
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    func showManageExtensionsPopover(
        relativeTo anchorView: NSView,
        extensions: [BrowserExtensionItem],
        isDark: Bool,
        isHiddenInToolbar: ((String) -> Bool)? = nil
    ) {
        closeActivePopoverImmediately()

        let w: CGFloat = 356
        let rowH: CGFloat = 52
        let listH = max(72, min(260, CGFloat(max(1, extensions.count)) * rowH))
        let totalH: CGFloat = 44 + listH + 54

        let root = FlippedExtensionPopoverView(frame: NSRect(x: 0, y: 0, width: w, height: totalH))
        root.wantsLayer = true

        let titleLbl = NSTextField(labelWithString: "Extensions")
        titleLbl.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        titleLbl.textColor = isDark ? .white : NSColor(white: 0.12, alpha: 1.0)
        titleLbl.frame = NSRect(x: 16, y: 12, width: w - 140, height: 18)
        root.addSubview(titleLbl)

        let storeBtn = NSButton(title: "Web Store", target: self, action: #selector(handleOpenStore))
        storeBtn.bezelStyle = .rounded
        storeBtn.controlSize = .small
        storeBtn.frame = NSRect(x: w - 98, y: 9, width: 84, height: 22)
        root.addSubview(storeBtn)

        let sep1 = NSView(frame: NSRect(x: 0, y: 40, width: w, height: 0.5))
        sep1.wantsLayer = true
        sep1.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.10)).cgColor
        root.addSubview(sep1)

        if extensions.isEmpty {
            let empty = NSTextField(labelWithString: "No extensions installed.\nInstall MV3 extensions from Chrome Web Store or Load Unpacked.")
            empty.maximumNumberOfLines = 2
            empty.alignment = .center
            empty.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
            empty.textColor = isDark ? NSColor.white.withAlphaComponent(0.60) : .secondaryLabelColor
            empty.frame = NSRect(x: 20, y: 56, width: w - 40, height: 38)
            root.addSubview(empty)
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 41, width: w, height: listH))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder

            let doc = FlippedExtensionPopoverView(frame: NSRect(x: 0, y: 0, width: w, height: max(listH, CGFloat(extensions.count) * rowH)))
            for (idx, ext) in extensions.enumerated() {
                let row = FlippedExtensionPopoverView(frame: NSRect(x: 0, y: CGFloat(idx) * rowH, width: w, height: rowH))
                let icon = NSImageView(frame: NSRect(x: 14, y: 12, width: 28, height: 28))
                icon.imageScaling = .scaleProportionallyDown
                icon.image = ext.icon ?? AssetLoader.shared.symbol(named: "puzzlepiece.extension.fill", pointSize: 20, weight: .regular)
                row.addSubview(icon)

                let nameLbl = NSTextField(labelWithString: ext.name)
                nameLbl.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
                nameLbl.textColor = isDark ? .white : NSColor(white: 0.12, alpha: 1.0)
                nameLbl.lineBreakMode = .byTruncatingTail
                nameLbl.frame = NSRect(x: 50, y: 9, width: w - 166, height: 17)
                row.addSubview(nameLbl)

                let verLbl = NSTextField(labelWithString: "Version \(ext.version.isEmpty ? "1.0" : ext.version)")
                verLbl.font = NSFont.systemFont(ofSize: 11.0, weight: .regular)
                verLbl.textColor = isDark ? NSColor.white.withAlphaComponent(0.55) : .secondaryLabelColor
                verLbl.frame = NSRect(x: 50, y: 27, width: w - 166, height: 15)
                row.addSubview(verLbl)

                let isPinned = !(isHiddenInToolbar?(ext.id) ?? false)
                let pinBtn = NSButton(frame: NSRect(x: w - 108, y: 15, width: 26, height: 22))
                pinBtn.bezelStyle = .rounded
                pinBtn.controlSize = .small
                pinBtn.setButtonType(.toggle)
                pinBtn.state = isPinned ? .on : .off
                pinBtn.image = AssetLoader.shared.symbol(named: isPinned ? "pin.fill" : "pin.slash", pointSize: 11.0, weight: .medium)
                pinBtn.imagePosition = .imageOnly
                pinBtn.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
                pinBtn.toolTip = isPinned ? "Hide from Toolbar" : "Show in Toolbar"
                pinBtn.identifier = NSUserInterfaceItemIdentifier(ext.id)
                pinBtn.target = self
                pinBtn.action = #selector(handleToggleToolbarPin(_:))
                row.addSubview(pinBtn)

                let remBtn = NSButton(title: "Remove", target: self, action: #selector(handleRemoveRow(_:)))
                remBtn.bezelStyle = .rounded
                remBtn.controlSize = .small
                remBtn.identifier = NSUserInterfaceItemIdentifier(ext.id)
                remBtn.frame = NSRect(x: w - 76, y: 15, width: 64, height: 22)
                row.addSubview(remBtn)

                doc.addSubview(row)
            }
            scroll.documentView = doc
            root.addSubview(scroll)
        }

        let sep2 = NSView(frame: NSRect(x: 0, y: totalH - 46, width: w, height: 0.5))
        sep2.wantsLayer = true
        sep2.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.10)).cgColor
        root.addSubview(sep2)

        let loadUnpackedBtn = NSButton(title: "Load Unpacked…", target: self, action: #selector(handleLoadUnpacked))
        loadUnpackedBtn.bezelStyle = .rounded
        loadUnpackedBtn.controlSize = .small
        loadUnpackedBtn.frame = NSRect(x: 14, y: totalH - 34, width: 144, height: 24)
        root.addSubview(loadUnpackedBtn)

        let crxBtn = NSButton(title: "Install .crx…", target: self, action: #selector(handleInstallCRX))
        crxBtn.bezelStyle = .rounded
        crxBtn.controlSize = .small
        crxBtn.frame = NSRect(x: w - 130, y: totalH - 34, width: 116, height: 24)
        root.addSubview(crxBtn)

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let vc = NSViewController()
        vc.view = root
        pop.contentViewController = vc
        pop.contentSize = root.frame.size

        activePopover = pop
        activeExtensionID = nil
        isManagePopover = true

        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    private func buildNoPopupFallbackView(item: BrowserExtensionItem, width: CGFloat, isDark: Bool) -> NSView {
        let v = FlippedExtensionPopoverView(frame: NSRect(x: 0, y: 0, width: width, height: 112))
        let name = NSTextField(labelWithString: item.name)
        name.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        name.textColor = isDark ? .white : .black
        name.frame = NSRect(x: 16, y: 14, width: width - 32, height: 18)
        v.addSubview(name)

        let desc = NSTextField(wrappingLabelWithString: "Version \(item.version) is active on this page.")
        desc.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
        desc.textColor = isDark ? NSColor.white.withAlphaComponent(0.65) : .secondaryLabelColor
        desc.frame = NSRect(x: 16, y: 38, width: width - 32, height: 34)
        v.addSubview(desc)

        let remBtn = NSButton(title: "Remove Extension", target: self, action: #selector(handleRemoveRow(_:)))
        remBtn.bezelStyle = .rounded
        remBtn.controlSize = .small
        remBtn.identifier = NSUserInterfaceItemIdentifier(item.id)
        remBtn.frame = NSRect(x: 16, y: 76, width: 140, height: 22)
        v.addSubview(remBtn)
        return v
    }

    @objc private func handleLoadUnpacked() {
        closeActivePopoverImmediately()
        onLoadUnpackedRequested?()
    }

    @objc private func handleInstallCRX() {
        closeActivePopoverImmediately()
        onInstallCRXRequested?()
    }

    @objc private func handleOpenStore() {
        closeActivePopoverImmediately()
        onOpenChromeWebStore?()
    }

    @objc private func handleRemoveRow(_ sender: NSButton) {
        guard let extID = sender.identifier?.rawValue, !extID.isEmpty else { return }
        closeActivePopoverImmediately()
        onRemoveExtension?(extID)
    }

    @objc private func handleToggleToolbarPin(_ sender: NSButton) {
        guard let extID = sender.identifier?.rawValue, !extID.isEmpty else { return }
        let showInToolbar = (sender.state == .on)
        sender.image = AssetLoader.shared.symbol(named: showInToolbar ? "pin.fill" : "pin.slash", pointSize: 11.0, weight: .medium)
        sender.contentTintColor = showInToolbar ? .controlAccentColor : .secondaryLabelColor
        sender.toolTip = showInToolbar ? "Hide from Toolbar" : "Show in Toolbar"
        onToggleToolbarPin?(extID, showInToolbar)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPop = notification.object as? NSPopover,
              closedPop === activePopover else {
            return
        }
        if let extID = activeExtensionID, !isManagePopover {
            onCloseExtensionPopup?(extID)
        }
        activePopover = nil
        activeExtensionID = nil
        activePopupContainer = nil
        isManagePopover = false
    }
}

private final class FlippedExtensionPopoverView: NSView {
    override var isFlipped: Bool { true }
}
