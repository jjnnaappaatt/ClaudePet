import Foundation
import Observation

/// Tracks whether the floating panel is actually visible (not fully occluded),
/// so the mascot animation can pause to save CPU/energy.
@MainActor
@Observable
final class PanelVisibility {
    var isVisible = true
}
