import Foundation

public struct Totals: Sendable, Equatable {
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0

    public mutating func add(_ e: UsageEntry, cost: Double) {
        workTokens += e.workTokens
        totalTokens += e.totalTokens
        costUSD += cost
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

public struct Aggregates: Sendable, Equatable {
    public var today: Totals = .init()
    public var week: Totals = .init()
    public var allTime: Totals = .init()
    public var todayByModel: [ModelTotal] = []
    public var unknownModels: Set<String> = []
}

/// Rolls deduplicated entries into today / week / all-time totals plus a
/// per-model breakdown for today. `now`/`calendar` are injectable for tests.
public enum Aggregator {
    public static func compute(entries: [UsageEntry],
                               pricing: PricingTable,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> Aggregates {
        var agg = Aggregates()

        let startOfToday = calendar.startOfDay(for: now)
        // Rolling 7 calendar days incl. today.
        let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var modelMap: [ModelFamily: ModelTotal] = [:]

        for e in entries {
            let cost = pricing.cost(for: e)
            agg.allTime.add(e, cost: cost)

            if e.timestamp >= weekStart { agg.week.add(e, cost: cost) }

            if calendar.isDate(e.timestamp, inSameDayAs: now) {
                agg.today.add(e, cost: cost)
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
        return agg
    }
}
