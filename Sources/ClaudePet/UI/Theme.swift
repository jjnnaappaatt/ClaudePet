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

    /// The gauge ramp: the app's own coral family, pale peach with headroom deepening to ember at the
    /// limit — **not** a traffic light, and deliberately not Claude's colours either.
    ///
    /// Claude's own Usage panel was measured pixel by pixel before this was written: `#4177D0` on a
    /// bar reading 8%, `#F0B544` on one reading 80%, each **flat** across the whole fill (zero
    /// variation over 780px) and switched at a threshold. Adopting it was tried and rejected — blue
    /// and amber are near complementary, so a continuous ramp between them passes through
    /// `rgb(152,150,138)`, a dead grey, and needs light bridge stops to avoid mud. Staying in one hue
    /// family has no such problem. Recorded here so the experiment isn't repeated from scratch.
    ///
    /// **The nine stops are the point, not padding.** Three stops interpolated in RGB is continuous in
    /// value but not in *rate*: measured in OKLab, its lightness moved 1.51× faster in some parts of
    /// the bar than others, with a visible kink where `claudeCoral` sat. These nine are sampled at
    /// equal **perceptual** arc length along the coral path, which brings that to 1.12× — near
    /// uniform. The ends are also pushed out to `#F8D3C0` and `#9E2A1F`, giving **75%** more
    /// perceptual travel (OKLab L 0.893 → 0.467, against the old 0.788 → 0.543), because the old ramp
    /// was nearly monochrome and the gradient could barely be seen at all.
    ///
    /// Re-derive rather than hand-edit: nudging one stop re-introduces exactly the uneven rate this
    /// exists to remove.
    private static let rampStops: [(p: Double, r: Double, g: Double, b: Double)] = [
        (0.000, 0.973, 0.827, 0.753),   // #F8D3C0
        (0.125, 0.964, 0.739, 0.642),   // #F6BDA4
        (0.250, 0.950, 0.650, 0.531),   // #F2A687  ≈ highlight
        (0.375, 0.907, 0.566, 0.442),   // #E79071
        (0.500, 0.859, 0.481, 0.356),   // #DB7B5B  ≈ claudeCoral
        (0.625, 0.820, 0.390, 0.283),   // #D16348
        (0.750, 0.779, 0.290, 0.212),   // #C74A36
        (0.875, 0.715, 0.207, 0.155),   // #B63528  ≈ ember
        (1.000, 0.620, 0.165, 0.122),   // #9E2A1F
    ]

    /// The ramp sampled at one point, as raw components. Single source of the interpolation — both
    /// `gaugeColor` and `gaugeTrack` go through here, because two copies of one lerp are two things
    /// that can drift apart.
    private static func rampRGB(_ fraction: Double) -> (r: Double, g: Double, b: Double) {
        let f = min(1, max(0, fraction))
        for i in 1 ..< rampStops.count where f <= rampStops[i].p {
            let a = rampStops[i - 1], b = rampStops[i]
            let t = b.p == a.p ? 0 : (f - a.p) / (b.p - a.p)
            return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
        }
        let last = rampStops[rampStops.count - 1]
        return (last.r, last.g, last.b)
    }

    /// The ramp sampled at one point — the colour that *this* percentage means.
    static func gaugeColor(_ fraction: Double) -> Color {
        let c = rampRGB(fraction)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// The ramp painted **along** the bar, so the fill is a continuous gradient instead of one flat
    /// colour that happens to be interpolated.
    ///
    /// The mapping is position → percentage, not position → 0…1 of the fill: a stop sits at
    /// `stop.p / fraction`, so the pixel standing for 50% is the same mid-coral whether the bar is at
    /// 60% or at 100%. Rescaling to the fill's own length instead would repaint the whole ramp on every
    /// change and make the colour at a given point meaningless.
    static func gaugeGradient(_ fraction: Double) -> LinearGradient {
        let f = min(1, max(0.02, fraction))    // floor: a 0% bar still has 3pt of capsule to paint
        var stops = rampStops.filter { $0.p < f }
            .map { Gradient.Stop(color: gaugeColor($0.p), location: $0.p / f) }
        stops.append(Gradient.Stop(color: gaugeColor(f), location: 1))
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// The unfilled remainder of a gauge, as a dark tint of **the fill's own hue** — a deep coral
    /// under a coral bar, darkening with it.
    ///
    /// The idea is borrowed from Claude's Usage panel — the colours are not. Measured there, the
    /// track is always a dark step of the fill's own hue (blue fill on `#0B1F40`, amber on `#2E1B04`)
    /// and that is what makes "how full" legible at a glance: their amber-on-brown is 8.9:1
    /// fill-vs-track, where our old flat white-12% track managed 4.5:1. Their two tracks sit at HSL
    /// lightness 0.147 and 0.098, so a single 0.12 stands in for both — applied here to *our* coral
    /// ramp, which gives a dark coral under a coral bar.
    ///
    /// Tinted at **every** value including zero. Falling back to a neutral grey below ~0 looked
    /// principled in isolation, but the three gauges are stacked in one column: an idle 0% session
    /// above a 40% weekly meant two tracks disagreeing about what an empty bar looks like, which
    /// reads as a rendering bug rather than as a distinction. `.nan` still lands on grey, via
    /// `rampComponents`.
    static func gaugeTrack(_ fraction: Double) -> Color {
        let c = rampComponents(min(1, max(0, fraction)))
        return Color(hslHue: c.h, saturation: c.s, lightness: 0.12)
    }

    /// The fill colour's HSL hue and saturation, which is all the track needs — it supplies its own
    /// lightness. `Double.nan` in gives a grey track rather than a crash, which is the right failure
    /// for a decorative capsule.
    private static func rampComponents(_ f: Double) -> (h: Double, s: Double) {
        let rgb = rampRGB(f)
        let mx = max(rgb.r, rgb.g, rgb.b), mn = min(rgb.r, rgb.g, rgb.b)
        let d = mx - mn
        let l = (mx + mn) / 2
        guard d > 0.0001 else { return (0, 0) }
        let s = d / (1 - abs(2 * l - 1))
        let h: Double
        switch mx {
        case rgb.r: h = ((rgb.g - rgb.b) / d).truncatingRemainder(dividingBy: 6)
        case rgb.g: h = (rgb.b - rgb.r) / d + 2
        default:    h = (rgb.r - rgb.g) / d + 4
        }
        return (h * 60 < 0 ? h * 60 + 360 : h * 60, min(1, s))
    }

    static let corner: CGFloat = 18
    static let padding: CGFloat = 12
}

extension Color {
    /// HSL, not HSB. SwiftUI ships `Color(hue:saturation:brightness:)`, and the two are not the same
    /// thing — HSB's "brightness" of a saturated colour is 1.0, so it can't express "same hue, much
    /// darker" without also draining the saturation. That is exactly what `Theme.gaugeTrack` needs.
    init(hslHue h: Double, saturation s: Double, lightness l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1:  (r, g, b) = (c, x, 0)
        case ..<2:  (r, g, b) = (x, c, 0)
        case ..<3:  (r, g, b) = (0, c, x)
        case ..<4:  (r, g, b) = (0, x, c)
        case ..<5:  (r, g, b) = (x, 0, c)
        default:    (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m)
    }
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
