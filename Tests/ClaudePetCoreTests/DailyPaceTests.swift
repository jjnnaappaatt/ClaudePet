import Testing
import Foundation
@testable import ClaudePetCore

@MainActor
@Suite struct DailyPaceTests {

    private func freshStore() -> MetricsStore {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let store = MetricsStore(defaults: d)
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

    @Test func averageExcludesTodayAndZeroDays() {
        let store = freshStore()
        // today=1000; priors 300, 0 (skipped), 900 → avg over the two non-zero priors = 600.
        store.weekDaily = [day(0, work: 1000), day(1, work: 300), day(2, work: 0), day(3, work: 900)]
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 600)
        #expect(store.dailyTodayValue(unit: .tokens, now: now, calendar: cal) == 1000)
        #expect(store.hasDailyHistory(now: now, calendar: cal))
    }

    @Test func fractionMidpointAtAverage() {
        let store = freshStore()
        store.weekDaily = [day(0, work: 600), day(1, work: 600)]   // today == avg → midpoint
        #expect(abs(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) - 0.5) < 0.0001)
    }

    @Test func fractionFullAtDoubleAverage() {
        let store = freshStore()
        store.weekDaily = [day(0, work: 5000), day(1, work: 500)]   // today ≫ 2× avg → clamps to 1
        #expect(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) == 1.0)
    }

    @Test func zeroTodayGivesEmptyBar() {
        let store = freshStore()
        store.weekDaily = [day(0, work: 0), day(1, work: 800)]
        #expect(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) == 0)
    }

    @Test func noPriorHistoryIsZeroAndFlagged() {
        let store = freshStore()
        store.weekDaily = [day(0, work: 1200)]   // only today has data
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 0)
        #expect(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) == 0)
        #expect(!store.hasDailyHistory(now: now, calendar: cal))
    }

    @Test func usdUnitUsesCost() {
        let store = freshStore()
        store.weekDaily = [day(0, work: 1, cost: 4.0), day(1, work: 1, cost: 2.0)]
        #expect(store.dailyTodayValue(unit: .usd, now: now, calendar: cal) == 4.0)
        #expect(store.dailyAverage(unit: .usd, now: now, calendar: cal) == 2.0)
    }

    @Test func todayValueFallsBackToTotalsWhenNoBucket() {
        let store = freshStore()
        store.today = Totals(workTokens: 777, totalTokens: 7770, costUSD: 1.5)
        store.weekDaily = [day(1, work: 500), day(2, work: 700)]   // no bucket for today
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
        store.weekDaily = [d]
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
