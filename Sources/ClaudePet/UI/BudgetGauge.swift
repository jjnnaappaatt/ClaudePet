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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("5h block").scaledFont(10, weight: .semibold)
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
            .frame(height: 7 * scaleHeight)

            HStack(spacing: 4) {
                Text("\(amount(metrics.blockValue(unit: unit))) / \(amount(metrics.blockBudget(unit: unit)))")
                Spacer()
                if let block = metrics.activeBlock {
                    Text("burn \(amount(metrics.blockBurnPerHour(unit: unit)))/h")
                    Text("·").foregroundStyle(Theme.textSecondary.opacity(0.5))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("resets in \(Format.duration(block.endsAt.timeIntervalSince(context.date)))")
                    }
                } else {
                    Text("idle")
                }
            }
            .scaledFont(9.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    @Environment(\.widgetScale) private var scaleHeight: CGFloat
}
