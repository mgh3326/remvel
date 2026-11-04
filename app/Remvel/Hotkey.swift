import Carbon.HIToolbox

/// Global hotkey via Carbon, the only API that works without Accessibility permission.
/// Defaults to ⌥⌘V so it can run next to Maccy (⇧⌘C) while trying it out.
final class Hotkey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: Int = kVK_ANSI_V, modifiers: Int = optionKey | cmdKey, action: @escaping () -> Void) {
        Hotkey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x524D_564C), id: 1) // "RMVL"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
