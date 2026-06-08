import SwiftUI
import ClaudePetCore

/// A 7-day "this week" bar chart (all models combined), like the Screen Time widget.
/// Bars use the selected gauge unit (work tokens or US$); today is highlighted.
struct WeeklyBarChart: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private static let dayLetter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f   // single-letter weekday
    }()

    private func value(_ d: DayTotal) -> Double {
        metrics.budgetUnit == .usd ? d.costUSD : Double(d.workTokens)
    }

    var body: some View {
        let days = metrics.weekDaily
        let maxV = max(days.map(value).max() ?? 1, 1)
        let barMax = 30 * scale

        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text("This week").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(metrics.budgetUnit == .usd ? "$/day" : "work/day")
                    .scaledFont(8.5).foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
            HStack(alignment: .bottom, spacing: 5 * scale) {
                ForEach(Array(days.enumerated()), id: \.element.id) { idx, day in
                    let isToday = idx == days.count - 1
                    VStack(spacing: 2 * scale) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(isToday ? Theme.claudeCoral : Theme.claudeCoral.opacity(0.40))
                            .frame(height: max(2, CGFloat(value(day) / maxV) * barMax))
                        Text(Self.dayLetter.string(from: day.date))
                            .scaledFont(7)
                            .foregroundStyle(isToday ? Theme.claudeCoral : Theme.textSecondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
