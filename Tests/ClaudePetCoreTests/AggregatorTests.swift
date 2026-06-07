import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct AggregatorTests {
    let cal = Calendar.current
    let pricing = PricingTable.default

    private var noon: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 7; c.hour = 12; c.minute = 0
        return cal.date(from: c)!
    }

    @Test func splitsTodayWeekAllTimeByLocalDay() {
        let now = noon
        let entries = [
            TestSupport.entry(at: now, input: 100, output: 10),                          // today
            TestSupport.entry(at: cal.date(byAdding: .day, value: -1, to: now)!, input: 50, output: 5),   // week, not today
            TestSupport.entry(at: cal.date(byAdding: .day, value: -10, to: now)!, input: 30, output: 3),  // all-time only
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        #expect(agg.today.workTokens == 110)
        #expect(agg.week.workTokens == 110 + 55)
        #expect(agg.allTime.workTokens == 110 + 55 + 33)
    }

    @Test func perModelBreakdownIsForToday() {
        let now = noon
        let entries = [
            TestSupport.entry(at: now, model: "claude-opus-4-8", input: 100, output: 0),
            TestSupport.entry(at: now, model: "claude-sonnet-4-6", input: 200, output: 0),
            TestSupport.entry(at: now, model: "claude-sonnet-4-6", input: 50, output: 0),
            TestSupport.entry(at: cal.date(byAdding: .day, value: -2, to: now)!, model: "claude-haiku-4-5", input: 999, output: 0),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        let families = Set(agg.todayByModel.map(\.family))
        #expect(families == [.opus, .sonnet])           // haiku entry was 2 days ago
        let sonnet = agg.todayByModel.first { $0.family == .sonnet }!
        #expect(sonnet.workTokens == 250)
    }

    @Test func tracksUnknownModels() {
        let now = noon
        let entries = [TestSupport.entry(at: now, model: "claude-zeta-1", input: 10, output: 1)]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        #expect(agg.unknownModels.contains("claude-zeta-1"))
        #expect(agg.todayByModel.first?.unpriced == true)
    }
}
