import AppKit
import SwiftUI

/// Explains the Accessibility permission, which Remvel needs to send ⌘V for the user.
/// Shown on first launch and whenever a paste fails for lack of it; closes itself once granted.
final class Onboarding {
    static let shared = Onboarding()

    private var window: NSWindow?
    private var timer: Timer?

    func show() {
        guard !AXIsProcessTrusted() else { return }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AccessibilityView()))
            window.title = "Remvel"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.window?.close()
        }
    }

    static func openAccessibilitySettings() {
        // Adds Remvel to the list so the user only has to flip the switch.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AccessibilityView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Let Remvel paste for you")
                .font(.title2.bold())
            Text("""
                Remvel records your clipboard without any permission. To paste the item you pick \
                straight into the app you were using, it needs Accessibility access to press ⌘V for you.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Without it, Remvel copies the item and you press ⌘V yourself.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button("Open Accessibility Settings") {
                Onboarding.openAccessibilitySettings()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 420)
    }
}
