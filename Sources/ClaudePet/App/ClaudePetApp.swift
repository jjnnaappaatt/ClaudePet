import SwiftUI

@main
struct ClaudePetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The floating widget itself is an NSPanel built in AppDelegate.
        // This Settings scene provides the Cmd-, settings window (filled in at M7).
        Settings {
            SettingsView()
                .environment(appDelegate.metrics)
        }
    }
}
