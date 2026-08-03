import Foundation

public struct Totals: Sendable, Equatable {
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    /// Work tokens scaled by each entry's model weight (Sonnet-equivalent). Used by
    /// the gauge when "weight tokens by model cost" is on; flat `workTokens` otherwise.
    public var weightedTokens: Double = 0
    /// The subagent (sidechain) slice of the two counts above — accumulated in `add` from the
    /// entry's own flag, so it costs no extra pass and can never disagree with the parent sums.
    /// Zero when "Include subagent usage" is off: those entries never reach the aggregator.
    /// These stay LAST so the synthesized memberwise init keeps existing call sites valid.
    public var sidechainWorkTokens: Int = 0
    public var sidechainTotalTokens: Int = 0

    /// Cache read + write tokens (the bulk of `totalTokens`).
    public var cacheTokens: Int { max(0, totalTokens - workTokens) }

    public mutating func add(_ e: UsageEntry, cost: Double, weight: Double = 1) {
        workTokens += e.workTokens
        totalTokens += e.totalTokens
        costUSD += cost
        weightedTokens += Double(e.workTokens) * weight
        if e.isSidechain {
            sidechainWorkTokens += e.workTokens
            sidechainTotalTokens += e.totalTokens
        }
    }
}

public struct ModelTotal: Sendable, Equatable, Identifiable {
    public let family: ModelFamily
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var unpriced: Bool = false
    public var id: String { family.rawValue }
}

/// One project's slice of a window. `path` is the real absolute `cwd` recorded on the turn, so the
/// name is exact — the `~/.claude/projects` directory name would be a lossy encoding of it.
public struct ProjectTotal: Sendable, Equatable, Identifiable {
    public let path: String          // "" when the transcript recorded no cwd
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var id: String { path }

    /// The directory's own name ("ClaudePet", "Support Project", "LiDAR + HPE").
    public var displayName: String {
        path.isEmpty ? "—" : URL(fileURLWithPath: path).lastPathComponent
    }
}

public struct DayTotal: Sendable, Equatable, Identifiable {
    public let date: Date            // start of local day
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    /// The subagent (sidechain) slice of the two counts above — accumulated alongside them, for the
    /// same reason `Totals` carries its own: a share can't be recovered afterwards from a total.
    public var sidechainWorkTokens: Int = 0
    public var sidechainTotalTokens: Int = 0
    public var id: TimeInterval { date.timeIntervalSince1970 }
}

public struct HourTotal: Sendable, Equatable, Identifiable {
    public let hour: Int             // 0...23, local hour of today
    public var workTokens: Int = 0
    public var totalTokens: Int = 0
    public var costUSD: Double = 0
    public var id: Int { hour }

