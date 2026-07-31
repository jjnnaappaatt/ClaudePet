import Foundation

/// The ground the pet stands on: the **weekly** limit, as terrain.
///
/// This exists because the mascot block was showing one number when there are two. `mascotEmotion`
/// used to read `max(5h, weekly)`, so a stormy pet could mean either limit and you couldn't tell
/// which — and the sky, being derived from the face, added no information at all.
///
/// The split is: **face and sky = the 5-hour session, ground = the week.** Terrain is the right
/// carrier for the weekly one because it changes on a slower clock than the weather does, which is
/// exactly how the two limits behave — a session resets several times a day, a week once.
///
/// Rendered by `GroundArt` into its own matrix, drawn between the sky and the pet.
public enum GroundCondition: String, CaseIterable, Sendable {
    case lush        // < 25% — thick grass, sprouts
    case grassy      // < 50% — ordinary grass
    case dry         // < 75% — patchy, going brown
    case sparse      // < 92% — mostly bare soil, a few tufts
    case cracked     // ≥ 92% — bare, cracked earth

    /// Bands over the weekly fraction. Deliberately **not** the same cut points as `MascotEmotion`:
    /// there is no `sleeping` equivalent (a week is always running, even when no session is), and the
    /// top band starts earlier because a weekly limit gives far less warning in wall-clock terms —
    /// 92% of a week with two days left is a different kind of trouble from 92% of a five-hour window.
    public static func from(weeklyFraction f: Double) -> GroundCondition {
        switch f {
        case ..<0.25: return .lush
        case ..<0.50: return .grassy
        case ..<0.75: return .dry
        case ..<0.92: return .sparse
        default:      return .cracked
        }
    }
}
