import SwiftUI
import ClaudePetCore

/// A 7-bar "this week" chart (all models combined), like the Screen Time widget.
/// One bar per weekday of the weekly-limit window, so they sum to the figure the weekly bar shows
/// while still being real weekdays; reset day's bar holds only the parts inside the window.
/// Values follow the gauge unit ($ or tokens) and the work/total basis; today is highlighted and
/// days still to come are dimmed.
struct WeeklyBarChart: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private static let dayLetter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f   // single-letter weekday
    }()

    private func value(_ d: DayTotal) -> Double {
        metrics.budgetUnit == .usd ? d.costUSD : Double(metrics.dayTokens(d))
    }

    private var caption: String {
        if metrics.budgetUnit == .usd { return "$/day" }
        return metrics.tokenBasis == .total ? "total/day" : "work/day"
    }

    private var chartHelp: String {
        let basis = metrics.budgetUnit == .usd ? "Cost" : "\(metrics.tokenBasisLabel.capitalized) tokens"
        return """
            \(basis) per day across the current weekly-limit window, so these bars add up to the \
            weekly figure above rather than to a rolling seven days. Reset day counts only the \
            hours inside the window, so its bar can look short. Today is highlighted; days still \
            to come are dimmed.
            """
    }

    var body: some View {
        let days = metrics.weekDaily
        let now = Date()
        let maxV = max(days.map(value).max() ?? 1, 1)
        let barMax = 30 * scale

        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text("This week").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(caption)
                    .scaledFont(8.5).foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
            HStack(alignment: .bottom, spacing: 5 * scale) {
                ForEach(days) { day in
                    // Not `idx == days.count - 1` any more: the last bar is the end of the
                    // weekly window, which mid-week is still in the future.
                    let isNow = metrics.isCurrentDayBucket(day, now: now)
                    let notStarted = day.date > now
                    VStack(spacing: 2 * scale) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(isNow ? Theme.claudeCoral
                                        : Theme.claudeCoral.opacity(notStarted ? 0.12 : 0.40))
                            .frame(height: max(2, CGFloat(value(day) / maxV) * barMax))
                        Text(Self.dayLetter.string(from: day.date))
                            .scaledFont(7)
                            .foregroundStyle(isNow ? Theme.claudeCoral
                                                   : Theme.textSecondary.opacity(notStarted ? 0.3 : 0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .help(chartHelp)
    }
}
