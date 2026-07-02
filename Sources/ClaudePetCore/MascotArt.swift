import Foundation

/// Pixel-art-as-code mascot (16×16): a faithful Clawd — the Claude Code mascot. A flat
/// Claude-coral rounded rectangle with plain dark square eyes (no glints), no mouth, small
/// side claw-arms, and four tiny feet. Emotes the way the terminal sprite does: eye poses
/// (glance left/right, closed, wide) plus an arms-up pose, with floating accent marks.
public enum MascotArt {
    static let n = 16

    public enum Eyes { case normal, closed, happy, wide, lookLeft, lookRight }
    public enum Arms { case side, up }
    public enum Accent { case none, sweat, sparkle, alarm, sleep }

    /// Palette indices: 1 coral body, 4 sparkle/zzz, 5 eye (dark), 6 sweat, 8 alarm.
    static func build(eyes: Eyes = .normal, arms: Arms = .side, accent: Accent = .none,
                      legPhase: Int = 0, yOffset: Int = 0) -> [[UInt8]] {
        var g = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: n)
        func set(_ r: Int, _ c: Int, _ v: UInt8) {
            let rr = r - yOffset
            guard rr >= 0, rr < n, c >= 0, c < n else { return }
            g[rr][c] = v
        }

        // Body: chunky rounded rectangle, 11 wide × 6 tall (cols 3...13, rows 4...9) —
        // the welcome-screen Clawd's ` █████████ / ██▄█████▄██ … ` proportions.
        for r in 4...9 {
            let inset = (r == 4 || r == 9) ? 1 : 0
            for c in (3 + inset)...(13 - inset) { set(r, c, 1) }
        }

        // Claw-arms: side nubs while calm; raised beside the head for the arms-up pose.
        switch arms {
        case .side:
            for r in 6...7 { set(r, 2, 1); set(r, 14, 1) }
        case .up:
            for r in 4...5 { set(r, 2, 1); set(r, 14, 1) }
            set(3, 1, 1); set(3, 15, 1)                       // open claw tips (▗▟ … ▙▖)
        }

        // Eyes: plain dark squares punched into the body (no whites). Base position is
        // 2×2 at rows 5...6, cols 5-6 and 10-11 — the sprite's rel cols 2 & 8 scaled up.
        switch eyes {
        case .normal:
            for r in 5...6 { for c in [5, 6, 10, 11] { set(r, c, 5) } }
        case .lookLeft:                                        // ▟▟ — pupils slide down-left
            for r in 6...7 { for c in [4, 5, 9, 10] { set(r, c, 5) } }
        case .lookRight:                                       // ▙▙ — pupils slide down-right
            for r in 6...7 { for c in [6, 7, 11, 12] { set(r, c, 5) } }
        case .closed:
            for c in [5, 6, 10, 11] { set(6, c, 5) }           // resting lines
        case .happy:                                           // eyes lifted a row — bright
            for r in 4...5 { for c in [5, 6, 10, 11] { set(r, c, 5) } }
        case .wide:
            for r in 5...7 { for c in [5, 6, 10, 11] { set(r, c, 5) } }   // 2×3 startled
        }

        // Accent marks (float in the open rows above the body).
        switch accent {
        case .none:    break
        case .sweat:   set(4, 15, 6); set(5, 15, 6)                      // drop beside the head
        case .sparkle: set(2, 4, 4); set(1, 8, 4); set(2, 12, 4)
        case .alarm:   set(1, 12, 8); set(2, 13, 8)                      // red mark
        case .sleep:   set(1, 14, 4); set(2, 13, 4); set(3, 12, 4)       // drifting zzz
        }

        // Four feet (body-relative cols 1,3,7,9 → 4,6,10,12), alternating as pairs to walk.
        let feetL = [4, 6], feetR = [10, 12]
        func plant(_ cols: [Int], planted: Bool) {
            for c in cols {
                set(10, c, 1)
                if planted { set(11, c, 1) }
            }
        }
        switch legPhase {
        case 1:  plant(feetL, planted: true);  plant(feetR, planted: false)
        case 2:  plant(feetL, planted: false); plant(feetR, planted: true)
        default: plant(feetL, planted: true);  plant(feetR, planted: true)
        }

        return g
    }

    /// Eyes / arms / accent for each mood — mapped to the terminal sprite's real poses.
    private static func style(_ e: MascotEmotion) -> (eyes: Eyes, arms: Arms, accent: Accent) {
        switch e {
        case .sleeping:    return (.closed, .side, .sleep)
        case .celebrating: return (.happy,  .up,   .sparkle)
        case .happy:       return (.happy,  .side, .none)
        case .neutral:     return (.normal, .side, .none)
        case .worried:     return (.wide,   .side, .sweat)
        case .alarmed:     return (.wide,   .side, .alarm)
        }
    }

    /// A frame for `emotion` with an optional idle action (blink/glance via `eyeOverride`,
    /// step, hop).
    public static func face(_ emotion: MascotEmotion, eyeOverride: Eyes? = nil,
                            legPhase: Int = 0, yOffset: Int = 0) -> [[UInt8]] {
        let s = style(emotion)
        return build(eyes: eyeOverride ?? s.eyes, arms: s.arms, accent: s.accent,
                     legPhase: legPhase, yOffset: yOffset)
    }

    // Neutral idle frames (kept for the app icon, preview sheet, paused fallback, tests).
    public static let sit     = build()
    public static let blink   = build(eyes: .closed)
    public static let walkA   = build(legPhase: 1)
    public static let walkB   = build(legPhase: 2)
    public static let hop     = build(yOffset: 2)
    public static let glanceL = build(eyes: .lookLeft)
    public static let glanceR = build(eyes: .lookRight)
    public static let resting = sit

    // Emotion faces (for the preview sheet / quick reference).
    public static let happy       = face(.happy)
    public static let worried     = face(.worried)
    public static let alarmed     = face(.alarmed)
    public static let sleeping    = face(.sleeping)
    public static let celebrating = face(.celebrating)
}
