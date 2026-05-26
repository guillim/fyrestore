import SwiftUI
import AppKit

@main
struct FyrestoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .frame(minWidth: 900, minHeight: 560)
                .background(WindowAccessor(autosaveName: "FyrestoreMainWindow"))
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Bridges to the underlying NSWindow so we can register a frame-autosave name.
/// macOS automatically saves the window's frame to UserDefaults under
/// "NSWindow Frame <name>" and restores it on subsequent launches.
private struct WindowAccessor: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window doesn't exist yet at make-time; defer to the next tick.
        DispatchQueue.main.async {
            applyAutosave(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // If the autosave hasn't been wired up yet (e.g. the window only just became
        // available), try again — cheap idempotent operation.
        if nsView.window?.frameAutosaveName != autosaveName {
            applyAutosave(to: nsView.window)
        }
    }

    private func applyAutosave(to window: NSWindow?) {
        guard let window = window else { return }
        // Setting the name registers the autosave; setFrameUsingName then explicitly
        // restores any previously-saved frame (SwiftUI may have already laid out the
        // window at its default size before this runs).
        window.setFrameAutosaveName(autosaveName)
        _ = window.setFrameUsingName(autosaveName)
    }
}

/// Forces the app to behave as a regular foreground GUI app even when launched as a bare
/// SwiftPM executable (no .app bundle). Without this, macOS leaves the window non-key,
/// so TextField never becomes first responder and keystrokes go to another app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
