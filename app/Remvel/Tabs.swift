import AppKit

/// A browser AppleScript can read tabs from: Safari, or any Chromium browser (Edge, Whale, Aside,
/// Chrome, Arc, Brave…), which all ship the same scripting dictionary. Firefox has none.
struct Browser: Hashable {
    let bundleId: String
    let name: String
    let safari: Bool

    /// Running browsers, found by their scripting dictionary rather than a list of names.
    static func running() -> [Browser] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, let url = app.bundleURL,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            let name = app.localizedName ?? id
            if id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview" {
                return Browser(bundleId: id, name: name, safari: true)
            }
            return Self.isChromium(url) ? Browser(bundleId: id, name: name, safari: false) : nil
        }
    }

    private static var chromium: [URL: Bool] = [:]

    private static func isChromium(_ app: URL) -> Bool {
        if let known = chromium[app] { return known }
        let sdef = app.appending(path: "Contents/Resources/scripting.sdef")
        let found = (try? String(contentsOf: sdef, encoding: .utf8))?.contains("active tab index") ?? false
        chromium[app] = found
        return found
    }
}

struct BrowserTab: Hashable {
    let browser: Browser
    let windowId: Int
    /// Chromium's tab id; Safari tabs have none, so their 1-based index in the window.
    let tabId: Int
    let title: String
    let url: String
    /// The tab the window shows.
    let active: Bool
}

/// Reads and switches tabs through `osascript`, one process per browser, so a browser that hangs
/// (or waits on its first permission prompt) is killed after a timeout without holding up the rest.
/// Nothing is watched: tabs are read only when the switcher opens.
enum Tabs {
    enum Access {
        case allowed
        /// macOS has not asked yet; asking shows its "Remvel wants to control …" prompt.
        case notAsked
        case denied
    }

    /// Never blocks on a prompt unless `ask` is true; then it waits for the answer.
    static func access(_ browser: Browser, ask: Bool) -> Access {
        let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleId)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .denied
        }
    }

    /// Every tab, front window first; nil when the browser did not answer in time.
    static func read(_ browser: Browser, timeout: TimeInterval = 5) -> [BrowserTab]? {
        guard let output = run(browser.safari ? safariRead(browser) : chromiumRead(browser), timeout: timeout) else {
            return nil
        }
        var tabs: [BrowserTab] = []
        for window in output.split(separator: "\u{1D}", omittingEmptySubsequences: true) {
            let records = window.split(separator: "\u{1E}", omittingEmptySubsequences: false).map {
                $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            }
            guard let head = records.first, head.count == 2, let windowId = Int(head[0]) else { continue }
            let active = Int(head[1]) ?? 0
            for (index, fields) in records.dropFirst().enumerated() where fields.count == 3 {
                guard let tabId = Int(fields[0]) else { continue }
                tabs.append(BrowserTab(browser: browser, windowId: windowId, tabId: tabId,
                                       title: clean(fields[1]), url: clean(fields[2]), active: index + 1 == active))
            }
        }
        return tabs
    }

    /// Shows the tab: selects it, raises its window and brings the browser forward, which moves
    /// to the window's desktop. False when the tab or window is gone.
    @discardableResult
    static func show(_ tab: BrowserTab) -> Bool {
        let script = tab.browser.safari ? """
            on run argv
                set wid to (item 1 of argv) as integer
                set i to (item 2 of argv) as integer
                tell application id "\(tab.browser.bundleId)"
                    set w to window id wid
                    set us to URL of every tab of w
                    -- Tabs may have moved since they were read; find this one by its address.
                    if i > (count of us) or (item i of us as text) is not (item 3 of argv) then
                        set i to 0
                        repeat with k from 1 to count of us
                            if (item k of us as text) is (item 3 of argv) then
                                set i to k
                                exit repeat
                            end if
                        end repeat
                        if i is 0 then return "gone"
                    end if
                    set current tab of w to tab i of w
                    try
                        set miniaturized of w to false
                    end try
                    set index of w to 1
                    activate
                end tell
                return "ok"
            end run
            """ : """
            on run argv
                set wid to (item 1 of argv) as integer
                set tid to (item 2 of argv) as integer
                tell application id "\(tab.browser.bundleId)"
                    set w to window id wid
                    set ids to id of every tab of w
                    set i to 0
                    repeat with k from 1 to count of ids
                        if (item k of ids) as integer is tid then
                            set i to k
                            exit repeat
                        end if
                    end repeat
                    if i is 0 then return "gone"
                    set active tab index of w to i
                    try
                        set minimized of w to false
                    end try
                    set index of w to 1
                    activate
                end tell
                return "ok"
            end run
            """
        return run(script, arguments: ["\(tab.windowId)", "\(tab.tabId)", tab.url], timeout: 5) == "ok"
    }

    // MARK: Scripts

    /// Each property is one Apple Event for every tab at once; asking tab by tab is 14× slower.
    /// Out: per window "id␟active␞" then "tab id␟title␟URL␞" per tab, then "␝".
    private static func chromiumRead(_ browser: Browser) -> String {
        """
        tell application id "\(browser.bundleId)"
            set wids to id of every window
            set acts to active tab index of every window
            set tids to id of every tab of every window
            set ts to title of every tab of every window
            set us to URL of every tab of every window
        end tell
        \(serialize)
        """
    }

    /// Safari tabs have no id, so the index stands in; `show` checks it against the URL.
    private static func safariRead(_ browser: Browser) -> String {
        """
        tell application id "\(browser.bundleId)"
            set wids to {}
            set acts to {}
            set us to {}
            set ts to {}
            -- Settings and other windows without tabs fail here and are left out.
            repeat with w in every window
                try
                    set a to index of current tab of w
                    set u to URL of every tab of w
                    set t to name of every tab of w
                    set end of wids to id of w
                    set end of acts to a
                    set end of us to u
                    set end of ts to t
                end try
            end repeat
            set tids to {}
            repeat with list_ in us
                set n to {}
                repeat with k from 1 to count of list_
                    set end of n to k
                end repeat
                set end of tids to n
            end repeat
        end tell
        \(serialize)
        """
    }

    private static let serialize = """
        set f to ASCII character 31
        set r to ASCII character 30
        set g to ASCII character 29
        set out to {}
        repeat with w from 1 to count of wids
            set end of out to ((item w of wids) as text) & f & ((item w of acts) as text) & r
            set wt to item w of tids
            set wn to item w of ts
            set wu to item w of us
            repeat with t from 1 to count of wt
                set end of out to ((item t of wt) as text) & f & ((item t of wn) as text) & f & ((item t of wu) as text) & r
            end repeat
            set end of out to g
        end repeat
        set AppleScript's text item delimiters to ""
        return out as text
        """

    /// AppleScript turns a tab with no title or address yet into "missing value".
    private static func clean(_ field: String) -> String {
        field == "missing value" ? "" : field
    }

    private static func run(_ script: String, arguments: [String] = [], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
