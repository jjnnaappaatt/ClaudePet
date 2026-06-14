import SwiftUI
import ClaudePetCore

/// Claude-orange palette + shared sizing for the widget.
enum Theme {
    static let claudeCoral = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let highlight   = Color(red: 0.949, green: 0.643, blue: 0.522)   // #F2A485
    static let darkOutline = Color(red: 0.475, green: 0.224, blue: 0.137)   // #793923
    static let warn = Color(red: 1.0, green: 0.584, blue: 0.0)              // #FF9500 (getting tight)
    static let over = Color(red: 1.0, green: 0.231, blue: 0.188)            // #FF3B30 (at the cap)

    /// The single accent colour for a card's binding limit — coral until it's tight.
    static func color(for level: StatusLevel) -> Color {
        switch level {
        case .ok:   return claudeCoral
        case .warn: return warn
        case .over: return over
        }
    }

    // Opaque background (native-widget look — not see-through).
    static let cardTop    = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let cardBottom = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let cardStroke = Color.white.opacity(0.08)
    static let textPrimary    = Color.white
    static let textSecondary  = Color.white.opacity(0.62)

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
