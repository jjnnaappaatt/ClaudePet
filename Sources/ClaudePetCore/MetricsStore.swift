import Foundation
import Observation

/// Widget shape: the wide two-column card (default) or the original tall single column.
public enum WidgetLayout: String, CaseIterable, Sendable { case landscape, vertical }

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
    public var todayHourly: [HourTotal] = []      // today's usage in 24 local-hour buckets
    public var cycleDaily: [DayTotal] = []        // one bucket per calendar date the billing cycle
    public var cycleByProject: [ProjectTotal] = []  // touches, and that same window split by project
                                                 // — each sums exactly to `cycle` (dashboard only)
    public var unknownModels: Set<String> = []
    public var activeBlock: UsageBlock?
    public var weekReset: Date?                   // end of the current fixed weekly window
    public private(set) var cycleStart: Date?      // start of the current billing cycle
    public private(set) var cycleReset: Date?      // end of the current billing cycle (next anniversary)
    public private(set) var serverUsage: StatuslineUsage?   // real 5h/7d from the statusline cache (local file read; no token/network)

    // Config (user-editable; persisted to UserDefaults)
    public var pricing = PricingTable.default
    public var budgetUnit: BudgetUnit = .tokens
    public var tokenBudget: Int = 2_000_000     // work tokens per 5h block
    public var costBudget: Double = 200          // notional API-equivalent $ per 5h block
    public var weeklyTokenBudget: Int = 20_000_000
    public var weeklyCostBudget: Double = 2000
    public var includeSubagents = true
    /// Count every logged assistant line instead of one per `message.id` — reproduces Claude
    /// Code's `/stats` figure. Off by default: ~57% of logged lines repeat an id already seen,
    /// with byte-identical usage, so they are re-logs of one API response rather than extra
    /// consumption, and counting them roughly doubles every number.
    public var countRepeatedLogLines = false
    public var weightTokensByModel = true        // gauge counts Opus tokens heavier than Haiku (cost-weighted)
    public var tokenBasis: TokenBasis = .total   // per-day token figures: cache-inclusive total (default) vs work (in+out)
    public var widgetScale: Double = 1.0         // uniform zoom (all resize handles + slider)
    public var widgetLayout: WidgetLayout = .landscape   // wide two-column (default) vs tall single column
    public var weatherEffectsEnabled = true      // ambient weather + celebrations behind the pet
    public var account: AccountInfo = .unknown   // plan + subscription start
    public var plan: AccountPlan { account.plan }
    public var autoBudgetFromPlan = true         // budget follows the plan unless overridden
    public var autoPeakBudget = true             // size the budget from your own usage (overrides plan)
    public var peakHeadroom = 0.15               // budget = anchor × (1 + this); 100% sits just above a heavy window

    // The auto-budget denominator, recomputed each pass. Despite the names these are NOT maxima:
    // `PeakEstimator` takes a fixed quantile of the completed windows so the 5h and weekly gauges
    // stay calibrated alike as their (very differently sized) window pools grow.
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
    public var billingCycleDayOverride: Int?     // manual day-of-month (1–31) override for the billing
                                                  // cycle anchor, for accounts (e.g. org/team plans) whose
                                                  // real Stripe billing day doesn't match subscriptionCreatedAt.
                                                  // nil = use the subscription-derived anchor.
    public var lastCalibratedAt: Date?           // when the 5h budget was last fitted to Claude's %
    public var weeklyCalibratedAt: Date?         // …and the weekly one, which expires on a different
                                                  // clock. One shared stamp meant every 5h reset —
                                                  // several a day — also dropped a perfectly good
                                                  // weekly fit back to the local estimate (observed:
                                                  // 22M → 57M). Strictly independent: a session-only
                                                  // fit must not make the weekly budget look synced.
                                                  // `loadConfig` migrates old single-stamp prefs.
    public var blockFitPercent: Double?          // the server % each stored budget was back-solved
    public var weeklyFitPercent: Double?         // from. Error scales as 1/percent — ±0.5% rounding
                                                  // is ±0.5% of the budget at 96% but ±7% at 7% —
                                                  // so a fit records its own precision and defends
                                                  // itself against noisier later samples.
    public private(set) var calibrationWasAutomatic = false   // …and whether that fit came from the
                                                  // statusline cache rather than the Calibrate sheet,
                                                  // so the UI can say which without lying. One flag
                                                  // for both gauges: it can mislabel one side after a
                                                  // hand calibration followed by an auto re-fit of the
                                                  // other, which is rare and cosmetic.
    public var useStatuslineData = true          // drive gauges from the statusline's local usage cache when present
    public var statuslineCachePath = StatuslineUsageReader.defaultPath   // injectable for tests
    /// Claude Code's own `/stats` cache. Injectable, and — exactly like `statuslineCachePath` — it
    /// defaults to the REAL file, so any test touching these figures must go through
    /// `TestSupport.store(defaults:)` or it reads the developer's own usage and passes by machine.
    public var statsCachePath = StatsCacheReader.defaultPath
    public private(set) var statsCache: StatsCache?
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
    /// Which counting mode `lastEntries` was produced with, so a change can trigger a re-merge.
    private var lastScanCountedRepeats = false
    /// Only true once entries came from disk. Guards the auto re-merge below so a store fed by
    /// `ingestForTesting` never kicks off a real scan of `~/.claude` behind a unit test.
    private var hasScannedFromDisk = false
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

    /// Verification hook: drop the calibration anchor in memory only, so the local-history
    /// budget estimate becomes visible behind it. Never persisted.
    public func clearCalibrationForTesting() {
        lastCalibratedAt = nil
        weeklyCalibratedAt = nil        // both, or the weekly gauge keeps showing its fit and the
        blockFitPercent = nil           // "no live data" view is only half true
        weeklyFitPercent = nil
        calibrationWasAutomatic = false
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
        lastScanCountedRepeats = countRepeatedLogLines
        hasScannedFromDisk = true
        lastEntries = await scanner.scan(deduplicated: !countRepeatedLogLines)
        recompute()
        isLoading = false
    }

    /// Synchronous one-shot load (used by snapshot rendering).
    public func loadFromDisk() {
        lastScanCountedRepeats = countRepeatedLogLines
        hasScannedFromDisk = true
        lastEntries = UsageScanner.scanOnce(deduplicated: !countRepeatedLogLines)
        recompute()
    }

    /// Re-aggregate the last-scanned entries with the current config (pricing,
    /// include-subagents). Cheap — no disk re-scan. Call after a settings change.
    public func recompute() {
        let now = Date()
        let entries = includeSubagents ? lastEntries : lastEntries.filter { !$0.isSidechain }
        let cycleBounds: (start: Date, end: Date)
        if let day = billingCycleDayOverride {
            cycleBounds = AccountInfo.dayOverrideCycleBounds(day: day, now: now)
        } else {
            cycleBounds = (account.billingCycleStart(now: now), account.billingCycleEnd(now: now))
        }
        let weekWin = WeeklyWindowEngine.window(anchor: weeklyAnchor, now: now)
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now,
                                     cycleWindow: cycleBounds, weekWindow: weekWin)
        today = agg.today
        week = agg.week                              // now the fixed weekly-reset window total
        weekReset = weekWin.end
        allTime = agg.allTime
        cycle = agg.cycle
        cycleStart = cycleBounds.start
        cycleReset = cycleBounds.end
        todayByModel = agg.todayByModel
        weekDaily = agg.weekDaily
        todayHourly = agg.todayHourly
        cycleDaily = agg.cycleDaily
        cycleByProject = agg.cycleByProject
        unknownModels = agg.unknownModels
        activeBlock = FiveHourBlockEngine.activeSession(from: entries, pricing: pricing, now: now,
                                                        resetOffset: sessionResetOffset)
        let pb = FiveHourBlockEngine.peakCompleted(from: entries, pricing: pricing, now: now,
                                                   resetOffset: sessionResetOffset)
        peakBlockWork = pb.work; peakBlockWeighted = pb.weighted; peakBlockCost = pb.cost
        let pw = WeeklyWindowEngine.peakCompleted(from: entries, pricing: pricing,
                                                  anchor: weeklyAnchor, now: now)
        peakWeekWork = pw.work; peakWeekWeighted = pw.weighted; peakWeekCost = pw.cost
        // Real server-side 5h/7d numbers, read from the statusline's local cache (no token,
        // no network — ClaudePet only reads the file the user's statusline already wrote).
        serverUsage = useStatuslineData ? StatuslineUsageReader.read(path: statuslineCachePath) : nil
        // Cheap (22 KB) and it only changes when Claude Code recomputes, so a plain re-read per
        // recompute is fine — no need for the mtime/size cache `UsageScanner` needs for 100 MB files.
        statsCache = StatsCacheReader.read(path: statsCachePath)
        // Must run before the mood/weather edges below, which read the gauge fractions this moves.
        applyServerCalibration(now: now, entries: entries)
        lastUpdated = now
        detectWeatherEdges()
        onRecompute?()
    }

    // MARK: - Config persistence

    private enum Key {
        static let budgetUnit = "budgetUnit"
        static let tokenBudget = "tokenBudget"
        static let costBudget = "costBudget"
        static let includeSubagents = "includeSubagents"
        static let countRepeatedLogLines = "countRepeatedLogLines"
        static let weightTokensByModel = "weightTokensByModel"
        static let pricing = "pricingTable"
        static let widgetScale = "widgetScale"
        static let widgetLayout = "widgetLayout"
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
        static let billingCycleDayOverride = "billingCycleDayOverride"
        static let lastCalibratedAt = "lastCalibratedAt"
        static let weeklyCalibratedAt = "weeklyCalibratedAt"
        static let blockFitPercent = "blockFitPercent"
        static let weeklyFitPercent = "weeklyFitPercent"
        static let calibrationWasAutomatic = "calibrationWasAutomatic"
        static let useStatuslineData = "useStatuslineData"
        static let weatherEffectsEnabled = "weatherEffectsEnabled"
        static let tokenBasis = "tokenBasis"
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
        if defaults.object(forKey: Key.countRepeatedLogLines) != nil {
            countRepeatedLogLines = defaults.bool(forKey: Key.countRepeatedLogLines)
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
        if let raw = defaults.string(forKey: Key.widgetLayout), let l = WidgetLayout(rawValue: raw) {
            widgetLayout = l
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
        if defaults.object(forKey: Key.billingCycleDayOverride) != nil {
            billingCycleDayOverride = defaults.integer(forKey: Key.billingCycleDayOverride)
        }
        if defaults.object(forKey: Key.lastCalibratedAt) != nil {
            lastCalibratedAt = Date(timeIntervalSince1970: defaults.double(forKey: Key.lastCalibratedAt))
        }
        if defaults.object(forKey: Key.weeklyCalibratedAt) != nil {
            weeklyCalibratedAt = Date(timeIntervalSince1970: defaults.double(forKey: Key.weeklyCalibratedAt))
        } else {
            // Migration: prefs written before the stamps were split carry one date covering both
            // gauges. Copy it across rather than treating the weekly side as never calibrated.
            weeklyCalibratedAt = lastCalibratedAt
        }
        // Absent for budgets fitted before fit percentages were recorded — left nil, which reads as
        // "unknown precision", so the next usable sample may replace it.
        if defaults.object(forKey: Key.blockFitPercent) != nil {
            blockFitPercent = defaults.double(forKey: Key.blockFitPercent)
        }
        if defaults.object(forKey: Key.weeklyFitPercent) != nil {
            weeklyFitPercent = defaults.double(forKey: Key.weeklyFitPercent)
        }
        if defaults.object(forKey: Key.calibrationWasAutomatic) != nil {
            calibrationWasAutomatic = defaults.bool(forKey: Key.calibrationWasAutomatic)
        }
        if defaults.object(forKey: Key.useStatuslineData) != nil {
            useStatuslineData = defaults.bool(forKey: Key.useStatuslineData)
        }
        if defaults.object(forKey: Key.weatherEffectsEnabled) != nil {
            weatherEffectsEnabled = defaults.bool(forKey: Key.weatherEffectsEnabled)
        }
        if let raw = defaults.string(forKey: Key.tokenBasis), let b = TokenBasis(rawValue: raw) {
            tokenBasis = b
        }
    }

    /// Persist config and re-aggregate so changes show immediately.
    public func saveConfigAndRecompute() {
        defaults.set(budgetUnit.rawValue, forKey: Key.budgetUnit)
        defaults.set(tokenBudget, forKey: Key.tokenBudget)
        defaults.set(costBudget, forKey: Key.costBudget)
        defaults.set(includeSubagents, forKey: Key.includeSubagents)
        defaults.set(countRepeatedLogLines, forKey: Key.countRepeatedLogLines)
        defaults.set(weightTokensByModel, forKey: Key.weightTokensByModel)
        if let data = try? JSONEncoder().encode(pricing) {
            defaults.set(data, forKey: Key.pricing)
        }
        defaults.set(widgetScale, forKey: Key.widgetScale)
        defaults.set(widgetLayout.rawValue, forKey: Key.widgetLayout)
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
        if let d = billingCycleDayOverride {
            defaults.set(d, forKey: Key.billingCycleDayOverride)
        } else {
            defaults.removeObject(forKey: Key.billingCycleDayOverride)
        }
        if let t = lastCalibratedAt {
            defaults.set(t.timeIntervalSince1970, forKey: Key.lastCalibratedAt)
        } else {
            defaults.removeObject(forKey: Key.lastCalibratedAt)
        }
        if let t = weeklyCalibratedAt {
            defaults.set(t.timeIntervalSince1970, forKey: Key.weeklyCalibratedAt)
        } else {
            defaults.removeObject(forKey: Key.weeklyCalibratedAt)
        }
        persistOptional(blockFitPercent, forKey: Key.blockFitPercent)
        persistOptional(weeklyFitPercent, forKey: Key.weeklyFitPercent)
        defaults.set(calibrationWasAutomatic, forKey: Key.calibrationWasAutomatic)
        defaults.set(useStatuslineData, forKey: Key.useStatuslineData)
        defaults.set(weatherEffectsEnabled, forKey: Key.weatherEffectsEnabled)
        defaults.set(tokenBasis.rawValue, forKey: Key.tokenBasis)
        recompute()
        // Dedup happens during the scan's merge, not in `recompute`, so this one setting needs a
        // re-scan to take effect. It re-merges the per-file parse cache — no file is re-read.
        if hasScannedFromDisk, lastScanCountedRepeats != countRepeatedLogLines {
            Task { await refresh() }
        }
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

    /// Real tokens (or $) actually used this block — raw, NEVER cost-weighted (that's
    /// `blockValue`), on the user's work/total basis so this subtitle can't contradict the
    /// header, charts and footer sitting beside it.
    public func blockTokensUsed(unit: BudgetUnit) -> Double {
        guard let b = activeBlock else { return 0 }
        return unit == .usd ? b.costUSD : Double(blockTokens(b))
    }

    /// `now` only decides whether a fitted budget has aged out — injectable so tests don't depend
    /// on the wall clock (see `CalibrationTests`).
    public func blockBudget(unit: BudgetUnit, now: Date = Date()) -> Double {
        if autoPeakBudget {
            // A fitted cap is the most accurate anchor, and it does NOT expire when the window
            // resets — what resets is the percentage, not Claude's limit, which is a property of
            // the plan. Tying it to the window meant the 5h budget was discarded 4–5× a day and
            // replaced by the local estimate, which measured ~3× high (6.2M against a real ~1.9M).
            if !blockFitIsExpired(now: now), lastCalibratedAt != nil {
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

    /// Clamped [0,1] fill for the bar. Prefers Claude's real utilization (from the
    /// statusline cache) when available; otherwise the local budget estimate.
    public func blockFraction(unit: BudgetUnit) -> Double {
        if let s = serverUsage?.fiveHour, serverFresh, s.isUsable() { return s.fraction }
        let budget = blockBudget(unit: unit)
        guard budget > 0 else { return 0 }
        return min(1, max(0, blockValue(unit: unit) / budget))
    }

    public func blockBurnPerHour(unit: BudgetUnit, now: Date = Date()) -> Double {
        guard let b = activeBlock else { return 0 }
        let hours = max(now.timeIntervalSince(b.actualStart) / 3600, 1.0 / 60)
        return blockTokensUsed(unit: unit) / hours   // real tokens, sharing "used"'s basis
    }

    // MARK: - Weekly (7-day) gauge helpers

    public func weeklyValue(unit: BudgetUnit) -> Double {
        if unit == .usd { return week.costUSD }
        return weightTokensByModel ? week.weightedTokens : Double(week.workTokens)
    }

    /// Real tokens (or $) actually used this week — raw, NEVER cost-weighted, on the user's
    /// work/total basis (so it agrees with the "Week" figure in the footer directly below).
    public func weeklyTokensUsed(unit: BudgetUnit) -> Double {
        unit == .usd ? week.costUSD : Double(totalsTokens(week))
    }

    public func weeklyBudget(unit: BudgetUnit, now: Date = Date()) -> Double {
        if autoPeakBudget {
            if !weeklyFitIsExpired(now: now), weeklyCalibratedAt != nil {
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
        if let s = serverUsage?.sevenDay, serverFresh, s.isUsable() { return s.fraction }
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

    // MARK: - Daily pace
    // Today's tokens vs your recent daily average. Claude has no daily limit, so this bar is
    // informational: the average day sits at the midpoint (full ≈ 2× a usual day). All values
    // come from the `weekDaily` series so today and the average stay on one consistent basis.

    private func dayValue(_ d: DayTotal, unit: BudgetUnit) -> Double {
        unit == .usd ? d.costUSD : Double(dayTokens(d))
    }

    /// Is this the `weekDaily` bucket holding `now` — i.e. the "today" bar?
    ///
    /// Matches on WEEKDAY, not on the date: the buckets are the seven weekday slots of the weekly
    /// window, so reset day's slot is dated to the window's opening date even once `now` has
    /// reached the window's closing date a week later. Seven slots are seven distinct weekdays, so
    /// this stays unambiguous. Order-independent too — callers build the array both oldest-first
    /// and newest-first, so it must not assume the current day is the last element.
    public func isCurrentDayBucket(_ d: DayTotal, now: Date = Date(),
                                   calendar: Calendar = .current) -> Bool {
        calendar.component(.weekday, from: d.date) == calendar.component(.weekday, from: now)
    }

    /// Today's tokens (or $) from the 7-day series — falls back to the canonical `today`
    /// totals only if the series has no bucket covering `now`.
    public func dailyTodayValue(unit: BudgetUnit, now: Date = Date(), calendar: Calendar = .current) -> Double {
        if let t = weekDaily.first(where: { isCurrentDayBucket($0, now: now, calendar: calendar) }) {
            return dayValue(t, unit: unit)
        }
        return unit == .usd ? today.costUSD : Double(totalsTokens(today))
    }

    /// Average over the prior buckets in the window (excludes the current one and zero-usage
    /// buckets, so not-yet-started cells can't drag the average down). 0 = no history.
    public func dailyAverage(unit: BudgetUnit, now: Date = Date(), calendar: Calendar = .current) -> Double {
        let priors = weekDaily
            .filter { !isCurrentDayBucket($0, now: now, calendar: calendar) }
            .map { dayValue($0, unit: unit) }
            .filter { $0 > 0 }
        guard !priors.isEmpty else { return 0 }
        return priors.reduce(0, +) / Double(priors.count)
    }

    /// Bar fill: a usual day fills the bar, so the fill IS "today as a share of a usual day" and
    /// matches the percentage printed beside it. 0 when no history.
    ///
    /// This used to put the average at the MIDPOINT (full ≈ 2× a usual day) to leave room to show
    /// a heavy day. Nobody read it that way: a day at 66% of normal drew a third of a bar, and
    /// once the caption stated "today 66%" the bar and the number visibly disagreed. Days past a
    /// usual one now clamp at full and are called out by colour plus the exact % in the caption,
    /// which keeps the information without making the bar lie.
    public func dailyPaceFraction(unit: BudgetUnit, now: Date = Date(), calendar: Calendar = .current) -> Double {
        let avg = dailyAverage(unit: unit, now: now, calendar: calendar)
        guard avg > 0 else { return 0 }
        return min(1, max(0, dailyTodayValue(unit: unit, now: now, calendar: calendar) / avg))
    }

    /// True once today has passed a usual day — the bar is pinned full, so the caption's % and a
    /// colour change are what carry the overshoot.
    public func dailyPaceExceedsAverage(unit: BudgetUnit, now: Date = Date(),
                                        calendar: Calendar = .current) -> Bool {
        let avg = dailyAverage(unit: unit, now: now, calendar: calendar)
        return avg > 0 && dailyTodayValue(unit: unit, now: now, calendar: calendar) > avg
    }

    public func hasDailyHistory(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        dailyAverage(unit: budgetUnit, now: now, calendar: calendar) > 0
    }

    // MARK: - Token display basis
    // Every token figure on screen shows "work" (input+output) or cache-inclusive "total", per the
    // user's `tokenBasis`, and funnels through these so the choice stays consistent. The gauge
    // subtitles included: they used to be hard-wired to work, which put a ~300× gap between
    // "4.2M used this week" and the "Week" figure directly below it under the .total default.
    // Cost ($) is always cache-inclusive and is never routed through here.

    public func tokens(work: Int, total: Int) -> Int { tokenBasis == .total ? total : work }
    public func dayTokens(_ d: DayTotal) -> Int     { tokens(work: d.workTokens, total: d.totalTokens) }
    public func hourTokens(_ h: HourTotal) -> Int   { tokens(work: h.workTokens, total: h.totalTokens) }
    public func modelTokens(_ m: ModelTotal) -> Int { tokens(work: m.workTokens, total: m.totalTokens) }
    public func totalsTokens(_ t: Totals) -> Int    { tokens(work: t.workTokens, total: t.totalTokens) }
    public func blockTokens(_ b: UsageBlock) -> Int { tokens(work: b.workTokens, total: b.totalTokens) }

    /// The word for the current basis, so a figure can name its own unit ("4.2M work used…").
    public var tokenBasisLabel: String { tokenBasis == .total ? "total" : "work" }

    // MARK: - Subagent share
    // Subagent turns are a large slice of real usage (often ~40% of turns) but a tiny slice of
    // WORK tokens — their cost is almost entirely cache reads, so on the work basis they look
    // like they aren't being counted at all. These expose the split so a tooltip can say so.

    public func sidechainTokens(_ t: Totals) -> Int {
        tokens(work: t.sidechainWorkTokens, total: t.sidechainTotalTokens)
    }
    public func sidechainTokens(_ b: UsageBlock) -> Int {
        tokens(work: b.sidechainWorkTokens, total: b.sidechainTotalTokens)
    }

    /// Subagent share, 0…1, on the current basis. Zero when nothing was counted.
    public func sidechainShare(_ t: Totals) -> Double {
        share(part: sidechainTokens(t), of: totalsTokens(t))
    }
    public func sidechainShare(_ b: UsageBlock) -> Double {
        share(part: sidechainTokens(b), of: blockTokens(b))
    }

    /// A tooltip clause naming the subagent share, or "" when there's nothing to say.
    public func sidechainNote(_ t: Totals) -> String { sidechainNote(share: sidechainShare(t)) }
    public func sidechainNote(_ b: UsageBlock) -> String { sidechainNote(share: sidechainShare(b)) }

    private func share(part: Int, of whole: Int) -> Double {
        whole > 0 ? Double(part) / Double(whole) : 0
    }

    private func sidechainNote(share: Double) -> String {
        guard includeSubagents else { return "" }
        let pct = Int((share * 100).rounded())
        guard pct > 0 else { return "" }
        return " Sub-agents (the Task tool) account for \(pct)% of this \(tokenBasisLabel) figure."
    }

    // MARK: - Hourly (today)

    /// The local hour (0...23) with the most usage today, or nil if today has no usage.
    public func peakHour(unit: BudgetUnit) -> Int? {
        let vals = todayHourly.map { unit == .usd ? $0.costUSD : Double(hourTokens($0)) }
        guard let m = vals.max(), m > 0 else { return nil }
        return vals.firstIndex(of: m)
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
            lastCalibratedAt = now            // the sheet fits both gauges in one go, so both
            weeklyCalibratedAt = now          // stamps move together here
            // An explicit user action always wins, but record what it was fitted at so the
            // automatic path can judge later samples against it like any other fit.
            if sessionPct > 0 { blockFitPercent = sessionPct }
            if weeklyPct > 0 { weeklyFitPercent = weeklyPct }
            calibrationWasAutomatic = false   // typed in by hand, not synced from the statusline
            saveConfigAndRecompute()
        }
        return did
    }

    /// Below this server-reported percentage the back-solve is noise, not calibration: the cache
    /// stores whole percents, so the ±0.5 rounding is ±5% of the derived budget at 10% utilization
    /// but ±17% at 3%.
    public static let autoCalibrationMinPercent = 10.0

    /// How far our window boundaries may sit from Claude's before we re-align. Wide enough that
    /// an aligned pair stops rewriting `UserDefaults` on every 30s tick.
    public static let windowAlignTolerance: TimeInterval = 60

    /// Keep the Auto budgets — and our own window boundaries — matched to Claude's real numbers
    /// whenever the statusline cache offers a usable pair. The budgets are written into the same
    /// fields the manual sheet uses, so the existing "a fresh calibration wins" branch of
    /// `blockBudget`/`weeklyBudget` picks them up; the gauge value chain is untouched.
    ///
    /// Why it matters: the fallback anchor is built from the user's own completed windows, which
    /// says nothing about where Anthropic's cap actually is. Measured on real data it ran 5.9×
    /// high on the 5h gauge and 2.7× high on the weekly one; the server percentages fix both.
    ///
    /// Deliberately NOT a call to `calibrateLimits`: that ends in `saveConfigAndRecompute()`,
    /// and this runs inside `recompute()`.
    private func applyServerCalibration(now: Date, entries: [UsageEntry]) {
        guard serverFresh(now: now) else { return }
        // Each window is handled on its own: they reset on different clocks, and a 5h rollover
        // must not drag a still-valid weekly fit down with it.
        let five = serverUsage?.fiveHour.flatMap { $0.isUsable(now: now) ? $0 : nil }
        let seven = serverUsage?.sevenDay.flatMap { $0.isUsable(now: now) ? $0 : nil }

        // Alignment doesn't divide by the percentage, so it isn't subject to the noise floor —
        // it only needs the reset instants, which are exact.
        var changed = alignWindowsToServer(fiveEnd: five?.resetsAt, sevenEnd: seven?.resetsAt, now: now)
        changed = fitBudgetsToServer(five: five, seven: seven, now: now, entries: entries) || changed
        if changed { persistCalibration() }
    }

    /// Phase-align our 5h grid and weekly anchor to Claude's real reset instants. Returns whether
    /// anything moved.
    ///
    /// Our 5h grid is anchored to the user's first message after a ≥5h gap, so it drifts off
    /// Anthropic's: measured 4h out in practice (ours 09:15–14:15 against Claude's 13:00–18:00).
    /// That misattributes usage on both sides of the real reset and makes "resets in" wrong, and
    /// `resets_at` is the exact answer — there's nothing to guess at.
    private func alignWindowsToServer(fiveEnd: Date?, sevenEnd: Date?, now: Date) -> Bool {
        var moved = false
        if let fiveEnd, let block = activeBlock {
            // Both grids have the same 5h period, so only the phase matters. Fold the correction
            // into ±2.5h rather than accumulating whole periods into the offset, and judge the
            // tolerance on that — a 30s error is 30s, not "4h59m the other way round".
            let period = FiveHourBlockEngine.blockDuration
            let raw = fiveEnd.timeIntervalSince(block.endsAt)
            var delta = raw - (raw / period).rounded() * period
            if abs(delta) > Self.windowAlignTolerance {
                // Then take the non-positive representative, so the anchor only ever moves
                // *earlier*. `activeSession` clamps `steps` at 0, so an anchor pushed past `now`
                // would pin the block's start into the future instead of re-phasing the grid.
                if delta > 0 { delta -= period }
                sessionResetOffset += delta
                moved = true
            }
        }
        if let sevenEnd {
            // Judge this the same way as the 5h side — on how far our window boundary actually
            // sits from Claude's — rather than on whether the (weekday, hour, minute) triple
            // differs. The server's instant wobbles either side of the minute (07:59:59.74Z one
            // tick, 08:00:00.46Z the next), so comparing truncated components flipped the anchor
            // 15:00 ⇄ 14:59 forever, rewriting prefs and shifting the window every 30s.
            let period = WeeklyWindowEngine.weekDuration
            let raw = sevenEnd.timeIntervalSince(WeeklyWindowEngine.window(anchor: weeklyAnchor,
                                                                          now: now).end)
            let delta = raw - (raw / period).rounded() * period
            if abs(delta) > Self.windowAlignTolerance {
                // The anchor is a (weekday, hour, minute) rule, so round to the minute we're
                // going to store instead of truncating toward the previous one.
                let rounded = Date(timeIntervalSinceReferenceDate:
                    (sevenEnd.timeIntervalSinceReferenceDate / 60).rounded() * 60)
                let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: rounded)
                if let wd = c.weekday, let h = c.hour, let m = c.minute {
                    weeklyResetWeekday = wd
                    weeklyResetHour = h
                    weeklyResetMinute = m
                    moved = true
                }
            }
        }
        return moved
    }

    /// Back-solve `budget = used ÷ %` for each window independently, in both units.
    /// Returns whether a persist is warranted.
    private func fitBudgetsToServer(five: ServerLimit?, seven: ServerLimit?,
                                    now: Date, entries: [UsageEntry]) -> Bool {
        guard autoPeakBudget else { return false }   // Plan/Custom budgets belong to the user
        var moved = false, fitted = false

        // Each side has its own stamp and its own noise floor, so one being unusable or quiet
        // never invalidates the other. Both units are fitted, not just the active one, so
        // flipping Tokens↔US$ doesn't show a budget from whenever that unit was last selected.
        // A unit with nothing to divide (every model unpriced → cost 0) is left alone, not zeroed.
        // Whether a reading is good enough to replace the stored fit is `shouldAcceptFit`'s call —
        // newer is not better here.
        //
        // Each window's usage is measured over *Claude's* interval, not `blockValue`/
        // `weeklyValue` — see `alignWindowsToServer` for the drift. Alignment fixes it going
        // forward, but this pass still holds the old boundaries, and a percentage divided into a
        // different interval is meaningless: it gave a 21.1M session budget where the answer
        // was 2.3M.
        if let five, let end = five.resetsAt,
           shouldAcceptFit(newPercent: five.utilization, storedPercent: blockFitPercent,
                           storedAt: lastCalibratedAt, sameWindow: !blockCalibrationIsStale(now: now),
                           now: now) {
            let v = gaugeValues(from: end.addingTimeInterval(-FiveHourBlockEngine.blockDuration),
                                to: now, entries: entries)
            var did = false
            if v.weighted > 0 {
                let fit = v.weighted / five.fraction
                moved = drifted(Double(tokenBudget), fit) || moved
                tokenBudget = Int(fit)
                did = true
            }
            if v.cost > 0 {
                let fit = v.cost / five.fraction
                moved = drifted(costBudget, fit) || moved
                costBudget = fit
                did = true
            }
            if did { lastCalibratedAt = now; blockFitPercent = five.utilization; fitted = true }
        }

        if let seven, let end = seven.resetsAt,
           shouldAcceptFit(newPercent: seven.utilization, storedPercent: weeklyFitPercent,
                           storedAt: weeklyCalibratedAt, sameWindow: !weeklyCalibrationIsStale(now: now),
                           now: now) {
            let v = gaugeValues(from: end.addingTimeInterval(-WeeklyWindowEngine.weekDuration),
                                to: now, entries: entries)
            var did = false
            if v.weighted > 0 {
                let fit = v.weighted / seven.fraction
                moved = drifted(Double(weeklyTokenBudget), fit) || moved
                weeklyTokenBudget = Int(fit)
                did = true
            }
            if v.cost > 0 {
                let fit = v.cost / seven.fraction
                moved = drifted(weeklyCostBudget, fit) || moved
                weeklyCostBudget = fit
                did = true
            }
            if did { weeklyCalibratedAt = now; weeklyFitPercent = seven.utilization; fitted = true }
        }
        guard fitted else { return false }

        // Same reason the manual sheet clears it: `init` re-mirrors the plan estimate over the
        // stored budgets while this is set, so leaving it on would discard the fit on next launch.
        autoBudgetFromPlan = false
        calibrationWasAutomatic = true
        // The stamps are refreshed in memory every pass so a calibration never goes stale while
        // the statusline is live, but a 30s timer must not rewrite `UserDefaults` forever.
        return moved || !calibrationWasPersisted
    }

    /// Exactly what `blockValue`/`weeklyValue` report — cost-weighted when that's on, raw work
    /// otherwise — but over an arbitrary window, so a server percentage can be divided into the
    /// same interval it describes. Both units come back so each can be fitted.
    private func gaugeValues(from start: Date, to end: Date,
                             entries: [UsageEntry]) -> (weighted: Double, cost: Double) {
        var weighted = 0.0, cost = 0.0
        for e in entries where e.timestamp >= start && e.timestamp < end {
            weighted += Double(e.workTokens) * (weightTokensByModel ? pricing.weight(for: e.family) : 1)
            cost += pricing.cost(for: e)
        }
        return (weighted, cost)
    }

    private func drifted(_ old: Double, _ new: Double) -> Bool {
        old <= 0 || abs(new - old) / old > 0.01
    }

    /// How long a fitted cap stays authoritative without being refreshed. Long enough that a 5h
    /// window reset (4–5× a day) never touches it, short enough to follow a plan change.
    public static let calibrationExpiry: TimeInterval = 14 * 86_400

    public func blockFitIsExpired(now: Date = Date()) -> Bool { expired(lastCalibratedAt, now: now) }
    public func weeklyFitIsExpired(now: Date = Date()) -> Bool { expired(weeklyCalibratedAt, now: now) }

    private func expired(_ stamp: Date?, now: Date) -> Bool {
        guard let stamp else { return true }
        return now.timeIntervalSince(stamp) > Self.calibrationExpiry
    }

    /// Above this the reading is saturated: you may already be throttled and still logging turns,
    /// so `used ÷ 1.0` reads as a cap larger than the real one.
    public static let autoCalibrationMaxPercent = 98.0

    /// Should a fresh server reading replace the stored fit for this gauge?
    ///
    /// Not simply "is it newer". A fit's precision is set by the percentage it was divided by, so
    /// the newest sample is routinely the *worst* one — a window that has just reset reads 10–12%,
    /// where ±0.5% rounding is ±5% of the budget, and it was overwriting readings taken at 96%.
    /// Within one window percentages only grow, so a later sample there is strictly better; across
    /// windows we defend the stored fit and let that claim decay linearly to nothing over
    /// `calibrationExpiry`, so a stale-but-precise fit still yields eventually without a cliff.
    private func shouldAcceptFit(newPercent: Double, storedPercent: Double?, storedAt: Date?,
                                 sameWindow: Bool, now: Date) -> Bool {
        guard newPercent >= Self.autoCalibrationMinPercent,
              newPercent <= Self.autoCalibrationMaxPercent else { return false }
        guard let storedPercent, let storedAt, !expired(storedAt, now: now) else { return true }
        if sameWindow { return true }
        let decay = max(0, 1 - now.timeIntervalSince(storedAt) / Self.calibrationExpiry)
        return newPercent >= max(Self.autoCalibrationMinPercent, storedPercent * decay)
    }

    private var calibrationWasPersisted: Bool {
        defaults.object(forKey: Key.lastCalibratedAt) != nil
    }

    /// Optional settings are stored by presence, never by a sentinel — see `billingCycleDayOverride`.
    private func persistOptional(_ value: Double?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Persist only what `applyServerCalibration` touched — no recompute, no full config write.
    private func persistCalibration() {
        defaults.set(sessionResetOffset, forKey: Key.sessionResetOffset)
        defaults.set(weeklyResetWeekday, forKey: Key.weeklyResetWeekday)
        defaults.set(weeklyResetHour, forKey: Key.weeklyResetHour)
        defaults.set(weeklyResetMinute, forKey: Key.weeklyResetMinute)
        defaults.set(autoBudgetFromPlan, forKey: Key.autoBudgetFromPlan)
        defaults.set(tokenBudget, forKey: Key.tokenBudget)
        defaults.set(costBudget, forKey: Key.costBudget)
        defaults.set(weeklyTokenBudget, forKey: Key.weeklyTokenBudget)
        defaults.set(weeklyCostBudget, forKey: Key.weeklyCostBudget)
        defaults.set(lastCalibratedAt?.timeIntervalSince1970 ?? 0, forKey: Key.lastCalibratedAt)
        if let t = weeklyCalibratedAt {
            defaults.set(t.timeIntervalSince1970, forKey: Key.weeklyCalibratedAt)
        } else {
            defaults.removeObject(forKey: Key.weeklyCalibratedAt)
        }
        persistOptional(blockFitPercent, forKey: Key.blockFitPercent)
        persistOptional(weeklyFitPercent, forKey: Key.weeklyFitPercent)
        defaults.set(calibrationWasAutomatic, forKey: Key.calibrationWasAutomatic)
    }

    /// True when the 5h fit predates the current block — a reset has occurred since it was taken.
    /// Also true when never calibrated.
    ///
    /// This no longer invalidates the budget (see `blockBudget`): a cap doesn't reset when the
    /// window does. It survives as the "is this reading from the same window as the stored fit?"
    /// test `shouldAcceptFit` needs, since percentages only climb within a window.
    public func blockCalibrationIsStale(now: Date = Date()) -> Bool {
        guard let cal = lastCalibratedAt else { return true }
        if let blockStart = activeBlock?.start, cal < blockStart { return true }
        return false
    }

    /// The same for the weekly window, judged **only** against the weekly reset — a 5h rollover
    /// says nothing about whether a weekly percentage is still current.
    public func weeklyCalibrationIsStale(now: Date = Date()) -> Bool {
        guard let cal = weeklyCalibratedAt else { return true }
        return cal < WeeklyWindowEngine.window(anchor: weeklyAnchor, now: now).start
    }

    /// Either side's reading predates its window. Nothing depends on this any more except wording.
    public func calibrationIsStale(now: Date = Date()) -> Bool {
        blockCalibrationIsStale(now: now) || weeklyCalibrationIsStale(now: now)
    }

    /// `calibrationIsStale(now:)` with the current clock — convenient for SwiftUI reads.
    public var calibrationIsStale: Bool { calibrationIsStale() }

    /// Short relative age of the last calibration ("just now", "2h ago", "3d ago"),
    /// or nil if never calibrated.
    public var calibrationAgeDescription: String? {
        guard let cal = lastCalibratedAt else { return nil }
        return Format.relativeAge(from: cal)
    }

    public enum GaugeWindow: Sendable { case block, weekly }

    /// Plain-language description of what a gauge's percentage is measured against right now — so
    /// the UI can be honest about the denominator (local anchor vs calibrated vs estimate).
    ///
    /// Per gauge, because the two fit and expire independently: the weekly budget can be Claude's
    /// while the 5h one has aged out to the local anchor, and one shared sentence would
    /// misdescribe whichever it wasn't written about.
    ///
    /// The fit's percentage is named because it *is* the precision: a cap back-solved at 96% is
    /// worth ten of one back-solved at 10%.
    public func budgetBasisDescription(for window: GaugeWindow) -> String {
        let stamp = window == .block ? lastCalibratedAt : weeklyCalibratedAt
        let expired = window == .block ? blockFitIsExpired() : weeklyFitIsExpired()
        let percent = window == .block ? blockFitPercent : weeklyFitPercent
        if let stamp, !expired {
            let age = Format.relativeAge(from: stamp)
            let at = percent.map { " at \(Int($0.rounded()))%" } ?? ""
            return calibrationWasAutomatic ? "Claude's live usage — synced \(age)\(at)"
                                           : "Claude's /usage — calibrated \(age)\(at)"
        }
        if autoPeakBudget {
            // Mirror `blockBudget`'s own fallback order — anchor, then plan. Reporting the custom
            // budget here would name a number the gauge isn't using.
            guard peakBlockWork > 0 || peakWeekWork > 0 else { return "a tier-scaled plan estimate" }
            // Deliberately not "your ceiling ≈ Anthropic's cap". Measured on real data this ran
            // ~3× above the real 5h limit, because a reconstructed window can straddle one of
            // Claude's resets and hold more than one limit's worth.
            return "a rough upper bound from your own history — it runs high, and is not Anthropic's cap"
        }
        return autoBudgetFromPlan ? "a tier-scaled plan estimate" : "your custom budget"
    }

    /// The 5h gauge's basis — kept for callers that predate the split.
    public var budgetBasisDescription: String { budgetBasisDescription(for: .block) }

    // MARK: - Claude Code's /stats figures

    /// `/stats`' "Total tokens", with today's usage added when the cache stops at yesterday.
    ///
    /// The delta is ClaudePet's own count, which is NOT the same accounting — measured on one complete
    /// day it ran within about ±7% of `/stats`. It's added only when the cache ends exactly yesterday:
    /// if the cache already covers today, adding it would double-count; if it's older than that, whole
    /// days are missing and inventing them would be worse than showing a dated figure.
    public func statsTotalTokens(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let c = statsCache else { return nil }
        guard c.endsYesterday(now, calendar: calendar) else { return c.totalWorkTokens }
        return c.totalWorkTokens + today.workTokens
    }

    /// Whether the figure above includes an estimated slice for today, so the UI can say so.
    public func statsIncludesToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        statsCache?.endsYesterday(now, calendar: calendar) ?? false
    }

    /// "29 Jul" — the last day Claude Code folded into its cache.
    public var statsAsOfDescription: String? {
        guard let d = statsCache?.lastComputedDate() else { return nil }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: - Live server usage (from the statusline cache)

    /// How recently the statusline must have written its cache for us to treat it as "live".
    /// Past this, the snapshot is assumed stale (the statusline stopped running) and we fall back
    /// to the local estimate.
    public static let serverDataMaxAge: TimeInterval = 30 * 60   // 30 min

    /// True only while the statusline cache is recent enough to trust.
    private func serverFresh(now: Date) -> Bool {
        serverUsage?.isFresh(now: now, maxAge: Self.serverDataMaxAge) == true
    }
    private var serverFresh: Bool { serverFresh(now: Date()) }

    /// True when Claude's real 5h utilization is available, fresh, and its window hasn't reset.
    public var serverDriven5h: Bool { serverFresh && serverUsage?.fiveHour?.isUsable() == true }
    /// True when Claude's real 7-day utilization is available, fresh, and its window hasn't reset.
    public var serverDriven7d: Bool { serverFresh && serverUsage?.sevenDay?.isUsable() == true }

    /// Relative age of the statusline cache ("2m ago"), or nil if no cache was read.
    public var serverDataAge: String? { serverUsage.map { Format.relativeAge(from: $0.asOf) } }

    /// 5h reset moment — Claude's real reset when server-driven, else the local block end.
    public var blockResetDate: Date? {
        if serverDriven5h, let r = serverUsage?.fiveHour?.resetsAt { return r }
        return activeBlock?.endsAt
    }
    /// Weekly reset moment — Claude's real reset when server-driven, else the local window end.
    public var weeklyResetDate: Date? {
        if serverDriven7d, let r = serverUsage?.sevenDay?.resetsAt { return r }
        return weekReset
    }

    // MARK: - Mascot mood

    /// The pet's mood, from how close the **5-hour session** is to its limit, using the same gauge
    /// fraction the bar shows (server-live or local estimate). Idle when there's no active session,
    /// so the pet sleeps when you're away.
    ///
    /// It used to read `max(blockFraction, weeklyFraction)`, which meant a stormy pet could be caused
    /// by either limit and the picture couldn't tell you which. The weekly figure is now its own
    /// signal — `groundCondition`, the terrain under the pet's feet — so each carries exactly one
    /// number. Don't fold weekly back in here; that would make the ground redundant and the face
    /// ambiguous again.
    public var mascotEmotion: MascotEmotion {
        guard activeBlock != nil || serverDriven5h else { return .sleeping }
        switch blockFraction(unit: budgetUnit) {
        case ..<0.05: return .celebrating   // fresh window, lots of room
        case ..<0.25: return .happy
        case ..<0.50: return .content
        case ..<0.70: return .neutral
        case ..<0.85: return .focused
        case ..<0.95: return .worried
        case ..<1.00: return .alarmed
        default:      return .exhausted     // at or past the limit — throttling territory
        }
    }

    // MARK: - Weather & ground

    /// The pet's ambient sky, derived from the same mood the face shows — so the two always agree,
    /// and the whole scene means one thing: your 5-hour session.
    public var weatherCondition: WeatherCondition { .from(mascotEmotion) }

    /// The ground under the pet: the **weekly** limit. Unlike the mood there is no idle state — a
    /// week keeps running whether or not a session is active, so the terrain always says something.
    public var groundCondition: GroundCondition {
        .from(weeklyFraction: weeklyFraction(unit: budgetUnit))
    }

    /// What the mascot block is actually saying, in words — the hover text for the whole scene.
    ///
    /// Without it the two signals are undiscoverable: nothing on screen tells you the pet is your
    /// session and the ground is your week, so a calm pet on cracked earth just looks inconsistent.
    /// Naming both, with both percentages, is what turns it from decoration into a reading.
    public var petSceneDescription: String {
        let session = Int((blockFraction(unit: budgetUnit) * 100).rounded())
        let weekly = Int((weeklyFraction(unit: budgetUnit) * 100).rounded())
        let mood = mascotEmotion == .sleeping
            ? "The pet is asleep — no session is running."
            : "The pet and its sky follow your 5-hour session (\(session)% — \(mascotEmotion.rawValue), "
              + "\(weatherCondition.rawValue))."
        return mood + " The ground it stands on follows your weekly limit "
            + "(\(weekly)% — \(groundCondition.rawValue))."
    }

    /// One-shot weather moments (confetti, lightning) raised on a usage transition. The view drains
    /// these via `consumeWeatherEvents()`; they are never part of the steady weather state.
    public private(set) var pendingWeatherEvents: [WeatherEvent] = []

    // Previous state for edge detection. @ObservationIgnored so updating them inside `recompute()`
    // (which runs often) never triggers a view refresh.
    @ObservationIgnored private var prevWindowToken: WindowToken?
    @ObservationIgnored private var prevEmotion: MascotEmotion?
    @ObservationIgnored private var didInitialEdgePass = false

    /// Identity of the current 5-hour window, robust across local and server-driven modes — so we
    /// can tell when a genuinely *fresh* window has begun (vs. the same window being recomputed).
    private struct WindowToken: Equatable {
        var blockStart: Date?     // local 5h block start
        var serverReset: Date?    // Claude's real window reset (only when server-driven)
        var isActive: Bool        // is any 5h window active at all
    }

    /// Drain the queued one-shot weather events (returns them and clears the queue). The view calls
    /// this from an `.onChange`, never inside its draw closure.
    public func consumeWeatherEvents() -> [WeatherEvent] {
        let events = pendingWeatherEvents
        pendingWeatherEvents = []
        return events
    }

    /// Notice usage transitions and queue one-shot weather events. Called at the end of every
    /// `recompute()`. Each event fires exactly once per transition; nothing fires on the first pass
    /// after launch, so loading an already-active or already-high window doesn't spam confetti or
    /// lightning.
    private func detectWeatherEdges() {
        let token = WindowToken(blockStart: activeBlock?.start,
                                serverReset: serverDriven5h ? serverUsage?.fiveHour?.resetsAt : nil,
                                isActive: activeBlock != nil || serverDriven5h)
        let emotion = mascotEmotion
        defer { prevWindowToken = token; prevEmotion = emotion; didInitialEdgePass = true }

        guard didInitialEdgePass, let prev = prevWindowToken else { return }   // first pass: prime only

        // Fresh 5h window: became active from idle, or the window identity advanced while active.
        let freshWindow = (token.isActive && !prev.isActive)
            || (token.isActive && prev.isActive
                && (token.blockStart != prev.blockStart || token.serverReset != prev.serverReset))
        if freshWindow { pendingWeatherEvents.append(.confetti) }

        // Crossed into the danger zone (≥95%) from a calmer mood.
        //
        // Tested against the whole *region*, not against `.alarmed` alone. Adding `.exhausted` above
        // it put a second state in the danger zone, and an equality check would then miss the case it
        // most needs to catch: a big turn landing you at 100%+ jumps `.worried` → `.exhausted` without
        // ever being `.alarmed`, so the bolt would silently never fire.
        let danger: Set<MascotEmotion> = [.alarmed, .exhausted]
        if danger.contains(emotion), let p = prevEmotion, !danger.contains(p) {
            pendingWeatherEvents.append(.lightningStrike)
        }
    }

    // MARK: - Previews / snapshots

    public func loadSampleForPreview() {
        let now = Date()
        today = Totals(workTokens: 142_000, totalTokens: 41_200_000, costUSD: 4.21)
        week = Totals(workTokens: 1_200_000, totalTokens: 300_000_000, costUSD: 38, weightedTokens: 1_650_000)
        allTime = Totals(workTokens: 14_000_000, totalTokens: 3_400_000_000, costUSD: 402)
        cycleStart = now.addingTimeInterval(-18 * 86_400)   // ~18 days into the cycle
        cycleReset = now.addingTimeInterval(12 * 86_400)    // ~12d until the cycle resets
        // 31 dates spanning that cycle, the last 12 still in the future (and so empty) — exactly
        // the shape the real aggregator produces. `cycle` is then summed FROM these rather than
        // written by hand, so sample data honours the same "bars add up to the headline" invariant
        // the dashboard claims.
        let cycleWork = (0..<31).map { i -> Int in
            guard i <= 18 else { return 0 }                     // future dates: nothing logged yet
            return i % 7 >= 5 ? 40_000 + i * 900 : 150_000 + i * 4_000   // weekends lighter
        }
        cycleDaily = cycleWork.enumerated().map { i, w in
            DayTotal(date: now.addingTimeInterval(Double(i - 18) * 86_400),
                     workTokens: w, totalTokens: w * 220, costUSD: Double(w) / 6800)
        }
        cycle = Totals(workTokens: cycleDaily.reduce(0) { $0 + $1.workTokens },
                       totalTokens: cycleDaily.reduce(0) { $0 + $1.totalTokens },
                       costUSD: cycleDaily.reduce(0) { $0 + $1.costUSD })
        // Split that same total across plausible projects; the last one absorbs the rounding
        // remainder so the list sums to `cycle` to the token, as the real one does.
        var remWork = cycle.workTokens, remTotal = cycle.totalTokens, remCost = cycle.costUSD
        let shares: [(String, Double)] = [("/Users/you/ClaudePet", 0.46),
                                          ("/Users/you/Desktop/AAI", 0.27),
                                          ("/Users/you/Desktop/LiDAR + HPE", 0.18),
                                          ("/Users/you/pookie-gym", 0.09)]
        cycleByProject = shares.enumerated().map { i, share in
            let isLast = i == shares.count - 1
            let w = isLast ? remWork : Int(Double(cycle.workTokens) * share.1)
            let t = isLast ? remTotal : Int(Double(cycle.totalTokens) * share.1)
            let c = isLast ? remCost : cycle.costUSD * share.1
            remWork -= w; remTotal -= t; remCost -= c
            return ProjectTotal(path: share.0, workTokens: w, totalTokens: t, costUSD: c)
        }
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
        // A representative morning-peak day (~9–11am busiest) for the "Today by hour" sparkline.
        let hourWork = [0, 0, 0, 0, 0, 0, 500, 3_000, 8_000, 18_000, 22_000, 20_000,
                        12_000, 9_000, 11_000, 8_000, 6_000, 5_000, 4_000, 3_000, 1_500, 500, 0, 0]
        todayHourly = (0...23).map { h in
            HourTotal(hour: h, workTokens: hourWork[h], totalTokens: hourWork[h] * 200,
                      costUSD: Double(hourWork[h]) / 7000)
        }
        // A representative `/stats` cache, dated yesterday so the preview also exercises the "add
        // today's delta" path. Real per-model figures, so the shares are plausible.
        var g = Calendar(identifier: .gregorian)
        g.timeZone = .current
        let yesterday = g.date(byAdding: .day, value: -1, to: now) ?? now
        statsCache = StatsCache(
            models: [
                StatsModelTotal(model: "claude-opus-4-8", inputTokens: 22_078_886, outputTokens: 89_435_705,
                                cacheReadTokens: 19_088_345_916, cacheWriteTokens: 421_818_449),
                StatsModelTotal(model: "claude-sonnet-4-6", inputTokens: 87_802, outputTokens: 10_064_185,
                                cacheReadTokens: 944_789_056, cacheWriteTokens: 39_159_434),
                StatsModelTotal(model: "claude-opus-5", inputTokens: 134_000, outputTokens: 8_339_741,
                                cacheReadTokens: 12_000_000, cacheWriteTokens: 900_000),
                StatsModelTotal(model: "claude-fable-5", inputTokens: 905_133, outputTokens: 2_882_970,
                                cacheReadTokens: 790_424_067, cacheWriteTokens: 18_166_381),
                StatsModelTotal(model: "claude-haiku-4-5-20251001", inputTokens: 517_600, outputTokens: 1_931_406,
                                cacheReadTokens: 462_062_039, cacheWriteTokens: 40_672_724),
            ],
            lastComputedDay: g.dateComponents([.year, .month, .day], from: yesterday),
            totalSessions: 208, asOf: now)
        lastUpdated = now
    }
}
