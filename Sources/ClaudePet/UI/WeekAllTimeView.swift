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
            label("Cycle", metrics.cycle).help(cycleHelp)
            if let reset = metrics.cycleReset {
                TimelineView(.periodic(from: .now, by: 3600)) { context in
                    Text("· \(Format.durationLong(reset.timeIntervalSince(context.date)))")
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
            }
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
            Text(Format.tokens(metrics.totalsTokens(t))).foregroundStyle(Theme.textPrimary)
        }
    }

    /// "This billing cycle: Jun 16 – Jul 16 · resets in 1d 4h. Anchored to your subscription."
    /// Falls back to the static description when the cycle dates aren't known yet.
    private var cycleHelp: String {
        guard let start = metrics.cycleStart, let end = metrics.cycleReset else {
            return "This billing cycle — resets monthly with your subscription."
        }
        let range = start.formatted(.dateTime.month(.abbreviated).day())
            + " – " + end.formatted(.dateTime.month(.abbreviated).day())
        let resets = Format.durationLong(end.timeIntervalSince(Date()))
        return "This billing cycle: \(range) · resets in \(resets). Anchored to your subscription."
    }
}
