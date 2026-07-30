import SwiftUI
import AppKit
import ClaudePetCore

/// Compact week + all-time line with a Settings (gear) button.
struct WeekAllTimeView: View {
    /// Off in the dashboard, which is already the expanded view — offering to expand it again there
    /// would be a button that does nothing visible.
    var showsExpandButton = true

    @Environment(MetricsStore.self) private var metrics

    var body: some View {
        HStack(spacing: 4) {
            label("Week", metrics.week)
                .help("Current weekly-limit window (resets every 7 days)."
                      + metrics.sidechainNote(metrics.week))
            Text("·").foregroundStyle(Theme.textSecondary.opacity(0.4))
            label("Cycle", metrics.cycle).help(cycleHelp)
            if let reset = metrics.cycleReset {
                TimelineView(.periodic(from: .now, by: 3600)) { context in
                    Text("· \(Format.durationLong(reset.timeIntervalSince(context.date)))")
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
            }
            Spacer()
            if showsExpandButton {
                Button {
                    // Open the full dashboard in a real, resizable, full-screen-capable window.
                    NotificationCenter.default.post(name: .openClaudePetDashboard, object: nil)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(10.5)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Open the full dashboard — a resizable window with the whole billing cycle "
                      + "day by day and a per-project breakdown. Supports full screen.")
            }
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
        let base = "This billing cycle: \(range) · resets in \(resets). Anchored to your subscription."
        return base + metrics.sidechainNote(metrics.cycle)
    }
}
