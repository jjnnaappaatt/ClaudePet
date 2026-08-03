import Testing
import Foundation
@testable import ClaudePetCore

@MainActor
@Suite struct DailyPaceTests {

    private func freshStore() -> MetricsStore {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let store = TestSupport.store(defaults: d)
        // These pace-math tests assert work-basis numbers; the .total default is exercised
        // separately by `tokenBasisSelectsWorkVsTotal` / `peakHourFollowsTokenBasis` below.
        store.tokenBasis = .work
        return store
    }

    private let cal = Calendar.current
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 12))! }

    /// A day `offset` days before `now` (0 = today), with the given work tokens / cost.
    private func day(_ offset: Int, work: Int, cost: Double = 0) -> DayTotal {
        DayTotal(date: cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!,
                 workTokens: work, totalTokens: work * 100, costUSD: cost)
    }

    /// The pace math reads THREE series and these fixtures aren't testing which — so they populate
    /// all three from one array and let the individual tests assert on the arithmetic:
    ///
    ///   - `dailyAverage`     → `allTimeDaily`      (a lifetime series; the rate-limit week empties
    ///                                               on reset and left the bar with no baseline)
    ///   - `dailyTodayValue`  → `calendarWeekDaily` (can never fold two calendar dates into a slot)
    ///   - `weekDaily`        → the rate-limit window, still read by the /stats day extension
    ///
    /// `allTimeDaily` is stored oldest-first because `dailyAverage` takes a `.suffix` of it; `days`
    /// is written newest-first here, hence the reverse. It makes no difference at these sizes — the
    /// window is 30 and no fixture has more than 4 days — but the contract is the contract.
    private func seed(_ store: MetricsStore, _ days: [DayTotal]) {
        store.weekDaily = days
        store.calendarWeekDaily = days
        store.allTimeDaily = days.reversed()
    }

    @Test func averageExcludesTodayAndZeroDays() {
        let store = freshStore()
        // today=1000; priors 300, 0 (skipped), 900 → avg over the two non-zero priors = 600.
        seed(store, [day(0, work: 1000), day(1, work: 300), day(2, work: 0), day(3, work: 900)])
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 600)
        #expect(store.dailyTodayValue(unit: .tokens, now: now, calendar: cal) == 1000)
        #expect(store.hasDailyHistory(now: now, calendar: cal))
    }

    @Test func fractionIsFullAtAverage() {
        let store = freshStore()
        seed(store, [day(0, work: 600), day(1, work: 600)])   // today == a usual day → full
        #expect(abs(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) - 1.0) < 0.0001)
        #expect(!store.dailyPaceExceedsAverage(unit: .tokens, now: now, calendar: cal))
    }

    /// The fill has to equal the "today N%" printed beside it. The old scale put the average at
    /// the midpoint, so a day at 2/3 of normal drew a third of a bar and the two disagreed.
    @Test func fractionEqualsShareOfAUsualDay() {
        let store = freshStore()
        seed(store, [day(0, work: 400), day(1, work: 600)])   // today is 2/3 of a usual day
        #expect(abs(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) - 2.0 / 3.0) < 0.0001)
    }

    @Test func fractionClampsAndFlagsAboveAverage() {
        let store = freshStore()
        seed(store, [day(0, work: 5000), day(1, work: 500)])   // 10× a usual day → pinned full
        #expect(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) == 1.0)
        #expect(store.dailyPaceExceedsAverage(unit: .tokens, now: now, calendar: cal))
    }

    @Test func zeroTodayGivesEmptyBar() {
        let store = freshStore()
        seed(store, [day(0, work: 0), day(1, work: 800)])
        #expect(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) == 0)
    }

    @Test func noPriorHistoryIsZeroAndFlagged() {
        let store = freshStore()
        seed(store, [day(0, work: 1200)])   // only today has data
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 0)
        #expect(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) == 0)
        #expect(!store.hasDailyHistory(now: now, calendar: cal))
    }

    @Test func usdUnitUsesCost() {
        let store = freshStore()
        seed(store, [day(0, work: 1, cost: 4.0), day(1, work: 1, cost: 2.0)])
        #expect(store.dailyTodayValue(unit: .usd, now: now, calendar: cal) == 4.0)
        #expect(store.dailyAverage(unit: .usd, now: now, calendar: cal) == 2.0)
    }

    @Test func todayValueFallsBackToTotalsWhenNoBucket() {
        let store = freshStore()
        store.today = Totals(workTokens: 777, totalTokens: 7770, costUSD: 1.5)
        seed(store, [day(1, work: 500), day(2, work: 700)])   // no bucket for today
        #expect(store.dailyTodayValue(unit: .tokens, now: now, calendar: cal) == 777)
        #expect(store.dailyTodayValue(unit: .usd, now: now, calendar: cal) == 1.5)
    }

    @Test func tokenBasisSelectsWorkVsTotal() {
        let store = freshStore()                       // freshStore pins .work
        let d = day(0, work: 1000)                     // totalTokens = work * 100 = 100_000
        let t = Totals(workTokens: 1000, totalTokens: 100_000, costUSD: 2)
        let h = HourTotal(hour: 9, workTokens: 1000, totalTokens: 100_000)
        let m = ModelTotal(family: .opus, workTokens: 1000, totalTokens: 100_000, costUSD: 2)

        store.tokenBasis = .work
        #expect(store.dayTokens(d) == 1000)
        #expect(store.hourTokens(h) == 1000)
        #expect(store.modelTokens(m) == 1000)
        #expect(store.totalsTokens(t) == 1000)

        store.tokenBasis = .total
        #expect(store.dayTokens(d) == 100_000)
        #expect(store.hourTokens(h) == 100_000)
        #expect(store.modelTokens(m) == 100_000)
        #expect(store.totalsTokens(t) == 100_000)

        // The daily-pace "today" value follows the basis too (via dayValue over the series).
        seed(store, [d])
        store.tokenBasis = .work
        #expect(store.dailyTodayValue(unit: .tokens, now: now, calendar: cal) == 1000)
        store.tokenBasis = .total
        #expect(store.dailyTodayValue(unit: .tokens, now: now, calendar: cal) == 100_000)
    }

    @Test func peakHourFollowsTokenBasis() {
        let store = freshStore()
        // Hour 9 is the work-heaviest; hour 14 is the total(cache)-heaviest.
        store.todayHourly = (0...23).map { hr in
            if hr == 9  { return HourTotal(hour: 9,  workTokens: 100, totalTokens: 100) }
            if hr == 14 { return HourTotal(hour: 14, workTokens: 10,  totalTokens: 10_000) }
            return HourTotal(hour: hr)
        }
        store.tokenBasis = .work
        #expect(store.peakHour(unit: .tokens) == 9)
        store.tokenBasis = .total
        #expect(store.peakHour(unit: .tokens) == 14)
    }
}
