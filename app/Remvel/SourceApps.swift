import AppKit

/// Names and icons of the apps items were copied from, looked up once per bundle id.
enum SourceApps {
    private static var cache: [String: (name: String, icon: NSImage)?] = [:]

    static func name(_ bundleID: String) -> String {
        lookup(bundleID)?.name ?? bundleID
    }

    static func icon(_ bundleID: String) -> NSImage? {
        lookup(bundleID)?.icon
    }

    private static func lookup(_ bundleID: String) -> (name: String, icon: NSImage)? {
        if let hit = cache[bundleID] { return hit }
        let entry = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url in
            let name = FileManager.default.displayName(atPath: url.path)
            return (name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                    icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        cache[bundleID] = entry
        return entry
    }
}
