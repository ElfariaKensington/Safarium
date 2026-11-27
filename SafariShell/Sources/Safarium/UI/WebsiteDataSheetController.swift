import AppKit

/// Native macOS Safari-style "Manage Website Data…" modal sheet (`520 x 440` `NSPanel`).
/// Supports live search filtering, multi-selection selective domain removal, and Remove All.
final class WebsiteDataSheetController: NSObject {
    private static var activeController: WebsiteDataSheetController?

    let sheetPanel: NSPanel
    private let fetchRecords: (@escaping ([WebsiteDataRecord]) -> Void) -> Void
    private let removeDomains: ([String], @escaping (Bool) -> Void) -> Void
    private let removeAll: (@escaping (Bool) -> Void) -> Void

    private weak var hostWindow: NSWindow?
    private var sheetViewController: WebsiteDataSheetViewController?

    init(
        fetchRecords: @escaping (@escaping ([WebsiteDataRecord]) -> Void) -> Void,
        removeDomains: @escaping ([String], @escaping (Bool) -> Void) -> Void,
        removeAll: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        self.fetchRecords = fetchRecords
        self.removeDomains = removeDomains
        self.removeAll = removeAll
        self.sheetPanel = WebsiteDataSheetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        if let customPanel = sheetPanel as? WebsiteDataSheetPanel {
            customPanel.onCancel = { [weak self] in
                self?.dismissSheet()
            }
        }

        sheetPanel.title = "Manage Website Data"
        sheetPanel.titleVisibility = .hidden
        sheetPanel.titlebarAppearsTransparent = true
        sheetPanel.isMovableByWindowBackground = false
        sheetPanel.isReleasedWhenClosed = false
        sheetPanel.standardWindowButton(.closeButton)?.isHidden = true
        sheetPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        sheetPanel.standardWindowButton(.zoomButton)?.isHidden = true
        sheetPanel.setContentSize(NSSize(width: 520, height: 440))
    }

    func makeSheetContentViewController() -> WebsiteDataSheetViewController {
        let vc = WebsiteDataSheetViewController(
            fetchRecords: fetchRecords,
            removeDomains: removeDomains,
            removeAll: removeAll
        )
        vc.onDone = { [weak self] in
            self?.dismissSheet()
        }
        return vc
    }

    func beginSheet(for parentWindow: NSWindow) {
        Self.activeController = self
        hostWindow = parentWindow
        if sheetViewController == nil {
            let vc = makeSheetContentViewController()
            sheetViewController = vc
            sheetPanel.contentViewController = vc
            sheetPanel.setContentSize(NSSize(width: 520, height: 440))
        } else if sheetViewController?.isViewLoaded == true {
            sheetViewController?.reloadRecords()
        }
        parentWindow.beginSheet(sheetPanel) { [weak self] _ in
            if Self.activeController === self {
                Self.activeController = nil
            }
        }
    }

    func dismissSheet() {
        if let win = hostWindow {
            win.endSheet(sheetPanel, returnCode: .OK)
        } else {
            sheetPanel.orderOut(nil)
        }
        if Self.activeController === self {
            Self.activeController = nil
        }
    }
}

