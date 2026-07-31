import Testing
import Foundation
@testable import ClaudePetCore

/// The ground is the **weekly** limit, drawn under the pet. It is a pure function of the weekly
/// fraction, with no idle state — a week keeps running even when no session does.
@Suite struct GroundConditionTests {

    @Test func bandsCoverTheWholeRange() {
        let cases: [(Double, GroundCondition)] = [
            (0.00, .lush), (0.24, .lush),
            (0.25, .grassy), (0.49, .grassy),
            (0.50, .dry), (0.74, .dry),
            (0.75, .sparse), (0.91, .sparse),
            (0.92, .cracked), (1.00, .cracked),
        ]
        for (f, expected) in cases {
            #expect(GroundCondition.from(weeklyFraction: f) == expected,
                    "weekly \(f) should be \(expected)")
        }
    }

    /// Past 100% is throttling territory, not a gap in the enum.
    @Test func overTheLimitStaysCracked() {
        #expect(GroundCondition.from(weeklyFraction: 1.4) == .cracked)
    }

    /// A negative fraction can't arise from the gauges, but the enum shouldn't fall off its own
    /// bottom band if one ever did.
    @Test func belowZeroIsLush() {
        #expect(GroundCondition.from(weeklyFraction: -0.2) == .lush)
    }

    /// The mascot's art ends at row 11 (feet), so ground pixels must start below it. This is the one
    /// invariant that lets the two be separate matrices drawn into the same frame.
    @Test func groundNeverCollidesWithTheMascot() {
        for c in GroundCondition.allCases {
            let g = GroundArt.matrix(for: c)
            for r in 0..<11 {
                #expect(g[r].allSatisfy { $0 == 0 }, "\(c) drew into row \(r), where the pet lives")
            }
        }
    }

    /// Blades may sit on row 11, but never in a column a foot plants in (4, 6, 10, 12).
    @Test func bladesAvoidTheFeet() {
        for c in GroundCondition.allCases {
            let g = GroundArt.matrix(for: c)
            for col in [4, 6, 10, 12] {
                #expect(g[11][col] == 0, "\(c) put a blade under a foot at column \(col)")
            }
        }
    }

    @Test func everyConditionDrawsSomething() {
        for c in GroundCondition.allCases {
            let g = GroundArt.matrix(for: c)
            #expect(g.contains { $0.contains { $0 != 0 } }, "\(c) rendered an empty ground")
        }
    }

    /// Terrain has to get emptier as the week fills, or the metaphor is backwards.
    @Test func vegetationThinsAsTheWeekFills() {
        let counts = GroundCondition.allCases.map { c in
            GroundArt.matrix(for: c).reduce(0) { $0 + $1.filter { $0 == 14 || $0 == 15 }.count }
        }
        #expect(counts == counts.sorted(by: >), "greenery should only decrease: \(counts)")
    }

    /// The patterns are written as 16-character strings meant to be read as pictures. A typo that
    /// drops a character doesn't fail to compile — the row just renders short, leaving a notch of bare
    /// card at the right edge of the ground that reads as a rendering glitch.
    @Test func everyGroundRowSpansTheFullWidth() {
        for c in GroundCondition.allCases {
            let g = GroundArt.matrix(for: c)
            #expect(g.count == 16, "\(c) is \(g.count) rows")
            for (r, row) in g.enumerated() {
                #expect(row.count == 16, "\(c) row \(r) is \(row.count) wide")
            }
        }
    }

    /// Soil has to reach the full width even where vegetation doesn't — except in `cracked`, where the
    /// gaps ARE the drawing. Catches a short pattern string that the width test above cannot see,
    /// because `matrix` pads with zeros rather than truncating.
    @Test func soilCoversTheGroundExceptWhereItIsCracked() {
        for c in GroundCondition.allCases where c != .cracked {
            let g = GroundArt.matrix(for: c)
            let soil = g[13].filter { $0 != 0 }.count
            #expect(soil == 16, "\(c) soil row covers only \(soil)/16 columns")
        }
    }
    /// The pet must have something under its feet in every state.
    ///
    /// Row 12 is where the feet land (they occupy rows 10-11 at columns 4, 6, 10 and 12). An empty
    /// cell there is a hole: the pet stands one row above the soil and reads as levitating over a
    /// floating slab, which is what `sparse` and `cracked` did — 3 of 16 columns inked and 0 of 16
    /// respectively. Thinning the *vegetation* as the week fills is the metaphor; removing the ground
    /// is not.
    @Test func theSurfaceRowIsNeverEmptyUnderAFoot() {
        for c in GroundCondition.allCases {
            let g = GroundArt.matrix(for: c)
            for col in [4, 6, 10, 12] {
                #expect(g[12][col] != 0, "\(c) leaves nothing under the foot at column \(col)")
            }
        }
    }

}
