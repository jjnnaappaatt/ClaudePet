import Foundation

/// The current 5-hour usage session.
public struct UsageBlock: Sendable, Equatable {
    public let start: Date          // grid-aligned session start
    public let actualStart: Date    // first message inside the window
    public let lastActivity: Date
    public var workTokens: Int
    public var totalTokens: Int
    public var costUSD: Double
    public var weightedTokens: Double = 0   // work tokens scaled by model weight
    // Subagent (sidechain) slice of the two counts above. Trailing + defaulted so the memberwise
    // init keeps existing call sites valid.
    public var sidechainWorkTokens: Int = 0
    public var sidechainTotalTokens: Int = 0

    public var endsAt: Date { start.addingTimeInterval(FiveHourBlockEngine.blockDuration) }
    public func isActive(now: Date) -> Bool { now >= start && now < endsAt }
}

/// Computes Claude's "current session" window.
///
/// Claude anchors sessions to a fixed 5-hour grid that starts with the streak's first
/// message and advances in 5h steps (so the reset lands on the grid boundary, e.g. 15:36,
/// not on whichever message happens to fall in the window). A >=5h inactivity gap starts a
/// fresh anchor. We sum tokens within the active grid window.
public enum FiveHourBlockEngine {
    public static let blockDuration: TimeInterval = 5 * 3600

    /// Timestamp-ordered `entries` — **without allocating when they already are.**
    ///
    /// Both functions below opened with `entries.sorted { … }`, and `UsageScanner.merge` had already
    /// sorted by timestamp before returning (`recompute`'s subagent filter preserves order). So this
    /// was re-sorting sorted data — except `.sorted` allocates unconditionally, which made it two
    /// fresh ~16 MB buffers per `recompute()`, on a 30s idle timer. Nothing reclaimed them in
    /// between: `malloc_zone_pressure_relief` runs only after a *scan*, deliberately. `vmmap` showed
    /// the result as empty `MALLOC_LARGE` regions of exactly 15.6 MB — `128,101 entries × 128 bytes`.
    ///
    /// Returning `entries` unchanged shares its buffer (copy-on-write; both callers only read), which
    /// is the whole point. The O(n) check walks data the very next loop walks anyway.
    ///
    /// **The check is real, not a precondition comment**: `ingestForTesting` assigns arbitrary arrays
    /// straight to `lastEntries`, so unsorted input reaches here in tests and must still be correct.
    static func timeOrdered(_ entries: [UsageEntry]) -> [UsageEntry] {
        guard entries.count > 1 else { return entries }
        for i in 1..<entries.count where entries[i].timestamp < entries[i - 1].timestamp {
            return entries.sorted { $0.timestamp < $1.timestamp }
        }
        return entries
    }

    /// The active session containing `now`, or nil if the session has expired (idle >=5h).
    public static func activeSession(from entries: [UsageEntry],
                                     pricing: PricingTable,
                                     now: Date = Date(),
                                     resetOffset: TimeInterval = 0) -> UsageBlock? {
        guard !entries.isEmpty else { return nil }
        let sorted = timeOrdered(entries)

        // Anchor = first message after the most recent >=5h gap, shifted by the user's
        // reset calibration (Claude anchors to the first prompt, ~minutes before our first
        // assistant message).
        var anchor = sorted[0].timestamp
        var prev = anchor
        for e in sorted.dropFirst() {
            if e.timestamp.timeIntervalSince(prev) >= blockDuration { anchor = e.timestamp }
            prev = e.timestamp
        }
        anchor = anchor.addingTimeInterval(resetOffset)
        // Session expired if there's been no activity for 5h.
        if now.timeIntervalSince(prev) >= blockDuration { return nil }

        // Grid-aligned window containing now.
        let steps = floor(now.timeIntervalSince(anchor) / blockDuration)
        let start = anchor.addingTimeInterval(max(0, steps) * blockDuration)
        let end = start.addingTimeInterval(blockDuration)

        var work = 0, total = 0
        var sideWork = 0, sideTotal = 0
        var cost = 0.0, weighted = 0.0
        var first: Date?
        var last = start
        for e in sorted where e.timestamp >= start && e.timestamp < end {
            if first == nil { first = e.timestamp }
            work += e.workTokens
            total += e.totalTokens
            cost += pricing.cost(for: e)
            weighted += Double(e.workTokens) * pricing.weight(for: e.family)
            if e.isSidechain {
                sideWork += e.workTokens
                sideTotal += e.totalTokens
            }
            last = e.timestamp
        }
        // This loop sums inline rather than going through `Totals.add`, so the sidechain split
        // has to be accumulated here too — keep the two in step.
        return UsageBlock(start: start, actualStart: first ?? start, lastActivity: last,
                          workTokens: work, totalTokens: total, costUSD: cost, weightedTokens: weighted,
                          sidechainWorkTokens: sideWork, sidechainTotalTokens: sideTotal)
    }

    /// Per-metric anchor over all **completed** 5h blocks in history — near the top of your own
    /// range (see `PeakEstimator`; not the single heaviest block), used to auto-size the gauge
    /// budget from your own usage. The active (still-growing) block is excluded so the
    /// denominator is stable. Buckets entries onto the same gap-anchored, grid-aligned cells
    /// `activeSession` uses, so anchor and live value share a basis.
    public static func peakCompleted(from entries: [UsageEntry], pricing: PricingTable,
                                     now: Date = Date(), resetOffset: TimeInterval = 0)
        -> (work: Int, weighted: Double, cost: Double) {
        guard !entries.isEmpty else { return (0, 0, 0) }
        let sorted = timeOrdered(entries)

        struct Cell { var work = 0; var weighted = 0.0; var cost = 0.0; var end = Date.distantPast }
        var cells: [Date: Cell] = [:]
        var anchor = sorted[0].timestamp.addingTimeInterval(resetOffset)
        var prev = sorted[0].timestamp
        for e in sorted {
            if e.timestamp.timeIntervalSince(prev) >= blockDuration {
                anchor = e.timestamp.addingTimeInterval(resetOffset)   // new streak after a >=5h gap
            }
            prev = e.timestamp
            let steps = floor(e.timestamp.timeIntervalSince(anchor) / blockDuration)
            let start = anchor.addingTimeInterval(max(0, steps) * blockDuration)
            var c = cells[start] ?? Cell()
            c.work += e.workTokens
            c.weighted += Double(e.workTokens) * pricing.weight(for: e.family)
            c.cost += pricing.cost(for: e)
            c.end = start.addingTimeInterval(blockDuration)
            cells[start] = c
        }
        // Each metric is anchored independently, exactly as the old per-metric max was: the
        // 7th-heaviest block by work need not be the 7th-heaviest by cost.
        let completed = cells.values.filter { $0.end <= now }   // completed blocks only
        return (PeakEstimator.anchor(completed.map(\.work)),
                PeakEstimator.anchor(completed.map(\.weighted)),
                PeakEstimator.anchor(completed.map(\.cost)))
    }
}
