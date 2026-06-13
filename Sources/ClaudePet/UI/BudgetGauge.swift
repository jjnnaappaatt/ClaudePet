import SwiftUI
import ClaudePetCore

/// The 5-hour block gauge: progress toward the user's budget (tokens or US$),
/// plus burn rate and a LIVE reset countdown. Approximation of the rolling-window limit.
struct BudgetGauge: View {
    @Environment(MetricsStore.self) private var metrics

    private var unit: BudgetUnit { metrics.budgetUnit }
    private var fraction: Double { metrics.blockFraction(unit: unit) }

    private var barColor: Color {
        switch fraction {
        case ..<0.7: return Theme.claudeCoral
        case ..<0.9: return .orange
        default:     return .red
        }
    }

    private func amount(_ value: Double) -> String {
        unit == .tokens ? Format.tokens(Int(value)) : Format.currency(value)
    }

    /// When server-driven, the % is Claude's real number; otherwise it's an approximation
    /// and we say what it's measured against (and nudge re-calibration if one has lapsed).
    private var limitHelp: String {
        if metrics.serverDriven5h {
            return "Claude's real 5-hour usage, via the statusline cache"
                + (metrics.serverDataAge.map { " (as of \($0))" } ?? "")
                + ". ClaudePet reads only the local file — no token, no network."
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
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(barColor).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 7 * scaleHeight)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if metrics.serverDriven5h {
                        // Server gives a %, not a token cap — show local tokens as context only.
                        Text("\(amount(metrics.blockValue(unit: unit))) used this window")
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
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
            }
            .scaledFont(9.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .help(limitHelp)
    }

    @Environment(\.widgetScale) private var scaleHeight: CGFloat
}
