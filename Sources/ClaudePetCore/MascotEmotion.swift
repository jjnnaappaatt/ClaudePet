import Foundation

/// The mascot's mood. Driven by how close you are to your limits — see
/// `MetricsStore.mascotEmotion`. `rawValue` is also the asset filename suffix
/// (e.g. `mascot-worried.png`) for the optional image drop-in.
public enum MascotEmotion: String, CaseIterable, Sendable {
    case sleeping, celebrating, happy, neutral, worried, alarmed
}
