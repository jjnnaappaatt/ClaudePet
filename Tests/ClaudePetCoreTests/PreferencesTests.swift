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
        a.budgetUnit = .usd
        a.tokenBudget = 7_777_777
        a.costBudget = 12.5
        a.includeSubagents = false
        a.pricing.prices["opus"]?.inputPerM = 9.99
        a.saveConfigAndRecompute()

        // A new store reading the same defaults restores everything.
        let b = MetricsStore(defaults: defaults)
        #expect(b.budgetUnit == .usd)
        #expect(b.tokenBudget == 7_777_777)
        #expect(b.costBudget == 12.5)
        #expect(b.includeSubagents == false)
        #expect(b.pricing.prices["opus"]?.inputPerM == 9.99)
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
