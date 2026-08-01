import Foundation

/// Drops duplicate assistant turns. Measured on a real corpus, **8,349 of 12,259 `message.id`s
/// appear more than once**, and every repeat sits inside the same file with byte-identical usage —
/// they are re-logs of one API response, NOT streaming deltas. Keep one per id and never sum;
/// summing roughly triples tokens and cost.
///
/// **This is defeated on purpose by a setting.** `MetricsStore.countRepeatedLogLines` (Settings →
/// "Count repeated log lines (match /stats)") passes `deduplicated: false` down to
/// `UsageScanner.scan`, which is a supported mode rather than a bug — so "the app dedups" is not
/// something a reader can assume from this file alone. `ScannerWiringTests` pins both directions.
public enum Deduplicator {

    /// Keep the first occurrence per `messageID`.
    ///
    /// `UsageScanner.merge` does **not** call this on the live path — it compacts its own array in
    /// place instead, because this returns a NEW array and holding two full copies of ~125k entries
    /// was a measurable part of the scan's peak. Kept as the readable statement of what dedup means,
    /// and as what the unit tests exercise.
    public static func deduplicated(_ entries: [UsageEntry]) -> [UsageEntry] {
        var seen = Set<String>()
        seen.reserveCapacity(entries.count)
        return entries.filter { seen.insert($0.messageID).inserted }
    }
}
