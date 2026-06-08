import Foundation

public struct Totals: Sendable, Equatable {
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    /// Work tokens scaled by each entry's model weight (Sonnet-equivalent). Used by
    /// the gauge when "weight tokens by model cost" is on; flat `workTokens` otherwise.
    public var weightedTokens: Double = 0

    /// Cache read + write tokens (the bulk of `totalTokens`).
    public var cacheTokens: Int { max(0, totalTokens - workTokens) }

    public mutating func add(_ e: UsageEntry, cost: Double, weight: Double = 1) {
        workTokens += e.workTokens
        totalTokens += e.totalTokens
        costUSD += cost
        weightedTokens += Double(e.workTokens) * weight
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

public struct Aggregates: Sendable, Equatable {
    public var today: Totals = .init()
    public var week: Totals = .init()
    public var allTime: Totals = .init()
    public var cycle: Totals = .init()         // current billing cycle
    public var todayByModel: [ModelTotal] = []
    public var weekDaily: [DayTotal] = []      // last 7 local days incl. today (all models)
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

        // Prepare 7 day buckets (oldest → today), keyed by start-of-day.
        var dayBuckets: [Date: DayTotal] = [:]
        var dayOrder: [Date] = []
        for offset in (0...6).reversed() {
            if let d = calendar.date(byAdding: .day, value: -offset, to: startOfToday) {
                dayBuckets[d] = DayTotal(date: d)
                dayOrder.append(d)
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

            // Day-by-day history chart is always the rolling last-7-calendar-days.
            if e.timestamp >= weekStart {
                let day = calendar.startOfDay(for: e.timestamp)
                if dayBuckets[day] != nil {
                    dayBuckets[day]!.workTokens += e.workTokens
                    dayBuckets[day]!.totalTokens += e.totalTokens
                    dayBuckets[day]!.costUSD += cost
                }
            }

            if calendar.isDate(e.timestamp, inSameDayAs: now) {
                agg.today.add(e, cost: cost, weight: weight)
                var mt = modelMap[e.family] ?? ModelTotal(family: e.family)
                mt.workTokens += e.workTokens
                mt.totalTokens += e.totalTokens
                mt.costUSD += cost
                mt.unpriced = pricing.isUnpriced(e.family)
                modelMap[e.family] = mt
            }

            if e.family == .other { agg.unknownModels.insert(e.model) }
        }

        // Stable, meaningful order: known families first, then other; by total tokens desc.
        agg.todayByModel = modelMap.values.sorted {
            if $0.unpriced != $1.unpriced { return !$0.unpriced }
            return $0.totalTokens > $1.totalTokens
        }
        agg.weekDaily = dayOrder.map { dayBuckets[$0] ?? DayTotal(date: $0) }
        return agg
    }
}
