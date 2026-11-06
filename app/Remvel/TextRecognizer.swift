import AppKit
import ImageIO
import Vision

/// Finds text in copied images so they can be searched like text.
/// Vision runs in a short-lived copy of Remvel (`--recognize-text`): recognition briefly needs
/// a few hundred MB, and a separate process hands all of it back to the system when it exits.
/// Images are done one at a time at utility priority, new copies before old history.
final class TextRecognizer {
    static let shared = TextRecognizer()
    static let helperFlag = "--recognize-text"
    /// Larger images are scaled down first; text stays legible and the work stays near 0.4 s.
    static let maxPixels = 2000
    /// The very first run on a Mac also prepares the system's models, which can take half a minute.
    static let timeout: TimeInterval = 120
    static let backfillBatch: Int64 = 20
    /// Pause between history images so a backfill never keeps a core busy.
    static let backfillPause: TimeInterval = 1

    private var pending: [Int64] = []
    private var running = false
    private let queue = DispatchQueue(label: "remvel.ocr", qos: .utility)

    /// A newly copied image goes ahead of any backfill.
    func recognize(_ id: Int64) {
        guard Settings.shared.recognizeText else { return }
        pending.removeAll { $0 == id }
        pending.insert(id, at: 0)
        next()
    }

    /// Queues history images that were never recognized, a batch at a time.
    func backfill() {
        guard Settings.shared.recognizeText, pending.isEmpty, !running else { return }
        Core.shared.run({ try $0.unrecognizedImages(limit: Self.backfillBatch) }) { [weak self] result in
            guard let self, case .success(let ids) = result, !ids.isEmpty else { return }
            self.pending += ids.filter { !self.pending.contains($0) }
            self.next()
        }
    }

    private func next() {
        guard !running, Settings.shared.recognizeText, !pending.isEmpty else { return }
        running = true
        let id = pending.removeFirst()
        Core.shared.run({ try Preprocessor.imageData($0.reps(id: id)) }) { [weak self] result in
            guard let self else { return }
            guard case .success(let data?) = result else {
                // No readable image: record an empty result so it is not offered again.
                self.finish(id: id, text: "")
                return
            }
            self.queue.async {
                let text = Self.runHelper(data)
                DispatchQueue.main.async { self.finish(id: id, text: text ?? "") }
            }
        }
    }

    private func finish(id: Int64, text: String) {
        let done = { [weak self] in
            guard let self else { return }
            self.running = false
            if self.pending.isEmpty {
                // Keep working through history until nothing is left.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.backfillPause) { self.backfill() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.backfillPause) { self.next() }
            }
        }
        // A failed run stores "" too, so one broken image is not retried forever.
        Core.shared.perform("storing recognized text", { try $0.setRecognizedText(id: id, text: text) }, then: done)
    }

    /// Image bytes in through stdin, text out through stdout, so nothing private touches the disk.
    private static func runHelper(_ image: Data) -> String? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = [helperFlag]
        process.qualityOfService = .utility
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.app.error("text recognition did not start: \(String(describing: error), privacy: .public)")
            return nil
        }
        DispatchQueue.global(qos: .utility).async {
            try? input.fileHandleForWriting.write(contentsOf: image)
            try? input.fileHandleForWriting.close()
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let text = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: text, as: UTF8.self)
    }

    // MARK: Helper process

    /// Entry point of the helper: reads an image from stdin, prints its text, exits.
    static func runAsHelper() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { exit(1) }

        let request = VNRecognizeTextRequest()
        // .fast cannot read Korean; .accurate on a 2000 px image takes about 0.4 s.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages(supported: (try? request.supportedRecognitionLanguages()) ?? [])
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            exit(1)
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        FileHandle.standardOutput.write(Data(lines.joined(separator: "\n").utf8))
        exit(0)
    }

    /// The user's languages that Vision can read, then English.
    private static func languages(supported: [String]) -> [String] {
        var result: [String] = []
        for preferred in Locale.preferredLanguages + ["en-US"] {
            let language = Locale(identifier: preferred).language.languageCode?.identifier
            if let match = supported.first(where: { $0 == preferred })
                ?? supported.first(where: { Locale(identifier: $0).language.languageCode?.identifier == language }),
                !result.contains(match) {
                result.append(match)
            }
        }
        return result
    }
}
