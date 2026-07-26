import Foundation

public struct Totals: Sendable, Equatable {
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    /// Work tokens scaled by each entry's model weight (Sonnet-equivalent). Used by
    /// the gauge when "weight tokens by model cost" is on; flat `workTokens` otherwise.
    public var weightedTokens: Double = 0
    /// The subagent (sidechain) slice of the two counts above — accumulated in `add` from the
    /// entry's own flag, so it costs no extra pass and can never disagree with the parent sums.
    /// Zero when "Include subagent usage" is off: those entries never reach the aggregator.
    /// These stay LAST so the synthesized memberwise init keeps existing call sites valid.
    public var sidechainWorkTokens: Int = 0
    public var sidechainTotalTokens: Int = 0

    /// Cache read + write tokens (the bulk of `totalTokens`).
    public var cacheTokens: Int { max(0, totalTokens - workTokens) }

    public mutating func add(_ e: UsageEntry, cost: Double, weight: Double = 1) {
        workTokens += e.workTokens
        totalTokens += e.totalTokens
        costUSD += cost
        weightedTokens += Double(e.workTokens) * weight
        if e.isSidechain {
            sidechainWorkTokens += e.workTokens
            sidechainTotalTokens += e.totalTokens
        }
    }
}

public struct ModelTotal: Sendable, Equatable, Identifiable {
    public let family: ModelFamily
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var unpriced: Bool = false
    public var id: String { family.rawValue }
}

public struct DayTotal: Sendable, Equatable, Identifiable {
    public let date: Date            // start of local day
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var id: TimeInterval { date.timeIntervalSince1970 }
}

public struct HourTotal: Sendable, Equatable, Identifiable {
    public let hour: Int             // 0...23, local hour of today
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var id: Int { hour }

    public init(hour: Int, workTokens: Int = 0, totalTokens: Int = 0, costUSD: Double = 0) {
        self.hour = hour
        self.workTokens = workTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

public struct Aggregates: Sendable, Equatable {
    public var today: Totals = .init()
    public var week: Totals = .init()
    public var allTime: Totals = .init()
    public var cycle: Totals = .init()         // current billing cycle
    public var todayByModel: [ModelTotal] = []
    public var weekDaily: [DayTotal] = []      // last 7 local days incl. today (all models)
    public var todayHourly: [HourTotal] = []   // today's usage in 24 local-hour buckets (all models)
    public var unknownModels: Set<String> = []
}

/// Rolls deduplicated entries into today / week / all-time totals plus a
/// per-model breakdown for today. `now`/`calendar` are injectable for tests.
public enum Aggregator {
    public static func compute(entries: [UsageEntry],
                               pricing: PricingTable,
                               now: Date = Date(),
                               calendar: Calendar = .current,
                               cycleStart: Date? = nil,
                               weekWindow: (start: Date, end: Date)? = nil) -> Aggregates {
        var agg = Aggregates()

        let startOfToday = calendar.startOfDay(for: now)
        // Rolling 7 calendar days incl. today — used for the day-by-day history chart.
        let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var modelMap: [ModelFamily: ModelTotal] = [:]

        // 24 fixed buckets for today, so the chart always has a full 12a→12p axis.
        var hourBuckets = (0...23).map { HourTotal(hour: $0) }

        // Day buckets for the history chart, oldest → newest.
        //
        // Given a weekly-reset window these are the CALENDAR DAYS that window covers, clipped to
        // it: the bars sum to exactly the weekly-limit total above them (a rolling last-7-days
        // silently disagreed with it by everything logged before a mid-afternoon reset — ~16% on
        // real data) while still being real days.
        //
        // Anchoring 24h cells to the reset *instant* also summed correctly but mislabelled the
        // bars: at 14:47 on a Sunday the cell holding `now` had begun Sat 15:00, so the chart
        // highlighted Saturday and would have jumped to Sunday at 15:00. Weekday letters have to
        // mean weekdays.
        //
        // A mid-day reset means the window touches 8 calendar days, reset day split across the
        // first and last bars. With no window, fall back to the rolling last 7 days.
        var dayBuckets: [Date: DayTotal] = [:]
        var dayOrder: [Date] = []
        if let ww = weekWindow {
            var d = calendar.startOfDay(for: ww.start)
            while d < ww.end {
                dayBuckets[d] = DayTotal(date: d)
                dayOrder.append(d)
                d = calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400)
            }
        } else {
            for offset in (0...6).reversed() {
                if let d = calendar.date(byAdding: .day, value: -offset, to: startOfToday) {
                    dayBuckets[d] = DayTotal(date: d)
                    dayOrder.append(d)
                }
            }
        }

        for e in entries {
            let cost = pricing.cost(for: e)
            let weight = pricing.weight(for: e.family)
            agg.allTime.add(e, cost: cost, weight: weight)

            if let cs = cycleStart, e.timestamp >= cs { agg.cycle.add(e, cost: cost, weight: weight) }

            // Weekly LIMIT total: the fixed 7-day reset window if provided (matches the
            // Claude app's resetting weekly limit), else the rolling-7-day fallback.
            if let ww = weekWindow {
                if e.timestamp >= ww.start && e.timestamp < ww.end { agg.week.add(e, cost: cost, weight: weight) }
            } else if e.timestamp >= weekStart {
                agg.week.add(e, cost: cost, weight: weight)
            }

            // Day-by-day history chart. Inside a window only in-window entries count, so reset
            // day's bar holds just the part that counts toward the limit.
            let dayKey: Date?
            if let ww = weekWindow {
                dayKey = (e.timestamp >= ww.start && e.timestamp < ww.end)
                    ? calendar.startOfDay(for: e.timestamp) : nil
            } else {
                dayKey = e.timestamp >= weekStart ? calendar.startOfDay(for: e.timestamp) : nil
            }
            if let key = dayKey, dayBuckets[key] != nil {
                dayBuckets[key]!.workTokens += e.workTokens
                dayBuckets[key]!.totalTokens += e.totalTokens
                dayBuckets[key]!.costUSD += cost
            }

            if calendar.isDate(e.timestamp, inSameDayAs: now) {
                agg.today.add(e, cost: cost, weight: weight)
                var mt = modelMap[e.family] ?? ModelTotal(family: e.family)
                mt.workTokens += e.workTokens
                mt.totalTokens += e.totalTokens
                mt.costUSD += cost
                mt.unpriced = pricing.isUnpriced(e.family)
                modelMap[e.family] = mt

                let h = calendar.component(.hour, from: e.timestamp)
                hourBuckets[h].workTokens += e.workTokens
                hourBuckets[h].totalTokens += e.totalTokens
                hourBuckets[h].costUSD += cost
            }

            if e.family == .other { agg.unknownModels.insert(e.model) }
        }

        // Stable, meaningful order: known families first, then other; by total tokens desc.
        agg.todayByModel = modelMap.values.sorted {
            if $0.unpriced != $1.unpriced { return !$0.unpriced }
            return $0.totalTokens > $1.totalTokens
        }
        agg.weekDaily = dayOrder.map { dayBuckets[$0] ?? DayTotal(date: $0) }
        agg.todayHourly = hourBuckets
        return agg
    }
}
