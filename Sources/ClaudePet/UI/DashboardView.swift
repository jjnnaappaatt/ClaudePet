import SwiftUI
import ClaudePetCore

/// The expanded, window-sized view of everything the widget shows, plus the two things it has no
/// room for: the whole billing cycle day by day, and the per-project split.
///
/// **Layout-driven, unlike `ContentView`.** The widget pins itself to a fixed width (520/300pt) and
/// the panel is then sized from `content.fittingSize`; that is incompatible with a window the user
/// can drag to any size. Here the geometry flows the other way — the window's size arrives via
/// `GeometryReader` and the content fills it, with `widgetScale` derived from the width so text
/// grows with the window instead of stranding a 10pt font on a 27-inch display.
///
/// Two deliberate abstentions:
/// - It sets the `\.widgetScale` **environment key** and never writes `metrics.widgetScale`, so
///   resizing this window can't resize the user's widget.
/// - It does **not** drain `metrics.pendingWeatherEvents`. `ContentView` is the single drain point
///   (see `MetricsStore.detectWeatherEdges`); a second consumer would race it and each window would
///   swallow celebrations meant for the other. The ambient sky still works — `WeatherView` reads
///   `metrics.weatherCondition` directly and needs no events.
/// - No `Form`/`.formStyle(.grouped)` anywhere: that is what makes `SettingsView` render blank
///   through `ImageRenderer`, and this view has to stay snapshot-verifiable (`CLAUDEPET_DASHBOARD`).
struct DashboardView: View {
    @Environment(MetricsStore.self) private var metrics
    @State private var weatherEngine = WeatherEngine()   // ambient sky only; never event-driven here

    /// Matches `DashboardWindowController.contentMinSize`. The whole layout — footer included — is
    /// verified to fit here via `CLAUDEPET_DASHBOARD` + `CLAUDEPET_DASHSIZE=900x800`, which is why
    /// the view needs no `ScrollView` (and a `ScrollView` would risk the same `ImageRenderer`
    /// blankness that stops `SettingsView` from being snapshot-checkable).
    ///
    /// Measured, not guessed — guessing was wrong twice. 620 cut the billing footer off entirely, and
    /// 740 fit the sample's short project list while still clipping on real data. Re-measure with
    /// `CLAUDEPET_REAL=1` if you add a row.
    static let minWidth: CGFloat = 900
    static let minHeight: CGFloat = 800

    /// Reference size the layout occupies at scale 1.0. These set the type size: everything scales off
    /// `min(width/refWidth, height/refHeight)`, so the ONLY way to enlarge the text is to make the
    /// layout need less room — hence the mascot being much smaller here than in the widget.
    ///
    /// `refHeight` must be **≥ the height the layout actually needs at scale 1**, and getting this
    /// wrong doesn't degrade, it breaks: when height is the binding axis, scale is `height/refHeight`,
    /// so required height is `need × height/refHeight` — which exceeds the window at *every* height if
    /// `refHeight < need`, not just at small ones. That shipped once, in 0.6.0.
    ///
    /// Measured at 1470×923 — full screen on a 16:10 display, where height binds hardest. Always test
    /// with **both** datasets: real data shows one model row here while the sample shows four, and it's
    /// the sample that makes the summary rail taller.
    ///
    /// Height binds at every realistic window size, so `refHeight` is effectively the type-size dial:
    /// the text only ever got bigger by making the layout need less room. What paid for it, in order of
    /// size: dropping the full-width footer row (folded into the summary rail), giving Week and Hourly
    /// their own columns instead of stacking them, shrinking the mascot 172 → 100, trimming the project
    /// list 8 → 6 rows, compacting the Today header from three lines to two, and tightening every
    /// padding and gap.
    ///
    /// The rail is the binding element in the top row and its stats column already exceeds the sky
    /// block, so shrinking the mascot again buys nothing — the remaining levers are all content.
    private static let refWidth: CGFloat = 780
    private static let refHeight: CGFloat = 620

    /// Extra scale for the summary rail only, filling the card the limits panel stretches it to.
    ///
    /// Measured: the rail's content reached only ~78% of the card at every window size (23% blank at
    /// 900×800, 22% at 1470×923, 20% at 1990×1256), because the *right* card sets the row height. That
    /// slack is free — growing into it costs no type size elsewhere and doesn't move `refHeight`.
    ///
    /// **1.18 is the boundary, not a preference.** Measured across 900×800 / 1470×923 / 1990×1256 with
    /// real data (seven models — the tallest case): at 1.18 the card heights and the window's bottom
    /// margin are identical to not boosting at all, and the blank drops to 6–10%. At 1.20 the rail
    /// becomes the card that *sets* the row height, and the bottom margin at 1470×923 goes 3px → 0.
    ///
    /// Don't raise it without re-measuring, and don't trust "are the two cards equal?" as the guard —
    /// they share a row and stretch together, so that reads equal either way. The signal is whether the
    /// **card height changed from the unboosted baseline**.
    private static let summaryBoost: CGFloat = 1.18

