import SwiftUI
import ClaudePetCore

/// A 7-bar "this week" chart (all models combined), like the Screen Time widget.
/// One bar per weekday of the weekly-limit window, so they sum to the figure the weekly bar shows
/// while still being real weekdays; reset day's bar holds only the parts inside the window.
/// Values follow the gauge unit ($ or tokens) and the work/total basis; today is highlighted and
/// days still to come are dimmed.
///
/// The subagent slice of the same seven days is **not** a second instance of this view. It was, for
/// exactly one build: `Series {total, subagents}` selecting the value and the title. Two identical
/// marks side by side each normalising to their own `maxV` made Tuesday's subagent bar stand as tall
/// as Tuesday's total bar while being ~6× smaller — the comparison the eye makes is the one the chart
/// invites. `SubagentShareChart` draws a different mark on a fixed 0…100% axis instead.
struct WeeklyBarChart: View {
    /// Let the bars grow into whatever height the container gives them. Off in the widget, where the
    /// card is sized from its content and a fixed bar height is what keeps it compact; on in the
    /// dashboard, where this chart shares a row with a taller card.
    var fillsHeight = false

    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

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
        let barMax = (fillsHeight ? 30 : 40) * scale

        VStack(alignment: .leading, spacing: 4 * scale) {
            // Same header shape as `TodayHourlyChart` in the dashboard: title, unit caption, then the
            // window's own total as a hero figure. Two chart cards sitting in one column looked
            // unbalanced when only one of them carried a number.
            header()
            if fillsHeight {
                GeometryReader { g in
                    bars(days, maxV: maxV, now: now,
                         barArea: max(10, g.size.height - 11 * scale))
                }
                .frame(minHeight: barMax + 11 * scale)
            } else {
                bars(days, maxV: maxV, now: now, barArea: barMax)
            }
        }
        // Same reason as the hour chart: the weekday letters were touching the card's bottom edge.
        .padding(.bottom, 4 * scale)
        .help(chartHelp)
    }

    /// No total on the right. It used to carry the window's own figure, but that is the same number
    /// the weekly gauge prints as "13.6M work used this week" and the footer prints as "Week 13.6M" —
    /// three copies of one value on one screen. The unit caption stays, because the bars are unreadable
    /// without knowing whether they are dollars or tokens.
    private func header() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
            Text("This week").scaledFont(fillsHeight ? 13.5 : 12, weight: .semibold)
                .foregroundStyle(fillsHeight ? Theme.textPrimary : Theme.textSecondary)
                .fixedSize()
            Text(caption)
                .scaledFont(fillsHeight ? 10 : 10.5).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 0)
        }
    }

    /// `barArea` is the height the tallest bar gets. Fixed in the widget; in the dashboard it's the
    /// card's spare height, so the chart fills its column instead of leaving a void beneath it.
    private func bars(_ days: [DayTotal], maxV: Double, now: Date, barArea: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 5 * scale) {
            ForEach(days) { day in
                // Not `idx == days.count - 1` any more: the last bar is the end of the
                // weekly window, which mid-week is still in the future.
                let isNow = metrics.isCurrentDayBucket(day, now: now)
                let notStarted = day.date > now
                VStack(spacing: 2 * scale) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isNow ? Theme.claudeCoral
                                    : Theme.claudeCoral.opacity(notStarted ? 0.12 : 0.40))
                        .frame(height: max(2, CGFloat(value(day) / maxV) * barArea))
                    // The BAR dims for a day that hasn't started; the LETTER doesn't. It was
                    // `textSecondary.opacity(0.3)` — 0.21 absolute, 1.8:1, invisible — so the axis
                    // simply stopped after today. Which weekday a slot is has to stay readable
                    // whether or not it has usage yet.
                    Text(Format.weekdayLabel(for: day.date))
                        .scaledFont(7)
                        .foregroundStyle(isNow ? Theme.claudeCoral
                                               : (notStarted ? Theme.textTertiary : Theme.textSecondary))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
