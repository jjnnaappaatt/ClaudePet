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
    private static let refHeight: CGFloat = 515

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
                HStack(alignment: .top, spacing: 10 * scale) {
                    // Not 50/50. The summary column is a narrow rail; the limits panel holds three
                    // full-width gauges. Split evenly, the left card ran ~40% empty at full screen.
                    card { summaryPanel(scale: scale) }
                        .frame(width: Self.summaryCardWidth(inner: geo.size.width - 24 * scale,
                                                           gap: 10 * scale, scale: scale))
                    card { limitsPanel(scale: scale) }
                }

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
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(Theme.windowBackground)
    }

    /// 38% of the row, but never so narrow that the mascot and the stats column collide.
    private static func summaryCardWidth(inner: CGFloat, gap: CGFloat, scale: CGFloat) -> CGFloat {
        let available = max(0, inner - gap)
        return min(available * 0.5, max(available * 0.38, 400 * scale))
    }

    // MARK: - Panels

    /// The left rail: who you are and what you've spent — mascot, today's headline, today's models,
    /// then the week / cycle / billing totals that used to sit in a footer strip of their own.
    ///
    /// The mascot is deliberately far smaller than the space would allow. Its sky block was the single
    /// biggest fixed height in the layout, and since nothing scrolls, every point of it is a point the
    /// type can't have. It went 172 → 122 → 100. The pet is decoration; the numbers are the product.
    private func summaryPanel(scale: CGFloat) -> some View {
        let pet = 84 * scale
        let sky = 92 * scale          // taller than the pet → open sky above it, as in the widget
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

                VStack(alignment: .leading, spacing: 7 * scale) {
                    StatsHeaderView(compact: true)
                    Text("Today by model")
                        .scaledFont(10, weight: .semibold).foregroundStyle(Theme.textSecondary)
                    ModelBreakdownView()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            divider
            todayDetail(scale: scale)

            // The week / cycle / billing totals. These used to own a full-width footer strip and its
            // own row; here they fill the rail instead, which is what the mascot card was short of.
            Spacer(minLength: 0)
            divider
            WeekAllTimeView(showsExpandButton: false)
            BillingLineView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Two figures that appear nowhere else on the dashboard, filling the gap the rail opens on a
    /// quiet day. Both are chosen because they are **always** present: the model list above is one row
    /// on an Opus-only day and four on a mixed one, so anything sized to it leaves a hole exactly when
    /// there's least to look at.
    private func todayDetail(scale: CGFloat) -> some View {
        let subagentsOn = metrics.includeSubagents
        let share = metrics.sidechainShare(metrics.today)
        return VStack(alignment: .leading, spacing: 5 * scale) {
            statRow("Subagents", scale: scale,
                    value: subagentsOn ? Format.tokens(metrics.sidechainTokens(metrics.today)) : "—",
                    trailing: subagentsOn ? "\(Int((share * 100).rounded()))%" : "off",
                    help: subagentsOn
                        ? "Today's tokens from turns the Task tool ran — subagents and workflow "
                          + "agents. The % is their share of today's figure on the current basis, and "
                          + "it moves when you change that basis: a subagent works in a short-lived "
                          + "context, while the main conversation re-reads a large cached one every "
                          + "turn. So subagents are usually a BIGGER share of 'work' than of "
                          + "cache-inclusive 'total' — measured here, 15% versus 8%."
                        : "\"Include subagent usage\" is off in Settings → Appearance, so these turns "
                          + "aren't counted in any figure here.")
            statRow("All time", scale: scale,
                    value: Format.tokens(metrics.totalsTokens(metrics.allTime)),
                    trailing: Format.currency(metrics.allTime.costUSD),
                    help: "Every turn in your transcripts, as far back as they go — not just this "
                          + "cycle. The cost is the notional API-equivalent estimate.")
        }
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

    private func limitsPanel(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            BudgetGauge()
            divider
            WeeklyLimitBar()
            divider
            DailyPaceView()
            Spacer(minLength: 0)
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
