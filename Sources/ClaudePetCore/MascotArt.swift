import Foundation

/// Pixel-art-as-code mascot (16×16). A flat Claude-coral critter — wide rounded body,
/// two side nubs, two legs — with swappable eyes / mouth / accent so it can emote.
public enum MascotArt {
    static let n = 16

    public enum Eyes { case slit, closed, happy, wide }
    public enum Mouth { case none, smile, open }
    public enum Accent { case none, sweat, sparkle, alarm, sleep }

    /// Palette indices: 1 coral body, 3 dark (mouth), 4 sparkle/zzz, 5 eye, 6 sweat, 8 alarm.
    static func build(eyes: Eyes = .slit, mouth: Mouth = .none, accent: Accent = .none,
                      legPhase: Int = 0, yOffset: Int = 0) -> [[UInt8]] {
        var g = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: n)
        func set(_ r: Int, _ c: Int, _ v: UInt8) {
            let rr = r - yOffset
            guard rr >= 0, rr < n, c >= 0, c < n else { return }
            g[rr][c] = v
        }

        // Body: rounded rectangle rows 4...10, cols 3...12 (corners trimmed).
        for r in 4...10 {
            for c in 3...12 {
                if (r == 4 || r == 10) && (c == 3 || c == 12) { continue }
                set(r, c, 1)
            }
        }
        // Side nubs (ears): rows 6...7 at cols 1-2 and 13-14.
        for r in 6...7 { set(r, 1, 1); set(r, 2, 1); set(r, 13, 1); set(r, 14, 1) }

        // Eyes (index 5).
        switch eyes {
        case .slit:
            for r in 6...7 { set(r, 6, 5); set(r, 9, 5) }
        case .closed:
            set(7, 5, 5); set(7, 6, 5); set(7, 9, 5); set(7, 10, 5)        // ‿ ‿ lines
        case .happy:
            set(7, 5, 5); set(6, 6, 5); set(7, 7, 5)                        // ^ left
            set(7, 8, 5); set(6, 9, 5); set(7, 10, 5)                       // ^ right
        case .wide:
            for r in 6...7 { for c in [5, 6, 9, 10] { set(r, c, 5) } }      // startled 2×2
        }

        // Mouth (index 3, dark, drawn over the body).
        switch mouth {
        case .none:  break
        case .smile: set(9, 6, 3); set(10, 7, 3); set(10, 8, 3); set(9, 9, 3)
        case .open:  set(9, 7, 3); set(9, 8, 3); set(10, 7, 3); set(10, 8, 3)
        }

        // Accent marks (float beside/above the head).
        switch accent {
        case .none:    break
        case .sweat:   set(4, 13, 6); set(5, 13, 6)                         // blue drop
        case .sparkle: set(3, 4, 4); set(2, 7, 4); set(3, 11, 4); set(4, 13, 4)
        case .alarm:   set(2, 11, 8); set(3, 12, 8)                         // red mark
        case .sleep:   set(2, 13, 4); set(3, 12, 4); set(4, 11, 4)          // drifting zzz
        }

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

    /// Eyes / mouth / accent for each mood.
    private static func style(_ e: MascotEmotion) -> (eyes: Eyes, mouth: Mouth, accent: Accent) {
        switch e {
        case .sleeping:    return (.closed, .none,  .sleep)
        case .celebrating: return (.happy,  .smile, .sparkle)
        case .happy:       return (.happy,  .smile, .none)
        case .neutral:     return (.slit,   .none,  .none)
        case .worried:     return (.wide,   .none,  .sweat)
        case .alarmed:     return (.wide,   .open,  .alarm)
        }
    }

    /// A frame for `emotion` with an optional idle action (blink via `eyeOverride`, step, hop).
    public static func face(_ emotion: MascotEmotion, eyeOverride: Eyes? = nil,
                            legPhase: Int = 0, yOffset: Int = 0) -> [[UInt8]] {
        let s = style(emotion)
        return build(eyes: eyeOverride ?? s.eyes, mouth: s.mouth, accent: s.accent,
                     legPhase: legPhase, yOffset: yOffset)
    }

    // Neutral idle frames (kept for the app icon, preview sheet, paused fallback, tests).
    public static let sit     = build()
    public static let blink   = build(eyes: .closed)
    public static let walkA   = build(legPhase: 1)
    public static let walkB   = build(legPhase: 2)
    public static let hop     = build(yOffset: 2)
    public static let resting = sit

    // Emotion faces (for the preview sheet / quick reference).
    public static let happy       = face(.happy)
    public static let worried     = face(.worried)
    public static let alarmed     = face(.alarmed)
    public static let sleeping    = face(.sleeping)
    public static let celebrating = face(.celebrating)
}
