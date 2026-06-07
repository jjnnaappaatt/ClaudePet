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
    func fitToContent() {
        let size = content.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        var frame = panel.frame
        let topY = frame.maxY
        frame.size = size
        frame.origin.y = topY - size.height
        panel.setFrame(frame, display: true)
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
