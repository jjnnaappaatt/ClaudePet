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
    /// 6 rather than 8 by choice: nothing on the dashboard scrolls, so these two rows were costing
    /// every label on the page ~5% of its size (see `DashboardView.refHeight`). The tail is still
    /// accounted for on the "+N more" line, so no usage disappears.
    private static let maxRows = 6

    private func value(_ p: ProjectTotal) -> Double {
        metrics.budgetUnit == .usd ? p.costUSD : Double(metrics.tokens(work: p.workTokens, total: p.totalTokens))
    }

    private func amount(_ v: Double) -> String {
        metrics.budgetUnit == .usd ? Format.currency(v) : Format.tokens(Int(v))
    }

    var body: some View {
        // Re-sort by the value actually on screen. `Aggregator` orders by cache-inclusive
        // `totalTokens` (a deterministic default), but this view shows whatever `TokenBasis` /
        // `budgetUnit` select — so under "work" the aggregator's order put 4M above 8.2M and the list
        // read as unsorted. The empty-path bucket still sinks to the bottom.
        let all = metrics.cycleByProject.sorted {
            if $0.path.isEmpty != $1.path.isEmpty { return !$0.path.isEmpty }
            return value($0) > value($1)
        }
        let shown = Array(all.prefix(Self.maxRows))
        let rest = all.dropFirst(Self.maxRows)
        let maxV = max(shown.map(value).max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack {
                Text("By project").scaledFont(11, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("this cycle")
                    .scaledFont(9).foregroundStyle(Theme.textSecondary.opacity(0.6))
            }

            if all.isEmpty {
                Text("no usage this cycle")
                    .scaledFont(10).foregroundStyle(Theme.textSecondary.opacity(0.7))
            } else {
                ForEach(shown) { row in
                    projectRow(row, maxV: maxV)
                }
                if !rest.isEmpty {
                    let restValue = rest.reduce(0.0) { $0 + value($1) }
                    HStack {
                        Text("+\(rest.count) more")
                            .scaledFont(9.5).foregroundStyle(Theme.textSecondary.opacity(0.7))
                        Spacer()
                        Text(amount(restValue))
                            .scaledFont(9.5, design: .rounded)
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    }
                    .help("Projects beyond the top \(Self.maxRows), combined — nothing is dropped, so "
                          + "the rows above plus this line still sum to the Cycle figure.")
                }
            }
        }
        .help("Tokens by project across the current billing cycle. Names come from each turn's own "
              + "recorded working directory, so they're exact. Subagent turns count toward the "
              + "project that launched them.")
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
            Text(Format.currency(row.costUSD))
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
