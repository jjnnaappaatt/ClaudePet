import Testing
import Foundation
@testable import ClaudePetCore

/// Cost-weighting the gauge: a work token on a pricier model should count for
/// more than one on a cheaper model, relative to Sonnet (= 1.0). Weights derive
/// from the editable pricing table so they stay a single source of truth.
@Suite struct WeightingTests {
    let pricing = PricingTable.default

    @Test func weightsScaleByBlendedRateRelativeToSonnet() {
        // Blended (in+out) per M: opus 30, sonnet 18, haiku 6.
        #expect(abs(pricing.weight(for: .sonnet) - 1.0) < 1e-9)
        #expect(abs(pricing.weight(for: .opus) - 30.0 / 18.0) < 1e-9)
        #expect(abs(pricing.weight(for: .haiku) - 6.0 / 18.0) < 1e-9)
    }

    @Test func unknownFamilyWeightsAsOne() {
        #expect(pricing.weight(for: .other) == 1.0)
    }

    @Test func totalsAccumulateWeightedTokens() {
        var t = Totals()
        let opus = TestSupport.entry(at: Date(), model: "claude-opus-4-8", input: 600, output: 400)   // 1000 work
        let haiku = TestSupport.entry(at: Date(), model: "claude-haiku-4-5", input: 600, output: 400)  // 1000 work
        t.add(opus, cost: pricing.cost(for: opus), weight: pricing.weight(for: .opus))
        t.add(haiku, cost: pricing.cost(for: haiku), weight: pricing.weight(for: .haiku))
        #expect(t.workTokens == 2000)                                   // flat sum unchanged
        // weighted = 1000*(30/18) + 1000*(6/18) = 1666.67 + 333.33 = 2000... check exactly
        let expected = 1000.0 * (30.0 / 18.0) + 1000.0 * (6.0 / 18.0)
        #expect(abs(t.weightedTokens - expected) < 1e-6)
    }

    @Test func opusHeavyWindowWeighsMoreThanFlatTokens() {
        // Aggregator should expose weightedTokens > workTokens for an Opus-only day.
        let now = Date()
        let es = [
            TestSupport.entry(at: now, model: "claude-opus-4-8", input: 5000, output: 5000),
        ]
        let agg = Aggregator.compute(entries: es, pricing: pricing, now: now)
        #expect(agg.today.workTokens == 10_000)
        #expect(agg.today.weightedTokens > 10_000)                      // Opus inflates the weighted count
        #expect(abs(agg.today.weightedTokens - 10_000 * (30.0 / 18.0)) < 1e-6)
    }

    @Test func fiveHourBlockCarriesWeightedTokens() {
        let base = Date(timeIntervalSince1970: 1_779_998_400)
        let es = [TestSupport.entry(at: base, model: "claude-opus-4-8", input: 500, output: 500)]
        let b = FiveHourBlockEngine.activeSession(from: es, pricing: pricing,
                                                  now: base.addingTimeInterval(3600))!
        #expect(b.workTokens == 1000)
        #expect(abs(b.weightedTokens - 1000 * (30.0 / 18.0)) < 1e-6)
    }
}
