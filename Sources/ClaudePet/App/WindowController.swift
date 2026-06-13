import AppKit
import ClaudePetCore

/// Owns the FloatingPanel: builds it, sizes it to its SwiftUI content (auto-fit, no empty
/// space), restores/saves its position manually, and shows it without activating the app.
///
/// Position is remembered PER display arrangement: the laptop alone, the laptop + a given
/// external monitor, etc. each keep their own spot, so plugging a monitor in/out restores
/// the widget to where it was on that setup. If a saved spot lands off every current screen
/// (monitor unplugged), it's pulled back on-screen so the widget never disappears.
final class WindowController {
    let panel: FloatingPanel
    private let content: NSView
    private let framesKey = "ClaudePetFrames"     // [arrangement signature: NSStringFromRect]
    private let legacyKey = "ClaudePetFrame"       // pre-multi-display single position (migrated)
    private var observers: [NSObjectProtocol] = []
    private var isRestoring = false                // suppress saves while we reposition
    static let baseWidth: CGFloat = 520

    init(content: NSView) {
        self.content = content
        let initial = NSRect(x: 0, y: 0, width: Self.baseWidth, height: 240)
        panel = FloatingPanel(contentRect: initial)
        panel.contentView = content
        fitToContent()
        restorePosition()
        observeMoves()
    }

    func show() { panel.orderFrontRegardless() }

    /// Resize the panel to the content's fitting size, keeping the top-left corner anchored.
    /// Resize to the content's fitting size, keeping the anchor point fixed.
    /// anchorFracX: 0 = left edge, 1 = right edge.  anchorFracY: 0 = bottom, 1 = top.
    /// Default (0, 1) = top-left anchored (used for settings/slider changes). Resize
    /// handles pass the side OPPOSITE the grip so the window grows toward the drag.
    func fitToContent(anchorFracX: CGFloat = 0, anchorFracY: CGFloat = 1) {
        let size = content.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let old = panel.frame
        let anchorX = old.minX + anchorFracX * old.width
        let anchorY = old.minY + anchorFracY * old.height
        let newX = anchorX - anchorFracX * size.width
        let newY = anchorY - anchorFracY * size.height
        panel.setFrame(NSRect(x: newX, y: newY, width: size.width, height: size.height), display: true)
    }

    // MARK: - Position persistence (size comes from content; origin per arrangement)

    /// A stable key for the current set of displays: each screen's id + geometry, so a
    /// rearranged or different-resolution setup is treated as its own arrangement.
    private func currentSignature() -> String {
        let keys = NSScreen.screens.map { s -> String in
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
            let f = s.frame
            return "\(num):\(Int(f.width))x\(Int(f.height))@\(Int(f.minX)),\(Int(f.minY))"
        }
        return WindowPlacement.signature(for: keys)
    }

    private func visibleFrames() -> [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    private func loadFrames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: framesKey) as? [String: String] ?? [:]
    }

    /// Place the panel for the current arrangement: its saved spot (migrating the old
    /// single-position key on first run), else a sensible top-left default — then clamp
    /// on-screen so an unplugged monitor can't strand it. Persists the resolved spot.
    private func restorePosition() {
        let sig = currentSignature()
        var frames = loadFrames()
        var frame = panel.frame   // size already set by fitToContent

        if let saved = frames[sig] ?? UserDefaults.standard.string(forKey: legacyKey) {
            frame.origin = NSRectFromString(saved).origin
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            frame.origin = NSPoint(x: vf.minX + 60, y: vf.maxY - frame.height - 60)
        }

        frame = WindowPlacement.clamped(frame, into: visibleFrames())
        isRestoring = true
        panel.setFrame(frame, display: true)
        isRestoring = false

        frames[sig] = NSStringFromRect(panel.frame)
        UserDefaults.standard.set(frames, forKey: framesKey)
    }

    private func saveFrame() {
        guard !isRestoring else { return }
        var frames = loadFrames()
        frames[currentSignature()] = NSStringFromRect(panel.frame)
        UserDefaults.standard.set(frames, forKey: framesKey)
    }

    private func observeMoves() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            let token = nc.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                self?.saveFrame()
            }
            observers.append(token)
        }
        // Monitor plugged in / out, resolution or arrangement change: restore this
        // arrangement's remembered spot (and rescue an off-screen window). Defer so the
        // display layout has settled before we read screen frames.
        let screenToken = nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.restorePosition() }
        }
        observers.append(screenToken)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
