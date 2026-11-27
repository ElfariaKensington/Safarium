import AppKit

/// Native macOS 27 Tahoe Page Menu popover anchored beneath the active tab's `≡` icon.
/// Contains only real, working actions (Zoom, Find on Page, Reload Page, Website Settings)
/// with full keyboard navigation (`↑`/`↓`, `Return`/`Space`, `Esc`).
final class PageMenuPopoverController: NSObject, NSPopoverDelegate {
    struct State {
        var domain: String
        var zoomFactor: Double
        var isDarkAppearance: Bool
    }

    var onSelectZoom: ((Double) -> Void)?
    var onFindOnPage: (() -> Void)?
    var onReloadPage: (() -> Void)?
    var onWebsiteSettings: (() -> Void)?

    private var popover: NSPopover
    private let contentVC = PageMenuContentViewController()
    private var currentState = State(domain: "", zoomFactor: 1.0, isDarkAppearance: false)
    private var lastPopoverDarkAppearance: Bool?

    private static let popoverSize = NSSize(width: 228, height: 126)

    override init() {
        self.popover = Self.makePopover(isDark: false)
        super.init()
        popover.delegate = self
        popover.contentViewController = contentVC

        contentVC.onSelectZoom = { [weak self] factor in
            guard let self else { return }
            self.currentState.zoomFactor = factor
            self.contentVC.apply(state: self.currentState)
            self.onSelectZoom?(factor)
        }
        contentVC.onFindOnPage = { [weak self] in
            self?.close()
            self?.onFindOnPage?()
        }
        contentVC.onReloadPage = { [weak self] in
            self?.close()
            self?.onReloadPage?()
        }
        contentVC.onWebsiteSettings = { [weak self] in
            self?.close()
            self?.onWebsiteSettings?()
        }
        contentVC.onDismiss = { [weak self] in
            self?.close()
        }
    }

    var isShown: Bool { popover.isShown }

    private static func makePopover(isDark: Bool) -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentSize = popoverSize
        p.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        return p
    }

    func applyTheme(isDark: Bool) {
        currentState.isDarkAppearance = isDark
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if popover.isShown {
            popover.appearance = appearance
            contentVC.view.appearance = appearance
            contentVC.view.window?.appearance = appearance
            contentVC.apply(state: currentState)
            CATransaction.flush()
        } else if lastPopoverDarkAppearance != isDark {
            popover.delegate = nil
            popover.contentViewController = nil
            let fresh = Self.makePopover(isDark: isDark)
            fresh.delegate = self
            fresh.contentViewController = contentVC
            popover = fresh
            contentVC.view.appearance = appearance
            contentVC.apply(state: currentState)
            lastPopoverDarkAppearance = isDark
        }
    }

    func toggle(relativeTo anchor: NSView, state: State) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        currentState = state
        let appearance = NSAppearance(named: state.isDarkAppearance ? .darkAqua : .aqua)
        if lastPopoverDarkAppearance != state.isDarkAppearance {
            popover.delegate = nil
            popover.contentViewController = nil
            let fresh = Self.makePopover(isDark: state.isDarkAppearance)
            fresh.delegate = self
            fresh.contentViewController = contentVC
            popover = fresh
            lastPopoverDarkAppearance = state.isDarkAppearance
        } else {
            popover.appearance = appearance
        }
        contentVC.view.appearance = appearance
        contentVC.apply(state: state)
        contentVC.resetKeyboardSelection()
        CATransaction.flush()
        let belowEdge: NSRectEdge = anchor.isFlipped ? .maxY : .minY
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: belowEdge)
        contentVC.view.window?.appearance = appearance
        contentVC.view.window?.makeFirstResponder(contentVC.view)
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }
}

