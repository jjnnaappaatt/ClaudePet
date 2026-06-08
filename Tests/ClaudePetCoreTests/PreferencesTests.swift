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
        let a = MetricsStore(defaults: defaults)
        a.autoBudgetFromPlan = false   // manual budget is only authoritative when plan-auto is off
        a.budgetUnit = .usd
        a.tokenBudget = 7_777_777
        a.costBudget = 12.5
        a.includeSubagents = false
        a.weightTokensByModel = false   // default is true — verify a saved `false` survives
        a.pricing.prices["opus"]?.inputPerM = 9.99
        a.saveConfigAndRecompute()

        // A new store reading the same defaults restores everything.
        let b = MetricsStore(defaults: defaults)
        #expect(b.autoBudgetFromPlan == false)
        #expect(b.budgetUnit == .usd)
        #expect(b.tokenBudget == 7_777_777)
        #expect(b.costBudget == 12.5)
        #expect(b.includeSubagents == false)
        #expect(b.weightTokensByModel == false)
        #expect(b.pricing.prices["opus"]?.inputPerM == 9.99)
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

    @Test func includeSubagentsTogglesAggregation() {
        let store = MetricsStore(defaults: freshDefaults())
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
