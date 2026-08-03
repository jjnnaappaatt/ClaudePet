import SwiftUI
import ClaudePetCore

/// How much of each day you delegated — the subagent slice as a **share of that day**, on a fixed
/// 0…100% axis, over the same fixed Sunday-to-Saturday calendar week `WeeklyBarChart` uses (see its
/// doc comment) rather than the weekly usage-limit window.
///
/// **The fixed axis is the whole point, and it replaced a second bar chart.** For one build this was
/// `WeeklyBarChart(series: .subagents)`: the same mark, the same seven slots, sitting beside the total
/// chart. Each instance normalises to its own `maxV`, so Tuesday's subagent bar stood exactly as tall
/// as Tuesday's total bar while being ~6× smaller. Two identical marks side by side invite that
/// comparison, and putting them in separate boxes made it worse rather than better.
///
/// A share has no free maximum, so there is nothing left to misread: the track is the whole day, the
/// fill is the part the Task tool ran, and the number says which. It is also a genuinely different
/// question from "how much did I use each day", which is what earns it its own card.
///
/// **Not the gauge ramp.** Every ramped bar in this app means "close to a limit", and a
/// heavy-delegation day is not a warning — the same argument that made `SubagentPaceView` a pace
/// rather than a share. So the fill reuses `WeeklyBarChart`'s coral states and the track reuses
/// `ProjectBreakdownView`'s neutral row track, and nothing here recolours with the value.
struct SubagentShareChart: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    /// Height below the bars: the weekday letter, and nothing else.
    ///
    /// It was 21 — a letter row *and* a percentage row. Moving the percentage inside the slot buys
    /// back that 10·scale for the bars, and lands this axis on exactly the same baseline as
    /// `WeeklyBarChart`'s beside it; with two rows here the two cards' axes sat a line apart.
    private var axisHeight: CGFloat { 11 * scale }

    /// The basis is load-bearing, not decoration: subagent turns are ~15% of *work* but ~8% of
    /// cache-inclusive *total*, so the same week reads very differently under the two settings. In
    /// `$` mode there is no per-day cost split for the slice, so the share stays measured on tokens
    /// and the caption stops naming a basis rather than naming a wrong one.
    private var caption: String {
        metrics.budgetUnit == .usd ? "% of each day" : "% of \(metrics.tokenBasisLabel)"
    }

    /// `metrics.calendarWeek`, not `metrics.week` — the same fixed Sunday-to-Saturday span the bars
    /// below sum over. Reading the rate-limit `week` here instead would print a percentage for one
    /// window over bars drawn from a different one, in the same card.
    private var weekShare: String {
        let pct = Int((metrics.sidechainShare(metrics.calendarWeek) * 100).rounded())
        return "\(pct)% this week"
    }

    private var chartHelp: String {
        """
        The share of each day that ran under the Task tool — subagents and workflow agents. The full \
        track is the whole day; the filled part is what was delegated. A fixed 0–100% scale, so \
        unlike a magnitude chart it can't be misread against This week beside it.

        Measured on \(metrics.tokenBasisLabel) tokens, and that matters: a subagent works in a \
        short-lived context while the main conversation re-reads a large cached one every turn, so \
        the same day is a bigger share of "work" than of cache-inclusive "total" — about 15% versus \
        8% here. In $ mode the share is still measured on tokens, because there is no per-day cost \
        split for these turns. Turn "Include subagent usage" off in Settings and they leave every \
        figure in the app.
        """
    }

    var body: some View {
        let days = metrics.calendarWeekDaily
        let now = Date()

        VStack(alignment: .leading, spacing: 4 * scale) {
            header
            // With "Include subagent usage" off, `recompute` filters sidechain entries out of the
            // aggregation entirely (`MetricsStore.recompute`), so every slot is a truthful 0% — and
            // seven empty tracks reading "0%" is indistinguishable from a week where you happened not
            // to delegate. Say which, the way the pace bar above does.
            if metrics.includeSubagents {
                GeometryReader { g in
                    slots(days, now: now, area: max(10, g.size.height - axisHeight))
                }
                .frame(minHeight: 30 * scale + axisHeight)
            } else {
                Text("not counted — see Settings")
                    .scaledFont(10).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
        }
        // Same reason as the other two charts: the axis sat hard against the card's bottom edge,
        // which reads as clipped rather than as finished. The card's padding is unscaled, so this is
        // the only lever that grows with the layout.
        .padding(.bottom, 4 * scale)
        .help(chartHelp)
    }

    /// Title, unit, then the week's own share on the right — the one figure this card knows that
    /// nothing else on the page prints. Same shape as the hour chart's "peak ~9am".
    ///
    /// **`ViewThatFits`, because `.fixedSize()` text does not stay inside its card.** This card is
    /// pinned to an exact half of its column, and `.frame(width:)` doesn't clip: three `fixedSize`
    /// runs need ~315pt against ~280pt of usable width, so SwiftUI centred the overflow and drew the
    /// title straight off the left edge of the *window*. Nothing errored, and at a wider size it
    /// looks perfect — which is exactly the failure this layout keeps producing. Dropping the week
    /// share whole is the right degradation; a clipped "22% this we…" says less than nothing. Same
    /// pattern as the billing calendar's legend.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(withWeekShare: true)
            headerRow(withWeekShare: false)
        }
    }

    private func headerRow(withWeekShare: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
            Text("Subagents/day").scaledFont(13.5, weight: .semibold)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
            Text(caption)
                .scaledFont(10).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4 * scale)
            if withWeekShare && metrics.includeSubagents {
                Text(weekShare)
                    .scaledFont(10).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    private func slots(_ days: [DayTotal], now: Date, area: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 5 * scale) {
            ForEach(days) { day in
                let isNow = metrics.isCurrentDayBucket(day, now: now)
                let notStarted = day.date > now
                let hasData = metrics.dayTokens(day) > 0
                let share = metrics.daySidechainShare(day)
                let fillH: CGFloat = share > 0 ? max(2, CGFloat(share) * area) : 0
                // The label rides the top of the FILL, not the top of the track — so it reads as
                // that bar's own figure and rises with the day. Clamped so a near-100% day doesn't
                // push it out of the slot: past the clamp it sits on top of the coral instead of
                // above it, which is why the colour has to work on both layers.
                let labelH: CGFloat = 12 * scale
                let labelLift = min(fillH + 3 * scale, max(0, area - labelH))
                VStack(spacing: 2 * scale) {
                    ZStack(alignment: .bottom) {
                        // The track is the day. Drawn at full height for every slot including the
                        // ones still to come, so the axis reads as seven days rather than stopping
                        // at today — the same reasoning as the weekday letters below it.
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                        // No `max(2, …)` floor here, unlike the bar charts. A floor would draw a
                        // stub for a day that delegated nothing, which is a different statement
                        // from "a very small share" — and on a share axis the reader can tell.
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(isNow ? Theme.claudeCoral
                                        : Theme.claudeCoral.opacity(notStarted ? 0.12 : 0.40))
                            .frame(height: fillH)
                        // The figure sits just above its own bar. It was centred first (it floated
                        // in an empty track with the bar far below, and mid-range fills cut through
                        // the digits), then pinned to the top of the track (one tidy row, but a
                        // 7% day labelled 100pt above the 7% bar). Riding the fill keeps the number
                        // and the thing it measures in the same glance.
                        //
                        // `textPrimary` is white at 0.95 and clears 4.5:1 against both the near-black
                        // track and the coral fill, so it needs no branch on share — which is
                        // load-bearing once the clamp puts it *on* the coral near 100%.
                        //
                        // "0%" and "–" are different facts: a day that ran turns and delegated none
                        // of them, versus a day with nothing in it at all.
                        Text(hasData ? "\(Int((share * 100).rounded()))%" : "–")
                            // NOT `scaledFont`, deliberately: that floors at `minScaledFont` (12 on
                            // the dashboard), and a floor is the wrong tool inside a ~34pt slot.
                            //
                            // **The declared size was not the rendered size**, which is why this
                            // number looks arbitrary. Floored to 12 and scaled, this asked for
                            // 16.65pt — far too wide for the slot — so `minimumScaleFactor` quietly
                            // shrank it to ~14pt to fit. Declaring 15% off the *floor* therefore
                            // changed the picture by 3%, because the floor was never what you were
                            // seeing. 8.6 is 15% off the 14pt that was actually being drawn, and it
                            // fits without shrinking, so from here the declared size is the real one.
                            // Measured from rendered pixels: "48%" 32 → 27px wide, cap 11 → 9px.
                            .font(.system(size: 8.6 * scale, weight: .semibold))
                            .foregroundStyle(notStarted ? Theme.textTertiary : Theme.textPrimary)
                            // Shrink rather than truncate: "100%" is the widest case and a clipped
                            // percentage is worse than a small one.
                            .lineLimit(1).minimumScaleFactor(0.65)
                            .padding(.bottom, labelLift)
                    }
                    .frame(height: area)
                    Text(Format.weekdayLabel(for: day.date))
                        .scaledFont(7)
                        .foregroundStyle(isNow ? Theme.claudeCoral
                                               : (notStarted ? Theme.textTertiary : Theme.textSecondary))
                }
                .frame(maxWidth: .infinity)
                .help(dayHelp(day, share: share, hasData: hasData))
            }
        }
    }

    private func dayHelp(_ day: DayTotal, share: Double, hasData: Bool) -> String {
        let date = day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard hasData else { return "\(date): no usage" }
        let part = Format.tokens(metrics.daySidechainTokens(day))
        let whole = Format.tokens(metrics.dayTokens(day))
        return "\(date): \(Int((share * 100).rounded()))% delegated — "
            + "\(part) of \(whole) \(metrics.tokenBasisLabel)"
    }
}
