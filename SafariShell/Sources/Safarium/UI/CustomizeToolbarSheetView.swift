import AppKit
import QuartzCore

/// Side of the toolbar where customizable action buttons or spacers can be placed.
enum ToolbarActionSide: String, Codable {
    case left
    case right
}

/// Free-standing toolbar groups that can sit on either side of the address bar (unlike the action capsules, which
/// always hug it).
enum ToolbarCluster: String, CaseIterable, Codable {
    case sidebar
    case backForward
    case privacyShield

    var itemID: CustomizableToolbarItemID {
        switch self {
        case .sidebar: return .sidebar
        case .backForward: return .backForward
        case .privacyShield: return .privacyReport
        }
    }

    init?(itemID: CustomizableToolbarItemID) {
        switch itemID {
        case .sidebar: self = .sidebar
        case .backForward: self = .backForward
        case .privacyReport: self = .privacyShield
        default: return nil
        }
    }
}

/// Identifiers for EVERY native Safarium toolbar control manageable in "Customize Toolbar…".
enum CustomizableToolbarItemID: String, CaseIterable, Codable {
    // Core default items
    case sidebar
    case backForward
    case downloads
    case share
    case newTab
    case tabOverview
    case addressBar

    // Optional real-action items users can drag into left or right side of the toolbar
    case startPage
    case home
    case history
    case bookmarks
    case zoom
    case reload
    case settings
    case print
    case webInspector
    case privacyReport

    // Spacers
    case flexibleSpace
    case fixedSpace

    var label: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .backForward: return "Back/Forward"
        case .downloads: return "Downloads"
        case .share: return "Share"
        case .newTab: return "New Tab"
        case .tabOverview: return "Tab Overview"
        case .addressBar: return "Address and Search"
        case .startPage: return "Start Page"
        case .home: return "Home"
        case .history: return "History"
        case .bookmarks: return "Bookmarks"
        case .zoom: return "Zoom"
        case .reload: return "Reload"
        case .settings: return "Settings"
        case .print: return "Print"
        case .webInspector: return "Web Inspector"
        case .privacyReport: return "Privacy Report"
        case .flexibleSpace: return "Flexible Space"
        case .fixedSpace: return "Space"
        }
    }

    var symbolName: String {
        switch self {
        case .sidebar: return "sidebar.left"
        case .backForward: return "chevron.left.chevron.right"
        case .downloads: return "arrow.down.circle"
        case .share: return "square.and.arrow.up"
        case .newTab: return "plus"
        case .tabOverview: return "square.on.square"
        case .addressBar: return "magnifyingglass"
        case .startPage: return "square.grid.2x2"
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .bookmarks: return "book"
        case .zoom: return "textformat.size"
        case .reload: return "arrow.clockwise"
        case .settings: return "gearshape"
        case .print: return "printer"
        case .webInspector: return "ladybug"
        case .privacyReport: return "shield.lefthalf.filled"
        case .flexibleSpace, .fixedSpace: return ""
        }
    }

    var isDefaultVisible: Bool {
        switch self {
        case .sidebar, .backForward, .downloads, .share, .newTab, .tabOverview, .addressBar:
            return true
        default:
            return false
        }
    }

    var isMovableAction: Bool {
        switch self {
        case .downloads, .share, .newTab, .tabOverview,
             .startPage, .home, .history, .bookmarks, .zoom, .reload, .settings, .print, .webInspector, .privacyReport:
            return true
        default:
            return false
        }
    }

    var isSpacer: Bool {
        self == .flexibleSpace || self == .fixedSpace
    }

    static let defaultRightActionOrder: [CustomizableToolbarItemID] = [
        .downloads, .share, .newTab, .tabOverview
    ]

    static let allMovableActions: [CustomizableToolbarItemID] = [
        .startPage, .home, .history, .bookmarks, .zoom, .reload, .settings, .print, .webInspector, .privacyReport,
        .downloads, .share, .newTab, .tabOverview
    ]

    static let optionalActionItems: [CustomizableToolbarItemID] = [
        .startPage, .home, .history, .bookmarks, .zoom, .reload, .settings, .print, .webInspector, .privacyReport
    ]

    static let row1Order: [CustomizableToolbarItemID] = [
        .sidebar, .backForward, .share, .newTab, .tabOverview,
        .startPage, .home, .history, .bookmarks, .zoom, .reload
    ]

    static let row2LeadingOrder: [CustomizableToolbarItemID] = [
        .settings, .print, .webInspector, .privacyReport, .downloads
    ]
}

/// Persistent toolbar customization state shared across windows:
/// supports hiding/showing EVERY native element, moving & reordering action items across left/right sides,
/// and adding/removing real Flexible Space and Space elements.
final class ToolbarCustomizationStore {
    static let shared = ToolbarCustomizationStore()
    static let didChangeNotification = Notification.Name("SafariumToolbarCustomizationDidChange")

    private static let hiddenDefaultsKey = "Safarium.Toolbar.HiddenNativeIDs.v2"
    private static let leftOrderKey = "Safarium.Toolbar.LeftActionOrder.v2"
    private static let rightOrderKey = "Safarium.Toolbar.RightActionOrder.v2"
    private static let leftSpacersKey = "Safarium.Toolbar.LeftSpacers.v2"
    private static let rightSpacersKey = "Safarium.Toolbar.RightSpacers.v2"
    private static let shieldRemovedKey = "Safarium.Toolbar.StandaloneShieldRemoved.v1"
    private static let leftClustersKey = "Safarium.Toolbar.LeftClusters.v1"
    private static let rightClustersKey = "Safarium.Toolbar.RightClusters.v1"

    // Legacy v1 migration keys
    private static let v1HiddenDefaultsKey = "Safarium.Toolbar.HiddenNativeIDs.v1"
    private static let v1EnabledExtrasKey = "Safarium.Toolbar.EnabledExtraIDs.v1"

    private(set) var hiddenDefaultIDs: Set<CustomizableToolbarItemID>
    private(set) var leftActionOrder: [CustomizableToolbarItemID]
    private(set) var rightActionOrder: [CustomizableToolbarItemID]
    private(set) var leftSpacers: [CustomizableToolbarItemID]
    private(set) var rightSpacers: [CustomizableToolbarItemID]
    /// The Privacy Report shield sits left of the address bar by default. Once the user removes it (sheet toggle or
    /// dragging it off the toolbar) this stays true until it is added back or the toolbar is reset.
    private(set) var standaloneShieldRemoved: Bool
    /// Left-to-right order of the free-standing clusters before / after the address bar.
    private(set) var leftClusters: [ToolbarCluster]
    private(set) var rightClusters: [ToolbarCluster]

