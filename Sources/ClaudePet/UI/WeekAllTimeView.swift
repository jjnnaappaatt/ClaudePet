import SwiftUI
import AppKit
import ClaudePetCore

/// Compact week + all-time line with a Settings (gear) button.
struct WeekAllTimeView: View {
    /// Off in the dashboard, which is already the expanded view — offering to expand it again there
    /// would be a button that does nothing visible.
    var showsExpandButton = true

    /// Off in the dashboard too — "wide vs tall" is a property of the floating widget card
    /// (`ContentView.baseWidth`/`verticalWidth`); the dashboard is always a full, layout-driven
    /// window, so this button would toggle a setting with no visible effect where it's shown.
    var showsLayoutButton = true

    @Environment(MetricsStore.self) private var metrics

    /// **`ViewThatFits`, not `.minimumScaleFactor` alone.** This row already carried Week, Cycle and
    /// a reset countdown before it had any buttons; landscape's right column is roughly half of
    /// `ContentView.baseWidth`, which was already too narrow to shrink-to-fit that much text — real
    /// data showed "15...." and "94...." even with only the expand and gear buttons. A third button
    /// made the same failure slightly worse, but didn't cause it. `minimumScaleFactor` hits its floor
    /// and then *truncates the token figures themselves*, which is the one thing on this line that
    /// must stay exact. Dropping the reset countdown — the least essential piece, still available in
    /// Cycle's own tooltip — is what the rest of this codebase does instead (see
    /// `TodayHourlyChart.header`, `SubagentShareChart.header`, `CycleCalendarView.legend`).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsReset: true)
            row(showsReset: false)
        }
        .scaledFont(10)
        .lineLimit(1)
    }

    private func row(showsReset: Bool) -> some View {
        HStack(spacing: 4) {
            label("Week", metrics.week)
                .help("Current weekly-limit window (resets every 7 days)."
                      + metrics.sidechainNote(metrics.week))
            Text("·").foregroundStyle(Theme.textFaint)
            label("Cycle", metrics.cycle).help(cycleHelp)
            if showsReset, let reset = metrics.cycleReset {
                TimelineView(.periodic(from: .now, by: 3600)) { context in
                    Text("· \(Format.durationLong(reset.timeIntervalSince(context.date)))")
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 4)
            if showsLayoutButton {
                Button(action: toggleLayout) {
                    // Shows the layout you're IN, not the one you'd switch to — same reading as
                    // Settings' segmented control, where the highlighted option is the current one.
                    // `.split.2x1` (side-by-side panes) mirrors `landscapeStack`'s HStack of two
                    // columns; `.split.1x2` (stacked panes) mirrors `verticalStack`'s single VStack.
                    // The help text carries the destination in words, so the icon reading doesn't
                    // have to be unambiguous on its own.
                    Image(systemName: metrics.widgetLayout == .landscape
                          ? "rectangle.split.2x1" : "rectangle.split.1x2")
                        .scaledFont(10.5)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(metrics.widgetLayout == .landscape
                      ? "Wide layout. Switch to the tall single-column card."
                      : "Tall layout. Switch to the wide two-column card.")
            }
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
    }

    /// Same call `SettingsView`'s "Widget layout" picker makes on change — persists the new value
    /// and recomputes, which fires `MetricsStore.onConfigChange` and resizes the panel to fit the
    /// new width/height. One path for the setting, whether it's changed from here or from Settings.
    private func toggleLayout() {
        metrics.widgetLayout = metrics.widgetLayout == .landscape ? .vertical : .landscape
        metrics.saveConfigAndRecompute()
    }

    /// `.fixedSize()` on both runs — the exact figure is the one thing on this line that must never
    /// be the part that gives. Everything a container can't fit gets squeezed by SwiftUI's flexible
    /// layout in roughly the order it's declared, and without this the token count was what lost that
    /// fight, truncating to "15....". Letting the row itself overflow at an extreme size is the
    /// acceptable failure mode here; a wrong-looking number is not.
    private func label(_ name: String, _ t: Totals) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(Theme.textSecondary).fixedSize()
            Text(Format.tokens(metrics.totalsTokens(t))).foregroundStyle(Theme.textPrimary).fixedSize()
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
