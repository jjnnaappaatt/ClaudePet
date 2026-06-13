import SwiftUI
import AppKit
import ClaudePetCore

/// Optional user-supplied mascot art. If a PNG named `mascot-<emotion>.png` was dropped into
/// `Sources/ClaudePet/Resources/Mascot/`, it's used for that mood; otherwise the built-in
/// pixel art is drawn. ClaudePet ships none of this art — see the Resources/Mascot README.
enum MascotAssets {
    static func image(for emotion: MascotEmotion) -> Image? {
        guard let ns = Bundle.module.image(forResource: "mascot-\(emotion.rawValue)") else { return nil }
        return Image(nsImage: ns)
    }
}
