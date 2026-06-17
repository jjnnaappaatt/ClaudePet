import SwiftUI
import ClaudePetCore

/// The ambient weather behind the pet — sun, clouds, rain and lightning that follow your usage,
/// drawn by the same pixel renderer as the mascot so the two layers line up. Purely decorative and
/// non-interactive. Pauses on occlusion / Reduce Motion / Low Power, exactly like `MascotView`.
///
/// The `WeatherEngine` is injected (owned by the parent) so the parent can be the single point that
/// drains one-shot events and fans them out — to this ambient engine and to the full-card overlay.
struct WeatherView: View {
    var width: CGFloat
    var height: CGFloat
    var engine: WeatherEngine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PanelVisibility.self) private var visibility: PanelVisibility?
    @Environment(MetricsStore.self) private var metrics: MetricsStore?
    private let renderer = PixelMatrixRenderer()

    private var isPaused: Bool { !(visibility?.isVisible ?? true) || reduceMotion }
    private var condition: WeatherCondition { metrics?.weatherCondition ?? .clearSky }

    var body: some View {
        let fps = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2.0 : 6.0
        return TimelineView(.animation(minimumInterval: 1.0 / fps, paused: isPaused)) { context in
            Canvas { ctx, sz in
                engine.setCondition(condition)
                if isPaused {
                    renderer.draw(engine.staticFrame(for: condition), in: &ctx, size: sz)   // single still
                } else {
                    engine.advance(to: context.date)
                    renderer.draw(engine.currentFrame, in: &ctx, size: sz)
                }
            }
            .onChange(of: isPaused) { _, paused in
                if !paused { engine.resetClock() }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)        // never steals clicks/drag from the widget
        .accessibilityHidden(true)      // decorative; the mascot already announces mood
    }
}
