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
                    .scaledFont(10).foregroundStyle(Theme.textSecondary)
            } else {
                // Cells are SQUARE, and the card is sized to suit rather than the other way round.
                //
                // A square cell can only be as big as the scarcer axis, and here that is always height:
                // seven columns across a wide card want far more width than the row can give in height.
                // Letting cells go wide to fill the card was tried (a 2.6:1 cap) and it does remove the
                // dead space, but a month grid of 2.6:1 tiles stops reading as a calendar. So the cells
                // stay square and `DashboardView` gives this card a narrow column instead — the fix
                // belongs in the column width, not in the cell shape.
                GeometryReader { g in
                    let gap = 4 * scale
                    // The weekday header shares this space, so its line has to come off the height
                    // before dividing by the week count — without it the last row fell off the card.
                    let headerRow = 16 * scale
                    let rows = CGFloat(weeks.count)
                    let fullW = max(6, (g.size.width - gap * 6) / 7)
                    let fullH = max(6, (g.size.height - headerRow - gap * rows) / rows)
                    let side = min(fullH, fullW)                 // square: the scarcer axis wins
                    let cellH = side, cellW = side
                    VStack(spacing: gap) {
                        weekdayHeader(cal: cal, side: cellW, gap: gap)
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            HStack(spacing: gap) {
                                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                    cell(day, maxV: maxV, now: now, cal: cal)
                                        .frame(width: cellW, height: cellH)
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

    /// How wide this card wants to be for a given height.
    ///
    /// Square cells make the width a **function of the height** — seven columns of whatever the row
    /// can spare vertically — so the column can't be a fixed fraction of the window. It was, and at
    /// 1470×923 that left a 241pt grid centred in a 424pt card: 91pt dead on each side, the same
    /// failure as the original square-cell attempt, just moved. `DashboardView` calls this to size the
    /// column from the row height instead.
    ///
    /// The chrome figures are measured, and errors here degrade gently in both directions: too narrow
    /// and the cells simply become width-bound and a little smaller; too wide and a little slack
    /// returns. Neither clips.
    static func naturalWidth(cardHeight: CGFloat, weeks: Int, scale: CGFloat) -> CGFloat {
        let cardPadding: CGFloat = 16                  // `card()` pads 8 on each side, unscaled
        let chrome = (46 + 14 + 12) * scale            // stacked header + legend + the two 6pt gaps
        let gap = 4 * scale
        let headerRow = 16 * scale                     // the weekday letters
        let rows = CGFloat(max(1, weeks))
        let gridH = max(30 * scale, cardHeight - cardPadding - chrome)
        let side = max(6, (gridH - headerRow - gap * rows) / rows)
        return side * 7 + gap * 6 + cardPadding
    }

    /// Two lines, not one. The total used to sit at the end of the title row, which meant the header
    /// needed ~420pt before it would fit — and that, not the grid, was what set this card's minimum
    /// width and kept it from ever being narrow enough for square cells to fill it. Stacking also
    /// reads as more of a headline, not less: the figure gets a line of its own instead of being
    /// squeezed against the right edge.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            // The card is deliberately narrow now, so the date range is dropped whole rather than
            // clipped to "4 Jul – 4…", which says less than nothing. Same degradation as the charts.
            ViewThatFits(in: .horizontal) {
                titleRow(withDates: true)
                titleRow(withDates: false)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
                // The cycle TOTAL, so it names the basis rather than sitting beside a "/day" caption —
                // "90.3M work/day" would read as a rate.
                Text(amount(metrics.budgetUnit == .usd
                            ? metrics.cycle.costUSD
                            : Double(metrics.totalsTokens(metrics.cycle))))
                    .scaledFont(26, weight: .bold, design: .rounded)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                if metrics.budgetUnit == .tokens {
                    Text(metrics.tokenBasisLabel)
                        .scaledFont(9).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func titleRow(withDates: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
            Text("This billing cycle").scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
            if withDates, let start = metrics.cycleStart, let end = metrics.cycleReset {
                Text(start.formatted(.dateTime.month(.abbreviated).day())
                     + " – " + end.formatted(.dateTime.month(.abbreviated).day()))
                    .scaledFont(9).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// What the shading means. A density grid is unreadable without it — every other panel here states
    /// its own units, and this one was asking the reader to infer them.
    private func legend(maxV: Double) -> some View {
        ViewThatFits(in: .horizontal) {
            legendRow(maxV: maxV, withPeak: true)
            legendRow(maxV: maxV, withPeak: false)
        }
    }

    private func legendRow(maxV: Double, withPeak: Bool) -> some View {
        HStack(spacing: 5 * scale) {
            Text("less").scaledFont(8).foregroundStyle(Theme.textTertiary).fixedSize()
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.claudeCoral.opacity(step == 0 ? 0.06 : 0.16 + 0.74 * step))
                    .frame(width: 9 * scale, height: 9 * scale)
            }
            Text("more").scaledFont(8).foregroundStyle(Theme.textTertiary).fixedSize()
            Spacer(minLength: 4 * scale)
            if withPeak {
                Text("up to \(amount(maxV))/day")
                    .scaledFont(8).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    /// Column letters in the locale's own week order — `CalendarGrid` places the cells the same way, so
    /// a Sunday-first locale needs no special-casing here.
    private func weekdayHeader(cal: Calendar, side: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(CalendarGrid.weekdayOrder(calendar: cal), id: \.self) { weekday in
                Text(Self.letter(forWeekday: weekday, cal: cal))
                    .scaledFont(8)
                    .foregroundStyle(Theme.textTertiary)
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
