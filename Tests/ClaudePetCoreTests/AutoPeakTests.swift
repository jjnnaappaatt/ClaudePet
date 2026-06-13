import Testing
import Foundation
@testable import ClaudePetCore

/// Auto-calibration sizes each gauge's budget from the user's own peak completed window
/// (no server data needed). The active/current window is excluded so the denominator is
/// stable, and a fresh manual calibration still overrides the peak until the next reset.
@MainActor
@Suite struct AutoPeakTests {

    let pricing = PricingTable.default

    private func freshDefaults() -> UserDefaults {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Engine peaks

    @Test func fiveHourPeakTakesHeaviestCompletedBlockExcludingActive() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let h: TimeInterval = 3600
        let m = "claude-sonnet-4-6"   // weight 1.0 → weighted == work
        let es = [
            TestSupport.entry(at: t0,        model: m, input: 500,  output: 500),   // block1 completed: 1000
            TestSupport.entry(at: t0 + 6*h,  model: m, input: 800,  output: 800),   // block2 completed: 1600
            TestSupport.entry(at: t0 + 13*h, model: m, input: 2500, output: 2500),  // block3 active: 5000
        ]
        let now = t0 + 14*h     // 1h into block3 → blocks 1 & 2 completed, block 3 active
        let peak = FiveHourBlockEngine.peakCompleted(from: es, pricing: pricing, now: now)
        #expect(peak.work == 1600)        // heaviest completed; the bigger active block is excluded
        #expect(abs(peak.weighted - 1600) < 1e-6)
    }

    @Test func weeklyPeakTakesHeaviestCompletedWindowExcludingCurrent() {
        let anchor = Date(timeIntervalSince1970: 1_704_067_200)  // a Monday reference
        let d: TimeInterval = 86_400
        let m = "claude-sonnet-4-6"
        let es = [
            TestSupport.entry(at: anchor + 3600,         model: m, input: 250_000,   output: 250_000),   // wk0 completed: 500k
            TestSupport.entry(at: anchor + 7*d + 3600,   model: m, input: 750_000,   output: 750_000),   // wk1 completed: 1.5M
            TestSupport.entry(at: anchor + 14*d + 1800,  model: m, input: 1_500_000, output: 1_500_000), // wk2 current: 3M
        ]
        let now = anchor + 14*d + 3600   // inside wk2
        let peak = WeeklyWindowEngine.peakCompleted(from: es, pricing: pricing, anchor: anchor, now: now)
        #expect(peak.work == 1_500_000)  // heaviest completed; the bigger current window is excluded
    }

    // MARK: Store precedence

    /// 9 days ago: a 2000-work burst (peak source for both block & week).
    /// ~10h ago: a 1000-work completed block (current week). Now: a 500-work active block.
    private func seed(now: Date) -> [UsageEntry] {
        let m = "claude-sonnet-4-6"
        return [
            TestSupport.entry(at: now.addingTimeInterval(-9 * 86_400), model: m, input: 1000, output: 1000),
            TestSupport.entry(at: now.addingTimeInterval(-10 * 3600),  model: m, input: 500,  output: 500),
            TestSupport.entry(at: now,                                  model: m, input: 250,  output: 250),
        ]
    }

    @Test func autoPeakBudgetIsPeakPlusHeadroom() {
        let store = MetricsStore(defaults: freshDefaults())
        store.weightTokensByModel = false
        store.ingestForTesting(seed(now: Date()))
        // Peak completed block & week are both the 2000-work burst; active/current excluded.
        #expect(store.peakBlockWork == 2000)
        #expect(store.peakWeekWork == 2000)
        // budget = peak × (1 + 0.15)
        #expect(abs(store.blockBudget(unit: .tokens) - 2300) < 0.01)
        #expect(abs(store.weeklyBudget(unit: .tokens) - 2300) < 0.01)
    }

    @Test func freshCalibrationOverridesPeak() {
        let now = Date()
        let store = MetricsStore(defaults: freshDefaults())
        store.weightTokensByModel = false
        store.ingestForTesting(seed(now: now))
        // Live gauge values: active block = 500 work; current week = 1000 + 500 = 1500 work.
        #expect(store.blockValue(unit: .tokens) == 500)
        #expect(store.weeklyValue(unit: .tokens) == 1500)

        #expect(store.calibrateLimits(sessionPct: 50, weeklyPct: 50, unit: .tokens, now: now))
        // A fresh calibration wins over the peak while it's still current.
        #expect(store.blockBudget(unit: .tokens) == 1000)    // 500 / 0.5
        #expect(store.weeklyBudget(unit: .tokens) == 3000)   // 1500 / 0.5
    }

    @Test func staleCalibrationFallsBackToPeak() {
        let store = MetricsStore(defaults: freshDefaults())
        store.weightTokensByModel = false
        store.ingestForTesting(seed(now: Date()))
        #expect(store.calibrateLimits(sessionPct: 50, weeklyPct: 50, unit: .tokens))
        // Backdate the calibration before this week's reset → stale → auto-peak resumes.
        store.lastCalibratedAt = Date().addingTimeInterval(-10 * 86_400)
        #expect(store.calibrationIsStale)
        #expect(abs(store.blockBudget(unit: .tokens) - 2300) < 0.01)
        #expect(abs(store.weeklyBudget(unit: .tokens) - 2300) < 0.01)
    }

    @Test func budgetSourceMapsToFlags() {
        let store = MetricsStore(defaults: freshDefaults())
        #expect(store.budgetSource == .auto)            // default
        store.budgetSource = .plan
        #expect(store.autoPeakBudget == false && store.autoBudgetFromPlan == true)
        store.budgetSource = .custom
        #expect(store.autoPeakBudget == false && store.autoBudgetFromPlan == false)
        store.budgetSource = .auto
        #expect(store.autoPeakBudget == true)
    }
}
