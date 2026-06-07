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

    /// June-2026, web-verified defaults.
    public static let `default` = PricingTable(
        prices: [
            ModelFamily.opus.rawValue:   ModelPrice(inputPerM: 5,  outputPerM: 25),
            ModelFamily.sonnet.rawValue: ModelPrice(inputPerM: 3,  outputPerM: 15),
            ModelFamily.haiku.rawValue:  ModelPrice(inputPerM: 1,  outputPerM: 5),
        ],
        effectiveDate: "2026-06-01",
        confidence: "high"
    )

    public func price(for family: ModelFamily) -> ModelPrice? {
        prices[family.rawValue]
    }

    /// True when this family has no rate and its tokens can't be priced.
    public func isUnpriced(_ family: ModelFamily) -> Bool {
        prices[family.rawValue] == nil
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
