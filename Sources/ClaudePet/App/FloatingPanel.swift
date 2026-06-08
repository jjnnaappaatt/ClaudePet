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
        isFloatingPanel = false
        // Normal level by default: clickable & draggable, and NOT always-on-top
        // (other windows can cover it). "Keep on top" raises it to .floating.
        level = .normal
        isOpaque = false                        // panel itself clear so the card's rounded corners show
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true       // drag-anywhere
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        // Stay on this Space and DON'T cover fullscreen apps (no .canJoinAllSpaces /
        // .fullScreenAuxiliary). "Show on all Spaces" can opt back in.
        collectionBehavior = [.stationary]
        // Do NOT rely on setFrameAutosaveName for a borderless/non-resizable panel.
    }

    /// Toggle always-on-top.
    func setOnTop(_ on: Bool) {
        level = on ? .floating : .normal
    }

    /// Show on every Space (incl. fullscreen) vs only this Space.
    func setShowOnAllSpaces(_ on: Bool) {
        collectionBehavior = on ? [.canJoinAllSpaces, .stationary] : [.stationary]
    }

    // Allow the panel to become key so Settings text fields accept input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
