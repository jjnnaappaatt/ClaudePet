import SwiftUI
import ClaudePetCore

/// "Today" header: shows BOTH work (input+output) and total billable tokens, plus cost.
struct StatsHeaderView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5 * scale) {
                Text("Today")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(metrics.plan.displayName)
                    .scaledFont(8.5, weight: .bold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 1.5 * scale)
                    .background(Theme.claudeCoral.opacity(0.20), in: Capsule())
                    .foregroundStyle(Theme.claudeCoral)
                Spacer()
                Text("~" + Format.currency(metrics.today.costUSD))
                    .scaledFont(21, weight: .bold, design: .rounded)
                    .foregroundStyle(Theme.claudeCoral)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Notional API-equivalent cost (estimate) — on a subscription you don't pay per token. The token counts below are exact (read from Claude's transcripts).")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(metrics.today.workTokens))
                    .scaledFont(17, weight: .bold, design: .rounded)
                    .foregroundStyle(Theme.textPrimary)
                Text("work").scaledFont(10).foregroundStyle(Theme.textSecondary)
            }
            .help("Work tokens = input + output (the actual prompt & response).")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(metrics.today.cacheTokens))
                    .scaledFont(12, weight: .medium, design: .rounded)
                    .foregroundStyle(Theme.textSecondary)
                Text("cache").scaledFont(10).foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .help("Cache tokens (reads + writes). Claude re-reads the cached conversation every turn, so this dwarfs 'work'. Cheap per token (reads 0.1×).")
        }
    }
}
