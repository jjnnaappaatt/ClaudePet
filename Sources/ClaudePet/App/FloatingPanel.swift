import AppKit

/// A frameless, transparent, always-on-top, drag-anywhere panel that shows on all Spaces.
///
/// Load-bearing corrections (verified against Apple docs):
/// - `.borderless` (raw value 0) adds nothing; you get frameless by *omitting* `.titled`.
/// - `level = .floating` is REQUIRED — the style mask alone does not float above other windows.
/// - `isMovableByWindowBackground = true` is REQUIRED — drag-anywhere is not automatic for borderless.
/// - `.nonactivatingPanel` must be set at init; toggling the style mask later breaks key-event delivery.
/// - Must be an actual `NSPanel` subclass; the delegate keeps a strong reference.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel],   // omit .titled => frameless
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating                       // REQUIRED for always-on-top
        isOpaque = false
        backgroundColor = .clear                // transparent
        hasShadow = true
        isMovableByWindowBackground = true       // REQUIRED for drag-anywhere
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        // Visible on every Space and unaffected by Mission Control / over fullscreen apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Do NOT rely on setFrameAutosaveName for a borderless/non-resizable panel.
    }

    // Allow the panel to become key so Settings text fields accept input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
