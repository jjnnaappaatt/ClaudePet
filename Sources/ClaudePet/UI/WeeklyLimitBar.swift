import SwiftUI
import ClaudePetCore

/// Weekly (7-day, all models) usage bar — mirrors the Claude app's "Weekly limits".
/// Local estimate: the real cap is server-side, so the budget is editable/calibratable.
struct WeeklyLimitBar: View {
    /// Bar thickness. 7 suits the widget's compact card; the dashboard passes a fatter bar, where the
    /// same 7pt reads as a hairline next to figures three times the size.
    var barThickness: CGFloat = 9

    @Environment(MetricsStore.self) private var metrics

    private var unit: BudgetUnit { metrics.budgetUnit }
    private var fraction: Double { metrics.weeklyFraction(unit: unit) }

    /// One flat colour for the whole bar, from the statusline's ramp — see `Theme.gaugeFill`.
    private var barFill: Color { Theme.gaugeFill(fraction) }

    private func amount(_ v: Double) -> String {
        unit == .tokens ? Format.tokens(Int(v)) : Format.currency(v)
    }

    /// Names the unit on the "used" line so it can't be misread as the other basis. Tokens only —
    /// in $ mode the figure is currency and a work/total word would be meaningless.
    private var basisSuffix: String { unit == .tokens ? " \(metrics.tokenBasisLabel)" : "" }

    /// Server-driven → Claude's real weekly number; otherwise approximate, named by basis.
    private var limitHelp: String {
        if metrics.serverDriven7d {
            // One interpolated literal, not a `+` chain — the concatenation blew up the
            // type-checker ("unable to type-check this expression in reasonable time").
            let age = metrics.serverDataAge.map { " (as of \($0))" } ?? ""
            return """
                Claude's real 7-day usage, via the statusline cache\(age). ClaudePet reads only \
                the local file — no token, no network. The % is Claude's own accounting; the count \
                below is ClaudePet's \(metrics.tokenBasisLabel)-token sum from your own transcripts, \
                so the two aren't the same measurement. Change the basis in Settings → Appearance.
                """
        }
        return "Fixed 7-day window that resets to zero on a schedule (like the Claude app). "
            + "The % is measured against \(metrics.budgetBasisDescription(for: .weekly))."
            + (metrics.lastCalibratedAt != nil && metrics.calibrationIsStale
               ? " A limit reset since you calibrated; re-calibrate in Settings to re-align." : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Weekly (all models)").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                if metrics.serverDriven7d {
                    Text("live").scaledFont(7.5, weight: .bold)
                        .padding(.horizontal, 3).padding(.vertical, 0.5)
                        .background(Theme.highlight.opacity(0.22), in: Capsule())
                        .foregroundStyle(Theme.highlight)
                }
                Spacer()
                Text("\(metrics.serverDriven7d ? "" : "~")\(Int((fraction * 100).rounded()))%")
                    .scaledFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.gaugeTrack(fraction))
                    Capsule().fill(barFill).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: barThickness * scale)

            Group {
                if metrics.serverDriven7d {
                    // Drops words rather than truncating: beside a long "resets in 5d 22h" the full
                    // line read "8.8M work used this…" in the landscape widget. Whole rows are the
                    // candidates, not just the text, so each is measured against the reset it sits
                    // beside. The last keeps only the figure and must always fit.
                    let used = "\(amount(metrics.weeklyTokensUsed(unit: unit)))\(basisSuffix)"
                    ViewThatFits(in: .horizontal) {
                        usedRow { Text("\(used) used this week") }
                        usedRow { Text("\(used) this week") }
                        usedRow { Text(used) }
                    }
                } else {
                    usedRow {
                        Text("\(amount(metrics.weeklyValue(unit: unit))) / \(amount(metrics.weeklyBudget(unit: unit)))")
                        Text("·").foregroundStyle(Theme.textFaint)
                        Text("\(amount(metrics.weeklyRemaining(unit: unit))) left")
                            .foregroundStyle(Theme.highlight.opacity(0.9))
                    }
                }
            }
            .scaledFont(9.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
        .help(limitHelp + metrics.sidechainNote(metrics.week))
    }

    /// The "used" figure on the left, the reset countdown on the right.
    private func usedRow<Used: View>(@ViewBuilder _ used: () -> Used) -> some View {
        HStack(spacing: 4) {
            used()
            Spacer()
            if let reset = metrics.weeklyResetDate {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("resets in \(Format.durationLong(reset.timeIntervalSince(context.date)))")
                }
            } else {
                Text("7-day · est.")
            }
        }
    }

    @Environment(\.widgetScale) private var scale: CGFloat
}
