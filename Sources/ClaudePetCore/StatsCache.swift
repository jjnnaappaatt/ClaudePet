import Foundation

/// One model's lifetime usage as Claude Code's own `/stats` records it.
public struct StatsModelTotal: Sendable, Equatable, Identifiable {
    public let model: String            // raw id, e.g. "claude-opus-4-8"
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int

    public var id: String { model }

    /// What `/stats` counts: input + output, cache EXCLUDED.
    public var workTokens: Int { inputTokens + outputTokens }

    public var family: ModelFamily { ModelFamily(modelID: model) }

    /// "Opus 4.8" from "claude-opus-4-8" — the shape `/stats` prints. Falls back to the raw id when the
    /// pattern doesn't match, so an unrecognised model is still labelled rather than blanked.
    public var displayName: String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Trailing date stamps ("claude-haiku-4-5-20251001") aren't part of the name.
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let name = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? name.capitalized : "\(name.capitalized) \(version)"
    }
}

/// Claude Code's `/stats` cache — the ONLY source that reproduces the "Total tokens" figure `/stats`
/// shows.
///
/// It cannot be recomputed from the transcripts. Measured against one complete day where `/stats` read
/// 3,063,775: counting every logged line gives +7.2%, excluding subagent lines gives −3.3%, and
/// deduplicating by `message.id` gives ×0.36 globally or ×0.46 per file. No rule lands on it, so the
/// number is read rather than derived.
///
/// Same class of action as reading `~/.claude.json` or the statusline cache: a local file the user's own
/// tooling already wrote. No network, no OAuth token — the token is not in this file.
public struct StatsCache: Sendable, Equatable {
    public let models: [StatsModelTotal]     // heaviest first, by work tokens
    /// Last day Claude Code folded into this cache — as **year/month/day components, not a `Date`**.
    ///
    /// The file gives a bare `"2026-07-29"` with no zone. Turning that into an absolute instant forces a
    /// timezone choice at parse time, and then any caller comparing it on a *different* calendar is off
    /// by a day: parsed in UTC+7 it becomes 2026-07-28T17:00Z, which "is yesterday" relative to the 29th
    /// rather than the 30th. Comparing y/m/d integers has no such trap.
    public let lastComputedDay: DateComponents?
    public let totalSessions: Int
    public let totalMessages: Int
    /// Every day Claude Code recorded activity on, as y/m/d, ascending. Same reason as
    /// `lastComputedDay` for keeping components rather than `Date`s: the file's dates are bare
    /// Gregorian strings, and turning them into instants forces a timezone choice at parse time.
    public let activeDays: [DateComponents]
    /// All-time message counts per hour of the local day, 0…23. Sparse in the file.
    public let hourCounts: [Int: Int]
    public let firstSessionDate: Date?
    public let longestSessionMessages: Int
    public let asOf: Date                    // file mtime, for freshness display

    public init(models: [StatsModelTotal], lastComputedDay: DateComponents?, totalSessions: Int,
                totalMessages: Int = 0, activeDays: [DateComponents] = [],
                hourCounts: [Int: Int] = [:], firstSessionDate: Date? = nil,
                longestSessionMessages: Int = 0, asOf: Date) {
        self.models = models
        self.lastComputedDay = lastComputedDay
        self.totalSessions = totalSessions
        self.totalMessages = totalMessages
        self.activeDays = activeDays
        self.hourCounts = hourCounts
        self.firstSessionDate = firstSessionDate
        self.longestSessionMessages = longestSessionMessages
        self.asOf = asOf
    }

    /// The hour of the day with the most messages, all time. Nil when the file records none.
    ///
    /// **Not the same thing as the hour chart's "peak"**, which is *today's* busiest hour from our own
    /// transcripts. Two different figures; label this one "all time" wherever it appears or they read
    /// as a contradiction.
    public var busiestHour: Int? {
        hourCounts.filter { $0.value > 0 }
            .max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    /// The longest run of consecutive active days anywhere in the record.
    public var longestStreak: Int { Self.streaks(activeDays).max() ?? 0 }

    /// The run of consecutive active days ending at the **last day the cache knows about** — which is
    /// not necessarily today. `MetricsStore.statsCurrentStreak()` extends it across the days the cache
    /// hasn't folded in yet.
    public var streakEndingAtLastDay: Int { Self.streaks(activeDays).last ?? 0 }

    /// Run lengths of consecutive days, in order. Uses a fixed Gregorian calendar: these are the
    /// file's own dates being compared against each other, so the user's locale is irrelevant here —
    /// and on a Buddhist calendar `Calendar.current` would not even agree on the year.
    private static func streaks(_ days: [DateComponents]) -> [Int] {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = days.compactMap { g.date(from: $0) }.sorted()
        guard !dates.isEmpty else { return [] }
        var runs: [Int] = []
        var run = 1
        for (a, b) in zip(dates, dates.dropFirst()) {
            if g.dateComponents([.day], from: a, to: b).day == 1 { run += 1 }
            else { runs.append(run); run = 1 }
        }
        runs.append(run)
        return runs
    }

    /// `/stats`' "Total tokens": input + output across every model, cache excluded.
    public var totalWorkTokens: Int { models.reduce(0) { $0 + $1.workTokens } }

    /// Each model's share of `totalWorkTokens`, 0…1. Zero when nothing is recorded.
    public func share(_ m: StatsModelTotal) -> Double {
        let t = totalWorkTokens
        return t > 0 ? Double(m.workTokens) / Double(t) : 0
    }

    private static func ymd(_ c: DateComponents) -> (Int, Int, Int)? {
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return (y, m, d)
    }

    /// The cache's date string is **Gregorian**, and the user's `Calendar.current` may not be.
    ///
    /// On a Thai locale it is the Buddhist calendar, where today's `year` is 2569 rather than 2026 — so
    /// comparing the parsed 2026 against `Calendar.current`'s components never matched, and the cache
    /// looked permanently stale (the live delta could not fire on that machine, ever). Compare on a
    /// Gregorian calendar while keeping the caller's **time zone**, which is what actually decides where
    /// the day boundary falls.
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        return g
    }

