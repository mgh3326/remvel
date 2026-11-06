import AppKit

/// Remembers every browser's tabs so a closed one can be searched and opened again (`closedTabs`).
/// A browser's tabs are read when the user leaves it, and every ten minutes while it stays in front,
/// so nothing runs while browsers sit unused. With page text on, the page the browser was showing
/// is kept too, so searches find what it said.
final class TabMemory {
    static let shared = TabMemory()

    /// One browser is not read again sooner than this.
    private static let minInterval: TimeInterval = 120
    private static let frontInterval: TimeInterval = 600

    private let queue = DispatchQueue(label: "io.github.remvel.tabmemory")
    private var lastRead: [String: Date] = [:]
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    func setEnabled(_ enabled: Bool) {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.left(app)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.frontInterval, repeats: true) { [weak self] _ in
            if let app = NSWorkspace.shared.frontmostApplication { self?.left(app) }
        }
    }

    /// Tabs the switcher just read: stored as they are, and the browser counts as read now.
    func record(_ browser: Browser, _ tabs: [BrowserTab]) {
        lastRead[browser.bundleId] = Date()
        store(browser, tabs)
    }

    private func left(_ app: NSRunningApplication) {
        guard Browser.isBrowser(app), let id = app.bundleIdentifier else { return }
        if let last = lastRead[id], Date().timeIntervalSince(last) < Self.minInterval { return }
        lastRead[id] = Date()
        let browser = Browser.named(id)
        let withText = Settings.shared.tabPageText
        queue.async {
            // Never prompts: a browser not allowed yet is asked for from the switcher.
            guard Tabs.access(browser, ask: false) == .allowed, let tabs = Tabs.read(browser) else { return }
            self.store(browser, tabs)
            if withText, let page = Tabs.pageText(browser) {
                Core.shared.perform("tab text") { try $0.setTabText(browser: browser.bundleId, url: page.url, text: page.text) }
            }
        }
    }

    private func store(_ browser: Browser, _ tabs: [BrowserTab]) {
        let seen = tabs.map { TabSeen(url: $0.url, title: $0.title) }
        let now = Date().unixMillis
        Core.shared.perform("record tabs") { try $0.recordTabs(browser: browser.bundleId, tabs: seen, at: now) }
    }
}
