import SwiftUI

/// Mascot palette. Index 0 is transparent; everything else maps to a Color.
/// Claude-orange forward.
enum Pal {
    static let colors: [UInt8: Color] = [
        0: .clear,
        1: Color(red: 0.851, green: 0.467, blue: 0.341),   // #D97757 body (Claude coral)
        2: Color(red: 0.957, green: 0.667, blue: 0.553),   // #F4AA8D belly highlight
        3: Color(red: 0.353, green: 0.149, blue: 0.094),   // #5A2618 dark outline
        4: .white,                                          // eye white / sparkle
        5: Color(red: 0.106, green: 0.106, blue: 0.118),   // #1B1B1E pupil
    ]
}
