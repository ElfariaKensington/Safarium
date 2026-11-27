import AppKit

/// Unified Liquid Glass toolbar capsule (`NSGlassEffectView` with `effectIsInteractive = true`,
/// `height = 38 pt`, `cornerRadius = 19 pt`) matching macOS 27.3 Safari's exact concentric geometry
/// (`19 pt` radius + `7 pt` top inset = `26 pt` concentric with window corner):
/// - Left Group 1: `[sidebar.left  chevron.down]` (`64 × 38 pt`)
/// - Left Group 2: `[chevron.backward]` (`38 × 38 pt`) or `[chevron.backward  chevron.forward]` (`75 × 38 pt`)
/// - Right Group: `[arrow.down.circle  square.and.arrow.up  plus  square.on.square]` (`155 × 38 pt`)
/// - Sidebar Header: `[plus.square.on.square  sidebar.left]` (`76 × 38 pt`)
final class GlassActionCapsule: NSView {
    struct ActionSpec {
        let id: String
        let symbolName: String
        let title: String?
        let tooltip: String
        let width: CGFloat
        let pointSize: CGFloat
        let weight: NSFont.Weight
        let onClick: () -> Void

        init(
            id: String,
            symbolName: String = "",
            title: String? = nil,
            tooltip: String,
            width: CGFloat,
            pointSize: CGFloat = 16.5,
            weight: NSFont.Weight = .regular,
            onClick: @escaping () -> Void
        ) {
            self.id = id
            self.symbolName = symbolName
            self.title = title
            self.tooltip = tooltip
            self.width = width
            self.pointSize = pointSize
            self.weight = weight
            self.onClick = onClick
        }
    }

    private let glassView: NSView
    private let stackView = NSStackView()
    private var buttons: [String: NSButton] = [:]
    private var actions: [String: () -> Void] = [:]
    private var buttonWidthConstraints: [String: NSLayoutConstraint] = [:]
    private var enabledState: [String: Bool] = [:]
    private var activeState: [String: Bool] = [:]
    private var tintColorOverrides: [String: NSColor] = [:]
    private var totalWidthConstraint: NSLayoutConstraint?
    private var specs: [ActionSpec] = []
    private var hiddenIDs: Set<String> = []
    private var theme: AdaptiveChromeTheme = .defaultLight
    private let forceSystemLightAppearance: Bool
    private let fullSlotHover: Bool

    // Merged extension icon slots + clean invisible drag placeholder (zero ring/circle)
    private var mergedButtons: [String: ExtensionToolbarIconButton] = [:]
    private var mergedButtonConstraints: [String: [NSLayoutConstraint]] = [:]
    private var placeholderView: NSView?
    private var placeholderWidthConstraint: NSLayoutConstraint?

    private let horizontalPadding: CGFloat

    var extensionSlotWidth: CGFloat {
        horizontalPadding == 0 ? 34.0 : 32.0
    }

    var hasMergedExtensions: Bool {
        !mergedButtons.isEmpty
    }

    var hasPlaceholder: Bool {
        placeholderView?.superview != nil
    }

    var currentRequiredWidth: CGFloat {
        let visibleNativeW = specs.reduce(CGFloat(0.0)) { acc, item in
            hiddenIDs.contains(item.id) ? acc : (acc + item.width)
        }
        let extW = CGFloat(mergedButtons.count) * extensionSlotWidth
        let phW: CGFloat = hasPlaceholder ? extensionSlotWidth : 0.0
        let contentW = visibleNativeW + extW + phW
        guard contentW > 0 else { return 0.0 }
        return max(SafariMetrics.glassButtonSize, contentW + horizontalPadding * 2.0)
    }

