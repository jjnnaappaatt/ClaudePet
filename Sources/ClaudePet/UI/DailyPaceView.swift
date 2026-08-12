import SwiftUI
import ClaudePetCore

/// "Today" daily-pace bar — the current day's tokens (or $) relative to your recent daily average.
/// Claude has no daily limit, so this is informational, not a budget. Sits beneath the 5h + weekly
/// gauges.
///
/// **A usual day fills the bar** (`MetricsStore.dailyPaceFraction`), so the fill and the "today N%"
/// beside it always say the same thing. It used to put the average at the midpoint — full ≈ 2× a
/// usual day — which nobody read that way: a day at 2/3 of normal drew a third of a bar.
///
/// Its two numbers come from two different series, and neither can stand in for the other:
/// today's own value from `calendarWeekDaily` (which can't fold two calendar dates into one slot),
/// the average from `allTimeDaily` (which a weekly reset can't empty). See the `// MARK: - Daily
/// pace` block in `MetricsStore` for why each.
struct DailyPaceView: View {
    /// Bar thickness. 7 suits the widget's compact card; the dashboard passes a fatter bar, where the
    /// same 7pt reads as a hairline next to figures three times the size.
    var barThickness: CGFloat = 9

    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private var unit: BudgetUnit { metrics.budgetUnit }
    private var todayValue: Double { metrics.dailyTodayValue(unit: unit) }
    private var average: Double { metrics.dailyAverage(unit: unit) }
    private var fraction: Double { metrics.dailyPaceFraction(unit: unit) }
    private var hasHistory: Bool { metrics.hasDailyHistory() && average > 0 }
    private var overAverage: Bool { metrics.dailyPaceExceedsAverage(unit: unit) }

    private func amount(_ v: Double) -> String {
        unit == .tokens ? Format.tokens(Int(v)) : Format.currency(v)
    }

    private var help: String {
        """
        Today's usage compared with your recent daily average. There's no daily limit, so this is \
        a pace check, not a budget: a usual day fills the bar, so the bar and the "today %" beside \
        it always say the same thing. A day heavier than usual fills it completely and turns \
        coral — the % is then the one to read, since it keeps going past 100%.

        "A usual day" is the average over your last 30 days that had any usage — days you didn't \
        use Claude don't count as light days, they just don't count. It's a rolling window, so the \
        baseline follows how you work now rather than being diluted by months of older history, \
        and unlike the weekly limit above it nothing resets it. Today itself is never counted \
        into its own average. Local data only — no token, no network.
        """
    }

    var body: some View {
        // Bound once. Each of these re-derives from `allTimeDaily` on every read, and the body
        // referenced them eight times between them — `overAverage` twice, `fraction` three times,
        // `average` three — so a single pass did the same scan eight times. The array is one entry
        // per *active day* (81 on the developer's machine), so this is legibility rather than a
        // measurable saving; it is not a performance claim.
        let todayValue = self.todayValue
        let average = self.average
        let fraction = self.fraction
        let overAverage = self.overAverage
        let hasHistory = metrics.hasDailyHistory() && average > 0

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(amount(todayValue))
                    .scaledFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.gaugeTrack(overAverage ? 1 : fraction))
                    // Full bar == a usual day, so the fill always agrees with the "today N%" beside it.
                    // Past a usual day it pins full; the ramp is what says how far past — the caption's
                    // % gives the number. Same palette ramp as the two gauges above, so "hotter" means
                    // the same thing on all three bars.
                    // `fraction` pins at 1 once today passes a usual day, so `overAverage` is what
                    // carries "past it" into the ramp's top stop.
                    Capsule().fill(Theme.gaugeFill(overAverage ? 1 : fraction))
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: barThickness * scale)

            HStack(spacing: 4) {
                if hasHistory {
                    Text("\(amount(average))/day avg · today \(Int((todayValue / average * 100).rounded()))%")
                } else {
                    Text("building daily average…")
                }
                Spacer()
            }
            .scaledFont(9.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
        .help(help)
    }
}
