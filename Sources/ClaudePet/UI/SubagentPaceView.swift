import SwiftUI
import ClaudePetCore

/// "Subagents today" as a pace bar — today's subagent tokens against your usual subagent day.
///
/// **A pace, not a share, and the distinction is what makes the colour honest.** This row used to
/// print the subagent slice as a percentage *of today*, which has no ceiling: 60% subagents is a fact
/// about how you worked, not a warning. Giving that the gauge ramp would have made a heavy-delegation
/// day glow red for no reason, and the ramp means "close to a limit" on every other bar in the app.
///
/// Comparing today against your own recent subagent days is the same question `DailyPaceView` asks, so
/// the ramp keeps its meaning and this bar can mirror that one exactly — full bar = a usual day, pinned
/// once past it, with the exact % in the caption.
struct SubagentPaceView: View {
    var barThickness: CGFloat = 9

    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private var unit: BudgetUnit { metrics.budgetUnit }
    private var todayValue: Double { metrics.subagentTodayValue(unit: unit) }
    private var average: Double { metrics.subagentDailyAverage(unit: unit) }
    private var fraction: Double { metrics.subagentPaceFraction(unit: unit) }
    private var overAverage: Bool { metrics.subagentPaceExceedsAverage(unit: unit) }
    private var hasHistory: Bool { average > 0 }

    private func amount(_ v: Double) -> String {
        unit == .tokens ? Format.tokens(Int(v)) : Format.currency(v)
    }

    private var help: String {
        """
        Today's subagent usage compared with your recent subagent days — turns the Task tool ran, \
        including workflow agents. A pace check, not a budget: there is no subagent limit, and a \
        heavy-delegation day is not a problem in itself. A usual day fills the bar; past that it \
        pins full and the % keeps counting. For their *share* of each day, which is a different \
        question, see the Subagents/day chart below. Turn "Include subagent usage" off in Settings \
        and these turns leave every figure here.
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Subagents today").scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(metrics.includeSubagents ? amount(todayValue) : "off")
                    .scaledFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.gaugeTrack(overAverage ? 1 : fraction))
                    Capsule().fill(Theme.gaugeFill(overAverage ? 1 : fraction))
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: barThickness * scale)

            HStack(spacing: 4) {
                if !metrics.includeSubagents {
                    Text("not counted — see Settings")
                } else if hasHistory {
                    // Deliberately the same shape as `DailyPaceView`'s caption, and nothing more.
                    // The subagent share of today used to ride along on the end of this line; it now
                    // has a chart of its own in the row below, where a share is the whole point
                    // rather than a third clause competing with the pace it sits under.
                    Text("\(amount(average))/day avg · today \(Int((todayValue / average * 100).rounded()))%")
                } else {
                    Text("building subagent average…")
                }
                Spacer()
            }
            .scaledFont(9.5)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
        .help(help)
    }
}
