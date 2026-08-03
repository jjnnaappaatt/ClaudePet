import Testing
import Foundation
@testable import ClaudePetCore

/// `allTimeDaily` — the lifetime per-day series — and the rolling 30-day baseline the two pace bars
/// average over.
///
/// **Why it exists.** `dailyAverage` used to read `weekDaily`, the rate-limit window's buckets.
/// `Aggregator` only fills those from entries inside the *current* window, so every weekly reset
/// wiped them to a single slot — today — and the average, which excludes today and excludes zero
/// days, had nothing left to average. The bar fell back to "building daily average…" while the
/// figure directly above it stayed correct. Reported live an hour after a Monday 15:00 reset, and it
/// would have recurred every week.
@Suite struct DailyBaselineTests {

    let pricing = PricingTable.default

    /// Fixed Gregorian calendar and fixed instants. `Calendar.current` on this machine is the
    /// **Buddhist** calendar (`Asia/Bangkok`, year 2569) — `DailyPaceTests` and `AggregatorTests`
    /// both use it bare, which is a latent hazard rather than a pattern to copy.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// 2026-07-15, a **Wednesday** (verified). The weekday matters for `excludesTodayByDateNotWeekday`.
    private var now: Date { at(2026, 7, 15) }

    @MainActor private func freshStore() -> MetricsStore {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = TestSupport.store(defaults: d)
        s.tokenBasis = .work
        return s
    }

