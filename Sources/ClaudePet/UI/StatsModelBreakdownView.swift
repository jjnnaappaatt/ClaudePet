import SwiftUI
import ClaudePetCore

/// Claude Code's own lifetime totals, as `/stats` reports them: the headline "Total tokens" plus each
/// model's share and its input/output split.
///
/// These are **read from `~/.claude/stats-cache.json`, not computed here** — `/stats`' figure cannot be
/// reproduced from the transcripts (see `StatsCache`). That also means they follow Claude Code's
/// accounting, not ClaudePet's: cache tokens are excluded and the work/total setting does not apply, so
/// this panel deliberately ignores `TokenBasis`. Every other token figure on the dashboard is ClaudePet's
/// own count and will not match — hence the explicit "/stats" labelling.
struct StatsModelBreakdownView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    /// Eight, in two columns of four — enough that every model a real account has used fits, so the
    /// "+N more" line normally doesn't appear at all. Each model needs two lines and nothing on the
    /// dashboard scrolls (verified: `ScrollView` renders blank through `ImageRenderer`, like `Form`), so
    /// a single column could only afford three; pairing them is what makes eight affordable. The fourth
    /// row is paid for by the summary card now matching the taller limits card beside it.
    private static let maxModels = 8

    private let dotColor: [ModelFamily: Color] = [
        .fable: Color(red: 0.72, green: 0.55, blue: 0.95),
        .opus: Theme.claudeCoral,
        .sonnet: Theme.highlight,
        .haiku: Color(red: 0.55, green: 0.78, blue: 0.95),
        .other: Color.gray,
    ]

    var body: some View {
        if let cache = metrics.statsCache, let total = metrics.statsTotalTokens() {
            let shown = Array(cache.models.prefix(Self.maxModels))
            let rest = cache.models.dropFirst(Self.maxModels)
            // Chunk into pairs so the grid stays a plain VStack of HStacks — `LazyVGrid` would give the
            // same picture, but lazy containers are the family that renders blank through
            // `ImageRenderer`, and this view has to stay snapshot-verifiable.
            let pairs = stride(from: 0, to: shown.count, by: 2).map {
                Array(shown[$0 ..< min($0 + 2, shown.count)])
            }

            VStack(alignment: .leading, spacing: 5 * scale) {
                // A hero figure, sized like the cost and token counts above it — this is the headline
                // number of the panel, not a caption for the list beneath.
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    Text("Total tokens").scaledFont(11, weight: .semibold)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(Format.tokens(total))
                        .scaledFont(21, weight: .bold, design: .rounded)
                        .foregroundStyle(Theme.textPrimary)
                }
                .help(headlineHelp(total: total))

                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 14 * scale) {
                        ForEach(pair) { m in
                            modelRow(m, share: cache.share(m))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Keeps a lone final model in the left column instead of letting it stretch
                        // across the full width and break the grid.
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                }
                if !rest.isEmpty {
                    HStack {
                        Text("+\(rest.count) more")
                            .scaledFont(9.5).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(Format.tokens(rest.reduce(0) { $0 + $1.workTokens }))
                            .scaledFont(9.5, design: .rounded)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .help("The remaining models, combined: "
                          + rest.map(\.displayName).joined(separator: ", "))
                }
            }
        }
    }

    private func modelRow(_ m: StatsModelTotal, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6 * scale) {
                Circle().fill(dotColor[m.family] ?? .gray)
                    .frame(width: 6 * scale, height: 6 * scale)
                Text(m.displayName)
                    .scaledFont(10.5, weight: .medium).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4 * scale)
                Text("\(share * 100, specifier: "%.1f")%")
                    .scaledFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(Theme.claudeCoral.opacity(0.9))
            }
            HStack(spacing: 5 * scale) {
                Text("In \(Format.tokens(m.inputTokens))")
                Text("·").foregroundStyle(Theme.textFaint)
                Text("Out \(Format.tokens(m.outputTokens))")
                Spacer()
            }
            .scaledFont(9.5).foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.leading, 12 * scale)
        }
        .help("\(m.displayName): \(Format.tokens(m.workTokens)) input+output all time, "
              + "\(Format.tokens(m.cacheReadTokens)) cache reads (not counted in the total).")
    }

    private func headlineHelp(total: Int) -> String {
        let asOf = metrics.statsAsOfDescription.map { " Claude Code last recomputed its cache on \($0)." } ?? ""
        let today = metrics.statsIncludesToday()
            ? " Today's usage is added from ClaudePet's own count, which uses different accounting — "
              + "measured on one full day it ran within about ±7% of Claude Code's, so treat today's "
              + "slice as approximate."
            : " Today's usage is not included yet."
        return "Input + output across every model, all time, exactly as Claude Code's /stats reports it "
            + "— read from its own local cache, because the figure can't be reproduced from the "
            + "transcripts. Cache tokens are excluded, so this won't match the other token figures here."
            + asOf + today
    }
}
