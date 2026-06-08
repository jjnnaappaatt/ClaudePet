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
    public var widgetScale: Double = 1.0         // uniform zoom (all resize handles + slider)
    public var account: AccountInfo = .unknown   // plan + subscription start
    public var plan: AccountPlan { account.plan }
    public var autoBudgetFromPlan = true         // budget follows the plan unless overridden
    public var keepOnTop = false                 // always-on-top vs normal (clickable, coverable)
    public var monthlyPrice: Double = 0          // actual subscription $ paid per cycle (editable)
    public var creditSpent: Double = 0           // usage-credit $ spent this cycle (server-side; editable)
    public var creditLimit: Double = 0           // monthly spend limit for usage credits
    public var creditBalance: Double = 0         // current usage-credit balance
    public var showOnAllSpaces = false           // join all Spaces (can cover fullscreen) vs this Space only
    public var sessionResetOffset: Double = 0    // seconds added to the 5h session window (reset calibration)
    public var weeklyResetOffset: Double = 0     // seconds added to the weekly window anchor (reset calibration)
    public var extraUsageEnabled: Bool { account.extraUsageEnabled }

    /// Anchor for the fixed weekly-limit grid: plan default + user calibration offset.
    public var weeklyAnchor: Date { account.weeklyAnchorBase().addingTimeInterval(weeklyResetOffset) }

    public var lastUpdated: Date?
    public var isLoading = false

    /// Fired after every recompute (used for verification heartbeats; nil in normal use).
    public var onRecompute: (() -> Void)?

    /// Fired after config is saved (e.g. so the panel can resize to a new widget scale).
    public var onConfigChange: (() -> Void)?

    private let scanner = UsageScanner()
    private var watcher: FileWatcher?
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
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
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
        lastUpdated = now
        onRecompute?()
    }

    // MARK: - Config persistence

    private enum Key {
        static let budgetUnit = "budgetUnit"
        static let tokenBudget = "tokenBudget"
        static let costBudget = "costBudget"
        static let includeSubagents = "includeSubagents"
        static let pricing = "pricingTable"
        static let widgetScale = "widgetScale"
        static let autoBudgetFromPlan = "autoBudgetFromPlan"
        static let keepOnTop = "keepOnTop"
        static let weeklyTokenBudget = "weeklyTokenBudget"
        static let weeklyCostBudget = "weeklyCostBudget"
        static let monthlyPrice = "monthlyPrice"
        static let creditSpent = "extraUsagePaid"   // legacy key reused
        static let creditLimit = "creditLimit"
        static let creditBalance = "creditBalance"
        static let showOnAllSpaces = "showOnAllSpaces"
        static let sessionResetOffset = "sessionResetOffset"
        static let weeklyResetOffset = "weeklyResetOffset"
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
        if let data = defaults.data(forKey: Key.pricing),
           let table = try? JSONDecoder().decode(PricingTable.self, from: data) {
            pricing = table
        }
        if defaults.object(forKey: Key.widgetScale) != nil {
            widgetScale = defaults.double(forKey: Key.widgetScale)
        }
        if defaults.object(forKey: Key.autoBudgetFromPlan) != nil {
            autoBudgetFromPlan = defaults.bool(forKey: Key.autoBudgetFromPlan)
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
        if defaults.object(forKey: Key.weeklyResetOffset) != nil { weeklyResetOffset = defaults.double(forKey: Key.weeklyResetOffset) }
    }

    /// Persist config and re-aggregate so changes show immediately.
    public func saveConfigAndRecompute() {
        defaults.set(budgetUnit.rawValue, forKey: Key.budgetUnit)
        defaults.set(tokenBudget, forKey: Key.tokenBudget)
        defaults.set(costBudget, forKey: Key.costBudget)
        defaults.set(includeSubagents, forKey: Key.includeSubagents)
        if let data = try? JSONEncoder().encode(pricing) {
            defaults.set(data, forKey: Key.pricing)
        }
        defaults.set(widgetScale, forKey: Key.widgetScale)
        defaults.set(autoBudgetFromPlan, forKey: Key.autoBudgetFromPlan)
        defaults.set(keepOnTop, forKey: Key.keepOnTop)
        defaults.set(weeklyTokenBudget, forKey: Key.weeklyTokenBudget)
        defaults.set(weeklyCostBudget, forKey: Key.weeklyCostBudget)
        defaults.set(monthlyPrice, forKey: Key.monthlyPrice)
        defaults.set(creditSpent, forKey: Key.creditSpent)
        defaults.set(creditLimit, forKey: Key.creditLimit)
        defaults.set(creditBalance, forKey: Key.creditBalance)
        defaults.set(showOnAllSpaces, forKey: Key.showOnAllSpaces)
        defaults.set(sessionResetOffset, forKey: Key.sessionResetOffset)
        defaults.set(weeklyResetOffset, forKey: Key.weeklyResetOffset)
        recompute()
        onConfigChange?()
    }

    // MARK: - 5h gauge helpers (unit-aware)

    public func blockValue(unit: BudgetUnit) -> Double {
        guard let b = activeBlock else { return 0 }
        // Token gauge tracks WORK tokens (human-scale, matches the headline); $ tracks notional cost.
        return unit == .tokens ? Double(b.workTokens) : b.costUSD
    }

    public func blockBudget(unit: BudgetUnit) -> Double {
        if autoBudgetFromPlan {
            return unit == .tokens ? Double(plan.tokenBudget) : plan.costBudget
        }
        return unit == .tokens ? Double(tokenBudget) : costBudget
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
        unit == .tokens ? Double(week.workTokens) : week.costUSD
    }

    public func weeklyBudget(unit: BudgetUnit) -> Double {
        if autoBudgetFromPlan {
            return unit == .tokens ? Double(plan.weeklyTokenBudget) : plan.weeklyCostBudget
        }
        return unit == .tokens ? Double(weeklyTokenBudget) : weeklyCostBudget
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

    // MARK: - Previews / snapshots

    public func loadSampleForPreview() {
        let now = Date()
        today = Totals(workTokens: 142_000, totalTokens: 41_200_000, costUSD: 4.21)
        week = Totals(workTokens: 1_200_000, totalTokens: 300_000_000, costUSD: 38)
        allTime = Totals(workTokens: 14_000_000, totalTokens: 3_400_000_000, costUSD: 402)
        cycle = Totals(workTokens: 5_400_000, totalTokens: 1_300_000_000, costUSD: 180)
        monthlyPrice = 100; creditSpent = 13.47; creditLimit = 60; creditBalance = 5.60
        todayByModel = [
            ModelTotal(family: .opus,   workTokens: 41_000, totalTokens: 20_000_000, costUSD: 3.10),
            ModelTotal(family: .sonnet, workTokens: 77_000, totalTokens: 18_000_000, costUSD: 1.05),
            ModelTotal(family: .haiku,  workTokens: 10_000, totalTokens: 3_200_000,  costUSD: 0.06),
        ]
        activeBlock = UsageBlock(start: now.addingTimeInterval(-2 * 3600),
                                 actualStart: now.addingTimeInterval(-2 * 3600),
                                 lastActivity: now,
                                 workTokens: 1_240_000, totalTokens: 44_000_000, costUSD: 150)
        weekReset = now.addingTimeInterval(3 * 86_400 + 4 * 3600)   // ~3d 4h until weekly reset
        let work = [600_000, 900_000, 400_000, 1_100_000, 700_000, 1_300_000, 1_500_000]
        weekDaily = (0..<7).map { i in
            DayTotal(date: now.addingTimeInterval(Double(i - 6) * 86_400),
                     workTokens: work[i], totalTokens: work[i] * 200, costUSD: Double(work[i]) / 7000)
        }
        lastUpdated = now
    }
}