final class PageMenuKeyRootView: NSView {
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // Down
            onMoveSelection?(1)
        case 126: // Up
            onMoveSelection?(-1)
        case 36, 76, 49: // Return, Enter, Space
            onActivateSelection?()
        case 53: // Escape
            onDismiss?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class PageMenuContentViewController: NSViewController {
    var onSelectZoom: ((Double) -> Void)?
    var onFindOnPage: (() -> Void)?
    var onReloadPage: (() -> Void)?
    var onWebsiteSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let stackView = NSStackView()
    private let separatorLine = NSView()

    lazy var zoomRow = PageMenuRowView(symbolName: "plus.magnifyingglass", title: "Zoom", showsChevronPair: true) { [weak self] in
        self?.presentZoomMenu()
    }
    lazy var findRow = PageMenuRowView(symbolName: "doc.text.magnifyingglass", title: "Find on Page…") { [weak self] in
        self?.onFindOnPage?()
    }
    lazy var reloadRow = PageMenuRowView(symbolName: "arrow.clockwise", title: "Reload Page") { [weak self] in
        self?.onReloadPage?()
    }
    lazy var settingsRow = PageMenuRowView(symbolName: "gearshape", title: "Website Settings…") { [weak self] in
        self?.onWebsiteSettings?()
    }

    var allRows: [PageMenuRowView] {
        [zoomRow, findRow, reloadRow, settingsRow]
    }

    private var currentZoomFactor: Double = 1.0
    private var isDark: Bool = false
    var selectedRowIndex: Int = -1

    override func loadView() {
        let root = PageMenuKeyRootView(frame: NSRect(x: 0, y: 0, width: 228, height: 126))
        root.wantsLayer = true
        root.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
        root.onActivateSelection = { [weak self] in self?.activateSelectedRow() }
        root.onDismiss = { [weak self] in self?.onDismiss?() }
        self.view = root

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: root.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        for row in [zoomRow, findRow, reloadRow] {
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }

        let sepWrap = NSView()
        sepWrap.translatesAutoresizingMaskIntoConstraints = false
        sepWrap.heightAnchor.constraint(equalToConstant: 8).isActive = true
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.wantsLayer = true
        sepWrap.addSubview(separatorLine)
        NSLayoutConstraint.activate([
            separatorLine.leadingAnchor.constraint(equalTo: sepWrap.leadingAnchor, constant: 14),
            separatorLine.trailingAnchor.constraint(equalTo: sepWrap.trailingAnchor, constant: -14),
            separatorLine.centerYAnchor.constraint(equalTo: sepWrap.centerYAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 0.5)
        ])
        stackView.addArrangedSubview(sepWrap)
        sepWrap.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        stackView.addArrangedSubview(settingsRow)
        settingsRow.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    func resetKeyboardSelection() {
        selectedRowIndex = -1
        for row in allRows { row.setKeyboardSelected(false) }
    }

    func moveSelection(by delta: Int) {
        let rows = allRows
        guard !rows.isEmpty else { return }
        if selectedRowIndex < 0 {
            selectedRowIndex = delta > 0 ? 0 : rows.count - 1
        } else {
            selectedRowIndex = (selectedRowIndex + delta + rows.count) % rows.count
        }
        for (i, row) in rows.enumerated() {
            row.setKeyboardSelected(i == selectedRowIndex)
        }
    }

    func activateSelectedRow() {
        let rows = allRows
        guard selectedRowIndex >= 0 && selectedRowIndex < rows.count else { return }
        rows[selectedRowIndex].triggerClick()
    }

    func apply(state: PageMenuPopoverController.State) {
        _ = self.view
        currentZoomFactor = state.zoomFactor
        isDark = state.isDarkAppearance

        let pct = Int((state.zoomFactor * 100.0).rounded())
        zoomRow.setTrailingValue("\(pct)%", emphasized: true, isAccent: false, isDark: isDark)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separatorLine.layer?.backgroundColor = isDark
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.black.withAlphaComponent(0.10).cgColor
        CATransaction.commit()

        for row in allRows {
            row.applyTheme(isDark: isDark)
        }
    }

    private func presentZoomMenu() {
        let levels: [Double] = [0.50, 0.75, 0.85, 1.00, 1.15, 1.25, 1.50, 1.75, 2.00, 2.50, 3.00]
        let menu = NSMenu(title: "Zoom")
        for level in levels {
            let pct = Int((level * 100.0).rounded())
            let item = NSMenuItem(title: "\(pct)%", action: #selector(zoomMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: level)
            item.state = abs(level - currentZoomFactor) < 0.02 ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: zoomRow.bounds.width - 82, y: 4), in: zoomRow)
    }

    @objc private func zoomMenuItemChosen(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        onSelectZoom?(num.doubleValue)
    }
}

final class PageMenuRowView: NSView {
    private let onClick: () -> Void
    private let hoverPill = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isKeyboardSelected = false
    private var isDark = false
    private var trailingEmphasized = false
    private var trailingAccent = false
    private let showsChevronPair: Bool

    init(symbolName: String, title: String, showsChevronPair: Bool = false, onClick: @escaping () -> Void) {
        self.showsChevronPair = showsChevronPair
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        hoverPill.translatesAutoresizingMaskIntoConstraints = false
        hoverPill.wantsLayer = true
        hoverPill.layer?.cornerRadius = 7.0
        hoverPill.layer?.cornerCurve = .continuous
        hoverPill.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hoverPill)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = AssetLoader.shared.symbol(named: symbolName, pointSize: 13.5, weight: .regular)
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        trailingLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        trailingLabel.alignment = .right
        trailingLabel.isHidden = true
        addSubview(trailingLabel)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = AssetLoader.shared.symbol(named: "chevron.up.chevron.down", pointSize: 9.5, weight: .semibold)
        chevronView.isHidden = !showsChevronPair
        addSubview(chevronView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26.0),

            hoverPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            hoverPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hoverPill.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingLabel.leadingAnchor, constant: -6),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            trailingLabel.trailingAnchor.constraint(
                equalTo: showsChevronPair ? chevronView.leadingAnchor : trailingAnchor,
                constant: showsChevronPair ? -4 : -14
            ),
            trailingLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        applyTheme(isDark: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func setTrailingValue(_ text: String, emphasized: Bool, isAccent: Bool, isDark: Bool) {
        trailingLabel.stringValue = text
        trailingLabel.isHidden = text.isEmpty
        trailingEmphasized = emphasized
        trailingAccent = isAccent
        applyTheme(isDark: isDark)
    }

    func setKeyboardSelected(_ selected: Bool) {
        isKeyboardSelected = selected
        updateHighlight()
    }

    func triggerClick() {
        onClick()
    }

    func applyTheme(isDark: Bool) {
        self.isDark = isDark
        let ink = isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.86)
        let secondary = isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.45)
        iconView.contentTintColor = ink
        titleLabel.textColor = ink
        chevronView.contentTintColor = secondary
        if trailingAccent {
            trailingLabel.textColor = NSColor.controlAccentColor
            trailingLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        } else {
            trailingLabel.textColor = trailingEmphasized ? ink : secondary
            trailingLabel.font = NSFont.systemFont(ofSize: 12.5, weight: trailingEmphasized ? .medium : .regular)
        }
        updateHighlight()
    }

    private func updateHighlight() {
        let active = isHovered || isKeyboardSelected
        if active {
            hoverPill.layer?.backgroundColor = (isDark
                ? NSColor.white.withAlphaComponent(0.13)
                : NSColor.black.withAlphaComponent(0.075)).cgColor
        } else {
            hoverPill.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHighlight()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
}
