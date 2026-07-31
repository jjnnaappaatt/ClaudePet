import SwiftUI
import ClaudePetCore

/// Debug-only (`CLAUDEPET_MASCOT`): every mood, sky and ground state at once, large enough to check
/// the pixel art by eye.
///
/// It exists for two specific failure modes that only show up side by side. **Moods that collide** —
/// at 16×16 with a fixed set of eye poses, two moods can end up drawing the same face; the row here
/// is what catches that. And **layers that overlap** — the ground row is rendered over a pet
/// silhouette so ground pixels straying up into the feet are visible immediately, rather than only
/// in the shipped widget.
struct MascotPreviewSheet: View {
    private let renderer = PixelMatrixRenderer()
    private let engine = WeatherEngine()

    private var idle: [(String, [[UInt8]])] {
        [("sit", MascotArt.sit), ("blink", MascotArt.blink),
         ("walkA", MascotArt.walkA), ("walkB", MascotArt.walkB),
         ("hop", MascotArt.hop), ("glanceL", MascotArt.glanceL), ("glanceR", MascotArt.glanceR)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("moods — the 5h session",
                MascotEmotion.allCases.map { ($0.rawValue, MascotArt.face($0)) })
            row("skies — derived from the mood, so they follow the session too",
                WeatherCondition.allCases.map { ($0.rawValue, engine.staticFrame(for: $0)) })
            row("ground — the weekly limit (pet drawn over it, to check for overlap)",
                GroundCondition.allCases.map { ($0.rawValue, $0) })
            row("idle frames", idle)
        }
        .padding(14)
    }

    private func row(_ title: String, _ items: [(String, [[UInt8]])]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { name, frame in
                    cell(name) { ctx, size in renderer.draw(frame, in: &ctx, size: size) }
                }
            }
        }
    }

    /// Ground gets the pet composited on top — the overlap check is the whole point of showing it.
    private func row(_ title: String, _ items: [(String, GroundCondition)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { name, condition in
                    cell(name) { ctx, size in
                        renderer.draw(GroundArt.matrix(for: condition), in: &ctx, size: size)
                        renderer.draw(MascotArt.sit, in: &ctx, size: size)
                    }
                }
            }
        }
    }

    private func cell(_ name: String,
                      _ draw: @escaping (inout GraphicsContext, CGSize) -> Void) -> some View {
        VStack(spacing: 3) {
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: 84, height: 84)
                .background(Color.black.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.15)))
            Text(name).font(.system(size: 10)).foregroundStyle(.white)
        }
    }
}
