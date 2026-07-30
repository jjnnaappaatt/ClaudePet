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
    /// Measured at 1470×923 (full screen on a 16:10 display, where height binds hardest): 560 fits
    /// with only a hair of margin, so 580 is the value. Test with **both** datasets — real data here
    /// shows one model row, while the sample shows four, and it's the sample that makes the mascot card
    /// taller. Height binds at every realistic window size, so `refHeight` is effectively the
    /// type-size dial: the text got bigger by making the layout need less room, nothing else.
    private static let refWidth: CGFloat = 780
    private static let refHeight: CGFloat = 580

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
            VStack(spacing: 9 * scale) {
                HStack(alignment: .top, spacing: 10 * scale) {
                    // Not 50/50. The pet panel needs the mascot's width plus a short stats column;
                    // the limits panel holds three full-width gauges. Split evenly, the left card ran
                    // ~40% empty at full screen, which reads as unfinished rather than spacious.
                    card { petPanel(scale: scale) }
                        .frame(width: Self.petCardWidth(inner: geo.size.width - 24 * scale,
                                                        gap: 10 * scale, scale: scale))
                    card { limitsPanel(scale: scale) }
                }

                // The only row that stretches. Spare height goes to the cycle chart's bars, so the
                // other cards stay snug around their content instead of framing empty space.
                card { CycleDailyChart() }
                    .frame(maxHeight: .infinity)

                HStack(alignment: .top, spacing: 10 * scale) {
                    card { ProjectBreakdownView() }
                    card { activityPanel(scale: scale) }
                }

                card { footer(scale: scale) }
            }
            .padding(12 * scale)
            .environment(\.widgetScale, scale)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(Theme.windowBackground)
    }

    /// 38% of the row, but never so narrow that the mascot and the stats column collide.
    private static func petCardWidth(inner: CGFloat, gap: CGFloat, scale: CGFloat) -> CGFloat {
        let available = max(0, inner - gap)
        return min(available * 0.5, max(available * 0.38, 400 * scale))
    }

    // MARK: - Panels

    /// The mascot with sky overhead, beside today's headline figures.
    ///
    /// Deliberately far smaller than the space would allow. The sky block was the single biggest fixed
    /// height in the layout, and since nothing scrolls, every point of it is a point the type can't
    /// have. It went 172 → 122 → 100, and the text is ~32% larger for it. The pet is decoration; the
    /// numbers are the product.
    private func petPanel(scale: CGFloat) -> some View {
        let pet = 84 * scale
        let sky = 100 * scale          // taller than the pet → open sky above it, as in the widget
        return HStack(alignment: .top, spacing: 14 * scale) {
            ZStack(alignment: .bottom) {
                if metrics.weatherEffectsEnabled {
                    WeatherView(width: pet, height: sky, engine: weatherEngine)
                }
                MascotView(size: pet)
            }
            .frame(width: pet, height: sky, alignment: .bottom)

            VStack(alignment: .leading, spacing: 10 * scale) {
                StatsHeaderView()
                Spacer(minLength: 0)
                // Labelled, so the gap the tall mascot opens above it reads as a section break
                // rather than as empty space nobody filled.
                Text("Today by model")
                    .scaledFont(10, weight: .semibold).foregroundStyle(Theme.textSecondary)
                ModelBreakdownView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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

    private func activityPanel(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            WeeklyBarChart()
            divider
            TodayHourlyChart()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func footer(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            WeekAllTimeView(showsExpandButton: false)
            BillingLineView()
        }
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
