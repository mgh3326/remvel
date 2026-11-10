import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = PasteboardWatcher()
    private let settings = Settings.shared
    private lazy var popup = PopupController()
    private lazy var tabs = TabSwitcher()
    private var hotkey: Hotkey?
    private var tabsHotkey: Hotkey?
    private var statusItem: NSStatusItem?
    private var openItem: NSMenuItem?
    private var tabsItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let snapshot = Snapshot.requested {
            snapshot.run(popup: popup)
            return
        }
        _ = Core.shared

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "StatusIcon")
            ?? NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Remvel")
        image?.isTemplate = true
        item.button?.image = image
        item.menu = makeMenu()
        statusItem = item

        hotkey = Hotkey { [weak self] in self?.togglePopup() }
        settings.$hotkey.sink { [weak self] combo in
            let ok = self?.hotkey?.register(combo) ?? false
            self?.openItem?.title = ok ? "Open Remvel  \(combo.label)" : "Open Remvel  (\(combo.label) is taken)"
            if !ok { Self.warnShortcutTaken(combo) }
        }.store(in: &subscriptions)
        tabsHotkey = Hotkey { [weak self] in self?.toggleTabs() }
        settings.$tabsHotkey.sink { [weak self] combo in
            let ok = self?.tabsHotkey?.register(combo) ?? false
            self?.tabsItem?.title = ok ? "Browser Tabs  \(combo.label)" : "Browser Tabs  (\(combo.label) is taken)"
        }.store(in: &subscriptions)
        settings.$rememberTabs.sink { TabMemory.shared.setEnabled($0) }.store(in: &subscriptions)
        settings.$windowShortcuts.sink { WindowMover.shared.setEnabled($0) }.store(in: &subscriptions)
        settings.$showInDock.sink { show in
            NSApp.setActivationPolicy(show ? .regular : .accessory)
        }.store(in: &subscriptions)
        settings.$paused.sink { [weak self] paused in
            self?.statusItem?.button?.appearsDisabled = paused
            self?.pauseItem?.state = paused ? .on : .off
        }.store(in: &subscriptions)
        SettingsWindow.shared.onHotkeyRecording = { [weak self] recording in
            self?.hotkey?.register(recording ? nil : self?.settings.hotkey)
            self?.tabsHotkey?.register(recording ? nil : self?.settings.tabsHotkey)
        }
        popup.onHop = { [weak self] query, topLeft in self?.tabs.show(query: query, at: topLeft) }
        tabs.onHop = { [weak self] query in
            guard let self else { return }
            popup.show(query: query, at: tabs.topLeft)
        }
        tabs.placement = { [weak self] size in self?.popup.origin(for: size) ?? .zero }

        popup.statusItemFrame = { [weak self] in
            guard let button = self?.statusItem?.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        watcher.onIngest = { [weak self] in self?.popup.historyDidChange() }
        watcher.start()
        // Old screenshots become searchable in the background, after launch has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { TextRecognizer.shared.backfill() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { HistoryImport.shared.run() }

        if !settings.hasOnboarded {
            settings.hasOnboarded = true
            Onboarding.shared.show()
        }
        if CommandLine.arguments.contains("--show-popup") {
            togglePopup()
        }

        let updater = Updater.shared
        updater.onChange = { [weak self] in self?.refreshUpdateItem() }
        refreshUpdateItem()
        if CommandLine.arguments.contains("--update-now") {
            updater.check { release in release.map(updater.install) }
        } else {
            updater.start()
        }
    }

    private static func warnShortcutTaken(_ combo: KeyCombo) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "\(combo.label) is used by another app"
            alert.informativeText = """
                Remvel could not register \(combo.label). Quit the other app that uses it (for example Maccy), \
                or choose a different shortcut in Remvel Settings.
                """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SettingsWindow.shared.show()
            }
        }
    }

    /// Clicking the Dock icon (shown when "Show in Dock" is on) opens the popup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popup.toggle()
        return false
    }

    private func refreshUpdateItem() {
        let updater = Updater.shared
        guard let item = updateItem else { return }
        item.isHidden = !updater.isUpdatable
        if updater.installing {
            item.title = "Installing Update…"
        } else if let release = updater.available {
            item.title = "Update to \(release.title)…"
        } else {
            item.title = "Check for Updates…"
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "Open Remvel", action: #selector(togglePopup), keyEquivalent: "")
        tabsItem = menu.addItem(withTitle: "Browser Tabs", action: #selector(toggleTabs), keyEquivalent: "")
        menu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "")
        pauseItem = menu.addItem(withTitle: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        updateItem = menu.addItem(withTitle: "Check for Updates", action: #selector(updateAction), keyEquivalent: "")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Remvel", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        for item in menu.items where item !== quit {
            item.target = self
        }
        return menu
    }

    /// For the Open Remvel shortcut.
    func showPopup(query: String) {
        popup.show(query: query)
    }

    /// Either shortcut swaps an open popup or switcher for the other, in the same place.
    @objc private func togglePopup() {
        if tabs.isVisible {
            tabs.close()
            popup.show(query: "", at: tabs.topLeft)
        } else {
            popup.toggle()
        }
    }

    @objc private func toggleTabs() {
        if popup.isVisible {
            let topLeft = popup.topLeft
            popup.toggle()
            tabs.show(at: topLeft)
        } else {
            tabs.toggle()
        }
    }

    @objc private func newNote() {
        NoteEditor.shared.open(id: nil, text: "")
    }

    @objc private func togglePause() {
        settings.paused.toggle()
    }

    @objc private func updateAction() {
        let updater = Updater.shared
        if let release = updater.available {
            updater.offer(release)
            return
        }
        updater.check { release in
            if let release {
                updater.offer(release)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Remvel is up to date"
            alert.informativeText = "You have \(updater.currentVersion) (Build \(updater.currentBuild))."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showSettings() {
        SettingsWindow.shared.show()
    }
}
