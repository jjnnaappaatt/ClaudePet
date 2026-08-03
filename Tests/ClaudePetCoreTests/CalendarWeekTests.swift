import Testing
import Foundation
@testable import ClaudePetCore

/// `calendarWeek`/`calendarWeekDaily` — a fixed Sunday-to-Saturday calendar week, deliberately
/// independent of the weekly usage-LIMIT window (`week`/`weekDaily`).
///
/// It exists because viewing the rate-limit window on its own reset weekday, before the reset
/// instant, shows last week's Tue–Fri under labels that read as "future days already have usage" —
/// real data, correctly counted, but confusing. A midnight-aligned boundary can't split a day, so
/// there's nothing to fold back the way `weekDaily` has to.
@Suite struct CalendarWeekTests {

    let pricing = PricingTable.default

    /// Fixed Gregorian calendar, fixed instants — `Calendar.current` on this machine is the
    /// **Buddhist** calendar (year 2569 today), which has already made a test in this repo silently
    /// assert nothing. `AggregatorTests.swift` uses bare `Calendar.current`; deliberately not
    /// following that pattern here.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// 2026-07-15 is a Wednesday. Verified: 07-11 Sat, 07-12 Sun, 07-18 Sat, 07-19 Sun.
    private var now: Date { at(2026, 7, 15) }

    @Test func calendarWeekDailySumsToCalendarWeekAndHasSevenBuckets() {
        let entries = [
            TestSupport.entry(at: at(2026, 7, 12), input: 100, output: 0),  // Sun, this cal-week
            TestSupport.entry(at: at(2026, 7, 15), input: 50, output: 0),   // Wed, today
            TestSupport.entry(at: at(2026, 7, 18), input: 900, output: 0),  // Sat, this cal-week
            TestSupport.entry(at: at(2026, 7, 19), input: 999, output: 0),  // next Sun — excluded
            TestSupport.entry(at: at(2026, 7, 11), input: 999, output: 0),  // prev Sat — excluded
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        #expect(agg.calendarWeekDaily.count == 7)
        #expect(agg.calendarWeekDaily.reduce(0) { $0 + $1.workTokens } == agg.calendarWeek.workTokens)
        #expect(agg.calendarWeek.workTokens == 1050)   // 100 (Sun) + 50 (Wed) + 900 (Sat) — both
                                                        // out-of-week entries correctly excluded
    }

    /// Independence from the rate-limit anchor: a `weekWindow` that shares nothing with the
    /// calendar week (a Thursday-3pm reset) must not move the calendar week's own boundary.
    @Test func calendarWeekBucketZeroIsAlwaysSundayRegardlessOfTheRateLimitWindow() {
        let rateWindow = (start: at(2026, 7, 9, 15), end: at(2026, 7, 16, 15))
        let agg = Aggregator.compute(entries: [], pricing: pricing, now: now, calendar: cal,
                                     weekWindow: rateWindow)
        #expect(cal.component(.weekday, from: agg.calendarWeekDaily[0].date) == 1)
        #expect(agg.calendarWeekDaily[0].date == at(2026, 7, 12, 0))
    }

    /// The direct encoding of the user's stated goal: two entries either side of a real Sunday
    /// midnight must land in DIFFERENT buckets — the opposite property from `weekDaily`'s
    /// `resetDayGetsOneBarHoldingBothEndsOfTheWindow`, which deliberately folds both ends together.
    @Test func entriesStraddlingASundayBoundaryLandInDifferentWeeks() {
        let saturdayNight = at(2026, 7, 11, 23)
        let sundayMorning = at(2026, 7, 12, 1)
        let agg = Aggregator.compute(entries: [
            TestSupport.entry(at: saturdayNight, input: 700, output: 0),
            TestSupport.entry(at: sundayMorning, input: 300, output: 0),
        ], pricing: pricing, now: now, calendar: cal)
        #expect(agg.calendarWeek.workTokens == 300)          // only Sunday's entry is in THIS week
        #expect(agg.calendarWeekDaily[0].workTokens == 300)  // Sunday's own bucket, not Saturday's
    }

    /// Genuinely decoupled, not `week` relabeled — using the same mid-day-reset shape the existing
    /// `weekDaily` tests use, an entry can be inside one window and outside the other.
    @Test func calendarWeekGenuinelyDiffersFromTheRateLimitWeek() {
        let window = (start: at(2026, 7, 9, 15), end: at(2026, 7, 16, 15))   // Thu 3pm reset
        let entries = [
            // Fri: inside the calendar week [Jul12, Jul19), but the rate window closed the day
            // before (Thu 15:00) — so it's the entry that proves the two windows are genuinely
            // different, not just two names for the same predicate.
            TestSupport.entry(at: at(2026, 7, 17, 12), input: 900, output: 0),
            TestSupport.entry(at: at(2026, 7, 12, 12), input: 300, output: 0), // Sun: in both
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal,
                                     weekWindow: window)
        #expect(agg.calendarWeek.workTokens != agg.week.workTokens)
        #expect(agg.calendarWeek.workTokens == 1200)
        #expect(agg.week.workTokens == 300)
    }

    /// Regression for the DST drift a `WeeklyWindowEngine.window`-based implementation would have
    /// had: its own doc comment admits ±1h drift across a DST change, because it steps a fixed 7×24h
    /// in raw seconds from an epoch anchor. The calendar-week boundary must be exact local midnight
    /// even months after the anchor, in a DST-observing zone — calendar-DAY arithmetic guarantees
    /// this; second-based stepping does not.
    @Test func calendarWeekBoundaryIsExactLocalMidnightAcrossDST() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let julyNow = ny.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
        let agg = Aggregator.compute(entries: [], pricing: pricing, now: julyNow, calendar: ny)
        let c = ny.dateComponents([.hour, .minute, .weekday], from: agg.calendarWeekDaily[0].date)
        #expect(c.weekday == 1 && c.hour == 0 && c.minute == 0)
    }

