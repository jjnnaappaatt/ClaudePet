import SwiftUI
import ClaudePetCore

/// The 5-hour block gauge: progress toward the user's budget (tokens or US$),
/// plus burn rate and a LIVE reset countdown. Approximation of the rolling-window limit.
struct BudgetGauge: View {
    /// Bar thickness. 7 suits the widget's compact card; the dashboard passes a fatter bar, where the
    /// same 7pt reads as a hairline next to figures three times the size.
    var barThickness: CGFloat = 9

    @Environment(MetricsStore.self) private var metrics

    private var unit: BudgetUnit { metrics.budgetUnit }
    private var fraction: Double { metrics.blockFraction(unit: unit) }

    /// One flat colour for the whole bar, from the statusline's ramp — see `Theme.gaugeFill`.
    private var barFill: Color { Theme.gaugeFill(fraction) }

    private func amount(_ value: Double) -> String {
        unit == .tokens ? Format.tokens(Int(value)) : Format.currency(value)
    }

    /// Names the unit on the "used" line so it can't be misread as the other basis. Tokens only —
    /// in $ mode the figure is currency and a work/total word would be meaningless.
    private var basisSuffix: String { unit == .tokens ? " \(metrics.tokenBasisLabel)" : "" }

    /// When server-driven, the % is Claude's real number; otherwise it's an approximation
    /// and we say what it's measured against (and nudge re-calibration if one has lapsed).
    private var limitHelp: String {
        if metrics.serverDriven5h {
            // One interpolated literal, not a `+` chain — the concatenation blew up the
            // type-checker ("unable to type-check this expression in reasonable time").
            let age = metrics.serverDataAge.map { " (as of \($0))" } ?? ""
            return """
                Claude's real 5-hour usage, via the statusline cache\(age). ClaudePet reads only \
                the local file — no token, no network. The % is Claude's own accounting; the count \
                below is ClaudePet's \(metrics.tokenBasisLabel)-token sum from your own transcripts, \
                so the two aren't the same measurement. Change the basis in Settings → Appearance.
                """
        }
        return "Approximate — the % is measured against \(metrics.budgetBasisDescription)."
            + (metrics.lastCalibratedAt != nil && metrics.calibrationIsStale
               ? " A limit reset since you calibrated; re-calibrate in Settings to re-align." : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("5h current session").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                if metrics.serverDriven5h {
                    Text("live").scaledFont(7.5, weight: .bold)
                        .padding(.horizontal, 3).padding(.vertical, 0.5)
                        .background(Theme.claudeCoral.opacity(0.22), in: Capsule())
                        .foregroundStyle(Theme.claudeCoral)
                }
                Spacer()
                Text("\(metrics.serverDriven5h ? "" : "~")\(Int((fraction * 100).rounded()))%")
                    .scaledFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.gaugeTrack(fraction))
                    Capsule().fill(barFill).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: barThickness * scaleHeight)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if metrics.serverDriven5h {
                        // Server gives a %, not a token cap — show real tokens used as context.
                        Text("\(amount(metrics.blockTokensUsed(unit: unit)))\(basisSuffix) used this window")
                    } else {
                        Text("\(amount(metrics.blockValue(unit: unit))) / \(amount(metrics.blockBudget(unit: unit)))")
                        Spacer()
                        Text("\(amount(metrics.blockRemaining(unit: unit))) left")
                            .foregroundStyle(Theme.claudeCoral.opacity(0.9))
                    }
                }
                HStack(spacing: 4) {
                    if metrics.activeBlock != nil {
                        Text("burn \(amount(metrics.blockBurnPerHour(unit: unit)))/h")
                    } else if !metrics.serverDriven5h {
                        Text("idle")
                    }
                    Spacer()
                    if let reset = metrics.blockResetDate {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("resets in \(Format.duration(reset.timeIntervalSince(context.date)))")
                        }
                    }
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .scaledFont(9.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
        .help(limitHelp + (metrics.activeBlock.map { metrics.sidechainNote($0) } ?? ""))
    }

    @Environment(\.widgetScale) private var scaleHeight: CGFloat
}
