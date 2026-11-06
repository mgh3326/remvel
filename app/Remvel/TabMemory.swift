import AppKit

/// Remembers every browser's tabs so a closed one can be searched and opened again (`closedTabs`).
/// Reading follows what the user does instead of a clock: a browser is read when its window title
/// changes (another tab, a new page, a closed tab), settled for a moment, and when the user leaves
/// it. Browsers left alone cost nothing. With page text on, the page shown is kept too, so searches
/// find what it said.
final class TabMemory {
    static let shared = TabMemory()

    /// Titles change in bursts while a page loads; read once they have been still this long.
    private static let settle: TimeInterval = 2
    /// One browser is not read again sooner than this.
    private static let minInterval: TimeInterval = 10

    private let queue = DispatchQueue(label: "io.github.remvel.tabmemory")
    private var lastRead: [String: Date] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Accessibility observers of running browsers, by process.
    private var observers: [pid_t: AXObserver] = [:]
    /// What the last read stored per browser, so an unchanged list is not written again.
    private var lastStored: [String: Int] = [:]
    /// The page whose text was kept last per browser, so it is not read again while it stays in front.
    private var lastText: [String: String] = [:]

    func setEnabled(_ enabled: Bool) {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        observers.values.forEach { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource($0), .defaultMode) }
        observers = [:]
        pending.values.forEach { $0.cancel() }
        pending = [:]
        guard enabled else { return }
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ action: @escaping (NSRunningApplication) -> Void) {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { action(app) }
            })
        }
        on(NSWorkspace.didDeactivateApplicationNotification) { [weak self] in self?.read($0, leaving: true) }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] in self?.watch($0) }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let observer = observers.removeValue(forKey: app.processIdentifier) else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        NSWorkspace.shared.runningApplications.forEach(watch)
    }

    /// Tabs the switcher just read: stored as they are, and the browser counts as read now.
    /// `front`: the browser was in front, so the tab its front window shows was just looked at.
    func record(_ browser: Browser, _ tabs: [BrowserTab], front: Bool) {
        lastRead[browser.bundleId] = Date()
        store(browser, tabs, front: front)
    }

    /// The tab the browser's front window shows: what the user is looking at while it is in front.
    static func frontTab(_ tabs: [BrowserTab]) -> BrowserTab? {
        guard let window = tabs.first?.windowId else { return nil }
        return tabs.first { $0.windowId == window && $0.active }
    }

    // MARK: Triggers

    /// Listens for the browser's window titles changing. Needs Accessibility, which pasting already
    /// asks for; without it only leaving the browser reads it.
    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), Browser.isBrowser(app), observers[pid] == nil else { return }
        var made: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &made) == .success, let observer = made else { return }
        let element = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, me)
        }
        // Title changes arrive from each window, so every window open now is followed too.
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
           let windows = windows as? [AXUIElement] {
            for window in windows { AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, me) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private static let callback: AXObserverCallback = { observer, element, notification, refcon in
        guard let refcon else { return }
        let memory = Unmanaged<TabMemory>.fromOpaque(refcon).takeUnretainedValue()
        // A new or newly focused window: follow its title too (adding twice is harmless).
        if (notification as String) != kAXTitleChangedNotification {
            AXObserverAddNotification(observer, element, kAXTitleChangedNotification as CFString, refcon)
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        memory.changed(pid)
    }

    private func changed(_ pid: pid_t) {
        // Background tabs retitle themselves ("(3) Slack", timers); only what the user is using counts.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier else { return }
        pending[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending[id] = nil
            self?.read(app)
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    // MARK: Reading

    /// `leaving`: the user just switched away, so the tab in front was looked at until now.
    /// Always read, and always written, whatever the interval.
    private func read(_ app: NSRunningApplication, leaving: Bool = false) {
        guard Browser.isBrowser(app), let id = app.bundleIdentifier else { return }
        if !leaving, let last = lastRead[id], Date().timeIntervalSince(last) < Self.minInterval {
            // Too soon after the last read: catch this change once the interval is up.
            if pending[id] == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.pending[id] = nil
                    self?.read(app)
                }
                pending[id] = work
                let wait = max(0, Self.minInterval - Date().timeIntervalSince(last))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            }
            return
        }
        lastRead[id] = Date()
        let browser = Browser.named(id)
        let withText = Settings.shared.tabPageText
        let started = Date()
        queue.async {
            // Never prompts: a browser not allowed yet is asked for from the switcher.
            guard Tabs.access(browser, ask: false) == .allowed, let tabs = Tabs.read(browser) else { return }
            let front = Self.frontTab(tabs)
            DispatchQueue.main.async {
                // Read because the user is using it or just left it: its front tab is the one they saw.
                if leaving { self.lastStored[id] = nil }
                let stored = self.store(browser, tabs, front: true)
                // The page in front changed: keep its text, once.
                let wantText = withText && front != nil && self.lastText[id] != front?.url
                Log.tabs.debug("read \(browser.name, privacy: .public): \(tabs.count) tabs, \(Int(Date().timeIntervalSince(started) * 1000)) ms, stored \(stored), text \(wantText)")
                guard wantText else { return }
                self.queue.async {
                    guard let page = Tabs.pageText(browser) else { return }
                    DispatchQueue.main.async { self.lastText[id] = page.url }
                    Core.shared.perform("tab text") { try $0.setTabText(browser: browser.bundleId, url: page.url, text: page.text) }
                }
            }
        }
    }

    /// Hands the list to the core unless it is the one stored last. Main thread. Returns whether it wrote.
    @discardableResult
    private func store(_ browser: Browser, _ tabs: [BrowserTab], front: Bool) -> Bool {
        let shown = front ? Self.frontTab(tabs) : nil
        let seen = tabs.map { TabSeen(url: $0.url, title: $0.title, active: $0 == shown) }
        var hasher = Hasher()
        for tab in seen { hasher.combine(tab.url); hasher.combine(tab.title); hasher.combine(tab.active) }
        let digest = hasher.finalize()
        // Unchanged, and no tab newly in front: nothing to write. A front tab marks its time,
        // so a list with one is written when the front tab differs from last time.
        guard lastStored[browser.bundleId] != digest else { return false }
        lastStored[browser.bundleId] = digest
        let now = Date().unixMillis
        Core.shared.perform("record tabs") { try $0.recordTabs(browser: browser.bundleId, tabs: seen, at: now) }
        return true
    }
}