    init() {
        let ud = UserDefaults.standard
        self.standaloneShieldRemoved = ud.bool(forKey: Self.shieldRemovedKey)
        let savedLeft = ud.stringArray(forKey: Self.leftClustersKey)
        let savedRight = ud.stringArray(forKey: Self.rightClustersKey)
        (self.leftClusters, self.rightClusters) = Self.normalizedClusters(
            left: savedLeft?.compactMap { ToolbarCluster(rawValue: $0) } ?? Self.defaultLeftClusters,
            right: savedRight?.compactMap { ToolbarCluster(rawValue: $0) } ?? []
        )
        if ud.object(forKey: Self.rightOrderKey) != nil {
            let rawHidden = ud.stringArray(forKey: Self.hiddenDefaultsKey) ?? []
            self.hiddenDefaultIDs = Set(rawHidden.compactMap { CustomizableToolbarItemID(rawValue: $0) })
            self.leftActionOrder = (ud.stringArray(forKey: Self.leftOrderKey) ?? [])
                .compactMap { CustomizableToolbarItemID(rawValue: $0) }
                .filter(\.isMovableAction)
            self.rightActionOrder = (ud.stringArray(forKey: Self.rightOrderKey) ?? [])
                .compactMap { CustomizableToolbarItemID(rawValue: $0) }
                .filter(\.isMovableAction)
            self.leftSpacers = (ud.stringArray(forKey: Self.leftSpacersKey) ?? [])
                .compactMap { CustomizableToolbarItemID(rawValue: $0) }
                .filter(\.isSpacer)
            self.rightSpacers = (ud.stringArray(forKey: Self.rightSpacersKey) ?? [])
                .compactMap { CustomizableToolbarItemID(rawValue: $0) }
                .filter(\.isSpacer)
        } else {
            let rawHidden = ud.stringArray(forKey: Self.v1HiddenDefaultsKey) ?? []
            let oldHidden = Set(rawHidden.compactMap { CustomizableToolbarItemID(rawValue: $0) })
            let oldExtras = (ud.stringArray(forKey: Self.v1EnabledExtrasKey) ?? [])
                .compactMap { CustomizableToolbarItemID(rawValue: $0) }
                .filter(\.isMovableAction)
            self.hiddenDefaultIDs = oldHidden.filter { !$0.isMovableAction }
            self.leftActionOrder = []
            var rightOrder = oldExtras
            for def in CustomizableToolbarItemID.defaultRightActionOrder where !oldHidden.contains(def) && !rightOrder.contains(def) {
                rightOrder.append(def)
            }
            self.rightActionOrder = rightOrder
            self.leftSpacers = []
            self.rightSpacers = []
        }
    }

    static let defaultLeftClusters: [ToolbarCluster] = [.sidebar, .backForward, .privacyShield]

    /// Every cluster appears exactly once; the sidebar toggle stays outermost when on the left (the sidebar pane
    /// slides in underneath that edge).
    static func normalizedClusters(left: [ToolbarCluster], right: [ToolbarCluster]) -> ([ToolbarCluster], [ToolbarCluster]) {
        var seen = Set<ToolbarCluster>()
        var l = left.filter { seen.insert($0).inserted }
        let r = right.filter { seen.insert($0).inserted }
        for c in ToolbarCluster.allCases where !seen.contains(c) {
            // Unknown/missing entries fall back to their default (left) spot.
            l.append(c)
        }
        if let i = l.firstIndex(of: .sidebar), i != 0 {
            l.remove(at: i)
            l.insert(.sidebar, at: 0)
        }
        return (l, r)
    }

    func clusterSide(_ cluster: ToolbarCluster) -> ToolbarActionSide {
        rightClusters.contains(cluster) ? .right : .left
    }

    /// Moves a cluster to `side` at `index` among that side's clusters (nil = outermost end of the side's list).
    func placeCluster(_ cluster: ToolbarCluster, on side: ToolbarActionSide, at index: Int? = nil) {
        var l = leftClusters.filter { $0 != cluster }
        var r = rightClusters.filter { $0 != cluster }
        switch side {
        case .left:
            l.insert(cluster, at: index.map { max(0, min(l.count, $0)) } ?? l.count)
        case .right:
            r.insert(cluster, at: index.map { max(0, min(r.count, $0)) } ?? r.count)
        }
        if cluster == .privacyShield {
            // Putting the shield somewhere brings back the default shield and takes it out of any action capsule.
            standaloneShieldRemoved = false
            leftActionOrder.removeAll { $0 == .privacyReport }
            rightActionOrder.removeAll { $0 == .privacyReport }
        }
        (leftClusters, rightClusters) = Self.normalizedClusters(left: l, right: r)
        persistAndNotify()
    }

    /// Re-splits the clusters around a new address-bar position: those in `toRight` go behind the bar, the rest stay
    /// in front of it, each keeping its relative order.
    func splitClusters(movingToRight toRight: Set<ToolbarCluster>) {
        let all = leftClusters + rightClusters
        let l = all.filter { !toRight.contains($0) }
        let r = all.filter { toRight.contains($0) }
        (leftClusters, rightClusters) = Self.normalizedClusters(left: l, right: r)
        persistAndNotify()
    }

    var leftSpacerExtraWidth: CGFloat {
        leftSpacers.reduce(0) { $0 + ($1 == .flexibleSpace ? 56.0 : 24.0) }
    }

    var rightSpacerExtraWidth: CGFloat {
        rightSpacers.reduce(0) { $0 + ($1 == .flexibleSpace ? 56.0 : 24.0) }
    }

    func side(for id: CustomizableToolbarItemID) -> ToolbarActionSide? {
        if leftActionOrder.contains(id) { return .left }
        if rightActionOrder.contains(id) { return .right }
        return nil
    }

    /// True while the default (non-capsule) Privacy Report shield should be drawn left of the address bar.
    var showsStandalonePrivacyShield: Bool {
        !standaloneShieldRemoved && !leftActionOrder.contains(.privacyReport) && !rightActionOrder.contains(.privacyReport)
    }

    func isVisibleInToolbar(_ id: CustomizableToolbarItemID) -> Bool {
        if id == .privacyReport {
            return leftActionOrder.contains(id) || rightActionOrder.contains(id) || !standaloneShieldRemoved
        }
        if id.isMovableAction {
            return leftActionOrder.contains(id) || rightActionOrder.contains(id)
        }
        if id.isSpacer {
            return leftSpacers.contains(id) || rightSpacers.contains(id)
        }
        return !hiddenDefaultIDs.contains(id)
    }

    func placeAction(_ id: CustomizableToolbarItemID, on side: ToolbarActionSide, at index: Int? = nil) {
        guard id.isMovableAction else { return }
        leftActionOrder.removeAll { $0 == id }
        rightActionOrder.removeAll { $0 == id }
        if id == .privacyReport { standaloneShieldRemoved = false }

        switch side {
        case .left:
            let idx = index.map { max(0, min(leftActionOrder.count, $0)) } ?? leftActionOrder.count
            leftActionOrder.insert(id, at: idx)
        case .right:
            let idx = index.map { max(0, min(rightActionOrder.count, $0)) } ?? rightActionOrder.count
            rightActionOrder.insert(id, at: idx)
        }
        persistAndNotify()
    }

    func removeAction(_ id: CustomizableToolbarItemID) {
        guard id.isMovableAction else { return }
        if id == .privacyReport { standaloneShieldRemoved = true }
        leftActionOrder.removeAll { $0 == id }
        rightActionOrder.removeAll { $0 == id }
        persistAndNotify()
    }

