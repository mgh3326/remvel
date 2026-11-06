import AppKit

private final class TabPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Remvel has no Edit menu to route these, so the search field gets them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers {
            case "a": editor.selectAll(nil); return true
            case "x": editor.cut(nil); return true
            case "c": editor.copy(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Every open tab of every running browser in one searchable list; ⏎ goes to the tab.
/// Looks like the clipboard popup, and ⇥ hops between the two with the search text.
final class TabSwitcher: NSObject {
    static let size = NSSize(width: 520, height: 480)

    /// Where the panel goes for a size, as the clipboard popup decides.
    var placement: ((NSSize) -> NSPoint)?
    /// ⇥: open the clipboard popup with this search text.
    var onHop: ((String) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var topLeft: NSPoint { NSPoint(x: panel.frame.minX, y: panel.frame.maxY) }

    private enum Row {
        case tab(BrowserTab)
        /// A browser whose tabs need permission first, or that did not answer.
        case browser(Browser, Status)
    }

    private enum Status {
        case notAsked, denied, silent
    }

    private let panel = TabPanel(
        contentRect: NSRect(origin: .zero, size: TabSwitcher.size),
        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
        backing: .buffered,
        defer: true
    )
    private let searchField = NSSearchField()
    private let header = NSTextField(labelWithString: "Tabs")
    private let count = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private let queue = DispatchQueue(label: "io.github.remvel.tabs", attributes: .concurrent)

    private var browsers: [Browser] = []
    /// Last tabs read per browser, shown at once while they are read again.
    private var tabs: [String: [BrowserTab]] = [:]
    private var status: [String: Status] = [:]
    private var reading: Set<String> = []
    private var rows: [Row] = []

    override init() {
        super.init()
        configure()
    }

    func show(query: String = "", at topLeft: NSPoint? = nil) {
        panel.sharingType = Settings.shared.hideFromScreenSharing ? .none : .readOnly
        searchField.stringValue = query
        if let topLeft {
            panel.setFrameTopLeftPoint(topLeft)
        } else if let origin = placement?(Self.size) {
            panel.setFrameOrigin(origin)
        }
        if !panel.isVisible { refresh() }
        reload()
        NSApp.activate(ignoringOtherApps: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    func close() {
        panel.orderOut(nil)
    }

    /// For `Snapshot`: lays out these tabs without reading any browser or taking focus.
    func prepareSnapshot(_ tabs: [BrowserTab], query: String, then: @escaping (NSView) -> Void) {
        browsers = Array(Set(tabs.map(\.browser))).sorted { $0.name < $1.name }
        self.tabs = Dictionary(grouping: tabs, by: \.browser.bundleId)
        searchField.stringValue = query
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { then(self.panel.contentView!) }
    }

    // MARK: Reading

    /// Reads every running browser at once; each one's tabs appear as soon as it answers.
    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        browsers = Browser.running().sorted { ($0.bundleId == front ? 0 : 1) < ($1.bundleId == front ? 0 : 1) }
        let running = Set(browsers.map(\.bundleId))
        tabs = tabs.filter { running.contains($0.key) }
        for browser in browsers where !reading.contains(browser.bundleId) {
            reading.insert(browser.bundleId)
            queue.async {
                let result: (Status?, [BrowserTab]?)
                switch Tabs.access(browser, ask: false) {
                case .notAsked: result = (.notAsked, nil)
                case .denied: result = (.denied, nil)
                case .allowed:
                    let read = Tabs.read(browser)
                    result = (read == nil ? .silent : nil, read)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    reading.remove(browser.bundleId)
                    status[browser.bundleId] = result.0
                    if let read = result.1 { tabs[browser.bundleId] = read }
                    reload()
                }
            }
        }
    }

    /// Shows macOS's permission prompt for one browser, then reads it.
    private func ask(_ browser: Browser) {
        close()
        queue.async {
            let access = Tabs.access(browser, ask: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                status[browser.bundleId] = access == .allowed ? nil : .denied
                if access == .allowed { show() }
            }
        }
    }

    // MARK: Rows

    private func reload() {
        let selectedTab: BrowserTab? = table.selectedRow >= 0 && table.selectedRow < rows.count
            ? { if case .tab(let tab) = rows[table.selectedRow] { return tab } else { return nil } }() : nil
        let words = searchField.stringValue.lowercased().split(separator: " ").map(String.init)
        let named = words.filter { $0.hasPrefix("@") && $0.count > 1 }.map { String($0.dropFirst()) }
        let text = words.filter { !$0.hasPrefix("@") }
        let shown = browsers.filter { browser in
            let name = browser.name.lowercased().replacingOccurrences(of: " ", with: "")
            return named.allSatisfy { name.hasPrefix($0) || name.contains($0) }
        }
        var titled: [Row] = [], addressed: [Row] = [], notices: [Row] = []
        for browser in shown {
            if let state = status[browser.bundleId], tabs[browser.bundleId] == nil || state != .silent {
                notices.append(.browser(browser, state))
            }
            for tab in tabs[browser.bundleId] ?? [] {
                let title = tab.title.lowercased(), url = tab.url.lowercased()
                guard text.allSatisfy({ title.contains($0) || url.contains($0) }) else { continue }
                // Matches in the title come first: the address of many tabs holds a common word.
                if text.isEmpty || text.allSatisfy(title.contains) {
                    titled.append(.tab(tab))
                } else {
                    addressed.append(.tab(tab))
                }
            }
        }
        rows = notices + titled + addressed
        table.reloadData()
        let tabCount = titled.count + addressed.count
        count.stringValue = reading.isEmpty ? "\(tabCount.formatted()) tabs" : "Reading \(reading.count) browsers…"
        header.stringValue = browsers.isEmpty ? "No browser is open" : "Tabs"
        let keep = selectedTab.flatMap { tab in rows.firstIndex { if case .tab(tab) = $0 { true } else { false } } }
        select(keep ?? notices.count.clamped(to: rows.count))
    }

    private func select(_ row: Int) {
        guard !rows.isEmpty else { return updateFooter() }
        let row = max(0, min(row, rows.count - 1))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateFooter()
    }

    private func updateFooter() {
        var hints: [(label: String, key: String)] = []
        if table.selectedRow >= 0, table.selectedRow < rows.count {
            switch rows[table.selectedRow] {
            case .tab: hints.append(("Go to tab", "⏎"))
            case .browser(_, .notAsked): hints.append(("Allow", "⏎"))
            case .browser(_, .denied): hints.append(("Open Privacy settings", "⏎"))
            case .browser(_, .silent): break
            }
        }
        hints.append(("Clipboard", "⇥"))
        footer.attributedStringValue = PopupController.hints(hints)
    }

    private func activate(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .tab(let tab):
            close()
            queue.async {
                if !Tabs.show(tab) { DispatchQueue.main.async { NSSound.beep() } }
            }
        case .browser(let browser, .notAsked):
            ask(browser)
        case .browser(_, .denied):
            close()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        case .browser(_, .silent):
            NSSound.beep()
        }
    }

    // MARK: Layout

    private func configure() {
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

        searchField.placeholderString = "Search open tabs      @browser"
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 14)
        searchField.controlSize = .large

        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = PopupController.rowHeight
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let line = NSBox()
        line.boxType = .separator
        footer.lineBreakMode = .byTruncatingTail

        for sub in [searchField, header, count, scroll, line, footer] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            count.firstBaselineAnchor.constraint(equalTo: header.firstBaselineAnchor),
            count.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -4),
            line.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -40),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -16),
            footer.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -20),
        ])
    }

    @objc private func doubleClicked() {
        activate(table.clickedRow)
    }

    private static var icons: [String: NSImage] = [:]

    private static func icon(_ browser: Browser) -> NSImage? {
        if let icon = icons[browser.bundleId] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[browser.bundleId] = icon
        return icon
    }

    /// "github.com/mgh3326/remvel" from the full address: the scheme and "www." say nothing.
    private static func shortAddress(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

extension TabSwitcher: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("tabCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TabCell ?? TabCell(identifier: id)
        switch rows[row] {
        case .tab(let tab):
            cell.imageView?.image = Self.icon(tab.browser)
            cell.set(title: tab.title.isEmpty ? Self.shortAddress(tab.url) : tab.title,
                     detail: Self.shortAddress(tab.url))
        case .browser(let browser, let status):
            cell.imageView?.image = Self.icon(browser)
            switch status {
            case .notAsked:
                cell.set(title: "Allow Remvel to read \(browser.name) tabs", detail: "macOS asks once")
            case .denied:
                cell.set(title: "\(browser.name) tabs are not allowed",
                         detail: "Privacy & Security › Automation › Remvel")
            case .silent:
                cell.set(title: "\(browser.name) did not answer", detail: "Try again in a moment")
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
    }
}

extension TabSwitcher: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)):
            select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            activate(table.selectedRow)
        case #selector(NSResponder.insertTab(_:)):
            let query = searchField.stringValue
            close()
            onHop?(query)
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                close()
            } else {
                searchField.stringValue = ""
                reload()
            }
        default:
            return false
        }
        return true
    }
}

extension TabSwitcher: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Browser icon → title, then the address dimmed.
private final class TabCell: NSTableCellView {
    private var title = ""
    private var detail = ""

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    func set(title: String, detail: String) {
        self.title = title
        self.detail = detail
        render()
    }

    private func render() {
        let selected = backgroundStyle == .emphasized
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        if !detail.isEmpty, detail != title {
            text.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: selected
                    ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7) : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        textField?.attributedStringValue = text
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.maximumNumberOfLines = 1
        text.usesSingleLineMode = true
        text.cell?.wraps = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        for sub in [image, text] {
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
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private extension Int {
    func clamped(to count: Int) -> Int { Swift.min(self, Swift.max(count - 1, 0)) }
}
