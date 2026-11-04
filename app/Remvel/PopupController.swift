import AppKit

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The popup: search field, virtualized history table, preview pane.
/// It is a non-activating panel so the app the user came from stays frontmost for pasting.
final class PopupController: NSObject {
    private let model = HistoryModel()
    private let preview = PreviewController()
    private let panel: Panel
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let thumbnails = NSCache<NSNumber, NSImage>()

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
        model.setQuery("")
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2 + frame.height / 8
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func close() {
        panel.orderOut(nil)
    }

    private func pasteSelected() {
        guard let item = model.summary(at: table.selectedRow) else { return }
        close()
        Paster.paste(id: item.id)
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

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.focusRingType = .none

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        let divider = NSBox()
        divider.boxType = .separator

        for sub in [searchField, tableScroll, divider, preview.view] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 30),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),

            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            tableScroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            tableScroll.widthAnchor.constraint(equalTo: background.widthAnchor, multiplier: 0.45),

            divider.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 4),

            preview.view.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            preview.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8),
            preview.view.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            preview.view.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),
        ])
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
    }

    @objc private func tableDoubleClicked() {
        pasteSelected()
    }

    private func reloadTable() {
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

    private func thumbnail(for item: ItemSummary, in cell: NSTableCellView, row: Int) {
        let key = NSNumber(value: item.id)
        if let image = thumbnails.object(forKey: key) {
            cell.imageView?.image = image
            return
        }
        Core.shared.run({ try $0.thumbnail(id: item.id) }) { [weak self] result in
            guard let self, case .success(let data?) = result, let image = NSImage(data: data) else { return }
            self.thumbnails.setObject(image, forKey: key)
            if row < self.table.numberOfRows {
                self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
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

extension PopupController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model.rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? Self.makeCell(id)
        cell.imageView?.image = nil
        guard let item = model.summary(at: row) else {
            cell.textField?.stringValue = ""
            return cell
        }
        cell.textField?.attributedStringValue = title(for: item, row: row)
        if item.kind == "image" {
            thumbnail(for: item, in: cell, row: row)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        preview.show(model.summary(at: table.selectedRow))
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyDown
        for sub in [image, text] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(sub)
        }
        cell.textField = text
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 22),
            image.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
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
        case #selector(NSResponder.insertNewline(_:)):
            pasteSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
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
