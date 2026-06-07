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
    public var todayByModel: [ModelTotal] = []
    public var unknownModels: Set<String> = []
    public var activeBlock: UsageBlock?

    // Config (user-editable; persisted to UserDefaults)
    public var pricing = PricingTable.default
    public var budgetUnit: BudgetUnit = .tokens
    public var tokenBudget: Int = 2_000_000     // work tokens per 5h block
    public var costBudget: Double = 200          // notional API-equivalent $ per 5h block
    public var includeSubagents = true
    public var widgetScale: Double = 1.0         // 0.8…1.6 size multiplier

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
        loadConfig()
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
        let agg = Aggregator.compute(entries: entries, pricing: pricing, now: now)
        let blocks = FiveHourBlockEngine.blocks(from: entries, pricing: pricing)
        today = agg.today
        week = agg.week
        allTime = agg.allTime
        todayByModel = agg.todayByModel
        unknownModels = agg.unknownModels
        activeBlock = FiveHourBlockEngine.activeBlock(in: blocks, now: now)
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
        unit == .tokens ? Double(tokenBudget) : costBudget
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

    // MARK: - Previews / snapshots

    public func loadSampleForPreview() {
        let now = Date()
        today = Totals(workTokens: 142_000, totalTokens: 41_200_000, costUSD: 4.21)
        week = Totals(workTokens: 1_200_000, totalTokens: 300_000_000, costUSD: 38)
        allTime = Totals(workTokens: 14_000_000, totalTokens: 3_400_000_000, costUSD: 402)
        todayByModel = [
            ModelTotal(family: .opus,   workTokens: 41_000, totalTokens: 20_000_000, costUSD: 3.10),
            ModelTotal(family: .sonnet, workTokens: 77_000, totalTokens: 18_000_000, costUSD: 1.05),
            ModelTotal(family: .haiku,  workTokens: 10_000, totalTokens: 3_200_000,  costUSD: 0.06),
        ]
        activeBlock = UsageBlock(start: now.addingTimeInterval(-2 * 3600),
                                 actualStart: now.addingTimeInterval(-2 * 3600),
                                 lastActivity: now,
                                 workTokens: 1_240_000, totalTokens: 44_000_000, costUSD: 150)
        lastUpdated = now
    }
}
