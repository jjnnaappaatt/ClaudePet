import SwiftUI
import ClaudePetCore

/// Which projects burned this billing cycle's tokens — the one dimension ClaudePet never had.
///
/// The name is the real directory name, taken from the `cwd` each transcript line records. The
/// `~/.claude/projects` folder name can't supply it: that encoding replaces every non-alphanumeric
/// with `-`, so `/Users/you/Desktop/LiDAR + HPE` is stored as `-Users-you-Desktop-LiDAR---HPE` and
/// is not decodable. Rows sum exactly to the `Cycle` figure.
struct ProjectBreakdownView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    /// Cap the list so one busy month can't produce an unbounded wall of rows; the remainder is
    /// shown as an explicit "+N more" total rather than silently dropped.
    ///
    /// Back to 8. It was cut to 6 when this card sat *under* a chart row, where the two heights added
    /// and those rows cost every label on the page ~5% of its size. It now owns a full-height column of
    /// its own, so the rows are close to free and 6 left the bottom of the card empty. The tail is
    /// still accounted for on the "+N more" line either way, so no usage disappears.
    private static let maxRows = 8

    private func value(_ p: ProjectTotal) -> Double {
        metrics.budgetUnit == .usd ? p.costUSD : Double(metrics.tokens(work: p.workTokens, total: p.totalTokens))
    }

    private func amount(_ v: Double) -> String {
        // Precise forms: these are lifetime figures, and the compact ones moved in 0.1M / $100 steps
        // — a row updating correctly sat unchanged for hours and read as frozen.
        metrics.budgetUnit == .usd ? Format.currencyWhole(v) : Format.tokensPrecise(Int(v))
    }

    var body: some View {
        // Re-sort by the value actually on screen. `Aggregator` orders by cache-inclusive
        // `totalTokens` (a deterministic default), but this view shows whatever `TokenBasis` /
        // `budgetUnit` select — so under "work" the aggregator's order put 4M above 8.2M and the list
        // read as unsorted. The empty-path bucket still sinks to the bottom.
        let all = metrics.allTimeByProject.sorted {
            if $0.path.isEmpty != $1.path.isEmpty { return !$0.path.isEmpty }
            return value($0) > value($1)
        }
        let shown = Array(all.prefix(Self.maxRows))
        let rest = all.dropFirst(Self.maxRows)
        let maxV = max(shown.map(value).max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text("By project").scaledFont(13.5, weight: .semibold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("all time")
                    .scaledFont(9).foregroundStyle(Theme.textTertiary)
            }

            if all.isEmpty {
                // Not "this cycle" — the rows are lifetime now, so an empty list means no transcripts
                // have been read at all, not that the current cycle happens to be quiet.
                Text("no usage recorded yet")
                    .scaledFont(10).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(shown) { row in
                    projectRow(row, maxV: maxV)
                }
                if !rest.isEmpty {
                    let restValue = rest.reduce(0.0) { $0 + value($1) }
                    // Same geometry as `projectRow`, so this figure lands in the TOKEN column with
                    // the rows it is a continuation of. It used to be a bare `HStack` + `Spacer()`
                    // with neither the row's horizontal padding nor its trailing cost reservation,
                    // so it drifted 63·scale right — into, and 5·scale past, the COST column. A
                    // token total sitting under the dollar figures reads as a dollar figure.
                    HStack(spacing: 6 * scale) {
                        Text("+\(rest.count) more")
                            .scaledFont(9.5).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 4 * scale)
                        Text(amount(restValue))
                            .scaledFont(9.5, design: .rounded)
                            .foregroundStyle(Theme.textSecondary)
                        // Holds the cost column open. There is no combined cost to print — the rows
                        // show `costUSD` per project and summing the tail would invite reading it as
                        // one project's spend — so the strip stays empty rather than borrowed.
                        Color.clear.frame(width: 52 * scale, height: 1)
                    }
                    .padding(.horizontal, 5 * scale)
                    .help("Projects beyond the top \(Self.maxRows), combined — nothing is dropped, so "
                          + "the rows above plus this line still sum to the all-time total.")
                }
            }
        }
        .help("Tokens by project across ALL of your history, not just this billing cycle — so these "
              + "rows sum to the all-time total, not to the Cycle figure beside them. Names come from "
              + "each turn's own recorded working directory, so they're exact. Subagent turns count "
              + "toward the project that launched them.")
    }

    /// One line per project, with the proportional bar as a BACKGROUND fill rather than a second
    /// row. A bar on its own line doubled the card's height, which pushed the billing footer off the
    /// bottom of the window at its minimum size.
    private func projectRow(_ row: ProjectTotal, maxV: Double) -> some View {
        HStack(spacing: 6 * scale) {
            Text(row.displayName)
                .scaledFont(10.5, weight: .medium)
                .foregroundStyle(row.path.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4 * scale)
            Text(amount(value(row)))
                .scaledFont(10, design: .rounded).foregroundStyle(Theme.textSecondary)
            Text(Format.currencyWhole(row.costUSD))
                .scaledFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 52 * scale, alignment: .trailing)
        }
        .padding(.vertical, 3 * scale)
        .padding(.horizontal, 5 * scale)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // A visible track matters: without one the heaviest project's fill spans the whole
                    // row and reads as a selected list item rather than as a full-length bar.
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.claudeCoral.opacity(row.path.isEmpty ? 0.10 : 0.20))
                        .frame(width: max(3, geo.size.width * (value(row) / maxV)))
                }
            }
        }
        .help(row.path.isEmpty
              ? "Turns whose transcript recorded no working directory — they can't be attributed to "
                + "a project. In practice this stays empty; the only files without one log no usage."
              : row.path)
    }
}
