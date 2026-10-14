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

    /// Version-specific exceptions applied on top of the family rates below. **First match wins**,
    /// so a more specific id must come before any id it contains.
    ///
    /// Cache reads dominate the notional cost under always-on prompt caching (they are ~97% of
    /// tokens), so a cache-read multiplier that differs from the standard 0.10× is not a detail:
    /// Fable 5.1's 0.025× priced at 0.10× overstated its cost roughly 4×.
    public static let defaultOverrides: [ModelPriceOverride] = [
        // Opus 4.1 is priced above the current Opus tier ($15/$75 vs $5/$25) and is deprecated.
        ModelPriceOverride(idContains: "opus-4-1", price: ModelPrice(inputPerM: 15, outputPerM: 75)),
        // Opus 5.5 undercuts the Opus family rate, and its cache reads are 0.05× ($0.20/MTok).
        ModelPriceOverride(idContains: "opus-5-5",
                           price: ModelPrice(inputPerM: 4, outputPerM: 20, cacheReadMultiplier: 0.05)),
        // Fable 5.1 (and Mythos 5.1, the same model) keep Fable 5's rates except cache reads at
        // 0.025× ($0.25/MTok).
        ModelPriceOverride(idContains: "fable-5-1",
                           price: ModelPrice(inputPerM: 10, outputPerM: 50, cacheReadMultiplier: 0.025)),
        ModelPriceOverride(idContains: "mythos-5-1",
                           price: ModelPrice(inputPerM: 10, outputPerM: 50, cacheReadMultiplier: 0.025)),
        // Sonnet 5 and 5.5 are $2/$10. This began as a dated introductory rate (through 2026-08-31)
        // and became the standing price; the substring covers `sonnet-5-5` too.
        ModelPriceOverride(idContains: "sonnet-5", price: ModelPrice(inputPerM: 2, outputPerM: 10)),
    ]

    /// Overrides this app once shipped as defaults and has since replaced. A saved table holding
    /// one of these **exactly** is carrying our stale default, not a user's edit, so
    /// `mergingMissingDefaults` swaps it for the current one; anything the user changed is left be.
    static let retiredDefaultOverrides: [ModelPriceOverride] = [
        ModelPriceOverride(idContains: "sonnet-5", price: ModelPrice(inputPerM: 2, outputPerM: 10),
                           throughDate: "2026-08-31"),
    ]

    /// Family rates (verified against Anthropic's published table, 2026-09-25). Fable is the top
    /// tier (above Opus). Version-specific rates live in `defaultOverrides`.
    public static let `default` = PricingTable(
        prices: [
            ModelFamily.fable.rawValue:  ModelPrice(inputPerM: 10, outputPerM: 50),
            ModelFamily.opus.rawValue:   ModelPrice(inputPerM: 5,  outputPerM: 25),
            ModelFamily.sonnet.rawValue: ModelPrice(inputPerM: 3,  outputPerM: 15),
            ModelFamily.haiku.rawValue:  ModelPrice(inputPerM: 1,  outputPerM: 5),
        ],
        effectiveDate: "2026-09-25",
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
        // Override-by-override, not "only when the list is empty": that rule restored the defaults
        // for a table saved before overrides existed and never again, so a table saved with one
        // override silently missed every override added after it (Opus 5.5, Fable 5.1).
        for (i, o) in merged.overrides.enumerated() where Self.retiredDefaultOverrides.contains(o) {
            if let current = PricingTable.default.overrides.first(where: { $0.idContains == o.idContains }) {
                merged.overrides[i] = current
            }
        }
        for d in PricingTable.default.overrides
        where !merged.overrides.contains(where: { $0.idContains == d.idContains }) {
            // Before the first saved override it would otherwise shadow ("opus-5-5" must be
            // checked before a user's own "opus-5"), else at the end.
            let at = merged.overrides.firstIndex { d.idContains.asciiContains($0.idContains) }
            merged.overrides.insert(d, at: at ?? merged.overrides.endIndex)
        }
        return merged
    }

    public func price(for family: ModelFamily) -> ModelPrice? {
        prices[family.rawValue]
    }

    /// The rate for a specific entry: a matching version override (respecting its date window)
    /// wins over the family rate. `calendar` supplies only the **time zone** — see `endOfDay`.
    func effectivePrice(for e: UsageEntry, calendar: Calendar = .current) -> ModelPrice? {
        PriceResolver(self, timeZone: calendar.timeZone).price(for: e)
    }

    /// End of a `yyyy-MM-dd` day, read on a **Gregorian** calendar in `timeZone`.
    ///
    /// The string is a Gregorian date, so the user's calendar must not interpret it. This used
    /// `Calendar.current`, and under the Thai Buddhist calendar year 2026 is Gregorian 1483 — so
    /// every dated override had lapsed five centuries before any entry it was meant to price, and
    /// the Sonnet 5 introductory rate never applied on the machine this app is developed on. Same
    /// trap `StatsCache` documents for `lastComputedDate`.
    static func endOfDay(_ ymd: String, timeZone: TimeZone) -> Date? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = timeZone
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        dc.hour = 23; dc.minute = 59; dc.second = 59
        return g.date(from: dc)
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
    ///
    /// Convenience for one-off use. A loop over the history must build one `PriceResolver` and ask
    /// it instead — this builds a fresh one per call.
    public func cost(for e: UsageEntry) -> Double {
        PriceResolver(self).cost(for: e)
    }

    static func cost(of e: UsageEntry, at p: ModelPrice) -> Double {
        let inM = p.inputPerM / 1_000_000
        let outM = p.outputPerM / 1_000_000
        return Double(e.inputTokens) * inM
             + Double(e.outputTokens) * outM
             + Double(e.cacheReadTokens) * inM * p.cacheReadMultiplier
             + Double(e.cacheWrite5mTokens) * inM * p.cacheWrite5mMultiplier
             + Double(e.cacheWrite1hTokens) * inM * p.cacheWrite1hMultiplier
    }
}

