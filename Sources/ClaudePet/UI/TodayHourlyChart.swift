import SwiftUI
import ClaudePetCore

/// A 24-bar "today by hour" sparkline (all models combined) — shows *when* in the day you worked.
/// Pairs with the day-level `WeeklyBarChart`; uses the selected gauge unit and highlights the
/// current hour. All data is the already-scanned local `todayHourly` series (no token, no network).
struct TodayHourlyChart: View {
    /// Let the bars grow into whatever height the container gives them — see `WeeklyBarChart`.
    var fillsHeight = false

    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private var unit: BudgetUnit { metrics.budgetUnit }

    private func value(_ h: HourTotal) -> Double {
        unit == .usd ? h.costUSD : Double(metrics.hourTokens(h))
    }

    private func amount(_ v: Double) -> String {
        unit == .usd ? Format.currency(v) : Format.tokens(Int(v))
    }

    var body: some View {
        let hours = metrics.todayHourly
        let maxV = max(hours.map(value).max() ?? 1, 1)
        let barMax = (fillsHeight ? 30 : 40) * scale
        let currentHour = Calendar.current.component(.hour, from: Date())

        VStack(alignment: .leading, spacing: 4 * scale) {
            // In the dashboard the peak-hour caption rides on the TITLE line and today's total becomes
            // a hero figure. That isn't decoration: the caption used to own a whole line of a card whose
            // bars already use `fillsHeight`, so folding it up hands that line straight to the bars.
            // The widget keeps both lines — its card is ~300pt wide and can't take a hero figure beside
            // a merged header without wrapping.
            // `ViewThatFits` rather than truncation: this card sits in a narrow column, and at 900pt
            // the caption clipped to "peak ~1…", which is worse than absent. Dropping it whole is the
            // right degradation — the peak hour is also readable off the bars themselves.
            header()
            if fillsHeight {
                GeometryReader { g in
                    bars(hours, maxV: maxV, currentHour: currentHour, barArea: max(8, g.size.height))
                }
                .frame(minHeight: barMax)
            } else {
                bars(hours, maxV: maxV, currentHour: currentHour, barArea: barMax)
            }
            // 0…24, not 12a/6a/12p/6p. The bars are 24 hourly buckets, so a 24-hour axis maps onto
            // them one-to-one; the 12-hour form made the reader translate before they could read the
            // shape. `24` closes the span rather than leaving the last bar's edge unlabelled.
            HStack(spacing: 0) {
                Text("0"); Spacer(); Text("6"); Spacer(); Text("12")
                Spacer(); Text("18"); Spacer(); Text("24")
            }
            .scaledFont(7).foregroundStyle(Theme.textSecondary)
            // The axis sat hard against the card's bottom edge, which read as clipped rather than as
            // finished. The card's own padding is unscaled, so this is the only lever that grows with
            // the layout.
            .padding(.bottom, 4 * scale)
        }
        .help("Today's usage by local hour — when in the day you've been working. Local data only.")
    }

    /// Title left, peak hour right — in **both** layouts now. The total used to sit on the right, but
    /// it is the same figure the Today gauge already prints one card away in the dashboard, and the
    /// same one the header prints in the widget. Repeating it twice in one view bought nothing, and
    /// the peak hour is the one thing this chart knows that nothing else does.
    private func header() -> some View {
        ViewThatFits(in: .horizontal) {
            headerRow(withCaption: true)
            headerRow(withCaption: false)
        }
    }

    /// The `ViewThatFits` is load-bearing, and the comment above claimed it long before the code had
    /// it. Both runs are `.fixedSize()`, and `.fixedSize()` text does not stay inside its frame: once
    /// this card was pinned to an explicit width, a header wider than the card centred its overflow
    /// and pushed the entire lower row off the left edge of the window. Dropping the caption whole is
    /// the right degradation — the peak hour is readable off the bars, and "peak ~1…" is not.
    private func headerRow(withCaption: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
            Text("Today by hour").scaledFont(fillsHeight ? 13.5 : 12, weight: .semibold)
                .foregroundStyle(fillsHeight ? Theme.textPrimary : Theme.textSecondary)
                .fixedSize()
            Spacer(minLength: 4 * scale)
            if withCaption {
                Text(caption)
                    .scaledFont(fillsHeight ? 10 : 10.5)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    /// `barArea` is the height the tallest bar gets — fixed in the widget, the card's spare height in
    /// the dashboard.
    private func bars(_ hours: [HourTotal], maxV: Double, currentHour: Int,
                      barArea: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 1.5 * scale) {
            ForEach(hours) { hour in
                let isNow = hour.hour == currentHour
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isNow ? Theme.claudeCoral : Theme.claudeCoral.opacity(0.40))
                    .frame(height: max(1, CGFloat(value(hour) / maxV) * barArea))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Today's total in the gauge's unit, matching the header / daily-pace figure.
    private func value(from t: Totals) -> Double {
        unit == .usd ? t.costUSD : Double(metrics.totalsTokens(t))
    }

    /// One phrase in both layouts. The widget used to say "most active ~9am" and the dashboard
    /// "peak ~9am" for the identical figure, which read as two different measurements.
    private var caption: String {
        guard let h = metrics.peakHour(unit: unit) else { return "no activity yet" }
        return "peak ~" + Format.hourLabel(h)
    }
}