    init(
        specs: [ActionSpec],
        horizontalPadding: CGFloat = 3.0,
        forceSystemLightAppearance: Bool = false,
        fullSlotHover: Bool = false
    ) {
        self.specs = specs
        self.horizontalPadding = horizontalPadding
        self.forceSystemLightAppearance = forceSystemLightAppearance
        self.fullSlotHover = fullSlotHover

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView()
            gv.style = .regular
            gv.cornerRadius = SafariMetrics.glassButtonCornerRadius
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                gv.effectIsInteractive = true
            }
            #endif
            self.glassView = gv
        } else {
            let vev = NSVisualEffectView()
            vev.material = .hudWindow
            vev.blendingMode = .withinWindow
            vev.wantsLayer = true
            vev.layer?.cornerRadius = SafariMetrics.glassButtonCornerRadius
            self.glassView = vev
        }

        let initialWidth = specs.reduce(horizontalPadding * 2) { $0 + $1.width }
        super.init(frame: NSRect(x: 0, y: 0, width: initialWidth, height: SafariMetrics.glassButtonSize))
        setupHierarchy(initialWidth: initialWidth)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupHierarchy(initialWidth: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let wc = widthAnchor.constraint(equalToConstant: initialWidth)
        // Below `required` so a collapsed (width 0) parent cluster wins quietly instead of AppKit logging an unsatisfiable-constraint break.
        wc.priority = .init(999)
        self.totalWidthConstraint = wc
        NSLayoutConstraint.activate([
            wc,
            heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize)
        ])

        glassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 0
        syncStackEdgeInsets()
        if fullSlotHover {
            stackView.wantsLayer = true
            stackView.layer?.masksToBounds = true
            stackView.layer?.cornerRadius = SafariMetrics.glassButtonCornerRadius
            stackView.layer?.cornerCurve = .continuous
        }

        for spec in specs {
            let btn = HoverableToolbarGlyphButton()
            btn.fullSlotHover = fullSlotHover
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.isBordered = false
            btn.bezelStyle = .regularSquare
            if let title = spec.title {
                btn.title = title
                btn.imagePosition = .noImage
                btn.font = NSFont.systemFont(ofSize: spec.pointSize, weight: spec.weight)
            } else {
                btn.image = AssetLoader.shared.symbol(named: spec.symbolName, pointSize: spec.pointSize, weight: spec.weight)
                btn.imagePosition = .imageOnly
                btn.imageScaling = .scaleProportionallyDown
            }
            btn.toolTip = spec.tooltip
            btn.identifier = NSUserInterfaceItemIdentifier(spec.id)
            btn.target = self
            btn.action = #selector(handleButtonClick(_:))

            let bwc = btn.widthAnchor.constraint(equalToConstant: spec.width)
            let buttonHeight: CGFloat = fullSlotHover ? SafariMetrics.glassButtonSize : (SafariMetrics.glassButtonSize - 4)
            NSLayoutConstraint.activate([
                bwc,
                btn.heightAnchor.constraint(equalToConstant: buttonHeight)
            ])

            buttons[spec.id] = btn
            actions[spec.id] = spec.onClick
            buttonWidthConstraints[spec.id] = bwc
            enabledState[spec.id] = true
            activeState[spec.id] = false
            stackView.addArrangedSubview(btn)
        }
        updateFullSlotHoverCorners()

        if #available(macOS 26.0, *), let gv = glassView as? NSGlassEffectView {
            stackView.translatesAutoresizingMaskIntoConstraints = true
            stackView.autoresizingMask = [.width, .height]
            gv.contentView = stackView
        } else {
            stackView.translatesAutoresizingMaskIntoConstraints = false
            glassView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
                stackView.topAnchor.constraint(equalTo: glassView.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
            ])
        }

        updateAppearance()
    }

    func button(for id: String) -> NSButton? {
        buttons[id]
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        enabledState[id] = enabled
        buttons[id]?.isEnabled = enabled
        updateAppearance()
    }

    func setActive(_ active: Bool, for id: String) {
        activeState[id] = active
        updateAppearance()
    }

    func setTintColorOverride(_ color: NSColor?, for id: String) {
        if let color {
            tintColorOverrides[id] = color
        } else {
            tintColorOverrides.removeValue(forKey: id)
        }
        updateAppearance()
    }

    func setHidden(_ hidden: Bool, for id: String, animated: Bool = true) {
        let wasHidden = hiddenIDs.contains(id)
        guard wasHidden != hidden else { return }
        if hidden {
            hiddenIDs.insert(id)
        } else {
            hiddenIDs.remove(id)
        }

        guard let spec = specs.first(where: { $0.id == id }),
              let btn = buttons[id] else { return }

        let reqW = currentRequiredWidth
        let targetWidth = reqW > 0.5 ? max(SafariMetrics.glassButtonSize, reqW) : 0.0
        syncStackEdgeInsets()

        let apply = {
            btn.isHidden = hidden
            self.buttonWidthConstraints[id]?.constant = hidden ? 0 : spec.width
            self.totalWidthConstraint?.constant = targetWidth
        }

        if animated && window?.isVisible == true && bounds.width > 1.0 {
            layoutSubtreeIfNeeded()
            btn.wantsLayer = true
            if !hidden {
                btn.isHidden = false
                btn.alphaValue = 0.0
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = hidden ? 0.16 : 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 1.0, 0.32, 1.0)
                ctx.allowsImplicitAnimation = true
                btn.animator().alphaValue = hidden ? 0.0 : 1.0
                self.buttonWidthConstraints[id]?.animator().constant = hidden ? 0 : spec.width
                self.totalWidthConstraint?.animator().constant = targetWidth
                self.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self, weak btn] in
                guard let self, let btn else { return }
                if self.hiddenIDs.contains(id) {
                    btn.isHidden = true
                    btn.alphaValue = 1.0
                }
            })
            if let layer = btn.layer {
                let cx = max(16.0, btn.bounds.midX)
                let cy = max(16.0, btn.bounds.midY)
                var scaledT = CATransform3DIdentity
                scaledT = CATransform3DTranslate(scaledT, cx, cy, 0)
                scaledT = CATransform3DScale(scaledT, hidden ? 0.65 : 0.55, hidden ? 0.65 : 0.55, 1.0)
                scaledT = CATransform3DTranslate(scaledT, -cx, -cy, 0)
                if !hidden {
                    let spring = CASpringAnimation(keyPath: "transform")
                    spring.mass = 1.0
                    spring.stiffness = 460.0
                    spring.damping = 28.0
                    spring.initialVelocity = 0.0
                    spring.fromValue = NSValue(caTransform3D: scaledT)
                    spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                    spring.duration = spring.settlingDuration
                    layer.add(spring, forKey: "navPopIn")
                } else {
                    let shrink = CABasicAnimation(keyPath: "transform")
                    shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
                    shrink.toValue = NSValue(caTransform3D: scaledT)
                    shrink.duration = 0.16
                    shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    layer.add(shrink, forKey: "navPopOut")
                }
            }
        } else {
            btn.alphaValue = 1.0
            apply()
        }
        updateFullSlotHoverCorners()
    }

    // MARK: - Merged Extension Icon Slots (Free Drag & Drop into Liquid Glass Button Groups)

    private func syncStackEdgeInsets() {
        let pad = (currentRequiredWidth > 0.5) ? horizontalPadding : 0.0
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: pad, bottom: 0, right: pad)
    }

    private func recalculateTotalWidth(animated: Bool) {
        let reqW = currentRequiredWidth
        let targetWidth = reqW > 0.5 ? max(SafariMetrics.glassButtonSize, reqW) : 0.0
        syncStackEdgeInsets()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.totalWidthConstraint?.animator().constant = targetWidth
            }
        } else {
            totalWidthConstraint?.constant = targetWidth
        }
    }

    private func visibleNonPlaceholderSubviews() -> [NSView] {
        stackView.arrangedSubviews.filter { v in
            guard v !== placeholderView else { return false }
            if let btn = v as? NSButton, let id = btn.identifier?.rawValue, hiddenIDs.contains(id) {
                return false
            }
            return !v.isHidden
        }
    }

    private func rawInsertionIndex(forVisibleIndex visibleIndex: Int) -> Int {
        let visible = visibleNonPlaceholderSubviews()
        let clamped = max(0, min(visible.count, visibleIndex))
        if clamped < visible.count,
           let rawIdx = stackView.arrangedSubviews.firstIndex(where: { $0 === visible[clamped] }) {
            return rawIdx
        }
        return stackView.arrangedSubviews.count
    }

    func orderedSlotTokens() -> [String] {
        var tokens: [String] = []
        for view in stackView.arrangedSubviews {
            if view === placeholderView { continue }
            if let extBtn = view as? ExtensionToolbarIconButton {
                tokens.append("ext:\(extBtn.item.id)")
            } else if let nativeBtn = view as? NSButton, let id = nativeBtn.identifier?.rawValue {
                tokens.append("native:\(id)")
            }
        }
        return tokens
    }

    func anchorExtensionButton(forExtensionID id: String) -> NSView? {
        mergedButtons[id]
    }

    func containsMergedExtension(atWindowPoint ptInWindow: NSPoint) -> Bool {
        guard !isHidden else { return false }
        for btn in mergedButtons.values where !btn.isHidden {
            let local = btn.convert(ptInWindow, from: nil)
            if btn.bounds.contains(local) {
                return true
            }
        }
        return false
    }

    func hitMergedExtensionButton(atWindowPoint ptInWindow: NSPoint) -> (button: ExtensionToolbarIconButton, visibleIndex: Int)? {
        guard !isHidden else { return nil }
        let visible = visibleNonPlaceholderSubviews()
        for (vIdx, view) in visible.enumerated() {
            guard let extBtn = view as? ExtensionToolbarIconButton else { continue }
            let local = extBtn.convert(ptInWindow, from: nil)
            if extBtn.bounds.contains(local) {
                return (extBtn, vIdx)
            }
        }
        return nil
    }

    /// Updates already-merged extension buttons in place when the ordered extension IDs match, avoiding view churn.
    func updateMergedExtensionsInPlace(itemsByID: [String: BrowserExtensionItem], tokenOrder: [String]) -> Bool {
        let expectedIDs = tokenOrder.compactMap { token -> String? in
            guard token.hasPrefix("ext:") else { return nil }
            let id = String(token.dropFirst("ext:".count))
            return itemsByID[id] != nil ? id : nil
        }
        let currentOrderedIDs = stackView.arrangedSubviews.compactMap { ($0 as? ExtensionToolbarIconButton)?.item.id }
        guard expectedIDs == currentOrderedIDs,
              expectedIDs.count == mergedButtons.count else {
            return false
        }
        for id in expectedIDs {
            if let item = itemsByID[id], let btn = mergedButtons[id] {
                btn.update(item: item)
            }
        }
        return true
    }

    func setMergedExtensions(_ buttonsInGroup: [ExtensionToolbarIconButton], tokenOrder: [String]) {
        // Remove existing placeholder & old merged extension buttons
        setPlaceholderVisibleIndex(nil, animated: false)
        for (_, oldBtn) in mergedButtons {
            stackView.removeArrangedSubview(oldBtn)
            oldBtn.removeFromSuperview()
        }
        for (_, constraints) in mergedButtonConstraints {
            NSLayoutConstraint.deactivate(constraints)
        }
        mergedButtons.removeAll()
        mergedButtonConstraints.removeAll()

        // Detach native buttons temporarily so we can re-insert everything in exact persisted tokenOrder
        for spec in specs {
            if let btn = buttons[spec.id] {
                stackView.removeArrangedSubview(btn)
                btn.removeFromSuperview()
            }
        }

        let extByID = Dictionary(uniqueKeysWithValues: buttonsInGroup.map { ($0.item.id, $0) })
        var orderedViews: [NSView] = []
        var placedNative = Set<String>()
        var placedExt = Set<String>()

        for token in tokenOrder {
            if token.hasPrefix("native:") {
                let id = String(token.dropFirst("native:".count))
                if let btn = buttons[id], !placedNative.contains(id) {
                    orderedViews.append(btn)
                    placedNative.insert(id)
                }
            } else if token.hasPrefix("ext:") {
                let id = String(token.dropFirst("ext:".count))
                if let btn = extByID[id], !placedExt.contains(id) {
                    orderedViews.append(btn)
                    placedExt.insert(id)
                }
            }
        }

        for spec in specs where !placedNative.contains(spec.id) {
            if let btn = buttons[spec.id] {
                orderedViews.append(btn)
                placedNative.insert(spec.id)
            }
        }
        for btn in buttonsInGroup where !placedExt.contains(btn.item.id) {
            orderedViews.append(btn)
            placedExt.insert(btn.item.id)
        }

        let isDark = (forceSystemLightAppearance ? AdaptiveChromeTheme.defaultLight : theme).prefersLightInk
        for view in orderedViews {
            if let extBtn = view as? ExtensionToolbarIconButton {
                attachMergedExtensionButton(extBtn, atRawIndex: stackView.arrangedSubviews.count, isDark: isDark)
            } else {
                stackView.addArrangedSubview(view)
            }
        }

        recalculateTotalWidth(animated: false)
    }

    private func attachMergedExtensionButton(_ extBtn: ExtensionToolbarIconButton, atRawIndex rawIdx: Int, isDark: Bool) {
        extBtn.translatesAutoresizingMaskIntoConstraints = false
        let wc = extBtn.widthAnchor.constraint(equalToConstant: extensionSlotWidth)
        let hc = extBtn.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize)
        NSLayoutConstraint.activate([wc, hc])
        mergedButtons[extBtn.item.id] = extBtn
        mergedButtonConstraints[extBtn.item.id] = [wc, hc]
        extBtn.applyDarkMode(isDark)
        let clampedRaw = max(0, min(stackView.arrangedSubviews.count, rawIdx))
        stackView.insertArrangedSubview(extBtn, at: clampedRaw)
    }

    func detachMergedExtensionButton(_ extBtn: ExtensionToolbarIconButton) -> Int? {
        let visible = visibleNonPlaceholderSubviews()
        let vIdx = visible.firstIndex(where: { $0 === extBtn })
        stackView.removeArrangedSubview(extBtn)
        extBtn.removeFromSuperview()
        if let constraints = mergedButtonConstraints.removeValue(forKey: extBtn.item.id) {
            NSLayoutConstraint.deactivate(constraints)
        }
        mergedButtons.removeValue(forKey: extBtn.item.id)
        extBtn.translatesAutoresizingMaskIntoConstraints = true
        recalculateTotalWidth(animated: false)
        return vIdx
    }

    func insertMergedExtensionButton(_ extBtn: ExtensionToolbarIconButton, atVisibleIndex visibleIndex: Int) {
        setPlaceholderVisibleIndex(nil, animated: false)
        let rawIdx = rawInsertionIndex(forVisibleIndex: visibleIndex)
        let isDark = (forceSystemLightAppearance ? AdaptiveChromeTheme.defaultLight : theme).prefersLightInk
        attachMergedExtensionButton(extBtn, atRawIndex: rawIdx, isDark: isDark)
        recalculateTotalWidth(animated: true)
    }

    func setPlaceholderVisibleIndex(_ visibleIndex: Int?, animated: Bool) {
        if let idx = visibleIndex {
            let ph: NSView
            if let existing = placeholderView {
                ph = existing
                stackView.removeArrangedSubview(existing)
                existing.removeFromSuperview()
            } else {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                let wc = spacer.widthAnchor.constraint(equalToConstant: extensionSlotWidth)
                let hc = spacer.heightAnchor.constraint(equalToConstant: SafariMetrics.glassButtonSize)
                NSLayoutConstraint.activate([wc, hc])
                placeholderView = spacer
                placeholderWidthConstraint = wc
                ph = spacer
            }
            let rawIdx = rawInsertionIndex(forVisibleIndex: idx)
            stackView.insertArrangedSubview(ph, at: max(0, min(stackView.arrangedSubviews.count, rawIdx)))
            recalculateTotalWidth(animated: animated)
        } else {
            guard let existing = placeholderView else { return }
            stackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
            if let wc = placeholderWidthConstraint {
                wc.isActive = false
            }
            placeholderView = nil
            placeholderWidthConstraint = nil
            recalculateTotalWidth(animated: animated)
        }
    }

    func insertionVisibleIndex(forWindowPoint ptInWindow: NSPoint, currentVisibleIndex: Int?) -> Int {
        let visible = visibleNonPlaceholderSubviews()
        guard !visible.isEmpty else { return 0 }
        let ptInStack = stackView.convert(ptInWindow, from: nil)

        if let cur = currentVisibleIndex {
            // Stable hysteresis around the open placeholder gap between visible[cur-1] and visible[cur]
            if cur > 0 {
                let leftMidX = visible[cur - 1].frame.midX
                if ptInStack.x < leftMidX - 3.0 {
                    var target = 0
                    for v in visible where v.frame.midX < ptInStack.x {
                        target += 1
                    }
                    return min(cur - 1, target)
                }
            }
            if cur < visible.count {
                let rightMidX = visible[cur].frame.midX
                if ptInStack.x > rightMidX + 3.0 {
                    var target = 0
                    for v in visible where v.frame.midX < ptInStack.x {
                        target += 1
                    }
                    return max(cur + 1, target)
                }
            }
            return max(0, min(visible.count, cur))
        }

        var idx = 0
        for v in visible where v.frame.midX < ptInStack.x {
            idx += 1
        }
        return max(0, min(visible.count, idx))
    }

    func mergedExtensionRect(forExtensionID id: String, in overlay: NSView) -> NSRect? {
        guard let btn = mergedButtons[id] else { return nil }
        return btn.convert(btn.bounds, to: overlay)
    }

    private func updateFullSlotHoverCorners() {
        guard fullSlotHover else { return }
        let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        for id in specs.map(\.id) {
            if let btn = buttons[id] as? HoverableToolbarGlyphButton {
                btn.fullSlotMaskedCorners = allCorners
            }
        }
    }

    func apply(theme: AdaptiveChromeTheme, animated: Bool) {
        self.theme = forceSystemLightAppearance ? .defaultLight : theme
        let applyBlock = { [weak self] in
            self?.updateAppearance()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = SafariMetrics.topEdgeTintAnimationDuration
                ctx.allowsImplicitAnimation = true
                applyBlock()
            }
        } else {
            applyBlock()
        }
    }

    private func updateAppearance() {
        let effectiveTheme = forceSystemLightAppearance ? AdaptiveChromeTheme.defaultLight : theme
        glassView.appearance = effectiveTheme.preferredAppearance
        if #available(macOS 26.0, *), let gv = glassView as? NSGlassEffectView {
            gv.tintColor = forceSystemLightAppearance ? nil : effectiveTheme.glassTintColor
        }

        for spec in specs {
            guard let btn = buttons[spec.id] as? HoverableToolbarGlyphButton else { continue }
            let enabled = enabledState[spec.id] ?? true
            let active = activeState[spec.id] ?? false
            if let title = spec.title {
                let textCol = effectiveTheme.prefersLightInk
                    ? NSColor.white.withAlphaComponent(0.68)
                    : NSColor(srgbRed: 0.49, green: 0.49, blue: 0.51, alpha: 1.0)
                btn.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: spec.pointSize, weight: spec.weight),
                    .foregroundColor: textCol
                ])
            } else {
                if let overrideColor = tintColorOverrides[spec.id] {
                    btn.contentTintColor = overrideColor
                } else {
                    btn.contentTintColor = enabled
                        ? (active ? HDRColorFactory.accentColor(for: window?.screen) : effectiveTheme.primaryInkColor)
                        : effectiveTheme.disabledInkColor
                }
            }
            btn.hoverBackgroundColor = effectiveTheme.prefersLightInk
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.06)
        }
        for extBtn in mergedButtons.values {
            extBtn.applyDarkMode(effectiveTheme.prefersLightInk)
        }
    }

    func hitNativeButton(atWindowPoint ptInWindow: NSPoint) -> (id: String, button: NSButton, visibleIndex: Int)? {
        guard !isHidden else { return nil }
        let visible = visibleNonPlaceholderSubviews()
        for (vIdx, view) in visible.enumerated() {
            guard let btn = view as? NSButton,
                  let id = btn.identifier?.rawValue,
                  !hiddenIDs.contains(id) else { continue }
            let local = btn.convert(ptInWindow, from: nil)
            if btn.bounds.contains(local) {
                return (id, btn, vIdx)
            }
        }
        return nil
    }

    func visibleNativeIDsInOrder() -> [String] {
        var result: [String] = []
        for view in stackView.arrangedSubviews {
            guard view !== placeholderView,
                  let btn = view as? NSButton,
                  let id = btn.identifier?.rawValue,
                  !hiddenIDs.contains(id),
                  !btn.isHidden else { continue }
            result.append(id)
        }
        return result
    }

    func setNativeButtonDragging(_ dragging: Bool, for id: String) {
        buttons[id]?.alphaValue = dragging ? 0.22 : 1.0
    }

    func applyNativeButtonOrder(_ orderedIDs: [String]) {
        // Reorder native buttons in stackView while preserving positions of any merged extension buttons.
        var nativeSlots: [Int] = []
        for (idx, v) in stackView.arrangedSubviews.enumerated() {
            if v is NSButton {
                nativeSlots.append(idx)
            }
        }
        guard !nativeSlots.isEmpty else { return }

        var desiredButtons: [NSButton] = []
        var seen = Set<String>()
        for id in orderedIDs {
            if let btn = buttons[id], !seen.contains(id) {
                desiredButtons.append(btn)
                seen.insert(id)
            }
        }
        for spec in specs where !seen.contains(spec.id) {
            if let btn = buttons[spec.id] {
                desiredButtons.append(btn)
                seen.insert(spec.id)
            }
        }

        // Rebuild arranged subviews preserving extension slots
        let currentViews = stackView.arrangedSubviews
        var rebuilt: [NSView] = []
        var nativeCursor = 0
        for v in currentViews {
            if v is NSButton {
                if nativeCursor < desiredButtons.count {
                    rebuilt.append(desiredButtons[nativeCursor])
                    nativeCursor += 1
                }
            } else {
                rebuilt.append(v)
            }
        }
        while nativeCursor < desiredButtons.count {
            rebuilt.append(desiredButtons[nativeCursor])
            nativeCursor += 1
        }

        // Skip if order is already identical
        if rebuilt.count == currentViews.count && zip(rebuilt, currentViews).allSatisfy({ $0 === $1 }) {
            return
        }

        for v in currentViews {
            stackView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for v in rebuilt {
            stackView.addArrangedSubview(v)
        }
        updateFullSlotHoverCorners()
    }

    func nativeInsertionIndex(forWindowPoint ptInWindow: NSPoint, excludingID: String? = nil) -> Int {
        let visibleNative = visibleNonPlaceholderSubviews().compactMap { v -> NSButton? in
            guard let btn = v as? NSButton,
                  let id = btn.identifier?.rawValue,
                  id != excludingID else { return nil }
            return btn
        }
        let ptInStack = stackView.convert(ptInWindow, from: nil)
        var idx = 0
        for btn in visibleNative where btn.frame.midX < ptInStack.x {
            idx += 1
        }
        return idx
    }

    func setCustomizeWiggle(_ active: Bool, basePhase: Double = 0.0) {
        let visibleViews = stackView.arrangedSubviews.filter { !$0.isHidden && $0 !== placeholderView }
        for (idx, view) in visibleViews.enumerated() {
            let phase = basePhase + Double(idx) * 0.14
            if let extBtn = view as? ExtensionToolbarIconButton {
                extBtn.setCustomizeWiggle(active, phase: phase)
                continue
            }
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: "sxCustomizeWiggleX")
            guard active else { continue }

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
    }

    @objc private func handleButtonClick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              enabledState[id] ?? true else { return }
        actions[id]?()
    }
}

