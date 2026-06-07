import SwiftUI
import ClaudePetCore

/// The ambient pixel-art Claude mascot. Animates on its own timeline (4–6 fps),
/// pauses when occluded / Reduce Motion / Low Power, and renders crisp pixels.
struct MascotView: View {
    var size: CGFloat = 48

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PanelVisibility.self) private var visibility: PanelVisibility?
    @State private var engine = MascotEngine()
    private let renderer = PixelMatrixRenderer()

    private var isPaused: Bool { !(visibility?.isVisible ?? true) || reduceMotion }

    var body: some View {
        let fps = ProcessInfo.processInfo.isLowPowerModeEnabled ? 2.0 : 6.0
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: isPaused)) { context in
            Canvas { ctx, sz in
                if isPaused {
                    renderer.draw(MascotArt.resting, in: &ctx, size: sz)   // safe resting frame
                } else {
                    engine.advance(to: context.date)
                    renderer.draw(engine.currentFrame, in: &ctx, size: sz)
                }
            }
            .onChange(of: isPaused) { _, paused in
                if !paused { engine.resetClock() }
            }
        }
        .frame(width: size, height: size)
    }
}
