import AppKit

private final class Panel: NSPanel {
    /// ⌘1–⌘9 paste the row with that number.
    var onQuickPaste: ((Int) -> Void)?
    var onSettings: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onTogglePin: (() -> Void)?
    /// ⌘C with no text selected in the search field copies the selected item.
    var onCopyItem: (() -> Void)?
    var onShowActions: (() -> Void)?
    var onToggleLargePreview: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// ⌥P would type "π" into the search field, so it is taken before the field sees it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option,
           event.keyCode == 35 { // P
            onTogglePin?()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = Self.latinKey(event)
        // Remvel has no Edit menu to route these, so the search field gets them here.
        if let editor = firstResponder as? NSTextView {
            switch (flags, key) {
            case (.command, "a"): editor.selectAll(nil); return true
            case (.command, "x"): editor.cut(nil); return true
            case (.command, "v"): editor.paste(nil); return true
            case (.command, "z"): editor.undoManager?.undo(); return true
            case ([.command, .shift], "z"): editor.undoManager?.redo(); return true
            case (.command, "c"):
                if editor.selectedRange().length > 0 { editor.copy(nil) } else { onCopyItem?() }
                return true
            default: break
            }
        }
        if flags == .command, let digit = Int(key), (1...9).contains(digit) {
            onQuickPaste?(digit - 1)
            return true
        }
        if flags == .command, key == "k" {
            onShowActions?()
            return true
        }
        if flags == .command, key == "y" {
            onToggleLargePreview?()
            return true
        }
        if flags == .command, key == "," {
            onSettings?()
            return true
        }
        if flags == [.command, .option], key == "s" {
            onToggleSidebar?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The key as on a US layout, so ⌘Y works while typing Korean ("ㅛ") or another non-Latin script.
    /// Latin layouts keep their own letters, so a Dvorak user's ⌘K is still the key marked K.
    private static func latinKey(_ event: NSEvent) -> String {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key.allSatisfy(\.isASCII) { return key }
        return usKeys[event.keyCode] ?? key
    }

    private static let usKeys: [UInt16: String] = [
        0: "a", 1: "s", 6: "z", 7: "x", 8: "c", 9: "v", 16: "y", 40: "k", 43: ",",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]
}

/// The popup: search band, optional facet sidebar, virtualized history list, preview card, hint footer.
/// It is a non-activating panel so the app the user came from stays frontmost for pasting.
/// Its size is fixed per mode; content scales or truncates to fit and never resizes it.
final class PopupController: NSObject {
    static let compactSize = NSSize(width: 960, height: 600)
    static let expandedSize = NSSize(width: 1200, height: 700)
    static let sidebarWidth: CGFloat = 210
    static let listWidth: CGFloat = 396
    static let rowHeight: CGFloat = 30
    static let quickPasteRows = 9
    /// Apps listed in the filter menu; the sidebar scrolls through all of them.
    static let maxFacetApps = 12
    /// Apps that `@name` in the search field and the sidebar can pick from.
    static let maxKnownApps: UInt32 = 500

    /// Screen frame of the menu bar icon, for `PopupPosition.statusItem`.
    var statusItemFrame: (() -> NSRect?)?

    private let model = HistoryModel()
    private let preview = PreviewController()
    private let settings = Settings.shared
    private let panel: Panel
    private let searchField = NSSearchField()
    private let chips = NSStackView()
    private let filterButton = NSButton()
    private let sidebarButton = NSButton()
    private let listHeader = NSTextField(labelWithString: "History")
    private let listCount = NSTextField(labelWithString: "")
    private let table = HistoryTable()
    private let actionPanel = ActionPanel()
    private let footer = NSTextField(labelWithString: "")
    private let sidebar = SidebarController()
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var facets = Facets(kinds: [], apps: [])

    /// Items picked with ⌘-click, in the order they will be pasted. Independent of the visible rows
    /// and of the selected (previewed) row, so it survives searching and filtering.
    private var queue: [Int64] = []
    /// Where the selection goes after the next reload: the item with `id` once its row loads,
    /// or else `row`. Set by pinning and deleting so the selection does not jump to the top.
    private var reselect: (id: Int64?, row: Int)?
    /// ⌘Y: the preview takes the list's place; ↑↓ still move through the list.
    private var largePreview = false
    private var listViews: [NSView] = []
    private var previewBesideList: NSLayoutConstraint!
    private var previewAlone: NSLayoutConstraint!

    private var expanded: Bool {
        get { UserDefaults.standard.bool(forKey: "popupExpanded") }
        set { UserDefaults.standard.set(newValue, forKey: "popupExpanded") }
    }

    override init() {
        panel = Panel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
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
        panel.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        panel.onTogglePin = { [weak self] in self.map { $0.togglePin(row: $0.table.selectedRow) } }
        panel.onCopyItem = { [weak self] in self?.pasteSelected(mode: .copyOnly) }
        panel.onShowActions = { [weak self] in self?.showActions() }
        panel.onToggleLargePreview = { [weak self] in self.map { $0.setLargePreview(!$0.largePreview) } }
        preview.onPickFile = { [weak self] path in self?.pasteFiles([path], ofRow: self?.table.selectedRow ?? -1) }
        sidebar.onSelect = { [weak self] filter in self?.model.filter = filter }
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
        loadFacets()
    }

    /// Opens the popup with `query` already typed, or brings it forward with that query.
    func show(query: String) {
        if !panel.isVisible { open() }
        searchField.stringValue = query
        model.setQuery(query)
        NSApp.activate(ignoringOtherApps: false)
        panel.makeKeyAndOrderFront(nil)
    }

    private func open() {
        setLargePreview(false)
        // Screen sharing, recordings and screenshots see an empty space instead, when asked.
        panel.sharingType = settings.hideFromScreenSharing ? .none : .readOnly
        searchField.stringValue = ""
        queue = []
        model.setQuery("")
        model.filter = Filter(kinds: [], apps: [])
        applyMode()
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        loadFacets()
    }

    /// For `Snapshot`: lays the panel out as `open()` would, without showing it or taking focus.
    func prepareSnapshot(query: String, expanded: Bool, large: Bool = false, actions: Bool = false, queueRows: [Int],
                         then: @escaping (NSView) -> Void) {
        self.expanded = expanded
        setLargePreview(large)
        searchField.stringValue = query
        queue = []
        model.filter = Filter(kinds: [], apps: [])
        model.setQuery(query)
        applyMode()
        loadFacets()
        // Let pages, facets and previews arrive, then queue rows by id as ⌘-click would.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for row in queueRows { self.toggleQueued(row: row) }
            if let last = queueRows.last { self.select(row: last) }
            if actions { self.showActions() }
            // Link previews come from the network.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                then(self.panel.contentView!)
            }
        }
    }

