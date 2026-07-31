import Foundation

/// Pixel-art-as-code ground (16×16), drawn between the sky and the pet: the weekly limit as terrain.
///
/// It shares the mascot's 16×16 grid on purpose, and both are drawn into the same `pet × pet` frame,
/// so the two matrices land on the same cell pitch and their rows line up exactly. (The *weather*
/// layer does not: it is 16×22 in a taller frame, so its cells are a different size.)
///
/// The mascot's art ends at **row 11** — body rows 4…9, feet 10…11. Ground owns row 12 down, plus
/// row 11 for tall blades, which is the one row the two layers share: blades are kept out of the
/// columns a foot plants in (4, 6, 10, 12) so they read as growing *beside* the pet rather than
/// through it. `GroundConditionTests` pins both halves of that — nothing above row 11, and no blade
/// in a foot column.
///
/// Static, with no engine behind it. `WeatherEngine` simulates per frame because rain and clouds have
/// to move; ground doesn't, and a second engine would double the draw cost of a decorative layer.
public enum GroundArt {
    static let n = 16

    /// The one row above the surface that may carry tall blades. Kept clear of the feet, which plant
    /// at columns 4, 6, 10 and 12 (see `MascotArt`).
    private static let bladeRow = 11
    private static let surfaceRow = 12

    /// Legend, one character per pixel — the patterns below are meant to be read as pictures in the
    /// source, which is how the mascot's art is written too.
    ///
    /// `.` nothing · `g` fresh grass · `d` dulled grass · `s` rich soil · `y` dry soil · `c` deep crack
    ///
    /// A `.` inside a soil row is not a gap in the drawing — it lets the near-black card show through,
    /// which is what reads as a fissure. Cheaper and darker than any colour we could put there.
    ///
    /// **The soil runs to the bottom row.** Weather is drawn *behind* the ground, and the terrain used
    /// to stop at row 14 — so raindrops kept falling through the empty row 15 and appeared underneath
    /// the soil, which reads as the ground floating. The last row is opaque fill for that reason, not
    /// for looks.
    ///
    /// **The surface row is never empty.** It is the row the feet land on, so a `.` there is a hole
    /// under the pet: it stood one row clear of the soil and read as levitating over a detached slab.
    /// That is what the bare states looked like before — `sparse` inked only 3 of 16 columns and
    /// `cracked` none at all, so at 75%+ of the week the pet floated. Vegetation is what thins as the
    /// week fills; the ground itself stays put. `GroundConditionTests` pins the foot columns.
    private static func pattern(_ c: GroundCondition) -> (blades: String, rows: [String]) {
        switch c {
        case .lush:
            return (".g.g....g....g.g",   // cols 1,3,8,13,15 — clear of the feet at 4,6,10,12
                    ["gggggggggggggggg",
                     "ssssssssssssssss",
                     "ssssssssssssssss",
                     "ssssssssssssssss"])
        case .grassy:
            return ("................",
                    ["gdggdggggdggdggg",
                     "ssssssssssssssss",
                     "ssssssssssssssss",
                     "ssssssssssssssss"])
        case .dry:
            return ("................",
                    ["ddydddyddydddydd",
                     "ssssyssssssyssss",
                     "yyyyyyyyyyyyyyyy",
                     "yyyyyyyyyyyyyyyy"])
        case .sparse:
            return ("................",
                    ["yydyyyydyyyyydyy",
                     "yyyysyyyyyyyysyy",
                     "yyyyyyyyyyyyyyyy",
                     "yyyyyyyyyyyyyyyy"])
        case .cracked:
            return ("................",
                    ["yyyyyyyyyyyyyyyy",
                     "yyy.yyyyy.yyy.yy",
                     "yycyyyyycyyyyyyc",
                     "yyyyyyyyyyyyyyyy"])
        }
    }

    private static func ink(_ ch: Character) -> UInt8 {
        switch ch {
        case "g": return 14
        case "d": return 15
        case "s": return 16
        case "y": return 17
        case "c": return 18
        default:  return 0
        }
    }

    /// The terrain matrix for a weekly state, in the mascot's own coordinate space.
    public static func matrix(for condition: GroundCondition) -> [[UInt8]] {
        var g = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: n)
        let p = pattern(condition)
        for (c, ch) in p.blades.enumerated() where c < n { g[bladeRow][c] = ink(ch) }
        for (i, row) in p.rows.enumerated() {
            let r = surfaceRow + i
            guard r < n else { break }
            for (c, ch) in row.enumerated() where c < n { g[r][c] = ink(ch) }
        }
        return g
    }
}
