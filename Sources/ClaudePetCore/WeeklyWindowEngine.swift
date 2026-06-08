import Foundation

/// Claude's weekly limit is a **fixed 7-day window that resets on a schedule** — not a
/// rolling last-7-days sum. We model it as a 7-day grid anchored to `anchor`; the active
/// window is the grid cell containing `now`, and usage **resets to zero** at each boundary
/// (mirroring the Claude app). The anchor is an estimate the user calibrates to match the
/// app, since Anthropic doesn't publish the real reset moment.
public struct WeeklyWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date            // start + 7d — the reset moment (countdown target)
    public var workTokens: Int
    public var totalTokens: Int
    public var costUSD: Double

    public func resetsIn(now: Date = Date()) -> TimeInterval { max(0, end.timeIntervalSince(now)) }
}

public enum WeeklyWindowEngine {
    public static let weekDuration: TimeInterval = 7 * 86_400

    /// The grid cell `[start, end)` containing `now`, for a reset `anchor`.
    /// Works whether `now` is before or after the anchor (no clamping), so the window
    /// always contains `now`.
    public static func window(anchor: Date, now: Date = Date()) -> (start: Date, end: Date) {
        let steps = (now.timeIntervalSince(anchor) / weekDuration).rounded(.down)
        let start = anchor.addingTimeInterval(steps * weekDuration)
        return (start, start.addingTimeInterval(weekDuration))
    }

    /// Sum usage that falls inside the active weekly window — i.e. only entries since the
    /// most recent reset count. Entries before `start` are excluded (they "reset off").
    public static func current(from entries: [UsageEntry], pricing: PricingTable,
                               anchor: Date, now: Date = Date()) -> WeeklyWindow {
        let (start, end) = window(anchor: anchor, now: now)
        var work = 0, total = 0
        var cost = 0.0
        for e in entries where e.timestamp >= start && e.timestamp < end {
            work += e.workTokens
            total += e.totalTokens
            cost += pricing.cost(for: e)
        }
        return WeeklyWindow(start: start, end: end, workTokens: work, totalTokens: total, costUSD: cost)
    }
}
