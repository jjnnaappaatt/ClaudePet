import SwiftUI
import ClaudePetCore

/// The terrain under the pet — the **weekly** limit, drawn by the same pixel renderer as the mascot
/// and the sky so all three layers line up on one grid. Non-interactive, but not decorative: it is
/// the only place the weekly figure appears in the mascot block.
///
/// Deliberately **not** behind the "Weather effects" toggle, unlike `WeatherView`. That setting's own
/// caption describes it as "Ambient sky behind the pet"; ground isn't sky and isn't an effect — it is
/// a reading of the weekly limit that happens to be drawn rather than printed. Someone who turns the
/// ambient animation off still wants to know where their week stands.
///
/// No `TimelineView` here, unlike `MascotView` and `WeatherView`. Ground doesn't move, so there is
/// nothing to animate and nothing to pause: a plain `Canvas` redraws only when the condition changes.
/// That also means it costs nothing when the panel is occluded, without needing the visibility gate
/// the other two carry.
struct GroundView: View {
    var size: CGFloat

    @Environment(MetricsStore.self) private var metrics: MetricsStore?
    private let renderer = PixelMatrixRenderer()

    private var condition: GroundCondition { metrics?.groundCondition ?? .lush }

    var body: some View {
        Canvas { ctx, sz in
            renderer.draw(GroundArt.matrix(for: condition), in: &ctx, size: sz)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)        // never steals clicks/drag from the widget
        .accessibilityHidden(true)      // decorative; the block's own help text says what it means
    }
}
