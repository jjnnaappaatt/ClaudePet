import Testing
import Foundation
@testable import ClaudePetCore

/// The Auto budgets re-anchor themselves to Claude's real percentages whenever the statusline
/// cache offers a usable pair, instead of resting on the local completed-window estimate — which
/// measures the user's own habits and says nothing about where Anthropic's cap sits (on real data
/// it ran 5.9× high on the 5h gauge and 2.7× high on the weekly one).
///
/// The gates are the interesting part: a bad sync is worse than none, because it writes over the
/// stored budgets and marks itself fresh.
@MainActor
@Suite struct ServerCalibrationTests {

    private func freshDefaults() -> UserDefaults {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// One entry, now: the active block and the current week both hold exactly 1000 work tokens,
    /// so every budget below is a clean division.
    private let oneThousandNow = [TestSupport.entry(at: Date(), model: "claude-sonnet-4-6",
                                                    input: 600, output: 400)]

    /// `resetsInHours < 0` writes an already-reset window; `sevenDayResetsInHours` overrides it
    /// for the weekly side only.
    private func writeCache(fiveHour: Double, sevenDay: Double,
                            resetsInHours: Double = 2,
                            sevenDayResetsInHours: Double? = nil) -> String {
        let five = iso(Date().addingTimeInterval(resetsInHours * 3600))
        let seven = iso(Date().addingTimeInterval((sevenDayResetsInHours ?? resetsInHours) * 3600))
        let path = NSTemporaryDirectory() + "csl-cal-\(UUID().uuidString).json"
        try! """
        {"five_hour":{"utilization":\(fiveHour),"resets_at":"\(five)"},
         "seven_day":{"utilization":\(sevenDay),"resets_at":"\(seven)"}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func store(cache path: String?) -> MetricsStore {
        let s = TestSupport.store(defaults: freshDefaults())
        s.weightTokensByModel = false          // weighted == work, so the arithmetic is visible
        if let path { s.statuslineCachePath = path }
        return s
    }

    @Test func backSolvesBothBudgetsFromTheServerPercentages() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)

        #expect(s.blockValue(unit: .tokens) == 1000)
        #expect(s.weeklyValue(unit: .tokens) == 1000)
        #expect(s.blockBudget(unit: .tokens) == 2000)    // 1000 / 0.50
        #expect(s.weeklyBudget(unit: .tokens) == 4000)   // 1000 / 0.25
        #expect(s.calibrationWasAutomatic)
        #expect(s.calibrationIsStale == false)
        #expect(s.budgetBasisDescription.contains("auto-synced"))
    }

    /// The derived budgets outlive the process — and come back labelled as automatic, not as
    /// something the user typed into the Calibrate sheet.
    @Test func derivedBudgetsPersist() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let defaults = freshDefaults()
        let a = TestSupport.store(defaults: defaults)
        a.weightTokensByModel = false
        a.statuslineCachePath = path
        a.ingestForTesting(oneThousandNow)
        #expect(a.tokenBudget == 2000)

        let b = TestSupport.store(defaults: defaults)
        #expect(b.tokenBudget == 2000)
        #expect(b.weeklyTokenBudget == 4000)
        #expect(b.calibrationWasAutomatic)
    }

    /// The tokens must be counted over *Claude's* window, not ClaudePet's.
    ///
    /// Our 5h block is gap-anchored to the user's own first message, so it drifts off Anthropic's
    /// grid — most sharply just after a real reset, when the local block still holds the previous
    /// window's tokens. Verified against live data during development: dividing the local block
    /// (which spanned the reset) by the server's fresh 8% produced a 21.1M session budget where
    /// the true answer was 2.3M.
    @Test func countsTokensOverClaudesWindowNotOurs() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)   // 5h window = [now-3h, now+2h)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        let m = "claude-sonnet-4-6"
        s.ingestForTesting([
            TestSupport.entry(at: Date().addingTimeInterval(-4 * 3600), model: m, input: 600, output: 400),
            TestSupport.entry(at: Date(), model: m, input: 600, output: 400),
        ])

        // The local block is gap-anchored to the older entry, so it spans Claude's reset and
        // holds both — 2000 work against Claude's 1000.
        #expect(s.blockValue(unit: .tokens) == 2000)
        #expect(s.blockBudget(unit: .tokens) == 2000)   // 1000 / 0.50, not 2000 / 0.50
    }

    /// Both units are fitted every sync, not just the active one — otherwise flipping
    /// Tokens↔US$ shows a budget from whenever that unit was last selected.
    @Test func fitsBothUnitsSoSwitchingUnitIsNotStale() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        #expect(s.budgetUnit == .tokens)
        s.ingestForTesting(oneThousandNow)

        #expect(s.tokenBudget == 2000)
        #expect(s.weeklyTokenBudget == 4000)
        // Same windows, same percentages, priced instead of counted.
        let sessionCost = s.blockBudget(unit: .usd)
        #expect(sessionCost > 0)
        #expect(abs(s.weeklyBudget(unit: .usd) - sessionCost * 2) < 1e-6)   // 1/0.25 vs 1/0.50
    }

    // MARK: Window alignment

    /// Our 5h grid is anchored to the user's own first message and drifts off Anthropic's — 4h
    /// out in practice. `resets_at` is exact, so the grid re-phases itself onto Claude's.
    @Test func alignsTheFiveHourGridToClaudesReset() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)   // 5h resets in 2h
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)                  // block would otherwise end in 5h

        s.recompute()                                       // alignment lands on the next pass
        let target = Date().addingTimeInterval(2 * 3600)
        #expect(abs((s.activeBlock?.endsAt ?? .distantPast).timeIntervalSince(target)) < 60)
    }

    @Test func alignsTheWeeklyAnchorToClaudesReset() {
        let reset = Date().addingTimeInterval(50 * 3600)    // ~2 days out, some other weekday
        let path = writeCache(fiveHour: 50, sevenDay: 25, resetsInHours: 2,
                              sevenDayResetsInHours: 50)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)

        // Rounded to the minute, not truncated — the anchor is stored as (weekday, hour, minute),
        // and truncating makes a sub-second wobble flip it (see the wobble test below).
        let rounded = Date(timeIntervalSinceReferenceDate:
            (reset.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: rounded)
        #expect(s.weeklyResetWeekday == c.weekday)
        #expect(s.weeklyResetHour == c.hour)
        #expect(s.weeklyResetMinute == c.minute)
    }

    /// Alignment never divides by the percentage, so the noise floor that guards the budget fit
    /// must not hold it back — a freshly reset window is exactly when the drift is worst.
    @Test func alignsEvenBelowTheBudgetNoiseFloor() {
        let path = writeCache(fiveHour: 2, sevenDay: 1)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)
        s.recompute()

        expectNoCalibration(s, "budgets stay on the local estimate below the floor")
        let target = Date().addingTimeInterval(2 * 3600)
        #expect(abs((s.activeBlock?.endsAt ?? .distantPast).timeIntervalSince(target)) < 60)
    }

    /// Once aligned it must stop moving, or a 30s timer rewrites `UserDefaults` forever.
    @Test func stopsMovingOnceAligned() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)
        s.recompute()
        let offset = s.sessionResetOffset
        let weekly = (s.weeklyResetWeekday, s.weeklyResetHour, s.weeklyResetMinute)
        s.recompute()
        s.recompute()
        #expect(s.sessionResetOffset == offset)
        #expect((s.weeklyResetWeekday, s.weeklyResetHour, s.weeklyResetMinute) == weekly)
    }

    /// The server's reset instant wobbles either side of the minute — 07:59:59.74Z on one tick,
    /// 08:00:00.46Z on the next. Truncating that to (weekday, hour, minute) flipped the stored
    /// anchor 15:00 ⇄ 14:59 forever, rewriting prefs and shifting the weekly window each time.
    @Test func aSubMinuteWobbleInTheResetInstantDoesNotMoveTheAnchor() {
        let s = store(cache: nil)
        s.ingestForTesting(oneThousandNow)

        // Land the anchor on a reset that is a hair *before* a whole minute.
        let base = Date().addingTimeInterval(50 * 3600)
        let onMinute = Date(timeIntervalSinceReferenceDate:
            (base.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        for offset in [-0.26, 0.46, -0.74] {
            let path = writeCache(fiveHour: 50, sevenDay: 25, resetsInHours: 2,
                                  sevenDayResetsInHours: (onMinute.addingTimeInterval(offset)
                                      .timeIntervalSince(Date())) / 3600)
            defer { try? FileManager.default.removeItem(atPath: path) }
            s.statuslineCachePath = path
            s.recompute()
            let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: onMinute)
            #expect(s.weeklyResetWeekday == c.weekday)
            #expect(s.weeklyResetHour == c.hour)
            #expect(s.weeklyResetMinute == c.minute, "wobble of \(offset)s must not move the anchor")
        }
    }

    // MARK: Gates — each of these must leave the budgets on the local estimate

    private func expectNoCalibration(_ s: MetricsStore, _ comment: Comment) {
        #expect(s.lastCalibratedAt == nil, comment)
        #expect(s.calibrationWasAutomatic == false, comment)
    }

    /// The floor is per-window. Whole-percent cache values make a low reading a terrible divisor
    /// (at 5% the ±0.5 rounding is ±10% of the budget), but that's no reason to throw away a good
    /// reading on the other gauge.
    @Test func theNoiseFloorOnlyVetoesItsOwnWindow() {
        let path = writeCache(fiveHour: 50, sevenDay: 5)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)

        #expect(s.blockBudget(unit: .tokens) == 2000)          // 1000 / 0.50
        #expect(s.lastCalibratedAt != nil)
        #expect(s.weeklyCalibratedAt == nil)                   // 5% is noise — left uncalibrated
        #expect(s.weeklyCalibrationIsStale())
        #expect(s.weeklyBudget(unit: .tokens) != 20_000)       // not 1000 / 0.05
    }

    /// 5h already reset (its cached % describes a window that's gone), weekly still open. The
    /// stamps are independent, so the live side calibrates and the dead one doesn't — and must
    /// not be *marked* calibrated off the other's stamp.
    @Test func oneUnusableWindowDoesNotBlockTheOther() {
        let path = writeCache(fiveHour: 50, sevenDay: 25, resetsInHours: -1, sevenDayResetsInHours: 2)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)

        #expect(s.weeklyBudget(unit: .tokens) == 4000)         // 1000 / 0.25
        #expect(s.weeklyCalibratedAt != nil)
        #expect(s.lastCalibratedAt == nil)                     // the 5h side stayed out of it
        #expect(s.blockCalibrationIsStale())
    }

    /// A 5h reset happens several times a day; it says nothing about the weekly percentage. With
    /// one shared stamp it dropped a good weekly fit back to the local estimate every time
    /// (observed on live data: 22M → 57M).
    @Test func aFiveHourResetDoesNotExpireTheWeeklyFit() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)
        #expect(s.weeklyBudget(unit: .tokens) == 4000)

        s.lastCalibratedAt = Date().addingTimeInterval(-6 * 3600)   // as if the 5h rolled over
        #expect(s.blockCalibrationIsStale())
        #expect(s.weeklyCalibrationIsStale() == false)
        #expect(s.weeklyBudget(unit: .tokens) == 4000)              // still Claude's number
    }

    @Test func skipsWhenTheCacheFileIsStale() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(MetricsStore.serverDataMaxAge + 60))],
            ofItemAtPath: path)
        let s = store(cache: path)
        s.ingestForTesting(oneThousandNow)
        expectNoCalibration(s, "a statusline that stopped running isn't a calibration source")
    }

    @Test func skipsWhenTheStatuslineToggleIsOff() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.useStatuslineData = false            // the opt-out; no separate setting needed
        s.ingestForTesting(oneThousandNow)
        expectNoCalibration(s, "useStatuslineData is the opt-out")
    }

    @Test func leavesPlanAndCustomBudgetsAlone() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for source in [MetricsStore.BudgetSource.plan, .custom] {
            let s = store(cache: path)
            s.budgetSource = source
            s.ingestForTesting(oneThousandNow)
            expectNoCalibration(s, "\(source) budgets belong to the user")
        }
    }

    @Test func skipsWhenThereIsNoLocalUsageToDivide() {
        let path = writeCache(fiveHour: 50, sevenDay: 25)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = store(cache: path)
        s.ingestForTesting([])
        expectNoCalibration(s, "no local value → nothing to back-solve")
    }

    /// A hand-entered calibration must not be relabelled as an automatic one.
    @Test func manualCalibrationKeepsItsLabel() {
        let s = store(cache: nil)              // no statusline cache in reach
        s.ingestForTesting(oneThousandNow)
        #expect(s.calibrateLimits(sessionPct: 40, weeklyPct: 20, unit: .tokens))
        #expect(s.blockBudget(unit: .tokens) == 2500)   // 1000 / 0.40
        #expect(s.calibrationWasAutomatic == false)
        #expect(s.budgetBasisDescription.contains("calibrated"))
    }
}
