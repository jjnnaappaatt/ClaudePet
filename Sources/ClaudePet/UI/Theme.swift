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
    static let textPrimary    = Color.white
    /// Lifted from 0.62 — secondary text is most of the labelling here, and it needs to stay legible
    /// now that it sits on black rather than on a grey that was doing half the work.
    static let textSecondary  = Color.white.opacity(0.70)

    /// Gauge fill for a 0…1 fraction: a continuous ramp **within the Claude palette**, not a
    /// traffic light.
    ///
    /// The bars used to jump `coral → .orange → .red` at 70% and 90%. Those last two are system
    /// colours that belong to no palette here — the weekly bar rendered a flat amber that fought the
    /// coral everywhere else. This keeps the same "hotter as it fills" reading using the palette's own
    /// hues: light `highlight` when there's headroom, `claudeCoral` mid-way, deepening to a saturated
    /// ember at the limit. Interpolating also removes the visual cliff, where one extra token flipped
    /// the whole bar to a different colour.
    static func gaugeColor(_ fraction: Double) -> Color {
        let f = min(1, max(0, fraction))
        // Stops sampled from the palette: highlight #F2A485 → claudeCoral #D97757 → ember #C0392B.
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.949, 0.643, 0.522),
            (0.55, 0.851, 0.467, 0.341),
            (1.00, 0.753, 0.224, 0.169),
        ]
        for i in 1..<stops.count where f <= stops[i].0 {
            let (p0, r0, g0, b0) = stops[i - 1]
            let (p1, r1, g1, b1) = stops[i]
            let t = p1 == p0 ? 0 : (f - p0) / (p1 - p0)
            return Color(red: r0 + (r1 - r0) * t,
                         green: g0 + (g1 - g0) * t,
                         blue: b0 + (b1 - b0) * t)
        }
        return Color(red: stops.last!.1, green: stops.last!.2, blue: stops.last!.3)
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
