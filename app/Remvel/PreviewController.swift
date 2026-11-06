import AppKit
import LinkPresentation
import Quartz

/// Shows one item in a fixed card with its metadata pinned below.
/// Text is read 64 KB at a time and appended as the user scrolls,
/// so a 50 MB log costs the same to open as a one-liner.
/// Nothing in here may change the panel's size: every label truncates and the image only scales down.
final class PreviewController: NSObject {
    static let chunkBytes: Int64 = 64 * 1024
    static let imageMaxPixels = 1600

    let view = NSView()

    private let header = NSTextField(labelWithString: "Preview")
    private let kindLabel = NSTextField(labelWithString: "")
    private let card = NSBox()
    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let imageView = NSImageView()
    /// Pixel size under an image, or the colour's value under a swatch.
    private let caption = NSTextField(labelWithString: "")
    /// Text read from an image, under it: what search matched, and what ⇧⏎ pastes.
    private let ocrScroll = NSTextView.scrollableTextView()
    private var ocrView: NSTextView { ocrScroll.documentView as! NSTextView }
    private let ocrLine = NSBox()
    /// Words of the search, marked where they occur in an image's text.
    var searchWords: [String] = [] {
        didSet { if searchWords != oldValue { markSearchWords() } }
    }
    private var captionAtBottom: NSLayoutConstraint!
    private var captionAboveText: NSLayoutConstraint!
    /// Quick Look for copied files: documents, PDFs, videos, folders.
    private let fileView = QLPreviewView(frame: .zero, style: .compact)!
    /// Several copied files at once, as tiles.
    private let fileGrid = FileGrid()
    /// Paths of the shown files item, once loaded; the action panel offers each one.
    private(set) var filePaths: [String] = []
    /// A tile of the file grid was clicked.
    var onPickFile: ((String) -> Void)? {
        get { fileGrid.onPick }
        set { fileGrid.onPick = newValue }
    }
    /// Title, image and site of a copied link, fetched when the link is previewed.
    private let linkView = LPLinkView(frame: .zero)
    private var linkFetch: LPMetadataProvider?
    private static let linkCache = NSCache<NSURL, LPLinkMetadata>()
    /// The whole address, large, while the page gives nothing better than a title: sign-in walls,
    /// bot checks and private links preview as a bare card, and the address is what tells them apart.
    private let urlLabel = NSTextField(wrappingLabelWithString: "")
    private let meta = NSTextField(labelWithString: "")

