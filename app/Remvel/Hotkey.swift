import Carbon.HIToolbox

/// Global hotkey via Carbon, the only API that works without Accessibility permission.
/// Each instance holds one shortcut; one handler finds the instance by the id Carbon passes back.
final class Hotkey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static let handlerInstalled: Bool = {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Hotkey.actions[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
        return true
    }()

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        _ = Self.handlerInstalled
        id = Self.nextId
        Self.nextId += 1
        Self.actions[id] = action
    }

    /// Replaces the current shortcut; nil leaves none registered, e.g. while recording a new one.
    /// Returns false when another app already holds the combination.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo else { return true }
        let hotKeyID = EventHotKeyID(signature: OSType(0x524D_564C), id: id) // "RMVL"
        return RegisterEventHotKey(UInt32(combo.carbonKeyCode), UInt32(combo.carbonModifiers), hotKeyID,
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }
}