    /// Exact on every Int, tolerant on the two accumulated Doubles — see the call site.
    private func expectSameTotals(_ a: Totals, _ b: Totals, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.workTokens == b.workTokens, sourceLocation: sourceLocation)
        #expect(a.totalTokens == b.totalTokens, sourceLocation: sourceLocation)
        #expect(a.sidechainWorkTokens == b.sidechainWorkTokens, sourceLocation: sourceLocation)
        #expect(a.sidechainTotalTokens == b.sidechainTotalTokens, sourceLocation: sourceLocation)
        #expect(abs(a.costUSD - b.costUSD) < 1e-9, sourceLocation: sourceLocation)
        #expect(abs(a.weightedTokens - b.weightedTokens) < 1e-6, sourceLocation: sourceLocation)
    }

    /// A day `offset` days before `now`, valued in work tokens (`totalTokens` scaled so a
    /// `.total`-basis assertion would also have something to bite on).
    private func day(_ offset: Int, work: Int, sidechain: Int = 0) -> DayTotal {
        DayTotal(date: cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!,
                 workTokens: work, totalTokens: work * 10, costUSD: Double(work) / 1000,
                 sidechainWorkTokens: sidechain, sidechainTotalTokens: sidechain * 10)
    }

    // MARK: - The series itself

    @Test func allTimeDailySumsToAllTime() {
        let entries = [
            TestSupport.entry(at: at(2026, 7, 15, 9), input: 100, output: 50),
            TestSupport.entry(at: at(2026, 7, 15, 18), input: 10, output: 5),   // same date, 2nd bucket hit
            TestSupport.entry(at: at(2026, 6, 1), input: 1000, output: 0),
            TestSupport.entry(at: at(2025, 12, 1), input: 7, output: 3, sidechain: true),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        #expect(agg.allTimeDaily.count == 3)   // 3 distinct dates, not 4 entries
        #expect(agg.allTimeDaily.reduce(0) { $0 + $1.workTokens } == agg.allTime.workTokens)
        #expect(agg.allTimeDaily.reduce(0) { $0 + $1.totalTokens } == agg.allTime.totalTokens)
        #expect(abs(agg.allTimeDaily.reduce(0) { $0 + $1.costUSD } - agg.allTime.costUSD) < 1e-9)
        // The sidechain slice reconciles too — `subagentDailyAverage` reads it per bucket.
        #expect(agg.allTimeDaily.reduce(0) { $0 + $1.sidechainWorkTokens }
                == agg.allTime.sidechainWorkTokens)
        #expect(agg.allTime.workTokens == 1175)   // 150 + 15 + 1000 + 10
    }

    /// `dailyAverage` takes a `.suffix` of this array to mean "the most recent N active days", so
    /// ascending order is a contract, not an accident. Entries are fed newest-first to prove the
    /// sort is real rather than inherited from the input.
    @Test func allTimeDailyIsSortedOldestFirst() {
        let entries = [
            TestSupport.entry(at: at(2026, 7, 15), input: 1, output: 0),
            TestSupport.entry(at: at(2026, 6, 1), input: 1, output: 0),
            TestSupport.entry(at: at(2025, 12, 1), input: 1, output: 0),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        #expect(agg.allTimeDaily.map(\.date) == agg.allTimeDaily.map(\.date).sorted())
        #expect(agg.allTimeDaily.first?.date == at(2025, 12, 1, 0))
        #expect(agg.allTimeDaily.last?.date == at(2026, 7, 15, 0))
    }

    /// Lifetime means lifetime: an entry outside the billing cycle AND outside the rate-limit week
    /// still gets a bucket. Mirrors `SubagentDailyTests.allTimeByProjectSumsToAllTime`'s fixture.
    @Test func allTimeDailyIncludesEntriesOutsideEveryWindow() {
        let cycle = (start: at(2026, 7, 4), end: at(2026, 8, 4))
        let week = (start: at(2026, 7, 13, 15), end: at(2026, 7, 20, 15))
        let old = TestSupport.entry(at: at(2025, 12, 1), input: 500, output: 0)
        let agg = Aggregator.compute(entries: [old], pricing: pricing, now: now, calendar: cal,
                                     cycleWindow: cycle, weekWindow: week)
        #expect(agg.cycle.workTokens == 0)
        #expect(agg.week.workTokens == 0)
        #expect(agg.allTimeDaily.count == 1)
        #expect(agg.allTimeDaily[0].workTokens == 500)
    }

    // MARK: - The baseline window

    /// **The headline regression.** `isCurrentDayBucket` matches on WEEKDAY — right for a 7-slot
    /// week array (7 slots are 7 distinct weekdays), silently wrong over a long series, where it
    /// drops every same-weekday day instead of just today.
    ///
    /// `now` is a Wednesday. Five prior Wednesdays carry 200 each; five other prior days carry 100.
    /// Excluding by date averages all ten: (5·200 + 5·100)/10 = **150**. Excluding by weekday keeps
    /// only the five non-Wednesdays: **100**. On the real 61-day corpus the same defect dropped 4
    /// days and moved the average +4.8%, swinging −6.6%…+3.5% with nothing but the calendar.
    @MainActor
    @Test func dailyAverageExcludesTodayByDateNotWeekday() {
        let wednesdays = [at(2026, 7, 8), at(2026, 7, 1), at(2026, 6, 24),
                          at(2026, 6, 17), at(2026, 6, 10)]
        let others = [at(2026, 7, 14), at(2026, 7, 13), at(2026, 7, 10),
                      at(2026, 7, 9), at(2026, 7, 7)]
        var entries = [TestSupport.entry(at: now, input: 999, output: 0)]   // today, must be excluded
        entries += wednesdays.map { TestSupport.entry(at: $0, input: 200, output: 0) }
        entries += others.map { TestSupport.entry(at: $0, input: 100, output: 0) }

        // Every fixture date really is the weekday this test claims.
        for d in wednesdays { #expect(cal.component(.weekday, from: d) == 4) }
        for d in others { #expect(cal.component(.weekday, from: d) != 4) }
        #expect(cal.component(.weekday, from: now) == 4)

        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        let store = freshStore()
        store.allTimeDaily = agg.allTimeDaily
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 150)
    }

    /// The window is the last N ACTIVE days, so older history stops counting rather than diluting
    /// forever. 40 prior days: the newest 30 at 100, the oldest 10 at 1 — the average is exactly 100
    /// only if those 10 are outside the window.
    @MainActor
    @Test func dailyAverageUsesAtMostThirtyPriorActiveDays() {
        let store = freshStore()
        // Oldest first, matching `Aggregator`'s contract.
        store.allTimeDaily = ((1...40).reversed()).map { off in
            day(off, work: off <= MetricsStore.dailyBaselineDays ? 100 : 1)
        }
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 100)
        #expect(MetricsStore.dailyBaselineDays == 30)
    }

    /// **Filter order.** `> 0` runs before `.suffix`, so the window holds 30 days that had usage —
    /// not 30 slots of which some were empty.
    ///
    /// Oldest 10 days carry 1000; the newest 30 alternate 0 and 100 (15 non-zero). Filtering first
    /// leaves 25 non-zero values, all inside a 30-wide window: (10·1000 + 15·100)/25 = **460**.
    /// Slicing first would take the newest 30 slots and average only their 15 non-zero days = 100.
    @MainActor
    @Test func zeroValueDaysAreDroppedBeforeTheThirtyDayCut() {
        let store = freshStore()
        store.allTimeDaily = ((1...40).reversed()).map { off in
            off > 30 ? day(off, work: 1000) : day(off, work: off.isMultiple(of: 2) ? 0 : 100)
        }
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 460)
    }

    /// The subagent baseline picks its OWN active days: a day that ran turns but delegated none of
    /// them must not consume a slot. So the two averages legitimately span different date ranges —
    /// on real data 07-01…08-01 for work against 06-28…07-31 for subagents.
    ///
    /// 40 prior days all with work 100; every 4th also has 50 subagent tokens (10 such days).
    /// Work: newest 30 of 40 → 100. Subagent: all 10 → 50, reaching back past the work window.
    @MainActor
    @Test func subagentDailyAverageWindowsItsOwnActiveDays() {
        let store = freshStore()
        store.allTimeDaily = ((1...40).reversed()).map { off in
            day(off, work: 100, sidechain: off.isMultiple(of: 4) ? 50 : 0)
        }
        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 100)
        #expect(store.subagentDailyAverage(unit: .tokens, now: now, calendar: cal) == 50)
        // The subagent sample genuinely reaches further back than the work one: its oldest
        // contributing day is 40 days ago, while the work window stops at 30.
        #expect(store.allTimeDaily.filter { $0.sidechainWorkTokens > 0 }.count == 10)
    }

    /// **The reported bug, end to end.** A weekly reset leaves `weekDaily` holding only today, which
    /// is exactly the state that blanked the bar. `allTimeDaily` is unaffected by that reset, so the
    /// baseline survives it.
    @MainActor
    @Test func paceBaselineSurvivesAWeeklyReset() {
        let store = freshStore()
        // Post-reset: the rate-limit window has one slot with anything in it, and it is today's.
        store.weekDaily = [day(0, work: 592_045)]
        store.calendarWeekDaily = [day(0, work: 592_045)]
        // The lifetime series still has a month of history behind it.
        store.allTimeDaily = ((1...30).reversed()).map { day($0, work: 3_500_000) } + [day(0, work: 592_045)]

        #expect(store.dailyAverage(unit: .tokens, now: now, calendar: cal) == 3_500_000)
        #expect(store.hasDailyHistory(now: now, calendar: cal))
        #expect(store.dailyPaceFraction(unit: .tokens, now: now, calendar: cal) > 0)
        #expect(!store.dailyPaceExceedsAverage(unit: .tokens, now: now, calendar: cal))
    }

    // MARK: - Correctness of the day-key cache

    /// The loop caches one `startOfDay` per day instead of per entry. That boundary must be exact
    /// local midnight even months from any anchor, in a DST-observing zone — which is why it steps
    /// with `calendar.date(byAdding: .day:)` and never `+86_400`. Same rule as the calendar week's.
    @Test func allTimeDailyBucketsAreExactLocalMidnightAcrossDST() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026 US DST: forward 8 Mar, back 1 Nov. Straddle both, from either side.
        let dates = [DateComponents(year: 2026, month: 3, day: 7, hour: 23),
                     DateComponents(year: 2026, month: 3, day: 9, hour: 1),
                     DateComponents(year: 2026, month: 7, day: 15, hour: 12),
                     DateComponents(year: 2026, month: 10, day: 31, hour: 23),
                     DateComponents(year: 2026, month: 11, day: 2, hour: 1)]
        let entries = dates.map { TestSupport.entry(at: ny.date(from: $0)!, input: 10, output: 0) }
        let julyNow = ny.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: julyNow, calendar: ny)

        #expect(agg.allTimeDaily.count == 5)
        for bucket in agg.allTimeDaily {
            let c = ny.dateComponents([.hour, .minute, .second], from: bucket.date)
            #expect(c.hour == 0 && c.minute == 0 && c.second == 0)
        }
    }

    /// The day-key cache assumes ascending input for SPEED only — `LogScanner` sorts, which is what
    /// makes it hit ~99.9%. Correctness must not depend on that: an out-of-order entry simply misses
    /// and recomputes. `ingestForTesting` and every test fixture bypass the scanner, so this is not
    /// a hypothetical input.
    @Test func dayKeyCacheIsCorrectForUnsortedEntries() {
        let cycle = (start: at(2026, 7, 4), end: at(2026, 8, 4))
        let week = (start: at(2026, 7, 13, 15), end: at(2026, 7, 20, 15))
        var sorted: [UsageEntry] = []
        for d in 1...31 {
            sorted.append(TestSupport.entry(id: "e\(d)a", at: at(2026, 7, d, 9),
                                            input: d * 10, output: d))
            sorted.append(TestSupport.entry(id: "e\(d)b", at: at(2026, 7, d, 20),
                                            input: d, output: d, sidechain: true))
        }
        // A fixed, deliberately hostile reordering — reversed interleaves every day boundary.
        let shuffled: [UsageEntry] = sorted.reversed()

        let a = Aggregator.compute(entries: sorted, pricing: pricing, now: now, calendar: cal,
                                   cycleWindow: cycle, weekWindow: week)
        let b = Aggregator.compute(entries: shuffled, pricing: pricing, now: now, calendar: cal,
                                   cycleWindow: cycle, weekWindow: week)
        // Token counts are Ints and must match to the token. `costUSD`/`weightedTokens` are Doubles
        // accumulated in input order, and float addition is not associative — over 62 entries the
        // reversed run lands on 2555.0000000000005 against 2555.0. That is arithmetic, not the
        // cache: it was equally true before this change, and every Int field is exact.
        expectSameTotals(a.today, b.today)
        expectSameTotals(a.week, b.week)
        expectSameTotals(a.allTime, b.allTime)
        #expect(a.allTimeDaily.map(\.date) == b.allTimeDaily.map(\.date))
        #expect(a.allTimeDaily.map(\.workTokens) == b.allTimeDaily.map(\.workTokens))
        #expect(a.allTimeDaily.map(\.sidechainWorkTokens) == b.allTimeDaily.map(\.sidechainWorkTokens))
        #expect(a.cycleDaily == b.cycleDaily)
        #expect(a.weekDaily == b.weekDaily)
        #expect(a.calendarWeekDaily == b.calendarWeekDaily)
        // …and the sorted run is itself right, so "identical" isn't "identically empty".
        #expect(a.allTimeDaily.count == 31)
        #expect(a.today.workTokens > 0)
    }
}
