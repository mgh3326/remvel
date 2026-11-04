import Foundation

/// Rows are fetched one page at a time as the table asks for them,
/// so opening the popup costs the same with 200 items or 200,000.
final class HistoryModel {
    static let pageSize = 100
    static let searchLimit: UInt32 = 500

    /// Row count or order changed; reload everything.
    var onReload: (() -> Void)?
    /// Summaries for these rows arrived.
    var onRowsLoaded: ((IndexSet) -> Void)?

    private(set) var rowCount = 0
    private(set) var query = ""
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

    func setQuery(_ newQuery: String) {
        query = newQuery
        generation += 1
        let gen = generation

        if newQuery.isEmpty {
            Core.shared.run({ $0.count() }) { [weak self] result in
                guard let self, gen == self.generation, case .success(let count) = result else { return }
                self.reset(count: Int(count), hits: nil)
            }
            return
        }

        Core.shared.run({ store in
            // Fuzzy over titles first, then substring matches anywhere in the full text.
            var hits = try store.search(query: newQuery, mode: .fuzzy, limit: Self.searchLimit)
            let seen = Set(hits.map(\.id))
            hits += try store.search(query: newQuery, mode: .exact, limit: Self.searchLimit)
                .filter { !seen.contains($0.id) }
            return hits
        }) { [weak self] result in
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
