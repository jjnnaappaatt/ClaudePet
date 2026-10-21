import SwiftUI
import ClaudePetCore

/// `/stats`' activity grid: one cell per day, weeks as columns, shaded in its four steps.
///
/// It fills the room between the model list and the ledger, which sat empty on any window taller than
/// the minimum. The grid is sized from that room rather than the other way round: cells are square,
/// their size comes from the height (capped so a tall window doesn't make them chunky), and as many
/// weeks as fit the width are shown, ending at this week — at most a year, like `/stats`. With too
/// little height for a legible cell it draws nothing, so at the minimum window size the panel is
/// exactly what it was.
///
/// Days are **UTC** dates, as `/stats` stores them (see `StatsDay`). Shading follows its `Pd`: none,
/// then by quartile of the active days' message counts.
struct StatsActivityHeatmap: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private static let maxWeeks = 53

    var body: some View {
        if let s = metrics.stats {
            GeometryReader { g in
                let gap = 3 * scale
                let caption = 18 * scale
                let topPad = 12 * scale
                let step = min((g.size.height - caption - topPad + gap) / 7, 15 * scale)
                let weeks = min(Self.maxWeeks, Int((g.size.width + gap) / max(step, 1)))
                if step - gap >= 5 * scale, weeks >= 8 {
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        captionRow(weeks: weeks)
                        grid(s, weeks: weeks, step: step, gap: gap)
                            .frame(width: CGFloat(weeks) * step - gap, height: 7 * step - gap)
                    }
                    .padding(.top, topPad)
                    // Centred in the room it's given, so a cap on cell size leaves even margins
                    // rather than a gap on one side.
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
            .help(help(s))
        }
    }

    private func captionRow(weeks: Int) -> some View {
        HStack(spacing: 6 * scale) {
            Text("Daily activity")
                .scaledFont(9).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 4 * scale)
            Text("less")
                .scaledFont(9).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 2 * scale) {
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 1.5 * scale)
                        .fill(Self.color(level))
                        .frame(width: 7 * scale, height: 7 * scale)
                }
            }
            Text("more")
                .scaledFont(9).foregroundStyle(Theme.textTertiary)
        }
        .lineLimit(1)
        .frame(height: 12 * scale)
    }

    /// `Canvas`, not 371 views: it is one draw, and it renders through `ImageRenderer` like the
    /// mascot does.
    private func grid(_ s: StatsSnapshot, weeks: Int, step: CGFloat, gap: CGFloat) -> some View {
        let today = StatsDay.index(of: Date())
        // 1970-01-01 was a Thursday, so (day + 4) % 7 is the weekday with Sunday = 0.
        let weekday = (today + 4) % 7
        let firstSunday = today - weekday - (weeks - 1) * 7
        let side = step - gap
        return Canvas { ctx, _ in
            for w in 0..<weeks {
                for d in 0..<7 {
                    let day = firstSunday + w * 7 + d
                    guard day <= today else { continue }          // the rest of this week hasn't happened
                    let rect = CGRect(x: CGFloat(w) * step, y: CGFloat(d) * step, width: side, height: side)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: max(1, side * 0.18)),
                             with: .color(Self.color(s.activityLevel(day))))
                }
            }
        }
    }

    /// Coral at four strengths, like `/stats`' ░▒▓█ in its own #da7756; an empty day is the card's
    /// stroke colour, present but quiet. These are fills, not text, so opacity is safe here.
    static func color(_ level: Int) -> Color {
        switch level {
        case 0: return Theme.cardStroke
        case 1: return Theme.claudeCoral.opacity(0.28)
        case 2: return Theme.claudeCoral.opacity(0.5)
        case 3: return Theme.claudeCoral.opacity(0.75)
        default: return Theme.claudeCoral
        }
    }

    private func help(_ s: StatsSnapshot) -> String {
        "Messages per day, the grid /stats draws: \(s.activeDays) active days out of \(s.totalDays). "
            + "Shaded by quartile of your active days; days are UTC dates, as /stats counts them."
    }
}
