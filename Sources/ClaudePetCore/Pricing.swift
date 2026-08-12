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

/// A price that applies to a specific model *version* whose rate differs from its family's
/// (e.g. deprecated Opus 4.1, or a time-boxed introductory rate). Matched by a lowercased
/// substring of the model ID; an optional `throughDate` bounds it to usage on/before that day.
public struct ModelPriceOverride: Codable, Sendable, Equatable {
    public var idContains: String        // lowercased substring match against the model ID
    public var price: ModelPrice
    public var throughDate: String?      // "yyyy-MM-dd" local; applies to usage on/before that day. nil = always

    public init(idContains: String, price: ModelPrice, throughDate: String? = nil) {
        self.idContains = idContains
        self.price = price
        self.throughDate = throughDate
    }
}

/// Editable, dated table mapping model families to rates. Costs are notional
/// API-equivalent (you're likely on a subscription). Codable for persistence.
public struct PricingTable: Codable, Sendable, Equatable {
    public var prices: [String: ModelPrice]   // keyed by ModelFamily.rawValue
    public var effectiveDate: String
    public var confidence: String
    public var overrides: [ModelPriceOverride]   // version-specific exceptions to the family rate

    public init(prices: [String: ModelPrice], effectiveDate: String, confidence: String,
                overrides: [ModelPriceOverride] = []) {
        self.prices = prices
        self.effectiveDate = effectiveDate
        self.confidence = confidence
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey { case prices, effectiveDate, confidence, overrides }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prices = try c.decode([String: ModelPrice].self, forKey: .prices)
        effectiveDate = try c.decode(String.self, forKey: .effectiveDate)
        confidence = try c.decode(String.self, forKey: .confidence)
        // Back-compat: a table persisted before overrides existed gets the current defaults.
        overrides = try c.decodeIfPresent([ModelPriceOverride].self, forKey: .overrides)
            ?? PricingTable.defaultOverrides
    }

    /// Version-specific exceptions applied on top of the family rates below.
    public static let defaultOverrides: [ModelPriceOverride] = [
        // Opus 4.1 is priced above the current Opus tier ($15/$75 vs $5/$25) and is deprecated.
        ModelPriceOverride(idContains: "opus-4-1", price: ModelPrice(inputPerM: 15, outputPerM: 75)),
        // Claude Sonnet 5 introductory pricing ($2/$10) runs through 2026-08-31, then reverts to the
        // Sonnet family rate ($3/$15).
        ModelPriceOverride(idContains: "sonnet-5", price: ModelPrice(inputPerM: 2, outputPerM: 10),
                           throughDate: "2026-08-31"),
    ]

    /// July-2026, web-verified defaults. Fable is the top tier (above Opus).
    public static let `default` = PricingTable(
        prices: [
            ModelFamily.fable.rawValue:  ModelPrice(inputPerM: 10, outputPerM: 50),
            ModelFamily.opus.rawValue:   ModelPrice(inputPerM: 5,  outputPerM: 25),
            ModelFamily.sonnet.rawValue: ModelPrice(inputPerM: 3,  outputPerM: 15),
            ModelFamily.haiku.rawValue:  ModelPrice(inputPerM: 1,  outputPerM: 5),
        ],
        effectiveDate: "2026-07-03",
        confidence: "high",
        overrides: defaultOverrides
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
        // A table persisted before version overrides existed carries none — restore them.
        if merged.overrides.isEmpty { merged.overrides = PricingTable.default.overrides }
        return merged
    }

    public func price(for family: ModelFamily) -> ModelPrice? {
        prices[family.rawValue]
    }

    /// The rate for a specific entry: a matching version override (respecting its date window)
    /// wins over the family rate. `calendar` is injectable for tests.
    func effectivePrice(for e: UsageEntry, calendar: Calendar = .current) -> ModelPrice? {
        // `asciiContains` rather than `lowercased()` + `contains`: this is called once per entry from
        // three separate full-history loops per `recompute()`, so the old form allocated a fresh
        // lowercased `String` and ran a locale-aware search ~384k times every 30 seconds. See
        // `String.asciiContains`.
        for o in overrides where e.model.asciiContains(o.idContains) {
            guard let through = o.throughDate else { return o.price }
            if let end = Self.endOfDay(through, calendar: calendar), e.timestamp <= end {
                return o.price
            }
            // Override has lapsed for this entry's timestamp — fall back to the family rate.
        }
        return price(for: e.family)
    }

    private static func endOfDay(_ ymd: String, calendar: Calendar) -> Date? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        dc.hour = 23; dc.minute = 59; dc.second = 59
        return calendar.date(from: dc)
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
        guard let p = effectivePrice(for: e) else { return 0 }
        let inM = p.inputPerM / 1_000_000
        let outM = p.outputPerM / 1_000_000
        return Double(e.inputTokens) * inM
             + Double(e.outputTokens) * outM
             + Double(e.cacheReadTokens) * inM * p.cacheReadMultiplier
             + Double(e.cacheWrite5mTokens) * inM * p.cacheWrite5mMultiplier
             + Double(e.cacheWrite1hTokens) * inM * p.cacheWrite1hMultiplier
    }
}
