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
    public var todayHourly: [HourTotal] = []   // today's usage in 24 local-hour buckets (all models)
    public var unknownModels: Set<String> = []
    /// One bucket per calendar date the billing cycle touches, and the same window split by
    /// project. Both use the identical in-cycle predicate as `cycle`, so each sums exactly to it.
    public var cycleDaily: [DayTotal] = []
    public var cycleByProject: [ProjectTotal] = []
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

        for e in entries {
            let cost = pricing.cost(for: e)
            let weight = pricing.weight(for: e.family)
            agg.allTime.add(e, cost: cost, weight: weight)

            // ONE predicate for `cycle`, `cycleDaily` and `cycleByProject`: the dashboard shows the
            // three together, so a bar chart or a project list that didn't add up to the headline
            // figure would read as a bug. It's also bounded above now — an entry stamped past the
            // cycle end (clock skew) used to inflate `cycle` while belonging to no bucket.
            if let cw = cycleWindow, e.timestamp >= cw.start, e.timestamp < cw.end {
                agg.cycle.add(e, cost: cost, weight: weight)

                let day = calendar.startOfDay(for: e.timestamp)
                if cycleBuckets[day] != nil {
                    cycleBuckets[day]!.workTokens += e.workTokens
                    cycleBuckets[day]!.totalTokens += e.totalTokens
                    cycleBuckets[day]!.costUSD += cost
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
                    let day = calendar.startOfDay(for: e.timestamp)
                    let n = calendar.dateComponents([.day], from: first, to: day).day ?? 0
                    dayKey = dayOrder[((n % 7) + 7) % 7]
                } else {
                    dayKey = nil
                }
            } else {
                dayKey = e.timestamp >= weekStart ? calendar.startOfDay(for: e.timestamp) : nil
            }
            if let key = dayKey, dayBuckets[key] != nil {
                dayBuckets[key]!.workTokens += e.workTokens
                dayBuckets[key]!.totalTokens += e.totalTokens
                dayBuckets[key]!.costUSD += cost
            }

            if calendar.isDate(e.timestamp, inSameDayAs: now) {
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
        agg.todayHourly = hourBuckets
        agg.cycleDaily = cycleOrder.map { cycleBuckets[$0] ?? DayTotal(date: $0) }
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
        return agg
    }
}
