import Foundation

/// Rows are fetched one page at a time as the table asks for them,
/// so opening the popup costs the same with 200 items or 200,000.
final class HistoryModel {
    static let pageSize = 100
    /// Most results for search text.
    static let searchLimit: Int64 = 1_000
    /// A filter with no text lists that many items at most, in browse order.
    static let filterLimit: Int64 = 10_000

    /// Row count or order changed; reload everything.
    var onReload: (() -> Void)?
    /// Summaries for these rows arrived.
    var onRowsLoaded: ((IndexSet) -> Void)?

    private(set) var rowCount = 0
    private(set) var query = ""
    /// Chosen in the filter menu or sidebar; `#tags` typed in the query add to it.
    var filter = Filter(kinds: [], apps: []) {
        didSet { refresh() }
    }
    /// True when rows are search or filter results rather than the whole history.
    var isFiltered: Bool { hits != nil }
    private var hits: [SearchHit]?
    private var rows: [Int: ItemSummary] = [:]
    private var requestedPages: Set<Int> = []
    /// Bumped on every new query; results from older queries are dropped.
    private var generation = 0

    func summary(at row: Int) -> ItemSummary? {
        guard row >= 0, row < rowCount else { return nil }
        if let summary = rows[row] { return summary }
        loadPage(row / Self.pageSize)
        return nil
    }

    func titleIndices(at row: Int) -> [UInt32] {
        hits.flatMap { row < $0.count ? $0[row].titleIndices : nil } ?? []
    }

    func refresh() {
        setQuery(query)
    }

    /// Source apps that `@name` can pick, most used first.
    var knownApps: [String] = []

    /// Splits "#image @safari cat" into kinds [.image], apps ["com.apple.Safari"] and text "cat".
    /// `@` matches the start of an app's name, or of the last part of its bundle id, among `apps`;
    /// the most used app wins. Unknown tags stay in the text.
    static func parse(_ query: String, apps: [String] = []) -> (text: String, kinds: [Kind], apps: [String]) {
        var kinds: [Kind] = []
        var picked: [String] = []
        var words: [Substring] = []
        for word in query.split(separator: " ", omittingEmptySubsequences: true) {
            if word.hasPrefix("#"), let kind = Kinds.tags[word.dropFirst().lowercased()] {
                if !kinds.contains(kind) { kinds.append(kind) }
            } else if word.hasPrefix("@"), word.count > 1, let app = matchApp(word.dropFirst().lowercased(), in: apps) {
                if !picked.contains(app) { picked.append(app) }
            } else {
                words.append(word)
            }
        }
        return (words.joined(separator: " "), kinds, picked)
    }

    private static func matchApp(_ prefix: String, in apps: [String]) -> String? {
        let squash = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
        return apps.first { app in
            squash(SourceApps.name(app)).hasPrefix(prefix)
                || squash(String(app.split(separator: ".").last ?? "")).hasPrefix(prefix)
        }
    }

    func setQuery(_ newQuery: String) {
        query = newQuery
        generation += 1
        let gen = generation
        let (text, typedKinds, typedApps) = Self.parse(newQuery, apps: knownApps)
        // Chosen kinds and apps first, then typed ones, without repeats, so the same input gives the same filter.
        let chosen = self.filter
        let filter = Filter(kinds: chosen.kinds + typedKinds.filter { !chosen.kinds.contains($0) },
                            apps: chosen.apps + typedApps.filter { !chosen.apps.contains($0) })

        // The whole history pages through `list`, which has the same order as `search` with no text.
        if text.isEmpty, filter.kinds.isEmpty, filter.apps.isEmpty {
            Core.shared.run({ $0.count() }) { [weak self] result in
                guard let self, gen == self.generation, case .success(let count) = result else { return }
                self.reset(count: Int(count), hits: nil)
            }
            return
        }

        // The core orders results; see `Remvel.search`.
        let limit = text.isEmpty ? Self.filterLimit : Self.searchLimit
        Core.shared.run({ try $0.search(query: text, filter: filter, limit: limit) }) { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let hits): self.reset(count: hits.count, hits: hits)
            case .failure(let error): NSLog("Remvel: search failed: \(error)")
            }
        }
    }

    private func reset(count: Int, hits: [SearchHit]?) {
        rowCount = count
        self.hits = hits
        rows = [:]
        requestedPages = []
        onReload?()
    }

    private func loadPage(_ page: Int) {
        guard requestedPages.insert(page).inserted else { return }
        let gen = generation
        let range = page * Self.pageSize ..< min((page + 1) * Self.pageSize, rowCount)
        let pageIds = hits.map { hits in range.map { hits[$0].id } }

        Core.shared.run({ store -> [Int: ItemSummary] in
            if let pageIds {
                let byId = Dictionary(uniqueKeysWithValues: try store.summaries(ids: pageIds).map { ($0.id, $0) })
                var rows: [Int: ItemSummary] = [:]
                for (offset, id) in pageIds.enumerated() {
                    rows[range.lowerBound + offset] = byId[id]
                }
                return rows
            }
            let items = try store.list(offset: Int64(range.lowerBound), limit: Int64(range.count))
            return Dictionary(uniqueKeysWithValues: items.enumerated().map { (range.lowerBound + $0.offset, $0.element) })
        }) { [weak self] result in
            guard let self, gen == self.generation, case .success(let loaded) = result else { return }
            self.rows.merge(loaded) { _, new in new }
            self.onRowsLoaded?(IndexSet(loaded.keys))
        }
    }
}
