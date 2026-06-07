import SwiftUI
import ClaudePetCore

/// Debug-only: renders every mascot frame large so the pixel art can be eyeballed.
struct MascotPreviewSheet: View {
    private let renderer = PixelMatrixRenderer()
    private let frames: [(String, [[UInt8]])] = [
        ("sit", MascotArt.sit),
        ("blink", MascotArt.blink),
        ("walkA", MascotArt.walkA),
        ("walkB", MascotArt.walkB),
        ("hop", MascotArt.hop),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(frames, id: \.0) { name, frame in
                VStack(spacing: 4) {
                    Canvas { ctx, size in renderer.draw(frame, in: &ctx, size: size) }
                        .frame(width: 88, height: 88)
                        .background(Color.black.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.15)))
                    Text(name).font(.system(size: 11)).foregroundStyle(.white)
                }
            }
        }
        .padding(14)
    }
}
