import Foundation
import Observation

/// The view model the UI and mascot read from. Scans `~/.claude` off the main
/// actor, recomputes aggregates, and publishes them on the main actor.
@MainActor
@Observable
public final class MetricsStore {
    // Aggregates
    public var today = Totals()
    public var week = Totals()
    public var allTime = Totals()
    public var cycle = Totals()                  // current billing cycle
    public var todayByModel: [ModelTotal] = []
    public var weekDaily: [DayTotal] = []
    public var unknownModels: Set<String> = []
    public var activeBlock: UsageBlock?
    public var weekReset: Date?                   // end of the current fixed weekly window

    // Config (user-editable; persisted to UserDefaults)
    public var pricing = PricingTable.default
    public var budgetUnit: BudgetUnit = .tokens
    public var tokenBudget: Int = 2_000_000     // work tokens per 5h block
    public var costBudget: Double = 200          // notional API-equivalent $ per 5h block
    public var weeklyTokenBudget: Int = 20_000_000
    public var weeklyCostBudget: Double = 2000
    public var includeSubagents = true
    public var weightTokensByModel = true        // gauge counts Opus tokens heavier than Haiku (cost-weighted)
    public var widgetScale: Double = 1.0         // uniform zoom (all resize handles + slider)
    public var account: AccountInfo = .unknown   // plan + subscription start
    public var plan: AccountPlan { account.plan }
    public var autoBudgetFromPlan = true         // budget follows the plan unless overridden
    public var autoPeakBudget = true             // size the budget from your own peak usage (overrides plan)
    public var peakHeadroom = 0.15               // budget = peak × (1 + this); 100% sits just above your record

    // Peak usage over completed windows (recomputed each pass; the auto-budget denominator).
    public private(set) var peakBlockWork = 0
    public private(set) var peakBlockWeighted = 0.0
    public private(set) var peakBlockCost = 0.0
    public private(set) var peakWeekWork = 0
    public private(set) var peakWeekWeighted = 0.0
    public private(set) var peakWeekCost = 0.0

    /// Where the gauge budget comes from. A UI convenience over the two flags below.
    public enum BudgetSource: String, CaseIterable, Sendable { case auto, plan, custom }
    public var budgetSource: BudgetSource {
        get { autoPeakBudget ? .auto : (autoBudgetFromPlan ? .plan : .custom) }
        set {
            switch newValue {
            case .auto:   autoPeakBudget = true
            case .plan:   autoPeakBudget = false; autoBudgetFromPlan = true
            case .custom: autoPeakBudget = false; autoBudgetFromPlan = false
            }
        }
    }
    public var keepOnTop = false                 // always-on-top vs normal (clickable, coverable)
    public var monthlyPrice: Double = 0          // actual subscription $ paid per cycle (editable)
    public var creditSpent: Double = 0           // usage-credit $ spent this cycle (server-side; editable)
    public var creditLimit: Double = 0           // monthly spend limit for usage credits
    public var creditBalance: Double = 0         // current usage-credit balance
    public var showOnAllSpaces = false           // join all Spaces (can cover fullscreen) vs this Space only
    public var sessionResetOffset: Double = 0    // seconds added to the 5h session window (reset calibration)
    public var weeklyResetWeekday = 2            // weekly reset day (Calendar: 1=Sun … 2=Mon … 7=Sat); default Monday
    public var weeklyResetHour = 15              // hour of the weekly reset, local 24h (default 3 PM)
    public var weeklyResetMinute = 0             // minute of the weekly reset, local
    public var lastCalibratedAt: Date?           // when budgets were last fitted to Claude's /usage
    public var extraUsageEnabled: Bool { account.extraUsageEnabled }

    /// Anchor for the fixed weekly-limit grid: the configured reset weekday + time of day,
    /// so the window resets on e.g. Monday 3:00 PM local (the default).
    public var weeklyAnchor: Date {
        WeeklyWindowEngine.anchor(weekday: weeklyResetWeekday, hour: weeklyResetHour, minute: weeklyResetMinute)
    }

    public var lastUpdated: Date?
    public var isLoading = false

