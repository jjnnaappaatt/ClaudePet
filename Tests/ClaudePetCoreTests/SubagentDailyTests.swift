import Testing
import Foundation
@testable import ClaudePetCore

/// The subagent slice is now carried **per day**, not just per window — `DayTotal` gained
/// `sidechainWorkTokens`/`sidechainTotalTokens` so the dashboard can chart subagents/day.
///
/// The invariant that matters is reconciliation: the per-day buckets must sum to the window total the
/// same way `weekDaily` already sums to `week`. A chart that didn't add up to the figure beside it
/// would read as a bug, which is the same reasoning behind `cycleDaily`'s in-cycle predicate.
@Suite struct SubagentDailyTests {

    let pricing = PricingTable.default

    /// Fixed calendar + instants — `Calendar.current` on this machine is the **Buddhist** calendar
    /// (year 2569), which has already made a test in this repo silently assert nothing.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var now: Date { at(2026, 7, 16) }

    /// The seven days ending with `now`'s date, half-open at the top like the real weekly window.
    private var week: (start: Date, end: Date) {
        (cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!,
         cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!)
    }

    @Test func perDaySubagentBucketsSumToTheWindowTotal() {
        var entries: [UsageEntry] = []
        for d in 0..<5 {
            let day = cal.date(byAdding: .day, value: -d, to: now)!
            entries.append(TestSupport.entry(at: day, input: 1000, output: 500))
            entries.append(TestSupport.entry(at: day, input: 100, output: 50, cacheRead: 900,
                                             sidechain: true))
        }
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal,
                                     weekWindow: week)
        let summed = agg.weekDaily.reduce(0) { $0 + $1.sidechainWorkTokens }
        #expect(summed == agg.week.sidechainWorkTokens)
        #expect(summed == 5 * 150)
        let summedTotal = agg.weekDaily.reduce(0) { $0 + $1.sidechainTotalTokens }
        #expect(summedTotal == agg.week.sidechainTotalTokens)
        #expect(summedTotal == 5 * 1050)
    }

    /// The slice must never exceed the day it belongs to, on either basis.
    @Test func theSliceNeverExceedsItsDay() {
        let entries = [
            TestSupport.entry(at: now, input: 900, output: 100),
            TestSupport.entry(at: now, input: 90, output: 10, cacheRead: 500, sidechain: true),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal,
                                     weekWindow: week)
        for d in agg.weekDaily {
            #expect(d.sidechainWorkTokens <= d.workTokens)
            #expect(d.sidechainTotalTokens <= d.totalTokens)
        }
    }

    /// A day with no subagent turns carries a zero slice, not a nil or a copy of the day's total —
    /// otherwise the chart would draw a full bar for a day that delegated nothing.
    @Test func aDayWithoutSubagentsCarriesZero() {
        let agg = Aggregator.compute(entries: [TestSupport.entry(at: now, input: 500, output: 500)],
                                     pricing: pricing, now: now, calendar: cal, weekWindow: week)
        #expect(agg.weekDaily.allSatisfy { $0.sidechainWorkTokens == 0 })
        #expect(agg.week.sidechainWorkTokens == 0)
    }

    /// The cycle buckets carry the same slice, and reconcile against the cycle total the way
    /// `cycleDaily` already reconciles against `cycle`.
    @Test func cycleBucketsCarryTheSameSlice() {
        let cycle = (start: at(2026, 6, 16, 3), end: at(2026, 7, 16, 3))
        let entries = [
            TestSupport.entry(at: at(2026, 6, 20), input: 100, output: 100, sidechain: true),
            TestSupport.entry(at: at(2026, 7, 1), input: 200, output: 200),
            // Outside the cycle at both ends — neither may reach the buckets or the total.
            TestSupport.entry(at: at(2026, 6, 10), input: 999, output: 999, sidechain: true),
            TestSupport.entry(at: at(2026, 7, 20), input: 999, output: 999, sidechain: true),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal,
                                     cycleWindow: cycle)
        #expect(agg.cycleDaily.reduce(0) { $0 + $1.sidechainWorkTokens }
                == agg.cycle.sidechainWorkTokens)
        #expect(agg.cycle.sidechainWorkTokens == 200)
    }

    /// `allTimeByProject` is the cycle split's lifetime twin, and must reconcile against `allTime`
    /// the way `cycleByProject` does against `cycle`.
    @Test func allTimeByProjectSumsToAllTime() {
        // One entry inside the cycle and one long before it, so the two series MUST differ.
        let entries = [
            TestSupport.entry(at: at(2026, 7, 10), input: 300, output: 200, project: "/a/one"),
            TestSupport.entry(at: at(2025, 12, 1), input: 700, output: 800, project: "/a/two"),
        ]
        let cycle = (start: at(2026, 7, 6, 3), end: at(2026, 8, 6, 3))
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal,
                                     cycleWindow: cycle)
        #expect(agg.allTimeByProject.reduce(0) { $0 + $1.workTokens } == agg.allTime.workTokens)
        #expect(agg.allTimeByProject.reduce(0) { $0 + $1.totalTokens } == agg.allTime.totalTokens)
        #expect(abs(agg.allTimeByProject.reduce(0) { $0 + $1.costUSD } - agg.allTime.costUSD) < 1e-9)
        // And the cycle version still means what it meant.
        #expect(agg.cycleByProject.reduce(0) { $0 + $1.workTokens } == agg.cycle.workTokens)
        #expect(agg.allTimeByProject.count == 2, "the pre-cycle project must appear in the lifetime split")
        #expect(agg.cycleByProject.count == 1, "…and must NOT appear in the cycle split")
    }
}
