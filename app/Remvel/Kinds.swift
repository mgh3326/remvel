import AppKit

/// Display names, symbols and `#tags` for the item kinds the core assigns.
enum Kinds {
    struct Info {
        let kind: String
        let name: String
        let symbol: String
        let tag: String
    }

    static let all: [Info] = [
        Info(kind: "text", name: "Text", symbol: "text.alignleft", tag: "text"),
        Info(kind: "link", name: "Links", symbol: "link", tag: "link"),
        Info(kind: "image", name: "Images", symbol: "photo", tag: "image"),
        Info(kind: "files", name: "Files", symbol: "doc", tag: "file"),
        Info(kind: "color", name: "Colors", symbol: "paintpalette", tag: "color"),
        Info(kind: "rich", name: "Rich Text", symbol: "textformat", tag: "rich"),
    ]

    /// `#tag` words and the kind each selects; a few aliases on top of the canonical tags.
    static let tags: [String: String] = Dictionary(uniqueKeysWithValues: all.map { ($0.tag, $0.kind) })
        .merging(["url": "link", "img": "image", "files": "files", "colour": "color"]) { old, _ in old }

    static func info(_ kind: String) -> Info {
        all.first { $0.kind == kind } ?? Info(kind: kind, name: kind.capitalized, symbol: "questionmark.square", tag: kind)
    }

    static func symbol(_ kind: String) -> NSImage? {
        NSImage(systemSymbolName: info(kind).symbol, accessibilityDescription: info(kind).name)
    }

    /// Parses "#1274DF", "#fff", "rgb(…)" and "hsl(…)" well enough to draw a swatch.
    static func color(from text: String) -> NSColor? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
            let rgba = hex.count == 6 ? value << 8 | 0xFF : value
            return NSColor(
                srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255
            )
        }
        let lower = text.lowercased()
        guard let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        let numbers = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            .split(whereSeparator: { ", /".contains($0) })
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%deg"))) }
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count > 3 ? (numbers[3] > 1 ? numbers[3] / 100 : numbers[3]) : 1
        if lower.hasPrefix("rgb") {
            return NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: alpha)
        }
        // HSL to HSB.
        let s = numbers[1] / 100, l = numbers[2] / 100
        let v = l + s * min(l, 1 - l)
        return NSColor(hue: numbers[0] / 360, saturation: v == 0 ? 0 : 2 * (1 - l / v), brightness: v, alpha: alpha)
    }

    static func swatch(_ color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: size / 4, yRadius: size / 4)
            color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }
}
