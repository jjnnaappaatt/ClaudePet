import SwiftUI
import AppKit
import ClaudePetCore

/// Compact week + all-time line with a Settings (gear) button.
struct WeekAllTimeView: View {
    @Environment(MetricsStore.self) private var metrics
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 4) {
            label("Week", metrics.week)
            Text("·").foregroundStyle(Theme.textSecondary.opacity(0.4))
            label("All", metrics.allTime)
            Spacer()
            Button {
                // Bring the accessory app forward so popover text fields get key focus.
                NSApp.activate(ignoringOtherApps: true)
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .scaledFont(11)
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView().environment(metrics)
            }
        }
        .scaledFont(10)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func label(_ name: String, _ t: Totals) -> some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(Theme.textSecondary.opacity(0.8))
            Text(Format.tokens(t.workTokens)).foregroundStyle(Theme.textPrimary)
            Text(Format.currency(t.costUSD)).foregroundStyle(Theme.textSecondary)
        }
    }
}
