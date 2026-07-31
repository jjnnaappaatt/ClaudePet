import SwiftUI
import ClaudePetCore

/// The ambient pixel-art Claude mascot. Its mood follows usage (`MetricsStore.mascotEmotion`):
/// happy when you have headroom, worried/alarmed near a limit, asleep when idle. Renders a
/// user-supplied PNG for the mood if one was dropped into Resources/Mascot, else animates the
/// built-in pixel art. Pauses when occluded / Reduce Motion / Low Power.
struct MascotView: View {
    var size: CGFloat = 48

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PanelVisibility.self) private var visibility: PanelVisibility?
    @Environment(MetricsStore.self) private var metrics: MetricsStore?
    @State private var engine = MascotEngine()
    private let renderer = PixelMatrixRenderer()

    private var isPaused: Bool { !(visibility?.isVisible ?? true) || reduceMotion }
    private var emotion: MascotEmotion { metrics?.mascotEmotion ?? .neutral }

    var body: some View {
        Group {
            if let img = MascotAssets.image(for: emotion) {
                img.resizable().interpolation(.none).scaledToFit()   // user-supplied art
            } else {
                codeDrawn                                            // built-in pixel art
            }
        }
        .frame(width: size, height: size)
        // The FULL scene description, not just this layer's mood. An inner `.help` wins over an outer
        // one wherever it sits, and the pet covers nearly the whole mascot block — so putting only
        // "Mood: happy" here meant the explanation of what the sky and ground mean was unreachable
        // except in the few pixels of margin around the sprite. Falls back when there's no store
        // (previews, the mascot sheet).
        .help(metrics?.petSceneDescription ?? "Mood: \(emotion.rawValue)")
    }

    private var codeDrawn: some View {
        let fps = AnimationRate.current
        return TimelineView(.animation(minimumInterval: 1.0 / fps, paused: isPaused)) { context in
            Canvas { ctx, sz in
                if isPaused {
                    renderer.draw(MascotArt.face(emotion), in: &ctx, size: sz)   // static mood face
                } else {
                    engine.setEmotion(emotion)
                    engine.advance(to: context.date)
                    renderer.draw(engine.currentFrame, in: &ctx, size: sz)
                }
            }
            .onChange(of: isPaused) { _, paused in
                if !paused { engine.resetClock() }
            }
        }
    }
}
