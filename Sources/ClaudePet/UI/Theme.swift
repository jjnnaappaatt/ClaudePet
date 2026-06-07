import SwiftUI

/// Claude-orange palette + shared sizing for the widget.
enum Theme {
    static let claudeCoral = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let highlight   = Color(red: 0.949, green: 0.643, blue: 0.522)   // #F2A485
    static let darkOutline = Color(red: 0.475, green: 0.224, blue: 0.137)   // #793923

    static let cardBackground = Color.black.opacity(0.62)
    static let cardStroke     = Color.white.opacity(0.08)
    static let textPrimary    = Color.white
    static let textSecondary  = Color.white.opacity(0.62)

    static let corner: CGFloat = 16
    static let padding: CGFloat = 12
}

extension View {
    /// The translucent rounded card the whole widget sits on.
    func widgetCard() -> some View {
        self
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
    }
}
