import AppKit
import SwiftUI
import ClaudePetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: WindowController?
    private var occlusionObserver: NSObjectProtocol?
    let metrics = MetricsStore()
    let panelVisibility = PanelVisibility()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug-only: render the 1024px app-icon master (transparent margins).
        if let iconPath = ProcessInfo.processInfo.environment["CLAUDEPET_ICON"] {
            let r = ImageRenderer(content: AppIconView())
            r.scale = 1
            r.isOpaque = false
            if let cg = r.cgImage,
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: iconPath))
                FileHandle.standardError.write(Data("icon: wrote \(iconPath)\n".utf8))
            }
            NSApp.terminate(nil)
            return
        }

        // Debug-only: render the Settings view.
        if let settingsPath = ProcessInfo.processInfo.environment["CLAUDEPET_SETTINGS"] {
            Snapshot.render(SettingsView().environment(metrics), to: settingsPath)
            NSApp.terminate(nil)
            return
        }

        // Debug-only: render all mascot frames large for visual inspection.
        if let mascotPath = ProcessInfo.processInfo.environment["CLAUDEPET_MASCOT"] {
            Snapshot.render(MascotPreviewSheet(), to: mascotPath)
            NSApp.terminate(nil)
            return
        }

        // Permission-free UI verification: render the real view to a PNG and exit.
        if let snapPath = ProcessInfo.processInfo.environment["CLAUDEPET_SNAPSHOT"] {
            if ProcessInfo.processInfo.environment["CLAUDEPET_REAL"] != nil {
                metrics.loadFromDisk()       // real ~/.claude data
            } else {
                metrics.loadSampleForPreview()
            }
            if let s = ProcessInfo.processInfo.environment["CLAUDEPET_SCALE"], let v = Double(s) {
                metrics.widgetScale = v
            }
            Snapshot.render(ContentView().environment(metrics).environment(panelVisibility), to: snapPath)
            NSApp.terminate(nil)
            return
        }

        // Dockless agent app: no Dock icon, no app menu, but panels still show.
        NSApp.setActivationPolicy(.accessory)

        let root = ContentView()
            .environment(metrics)
            .environment(panelVisibility)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = .intrinsicContentSize   // report SwiftUI's fitting size

        let wc = WindowController(content: hosting)
        wc.show()
        windowController = wc

        // Resize the panel to fit when the widget scale (or content) changes.
        metrics.onConfigChange = { [weak wc] in
            DispatchQueue.main.async { wc?.fitToContent() }
        }

        // Pause the mascot when the panel is fully occluded (bitfield: use .contains).
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: wc.panel, queue: .main
        ) { [weak panelVisibility] note in
            guard let win = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                panelVisibility?.isVisible = win.occlusionState.contains(.visible)
            }
        }

        // Verification-only heartbeat: write metrics to a file on each recompute.
        if let hb = ProcessInfo.processInfo.environment["CLAUDEPET_HEARTBEAT"] {
            metrics.onRecompute = { [weak metrics] in
                guard let m = metrics else { return }
                let obj: [String: Any] = [
                    "lastUpdated": m.lastUpdated?.timeIntervalSince1970 ?? 0,
                    "todayWork": m.today.workTokens,
                    "todayTotal": m.today.totalTokens,
                ]
                if let d = try? JSONSerialization.data(withJSONObject: obj) {
                    try? d.write(to: URL(fileURLWithPath: hb))
                }
            }
        }

        metrics.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        metrics.stop()
    }
}
