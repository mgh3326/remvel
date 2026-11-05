import AppKit

/// Desktops (Spaces) through SkyLight's window-management bridge, the one way to move a window
/// between Spaces with SIP on since macOS 15 (Loop does the same). Private and looked up at run time:
/// every call returns nil when the classes are gone, and callers treat that as "not supported".
enum Spaces {
    struct Desktop: Equatable {
        let id: UInt64
    }

    /// The window's display's desktops, left to right, and the Space the window is on now.
    /// Full-screen apps' Spaces are left out: macOS cannot put another window there,
    /// but a window shown over one (such as a panel) can still be sent to a desktop.
    static func desktops(around window: CGWindowID) -> (all: [Desktop], current: Desktop)? {
        guard let current = space(of: window),
              let displays = perform(make("SLSBridgedCopyManagedDisplaySpacesOperation"))?
                .value(forKey: "propertyListArray") as? [NSDictionary]
        else { return nil }
        for display in displays {
            let spaces = display["Spaces"] as? [NSDictionary] ?? []
            guard spaces.contains(where: { ($0["ManagedSpaceID"] as? UInt64) == current }) else { continue }
            let desktops = spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { ($0["ManagedSpaceID"] as? UInt64).map(Desktop.init) }
            return (desktops, Desktop(id: current))
        }
        return nil
    }

    static func space(of window: CGWindowID) -> UInt64? {
        typealias Init = @convention(c) (AnyObject, Selector, Int32, NSArray) -> AnyObject?
        guard let send, let op = alloc("SLSBridgedCopySpacesForWindowsOperation") else { return nil }
        // 7: every managed Space the window is on.
        let made = unsafeBitCast(send, to: Init.self)(op, NSSelectorFromString("initWithOptions:windows:"), 7, [NSNumber(value: window)])
        return (perform(made)?.value(forKey: "numbers") as? [NSNumber])?.first?.uint64Value
    }

    /// Asks for the move; the bridge may quietly do nothing, so check `space(of:)` afterwards.
    static func move(_ window: CGWindowID, to desktop: Desktop) {
        typealias Init = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        guard let send, let op = alloc("SLSBridgedMoveWindowsToManagedSpaceOperation") else { return }
        let made = unsafeBitCast(send, to: Init.self)(op, NSSelectorFromString("initWithWindows:spaceID:"), [NSNumber(value: window)], desktop.id)
        _ = perform(made)
    }

    private static let send: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY).flatMap { dlsym($0, "objc_msgSend") }

    private static func make(_ name: String) -> AnyObject? {
        (NSClassFromString(name) as? NSObject.Type)?.init()
    }

    private static func alloc(_ name: String) -> AnyObject? {
        typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let send, let cls = NSClassFromString(name) else { return nil }
        return unsafeBitCast(send, to: Alloc.self)(cls, NSSelectorFromString("alloc"))
    }

    private static func perform(_ operation: AnyObject?) -> AnyObject? {
        typealias Perform = @convention(c) (AnyObject, Selector) -> AnyObject?
        let selector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let send, let operation, operation.responds(to: selector) else { return nil }
        return unsafeBitCast(send, to: Perform.self)(operation, selector)
    }
}
