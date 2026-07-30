import SwiftUI
import ClaudePetCore

/// One bar per calendar date of the current billing cycle — the long view the little widget has no
/// room for. Follows `WeeklyBarChart`'s shape (gauge unit, work/total basis, today highlighted,
/// future days dimmed), but labels by DATE rather than weekday, because a cycle is 28–31 days long.
///
/// The bars sum exactly to the `Cycle` figure: `Aggregator` buckets them with the same in-cycle
/// predicate that produces the headline total.
struct CycleDailyChart: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private func value(_ d: DayTotal) -> Double {
        metrics.budgetUnit == .usd ? d.costUSD : Double(metrics.dayTokens(d))
    }

    private func amount(_ v: Double) -> String {
        metrics.budgetUnit == .usd ? Format.currency(v) : Format.tokens(Int(v))
    }

    private var chartHelp: String {
        let basis = metrics.budgetUnit == .usd ? "Cost" : "\(metrics.tokenBasisLabel.capitalized) tokens"
        return """
            \(basis) per day across the current billing cycle, so these bars add up to the Cycle \
            figure exactly. The first and last bars are part-days — a cycle starts and ends on your \
            subscription's anniversary time, not at midnight — so they can look short. Today is \
            highlighted; days still to come are empty.
            """
    }

    var body: some View {
        let days = metrics.cycleDaily
        let now = Date()
        let cal = Calendar.current
        let maxV = max(days.map(value).max() ?? 1, 1)
        let barMax = 42 * scale        // floor only — the bars stretch past this to fill the card

        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 6 * scale) {
                Text("This billing cycle, by day").scaledFont(11, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                if let start = metrics.cycleStart, let end = metrics.cycleReset {
                    Text(start.formatted(.dateTime.month(.abbreviated).day())
                         + " – " + end.formatted(.dateTime.month(.abbreviated).day()))
                        .scaledFont(9).foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                Spacer()
                // The figure is the cycle TOTAL, so it must not sit next to a "/day" caption the
                // way `WeeklyBarChart`'s does — "3M work/day" reads as a rate. Name the basis
                // instead, exactly as the header does ("142k work").
                Text(amount(metrics.budgetUnit == .usd
                            ? metrics.cycle.costUSD
                            : Double(metrics.totalsTokens(metrics.cycle))))
                    .scaledFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(Theme.textPrimary)
                if metrics.budgetUnit == .tokens {
                    Text(metrics.tokenBasisLabel)
                        .scaledFont(9).foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
            }

            if days.isEmpty {
                Text("no cycle data yet")
                    .scaledFont(10).foregroundStyle(Theme.textSecondary.opacity(0.7))
            } else {
                // The bars take whatever height the card is given rather than a fixed `barMax`, so
                // this chart absorbs the window's spare vertical space. It's the one panel worth
                // growing on a large display — the alternative left ~180pt of dead air inside the
                // mascot card instead, which reads as unfinished rather than spacious.
                GeometryReader { g in
                    let labelRow = 13 * scale
                    let barArea = max(16, g.size.height - labelRow - 3 * scale)
                    HStack(alignment: .bottom, spacing: 2 * scale) {
                        ForEach(days) { day in
                            let isToday = cal.isDate(day.date, inSameDayAs: now)
                            let notStarted = day.date > now
                            VStack(spacing: 3 * scale) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(isToday ? Theme.claudeCoral
                                                  : Theme.claudeCoral.opacity(notStarted ? 0.10 : 0.42))
                                    .frame(height: max(2, CGFloat(value(day) / maxV) * barArea))
                                // Every date would be unreadable at 30 bars; label the 1st and every 5th.
                                Text(dayLabel(day.date, calendar: cal))
                                    .scaledFont(7.5)
                                    .foregroundStyle(isToday ? Theme.claudeCoral
                                                             : Theme.textSecondary.opacity(0.55))
                            }
                            .frame(maxWidth: .infinity)
                            .help("\(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): "
                                  + amount(value(day)))
                        }
                    }
                }
                .frame(minHeight: barMax + 16 * scale)
            }
        }
        .help(chartHelp)
    }

    /// Sparse date labels: day-of-month on the 1st and every 5th, blank elsewhere. Uses a
    /// non-breaking space rather than "" so every bar reserves the same label height and the
    /// bar baselines stay aligned.
    private func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let d = calendar.component(.day, from: date)
        return (d == 1 || d % 5 == 0) ? "\(d)" : "\u{00A0}"
    }
}
