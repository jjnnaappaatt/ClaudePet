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

    /// An anchor instant on `weekday` at `hour:minute` (local), suitable for the 7-day grid.
    /// `weekday` follows `Calendar` numbering (1 = Sunday … 2 = Monday … 7 = Saturday).
    /// Deterministic and independent of "now" — found relative to a fixed Monday reference —
    /// so every grid boundary lands on that weekday/time. Exact in zones without DST; may
    /// drift ±1h across a DST change (the grid steps by a fixed 7×24h).
    public static func anchor(weekday: Int, hour: Int, minute: Int,
                              calendar: Calendar = .current) -> Date {
        let mondayRef = Date(timeIntervalSince1970: 1_704_067_200)  // 2024-01-01 00:00 UTC (a Monday)
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.nextDate(after: mondayRef, matching: comps, matchingPolicy: .nextTime) ?? mondayRef
    }

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

    /// Per-metric peak over all **completed** weekly windows in history — your heaviest week
    /// ever, used to auto-size the weekly gauge budget from your own usage. The current
    /// (still-growing) window is excluded so the denominator is stable.
    public static func peakCompleted(from entries: [UsageEntry], pricing: PricingTable,
                                     anchor: Date, now: Date = Date())
        -> (work: Int, weighted: Double, cost: Double) {
        guard !entries.isEmpty else { return (0, 0, 0) }
        struct Cell { var work = 0; var weighted = 0.0; var cost = 0.0; var end = Date.distantPast }
        var cells: [Date: Cell] = [:]
        for e in entries {
            let steps = (e.timestamp.timeIntervalSince(anchor) / weekDuration).rounded(.down)
            let start = anchor.addingTimeInterval(steps * weekDuration)
            var c = cells[start] ?? Cell()
            c.work += e.workTokens
            c.weighted += Double(e.workTokens) * pricing.weight(for: e.family)
            c.cost += pricing.cost(for: e)
            c.end = start.addingTimeInterval(weekDuration)
            cells[start] = c
        }
        var pw = 0; var cw = 0.0; var cc = 0.0
        for (_, c) in cells where c.end <= now {        // completed windows only
            pw = max(pw, c.work); cw = max(cw, c.weighted); cc = max(cc, c.cost)
        }
        return (pw, cw, cc)
    }
}
