import Testing
import Foundation
@testable import ClaudePetCore

@MainActor
@Suite struct PreferencesTests {

    private func freshDefaults() -> UserDefaults {
        let name = "claudepet-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func configRoundTripsThroughDefaults() {
        let defaults = freshDefaults()
        let a = TestSupport.store(defaults: defaults)
        a.autoBudgetFromPlan = false   // manual budget is only authoritative when plan-auto is off
        a.budgetUnit = .usd
        a.tokenBudget = 7_777_777
        a.costBudget = 12.5
        a.includeSubagents = false
        a.weightTokensByModel = false   // default is true — verify a saved `false` survives
        a.weatherEffectsEnabled = false // default is true — verify a saved `false` survives
        a.tokenBasis = .work            // default is .total — verify a saved `.work` survives
        a.weeklyResetWeekday = 5        // Thursday
        a.weeklyResetHour = 9
        a.weeklyResetMinute = 30
        a.lastCalibratedAt = Date(timeIntervalSince1970: 1_700_000_000)
        a.pricing.prices["opus"]?.inputPerM = 9.99
        a.saveConfigAndRecompute()

        // A new store reading the same defaults restores everything.
        let b = TestSupport.store(defaults: defaults)
        #expect(b.autoBudgetFromPlan == false)
        #expect(b.budgetUnit == .usd)
        #expect(b.tokenBudget == 7_777_777)
        #expect(b.costBudget == 12.5)
        #expect(b.includeSubagents == false)
        #expect(b.weightTokensByModel == false)
        #expect(b.weatherEffectsEnabled == false)
        #expect(b.tokenBasis == .work)
        #expect(b.weeklyResetWeekday == 5)
        #expect(b.weeklyResetHour == 9)
        #expect(b.weeklyResetMinute == 30)
        #expect(b.lastCalibratedAt?.timeIntervalSince1970 == 1_700_000_000)
        #expect(b.pricing.prices["opus"]?.inputPerM == 9.99)
    }

    @Test func tokenBasisDefaultsToTotal() {
        // A fresh store (no stored key) shows cache-inclusive totals out of the box.
        let s = TestSupport.store(defaults: freshDefaults())
        #expect(s.tokenBasis == .total)
    }

