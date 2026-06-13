import Foundation

/// Per-model rates in USD per 1M tokens. Cache rates are expressed as multipliers
/// of the input rate (standard Anthropic ratios): read 0.10×, 5m write 1.25×, 1h write 2×.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var inputPerM: Double
    public var outputPerM: Double
    public var cacheReadMultiplier: Double
    public var cacheWrite5mMultiplier: Double
    public var cacheWrite1hMultiplier: Double

    public init(inputPerM: Double, outputPerM: Double,
                cacheReadMultiplier: Double = 0.10,
                cacheWrite5mMultiplier: Double = 1.25,
                cacheWrite1hMultiplier: Double = 2.0) {
        self.inputPerM = inputPerM
        self.outputPerM = outputPerM
        self.cacheReadMultiplier = cacheReadMultiplier
        self.cacheWrite5mMultiplier = cacheWrite5mMultiplier
        self.cacheWrite1hMultiplier = cacheWrite1hMultiplier
    }
}

/// Editable, dated table mapping model families to rates. Costs are notional
/// API-equivalent (you're likely on a subscription). Codable for persistence.
public struct PricingTable: Codable, Sendable, Equatable {
    public var prices: [String: ModelPrice]   // keyed by ModelFamily.rawValue
    public var effectiveDate: String
    public var confidence: String

    public init(prices: [String: ModelPrice], effectiveDate: String, confidence: String) {
        self.prices = prices
        self.effectiveDate = effectiveDate
        self.confidence = confidence
    }

    /// June-2026, web-verified defaults. Fable is the top tier (above Opus).
    public static let `default` = PricingTable(
        prices: [
            ModelFamily.fable.rawValue:  ModelPrice(inputPerM: 10, outputPerM: 50),
            ModelFamily.opus.rawValue:   ModelPrice(inputPerM: 5,  outputPerM: 25),
            ModelFamily.sonnet.rawValue: ModelPrice(inputPerM: 3,  outputPerM: 15),
            ModelFamily.haiku.rawValue:  ModelPrice(inputPerM: 1,  outputPerM: 5),
        ],
        effectiveDate: "2026-06-01",
        confidence: "high"
    )

    /// A copy with any family that exists in `default` but is missing here filled in from
    /// the defaults. Lets a table persisted before a new model existed (e.g. a saved table
    /// with no Fable entry) pick up the new family without discarding the user's own edits
    /// to the families it already has.
    public func mergingMissingDefaults() -> PricingTable {
        var merged = self
        for (family, price) in PricingTable.default.prices where merged.prices[family] == nil {
            merged.prices[family] = price
        }
        return merged
    }

    public func price(for family: ModelFamily) -> ModelPrice? {
        prices[family.rawValue]
    }

    /// True when this family has no rate and its tokens can't be priced.
    public func isUnpriced(_ family: ModelFamily) -> Bool {
        prices[family.rawValue] == nil
    }

    /// How much a work token on `family` should count toward the gauge, relative to
    /// Sonnet (= 1.0). Derived from each family's blended (input+output) rate so an
    /// Opus token weighs ~1.67× a Sonnet token and a Haiku token ~0.33×. This makes
    /// the token gauge track limit consumption better than a flat token sum, since
    /// pricier models burn the subscription faster. Unknown/unpriced families → 1.0.
    public func weight(for family: ModelFamily) -> Double {
        guard let p = price(for: family), let ref = price(for: .sonnet) else { return 1 }
        let blended = p.inputPerM + p.outputPerM
        let refBlended = ref.inputPerM + ref.outputPerM
        return refBlended > 0 ? blended / refBlended : 1
    }

    /// Notional USD cost of one usage entry (0 if the family is unpriced).
    public func cost(for e: UsageEntry) -> Double {
        guard let p = price(for: e.family) else { return 0 }
        let inM = p.inputPerM / 1_000_000
        let outM = p.outputPerM / 1_000_000
        return Double(e.inputTokens) * inM
             + Double(e.outputTokens) * outM
             + Double(e.cacheReadTokens) * inM * p.cacheReadMultiplier
             + Double(e.cacheWrite5mTokens) * inM * p.cacheWrite5mMultiplier
             + Double(e.cacheWrite1hTokens) * inM * p.cacheWrite1hMultiplier
    }
}
