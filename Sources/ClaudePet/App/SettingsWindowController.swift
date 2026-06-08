import AppKit
import SwiftUI
import ClaudePetCore

extension Notification.Name {
    static let openClaudePetSettings = Notification.Name("openClaudePetSettings")
}

/// Hosts Settings in a real, key-capable window. (A popover from the non-activating
/// widget panel can't receive keyboard input, so text fields wouldn't accept typing.)
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let metrics: MetricsStore

    init(metrics: MetricsStore) { self.metrics = metrics }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environment(metrics))
            let win = NSWindow(contentViewController: host)
            win.title = "ClaudePet Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.titlebarAppearsTransparent = false
            // Back to dockless agent once Settings closes.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: win, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
            window = win
        }
        // For an accessory app opened WHILE running, the policy change + activation aren't
        // synchronous — ordering the window front in the same runloop turn yields a
        // non-key window (so text fields can't type). Activate now, order front next turn.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)        // still functional + more reliable than no-arg
        let win = window
        DispatchQueue.main.async {
            win?.center()
            win?.makeKeyAndOrderFront(nil)
            win?.orderFrontRegardless()
        }
    }
}
