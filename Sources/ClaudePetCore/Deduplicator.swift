import Foundation

/// Drops duplicate assistant turns. ~51% of raw assistant lines repeat the same
/// `message.id` with IDENTICAL usage (they are NOT streaming deltas), so we keep
/// one per id and never sum — summing would roughly double tokens and cost.
public struct Deduplicator {
    private var seen: Set<String> = []

    public init() {}

    public var uniqueCount: Int { seen.count }

    /// Returns only entries whose `messageID` is new, recording them as seen.
    /// Stateful so incremental re-parses across many files stay deduplicated.
    public mutating func newEntries(from entries: [UsageEntry]) -> [UsageEntry] {
        var out: [UsageEntry] = []
        out.reserveCapacity(entries.count)
        for entry in entries where seen.insert(entry.messageID).inserted {
            out.append(entry)
        }
        return out
    }

    /// Stateless one-shot dedup (keep first occurrence per `messageID`).
    public static func deduplicated(_ entries: [UsageEntry]) -> [UsageEntry] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.messageID).inserted }
    }
}
