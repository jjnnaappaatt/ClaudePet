import Foundation
import Observation
import ClaudePetCore

/// Bridges the SwiftUI corner handles to the AppKit panel: dragging a corner
/// changes the widget scale live (which reflows fonts + auto-fits the window).
@MainActor
@Observable
final class ResizeController {
    weak var window: WindowController?
    weak var store: MetricsStore?

    static let minScale = 0.7
    static let maxScale = 2.0

    var scale: Double { store?.widgetScale ?? 1 }

    /// Any handle drag → uniform zoom of the actual content. The anchor (the side opposite
    /// the dragged grip) stays fixed, so the window grows toward the drag direction.
    func setScale(_ s: Double, anchorX: CGFloat = 0, anchorY: CGFloat = 1) {
        guard let store else { return }
        store.widgetScale = min(Self.maxScale, max(Self.minScale, s))
        window?.fitToContent(anchorFracX: anchorX, anchorFracY: anchorY)
    }

    /// Persist at drag end.
    func commit() { store?.saveConfigAndRecompute() }
}
