import SwiftUI
import ClaudePetCore

/// Today's per-model split (work tokens + cost). Unknown models are flagged "unpriced".
struct ModelBreakdownView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private let dotColor: [ModelFamily: Color] = [
        .opus: Theme.claudeCoral,
        .sonnet: Theme.highlight,
        .haiku: Color(red: 0.55, green: 0.78, blue: 0.95),
        .other: Color.gray,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if metrics.todayByModel.isEmpty {
                Text("no model usage today")
                    .scaledFont(10).foregroundStyle(Theme.textSecondary.opacity(0.7))
            } else {
                ForEach(metrics.todayByModel) { row in
                    HStack(spacing: 6) {
                        Circle().fill(dotColor[row.family] ?? .gray)
                            .frame(width: 6 * scale, height: 6 * scale)
                        Text(row.family.displayName)
                            .scaledFont(11, weight: .medium).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(Format.tokens(row.workTokens))
                            .scaledFont(10, design: .rounded).foregroundStyle(Theme.textSecondary)
                        Text(row.unpriced ? "—" : Format.currency(row.costUSD))
                            .scaledFont(10, weight: .semibold, design: .rounded)
                            .foregroundStyle(row.unpriced ? Theme.textSecondary.opacity(0.6) : Theme.textPrimary)
                            .frame(width: 44 * scale, alignment: .trailing)
                    }
                }
            }
        }
    }
}
