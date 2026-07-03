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

    // MARK: - Version-specific pricing gaps

    @Test func mythos5IsPricedAsFable() {
        let e = TestSupport.entry(at: Date(), model: "claude-mythos-5", input: 1_000_000, output: 1_000_000)
        #expect(e.family == .fable)                       // routed to Fable pricing
        #expect(!pricing.isUnpriced(e.family))
        #expect(abs(pricing.cost(for: e) - 60) < 1e-6)    // 10 + 50, same as Fable
    }

    @Test func opus41UsesLegacyHigherRate() {
        let e = TestSupport.entry(at: Date(), model: "claude-opus-4-1-20250805",
                                  input: 1_000_000, output: 1_000_000)
        #expect(e.family == .opus)
        #expect(abs(pricing.cost(for: e) - 90) < 1e-6)    // 15 + 75, not the 5/25 family rate
        // Current Opus versions keep the family rate.
        let cur = TestSupport.entry(at: Date(), model: "claude-opus-4-8",
                                    input: 1_000_000, output: 1_000_000)
        #expect(abs(pricing.cost(for: cur) - 30) < 1e-6)  // 5 + 25
    }

    @Test func sonnet5IntroPriceThenReverts() {
        let intro = TestSupport.entry(at: date("2026-07-15"), model: "claude-sonnet-5",
                                      input: 1_000_000, output: 1_000_000)
        #expect(abs(pricing.cost(for: intro) - 12) < 1e-6)   // 2 + 10 during intro window
        let after = TestSupport.entry(at: date("2026-09-01"), model: "claude-sonnet-5",
                                      input: 1_000_000, output: 1_000_000)
        #expect(abs(pricing.cost(for: after) - 18) < 1e-6)   // 3 + 15 after 2026-08-31
        // Older Sonnet versions are unaffected by the Sonnet-5 override.
        let s46 = TestSupport.entry(at: date("2026-07-15"), model: "claude-sonnet-4-6",
                                    input: 1_000_000, output: 1_000_000)
        #expect(abs(pricing.cost(for: s46) - 18) < 1e-6)
    }

    @Test func mergingRestoresMissingOverrides() {
        var old = PricingTable.default
        old.overrides = []                                 // simulate a table persisted before overrides
        #expect(old.mergingMissingDefaults().overrides == PricingTable.default.overrides)
    }

    private func date(_ ymd: String) -> Date {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]; dc.hour = 12
        return Calendar.current.date(from: dc)!
    }
}
