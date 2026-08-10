import SwiftUI

/// Claude-orange palette + shared sizing for the widget.
enum Theme {
    static let claudeCoral = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let highlight   = Color(red: 0.949, green: 0.643, blue: 0.522)   // #F2A485
    static let darkOutline = Color(red: 0.475, green: 0.224, blue: 0.137)   // #793923

    // Opaque, true-black palette. The cards used to be a mid-grey gradient (0.17 → 0.10), which on a
    // large dark display washed the whole thing out: grey card on grey canvas, with the coral fighting
    // both. Now near-black, with only enough lift to separate a card from the canvas — the coral and
    // the white text carry the contrast instead of the background.
    static let cardTop    = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let cardBottom = Color(red: 0.020, green: 0.020, blue: 0.026)
    /// Stronger than the old 0.08: against near-black there's barely any tonal difference left between
    /// card and canvas, so the edge has to define the card itself.
    static let cardStroke = Color.white.opacity(0.11)
    /// True black behind the dashboard window's cards. The widget has no equivalent: it *is* a single
    /// card sitting on the desktop.
    static let windowBackground = Color.black
    // Text tiers, with the contrast each one measures against the card background. Use these — never
    // `.opacity(…)` on top of one.
    //
    // The trap they exist to close: `textSecondary` is ALREADY white at 0.70, so `.opacity(0.6)` on it
    // compounds to 0.42 absolute, not 0.6. In code that reads as "slightly dimmer"; on screen it is
    // 4.0:1, under the 4.5:1 needed for body text. Eight call sites did exactly that, four more sat at
    // 0.39 (3.5:1) and five separators at 0.28 (2.3:1) — which is most of why the grey text was hard to
    // read. Anything carrying words belongs on one of these four.
    static let textPrimary    = Color.white                  // 19:1
    /// Lifted from 0.62 — secondary text is most of the labelling here, and it needs to stay legible
    /// now that it sits on black rather than on a grey that was doing half the work.
    static let textSecondary  = Color.white.opacity(0.70)    // 9.6:1 — captions and body labels
    static let textTertiary   = Color.white.opacity(0.55)    // 6.2:1 — axis ticks, small units
    /// The floor. Nothing readable may go below this; it is for separators and de-emphasised marks.
    static let textFaint      = Color.white.opacity(0.45)    // 4.5:1 — exactly the AA floor

    /// The gauge ramp, **ported from the terminal statusline** (`~/.claude/statusline.sh`) so the two
    /// readouts of the same limits say the same thing in the same colours.
    ///
    /// These six stops are a **contract**, not a starting point — they were tuned over many rounds
    /// against real usage, and the `statusline` skill records the reasoning. Don't nudge one to fix a
    /// local complaint; the invariants below are what they buy, and the app has no better claim on the
    /// palette than the statusline does. Gold `rgb(240,181,68)`, clay `rgb(204,124,94)` and red
    /// `rgb(192,71,66)` are sampled from Claude Code's own Usage panel; clay is the logo colour.
    ///
    /// Four properties hold across 0…100 (re-check them if a stop ever moves):
    /// - **Brightness falls monotonically.** A ramp that peaks mid-range makes low and mid usage render
    ///   nearly the same colour — 16% and 50% once differed by `(4, −12, −6)` and were indistinguishable.
    /// - **Redness (R−G) rises**, 35 → 121.
    /// - **No adjacent-percentage jump above 6 units** — measured max 2.85.
    /// - **Every stop is a warm hue**, so interpolation never passes through a desaturated grey. Blue
    ///   was in this ramp once and was removed for exactly that: blue and gold are near complementary
    ///   and blend through `rgb(152,150,138)`, dead grey. A coral-only ramp shipped here this morning
    ///   for the same reason; this one keeps the hue travel *and* avoids the mud.
    ///
    /// The 90 and 100 stops are the same colour deliberately: the ramp finishes at official red at 90
    /// and holds, which is also where the statusline's critical threshold fires.
    private static let rampStops: [(p: Double, r: Double, g: Double, b: Double)] = [
        (0.00, 250.0 / 255, 215.0 / 255, 130.0 / 255),   // pale yellow
        (0.30, 240.0 / 255, 181.0 / 255,  68.0 / 255),   // official gold
        (0.50, 204.0 / 255, 124.0 / 255,  94.0 / 255),   // Claude clay (the logo)
        (0.80, 214.0 / 255,  96.0 / 255,  72.0 / 255),   // orange-red
        (0.90, 192.0 / 255,  71.0 / 255,  66.0 / 255),   // official red
        (1.00, 192.0 / 255,  71.0 / 255,  66.0 / 255),   // held — see above
    ]

    /// Codex's ramp — cyan into blue, sampled from Codex's own mark for the terminal statusline and
    /// carried here for the same reason the warm ramp is: two readouts of one number in two places
    /// should not disagree about its colour.
    ///
    /// It is a *different* ramp rather than the warm one re-used because the two quotas are
    /// different quotas. A Codex bar in Claude gold reads as a fourth Claude limit.
    private static let codexRampStops: [(p: Double, r: Double, g: Double, b: Double)] = [
        (0.00, 56.0 / 255, 239.0 / 255, 255.0 / 255),
        (0.50, 69.0 / 255, 207.0 / 255, 252.0 / 255),
        (1.00, 78.0 / 255, 175.0 / 255, 252.0 / 255),
    ]

