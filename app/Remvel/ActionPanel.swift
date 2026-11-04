import AppKit

/// One thing the action panel (⌘K) or the right-click menu can do with an item.
struct ItemAction {
    let title: String
    /// Shortcut shown beside the title, e.g. "⇧⏎"; empty for none.
    let hint: String
    let run: () -> Void
}

struct ActionSection {
    var title: String?
    var actions: [ItemAction]
}

/// The ⌘K list, drawn inside the popup rather than as a system menu: Remvel never becomes the
/// active app, and a system menu would take key focus from the popup and close it.
/// Type to filter, ↑↓ to move, ⏎ to run, Esc or ⌘K to close.
final class ActionPanel: NSVisualEffectView {
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 28
    static let maxVisibleRows = 12

    /// Called after an action runs or the panel is dismissed.
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private var sections: [ActionSection] = []
    private var rows: [Row] = []

    private enum Row {
        case header(String)
        case action(ItemAction)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .menu
        state = .active
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        field.placeholderString = "Search actions…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self

        let column = NSTableColumn(identifier: .init("action"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let separator = NSBox()
        separator.boxType = .separator
        for view in [scroll, separator, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            heightConstraint,
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ sections: [ActionSection]) {
        self.sections = sections
        field.stringValue = ""
        filter()
        isHidden = false
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
        onClose?()
    }

    private func filter() {
        let needle = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = []
        for section in sections {
            let actions = needle.isEmpty ? section.actions : section.actions.filter { $0.title.lowercased().contains(needle) }
            guard !actions.isEmpty else { continue }
            if let title = section.title { rows.append(.header(title)) }
            rows += actions.map(Row.action)
        }
        table.reloadData()
        heightConstraint.constant = CGFloat(max(1, min(rows.count, Self.maxVisibleRows))) * Self.rowHeight
        select(from: -1, step: 1)
    }

    /// Moves to the next action row from `row` in direction `step`, skipping headers; stays put at the ends.
    private func select(from row: Int, step: Int) {
        var next = row + step
        while rows.indices.contains(next) {
            if case .action = rows[next] {
                table.selectRowIndexes([next], byExtendingSelection: false)
                table.scrollRowToVisible(next)
                return
            }
            next += step
        }
        if row < 0 { table.deselectAll(nil) }
    }

    private func run(row: Int) {
        guard rows.indices.contains(row), case .action(let action) = rows[row] else {
            NSSound.beep()
            return
        }
        dismiss()
        action.run()
    }

    @objc private func clicked() {
        run(row: table.clickedRow)
    }
}

extension ActionPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(from: table.selectedRow, step: -1)
        case #selector(NSResponder.moveDown(_:)): select(from: table.selectedRow, step: 1)
        case #selector(NSResponder.insertNewline(_:)): run(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
}

extension ActionPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .action = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: "")
        let hint = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        switch rows[row] {
        case .header(let text):
            title.stringValue = text
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
        case .action(let action):
            title.stringValue = action.title
            title.font = .systemFont(ofSize: 13)
            hint.stringValue = action.hint
        }
        for view in [title, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            hint.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
