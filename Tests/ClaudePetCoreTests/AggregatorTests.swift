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

    /// The chart bars tile the weekly-limit window, so they must sum to exactly the weekly total.
    /// They used to be the rolling last-7-calendar-days while `week` was the fixed reset window —
    /// so usage earlier on reset day appeared in the chart but not in the limit, and adding up the
    /// visible bars gave a bigger number than the gauge above them.
    @Test func weeklyChartBarsSumToTheWeeklyTotal() {
        let now = noon
        // Reset landed 21h ago — mid-afternoon yesterday — so reset day is split in two, which is
        // exactly the case calendar-day buckets got wrong.
        let windowStart = now.addingTimeInterval(-21 * 3600)
        let window = (start: windowStart, end: windowStart.addingTimeInterval(7 * 86_400))
        let entries = [
            TestSupport.entry(at: windowStart.addingTimeInterval(-3600), input: 900, output: 90), // pre-reset
            TestSupport.entry(at: windowStart.addingTimeInterval(60), input: 100, output: 10),    // cell 0
            TestSupport.entry(at: now, input: 50, output: 5),                                     // cell 0 (21h in)
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal,
                                     weekWindow: window)
        #expect(agg.week.workTokens == 165)                       // the pre-reset entry reset off
        #expect(agg.weekDaily.count == 8)                         // mid-day reset → reset day at both ends
        #expect(agg.weekDaily.reduce(0) { $0 + $1.workTokens } == agg.week.workTokens)

        // Reset day is the first bar and holds only what counts toward the limit.
        #expect(cal.isDate(agg.weekDaily[0].date, inSameDayAs: windowStart))
        #expect(agg.weekDaily[0].workTokens == 110)

        // The bar holding `now` is TODAY's calendar day. Anchoring 24h cells to the reset instant
        // summed correctly but put `now` in a cell that began the previous afternoon, so the chart
        // highlighted (and labelled) the wrong weekday — Saturday on a Sunday.
        let todayBar = agg.weekDaily.first { cal.isDate($0.date, inSameDayAs: now) }
        #expect(todayBar?.workTokens == 55)
        #expect(agg.allTime.workTokens == 165 + 990)              // …but it still counts all-time
    }

    /// Without a window (callers/tests that pass none) the chart stays rolling calendar days.
    @Test func weeklyChartFallsBackToCalendarDaysWithoutAWindow() {
        let now = noon
        let agg = Aggregator.compute(entries: [TestSupport.entry(at: now, input: 10, output: 1)],
                                     pricing: pricing, now: now, calendar: cal)
        #expect(agg.weekDaily.count == 7)
        #expect(agg.weekDaily.last?.date == cal.startOfDay(for: now))
        #expect(agg.weekDaily.last?.workTokens == 11)
    }

    @Test func tracksUnknownModels() {
        let now = noon
        let entries = [TestSupport.entry(at: now, model: "claude-zeta-1", input: 10, output: 1)]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        #expect(agg.unknownModels.contains("claude-zeta-1"))
        #expect(agg.todayByModel.first?.unpriced == true)
    }
}