    func addSpacer(_ id: CustomizableToolbarItemID, on side: ToolbarActionSide) {
        guard id.isSpacer else { return }
        switch side {
        case .left:
            if leftSpacers.count < 3 { leftSpacers.append(id) }
        case .right:
            if rightSpacers.count < 3 { rightSpacers.append(id) }
        }
        persistAndNotify()
    }

    func removeSpacers(of id: CustomizableToolbarItemID) {
        leftSpacers.removeAll { $0 == id }
        rightSpacers.removeAll { $0 == id }
        persistAndNotify()
    }

    func setVisible(_ visible: Bool, for id: CustomizableToolbarItemID) {
        if id == .privacyReport, visible {
            // Back to its default spot (the standalone shield) unless it already lives in an action capsule.
            if !leftActionOrder.contains(id) && !rightActionOrder.contains(id) {
                standaloneShieldRemoved = false
                persistAndNotify()
            }
            return
        }
        if id.isMovableAction {
            if visible {
                if !isVisibleInToolbar(id) {
                    if let defaultIdx = CustomizableToolbarItemID.defaultRightActionOrder.firstIndex(of: id) {
                        placeAction(id, on: .right, at: min(defaultIdx, rightActionOrder.count))
                    } else {
                        placeAction(id, on: .right, at: 0)
                    }
                    return
                }
            } else {
                removeAction(id)
                return
            }
        } else if id.isSpacer {
            if visible {
                addSpacer(id, on: .left)
            } else {
                removeSpacers(of: id)
            }
            return
        } else {
            if visible {
                hiddenDefaultIDs.remove(id)
            } else {
                hiddenDefaultIDs.insert(id)
            }
        }
        persistAndNotify()
    }

    func toggle(_ id: CustomizableToolbarItemID) {
        setVisible(!isVisibleInToolbar(id), for: id)
    }

    func resetToDefaults() {
        hiddenDefaultIDs.removeAll()
        standaloneShieldRemoved = false
        leftClusters = Self.defaultLeftClusters
        rightClusters = []
        leftActionOrder = []
        rightActionOrder = CustomizableToolbarItemID.defaultRightActionOrder
        leftSpacers = []
        rightSpacers = []
        persistAndNotify()
    }