    private var item: ItemSummary?
    private var nextOffset: Int64 = 0
    private var loadingChunk = false
    private var generation = 0

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMddHHmm")
        return formatter
    }()

    override init() {
        super.init()
        for label in [header, kindLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        kindLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        kindLabel.alignment = .right

        card.boxType = .custom
        card.fillColor = .textBackgroundColor
        card.borderColor = .separatorColor
        card.borderWidth = 1
        card.cornerRadius = 8
        card.contentViewMargins = .zero
        card.titlePosition = .noTitle

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textScroll.drawsBackground = false
        textScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: textScroll.contentView
        )

        imageView.imageScaling = .scaleProportionallyDown
        ocrView.isEditable = false
        ocrView.isSelectable = true
        ocrView.drawsBackground = false
        ocrView.font = .systemFont(ofSize: 13)
        ocrView.textColor = .labelColor
        ocrView.textContainerInset = NSSize(width: 10, height: 8)
        ocrScroll.drawsBackground = false
        ocrLine.boxType = .separator
        caption.alignment = .center
        fileView.shouldCloseWithWindow = false

        meta.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        meta.textColor = .secondaryLabelColor
        for label in [header, kindLabel, caption, meta] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        urlLabel.isSelectable = true
        urlLabel.lineBreakMode = .byCharWrapping
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        caption.textColor = .secondaryLabelColor
        // A large image must shrink into the card, never push the card (and the panel) bigger.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(.defaultLow, for: orientation)
            imageView.setContentHuggingPriority(.defaultLow, for: orientation)
        }

        let content = card.contentView!
        linkView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        linkView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for sub in [textScroll, imageView, caption, ocrLine, ocrScroll, fileView, fileGrid, linkView, urlLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(sub)
        }
        for sub in [header, kindLabel, card, meta] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        captionAtBottom = caption.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        captionAboveText = caption.bottomAnchor.constraint(equalTo: ocrLine.topAnchor, constant: -8)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            kindLabel.firstBaselineAnchor.constraint(equalTo: header.firstBaselineAnchor),
            kindLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            kindLabel.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 8),

            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: meta.topAnchor, constant: -8),

            meta.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            meta.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            meta.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            textScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 2),
            textScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            textScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            textScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -2),

            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            imageView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -8),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            captionAtBottom,
            ocrLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ocrLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ocrScroll.topAnchor.constraint(equalTo: ocrLine.bottomAnchor),
            ocrScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            ocrScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            ocrScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -2),
            ocrScroll.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.4),

            linkView.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            linkView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            linkView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            linkView.bottomAnchor.constraint(lessThanOrEqualTo: caption.topAnchor, constant: -8),
            urlLabel.topAnchor.constraint(equalTo: linkView.bottomAnchor, constant: 16),
            urlLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            urlLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            urlLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
            urlLabel.bottomAnchor.constraint(lessThanOrEqualTo: ocrLine.topAnchor, constant: -8),

            fileView.topAnchor.constraint(equalTo: content.topAnchor, constant: 1),
            fileView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 1),
            fileView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -1),
            fileView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -1),

            fileGrid.topAnchor.constraint(equalTo: content.topAnchor, constant: 1),
            fileGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 1),
            fileGrid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -1),
            fileGrid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -1),
        ])
        show(nil, force: true)
    }

    func show(_ newItem: ItemSummary?, force: Bool = false) {
        guard force || newItem?.id != item?.id else { return }
        item = newItem
        generation += 1
        nextOffset = 0
        loadingChunk = false
        textView.string = ""
        imageView.image = nil
        caption.stringValue = ""
        caption.toolTip = nil
        showRecognizedText(nil)
        fileView.previewItem = nil
        fileGrid.paths = []
        filePaths = []
        linkFetch?.cancel()
        linkFetch = nil
        meta.stringValue = newItem.map(Self.describe) ?? ""
        meta.toolTip = newItem.map(Self.fullDates)
        kindLabel.stringValue = newItem.map { Kinds.info($0.kind).name } ?? ""

        let kind = newItem?.kind ?? .text
        let visual = kind == .image || kind == .color
        // Hidden (list-only popup): no page is fetched until the preview is shown and asks again.
        let link = kind == .link && Settings.shared.linkPreviews && !view.isHidden
        textScroll.isHidden = visual || link || kind == .files
        imageView.isHidden = !visual
        caption.isHidden = !visual && !link
        fileView.isHidden = kind != .files || (newItem?.lineCount ?? 0) > 1
        fileGrid.isHidden = kind != .files || (newItem?.lineCount ?? 0) <= 1
        linkView.isHidden = !link
        urlLabel.isHidden = true

        guard let newItem else { return }
        switch kind {
        case .image: loadImage(newItem.id)
        case .files: loadFiles(newItem.id)
        case .color: showColor(newItem.title)
        case .link where link: loadLink(newItem.id)
        default: loadNextChunk()
        }
    }

    private func showColor(_ value: String) {
        guard let color = Kinds.color(from: value) else {
            imageView.isHidden = true
            textScroll.isHidden = false
            loadNextChunk()
            return
        }
        imageView.image = Kinds.swatch(color, size: 160)
        // Show the other notation than the one copied.
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let (r, g, b) = (Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        caption.stringValue = value.hasPrefix("#")
            ? "rgb(\(r), \(g), \(b))"
            : String(format: "#%02X%02X%02X", r, g, b)
    }

    /// A browser tab: its page as a link card and its address large, as for a copied link.
    /// `kind` and `meta` take the places of the item's kind and dates.
    func show(page address: String, title: String, kind: String, meta: String) {
        show(nil, force: true)
        kindLabel.stringValue = kind
        self.meta.stringValue = meta
        self.meta.toolTip = nil
        textScroll.isHidden = true
        linkView.isHidden = false
        if !showAddress(address, title: title, fetch: Settings.shared.linkPreviews) {
            // edge://settings and the like: nothing to fetch, so the address alone.
            linkView.isHidden = true
            caption.isHidden = true
            textScroll.isHidden = false
            textView.string = title.isEmpty ? address : "\(title)\n\n\(address)"
        }
    }

    /// Text kept from a tab's page, under its card, with the search words marked; nil hides it.
    func showPageText(_ text: String?) {
        showRecognizedText(text?.isEmpty == false ? text : nil)
    }

    private func loadLink(_ id: Int64) {
        let gen = generation
        Core.shared.run({ try $0.previewText(id: id, byteOffset: 0, maxBytes: 4096) }) { [weak self] result in
            guard let self, gen == self.generation else { return }
            let text = (try? result.get())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !self.showAddress(text, title: nil, fetch: true) {
                self.linkView.isHidden = true
                self.caption.isHidden = true
                self.urlLabel.isHidden = true
                self.textScroll.isHidden = false
                self.loadNextChunk()
            }
        }
    }

    /// Shows what is known about the link at once, then the page's title and image when they arrive.
    /// False, showing nothing, when `text` is not a web address.
    private func showAddress(_ text: String, title: String?, fetch: Bool) -> Bool {
        guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else { return false }
        let gen = generation
        caption.stringValue = text
        caption.toolTip = text
        urlLabel.attributedStringValue = Self.styledAddress(url, text)
        if let cached = Self.linkCache.object(forKey: url as NSURL) {
            showLink(cached)
            return true
        }
        let placeholder = LPLinkMetadata()
        placeholder.originalURL = url
        placeholder.url = url
        if let title, !title.isEmpty { placeholder.title = title }
        showLink(placeholder)
        guard fetch, !Self.looksPrivate(url) else { return true }
        // Only once the selection rests: holding ↓ through a list must not load every page on the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, gen == self.generation else { return }
            let provider = LPMetadataProvider()
            provider.timeout = 6
            linkFetch = provider
            provider.startFetchingMetadata(for: url) { metadata, _ in
                DispatchQueue.main.async {
                    guard let metadata else { return }
                    Self.linkCache.setObject(metadata, forKey: url as NSURL)
                    if gen == self.generation { self.showLink(metadata) }
                }
            }
        }
        return true
    }

    /// A page with a picture gets the full card and the address as a caption; one without
    /// (unfetched, blocked, or behind a sign-in) gets a slim card with the address large below it.
    private func showLink(_ metadata: LPLinkMetadata) {
        linkView.metadata = metadata
        let rich = metadata.imageProvider != nil || metadata.videoProvider != nil
        urlLabel.isHidden = rich
        caption.isHidden = !rich
    }

    /// Scheme and query dimmed, host bold, path plain; percent-escapes decoded so non-Latin paths read as text.
    private static func styledAddress(_ url: URL, _ text: String) -> NSAttributedString {
        let readable = text.removingPercentEncoding ?? text
        let result = NSMutableAttributedString(string: readable, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        guard let host = url.host, let hostRange = readable.range(of: host) else { return result }
        let queryStart = readable[hostRange.upperBound...].firstIndex { $0 == "?" || $0 == "#" } ?? readable.endIndex
        result.addAttributes([.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor],
                             range: NSRange(hostRange, in: readable))
        result.addAttribute(.foregroundColor, value: NSColor.labelColor,
                            range: NSRange(hostRange.upperBound..<queryStart, in: readable))
        return result
    }

    /// Links that may be single-use or carry credentials are never opened just to preview them:
    /// loading a password-reset or sign-in link could use it up.
    static func looksPrivate(_ url: URL) -> Bool {
        if url.user != nil || url.password != nil { return true }
        let markers = ["token", "code", "key", "sig", "auth", "pass", "secret", "reset", "magic", "otp",
                       "session", "credential", "invite", "confirm", "verify", "login", "x-amz-"]
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        let path = url.path.lowercased()
        return names.contains { name in markers.contains { name.contains($0) } }
            || ["reset", "magic", "verify", "confirm", "invite", "login", "signin", "oauth"].contains { path.contains($0) }
    }

    /// One file: Quick Look of it. Several: a tile for each. Falls back to the list of paths when none is left.
    private func loadFiles(_ id: Int64) {
        let gen = generation
        Core.shared.run({ try $0.fullText(id: id) }) { [weak self] result in
            guard let self, gen == self.generation, case .success(let text) = result else { return }
            let paths = text.split(separator: "\n").map(String.init)
            self.filePaths = paths
            if paths.count > 1 {
                let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }.count
                self.meta.stringValue += missing == 0 ? " · click a file to paste it alone" : " · \(missing) moved or deleted"
                self.fileGrid.paths = paths
                return
            }
            guard let first = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                self.meta.stringValue += " · moved or deleted"
                self.fileView.isHidden = true
                self.textScroll.isHidden = false
                self.loadNextChunk()
                return
            }
            self.meta.stringValue += " · \((first as NSString).abbreviatingWithTildeInPath)"
            self.fileView.previewItem = URL(fileURLWithPath: first) as NSURL
        }
    }

    @objc private func didScroll() {
        let visible = textScroll.documentVisibleRect
        let height = textView.frame.height
        if visible.maxY > height - visible.height * 2 {
            loadNextChunk()
        }
    }

    private func loadNextChunk() {
        guard let item, !loadingChunk, nextOffset < item.textBytes else { return }
        loadingChunk = true
        let gen = generation
        let offset = nextOffset
        Core.shared.run({ try $0.previewText(id: item.id, byteOffset: offset, maxBytes: Self.chunkBytes) }) { [weak self] result in
            guard let self, gen == self.generation else { return }
            self.loadingChunk = false
            guard case .success(let chunk) = result, !chunk.isEmpty else { return }
            self.nextOffset = offset + Int64(chunk.utf8.count)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            self.textView.textStorage?.append(NSAttributedString(string: chunk, attributes: [
                .font: self.textView.font as Any,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]))
        }
    }

    private func loadImage(_ id: Int64) {
        let gen = generation
        Core.shared.run({ store -> (CGImage, CGSize, String?)? in
            guard let data = Preprocessor.imageData(try store.reps(id: id)),
                  let image = Preprocessor.downsampled(data, maxPixels: Self.imageMaxPixels) else { return nil }
            let size = Preprocessor.pixelSize(data) ?? CGSize(width: image.width, height: image.height)
            return (image, size, try store.recognizedText(id: id))
        }) { [weak self] result in
            guard let self, gen == self.generation, case .success(let (image, size, text)?) = result else { return }
            self.imageView.image = NSImage(cgImage: image, size: .zero)
            let words = text?.split(whereSeparator: \.isWhitespace).count ?? 0
            self.caption.stringValue = "\(Int(size.width)) × \(Int(size.height)) px"
                + (words == 1 ? " · 1 word found, searchable" : words > 1 ? " · \(words) words found, searchable" : "")
            self.showRecognizedText(words > 0 ? text : nil)
        }
    }

    /// Marks every occurrence, ignoring case, and scrolls the first into view.
    private func markSearchWords() {
        guard let storage = ocrView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: whole)
        let text = storage.string as NSString
        var first: NSRange?
        for word in searchWords {
            var range = text.range(of: word, options: .caseInsensitive, range: whole)
            while range.location != NSNotFound {
                storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.6), range: range)
                if first.map({ range.location < $0.location }) ?? true { first = range }
                let next = range.upperBound
                range = text.range(of: word, options: .caseInsensitive, range: NSRange(location: next, length: whole.length - next))
            }
        }
        if let first { ocrView.scrollRangeToVisible(first) }
    }

    /// The image keeps the top of the card; its text takes the bottom 40% and scrolls.
    private func showRecognizedText(_ text: String?) {
        ocrView.string = text ?? ""
        ocrView.scroll(.zero)
        markSearchWords()
        ocrLine.isHidden = text == nil
        ocrScroll.isHidden = text == nil
        captionAtBottom.isActive = text == nil
        captionAboveText.isActive = text != nil
    }

    /// App · First · Last · counts · copies, in that fixed order.
    private static func describe(_ item: ItemSummary) -> String {
        var parts: [String] = []
        if let app = item.app {
            parts.append(SourceApps.name(app))
        }
        parts.append("First \(shortDate.string(from: date(item.firstCopiedAt)))")
        if item.lastCopiedAt != item.firstCopiedAt {
            parts.append("Last \(shortDate.string(from: date(item.lastCopiedAt)))")
        }
        switch item.kind {
        case .files:
            parts.append(item.lineCount == 1 ? "1 file" : "\(item.lineCount) files")
        case .image, .color:
            break
        default:
            if item.charCount > 0 {
                parts.append("\(item.charCount.formatted()) chars / \(item.lineCount.formatted()) lines")
            }
        }
        if item.copyCount > 1 {
            parts.append("\(item.copyCount) copies")
        }
        return parts.joined(separator: " · ")
    }

    private static func fullDates(_ item: ItemSummary) -> String {
        let first = date(item.firstCopiedAt).formatted(date: .complete, time: .standard)
        let last = date(item.lastCopiedAt).formatted(date: .complete, time: .standard)
        return "First copied \(first)\nLast copied \(last)\nCopied or pasted \(item.copyCount) times"
    }

    private static func date(_ millis: Int64) -> Date {
        Date(unixMillis: millis)
    }
}
