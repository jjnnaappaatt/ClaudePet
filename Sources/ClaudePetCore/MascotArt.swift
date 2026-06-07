import Foundation

/// Pixel-art-as-code: each frame is a 16×16 matrix of palette indices, generated
/// procedurally so the sunburst stays symmetric and animation params are easy to tweak.
public enum MascotArt {
    static let n = 16

    struct Params {
        var eyeOpen = true
        var yOffset = 0        // shift whole sprite up (hop)
        var footPhase = 0      // 0 together, 1 left-fwd, 2 right-fwd
        var mouthOpen = false
    }

    static func build(_ p: Params) -> [[UInt8]] {
        var g = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: n)
        let cx = 7.5
        let cy = 8.2 - Double(p.yOffset)
        let R = 4.4

        func plot(_ x: Int, _ y: Int, _ v: UInt8) {
            guard x >= 0, x < n, y >= 0, y < n else { return }
            g[y][x] = v
        }

        // 1) sunburst rays: up, left, right, 4 diagonals (bottom is left for feet)
        let dirs: [(Double, Double)] = [
            (0, -1), (-1, 0), (1, 0),
            (-0.72, -0.72), (0.72, -0.72), (-0.72, 0.72), (0.72, 0.72),
        ]
        for (dx, dy) in dirs {
            for t in stride(from: R + 0.3, through: R + 2.1, by: 0.5) {
                plot(Int((cx + dx * t).rounded()), Int((cy + dy * t).rounded()), 1)
            }
        }

        // 2) body disc
        for y in 0..<n { for x in 0..<n {
            if hypot(Double(x) - cx, Double(y) - cy) <= R { g[y][x] = 1 }
        }}

        // 3) belly highlight (lower-center)
        for y in 0..<n { for x in 0..<n {
            if g[y][x] == 1, hypot(Double(x) - cx, Double(y) - (cy + 1.7)) <= R - 2.3 { g[y][x] = 2 }
        }}

        // 4) outline: clear cells 4-adjacent to body/ray
        let base = g
        for y in 0..<n { for x in 0..<n where base[y][x] == 0 {
            for (ax, ay) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + ax, ny = y + ay
                if nx >= 0, nx < n, ny >= 0, ny < n, base[ny][nx] == 1 || base[ny][nx] == 2 {
                    g[y][x] = 3; break
                }
            }
        }}

        // 5) eyes (symmetric around center)
        let eyeY = Int((cy - 0.6).rounded())
        let lxe = 6, rxe = 9
        if p.eyeOpen {
            for ex in [lxe, rxe] {
                plot(ex, eyeY, 5)            // pupil
                plot(ex, eyeY - 1, 4)        // sparkle above
            }
        } else {
            // closed: a clear dark dash, no sparkle
            for ex in [lxe, rxe] {
                plot(ex - 1, eyeY, 3); plot(ex, eyeY, 3); plot(ex + 1, eyeY, 3)
            }
        }

        // 6) mouth
        let my = Int((cy + 2.0).rounded())
        if p.mouthOpen {
            // surprised "o"
            plot(7, my, 3); plot(8, my, 3)
            plot(7, my + 1, 3); plot(8, my + 1, 3)
        } else {
            // small U smile
            plot(6, my, 3); plot(7, my + 1, 3); plot(8, my + 1, 3); plot(9, my, 3)
        }

        // 7) feet
        let fy = Int((cy + R - 0.1).rounded())
        let lf = Int((cx - 1.6).rounded())
        let rf = Int((cx + 1.6).rounded())
        func foot(_ x: Int, _ y: Int) { plot(x, y, 3); plot(x, y - 1, 1) }
        switch p.footPhase {
        case 1: foot(lf, fy + 1); foot(rf, fy)
        case 2: foot(lf, fy); foot(rf, fy + 1)
        default: foot(lf, fy); foot(rf, fy)
        }

        return g
    }

    public static let sit   = build(Params(eyeOpen: true))
    public static let blink = build(Params(eyeOpen: false))
    public static let walkA = build(Params(eyeOpen: true, footPhase: 1))
    public static let walkB = build(Params(eyeOpen: true, footPhase: 2))
    public static let hop   = build(Params(eyeOpen: true, yOffset: 2, mouthOpen: true))
    public static let resting = sit
}
