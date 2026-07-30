import SwiftUI
import ClaudePetCore

/// The billing cycle as a month calendar, one shaded cell per day — the same data the bar strip used
/// to show, read as density rather than height.
///
/// The cells still sum exactly to the `Cycle` figure in the header: `Aggregator` buckets them with the
/// identical in-cycle predicate that produces the total. A cycle starts on the subscription's
/// anniversary date, so the first and last cells are part-days and the grid needs padding at both ends
/// — that layout lives in `CalendarGrid`, in Core, where it's tested.
struct CycleCalendarView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    private static let dayLetter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f     // single-letter weekday
    }()

    private func value(_ d: DayTotal) -> Double {
        metrics.budgetUnit == .usd ? d.costUSD : Double(metrics.dayTokens(d))
    }

    private func amount(_ v: Double) -> String {
        metrics.budgetUnit == .usd ? Format.currency(v) : Format.tokens(Int(v))
    }

    private var help: String {
        let basis = metrics.budgetUnit == .usd ? "Cost" : "\(metrics.tokenBasisLabel.capitalized) tokens"
        return """
            \(basis) per day across the current billing cycle — darker means heavier. The cells add up \
            to the Cycle figure exactly. The first and last days are part-days, because a cycle starts \
            and ends on your subscription's anniversary time rather than at midnight, so they can look \
            light. Today is outlined; days still to come are empty.
            """
    }

    var body: some View {
        let days = metrics.cycleDaily
        let now = Date()
        let cal = Calendar.current
        let weeks = CalendarGrid.weeks(days, calendar: cal)
        let maxV = max(days.map(value).max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 6 * scale) {
            header
            if weeks.isEmpty {
                Text("no cycle data yet")
                    .scaledFont(10).foregroundStyle(Theme.textSecondary.opacity(0.7))
            } else {
                // Cells are sized from BOTH axes and kept square. Sizing on width alone stretched them
                // into 4px stripes: seven columns across a 900pt card wants ~125pt cells, but the row
                // only had ~90pt of height to give. A calendar's aspect ratio is fixed by its shape —
                // it can't fill an arbitrary rectangle the way a bar chart can.
                GeometryReader { g in
                    let gap = 4 * scale
                    // The weekday header shares this space, so its line has to come off the height
                    // before dividing by the week count — without it the last row fell off the card.
                    let headerRow = 16 * scale
                    let side = max(6, min((g.size.width - gap * 6) / 7,
                                          (g.size.height - headerRow - gap * CGFloat(weeks.count)) / CGFloat(weeks.count)))
                    VStack(spacing: gap) {
                        weekdayHeader(cal: cal, side: side, gap: gap)
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            HStack(spacing: gap) {
                                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                    cell(day, maxV: maxV, now: now, cal: cal)
                                        .frame(width: side, height: side)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(minHeight: 46 * scale)
                legend(maxV: maxV)
            }
        }
        .help(help)
    }

    /// Headline-sized, like the Today figures — this card owns the whole left column, so a caption-sized
    /// title read as a footnote on it.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
            Text("This billing cycle").scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.textPrimary)
            if let start = metrics.cycleStart, let end = metrics.cycleReset {
                Text(start.formatted(.dateTime.month(.abbreviated).day())
                     + " – " + end.formatted(.dateTime.month(.abbreviated).day()))
                    .scaledFont(9).foregroundStyle(Theme.textSecondary.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4 * scale)
            // The cycle TOTAL, so it names the basis rather than sitting beside a "/day" caption —
            // "90.3M work/day" would read as a rate.
            Text(amount(metrics.budgetUnit == .usd
                        ? metrics.cycle.costUSD
                        : Double(metrics.totalsTokens(metrics.cycle))))
                .scaledFont(19, weight: .bold, design: .rounded)
                .foregroundStyle(Theme.textPrimary)
            if metrics.budgetUnit == .tokens {
                Text(metrics.tokenBasisLabel)
                    .scaledFont(9).foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
        }
    }

    /// What the shading means. A density grid is unreadable without it — every other panel here states
    /// its own units, and this one was asking the reader to infer them.
    private func legend(maxV: Double) -> some View {
        HStack(spacing: 5 * scale) {
            Text("less").scaledFont(8).foregroundStyle(Theme.textSecondary.opacity(0.55))
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.claudeCoral.opacity(step == 0 ? 0.06 : 0.16 + 0.74 * step))
                    .frame(width: 9 * scale, height: 9 * scale)
            }
            Text("more").scaledFont(8).foregroundStyle(Theme.textSecondary.opacity(0.55))
            Spacer()
            Text("up to \(amount(maxV))/day")
                .scaledFont(8).foregroundStyle(Theme.textSecondary.opacity(0.55))
                .lineLimit(1)
        }
    }

    /// Column letters in the locale's own week order — `CalendarGrid` places the cells the same way, so
    /// a Sunday-first locale needs no special-casing here.
    private func weekdayHeader(cal: Calendar, side: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(CalendarGrid.weekdayOrder(calendar: cal), id: \.self) { weekday in
                Text(Self.letter(forWeekday: weekday, cal: cal))
                    .scaledFont(8)
                    .foregroundStyle(Theme.textSecondary.opacity(0.55))
                    .frame(width: side)
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: DayTotal?, maxV: Double, now: Date, cal: Calendar) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if let day {
            let isToday = cal.isDate(day.date, inSameDayAs: now)
            let future = day.date > now
            // Floor the filled days well above zero so a light day still reads as "used", instead of
            // vanishing into the empty-day colour and looking like a gap in the cycle.
            let level = future ? 0 : 0.16 + 0.74 * min(1, value(day) / maxV)
            shape
                .fill(Theme.claudeCoral.opacity(level))
                .overlay(shape.stroke(isToday ? Theme.claudeCoral : Color.white.opacity(0.06),
                                      lineWidth: isToday ? 1.5 : 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("\(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): "
                      + amount(value(day)))
        } else {
            // Padding outside the cycle — no border either, so the grid's edges read as ragged rather
            // than as empty days that happen to be unused.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func letter(forWeekday weekday: Int, cal: Calendar) -> String {
        // Build a real date with that weekday so the symbol comes from the locale, not a hardcoded list.
        var comps = DateComponents(); comps.weekday = weekday
        guard let d = cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)
        else { return "" }
        return dayLetter.string(from: d)
    }
}