    @Test func planTierMapping() {
        #expect(AccountPlan.plan(forTier: "default_claude_max_5x").displayName == "Max 5×")
        #expect(AccountPlan.plan(forTier: "default_claude_max_20x").displayName == "Max 20×")
        #expect(AccountPlan.plan(forTier: "claude_pro").displayName == "Pro")
        #expect(AccountPlan.plan(forTier: "").displayName == "—")
        // Max 5× should suggest a bigger budget than Pro.
        #expect(AccountPlan.plan(forTier: "default_claude_max_5x").tokenBudget
              > AccountPlan.plan(forTier: "claude_pro").tokenBudget)
    }

    @Test func billingCycleAnchorsToSubscriptionDay() {
        let cal = Calendar.current
        let sub = cal.date(from: DateComponents(year: 2026, month: 3, day: 16))!
        let info = AccountInfo(plan: .unknown, subscriptionStart: sub)

        // June 7 → before the 16th → cycle started May 16.
        let now1 = cal.date(from: DateComponents(year: 2026, month: 6, day: 7))!
        let s1 = cal.dateComponents([.month, .day], from: info.billingCycleStart(now: now1, calendar: cal))
        #expect(s1.month == 5 && s1.day == 16)

        // June 20 → after the 16th → cycle started June 16.
        let now2 = cal.date(from: DateComponents(year: 2026, month: 6, day: 20))!
        let s2 = cal.dateComponents([.month, .day], from: info.billingCycleStart(now: now2, calendar: cal))
        #expect(s2.month == 6 && s2.day == 16)
    }

    /// UTC-instant helper so these tests are deterministic regardless of the machine's local zone.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    @Test func billingCycleRealShapeAnchorsToSubscriptionInstant() {
        // Real-shape case: subscriptionCreatedAt 2026-03-16T03:03:51Z, evaluated 2026-07-15.
        let sub = utc(2026, 3, 16, 3, 3, 51)
        let info = AccountInfo(plan: .unknown, subscriptionStart: sub)
        let now = utc(2026, 7, 15, 11, 0, 0)
        #expect(info.billingCycleStart(now: now) == utc(2026, 6, 16, 3, 3, 51))
        #expect(info.billingCycleEnd(now: now) == utc(2026, 7, 16, 3, 3, 51))
    }

    @Test func billingCycleClampsShortMonthsWithoutOffByOne() {
        // Bug #1 regression: anchor day 31 must renew ON the clamped day (e.g. Jun 30), not a day late.
        let sub = utc(2026, 1, 31, 12, 0, 0)
        let info = AccountInfo(plan: .unknown, subscriptionStart: sub)

        // Feb 15 → still in the Jan 31 → Feb 28 cycle.
        #expect(info.billingCycleStart(now: utc(2026, 2, 15)) == utc(2026, 1, 31, 12))
        // Exactly at the Jun 30 renewal instant → the NEW cycle has started (not still May 31).
        #expect(info.billingCycleStart(now: utc(2026, 6, 30, 12, 0, 0)) == utc(2026, 6, 30, 12))
        #expect(info.billingCycleEnd(now: utc(2026, 6, 30, 12, 0, 0)) == utc(2026, 7, 31, 12))
    }

    @Test func billingCycleAnchorsToUTCInstantRegardlessOfHostTimeZone() {
        // Bug #2 regression: the anchor day comes from the UTC instant, not a local reinterpretation
        // of it — so the result is identical no matter which Calendar/timezone is passed in.
        let sub = utc(2026, 3, 1, 2, 0, 0)   // near UTC midnight — the case that broke local-calendar reads
        let info = AccountInfo(plan: .unknown, subscriptionStart: sub)
        let now = utc(2026, 3, 15)

        var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = TimeZone(identifier: "UTC")!
        var pacificCal = Calendar(identifier: .gregorian); pacificCal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var tokyoCal = Calendar(identifier: .gregorian); tokyoCal.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        let expected = utc(2026, 3, 1, 2, 0, 0)
        #expect(info.billingCycleStart(now: now, calendar: utcCal) == expected)
        #expect(info.billingCycleStart(now: now, calendar: pacificCal) == expected)
        #expect(info.billingCycleStart(now: now, calendar: tokyoCal) == expected)
    }

    @Test func dayOverrideCycleBoundsUsesManualDayNotSubscriptionDate() {
        // A team/org account whose real invoices land on the 4th, even though
        // subscriptionCreatedAt (unused here) would suggest a different day.
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        let b = AccountInfo.dayOverrideCycleBounds(day: 4, now: now, calendar: cal)
        let s = cal.dateComponents([.month, .day], from: b.start)
        let e = cal.dateComponents([.month, .day], from: b.end)
        #expect(s.month == 7 && s.day == 4)
        #expect(e.month == 8 && e.day == 4)
    }

    @Test func dayOverrideCycleBoundsClampsShortMonthsWithoutOffByOne() {
        // Regression guard for the same bug class as billingCycleClampsShortMonthsWithoutOffByOne,
        // but through the manual-override path: comparing full instants (not raw day ints) means
        // an anchor of 31 still renews exactly on Jun 30, not a day late.
        let cal = Calendar.current
        let onRenewalDay = cal.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 9))!
        let b1 = AccountInfo.dayOverrideCycleBounds(day: 31, now: onRenewalDay, calendar: cal)
        let s1 = cal.dateComponents([.month, .day], from: b1.start)
        #expect(s1.month == 6 && s1.day == 30)   // NOT May 31

        let midMonth = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let b2 = AccountInfo.dayOverrideCycleBounds(day: 31, now: midMonth, calendar: cal)
        let s2 = cal.dateComponents([.month, .day], from: b2.start)
        #expect(s2.month == 5 && s2.day == 31)   // still in the May 31 → Jun 30 cycle
    }

    @Test func billingCycleDayOverridePersistsAndDrivesRecompute() {
        let defaults = freshDefaults()
        let a = TestSupport.store(defaults: defaults)
        #expect(a.billingCycleDayOverride == nil)   // default: use the subscription-derived anchor
        a.billingCycleDayOverride = 4
        a.saveConfigAndRecompute()

        let b = TestSupport.store(defaults: defaults)
        #expect(b.billingCycleDayOverride == 4)

        // Clearing the override removes the stored key rather than persisting a stale value.
        b.billingCycleDayOverride = nil
        b.saveConfigAndRecompute()
        let c = TestSupport.store(defaults: defaults)
        #expect(c.billingCycleDayOverride == nil)
    }

    /// Off by default — dedup stays on unless the user opts into `/stats`-style counting.
    @Test func countRepeatedLogLinesDefaultsOffAndPersists() {
        let defaults = freshDefaults()
        let a = TestSupport.store(defaults: defaults)
        #expect(a.countRepeatedLogLines == false)
        a.countRepeatedLogLines = true
        a.saveConfigAndRecompute()
        #expect(TestSupport.store(defaults: defaults).countRepeatedLogLines == true)
    }

    /// Prefs written before the calibration stamps were split carry one date covering both
    /// gauges. Without the copy-across, an existing user's weekly budget would read as never
    /// calibrated on first launch and drop to the local estimate.
    @Test func oldSingleCalibrationStampMigratesToBothGauges() {
        let defaults = freshDefaults()
        let then = Date(timeIntervalSince1970: 1_780_000_000)
        defaults.set(then.timeIntervalSince1970, forKey: "lastCalibratedAt")

        let s = TestSupport.store(defaults: defaults)
        #expect(s.lastCalibratedAt == then)
        #expect(s.weeklyCalibratedAt == then)
    }

    @Test func includeSubagentsTogglesAggregation() {
        let store = TestSupport.store(defaults: freshDefaults())
        let now = Date()
        let main = TestSupport.entry(id: "m", at: now, model: "claude-opus-4-8", input: 100, output: 0, sidechain: false)
        let sub  = TestSupport.entry(id: "s", at: now, model: "claude-opus-4-8", input: 40, output: 0, sidechain: true)

        store.includeSubagents = true
        store.ingestForTesting([main, sub])
        #expect(store.today.workTokens == 140)

        store.includeSubagents = false
        store.recompute()
        #expect(store.today.workTokens == 100)   // subagent excluded
    }
}
