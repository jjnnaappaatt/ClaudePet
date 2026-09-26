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
        pendingAnchor = (anchorFracX, anchorFracY)
        applyFit(anchorFracX: anchorFracX, anchorFracY: anchorFracY)
    }

    /// The content's size changed underneath us (`FittingHostingView`) — the first scan landing, a
    /// Codex row appearing, a grip's new scale propagating. Refit, keeping whatever anchor the last
    /// explicit fit asked for.
    ///
    /// Why carry the anchor over: a grip's `fitToContent` runs synchronously, before SwiftUI has
    /// propagated the new scale, so it reads the OLD size and the real growth arrives here a moment
    /// later. Refitting that top-left would pin a side grip's drag (anchored on the vertical centre)
    /// to the top instead. Consumed once, so a later scan-driven refit is top-left again.
    ///
    /// Side grips still don't hold their centre today, and not because of this: the `Settings`
    /// scene builds `SettingsView` at launch, so its scale slider's `.onChange` → `persist()` →
    /// `onConfigChange` → a default top-left `fitToContent()` fires on every grip event. Measured
    /// identical with this refit switched off (centre moved either way). Pre-existing; when that
    /// path is fixed, this hand-off is what keeps the refit from reintroducing the same drift.
    func refitToContent() {
        let a = pendingAnchor ?? (0, 1)
        pendingAnchor = nil
        applyFit(anchorFracX: a.x, anchorFracY: a.y)
    }

    private var pendingAnchor: (x: CGFloat, y: CGFloat)?

    private func applyFit(anchorFracX: CGFloat, anchorFracY: CGFloat) {
        let size = content.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let old = panel.frame
        // A no-op when nothing moved: most size invalidations don't change the size. Within a point
        // because `fittingSize` is fractional and the frame lands on the backing-pixel grid (427.x
        // against 428).
        if abs(size.width - old.width) < 1, abs(size.height - old.height) < 1 { return }
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
