import AppKit

/// Display names, symbols and `#tags` for the item kinds the core assigns.
enum Kinds {
    struct Info {
        let kind: Kind
        let name: String
        let symbol: String
        let tag: String
    }

    /// Every kind, in menu order.
    static let all: [Info] = [Kind.note, .text, .link, .image, .files, .color, .rich].map(Kinds.info)

    /// `#tag` words and the kind each selects; a few aliases on top of the canonical tags.
    static let tags: [String: Kind] = Dictionary(uniqueKeysWithValues: all.map { ($0.tag, $0.kind) })
        .merging(["url": .link, "img": .image, "files": .files, "colour": .color, "notes": .note, "memo": .note]) { old, _ in old }

    /// Exhaustive, so a kind added in the core does not build until it has a name and symbol here.
    static func info(_ kind: Kind) -> Info {
        switch kind {
        case .text: Info(kind: kind, name: "Text", symbol: "text.alignleft", tag: "text")
        case .link: Info(kind: kind, name: "Links", symbol: "link", tag: "link")
        case .image: Info(kind: kind, name: "Images", symbol: "photo", tag: "image")
        case .files: Info(kind: kind, name: "Files", symbol: "doc", tag: "file")
        case .color: Info(kind: kind, name: "Colors", symbol: "paintpalette", tag: "color")
        case .rich: Info(kind: kind, name: "Rich Text", symbol: "textformat", tag: "rich")
        case .note: Info(kind: kind, name: "Notes", symbol: "note.text", tag: "note")
        }
    }

    static func symbol(_ kind: Kind) -> NSImage? {
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
