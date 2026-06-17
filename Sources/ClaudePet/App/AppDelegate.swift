import AppKit
import SwiftUI
import ClaudePetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: WindowController?
    private var occlusionObserver: NSObjectProtocol?
    let metrics = MetricsStore()
    let panelVisibility = PanelVisibility()
    let resizeController = ResizeController()
    private lazy var settingsWC = SettingsWindowController(metrics: metrics)

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
            if let lay = ProcessInfo.processInfo.environment["CLAUDEPET_LAYOUT"],
               let l = WidgetLayout(rawValue: lay) {
                metrics.widgetLayout = l       // verification override; leaves the user's saved choice untouched
            }
            // Debug-only: force a weather condition by faking the statusline utilization (0–100).
            if let u = ProcessInfo.processInfo.environment["CLAUDEPET_UTIL"], let util = Double(u) {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let reset = f.string(from: Date().addingTimeInterval(2 * 3600))
                let json = "{\"five_hour\":{\"utilization\":\(util),\"resets_at\":\"\(reset)\"},\"seven_day\":{\"utilization\":0,\"resets_at\":\"\(reset)\"}}"
                let path = NSTemporaryDirectory() + "cp-snap-util.json"
                try? json.write(toFile: path, atomically: true, encoding: .utf8)
                metrics.useStatuslineData = true
                metrics.statuslineCachePath = path
                metrics.recompute()
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
            .environment(resizeController)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = .intrinsicContentSize   // report SwiftUI's fitting size

        let wc = WindowController(content: hosting)
        wc.panel.setOnTop(metrics.keepOnTop)
        wc.panel.setShowOnAllSpaces(metrics.showOnAllSpaces)
        wc.show()
        windowController = wc
        resizeController.window = wc
        resizeController.store = metrics

        // Resize the panel to fit + apply window settings when config changes.
        metrics.onConfigChange = { [weak wc, weak metrics] in
            DispatchQueue.main.async {
                wc?.fitToContent()
                if let m = metrics {
                    wc?.panel.setOnTop(m.keepOnTop)
                    wc?.panel.setShowOnAllSpaces(m.showOnAllSpaces)
                }
            }
        }

        // Open Settings in a real key-capable window when the gear is tapped.
        NotificationCenter.default.addObserver(forName: .openClaudePetSettings,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWC.show() }
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

        // Debug: simulate the REAL flow — app already running as accessory, then open
        // Settings (as if the gear was clicked) and report activation/key/responder state.
        if ProcessInfo.processInfo.environment["CLAUDEPET_OPENSETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NotificationCenter.default.post(name: .openClaudePetSettings, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let key = NSApp.keyWindow
                    let frName = key?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    let msg = "diag: active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) " +
                              "keyWindow=\(key?.title ?? "nil") isKey=\(key?.isKeyWindow ?? false) " +
                              "firstResponder=\(frName)\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        metrics.stop()
    }
}
