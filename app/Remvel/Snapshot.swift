import AppKit

/// Renders the popup offscreen to a PNG with synthetic history, for reviewing the UI
/// without opening a window or touching the user's data. Not part of normal use.
///
///     Remvel --snapshot out.png --data-dir /tmp/remvel-snap [--state default|search|queue|expanded] [--dark]
struct Snapshot {
    let output: URL
    let state: String
    let dark: Bool

    static var dataDirectory: URL? {
        argument("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var requested: Snapshot? {
        guard let path = argument("--snapshot"), dataDirectory != nil else { return nil }
        return Snapshot(
            output: URL(fileURLWithPath: path),
            state: argument("--state") ?? "default",
            dark: CommandLine.arguments.contains("--dark")
        )
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func run(popup: PopupController) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Core.shared.run({ store in
            if store.count() == 0 { try Self.fill(store) }
        }) { result in
            if case .failure(let error) = result { fatalError("Snapshot data: \(error)") }
            let query = state == "search" ? "#image rvl" : ""
            let queueRows = state == "queue" ? [7, 1, 4] : []
            popup.prepareSnapshot(query: query, expanded: state == "expanded", queueRows: queueRows) { view in
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try! rep.representation(using: .png, properties: [:])!.write(to: output)
                NSApp.terminate(nil)
            }
        }
    }

    /// Synthetic items only.
    private static func fill(_ store: Remvel) throws {
        let text = NSPasteboard.PasteboardType.string.rawValue
        let samples: [(String, String)] = [
            ("let pageSize = 100", "com.apple.dt.Xcode"),
            ("https://github.com/mgh3326/remvel", "com.apple.Safari"),
            ("#1274DF", "com.figma.Desktop"),
            ("cargo test --release", "com.apple.Terminal"),
            ("회의 메모 — 검색과 미리보기", "com.apple.Notes"),
            ("검색은 메인 스레드를 막지 않는다", "com.apple.Notes"),
            ("rgb(41, 155, 141)", "com.figma.Desktop"),
            ("Release checklist — Remvel 0.3\n\n검색과 저장은 백그라운드에서 처리합니다.\nThe main thread only draws the interface.\n\n• Keep the list at 30 pt per row.\n• Read only the visible page of metadata.\n• Load large text previews in small chunks.", "com.apple.Notes"),
        ]
        var at = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        for (body, app) in samples {
            at += 60_000
            let id = try store.ingest(capture: Capture(
                reps: [Rep(uti: text, data: Data(body.utf8))], app: app, derivedText: nil,
                thumbnailPng: nil, title: nil, copiedAt: at
            )).id
            if body.hasPrefix("cargo") { try store.setPin(id: id, pin: "0000000000001") }
        }
        for (index, name) in ["river-valley", "review-panel-dark", "archive-levels"].enumerated() {
            let image = NSApp.applicationIconImage!
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            let reps = [Rep(uti: NSPasteboard.PasteboardType.png.rawValue, data: png + Data([UInt8(index)]))]
            var capture = Preprocessor.capture(reps: reps, app: "com.apple.Safari", copiedAt: at + Int64(index) * 1000)
            capture.title = "\(name).png"
            let id = try store.ingest(capture: capture).id
            try store.setRecognizedText(id: id, text: "Remvel clipboard history 검색 미리보기")
        }
    }
}