    private func close() {
        actionPanel.isHidden = true
        panel.orderOut(nil)
    }

    private func loadFacets() {
        Core.shared.run({ try $0.facets(maxApps: Self.maxKnownApps) }) { [weak self] result in
            guard let self, case .success(let facets) = result else { return }
            self.model.knownApps = facets.apps.map(\.name)
            self.facets = facets
            self.sidebar.update(facets: facets, total: facets.kinds.reduce(0) { $0 + $1.count }, filter: self.model.filter)
        }
    }

    // MARK: Modes and position

    private func toggleSidebar() {
        expanded.toggle()
        let top = panel.frame.maxY
        applyMode()
        var frame = panel.frame
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true, animate: false)
        panel.setFrameOrigin(clamped(panel.frame.origin, size: panel.frame.size))
    }

    private func applyMode() {
        let size = expanded ? Self.expandedSize : Self.compactSize
        sidebarWidthConstraint.constant = expanded ? Self.sidebarWidth : 0
        sidebar.view.isHidden = !expanded
        sidebarButton.state = expanded ? .on : .off
        panel.setContentSize(size)
        panel.contentMinSize = size
        panel.contentMaxSize = size
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        let origin: NSPoint
        switch settings.popupPosition {
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height / 8)
        case .cursor:
            origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        case .statusItem:
            if let icon = statusItemFrame?() {
                origin = NSPoint(x: icon.midX - size.width / 2, y: icon.minY - size.height - 4)
            } else {
                origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height)
            }
        }
        return clamped(origin, size: size)
    }

    /// Keeps the whole panel on the screen it is on.
    private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: origin.x + 1, y: origin.y + size.height - 1)) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }

    // MARK: Pasting

    private func pasteSelected(mode: PasteMode) {
        if !queue.isEmpty {
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

    private func toggleQueued(row: Int) {
        guard let id = model.summary(at: row)?.id else { return }
        if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
        } else {
            queue.append(id)
        }
        reloadVisibleRows()
        updateFooter()
    }

    private func clearQueue() {
        queue = []
        reloadVisibleRows()
        updateFooter()
    }

    // MARK: Pinning and deleting

    /// Pinned items stay at the top of the history and are never trimmed.
    private func togglePin(row: Int) {
        guard let item = model.summary(at: row) else { return }
        // The pin value orders pins: first pinned stays first.
        let pin = item.pin == nil ? String(format: "%013lld", Int64(Date().timeIntervalSince1970 * 1000)) : nil
        Core.shared.run({ try $0.setPin(id: item.id, pin: pin) }) { [weak self] _ in
            self?.reselect = (item.id, row)
            self?.model.refresh()
        }
    }

    private func delete(row: Int) {
        guard let item = model.summary(at: row) else { return }
        queue.removeAll { $0 == item.id }
        let remove = {
            Core.shared.run({ try $0.delete(id: item.id) }) { [weak self] _ in
                self?.reselect = (nil, row)
                self?.model.refresh()
                self?.loadFacets()
            }
        }
        // Fade the row out first, so it is clear which one went.
        guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { return remove() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            rowView.animator().alphaValue = 0
        }, completionHandler: remove)
    }

    // MARK: Actions (⌘K) and transforms

    /// The selected item's actions as a menu under its row; type to jump to one.
    /// ⌘K: opens the action panel for the selected item, or closes it.
    private func showActions() {
        guard actionPanel.isHidden else { return actionPanel.dismiss() }
        let sections = actionSections(row: table.selectedRow)
        guard !sections.isEmpty else { return }
        actionPanel.show(sections)
    }

    /// What ⌘K and right-click offer for the item at `row`.
    private func actionSections(row: Int) -> [ActionSection] {
        guard let item = model.summary(at: row) else { return [] }
        let action = { (title: String, hint: String, run: @escaping () -> Void) in ItemAction(title: title, hint: hint, run: run) }
        var sections = [
            ActionSection(title: nil, actions: [
                action(item.kind == "files" ? "Paste Files" : "Paste", "⏎") { [weak self] in self?.paste(rows: [row], mode: .original) },
                action(item.kind == "image" ? "Paste Text in Image" : item.kind == "files" ? "Paste Paths" : "Paste as Plain Text",
                       "⇧⏎") { [weak self] in self?.paste(rows: [row], mode: .plainText) },
                action("Copy", "⌥⏎") { [weak self] in self?.paste(rows: [row], mode: .copyOnly) },
                action(largePreview ? "Smaller Preview" : "Larger Preview", "⌘Y") { [weak self] in
                    self.map { $0.setLargePreview(!$0.largePreview) }
                },
                action(item.pin == nil ? "Pin" : "Unpin", "⌥P") { [weak self] in self?.togglePin(row: row) },
                action("Delete", "⌥⌫") { [weak self] in self?.delete(row: row) },
            ]),
        ]
        if item.kind == "files" {
            // The preview has loaded the selected item's paths.
            guard row == table.selectedRow, preview.filePaths.count > 1 else { return sections }
            sections.append(ActionSection(title: "Paste One File", actions: preview.filePaths.map { path in
                action((path as NSString).lastPathComponent, "") { [weak self] in self?.pasteFiles([path], ofRow: row) }
            }))
            return sections
        }
        for (index, group) in Transform.all.enumerated() {
            sections.append(ActionSection(title: index == 0 ? "Paste Changed" : nil, actions: group.map { transform in
                action(transform.title, "") { [weak self] in self?.paste(id: item.id, transformedBy: transform) }
            }))
        }
        return sections
    }

    private func pasteFiles(_ paths: [String], ofRow row: Int) {
        guard let item = model.summary(at: row) else { return }
        close()
        Paster.paste(files: paths, from: item.id)
    }

    /// Pastes the item's text after `transform`; beeps when it does not apply.
    private func paste(id: Int64, transformedBy transform: Transform) {
        Core.shared.run({ try $0.fullText(id: id) }) { [weak self] result in
            guard case .success(let text) = result, !text.isEmpty, let changed = transform.apply(text) else {
                NSSound.beep()
                return
            }
            self?.close()
            Paster.paste(text: changed, from: id)
        }
    }

    private func setLargePreview(_ on: Bool) {
        largePreview = on
        listViews.forEach { $0.isHidden = on }
        previewBesideList.isActive = !on
        previewAlone.isActive = on
        updateFooter()
    }

    // MARK: Layout

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        panel.contentView = background

        searchField.placeholderString = "Search clipboard history      #image  @app"
        searchField.delegate = self
        searchField.focusRingType = .default
        searchField.font = .systemFont(ofSize: 14)
        searchField.controlSize = .large

        chips.orientation = .horizontal
        chips.spacing = 6

        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter")
        filterButton.bezelStyle = .texturedRounded
        filterButton.isBordered = false
        filterButton.toolTip = "Filter by kind or app"
        filterButton.target = self
        filterButton.action = #selector(showFilterMenu)

        sidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
        sidebarButton.setButtonType(.pushOnPushOff)
        sidebarButton.isBordered = false
        sidebarButton.toolTip = "Browse by kind and app (⌥⌘S)"
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarClicked)

        listHeader.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        listHeader.textColor = .secondaryLabelColor
        listCount.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        listCount.textColor = .secondaryLabelColor
        listCount.alignment = .right

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        let divider = NSBox()
        divider.boxType = .separator
        let footerLine = NSBox()
        footerLine.boxType = .separator

        footer.lineBreakMode = .byTruncatingTail
        let settingsHint = NSTextField(labelWithAttributedString: Self.hints([("Settings", "⌘,")]))

        for label in [footer, listHeader, listCount, settingsHint] {
            // Labels truncate; they must never widen the panel.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        settingsHint.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let views: [NSView] = [
            searchField, chips, filterButton, sidebarButton, sidebar.view, listHeader, listCount, tableScroll,
            divider, preview.view, footerLine, footer, settingsHint, actionPanel,
        ]
        for sub in views {
            sub.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(sub)
        }
        sidebarWidthConstraint = sidebar.view.widthAnchor.constraint(equalToConstant: 0)
        let listLeading = sidebar.view.trailingAnchor
        listViews = [listHeader, listCount, tableScroll, divider]
        previewBesideList = preview.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 16)
        previewAlone = preview.view.leadingAnchor.constraint(equalTo: listLeading, constant: 16)
        previewBesideList.isActive = true

        NSLayoutConstraint.activate([
            // Search band, 56 pt.
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            chips.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            chips.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            filterButton.leadingAnchor.constraint(equalTo: chips.trailingAnchor, constant: 6),
            filterButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            sidebarButton.leadingAnchor.constraint(equalTo: filterButton.trailingAnchor, constant: 8),
            sidebarButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            sidebarButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),

            // Sidebar, only in the expanded mode.
            sidebar.view.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            sidebar.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: footerLine.topAnchor),
            sidebarWidthConstraint,

            // History list.
            listHeader.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            listHeader.leadingAnchor.constraint(equalTo: listLeading, constant: 22),
            listCount.firstBaselineAnchor.constraint(equalTo: listHeader.firstBaselineAnchor),
            listCount.trailingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: -14),
            listCount.leadingAnchor.constraint(greaterThanOrEqualTo: listHeader.trailingAnchor, constant: 8),
            tableScroll.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: listLeading, constant: 4),
            tableScroll.widthAnchor.constraint(equalToConstant: Self.listWidth),
            tableScroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -4),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            divider.bottomAnchor.constraint(equalTo: footerLine.topAnchor),
            divider.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 4),

            // Preview card with metadata pinned below it.
            preview.view.topAnchor.constraint(equalTo: listHeader.topAnchor),
            preview.view.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            preview.view.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -12),

            // Footer, 40 pt.
            footerLine.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footerLine.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -40),
            actionPanel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            actionPanel.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            footer.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -20),
            settingsHint.leadingAnchor.constraint(greaterThanOrEqualTo: footer.trailingAnchor, constant: 16),
            settingsHint.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            settingsHint.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        // 30 pt is the full row pitch, so no extra spacing between rows.
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        // One selected row is the preview; the queue is tracked separately.
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        // Clicks select rows but typing, ⏎ and Esc keep going to the search field.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        table.doubleAction = #selector(tableDoubleClicked)
        table.onRightClick = { [weak self] row in
            self?.select(row: row)
            self?.actionPanel.dismiss()
            self?.showActions()
        }
        actionPanel.isHidden = true
        actionPanel.onClose = { [weak self] in self.map { $0.panel.makeFirstResponder($0.searchField) } }
    }

    @objc private func tableClicked() {
        guard table.clickedRow >= 0 else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            toggleQueued(row: table.clickedRow)
            select(row: table.clickedRow)
        }
    }

    @objc private func tableDoubleClicked() {
        guard table.clickedRow >= 0, NSApp.currentEvent?.modifierFlags.contains(.command) != true else { return }
        paste(rows: [table.clickedRow], mode: .original)
    }

    @objc private func sidebarClicked() {
        toggleSidebar()
    }

    // MARK: Filter menu and chips

    @objc private func showFilterMenu() {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Kind"))
        let counts = Dictionary(uniqueKeysWithValues: facets.kinds.map { ($0.name, $0.count) })
        for info in Kinds.all where counts[info.kind] != nil {
            let item = menu.addItem(withTitle: "\(info.name)  \(counts[info.kind]!.formatted())",
                                    action: #selector(toggleKind(_:)), keyEquivalent: "")
            item.image = Kinds.symbol(info.kind)
            item.representedObject = info.kind
            item.state = model.filter.kinds.contains(info.kind) ? .on : .off
            item.target = self
        }
        if !facets.apps.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "App"))
            for app in facets.apps.prefix(Self.maxFacetApps) {
                let item = menu.addItem(withTitle: "\(SourceApps.name(app.name))  \(app.count.formatted())",
                                        action: #selector(toggleApp(_:)), keyEquivalent: "")
                item.image = SourceApps.icon(app.name).map(Self.menuIcon)
                item.representedObject = app.name
                item.state = model.filter.apps.contains(app.name) ? .on : .off
                item.target = self
            }
        }
        if !model.filter.kinds.isEmpty || !model.filter.apps.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clear Filters", action: #selector(clearFilters), keyEquivalent: "").target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.height + 4), in: filterButton)
    }

    private static func menuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    @objc private func toggleKind(_ item: NSMenuItem) {
        guard let kind = item.representedObject as? String else { return }
        var filter = model.filter
        filter.kinds = filter.kinds.contains(kind) ? filter.kinds.filter { $0 != kind } : filter.kinds + [kind]
        setFilter(filter)
    }

    @objc private func toggleApp(_ item: NSMenuItem) {
        guard let app = item.representedObject as? String else { return }
        var filter = model.filter
        filter.apps = filter.apps.contains(app) ? filter.apps.filter { $0 != app } : filter.apps + [app]
        setFilter(filter)
    }

    @objc private func clearFilters() {
        setFilter(Filter(kinds: [], apps: []))
    }

    @objc private func removeChip(_ sender: NSButton) {
        var filter = model.filter
        filter.kinds.removeAll { $0 == sender.identifier?.rawValue }
        filter.apps.removeAll { $0 == sender.identifier?.rawValue }
        setFilter(filter)
    }

    private func setFilter(_ filter: Filter) {
        model.filter = filter
        sidebar.select(filter)
    }

    /// One removable chip per active kind or app filter, next to the search field.
    private func updateChips() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = model.filter.kinds.map { ($0, Kinds.info($0).name, Kinds.symbol($0)) }
            + model.filter.apps.map { ($0, SourceApps.name($0), SourceApps.icon($0).map(Self.menuIcon)) }
        for (id, name, image) in entries {
            let chip = NSButton(title: "\(name)  ✕", target: self, action: #selector(removeChip(_:)))
            chip.identifier = NSUserInterfaceItemIdentifier(id)
            chip.image = image
            chip.imagePosition = .imageLeading
            chip.bezelStyle = .push
            chip.controlSize = .small
            chip.toolTip = "Remove this filter"
            chips.addArrangedSubview(chip)
        }
        filterButton.contentTintColor = entries.isEmpty ? nil : .controlAccentColor
    }

    // MARK: Table updates

    private func reloadTable() {
        table.reloadData()
        updateChips()
        listHeader.stringValue = model.isFiltered ? "Results" : "History"
        let noun = model.isFiltered ? "" : (model.rowCount == 1 ? " item" : " items")
        listCount.stringValue = "\(model.rowCount.formatted())\(noun)"
        if model.rowCount > 0 {
            select(row: reselect?.row ?? 0)
            if reselect?.id == nil { reselect = nil }
        } else {
            reselect = nil
            preview.show(nil)
            updateFooter()
        }
    }

    private func rowsLoaded(_ rows: IndexSet) {
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        if let id = reselect?.id {
            reselect = nil
            if let row = rows.first(where: { model.summary(at: $0)?.id == id }) {
                select(row: row)
            }
        }
        if rows.contains(table.selectedRow) {
            preview.show(model.summary(at: table.selectedRow))
            updateFooter()
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

    /// Keyboard hints for what ⏎ and friends will do right now.
    private func updateFooter() {
        var hints: [(String, String)]
        if !queue.isEmpty {
            hints = [("⏎", "Paste \(queue.count) in order"), ("⇧⏎", "As plain text"),
                     ("⌘-click", "Add or remove"), ("Esc", "Clear queue")]
        } else {
            let item = model.summary(at: table.selectedRow)
            switch item?.kind {
            case "image":
                hints = [("⏎", "Paste image"), ("⇧⏎", "Paste its text"), ("⌥⏎", "Copy")]
            case "files":
                hints = [("⏎", "Paste files"), ("⇧⏎", "Paste paths"), ("⌥⏎", "Copy")]
            default:
                hints = [("⏎", "Paste"), ("⇧⏎", "Plain text"), ("⌥⏎", "Copy")]
            }
            hints += [("⌘1–9", "Paste row"), ("⌘-click", "Queue"), ("⌘K", "Actions"),
                      ("⌘Y", largePreview ? "Smaller" : "Larger")]
        }
        footer.attributedStringValue = Self.hints(hints.map { ($1, $0) })
    }

    /// "⏎ Paste   ⇧⏎ Plain text": keys in label colour, actions secondary.
    private static func hints(_ pairs: [(label: String, key: String)]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let size = NSFont.smallSystemFontSize
        for (index, pair) in pairs.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "     ")) }
            text.append(NSAttributedString(string: pair.key + " ", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]))
            text.append(NSAttributedString(string: pair.label, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    // MARK: Row content

    private func icon(for item: ItemSummary) -> NSImage? {
        if item.kind == "color", let color = Kinds.color(from: item.title) {
            return Kinds.swatch(color, size: 16)
        }
        if let app = item.app, let icon = SourceApps.icon(app) {
            return icon
        }
        return Kinds.symbol(item.kind)
    }

    private func shortcut(row: Int) -> String {
        row < Self.quickPasteRows ? "⌘\(row + 1)" : ""
    }

    /// Fuzzy matches in semibold and underlined, readable on the selected row too.
    private func title(for item: ItemSummary, row: Int) -> NSAttributedString {
        let title = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let indices = Set(model.titleIndices(at: row).map(Int.init))
        guard !indices.isEmpty else { return title }
        // nucleo reports grapheme indices, which are Swift Character offsets.
        var utf16Offset = 0
        for (index, character) in item.title.enumerated() {
            let length = character.utf16.count
            if indices.contains(index) {
                title.addAttributes([
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: NSRange(location: utf16Offset, length: length))
            }
            utf16Offset += length
        }
        return title
    }
}

/// Source icon → one-line title → queue badge → ⌘ shortcut, each in a fixed slot.
private final class HistoryCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    let shortcut = NSTextField(labelWithString: "")

    /// Title and badge without colours; `render` colours them for the selection state.
    var title = NSAttributedString() { didSet { render() } }
    var badgeText = "" { didSet { render() } }
    /// Shown in the badge slot when the row has no queue number.
    var pinned = false { didSet { render() } }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        let selected = backgroundStyle == .emphasized
        let text = NSMutableAttributedString(attributedString: title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttributes([
            .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: text.length))
        textField?.attributedStringValue = text
        if badgeText.isEmpty, pinned, let pin = Self.pinSymbol {
            let attachment = NSTextAttachment()
            attachment.image = pin
            let mark = NSMutableAttributedString(attachment: attachment)
            mark.addAttribute(.foregroundColor,
                              value: selected ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
                              range: NSRange(location: 0, length: mark.length))
            badge.attributedStringValue = mark
        } else {
            badge.attributedStringValue = NSAttributedString(string: badgeText, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
                .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.controlAccentColor,
            ])
        }
        shortcut.textColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7) : .tertiaryLabelColor
    }

    private static let pinSymbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.usesSingleLineMode = true
        text.cell?.wraps = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.alignment = .center
        shortcut.alignment = .right
        shortcut.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        shortcut.textColor = .tertiaryLabelColor
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        for sub in [image, text, badge, shortcut] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        textField = text
        imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 6),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 2),
            shortcut.widthAnchor.constraint(equalToConstant: 32),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        cell.shortcut.stringValue = shortcut(row: row)
        guard let item = model.summary(at: row) else {
            cell.imageView?.image = nil
            cell.title = NSAttributedString()
            cell.badgeText = ""
            cell.pinned = false
            return cell
        }
        cell.imageView?.image = icon(for: item)
        cell.title = title(for: item, row: row)
        cell.badgeText = queue.firstIndex(of: item.id).map { "\($0 + 1)" } ?? ""
        cell.pinned = item.pin != nil
        return cell
    }

    /// Row views are reused; one faded out by `delete` must come back visible.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.alphaValue = 1
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // The open action panel acts on the row it was opened for.
        actionPanel.dismiss()
        preview.show(model.summary(at: table.selectedRow))
        updateFooter()
    }
}

