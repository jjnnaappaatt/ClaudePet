import Foundation

/// Pixel-art-as-code mascot (16×16). Flat Claude-coral critter: a wide rounded body
/// with two side nubs, two vertical slit eyes, and two legs — matching the provided design.
public enum MascotArt {
    static let n = 16

    /// 1 = coral body, 5 = dark eye. (Other palette indices unused for this flat design.)
    static func build(eyeOpen: Bool = true, legPhase: Int = 0, yOffset: Int = 0) -> [[UInt8]] {
        var g = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: n)
        func set(_ r: Int, _ c: Int, _ v: UInt8) {
            let rr = r - yOffset
            guard rr >= 0, rr < n, c >= 0, c < n else { return }
            g[rr][c] = v
        }

        // Body: rounded rectangle rows 4...10, cols 3...12 (corners trimmed for roundness).
        for r in 4...10 {
            for c in 3...12 {
                if (r == 4 || r == 10) && (c == 3 || c == 12) { continue }
                set(r, c, 1)
            }
        }
        // Side nubs (ears): rows 6...7, sticking out at cols 1-2 and 13-14.
        for r in 6...7 { set(r, 1, 1); set(r, 2, 1); set(r, 13, 1); set(r, 14, 1) }

        // Eyes: vertical slits at cols 6 and 9, rows 6...7.
        if eyeOpen { for r in 6...7 { set(r, 6, 5); set(r, 9, 5) } }

        // Legs at cols 5-6 (left) and 9-10 (right); alternate for walk.
        let up = 11, down = 12
        func leg(_ c0: Int, planted: Bool) {
            set(up, c0, 1); set(up, c0 + 1, 1)
            if planted { set(down, c0, 1); set(down, c0 + 1, 1) }
        }
        switch legPhase {
        case 1: leg(5, planted: true);  leg(9, planted: false)
        case 2: leg(5, planted: false); leg(9, planted: true)
        default: leg(5, planted: true); leg(9, planted: true)
        }

        return g
    }

    public static let sit     = build()
    public static let blink   = build(eyeOpen: false)
    public static let walkA   = build(legPhase: 1)
    public static let walkB   = build(legPhase: 2)
    public static let hop     = build(yOffset: 2)
    public static let resting = sit
}
