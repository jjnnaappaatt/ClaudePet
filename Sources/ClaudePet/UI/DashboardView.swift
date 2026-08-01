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
    /// Measured across 900×800 / 1470×923 / **1990×820** / 1990×1256 / 2560×1440, with both datasets.
    /// The wide-but-short case earns its place in that list: it is the only one where the boosts run at
    /// full strength (they key off width) while height is tight, and it is 5px stricter than every
    /// other size — 690 passed everywhere else and clipped there. (It was 1990×760 until `minHeight`
    /// made 760 unreachable; the shape is what matters, not the exact number.)
    ///
    /// 722 → 745 when the subagent row became a full pace bar. The plan that added it assumed the left
    /// card had 74px spare and would grow into it for free; measured, it had **15**, so the top row
    /// grew 18.5pt at scale 1 and the lower row — already at its minimum at 1990×820 — lost the
    /// difference and clipped "By project" off the bottom edge. Every gauge and chart in the card
    /// stretches, so nothing on screen looks tight until it suddenly clips: measure the bottom-most
    /// *card* pixel, not the text.
    ///
    /// Height binds at every realistic window size, so `refHeight` is effectively the type-size dial:
    /// the text only ever got bigger by making the layout need less room. What paid for it, in order of
    /// size: dropping the full-width footer row (folded into a card), splitting the lower half into
    /// three independent columns so the project list's fixed rows stopped *adding* to a chart row's
    /// height, shrinking the mascot 172 → 100, compacting the Today header from three lines to two, and
    /// tightening every padding and gap.
    ///
    /// `refWidth` matters too, and only at narrow windows. It went 780 → 900 when the lower half became
    /// three columns: 780 claimed the layout fits in 780pt, so a 900pt window scaled text up 15% and
    /// overflowed the row. Above ~1100pt height binds and `refWidth` stops mattering entirely.
    private static let refWidth: CGFloat = 900
    private static let refHeight: CGFloat = 745

    /// The boosts are named for **cards**, not for content: the two top panels have swapped sides
    /// once already, and whichever card is *taller* sets the row height — so a boost is free on one
    /// side and expensive on the other purely by position. Re-measure both after any swap.

    /// Extra scale for the left card (mascot, Today, the three gauges, subagents).
    ///
    /// **This is the costly one now.** After the swap the gauges are here and they set the row's
    /// height, so every point of this boost is a point `refHeight` has to grow by — it came down 1.30
    /// → 1.20 for exactly that reason, and the 41px it gave back went to the lower row, where the
    /// calendar wanted it. The guard is **not** "are the two cards equal?" — they share a row and
    /// stretch together, so that reads equal either way. The signal is whether the **card height
    /// changed from the unboosted baseline**.
    private static let usageBoost: CGFloat = 1.04

    /// Extra scale for the Today header alone, on top of the left card's. Its row is as tall as the
    /// mascot's sky block, and two lines of text reached only about 60% of that, leaving a blank under
    /// "3.6M work · 1B cache". Bounded by **width**, not height: both lines have to stay unwrapped in a
    /// narrow column — which is what `boost(_:for:)` below exists to guarantee at small windows.
    private static let headerBoost: CGFloat = 1.6

    /// Extra scale for the right card (Claude Code's lifetime totals, the model grid, week/cycle/
    /// billing), and a fatter gauge bar to match on the left.
    ///
    /// This is the side with the slack now, so it takes the large boost — before the swap it was 1.2
    /// and the same 1.2 on this content left a 191px void between the model grid and the billing lines.
    /// **This is the only dial that makes that card's captions bigger.** They are declared at
    /// 9/9.5/10/10.5, but the dashboard floors every font at `minScaledFont: 12`, so editing those
    /// numbers changes nothing at all — they are already floored. Only the boost moves them.
    ///
    /// **The boundary is not where the old note here claimed.** It said 1.50; measured after the
    /// subagent pace bar made the LEFT card the taller one, the row starts growing at **1.24** and
    /// 1.34 grew it 48pt and clipped the bottom card off the window. Re-measure this after anything
    /// that changes either card — the number in a comment is a fact about a layout that no longer
    /// exists.
    ///
    /// 1.34 is affordable only because `totalsPanel`'s inter-section gap came down with it (10 → 5).
    /// Those gaps scale with the boost, so most of what a bigger boost buys in type it spends again in
    /// leading; tightening them pays for the type out of the card's own slack instead of out of the
    /// page. At 1.34 with the old gaps the top row was 576px, with the new ones it is 528 — the
    /// unboosted baseline, i.e. free.
    private static let totalsBoost: CGFloat = 1.34
    private static let barThickness: CGFloat = 10

    /// Extra scale for the four lower cards.
    ///
    /// They carried no boost at all while the top row carried 1.2–1.3×, so at 1470×923 their captions
    /// rendered ~15.8pt against the top row's ~20.6pt — the *peripheral* text ~23% smaller than the
    /// headline text, which is backwards from how a reader works down a page. Not free: the project
    /// card's fixed rows set the lower row's minimum height, so this multiplies straight into
    /// `refHeight`. It's affordable only because restacking the lower half made that row shorter.
    private static let lowerBoost: CGFloat = 1.12

    /// Boosts buy **height** and are paid for in **width** — and at the minimum window size there is
    /// no width to spend. At 900pt every top-row boost overflowed the row: the gap between the two
    /// cards collapsed to nothing, the left card slid off the screen edge, the model grid truncated to
    /// "In 22…", and "This billing cycle" wrapped onto two lines. None of that shows at 1470.
    ///
    /// So each boost fades in with the width surplus over `minWidth`, reaching full strength at 1.5×
    /// it (1350pt) — the boosts were all measured at 1470, and this is what keeps that measurement
    /// from being applied at a size where it doesn't hold.
    static func boost(_ full: CGFloat, for size: CGSize) -> CGFloat {
        let t = min(1, max(0, (size.width / minWidth - 1) / 0.5))
        return 1 + (full - 1) * t
    }

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
            // TWO rows. The billing footer used to own a full-width strip of its own; folding it into
            // a card removed that row and its gap, and filled space that card was wasting — the two
            // problems turned out to be each other's solution.
            VStack(spacing: 9 * scale) {
                // Both cards take the height of the taller one. Left to their natural sizes one ended
                // well short of the other, leaving a band of dead canvas beside it — the row reads as
                // one band, so the cards have to agree on where its bottom edge is.
                HStack(alignment: .top, spacing: 10 * scale) {
                    // Left: who you are and where you stand right now — mascot, today's headline, and
                    // the three limit gauges. Right: the accumulated totals. Left is the narrower of
                    // the two because gauges are full-width bars that reflow into any width, whereas
                    // the model grid on the right needs real width to hold two columns.
                    let usageScale = scale * Self.boost(Self.usageBoost, for: geo.size)
                    card { usagePanel(scale: usageScale,
                                      headerBoost: Self.boost(Self.headerBoost, for: geo.size)) }
                        .frame(width: Self.usageCardWidth(inner: geo.size.width - 24 * scale,
                                                          gap: 10 * scale, scale: scale,
                                                          size: geo.size),
                               height: nil)
                        .frame(maxHeight: .infinity)
                        .environment(\.widgetScale, usageScale)
                    let totalsScale = scale * Self.boost(Self.totalsBoost, for: geo.size)
                    card { totalsPanel(scale: totalsScale) }
                        .frame(maxHeight: .infinity)
                        .environment(\.widgetScale, totalsScale)
                }
                .fixedSize(horizontal: false, vertical: true)

                // THREE columns, sized by what each shape actually needs.
                //
                // The two charts are wide-and-short by nature — 7 bars and 24 bars — so they stack
                // happily in one narrow column and gain height from it. The calendar is the opposite:
                // its aspect ratio is fixed by its shape, so it takes width priority and gets the
                // largest column. By project is a list of rows: narrow is fine, tall is useful.
                //
                // This is also cheaper than the two-row arrangement it replaced. There, the project
                // card's fixed rows sat *below* a chart row, so both heights added; here every column
                // is independent and the row's minimum is the tallest single one, not a sum.
                // A GeometryReader, because the calendar's width depends on this row's HEIGHT: its
                // cells are square, so seven columns of whatever height the row can spare is all the
                // width it can use. Sized as a fixed fraction it stranded 91pt on each side at
                // 1470×923 while fitting at 900×800 — the fraction that works at one size is wrong at
                // the other. Whatever the calendar doesn't need goes to the charts.
                GeometryReader { lower in
                    let lowerScale = scale * Self.boost(Self.lowerBoost, for: geo.size)
                    let weeks = CalendarGrid.weeks(metrics.cycleDaily).count
                    // `naturalWidth` answers "how wide do square cells of this height want to be", and
                    // once asked it can want a lot: at 51% of the row it starved the other two columns
                    // and pushed the charts off the left edge. The cap is what stops that.
                    //
                    // At 0.40 it is a **backstop that binds at no tested size** — measured, the
                    // calendar asks for 339pt against a 350pt cap at the 900×800 minimum, 302 against
                    // 576 at 1470×923, 270 against 785 at 1990×820. It earns its place only because
                    // `naturalWidth` did once ask for 51%, when the top row was shorter; nothing
                    // guarantees it won't again.
                    //
                    // 0.34 — its first value, set while that was happening — did bind at the minimum,
                    // and cost the calendar 40pt and wrapped "Billing cycle" onto two lines. 0.40 fits
                    // the title on one line, restores the full date range and the legend's peak
                    // figure, and leaves the hour chart 282pt. Renders at 1470×923 / 1990×1256 /
                    // 2560×1440 are byte-identical either way, so tune it at 900×800 or not at all.
                    let calW = min(CycleCalendarView.naturalWidth(cardHeight: lower.size.height,
                                                                 weeks: weeks, scale: lowerScale),
                                   lower.size.width * 0.40)
                    let rest = max(0, lower.size.width - calW - 20 * scale)
                    let chartW = rest * 0.54
                    // Four boxes, not two cards of two panels. The gate is expressed against the
                    // width a panel actually gets, which is `chartW` minus the extra card's own
                    // unscaled padding — so the constant keeps meaning "the narrow panel needs this
                    // much" instead of drifting as the chrome around it changes.
                    let secondary = chartW - 16 >= 350 * scale
                    HStack(alignment: .top, spacing: 10 * scale) {
                        VStack(spacing: 9 * scale) {
                            // Row 1 keeps its unequal split: 24 hourly bars use every point of width
                            // they can get, while the model list is a fixed narrow column. "Which
                            // models did I use today" was the one thing the widget showed that the
                            // dashboard did not. (The right card's model grid is Claude Code's
                            // ALL-TIME `/stats` split, which is a different question.)
                            HStack(alignment: .top, spacing: 10 * scale) {
                                // Both widths pinned, and the model card is NOT `.fixedSize`.
                                // Sized greedily it demanded its full 190*scale + padding out of a
                                // column that didn't have it, the HStack overflowed, and — since
                                // neither `.frame(width:)` nor `.fixedSize` clips — the whole lower
                                // row centred and slid off the LEFT edge of the window. Live at
                                // 1180×900 and invisible at every other size tested.
                                let modelW = secondary ? 190 * scale + 16 : 0
                                let hourW = max(120 * scale,
                                                chartW - (secondary ? modelW + 10 * scale : 0))
                                card { chartPanel(TodayHourlyChart(fillsHeight: true)) }
                                    .frame(width: hourW)
                                    .frame(maxHeight: .infinity)
                                // Squeezed into what was left at 900×800 the model column got 121pt
                                // and broke "Opus" across two lines — a column too narrow to read is
                                // worse than no column, and the same figures are one card up in the
                                // Today header.
                                if secondary {
                                    card {
                                        todayModels(scale: scale * Self.boost(Self.lowerBoost,
                                                                              for: geo.size))
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                    }
                                    .frame(width: modelW)
                                    .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(maxHeight: .infinity)

                            // Row 2 is a true 50/50: two charts over the same seven days, and equal
                            // widths are what make them fair to compare. That leaves the vertical
                            // seam ~48pt off the row above, which is accepted — matching the seams
                            // would mean taking width from the 24-bar chart or handing the subagent
                            // card more room than This week.
                            //
                            // The gate names the VIEW, not the position. It used to hide "the second
                            // panel in the HStack"; after the swap that is `This week`, so a literal
                            // port would have hidden the primary chart at the minimum window size and
                            // kept the subagent one. Nothing about that fails loudly — the layout
                            // still renders, with the wrong chart in it.
                            HStack(alignment: .top, spacing: 10 * scale) {
                                // Pinned to an explicit half, not left to `maxWidth: .infinity`.
                                // Both cards ask for infinity, but SwiftUI still weighs their IDEAL
                                // widths, and this card's header carries three `fixedSize` runs
                                // ("Subagents/day", "% of work", "22% this week") against This
                                // week's two — so it claimed 354pt to the other's 229. Equal widths
                                // are the entire reason these two sit side by side.
                                let halfW = secondary ? (chartW - 10 * scale) / 2 : chartW
                                if secondary {
                                    card { chartPanel(SubagentShareChart()) }
                                        .frame(width: halfW)
                                        .frame(maxHeight: .infinity)
                                }
                                card { chartPanel(WeeklyBarChart(fillsHeight: true)) }
                                    .frame(width: halfW)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(maxHeight: .infinity)
                        }
                        .frame(width: chartW)

                        card { CycleCalendarView() }
                            .frame(width: calW)
                            .frame(maxHeight: .infinity)

                        // The fill frame goes INSIDE the card, not on it. `widgetCard()` draws its
                        // background around whatever the content measures, so an outer `maxHeight`
                        // only stretches the layout slot and leaves a short card floating in the
                        // middle of it — which is what a four-project cycle looked like.
                        card {
                            ProjectBreakdownView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(height: lower.size.height, alignment: .top)
                }
                .frame(maxHeight: .infinity)
                .environment(\.widgetScale, scale * Self.boost(Self.lowerBoost, for: geo.size))
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

    /// The left card takes 46% at the minimum window size and grows to 54% once there's width to
    /// spare — the gauges are long bars that use length, while the model grid opposite has visible
    /// slack at full screen.
    ///
    /// Faded in with `boost(_:for:)` rather than applied flat, and for the same reason that helper
    /// exists: at 900pt the right card is already near its floor, and taking 8% off it there brings
    /// back the "In 22…" truncation. The floor also keeps the Today header's two lines unwrapped
    /// beside the mascot at the minimum size.
    private static func usageCardWidth(inner: CGFloat, gap: CGFloat, scale: CGFloat,
                                       size: CGSize) -> CGFloat {
        let available = max(0, inner - gap)
        let share = 0.46 + (0.54 - 0.46) * (boost(2, for: size) - 1)   // 0.46 → 0.54 with width
        return min(available * 0.60, max(available * share, 360 * scale))
    }

    // MARK: - Panels

    /// The left card: the live picture — mascot, today's headline, and the three limit gauges with
    /// today's subagent share beneath them.
    ///
    /// The mascot is deliberately far smaller than the space would allow. Its sky block was the single
    /// biggest fixed height in the layout, and since nothing scrolls, every point of it is a point the
    /// type can't have. It went 172 → 122 → 100. The pet is decoration; the numbers are the product.
    private func usagePanel(scale: CGFloat, headerBoost: CGFloat) -> some View {
        // The mascot row is as tall as `max(sky, the Today header column)`, and since `headerBoost`
        // the header is the taller of the two — so growing the sky into it costs nothing. Past the
        // header's height it starts setting the row, and lands on `refHeight`.
        // +30%, and the ratio is kept so the clear band the weather needs above the pet survives.
        // NOT free: the mascot row is `max(sky, the Today header column)` and sky binds (88 vs 76), so
        // every point here pushes the top row down into the lower one — measured at 1.9px of calendar
        // width per point of sky. That trade was made deliberately.
        let pet = 99 * scale
        let sky = 114 * scale         // taller than the pet → open sky above it, as in the widget
        return VStack(alignment: .leading, spacing: 6 * scale) {
            // Mascot and today's figures sit SIDE BY SIDE rather than stacked. Stacking read more
            // cleanly but made the card ~40pt taller at scale 1, and in this layout height is type
            // size. Beside the pet, the header is free until it outgrows the sky block.
            HStack(alignment: .top, spacing: 14 * scale) {
                // Three layers — see `ContentView.header` for how the grids relate. The pet and
                // its sky are the 5h session; the ground beneath it is the week.
                ZStack(alignment: .bottom) {
                    if metrics.weatherEffectsEnabled {
                        WeatherView(width: pet, height: sky, engine: weatherEngine)
                    }
                    GroundView(size: pet)
                    MascotView(size: pet)
                }
                .frame(width: pet, height: sky, alignment: .bottom)
                .help(metrics.petSceneDescription)

                // No `maxHeight: .infinity` here. With the card stretching to match the one beside it, a
                // greedy right column swallowed all the slack and pushed what follows down, opening a
                // hole under the Today header. Let this row be as tall as the mascot; the slack belongs
                // to the Spacer at the bottom of the card.
                VStack(alignment: .leading, spacing: 7 * scale) {
                    // Today's figures run larger still. The mascot's sky block sets this row's height,
                    // and two lines of header filled only ~60% of it — so growing them is free, exactly
                    // like `usageBoost`. Unlike everywhere else in this layout, the limit here is
                    // WIDTH: both lines must stay unwrapped in a column that is only ~200pt wide at the
                    // minimum window size.
                    StatsHeaderView(compact: true)
                        .environment(\.widgetScale, scale * headerBoost)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            // The gauges sit under the pet, so the mood on its face and the bar that produced it read
            // as one statement: `mascotEmotion` derives from `blockFraction` — the 5h gauge directly
            // beneath. The weekly bar below it is NOT the face's number; it drives the ground layer
            // under the pet's feet. (It used to be `max(5h, weekly)`; see `MetricsStore`.)
            // A Spacer between every section rather than one at the end. Whatever slack the row has
            // used to pool at the bottom, so the gauges bunched under the mascot with a void beneath
            // them; equal spacers distribute it into the gaps instead, which is what actually reads as
            // "not top-heavy". They cost no height — `minLength: 0` — so this is free at any size.
            //
            // What is NOT free is the content: since the subagent row became a pace bar this card is
            // the taller of the two and therefore sets the row height, so anything added here lands on
            // `refHeight` and shrinks the type on the whole page. Measure before assuming otherwise —
            // the spare here was 15pt, not the 74 an earlier reading of this comment claimed.
            divider
            Spacer(minLength: 0)
            BudgetGauge(barThickness: Self.barThickness)
            Spacer(minLength: 0)
            divider
            WeeklyLimitBar(barThickness: Self.barThickness)
            Spacer(minLength: 0)
            divider
            DailyPaceView(barThickness: Self.barThickness)
            Spacer(minLength: 0)
            divider
            SubagentPaceView(barThickness: Self.barThickness)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// The right card: everything cumulative — Claude Code's own lifetime total and per-model split,
    /// then the week / cycle / billing lines that used to sit in a footer strip of their own.
    ///
    /// With no `/stats` cache — an older Claude Code, or one that has never computed stats — this would
    /// otherwise open on empty space, so fall back to today's models plus our own all-time total.
    private func totalsPanel(scale: CGFloat) -> some View {
        // 10 → 5, and it is what pays for `totalsBoost` 1.16 → 1.34. Six children means six gaps, all
        // scaled by the boost, so raising the boost inflates the leading as fast as the type and the
        // card outgrows the row. Halving the gap is a real typographic trade at 15% larger text, and
        // it keeps the top row at its unboosted 528px instead of 576px.
        VStack(alignment: .leading, spacing: 5 * scale) {
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
            // The KPI tiles take the slack the Spacer used to hold. They keep a Spacer above and
            // below so that when an account has enough models to squeeze the band, the grid is pushed
            // rather than the billing lines — those must never leave the card.
            Spacer(minLength: 0)
            StatsKPIGrid()
            Spacer(minLength: 0)
            divider
            WeekAllTimeView(showsExpandButton: false)
            BillingLineView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Today's per-model split, sharing the hour chart's card. Titled, because unlabelled it reads as
    /// a continuation of the chart beside it rather than a different cut of the day.
    private func todayModels(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text("Today by model").scaledFont(13.5, weight: .semibold)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
            ModelBreakdownView()
            Spacer(minLength: 0)
        }
        .help("Which models you've used today, with tokens and notional cost. The all-time split is "
              + "the model grid in the card above, which is Claude Code's own /stats accounting.")
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
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .widgetCard()
    }

    private var divider: some View {
        Rectangle().fill(Theme.cardStroke).frame(height: 1)
    }
}
