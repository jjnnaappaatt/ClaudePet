import SwiftUI
import ClaudePetCore

/// Weekly (7-day, all models) usage bar — mirrors the Claude app's "Weekly limits".
/// Local estimate: the real cap is server-side, so the budget is editable/calibratable.
struct WeeklyLimitBar: View {
    @Environment(MetricsStore.self) private var metrics

    private var unit: BudgetUnit { metrics.budgetUnit }
    private var fraction: Double { metrics.weeklyFraction(unit: unit) }

    private var barColor: Color {
        switch fraction {
        case ..<0.7: return Theme.highlight
        case ..<0.9: return .orange
        default:     return .red
        }
    }

    private func amount(_ v: Double) -> String {
        unit == .tokens ? Format.tokens(Int(v)) : Format.currency(v)
    }

    /// Server-driven → Claude's real weekly number; otherwise approximate, named by basis.
    private var limitHelp: String {
        if metrics.serverDriven7d {
            return "Claude's real 7-day usage, via the statusline cache"
                + (metrics.serverDataAge.map { " (as of \($0))" } ?? "")
                + ". ClaudePet reads only the local file — no token, no network."
        }
        return "Fixed 7-day window that resets to zero on a schedule (like the Claude app). "
            + "The % is measured against \(metrics.budgetBasisDescription)."
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
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(barColor).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 7 * scale)

            HStack(spacing: 4) {
                if metrics.serverDriven7d {
                    Text("\(amount(metrics.weeklyValue(unit: unit))) used this week")
                } else {
                    Text("\(amount(metrics.weeklyValue(unit: unit))) / \(amount(metrics.weeklyBudget(unit: unit)))")
                    Text("·").foregroundStyle(Theme.textSecondary.opacity(0.4))
                    Text("\(amount(metrics.weeklyRemaining(unit: unit))) left")
                        .foregroundStyle(Theme.highlight.opacity(0.9))
                }
                Spacer()
                if let reset = metrics.weeklyResetDate {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("resets in \(Format.durationLong(reset.timeIntervalSince(context.date)))")
                    }
                } else {
                    Text("7-day · est.")
                }
            }
            .scaledFont(9.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .help(limitHelp)
    }

    @Environment(\.widgetScale) private var scale: CGFloat
}
