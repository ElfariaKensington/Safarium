import AppKit

/// Native macOS Safari "When visiting <host>:" Website Settings popover,
/// anchored directly below the active address bar pill with top pointer arrow.
final class WebsiteSettingsPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    var onPageZoomChanged: ((Double) -> Void)?
    var onAdaptiveDarkModeChanged: ((Bool) -> Void)?
    var onReaderModeChanged: ((Bool) -> Void)?
    var onContentBlockersChanged: ((Bool) -> Void)?

    var isShown: Bool { popover?.isShown ?? false }

    func show(forHost rawHost: String, relativeTo anchorView: NSView) {
        if let existing = popover, existing.isShown {
            existing.close()
            popover = nil
        }

        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty else { return }

        let vc = WebsiteSettingsPopoverViewController(host: host)
        vc.onPageZoomChanged = { [weak self] factor in self?.onPageZoomChanged?(factor) }
        vc.onAdaptiveDarkModeChanged = { [weak self] enabled in self?.onAdaptiveDarkModeChanged?(enabled) }
        vc.onReaderModeChanged = { [weak self] enabled in self?.onReaderModeChanged?(enabled) }
        vc.onContentBlockersChanged = { [weak self] enabled in self?.onContentBlockersChanged?(enabled) }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.appearance = anchorView.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        pop.contentViewController = vc
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: anchorView.isFlipped ? .maxY : .minY)
        self.popover = pop
    }

    /// Lowercases the host and drops exactly one leading "www.".
    static func normalizedHost(_ rawHost: String) -> String {
        rawHost.lowercased().hasPrefix("www.")
            ? String(rawHost.lowercased().dropFirst(4))
            : rawHost.lowercased()
    }

    func close() {
        popover?.close()
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

final class WebsiteSettingsPopoverViewController: NSViewController {
    private let host: String

    var onPageZoomChanged: ((Double) -> Void)?
    var onAdaptiveDarkModeChanged: ((Bool) -> Void)?
    var onReaderModeChanged: ((Bool) -> Void)?
    var onContentBlockersChanged: ((Bool) -> Void)?

    static let zoomOptions = ["50%", "75%", "85%", "100%", "115%", "125%", "150%", "175%", "200%", "250%", "300%"]
    private static let autoPlayOptions = ["Allow All Auto-Play", "Stop Media with Sound", "Never Auto-Play"]
    private static let popupOptions = ["Block and Notify", "Block", "Allow"]
    private static let permissionOptions = ["Ask", "Deny", "Allow"]

    private var checkboxHandlers: [NSButton: (Bool) -> Void] = [:]
    private var popupHandlers: [NSPopUpButton: (Int) -> Void] = [:]

    init(host: String) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let width: CGFloat = 336.0
        let root = FlippedWebsiteSettingsView(frame: NSRect(x: 0, y: 0, width: width, height: 390))

        let settings = BrowserSettings.shared
        let labelColRight: CGFloat = 160.0
        let controlX: CGFloat = 172.0
        let controlW: CGFloat = width - controlX - 16.0

        var y: CGFloat = 16.0

        // Centered header: "When visiting <host>:"
        let header = NSTextField(labelWithString: "When visiting \(host):")
        header.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        header.textColor = .labelColor
        header.alignment = .center
        header.lineBreakMode = .byTruncatingMiddle
        header.frame = NSRect(x: 16, y: y, width: width - 32, height: 18)
        root.addSubview(header)
        y += 32.0

        // Section 1: 3 Checkboxes
        func addCheckbox(title: String, isInitiallyOn: Bool, onToggle: @escaping (Bool) -> Void) {
            let btn = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxChanged(_:)))
            btn.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
            btn.state = isInitiallyOn ? .on : .off
            btn.frame = NSRect(x: 92, y: y, width: width - 108, height: 20)
            checkboxHandlers[btn] = onToggle
            root.addSubview(btn)
            y += 28.0
        }

        func addBinaryPolicyCheckbox(title: String, category: String, defaultOn: Bool, onChange: @escaping (Bool) -> Void) {
            let idx = settings.websitePolicyIndex(category: category, host: host, defaultIndex: defaultOn ? 1 : 0)
            addCheckbox(title: title, isInitiallyOn: idx != 0) { [weak self] checked in
                guard let self else { return }
                BrowserSettings.shared.setWebsitePolicy(category: category, host: self.host, index: checked ? 1 : 0)
                onChange(checked)
            }
        }

        addBinaryPolicyCheckbox(title: "Use Reader when available", category: "Reader", defaultOn: false) { [weak self] on in
            self?.onReaderModeChanged?(on)
        }
        addCheckbox(
            title: "Enable content blockers",
            isInitiallyOn: settings.isContentBlockersEnabled(forHost: host)
        ) { [weak self] checked in
            guard let self else { return }
            BrowserSettings.shared.setContentBlockersEnabled(checked, forHost: self.host)
            self.onContentBlockersChanged?(checked)
        }
        addBinaryPolicyCheckbox(title: "Adaptive Dark Mode", category: "Adaptive Dark Mode", defaultOn: false) { [weak self] on in
            self?.onAdaptiveDarkModeChanged?(on)
        }

        y += 6.0
        addDivider(to: root, y: y, width: width)
        y += 14.0

        // Helper for right-aligned label + clean borderless popup button
        func addPopupRow(label: String, options: [String], category: String, defaultIndex: Int, onChange: ((Int) -> Void)? = nil) {
            let lbl = NSTextField(labelWithString: label)
            lbl.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .right
            lbl.frame = NSRect(x: 14, y: y + 2, width: labelColRight - 14, height: 18)
            root.addSubview(lbl)

            let pop = NSPopUpButton(frame: NSRect(x: controlX - 4, y: y - 1, width: controlW + 6, height: 24), pullsDown: false)
            pop.isBordered = false
            pop.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
            pop.addItems(withTitles: options)
            let curIdx = max(0, min(options.count - 1, settings.websitePolicyIndex(category: category, host: host, defaultIndex: defaultIndex)))
            pop.selectItem(at: curIdx)
            pop.target = self
            pop.action = #selector(popupChanged(_:))
            popupHandlers[pop] = { [weak self] idx in
                guard let self else { return }
                BrowserSettings.shared.setWebsitePolicy(category: category, host: self.host, index: idx)
                onChange?(idx)
            }
            root.addSubview(pop)
            y += 30.0
        }

        // Section 2: Page Zoom, Auto-Play, Pop-up Windows
        addPopupRow(label: "Page Zoom:", options: Self.zoomOptions, category: "Page Zoom", defaultIndex: 3) { [weak self] idx in
            let clamped = max(0, min(BrowserSettings.pageZoomValues.count - 1, idx))
            self?.onPageZoomChanged?(BrowserSettings.pageZoomValues[clamped])
        }
        addPopupRow(label: "Auto-Play:", options: Self.autoPlayOptions, category: "Auto-Play", defaultIndex: 1)
        addPopupRow(label: "Pop-up Windows:", options: Self.popupOptions, category: "Pop-up Windows", defaultIndex: 0)

        y += 6.0
        addDivider(to: root, y: y, width: width)
        y += 14.0

        // Section 3: Camera, Microphone, Screen Sharing, Location
        addPopupRow(label: "Camera:", options: Self.permissionOptions, category: "Camera", defaultIndex: 0)
        addPopupRow(label: "Microphone:", options: Self.permissionOptions, category: "Microphone", defaultIndex: 0)
        addPopupRow(label: "Screen Sharing:", options: Self.permissionOptions, category: "Screen Sharing", defaultIndex: 0)
        addPopupRow(label: "Location:", options: Self.permissionOptions, category: "Location", defaultIndex: 0)

        y += 10.0
        root.frame = NSRect(x: 0, y: 0, width: width, height: y)
        self.view = root
        self.preferredContentSize = NSSize(width: width, height: y)
    }

    private func addDivider(to parent: NSView, y: CGFloat, width: CGFloat) {
        let div = NSView(frame: NSRect(x: 0, y: y, width: width, height: 1))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        parent.addSubview(div)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        checkboxHandlers[sender]?(sender.state == .on)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        popupHandlers[sender]?(sender.indexOfSelectedItem)
    }
}

private final class FlippedWebsiteSettingsView: NSView {
    override var isFlipped: Bool { true }
}
