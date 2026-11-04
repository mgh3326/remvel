import AppKit

enum Paster {
    /// Puts the item back on the pasteboard and, with Accessibility permission, sends ⌘V.
    /// The popup is a non-activating panel, so the previous app is still frontmost.
    static func paste(id: Int64) {
        Core.shared.run({ try $0.reps(id: id) }) { result in
            guard case .success(let reps) = result, !reps.isEmpty else { return }
            let item = NSPasteboardItem()
            for rep in reps {
                item.setData(rep.data, forType: .init(rep.uti))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])

            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(prompt) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: postCommandV)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(9) // ANSI V
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
    }
}
