import Foundation
import SQLite3

/// Copies each browser's history into Remvel (`importVisits`), so pages can be searched along with
/// tabs and outlive the browser's own history (Chromium keeps 90 days). An import reads only visits
/// newer than the last one stored, so after the first it takes a few milliseconds.
final class HistoryImport {
    static let shared = HistoryImport()

    /// Where Chromium browsers keep their profiles, under Application Support, by bundle id.
    /// Each profile folder ("Default", "Profile 1"…) holds a `History` database.
    private static let chromium: [String: String] = [
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.google.Chrome": "Google/Chrome",
        "com.naver.Whale": "Naver/Whale",
        "at.studio.AsideBrowser": "Aside",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "org.chromium.Chromium": "Chromium",
    ]
    static let safari = "com.apple.Safari"
    private static let safariHistory = URL.homeDirectory.appending(path: "Library/Safari/History.db")
    /// Not imported again sooner than this.
    private static let minInterval: TimeInterval = 300
    private static let year: Int64 = 365 * 24 * 60 * 60 * 1000

    private let queue = DispatchQueue(label: "io.github.remvel.history", qos: .utility)
    private var lastRun: Date?

    /// Safari's history sits behind Full Disk Access, which only the user can grant.
    static var safariReadable: Bool {
        guard FileManager.default.fileExists(atPath: safariHistory.path) else { return true }
        let fd = open(safariHistory.path, O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    func run(force: Bool = false) {
        guard Settings.shared.importHistory else { return }
        if !force, let lastRun, Date().timeIntervalSince(lastRun) < Self.minInterval { return }
        lastRun = Date()
        queue.async { Self.importAll() }
    }

    private static func importAll() {
        let support = URL.applicationSupportDirectory
        var sources: [(browser: String, file: URL, safari: Bool)] = []
        for (browser, folder) in chromium {
            let root = support.appending(path: folder)
            let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
                let file = root.appending(path: profile).appending(path: "History")
                if FileManager.default.fileExists(atPath: file.path) { sources.append((browser, file, false)) }
            }
        }
        if FileManager.default.fileExists(atPath: safariHistory.path) { sources.append((safari, safariHistory, true)) }

        let now = Date().unixMillis
        for source in sources {
            let since = max(lastVisit(source.browser), now - year)
            let visits = read(source.file, browser: source.browser, safari: source.safari, since: since)
            // Chunks keep each core call short, so a search typed meanwhile is not held up.
            for start in stride(from: 0, to: visits.count, by: 2_000) {
                let chunk = Array(visits[start ..< min(start + 2_000, visits.count)])
                Core.shared.perform("import history") { try $0.importVisits(visits: chunk, now: now) }
            }
        }
    }

    private static func lastVisit(_ browser: String) -> Int64 {
        let done = DispatchSemaphore(value: 0)
        var last: Int64 = 0
        Core.shared.run({ try $0.lastVisit(browser: browser) }) { result in
            last = (try? result.get()) ?? 0
            done.signal()
        }
        done.wait()
        return last
    }

    /// Reads a copy: the browser holds its database open and may be writing to it.
    static func read(_ file: URL, browser: String, safari: Bool, since: Int64) -> [Visit] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "remvel-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-journal"] {
                let from = URL(filePath: file.path + suffix)
                if FileManager.default.fileExists(atPath: from.path) {
                    try FileManager.default.copyItem(at: from, to: dir.appending(path: "History" + suffix))
                }
            }
        } catch {
            return []
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dir.appending(path: "History").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        // Chromium counts microseconds from 1601; Safari seconds from 2001.
        let sql = safari ? """
            SELECT i.url,
                   coalesce((SELECT title FROM history_visits WHERE history_item = i.id ORDER BY visit_time DESC LIMIT 1), ''),
                   i.visit_count, CAST((max(v.visit_time) + 978307200) * 1000 AS INTEGER)
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id HAVING max(v.visit_time) > (?1 / 1000.0 - 978307200)
            ORDER BY 4 DESC LIMIT 100000
            """ : """
            SELECT url, title, visit_count, last_visit_time / 1000 - 11644473600000
            FROM urls WHERE hidden = 0 AND last_visit_time > (?1 + 11644473600000) * 1000
            ORDER BY last_visit_time DESC LIMIT 100000
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        var visits: [Visit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
            }
            visits.append(Visit(browser: browser, url: text(0), title: text(1),
                                lastVisit: sqlite3_column_int64(stmt, 3), visitCount: sqlite3_column_int64(stmt, 2)))
        }
        return visits
    }
}
