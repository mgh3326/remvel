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

    /// Pastes text made from item `id`, e.g. by a transform; the item counts as used.
    static func paste(text: String, from id: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        Core.shared.run({ try $0.touch(id: id, at: now) }) { _ in }
        write([Rep(uti: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))])
        guard AXIsProcessTrusted() else {
            Onboarding.shared.show()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: postCommandV)
    }

    /// Pastes some of the files of item `id`; the item counts as used.
    static func paste(files: [String], from id: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        Core.shared.run({ try $0.touch(id: id, at: now) }) { _ in }
        write([Rep(uti: PasteboardWatcher.filePathsUTI, data: Data(files.joined(separator: "\n").utf8))])
        guard AXIsProcessTrusted() else {
            Onboarding.shared.show()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: postCommandV)
    }

    /// Puts one item on the pasteboard without pasting, for Shortcuts.
    static func copy(id: Int64, plainText: Bool) {
        Core.shared.run({ try contents(of: id, mode: plainText ? .plainText : .original, store: $0) }) { result in
            guard case .success(let reps) = result else { return }
            write(reps)
        }
    }

    private static func contents(of id: Int64, mode: PasteMode, store: Remvel) throws -> [Rep] {
        let reps = try store.reps(id: id)
        guard mode == .plainText else { return reps }
        let plain = NSPasteboard.PasteboardType.string.rawValue
        // Files paste as their paths.
        if let paths = reps.first(where: { $0.uti == PasteboardWatcher.filePathsUTI }) {
            return [Rep(uti: plain, data: paths.data)]
        }
        if let text = reps.first(where: { $0.uti == plain }) {
            return [text]
        }
        // Rich-only items: the core keeps their extracted text. Images: the text found in them.
        // Items with neither paste as they are.
        let text = try store.fullText(id: id)
        return text.isEmpty ? reps : [Rep(uti: plain, data: Data(text.utf8))]
    }

    private static func write(_ reps: [Rep]) {
        let source = Bundle.main.bundleIdentifier ?? "Remvel"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let paths = reps.first(where: { $0.uti == PasteboardWatcher.filePathsUTI }) {
            // One pasteboard item per file, as Finder writes them.
            let items = String(decoding: paths.data, as: UTF8.self).split(separator: "\n").map { path in
                let item = NSPasteboardItem()
                item.setString(URL(fileURLWithPath: String(path)).absoluteString, forType: .fileURL)
                return item
            }
            items.first?.setString(source, forType: PasteboardWatcher.sourceType)
            pasteboard.writeObjects(items)
            return
        }
        let item = NSPasteboardItem()
        for rep in reps {
            item.setData(rep.data, forType: .init(rep.uti))
        }
        // Names Remvel as the source, so the watcher does not record this as a new copy.
        item.setString(source, forType: PasteboardWatcher.sourceType)
        pasteboard.writeObjects([item])
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