    /// True when the cache already covers `now`'s calendar day (or later) — in which case a caller must
    /// NOT add a live delta for today, or it double-counts.
    public func covers(_ now: Date, calendar: Calendar = .current) -> Bool {
        let g = Self.gregorian(calendar)
        guard let last = lastComputedDay.flatMap(Self.ymd),
              let today = Self.ymd(g.dateComponents([.year, .month, .day], from: now))
        else { return false }
        return last >= today
    }

    /// The cache's last day as an instant, for display **and for bounding the gap** that
    /// `MetricsStore.statsGapDays` fills from local history. There was an `endsYesterday` companion to
    /// `covers` here; it is gone deliberately. It encoded the rule that only a one-day gap could be
    /// closed, which left a seven-day-old total on screen unmarked, and a predicate with no caller is
    /// an invitation to wire that rule back in.
    ///
    /// Built on a Gregorian calendar for the same reason as above — `Calendar.current.date(from:)`
    /// would read 2026 as a Buddhist year and land in the 15th century.
    public func lastComputedDate(calendar: Calendar = .current) -> Date? {
        lastComputedDay.flatMap { Self.gregorian(calendar).date(from: $0) }
    }
}

public enum StatsCacheReader {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/stats-cache.json").path
    }

    /// The file's `firstSessionDate` carries fractional seconds; the default `ISO8601DateFormatter`
    /// rejects those, which silently yielded nil.
    fileprivate static let statsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The cache carries much more than we use (`dailyActivity`, `hourCounts`, `longestSession`, …);
    /// Codable ignores the rest. Note `costUSD` is present but always 0, so `PricingTable` stays the
    /// source for every `$` figure — don't be tempted by that field.
    private struct Raw: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?
        }
        struct DailyActivity: Decodable { let date: String? }
        struct LongestSession: Decodable { let messageCount: Int? }
        let lastComputedDate: String?
        let modelUsage: [String: Usage]?
        let totalSessions: Int?
        let totalMessages: Int?
        let dailyActivity: [DailyActivity]?
        let hourCounts: [String: Int]?
        let firstSessionDate: String?
        let longestSession: LongestSession?
    }

    /// `"2026-07-29"` → y/m/d components. No calendar or timezone involved, deliberately — see
    /// `StatsCache.lastComputedDay`.
    static func parseDay(_ s: String?) -> DateComponents? {
        guard let s else { return nil }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Reads and parses the `/stats` cache. Returns nil when absent, unreadable, malformed, or carrying
    /// no model usage — callers then simply omit the `/stats` figures rather than showing a zero.
    public static func read(path: String = defaultPath) -> StatsCache? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let usage = raw.modelUsage, !usage.isEmpty else { return nil }

        let models = usage.map { model, u in
            StatsModelTotal(model: model,
                            inputTokens: u.inputTokens ?? 0,
                            outputTokens: u.outputTokens ?? 0,
                            cacheReadTokens: u.cacheReadInputTokens ?? 0,
                            cacheWriteTokens: u.cacheCreationInputTokens ?? 0)
        }
        // Heaviest first; tie-break on the id so the order can't flicker between reads.
        .sorted { $0.workTokens != $1.workTokens ? $0.workTokens > $1.workTokens : $0.model < $1.model }

        guard models.contains(where: { $0.workTokens > 0 }) else { return nil }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let days = (raw.dailyActivity ?? []).compactMap { parseDay($0.date) }
        let hours = (raw.hourCounts ?? [:]).reduce(into: [Int: Int]()) { out, kv in
            if let h = Int(kv.key), (0...23).contains(h) { out[h] = kv.value }
        }
        return StatsCache(models: models, lastComputedDay: parseDay(raw.lastComputedDate),
                          totalSessions: raw.totalSessions ?? 0,
                          totalMessages: raw.totalMessages ?? 0,
                          activeDays: days,
                          hourCounts: hours,
                          firstSessionDate: raw.firstSessionDate.flatMap {
                              Self.statsFormatter.date(from: $0)
                          },
                          longestSessionMessages: raw.longestSession?.messageCount ?? 0,
                          asOf: mtime ?? Date())
    }
}
