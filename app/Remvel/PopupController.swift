import AppKit

private final class Panel: NSPanel {
    /// ⌘1–⌘9 paste the row with that number.
    var onQuickPaste: ((Int) -> Void)?
    var onSettings: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            if let digit = Int(key), (1...9).contains(digit) {
                onQuickPaste?(digit - 1)
                return true
            }
            if key == "," {
                onSettings?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The popup: search field, virtualized history table, preview pane.
/// It is a non-activating panel so the app the user came from stays frontmost for pasting.
final class PopupController: NSObject {
    static let rowHeight: CGFloat = 30
    static let quickPasteRows = 9
    static let footer = "⏎ Paste   ⇧⏎ Plain text   ⌥⏎ Copy   ⌘-click Queue   ⌘1–9 Quick paste   #link #image #file"

    /// Screen frame of the menu bar icon, for `PopupPosition.statusItem`.
    var statusItemFrame: (() -> NSRect?)?

    private let model = HistoryModel()
    private let preview = PreviewController()
    private let settings = Settings.shared
    private let panel: Panel
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let thumbnails = NSCache<NSNumber, NSImage>()
    /// Items picked with ⌘-click, in the order they will be pasted.
    private var queue: [Int64] = []

    override init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 500),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        configureTable()

        model.onReload = { [weak self] in self?.reloadTable() }
        model.onRowsLoaded = { [weak self] rows in self?.rowsLoaded(rows) }
        panel.onQuickPaste = { [weak self] row in self?.paste(rows: [row], mode: .original) }
        panel.onSettings = { [weak self] in
            self?.close()
            SettingsWindow.shared.show()
        }
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    func historyDidChange() {
        guard panel.isVisible else { return }
        model.refresh()
    }

    private func open() {
        searchField.stringValue = ""
        queue = []
        model.setQuery("")
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        var origin: NSPoint
        switch settings.popupPosition {
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height / 8)
        case .cursor:
            origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        case .statusItem:
            guard let icon = statusItemFrame?() else { return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height) }
            origin = NSPoint(x: icon.midX - size.width / 2, y: icon.minY - size.height - 4)
        }
        // Keep the whole panel on screen.
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private func close() {
        panel.orderOut(nil)
    }

    private func pasteSelected(mode: PasteMode) {
        if queue.count > 1 {
            let ids = queue
            close()
            Paster.paste(ids: ids, mode: mode)
        } else {
            paste(rows: [table.selectedRow], mode: mode)
        }
    }

    private func paste(rows: [Int], mode: PasteMode) {
        let ids = rows.compactMap { model.summary(at: $0)?.id }
        guard !ids.isEmpty else { return }
        close()
        Paster.paste(ids: ids, mode: mode)
    }

    // MARK: Layout

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        panel.contentView = background

        searchField.placeholderString = "Search  ·  #link #image #file to filter"
        searchField.delegate = self
        searchField.focusRingType = .none

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        let divider = NSBox()
        divider.boxType = .separator

        let footer = NSTextField(labelWithString: Self.footer)
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        // Long labels must truncate, not widen the panel.
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for sub in [searchField, tableScroll, divider, preview.view, footer] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),

            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            tableScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            tableScroll.widthAnchor.constraint(equalTo: background.widthAnchor, multiplier: 0.45),

            divider.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 4),

            preview.view.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            preview.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8),
            preview.view.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            preview.view.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        // Clicks select rows but typing, ⏎ and Esc keep going to the search field.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
    }

    @objc private func tableDoubleClicked() {
        paste(rows: [table.clickedRow], mode: .original)
    }

    private func reloadTable() {
        queue = []
        table.reloadData()
        if model.rowCount > 0 {
            select(row: 0)
        } else {
            preview.show(nil)
        }
    }

    private func rowsLoaded(_ rows: IndexSet) {
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        if rows.contains(table.selectedRow) {
            preview.show(model.summary(at: table.selectedRow))
        }
    }

    private func select(row: Int) {
        let row = max(0, min(row, model.rowCount - 1))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func reloadVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location ..< NSMaxRange(visible)),
                         columnIndexes: IndexSet(integer: 0))
    }

    private func thumbnail(for item: ItemSummary, row: Int) -> NSImage? {
        let key = NSNumber(value: item.id)
        if let image = thumbnails.object(forKey: key) {
            return image
        }
        Core.shared.run({ try $0.thumbnail(id: item.id) }) { [weak self] result in
            guard let self, case .success(let data?) = result, let image = NSImage(data: data) else { return }
            self.thumbnails.setObject(image, forKey: key)
            if row < self.table.numberOfRows {
                self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
        return nil
    }

    private func icon(for item: ItemSummary, row: Int) -> NSImage? {
        if item.kind == "image" || item.kind == "files", let thumbnail = thumbnail(for: item, row: row) {
            return thumbnail
        }
        if let app = item.app, let icon = SourceApps.icon(app) {
            return icon
        }
        let symbol = switch item.kind {
        case "link": "link"
        case "image": "photo"
        case "files": "doc"
        default: "text.alignleft"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: item.kind)
    }

    /// The queue position when queued, otherwise the ⌘-number for the first rows.
    private func hint(for item: ItemSummary, row: Int) -> NSAttributedString {
        if let position = queue.firstIndex(of: item.id) {
            return NSAttributedString(string: "\(position + 1)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor,
            ])
        }
        guard row < Self.quickPasteRows else { return NSAttributedString() }
        return NSAttributedString(string: "⌘\(row + 1)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    private func title(for item: ItemSummary, row: Int) -> NSAttributedString {
        let title = NSMutableAttributedString(string: item.title)
        let indices = Set(model.titleIndices(at: row).map(Int.init))
        guard !indices.isEmpty else { return title }
        // nucleo reports grapheme indices, which are Swift Character offsets.
        var utf16Offset = 0
        for (index, character) in item.title.enumerated() {
            let length = character.utf16.count
            if indices.contains(index) {
                title.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                                   range: NSRange(location: utf16Offset, length: length))
            }
            utf16Offset += length
        }
        return title
    }
}

private final class HistoryCell: NSTableCellView {
    let hint = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.usesSingleLineMode = true
        text.cell?.wraps = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.alignment = .right
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        hint.setContentHuggingPriority(.required, for: .horizontal)
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        for sub in [image, text, hint] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        textField = text
        imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension PopupController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model.rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCell ?? HistoryCell(identifier: id)
        guard let item = model.summary(at: row) else {
            cell.imageView?.image = nil
            cell.textField?.stringValue = ""
            cell.hint.stringValue = ""
            return cell
        }
        cell.imageView?.image = icon(for: item, row: row)
        cell.textField?.attributedStringValue = title(for: item, row: row)
        cell.hint.attributedStringValue = hint(for: item, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRowIndexes
        let hadQueue = !queue.isEmpty
        if selected.count > 1 {
            // Keep the click order: survivors stay in place, new picks go to the end.
            let ids = selected.compactMap { model.summary(at: $0)?.id }
            queue = queue.filter(ids.contains) + ids.filter { !queue.contains($0) }
        } else {
            queue = []
        }
        if hadQueue || !queue.isEmpty {
            reloadVisibleRows()
        }
        preview.show(model.summary(at: table.selectedRow))
    }
}

extension PopupController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            select(row: table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)):
            select(row: table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            pasteSelected(mode: flags.contains(.option) ? .copyOnly : flags.contains(.shift) ? .plainText : .original)
        case #selector(NSResponder.cancelOperation(_:)):
            if queue.isEmpty {
                close()
            } else {
                select(row: table.selectedRow)
            }
        default:
            return false
        }
        return true
    }
}

extension PopupController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
