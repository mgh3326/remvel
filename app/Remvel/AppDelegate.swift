import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = PasteboardWatcher()
    private lazy var popup = PopupController()
    private var hotkey: Hotkey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Core.shared

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Remvel")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Remvel  ⌥⌘V", action: #selector(togglePopup), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = $0.action == #selector(togglePopup) ? self : nil }
        item.menu = menu
        statusItem = item

        hotkey = Hotkey { [weak self] in self?.togglePopup() }

        watcher.onIngest = { [weak self] in self?.popup.historyDidChange() }
        watcher.start()

        if CommandLine.arguments.contains("--show-popup") {
            togglePopup()
        }
    }

    @objc private func togglePopup() {
        popup.toggle()
    }
}
