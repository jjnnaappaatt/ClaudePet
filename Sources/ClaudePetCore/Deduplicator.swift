import Foundation

/// Collapses repeated assistant turns. Most `message.id`s appear more than once — Claude Code logs a
/// line per content block as a response streams — so keep **one per id and never sum**; summing
/// roughly triples tokens and cost.
///
/// **The copies are not identical, and which one is kept matters.** This comment used to say every
/// repeat carried byte-identical usage. On the real corpus (2026-10) the copies of 72,984 of 73,016
/// repeated ids share input and cache counts while output only grows, `3, 3, 3, 4313`: each is the
/// usage known at that point in the stream. Keeping the first undercounted output by 26%, and where
/// copies tied on timestamp across files it made totals depend on file order. One entry per id,
/// carrying the largest copy's usage at the earliest copy's timestamp — `UsageEntry.absorbing`.
///
/// **This is defeated on purpose by a setting.** `MetricsStore.countRepeatedLogLines` (Settings →
/// "Count repeated log lines (match /stats)") passes `deduplicated: false` down to
/// `UsageScanner.scan`, which is a supported mode rather than a bug — so "the app dedups" is not
/// something a reader can assume from this file alone. `ScannerWiringTests` pins both directions.
public enum Deduplicator {

    /// One entry per `messageID`, in first-seen position, folding later copies in with `absorbing`.
    ///
    /// `UsageScanner.merge` does **not** call this on the live path — it compacts its own array in
    /// place instead, because this returns a NEW array and holding two full copies of ~125k entries
    /// was a measurable part of the scan's peak. Kept as the readable statement of what dedup means,
    /// and as what the unit tests exercise.
    public static func deduplicated(_ entries: [UsageEntry]) -> [UsageEntry] {
        var out: [UsageEntry] = []
        var slot: [MessageKey: Int] = [:]
        for e in entries {
            if let k = slot[e.messageID] { out[k] = out[k].absorbing(e); continue }
            slot[e.messageID] = out.count
            out.append(e)
        }
        return out
    }
}
