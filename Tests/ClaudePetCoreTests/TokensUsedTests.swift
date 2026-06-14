import Testing
import Foundation
@testable import ClaudePetCore

/// "X used this week/window" must report REAL tokens (raw work), never the cost-weighted
/// value the gauge fraction uses. Otherwise the count overstates true usage (Opus/Fable
/// tokens weigh >1×), which is the bug behind "14.9M used" vs the real 7.9M.
@MainActor
@Suite struct TokensUsedTests {

    private func freshStore() -> MetricsStore {
        let name = "tokensused-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return MetricsStore(defaults: d)
    }

    @Test func weeklyTokensUsedIsRawNotWeighted() {
        let s = freshStore()
        s.weightTokensByModel = true
        s.week = Totals(workTokens: 1_000_000, totalTokens: 5_000_000,
                        costUSD: 9, weightedTokens: 1_900_000)
        // The gauge math stays weighted…
        #expect(s.weeklyValue(unit: .tokens) == 1_900_000)
        // …but the displayed "used" count is the real (raw) work tokens.
        #expect(s.weeklyTokensUsed(unit: .tokens) == 1_000_000)
        #expect(s.weeklyTokensUsed(unit: .usd) == 9)
    }

    @Test func weeklyTokensUsedUnaffectedByWeightingToggle() {
        let s = freshStore()
        s.week = Totals(workTokens: 800_000, totalTokens: 2_000_000,
                        costUSD: 4, weightedTokens: 1_500_000)
        s.weightTokensByModel = true
        let on = s.weeklyTokensUsed(unit: .tokens)
        s.weightTokensByModel = false
        let off = s.weeklyTokensUsed(unit: .tokens)
        #expect(on == off)            // display is invariant to the weighting setting
        #expect(on == 800_000)
    }
}
