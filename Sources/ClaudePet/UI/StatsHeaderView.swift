import SwiftUI
import ClaudePetCore

/// "Today" header: a headline token count (cache-inclusive total by default, or work per the
/// work/total setting), a separate cache-tokens line, and the notional cost.
struct StatsHeaderView: View {
    /// Put the token count and the cache count on ONE line instead of two.
    ///
    /// On in the dashboard, where this view sits in the summary rail — and that rail sets the whole top
    /// row's height, which is the dashboard's type size, since nothing scrolls. Off in the widget,
    /// where the stats column is only ~200pt wide and the two figures wouldn't fit side by side.
    var compact = false

    @Environment(MetricsStore.self) private var metrics
    @Environment(\.widgetScale) private var scale

    /// Names the basis and, when there is one, the subagent slice — sub-agents are a big share of
    /// real usage but a tiny share of *work* tokens, so on that basis they look uncounted.
    private var tokenCountHelp: String {
        let base = metrics.tokenBasis == .total
            ? "Total tokens = input + output + cache reads & writes — everything Claude processed. Switch to 'work' in Settings → Appearance."
            : "Work tokens = input + output (the actual prompt & response) — around 1% of what Claude really processes once prompt caching is counted. Switch to 'total' in Settings → Appearance."
        return base + metrics.sidechainNote(metrics.today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5 * scale) {
                Text("Today")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(metrics.plan.displayName)
                    .scaledFont(8.5, weight: .bold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 1.5 * scale)
                    .background(Theme.claudeCoral.opacity(0.20), in: Capsule())
                    .foregroundStyle(Theme.claudeCoral)
                Spacer()
                Text("~" + Format.currency(metrics.today.costUSD))
                    .scaledFont(21, weight: .bold, design: .rounded)
                    .foregroundStyle(Theme.claudeCoral)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Notional API-equivalent cost (estimate) — on a subscription you don't pay per token. The token counts below are exact (read from Claude's transcripts).")
            }
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                    workFigure
                    Text("·").scaledFont(11).foregroundStyle(Theme.textFaint)
                    cacheFigure
                }
                .lineLimit(1)
                .help(tokenCountHelp + "\n\n" + Self.cacheHelp)
                HStack(spacing: 6 * scale) {
                    Spacer(minLength: 0)
                    temperature
                    if DeviceMonitor.shared.reading?.celsius != nil {
                        Text("·").scaledFont(10).foregroundStyle(Theme.textFaint)
                    }
                    pressureAndCPU
                }
                .help(Self.deviceHelp)
            } else {
                // The device readout fills the trailing side of these two rows — the space under
                // the cost that sat empty, beside figures that are only ever left-aligned.
                HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                    workFigure.help(tokenCountHelp)
                    Spacer(minLength: 4 * scale)
                    temperature.help(Self.deviceHelp)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                    cacheFigure.help(Self.cacheHelp)
                    Spacer(minLength: 4 * scale)
                    pressureAndCPU.help(Self.deviceHelp)
                }
            }
        }
    }

    // MARK: - Device readout

    private var device: DeviceReading? { DeviceMonitor.shared.reading }

    /// Nominal stays quiet; only a Mac under pressure earns colour, and the ramp mirrors the gauge
    /// ramp's meaning — warm means "close to a limit". Never `.opacity` on a text token.
    private func tint(_ p: ThermalPressure) -> Color {
        switch p {
        case .nominal: return Theme.textSecondary
        case .fair: return Theme.highlight
        case .serious: return Theme.claudeCoral
        case .critical: return Theme.gaugeColor(1)
        }
    }

    @ViewBuilder private var temperature: some View {
        if let d = device, let c = d.celsius {
            HStack(spacing: 2 * scale) {
                Image(systemName: "thermometer.medium").scaledFont(9.5)
                Text(Format.celsius(c)).scaledFont(10.5, weight: .semibold, design: .rounded)
            }
            .foregroundStyle(tint(d.pressure))
            .lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder private var pressureAndCPU: some View {
        if let d = device {
            HStack(spacing: 4 * scale) {
                Text(d.pressure.label).foregroundStyle(tint(d.pressure))
                if let cpu = d.cpuPercent {
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(Format.cpu(cpu)).foregroundStyle(Theme.textTertiary)
                }
            }
            .scaledFont(10)
            .lineLimit(1).fixedSize()
        }
    }

    private static let deviceHelp = "This Mac: the hottest SoC die sensor, macOS's thermal state "
        + "(Nominal → Fair → Serious → Critical; above Nominal the system starts slowing down), and "
        + "ClaudePet's own CPU use averaged over the last 15 seconds — 100% would be one full core. "
        + "Read locally from the Mac's sensors; nothing leaves the machine."

    private var workFigure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Format.tokens(metrics.totalsTokens(metrics.today)))
                .scaledFont(17, weight: .bold, design: .rounded)
                .foregroundStyle(Theme.textPrimary)
            Text(metrics.tokenBasisLabel)
                .scaledFont(10).foregroundStyle(Theme.textSecondary)
        }
    }

    private var cacheFigure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Format.tokens(metrics.today.cacheTokens))
                .scaledFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(Theme.textSecondary)
            Text("cache").scaledFont(10).foregroundStyle(Theme.textSecondary)
        }
    }

    private static let cacheHelp = "Cache tokens (reads + writes). Claude re-reads the cached conversation every turn, so this dwarfs 'work'. Cheap per token (reads cost 0.025–0.1× of input, depending on the model)."
}
