import Testing
import Foundation
@testable import ClaudePetCore

@MainActor
@Suite struct DailyPaceTests {

    private func freshStore() -> MetricsStore {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return MetricsStore(defaults: d)
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
}
