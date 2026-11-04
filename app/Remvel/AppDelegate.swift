import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = PasteboardWatcher()
    private let settings = Settings.shared
    private lazy var popup = PopupController()
    private var hotkey: Hotkey?
    private var statusItem: NSStatusItem?
    private var openItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            self?.hotkey?.register(combo)
            self?.openItem?.title = "Open Remvel  \(combo.label)"
        }.store(in: &subscriptions)
        settings.$paused.sink { [weak self] paused in
            self?.statusItem?.button?.appearsDisabled = paused
            self?.pauseItem?.state = paused ? .on : .off
        }.store(in: &subscriptions)
        SettingsWindow.shared.onHotkeyRecording = { [weak self] recording in
            self?.hotkey?.register(recording ? nil : self?.settings.hotkey)
        }

        popup.statusItemFrame = { [weak self] in
            guard let button = self?.statusItem?.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        watcher.onIngest = { [weak self] in self?.popup.historyDidChange() }
        watcher.start()

        if !settings.hasOnboarded {
            settings.hasOnboarded = true
            Onboarding.shared.show()
        }
        if CommandLine.arguments.contains("--show-popup") {
            togglePopup()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        openItem = menu.addItem(withTitle: "Open Remvel", action: #selector(togglePopup), keyEquivalent: "")
        pauseItem = menu.addItem(withTitle: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Remvel", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        for item in menu.items where item !== quit {
            item.target = self
        }
        return menu
    }

    @objc private func togglePopup() {
        popup.toggle()
    }

    @objc private func togglePause() {
        settings.paused.toggle()
    }

    @objc private func showSettings() {
        SettingsWindow.shared.show()
    }
}
