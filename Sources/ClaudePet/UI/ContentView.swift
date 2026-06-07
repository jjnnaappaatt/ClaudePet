import SwiftUI
import ClaudePetCore

/// Root widget view: mascot + today header, 5h gauge, per-model breakdown, week/all-time.
/// Sizes itself to its content at the user's chosen widget scale (crisp scaled fonts).
struct ContentView: View {
    @Environment(MetricsStore.self) private var metrics
    static let baseWidth: CGFloat = 268

    var body: some View {
        let scale = CGFloat(metrics.widgetScale)
        VStack(alignment: .leading, spacing: 7 * scale) {
            HStack(alignment: .top, spacing: 10 * scale) {
                MascotView(size: 48 * scale)
                StatsHeaderView()
            }
            separator
            BudgetGauge()
            separator
            ModelBreakdownView()
            separator
            WeekAllTimeView()
        }
        .padding(Theme.padding * scale)
        .frame(width: Self.baseWidth * scale, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.widgetScale, scale)
        .widgetCard()
    }

    private var separator: some View {
        Rectangle().fill(Theme.cardStroke).frame(height: 1)
    }
}
