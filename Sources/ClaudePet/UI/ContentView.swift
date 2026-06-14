import SwiftUI
import ClaudePetCore

/// Root widget view. Two faces, both pet-anchored:
/// - **vertical** = one glance: the mascot, the binding limit as one big %, a status word,
///   and a single muted context line.
/// - **landscape** = tiered: mascot + plain-language status, a LIMITS block (only the binding
///   one in coral), a real per-model split, and a muted summary. Detail lives in Settings.
struct ContentView: View {
    @Environment(MetricsStore.self) private var metrics
    @State private var hovering = false
    static let baseWidth: CGFloat = 520       // landscape two-column card
    static let verticalWidth: CGFloat = 260   // tall one-glance card
    private static let handleMargin: CGFloat = 11   // transparent margin OUTSIDE the card for the grips
    private static let forceHandles = ProcessInfo.processInfo.environment["CLAUDEPET_HANDLES"] != nil

    var body: some View {
        let scale = CGFloat(metrics.widgetScale)

        content(scale: scale)
            .widgetCard()
            .padding(Self.handleMargin)
            .overlay(ResizeHandles(visible: hovering || Self.forceHandles))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
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

    // MARK: - Compact (vertical): one glance

    @ViewBuilder private func verticalStack(scale: CGFloat) -> some View {
        let level = metrics.statusLevel
        VStack(spacing: 7 * scale) {
            HStack { Spacer(); gearButton }
            MascotView(size: 92 * scale)
            Text(metrics.statusWord)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.textPrimary)
            Text("\(Int((metrics.bindingFraction * 100).rounded()))%")
                .scaledFont(46, weight: .bold, design: .rounded)
                .foregroundStyle(Theme.color(for: level))
                .lineLimit(1)
            Text(metrics.bindingIsWeekly ? "Weekly limit" : "5-hour session")
                .scaledFont(13)
                .foregroundStyle(Theme.textSecondary)
            glanceContext
                .scaledFont(13)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Resets in 2h 19m · ~$26.38 today" — live countdown of the binding limit + today's cost.
    private var glanceContext: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let reset = metrics.bindingResetDate.map { "Resets in \(Format.durationLong($0.timeIntervalSince(ctx.date)))" }
            let cost = "~\(Format.currency(metrics.today.costUSD)) today"
            Text([reset, cost].compactMap { $0 }.joined(separator: " · "))
        }
    }

    // MARK: - Large (landscape): tiered, pet-anchored

    @ViewBuilder private func landscapeStack(scale: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 14 * scale) {
            // Left: mascot anchor + plain-language status + the two limits.
            VStack(alignment: .leading, spacing: 11 * scale) {
                HStack(alignment: .center, spacing: 12 * scale) {
                    MascotView(size: 84 * scale)
                    VStack(alignment: .leading, spacing: 3 * scale) {
                        Text(metrics.statusWord)
                            .scaledFont(20, weight: .bold)
                            .foregroundStyle(Theme.textPrimary)
                        statusSentence
                            .scaledFont(13)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                sectionLabel("LIMITS")
                LimitRow(label: "5-hour session",
                         fraction: metrics.blockFraction(unit: metrics.budgetUnit),
                         isBinding: !metrics.bindingIsWeekly, level: metrics.statusLevel)
                LimitRow(label: "Weekly · all models",
                         fraction: metrics.weeklyFraction(unit: metrics.budgetUnit),
                         isBinding: metrics.bindingIsWeekly, level: metrics.statusLevel)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            vDivider

            // Right: the per-model split (what the coloured dots were built for) + a muted summary.
            VStack(alignment: .leading, spacing: 10 * scale) {
                HStack {
                    sectionLabel("BY MODEL · TODAY")
                    Spacer()
                    gearButton
                }
                ModelBreakdownView()
                Spacer(minLength: 0)
                Text("Today ~\(Format.currency(metrics.today.costUSD)) · Week \(Format.tokens(metrics.week.workTokens))")
                    .scaledFont(13)
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// "Plenty of headroom — session resets in 2h 19m." (live)
    private var statusSentence: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text(metrics.statusLine(now: ctx.date))
        }
    }

    // MARK: - Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(12, weight: .bold)
            .tracking(0.6)
            .foregroundStyle(Theme.textSecondary.opacity(0.7))
    }

    private var gearButton: some View {
        Button {
            NotificationCenter.default.post(name: .openClaudePetSettings, object: nil)
        } label: {
            Image(systemName: "gearshape.fill")
                .scaledFont(13)
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var vDivider: some View {
        Rectangle().fill(Theme.cardStroke).frame(width: 1)
    }
}