    /// The ramp sampled at one point, as raw components. Single source of the interpolation — every
    /// fill and track goes through here, because two copies of one lerp are two things that can
    /// drift apart.
    private static func rampRGB(_ fraction: Double,
                                stops: [(p: Double, r: Double, g: Double, b: Double)] = rampStops)
        -> (r: Double, g: Double, b: Double)
    {
        let f = min(1, max(0, fraction))
        for i in 1 ..< stops.count where f <= stops[i].p {
            let a = stops[i - 1], b = stops[i]
            let t = b.p == a.p ? 0 : (f - a.p) / (b.p - a.p)
            return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
        }
        let last = stops[stops.count - 1]
        return (last.r, last.g, last.b)
    }

    /// The ramp sampled at one point — the colour that *this* percentage means.
    static func gaugeColor(_ fraction: Double) -> Color {
        let c = rampRGB(fraction)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// One flat colour for the whole bar, picked by the current percentage — **not** a gradient along
    /// its length.
    ///
    /// The gradient was tried and dropped. It is also what the statusline does *not* do: `build_bar`
    /// resolves a single rgb for the whole bar and paints every cell with it. A bar shaded along its
    /// length says "this part of my usage was cooler than that part", which is not a thing that
    /// happened — every token in the window counts the same. One colour per bar reads as one state.
    static func gaugeFill(_ fraction: Double) -> Color { gaugeColor(fraction) }

    /// The unfilled remainder of a gauge: **the fill's own shadow**, so the bar reads as one object
    /// rather than a bright thing sitting on an unrelated brown.
    ///
    /// Same shape as the statusline's — `fill × 12% + floor` — but the floor is re-solved, because
    /// theirs is tuned to **Ghostty's `rgb(40,44,52)`** and our card is `rgb(14,14,16)`. Copying
    /// `(76,62,56)` verbatim onto a background that much darker pushes the track to 2.3–2.8:1, where it
    /// stops reading as an empty track and starts competing with the fill. `(49,40,36)` is what puts
    /// the same *relationships* back on our background:
    ///
    /// |                     | statusline, on Ghostty | here, on our card |
    /// |---------------------|------------------------|-------------------|
    /// | track vs background | 1.66–2.06:1            | 1.60–2.09:1       |
    /// | fill vs track       | ≥ 1.69:1               | ≥ 2.42:1          |
    ///
    /// Both sit inside the statusline's own invariants (track 1.6–2.1:1, fill ≥1.55:1 above it). The
    /// fill/track margin comes out better than the terminal's simply because a darker background leaves
    /// more room at the red end, where `rgb(192,71,66)` is itself only 2.81:1 above Ghostty's grey.
    ///
    /// Tinted at **every** value including zero. Falling back to a neutral grey near zero looked
    /// principled in isolation, but the three gauges are stacked in one column: an idle 0% session
    /// above a 40% weekly meant two tracks disagreeing about what an empty bar looks like, which reads
    /// as a rendering bug rather than as a distinction.
    static func gaugeTrack(_ fraction: Double) -> Color {
        let c = rampRGB(min(1, max(0, fraction)))
        return Color(red:   c.r * 0.12 + 49.0 / 255,
                     green: c.g * 0.12 + 40.0 / 255,
                     blue:  c.b * 0.12 + 36.0 / 255)
    }

    /// The Codex gauge's fill — same rule as `gaugeFill`: one flat colour for the whole bar.
    static func codexGaugeFill(_ fraction: Double) -> Color {
        let c = rampRGB(fraction, stops: codexRampStops)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// The Codex gauge's track. Same `fill × 12% + floor` shape as `gaugeTrack`, with the warm
    /// floor **mirrored** — `(49,40,36)` → `(36,40,49)` — rather than re-used.
    ///
    /// Re-used is the bug that already happened, in the terminal: the warm floor is warm-biased, and
    /// only 12% of the fill survives it, so a cyan fill still produced a grey-brown track that
    /// visibly did not belong to its bar. Mirroring is the same formula reflected, not a new tuning.
    ///
    /// Measured across 0…100 against this card's `rgb(14,14,16)`:
    ///
    /// |                     | warm ramp, (49,40,36) | codex ramp, (36,40,49) | invariant  |
    /// |---------------------|-----------------------|------------------------|------------|
    /// | track vs card       | 1.77–1.92:1           | 1.74–1.89:1            | 1.6–2.1:1  |
    /// | fill vs track (min) | 4.59:1                | 4.68:1                 | ≥ 1.55:1   |
    ///
    /// Re-measure if a stop moves. The warm floor happens to pass with these stops too, which is
    /// exactly why the check has to be run rather than reasoned about.
    static func codexGaugeTrack(_ fraction: Double) -> Color {
        let c = rampRGB(min(1, max(0, fraction)), stops: codexRampStops)
        return Color(red:   c.r * 0.12 + 36.0 / 255,
                     green: c.g * 0.12 + 40.0 / 255,
                     blue:  c.b * 0.12 + 49.0 / 255)
    }

    static let corner: CGFloat = 18
    static let padding: CGFloat = 12
}

extension View {
    /// The opaque rounded card the whole widget sits on (iOS-widget style).
    func widgetCard() -> some View {
        self
            .background(
                LinearGradient(colors: [Theme.cardTop, Theme.cardBottom],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
    }
}
