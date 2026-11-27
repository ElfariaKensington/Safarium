import AppKit
import UniformTypeIdentifiers

/// Native macOS 27 Tahoe Safari-style Import Sheet (`File → Import from Browser → <Browser>…`):
/// - Presented as a real native window sheet (`parentWindow.beginSheet`) with automatic backdrop dimming
/// - Exact compact Safari layout: `58×58` browser app icon on left, `"Select the items to import:"`,
///   clean native checkboxes (`Bookmarks`, `History`, `Reading List`, `Extensions`), and `[ Cancel ] [ Import ]`
/// - Zero folder pickers: if macOS TCC denies direct access, prompts directly for Full Disk Access
///   in System Settings and automatically re-scans the moment the user returns to Safarium
/// - Automatically converts MV2 / Safari WebExtensions via `ExtensionCompatibilityConverter` and skips
///   truly incompatible extensions
final class ImportDataWindowController: NSWindowController {
    private let engine: BrowserEngine
    private let browser: SupportedBrowserKind

    private weak var hostWindow: NSWindow?
    private var profiles: [DetectedBrowserProfile] = []
    private var selectedProfileIndex: Int = 0
    private var currentScan: BrowserProfileScan?
    private var isImporting: Bool = false
    private var isShowingDiskAccessPrompt: Bool = false
    private var needsAccessRescan: Bool = false
    private var appActiveObserver: NSObjectProtocol?

    // Compact sheet layout views
    private let iconView = NSImageView()
    private let headingLabel = NSTextField(labelWithString: "Select the items to import:")
    private let contentStack = NSStackView()
    private let profileRow = NSStackView()
    private let profilePopup = NSPopUpButton()

