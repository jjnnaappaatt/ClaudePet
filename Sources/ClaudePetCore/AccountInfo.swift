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

    /// The current billing cycle as `[start, end)`: the monthly anniversary of the subscription
    /// instant, walked on a **UTC** calendar (matching `subscriptionCreatedAt`, which is UTC and
    /// the only billing-zone signal we have). `Calendar.date(byAdding: .month:)` clamps short
    /// months (e.g. Jan 31 → Feb 28) and preserves the renewal time-of-day for free; walking from
    /// the *original* instant each time (never cumulatively) keeps the clamp from drifting. Returns
    /// nil if there's no subscription date (caller falls back to start-of-month).
    private func cycleBounds(now: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        guard let sub = subscriptionStart else { return nil }
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        func anniversary(_ k: Int) -> Date { cal.date(byAdding: .month, value: k, to: sub) ?? sub }
        var k = max(0, cal.dateComponents([.month], from: sub, to: now).month ?? 0)
        if anniversary(k) > now {
            k = max(0, k - 1)
        } else {
            while anniversary(k + 1) <= now { k += 1 }
        }
        return (anniversary(k), anniversary(k + 1))
    }

    /// Start of the current monthly billing cycle. Falls back to start-of-local-month if no
    /// subscription date is known.
    public func billingCycleStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        if let b = cycleBounds(now: now, calendar: calendar) { return b.start }
        let comps = calendar.dateComponents([.year, .month], from: now)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: now)
    }

    /// End of the current billing cycle — the next anniversary, i.e. the reset moment / the
    /// countdown target for a "resets in …" display.
    public func billingCycleEnd(now: Date = Date(), calendar: Calendar = .current) -> Date {
        if let b = cycleBounds(now: now, calendar: calendar) { return b.end }
        let start = billingCycleStart(now: now, calendar: calendar)
        return calendar.date(byAdding: .month, value: 1, to: start) ?? start
    }

    /// Cycle bounds from a manually-entered day-of-month (1–31), for accounts whose real Stripe
    /// billing anchor doesn't match `subscriptionCreatedAt` — e.g. an org/team plan, where that
    /// field reflects when *this seat* was created, not when the organization's invoice recurs.
    /// There's no local-file signal for the true org billing day, so the user reads it off their
    /// own invoice history and enters it here.
    ///
    /// Compares full `Date` instants (never raw day-of-month integers), so a short month's clamp
    /// can't cause an off-by-one the way the old subscription-day reconstruction did: the current
    /// month's clamped anchor either has already passed (this cycle) or hasn't (previous cycle).
    public static func dayOverrideCycleBounds(day: Int, now: Date, calendar: Calendar = .current)
        -> (start: Date, end: Date) {
        let day = max(1, min(31, day))
        func anchor(inMonthOf date: Date) -> Date {
            var comps = calendar.dateComponents([.year, .month], from: date)
            let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<29
            comps.day = min(day, range.upperBound - 1)
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return calendar.date(from: comps) ?? date
        }
        let thisMonth = anchor(inMonthOf: now)
        if thisMonth <= now {
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: now) ?? now
            return (thisMonth, anchor(inMonthOf: nextMonth))
        } else {
            let prevMonth = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return (anchor(inMonthOf: prevMonth), thisMonth)
        }
    }
}
