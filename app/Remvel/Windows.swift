import AppKit
import Carbon.HIToolbox

/// What macOS tiling (halves, quarters, fill, centre, restore) can't do: send the focused window
/// to another desktop or display. Off unless Settings turns it on.
enum WindowCommand: Hashable {
    case desktop(offset: Int)
    case desktopNumber(Int)
    case display(offset: Int)

    /// Fixed for now: ⌃⌥⌘←→ as in Magnet and Rectangle, ⌃⌥⇧ for desktops.
    static let shortcuts: [(WindowCommand, KeyCombo)] = {
        let desktop = controlKey | optionKey | shiftKey
        let display = controlKey | optionKey | cmdKey
        var list: [(WindowCommand, KeyCombo)] = [
            (.desktop(offset: -1), KeyCombo(carbonKeyCode: kVK_LeftArrow, carbonModifiers: desktop, key: "←")),
            (.desktop(offset: 1), KeyCombo(carbonKeyCode: kVK_RightArrow, carbonModifiers: desktop, key: "→")),
            (.display(offset: -1), KeyCombo(carbonKeyCode: kVK_LeftArrow, carbonModifiers: display, key: "←")),
            (.display(offset: 1), KeyCombo(carbonKeyCode: kVK_RightArrow, carbonModifiers: display, key: "→")),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, code) in digits.enumerated() {
            list.append((.desktopNumber(index + 1), KeyCombo(carbonKeyCode: code, carbonModifiers: desktop, key: "\(index + 1)")))
        }
        return list
    }()
}

final class WindowMover: ObservableObject {
    static let shared = WindowMover()
    /// Shortcuts another app already holds, shown in Settings.
    @Published private(set) var taken: [KeyCombo] = []
    /// Accessibility calls wait on the target app; a hung app must not freeze the popup.
    private let queue = DispatchQueue(label: "io.github.remvel.windows")
    private var hotkeys: [Hotkey] = []

    /// Registers every shortcut, or none.
    func setEnabled(_ enabled: Bool) {
        hotkeys = []
        taken = []
        guard enabled else { return }
        for (command, combo) in WindowCommand.shortcuts {
            let hotkey = Hotkey { [weak self] in self?.run(command) }
            if hotkey.register(combo) { hotkeys.append(hotkey) } else { taken.append(combo) }
        }
    }

    func run(_ command: WindowCommand) {
        guard AXIsProcessTrusted() else {
            Onboarding.shared.show()
            return
        }
        // Screens are read here: NSScreen belongs to the main thread.
        let screens = NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        let pid = app.processIdentifier
        queue.async {
            let ok: Bool
            switch command {
            case .desktop(let offset): ok = Self.sendToDesktop(pid: pid) { all, current in
                    all.firstIndex(of: current).flatMap { all.indices.contains($0 + offset) ? all[$0 + offset] : nil }
                }
            case .desktopNumber(let number): ok = Self.sendToDesktop(pid: pid) { all, _ in
                    all.indices.contains(number - 1) ? all[number - 1] : nil
                }
            case .display(let offset):
                ok = Self.sendToDisplay(pid: pid, offset: offset, screens: screens, primaryHeight: primaryHeight)
            }
            if !ok { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    // MARK: - Desktops

    private static func sendToDesktop(pid: pid_t, pick: ([Spaces.Desktop], Spaces.Desktop) -> Spaces.Desktop?) -> Bool {
        guard let window = focusedWindow(pid: pid), let id = windowID(window),
              let (all, current) = Spaces.desktops(around: id),
              let target = pick(all, current), target != current
        else { return false }
        Spaces.move(id, to: target)
        // The bridge can report nothing and do nothing; trust only where the window ends up.
        for _ in 0..<8 {
            if Spaces.space(of: id) == target.id { return true }
            usleep(100_000)
        }
        return false
    }

    // MARK: - Displays

    private static func sendToDisplay(pid: pid_t, offset: Int, screens: [(frame: CGRect, visible: CGRect)],
                                      primaryHeight: CGFloat) -> Bool {
        guard screens.count > 1, let window = focusedWindow(pid: pid),
              let topLeft = frame(of: window) else { return false }
        // AX measures from the top of the main screen; NSScreen from the bottom.
        let current = CGRect(x: topLeft.minX, y: primaryHeight - topLeft.maxY, width: topLeft.width, height: topLeft.height)
        let ordered = screens.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let center = CGPoint(x: current.midX, y: current.midY)
        let sourceIndex = ordered.firstIndex { $0.frame.contains(center) }
            ?? ordered.indices.max { ordered[$0].frame.intersection(current).area < ordered[$1].frame.intersection(current).area }!
        let target = ordered[(sourceIndex + offset + ordered.count) % ordered.count].visible
        let moved = transfer(current, from: ordered[sourceIndex].visible, to: target)
        setFrame(window, CGRect(x: moved.minX, y: primaryHeight - moved.maxY, width: moved.width, height: moved.height))
        return true
    }

    /// Keeps the window's place as fractions of the screen, so a left half stays a left half
    /// on a screen of another size. A window that fills its screen fills the new one.
    static func transfer(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let slack: CGFloat = 4
        if abs(window.minX - source.minX) <= slack, abs(window.maxX - source.maxX) <= slack,
           abs(window.minY - source.minY) <= slack, abs(window.maxY - source.maxY) <= slack {
            return target
        }
        var rect = CGRect(
            x: target.minX + (window.minX - source.minX) / source.width * target.width,
            y: target.minY + (window.minY - source.minY) / source.height * target.height,
            width: window.width / source.width * target.width,
            height: window.height / source.height * target.height
        )
        rect.size.width = min(rect.width, target.width)
        rect.size.height = min(rect.height, target.height)
        rect.origin.x = min(max(rect.minX, target.minX), target.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, target.minY), target.maxY - rect.height)
        return rect
    }

    // MARK: - Accessibility

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              AXValueGetValue(value as! AXValue, .cgPoint, &position),
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              AXValueGetValue(value as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Size, position, size: macOS clamps a window to the screen it is on, so the first size lets it
    /// fit where it lands and the second sets it once there. Apps that animate frame changes for
    /// assistive tools (Chrome, Electron) jump instead while that flag is off.
    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)
        let enhanced = "AXEnhancedUserInterface" as CFString
        var was: CFTypeRef?
        let wasOn = AXUIElementCopyAttributeValue(app, enhanced, &was) == .success && (was as? Bool) == true
        if wasOn { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse) }
        defer { if wasOn { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) } }

        var size = frame.size, origin = frame.origin
        let sizeValue = AXValueCreate(.cgSize, &size)!, positionValue = AXValueCreate(.cgPoint, &origin)!
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}

/// Private but stable for a decade; every window manager uses it to match an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
