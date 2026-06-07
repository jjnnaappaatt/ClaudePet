import SwiftUI

/// Seam so a PNG sprite-sheet renderer can replace the pixel-matrix one later
/// without touching the animation/timing code.
protocol MascotRenderer {
    func draw(_ frame: [[UInt8]], in ctx: inout GraphicsContext, size: CGSize)
}
