import SwiftUI
import ClaudePetCore

/// "Today" header: a headline token count (cache-inclusive total by default, or work per the
/// work/total setting), a separate cache-tokens line, and the notional cost.
struct StatsHeaderView: View {
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
            // The device readout fills the trailing side under the cost, one figure per line —
            // the space beside figures that are only ever left-aligned. Three lines against the
            // two token rows, so it gets its own column rather than sharing their baselines. The
            // dashboard uses this same layout: it used to put work and cache on one line to save
            // height, but that line set the column's minimum width, and the readout's three lines
            // are what set the height now either way.
            HStack(alignment: .center, spacing: 4 * scale) {
                VStack(alignment: .leading, spacing: 2) {
                    workFigure.help(tokenCountHelp)
                    cacheFigure.help(Self.cacheHelp)
                }
                Spacer(minLength: 4 * scale)
                VStack(alignment: .trailing, spacing: 1 * scale) {
                    temperature
                    pressure
                    cpu
                }
                .help(Self.deviceHelp)
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
                Image(systemName: "thermometer.medium").scaledFont(11)
                Text(Format.celsius(c)).scaledFont(12.5, weight: .semibold, design: .rounded)
            }
            .foregroundStyle(tint(d.pressure))
            .lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder private var pressure: some View {
        if let d = device {
            Text(d.pressure.label)
                .scaledFont(11.5)
                .foregroundStyle(tint(d.pressure))
                .lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder private var cpu: some View {
        if let p = device?.cpuPercent {
            Text(Format.cpu(p))
                .scaledFont(11.5)
                .foregroundStyle(Theme.textTertiary)
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
