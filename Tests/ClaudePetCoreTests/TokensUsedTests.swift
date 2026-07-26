import Testing
import Foundation
@testable import ClaudePetCore

/// "X used this week/window" must report REAL tokens (raw), never the cost-weighted
/// value the gauge fraction uses. Otherwise the count overstates true usage (Opus/Fable
/// tokens weigh >1×), which is the bug behind "14.9M used" vs the real 7.9M.
///
/// It must also follow the user's work/total basis. It used to be hard-wired to work while
/// the header, charts and footer honoured the setting — so under the `.total` default the bar
/// read "4.2M used this week" directly above a footer reading "Week 1.3B", ~300× apart.
@MainActor
@Suite struct TokensUsedTests {

    /// The "raw, never weighted" tests below assert work-basis numbers; `tokenBasis` defaults to
    /// `.total`, so pin it here and let the basis-flip tests exercise the other side explicitly.
    /// Same rationale (and shape) as `DailyPaceTests.freshStore`.
    private func freshStore() -> MetricsStore {
        let name = "tokensused-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let store = MetricsStore(defaults: d)
        store.tokenBasis = .work
        return store
    }

    /// A fixed instant so nothing here depends on when the suite runs.
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func block(work: Int, total: Int, cost: Double, weighted: Double,
                       hoursElapsed: Double = 1) -> UsageBlock {
        let started = t0.addingTimeInterval(-hoursElapsed * 3600)
        return UsageBlock(start: started, actualStart: started, lastActivity: t0,
                          workTokens: work, totalTokens: total, costUSD: cost,
                          weightedTokens: weighted)
    }

    // MARK: - Raw, never cost-weighted

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

    /// The basis change must not quietly reintroduce weighting on the block subtitle either.
    @Test func blockTokensUsedIsNeverWeighted() {
        let s = freshStore()
        s.tokenBasis = .total
        s.activeBlock = block(work: 1_000, total: 100_000, cost: 2, weighted: 1_700)
        s.weightTokensByModel = true
        let on = s.blockTokensUsed(unit: .tokens)
        s.weightTokensByModel = false
        #expect(on == s.blockTokensUsed(unit: .tokens))
        #expect(on == 100_000)        // the total-basis figure, not 1_700
    }

    // MARK: - Follows the work/total basis

    @Test func weeklyTokensUsedFollowsTokenBasis() {
        let s = freshStore()
        s.week = Totals(workTokens: 1_000_000, totalTokens: 300_000_000,
                        costUSD: 9, weightedTokens: 1_900_000)
        s.tokenBasis = .work
        #expect(s.weeklyTokensUsed(unit: .tokens) == 1_000_000)
        s.tokenBasis = .total
        #expect(s.weeklyTokensUsed(unit: .tokens) == 300_000_000)
        // Cost never routes through the basis funnel.
        #expect(s.weeklyTokensUsed(unit: .usd) == 9)
        s.tokenBasis = .work
        #expect(s.weeklyTokensUsed(unit: .usd) == 9)
    }

    @Test func blockTokensUsedFollowsTokenBasis() {
        let s = freshStore()
        s.activeBlock = block(work: 1_000, total: 100_000, cost: 2, weighted: 1_700)
        s.tokenBasis = .work
        #expect(s.blockTokensUsed(unit: .tokens) == 1_000)
        s.tokenBasis = .total
        #expect(s.blockTokensUsed(unit: .tokens) == 100_000)
        #expect(s.blockTokensUsed(unit: .usd) == 2)
    }

    /// Burn is "used ÷ elapsed", so it has to move with the same basis or the two lines of the
    /// gauge disagree about what a token is. `now` is explicit, so this needs no config pinning.
    @Test func blockBurnPerHourSharesTokensUsedBasis() {
        let s = freshStore()
        s.activeBlock = block(work: 1_000, total: 100_000, cost: 2, weighted: 1_700,
                              hoursElapsed: 2)
        s.tokenBasis = .work
        #expect(abs(s.blockBurnPerHour(unit: .tokens, now: t0) - 500) < 0.001)
        s.tokenBasis = .total
        #expect(abs(s.blockBurnPerHour(unit: .tokens, now: t0) - 50_000) < 0.001)
    }

    /// The literal defect: the weekly bar's subtitle and the "Week" figure in the footer read the
    /// same `Totals`, so they must agree on every basis.
    @Test func weeklySubtitleAgreesWithFooter() {
        let s = freshStore()
        s.week = Totals(workTokens: 4_266_414, totalTokens: 1_292_777_967,
                        costUSD: 120, weightedTokens: 6_000_000)
        for basis in TokenBasis.allCases {
            s.tokenBasis = basis
            #expect(s.weeklyTokensUsed(unit: .tokens) == Double(s.totalsTokens(s.week)))
        }
    }
}
