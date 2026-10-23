import SwiftUI
import ClaudePetCore

/// Claude Code's lifetime totals, as `/stats` reports them right now: the headline "Total tokens" and
/// each model's share of it.
///
/// **Live, not a snapshot.** `MetricsStore.stats` is the cache Claude Code last wrote plus every day
/// since, folded in by the same rules `/stats` itself uses (`StatsReplica`), so this matches `/stats`
/// to the token whenever it is opened. It also follows Claude Code's accounting rather than ClaudePet's
/// — cache excluded, repeated log lines counted, the work/total setting ignored — so it will not match
/// the other token figures on the dashboard, and is labelled `/stats` for that reason.
struct StatsModelBreakdownView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    /// Eight cells, two columns of four. One line per model rather than the two this used to take
    /// (name, then "In … · Out …"): the split moved to the tooltip, and the grid now costs half the
    /// height for the same models. A ninth model and beyond fold into the last cell as "Other".
    private static let maxCells = 8

    /// Past this, a cache this old has transcripts close to Claude Code's 30-day cleanup — see
    /// `MetricsStore.statsCacheAgeDays`.
    private static let staleAfterDays = 21

    /// Shared with `StatsKPIGrid`'s favourite tile, so its dot reads as a pointer into this grid.
    static let dotColor: [ModelFamily: Color] = [
        .fable: Color(red: 0.72, green: 0.55, blue: 0.95),
        .opus: Theme.claudeCoral,
        .sonnet: Theme.highlight,
        .haiku: Color(red: 0.55, green: 0.78, blue: 0.95),
        .other: Color.gray,
    ]

    private struct Cell: Identifiable {
        let id: String
        let name: String
        let color: Color
        let tokens: Int
        let help: String
    }

    var body: some View {
        if let stats = metrics.stats {
            let total = stats.totalWorkTokens
            let cells = cells(stats.models)
            // Plain VStack of HStacks — lazy grids render blank through `ImageRenderer`, and this view
            // has to stay snapshot-verifiable.
            let pairs = stride(from: 0, to: cells.count, by: 2).map {
                Array(cells[$0 ..< min($0 + 2, cells.count)])
            }

            VStack(alignment: .leading, spacing: 8 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    Text("Total tokens").scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).fixedSize()
                    sourceTag
                    Spacer(minLength: 4 * scale)
                    Text(Format.tokensPrecise(total))
                        .scaledFont(21, weight: .bold, design: .rounded)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).fixedSize()
                }
                .help(headlineHelp(stats))

                // No stretch here, deliberately. Letting the rows breathe was tried and read as a list
                // drifting apart — and a capped Spacer between rows is not capped at all, because it
                // also brings a second stack gap with it (rows went from 53 to 80px at 1990 wide).
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 16 * scale) {
                        ForEach(pair) { c in
                            row(c, share: total > 0 ? Double(c.tokens) / Double(total) : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Keeps a lone final cell in the left column instead of stretching across.
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
        }
    }

    private func cells(_ models: [StatsModelTotal]) -> [Cell] {
        let fits = models.count <= Self.maxCells
        let shown = fits ? models : Array(models.prefix(Self.maxCells - 1))
        var out = shown.map { m in
            Cell(id: m.model, name: m.displayName, color: Self.dotColor[m.family] ?? .gray,
                 tokens: m.workTokens,
                 help: "\(m.displayName): in \(Format.tokens(m.inputTokens)) · out "
                     + "\(Format.tokens(m.outputTokens)), all time. "
                     + "\(Format.tokens(m.cacheReadTokens)) cache reads, not counted in the total.")
        }
        if !fits {
            let rest = models.dropFirst(Self.maxCells - 1)
            out.append(Cell(id: "other", name: "Other (\(rest.count))", color: Theme.textFaint,
                            tokens: rest.reduce(0) { $0 + $1.workTokens },
                            help: rest.map(\.displayName).joined(separator: ", ")))
        }
        return out
    }

    /// Names the source, and turns into the one call to action ClaudePet can't take for the user
    /// once the cache is old enough for its days to be at risk.
    @ViewBuilder private var sourceTag: some View {
        if let age = metrics.statsCacheAgeDays(), age >= Self.staleAfterDays {
            Text("open /stats · \(age)d")
                .scaledFont(9.5, weight: .medium, design: .monospaced)
                .foregroundStyle(Theme.highlight)
                .lineLimit(1).fixedSize()
        } else {
            Text("/stats")
                .scaledFont(9.5, design: .monospaced)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1).fixedSize()
        }
    }

    /// A hairline share bar under each row: the mix reads at a glance without parsing percentages,
    /// and the card's spare height goes to something rather than a void. Family colour, never the
    /// gauge ramp — a big share is not a warning.
    private func row(_ c: Cell, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            // The token figure is what gives when the column is narrow (900×800): shrinking the name
            // instead left "Opus 4.8" smaller than the numbers beside it. The bar and the share still
            // carry the comparison, and the tooltip has the figure.
            ViewThatFits(in: .horizontal) {
                label(c, share: share, showsTokens: true)
                label(c, share: share, showsTokens: false)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardStroke)
                    Capsule().fill(c.color)
                        .frame(width: max(2 * scale, g.size.width * min(max(share, 0), 1)))
                }
            }
            .frame(height: 2.5 * scale)
            .padding(.leading, 12 * scale)
        }
        .help(c.help)
    }

    private func label(_ c: Cell, share: Double, showsTokens: Bool) -> some View {
        HStack(spacing: 6 * scale) {
            Circle().fill(c.color).frame(width: 6 * scale, height: 6 * scale)
            Text(c.name)
                .scaledFont(10.5, weight: .medium).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4 * scale)
            if showsTokens {
                Text(Format.tokens(c.tokens))
                    .scaledFont(10, design: .rounded).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).fixedSize()
            }
            Text("\(share * 100, specifier: share >= 0.1 ? "%.0f" : "%.1f")%")
                .scaledFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(Theme.claudeCoral)
                .lineLimit(1).fixedSize()
                .frame(minWidth: 28 * scale, alignment: .trailing)
        }
    }

    private func headlineHelp(_ stats: StatsSnapshot) -> String {
        var s = "Input + output across every model, all time — the figure Claude Code's /stats shows. "
            + "Claude Code saves its stats only when /stats is opened, so ClaudePet adds every day "
            + "since by the same rules, live. Cache tokens are excluded and repeated log lines are "
            + "counted, as /stats does, so this won't match the other token figures here."
        if let asOf = metrics.statsAsOfDescription { s += " Last saved by /stats: \(asOf)." }
        if let age = metrics.statsCacheAgeDays(), age >= Self.staleAfterDays {
            s += " That is \(age) days ago. Claude Code deletes transcripts after 30 days by default "
                + "and only folds them into its all-time totals when /stats is opened — open it in "
                + "Claude Code before they age out, or those days drop out of /stats (and this panel) "
                + "for good."
        }
        return s
    }
}
