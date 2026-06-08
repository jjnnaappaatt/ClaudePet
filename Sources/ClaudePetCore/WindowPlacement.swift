import Foundation
import CoreGraphics

/// Pure geometry for remembering the widget's position across display arrangements.
/// AppKit-free so it's unit-tested; `WindowController` supplies the live screen frames.
public enum WindowPlacement {
    /// A stable key for a set of screens. Order-independent, so the same arrangement
    /// always maps to the same key regardless of how the OS enumerates displays.
    public static func signature(for screenKeys: [String]) -> String {
        screenKeys.sorted().joined(separator: "|")
    }

    /// Keep `frame` reachable. If at least `minVisible` points show on some screen (both
    /// axes), it's left exactly where the user put it. Otherwise it's pulled fully onto the
    /// screen it overlaps most (or the first screen), so the widget can never strand itself
    /// off-screen when a monitor disconnects.
    public static func clamped(_ frame: CGRect, into visibleFrames: [CGRect],
                               minVisible: CGFloat = 40) -> CGRect {
        guard !visibleFrames.isEmpty else { return frame }

        let needX = Swift.min(minVisible, frame.width)
        let needY = Swift.min(minVisible, frame.height)
        for vf in visibleFrames {
            let i = vf.intersection(frame)
            if !i.isNull && i.width >= needX && i.height >= needY { return frame }
        }

        // Not reachable — clamp into the best-overlapping screen (else the first).
        let target = visibleFrames.max { area($0.intersection(frame)) < area($1.intersection(frame)) }
            ?? visibleFrames[0]
        var f = frame
        f.origin.x = clamp(f.minX, target.minX, Swift.max(target.minX, target.maxX - f.width))
        f.origin.y = clamp(f.minY, target.minY, Swift.max(target.minY, target.maxY - f.height))
        return f
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(v, lo), hi)
    }
}
