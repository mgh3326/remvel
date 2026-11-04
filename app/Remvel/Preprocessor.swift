import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The AppKit-only parts of ingest. Runs on the core queue, never the main thread.
/// HTML→text happens in Rust; RTF and images need Apple frameworks, so they happen here.
enum Preprocessor {
    static let thumbnailMaxPixels = 160

    static func capture(reps: [Rep], app: String?, copiedAt: Int64) -> Capture {
        Capture(
            reps: reps,
            app: app,
            derivedText: derivedText(reps),
            thumbnailPng: imageData(reps).flatMap { downsampledPNG($0, maxPixels: thumbnailMaxPixels) },
            copiedAt: copiedAt
        )
    }

    static func imageData(_ reps: [Rep]) -> Data? {
        data(reps, .png) ?? data(reps, .tiff)
    }

    /// Decodes only as many pixels as needed. Full-size decoding of a 6MP screenshot
    /// is what makes image previews slow.
    static func downsampled(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func downsampledPNG(_ data: Data, maxPixels: Int) -> Data? {
        guard let image = downsampled(data, maxPixels: maxPixels) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func derivedText(_ reps: [Rep]) -> String? {
        guard data(reps, .string) == nil, let rtf = data(reps, .rtf) else { return nil }
        return NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
    }

    private static func data(_ reps: [Rep], _ type: NSPasteboard.PasteboardType) -> Data? {
        reps.first { $0.uti == type.rawValue }?.data
    }
}
