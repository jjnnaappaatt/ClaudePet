import SwiftUI

/// Draws a frame matrix as crisp square pixels: one filled rect per pixel,
/// `antialiased: false` + integer scale + floored origins (no blurry seams).
struct PixelMatrixRenderer: MascotRenderer {
    func draw(_ frame: [[UInt8]], in ctx: inout GraphicsContext, size: CGSize) {
        let rows = frame.count
        let cols = frame.first?.count ?? 0
        guard rows > 0, cols > 0 else { return }

        let scale = max(1, floor(min(size.width / CGFloat(cols), size.height / CGFloat(rows))))
        let ox = floor((size.width - scale * CGFloat(cols)) / 2)
        let oy = floor((size.height - scale * CGFloat(rows)) / 2)

        for r in 0..<rows {
            for c in 0..<cols {
                let i = frame[r][c]
                if i == 0 { continue }
                guard let color = Pal.colors[i] else { continue }
                let rect = CGRect(x: ox + CGFloat(c) * scale, y: oy + CGFloat(r) * scale,
                                  width: scale, height: scale)
                ctx.fill(Path(rect), with: .color(color),
                         style: FillStyle(eoFill: false, antialiased: false))
            }
        }
    }
}
