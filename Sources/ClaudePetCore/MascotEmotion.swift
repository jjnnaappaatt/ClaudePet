import Foundation

/// The mascot's mood. Driven by how close you are to your limits — see
/// `MetricsStore.mascotEmotion`. `rawValue` is also the asset filename suffix
/// (e.g. `mascot-worried.png`) for the optional image drop-in.
public enum MascotEmotion: String, CaseIterable, Sendable {
    case sleeping, celebrating, happy, neutral, worried, alarmed
}

/// Severity of the binding limit — the single accent colour + a colour-blind-safe signal
/// (the redesign pairs this with a status word so state never relies on colour alone).
public enum StatusLevel: String, CaseIterable, Sendable {
    case ok      // plenty of headroom (coral)
    case warn    // getting tight (orange)
    case over    // at the cap (red)
}
