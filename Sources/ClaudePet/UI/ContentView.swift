import SwiftUI
import ClaudePetCore

/// Root widget view: mascot + today header, 5h gauge, weekly bar, per-model breakdown,
/// weekly chart, week/cycle. Scales by widgetScale; a padding ring holds the resize grips
/// clear of the content and grows with the horizontal/vertical resize.
struct ContentView: View {
    @Environment(MetricsStore.self) private var metrics
    @State private var hovering = false
    static let baseWidth: CGFloat = 268
    private static let handleMargin: CGFloat = 11   // transparent margin OUTSIDE the card for the grips
    private static let forceHandles = ProcessInfo.processInfo.environment["CLAUDEPET_HANDLES"] != nil

    var body: some View {
        let scale = CGFloat(metrics.widgetScale)

        content(scale: scale)
            .widgetCard()                            // compact opaque card (small padding)
            .padding(Self.handleMargin)              // transparent margin; grips live out here
            .overlay(ResizeHandles(visible: hovering || Self.forceHandles))
            .contentShape(Rectangle())               // whole area hoverable so grips stay visible
            .onHover { hovering = $0 }
    }

    private func content(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(alignment: .top, spacing: 11 * scale) {
                MascotView(size: 48 * scale)
                StatsHeaderView()
            }
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
        .padding(Theme.padding * scale)
        .frame(width: Self.baseWidth * scale, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.widgetScale, scale)
    }

    private var separator: some View {
        Rectangle().fill(Theme.cardStroke).frame(height: 1)
    }
}
