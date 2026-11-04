import AppKit
import Quartz

/// Shows one item. Text is read 64 KB at a time and appended as the user scrolls,
/// so a 50 MB log costs the same to open as a one-liner.
final class PreviewController: NSObject {
    static let chunkBytes: Int64 = 64 * 1024
    static let imageMaxPixels = 1600

    let view = NSView()

    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let imageView = NSImageView()
    /// Quick Look for copied files: documents, PDFs, videos, folders.
    private let fileView = QLPreviewView(frame: .zero, style: .compact)!
    private let info = NSTextField(labelWithString: "")

    private var item: ItemSummary?
    private var nextOffset: Int64 = 0
    private var loadingChunk = false
    private var generation = 0

    override init() {
        super.init()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textScroll.drawsBackground = false
        textScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: textScroll.contentView
        )

        imageView.imageScaling = .scaleProportionallyDown
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        info.lineBreakMode = .byTruncatingTail
        // Long info lines must truncate, not widen the panel.
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileView.shouldCloseWithWindow = false

        for sub in [textScroll, imageView, fileView, info] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: view.topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -6),
            imageView.topAnchor.constraint(equalTo: textScroll.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: textScroll.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: textScroll.bottomAnchor),
            fileView.topAnchor.constraint(equalTo: textScroll.topAnchor),
            fileView.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor),
            fileView.trailingAnchor.constraint(equalTo: textScroll.trailingAnchor),
            fileView.bottomAnchor.constraint(equalTo: textScroll.bottomAnchor),
            info.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            info.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            info.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    func show(_ newItem: ItemSummary?) {
        guard newItem?.id != item?.id else { return }
        item = newItem
        generation += 1
        nextOffset = 0
        loadingChunk = false
        textView.string = ""
        imageView.image = nil
        info.stringValue = newItem.map(Self.describe) ?? ""

        fileView.previewItem = nil
        fileView.isHidden = true
        guard let newItem else { return }
        let isImage = newItem.kind == "image"
        textScroll.isHidden = isImage
        imageView.isHidden = !isImage
        if isImage {
            loadImage(newItem.id)
        } else if newItem.kind == "files" {
            loadFiles(newItem.id)
        } else {
            loadNextChunk()
        }
    }

    /// Previews the first file that still exists; falls back to the list of paths.
    private func loadFiles(_ id: Int64) {
        let gen = generation
        Core.shared.run({ try $0.previewText(id: id, byteOffset: 0, maxBytes: Self.chunkBytes) }) { [weak self] result in
            guard let self, gen == self.generation, case .success(let text) = result else { return }
            let paths = text.split(separator: "\n").map(String.init)
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard let first = existing.first else {
                self.info.stringValue += " · moved or deleted"
                self.loadNextChunk()
                return
            }
            if paths.count > 1 {
                self.info.stringValue += " · showing \((first as NSString).lastPathComponent)"
            } else {
                self.info.stringValue += " · \((first as NSString).abbreviatingWithTildeInPath)"
            }
            self.textScroll.isHidden = true
            self.fileView.isHidden = false
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
            self.textView.textStorage?.append(NSAttributedString(string: chunk, attributes: [
                .font: self.textView.font as Any,
                .foregroundColor: NSColor.labelColor,
            ]))
        }
    }

    private func loadImage(_ id: Int64) {
        let gen = generation
        Core.shared.run({ store -> (CGImage, CGSize)? in
            guard let data = Preprocessor.imageData(try store.reps(id: id)),
                  let image = Preprocessor.downsampled(data, maxPixels: Self.imageMaxPixels) else { return nil }
            return (image, Preprocessor.pixelSize(data) ?? CGSize(width: image.width, height: image.height))
        }) { [weak self] result in
            guard let self, gen == self.generation, case .success(let (image, size)?) = result else { return }
            self.imageView.image = NSImage(cgImage: image, size: .zero)
            self.info.stringValue += " · \(Int(size.width))×\(Int(size.height)) px"
        }
    }

    private static func describe(_ item: ItemSummary) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.lastCopiedAt) / 1000)
        var parts = [date.formatted(date: .abbreviated, time: .shortened)]
        if let app = item.app {
            parts.append(SourceApps.name(app))
        }
        if item.kind == "files" {
            parts.append(item.lineCount == 1 ? "1 file" : "\(item.lineCount) files")
            if item.copyCount > 1 {
                parts.append("copied \(item.copyCount)×")
            }
            return parts.joined(separator: " · ")
        }
        if item.charCount > 0 {
            parts.append("\(item.charCount.formatted()) chars")
            parts.append(item.lineCount == 1 ? "1 line" : "\(item.lineCount.formatted()) lines")
        }
        if item.textBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: item.textBytes, countStyle: .file))
        }
        if item.copyCount > 1 {
            parts.append("copied \(item.copyCount)×")
        }
        return parts.joined(separator: " · ")
    }
}
