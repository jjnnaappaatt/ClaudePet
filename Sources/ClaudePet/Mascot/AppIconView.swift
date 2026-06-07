import SwiftUI
import ClaudePetCore

/// The app icon: the pixel mascot on a dark rounded "squircle", drawn at 1024pt.
struct AppIconView: View {
    private let renderer = PixelMatrixRenderer()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.20, green: 0.16, blue: 0.14),
                                 Color(red: 0.09, green: 0.08, blue: 0.08)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 6)
                )
                .frame(width: 832, height: 832)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)

            Canvas { ctx, size in renderer.draw(MascotArt.sit, in: &ctx, size: size) }
                .frame(width: 560, height: 560)
        }
        .frame(width: 1024, height: 1024)
    }
}
