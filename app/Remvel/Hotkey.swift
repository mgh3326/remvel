import Carbon.HIToolbox

/// Global hotkey via Carbon, the only API that works without Accessibility permission.
final class Hotkey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        Hotkey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.action?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Replaces the current shortcut; nil leaves none registered, e.g. while recording a new one.
    /// Returns false when another app already holds the combination.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo else { return true }
        let id = EventHotKeyID(signature: OSType(0x524D_564C), id: 1) // "RMVL"
        return RegisterEventHotKey(UInt32(combo.carbonKeyCode), UInt32(combo.carbonModifiers), id,
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
