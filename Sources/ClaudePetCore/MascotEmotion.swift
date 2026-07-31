import Foundation

/// The mascot's mood. Driven by how close the **5-hour session** is to its limit — see
/// `MetricsStore.mascotEmotion`. The weekly limit is a separate signal and shows up as the
/// `GroundCondition` beneath the pet, never on its face. `rawValue` is also the asset filename
/// suffix (e.g. `mascot-worried.png`) for the optional image drop-in.
///
/// Ordered from most headroom to least. `content`, `focused` and `exhausted` fill what were the
/// coarsest gaps: the ramp used to jump straight from `happy` at 49% to `neutral` at 50%, and had
/// nothing at all to say once you were *past* the limit.
public enum MascotEmotion: String, CaseIterable, Sendable {
    case sleeping, celebrating, happy, content, neutral, focused, worried, alarmed, exhausted
}
