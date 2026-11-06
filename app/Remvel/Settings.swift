import AppKit
import Carbon.HIToolbox

enum PopupPosition: String, CaseIterable, Identifiable {
    case center, cursor, statusItem

    var id: String { rawValue }

    var label: String {
        switch self {
        case .center: "Center of screen"
        case .cursor: "At mouse pointer"
        case .statusItem: "Below menu bar icon"
        }
    }
}

/// How big the popup opens. ⌘Y steps through the sizes while it is open.
enum PreviewMode: String, CaseIterable, Identifiable {
    /// The list alone, to cover as little of the screen as possible.
    case hidden
    /// The list with the preview beside it.
    case beside
    /// The preview alone, across the popup.
    case large

    var id: String { rawValue }

    var next: PreviewMode {
        switch self {
        case .hidden: .beside
        case .beside: .large
        case .large: .hidden
        }
    }
}

enum PopupStart: String, CaseIterable, Identifiable {
    case list, preview, last

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: "List only"
        case .preview: "List and preview"
        case .last: "As I last left it"
        }
    }
}

/// A global shortcut, stored the way most Mac clipboard apps store it: Carbon key code and modifiers.
struct KeyCombo: Codable, Equatable {
    var carbonKeyCode: Int
    var carbonModifiers: Int
    /// What the key printed when it was recorded, e.g. "V".
    var key: String

    /// ⇧⌘C, the shortcut Maccy users already know.
    static let `default` = KeyCombo(carbonKeyCode: kVK_ANSI_C, carbonModifiers: shiftKey | cmdKey, key: "C")
    /// ⌃⌥B for browser tabs; ⌃⌥Space is macOS's "next input source".
    static let tabs = KeyCombo(carbonKeyCode: kVK_ANSI_B, carbonModifiers: controlKey | optionKey, key: "B")

    var label: String {
        var text = ""
        if carbonModifiers & controlKey != 0 { text += "⌃" }
        if carbonModifiers & optionKey != 0 { text += "⌥" }
        if carbonModifiers & shiftKey != 0 { text += "⇧" }
        if carbonModifiers & cmdKey != 0 { text += "⌘" }
        return text + key
    }

    init(carbonKeyCode: Int, carbonModifiers: Int, key: String) {
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers
        self.key = key
    }

    /// Nil unless the event has at least one of ⌘ ⌥ ⌃, so plain typing never becomes a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        guard modifiers & (cmdKey | optionKey | controlKey) != 0,
              let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        self.init(carbonKeyCode: Int(event.keyCode), carbonModifiers: modifiers, key: key)
    }
}

/// User preferences, backed by UserDefaults. Read from the main thread only.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Apps whose copies are never recorded. Password managers that mark their copies
    /// as concealed are skipped anyway; these are the ones that do not.
    static let seededIgnoredApps = ["com.apple.keychainaccess", "com.apple.Passwords"]
    static let historyLimits = [0, 1_000, 10_000, 100_000]

    private let defaults = UserDefaults.standard

    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    @Published var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: "ignoredApps") } }
    @Published var ignoreRemoteClipboard: Bool {
        didSet { defaults.set(ignoreRemoteClipboard, forKey: "ignoreRemoteClipboard") }
    }
    @Published var popupPosition: PopupPosition {
        didSet { defaults.set(popupPosition.rawValue, forKey: "popupPosition") }
    }
    @Published var popupStart: PopupStart {
        didSet { defaults.set(popupStart.rawValue, forKey: "popupStart") }
    }
    /// 0 keeps everything.
    @Published var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    /// Also offer every build of main, not only tagged releases.
    @Published var nightlyUpdates: Bool { didSet { defaults.set(nightlyUpdates, forKey: "nightlyUpdates") } }
    /// Keep the popup out of screen sharing, recordings and screenshots.
    @Published var hideFromScreenSharing: Bool {
        didSet { defaults.set(hideFromScreenSharing, forKey: "hideFromScreenSharing") }
    }
    /// Load a copied link's page title and image when it is previewed.
    @Published var linkPreviews: Bool { didSet { defaults.set(linkPreviews, forKey: "linkPreviews") } }
    /// Read text in copied images on this Mac so searches find it.
    @Published var recognizeText: Bool { didSet { defaults.set(recognizeText, forKey: "recognizeText") } }
    /// Shortcuts that send the focused window to another desktop or display.
    @Published var windowShortcuts: Bool { didSet { defaults.set(windowShortcuts, forKey: "windowShortcuts") } }
    @Published var hotkey: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") }
    }
    /// Opens the switcher over every browser's open tabs.
    @Published var tabsHotkey: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(tabsHotkey), forKey: "tabsHotkey") }
    }
    var hasOnboarded: Bool {
        get { defaults.bool(forKey: "hasOnboarded") }
        set { defaults.set(newValue, forKey: "hasOnboarded") }
    }

    private init() {
        paused = defaults.bool(forKey: "paused")
        ignoredApps = defaults.stringArray(forKey: "ignoredApps") ?? Self.seededIgnoredApps
        ignoreRemoteClipboard = defaults.bool(forKey: "ignoreRemoteClipboard")
        popupPosition = defaults.string(forKey: "popupPosition").flatMap(PopupPosition.init) ?? .center
        popupStart = defaults.string(forKey: "popupStart").flatMap(PopupStart.init) ?? .list
        historyLimit = defaults.integer(forKey: "historyLimit")
        showInDock = defaults.bool(forKey: "showInDock")
        nightlyUpdates = defaults.bool(forKey: "nightlyUpdates")
        hideFromScreenSharing = defaults.bool(forKey: "hideFromScreenSharing")
        linkPreviews = defaults.object(forKey: "linkPreviews") as? Bool ?? true
        recognizeText = defaults.object(forKey: "recognizeText") as? Bool ?? true
        windowShortcuts = defaults.bool(forKey: "windowShortcuts")
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? .default
        tabsHotkey = defaults.data(forKey: "tabsHotkey").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? .tabs
    }
}
