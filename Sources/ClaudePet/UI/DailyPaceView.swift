import SwiftUI
import ClaudePetCore

/// "Today" daily-pace bar — the current day's tokens (or $) relative to your recent daily average.
/// Claude has no daily limit, so this is informational, not a budget: the average day sits at
/// the bar's midpoint, so a full bar ≈ 2× a usual day. Sits beneath the 5h + weekly gauges.
///
/// "Today" is the same bucket the chart highlights — a calendar day clipped to the weekly window —
/// so this row and the chart's highlighted bar always agree. On reset day that means only the part
/// since the reset, which the tooltip says.
struct DailyPaceView: View {
    /// Bar thickness. 7 suits the widget's compact card; the dashboard passes a fatter bar, where the
    /// same 7pt reads as a hairline next to figures three times the size.
    var barThickness: CGFloat = 7

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
        coral — the % is then the one to read, since it keeps going past 100%. Days come from the \
        chart below, which covers the weekly-limit window, so on reset day this counts only the \
        part since the reset. Local data only — no token, no network.
        """
    }

    var body: some View {
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
                    Capsule().fill(Color.white.opacity(0.12))
                    // Full bar == a usual day, so the fill always agrees with the "today N%" beside it.
                    // Past a usual day it pins full; the ramp is what says how far past — the caption's
                    // % gives the number. Same palette ramp as the two gauges above, so "hotter" means
                    // the same thing on all three bars.
                    // `fraction` pins at 1 once today passes a usual day, so `overAverage` is what
                    // carries "past it" into the ramp's top stop.
                    Capsule().fill(Theme.gaugeColor(overAverage ? 1 : fraction))
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
