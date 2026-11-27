import AppKit

/// Native 1:1 macOS Safari History Page (`safarium://history`) hosted inside a Safarium tab:
/// - Full-bleed background extending behind the 52pt frosted toolbar
/// - Header row with bold `History` title on left, pill `Clear History...` button + pill `Search` field on right
/// - Expandable `NSOutlineView` grouped by calendar day (`Last Visited Today`, `25 November 2026 Wednesday`, ...)
///   with `Website` and `Address` columns, favicons, item counts, live search, keyboard navigation, and context menu.
final class HistoryPageView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    static var boundFaviconURLKey: UInt8 = 0

    var onOpenURL: ((URL, Bool) -> Void)?
    var onClearHistory: (() -> Void)?

    final class HistoryGroupNode: NSObject {
        let dayKey: String
        let title: String
        let date: Date
        var items: [HistoryItemNode]

        init(dayKey: String, title: String, date: Date, items: [HistoryItemNode]) {
            self.dayKey = dayKey
            self.title = title
            self.date = date
            self.items = items
        }
    }

    final class HistoryItemNode: NSObject {
        let entry: AssetLoader.HistoryEntry
        init(entry: AssetLoader.HistoryEntry) {
            self.entry = entry
        }
    }

    private static let websiteColID = NSUserInterfaceItemIdentifier("WebsiteColumn")
    private static let addressColID = NSUserInterfaceItemIdentifier("AddressColumn")

    private let headerContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "History")
    private let clearButton = NSButton()
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let outlineView = HistoryKeyOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "No Browsing History")

    var groups: [HistoryGroupNode] = []
    private var expandedDayKeys: Set<String> = []
    private var hasInitializedExpansion = false
    private var searchQuery: String = ""
    private var historyObserver: NSObjectProtocol?

    static let dayHeaderFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "d MMMM yyyy EEEE"
        return df
    }()

    static let dayKeyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    var effectiveTopColor: NSColor {
        isDarkMode
            ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1.0)
            : NSColor.white
    }

    var prefersDarkAppearance: Bool { isDarkMode }

    private var isDarkMode: Bool {
        let best = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return best == .darkAqua
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupUI()
        applyColors()
        reloadHistoryData()

        historyObserver = NotificationCenter.default.addObserver(
            forName: .safariumHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadHistoryData()
        }
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        outlineView.reloadData()
    }

    override func layout() {
        super.layout()
        updateColumnWidths()
    }

    func reloadIfVisible() {
        reloadHistoryData()
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: - Setup

    private func setupUI() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerContainer)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        headerContainer.addSubview(titleLabel)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.title = "Clear History..."
        clearButton.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        clearButton.isBordered = false
        clearButton.wantsLayer = true
        clearButton.layer?.cornerRadius = 12
        clearButton.layer?.cornerCurve = .continuous
        clearButton.target = self
        clearButton.action = #selector(clearHistoryClicked)
        headerContainer.addSubview(clearButton)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.controlSize = .regular
        searchField.font = NSFont.systemFont(ofSize: 12.5)
        searchField.bezelStyle = .roundedBezel
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        headerContainer.addSubview(searchField)

        // OutlineView setup
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnResizing = true
        outlineView.allowsColumnReordering = false
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 8, height: 0)
        outlineView.indentationPerLevel = 14
        outlineView.style = .plain
        outlineView.gridStyleMask = []
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked)
        outlineView.onReturnKey = { [weak self] in self?.openSelectedItems(newTab: false) }
        outlineView.onDeleteKey = { [weak self] in self?.deleteSelectedItems() }

        let websiteCol = NSTableColumn(identifier: Self.websiteColID)
        websiteCol.title = "Website"
        websiteCol.minWidth = 240
        websiteCol.width = 560
        websiteCol.resizingMask = .userResizingMask
        outlineView.addTableColumn(websiteCol)

        let addressCol = NSTableColumn(identifier: Self.addressColID)
        addressCol.title = "Address"
        addressCol.minWidth = 180
        addressCol.width = 480
        addressCol.resizingMask = .userResizingMask
        outlineView.addTableColumn(addressCol)
        outlineView.outlineTableColumn = websiteCol

        let ctxMenu = NSMenu()
        ctxMenu.delegate = self
        outlineView.menu = ctxMenu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = outlineView
        addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: topAnchor, constant: SafariMetrics.toolbarHeight),
            headerContainer.heightAnchor.constraint(equalToConstant: 54),

            titleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 20),
            titleLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor, constant: 1),

            searchField.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -20),
            searchField.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor, constant: 1),
            searchField.widthAnchor.constraint(equalToConstant: 190),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            clearButton.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 112),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20)
        ])
    }

    private func applyColors() {
        let dark = isDarkMode
        let bg = effectiveTopColor
        layer?.backgroundColor = bg.cgColor
        scrollView.backgroundColor = bg
        outlineView.backgroundColor = bg
        titleLabel.textColor = dark ? NSColor.white.withAlphaComponent(0.95) : NSColor(white: 0.10, alpha: 1.0)
        emptyLabel.textColor = dark ? NSColor.white.withAlphaComponent(0.45) : NSColor.secondaryLabelColor

        clearButton.layer?.backgroundColor = (dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor(white: 0.92, alpha: 1.0)).cgColor
        clearButton.contentTintColor = dark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.14, alpha: 1.0)
        clearButton.attributedTitle = NSAttributedString(
            string: "Clear History...",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: dark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.14, alpha: 1.0)
            ]
        )
    }

    private func updateColumnWidths() {
        let avail = max(420, scrollView.contentSize.width)
        guard let wCol = outlineView.tableColumn(withIdentifier: Self.websiteColID),
              let aCol = outlineView.tableColumn(withIdentifier: Self.addressColID) else { return }
        let targetW = floor(avail * 0.56)
        let targetA = max(180, avail - targetW - 8)
        if abs(wCol.width - targetW) > 12 || abs(aCol.width - targetA) > 12 {
            wCol.width = targetW
            aCol.width = targetA
        }
    }

    // MARK: - Data Loading & Grouping

    func reloadHistoryData() {
        let allEntries = AssetLoader.shared.browsingHistory()
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        let filtered: [AssetLoader.HistoryEntry]
        if q.isEmpty {
            filtered = allEntries
        } else {
            filtered = allEntries.filter {
                $0.title.localizedCaseInsensitiveContains(q) ||
                $0.url.localizedCaseInsensitiveContains(q)
            }
        }

        let cal = Calendar.current
        var bucketOrder: [String] = []
        var bucketMap: [String: (date: Date, entries: [AssetLoader.HistoryEntry])] = [:]

        for entry in filtered {
            let dayStart = cal.startOfDay(for: entry.lastVisited)
            let key = Self.dayKeyFormatter.string(from: dayStart)
            if bucketMap[key] == nil {
                bucketOrder.append(key)
                bucketMap[key] = (dayStart, [])
            }
            bucketMap[key]?.entries.append(entry)
        }

        var built: [HistoryGroupNode] = []
        built.reserveCapacity(bucketOrder.count)
        for key in bucketOrder {
            guard let bucket = bucketMap[key] else { continue }
            let title: String
            if cal.isDateInToday(bucket.date) {
                title = "Last Visited Today"
            } else {
                title = Self.dayHeaderFormatter.string(from: bucket.date)
            }
            let sortedEntries = bucket.entries.sorted { $0.lastVisited > $1.lastVisited }
            let nodes = sortedEntries.map { HistoryItemNode(entry: $0) }
            built.append(HistoryGroupNode(dayKey: key, title: title, date: bucket.date, items: nodes))
        }

        self.groups = built
        if !hasInitializedExpansion, let first = built.first {
            expandedDayKeys.insert(first.dayKey)
            hasInitializedExpansion = true
        }

        emptyLabel.stringValue = q.isEmpty ? "No Browsing History" : "No Matching History"
        emptyLabel.isHidden = !built.isEmpty
        clearButton.isEnabled = !allEntries.isEmpty

        outlineView.reloadData()
        for group in built {
            if !q.isEmpty || expandedDayKeys.contains(group.dayKey) {
                outlineView.expandItem(group)
            }
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let g = item as? HistoryGroupNode { return g.items.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        if let g = item as? HistoryGroupNode { return g.items[index] }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is HistoryGroupNode
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return (item is HistoryGroupNode) ? 26.0 : 24.0
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let group = notification.userInfo?["NSObject"] as? HistoryGroupNode {
            expandedDayKeys.insert(group.dayKey)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let group = notification.userInfo?["NSObject"] as? HistoryGroupNode {
            expandedDayKeys.remove(group.dayKey)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let colID = tableColumn?.identifier else { return nil }

        if let group = item as? HistoryGroupNode {
            if colID == Self.websiteColID {
                let id = NSUserInterfaceItemIdentifier("HistoryGroupWebsiteCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeIconTextCell(identifier: id, isGroup: true)
                cell.imageView?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13.0, weight: .regular))
                cell.imageView?.contentTintColor = .secondaryLabelColor
                cell.textField?.stringValue = group.title
                cell.textField?.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
                return cell
            } else {
                let id = NSUserInterfaceItemIdentifier("HistoryGroupCountCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeAddressCell(identifier: id)
                let count = group.items.count
                cell.textField?.stringValue = count == 1 ? "1 item" : "\(count) items"
                cell.textField?.textColor = .secondaryLabelColor
                return cell
            }
        }

        if let node = item as? HistoryItemNode {
            if colID == Self.websiteColID {
                let id = NSUserInterfaceItemIdentifier("HistoryItemWebsiteCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeIconTextCell(identifier: id, isGroup: false)
                let title = node.entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                cell.textField?.stringValue = title.isEmpty ? "(no title)" : title
                cell.textField?.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)

                let urlStr = node.entry.url
                if let cached = FaviconCache.shared.cachedImage(forURLString: urlStr) {
                    cell.imageView?.image = cached
                    cell.imageView?.contentTintColor = nil
                } else {
                    cell.imageView?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 12.5, weight: .regular))
                    cell.imageView?.contentTintColor = .secondaryLabelColor
                    objc_setAssociatedObject(cell, &HistoryPageView.boundFaviconURLKey, urlStr, .OBJC_ASSOCIATION_COPY_NONATOMIC)
                    FaviconCache.shared.fetchFavicon(forURLString: urlStr) { [weak cell] img in
                        guard let img, let cell else { return }
                        // Cells are recycled: ignore a late icon that belongs to a row this cell no longer shows.
                        guard (objc_getAssociatedObject(cell, &HistoryPageView.boundFaviconURLKey) as? String) == urlStr else { return }
                        cell.imageView?.image = img
                        cell.imageView?.contentTintColor = nil
                    }
                }
                return cell
            } else {
                let id = NSUserInterfaceItemIdentifier("HistoryItemAddressCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeAddressCell(identifier: id)
                cell.textField?.stringValue = node.entry.url
                cell.textField?.textColor = .secondaryLabelColor
                return cell
            }
        }

        return nil
    }

    private func makeIconTextCell(identifier: NSUserInterfaceItemIdentifier, isGroup: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        iv.wantsLayer = true
        if !isGroup {
            iv.layer?.cornerRadius = 3.0
            iv.layer?.masksToBounds = true
        }
        cell.addSubview(iv)
        cell.imageView = iv

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        tf.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),

            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeAddressCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        tf.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        if let sf = obj.object as? NSSearchField {
            searchQuery = sf.stringValue
            reloadHistoryData()
        }
    }

    // MARK: - Actions & Context Menu

    @objc private func clearHistoryClicked() {
        onClearHistory?()
    }

    @objc private func outlineDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if let group = item as? HistoryGroupNode {
            if outlineView.isItemExpanded(group) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
            return
        }
        if let node = item as? HistoryItemNode, let url = URL(string: node.entry.url) {
            let openInNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            onOpenURL?(url, openInNewTab)
        }
    }

    private func openSelectedItems(newTab: Bool) {
        let rows = outlineView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        var first = true
        for row in rows {
            guard let item = outlineView.item(atRow: row) else { continue }
            if let group = item as? HistoryGroupNode, rows.count == 1 {
                if outlineView.isItemExpanded(group) {
                    outlineView.collapseItem(group)
                } else {
                    outlineView.expandItem(group)
                }
                return
            }
            if let node = item as? HistoryItemNode, let url = URL(string: node.entry.url) {
                onOpenURL?(url, newTab || !first)
                first = false
            }
        }
    }

    private func deleteSelectedItems() {
        let rows = outlineView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        var urlsToDelete = Set<String>()
        for row in rows {
            guard let item = outlineView.item(atRow: row) else { continue }
            if let group = item as? HistoryGroupNode {
                for child in group.items {
                    urlsToDelete.insert(child.entry.url)
                }
            } else if let node = item as? HistoryItemNode {
                urlsToDelete.insert(node.entry.url)
            }
        }
        guard !urlsToDelete.isEmpty else { return }
        AssetLoader.shared.removeHistoryEntries(urls: urlsToDelete)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) else { return }
        if !outlineView.isRowSelected(clickedRow) {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        if let node = item as? HistoryItemNode {
            let openItem = NSMenuItem(title: "Open", action: #selector(ctxOpenAction(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = node.entry.url
            menu.addItem(openItem)

            let openNewTabItem = NSMenuItem(title: "Open in New Tab", action: #selector(ctxOpenNewTabAction(_:)), keyEquivalent: "")
            openNewTabItem.target = self
            openNewTabItem.representedObject = node.entry.url
            menu.addItem(openNewTabItem)

            let copyItem = NSMenuItem(title: "Copy Address", action: #selector(ctxCopyAction(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = node.entry.url
            menu.addItem(copyItem)

            menu.addItem(.separator())
            let delItem = NSMenuItem(title: "Delete", action: #selector(ctxDeleteAction), keyEquivalent: "")
            delItem.target = self
            menu.addItem(delItem)
        } else if item is HistoryGroupNode {
            let delGroup = NSMenuItem(title: "Delete All Items in Group", action: #selector(ctxDeleteAction), keyEquivalent: "")
            delGroup.target = self
            menu.addItem(delGroup)
        }
    }

    @objc private func ctxOpenAction(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let u = URL(string: s) else { return }
        onOpenURL?(u, false)
    }

    @objc private func ctxOpenNewTabAction(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let u = URL(string: s) else { return }
        onOpenURL?(u, true)
    }

    @objc private func ctxCopyAction(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @objc private func ctxDeleteAction() {
        deleteSelectedItems()
    }
}

private final class HistoryKeyOutlineView: NSOutlineView {
    var onReturnKey: (() -> Void)?
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / Enter
            onReturnKey?()
        case 51, 117: // Delete / Forward Delete
            onDeleteKey?()
        default:
            super.keyDown(with: event)
        }
    }
}
