import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindow {
    static let shared = SettingsWindow()

    /// Set by the app delegate: called with nil while a new shortcut is being recorded.
    var onHotkeyRecording: ((Bool) -> Void)?

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Remvel Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var selectedApp: String?

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Open Remvel") {
                    ShortcutRecorder(combo: $settings.hotkey)
                        .frame(width: 120, height: 24)
                }
                Picker("Show popup", selection: $settings.popupPosition) {
                    ForEach(PopupPosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Keep history", selection: $settings.historyLimit) {
                    ForEach(Settings.historyLimits, id: \.self) { limit in
                        Text(limit == 0 ? "Unlimited" : "\(limit.formatted()) items").tag(limit)
                    }
                }
                Toggle("Show in Dock", isOn: $settings.showInDock)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("Remvel: launch at login failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                Toggle("Include nightly builds", isOn: $settings.nightlyUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("Remvel checks GitHub every six hours. Nightly builds come from every change to main; releases are tested versions.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Pause recording", isOn: $settings.paused)
                Toggle("Ignore copies from other devices (Universal Clipboard)", isOn: $settings.ignoreRemoteClipboard)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Passwords that apps mark as concealed, such as from 1Password, are never recorded.")
                    .foregroundStyle(.secondary)
            }
            Section("Ignored apps") {
                List(settings.ignoredApps, id: \.self, selection: $selectedApp) { bundleID in
                    HStack {
                        if let icon = SourceApps.icon(bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(SourceApps.name(bundleID))
                        Spacer()
                        Text(bundleID).foregroundStyle(.tertiary).font(.caption)
                    }
                }
                .frame(minHeight: 110)
                HStack {
                    Button("Add App…", action: addApp)
                    Button("Remove") {
                        settings.ignoredApps.removeAll { $0 == selectedApp }
                        selectedApp = nil
                    }
                    .disabled(selectedApp == nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.ignoredApps.contains(id) {
                settings.ignoredApps.append(id)
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels.
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = { combo = $0 }
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.combo = combo
    }
}

private final class RecorderButton: NSButton {
    var onRecord: ((KeyCombo) -> Void)?
    var combo: KeyCombo? { didSet { refresh() } }
    private var recording = false { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        recording = true
        SettingsWindow.shared.onHotkeyRecording?(true)
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        recording = false
        SettingsWindow.shared.onHotkeyRecording?(false)
    }

    override func resignFirstResponder() -> Bool {
        if recording { stopRecording() }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        if event.keyCode == 53 { // Esc
            stopRecording()
            return
        }
        guard let new = KeyCombo(event: event) else {
            NSSound.beep()
            return
        }
        onRecord?(new)
        stopRecording()
    }

    private func refresh() {
        title = recording ? "Type shortcut…" : combo?.label ?? ""
    }
}
