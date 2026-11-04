import AppKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains(TextRecognizer.helperFlag) {
            TextRecognizer.runAsHelper()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