    private func persistAndNotify() {
        let ud = UserDefaults.standard
        ud.set(hiddenDefaultIDs.map(\.rawValue), forKey: Self.hiddenDefaultsKey)
        ud.set(leftActionOrder.map(\.rawValue), forKey: Self.leftOrderKey)
        ud.set(rightActionOrder.map(\.rawValue), forKey: Self.rightOrderKey)
        ud.set(leftSpacers.map(\.rawValue), forKey: Self.leftSpacersKey)
        ud.set(rightSpacers.map(\.rawValue), forKey: Self.rightSpacersKey)
        ud.set(standaloneShieldRemoved, forKey: Self.shieldRemovedKey)
        ud.set(leftClusters.map(\.rawValue), forKey: Self.leftClustersKey)
        ud.set(rightClusters.map(\.rawValue), forKey: Self.rightClustersKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// Native macOS 27 Tahoe Safari "Customize Toolbar…" sheet (1:1 visual & animation fidelity):
/// - Full-width smooth frosted translucent sheet materializing in place right beneath the 52pt toolbar
/// - Zero backdrop dim over the webpage below
/// - Bare floating SF Symbol & extension glyphs (no circle borders, no blue dots); items already in the
///   toolbar dim cleanly to 0.34 alpha while available items stay crisp at 1.0
/// - EVERY element (core controls, optional actions, Address & Search, extensions, Flexible Space, Space)
///   can be clicked to toggle OR dragged directly onto any position in the toolbar.
final class CustomizeToolbarSheetView: NSView {
    var onToggleNativeItem: ((CustomizableToolbarItemID, Bool) -> Void)?
    var onDropNativeItem: ((CustomizableToolbarItemID, NSPoint) -> Void)?
    var onToggleExtension: ((BrowserExtensionItem, Bool) -> Void)?
    var onDropExtension: ((BrowserExtensionItem, NSPoint) -> Void)?
    var onResetDefaultSet: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// Window-coordinate rect of the toolbar so drag-up drops commit when released on the toolbar.
    var toolbarRectInWindowProvider: (() -> NSRect)?

    private(set) var isPresented: Bool = false
    private var isDarkMode: Bool = false
    private var extensions: [BrowserExtensionItem] = []
    private var hiddenExtensionIDs = Set<String>()

    private let backdropHitCatcher = NSView()
    private let sheetClipContainer = NSView()
    private let sheetCard = NSView()
    private let sheetFrostView = NSVisualEffectView()
    private let sheetTintView = NSView()
    private let sheetContentHost = NSView()
    private var sheetTopConstraint: NSLayoutConstraint?
    private var sheetHeightConstraint: NSLayoutConstraint?

    private let headerLabel = NSTextField(labelWithString: "Drag your favorite items into the toolbar…")
    private let paletteCanvas = FlippedCustomizeCanvas()
    private var paletteHeightConstraint: NSLayoutConstraint?
    private let defaultHeaderLabel = NSTextField(labelWithString: "… or drag the default set into the toolbar.")
    private let defaultSetStrip = CustomizeDefaultSetStripView()
    private let doneButton = NSButton()

    private var tileViews: [CustomizePaletteTileView] = []

    private var dragGhostView: NSView?
    private var draggedPayload: DragPayload?

    private enum DragPayload {
        case native(CustomizableToolbarItemID)
        case ext(BrowserExtensionItem)
        case defaultSet
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true

        // Transparent click-outside dismissal catcher (zero dark wash over the webpage)
        backdropHitCatcher.translatesAutoresizingMaskIntoConstraints = false
        backdropHitCatcher.wantsLayer = true
        backdropHitCatcher.layer?.backgroundColor = NSColor.clear.cgColor
        let backdropClick = NSClickGestureRecognizer(target: self, action: #selector(handleBackdropClick))
        backdropHitCatcher.addGestureRecognizer(backdropClick)
        addSubview(backdropHitCatcher)

        // Clips sheetCard right at the bottom edge of the 52pt toolbar
        sheetClipContainer.translatesAutoresizingMaskIntoConstraints = false
        sheetClipContainer.wantsLayer = true
        sheetClipContainer.layer?.masksToBounds = true
        addSubview(sheetClipContainer)

        sheetCard.translatesAutoresizingMaskIntoConstraints = false
        sheetCard.wantsLayer = true
        sheetCard.layer?.cornerRadius = 22.0
        sheetCard.layer?.cornerCurve = .continuous
        sheetCard.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetCard.layer?.shadowColor = NSColor.black.cgColor
        sheetCard.layer?.shadowOpacity = 0.30
        sheetCard.layer?.shadowRadius = 28.0
        sheetCard.layer?.shadowOffset = CGSize(width: 0, height: -10)
        sheetClipContainer.addSubview(sheetCard)

        sheetFrostView.translatesAutoresizingMaskIntoConstraints = false
        sheetFrostView.material = .hudWindow
        sheetFrostView.blendingMode = .withinWindow
        sheetFrostView.state = .active
        sheetFrostView.wantsLayer = true
        sheetFrostView.layer?.cornerRadius = 22.0
        sheetFrostView.layer?.cornerCurve = .continuous
        sheetFrostView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetFrostView.layer?.masksToBounds = true
        sheetCard.addSubview(sheetFrostView)

        sheetTintView.translatesAutoresizingMaskIntoConstraints = false
        sheetTintView.wantsLayer = true
        sheetTintView.layer?.cornerRadius = 22.0
        sheetTintView.layer?.cornerCurve = .continuous
        sheetTintView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetTintView.layer?.masksToBounds = true
        sheetFrostView.addSubview(sheetTintView)

        sheetContentHost.translatesAutoresizingMaskIntoConstraints = false
        sheetContentHost.wantsLayer = true
        sheetContentHost.layer?.backgroundColor = NSColor.clear.cgColor
        sheetFrostView.addSubview(sheetContentHost)

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
        sheetContentHost.addSubview(headerLabel)

        paletteCanvas.translatesAutoresizingMaskIntoConstraints = false
        paletteCanvas.wantsLayer = true
        sheetContentHost.addSubview(paletteCanvas)

        defaultHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        defaultHeaderLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
        sheetContentHost.addSubview(defaultHeaderLabel)

        defaultSetStrip.translatesAutoresizingMaskIntoConstraints = false
        defaultSetStrip.onClickReset = { [weak self] in
            self?.performResetDefaultSet()
        }
        defaultSetStrip.onDragBegan = { [weak self] event in
            self?.beginDefaultSetDrag(event)
        }
        defaultSetStrip.onDragChanged = { [weak self] event in
            self?.updateDrag(event)
        }
        defaultSetStrip.onDragEnded = { [weak self] event in
            self?.endDrag(event)
        }
        sheetContentHost.addSubview(defaultSetStrip)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.title = "Done"
        doneButton.isBordered = false
        doneButton.wantsLayer = true
        doneButton.layer?.backgroundColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0).cgColor
        doneButton.layer?.cornerRadius = 14.0
        doneButton.layer?.cornerCurve = .continuous
        doneButton.target = self
        doneButton.action = #selector(handleDoneClick)
        doneButton.attributedTitle = NSAttributedString(
            string: "Done",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13.0, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        sheetContentHost.addSubview(doneButton)

        let topC = sheetCard.topAnchor.constraint(equalTo: sheetClipContainer.topAnchor, constant: 0)
        let heightC = sheetCard.heightAnchor.constraint(equalToConstant: 424)
        let palH = paletteCanvas.heightAnchor.constraint(equalToConstant: 214)
        self.sheetTopConstraint = topC
        self.sheetHeightConstraint = heightC
        self.paletteHeightConstraint = palH

        let cardLeading = sheetCard.leadingAnchor.constraint(equalTo: sheetClipContainer.leadingAnchor, constant: 6)
        cardLeading.priority = .defaultHigh
        let cardTrailing = sheetCard.trailingAnchor.constraint(equalTo: sheetClipContainer.trailingAnchor, constant: -6)
        cardTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backdropHitCatcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropHitCatcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropHitCatcher.topAnchor.constraint(equalTo: topAnchor),
            backdropHitCatcher.bottomAnchor.constraint(equalTo: bottomAnchor),

            sheetClipContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sheetClipContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            sheetClipContainer.topAnchor.constraint(equalTo: topAnchor),
            sheetClipContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            sheetCard.centerXAnchor.constraint(equalTo: sheetClipContainer.centerXAnchor),
            sheetCard.widthAnchor.constraint(lessThanOrEqualToConstant: 1360),
            sheetCard.leadingAnchor.constraint(greaterThanOrEqualTo: sheetClipContainer.leadingAnchor, constant: 6),
            sheetCard.trailingAnchor.constraint(lessThanOrEqualTo: sheetClipContainer.trailingAnchor, constant: -6),
            cardLeading,
            cardTrailing,
            topC,
            heightC,

            sheetFrostView.leadingAnchor.constraint(equalTo: sheetCard.leadingAnchor),
            sheetFrostView.trailingAnchor.constraint(equalTo: sheetCard.trailingAnchor),
            sheetFrostView.topAnchor.constraint(equalTo: sheetCard.topAnchor),
            sheetFrostView.bottomAnchor.constraint(equalTo: sheetCard.bottomAnchor),

            sheetTintView.leadingAnchor.constraint(equalTo: sheetFrostView.leadingAnchor),
            sheetTintView.trailingAnchor.constraint(equalTo: sheetFrostView.trailingAnchor),
            sheetTintView.topAnchor.constraint(equalTo: sheetFrostView.topAnchor),
            sheetTintView.bottomAnchor.constraint(equalTo: sheetFrostView.bottomAnchor),

            sheetContentHost.leadingAnchor.constraint(equalTo: sheetFrostView.leadingAnchor),
            sheetContentHost.trailingAnchor.constraint(equalTo: sheetFrostView.trailingAnchor),
            sheetContentHost.topAnchor.constraint(equalTo: sheetFrostView.topAnchor),
            sheetContentHost.bottomAnchor.constraint(equalTo: sheetFrostView.bottomAnchor),

            headerLabel.leadingAnchor.constraint(equalTo: sheetContentHost.leadingAnchor, constant: 24),
            headerLabel.topAnchor.constraint(equalTo: sheetContentHost.topAnchor, constant: 18),

            paletteCanvas.leadingAnchor.constraint(equalTo: sheetContentHost.leadingAnchor, constant: 16),
            paletteCanvas.trailingAnchor.constraint(equalTo: sheetContentHost.trailingAnchor, constant: -16),
            paletteCanvas.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 14),
            palH,

            defaultHeaderLabel.leadingAnchor.constraint(equalTo: sheetContentHost.leadingAnchor, constant: 24),
            defaultHeaderLabel.topAnchor.constraint(equalTo: paletteCanvas.bottomAnchor, constant: 14),

            defaultSetStrip.leadingAnchor.constraint(equalTo: sheetContentHost.leadingAnchor, constant: 20),
            defaultSetStrip.trailingAnchor.constraint(equalTo: sheetContentHost.trailingAnchor, constant: -20),
            defaultSetStrip.topAnchor.constraint(equalTo: defaultHeaderLabel.bottomAnchor, constant: 10),
            defaultSetStrip.heightAnchor.constraint(equalToConstant: 70),

            doneButton.trailingAnchor.constraint(equalTo: sheetContentHost.trailingAnchor, constant: -22),
            doneButton.bottomAnchor.constraint(equalTo: sheetContentHost.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(equalToConstant: 72),
            doneButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    func topCenteredScaleTransform(scale: CGFloat, translateY: CGFloat) -> CATransform3D {
        let cx = sheetCard.bounds.width * 0.5
        let topY = sheetCard.bounds.height
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx, topY + translateY, 0)
        t = CATransform3DScale(t, scale, scale, 1.0)
        t = CATransform3DTranslate(t, -cx, -topY, 0)
        return t
    }

    func present(extensions: [BrowserExtensionItem], hiddenExtensionIDs: Set<String>, isDark: Bool) {
        self.extensions = extensions.filter(\.enabled)
        self.hiddenExtensionIDs = hiddenExtensionIDs
        self.isDarkMode = isDark
        applyAppearance()
        rebuildPalette()
        defaultSetStrip.configure(extensions: self.extensions, isDark: isDark)

        isHidden = false
        isPresented = true
        sheetCard.layer?.removeAllAnimations()

        superview?.layoutSubtreeIfNeeded()
        layoutPaletteTiles()
        superview?.layoutSubtreeIfNeeded()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheetTopConstraint?.constant = -12.0
        sheetCard.alphaValue = 0.0
        sheetCard.layer?.transform = topCenteredScaleTransform(scale: 0.975, translateY: 0.0)
        sheetClipContainer.layoutSubtreeIfNeeded()
        CATransaction.commit()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented else { return }
            if MotionPreference.reduced {  // Reduce Motion: show the sheet in its final state, no slide/scale
                self.sheetTopConstraint?.constant = 0.0
                self.sheetCard.alphaValue = 1.0
                self.sheetCard.layer?.transform = CATransform3DIdentity
                self.sheetClipContainer.layoutSubtreeIfNeeded()
                return
            }
            let timing = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            if let cardLayer = self.sheetCard.layer {
                let scaleAnim = CABasicAnimation(keyPath: "transform")
                scaleAnim.fromValue = NSValue(caTransform3D: self.topCenteredScaleTransform(scale: 0.975, translateY: 0.0))
                scaleAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                scaleAnim.duration = 0.36
                scaleAnim.timingFunction = timing
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                cardLayer.transform = CATransform3DIdentity
                CATransaction.commit()
                cardLayer.add(scaleAnim, forKey: "sxSheetOpenScale")
            }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.36
                ctx.timingFunction = timing
                ctx.allowsImplicitAnimation = true
                self.sheetTopConstraint?.animator().constant = 0.0
                self.sheetCard.animator().alphaValue = 1.0
                self.sheetClipContainer.layoutSubtreeIfNeeded()
            }
        }
    }

    func refreshState(extensions: [BrowserExtensionItem], hiddenExtensionIDs: Set<String>, isDark: Bool) {
        self.extensions = extensions.filter(\.enabled)
        self.hiddenExtensionIDs = hiddenExtensionIDs
        self.isDarkMode = isDark
        guard isPresented else { return }
        applyAppearance()
        rebuildPalette()
        defaultSetStrip.configure(extensions: self.extensions, isDark: isDark)
    }

    func dismiss(animated: Bool = true) {
        guard isPresented || !isHidden else { return }
        isPresented = false
        clearDragGhost()
        if !animated || MotionPreference.reduced {
            sheetCard.layer?.removeAllAnimations()
            sheetCard.layer?.transform = CATransform3DIdentity
            sheetCard.alphaValue = 0.0
            sheetTopConstraint?.constant = 0.0
            isHidden = true
            onDismiss?()
            return
        }

        let timing = CAMediaTimingFunction(controlPoints: 0.40, 0.0, 1.0, 1.0)
        if let cardLayer = sheetCard.layer {
            let endT = topCenteredScaleTransform(scale: 0.975, translateY: 0.0)
            let scaleAnim = CABasicAnimation(keyPath: "transform")
            scaleAnim.fromValue = NSValue(caTransform3D: cardLayer.presentation()?.transform ?? cardLayer.transform)
            scaleAnim.toValue = NSValue(caTransform3D: endT)
            scaleAnim.duration = 0.24
            scaleAnim.timingFunction = timing
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cardLayer.transform = endT
            CATransaction.commit()
            cardLayer.add(scaleAnim, forKey: "sxSheetCloseScale")
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            self.sheetTopConstraint?.animator().constant = -12.0
            self.sheetCard.animator().alphaValue = 0.0
            self.sheetClipContainer.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, !self.isPresented else { return }
            self.isHidden = true
            self.sheetCard.layer?.removeAllAnimations()
            self.sheetCard.layer?.transform = CATransform3DIdentity
            self.sheetTopConstraint?.constant = 0.0
            self.onDismiss?()
        })
    }

    private func applyAppearance() {
        let dark = isDarkMode
        sheetFrostView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        sheetFrostView.material = dark ? .hudWindow : .popover
        sheetTintView.layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0.11, green: 0.115, blue: 0.13, alpha: 0.36)
            : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.985, alpha: 0.42)).cgColor
        sheetTintView.layer?.borderWidth = 0.75
        sheetTintView.layer?.borderColor = (dark
            ? NSColor.white.withAlphaComponent(0.15)
            : NSColor.black.withAlphaComponent(0.10)).cgColor

        let titleColor = dark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.10, alpha: 1.0)
        headerLabel.textColor = titleColor
        defaultHeaderLabel.textColor = titleColor
    }

    private func rebuildPalette() {
        for v in tileViews { v.removeFromSuperview() }
        tileViews.removeAll()

        let store = ToolbarCustomizationStore.shared

        func makeNativeTile(_ nativeID: CustomizableToolbarItemID, kindOverride: CustomizePaletteTileView.Kind? = nil) -> CustomizePaletteTileView {
            let active = store.isVisibleInToolbar(nativeID)
            let resolvedKind: CustomizePaletteTileView.Kind
            if let kindOverride {
                resolvedKind = kindOverride
            } else if nativeID == .backForward {
                resolvedKind = .backForwardPair
            } else if nativeID == .addressBar {
                resolvedKind = .addressAndSearch
            } else if nativeID == .flexibleSpace {
                resolvedKind = .flexibleSpace
            } else if nativeID == .fixedSpace {
                resolvedKind = .fixedSpace
            } else {
                resolvedKind = .symbol(nativeID.symbolName)
            }

            let tile = CustomizePaletteTileView(
                kind: resolvedKind,
                title: nativeID.label,
                isInToolbar: active && !nativeID.isSpacer,
                isDark: isDarkMode
            )
            tile.onClick = { [weak self] in
                guard let self else { return }
                let nextVisible = !ToolbarCustomizationStore.shared.isVisibleInToolbar(nativeID)
                self.onToggleNativeItem?(nativeID, nextVisible)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                self.rebuildPalette()
            }
            tile.onDragBegan = { [weak self, weak tile] event in
                guard let self, let tile else { return }
                self.beginTileDrag(payload: .native(nativeID), sourceTile: tile, event: event)
            }
            tile.onDragChanged = { [weak self] event in self?.updateDrag(event) }
            tile.onDragEnded = { [weak self] event in self?.endDrag(event) }
            return tile
        }

        // Row 1: Core & navigation actions
        for nativeID in CustomizableToolbarItemID.row1Order {
            tileViews.append(makeNativeTile(nativeID))
        }

        // Row 2: Secondary actions + Address and Search + Installed Extensions
        for nativeID in CustomizableToolbarItemID.row2LeadingOrder {
            tileViews.append(makeNativeTile(nativeID))
        }

        tileViews.append(makeNativeTile(.addressBar, kindOverride: .addressAndSearch))

        for ext in extensions {
            let active = !hiddenExtensionIDs.contains(ext.id)
            let tile = CustomizePaletteTileView(
                kind: .extensionIcon(ext.icon),
                title: ext.name,
                isInToolbar: active,
                isDark: isDarkMode
            )
            tile.onClick = { [weak self] in
                guard let self else { return }
                let currentlyInToolbar = !self.hiddenExtensionIDs.contains(ext.id)
                let nextVisible = !currentlyInToolbar
                if nextVisible {
                    self.hiddenExtensionIDs.remove(ext.id)
                } else {
                    self.hiddenExtensionIDs.insert(ext.id)
                }
                self.onToggleExtension?(ext, nextVisible)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                self.rebuildPalette()
            }
            tile.onDragBegan = { [weak self, weak tile] event in
                guard let self, let tile else { return }
                self.beginTileDrag(payload: .ext(ext), sourceTile: tile, event: event)
            }
            tile.onDragChanged = { [weak self] event in self?.updateDrag(event) }
            tile.onDragEnded = { [weak self] event in self?.endDrag(event) }
            tileViews.append(tile)
        }

        // Row 3: Spacers (draggable AND clickable!)
        tileViews.append(makeNativeTile(.flexibleSpace, kindOverride: .flexibleSpace))
        tileViews.append(makeNativeTile(.fixedSpace, kindOverride: .fixedSpace))

        for v in tileViews {
            paletteCanvas.addSubview(v)
        }
        layoutPaletteTiles()
    }

    override func layout() {
        super.layout()
        layoutPaletteTiles()
    }

    func layoutPaletteTiles() {
        let availW = max(560, paletteCanvas.bounds.width > 10 ? paletteCanvas.bounds.width : (bounds.width - 52))
        let padX: CGFloat = 8
        let padY: CGFloat = 4
        let gapX: CGFloat = 14
        let gapY: CGFloat = 16
        let tileH: CGFloat = 66

        var x = padX
        var y = padY
        for tile in tileViews {
            let w = tile.preferredTileWidth
            if x + w > availW - padX && x > padX {
                x = padX
                y += tileH + gapY
            }
            tile.frame = NSRect(x: x, y: y, width: w, height: tileH)
            x += w + gapX
        }
        let neededPaletteH = max(144, y + tileH + padY)
        if abs((paletteHeightConstraint?.constant ?? 0) - neededPaletteH) > 0.5 {
            paletteHeightConstraint?.constant = neededPaletteH
        }
        let neededSheetH = min(max(356, 220 + neededPaletteH), max(356, bounds.height - 20))
        if abs((sheetHeightConstraint?.constant ?? 0) - neededSheetH) > 0.5 {
            sheetHeightConstraint?.constant = neededSheetH
        }
    }

    // MARK: - Drag from Sheet into Toolbar

    private func beginTileDrag(payload: DragPayload, sourceTile: CustomizePaletteTileView, event: NSEvent) {
        clearDragGhost()
        draggedPayload = payload
        guard let win = window, let contentView = win.contentView else { return }

        let ghost = sourceTile.makeFloatingDragSnapshot()
        let ptInContent = contentView.convert(event.locationInWindow, from: nil)
        ghost.frame = NSRect(
            x: round(ptInContent.x - ghost.bounds.width * 0.5),
            y: round(ptInContent.y - ghost.bounds.height * 0.5),
            width: ghost.bounds.width,
            height: ghost.bounds.height
        )
        contentView.addSubview(ghost)
        dragGhostView = ghost
        NSCursor.closedHand.push()
    }

    private func beginDefaultSetDrag(_ event: NSEvent) {
        clearDragGhost()
        draggedPayload = .defaultSet
        guard let win = window, let contentView = win.contentView else { return }

        let rep = defaultSetStrip.bitmapImageRepForCachingDisplay(in: defaultSetStrip.bounds)
        let ghost = NSImageView(frame: NSRect(x: 0, y: 0, width: min(680, defaultSetStrip.bounds.width), height: 62))
        if let rep {
            defaultSetStrip.cacheDisplay(in: defaultSetStrip.bounds, to: rep)
            let img = NSImage(size: defaultSetStrip.bounds.size)
            img.addRepresentation(rep)
            ghost.image = img
            ghost.imageScaling = .scaleProportionallyDown
        }
        ghost.wantsLayer = true
        ghost.alphaValue = 0.90
        let ptInContent = contentView.convert(event.locationInWindow, from: nil)
        ghost.frame.origin = NSPoint(
            x: round(ptInContent.x - ghost.bounds.width * 0.5),
            y: round(ptInContent.y - ghost.bounds.height * 0.5)
        )
        contentView.addSubview(ghost)
        dragGhostView = ghost
        NSCursor.closedHand.push()
    }

    private func updateDrag(_ event: NSEvent) {
        guard let ghost = dragGhostView, let contentView = window?.contentView else { return }
        let pt = contentView.convert(event.locationInWindow, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.frame.origin = NSPoint(
            x: round(pt.x - ghost.bounds.width * 0.5),
            y: round(pt.y - ghost.bounds.height * 0.5)
        )
        CATransaction.commit()
    }

    private func endDrag(_ event: NSEvent) {
        defer {
            clearDragGhost()
            draggedPayload = nil
        }
        guard let payload = draggedPayload else { return }
        let ptWin = event.locationInWindow
        let toolbarRect = toolbarRectInWindowProvider?() ?? NSRect(
            x: 0,
            y: (window?.frame.height ?? 800) - 72,
            width: window?.frame.width ?? 1200,
            height: 72
        )
        let droppedOnToolbar = toolbarRect.insetBy(dx: -16, dy: -24).contains(ptWin)
        guard droppedOnToolbar else { return }

        switch payload {
        case .native(let id):
            if let onDropNativeItem {
                onDropNativeItem(id, ptWin)
            } else {
                onToggleNativeItem?(id, true)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            rebuildPalette()
        case .ext(let ext):
            hiddenExtensionIDs.remove(ext.id)
            if let onDropExtension {
                onDropExtension(ext, ptWin)
            } else {
                onToggleExtension?(ext, true)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            rebuildPalette()
        case .defaultSet:
            performResetDefaultSet()
        }
    }

    private func clearDragGhost() {
        if dragGhostView != nil {
            dragGhostView?.removeFromSuperview()
            dragGhostView = nil
            NSCursor.pop()
        }
    }

    private func performResetDefaultSet() {
        hiddenExtensionIDs.removeAll()
        onResetDefaultSet?()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        rebuildPalette()
    }

    @objc private func handleDoneClick() {
        dismiss(animated: true)
    }

    @objc private func handleBackdropClick() {
        dismiss(animated: true)
    }
}

// MARK: - Supporting Sheet Views

private final class FlippedCustomizeCanvas: NSView {
    override var isFlipped: Bool { true }
}

private final class DashedSpaceBoxView: NSView {
    private let borderLayer = CAShapeLayer()
    private let strokeColor: NSColor

    init(frame: NSRect, strokeColor: NSColor) {
        self.strokeColor = strokeColor
        super.init(frame: frame)
        wantsLayer = true
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = strokeColor.cgColor
        borderLayer.lineWidth = 1.0
        borderLayer.lineDashPattern = [3, 2]
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: 5.5,
            cornerHeight: 5.5,
            transform: nil
        )
    }
}

final class CustomizePaletteTileView: NSView {
    enum Kind {
        case symbol(String)
        case backForwardPair
        case extensionIcon(NSImage?)
        case addressAndSearch
        case flexibleSpace
        case fixedSpace
    }

    var onClick: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?

    let preferredTileWidth: CGFloat

    private let iconStage = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let kind: Kind
    private let isDark: Bool
    private let isInToolbar: Bool

    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    init(kind: Kind, title: String, isInToolbar: Bool, isDark: Bool) {
        self.kind = kind
        self.isDark = isDark
        self.isInToolbar = isInToolbar
        switch kind {
        case .addressAndSearch:
            self.preferredTileWidth = 248
        case .backForwardPair:
            self.preferredTileWidth = 86
        case .flexibleSpace:
            self.preferredTileWidth = 88
        case .fixedSpace:
            self.preferredTileWidth = 64
        case .symbol, .extensionIcon:
            self.preferredTileWidth = 82
        }
        super.init(frame: .zero)
        setup(title: title)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makePillBox(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = cornerRadius
        pill.layer?.cornerCurve = .continuous
        pill.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.055)).cgColor
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.09)).cgColor
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: width),
            pill.heightAnchor.constraint(equalToConstant: height)
        ])
        return pill
    }

    private func setup(title: String) {
        wantsLayer = true
        alphaValue = isInToolbar ? 0.34 : 1.0

        iconStage.translatesAutoresizingMaskIntoConstraints = false
        iconStage.wantsLayer = true
        addSubview(iconStage)

        let inkColor = isDark ? NSColor.white.withAlphaComponent(0.94) : NSColor(white: 0.14, alpha: 1.0)

        switch kind {
        case .symbol(let symbolName):
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            iv.image = AssetLoader.shared.symbol(named: symbolName, pointSize: 21.0, weight: .regular)
            iv.contentTintColor = inkColor
            iconStage.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: iconStage.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: iconStage.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 26),
                iv.heightAnchor.constraint(equalToConstant: 26)
            ])

        case .backForwardPair:
            let pill = makePillBox(width: 62, height: 28, cornerRadius: 14)
            let left = NSImageView()
            left.translatesAutoresizingMaskIntoConstraints = false
            left.image = AssetLoader.shared.symbol(named: "chevron.backward", pointSize: 13.5, weight: .medium)
            left.contentTintColor = inkColor
            let right = NSImageView()
            right.translatesAutoresizingMaskIntoConstraints = false
            right.image = AssetLoader.shared.symbol(named: "chevron.forward", pointSize: 13.5, weight: .medium)
            right.contentTintColor = inkColor
            pill.addSubview(left)
            pill.addSubview(right)
            iconStage.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: iconStage.centerXAnchor),
                pill.centerYAnchor.constraint(equalTo: iconStage.centerYAnchor),
                left.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                left.trailingAnchor.constraint(equalTo: pill.centerXAnchor, constant: -8),
                right.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                right.leadingAnchor.constraint(equalTo: pill.centerXAnchor, constant: 8)
            ])

        case .extensionIcon(let customIcon):
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            if let customIcon {
                iv.image = customIcon
                iv.wantsLayer = true
                iv.layer?.cornerRadius = 4.5
                iv.layer?.cornerCurve = .continuous
                iv.layer?.masksToBounds = true
            } else {
                iv.image = AssetLoader.shared.symbol(named: "puzzlepiece.extension.fill", pointSize: 20.0, weight: .regular)
                iv.contentTintColor = inkColor
            }
            iconStage.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: iconStage.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: iconStage.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 22),
                iv.heightAnchor.constraint(equalToConstant: 22)
            ])

        case .addressAndSearch:
            let bar = makePillBox(width: 234, height: 28, cornerRadius: 14)
            let mag = NSImageView()
            mag.translatesAutoresizingMaskIntoConstraints = false
            mag.image = AssetLoader.shared.symbol(named: "magnifyingglass", pointSize: 11.0, weight: .medium)
            mag.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.45)

            let lbl = NSTextField(labelWithString: "Search or enter website name")
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.font = NSFont.systemFont(ofSize: 11.0, weight: .regular)
            lbl.textColor = isDark ? NSColor.white.withAlphaComponent(0.58) : NSColor.black.withAlphaComponent(0.48)
            lbl.lineBreakMode = .byTruncatingTail

            let hs = NSStackView(views: [mag, lbl])
            hs.translatesAutoresizingMaskIntoConstraints = false
            hs.orientation = .horizontal
            hs.alignment = .centerY
            hs.spacing = 5
            bar.addSubview(hs)
            iconStage.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.centerXAnchor.constraint(equalTo: iconStage.centerXAnchor),
                bar.centerYAnchor.constraint(equalTo: iconStage.centerYAnchor),
                hs.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
                hs.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
            ])

        case .flexibleSpace, .fixedSpace:
            let isFlex: Bool
            if case .flexibleSpace = kind { isFlex = true } else { isFlex = false }
            let box = DashedSpaceBoxView(
                frame: .zero,
                strokeColor: isDark ? NSColor.white.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.24)
            )
            box.translatesAutoresizingMaskIntoConstraints = false
            iconStage.addSubview(box)

            let arrows = NSTextField(labelWithString: isFlex ? "←   →" : "↔")
            arrows.translatesAutoresizingMaskIntoConstraints = false
            arrows.font = NSFont.systemFont(ofSize: 11.0, weight: .medium)
            arrows.textColor = isDark ? NSColor.white.withAlphaComponent(0.68) : NSColor.black.withAlphaComponent(0.54)
            box.addSubview(arrows)
            NSLayoutConstraint.activate([
                box.centerXAnchor.constraint(equalTo: iconStage.centerXAnchor),
                box.centerYAnchor.constraint(equalTo: iconStage.centerYAnchor),
                box.widthAnchor.constraint(equalToConstant: isFlex ? 62 : 30),
                box.heightAnchor.constraint(equalToConstant: 22),
                arrows.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                arrows.centerYAnchor.constraint(equalTo: box.centerYAnchor)
            ])
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        titleLabel.textColor = isDark ? NSColor.white.withAlphaComponent(0.86) : NSColor(white: 0.16, alpha: 1.0)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.usesSingleLineMode = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconStage.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconStage.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconStage.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            iconStage.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            titleLabel.topAnchor.constraint(equalTo: iconStage.bottomAnchor, constant: 5)
        ])
    }

    func makeFloatingDragSnapshot() -> NSView {
        let host = NSImageView(frame: iconStage.bounds)
        host.wantsLayer = true
        host.alphaValue = 0.94
        if let rep = iconStage.bitmapImageRepForCachingDisplay(in: iconStage.bounds) {
            iconStage.cacheDisplay(in: iconStage.bounds, to: rep)
            let img = NSImage(size: iconStage.bounds.size)
            img.addRepresentation(rep)
            host.image = img
        }
        return host
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let dist = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        if !isDragging && dist > 5.0 {
            isDragging = true
            onDragBegan?(event)
        }
        if isDragging {
            onDragChanged?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            isDragging = false
        }
        if isDragging {
            onDragEnded?(event)
        } else if mouseDownPoint != nil {
            onClick?()
        }
    }
}

