import SwiftUI
import ClaudePetCore

/// A 24-bar "today by hour" sparkline (all models combined) — shows *when* in the day you worked.
/// Pairs with the day-level `WeeklyBarChart`; uses the selected gauge unit and highlights the
/// current hour. All data is the already-scanned local `todayHourly` series (no token, no network).
struct TodayHourlyChart: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private var unit: BudgetUnit { metrics.budgetUnit }

    private func value(_ h: HourTotal) -> Double {
        unit == .usd ? h.costUSD : Double(h.workTokens)
    }

    private func amount(_ v: Double) -> String {
        unit == .usd ? Format.currency(v) : Format.tokens(Int(v))
    }

    var body: some View {
        let hours = metrics.todayHourly
        let maxV = max(hours.map(value).max() ?? 1, 1)
        let barMax = 24 * scale
        let currentHour = Calendar.current.component(.hour, from: Date())

        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text("Today by hour").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(amount(value(from: metrics.today)))
                    .scaledFont(9.5).foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
            HStack(alignment: .bottom, spacing: 1.5 * scale) {
                ForEach(hours) { hour in
                    let isNow = hour.hour == currentHour
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(isNow ? Theme.claudeCoral : Theme.claudeCoral.opacity(0.40))
                        .frame(height: max(1, CGFloat(value(hour) / maxV) * barMax))
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 0) {
                Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p")
            }
            .scaledFont(7).foregroundStyle(Theme.textSecondary.opacity(0.7))
            Text(caption)
                .scaledFont(9.5).lineLimit(1)
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .help("Today's usage by local hour — when in the day you've been working. Local data only.")
    }

    /// Today's total in the gauge's unit, matching the header / daily-pace figure.
    private func value(from t: Totals) -> Double {
        unit == .usd ? t.costUSD : Double(t.workTokens)
    }

    private var caption: String {
        if let h = metrics.peakHour(unit: unit) {
            return "most active ~\(Format.hourLabel(h))"
        }
        return "no activity yet today"
    }
}
