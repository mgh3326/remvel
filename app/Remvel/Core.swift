import Foundation

/// Owns the Rust store. Every call runs on one serial background queue,
/// so the main thread never waits on SQLite or search.
final class Core {
    static let shared = Core()

    private let store: Remvel
    private let queue = DispatchQueue(label: "remvel.core", qos: .userInitiated)

    private init() {
        let dir = URL.applicationSupportDirectory.appending(path: "Remvel", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            store = try Remvel.open(path: dir.appending(path: "remvel.sqlite").path)
        } catch {
            fatalError("Cannot open database: \(error)")
        }
    }

    /// Runs `work` on the core queue and delivers the result on the main queue.
    func run<T>(_ work: @escaping (Remvel) throws -> T, then: @escaping (Result<T, Swift.Error>) -> Void) {
        queue.async { [store] in
            let result = Result { try work(store) }
            DispatchQueue.main.async { then(result) }
        }
    }
}
