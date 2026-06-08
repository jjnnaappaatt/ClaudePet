import AppKit

/// Owns the FloatingPanel: builds it, sizes it to its SwiftUI content (auto-fit, no empty
/// space), restores/saves its position manually, and shows it without activating the app.
final class WindowController {
    let panel: FloatingPanel
    private let content: NSView
    private let frameKey = "ClaudePetFrame"
    private var observers: [NSObjectProtocol] = []
    static let baseWidth: CGFloat = 268

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

    // MARK: - Position persistence (size comes from content)

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            var frame = panel.frame
            frame.origin = NSRectFromString(saved).origin
            panel.setFrame(frame, display: true)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            var frame = panel.frame
            frame.origin = NSPoint(x: vf.minX + 60, y: vf.maxY - frame.height - 60)
            panel.setFrame(frame, display: true)
        }
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
    }

    private func observeMoves() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            let token = nc.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                self?.saveFrame()
            }
            observers.append(token)
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
