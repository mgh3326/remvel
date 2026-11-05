import AppIntents
import AppKit

// Actions for Shortcuts, Spotlight and Siri. They run inside Remvel and read the same store
// as the popup; nothing is sent anywhere unless the user's shortcut sends it.

/// One history item as Shortcuts sees it.
struct ClipboardItem: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Clipboard Item")
    static let defaultQuery = ClipboardItemQuery()

    let id: Int
    @Property(title: "Title")
    var title: String
    @Property(title: "Kind")
    var kind: String
    @Property(title: "App")
    var app: String
    @Property(title: "Last Copied")
    var lastCopied: Date

    init(_ summary: ItemSummary) {
        id = Int(summary.id)
        title = summary.title
        kind = Kinds.info(summary.kind).name
        app = summary.app.map(SourceApps.name) ?? ""
        lastCopied = Date(unixMillis: summary.lastCopiedAt)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(kind)\(app.isEmpty ? "" : " · \(app)")",
            image: .init(systemName: Kinds.all.first { $0.name == kind }?.symbol ?? "doc.on.clipboard")
        )
    }
}

struct ClipboardItemQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [ClipboardItem] {
        try await core { try $0.summaries(ids: identifiers.map(Int64.init)) }.map(ClipboardItem.init)
    }

    func entities(matching string: String) async throws -> [ClipboardItem] {
        try await search(string, limit: 20)
    }

    func suggestedEntities() async throws -> [ClipboardItem] {
        try await core { try $0.list(offset: 0, limit: 20) }.map(ClipboardItem.init)
    }
}

struct SearchClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Clipboard History"
    static let description = IntentDescription(
        "Finds items in Remvel's clipboard history whose text, title, or text inside images matches."
    )

    @Parameter(title: "Search Text", description: "Words to look for.")
    var query: String

    @Parameter(title: "Limit", description: "Most items to return.", default: 10, inclusiveRange: (1, 100))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search clipboard history for \(\.$query)") { \.$limit }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipboardItem]> {
        .result(value: try await search(query, limit: limit))
    }
}

struct RecentClipboardItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Clipboard Items"
    static let description = IntentDescription("Returns the most recently copied items, pinned items first.")

    @Parameter(title: "Count", default: 5, inclusiveRange: (1, 100))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get the \(\.$count) most recent clipboard items")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipboardItem]> {
        .result(value: try await core { try $0.list(offset: 0, limit: Int64(count)) }.map(ClipboardItem.init))
    }
}

struct ClipboardItemTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Text of Clipboard Item"
    static let description = IntentDescription(
        "Returns an item's full text: the text itself, a file's path, or the words found in an image."
    )

    @Parameter(title: "Item")
    var item: ClipboardItem

    static var parameterSummary: some ParameterSummary {
        Summary("Get the text of \(\.$item)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = Int64(item.id)
        return .result(value: try await core { try $0.fullText(id: id) })
    }
}

struct CopyClipboardItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Clipboard Item"
    static let description = IntentDescription("Puts an item from the history back on the clipboard, ready to paste.")

    @Parameter(title: "Item")
    var item: ClipboardItem

    @Parameter(title: "Plain Text", description: "Drop formatting; images give the text found in them.", default: false)
    var plainText: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$item)") { \.$plainText }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        Paster.copy(id: Int64(item.id), plainText: plainText)
        return .result()
    }
}

struct OpenRemvelIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Remvel"
    static let description = IntentDescription("Opens the Remvel popup, optionally with a search already typed.")

    @Parameter(title: "Search Text")
    var query: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        (NSApp.delegate as? AppDelegate)?.showPopup(query: query ?? "")
        return .result()
    }
}

struct RemvelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenRemvelIntent(),
            phrases: ["Open \(.applicationName)", "Show my clipboard in \(.applicationName)"],
            shortTitle: "Open Remvel",
            systemImageName: "list.clipboard"
        )
        AppShortcut(
            intent: SearchClipboardIntent(),
            phrases: ["Search \(.applicationName)", "Search clipboard history in \(.applicationName)"],
            shortTitle: "Search Clipboard",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: CopyClipboardItemIntent(),
            phrases: ["Copy \(\.$item) from \(.applicationName)"],
            shortTitle: "Copy Item",
            systemImageName: "doc.on.doc"
        )
    }
}

// MARK: Helpers

/// `Core.run` for async code.
private func core<T>(_ work: @escaping (Remvel) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Core.shared.run(work) { continuation.resume(with: $0) }
    }
}

/// The popup's search, in the popup's order: `#tags` filter, the core ranks.
private func search(_ query: String, limit: Int) async throws -> [ClipboardItem] {
    let (text, kinds, _) = HistoryModel.parse(query)
    let filter = Filter(kinds: kinds, apps: [])
    let summaries = try await core { store -> [ItemSummary] in
        let hits = try store.search(query: text, filter: filter, limit: Int64(limit))
        return try store.summaries(ids: hits.map(\.id))
    }
    return summaries.map(ClipboardItem.init)
}
