import AppKit

/// A window for jotting a note, or for reworking a copy's text before using it: what a scratch note
/// in Notes was for. Saves as you type; notes are listed, searched (`#note`) and pasted with the history,
/// and the history limit never drops them. ⌘⏎ pastes the note into the app that was in front.
final class NoteEditor: NSObject {
    static let shared = NoteEditor()

    /// Wait this long after the last keystroke before saving.
    private static let saveDelay: TimeInterval = 0.5

    private var window: NoteWindow?
    private let textView = NSTextView()
    private let hint = NSTextField(labelWithString: "")
    private var document: NoteDocument?
    private var pendingSave: DispatchWorkItem?
    /// Where ⌘⏎ pastes and where focus goes back on closing.
    private var previousApp: NSRunningApplication?

    /// Opens note `id` (nil for a new note) holding `text`. `source` is the copy a new note's text came from.
    func open(id: Int64?, text: String, source: Int64? = nil) {
        if let document, let id, document.id == id, window?.isVisible == true {
            return bringForward()
        }
        finish()
        document = NoteDocument(id: id, text: text, source: source)
        let window = self.window ?? makeWindow()
        window.title = id == nil ? (source == nil ? "New Note" : "New Note from Copy") : "Note"
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.scrollToEndOfDocument(nil)
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            previousApp = front
        }
        hint.attributedStringValue = PopupController.hints([
            ("Paste into \(previousApp?.localizedName ?? "the app")", "⌘⏎"), ("Close", "⌘W"),
            ("Saved as you type · find it with #note", ""),
        ])
        bringForward()
    }

    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    private func makeWindow() -> NoteWindow {
        let window = NoteWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 200)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("RemvelNote")
        window.onPaste = { [weak self] in self?.pasteAndClose() }

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        // Copied code and commands must stay as they are.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        hint.lineBreakMode = .byTruncatingTail
        let separator = NSBox()
        separator.boxType = .separator

        let content = NSView()
        for view in [scroll, separator, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hint.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 7),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.contentView = content
        self.window = window
        return window
    }

    /// Saves now what is waiting to be saved; a note left blank is deleted.
    private func finish() {
        pendingSave?.cancel()
        pendingSave = nil
        document?.finish(textView.string)
    }

    private func pasteAndClose() {
        let text = textView.string
        let from = document?.id ?? document?.source
        let target = previousApp
        window?.close()
        guard let from, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let target else { return }
        // ⌘V must reach the app once it is in front again.
        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Paster.paste(text: text, from: from)
        }
    }
}

extension NoteEditor: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.document?.save(self.textView.string)
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: save)
    }
}

extension NoteEditor: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish()
        document = nil
        // An app without a Dock icon does not hand focus back by itself.
        if previousApp?.isTerminated == false { previousApp?.activate() }
    }
}

/// One note's saving. Saves run one at a time, so a new note is created once however fast the user types,
/// and the latest text always lands last, even after the editor has moved on to another note.
private final class NoteDocument {
    private(set) var id: Int64?
    /// The copy a new note's text came from.
    let source: Int64?
    /// The text in the database, or the text the note opened with.
    private var saved: String
    private var saving = false
    /// Text that arrived while a save ran.
    private var waiting: String?
    /// Emptied out and closed while a save ran: delete the note once it has an id.
    private var discarded = false

    init(id: Int64?, text: String, source: Int64?) {
        self.id = id
        self.source = source
        saved = text
    }

    /// Unchanged or blank text is not saved: a copy opened and closed untouched does not become a note.
    func save(_ text: String) {
        guard !saving else {
            waiting = text
            return
        }
        guard text != saved, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        let id = self.id, now = Date().unixMillis
        Core.shared.run({ try $0.saveNote(id: id, text: text, at: now) }) { [self] result in
            saving = false
            switch result {
            case .success(let saved):
                self.id = saved
                self.saved = text
            case .failure(let error):
                Log.app.error("note save failed: \(String(describing: error), privacy: .public)")
            }
            if discarded {
                return discard()
            }
            if let next = waiting {
                waiting = nil
                save(next)
            }
        }
    }

    /// The last save; a note emptied out is deleted.
    func finish(_ text: String) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return save(text) }
        waiting = nil
        discarded = true
        if !saving { discard() }
    }

    private func discard() {
        guard let id else { return }
        self.id = nil
        Core.shared.perform("delete note", { try $0.delete(id: id) })
    }
}

/// Remvel has no Edit menu, so editing keys are routed here, by key position so they work while typing Korean.
private final class NoteWindow: NSWindow {
    var onPaste: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 { // ⏎, keypad enter
            onPaste?()
            return true
        }
        let editor = firstResponder as? NSTextView
        switch (flags, event.latinKey) {
        case (.command, "a"): editor?.selectAll(nil)
        case (.command, "c"): editor?.copy(nil)
        case (.command, "x"): editor?.cut(nil)
        case (.command, "v"): editor?.pasteAsPlainText(nil)
        case (.command, "z"): editor?.undoManager?.undo()
        case ([.command, .shift], "z"): editor?.undoManager?.redo()
        case (.command, "w"): performClose(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
