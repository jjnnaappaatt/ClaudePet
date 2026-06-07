import Foundation

/// One rolling 5-hour usage window. `start` is hour-floored (UTC), as ccusage does.
public struct UsageBlock: Sendable, Equatable {
    public let start: Date          // hour-floored block start
    public let actualStart: Date    // first entry's timestamp
    public let lastActivity: Date
    public var workTokens: Int
    public var totalTokens: Int
    public var costUSD: Double

    public var endsAt: Date { start.addingTimeInterval(FiveHourBlockEngine.blockDuration) }

    /// A block is "active" when now falls inside its 5h window.
    public func isActive(now: Date) -> Bool { now >= start && now < endsAt }
}

/// Groups deduplicated entries into rolling 5-hour blocks.
///
/// Faithful (but simplified) approximation of Claude's rolling-window limit:
/// - block start is floored to the top of the hour (UTC),
/// - a block ends at the EARLIER of 5h-from-start or a >=5h inactivity gap,
/// - concurrent sessions share one block (we group purely by time),
/// - the active block is the one whose 5h window covers now.
public enum FiveHourBlockEngine {
    public static let blockDuration: TimeInterval = 5 * 3600

    /// Floor to the absolute hour boundary (aligns with UTC :00, timezone-independent).
    static func hourFloor(_ date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 3600).rounded(.down) * 3600)
    }

    public static func blocks(from entries: [UsageEntry], pricing: PricingTable) -> [UsageBlock] {
        guard !entries.isEmpty else { return [] }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }

        var blocks: [UsageBlock] = []
        var start: Date? = nil
        var actualStart = Date.distantPast
        var last = Date.distantPast
        var work = 0, total = 0
        var cost = 0.0

        func flush() {
            guard let s = start else { return }
            blocks.append(UsageBlock(start: s, actualStart: actualStart, lastActivity: last,
                                     workTokens: work, totalTokens: total, costUSD: cost))
        }
        func open(at ts: Date) {
            start = hourFloor(ts); actualStart = ts; last = ts
            work = 0; total = 0; cost = 0
        }

        for e in sorted {
            let ts = e.timestamp
            if let s = start {
                let gap = ts.timeIntervalSince(last)
                let pastDuration = ts >= s.addingTimeInterval(blockDuration)
                if gap >= blockDuration || pastDuration {
                    flush()
                    open(at: ts)
                }
            } else {
                open(at: ts)
            }
            work += e.workTokens
            total += e.totalTokens
            cost += pricing.cost(for: e)
            last = ts
        }
        flush()
        return blocks
    }

    /// The block whose 5h window currently contains `now`, if any.
    public static func activeBlock(in blocks: [UsageBlock], now: Date) -> UsageBlock? {
        blocks.last(where: { $0.isActive(now: now) })
    }
}
