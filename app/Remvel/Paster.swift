import AppKit

enum PasteMode {
    case original
    /// Plain text only, no formatting.
    case plainText
    /// Put it on the pasteboard and stop.
    case copyOnly
}

enum Paster {
    /// Pause between items of a queue so the target app reads one pasteboard before the next replaces it.
    static let queueStep: TimeInterval = 0.25

    /// Puts the items on the pasteboard one after another and, with Accessibility permission, sends ⌘V for each.
    /// The popup is a non-activating panel, so the app the user came from is still frontmost.
    static func paste(ids: [Int64], mode: PasteMode) {
        guard !ids.isEmpty else { return }
        Core.shared.run({ store in try ids.map { try contents(of: $0, mode: mode, store: store) } }) { result in
            guard case .success(let items) = result else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            Core.shared.run({ store in try ids.forEach { try store.touch(id: $0, at: now) } }) { _ in }

            guard mode != .copyOnly, AXIsProcessTrusted() else {
                write(items.last ?? [])
                if mode != .copyOnly { Onboarding.shared.show() }
                return
            }
            for (index, reps) in items.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + queueStep * Double(index)) {
                    write(reps)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: postCommandV)
                }
            }
        }
    }

    private static func contents(of id: Int64, mode: PasteMode, store: Remvel) throws -> [Rep] {
        let reps = try store.reps(id: id)
        guard mode == .plainText else { return reps }
        let plain = NSPasteboard.PasteboardType.string.rawValue
        if let text = reps.first(where: { $0.uti == plain }) {
            return [text]
        }
        // Rich-only items: the core keeps their extracted text.
        let text = try store.previewText(id: id, byteOffset: 0, maxBytes: 1 << 40)
        return text.isEmpty ? reps : [Rep(uti: plain, data: Data(text.utf8))]
    }

    private static func write(_ reps: [Rep]) {
        let item = NSPasteboardItem()
        for rep in reps {
            item.setData(rep.data, forType: .init(rep.uti))
        }
        // Names Remvel as the source, so the watcher does not record this as a new copy.
        item.setString(Bundle.main.bundleIdentifier ?? "Remvel", forType: PasteboardWatcher.sourceType)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
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
