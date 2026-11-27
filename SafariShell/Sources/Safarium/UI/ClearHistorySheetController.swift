import AppKit

/// Native macOS Safari-style Clear History modal sheet with time-range popup:
/// `Last Hour`, `Today`, `Today and Yesterday`, `All History`.
final class ClearHistorySheetController: NSObject {
    private static var activeController: ClearHistorySheetController?

    private let panel: NSPanel
    private let rangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onConfirm: (AssetLoader.HistoryClearRange) -> Void
    private weak var hostWindow: NSWindow?

    static func present(
        over window: NSWindow?,
        onConfirm: @escaping (AssetLoader.HistoryClearRange) -> Void
    ) {
        let controller = ClearHistorySheetController(hostWindow: window, onConfirm: onConfirm)
        activeController = controller
        controller.show()
    }

    private init(
        hostWindow: NSWindow?,
        onConfirm: @escaping (AssetLoader.HistoryClearRange) -> Void
    ) {
        self.hostWindow = hostWindow
        self.onConfirm = onConfirm
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 458, height: 182),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        // Left: Safarium app icon (56×56pt, matching macOS Safari sheet)
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(iconView)

        // Title
        let titleLabel = NSTextField(wrappingLabelWithString: "Clearing history will remove related cookies and other website data.")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .bold)
        titleLabel.textColor = .labelColor
        root.addSubview(titleLabel)

        // Subtitle
        let subtitleLabel = NSTextField(wrappingLabelWithString: "Visited pages, cookies, and cached website data for the selected time range will be removed.")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        root.addSubview(subtitleLabel)

        // "Clear:" + native NSPopUpButton
        let clearLabel = NSTextField(labelWithString: "Clear:")
        clearLabel.translatesAutoresizingMaskIntoConstraints = false
        clearLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        clearLabel.textColor = .labelColor
        root.addSubview(clearLabel)

        rangePopup.translatesAutoresizingMaskIntoConstraints = false
        rangePopup.controlSize = .regular
        rangePopup.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        for range in AssetLoader.HistoryClearRange.allCases {
            rangePopup.addItem(withTitle: range.title)
            rangePopup.lastItem?.tag = range.rawValue
        }
        rangePopup.selectItem(at: 0) // Default: "Last Hour" (matches Safari)
        root.addSubview(rangePopup)

        // Bottom row: Help (?) on left, Cancel + Clear History on right
        let helpButton = NSButton()
        helpButton.translatesAutoresizingMaskIntoConstraints = false
        helpButton.bezelStyle = .helpButton
        helpButton.title = ""
        helpButton.target = self
        helpButton.action = #selector(helpTapped)
        root.addSubview(helpButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        root.addSubview(cancelButton)

        let clearButton = NSButton(title: "Clear History", target: self, action: #selector(confirmTapped))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded
        clearButton.keyEquivalent = "\r"
        root.addSubview(clearButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),

            clearLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            clearLabel.centerYAnchor.constraint(equalTo: rangePopup.centerYAnchor),

            rangePopup.leadingAnchor.constraint(equalTo: clearLabel.trailingAnchor, constant: 8),
            rangePopup.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            rangePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),

            helpButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            helpButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            clearButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            clearButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 108),

            cancelButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78)
        ])
    }

    private func show() {
        if let win = hostWindow {
            win.beginSheet(panel) { [weak self] _ in
                if Self.activeController === self {
                    Self.activeController = nil
                }
            }
        } else {
            panel.center()
            NSApp.runModal(for: panel)
            Self.activeController = nil
        }
    }

    private func dismiss(response: NSApplication.ModalResponse) {
        if let win = hostWindow {
            win.endSheet(panel, returnCode: response)
        } else {
            NSApp.stopModal(withCode: response)
            panel.orderOut(nil)
        }
    }

    @objc private func cancelTapped() {
        dismiss(response: .cancel)
    }

    /// Maps a range popup item tag to a clear range; a missing or unknown tag falls back to `.allHistory`.
    static func historyClearRange(forPopupTag tag: Int?) -> AssetLoader.HistoryClearRange {
        let raw = tag ?? AssetLoader.HistoryClearRange.allHistory.rawValue
        return AssetLoader.HistoryClearRange(rawValue: raw) ?? .allHistory
    }

    /// Clears `PrivacyReportStore.shared` events matching the selected Clear History range.
    static func clearPrivacyReport(for range: AssetLoader.HistoryClearRange, now: Date = Date()) {
        if range == .allHistory {
            PrivacyReportStore.shared.clearAll()
            return
        }
        let cal = Calendar.current
        let cutoff: Date
        switch range {
        case .lastHour:
            cutoff = now.addingTimeInterval(-3600)
        case .today:
            cutoff = cal.startOfDay(for: now)
        case .todayAndYesterday:
            let todayStart = cal.startOfDay(for: now)
            cutoff = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-86400)
        case .allHistory:
            PrivacyReportStore.shared.clearAll()
            return
        }
        PrivacyReportStore.shared.clearEvents(since: cutoff)
    }

    @objc private func confirmTapped() {
        let range = Self.historyClearRange(forPopupTag: rangePopup.selectedItem?.tag)
        dismiss(response: .OK)
        Self.clearPrivacyReport(for: range)
        onConfirm(range)
    }

    @objc private func helpTapped() {
        let info = NSAlert()
        info.alertStyle = .informational
        info.messageText = "Clear History"
        info.informativeText = "Choose a time range to remove visited websites from your Safarium browsing history along with related cookies and cached website data."
        info.addButton(withTitle: "OK")
        info.beginSheetModal(for: panel, completionHandler: nil)
    }
}