private final class CustomizeDefaultSetStripView: NSView {
    var onClickReset: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?

    private let stack = NSStackView()
    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14.0
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.0

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .gravityAreas
        stack.spacing = 12
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(extensions: [BrowserExtensionItem], isDark: Bool) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.02)
            : NSColor.black.withAlphaComponent(0.02)).cgColor
        layer?.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.11)).cgColor

        let ink = isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.14, alpha: 1.0)
        let subInk = isDark ? NSColor.white.withAlphaComponent(0.76) : NSColor(white: 0.26, alpha: 1.0)
        let pillBg = isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.055)
        let pillBorder = isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.09)

        func makeLabeledItem(topView: NSView, label: String) -> NSView {
            let col = NSStackView()
            col.translatesAutoresizingMaskIntoConstraints = false
            col.orientation = .vertical
            col.alignment = .centerX
            col.spacing = 5
            col.addArrangedSubview(topView)

            let lbl = NSTextField(labelWithString: label)
            lbl.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
            lbl.textColor = subInk
            lbl.lineBreakMode = .byTruncatingTail
            lbl.alignment = .center
            lbl.maximumNumberOfLines = 1
            col.addArrangedSubview(lbl)
            return col
        }

        func makeBareGlyph(_ symbol: String) -> NSView {
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.image = AssetLoader.shared.symbol(named: symbol, pointSize: 16.0, weight: .regular)
            iv.contentTintColor = ink
            wrap.addSubview(iv)
            NSLayoutConstraint.activate([
                wrap.widthAnchor.constraint(equalToConstant: 24),
                wrap.heightAnchor.constraint(equalToConstant: 26),
                iv.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
            ])
            return wrap
        }

        func makeBackFwdPill() -> NSView {
            let v = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.wantsLayer = true
            v.layer?.cornerRadius = 13.0
            v.layer?.cornerCurve = .continuous
            v.layer?.backgroundColor = pillBg.cgColor
            v.layer?.borderWidth = 0.5
            v.layer?.borderColor = pillBorder.cgColor
            let hs = NSStackView()
            hs.translatesAutoresizingMaskIntoConstraints = false
            hs.orientation = .horizontal
            hs.spacing = 9
            for sym in ["chevron.backward", "chevron.forward"] {
                let iv = NSImageView()
                iv.image = AssetLoader.shared.symbol(named: sym, pointSize: 12.0, weight: .medium)
                iv.contentTintColor = ink
                hs.addArrangedSubview(iv)
            }
            v.addSubview(hs)
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: 50),
                v.heightAnchor.constraint(equalToConstant: 26),
                hs.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                hs.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            return v
        }

        func makeFlexSpace() -> NSView {
            let box = DashedSpaceBoxView(
                frame: .zero,
                strokeColor: isDark ? NSColor.white.withAlphaComponent(0.24) : NSColor.black.withAlphaComponent(0.20)
            )
            box.translatesAutoresizingMaskIntoConstraints = false
            let arrows = NSTextField(labelWithString: "← →")
            arrows.translatesAutoresizingMaskIntoConstraints = false
            arrows.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            arrows.textColor = subInk
            box.addSubview(arrows)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: 46),
                box.heightAnchor.constraint(equalToConstant: 22),
                arrows.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                arrows.centerYAnchor.constraint(equalTo: box.centerYAnchor)
            ])
            return makeLabeledItem(topView: box, label: "Flexible Space")
        }

        stack.addArrangedSubview(makeLabeledItem(topView: makeBareGlyph("sidebar.left"), label: "Sidebar"))
        stack.addArrangedSubview(makeLabeledItem(topView: makeBackFwdPill(), label: "Back/Forward"))
        stack.addArrangedSubview(makeFlexSpace())

        for ext in extensions.prefix(3) {
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.image = ext.icon ?? AssetLoader.shared.symbol(named: "puzzlepiece.extension.fill", pointSize: 15, weight: .regular)
            iv.imageScaling = .scaleProportionallyDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 4.0
            iv.layer?.masksToBounds = true
            wrap.addSubview(iv)
            NSLayoutConstraint.activate([
                wrap.widthAnchor.constraint(equalToConstant: 24),
                wrap.heightAnchor.constraint(equalToConstant: 26),
                iv.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18),
                iv.heightAnchor.constraint(equalToConstant: 18)
            ])
            stack.addArrangedSubview(makeLabeledItem(topView: wrap, label: ext.name))
        }

        let addr = NSView()
        addr.translatesAutoresizingMaskIntoConstraints = false
        addr.wantsLayer = true
        addr.layer?.cornerRadius = 13.0
        addr.layer?.cornerCurve = .continuous
        addr.layer?.backgroundColor = pillBg.cgColor
        addr.layer?.borderWidth = 0.5
        addr.layer?.borderColor = pillBorder.cgColor
        addr.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let mag = NSImageView()
        mag.translatesAutoresizingMaskIntoConstraints = false
        mag.image = AssetLoader.shared.symbol(named: "magnifyingglass", pointSize: 10.5, weight: .medium)
        mag.contentTintColor = subInk
        let addrLbl = NSTextField(labelWithString: "Search or enter website name")
        addrLbl.translatesAutoresizingMaskIntoConstraints = false
        addrLbl.font = NSFont.systemFont(ofSize: 11.0, weight: .regular)
        addrLbl.textColor = subInk
        let addrInner = NSStackView(views: [mag, addrLbl])
        addrInner.translatesAutoresizingMaskIntoConstraints = false
        addrInner.orientation = .horizontal
        addrInner.spacing = 5
        addr.addSubview(addrInner)
        NSLayoutConstraint.activate([
            addr.heightAnchor.constraint(equalToConstant: 26),
            addr.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            addrInner.centerXAnchor.constraint(equalTo: addr.centerXAnchor),
            addrInner.centerYAnchor.constraint(equalTo: addr.centerYAnchor)
        ])
        let addrCol = makeLabeledItem(topView: addr, label: "Address and Search")
        addrCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(addrCol)

        stack.addArrangedSubview(makeFlexSpace())
        stack.addArrangedSubview(makeLabeledItem(topView: makeBareGlyph("arrow.down.circle"), label: "Downloads"))
        stack.addArrangedSubview(makeLabeledItem(topView: makeBareGlyph("square.and.arrow.up"), label: "Share"))
        stack.addArrangedSubview(makeLabeledItem(topView: makeBareGlyph("plus"), label: "New Tab"))
        stack.addArrangedSubview(makeLabeledItem(topView: makeBareGlyph("square.on.square"), label: "Tab Overview"))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let dist = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        if !isDragging && dist > 6.0 {
            isDragging = true
            onDragBegan?(event)
        }
        if isDragging {
            onDragChanged?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            isDragging = false
        }
        if isDragging {
            onDragEnded?(event)
        } else if mouseDownPoint != nil {
            onClickReset?()
        }
    }
}
