import SwiftUI

/// Shared pixel palette. Index 0 is transparent; everything else maps to a Color.
/// Indices 1–8 are the mascot (Claude-orange forward); 9+ are the ambient weather layer
/// (`WeatherEngine`), drawn behind the pet by the same renderer.
enum Pal {
    static let colors: [UInt8: Color] = [
        0: .clear,
        // Mascot (1–8)
        1: Color(red: 0.851, green: 0.467, blue: 0.341),   // #D97757 body (Claude coral)
        2: Color(red: 0.957, green: 0.667, blue: 0.553),   // #F4AA8D belly highlight
        3: Color(red: 0.353, green: 0.149, blue: 0.094),   // #5A2618 dark outline
        4: .white,                                          // eye white / sparkle / zzz
        5: Color(red: 0.106, green: 0.106, blue: 0.118),   // #1B1B1E pupil
        6: Color(red: 0.40, green: 0.72, blue: 0.95),      // sweat drop (worried)
        8: Color(red: 0.93, green: 0.30, blue: 0.27),      // alarm mark (alarmed)
        // Weather (7, 9–13)
        7:  Color(red: 0.42, green: 0.62, blue: 0.86),     // rain
        9:  Color(red: 0.78, green: 0.80, blue: 0.85),     // cloud (light)
        10: Color(red: 0.40, green: 0.42, blue: 0.48),     // cloud (dark / storm)
        11: Color(red: 0.99, green: 0.82, blue: 0.36),     // sun
        12: Color(red: 1.00, green: 0.96, blue: 0.62),     // lightning bolt
        13: Color(red: 0.36, green: 0.80, blue: 0.74),     // confetti accent (teal)
    ]
}