/// Content view controller for `WebsiteDataSheetController`.
/// Exposed cleanly for hermetic unit tests without displaying an `NSPanel` on screen.
final class WebsiteDataSheetViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onDone: (() -> Void)?

    var searchQuery: String = "" {
        didSet {
            if searchField.stringValue != searchQuery {
                searchField.stringValue = searchQuery
            }
            applyFilter()
        }
    }

    private(set) var allRecords: [WebsiteDataRecord] = []
    private(set) var displayedRecords: [WebsiteDataRecord] = []
    private(set) var isLoading: Bool = false

    private let fetchRecords: (@escaping ([WebsiteDataRecord]) -> Void) -> Void
    private let removeDomains: ([String], @escaping (Bool) -> Void) -> Void
    private let removeAll: (@escaping (Bool) -> Void) -> Void

    let searchField = NSSearchField()
    let tableView = NSTableView()
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let removeAllButton = NSButton(title: "Remove All", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    let loadingIndicator = NSProgressIndicator()
    let emptyStateLabel = NSTextField(labelWithString: "No stored website data")

    private let scrollView = NSScrollView()
    private let listCard = PrivacyGlassCardView(cornerRadius: 12)
    private var didInitialLoad = false

    init(
        fetchRecords: @escaping (@escaping ([WebsiteDataRecord]) -> Void) -> Void,
        removeDomains: @escaping ([String], @escaping (Bool) -> Void) -> Void,
        removeAll: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        self.fetchRecords = fetchRecords
        self.removeDomains = removeDomains
        self.removeAll = removeAll
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
        root.translatesAutoresizingMaskIntoConstraints = false
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        self.view = root

        let titleLabel = NSTextField(labelWithString: "Manage Website Data")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor
        root.addSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "These websites have stored data that can be used to track your browsing. Removing data may sign you out of websites.")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(subtitleLabel)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        root.addSubview(searchField)

        root.addSubview(listCard)

        // Table inside glass list card
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WebsiteDataColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        listCard.bodyView.addSubview(scrollView)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isDisplayedWhenStopped = false
        listCard.bodyView.addSubview(loadingIndicator)

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true
        listCard.bodyView.addSubview(emptyStateLabel)

        // Bottom Action Bar
        PrivacyUIStyle.configureGlassButton(removeButton)
        removeButton.target = self
        removeButton.action = #selector(removeSelectedTapped)
        removeButton.isEnabled = false
        root.addSubview(removeButton)

        PrivacyUIStyle.configureGlassButton(removeAllButton)
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAllTapped)
        removeAllButton.isEnabled = false
        root.addSubview(removeAllButton)

        PrivacyUIStyle.configureGlassButton(doneButton, accent: true)
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        root.addSubview(doneButton)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),

            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            searchField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),

            listCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            listCard.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            listCard.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            listCard.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -14),

            scrollView.leadingAnchor.constraint(equalTo: listCard.bodyView.leadingAnchor, constant: 2),
            scrollView.trailingAnchor.constraint(equalTo: listCard.bodyView.trailingAnchor, constant: -2),
            scrollView.topAnchor.constraint(equalTo: listCard.bodyView.topAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: listCard.bodyView.bottomAnchor, constant: -2),

            loadingIndicator.centerXAnchor.constraint(equalTo: listCard.bodyView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: listCard.bodyView.centerYAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: listCard.bodyView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: listCard.bodyView.centerYAnchor),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualTo: listCard.bodyView.widthAnchor, constant: -32),

            removeButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            removeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            removeAllButton.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 8),
            removeAllButton.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            doneButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 78)
        ])

        preferredContentSize = NSSize(width: 520, height: 440)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if !didInitialLoad {
            reloadRecords()
        }
    }

    func reloadRecords() {
        guard !isLoading else { return }
        didInitialLoad = true
        isLoading = true
        updateStatusControls()
        loadingIndicator.startAnimation(nil)

        fetchRecords { [weak self] records in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.loadingIndicator.stopAnimation(nil)
                self.allRecords = records.sorted { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
                self.applyFilter()
            }
        }
    }

    @objc override func cancelOperation(_ sender: Any?) {
        onDone?()
    }

    private func applyFilter() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            displayedRecords = allRecords
        } else {
            displayedRecords = allRecords.filter { $0.domain.lowercased().contains(trimmed) }
        }
        tableView.reloadData()
        updateStatusControls()
    }

    private func updateStatusControls() {
        let hasSelection = !tableView.selectedRowIndexes.isEmpty
        removeButton.isEnabled = !isLoading && hasSelection
        removeAllButton.isEnabled = !isLoading && !allRecords.isEmpty

        if isLoading {
            emptyStateLabel.isHidden = true
        } else if displayedRecords.isEmpty {
            emptyStateLabel.stringValue = allRecords.isEmpty
                ? "No stored website data"
                : "No matching websites"
            emptyStateLabel.isHidden = false
        } else {
            emptyStateLabel.isHidden = true
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRecords.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < displayedRecords.count else { return nil }
        let record = displayedRecords[row]

        let identifier = NSUserInterfaceItemIdentifier("WebsiteDataCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? WebsiteDataRowCellView)
            ?? WebsiteDataRowCellView(identifier: identifier)
        cell.configure(with: record)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatusControls()
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
    }

    @objc func removeSelectedTapped() {
        let indexes = tableView.selectedRowIndexes
        let selectedDomains = indexes.compactMap { idx -> String? in
            guard idx >= 0, idx < displayedRecords.count else { return nil }
            return displayedRecords[idx].domain
        }
        guard !selectedDomains.isEmpty else { return }

        removeButton.isEnabled = false
        removeAllButton.isEnabled = false

        removeDomains(selectedDomains) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    let removedSet = Set(selectedDomains)
                    self.allRecords.removeAll { removedSet.contains($0.domain) }
                    self.tableView.deselectAll(nil)
                    self.applyFilter()
                } else {
                    self.updateStatusControls()
                }
            }
        }
    }

    @objc func removeAllTapped() {
        guard !allRecords.isEmpty else { return }
        removeButton.isEnabled = false
        removeAllButton.isEnabled = false

        removeAll { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.allRecords.removeAll()
                    self.applyFilter()
                } else {
                    self.updateStatusControls()
                }
            }
        }
    }

    @objc private func doneTapped() {
        onDone?()
    }
}

private final class WebsiteDataRowCellView: NSTableCellView {
    private let domainLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        domainLabel.translatesAutoresizingMaskIntoConstraints = false
        domainLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        domainLabel.textColor = .labelColor
        domainLabel.lineBreakMode = .byTruncatingMiddle
        domainLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right

        addSubview(domainLabel)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            domainLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            domainLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            domainLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -10),

            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func configure(with record: WebsiteDataRecord) {
        domainLabel.stringValue = record.domain
        detailLabel.stringValue = record.detailSummary
    }
}

private final class WebsiteDataSheetPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
