import SwiftUI
import ClaudePetCore

/// "Today" header: shows BOTH work (input+output) and total billable tokens, plus cost.
struct StatsHeaderView: View {
    @Environment(MetricsStore.self) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Today")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(Format.currency(metrics.today.costUSD))
                    .scaledFont(15, weight: .bold, design: .rounded)
                    .foregroundStyle(Theme.claudeCoral)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(metrics.today.workTokens))
                    .scaledFont(17, weight: .bold, design: .rounded)
                    .foregroundStyle(Theme.textPrimary)
                Text("work").scaledFont(10).foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(metrics.today.totalTokens))
                    .scaledFont(12, weight: .medium, design: .rounded)
                    .foregroundStyle(Theme.textSecondary)
                Text("total").scaledFont(10).foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
        }
    }
}
