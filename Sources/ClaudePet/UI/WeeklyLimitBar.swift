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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Weekly (all models)").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
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
                Text("\(amount(metrics.weeklyValue(unit: unit))) / \(amount(metrics.weeklyBudget(unit: unit)))")
                Text("·").foregroundStyle(Theme.textSecondary.opacity(0.4))
                Text("\(amount(metrics.weeklyRemaining(unit: unit))) left")
                    .foregroundStyle(Theme.highlight.opacity(0.9))
                Spacer()
                if let reset = metrics.weekReset {
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
        .help("Fixed 7-day limit window that resets to zero on a schedule (like the Claude app). Both the reset time and the cap are estimates — calibrate them in Settings → Match the Claude app.")
    }

    @Environment(\.widgetScale) private var scale: CGFloat
}