/// A `PricingTable` prepared for pricing many entries: build one per pass over the history.
///
/// **This exists because pricing was the hot spot of every recompute.** `effectivePrice` ran once
/// per entry from four full-history loops, and each call substring-matched every override against
/// the model id, then re-parsed the override's `throughDate` string and built a `Date` through
/// `Calendar` — ~130k entries × 4 loops of string splitting and calendar arithmetic per recompute,
/// visible as `PricingTable.endOfDay` + `String.split` in a live `sample`. Here each override's end
/// date is computed once, and the override list is resolved once per distinct model id (~10 on a
/// real corpus; `model` is interned, so consecutive entries usually share one string and the
/// one-slot memo short-circuits even the dictionary lookup). Results are identical to
/// `effectivePrice` by construction — it is now implemented on top of this.
public final class PriceResolver {
    private struct Rule { let price: ModelPrice; let end: Date? }
    private let table: PricingTable
    /// Per override, in table order; nil for an override whose `throughDate` doesn't parse — it
    /// can never apply, which is what the old per-entry code did with it too.
    private let compiled: [Rule?]
    private var byModel: [String: [Rule]] = [:]
    private var lastModel: String?
    private var lastRules: [Rule] = []
    private let familyPrice: [ModelFamily: ModelPrice]
    private let familyWeight: [ModelFamily: Double]

    public init(_ table: PricingTable, timeZone: TimeZone = .current) {
        self.table = table
        compiled = table.overrides.map { o in
            guard let through = o.throughDate else { return Rule(price: o.price, end: nil) }
            return PricingTable.endOfDay(through, timeZone: timeZone).map { Rule(price: o.price, end: $0) }
        }
        var fp: [ModelFamily: ModelPrice] = [:]
        var fw: [ModelFamily: Double] = [:]
        for f in ModelFamily.allCases {
            fp[f] = table.price(for: f)
            fw[f] = table.weight(for: f)
        }
        familyPrice = fp
        familyWeight = fw
    }

    private func rules(for model: String) -> [Rule] {
        if let lastModel, lastModel == model { return lastRules }
        let r: [Rule]
        if let hit = byModel[model] {
            r = hit
        } else {
            r = zip(table.overrides, compiled).compactMap { o, rule in
                model.asciiContains(o.idContains) ? rule : nil
            }
            byModel[model] = r
        }
        lastModel = model
        lastRules = r
        return r
    }

    public func price(for e: UsageEntry) -> ModelPrice? {
        for rule in rules(for: e.model) {
            guard let end = rule.end else { return rule.price }
            if e.timestamp <= end { return rule.price }
            // Lapsed for this entry's timestamp — try the next override, then the family rate.
        }
        return familyPrice[e.family]
    }

    public func cost(for e: UsageEntry) -> Double {
        guard let p = price(for: e) else { return 0 }
        return PricingTable.cost(of: e, at: p)
    }

    public func weight(for family: ModelFamily) -> Double { familyWeight[family] ?? 1 }
}
