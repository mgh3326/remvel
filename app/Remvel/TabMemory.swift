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
        on(NSWorkspace.didDeactivateApplicationNotification) { [weak self] in self?.read($0) }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] in self?.watch($0) }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let observer = observers.removeValue(forKey: app.processIdentifier) else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        NSWorkspace.shared.runningApplications.forEach(watch)
    }

    /// Tabs the switcher just read: stored as they are, and the browser counts as read now.
    func record(_ browser: Browser, _ tabs: [BrowserTab]) {
        lastRead[browser.bundleId] = Date()
        store(browser, tabs)
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
        guard let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier else { return }
        pending[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending[id] = nil
            self?.read(app)
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    // MARK: Reading

    private func read(_ app: NSRunningApplication) {
        guard Browser.isBrowser(app), let id = app.bundleIdentifier else { return }
        if let last = lastRead[id], Date().timeIntervalSince(last) < Self.minInterval {
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
