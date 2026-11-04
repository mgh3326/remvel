import AppKit
import Security

/// Updates from the rolling `nightly` GitHub release that CI publishes for every build of main.
/// An update is installed only if it satisfies the running app's designated requirement,
/// i.e. it is signed with the same certificate, so a tampered download is refused.
final class Updater {
    struct Release {
        let build: Int
        let url: URL
    }

    static let shared = Updater()
    static let releaseAPI = URL(string: "https://api.github.com/repos/mgh3326/remvel/releases/tags/nightly")!
    static let checkInterval: TimeInterval = 6 * 60 * 60

    /// Called on the main queue whenever `available` or `installing` changes.
    var onChange: (() -> Void)?
    private(set) var available: Release?
    private(set) var installing = false

    /// CI stamps the run number; local builds are 0 and never update themselves.
    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    var isUpdatable: Bool { currentBuild > 0 }

    private var timer: Timer?

    func start() {
        guard isUpdatable else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func check(completion: ((Release?) -> Void)? = nil) {
        var request = URLRequest(url: Self.releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let release = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                self.available = release.flatMap { $0.build > self.currentBuild ? $0 : nil }
                self.onChange?()
                completion?(self.available)
            }
        }.resume()
    }

    /// Finds the newest `Remvel-<build>.zip` asset; while CI swaps assets there can be two.
    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        return assets.compactMap { asset -> Release? in
            guard let name = asset["name"] as? String, name.hasPrefix("Remvel-"), name.hasSuffix(".zip"),
                  let build = Int(name.dropFirst("Remvel-".count).dropLast(".zip".count)),
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init) else { return nil }
            return Release(build: build, url: url)
        }.max { $0.build < $1.build }
    }

    func install(_ release: Release) {
        guard !installing else { return }
        installing = true
        onChange?()
        URLSession.shared.downloadTask(with: release.url) { [weak self] zip, _, error in
            let result = Result { () -> URL in
                guard let zip else { throw UpdateError("Download failed: \(error?.localizedDescription ?? "no data")") }
                return try Self.unpackAndVerify(zip)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let app): self?.replace(with: app)
                case .failure(let error): self?.fail(error)
                }
            }
        }.resume()
    }

    private static func unpackAndVerify(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "RemvelUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = dir.appending(path: "Remvel.app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("The download is not a Remvel build.")
        }
        try verifySameSigner(app)
        return app
    }

    private static func verifySameSigner(_ app: URL) throws {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError("Could not read code signatures.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw UpdateError("The update is not signed like this copy of Remvel, so it was not installed.")
        }
    }

    /// A detached shell waits for Remvel to quit, swaps the bundle, and relaunches it.
    private func replace(with app: URL) {
        let target = Bundle.main.bundleURL.path
        let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "$1" && ditto "$2" "$1" && xattr -dr com.apple.quarantine "$1"
            open "$1"
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "sh", target, app.path]
        do {
            try shell.run()
            NSApp.terminate(nil)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Swift.Error) {
        installing = false
        onChange?()
        NSLog("Remvel: update failed: \(error)")
        let alert = NSAlert()
        alert.messageText = "Remvel could not update"
        alert.informativeText = (error as? UpdateError)?.message ?? error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private struct UpdateError: Swift.Error {
    let message: String
    init(_ message: String) { self.message = message }
}