    /// Fired after every recompute (used for verification heartbeats; nil in normal use).
    public var onRecompute: (() -> Void)?

    /// Fired after config is saved (e.g. so the panel can resize to a new widget scale).
    public var onConfigChange: (() -> Void)?

    private let scanner = UsageScanner()
    private var watcher: FileWatcher?
    private var tick: Timer?                       // time-based recompute (rolls windows while idle)
    private var lastEntries: [UsageEntry] = []
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        account = AccountInfo.detect()
        monthlyPrice = account.plan.monthlyPrice    // default; overridden by saved value below
        loadConfig()
        if autoBudgetFromPlan {
            tokenBudget = plan.tokenBudget   // mirror plan so manual fields start sensibly
            costBudget = plan.costBudget
            weeklyTokenBudget = plan.weeklyTokenBudget
            weeklyCostBudget = plan.weeklyCostBudget
        }
    }

    /// Test hook: aggregate a fixed set of entries with the current config.
    public func ingestForTesting(_ entries: [UsageEntry]) {
        lastEntries = entries
        recompute()
    }

    // MARK: - Loading

    /// Initial refresh + live file watching for incremental updates.
    public func start() {
        Task { await refresh() }

        let root = UsageScanner.defaultRoot.path
        let w = FileWatcher(paths: [root]) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        w.start()
        watcher = w

        // The 5h session (and the day/week/cycle windows) reset on the clock, not on a file
        // write. Without this, an elapsed window keeps showing its old usage until the next
        // token is logged. Re-aggregate the cached entries periodically so it rolls to empty
        // on time. Cheap — no disk rescan; just re-sums lastEntries against a fresh `now`.
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        t.tolerance = 5
        tick = t
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        tick?.invalidate()
        tick = nil
    }

    public func refresh() async {
        isLoading = true
        lastEntries = await scanner.scan()
        recompute()
        isLoading = false
    }

    /// Synchronous one-shot load (used by snapshot rendering).
    public func loadFromDisk() {
        lastEntries = UsageScanner.scanOnce()
        recompute()
    }

    /// Re-aggregate the last-scanned entries with the current config (pricing,
    /// include-subagents). Cheap — no disk re-scan. Call after a settings change.
    public func recompute() {
        let now = Date()
        let entries = includeSubagents ? lastEntries : lastEntries.filter { !$0.isSidechain }
        let cycleStart = account.billingCycleStart(now: now)
        let weekWin = WeeklyWindowEngine.window(anchor: weeklyAnchor, now: now)
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now,
                                     cycleStart: cycleStart, weekWindow: weekWin)
        today = agg.today
        week = agg.week                              // now the fixed weekly-reset window total
        weekReset = weekWin.end
        allTime = agg.allTime
        cycle = agg.cycle
        todayByModel = agg.todayByModel
        weekDaily = agg.weekDaily
        unknownModels = agg.unknownModels
        activeBlock = FiveHourBlockEngine.activeSession(from: entries, pricing: pricing, now: now,
                                                        resetOffset: sessionResetOffset)
        let pb = FiveHourBlockEngine.peakCompleted(from: entries, pricing: pricing, now: now,
                                                   resetOffset: sessionResetOffset)
        peakBlockWork = pb.work; peakBlockWeighted = pb.weighted; peakBlockCost = pb.cost
        let pw = WeeklyWindowEngine.peakCompleted(from: entries, pricing: pricing,
                                                  anchor: weeklyAnchor, now: now)
        peakWeekWork = pw.work; peakWeekWeighted = pw.weighted; peakWeekCost = pw.cost
        lastUpdated = now
        onRecompute?()
    }

    // MARK: - Config persistence

    private enum Key {
        static let budgetUnit = "budgetUnit"
        static let tokenBudget = "tokenBudget"
        static let costBudget = "costBudget"
        static let includeSubagents = "includeSubagents"
        static let weightTokensByModel = "weightTokensByModel"
        static let pricing = "pricingTable"
        static let widgetScale = "widgetScale"
        static let autoBudgetFromPlan = "autoBudgetFromPlan"
        static let autoPeakBudget = "autoPeakBudget"
        static let peakHeadroom = "peakHeadroom"
        static let keepOnTop = "keepOnTop"
        static let weeklyTokenBudget = "weeklyTokenBudget"
        static let weeklyCostBudget = "weeklyCostBudget"
        static let monthlyPrice = "monthlyPrice"
        static let creditSpent = "extraUsagePaid"   // legacy key reused
        static let creditLimit = "creditLimit"
        static let creditBalance = "creditBalance"
        static let showOnAllSpaces = "showOnAllSpaces"
        static let sessionResetOffset = "sessionResetOffset"
        static let weeklyResetWeekday = "weeklyResetWeekday"
        static let weeklyResetHour = "weeklyResetHour"
        static let weeklyResetMinute = "weeklyResetMinute"
        static let lastCalibratedAt = "lastCalibratedAt"
    }

    public func loadConfig() {
        if let raw = defaults.string(forKey: Key.budgetUnit), let u = BudgetUnit(rawValue: raw) {
            budgetUnit = u
        }
        if defaults.object(forKey: Key.tokenBudget) != nil {
            tokenBudget = defaults.integer(forKey: Key.tokenBudget)
        }
        if defaults.object(forKey: Key.costBudget) != nil {
            costBudget = defaults.double(forKey: Key.costBudget)
        }
        if defaults.object(forKey: Key.includeSubagents) != nil {
            includeSubagents = defaults.bool(forKey: Key.includeSubagents)
        }
        if defaults.object(forKey: Key.weightTokensByModel) != nil {
            weightTokensByModel = defaults.bool(forKey: Key.weightTokensByModel)
        }
        if let data = defaults.data(forKey: Key.pricing),
           let table = try? JSONDecoder().decode(PricingTable.self, from: data) {
            // Fill in families added since this table was saved (e.g. Fable) so new models
            // are priced/weighted instead of silently counting as free/unweighted.
            pricing = table.mergingMissingDefaults()
        }
        if defaults.object(forKey: Key.widgetScale) != nil {
            widgetScale = defaults.double(forKey: Key.widgetScale)
        }
        if defaults.object(forKey: Key.autoBudgetFromPlan) != nil {
            autoBudgetFromPlan = defaults.bool(forKey: Key.autoBudgetFromPlan)
        }
        if defaults.object(forKey: Key.autoPeakBudget) != nil {
            autoPeakBudget = defaults.bool(forKey: Key.autoPeakBudget)
        }
        if defaults.object(forKey: Key.peakHeadroom) != nil {
            peakHeadroom = defaults.double(forKey: Key.peakHeadroom)
        }
        if defaults.object(forKey: Key.keepOnTop) != nil {
            keepOnTop = defaults.bool(forKey: Key.keepOnTop)
        }
        if defaults.object(forKey: Key.weeklyTokenBudget) != nil {
            weeklyTokenBudget = defaults.integer(forKey: Key.weeklyTokenBudget)
        }
        if defaults.object(forKey: Key.weeklyCostBudget) != nil {
            weeklyCostBudget = defaults.double(forKey: Key.weeklyCostBudget)
        }
        if defaults.object(forKey: Key.monthlyPrice) != nil {
            monthlyPrice = defaults.double(forKey: Key.monthlyPrice)
        }
        if defaults.object(forKey: Key.creditSpent) != nil { creditSpent = defaults.double(forKey: Key.creditSpent) }
        if defaults.object(forKey: Key.creditLimit) != nil { creditLimit = defaults.double(forKey: Key.creditLimit) }
        if defaults.object(forKey: Key.creditBalance) != nil { creditBalance = defaults.double(forKey: Key.creditBalance) }
        if defaults.object(forKey: Key.showOnAllSpaces) != nil { showOnAllSpaces = defaults.bool(forKey: Key.showOnAllSpaces) }
        if defaults.object(forKey: Key.sessionResetOffset) != nil { sessionResetOffset = defaults.double(forKey: Key.sessionResetOffset) }
        if defaults.object(forKey: Key.weeklyResetWeekday) != nil { weeklyResetWeekday = defaults.integer(forKey: Key.weeklyResetWeekday) }
        if defaults.object(forKey: Key.weeklyResetHour) != nil { weeklyResetHour = defaults.integer(forKey: Key.weeklyResetHour) }
        if defaults.object(forKey: Key.weeklyResetMinute) != nil { weeklyResetMinute = defaults.integer(forKey: Key.weeklyResetMinute) }
        if defaults.object(forKey: Key.lastCalibratedAt) != nil {
            lastCalibratedAt = Date(timeIntervalSince1970: defaults.double(forKey: Key.lastCalibratedAt))
        }
    }

    /// Persist config and re-aggregate so changes show immediately.
    public func saveConfigAndRecompute() {
        defaults.set(budgetUnit.rawValue, forKey: Key.budgetUnit)
        defaults.set(tokenBudget, forKey: Key.tokenBudget)
        defaults.set(costBudget, forKey: Key.costBudget)
        defaults.set(includeSubagents, forKey: Key.includeSubagents)
        defaults.set(weightTokensByModel, forKey: Key.weightTokensByModel)
        if let data = try? JSONEncoder().encode(pricing) {
            defaults.set(data, forKey: Key.pricing)
        }
        defaults.set(widgetScale, forKey: Key.widgetScale)
        defaults.set(autoBudgetFromPlan, forKey: Key.autoBudgetFromPlan)
        defaults.set(autoPeakBudget, forKey: Key.autoPeakBudget)
        defaults.set(peakHeadroom, forKey: Key.peakHeadroom)
        defaults.set(keepOnTop, forKey: Key.keepOnTop)
        defaults.set(weeklyTokenBudget, forKey: Key.weeklyTokenBudget)
        defaults.set(weeklyCostBudget, forKey: Key.weeklyCostBudget)
        defaults.set(monthlyPrice, forKey: Key.monthlyPrice)
        defaults.set(creditSpent, forKey: Key.creditSpent)
        defaults.set(creditLimit, forKey: Key.creditLimit)
        defaults.set(creditBalance, forKey: Key.creditBalance)
        defaults.set(showOnAllSpaces, forKey: Key.showOnAllSpaces)
        defaults.set(sessionResetOffset, forKey: Key.sessionResetOffset)
        defaults.set(weeklyResetWeekday, forKey: Key.weeklyResetWeekday)
        defaults.set(weeklyResetHour, forKey: Key.weeklyResetHour)
        defaults.set(weeklyResetMinute, forKey: Key.weeklyResetMinute)
        if let t = lastCalibratedAt {
            defaults.set(t.timeIntervalSince1970, forKey: Key.lastCalibratedAt)
        } else {
            defaults.removeObject(forKey: Key.lastCalibratedAt)
        }
        recompute()
        onConfigChange?()
    }

    // MARK: - 5h gauge helpers (unit-aware)

    public func blockValue(unit: BudgetUnit) -> Double {
        guard let b = activeBlock else { return 0 }
        // $ tracks notional cost; tokens track WORK tokens — cost-weighted by model
        // (Sonnet-equivalent) when enabled, else the flat human-scale sum.
        if unit == .usd { return b.costUSD }
        return weightTokensByModel ? b.weightedTokens : Double(b.workTokens)
    }

    public func blockBudget(unit: BudgetUnit) -> Double {
        if autoPeakBudget {
            // A fresh manual calibration is the most accurate anchor — it wins until a reset.
            if lastCalibratedAt != nil && !calibrationIsStale {
                return unit == .tokens ? Double(tokenBudget) : costBudget
            }
            let peak = peakBlockBudget(unit: unit)
            if peak > 0 { return peak }
            // No completed history yet — fall back to the plan estimate.
            return unit == .tokens ? Double(plan.tokenBudget) : plan.costBudget
        }
        if autoBudgetFromPlan {
            return unit == .tokens ? Double(plan.tokenBudget) : plan.costBudget
        }
        return unit == .tokens ? Double(tokenBudget) : costBudget
    }

    /// Auto budget = your heaviest completed 5h block + headroom, in the gauge's unit.
    private func peakBlockBudget(unit: BudgetUnit) -> Double {
        let base = unit == .usd ? peakBlockCost
            : (weightTokensByModel ? peakBlockWeighted : Double(peakBlockWork))
        return base * (1 + peakHeadroom)
    }

    /// Clamped [0,1] fill for the bar.
    public func blockFraction(unit: BudgetUnit) -> Double {
        let budget = blockBudget(unit: unit)
        guard budget > 0 else { return 0 }
        return min(1, max(0, blockValue(unit: unit) / budget))
    }

    public func blockBurnPerHour(unit: BudgetUnit, now: Date = Date()) -> Double {
        guard let b = activeBlock else { return 0 }
        let hours = max(now.timeIntervalSince(b.actualStart) / 3600, 1.0 / 60)
        return blockValue(unit: unit) / hours
    }

    // MARK: - Weekly (7-day) gauge helpers

    public func weeklyValue(unit: BudgetUnit) -> Double {
        if unit == .usd { return week.costUSD }
        return weightTokensByModel ? week.weightedTokens : Double(week.workTokens)
    }

    public func weeklyBudget(unit: BudgetUnit) -> Double {
        if autoPeakBudget {
            if lastCalibratedAt != nil && !calibrationIsStale {
                return unit == .tokens ? Double(weeklyTokenBudget) : weeklyCostBudget
            }
            let peak = peakWeeklyBudget(unit: unit)
            if peak > 0 { return peak }
            return unit == .tokens ? Double(plan.weeklyTokenBudget) : plan.weeklyCostBudget
        }
        if autoBudgetFromPlan {
            return unit == .tokens ? Double(plan.weeklyTokenBudget) : plan.weeklyCostBudget
        }
        return unit == .tokens ? Double(weeklyTokenBudget) : weeklyCostBudget
    }

    /// Auto budget = your heaviest completed weekly window + headroom, in the gauge's unit.
    private func peakWeeklyBudget(unit: BudgetUnit) -> Double {
        let base = unit == .usd ? peakWeekCost
            : (weightTokensByModel ? peakWeekWeighted : Double(peakWeekWork))
        return base * (1 + peakHeadroom)
    }

    public func weeklyFraction(unit: BudgetUnit) -> Double {
        let budget = weeklyBudget(unit: unit)
        guard budget > 0 else { return 0 }
        return min(1, max(0, weeklyValue(unit: unit) / budget))
    }

    /// How much budget remains (clamped ≥ 0).
    public func blockRemaining(unit: BudgetUnit) -> Double {
        max(0, blockBudget(unit: unit) - blockValue(unit: unit))
    }
    public func weeklyRemaining(unit: BudgetUnit) -> Double {
        max(0, weeklyBudget(unit: unit) - weeklyValue(unit: unit))
    }

    // MARK: - Calibration to Claude's /usage

    /// Fit the 5h and/or weekly budgets so the gauges read the percentages Claude's
    /// `/usage` shows right now. A non-positive pct (or a gauge with no measured usage
    /// to back-solve from) leaves that gauge untouched. Returns true if anything was set.
    ///
    /// Subscription usage isn't exposed by any API, so this manual sync is the only bridge
    /// to Anthropic's real numbers. We back-solve `budget = currentValue / (pct/100)` against
    /// the live gauge value (which already accounts for cost-weighting), persist, and stamp
    /// the moment so staleness can be surfaced.
    @discardableResult
    public func calibrateLimits(sessionPct: Double, weeklyPct: Double,
                                unit: BudgetUnit, now: Date = Date()) -> Bool {
        var did = false
        if sessionPct > 0 {
            let v = blockValue(unit: unit)
            if v > 0 {
                let budget = v / (sessionPct / 100)
                if unit == .tokens { tokenBudget = Int(budget) } else { costBudget = budget }
                did = true
            }
        }
        if weeklyPct > 0 {
            let v = weeklyValue(unit: unit)
            if v > 0 {
                let budget = v / (weeklyPct / 100)
                if unit == .tokens { weeklyTokenBudget = Int(budget) } else { weeklyCostBudget = budget }
                did = true
            }
        }
        if did {
            autoBudgetFromPlan = false        // calibrated budgets override the plan estimate
            lastCalibratedAt = now
            saveConfigAndRecompute()
        }
        return did
    }

    /// True when the calibration anchor predates the current 5h or weekly window — i.e. a
    /// reset has occurred since the user last synced, so the % basis has moved and a
    /// re-calibration would re-align it. Also true when never calibrated.
    public func calibrationIsStale(now: Date = Date()) -> Bool {
        guard let cal = lastCalibratedAt else { return true }
        let weekStart = WeeklyWindowEngine.window(anchor: weeklyAnchor, now: now).start
        if cal < weekStart { return true }
        if let blockStart = activeBlock?.start, cal < blockStart { return true }
        return false
    }

    /// `calibrationIsStale(now:)` with the current clock — convenient for SwiftUI reads.
    public var calibrationIsStale: Bool { calibrationIsStale() }

    /// Short relative age of the last calibration ("just now", "2h ago", "3d ago"),
    /// or nil if never calibrated.
    public var calibrationAgeDescription: String? {
        guard let cal = lastCalibratedAt else { return nil }
        return Format.relativeAge(from: cal)
    }

    /// Plain-language description of what the gauge percentages are measured against right
    /// now — so the UI can be honest about the denominator (peak vs calibrated vs estimate).
    public var budgetBasisDescription: String {
        if autoPeakBudget, lastCalibratedAt != nil, !calibrationIsStale,
           let age = calibrationAgeDescription {
            return "Claude's /usage (calibrated \(age))"
        }
        if autoPeakBudget, peakBlockWork > 0 || peakWeekWork > 0 {
            return "your peak usage +\(Int((peakHeadroom * 100).rounded()))% — your own record, not Anthropic's cap"
        }
        if lastCalibratedAt != nil, !calibrationIsStale, let age = calibrationAgeDescription {
            return "Claude's /usage (calibrated \(age))"
        }
        return autoBudgetFromPlan ? "a tier-scaled plan estimate" : "your custom budget"
    }

    // MARK: - Previews / snapshots

    public func loadSampleForPreview() {
        let now = Date()
        today = Totals(workTokens: 142_000, totalTokens: 41_200_000, costUSD: 4.21)
        week = Totals(workTokens: 1_200_000, totalTokens: 300_000_000, costUSD: 38, weightedTokens: 1_650_000)
        allTime = Totals(workTokens: 14_000_000, totalTokens: 3_400_000_000, costUSD: 402)
        cycle = Totals(workTokens: 5_400_000, totalTokens: 1_300_000_000, costUSD: 180)
        monthlyPrice = 100; creditSpent = 13.47; creditLimit = 60; creditBalance = 5.60
        todayByModel = [
            ModelTotal(family: .fable,  workTokens: 22_000, totalTokens: 9_000_000,  costUSD: 2.80),
            ModelTotal(family: .opus,   workTokens: 41_000, totalTokens: 20_000_000, costUSD: 3.10),
            ModelTotal(family: .sonnet, workTokens: 77_000, totalTokens: 18_000_000, costUSD: 1.05),
            ModelTotal(family: .haiku,  workTokens: 10_000, totalTokens: 3_200_000,  costUSD: 0.06),
        ]
        activeBlock = UsageBlock(start: now.addingTimeInterval(-2 * 3600),
                                 actualStart: now.addingTimeInterval(-2 * 3600),
                                 lastActivity: now,
                                 workTokens: 1_240_000, totalTokens: 44_000_000, costUSD: 150,
                                 weightedTokens: 1_700_000)
        weekReset = now.addingTimeInterval(3 * 86_400 + 4 * 3600)   // ~3d 4h until weekly reset
        let work = [600_000, 900_000, 400_000, 1_100_000, 700_000, 1_300_000, 1_500_000]
        weekDaily = (0..<7).map { i in
            DayTotal(date: now.addingTimeInterval(Double(i - 6) * 86_400),
                     workTokens: work[i], totalTokens: work[i] * 200, costUSD: Double(work[i]) / 7000)
        }
        lastUpdated = now
    }
}
