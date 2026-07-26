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
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private var unit: BudgetUnit { metrics.budgetUnit }
    private var todayValue: Double { metrics.dailyTodayValue(unit: unit) }
    private var average: Double { metrics.dailyAverage(unit: unit) }
    private var fraction: Double { metrics.dailyPaceFraction(unit: unit) }

    private func amount(_ v: Double) -> String {
        unit == .tokens ? Format.tokens(Int(v)) : Format.currency(v)
    }

    private var help: String {
        """
        Today's usage compared with your recent daily average. There's no daily limit — the \
        average day sits at the bar's midpoint, so a full bar is roughly twice a usual day. Days \
        come from the chart below, which covers the weekly-limit window, so on reset day this \
        counts only the part since the reset. Local data only — no token, no network.
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
                    Capsule().fill(Theme.highlight).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 7 * scale)

            HStack(spacing: 4) {
                if metrics.hasDailyHistory() {
                    Text("\(amount(average))/day avg this week")
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
