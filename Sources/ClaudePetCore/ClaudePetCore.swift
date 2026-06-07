import Foundation

/// Namespace + version marker for the ClaudePet data layer.
/// The real data engine (models, parser, dedup, aggregation, pricing, 5h block)
/// lives in the sibling files of this target.
public enum ClaudePetCore {
    public static let version = "0.1.0"
}
