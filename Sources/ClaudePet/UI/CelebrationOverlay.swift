import SwiftUI
import ClaudePetCore

/// A brief, transient, non-interactive celebration drawn across the whole card for the two rare
/// one-shot weather moments — confetti when a fresh 5-hour window opens, a lightning flash when
/// usage crosses into the danger zone. Each instance animates once then calls `onDone` to remove
/// itself, so the everyday dense layout is never disturbed. Skipped entirely under Reduce Motion
/// (the parent never spawns one).
struct CelebrationOverlay: View {
    let kind: WeatherEvent
    let onDone: () -> Void

    var body: some View {
        Group {
            switch kind {
            case .confetti:        ConfettiBurst()
            case .lightningStrike: LightningFlash()
            }
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(nanoseconds: kind == .confetti ? 1_700_000_000 : 650_000_000)
            onDone()
        }
    }
}

/// Colorful pieces that rain down across the card once and fade as they fall.
private struct ConfettiBurst: View {
    private struct Piece: Identifiable {
        let id = UUID()
        let x: CGFloat          // 0…1 across the width
        let delay: Double
        let drift: CGFloat
        let size: CGFloat
        let color: Color
        let spin: Double
    }

    @State private var fall = false
    private let pieces: [Piece]

    init() {
        let palette: [Color] = [
            Theme.claudeCoral, Theme.highlight,
            Color(red: 0.36, green: 0.80, blue: 0.74),   // teal
            Color(red: 0.99, green: 0.82, blue: 0.36),   // gold
            .white,
        ]
        pieces = (0..<34).map { _ in
            Piece(x: .random(in: 0...1), delay: .random(in: 0...0.35),
                  drift: .random(in: -26...26), size: .random(in: 4...8),
                  color: palette.randomElement()!, spin: .random(in: -200...200))
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { p in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(p.color)
                        .frame(width: p.size, height: p.size * 1.6)
                        .rotationEffect(.degrees(fall ? p.spin : 0))
                        .position(x: p.x * geo.size.width + (fall ? p.drift : 0),
                                  y: fall ? geo.size.height + 14 : -14)
                        .opacity(fall ? 0 : 1)
                        .animation(.easeIn(duration: 1.3).delay(p.delay), value: fall)
                }
            }
        }
        .onAppear { fall = true }
    }
}

/// A quick double-flash that brightens the whole card, like a lightning strike.
private struct LightningFlash: View {
    var body: some View {
        Rectangle()
            .fill(Color(red: 1.0, green: 0.97, blue: 0.82))
            .blendMode(.plusLighter)
            .keyframeAnimator(initialValue: 0.0) { content, value in
                content.opacity(value)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0.55, duration: 0.06)
                    LinearKeyframe(0.0,  duration: 0.10)
                    LinearKeyframe(0.42, duration: 0.06)
                    LinearKeyframe(0.0,  duration: 0.22)
                }
            }
    }
}