private final class HoverableToolbarGlyphButton: NSButton {
    var fullSlotHover: Bool = false {
        didSet { needsLayout = true }
    }
    var fullSlotMaskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner] {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverCircleLayer.maskedCorners = fullSlotMaskedCorners
            CATransaction.commit()
        }
    }
    var hoverBackgroundColor: NSColor = NSColor.black.withAlphaComponent(0.06) {
        didSet {
            if isHovered {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hoverCircleLayer.backgroundColor = hoverBackgroundColor.cgColor
                CATransaction.commit()
            }
        }
    }
    private let hoverCircleLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        hoverCircleLayer.cornerRadius = 15.0
        hoverCircleLayer.cornerCurve = .continuous
        hoverCircleLayer.backgroundColor = NSColor.clear.cgColor
        hoverCircleLayer.zPosition = -1
        layer?.addSublayer(hoverCircleLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fullSlotHover {
            hoverCircleLayer.frame = bounds
            hoverCircleLayer.cornerRadius = bounds.height / 2.0
            hoverCircleLayer.maskedCorners = fullSlotMaskedCorners
        } else {
            let d: CGFloat = min(28.0, min(bounds.width, bounds.height) - 4.0)
            hoverCircleLayer.frame = CGRect(
                x: ((bounds.width - d) / 2.0).rounded(),
                y: ((bounds.height - d) / 2.0).rounded(),
                width: d,
                height: d
            )
            hoverCircleLayer.cornerRadius = d / 2.0
            hoverCircleLayer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverCircleLayer.backgroundColor = hoverBackgroundColor.cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverCircleLayer.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
    }
}

/// Wraps a toolbar glass capsule in a native macOS 27 `NSGlassEffectContainerView` (`spacing = 0` to prevent
/// unwanted glass blob fusion during hide/show animations while keeping GPU batch rendering).
final class GlassToolbarClusterView: NSView {
    private let stackView = NSStackView()
    private let containerView: NSView

    init(spacing: CGFloat = 0, mergeSpacing: CGFloat = 0) {
        if #available(macOS 26.0, *) {
            let gcv = NSGlassEffectContainerView()
            gcv.spacing = mergeSpacing
            self.containerView = gcv
        } else {
            self.containerView = NSView()
        }
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = spacing
        stackView.setContentHuggingPriority(.required, for: .horizontal)
        stackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if #available(macOS 26.0, *), let gcv = containerView as? NSGlassEffectContainerView {
            stackView.translatesAutoresizingMaskIntoConstraints = true
            stackView.autoresizingMask = [.width, .height]
            gcv.contentView = stackView
        } else {
            stackView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                stackView.topAnchor.constraint(equalTo: containerView.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func addArrangedView(_ view: NSView) {
        stackView.addArrangedSubview(view)
    }
}
