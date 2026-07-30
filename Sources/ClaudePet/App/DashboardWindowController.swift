import AppKit
import SwiftUI
import ClaudePetCore

extension Notification.Name {
    static let openClaudePetDashboard = Notification.Name("openClaudePetDashboard")
}

/// Hosts `DashboardView` in a real Mac window: titled, resizable, and natively full-screen capable.
///
/// Follows `SettingsWindowController`'s proven shape for a real window in this dockless app, with
/// three things that pane doesn't need:
/// - `.resizable` + `.fullScreenPrimary`. `.resizable` is what produces the green button at all;
///   without it `toggleFullScreen` is a no-op.
/// - The View-menu item (`AppPolicy.installFullScreenMenuItem`), because SwiftUI leaves that menu
///   empty and ⌃⌘F would otherwise be dead.
/// - Its own `PanelVisibility`. Sharing the widget's would pause the dashboard's mascot whenever the
///   small widget happened to be covered — two unrelated windows, one animation gate.
@MainActor
final class DashboardWindowController {
    private var window: NSWindow?
    private let metrics: MetricsStore
    private let visibility = PanelVisibility()
    private var fullScreenMenuItem: NSMenuItem?
    private var observers: [NSObjectProtocol] = []

    /// The widget, hidden while this window is full screen — with "Show on all Spaces" on it would
    /// otherwise float on top of its own full-screen dashboard.
    weak var widgetPanel: NSWindow?
    private var widgetWasVisible = false

    init(metrics: MetricsStore) { self.metrics = metrics }

    func show() {
        if window == nil { window = build() }

        // Same two-step as Settings: for an accessory app already running, the policy change and
        // activation aren't synchronous, so ordering front in this runloop turn yields a non-key
        // window. Activate now, order front next turn.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        fullScreenMenuItem = AppPolicy.installFullScreenMenuItem()

        let win = window
        DispatchQueue.main.async {
            win?.makeKeyAndOrderFront(nil)
            win?.orderFrontRegardless()
        }
    }

    private func build() -> NSWindow {
        // The minimum has to be expressed in SwiftUI terms as well as on the window: `NSHostingView`
        // drives the window's content size limits from its root view, and `DashboardView`'s root is a
        // `GeometryReader`, which has no intrinsic size — so a window-level `contentMinSize` alone was
        // silently reset to 0×0 and the window could be dragged smaller than the layout fits at.
        let root = DashboardView()
            .frame(minWidth: DashboardView.minWidth, minHeight: DashboardView.minHeight)
            .environment(metrics)
            .environment(visibility)
        // `contentView` with the style mask set AT INIT — not `NSWindow(contentViewController:)`.
        // With a content view *controller* AppKit derives the window's minimum from that
        // controller's Auto Layout constraints and `contentMinSize` silently reads back as 0×0, so
        // the user could drag the window below the size the layout is actually verified to fit at.
        // (Setting the mask at init rather than assigning it after is the same discipline
        // `FloatingPanel` documents.)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        // No `sizingOptions = .intrinsicContentSize` here, unlike the widget's hosting view: this
        // view is layout-driven and must take its size FROM the window, not dictate it.
        win.contentView = NSHostingView(rootView: root)
        win.title = "ClaudePet"
        win.collectionBehavior.insert(.fullScreenPrimary)
        win.contentMinSize = NSSize(width: DashboardView.minWidth, height: DashboardView.minHeight)
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(Theme.windowBackground)
        win.center()
        // Safe here, unlike the widget: `WindowController`'s "don't rely on setFrameAutosaveName"
        // note is about a borderless, non-resizable panel sized from its content.
        win.setFrameAutosaveName("ClaudePetDashboard")
        // A frame saved before the minimum grew would restore too small — clamp it back.
        if win.frame.width < DashboardView.minWidth || win.frame.height < DashboardView.minHeight {
            win.setContentSize(NSSize(width: 1180, height: 820))
            win.center()
        }
        observe(win)
        return win
    }

    private func observe(_ win: NSWindow) {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification,
                                        object: win, queue: .main) { _ in
            MainActor.assumeIsolated { AppPolicy.revertToAccessory(unless: win) }
        })

        // Pause the mascot/weather when this window is hidden behind others (bitfield: use .contains).
        observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                        object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.visibility.isVisible = win.occlusionState.contains(.visible)
            }
        })

        observers.append(nc.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                        object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fullScreenMenuItem?.title = "Exit Full Screen"
                guard let self, let panel = self.widgetPanel, panel.isVisible else { return }
                self.widgetWasVisible = true
                panel.orderOut(nil)
            }
        })

        observers.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                        object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fullScreenMenuItem?.title = "Enter Full Screen"
                guard let self, self.widgetWasVisible else { return }
                self.widgetWasVisible = false
                self.widgetPanel?.orderFrontRegardless()
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
