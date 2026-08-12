import SwiftUI
import ClaudePetCore

/// Codex's own quota, beneath the two Claude gauges. Renders nothing at all when there is no Codex
/// reading — see `CodexLimitBars`.
///
/// Unlike the gauges above it there is no local estimate behind this one and nothing to calibrate:
/// Codex reports the percentage itself, and either we have that figure or we have none.
struct CodexLimitBar: View {
    let limit: CodexLimit
    /// Set when Codex reports more than one window, so "Codex" alone would be ambiguous.
    var nameWindow: Bool = false
    var barThickness: CGFloat = 9

    @Environment(\.widgetScale) private var scale: CGFloat

    private var freshness: CodexFreshness { limit.freshness() }

    private var label: String {
        guard nameWindow else { return "Codex" }
        return limit.windowMinutes < 1440 ? "Codex (session)" : "Codex (weekly)"
    }

    /// Live readings sit at the same tier as the rows above; anything older drops a tier. The bar
    /// keeps its ramp colour either way — the text carries the staleness, so the colour stays free
    /// to carry the number.
    private var textTier: Color {
        freshness == .live ? Theme.textSecondary : Theme.textTertiary
    }

    /// A reset is only worth showing while the window it names is still open AND the reading is
    /// recent enough to be describing the current one. Past either, the honest thing on that line is
    /// how old the number is — a 65-hour-old row once promised a reset that had already happened,
    /// behind a percentage that had since gone from 47% to 0%.
    private var showsReset: Bool { freshness != .ancient && limit.isUsable() }

    private var help: String {
        // Built in pieces: as one chained `+` expression with interpolations the type-checker gave
        // up outright ("unable to type-check this expression in reasonable time").
        var count = ""
        if let used = limit.tokensUsed {
            let amount = Format.tokens(used)
            count = " The token count is summed from Codex's own session rollouts and is a spend"
            count += " figure — every turn resends the context, so it counts \(amount) billed, not"
            count += " \(amount) held in a context window. Cache reads are excluded, so it is the"
            count += " same basis as a \"work\" figure on the Claude rows above — but Codex counts"
            count += " cache the opposite way round (its input_tokens includes the cached part,"
            count += " where Anthropic's excludes it), so the subtraction happens in the statusline"
            count += " before the number reaches here. Left in, this row read 28.2M against a"
            count += " true 2.0M."
        }
        return """
            Codex's own quota, as Codex reported it — read from the statusline's local cache file. \
            ClaudePet does not talk to Codex: no token, no network, same as the Claude rows above. \
            The figure only moves when Codex runs, so this one is \
            \(Format.relativeAge(from: limit.recordedAt)).\(count)
            """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).scaledFont(10, weight: .semibold)
                    .foregroundStyle(textTier)
                Spacer()
                Text("\(Int((limit.fraction * 100).rounded()))%")
                    .scaledFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(textTier)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.codexGaugeTrack(limit.fraction))
                    Capsule().fill(Theme.codexGaugeFill(limit.fraction))
                        .frame(width: max(3, geo.size.width * limit.fraction))
                }
            }
            .frame(height: barThickness * scale)

            HStack(spacing: 4) {
                if let tokens = limit.tokensUsed {
                    // "this week" only when the window actually is a week. Codex reported a
                    // 5-hour window until 2026-07-14 and the format still carries one.
                    //
                    // "work" is spelled out rather than taken from `tokenBasisLabel`: this count is
                    // always cache-excluded, while the Claude rows follow the user's basis. Naming
                    // its own unit is what keeps it honest when they diverge — under `.total` the
                    // row above reads "total" and no false comparison is offered.
                    Text("\(Format.tokens(tokens)) work used this "
                         + "\(limit.windowMinutes >= 1440 ? "week" : "window")")
                }
                Spacer()
                if showsReset {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("resets in \(Format.durationLong(limit.resetsAt.timeIntervalSince(context.date)))")
                    }
                } else {
                    Text(Format.relativeAge(from: limit.recordedAt))
                }
            }
            .scaledFont(9.5)
            .foregroundStyle(textTier)
            .lineLimit(1)
        }
        .help(help)
    }
}

/// Every Codex window the cache offers, or nothing. The wrapper exists so the call sites stay one
/// line and so the "no Codex installed" case is decided in one place: an absent file yields an empty
/// array, and a 0% bar for a tool that isn't installed would be a claim, not a default.
struct CodexLimitBars: View {
    var barThickness: CGFloat = 9

    @Environment(MetricsStore.self) private var metrics

    var body: some View {
        let limits = metrics.codexUsage
        ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in
            CodexLimitBar(limit: limit, nameWindow: limits.count > 1, barThickness: barThickness)
        }
    }
}
