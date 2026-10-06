import Testing
import Foundation
@testable import ClaudePetCore

/// The `/stats` headline is extended across every day Claude Code's cache hasn't folded in yet.
///
/// Why this exists: the rule used to be "add today, but only if the cache stopped at yesterday".
/// Anything staler showed the cache's own figure unchanged and unmarked — and Claude Code recomputes
/// that file when it feels like it, not daily. Measured live, it sat at 4 August through seven days of
/// continuous use, so the panel read 151.4M beside Claude Code's own 160.9M with nothing on screen to
/// say the number was a week old. Six days were missing, not one.
///
/// **Calendar note.** These use `TimeZone.current`, not a pinned UTC zone, and that is deliberate
/// rather than sloppy: `allTimeDaily`'s buckets are cut by `recompute()` using `Calendar.current`, so a
/// test that asked about them through a UTC calendar would compare local midnights against UTC ones
/// and drift a day on any machine east or west of Greenwich. Determinism here comes from pinning
/// `now` and every entry's instant — never from the wall clock — and the identifier is still pinned
/// Gregorian so the assertions read in 2026 rather than the Buddhist 2569.
@Suite struct StatsGapFillTests {

    /// One model with round numbers: `totalWorkTokens` is exactly 5,000,000, so every expectation
    /// below is legible arithmetic instead of a 9-digit constant. The cache tokens are deliberately
    /// enormous — 190× the work figure — because that ratio is what makes the display-basis trap
    /// expensive when it fires.
    private static let json = #"""
    {
      "version": 5,
      "lastComputedDate": "2026-07-29",
      "totalSessions": 10,
      "totalMessages": 100,
      "dailyActivity": [{"date":"2026-07-28"},{"date":"2026-07-29"}],
      "modelUsage": {
        "claude-opus-4-8": {"inputTokens":1000000,"outputTokens":4000000,
                            "cacheReadInputTokens":900000000,"cacheCreationInputTokens":50000000}
      }
    }
    """#

    private static let cacheWork = 5_000_000

    private func write(_ contents: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stats-cache.json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current            // must match what `recompute()` bucketed with — see above
        return c
    }

    /// Noon local, so an entry can never land on a neighbouring date through a DST shift.
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @MainActor
    private func store(_ entries: [UsageEntry]) throws -> MetricsStore {
        let name = "claudepet-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let s = TestSupport.store(defaults: defaults)
        s.statsCachePath = try write(Self.json)
        s.ingestForTesting(entries)
        return s
    }

    /// `work` tokens split across input/output, plus a cache slice ~190× larger — the real shape of a
    /// prompt-cached turn, and the thing `dayTokens` would wrongly include.
    private func entries(_ dates: [(Date, Int)]) -> [UsageEntry] {
        dates.map { date, work in
            TestSupport.entry(at: date, input: work / 5, output: work - work / 5,
                              cacheRead: work * 190)
        }
    }

    // MARK: - The fill itself

    /// **The headline test.** Four days sit between the cache's last day and `now`; all four are added.
    /// Reverting to the old `endsYesterday`-only rule returns the bare 5,000,000 and fails here while
    /// leaving the rest of the suite green — which is exactly how the seven-day-stale figure shipped.
    @MainActor
    @Test func fillsEveryDayAfterTheCacheNotJustToday() throws {
        let s = try store(entries([
            (day(2026, 7, 28), 111),          // before the cache's edge — already counted, must not add
            (day(2026, 7, 30), 100_000),
            (day(2026, 7, 31), 200_000),
            (day(2026, 8, 1), 300_000),
            (day(2026, 8, 2), 400_000),       // today
        ]))
        let now = day(2026, 8, 2)
        #expect(s.statsTotalTokens(now: now, calendar: cal) == Self.cacheWork + 1_000_000)
        #expect(s.statsFilledDays(now: now, calendar: cal) == 4)
        #expect(!s.statsIsDated(now: now, calendar: cal))
    }

    /// The cache's own last day is inside the cache. Adding it back is the double-count the old
    /// `covers` guard existed to prevent, and the new bound has to keep that property.
    @MainActor
    @Test func theCachesOwnLastDayIsNeverAddedTwice() throws {
        let s = try store(entries([(day(2026, 7, 29), 750_000)]))
        // `now` is the cache's own day: nothing after it exists.
        #expect(s.statsTotalTokens(now: day(2026, 7, 29), calendar: cal) == Self.cacheWork)
        #expect(s.statsFilledDays(now: day(2026, 7, 29), calendar: cal) == 0)
        // And a day later that same 29 July usage is still excluded — only the 30th onward is ours.
        #expect(s.statsTotalTokens(now: day(2026, 7, 30), calendar: cal) == Self.cacheWork)
    }

    /// A clock-skewed entry dated after `now` belongs to no window we can vouch for. The in-cycle
    /// predicate is half-open at both ends for the same reason; this bound matches it.
    @MainActor
    @Test func daysAfterNowAreNotFolded() throws {
        let s = try store(entries([
            (day(2026, 7, 28), 111),
            (day(2026, 7, 30), 100_000),
            (day(2026, 8, 9), 900_000),       // clock-skewed, eight days past `now`
        ]))
        #expect(s.statsTotalTokens(now: day(2026, 7, 30), calendar: cal) == Self.cacheWork + 100_000)
        #expect(s.statsFilledDays(now: day(2026, 7, 30), calendar: cal) == 1)
    }

    // MARK: - The trap that costs 190×

    /// **Work tokens, never the display basis.** `/stats`' figure excludes cache, but `dayTokens`
    /// routes through the user's `TokenBasis` — which defaults to `.total`. Summing the gap through it
    /// would splice a cache-inclusive slice onto a cache-excluded total, inflating each added day by
    /// the cache ratio (191× on this fixture, ~200× on real data).
    ///
    /// Nothing else can see this: the figure stays internally consistent, the panel still renders, and
    /// the number is simply wrong. Flip `d.workTokens` to `dayTokens(d)` and only this test moves.
    @MainActor
    @Test func fillUsesWorkTokensRegardlessOfTheDisplayBasis() throws {
        let s = try store(entries([
            (day(2026, 7, 28), 111),          // reaches back past the cache, so the fill is allowed
            (day(2026, 7, 30), 100_000),
            (day(2026, 7, 31), 200_000),
        ]))
        let now = day(2026, 7, 31)

        s.tokenBasis = .work
        let onWork = s.statsTotalTokens(now: now, calendar: cal)
        s.tokenBasis = .total
        let onTotal = s.statsTotalTokens(now: now, calendar: cal)

        #expect(onWork == Self.cacheWork + 300_000)
        #expect(onTotal == onWork)          // the headline must not move with a display setting
        // Sanity: the basis really is live on this store, or the equality above proves nothing.
        #expect(s.dayTokens(s.allTimeDaily.last!) > s.allTimeDaily.last!.workTokens * 100)
    }

    // MARK: - When the gap must NOT be filled

    /// Claude Code deletes transcripts past `cleanupPeriodDays`, so a cache left un-recomputed for
    /// long enough outlives the local history it would need to be extended with. Adding only the days
    /// we still hold would give a total that is neither the cache's nor ours — so the figure stays
    /// dated, and says so.
    @MainActor
    @Test func fillIsRefusedWhenLocalHistoryStartsAfterTheCache() throws {
        let s = try store(entries([(day(2026, 8, 3), 100_000), (day(2026, 8, 4), 200_000)]))
        let now = day(2026, 8, 4)
        #expect(s.statsTotalTokens(now: now, calendar: cal) == Self.cacheWork)
        #expect(s.statsFilledDays(now: now, calendar: cal) == 0)
        #expect(s.statsIsDated(now: now, calendar: cal))
    }

    /// A cache with no local history at all behind it — the first launch, before any scan has run.
    @MainActor
    @Test func noLocalHistoryMeansTheDatedFigure() throws {
        let s = try store([])
        #expect(s.statsTotalTokens(now: day(2026, 8, 4), calendar: cal) == Self.cacheWork)
        #expect(s.statsIsDated(now: day(2026, 8, 4), calendar: cal))
    }

    /// An old cache followed by idle days is **not** dated — its figure is still current, because
    /// nothing happened after it. `statsGapDays` returns an empty gap rather than nil for this, and the
    /// distinction is what keeps the chip off the card when there is nothing to warn about.
    @MainActor
    @Test func anIdleStretchAfterTheCacheIsNotDated() throws {
        let s = try store(entries([(day(2026, 7, 28), 100_000), (day(2026, 7, 29), 200_000)]))
        let now = day(2026, 8, 6)
        #expect(s.statsTotalTokens(now: now, calendar: cal) == Self.cacheWork)
        #expect(s.statsFilledDays(now: now, calendar: cal) == 0)
        #expect(!s.statsIsDated(now: now, calendar: cal))
    }

    @MainActor
    @Test func noCacheMeansNoFigureAndNothingToWarnAbout() throws {
        let name = "claudepet-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let s = TestSupport.store(defaults: defaults)      // wired to a nonexistent stats path
        s.ingestForTesting(entries([(day(2026, 7, 30), 100_000)]))
        #expect(s.statsTotalTokens(now: day(2026, 7, 30), calendar: cal) == nil)
        #expect(s.statsFilledDays(now: day(2026, 7, 30), calendar: cal) == 0)
        #expect(!s.statsIsDated(now: day(2026, 7, 30), calendar: cal))
    }

    // MARK: - Non-Gregorian locale

    /// `Calendar.current` on this project's own development machine is the **Buddhist** calendar, where
    /// today's year is 2569 — the locale that once made the whole live delta unable to fire. The gap
    /// bounds go through `lastComputedDate(calendar:)` and `startOfDay`, so they have to survive it.
    @MainActor
    @Test func fillIsCorrectOnANonGregorianCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = .current
        let s = try store(entries([
            (day(2026, 7, 28), 111),
            (day(2026, 7, 30), 100_000),
            (day(2026, 7, 31), 200_000),
        ]))
        let now = day(2026, 7, 31)
        #expect(buddhist.dateComponents([.year], from: now).year == 2569)   // it really is different
        #expect(s.statsTotalTokens(now: now, calendar: buddhist) == Self.cacheWork + 300_000)
        #expect(s.statsFilledDays(now: now, calendar: buddhist) == 2)
        #expect(!s.statsIsDated(now: now, calendar: buddhist))
    }

    /// The per-model rows used to be the cache alone while the headline above them was extended —
    /// so on a cache 18 days stale the rows froze at that date and stopped adding up to the total
    /// they sit under, which read as "the dashboard isn't updating". They are extended across the
    /// same days now, and must sum to the headline exactly.
    @MainActor
    @Test func modelRowsAreExtendedAndSumToTheHeadline() throws {
        // History reaching back to the cache's own last day (07-29, already counted there) — the
        // condition for filling at all.
        let gap = entries([(day(2026, 7, 29), 9_000_000), (day(2026, 7, 30), 1_000_000),
                           (day(2026, 8, 1), 500_000)])
        let other = [TestSupport.entry(at: day(2026, 8, 2), model: "claude-opus-5-5",
                                       input: 100_000, output: 200_000)]
        let s = try store(gap + other)
        let now = day(2026, 8, 2)
        let rows = s.statsModels(now: now, calendar: cal)
        #expect(rows.reduce(0) { $0 + $1.workTokens } == s.statsTotalTokens(now: now, calendar: cal))
        #expect(rows.first { $0.model == "claude-opus-4-8" }?.workTokens == Self.cacheWork + 1_500_000)
        #expect(rows.first { $0.model == "claude-opus-5-5" }?.workTokens == 300_000)  // new since the cache
        #expect(rows.map(\.workTokens) == rows.map(\.workTokens).sorted(by: >))
    }

    /// Same refusal as the headline: if our history can't reach back to the cache's last day, the
    /// rows stay the cache's own rather than gaining a partial slice.
    @MainActor
    @Test func modelRowsAreNotExtendedWhenTheGapCantBeFilled() throws {
        let s = try store(entries([(day(2026, 8, 5), 1_000_000)]))   // history starts after 07-29
        let rows = s.statsModels(now: day(2026, 8, 6), calendar: cal)
        #expect(rows.reduce(0) { $0 + $1.workTokens } == Self.cacheWork)
    }
}