    public init(hour: Int, workTokens: Int = 0, totalTokens: Int = 0, costUSD: Double = 0) {
        self.hour = hour
        self.workTokens = workTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

public struct Aggregates: Sendable, Equatable {
    public var today: Totals = .init()
    public var week: Totals = .init()
    public var allTime: Totals = .init()
    public var cycle: Totals = .init()         // current billing cycle
    public var todayByModel: [ModelTotal] = []
    public var weekDaily: [DayTotal] = []      // last 7 local days incl. today (all models)
    public var calendarWeek: Totals = .init()
    /// One bucket per date in the fixed Sunday-to-Saturday calendar week containing `now` — always
    /// exactly 7 whole calendar dates (no reset-day fold, unlike `weekDaily`). Independent of the
    /// rate-limit `weekWindow`; see CLAUDE.md.
    public var calendarWeekDaily: [DayTotal] = []
    public var todayHourly: [HourTotal] = []   // today's usage in 24 local-hour buckets (all models)
    public var unknownModels: Set<String> = []
    /// One bucket per calendar date the billing cycle touches, and the same window split by
    /// project. Both use the identical in-cycle predicate as `cycle`, so each sums exactly to it.
    public var cycleDaily: [DayTotal] = []
    public var cycleByProject: [ProjectTotal] = []
    /// The same split over ALL history. Kept beside the cycle version rather than replacing it: the
    /// cycle one is pinned by tests to sum exactly to `cycle`, which the dashboard's calendar card
    /// depends on. This one sums to `allTime` instead.
    public var allTimeByProject: [ProjectTotal] = []
    /// The lifetime daily history, oldest first — one bucket per calendar date that has usage.
    ///
    /// **ACTIVE days only, and alone among the series here it is not pre-gridded.** The other three
    /// build a fixed grid first because their span is known up front (7 slots, 7 dates, the cycle's
    /// dates); this one's span isn't known until the entries have been seen, and pre-gridding it
    /// would need a separate pass just to find the earliest. Gaps cost nothing: its consumer
    /// (`MetricsStore.dailyAverage`) drops zero-value days anyway, since a day you didn't work is
    /// not evidence about what a usual day looks like.
    public var allTimeDaily: [DayTotal] = []
}

/// Rolls deduplicated entries into today / week / all-time totals plus a
/// per-model breakdown for today. `now`/`calendar` are injectable for tests.
public enum Aggregator {
    public static func compute(entries: [UsageEntry],
                               pricing: PricingTable,
                               now: Date = Date(),
                               calendar: Calendar = .current,
                               cycleWindow: (start: Date, end: Date)? = nil,
                               weekWindow: (start: Date, end: Date)? = nil) -> Aggregates {
        var agg = Aggregates()

        let startOfToday = calendar.startOfDay(for: now)
        // Rolling 7 calendar days incl. today — used for the day-by-day history chart.
        let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var modelMap: [ModelFamily: ModelTotal] = [:]

        // 24 fixed buckets for today, so the chart always has a full 12a→12p axis.
        var hourBuckets = (0...23).map { HourTotal(hour: $0) }

        // Day buckets for the history chart, oldest → newest.
        //
        // Given a weekly-reset window these are the CALENDAR DAYS that window covers, clipped to
        // it: the bars sum to exactly the weekly-limit total above them (a rolling last-7-days
        // silently disagreed with it by everything logged before a mid-afternoon reset — ~16% on
        // real data) while still being real days.
        //
        // Anchoring 24h cells to the reset *instant* also summed correctly but mislabelled the
        // bars: at 14:47 on a Sunday the cell holding `now` had begun Sat 15:00, so the chart
        // highlighted Saturday and would have jumped to Sunday at 15:00. Weekday letters have to
        // mean weekdays.
        //
        // A mid-day reset makes the window touch 8 calendar dates, but a week has 7 days, so the
        // bars are WEEKDAY SLOTS of the window: reset day gets one bar holding both its
        // post-reset part at the start of the window and its pre-reset part at the end. Seven
        // bars, one per weekday, still summing to `week`.
        //
        // With no window, fall back to the rolling last 7 days.
        let weekGridStart = weekWindow.map { calendar.startOfDay(for: $0.start) }
        var dayBuckets: [Date: DayTotal] = [:]
        var dayOrder: [Date] = []
        if let first = weekGridStart {
            for i in 0..<7 {
                let d = calendar.date(byAdding: .day, value: i, to: first)
                    ?? first.addingTimeInterval(Double(i) * 86_400)
                dayBuckets[d] = DayTotal(date: d)
                dayOrder.append(d)
            }
        } else {
            for offset in (0...6).reversed() {
                if let d = calendar.date(byAdding: .day, value: -offset, to: startOfToday) {
                    dayBuckets[d] = DayTotal(date: d)
                    dayOrder.append(d)
                }
            }
        }

        // Fixed Sunday 00:00 → next Sunday 00:00 calendar week containing `now` — deliberately
        // independent of `weekWindow` (the real rate-limit window, whatever day/time it resets).
        // Unlike `weekDaily` above, this always has exactly 7 whole calendar dates: no optional/
        // "no window" branch (there's nothing to fall back from — `now`/`calendar` are always
        // enough), and no `% 7` fold (a midnight-aligned boundary can never split a day).
        //
        // Built from calendar-DAY arithmetic, NOT `WeeklyWindowEngine.window` — that steps a fixed
        // 7×24h in raw SECONDS from an epoch anchor, which drifts up to ±1h off true local midnight
        // for roughly half of every year in a DST-observing zone (its own doc comment admits this).
        // For the rate-limit window that's tolerated (an approximation recalibrated against the
        // server anyway), but it would silently exclude up to an hour of entries near the Sunday
        // boundary from every bucket here — reintroducing a subtler version of the exact confusion
        // this aggregate exists to remove. `calendar.date(byAdding: .day:)` absorbs DST by
        // construction, so this boundary is always exactly local midnight.
        let todayMidnight = calendar.startOfDay(for: now)
        let weekdayToday = calendar.component(.weekday, from: todayMidnight)
        let calWeekStart = calendar.date(byAdding: .day, value: -(weekdayToday - 1), to: todayMidnight)
            ?? todayMidnight
        let calWeekEnd = calendar.date(byAdding: .day, value: 7, to: calWeekStart)
            ?? calWeekStart.addingTimeInterval(7 * 86_400)
        var calWeekBuckets: [Date: DayTotal] = [:]
        var calWeekOrder: [Date] = []
        var cwDate = calWeekStart
        for _ in 0..<7 {
            calWeekBuckets[cwDate] = DayTotal(date: cwDate)
            calWeekOrder.append(cwDate)
            cwDate = calendar.date(byAdding: .day, value: 1, to: cwDate) ?? cwDate.addingTimeInterval(86_400)
        }

        // Billing-cycle day grid: one bucket per calendar DATE the cycle touches, oldest → newest.
        // The cycle boundary is a mid-day instant (the subscription anniversary, e.g. 03:03 UTC), so
        // the first and last dates are partial. This deliberately does NOT copy `weekDaily`'s `% 7`
        // fold: that exists because a week must be exactly 7 *weekday* slots, whereas these bars are
        // labelled by date — so a short first/last bar is honest, where a folded one would be a lie.
        var cycleBuckets: [Date: DayTotal] = [:]
        var cycleOrder: [Date] = []
        if let cw = cycleWindow {
            var d = calendar.startOfDay(for: cw.start)
            while d < cw.end {
                cycleBuckets[d] = DayTotal(date: d)
                cycleOrder.append(d)
                d = calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400)
            }
        }
        // Keyed by the transcript's project DIRECTORY, not by `cwd`: cwd varies per turn across
        // subdirectories and workflow worktrees, which on real data split 11 projects into 120 rows.
        // The cwd frequencies ride along so the directory can be resolved back to a real path
        // afterwards — see `ProjectKey.resolveRoot`.
        struct ProjectAcc { var work = 0; var total = 0; var cost = 0.0; var cwds: [String: Int] = [:] }
        var projectAcc: [String: ProjectAcc] = [:]
        var lifetimeProjectAcc: [String: ProjectAcc] = [:]

        // Lifetime day buckets. No pre-built grid — see `Aggregates.allTimeDaily`.
        var allTimeBuckets: [Date: DayTotal] = [:]

        // One `startOfDay` per DAY rather than per ENTRY, reused by every branch below.
        //
        // **This is a speed cache, not a correctness one**, and the distinction matters: an
        // out-of-order entry simply misses and recomputes, so the result is identical for any input
        // ordering (`DailyBaselineTests.dayKeyCacheIsCorrectForUnsortedEntries` pins that). It hits
        // ~99.9% in practice only because `LogScanner` sorts by timestamp — which makes that sort
        // load-bearing for PERFORMANCE as well as for dedup determinism.
        //
        // Measured end to end on 127k real entries, p50 of 21 runs of this whole function:
        // **275.5ms before `allTimeDaily` existed, 345.3ms with it added naively, 233.9ms as it
        // stands.** `recompute()` is on the main actor on a 30s timer, so the naive +70ms was not
        // payable — and the cached key also replaces the per-entry `isDate(_:inSameDayAs:)` below,
        // which is what turns the feature's cost into a net saving.
        //
        // Benchmark the whole function, not these calls alone: an isolated microbenchmark of
        // `isDate` over synthetic dates claimed 79ms, ~2× the ~42ms the substitution really nets
        // here. Not wrong, just measuring something else.
        var dayCacheStart = Date.distantPast
        var dayCacheEnd = Date.distantPast

        for e in entries {
            if e.timestamp < dayCacheStart || e.timestamp >= dayCacheEnd {
                dayCacheStart = calendar.startOfDay(for: e.timestamp)
                // `date(byAdding: .day:)`, never `+86_400` — same DST rule as the calendar-week
                // block above: a raw-second step is an hour wrong twice a year.
                dayCacheEnd = calendar.date(byAdding: .day, value: 1, to: dayCacheStart)
                    ?? dayCacheStart.addingTimeInterval(86_400)
            }
            let day = dayCacheStart

            let cost = pricing.cost(for: e)
            let weight = pricing.weight(for: e.family)
            agg.allTime.add(e, cost: cost, weight: weight)

            // Unconditional, exactly like `agg.allTime` above it — this series IS the lifetime one.
            var lifeDay = allTimeBuckets[day] ?? DayTotal(date: day)
            lifeDay.workTokens += e.workTokens
            lifeDay.totalTokens += e.totalTokens
            lifeDay.costUSD += cost
            if e.isSidechain {
                lifeDay.sidechainWorkTokens += e.workTokens
                lifeDay.sidechainTotalTokens += e.totalTokens
            }
            allTimeBuckets[day] = lifeDay

            var lifeAcc = lifetimeProjectAcc[e.projectDir] ?? ProjectAcc()
            lifeAcc.work += e.workTokens
            lifeAcc.total += e.totalTokens
            lifeAcc.cost += cost
            if !e.project.isEmpty { lifeAcc.cwds[e.project, default: 0] += 1 }
            lifetimeProjectAcc[e.projectDir] = lifeAcc

            // ONE predicate for `cycle`, `cycleDaily` and `cycleByProject`: the dashboard shows the
            // three together, so a bar chart or a project list that didn't add up to the headline
            // figure would read as a bug. It's also bounded above now — an entry stamped past the
            // cycle end (clock skew) used to inflate `cycle` while belonging to no bucket.
            if let cw = cycleWindow, e.timestamp >= cw.start, e.timestamp < cw.end {
                agg.cycle.add(e, cost: cost, weight: weight)

                if cycleBuckets[day] != nil {
                    cycleBuckets[day]!.workTokens += e.workTokens
                    cycleBuckets[day]!.totalTokens += e.totalTokens
                    cycleBuckets[day]!.costUSD += cost
                    if e.isSidechain {
                        cycleBuckets[day]!.sidechainWorkTokens += e.workTokens
                        cycleBuckets[day]!.sidechainTotalTokens += e.totalTokens
                    }
                }

                var acc = projectAcc[e.projectDir] ?? ProjectAcc()
                acc.work += e.workTokens
                acc.total += e.totalTokens
                acc.cost += cost
                if !e.project.isEmpty { acc.cwds[e.project, default: 0] += 1 }
                projectAcc[e.projectDir] = acc
            }

            // Weekly LIMIT total: the fixed 7-day reset window if provided (matches the
            // Claude app's resetting weekly limit), else the rolling-7-day fallback.
            if let ww = weekWindow {
                if e.timestamp >= ww.start && e.timestamp < ww.end { agg.week.add(e, cost: cost, weight: weight) }
            } else if e.timestamp >= weekStart {
                agg.week.add(e, cost: cost, weight: weight)
            }

            // Day-by-day history chart. Inside a window only in-window entries count, so reset
            // day's bar holds just the parts that count toward the limit. `% 7` folds the
            // window's trailing reset-day date back onto the same weekday slot it opened with.
            let dayKey: Date?
            if let ww = weekWindow, let first = weekGridStart {
                if e.timestamp >= ww.start && e.timestamp < ww.end {
                    let n = calendar.dateComponents([.day], from: first, to: day).day ?? 0
                    dayKey = dayOrder[((n % 7) + 7) % 7]
                } else {
                    dayKey = nil
                }
            } else {
                dayKey = e.timestamp >= weekStart ? day : nil
            }
            if let key = dayKey, dayBuckets[key] != nil {
                dayBuckets[key]!.workTokens += e.workTokens
                dayBuckets[key]!.totalTokens += e.totalTokens
                dayBuckets[key]!.costUSD += cost
                if e.isSidechain {
                    dayBuckets[key]!.sidechainWorkTokens += e.workTokens
                    dayBuckets[key]!.sidechainTotalTokens += e.totalTokens
                }
            }

            // Fixed Sunday-anchored calendar week — deliberately independent of `week`/`weekWindow`
            // above. No fold needed: `calWeekBuckets` always has a key for every date this filter
            // can produce, since the boundaries are exact calendar-day midnights.
            if e.timestamp >= calWeekStart && e.timestamp < calWeekEnd {
                agg.calendarWeek.add(e, cost: cost, weight: weight)
                if calWeekBuckets[day] != nil {
                    calWeekBuckets[day]!.workTokens += e.workTokens
                    calWeekBuckets[day]!.totalTokens += e.totalTokens
                    calWeekBuckets[day]!.costUSD += cost
                    if e.isSidechain {
                        calWeekBuckets[day]!.sidechainWorkTokens += e.workTokens
                        calWeekBuckets[day]!.sidechainTotalTokens += e.totalTokens
                    }
                }
            }

            // `day == startOfToday` is exactly `calendar.isDate(e.timestamp, inSameDayAs: now)` —
            // that call IS defined as comparing the two `startOfDay`s — but reuses the cached key
            // instead of paying a Calendar round trip per entry. That substitution is what pays for
            // the lifetime series; see the cache's own comment above for the measured split.
            if day == startOfToday {
                agg.today.add(e, cost: cost, weight: weight)
                var mt = modelMap[e.family] ?? ModelTotal(family: e.family)
                mt.workTokens += e.workTokens
                mt.totalTokens += e.totalTokens
                mt.costUSD += cost
                mt.unpriced = pricing.isUnpriced(e.family)
                modelMap[e.family] = mt

                let h = calendar.component(.hour, from: e.timestamp)
                hourBuckets[h].workTokens += e.workTokens
                hourBuckets[h].totalTokens += e.totalTokens
                hourBuckets[h].costUSD += cost
            }

            if e.family == .other { agg.unknownModels.insert(e.model) }
        }

        // Stable, meaningful order: known families first, then other; by total tokens desc.
        agg.todayByModel = modelMap.values.sorted {
            if $0.unpriced != $1.unpriced { return !$0.unpriced }
            return $0.totalTokens > $1.totalTokens
        }
        agg.weekDaily = dayOrder.map { dayBuckets[$0] ?? DayTotal(date: $0) }
        agg.calendarWeekDaily = calWeekOrder.map { calWeekBuckets[$0] ?? DayTotal(date: $0) }
        agg.todayHourly = hourBuckets
        agg.cycleDaily = cycleOrder.map { cycleBuckets[$0] ?? DayTotal(date: $0) }
        // Ascending is part of the contract, not incidental: `MetricsStore.dailyAverage` takes a
        // `.suffix` of this to mean "the most recent N active days".
        agg.allTimeDaily = allTimeBuckets.values.sorted { $0.date < $1.date }
        // Resolve each directory to its real path, then merge: two directories CAN resolve to the
        // same project (a session started in the root and another in a subdirectory), and they are
        // genuinely the same project, so they belong in one row.
        var byPath: [String: ProjectTotal] = [:]
        for (dir, acc) in projectAcc {
            let path = ProjectKey.resolveRoot(dir: dir, cwdCounts: acc.cwds)
            var pt = byPath[path] ?? ProjectTotal(path: path)
            pt.workTokens += acc.work
            pt.totalTokens += acc.total
            pt.costUSD += acc.cost
            byPath[path] = pt
        }
        // Heaviest project first; the "no cwd recorded" bucket always last so it can't head the list.
        // This is a deterministic default order, not the display order — a view showing `work` or `$`
        // must re-sort by the figure it actually prints (see `ProjectBreakdownView`).
        agg.cycleByProject = byPath.values.sorted {
            if $0.path.isEmpty != $1.path.isEmpty { return !$0.path.isEmpty }
            return $0.totalTokens > $1.totalTokens
        }
        var lifeByPath: [String: ProjectTotal] = [:]
        for (dir, acc) in lifetimeProjectAcc {
            let path = ProjectKey.resolveRoot(dir: dir, cwdCounts: acc.cwds)
            var pt = lifeByPath[path] ?? ProjectTotal(path: path)
            pt.workTokens += acc.work
            pt.totalTokens += acc.total
            pt.costUSD += acc.cost
            lifeByPath[path] = pt
        }
        agg.allTimeByProject = lifeByPath.values.sorted {
            if $0.path.isEmpty != $1.path.isEmpty { return !$0.path.isEmpty }
            return $0.totalTokens > $1.totalTokens
        }
        return agg
    }
}
