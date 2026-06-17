import SwiftUI
import ClaudePetCore

/// Root widget view: mascot + today header, 5h gauge, weekly bar, per-model breakdown,
/// weekly chart, week/cycle. Scales by widgetScale; a padding ring holds the resize grips
/// clear of the content and grows with the horizontal/vertical resize.
struct ContentView: View {
    @Environment(MetricsStore.self) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var weatherEngine = WeatherEngine()   // ambient sky behind the pet (owned here so events fan out once)
    @State private var bursts: [BurstItem] = []          // active full-card celebration overlays

    private struct BurstItem: Identifiable { let id = UUID(); let kind: WeatherEvent }
    static let baseWidth: CGFloat = 520       // landscape two-column card
    static let verticalWidth: CGFloat = 300   // original tall single-column card (wide enough for the larger mascot + cost on one line)
    private static let handleMargin: CGFloat = 11   // transparent margin OUTSIDE the card for the grips
    private static let forceHandles = ProcessInfo.processInfo.environment["CLAUDEPET_HANDLES"] != nil

    var body: some View {
        let scale = CGFloat(metrics.widgetScale)

        content(scale: scale)
            .widgetCard()                            // compact opaque card (small padding)
            .overlay {                               // transient celebrations, clipped to the card
                ZStack {
                    ForEach(bursts) { b in
                        CelebrationOverlay(kind: b.kind) { bursts.removeAll { $0.id == b.id } }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .allowsHitTesting(false)
            }
            .padding(Self.handleMargin)              // transparent margin; grips live out here
            .overlay(ResizeHandles(visible: hovering || Self.forceHandles))
            .contentShape(Rectangle())               // whole area hoverable so grips stay visible
            .onHover { hovering = $0 }
            .onChange(of: metrics.pendingWeatherEvents) { _, events in
                drainWeatherEvents(events)
            }
    }

    /// Single drain point for one-shot weather events: clear the queue, then fan each out to the
    /// ambient sky engine and (unless Reduce Motion / disabled) a full-card celebration.
    private func drainWeatherEvents(_ events: [WeatherEvent]) {
        guard !events.isEmpty else { return }
        let drained = metrics.consumeWeatherEvents()        // always clear, even when disabled
        guard metrics.weatherEffectsEnabled, !reduceMotion else { return }
        for event in drained {
            weatherEngine.trigger(event)
            bursts.append(BurstItem(kind: event))
        }
    }

    private func content(scale: CGFloat) -> some View {
        let vertical = metrics.widgetLayout == .vertical
        return Group {
            if vertical { verticalStack(scale: scale) } else { landscapeStack(scale: scale) }
        }
        .padding(Theme.padding * scale)
        .frame(width: (vertical ? Self.verticalWidth : Self.baseWidth) * scale, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.widgetScale, scale)
    }

    /// Wide two-column card: mascot/today + models + chart on the left, gauges + totals right.
    @ViewBuilder private func landscapeStack(scale: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12 * scale) {
            VStack(alignment: .leading, spacing: 9 * scale) {
                header(scale: scale)
                separator
                ModelBreakdownView()
                WeeklyBarChart()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            vDivider

            VStack(alignment: .leading, spacing: 9 * scale) {
                BudgetGauge()
                WeeklyLimitBar()
                separator
                WeekAllTimeView()
                BillingLineView()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Original tall single-column card.
    @ViewBuilder private func verticalStack(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            header(scale: scale)
            separator
            VStack(alignment: .leading, spacing: 9 * scale) {
                BudgetGauge()
                WeeklyLimitBar()
            }
            separator
            ModelBreakdownView()
            separator
            WeeklyBarChart()
            separator
            WeekAllTimeView()
            BillingLineView()
        }
    }

    private func header(scale: CGFloat) -> some View {
        let pet = 64 * scale
        let sky = 88 * scale          // taller than the pet → open sky above it
        return HStack(alignment: .top, spacing: 11 * scale) {
            ZStack(alignment: .bottom) {
                if metrics.weatherEffectsEnabled {
                    WeatherView(width: pet, height: sky, engine: weatherEngine)   // sky overhead
                }
                MascotView(size: pet)                                            // pet stands beneath
            }
            .frame(width: pet, height: sky, alignment: .bottom)
            StatsHeaderView()
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.cardStroke).frame(height: 1)
    }

    private var vDivider: some View {
        Rectangle().fill(Theme.cardStroke).frame(width: 1)
    }
}
