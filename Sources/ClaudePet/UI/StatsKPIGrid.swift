import SwiftUI
import ClaudePetCore

/// Claude Code's lifetime counters, as eight tiles — the same figures `/stats` prints, live.
///
/// Every value comes from `MetricsStore.stats`: the cache plus the days since, merged the way Claude
/// Code merges them, so nothing here needs a "to 17 Sep" qualifier any more.
///
/// Two rows of five, read as a ledger: the first is how much (sessions, messages, days, when), the
/// second is records and preferences. **Favourite model is its own tile, not "the grid's first row"**
/// — `/stats` ranks it by tokens including cache, the grid by input + output, and on real data those
/// name different models (Opus 5.5 vs Opus 4.8). The cache-inclusive total sits right after it, so
/// the reason for the difference is on screen beside the answer.
struct StatsKPIGrid: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    var body: some View {
        if let s = metrics.stats {
            let tiles = tiles(s)
            LedgerLayout(columns: Self.columns, hSpacing: 10 * scale, vSpacing: 9 * scale) {
                ForEach(tiles, id: \.label) { tile($0) }
            }
        }
    }

    private static let columns = 5

    private struct Tile {
        let label: String
        let value: String
        var suffix = ""
        var help = ""
        var dot: Color? = nil
    }

    private func tiles(_ s: StatsSnapshot) -> [Tile] {
        // Zero renders as "—": an older Claude Code writes a cache without these keys, and a confident
        // zero would claim "never" where the file simply doesn't say.
        let since = s.firstSessionDate.map { " since \($0.formatted(.dateTime.day().month(.abbreviated).year()))" } ?? ""
        return [
            Tile(label: "Sessions", value: count(s.totalSessions)),
            Tile(label: "Messages", value: count(s.totalMessages)),
            Tile(label: "Active days", value: count(s.activeDays),
                 suffix: s.totalDays > 0 ? "/\(s.totalDays)" : "",
                 help: "Days with any activity, out of every day\(since)."),
            Tile(label: "Most active", value: s.mostActiveDay.map(Self.dayLabel) ?? "—",
                 help: "The day with the most messages."),
            // "Peak hour", not "busiest": the hour chart nearby says "peak ~10am" for TODAY; this is
            // all time, by when sessions began. The tooltip keeps the two apart.
            Tile(label: "Peak hour", value: s.peakHour.map(Format.hourLabel) ?? "—",
                 help: "The hour your sessions most often start, all time."),
            Tile(label: "Streak", value: days(s.currentStreak),
                 help: "Consecutive days with activity, ending today. Days are UTC, as /stats counts them."),
            Tile(label: "Longest streak", value: days(s.longestStreak)),
            Tile(label: "Longest session",
                 value: s.longestSession.map { Format.durationLong($0.duration) } ?? "—",
                 help: s.longestSession.map {
                     "By wall-clock time, as /stats picks it: \(Format.grouped(Double($0.messageCount))) "
                         + "messages, started \($0.start.formatted(date: .abbreviated, time: .shortened))."
                 } ?? ""),
            Tile(label: "Favourite", value: s.favouriteModel?.displayName ?? "—",
                 help: s.favouriteModel.map {
                     "The model with the most tokens including cache — /stats' own rule. "
                         + "\($0.displayName): \(Format.tokens($0.allTokens)). The list above ranks by "
                         + "input + output instead, which is why its first row can be a different model."
                 } ?? "",
                 dot: s.favouriteModel.map { StatsModelBreakdownView.dotColor[$0.family] ?? .gray }),
            Tile(label: "Incl. cache", value: Format.tokensPrecise(s.totalTokensIncludingCache),
                 help: "Every token Claude processed, cache reads and writes included — the \"Total "
                     + "tokens\" the terminal /stats prints. The headline above is input + output only, "
                     + "as the Claude desktop app shows it; prompt caching makes this one ~300× larger."),
        ]
    }

    /// The file's dates are UTC calendar dates, labelled as such — a `Date` would shift them a day
    /// in any zone west of Greenwich.
    private static func dayLabel(_ c: DateComponents) -> String {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let d = g.date(from: c) else { return "—" }
        let f = DateFormatter()
        f.calendar = g
        f.timeZone = g.timeZone
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: d)
    }

    private func count(_ n: Int) -> String { n > 0 ? Format.grouped(Double(n)) : "—" }
    private func days(_ n: Int) -> String { n > 0 ? "\(n)d" : "—" }

    private func tile(_ t: Tile) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(t.label)
                .scaledFont(9).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if let dot = t.dot {
                    Circle().fill(dot).frame(width: 6 * scale, height: 6 * scale)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 * scale }
                        .padding(.trailing, 4 * scale)
                }
                Text(t.value)
                    .scaledFont(13, weight: .semibold, design: .rounded)
                    .foregroundStyle(Theme.textPrimary)
                if !t.suffix.isEmpty {
                    Text(t.suffix)
                        .scaledFont(10, design: .rounded)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .help(t.help)
    }
}

/// Columns sized to their content, inside exactly the width offered.
///
/// Equal fifths squeezed "Longest session" below its neighbours at 900×800, and the smaller label
/// knocked its value off the row's baseline. `Grid` with `fixedSize` tiles fixed that and broke
/// something worse: a fixed-size tile raises the card's *minimum* width, the dashboard row honoured
/// it, and the whole card ran past the window edge — with `ViewThatFits` never falling back, since the
/// width it measured against was not yet fixed. This reports the proposed width as its own, so it
/// can never widen its container. Inside that width each column gets its natural width plus an even
/// share of what's left; when they don't all fit, columns shrink in proportion to their natural
/// width (tiles carry `minimumScaleFactor`), so the long labels keep the most room.
private struct LedgerLayout: Layout {
    let columns: Int
    let hSpacing: CGFloat
    let vSpacing: CGFloat

    private func widths(_ subviews: Subviews, available: CGFloat) -> [CGFloat] {
        var natural = Array(repeating: CGFloat(0), count: columns)
        for (i, v) in subviews.enumerated() {
            natural[i % columns] = max(natural[i % columns], v.sizeThatFits(.unspecified).width)
        }
        let room = max(0, available - hSpacing * CGFloat(columns - 1))
        let sum = natural.reduce(0, +)
        guard sum > 0 else { return Array(repeating: room / CGFloat(columns), count: columns) }
        if sum <= room { return natural.map { $0 + (room - sum) / CGFloat(columns) } }
        return natural.map { room * $0 / sum }
    }

    private func rowHeights(_ subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        var heights: [CGFloat] = []
        for (i, v) in subviews.enumerated() {
            let h = v.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height
            if i % columns == 0 { heights.append(h) } else { heights[heights.count - 1] = max(heights.last!, h) }
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = widths(subviews, available: .infinity).reduce(0, +) + hSpacing * CGFloat(columns - 1)
        let width = proposal.width ?? natural
        let rows = rowHeights(subviews, widths: widths(subviews, available: width))
        return CGSize(width: width, height: rows.reduce(0, +) + vSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(subviews, available: bounds.width)
        let rows = rowHeights(subviews, widths: w)
        var y = bounds.minY
        for (i, v) in subviews.enumerated() {
            let col = i % columns, row = i / columns
            if col == 0, row > 0 { y += rows[row - 1] + vSpacing }
            let x = bounds.minX + w[..<col].reduce(0, +) + hSpacing * CGFloat(col)
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: w[col], height: rows[row]))
        }
    }
}
