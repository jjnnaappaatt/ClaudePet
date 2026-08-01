import SwiftUI
import ClaudePetCore

/// Today's per-model split (tokens + cost); the token count follows the work/total setting.
/// Unknown models are flagged "unpriced".
struct ModelBreakdownView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private let dotColor: [ModelFamily: Color] = [
        .fable: Color(red: 0.72, green: 0.55, blue: 0.95),   // top tier — violet
        .opus: Theme.claudeCoral,
        .sonnet: Theme.highlight,
        .haiku: Color(red: 0.55, green: 0.78, blue: 0.95),
        .other: Color.gray,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            if metrics.todayByModel.isEmpty {
                Text("no model usage today")
                    .scaledFont(10).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(metrics.todayByModel) { row in
                    HStack(spacing: 6) {
                        Circle().fill(dotColor[row.family] ?? .gray)
                            .frame(width: 6 * scale, height: 6 * scale)
                        Text(row.family.displayName)
                            .scaledFont(13, weight: .medium).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).fixedSize()
                        Spacer()
                        Text(Format.tokens(metrics.modelTokens(row)))
                            .scaledFont(11.5, design: .rounded).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).fixedSize()
                        Text(row.unpriced ? "—" : Format.currency(row.costUSD))
                            .scaledFont(11.5, weight: .semibold, design: .rounded)
                            .foregroundStyle(row.unpriced ? Theme.textTertiary : Theme.textPrimary)
                            .frame(width: 50 * scale, alignment: .trailing)
                            .help(row.unpriced
                                ? "No price set for \(row.family.displayName) — tokens are exact, cost can't be estimated."
                                : "Notional API-equivalent cost estimate; tokens are exact.")
                    }
                }
            }
        }
    }
}