    /// The exact bug this whole file exists to prevent, reproduced end to end through
    /// `Aggregator.compute` and `MetricsStore.dailyTodayValue`/`subagentTodayValue` — not just
    /// `calendarWeekDaily`'s own construction. On the rate-limit reset weekday, before the reset
    /// instant, `weekDaily`'s "today" bucket folds last week's post-reset tail into today's own
    /// figure; reported live, measured on a real Monday: 1,612,803 (last Monday's tail) +
    /// 432,336 (this Monday, actual) read as "2,045,139 today" against a true 415k-ish. This pins
    /// that `dailyTodayValue`/`subagentTodayValue` no longer do that, because `calendarWeekDaily`
    /// has nothing to fold — a calendar day belongs to exactly one bucket.
    @MainActor
    @Test func todayValueDoesNotFoldLastWeeksPostResetTailIntoTodaysFigure() {
        let name = "claudepet-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = TestSupport.store(defaults: defaults)
        store.tokenBasis = .work
        // A rate-limit window reset THIS Monday (`now`'s own weekday) at 15:00 — still 3h from
        // `now` (noon), so the ACTIVE window is last-Monday-15:00 -> this-Monday-15:00, the exact
        // shape that folds. 2026-07-13/07-06 are both Mondays (verified).
        let today = at(2026, 7, 13)
        let lastMondayEvening = at(2026, 7, 6, 20)
        let rateWindow = (start: at(2026, 7, 6, 15), end: at(2026, 7, 13, 15))
        // The sidechain entry's tokens count toward today's TOTAL as well as its own slice —
        // `isSidechain` marks a subset, not a separate pool — so today's full total is
        // 400,000 + 32,336 + 60,000 + 5,000 = 497,336, and the subagent slice alone is 65,000.
        let entries = [
            TestSupport.entry(at: lastMondayEvening, input: 1_600_000, output: 12_803),  // last week's tail
            TestSupport.entry(at: today, input: 400_000, output: 32_336, sidechain: false),
            TestSupport.entry(at: today, input: 60_000, output: 5_000, sidechain: true),
        ]
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: today, calendar: cal,
                                     weekWindow: rateWindow)
        store.today = agg.today
        store.weekDaily = agg.weekDaily
        store.calendarWeekDaily = agg.calendarWeekDaily

        // The fold is real and still present in `weekDaily` — confirms the fixture actually
        // reproduces the reported shape, not a scenario that never folded in the first place.
        let weekDailyToday = agg.weekDaily.first { cal.component(.weekday, from: $0.date)
                                                    == cal.component(.weekday, from: today) }
        #expect(weekDailyToday?.workTokens == 1_612_803 + 497_336)

        // `dailyTodayValue` must read ONLY today's own entries — all of today's total, not last
        // week's tail. `subagentTodayValue` must read only today's own subagent slice.
        #expect(store.dailyTodayValue(unit: .tokens, now: today, calendar: cal) == 497_336)
        #expect(store.subagentTodayValue(unit: .tokens, now: today, calendar: cal) == 65_000)
    }

    /// Sidechain reconciliation, mirroring `SubagentDailyTests.perDaySubagentBucketsSumToTheWindowTotal`
    /// — `SubagentShareChart` needs these fields populated per bucket, not just the parent totals.
    @Test func calendarWeekSidechainBucketsSumToCalendarWeeksSidechainTotal() {
        var entries: [UsageEntry] = []
        for d in [12, 13, 14, 15, 16, 17, 18] {   // the full Sun–Sat span
            let day = at(2026, 7, d)
            entries.append(TestSupport.entry(at: day, input: 1000, output: 500))
            entries.append(TestSupport.entry(at: day, input: 100, output: 50, sidechain: true))
        }
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now, calendar: cal)
        let summed = agg.calendarWeekDaily.reduce(0) { $0 + $1.sidechainWorkTokens }
        #expect(summed == agg.calendarWeek.sidechainWorkTokens)
        #expect(summed == 7 * 150)
    }
}
