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

    /// The active session containing `now`, or nil if the session has expired (idle >=5h).
    public static func activeSession(from entries: [UsageEntry],
                                     pricing: PricingTable,
                                     now: Date = Date(),
                                     resetOffset: TimeInterval = 0) -> UsageBlock? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }

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
        var cost = 0.0, weighted = 0.0
        var first: Date?
        var last = start
        for e in sorted where e.timestamp >= start && e.timestamp < end {
            if first == nil { first = e.timestamp }
            work += e.workTokens
            total += e.totalTokens
            cost += pricing.cost(for: e)
            weighted += Double(e.workTokens) * pricing.weight(for: e.family)
            last = e.timestamp
        }
        return UsageBlock(start: start, actualStart: first ?? start, lastActivity: last,
                          workTokens: work, totalTokens: total, costUSD: cost, weightedTokens: weighted)
    }
}
