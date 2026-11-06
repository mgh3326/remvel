import os

/// Remvel's log, in the macOS unified log on this Mac only. Errors are kept; debug lines cost nothing
/// unless someone is watching:
///     log stream --predicate 'subsystem == "io.github.remvel"' --level debug
/// Addresses, titles and copied text are never logged.
enum Log {
    static let core = Logger(subsystem: "io.github.remvel", category: "core")
    static let tabs = Logger(subsystem: "io.github.remvel", category: "tabs")
    static let history = Logger(subsystem: "io.github.remvel", category: "history")
    static let app = Logger(subsystem: "io.github.remvel", category: "app")
}
