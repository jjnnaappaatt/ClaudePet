import Testing
import Foundation
@testable import ClaudePetCore

/// Claude Code's `/stats` "Total tokens" is read from `~/.claude/stats-cache.json`, never derived.
///
/// Why it's read: measured against one complete day where `/stats` showed 3,063,775, counting every
/// logged transcript line gave +7.2%, excluding subagent lines gave −3.3%, and deduplicating by
/// `message.id` gave ×0.36 globally / ×0.46 per file. Nothing lands on the figure, so these tests pin
/// the *reading* — the arithmetic is Claude Code's, not ours.
@Suite struct StatsCacheTests {

    /// The real file's shape, with the real per-model numbers for the four heaviest models.
    /// Σ(input+output) = 140,541,663 across all seven, which is what `/stats` printed as 140.5m.
    private static let json = #"""
    {
      "version": 4,
      "lastComputedDate": "2026-07-29",
      "totalSessions": 208,
      "totalMessages": 125137,
      "hourCounts": {"9": 14, "14": 31},
      "firstSessionDate": "2026-05-08T09:40:38.571Z",
      "longestSession": {"sessionId":"af6e6cf1","duration":2498851599,"messageCount":1720,"timestamp":"2026-05-19T08:39:07.144Z"},
      "dailyActivity": [{"date":"2026-07-29","messageCount":6431,"sessionCount":34,"toolCallCount":2328}],
      "modelUsage": {
        "claude-opus-4-8":  {"inputTokens":22078886,"outputTokens":89435705,"cacheReadInputTokens":19088345916,"cacheCreationInputTokens":421818449,"costUSD":0},
        "claude-sonnet-4-6":{"inputTokens":87802,"outputTokens":10064185,"cacheReadInputTokens":944789056,"cacheCreationInputTokens":39159434,"costUSD":0},
        "claude-opus-5":    {"inputTokens":134000,"outputTokens":8339741,"cacheReadInputTokens":1,"cacheCreationInputTokens":2,"costUSD":0},
        "claude-fable-5":   {"inputTokens":905133,"outputTokens":2882970,"cacheReadInputTokens":790424067,"cacheCreationInputTokens":18166381,"costUSD":0},
        "claude-opus-4-7":  {"inputTokens":93313,"outputTokens":2361922,"cacheReadInputTokens":140422625,"cacheCreationInputTokens":29913669,"costUSD":0},
        "claude-haiku-4-5-20251001":{"inputTokens":517600,"outputTokens":1931406,"cacheReadInputTokens":462062039,"cacheCreationInputTokens":40672724,"costUSD":0},
        "claude-sonnet-5":  {"inputTokens":333422,"outputTokens":1375578,"cacheReadInputTokens":353731938,"cacheCreationInputTokens":12352260,"costUSD":0}
      }
    }
    """#

    private func write(_ contents: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudepet-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stats-cache.json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: - Reading

    @Test func totalIsInputPlusOutputAcrossModelsWithCacheExcluded() throws {
        let c = try #require(StatsCacheReader.read(path: try write(Self.json)))
        #expect(c.totalWorkTokens == 140_541_663)
        // Cache tokens are in the file and deliberately NOT in the total — they'd add ~26 billion.
        #expect(c.models.reduce(0) { $0 + $1.cacheReadTokens } > 20_000_000_000)
        #expect(c.totalSessions == 208)
    }

    @Test func modelsAreHeaviestFirstWithSharesSummingToOne() throws {
        let c = try #require(StatsCacheReader.read(path: try write(Self.json)))
        #expect(c.models.count == 7)
        #expect(c.models.first?.model == "claude-opus-4-8")
        #expect(c.models.first?.workTokens == 111_514_591)
        // 111,514,591 / 140,541,663 = 79.35%. (The 78.2% in a `/stats` screenshot is lower because the
        // live view adds today's delta to the actively-used model, which the cache doesn't have yet.)
        #expect(abs((c.share(c.models[0]) * 100) - 79.35) < 0.01)
        #expect(abs(c.models.reduce(0) { $0 + c.share($1) } - 1.0) < 1e-9)
        // Descending, no exceptions.
        #expect(zip(c.models, c.models.dropFirst()).allSatisfy { $0.workTokens >= $1.workTokens })
    }

    /// `/stats` prints "Opus 4.8", "Haiku 4.5" — not the raw ids, and not the date stamp some carry.
    @Test func displayNameMatchesWhatStatsPrints() {
        func name(_ m: String) -> String { StatsModelTotal(model: m, inputTokens: 0, outputTokens: 0,
                                                           cacheReadTokens: 0, cacheWriteTokens: 0).displayName }
        #expect(name("claude-opus-4-8") == "Opus 4.8")
        #expect(name("claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(name("claude-opus-5") == "Opus 5")
        #expect(name("claude-haiku-4-5-20251001") == "Haiku 4.5")   // trailing date stamp dropped
        #expect(name("weird-thing") == "Weird thing")                // degrades, never blanks
    }

    @Test func absentOrMalformedOrEmptyYieldsNilRatherThanZero() throws {
        #expect(StatsCacheReader.read(path: "/nonexistent/claudepet/stats-cache.json") == nil)
        #expect(StatsCacheReader.read(path: try write("{ not json")) == nil)
        #expect(StatsCacheReader.read(path: try write(#"{"version":4}"#)) == nil)
        #expect(StatsCacheReader.read(path: try write(#"{"modelUsage":{}}"#)) == nil)
        // Present but all-zero is as useless as absent — showing "0 tokens" would be a lie.
        #expect(StatsCacheReader.read(path: try write(
            #"{"modelUsage":{"m":{"inputTokens":0,"outputTokens":0}}}"#)) == nil)
    }

    // MARK: - Freshness: when may today's own count be added?

    @Test func coversIsHalfOpenAtTheCachesOwnDay() throws {
        let c = try #require(StatsCacheReader.read(path: try write(Self.json)))
        // Cache ends 2026-07-29. Its own day is already counted — a caller adding a delta there
        // double-counts.
        #expect(c.covers(day(2026, 7, 29), calendar: cal))
        #expect(!c.covers(day(2026, 7, 30), calendar: cal))
        #expect(!c.covers(day(2026, 8, 1), calendar: cal))
    }

    /// Regression: the cache's `"2026-07-29"` is Gregorian, but `Calendar.current` need not be. On a Thai
    /// locale it's the Buddhist calendar, whose year for the same day is **2569** — so comparing the
    /// parsed 2026 against the current calendar's components never matched, and on that machine the
    /// live delta could not fire at all. Caught only by printing the raw components from a real run.
    @Test func freshnessIsCorrectOnANonGregorianCalendar() throws {
        let c = try #require(StatsCacheReader.read(path: try write(Self.json)))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        // Sanity: this calendar really does report a different year for the same instant.
        #expect(buddhist.dateComponents([.year], from: day(2026, 7, 30)).year == 2569)

        #expect(c.covers(day(2026, 7, 29, 6), calendar: buddhist))
        #expect(!c.covers(day(2026, 7, 30, 6), calendar: buddhist))
        #expect(!c.covers(day(2026, 8, 5), calendar: buddhist))
        // And the display date must not land in the 15th century.
        let shown = try #require(c.lastComputedDate(calendar: buddhist))
        var g = Calendar(identifier: .gregorian); g.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        #expect(g.dateComponents([.year, .month, .day], from: shown).year == 2026)
    }

    @MainActor
    @Test func noCacheMeansNoStatsFiguresAtAll() {
        let name = "claudepet-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = TestSupport.store(defaults: defaults)   // wired to a nonexistent path
        store.ingestForTesting([TestSupport.entry(at: Date(), input: 700, output: 300)])
        #expect(store.statsCache == nil)
        #expect(store.stats == nil)
        #expect(store.statsAsOfDescription == nil)
    }
    // MARK: - The lifetime KPI figures

    /// Every tile is READ from the file. These pin the reading against the real values.
    @Test func readsTheLifetimeCounters() throws {
        let path = try write(Self.json)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let c = try #require(StatsCacheReader.read(path: path))
        #expect(c.totalSessions == 208)
        #expect(c.totalMessages == 125_137)
        #expect(c.activeDays.count == 1)
        #expect(c.longestSessionMessages == 1720)
    }

    /// Ties on message count break toward the EARLIER hour, so the answer can't flicker between reads.
    @Test func busiestHourIsTheArgmaxOfHourCounts() {
        let c = Self.cache(hourCounts: [9: 14, 14: 31, 22: 13])
        #expect(c.busiestHour == 14)
        #expect(Self.cache(hourCounts: [9: 20, 14: 20]).busiestHour == 9)
        #expect(Self.cache(hourCounts: [:]).busiestHour == nil)
        #expect(Self.cache(hourCounts: [3: 0]).busiestHour == nil)
    }

    /// Runs are counted on a fixed Gregorian calendar — these are the file's own dates compared
    /// against each other, and under the Thai Buddhist calendar `Calendar.current` disagrees on the
    /// year entirely.
    @Test func streaksCountConsecutiveDays() {
        let c = Self.cache(days: ["2026-07-01", "2026-07-02", "2026-07-03",   // 3
                                  "2026-07-10",                               // 1
                                  "2026-07-20", "2026-07-21"])                // 2, and last
        #expect(c.longestStreak == 3)
        #expect(c.streakEndingAtLastDay == 2)
    }

    @Test func streakHandlesAnEmptyAndASingleDay() {
        #expect(Self.cache(days: []).longestStreak == 0)
        #expect(Self.cache(days: []).streakEndingAtLastDay == 0)
        #expect(Self.cache(days: ["2026-07-01"]).streakEndingAtLastDay == 1)
    }

    /// Out-of-order dates in the file must not break the run detection.
    @Test func streakSortsBeforeCounting() {
        let c = Self.cache(days: ["2026-07-03", "2026-07-01", "2026-07-02"])
        #expect(c.longestStreak == 3)
    }

    private static func cache(days: [String] = [], hourCounts: [Int: Int] = [:]) -> StatsCache {
        StatsCache(models: [StatsModelTotal(model: "m", inputTokens: 1, outputTokens: 1,
                                            cacheReadTokens: 0, cacheWriteTokens: 0)],
                   lastComputedDay: nil, totalSessions: 0,
                   activeDays: days.compactMap { StatsCacheReader.parseDay($0) },
                   hourCounts: hourCounts, asOf: Date())
    }
}