extension PopupController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // While a Korean (or any) input method is composing, its keys belong to it:
        // ⏎ commits the syllable instead of pasting.
        if textView.hasMarkedText() {
            return false
        }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            select(row: table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)):
            select(row: table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            pasteSelected(mode: flags.contains(.option) ? .copyOnly : flags.contains(.shift) ? .plainText : .original)
        case #selector(NSResponder.deleteWordBackward(_:)) where NSApp.currentEvent?.modifierFlags.contains(.option) == true:
            // ⌥⌫ deletes the selected item, as in Maccy.
            delete(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            if !queue.isEmpty {
                clearQueue()
            } else if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                model.setQuery("")
            } else {
                close()
            }
        default:
            return false
        }
        return true
    }
}

/// Right-click opens the action panel on the clicked row. A system menu would take key focus from
/// the popup, which closes it.
private final class HistoryTable: NSTableView {
    var onRightClick: ((Int) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onRightClick?(row) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

extension PopupController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Facet list for the expanded mode: everything, each kind, and the most-used source apps, with counts.
private final class SidebarController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Row {
        case header(String)
        case all(Int64)
        case kind(Facet)
        case app(Facet)

        var filter: Filter? {
            switch self {
            case .header: nil
            case .all: Filter(kinds: [], apps: [])
            case .kind(let facet): Filter(kinds: [facet.name], apps: [])
            case .app(let facet): Filter(kinds: [], apps: [facet.name])
            }
        }
    }

    var onSelect: ((Filter) -> Void)?
    let view = NSScrollView()
    private let table = NSTableView()
    private var rows: [Row] = []
    private var updating = false

    override init() {
        super.init()
        table.addTableColumn(NSTableColumn(identifier: .init("facet")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 26
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        view.documentView = table
        view.drawsBackground = false
        view.hasVerticalScroller = true
    }

    func update(facets: Facets, total: Int64, filter: Filter) {
        rows = [.all(total), .header("Kinds")] + facets.kinds.map(Row.kind)
        if !facets.apps.isEmpty {
            rows += [.header("Apps")] + facets.apps.map(Row.app)
        }
        table.reloadData()
        select(filter)
    }

    /// Highlights the row matching a single-facet filter, or nothing for combined filters.
    func select(_ filter: Filter) {
        updating = true
        defer { updating = false }
        if let index = rows.firstIndex(where: { $0.filter == filter }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].filter != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        let count = NSTextField(labelWithString: "")
        let image = NSImageView()
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        switch rows[row] {
        case .header(let title):
            text.stringValue = title
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            text.textColor = .secondaryLabelColor
        case .all(let total):
            text.stringValue = "All Items"
            image.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
            count.stringValue = total.formatted()
        case .kind(let facet):
            text.stringValue = Kinds.info(facet.name).name
            image.image = Kinds.symbol(facet.name)
            count.stringValue = facet.count.formatted()
        case .app(let facet):
            text.stringValue = SourceApps.name(facet.name)
            image.image = SourceApps.icon(facet.name)
            count.stringValue = facet.count.formatted()
        }
        for sub in [image, text, count] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, table.selectedRow >= 0, let filter = rows[table.selectedRow].filter else { return }
        onSelect?(filter)
    }
}
