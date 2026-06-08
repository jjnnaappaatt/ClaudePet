import Foundation

/// The Claude subscription plan, read from `~/.claude.json` → `oauthAccount`.
/// Anthropic doesn't publish exact 5h/weekly token caps, so the budgets are sensible
/// tier-scaled estimates the user can edit/calibrate.
public struct AccountPlan: Sendable, Equatable {
    public let tier: String          // raw, e.g. "default_claude_max_5x"
    public let displayName: String   // "Max 5×"
    public let tokenBudget: Int      // suggested work-token budget per 5h block
    public let costBudget: Double    // suggested notional $ budget per 5h block
    public let weeklyTokenBudget: Int
    public let weeklyCostBudget: Double
    public let monthlyPrice: Double   // standard US subscription price you actually pay

    public static let unknown = AccountPlan(tier: "", displayName: "—",
                                            tokenBudget: 800_000, costBudget: 60,
                                            weeklyTokenBudget: 8_000_000, weeklyCostBudget: 600,
                                            monthlyPrice: 0)

    static func plan(forTier tier: String) -> AccountPlan {
        // Budgets calibrated against real Max 5× usage; other tiers scale. Editable + a
        // Calibrate tool in Settings. monthlyPrice = standard US plan fee (2026).
        func p(_ name: String, _ tok: Int, _ cost: Double, _ wtok: Int, _ wcost: Double, _ price: Double) -> AccountPlan {
            AccountPlan(tier: tier, displayName: name, tokenBudget: tok, costBudget: cost,
                        weeklyTokenBudget: wtok, weeklyCostBudget: wcost, monthlyPrice: price)
        }
        let t = tier.lowercased()
        if t.contains("max_20") { return p("Max 20×", 6_000_000, 1140, 56_000_000, 7000, 200) }
        if t.contains("max_5")  { return p("Max 5×",  1_500_000, 285,  12_500_000, 1750, 100) }
        if t.contains("max")    { return p("Max",     1_500_000, 285,  12_500_000, 1750, 100) }
        if t.contains("pro")    { return p("Pro",     300_000,   57,   2_800_000,  350,  20) }
        if t.isEmpty            { return .unknown }
        if t.contains("free")   { return p("Free",    150_000,   12,   1_400_000,  90,   0) }
        return p(tier, 800_000, 60, 8_000_000, 600, 0)
    }
}

/// Plan + subscription start (for the monthly billing cycle).
public struct AccountInfo: Sendable, Equatable {
    public var plan: AccountPlan
    public var subscriptionStart: Date?
    public var extraUsageEnabled: Bool = false   // pay-as-you-go overage beyond the plan

    public static let unknown = AccountInfo(plan: .unknown, subscriptionStart: nil)

    public static func detect(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> AccountInfo {
        let url = homeURL.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any] else { return .unknown }
        let tier = (oauth["organizationRateLimitTier"] as? String)
            ?? (oauth["userRateLimitTier"] as? String) ?? ""
        var start: Date?
        if let s = oauth["subscriptionCreatedAt"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            start = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        // Extra usage (overage) is on unless a disabled-reason is recorded.
        let reason = obj["cachedExtraUsageDisabledReason"] as? String
        let extraEnabled = (reason ?? "").isEmpty
        return AccountInfo(plan: AccountPlan.plan(forTier: tier),
                           subscriptionStart: start, extraUsageEnabled: extraEnabled)
    }

    /// Default anchor for the fixed 7-day weekly-limit grid. Uses the subscription start
    /// (so the grid lines up with account timing) or, lacking that, a fixed reference
    /// Monday (2024-01-01 00:00 UTC) for a reproducible grid. This is an estimate — the
    /// user calibrates an offset on top to match the Claude app's "resets in".
    public func weeklyAnchorBase() -> Date {
        subscriptionStart ?? Date(timeIntervalSince1970: 1_704_067_200)
    }

    /// Start of the current monthly billing cycle (subscription day-of-month anchor),
    /// clamped to month length. Falls back to start-of-month if no subscription date.
    public func billingCycleStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let anchorDay: Int
        if let s = subscriptionStart {
            anchorDay = calendar.component(.day, from: s)
        } else {
            anchorDay = 1
        }
        let startOfToday = calendar.startOfDay(for: now)
        let todayDay = calendar.component(.day, from: startOfToday)
        // The cycle started on `anchorDay` this month if we're past it, else last month.
        let baseMonth = todayDay >= anchorDay
            ? startOfToday
            : (calendar.date(byAdding: .month, value: -1, to: startOfToday) ?? startOfToday)
        var comps = calendar.dateComponents([.year, .month], from: baseMonth)
        let range = calendar.range(of: .day, in: .month, for: baseMonth) ?? 1..<29
        comps.day = min(anchorDay, (range.upperBound - 1))
        return calendar.date(from: comps) ?? startOfToday
    }
}
