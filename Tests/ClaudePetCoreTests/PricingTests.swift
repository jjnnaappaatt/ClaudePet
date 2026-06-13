import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct PricingTests {
    let pricing = PricingTable.default

    @Test func opusCostUsesCorrectCacheMultipliers() {
        // 1M of each bucket on Opus ($5 in / $25 out):
        // 5 + 25 + (0.10*5) + (1.25*5) + (2.0*5) = 5 + 25 + 0.5 + 6.25 + 10 = 46.75
        let e = TestSupport.entry(at: Date(), model: "claude-opus-4-8",
                                  input: 1_000_000, output: 1_000_000,
                                  cacheRead: 1_000_000, cw5m: 1_000_000, cw1h: 1_000_000)
        #expect(abs(pricing.cost(for: e) - 46.75) < 1e-6)
    }

    @Test func sonnetAndHaikuBaseRates() {
        let s = TestSupport.entry(at: Date(), model: "claude-sonnet-4-6", input: 1_000_000, output: 1_000_000)
        #expect(abs(pricing.cost(for: s) - 18) < 1e-6)   // 3 + 15
        let h = TestSupport.entry(at: Date(), model: "claude-haiku-4-5", input: 1_000_000, output: 1_000_000)
        #expect(abs(pricing.cost(for: h) - 6) < 1e-6)    // 1 + 5
    }

    @Test func fableIsTopTierPriced() {
        // claude-fable-5 → Fable family, priced $10 in / $50 out (blended 60/M).
        let e = TestSupport.entry(at: Date(), model: "claude-fable-5", input: 1_000_000, output: 1_000_000)
        #expect(e.family == .fable)
        #expect(e.family.displayName == "Fable")
        #expect(!pricing.isUnpriced(.fable))
        #expect(abs(pricing.cost(for: e) - 60) < 1e-6)   // 10 + 50
    }

    @Test func mergingFillsMissingFableWithoutClobberingEdits() {
        // A table persisted before Fable existed: drop Fable, and edit Opus.
        var old = PricingTable.default
        old.prices.removeValue(forKey: ModelFamily.fable.rawValue)
        old.prices[ModelFamily.opus.rawValue] = ModelPrice(inputPerM: 99, outputPerM: 99)
        let merged = old.mergingMissingDefaults()
        #expect(merged.prices[ModelFamily.fable.rawValue] == PricingTable.default.prices[ModelFamily.fable.rawValue])  // Fable filled in
        #expect(merged.prices[ModelFamily.opus.rawValue]?.inputPerM == 99)   // user's edit preserved
    }

    @Test func unknownModelIsUnpricedNotCrash() {
        let e = TestSupport.entry(at: Date(), model: "claude-mystery-9", input: 1_000_000, output: 1_000_000)
        #expect(e.family == .other)
        #expect(pricing.isUnpriced(.other))
        #expect(pricing.cost(for: e) == 0)
    }

    @Test func tableRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(PricingTable.default)
        let back = try JSONDecoder().decode(PricingTable.self, from: data)
        #expect(back == PricingTable.default)
    }
}
