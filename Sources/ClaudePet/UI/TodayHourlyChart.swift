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
        let barMax = (fillsHeight ? 30 : 24) * scale
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
            ViewThatFits(in: .horizontal) {
                header(withCaption: true)
                header(withCaption: false)
            }
            if fillsHeight {
                GeometryReader { g in
                    bars(hours, maxV: maxV, currentHour: currentHour, barArea: max(8, g.size.height))
                }
                .frame(minHeight: barMax)
            } else {
                bars(hours, maxV: maxV, currentHour: currentHour, barArea: barMax)
            }
            HStack(spacing: 0) {
                Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p")
            }
            .scaledFont(7).foregroundStyle(Theme.textSecondary)
            if !fillsHeight {
                Text(caption)
                    .scaledFont(9.5).lineLimit(1)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .help("Today's usage by local hour — when in the day you've been working. Local data only.")
    }

    private func header(withCaption: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
            Text("Today by hour").scaledFont(fillsHeight ? 11 : 10, weight: .semibold)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            if fillsHeight && withCaption {
                Text(caption).scaledFont(9)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 4 * scale)
            Text(amount(value(from: metrics.today)))
                .scaledFont(fillsHeight ? 21 : 9.5,
                            weight: fillsHeight ? .bold : .regular, design: .rounded)
                .foregroundStyle(fillsHeight ? Theme.textPrimary : Theme.textTertiary)
                .fixedSize()
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

    /// Short in the dashboard: this card sits in a narrow column there, and "most active ~4p" beside
    /// the title and a hero figure truncated to "most active ~…" — which says nothing at all.
    private var caption: String {
        guard let h = metrics.peakHour(unit: unit) else {
            return fillsHeight ? "no activity" : "no activity yet today"
        }
        return (fillsHeight ? "peak ~" : "most active ~") + Format.hourLabel(h)
    }
}