    /// Text grows with the window, clamped so it neither crowds at the minimum size nor turns into a
    /// poster on a large display.
    ///
    /// Driven by **both** axes, and that matters. Scaling on width alone inflated every fixed height
    /// in the layout — the mascot's sky, the bar heights — as the window widened, so a wide-but-short
    /// window clipped the billing footer despite having horizontal room to spare. That isn't an edge
    /// case: it is exactly the shape native full screen produces on a 16:10 display (1470×923 here).
    static func scale(for size: CGSize) -> CGFloat {
        min(2.4, max(1.0, min(size.width / refWidth, size.height / refHeight)))
    }

    var body: some View {
        GeometryReader { geo in
            let scale = Self.scale(for: geo.size)
            // Every one of these gaps and paddings is vertical budget, and vertical budget IS type
            // size here — see `refHeight`. They're deliberately tight so the text can be large.
            // THREE rows, not four. The billing footer used to own a full-width strip of its own;
            // folding it into the summary column removed that row and its gap, and filled the space
            // the mascot card was wasting — the two problems turned out to be each other's solution.
            VStack(spacing: 9 * scale) {
                // Both cards take the height of the taller one. Left to their natural sizes the summary
                // card ended well short of the limits card, leaving a band of dead canvas beside it —
                // the row reads as one band, so the cards have to agree on where its bottom edge is.
                HStack(alignment: .top, spacing: 10 * scale) {
                    // Not 50/50. The summary column is a narrow rail; the limits panel holds three
                    // full-width gauges. Split evenly, the left card ran ~40% empty at full screen.
                    // The rail runs at its OWN scale. Its content filled only ~78% of the card, because
                    // the limits card beside it sets the height — so the remaining fifth was free to
                    // grow into, costing no type size anywhere else on the page.
                    let railScale = scale * Self.summaryBoost
                    card { summaryPanel(scale: railScale) }
                        .frame(width: Self.summaryCardWidth(inner: geo.size.width - 24 * scale,
                                                           gap: 10 * scale, scale: scale),
                               height: nil)
                        .frame(maxHeight: .infinity)
                        .environment(\.widgetScale, railScale)
                    card { limitsPanel(scale: scale) }
                        .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                // The only row that stretches. Spare height goes to the cycle chart's bars, so the
                // other cards stay snug around their content instead of framing empty space.
                card { CycleDailyChart() }
                    .frame(maxHeight: .infinity)

                // Week and hourly get their own columns rather than stacking in one card. Stacked,
                // they made this row as tall as two charts; side by side the row is only as tall as
                // the tallest single panel, and that saving goes straight into the type size.
                HStack(alignment: .top, spacing: 10 * scale) {
                    card { ProjectBreakdownView() }
                    card { chartPanel(WeeklyBarChart(fillsHeight: true)) }
                    card { chartPanel(TodayHourlyChart(fillsHeight: true)) }
                }
            }
            .padding(12 * scale)
            .environment(\.widgetScale, scale)
            // Lift the bottom of the type ramp: the 7-9.5pt captions ("work/day", "resets in", the hour
            // axis) were drawn for a 300pt widget card and read too small blown up. Raising the global
            // scale can't fix that - it lifts the headlines equally. Widget keeps the unfloored ramp.
            .environment(\.minScaledFont, 12)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(Theme.windowBackground)
    }

    /// 52% of the row. The rail carries a two-column model grid with In/Out under each name, so it needs
    /// real width; the limits card is full-width bars and text that reflow happily in what's left.
    private static func summaryCardWidth(inner: CGFloat, gap: CGFloat, scale: CGFloat) -> CGFloat {
        let available = max(0, inner - gap)
        return min(available * 0.62, max(available * 0.52, 400 * scale))
    }

    // MARK: - Panels

    /// The left rail: who you are and what you've spent — mascot, today's headline, today's models,
    /// then the week / cycle / billing totals that used to sit in a footer strip of their own.
    ///
    /// The mascot is deliberately far smaller than the space would allow. Its sky block was the single
    /// biggest fixed height in the layout, and since nothing scrolls, every point of it is a point the
    /// type can't have. It went 172 → 122 → 100. The pet is decoration; the numbers are the product.
    private func summaryPanel(scale: CGFloat) -> some View {
        let pet = 66 * scale
        let sky = 74 * scale          // taller than the pet → open sky above it, as in the widget
        return VStack(alignment: .leading, spacing: 8 * scale) {
            // Mascot and today's figures sit SIDE BY SIDE, and the model list goes in the right column
            // beside the pet rather than beneath it. Stacking them read more cleanly but made the rail
            // ~40pt taller at scale 1, and this rail sets the whole top row's height — which is type
            // size. Beside the pet, the list is free until it outgrows the sky block.
            HStack(alignment: .top, spacing: 14 * scale) {
                ZStack(alignment: .bottom) {
                    if metrics.weatherEffectsEnabled {
                        WeatherView(width: pet, height: sky, engine: weatherEngine)
                    }
                    MascotView(size: pet)
                }
                .frame(width: pet, height: sky, alignment: .bottom)

                // No `maxHeight: .infinity` here. With the card now stretching to match the limits card
                // beside it, a greedy right column swallowed all the slack and pushed the model grid
                // down, opening a hole under the Today header. Let this row be as tall as the mascot;
                // the slack belongs to the Spacer at the bottom of the card.
                VStack(alignment: .leading, spacing: 7 * scale) {
                    StatsHeaderView(compact: true)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            // Claude Code's own lifetime figures. "Today by model" used to sit here; it was a second
            // model list directly above this one, and dropping it is most of what paid for these rows.
            //
            // With no `/stats` cache — an older Claude Code, or one that has never computed stats — the
            // rail would otherwise be a mascot above empty space, so fall back to what used to be here.
            divider
            if metrics.statsCache != nil {
                StatsModelBreakdownView()
            } else {
                Text("Today by model")
                    .scaledFont(10, weight: .semibold).foregroundStyle(Theme.textSecondary)
                ModelBreakdownView()
                statRow("All time", scale: scale,
                        value: Format.tokens(metrics.totalsTokens(metrics.allTime)),
                        trailing: Format.currency(metrics.allTime.costUSD),
                        help: "Every turn in your transcripts. Claude Code's own /stats total would show "
                              + "here instead, but its cache (~/.claude/stats-cache.json) wasn't found.")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Today's subagent slice, under the three bars it's a share of. (The old "All time" row beside it
    /// is gone — `StatsModelBreakdownView` shows Claude Code's own lifetime total instead, which is the
    /// number `/stats` prints.)
    private func subagentRow(scale: CGFloat) -> some View {
        let on = metrics.includeSubagents
        let share = metrics.sidechainShare(metrics.today)
        return statRow("Subagents today", scale: scale,
                       value: on ? Format.tokens(metrics.sidechainTokens(metrics.today)) : "—",
                       trailing: on ? "\(Int((share * 100).rounded()))%" : "off",
                       help: on
                           ? "Today's tokens from turns the Task tool ran — subagents and workflow "
                             + "agents. The % is their share of today's figure on the current basis, and "
                             + "it moves when you change that basis: a subagent works in a short-lived "
                             + "context, while the main conversation re-reads a large cached one every "
                             + "turn. So subagents are usually a BIGGER share of 'work' than of "
                             + "cache-inclusive 'total' — measured here, 15% versus 8%."
                           : "\"Include subagent usage\" is off in Settings → Appearance, so these turns "
                             + "aren't counted in any figure here.")
    }

    private func statRow(_ label: String, scale: CGFloat, value: String, trailing: String,
                         help: String) -> some View {
        HStack(spacing: 6 * scale) {
            Text(label).scaledFont(10.5, weight: .medium).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4 * scale)
            Text(value).scaledFont(10.5, design: .rounded).foregroundStyle(Theme.textPrimary)
            Text(trailing).scaledFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(Theme.claudeCoral.opacity(0.9))
                .frame(width: 52 * scale, alignment: .trailing)
        }
        .lineLimit(1)
        .help(help)
    }

    /// The three usage bars, then the subagent share, then the week / cycle / billing totals.
    ///
    /// Subagents moved here from the rail by request — it belongs beside the bars it's a share of. The
    /// billing lines followed for a different reason: this card had ~90pt of slack at scale 1 while the
    /// rail had none, and in a two-card row only the taller card sets the height.
    private func limitsPanel(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            BudgetGauge()
            divider
            WeeklyLimitBar()
            divider
            DailyPaceView()
            divider
            subagentRow(scale: scale)
            Spacer(minLength: 0)
            divider
            WeekAllTimeView(showsExpandButton: false)
            BillingLineView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One chart per card in the bottom row. No trailing `Spacer` — the charts are built with
    /// `fillsHeight`, so they grow into the card themselves rather than sitting on top of a void.
    private func chartPanel<Content: View>(_ chart: Content) -> some View {
        chart.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Chrome

    /// The widget's card treatment, reused per region so the dashboard reads as the same product.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .widgetCard()
    }

    private var divider: some View {
        Rectangle().fill(Theme.cardStroke).frame(height: 1)
    }
}
