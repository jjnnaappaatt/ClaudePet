import SwiftUI
import ClaudePetCore

/// Claude Code's lifetime counters, as eight tiles: sessions, messages, active days, streaks and so on.
///
/// **Every figure is read from `~/.claude/stats-cache.json`, not derived** — the same rule that governs
/// the `/stats` total above it. That file already carried all of this; nothing here is computed from
/// our own transcripts except the streak's tail (see `MetricsStore.statsCurrentStreak`).
///
/// The eight were picked so that none repeats something already on the dashboard. Three of Claude
/// Code's own tiles are deliberately absent for that reason: **Total tokens** is the hero of this very
/// card, **Favourite model** is row 1 of the model grid directly above (which is sorted heaviest
/// first), and **tokens/day** is what the Today pace bar prints. A tile that restates its neighbour
/// costs space and teaches nothing.
struct StatsKPIGrid: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    var body: some View {
        if let c = metrics.statsCache {
            let tiles = tiles(c)
            VStack(spacing: 6 * scale) {
                ForEach(Array(stride(from: 0, to: tiles.count, by: 4)), id: \.self) { start in
                    HStack(alignment: .top, spacing: 8 * scale) {
                        ForEach(tiles[start ..< min(start + 4, tiles.count)], id: \.label) { t in
                            tile(t).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .help("Claude Code's own lifetime figures, read from its stats cache"
                  + (metrics.statsAsOfDescription.map { " (last recomputed \($0))" } ?? "")
                  + ". The current streak is extended past that date with days ClaudePet can see for "
                  + "itself, so it doesn't read low while the cache catches up.")
        }
    }

    private struct Tile { let label: String; let value: String }

    private func tiles(_ c: StatsCache) -> [Tile] {
        // These four come from the cache alone and can't be extended honestly (a "session" or
        // "message" is Claude Code's own count). When the cache lags, say so on the tile — an 18-day
        // old count rendered exactly like a current one, which read as the dashboard not updating.
        let asOf = metrics.statsCacheLags() ? metrics.statsAsOfDescription.map { " · to \($0)" } ?? "" : ""
        return [
            // Zero renders as "—", not "0". An older Claude Code writes a cache without these keys,
            // and a confident zero there would be a lie — "no messages ever" rather than "this file
            // doesn't say". Every tile below follows the same rule.
            Tile(label: "Sessions" + asOf, value: count(c.totalSessions)),
            Tile(label: "Messages" + asOf, value: count(c.totalMessages)),
            // Via the store: extended past the cache like the streak, or a 27-day streak sits
            // beside 26 active days.
            Tile(label: "Active days", value: count(metrics.statsActiveDays() ?? 0)),
            Tile(label: "Since", value: c.firstSessionDate.map {
                $0.formatted(.dateTime.day().month(.abbreviated))
            } ?? "—"),
            Tile(label: "Current streak", value: metrics.statsCurrentStreak().map { "\($0)d" } ?? "—"),
            // Via the store, not `c.longestStreak`: the current streak is extended past the cache, so
            // the cached longest can be overtaken by it — see `statsLongestStreak`.
            Tile(label: "Longest streak",
                 value: (metrics.statsLongestStreak()).map { $0 > 0 ? "\($0)d" : "—" } ?? "—"),
            // "All time" is load-bearing: the hour chart one card away says "peak ~9am", which is
            // TODAY's busiest hour. Same word, different figure — the label is what keeps them apart.
            Tile(label: asOf.isEmpty ? "Busiest hr · all time" : "Busiest hr" + asOf,
                 value: c.busiestHour.map { Format.hourLabel($0) } ?? "—"),
            Tile(label: "Longest session" + asOf,
                 value: c.longestSessionMessages > 0
                     ? Format.grouped(Double(c.longestSessionMessages)) + " msg" : "—"),
        ]
    }

    private func count(_ n: Int) -> String { n > 0 ? Format.grouped(Double(n)) : "—" }

    private func tile(_ t: Tile) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // Shrink, don't clip. "Busiest hr · all time" is the longest label and truncated to
            // "all ti…" at 900x800 even before this card's type grew; `WeekAllTimeView` and
            // `BillingLineView` in the same card have carried 0.8 for exactly this reason.
            Text(t.label)
                .scaledFont(9).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(t.value)
                .scaledFont(13, weight: .semibold, design: .rounded)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}
