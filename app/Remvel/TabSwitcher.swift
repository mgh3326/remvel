import AppKit

private final class TabPanel: NSPanel {
    var onTogglePreview: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onOpenIn: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// ⌥⌫ by key code, before the search field sees it: a Korean input method turns it into a plain
    /// backspace, so it never arrives as "delete word backward".
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 51,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option {
            onCloseTab?()
            return
        }
        super.sendEvent(event)
    }

    /// Remvel has no Edit menu to route these, so the search field gets them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // By key code, as on a US layout: with Korean input ⌘A arrives as "ㅁ" and would be typed.
        if flags == .command, let editor = firstResponder as? NSTextView {
            switch event.keyCode {
            case 0: editor.selectAll(nil); return true
            case 7: editor.cut(nil); return true
            case 8: editor.copy(nil); return true
            case 9: editor.paste(nil); return true
            case 6: editor.undoManager?.undo(); return true
            default: break
            }
        }
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 { // ⌘⏎, ⌘enter
            onOpenIn?()
            return true
        }
        // keyCode 16 is Y on a US layout, so ⌘Y works while typing Korean too.
        if flags == .command, event.keyCode == 16 {
            onTogglePreview?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Every open tab of every running browser in one searchable list; ⏎ goes to the tab.
/// Looks like the clipboard popup, and ⇥ hops between the two with the search text.
final class TabSwitcher: NSObject {
    static let size = PopupController.listOnlySize

    /// Where the panel goes for a size, as the clipboard popup decides.
    var placement: ((NSSize) -> NSPoint)?
    /// ⇥: open the clipboard popup with this search text.
    var onHop: ((String) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var topLeft: NSPoint { NSPoint(x: panel.frame.minX, y: panel.frame.maxY) }

    private enum Row {
        /// Open tabs of one address in one browser, latest seen first; ⏎ goes to the first.
        case tabs([BrowserTab])
        /// One of those tabs, listed under its row after ⌥⏎ to pick which to go to.
        case member(BrowserTab)
        /// Remembered by `TabMemory` and no longer open; ⏎ opens it again.
        case closed(ClosedTab)
        /// Pages from the browsers' history at one address (query left out), latest first; while searching.
        case visited([Visit])
        /// "Closed", "History": where the open tabs end and remembered pages begin.
        case header(String)
        /// The search text is an address no open tab shows: ⏎ opens it, as an address bar would.
        case address(URL, Browser?)
        /// Under a row after ⌘⏎: its page in a new tab of another running browser.
        case openIn(String, Browser)
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
    private let divider = NSBox()
    /// The selected tab's page, as the clipboard popup previews a link (⌘Y or →).
    private let preview = PreviewController()
    private var listAlone: NSLayoutConstraint!
    private var listBesidePreview: NSLayoutConstraint!
    private var snapshotPreview = false
    private var previewShown: Bool {
        get { snapshotPreview || UserDefaults.standard.bool(forKey: "tabsPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "tabsPreview") }
    }
    private let queue = DispatchQueue(label: "io.github.remvel.tabs", attributes: .concurrent)

    private var browsers: [Browser] = []
    /// Last tabs read per browser, shown at once while they are read again.
    private var tabs: [String: [BrowserTab]] = [:]
    private var status: [String: Status] = [:]
    private var reading: Set<String> = []
    private var rows: [Row] = []
    private var closed: [ClosedTab] = []
    private var visited: [Visit] = []
    /// Open tabs ("bundle id URL") whose kept page text matches the search text.
    private var inPage: Set<String> = []
    private var closedGeneration = 0
    /// The browser in front when the list opened: where a typed address opens.
    private var frontBrowser: Browser?
    /// Words of the search text, marked where they occur in each row.
    private var searchWords: [String] {
        searchField.stringValue.lowercased().split(separator: " ").filter { !$0.hasPrefix("@") }.map(String.init)
    }
    /// When each open tab ("bundle id URL") was last the one shown, newest first in the list.
    private var activity: [String: Int64] = [:]
    /// Rows opened with ⌥⏎ to show each of their tabs.
    private var expanded: Set<String> = []
    /// The row opened with ⌘⏎ to list other browsers to open its page in.
    private var openInRow: String?
    /// Row order once the user starts moving through or closing tabs, until the list closes.
    /// Closing a tab changes which tab its window shows, which would re-rank the list under the cursor.
    private var frozenOrder: [String: Int]?

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    override init() {
        super.init()
        configure()
    }

    func show(query: String = "", at topLeft: NSPoint? = nil) {
        panel.sharingType = Settings.shared.hideFromScreenSharing ? .none : .readOnly
        searchField.stringValue = query
        applyPreview()
        if let topLeft {
            panel.setFrameTopLeftPoint(topLeft)
        } else if let origin = placement?(panel.frame.size) {
            panel.setFrameOrigin(origin)
        }
        if !panel.isVisible {
            expanded = []
            openInRow = nil
            frozenOrder = nil
            refresh()
            HistoryImport.shared.run()
        }
        reload()
        loadRemembered()
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
        // Shown without saving the choice: snapshots run against the user's defaults.
        snapshotPreview = true
        applyPreview()
        browsers = Array(Set(tabs.map(\.browser))).sorted { $0.name < $1.name }
        self.tabs = Dictionary(grouping: tabs, by: \.browser.bundleId)
        searchField.stringValue = query
        reload()
        loadRemembered()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { then(self.panel.contentView!) }
    }

    // MARK: Reading

    /// Reads every running browser at once; each one's tabs appear as soon as it answers.
    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontBrowser = nil
        if let front, let app = NSWorkspace.shared.frontmostApplication, Browser.isBrowser(app) {
            frontBrowser = Browser.named(front)
        }
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
                    if let read = result.1 {
                        tabs[browser.bundleId] = read
                        let isFront = browser.bundleId == front
                        TabMemory.shared.record(browser, read, front: isFront)
                        // The tab the user just left leads the list at once, before the core answers.
                        if isFront, let shown = TabMemory.frontTab(read) {
                            activity["\(browser.bundleId) \(shown.url)"] = Date().unixMillis
                        }
                    }
                    reload()
                    // Tabs closed since the last read are known once every browser has answered.
                    if reading.isEmpty { loadRemembered() }
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

    // MARK: Preview

    private func togglePreview() {
        previewShown.toggle()
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        applyPreview()
        panel.setFrameTopLeftPoint(topLeft)
    }

    private func applyPreview() {
        let shown = previewShown
        preview.view.isHidden = !shown
        divider.isHidden = !shown
        listAlone.isActive = !shown
        listBesidePreview.isActive = shown
        panel.setContentSize(shown ? PopupController.previewSize : Self.size)
        updatePreview()
    }

    private func updatePreview() {
        guard previewShown, table.selectedRow >= 0, table.selectedRow < rows.count else {
            if previewShown { preview.show(nil, force: true) }
            return
        }
        let tab: BrowserTab
        var others = 0
        switch rows[table.selectedRow] {
        case .tabs(let group):
            tab = group[0]
            others = group.count - 1
        case .member(let open): tab = open
        case .closed(let gone):
            let closedAt = Date(unixMillis: gone.closedAt)
            preview.show(page: gone.url, title: gone.title, kind: Browser.named(gone.browser).name,
                         meta: "Closed \(Self.relative.localizedString(for: closedAt, relativeTo: Date()))")
            loadPageText(browser: gone.browser, url: gone.url)
            return
        case .visited(let visits):
            let visit = visits[0]
            let when = Self.relative.localizedString(for: Date(unixMillis: visit.lastVisit), relativeTo: Date())
            let count = visits.reduce(0) { $0 + $1.visitCount }
            preview.show(page: visit.url, title: Self.title(visits), kind: Browser.named(visit.browser).name,
                         meta: "Visited \(when)" + (count > 1 ? " · \(count) visits" : "")
                             + (visits.count > 1 ? " · \(visits.count) addresses" : ""))
            return
        case .address(let url, let browser):
            preview.show(page: url.absoluteString, title: "", kind: browser?.name ?? "", meta: "Opens in a new tab")
            return
        case .openIn(let url, let browser):
            preview.show(page: url, title: "", kind: browser.name, meta: "Opens in a new tab")
            return
        case .browser, .header:
            preview.show(nil, force: true)
            return
        }
        let windows = Set((tabs[tab.browser.bundleId] ?? []).map(\.windowId)).count
        let count = tabs[tab.browser.bundleId]?.count ?? 0
        preview.show(page: tab.url, title: tab.title, kind: tab.browser.name,
                     meta: "\(count) tabs" + (windows > 1 ? " in \(windows) windows" : "") + (tab.active ? " · showing" : "")
                         + (others > 0 ? " · open \(others + 1) times" : ""))
        loadPageText(browser: tab.browser.bundleId, url: tab.url)
    }

    /// The page text kept for the previewed tab, under its card, if the selection has not moved on.
    private func loadPageText(browser: String, url: String) {
        let row = table.selectedRow
        Core.shared.run({ try $0.tabText(browser: browser, url: url) }) { [weak self] result in
            guard let self, table.selectedRow == row, case .success(let text) = result else { return }
            preview.showPageText(text)
        }
    }

    /// ⌥⌫: closes the selected tab where it is, without leaving Remvel; it stays findable as closed.
    /// On a closed tab, forgets it.
    private func closeSelected() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { return }
        freezeOrder()
        switch rows[row] {
        case .tabs(let group):
            // One tab: close it. Several of one address: close the copies, keep the latest.
            closeTabs(group.count > 1 ? Array(group.dropFirst()) : group)
        case .member(let tab):
            closeTabs([tab])
        case .closed(let gone):
            closed.removeAll { $0 == gone }
            Core.shared.perform("forget tab") { try $0.forgetTab(browser: gone.browser, url: gone.url) }
        case .visited(let visits):
            visited.removeAll { visits.contains($0) }
            Core.shared.perform("forget visits") { store in
                for visit in visits { try store.forgetVisit(browser: visit.browser, url: visit.url) }
            }
        case .browser, .header, .address, .openIn:
            return NSSound.beep()
        }
        reload()
        select(row)
    }

    private func closeTabs(_ doomed: [BrowserTab]) {
        for tab in doomed { tabs[tab.browser.bundleId]?.removeAll { $0 == tab } }
        let now = Date().unixMillis
        queue.async {
            var failed = false
            for tab in doomed {
                if Tabs.close(tab) {
                    // A copy of an address still open elsewhere is not closed in memory.
                    Core.shared.perform("tab closed", { store in
                        if !doomed.contains(where: { $0 != tab && $0.url == tab.url }) {
                            try store.tabClosed(browser: tab.browser.bundleId, url: tab.url, at: now)
                        }
                    }, then: { [weak self] in self?.loadRemembered() })
                } else {
                    failed = true
                }
            }
            if failed { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    /// What the core remembers for the search text: closed tabs, and open tabs only their page
    /// text matches. Both follow the open tabs whose title or address matches.
    private func loadRemembered() {
        closedGeneration += 1
        let generation = closedGeneration
        let text = searchField.stringValue.split(separator: " ").filter { !$0.hasPrefix("@") }.joined(separator: " ")
        preview.searchWords = text.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        // Browsing shows the latest few; a search looks through all of them.
        let limit: Int64 = text.isEmpty ? 30 : 300
        Core.shared.run({ store in
            (try store.closedTabs(query: text, limit: limit), try store.openTabsWithText(query: text, limit: 300),
             try store.searchVisits(query: text, limit: 300), try store.tabActivity())
        }) { [weak self] result in
            guard let self, generation == closedGeneration, case .success(let (found, pages, visits, seen)) = result else { return }
            for tab in seen { activity["\(tab.browser) \(tab.url)", default: 0] = max(activity["\(tab.browser) \(tab.url)"] ?? 0, tab.lastActive) }
            closed = found
            inPage = Set(pages.map { "\($0.browser) \($0.url)" })
            visited = visits
            reload()
        }
    }

    // MARK: Rows

    private func reload() {
        let selectedKey = table.selectedRow >= 0 && table.selectedRow < rows.count ? Self.key(rows[table.selectedRow]) : nil
        let words = searchField.stringValue.lowercased().split(separator: " ").map(String.init)
        let named = words.filter { $0.hasPrefix("@") && $0.count > 1 }.map { String($0.dropFirst()) }
        let text = words.filter { !$0.hasPrefix("@") }
        let shown = browsers.filter { browser in
            let name = browser.name.lowercased().replacingOccurrences(of: " ", with: "")
            return named.allSatisfy { name.hasPrefix($0) || name.contains($0) }
        }
        var notices: [Row] = []
        // One row per address per browser; its tabs lead with the one a window shows, front window first.
        var groups: [[BrowserTab]] = []
        var index: [String: Int] = [:]
        for browser in shown {
            if let state = status[browser.bundleId], tabs[browser.bundleId] == nil || state != .silent {
                notices.append(.browser(browser, state))
            }
            for tab in tabs[browser.bundleId] ?? [] {
                let key = "\(tab.browser.bundleId) \(tab.url)"
                if let at = index[key] {
                    if tab.active && !groups[at][0].active { groups[at].insert(tab, at: 0) } else { groups[at].append(tab) }
                } else {
                    index[key] = groups.count
                    groups.append([tab])
                }
            }
        }
        // Latest looked at first; tabs never seen in front keep the browsers' own order after them.
        var ranked = groups.enumerated().sorted { a, b in
            let (x, y) = (activity["\(a.element[0].browser.bundleId) \(a.element[0].url)"] ?? 0,
                          activity["\(b.element[0].browser.bundleId) \(b.element[0].url)"] ?? 0)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        if let frozen = frozenOrder {
            // Frozen: rows keep their places; tabs opened meanwhile follow in their own order.
            ranked = ranked.enumerated().sorted { a, b in
                let (x, y) = (frozen[Self.groupKey(a.element)] ?? .max, frozen[Self.groupKey(b.element)] ?? .max)
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)
        }
        // A typed address ("naver.com"): the tabs showing exactly that page lead, then that host's home.
        let typed = Self.typedAddress(text.joined(separator: " "))
        var exact: [[BrowserTab]] = []
        var titled: [[BrowserTab]] = [], addressed: [[BrowserTab]] = [], paged: [[BrowserTab]] = []
        for group in ranked {
            let tab = group[0]
            if let typed, Self.page(tab.url) == Self.page(typed.absoluteString) {
                exact.append(group)
                continue
            }
            let title = tab.title.lowercased(), url = tab.url.lowercased()
            guard text.allSatisfy({ title.contains($0) || url.contains($0) }) else {
                if !text.isEmpty, inPage.contains("\(tab.browser.bundleId) \(tab.url)") { paged.append(group) }
                continue
            }
            // Matches in the title come first: the address of many tabs holds a common word.
            if text.isEmpty || text.allSatisfy(title.contains) {
                titled.append(group)
            } else {
                addressed.append(group)
            }
        }
        // Nothing open shows it: offer to open it, in the browser the user came from.
        // Otherwise the browser of the tab looked at last.
        let lastUsed = activity.max { $0.value < $1.value }.flatMap { entry in
            browsers.first { entry.key.hasPrefix($0.bundleId + " ") }
        }
        let offer: [Row] = typed != nil && exact.isEmpty ? [.address(typed!, frontBrowser ?? lastUsed ?? browsers.first)] : []
        let openRows: [Row] = offer + (exact + titled + addressed + paged).flatMap { group -> [Row] in
            let row = Row.tabs(group)
            return expanded.contains(Self.key(row)) && group.count > 1 ? [row] + group.map(Row.member) : [row]
        }
        let open = Set(tabs.values.joined().map { "\($0.browser.bundleId) \($0.url)" })
        let gone: [Row] = closed.filter { tab in
            guard !open.contains("\(tab.browser) \(tab.url)") else { return false }
            let name = Browser.named(tab.browser).name.lowercased().replacingOccurrences(of: " ", with: "")
            return named.allSatisfy { name.contains($0) }
        }.map(Row.closed)
        // History repeats what is open or closed already; those rows say more.
        let known = open.union(closed.map { "\($0.browser) \($0.url)" })
        var pages: [[Visit]] = []
        var at: [String: Int] = [:]
        for visit in visited where !known.contains("\(visit.browser) \(visit.url)") {
            let name = Browser.named(visit.browser).name.lowercased().replacingOccurrences(of: " ", with: "")
            guard named.allSatisfy({ name.contains($0) }) else { continue }
            // One row per page: sign-in flows and consoles differ only in their query.
            let key = "\(visit.browser) \(Self.page(visit.url))"
            if let index = at[key] { pages[index].append(visit) } else { at[key] = pages.count; pages.append([visit]) }
        }
        // Sign-in, token and callback pages say little about what was read; they go last.
        let plain = pages.filter { group in !group.allSatisfy { URL(string: $0.url).map(PreviewController.looksPrivate) ?? false } }
        let auth = pages.filter { group in group.allSatisfy { URL(string: $0.url).map(PreviewController.looksPrivate) ?? false } }
        let history = (plain + auth).map(Row.visited)
        // Headers only where open tabs and remembered pages meet.
        let sections = !openRows.isEmpty || !gone.isEmpty && !history.isEmpty
        rows = notices + openRows
            + (gone.isEmpty ? [] : (sections ? [.header("Closed")] : []) + gone)
            + (history.isEmpty ? [] : (sections ? [.header("History")] : []) + history)
        if let target = openInRow, let at = rows.firstIndex(where: { Self.key($0) == target }), let page = Self.page(of: rows[at]) {
            let others = browsers.filter { $0.bundleId != page.browser }
            rows.insert(contentsOf: others.map { Row.openIn(page.url, $0) }, at: at + 1)
        }
        table.reloadData()
        let tabCount = (exact + titled + addressed + paged).reduce(0) { $0 + $1.count }
        count.stringValue = reading.isEmpty
            ? (tabCount == 1 ? "1 tab" : "\(tabCount.formatted()) tabs") + (gone.isEmpty ? "" : " · \(gone.count.formatted()) closed")
                + (history.isEmpty ? "" : " · \(history.count.formatted()) visited")
            : "Reading \(reading.count) browsers…"
        header.stringValue = browsers.isEmpty && gone.isEmpty ? "No browser is open" : "Tabs"
        let keep = selectedKey.flatMap { key in rows.firstIndex { Self.key($0) == key } }
        select(keep ?? notices.count.clamped(to: rows.count))
    }

    /// The search text as a web address when it reads like one: "naver.com", "github.com/mgh3326",
    /// "https://…". Words with spaces, or without a dot in the host, are a search instead.
    static func typedAddress(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let full = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: full), let host = url.host, host.contains("."),
              !host.hasSuffix("."), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// Host and path, the query and fragment left out: what identifies a page in a list.
    static func page(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host else { return shortAddress(url) }
        let path = parts.path == "/" ? "" : parts.path
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + (path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    /// The best title among visits to one page, or the page itself.
    private static func title(_ visits: [Visit]) -> String {
        visits.first { !$0.title.isEmpty }?.title ?? page(visits[0].url)
    }

    /// "12s", "24m", "11h", "3d", "5w": short enough for a column.
    private static func ago(_ millis: Int64) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(Date(unixMillis: millis))))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<(14 * 86_400): return "\(seconds / 86_400)d"
        default: return "\(seconds / (7 * 86_400))w"
        }
    }

    private static func groupKey(_ group: [BrowserTab]) -> String {
        "\(group[0].browser.bundleId) \(group[0].url)"
    }

    /// Keeps the current order of open tabs from here on (see `frozenOrder`).
    private func freezeOrder() {
        guard frozenOrder == nil else { return }
        var order: [String: Int] = [:]
        for row in rows {
            if case .tabs(let group) = row { order[Self.groupKey(group)] = order.count }
        }
        frozenOrder = order
    }

    /// Identifies a row across reloads, so the selection stays on it.
    private static func key(_ row: Row) -> String {
        switch row {
        case .tabs(let group): "tabs \(group[0].browser.bundleId) \(group[0].url)"
        case .member(let tab): "member \(tab.browser.bundleId) \(tab.windowId) \(tab.tabId)"
        case .closed(let tab): "closed \(tab.browser) \(tab.url)"
        case .visited(let visits): "visited \(visits[0].browser) \(page(visits[0].url))"
        case .header(let title): "header \(title)"
        case .address(let url, _): "address \(url.absoluteString)"
        case .openIn(let url, let browser): "openin \(browser.bundleId) \(url)"
        case .browser(let browser, _): "browser \(browser.bundleId)"
        }
    }

    /// Selects `row`, or the nearest row past a header in the direction of travel.
    private func select(_ row: Int, step: Int = 1) {
        guard !rows.isEmpty else { return updateFooter() }
        var row = max(0, min(row, rows.count - 1))
        while case .header = rows[row] {
            let next = row + step
            guard next >= 0, next < rows.count else { row -= step; break }
            row = next
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateFooter()
        updatePreview()
    }

    private func updateFooter() {
        var hints: [(label: String, key: String)] = []
        if table.selectedRow >= 0, table.selectedRow < rows.count {
            switch rows[table.selectedRow] {
            case .tabs(let group) where group.count > 1:
                hints.append(("Go to tab", "⏎"))
                hints.append((expanded.contains(Self.key(rows[table.selectedRow])) ? "Fold" : "Choose of \(group.count)", "⌥⏎"))
                hints.append((group.count == 2 ? "Close the copy" : "Close \(group.count - 1) copies", "⌥⌫"))
            case .tabs, .member:
                hints.append(("Go to tab", "⏎"))
                hints.append(("Close", "⌥⌫"))
            case .closed, .visited:
                hints.append(("Open again", "⏎"))
                hints.append(("Forget", "⌥⌫"))
            case .header: break
            case .address(_, let browser): hints.append((browser.map { "Open in \($0.name)" } ?? "Open", "⏎"))
            case .openIn(_, let browser): hints.append(("Open in \(browser.name)", "⏎"))
            case .browser(_, .notAsked): hints.append(("Allow", "⏎"))
            case .browser(_, .denied): hints.append(("Open Privacy settings", "⏎"))
            case .browser(_, .silent): break
            }
        }
        if table.selectedRow >= 0, table.selectedRow < rows.count, Self.page(of: rows[table.selectedRow]) != nil {
            hints.append(("Other browser", "⌘⏎"))
        }
        hints.append(("Preview", "⌘Y"))
        hints.append(("Clipboard", "⇥"))
        footer.attributedStringValue = PopupController.hints(hints)
    }

    private func activate(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        let target: BrowserTab
        switch rows[row] {
        case .tabs(let group): target = group[0]
        case .member(let tab): target = tab
        default: return activateRemembered(row)
        }
        close()
        queue.async {
            if !Tabs.show(target) { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    /// The page a row stands for, and the browser it is in.
    private static func page(of row: Row) -> (url: String, browser: String?)? {
        switch row {
        case .tabs(let group): (group[0].url, group[0].browser.bundleId)
        case .member(let tab): (tab.url, tab.browser.bundleId)
        case .closed(let tab): (tab.url, tab.browser)
        case .visited(let visits): (visits[0].url, visits[0].browser)
        case .address(let url, let browser): (url.absoluteString, browser?.bundleId)
        case .openIn, .header, .browser: nil
        }
    }

    /// ⌘⏎: lists the other running browsers under the row, to open its page in one; again folds them.
    private func toggleOpenIn(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        var key = Self.key(rows[row])
        if case .openIn = rows[row], let owner = openInRow { key = owner }
        guard Self.page(of: rows.first { Self.key($0) == key } ?? rows[row]) != nil else { return NSSound.beep() }
        freezeOrder()
        openInRow = openInRow == key ? nil : key
        reload()
        if let at = rows.firstIndex(where: { Self.key($0) == key }) {
            select(openInRow == nil ? at : at + 1)
        }
    }

    /// ⌥⏎: lists each tab of an address under its row, or folds them back.
    private func toggleExpanded(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        let key: String
        switch rows[row] {
        case .tabs(let group) where group.count > 1: key = Self.key(rows[row])
        case .member(let tab): key = "tabs \(tab.browser.bundleId) \(tab.url)"
        default: return NSSound.beep()
        }
        freezeOrder()
        if expanded.remove(key) == nil { expanded.insert(key) }
        reload()
        if let at = rows.firstIndex(where: { Self.key($0) == key }) { select(at) }
    }

    private func activateRemembered(_ row: Int) {
        switch rows[row] {
        case .tabs, .member:
            return
        case .closed(let gone):
            reopen(gone.url, in: gone.browser)
        case .visited(let visits):
            reopen(visits[0].url, in: visits[0].browser)
        case .header:
            return
        case .address(let url, let browser):
            reopen(url.absoluteString, in: browser?.bundleId ?? "")
        case .openIn(let url, let browser):
            reopen(url, in: browser.bundleId)
        case .browser(let browser, .notAsked):
            ask(browser)
        case .browser(_, .denied):
            close()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        case .browser(_, .silent):
            NSSound.beep()
        }
    }

    /// In the browser it was open in, or the default one when that is gone.
    private func reopen(_ address: String, in browser: String) {
        guard let url = URL(string: address) else { return NSSound.beep() }
        close()
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
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
        panel.onTogglePreview = { [weak self] in self?.togglePreview() }
        panel.onCloseTab = { [weak self] in self?.closeSelected() }
        panel.onOpenIn = { [weak self] in self.map { $0.toggleOpenIn($0.table.selectedRow) } }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        panel.contentView = background

        searchField.placeholderString = "Search tabs and history      @browser"
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
        table.floatsGroupRows = false
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

        divider.boxType = .separator
        for sub in [searchField, header, count, scroll, divider, preview.view, line, footer] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(sub)
        }
        listAlone = scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4)
        listBesidePreview = scroll.widthAnchor.constraint(equalToConstant: PopupController.listWidth)
        listAlone.isActive = true
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            count.firstBaselineAnchor.constraint(equalTo: header.firstBaselineAnchor),
            count.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            divider.bottomAnchor.constraint(equalTo: line.topAnchor),
            divider.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 4),
            preview.view.topAnchor.constraint(equalTo: header.topAnchor),
            preview.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 16),
            preview.view.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            preview.view.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -12),
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

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { 26 } else { tableView.rowHeight }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { false } else { true }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case .header(let title) = rows[row] {
            let id = NSUserInterfaceItemIdentifier("tabHeader")
            let label = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = id
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                label.textColor = .secondaryLabelColor
                return label
            }()
            label.stringValue = "   " + title
            return label
        }
        let id = NSUserInterfaceItemIdentifier("tabCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TabCell ?? TabCell(identifier: id)
        cell.marks = searchWords
        cell.time = ""
        switch rows[row] {
        case .header: break
        case .openIn(_, let browser):
            cell.imageView?.image = Self.icon(browser)
            cell.set(title: "↳ Open in \(browser.name)", detail: "")
        case .address(let url, let browser):
            cell.imageView?.image = browser.flatMap(Self.icon) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            cell.set(title: "Open \(Self.page(url.absoluteString))", detail: browser.map { "in \($0.name)" } ?? "")
        case .tabs(let group):
            let tab = group[0]
            cell.imageView?.image = Self.icon(tab.browser)
            let inPageOnly = !searchWords.isEmpty && !searchWords.allSatisfy { (tab.title + " " + tab.url).lowercased().contains($0) }
            cell.set(title: tab.title.isEmpty ? Self.page(tab.url) : tab.title,
                     detail: (group.count > 1 ? "×\(group.count) · " : "") + (inPageOnly ? "in page · " : "") + Self.page(tab.url))
        case .member(let tab):
            cell.imageView?.image = nil
            let windows = Array(NSOrderedSet(array: (tabs[tab.browser.bundleId] ?? []).map(\.windowId))) as? [Int] ?? []
            let window = (windows.firstIndex(of: tab.windowId) ?? 0) + 1
            let position = ((tabs[tab.browser.bundleId] ?? []).filter { $0.windowId == tab.windowId }.firstIndex(of: tab) ?? 0) + 1
            cell.set(title: "↳ \(tab.browser.name) · window \(window), tab \(position)", detail: tab.active ? "showing" : "")
        case .closed(let gone):
            cell.imageView?.image = Self.icon(Browser.named(gone.browser))
            cell.time = Self.ago(gone.closedAt)
            cell.set(title: gone.title.isEmpty ? Self.page(gone.url) : gone.title, detail: Self.page(gone.url))
        case .visited(let visits):
            cell.imageView?.image = Self.icon(Browser.named(visits[0].browser))
            cell.time = Self.ago(visits[0].lastVisit)
            let title = Self.title(visits)
            cell.set(title: title, detail: (visits.count > 1 ? "×\(visits.count) · " : "") + (title == Self.page(visits[0].url) ? "" : Self.page(visits[0].url)))
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
        updatePreview()
    }
}

extension TabSwitcher: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        reload()
        loadRemembered()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            freezeOrder()
            select(table.selectedRow - 1, step: -1)
        case #selector(NSResponder.moveDown(_:)):
            freezeOrder()
            select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                toggleExpanded(table.selectedRow)
            } else {
                activate(table.selectedRow)
            }
        case #selector(NSResponder.moveRight(_:))
            where !previewShown && textView.selectedRange() == NSRange(location: textView.string.utf16.count, length: 0):
            togglePreview()
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
                loadRemembered()
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

/// Browser icon → title (search words marked), then the page dimmed → how long ago, in a column.
private final class TabCell: NSTableCellView {
    private var title = ""
    private var detail = ""
    private let timeLabel = NSTextField(labelWithString: "")
    var marks: [String] = []
    var time = "" { didSet { timeLabel.stringValue = time } }

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
        // Why the row matched, at a glance: each search word bold and underlined where it occurs.
        let whole = text.string as NSString
        for word in marks where !word.isEmpty {
            var range = whole.range(of: word, options: .caseInsensitive)
            while range.location != NSNotFound {
                let bold = NSFont.systemFont(ofSize: range.location < (title as NSString).length ? 13 : 12, weight: .bold)
                text.addAttributes([.font: bold, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                let next = NSMaxRange(range)
                range = whole.range(of: word, options: .caseInsensitive, range: NSRange(location: next, length: whole.length - next))
            }
        }
        textField?.attributedStringValue = text
        timeLabel.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7) : .tertiaryLabelColor
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
        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        timeLabel.alignment = .right
        for sub in [image, text, timeLabel] {
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
            text.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            timeLabel.widthAnchor.constraint(equalToConstant: 32),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private extension Int {
    func clamped(to count: Int) -> Int { Swift.min(self, Swift.max(count - 1, 0)) }
}
