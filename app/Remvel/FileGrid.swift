import AppKit
import QuickLookThumbnailing

/// Every file of a multi-file copy as a tile with its thumbnail and name.
/// Clicking a tile pastes that file alone.
final class FileGrid: NSScrollView {
    static let tileSize = NSSize(width: 112, height: 128)
    static let spacing: CGFloat = 10
    /// More than this shows the first ones; the caption says how many there are.
    static let maxTiles = 200

    var onPick: ((String) -> Void)?
    private let grid = FlippedView()
    private var tiles: [FileTile] = []
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = grid
    }

    required init?(coder: NSCoder) { fatalError() }

    var paths: [String] = [] {
        didSet {
            generation += 1
            tiles.forEach { $0.removeFromSuperview() }
            tiles = paths.prefix(Self.maxTiles).map { path in
                let tile = FileTile(path: path)
                tile.target = self
                tile.action = #selector(pick(_:))
                grid.addSubview(tile)
                return tile
            }
            needsLayout = true
            loadThumbnails()
        }
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        let columns = max(1, Int((width - Self.spacing) / (Self.tileSize.width + Self.spacing)))
        // Spread the leftover width so the grid fills the card edge to edge.
        let gap = (width - CGFloat(columns) * Self.tileSize.width) / CGFloat(columns + 1)
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            tile.frame = NSRect(
                x: gap + CGFloat(column) * (Self.tileSize.width + gap),
                y: Self.spacing + CGFloat(row) * (Self.tileSize.height + Self.spacing),
                width: Self.tileSize.width, height: Self.tileSize.height
            )
        }
        let rows = (tiles.count + columns - 1) / columns
        grid.frame.size = NSSize(width: width, height: max(contentSize.height,
            Self.spacing + CGFloat(rows) * (Self.tileSize.height + Self.spacing)))
    }

    private func loadThumbnails() {
        let gen = generation
        let scale = window?.backingScaleFactor ?? 2
        for tile in tiles {
            let url = URL(fileURLWithPath: tile.path)
            guard FileManager.default.fileExists(atPath: tile.path) else {
                tile.missing = true
                continue
            }
            tile.image = NSWorkspace.shared.icon(forFile: tile.path)
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: NSSize(width: Self.tileSize.width, height: Self.tileSize.width),
                scale: scale, representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak tile] thumbnail, _ in
                guard let thumbnail else { return }
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    tile?.image = thumbnail.nsImage
                }
            }
        }
    }

    @objc private func pick(_ sender: FileTile) {
        onPick?(sender.path)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class FileTile: NSButton {
    let path: String
    var missing = false {
        didSet {
            isEnabled = !missing
            image = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: "Missing")?
                .withSymbolConfiguration(.init(pointSize: 40, weight: .light))
            toolTip = "\(path)\nMoved or deleted"
        }
    }

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        title = (path as NSString).lastPathComponent
        toolTip = path
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lineBreakMode = .byTruncatingMiddle
        (cell as? NSButtonCell)?.highlightsBy = .contentsCellMask
    }

    required init?(coder: NSCoder) { fatalError() }
}
