import SwiftUI
import AppKit

/// Eight resize grips (4 corners + 4 edge midpoints) that auto-hide — visible only while
/// you hover the widget. They live in the card's padding ring so they don't overlap content.
/// - Corners: uniform zoom (diagonal).
/// - Left/right edges: resize horizontally (window width).
/// - Top/bottom edges: resize vertically (window height).
struct ResizeHandles: View {
    var visible: Bool
    @Environment(ResizeController.self) private var resizer: ResizeController?

    @State private var startScale: Double?

    // (alignment, outward-x sign, outward-y sign)
    private let points: [(Alignment, CGFloat, CGFloat)] = [
        (.topLeading, -1, -1), (.top, 0, -1), (.topTrailing, 1, -1),
        (.leading, -1, 0),                     (.trailing, 1, 0),
        (.bottomLeading, -1, 1), (.bottom, 0, 1), (.bottomTrailing, 1, 1),
    ]

    var body: some View {
        ZStack {
            ForEach(0..<points.count, id: \.self) { i in
                let (align, sx, sy) = points[i]
                grip(sx: sx, sy: sy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
            }
        }
        .padding(2)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: visible)
        .allowsHitTesting(visible && resizer != nil)
    }

    private func grip(sx: CGFloat, sy: CGFloat) -> some View {
        let isCorner = sx != 0 && sy != 0
        // Edge grips are short bars along their edge; corner grips are square dots.
        let w: CGFloat = isCorner ? 9 : (sy == 0 ? 9 : 20)
        let h: CGFloat = isCorner ? 9 : (sy == 0 ? 20 : 9)
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Theme.claudeCoral)
            .frame(width: w, height: h)
            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: 26, height: 26)               // hit area
            .contentShape(Rectangle())
            .background(NonWindowDraggable())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        guard let resizer else { return }
                        if startScale == nil { startScale = resizer.scale }
                        let dx = Double(v.translation.width) * Double(sx)
                        let dy = Double(v.translation.height) * Double(sy)
                        // Project the drag onto this handle's outward axis (corner = both)
                        // → uniform zoom of the actual content.
                        let axes = abs(sx) + abs(sy)
                        let delta = (dx + dy) / Double(max(1, axes))
                        // Anchor the side OPPOSITE this grip so the window grows toward the drag.
                        let anchorX = CGFloat(0.5 - 0.5 * sx)   // 0=left … 1=right
                        let anchorY = CGFloat(0.5 + 0.5 * sy)   // 0=bottom … 1=top
                        resizer.setScale((startScale ?? 1) + delta / 200, anchorX: anchorX, anchorY: anchorY)
                    }
                    .onEnded { _ in startScale = nil; resizer?.commit() }
            )
    }
}

/// Transparent AppKit view whose region is NOT window-draggable, so the resize gesture
/// works even though dragging the rest of the card moves the window.
private struct NonWindowDraggable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NoMoveView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class NoMoveView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