    private let bookmarksCheck = NSButton(checkboxWithTitle: "Bookmarks", target: nil, action: nil)
    private let historyCheck = NSButton(checkboxWithTitle: "History", target: nil, action: nil)
    private let readingListCheck = NSButton(checkboxWithTitle: "Reading List", target: nil, action: nil)
    private let extensionsCheck = NSButton(checkboxWithTitle: "Extensions", target: nil, action: nil)

    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let grantAccessButton = NSButton(title: "Grant Disk Access…", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()

    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let actionButton = NSButton(title: "Import", target: nil, action: nil)

    init(engine: BrowserEngine, browser: SupportedBrowserKind) {
        self.engine = engine
        self.browser = browser

        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 424, height: 196),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isMovable = false

        super.init(window: sheet)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
        }
    }

    func presentSheet(on parentWindow: NSWindow?) {
        guard let sheet = window else { return }
        self.hostWindow = parentWindow

        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, (self.isShowingDiskAccessPrompt || self.needsAccessRescan), !self.isImporting else { return }
            self.scanBrowser()
        }

        if let parentWindow {
            parentWindow.beginSheet(sheet, completionHandler: nil)
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }

        scanBrowser()
    }

    // MARK: - Native Tahoe Sheet Layout

    private func setupUI() {
        guard let sheet = window else { return }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView = root

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = browser.appIcon(size: 58)
        iconView.imageScaling = .scaleProportionallyDown
        root.addSubview(iconView)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 7
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)

        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        headingLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        headingLabel.textColor = .labelColor
        headingLabel.lineBreakMode = .byWordWrapping
        headingLabel.maximumNumberOfLines = 2
        contentStack.addArrangedSubview(headingLabel)

        // Optional profile selector (only shown when > 1 profile exists)
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 6
        profileRow.translatesAutoresizingMaskIntoConstraints = false
        let profLbl = NSTextField(labelWithString: "Profile:")
        profLbl.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        profLbl.textColor = .secondaryLabelColor
        profilePopup.controlSize = .small
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        profileRow.addArrangedSubview(profLbl)
        profileRow.addArrangedSubview(profilePopup)
        profileRow.isHidden = true
        contentStack.addArrangedSubview(profileRow)

        for cb in [bookmarksCheck, historyCheck, readingListCheck, extensionsCheck] {
            cb.translatesAutoresizingMaskIntoConstraints = false
            cb.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
            cb.state = .on
            cb.target = self
            cb.action = #selector(checkboxToggled)
            cb.isHidden = true
            contentStack.addArrangedSubview(cb)
        }

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 314
        detailLabel.stringValue = "Checking \(browser.rawValue)…"
        contentStack.addArrangedSubview(detailLabel)
        contentStack.setCustomSpacing(10, after: extensionsCheck)

        grantAccessButton.translatesAutoresizingMaskIntoConstraints = false
        grantAccessButton.controlSize = .small
        grantAccessButton.target = self
        grantAccessButton.action = #selector(openDiskAccessSettingsClicked)
        if #available(macOS 26.0, *) {
            grantAccessButton.bezelStyle = .glass
        } else {
            grantAccessButton.bezelStyle = .rounded
        }
        grantAccessButton.isHidden = true
        contentStack.addArrangedSubview(grantAccessButton)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        contentStack.addArrangedSubview(progressBar)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        if #available(macOS 26.0, *) {
            cancelButton.bezelStyle = .glass
        } else {
            cancelButton.bezelStyle = .rounded
        }
        root.addSubview(cancelButton)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        if #available(macOS 26.0, *) {
            actionButton.bezelStyle = .glass
        } else {
            actionButton.bezelStyle = .rounded
        }
        actionButton.bezelColor = .controlAccentColor
        actionButton.isEnabled = false
        root.addSubview(actionButton)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 424),

            iconView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 58),
            iconView.heightAnchor.constraint(equalToConstant: 58),

            contentStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),

            progressBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor),

            actionButton.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 18),
            actionButton.topAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor, constant: 18),
            actionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actionButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),

            cancelButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78)
        ])
    }

    // MARK: - Scan & State Rendering

    private func scanBrowser() {
        let installed = engine.installedExtensions()
        let installedIDs = Set(installed.map { $0.id.lowercased() })
        let installedNames = Set(installed.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let browserKind = self.browser
        let chosenIdx = self.selectedProfileIndex

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detected = BrowserDataImporter.shared.detectProfiles(for: browserKind)
            guard !detected.isEmpty else {
                DispatchQueue.main.async {
                    self?.applyNoDataState()
                }
                return
            }
            let safeIdx = Self.clampedProfileIndex(chosenIdx, profileCount: detected.count)
            let scan = BrowserDataImporter.shared.scan(
                profile: detected[safeIdx],
                installedExtensionIDs: installedIDs,
                installedExtensionNames: installedNames
            )
            DispatchQueue.main.async {
                self?.profiles = detected
                self?.selectedProfileIndex = safeIdx
                self?.applyScan(scan)
            }
        }
    }

    private func applyNoDataState() {
        isShowingDiskAccessPrompt = false
        needsAccessRescan = false
        grantAccessButton.isHidden = true
        headingLabel.stringValue = "No Data Found"
        profileRow.isHidden = true
        bookmarksCheck.isHidden = true
        historyCheck.isHidden = true
        readingListCheck.isHidden = true
        extensionsCheck.isHidden = true
        detailLabel.isHidden = false
        detailLabel.stringValue = "No importable bookmarks, history, or extensions were found for \(browser.rawValue)."
        actionButton.title = "Import"
        actionButton.isEnabled = false
        resizeSheetToFit()
    }

    private func applyScan(_ scan: BrowserProfileScan) {
        currentScan = scan

        let importableExts = scan.extensions.filter { !$0.isAlreadyInstalled && $0.compatibility.isImportable }
        let hasAnyData = !scan.bookmarks.isEmpty || !scan.history.isEmpty || !scan.readingList.isEmpty || !importableExts.isEmpty

        if scan.accessBlocked && !hasAnyData {
            isShowingDiskAccessPrompt = true
            needsAccessRescan = true
            grantAccessButton.isHidden = true
            headingLabel.stringValue = "Disk Access Required"
            profileRow.isHidden = true
            bookmarksCheck.isHidden = true
            historyCheck.isHidden = true
            readingListCheck.isHidden = true
            extensionsCheck.isHidden = true
            detailLabel.isHidden = false
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = "Allow Full Disk Access for Safarium in System Settings to import your \(browser.rawValue) bookmarks, history, and extensions."
            actionButton.title = "Open System Settings"
            actionButton.isEnabled = true
            resizeSheetToFit()
            return
        }

        isShowingDiskAccessPrompt = false
        needsAccessRescan = scan.accessBlocked
        headingLabel.stringValue = "Select the items to import:"

        // Profile selector (only when >1 profile exists)
        if profiles.count > 1 {
            profilePopup.removeAllItems()
            for p in profiles {
                profilePopup.addItem(withTitle: p.profileName)
            }
            profilePopup.selectItem(at: selectedProfileIndex)
            profileRow.isHidden = false
        } else {
            profileRow.isHidden = true
        }

        if !scan.bookmarks.isEmpty {
            bookmarksCheck.title = "Bookmarks (\(scan.bookmarks.count))"
            bookmarksCheck.isHidden = false
            bookmarksCheck.isEnabled = true
            bookmarksCheck.state = .on
        } else if scan.accessBlocked {
            bookmarksCheck.title = "Bookmarks (Requires Disk Access)"
            bookmarksCheck.isHidden = false
            bookmarksCheck.isEnabled = false
            bookmarksCheck.state = .off
        } else {
            bookmarksCheck.title = "Bookmarks (None)"
            bookmarksCheck.isHidden = false
            bookmarksCheck.isEnabled = false
            bookmarksCheck.state = .off
        }

        if !scan.history.isEmpty {
            historyCheck.title = "History (\(scan.history.count))"
            historyCheck.isHidden = false
            historyCheck.isEnabled = true
            historyCheck.state = .on
        } else if scan.accessBlocked {
            historyCheck.title = "History (Requires Disk Access)"
            historyCheck.isHidden = false
            historyCheck.isEnabled = false
            historyCheck.state = .off
        } else {
            historyCheck.title = "History (None)"
            historyCheck.isHidden = false
            historyCheck.isEnabled = false
            historyCheck.state = .off
        }

        if !scan.readingList.isEmpty {
            readingListCheck.title = "Reading List (\(scan.readingList.count))"
            readingListCheck.isHidden = false
            readingListCheck.isEnabled = true
            readingListCheck.state = .on
        } else if scan.accessBlocked && browser == .safari {
            readingListCheck.title = "Reading List (Requires Disk Access)"
            readingListCheck.isHidden = false
            readingListCheck.isEnabled = false
            readingListCheck.state = .off
        } else {
            readingListCheck.isHidden = true
            readingListCheck.isEnabled = false
            readingListCheck.state = .off
        }

        if !importableExts.isEmpty {
            let convertibleCount = importableExts.filter {
                if case .convertible = $0.compatibility { return true }
                return false
            }.count
            extensionsCheck.title = "Extensions (\(importableExts.count))"
            extensionsCheck.toolTip = convertibleCount > 0
                ? "\(convertibleCount) extension(s) will be automatically converted to Chromium MV3."
                : nil
            extensionsCheck.isHidden = false
            extensionsCheck.isEnabled = true
            extensionsCheck.state = .on
        } else {
            extensionsCheck.isHidden = true
            extensionsCheck.isEnabled = false
            extensionsCheck.state = .off
        }

        let incompatibleExts = scan.extensions.filter { !$0.compatibility.isImportable }
        if scan.accessBlocked {
            // Safari extensions found even though Bookmarks/History/Reading List require Full Disk Access
            detailLabel.isHidden = false
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = "Allow Full Disk Access for Safarium in System Settings to also import \(browser.rawValue) bookmarks, history, and reading list."
            grantAccessButton.isHidden = false
        } else if !hasAnyData {
            grantAccessButton.isHidden = true
            detailLabel.isHidden = false
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.stringValue = "Everything in \(browser.rawValue) is already imported or empty."
        } else if !incompatibleExts.isEmpty {
            grantAccessButton.isHidden = true
            detailLabel.isHidden = false
            detailLabel.textColor = .secondaryLabelColor
            let names = incompatibleExts.prefix(2).map(\.name).joined(separator: ", ")
            let more = incompatibleExts.count > 2 ? " +\(incompatibleExts.count - 2) more" : ""
            detailLabel.stringValue = "Incompatible extensions skipped: \(names)\(more)."
        } else {
            grantAccessButton.isHidden = true
            detailLabel.isHidden = true
        }

        actionButton.title = "Import"
        syncActionButtonEnabled()
        resizeSheetToFit()
    }

    private func syncActionButtonEnabled() {
        guard !isImporting else {
            actionButton.isEnabled = false
            return
        }
        if isShowingDiskAccessPrompt {
            actionButton.isEnabled = true
            return
        }
        let anyChecked =
            (!bookmarksCheck.isHidden && bookmarksCheck.isEnabled && bookmarksCheck.state == .on) ||
            (!historyCheck.isHidden && historyCheck.isEnabled && historyCheck.state == .on) ||
            (!readingListCheck.isHidden && readingListCheck.isEnabled && readingListCheck.state == .on) ||
            (!extensionsCheck.isHidden && extensionsCheck.isEnabled && extensionsCheck.state == .on)
        actionButton.isEnabled = anyChecked
    }

    private func resizeSheetToFit() {
        guard let sheet = window, let content = sheet.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let targetSize = NSSize(width: 424, height: max(156, ceil(fitting.height)))
        if abs(sheet.contentRect(forFrameRect: sheet.frame).height - targetSize.height) > 1 {
            sheet.setContentSize(targetSize)
        }
    }

    /// Clamps a requested profile index into `0..<profileCount`; an empty list clamps to 0.
    static func clampedProfileIndex(_ requested: Int, profileCount: Int) -> Int {
        max(0, min(profileCount - 1, requested))
    }

    /// Builds the import selection from the checkbox states; extension IDs are only kept when that box is checked.
    static func makeSelection(
        bookmarks: Bool,
        history: Bool,
        readingList: Bool,
        extensions: Bool,
        importableExtensionIDs: Set<String>
    ) -> BrowserImportSelection {
        BrowserImportSelection(
            importBookmarks: bookmarks,
            importHistory: history,
            importReadingList: readingList,
            selectedExtensionIDs: extensions ? importableExtensionIDs : []
        )
    }

    // MARK: - Actions

    @objc private func profileChanged() {
        selectedProfileIndex = max(0, profilePopup.indexOfSelectedItem)
        scanBrowser()
    }

    @objc private func checkboxToggled() {
        syncActionButtonEnabled()
    }

    @objc private func openDiskAccessSettingsClicked() {
        needsAccessRescan = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func actionClicked() {
        if isShowingDiskAccessPrompt {
            openDiskAccessSettingsClicked()
            return
        }

        guard !isImporting, let scan = currentScan else { return }

        let importableExtIDs = Set(
            scan.extensions
                .filter { !$0.isAlreadyInstalled && $0.compatibility.isImportable }
                .map(\.id)
        )

        // Capture selection BEFORE disabling checkboxes for the in-progress UI state.
        let selection = Self.makeSelection(
            bookmarks: !bookmarksCheck.isHidden && bookmarksCheck.isEnabled && bookmarksCheck.state == .on,
            history: !historyCheck.isHidden && historyCheck.isEnabled && historyCheck.state == .on,
            readingList: !readingListCheck.isHidden && readingListCheck.isEnabled && readingListCheck.state == .on,
            extensions: !extensionsCheck.isHidden && extensionsCheck.isEnabled && extensionsCheck.state == .on,
            importableExtensionIDs: importableExtIDs
        )

        isImporting = true
        actionButton.isEnabled = false
        cancelButton.isEnabled = false
        grantAccessButton.isEnabled = false
        profilePopup.isEnabled = false
        for cb in [bookmarksCheck, historyCheck, readingListCheck, extensionsCheck] {
            cb.isEnabled = false
        }

        progressBar.doubleValue = 0.08
        progressBar.isHidden = false
        detailLabel.isHidden = false
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = "Importing from \(browser.rawValue)…"
        resizeSheetToFit()

        BrowserDataImporter.shared.performImport(
            scan: scan,
            selection: selection,
            engine: engine,
            onProgress: { [weak self] status, fraction in
                DispatchQueue.main.async {
                    self?.detailLabel.stringValue = status
                    self?.progressBar.doubleValue = max(0.08, min(1.0, fraction))
                }
            },
            completion: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.dismissSheet()
                }
            }
        )
    }

    @objc private func cancelClicked() {
        dismissSheet()
    }

    private func dismissSheet() {
        guard let sheet = window else { return }
        if let hostWindow {
            hostWindow.endSheet(sheet)
        } else {
            sheet.close()
        }
    }
}
