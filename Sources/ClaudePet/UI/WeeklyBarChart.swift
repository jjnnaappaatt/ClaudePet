import SwiftUI
import ClaudePetCore

/// A 7-bar "this week" chart (all models combined), like the Screen Time widget.
/// One bar per weekday of a **fixed Sunday-to-Saturday calendar week** — deliberately independent
/// of the weekly usage-LIMIT window (`WeeklyLimitBar`, the "Week" footer figure), which keeps its
/// own real reset schedule synced from Claude's servers. Since the calendar-week boundary is exact
/// local midnight at both ends, a calendar day's tokens always land in exactly one bar; there is no
/// reset-day split to fold. Values follow the gauge unit ($ or tokens) and the work/total basis;
/// today is highlighted and days still to come are dimmed.
///
/// The subagent slice of the same seven days is **not** a second instance of this view. It was, for
/// exactly one build: `Series {total, subagents}` selecting the value and the title. Two identical
/// marks side by side each normalising to their own `maxV` made Tuesday's subagent bar stand as tall
/// as Tuesday's total bar while being ~6× smaller — the comparison the eye makes is the one the chart
/// invites. `SubagentShareChart` draws a different mark on a fixed 0…100% axis instead.
struct WeeklyBarChart: View {
    /// Let the bars grow into whatever height the container gives them, with no ceiling. On in the
    /// dashboard, where this chart shares a row with a taller card; off in the widget, whose card is
    /// sized from its own content. It also carries the dashboard's typography — see `header()`.
    var fillsHeight = false

    /// How much taller than `barMax` the bars may grow when their column has height to spare, in
    /// unscaled points (multiplied by `scale`, same convention as the pace bars' `barThickness`).
    /// 0 = never.
    ///
    /// `landscapeStack`'s case, and it is neither of the other two: that card is sized from its
    /// content, but its height is set by the OTHER column, so the slack exists whether or not this
    /// chart wants it. Capped rather than free because the two columns' heights both swing with the
    /// data (0–2 Codex rows, 1–5 model families), and an uncapped chart in the lopsided direction
    /// would draw bars taller than the mascot.
    var growth: CGFloat = 0

    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    /// Height below the bars: the weekday letter and the gap above it. Same name and shape as
    /// `SubagentShareChart.axisHeight`, which sits beside this chart in the dashboard and has to land
    /// its own axis on the same baseline.
    private var axisHeight: CGFloat { 11 * scale }

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
            \(basis) per day across a fixed Sunday-to-Saturday calendar week — independent of the \
            weekly usage-limit window shown elsewhere, so a calendar day's usage always lands in \
            exactly one bar and never straddles two weeks. Today is highlighted; days still to \
            come are dimmed.
            """
    }

    var body: some View {
        let days = metrics.calendarWeekDaily
        let now = Date()
        let maxV = max(days.map(value).max() ?? 1, 1)
        let barMax = (fillsHeight ? 30 : 40) * scale

        VStack(alignment: .leading, spacing: 4 * scale) {
            // Same header shape as `TodayHourlyChart` in the dashboard: title, unit caption, then the
            // window's own total as a hero figure. Two chart cards sitting in one column looked
            // unbalanced when only one of them carried a number.
            header()
            if fillsHeight || growth > 0 {
                // One branch for both growing modes; `maxHeight: nil` is what "no ceiling" means to
                // `frame`, so the dashboard's call is unchanged by the widget gaining a cap.
                GeometryReader { g in
                    bars(days, maxV: maxV, now: now,
                         barArea: max(10, g.size.height - axisHeight))
                }
                .frame(minHeight: barMax + axisHeight,
                       maxHeight: fillsHeight ? nil : barMax + growth * scale + axisHeight)
            } else {
                // `.fixedSize` is a FIX, not a tidy-up. Each bar is `VStack { Spacer; bar; label }`
                // and a `Spacer` is vertically unbounded, so this view was the only flexible child of
                // `landscapeStack`'s left column — and a `VStack` hands its surplus to whatever is
                // flexible. The whole column's slack (the right column is the taller one) landed here
                // while `barArea` stayed pinned at `barMax`: the bars didn't grow into it, they were
                // pushed DOWN it, leaving ~124pt of void between this header and its own bars.
                //
                // `.fixedSize` rather than `.frame(height: barMax + axisHeight)` because the weekday
                // label is not 7pt — `\.minScaledFont` floors it at 10.5 in the widget and 12 in the
                // dashboard, so a frame constant would have to guess a number the layout already
                // knows. This measures it.
                bars(days, maxV: maxV, now: now, barArea: barMax)
                    .fixedSize(horizontal: false, vertical: true)
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
