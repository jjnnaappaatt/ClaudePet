import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct HourlyTests {
    let cal = Calendar.current
    let pricing = PricingTable.default

    /// A fixed local day/time so hour bucketing is deterministic.
    private func at(hour: Int, dayOffset: Int = 0) -> Date {
        let base = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let startOfDay = cal.startOfDay(for: base)
        let day = cal.date(byAdding: .day, value: dayOffset, to: startOfDay)!
        return cal.date(byAdding: .hour, value: hour, to: day)!
    }
    private var now: Date { at(hour: 12) }

    @Test func producesTwentyFourOrderedBuckets() {
        let agg = Aggregator.compute(entries: [], pricing: pricing, now: now, calendar: cal)
        #expect(agg.todayHourly.count == 24)
        #expect(agg.todayHourly.map(\.hour) == Array(0...23))
    }

    @Test func entryLandsInItsLocalHourBucket() {
        let entries = [TestSupport.entry(at: at(hour: 9), input: 100, output: 20, cacheRead: 40)]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        let nine = agg.todayHourly[9]
        #expect(nine.workTokens == 120)              // input + output
        #expect(nine.totalTokens == 160)             // + cacheRead
        #expect(nine.costUSD > 0)
        // Every other bucket is empty.
        #expect(agg.todayHourly.filter { $0.workTokens > 0 }.map(\.hour) == [9])
    }

    @Test func excludesYesterdayFromToday() {
        let entries = [
            TestSupport.entry(at: at(hour: 9), input: 100, output: 0),                 // today 9am
            TestSupport.entry(at: at(hour: 9, dayOffset: -1), input: 500, output: 0),  // yesterday 9am
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        #expect(agg.todayHourly[9].workTokens == 100)   // yesterday's 500 excluded
    }

    @Test func hourlySumMatchesTodayTotal() {
        let entries = [
            TestSupport.entry(at: at(hour: 8), input: 100, output: 0),
            TestSupport.entry(at: at(hour: 10), input: 200, output: 30),
            TestSupport.entry(at: at(hour: 10), input: 50, output: 0),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        let sum = agg.todayHourly.reduce(0) { $0 + $1.workTokens }
        #expect(sum == agg.today.workTokens)
        #expect(sum == 380)
    }

    @MainActor @Test func peakHourFindsBusiestAndNilWhenEmpty() {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let store = MetricsStore(defaults: d)

        #expect(store.peakHour(unit: .tokens) == nil)          // no data yet
        store.todayHourly = (0...23).map {
            HourTotal(hour: $0, workTokens: $0 == 10 ? 5000 : ($0 == 8 ? 1000 : 0), costUSD: $0 == 10 ? 4 : 0)
        }
        #expect(store.peakHour(unit: .tokens) == 10)
        #expect(store.peakHour(unit: .usd) == 10)
    }

    @Test func hourLabelFormatsTwelveHourClock() {
        #expect(Format.hourLabel(0) == "12a")
        #expect(Format.hourLabel(9) == "9a")
        #expect(Format.hourLabel(12) == "12p")
        #expect(Format.hourLabel(18) == "6p")
        #expect(Format.hourLabel(23) == "11p")
    }
}
