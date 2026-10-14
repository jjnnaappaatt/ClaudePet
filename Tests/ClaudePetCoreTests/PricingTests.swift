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

    @Test func sonnet5AndSonnet55AreTwoAndTen() {
        // Began as an introductory rate ending 2026-08-31; it is now the standing price, so a
        // September entry must not revert to the $3/$15 family rate.
        for (model, day) in [("claude-sonnet-5", "2026-07-15"), ("claude-sonnet-5", "2026-09-15"),
                             ("claude-sonnet-5-5", "2026-10-01")] {
            let e = TestSupport.entry(at: date(day), model: model, input: 1_000_000, output: 1_000_000)
            #expect(abs(pricing.cost(for: e) - 12) < 1e-6, "\(model) on \(day)")
        }
        // Older Sonnet versions are unaffected by the Sonnet-5 override.
        let s46 = TestSupport.entry(at: date("2026-07-15"), model: "claude-sonnet-4-6",
                                    input: 1_000_000, output: 1_000_000)
        #expect(abs(pricing.cost(for: s46) - 18) < 1e-6)
    }

    @Test func opus55IsFourAndTwentyWithHalfPriceCacheReads() {
        // 1M input + 1M output + 1M cache read: 4 + 20 + 0.05*4 = 24.2
        let e = TestSupport.entry(at: Date(), model: "claude-opus-5-5",
                                  input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(pricing.cost(for: e) - 24.2) < 1e-6)
        // `opus-5` (no point release) keeps the family rate: 5 + 25 + 0.10*5.
        let o5 = TestSupport.entry(at: Date(), model: "claude-opus-5",
                                   input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(pricing.cost(for: o5) - 30.5) < 1e-6)
    }

    @Test func fable51CacheReadsAreAQuarterOfFable5s() {
        let read = 1_000_000
        let f51 = TestSupport.entry(at: Date(), model: "claude-fable-5-1", cacheRead: read)
        let f5 = TestSupport.entry(at: Date(), model: "claude-fable-5", cacheRead: read)
        #expect(abs(pricing.cost(for: f51) - 0.25) < 1e-9)
        #expect(abs(pricing.cost(for: f5) - 1.00) < 1e-9)
        let m51 = TestSupport.entry(at: Date(), model: "claude-mythos-5-1", cacheRead: read)
        #expect(abs(pricing.cost(for: m51) - 0.25) < 1e-9)
    }

    @Test func savedTablePicksUpNewOverridesAndDropsTheRetiredSonnetDate() {
        // A table saved by v0.14: Opus 4.1 plus the then-dated Sonnet 5 rate, nothing newer.
        var old = PricingTable.default
        old.overrides = [PricingTable.default.overrides[0]] + PricingTable.retiredDefaultOverrides
        let merged = old.mergingMissingDefaults()
        #expect(Set(merged.overrides.map(\.idContains)) == Set(PricingTable.default.overrides.map(\.idContains)))
        #expect(merged.overrides.first { $0.idContains == "sonnet-5" }?.throughDate == nil)
    }

    @Test func mergeKeepsUserEditedOverridesAndDoesNotLetThemShadowNewOnes() {
        var old = PricingTable.default
        let mine = ModelPriceOverride(idContains: "opus-5", price: ModelPrice(inputPerM: 7, outputPerM: 7))
        let editedSonnet = ModelPriceOverride(idContains: "sonnet-5",
                                              price: ModelPrice(inputPerM: 9, outputPerM: 9),
                                              throughDate: "2026-08-31")
        old.overrides = [mine, editedSonnet]
        let merged = old.mergingMissingDefaults()
        #expect(merged.overrides.contains(editedSonnet))          // not a retired default: kept
        let i55 = merged.overrides.firstIndex { $0.idContains == "opus-5-5" }!
        let iMine = merged.overrides.firstIndex(of: mine)!
        #expect(i55 < iMine)                                      // first match wins
        let e = TestSupport.entry(at: Date(), model: "claude-opus-5-5", input: 1_000_000)
        #expect(abs(merged.cost(for: e) - 4) < 1e-6)
    }

    /// The resolver is what every full-history loop now uses; it must price exactly as the
    /// per-entry path, including dated overrides on either side of their end and models that
    /// alternate (the one-slot memo must not leak one model's rules onto the next).
    @Test func resolverMatchesPerEntryPricing() {
        var table = PricingTable.default
        table.overrides.append(ModelPriceOverride(idContains: "haiku-4-5",
                                                  price: ModelPrice(inputPerM: 0.5, outputPerM: 2),
                                                  throughDate: "2026-08-31"))
        let models = ["claude-opus-5-5", "claude-haiku-4-5", "claude-opus-5-5", "claude-fable-5-1",
                      "claude-haiku-4-5", "claude-sonnet-4-6", "claude-mystery-9", "claude-opus-4-1"]
        let days = ["2026-08-30", "2026-08-31", "2026-09-01", "2026-09-30"]
        let resolver = PriceResolver(table)
        for (i, m) in models.enumerated() {
            for d in days {
                let e = TestSupport.entry(at: date(d), model: m, input: 1_000 + i, output: 2_000,
                                          cacheRead: 30_000, cw5m: 500, cw1h: 100)
                #expect(resolver.cost(for: e) == table.cost(for: e), "\(m) \(d)")
            }
        }
    }

    @Test func mergingRestoresMissingOverrides() {
        var old = PricingTable.default
        old.overrides = []                                 // simulate a table persisted before overrides
        #expect(old.mergingMissingDefaults().overrides == PricingTable.default.overrides)
        // And a current table is left exactly as it is.
        #expect(PricingTable.default.mergingMissingDefaults() == PricingTable.default)
    }

    /// `throughDate` is a Gregorian `yyyy-MM-dd`, so it must not be read on the user's calendar.
    /// Under the Thai Buddhist calendar `Calendar.current.date(from: year 2026)` is the Gregorian
    /// year 1483, so every dated override silently lapsed — on the developer's own machine, which
    /// is exactly the locale where this ships.
    @Test func datedOverrideIsReadAsGregorianOnABuddhistCalendar() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let table = PricingTable(
            prices: PricingTable.default.prices, effectiveDate: "test", confidence: "test",
            overrides: [ModelPriceOverride(idContains: "sonnet-9",
                                           price: ModelPrice(inputPerM: 2, outputPerM: 10),
                                           throughDate: "2026-08-31")])
        let inWindow = TestSupport.entry(at: date("2026-08-15"), model: "claude-sonnet-9",
                                         input: 1_000_000, output: 1_000_000)
        let lapsed = TestSupport.entry(at: date("2026-09-15"), model: "claude-sonnet-9",
                                       input: 1_000_000, output: 1_000_000)
        #expect(table.effectivePrice(for: inWindow, calendar: buddhist)?.inputPerM == 2)
        #expect(table.effectivePrice(for: lapsed, calendar: buddhist)?.inputPerM == 3)
    }

    /// Gregorian on purpose — `Calendar.current` is Buddhist on the developer's machine, which put
    /// these test dates in 1483 and let the bug above pass its own test.
    private func date(_ ymd: String) -> Date {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]; dc.hour = 12
        var g = Calendar(identifier: .gregorian)
        g.timeZone = .current
        return g.date(from: dc)!
    }
}
