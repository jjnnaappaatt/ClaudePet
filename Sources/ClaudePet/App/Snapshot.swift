import SwiftUI
import AppKit

/// Permission-free verification: renders a SwiftUI view straight to a PNG via
/// `ImageRenderer` (no screen capture, so no Screen-Recording TCC prompt).
/// Renders at the view's own intrinsic size. Triggered by env vars in AppDelegate.
enum Snapshot {
    @MainActor
    static func render<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
        // Composite over a mid-tone "desktop" so translucent cards / rounded corners show.
        let framed = view.background(Color(white: 0.30))

        let renderer = ImageRenderer(content: framed)
        renderer.scale = scale
        renderer.isOpaque = true

        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: ImageRenderer produced no image\n".utf8))
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed: \(error)\n".utf8))
        }
    }
}
