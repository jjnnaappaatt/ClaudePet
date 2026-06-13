import Testing
import Foundation
@testable import ClaudePetCore

/// Calibration fits the limit gauges to the percentages Claude's `/usage` shows — the only
/// sanctioned bridge to subscription numbers (which no API exposes). It back-solves the
/// budget from the live gauge value and timestamps the sync so staleness can be surfaced.
@MainActor
@Suite struct CalibrationTests {

    private func freshDefaults() -> UserDefaults {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// `budget = value / (pct/100)` for both gauges. With flat (unweighted) tokens the gauge
    /// value equals the window's work tokens, so the math is exact and checkable.
    @Test func calibrateLimitsBackSolvesBothBudgets() {
        let store = MetricsStore(defaults: freshDefaults())
        store.weightTokensByModel = false      // gauge value == flat work tokens
        let now = Date()
        // 1000 work tokens, landing in both the active 5h block and the weekly window.
        store.ingestForTesting([TestSupport.entry(at: now, model: "claude-sonnet-4-6", input: 600, output: 400)])
        #expect(store.blockValue(unit: .tokens) == 1000)
        #expect(store.weeklyValue(unit: .tokens) == 1000)

        let did = store.calibrateLimits(sessionPct: 50, weeklyPct: 25, unit: .tokens, now: now)
        #expect(did)
        #expect(store.tokenBudget == 2000)         // 1000 / 0.50
        #expect(store.weeklyTokenBudget == 4000)   // 1000 / 0.25
        #expect(store.autoBudgetFromPlan == false) // calibrated budgets override the plan estimate
        #expect(store.lastCalibratedAt == now)
        // The gauges now read back the calibrated percentages.
        #expect(abs(store.blockFraction(unit: .tokens) - 0.5) < 1e-9)
        #expect(abs(store.weeklyFraction(unit: .tokens) - 0.25) < 1e-9)
    }

    /// A gauge with no measured usage can't be back-solved, so it's left untouched —
    /// never write a zero budget from a contradictory "X% of nothing".
    @Test func calibrateSkipsGaugeWithNoUsage() {
        let store = MetricsStore(defaults: freshDefaults())
        // No ingest → no active block, empty week → both gauge values are 0.
        let did = store.calibrateLimits(sessionPct: 50, weeklyPct: 50, unit: .tokens)
        #expect(did == false)
        #expect(store.lastCalibratedAt == nil)
    }

    /// Staleness flips once a weekly reset has moved past the calibration moment — the cue
    /// to re-sync. Never-calibrated also reads as stale.
    @Test func calibrationStaleFlipsAcrossWeeklyReset() {
        let store = MetricsStore(defaults: freshDefaults())
        let now1 = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(store.calibrationIsStale(now: now1) == true)   // never calibrated

        // Calibrate just inside the current weekly window → fresh.
        let weekStart1 = WeeklyWindowEngine.window(anchor: store.weeklyAnchor, now: now1).start
        store.lastCalibratedAt = weekStart1.addingTimeInterval(3600)
        #expect(store.calibrationIsStale(now: now1) == false)

        // Seven days on, the next reset has passed the calibration anchor → stale.
        let now2 = now1.addingTimeInterval(7 * 86_400)
        #expect(store.calibrationIsStale(now: now2) == true)
    }
}
