import SwiftUI
import AppKit
import ClaudePetCore

/// Compact week + all-time line with a Settings (gear) button.
struct WeekAllTimeView: View {
    @Environment(MetricsStore.self) private var metrics

    var body: some View {
        HStack(spacing: 4) {
            label("Week", metrics.week).help("Current weekly-limit window (resets every 7 days).")
            Text("·").foregroundStyle(Theme.textSecondary.opacity(0.4))
            label("Cycle", metrics.cycle).help("This billing cycle — resets monthly with your subscription.")
            Spacer()
            Button {
                // Open Settings in a real key-capable window (text fields need keyboard focus).
                NotificationCenter.default.post(name: .openClaudePetSettings, object: nil)
            } label: {
                Image(systemName: "gearshape.fill")
                    .scaledFont(11)
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .scaledFont(10)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func label(_ name: String, _ t: Totals) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(Theme.textSecondary.opacity(0.8))
            Text(Format.tokens(t.workTokens)).foregroundStyle(Theme.textPrimary)
        }
    }
}
