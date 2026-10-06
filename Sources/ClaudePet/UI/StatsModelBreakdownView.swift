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
        if metrics.statsCache != nil, let total = metrics.statsTotalTokens() {
            // Extended across the gap like the headline, so the rows keep adding up to it.
            let models = metrics.statsModels()
            let shown = Array(models.prefix(Self.maxModels))
            let rest = models.dropFirst(Self.maxModels)
            // Chunk into pairs so the grid stays a plain VStack of HStacks — `LazyVGrid` would give the
            // same picture, but lazy containers are the family that renders blank through
            // `ImageRenderer`, and this view has to stay snapshot-verifiable.
            let pairs = stride(from: 0, to: shown.count, by: 2).map {
                Array(shown[$0 ..< min($0 + 2, shown.count)])
            }
            // Derived once and threaded down. Both of these re-filter `allTimeDaily` through
            // `statsGapDays`, and between the chip and the tooltip the body asked for them five
            // times per render. The array is one entry per active day, so this is tidiness, not a
            // measurable saving.
            let dated = metrics.statsIsDated()
            let filled = metrics.statsFilledDays()

            VStack(alignment: .leading, spacing: 5 * scale) {
                // A hero figure, sized like the cost and token counts above it — this is the headline
                // number of the panel, not a caption for the list beneath.
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    Text("Total tokens").scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).fixedSize()
                    ageChip(dated: dated, filled: filled)
                    Spacer(minLength: 4 * scale)
                    Text(Format.tokensPrecise(total))
                        .scaledFont(21, weight: .bold, design: .rounded)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).fixedSize()
                }
                .help(headlineHelp(dated: dated, filled: filled))

                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 14 * scale) {
                        ForEach(pair) { m in
                            modelRow(m, share: total > 0 ? Double(m.workTokens) / Double(total) : 0)
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

    /// What the headline covers that the cache doesn't — the fix for a total that could sit a week
    /// stale while rendering pixel-identical to a current one.
    ///
    /// Two states, because they need opposite reactions. `to 4 Aug` means the figure genuinely stops
    /// there and only running `/stats` will move it; `+2d` means ClaudePet closed the gap itself, and
    /// covers the model rows below it too, which are extended across the same days.
    @ViewBuilder private func ageChip(dated: Bool, filled: Int) -> some View {
        if dated, let asOf = metrics.statsAsOfDescription {
            Text("to \(asOf)")
                .scaledFont(9.5, weight: .medium)
                .foregroundStyle(Theme.highlight)
                .lineLimit(1).fixedSize()
        } else if filled > 0 {
            Text("+\(filled)d")
                .scaledFont(9.5, weight: .medium)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1).fixedSize()
        }
    }

    private func modelRow(_ m: StatsModelTotal, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6 * scale) {
                Circle().fill(dotColor[m.family] ?? .gray)
                    .frame(width: 6 * scale, height: 6 * scale)
                // Shrink rather than clip — this grid is the documented site of the "In 22…"
                // truncation, and the card's type just grew.
                Text(m.displayName)
                    .scaledFont(10.5, weight: .medium).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
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
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.leading, 12 * scale)
        }
        .help("\(m.displayName): \(Format.tokens(m.workTokens)) input+output all time, "
              + "\(Format.tokens(m.cacheReadTokens)) cache reads (not counted in the total).")
    }

    private func headlineHelp(dated: Bool, filled: Int) -> String {
        let asOf = metrics.statsAsOfDescription.map { " Claude Code last recomputed its cache on \($0)." } ?? ""
        let gap: String
        if dated {
            gap = " Days since then are NOT included: ClaudePet's own history doesn't reach back that "
                + "far, so filling the gap would undercount. Run /stats in Claude Code to refresh it."
        } else if filled > 0 {
            gap = " The \(filled == 1 ? "day" : "\(filled) days") since then \(filled == 1 ? "is" : "are") "
                + "added from ClaudePet's own count, which uses different accounting — measured on one "
                + "full day the two ran within about ±7% of each other, so treat that slice as "
                + "approximate. The per-model rows below are extended across the same days."
        } else {
            gap = " Nothing has been logged since, so the figure is current."
        }
        return "Input + output across every model, all time, as Claude Code's /stats reports it — read "
            + "from its own local cache, because the figure can't be reproduced from the transcripts. "
            + "Cache tokens are excluded, so this won't match the other token figures here."
            + asOf + gap
    }
}
